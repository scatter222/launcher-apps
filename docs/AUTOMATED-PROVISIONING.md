# Automated provisioning: bringing the API up around FreeIPA

The API host is built before FreeIPA exists, so nothing Kerberos can be done at
kickstart time. This is the ordered set of commands for the automation that runs
afterwards, once FreeIPA answers.

Every block says which host it runs on, and every block is safe to re-run.

Substitute your own names:

```bash
API_FQDN=api.example.com
IPA_FQDN=ipa.example.com
REALM=EXAMPLE.COM
BASE_DN=dc=example,dc=com
DOMAIN=example.com
```

---

## What runs when

| Phase | Host | FreeIPA needed |
| --- | --- | --- |
| 1. Packages, app, unit file | API host | No, do it at kickstart |
| 2. Wait for readiness | either | Waiting on it |
| 3. Groups and DNS records | FreeIPA server | Yes |
| 4. Enrol, keytab, service config | API host | Yes |
| 5. Verification gate | API host | Yes |

---

## Four rules that bite automation

1. **Never re-fetch a keytab unconditionally.** `ipa-getkeytab` without `-r`
   mints a *new* key and invalidates the one your running service is using. A
   playbook that re-runs this breaks a working system. Phase 4 guards it.
2. **Fix the clock before any Kerberos command.** More than five minutes of
   skew and everything fails, often with misleading errors.
3. **Enrol before generating the service keytab.** Enrolment rotates host keys
   and can disturb services created beforehand, leaving a keytab that decrypts
   nothing.
4. **Readiness is not reachability.** FreeIPA answers DNS well before its KDC
   and directory are usable. Wait for a ticket, not for a ping.

---

## Phase 1: kickstart, before FreeIPA exists

On the **API host**. No Kerberos, no enrolment, no keytab.

```bash
dnf install -y ipa-client krb5-workstation openldap-clients bind-utils nginx

# ... install the application to /opt/launcher-api ...
```

Write the unit now, but keep it from flapping before provisioning has produced
a keytab. `ConditionPathExists` makes systemd skip the start cleanly rather
than crash-looping:

```bash
cat > /etc/systemd/system/launcher-api.service <<'EOF'
[Unit]
Description=Launcher API
After=network-online.target sssd.service
Wants=network-online.target
ConditionPathExists=/etc/krb5.keytab.api

[Service]
WorkingDirectory=/opt/launcher-api
ExecStart=/opt/launcher-api/LauncherApi
Environment=ASPNETCORE_URLS=http://0.0.0.0:5000
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=KRB5_KTNAME=/etc/krb5.keytab.api
Environment=KRB5_CLIENT_KTNAME=/etc/krb5.keytab.api
Environment=KRB5CCNAME=FILE:/run/launcher-api/krb5cc
RuntimeDirectory=launcher-api
ExecStartPre=/usr/bin/kinit -k -t /etc/krb5.keytab.api -c FILE:/run/launcher-api/krb5cc HTTP/API_FQDN_PLACEHOLDER
Restart=always
RestartSec=5
SyslogIdentifier=launcher-api

[Install]
WantedBy=multi-user.target
EOF

sed -i "s/API_FQDN_PLACEHOLDER/${API_FQDN}/" /etc/systemd/system/launcher-api.service
systemctl daemon-reload
systemctl enable launcher-api        # enable, do not start
```

The three `KRB5` variables are all needed and do different jobs:
`KRB5_KTNAME` decrypts inbound tickets, `KRB5_CLIENT_KTNAME` authenticates the
outbound LDAP bind, and `KRB5CCNAME` gives the service a cache it can write.

---

## Phase 2: wait for FreeIPA to be usable

From the **API host**. Install takes 15 to 25 minutes, so allow for it. The
final check is a real ticket, because DNS and LDAP come up before the KDC is
ready.

```bash
ready=0
for i in $(seq 1 90); do
  if host "$IPA_FQDN" >/dev/null 2>&1 &&
     ldapsearch -x -H "ldap://${IPA_FQDN}" -b "" -s base namingContexts \
       2>/dev/null | grep -q "dc=" &&
     kinit -k -t /root/automation.keytab -c FILE:/tmp/.ready svc-automation >/dev/null 2>&1
  then
    kdestroy -c FILE:/tmp/.ready
    ready=1
    break
  fi
  sleep 20
done
[ "$ready" = 1 ] || { echo "FreeIPA not ready after 30 minutes"; exit 1; }
```

The last check needs some credential, and a keytab for an automation principal
is the one to use here, because it keeps passwords off the host. Creating that
principal is below. If you only have the admin password, run this loop on the
FreeIPA server instead of on the API host.

On Oracle Linux and RHEL 8, piping into `kinit` can fail because it reads from
the terminal. Use a file redirect instead:

```bash
umask 077; printf '%s' "$IPA_ADMIN_PASSWORD" > /tmp/.pw
kinit admin < /tmp/.pw
rm -f /tmp/.pw
```

Better still, give your automation its own principal and keytab so no password
appears in a playbook or a process list at all:

```bash
# once, by hand, on the FreeIPA server
ipa user-add svc-automation --first=Svc --last=Automation
ipa-getkeytab -p svc-automation -k /root/automation.keytab
# then in automation
kinit -k -t /root/automation.keytab svc-automation
```

That principal needs enough privilege for host enrolment and keytab retrieval,
which means a role with the Host Enrollment privilege rather than full admin.
With the one-time password flow in phase 3, it does not need to reach the API
host at all.

---

## Phase 3: on the FreeIPA server

Groups and DNS. All idempotent.

```bash
kinit admin

# Authorization groups the API's policies refer to
for g in launcher-users launcher-vm-users launcher-admins; do
  ipa group-show "$g" >/dev/null 2>&1 || ipa group-add "$g"
done

# Nesting: members of launcher-vm-users are also seen in launcher-users,
# because FreeIPA keeps memberOf expanded
ipa group-add-member launcher-users --groups=launcher-vm-users 2>/dev/null || true

# Forward and reverse DNS for the API name. Reverse matters because a client
# with rdns enabled will use the PTR name as the service principal.
ipa dnsrecord-add "$DOMAIN" api --a-rec="$API_IP" 2>/dev/null || true
ipa dnszone-add "$REVERSE_ZONE" 2>/dev/null || true
ipa dnsrecord-add "$REVERSE_ZONE" "$LAST_OCTET" --ptr-rec="${API_FQDN}." 2>/dev/null || true
```

Watch the reverse record. If several names share one address, the PTR can only
name one of them, and a client that canonicalises will ask for that name. Point
the PTR at the name clients actually dial, or set `rdns = false` on clients.

### Pre-create the host and service, and hand out a one-time password

This is what keeps admin credentials off the API host entirely. The host
enrols with a single-use password, then fetches its own service keytab using
its own host credentials.

```bash
# service principal, and permission for the host to retrieve its keytab
ipa service-show "HTTP/${API_FQDN}" >/dev/null 2>&1 || \
  ipa service-add "HTTP/${API_FQDN}"
ipa service-allow-retrieve-keytab "HTTP/${API_FQDN}" --hosts="$API_FQDN" \
  2>/dev/null || true

# one-time password for enrolment, only needed if the host is not yet enrolled
if ipa host-show "$API_FQDN" >/dev/null 2>&1; then
  OTP=$(ipa host-mod "$API_FQDN" --random | awk '/Random password:/ {print $3}')
else
  OTP=$(ipa host-add "$API_FQDN" --force --no-reverse --random \
        | awk '/Random password:/ {print $3}')
fi
echo "$OTP"      # hand this to the API host's automation
```

The password is single-use and worthless once enrolment consumes it, so it is
far safer to pass around than an admin password. Only issue a new one when the
host is not already enrolled, since doing so permits a re-enrolment.

The `service-allow-retrieve-keytab` grant is what makes phase 4 re-runnable:
with it, the host can use `ipa-getkeytab -r` to fetch the **existing** key
rather than minting a new one.

---

## Phase 4: on the API host

### 4a. Clock first

```bash
chronyc makestep 2>/dev/null || true
date -u                                  # compare against the FreeIPA server
```

### 4b. Resolver

```bash
cat > /etc/resolv.conf <<EOF
search ${DOMAIN}
nameserver ${IPA_IP}
EOF

grep -q "dns=none" /etc/NetworkManager/NetworkManager.conf 2>/dev/null ||
  sed -i '/\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
systemctl restart NetworkManager || true
```

### 4c. Enrol, only if not already enrolled

Enrol with the one-time password from phase 3. No `--principal`, so no admin
credentials reach this host.

```bash
if [ ! -f /etc/ipa/default.conf ]; then
  ipa-client-install --unattended \
    --hostname="$API_FQDN" --domain="$DOMAIN" --realm="$REALM" \
    --server="$IPA_FQDN" --password="$OTP" \
    --mkhomedir --no-ntp
fi

grep -q "rdns = false" /etc/krb5.conf || echo "  check rdns in /etc/krb5.conf"
```

Any password on a command line is briefly visible in the process list, which is
the other reason to use a single-use one here.

Enrolment is what writes `rdns = false` and the realm configuration, so if you
skip it you must write `/etc/krb5.conf` yourself.

### 4d. Authenticate as the host itself

Enrolment left a host keytab, so this host can act for itself. `kinit -k` with
no principal uses the default entry in `/etc/krb5.keytab`, which is
`host/api.example.com@EXAMPLE.COM`.

```bash
kinit -k
klist                     # expect host/${API_FQDN}@${REALM}
```

The service principal was created in phase 3, so there is nothing to create
here and no admin ticket is needed.

### 4e. Keytab, only when the current one does not work

This is the guard that makes re-runs safe. Fetching unconditionally rotates the
key and breaks the running service.

```bash
need_keytab=1
if [ -f /etc/krb5.keytab.api ] &&
   kinit -k -t /etc/krb5.keytab.api -c FILE:/tmp/.ktest "HTTP/${API_FQDN}" 2>/dev/null
then
  kdestroy -c FILE:/tmp/.ktest
  need_keytab=0
fi

if [ "$need_keytab" = 1 ]; then
  # -r retrieves the existing key, so other copies keep working. It needs the
  # retrieve grant from phase 3. Without the grant, drop -r and accept that a
  # new key is minted.
  ipa-getkeytab -r -s "$IPA_FQDN" -p "HTTP/${API_FQDN}" -k /etc/krb5.keytab.api ||
    ipa-getkeytab -s "$IPA_FQDN" -p "HTTP/${API_FQDN}" -k /etc/krb5.keytab.api
  chmod 600 /etc/krb5.keytab.api
  klist -kte /etc/krb5.keytab.api
fi
```

`kinit -k -t` succeeding is the only reliable test that a keytab's key still
matches the KDC. File existence proves nothing.

### 4f. Trust the FreeIPA CA for LDAPS

```bash
if [ -f /etc/ipa/ca.crt ]; then
  cp /etc/ipa/ca.crt /etc/pki/ca-trust/source/anchors/ipa-ca.crt
  update-ca-trust extract
fi
```

### 4g. Application configuration

```bash
mkdir -p /etc/systemd/system/launcher-api.service.d
cat > /etc/systemd/system/launcher-api.service.d/freeipa.conf <<EOF
[Service]
Environment=FreeIpa__LdapUri=ldaps://${IPA_FQDN}:636
Environment=FreeIpa__Realm=${REALM}
EOF
```

Group names live in the application's `Authorization:Policies` section and must
match the groups from phase 3. Template that file from the same variables your
automation uses here, so the two cannot drift apart.

### 4h. Start

```bash
systemctl daemon-reload
systemctl restart launcher-api
```

---

## Phase 5: verification gate

Assert on these so a bad provision fails loudly instead of quietly serving 403s.

```bash
set -e

# the keytab's key matches the KDC
kinit -k -t /etc/krb5.keytab.api -c FILE:/tmp/.v "HTTP/${API_FQDN}"
kdestroy -c FILE:/tmp/.v

# the service acquired its own credentials
test -s /run/launcher-api/krb5cc
klist -c FILE:/run/launcher-api/krb5cc | grep -q "HTTP/${API_FQDN}@${REALM}"

# the directory read the API depends on
kinit -k -t /etc/krb5.keytab.api "HTTP/${API_FQDN}"
ldapsearch -Y GSSAPI -H "ldaps://${IPA_FQDN}" \
  -b "cn=users,cn=accounts,${BASE_DN}" "(uid=testuser)" memberOf | grep -q "^memberOf"
kdestroy

# the API answers
curl -fsk https://localhost/api/health >/dev/null

echo "provisioning verified"
```

The group read is the check worth keeping. Authentication can be perfect while
the LDAP bind fails, and the only visible symptom is users being denied.

---

## Re-running safely

| Operation | Safe to repeat | Why |
| --- | --- | --- |
| `ipa group-add`, `ipa service-add`, `dnsrecord-add` | Yes, guarded | Already-exists is not a failure |
| `ipa-client-install` | Only behind the `default.conf` check | Re-enrolment rotates host keys |
| `ipa-getkeytab` **without** `-r` | **No** | Mints a new key, breaks the running service |
| `ipa-getkeytab -r` | Yes | Retrieves the existing key, needs the retrieve permission |
| systemd drop-ins, CA trust, resolver | Yes | Plain file writes |

To grant the retrieve permission once, so later runs can use `-r` freely:

```bash
ipa service-allow-retrieve-keytab "HTTP/${API_FQDN}" --hosts="$API_FQDN"
```

## Rotating a keytab on purpose

```bash
kinit admin
ipa-getkeytab -s "$IPA_FQDN" -p "HTTP/${API_FQDN}" -k /etc/krb5.keytab.api
chmod 600 /etc/krb5.keytab.api
systemctl restart launcher-api
```

Inbound and outbound both read this one file, so they change together and there
is no window where one works and the other does not.

---

Diagnostics for when one of these steps has not taken:
[KERBEROS-TROUBLESHOOTING.md](KERBEROS-TROUBLESHOOTING.md). The specific fix for
a service whose ticket is never replaced:
[FIX-SERVICE-TICKET-REFRESH.md](FIX-SERVICE-TICKET-REFRESH.md).
