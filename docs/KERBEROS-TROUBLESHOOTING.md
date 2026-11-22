# Kerberos and FreeIPA Troubleshooting Runbook

Commands to run and what the output should look like, for an API that
authenticates callers with Kerberos/SPNEGO and reads their group membership
from FreeIPA over LDAP.

Written to be self-contained, so it can be copied to a host with no network
access. Substitute throughout:

| Placeholder | Meaning | Example |
| --- | --- | --- |
| `api.example.com` | DNS name of the API host, as clients dial it | |
| `ipa.example.com` | FreeIPA server | |
| `EXAMPLE.COM` | Kerberos realm, uppercase | |
| `dc=example,dc=com` | LDAP base DN, the realm as `dc` components | |
| `jsmith` | A test user's login | |
| `10.0.0.5` | The API host's address | |

---

## Start here: which failure do you have?

The message text tells you which layer is broken. Match it before changing
anything.

| Message | Layer | What it means |
| --- | --- | --- |
| `Server not found in Kerberos database` | client to KDC | The client asked for a service principal that does not exist. Read the principal name in the message. |
| `No Kerberos credentials available` | client | The user has no ticket. Run `kinit`. |
| `Clock skew too great` | time | More than five minutes of drift between client, KDC or server. |
| `An exception occurred while processing the authentication request`, `GenericFailure`, `Decrypt integrity check failed`, `Key table entry not found` | server keytab | The ticket arrived and the server cannot decrypt it. Read the GSSAPI minor code. See step 9. |
| `KDC has no support for encryption type` | enctype | The keytab's encryption types do not overlap with the KDC's. |
| 401 with no ticket ever requested | client config | The client never attempted Negotiate. See step 8. |
| `ldap_sasl_interactive_bind_s: Local error (-2)` | LDAP bind | No usable credentials cache for the GSSAPI bind. See step 11. |
| `Insufficient access` from LDAP | directory ACI | The bind worked but the account may not read that attribute. |

If the principal in a "not found in Kerberos database" message contains an **IP
address**, the client built it from the URL and no hostname was involved. Fix
the URL first. Kerberos names services by hostname only and there is no service
principal for an address. The port is never part of the name.

### The single most useful debugging switch

`KRB5_TRACE` prints every step the Kerberos library takes, including the exact
principal it asks for and where it gives up.

```bash
KRB5_TRACE=/dev/stderr curl -k --negotiate -u : https://api.example.com/api/user
```

Look for the `Getting credentials` line. It names the service principal being
requested. That one line usually ends the investigation.

---

## 1. The client has a ticket

```bash
kinit jsmith
klist
```

Expect a ticket-granting ticket and nothing else yet:

```
Ticket cache: KEYRING:persistent:1000:1000
Default principal: jsmith@EXAMPLE.COM

Valid starting       Expires              Service principal
11/19/26 09:14:02    11/20/26 09:13:58    krbtgt/EXAMPLE.COM@EXAMPLE.COM
```

The default principal must carry the realm in uppercase. If `kinit` itself
fails, the problem is the user account or the KDC, not the API.

## 2. Clocks agree

Kerberos rejects anything more than five minutes out. Airgapped hosts drift,
and a FreeIPA server installed with `--no-ntp` does not fix itself.

```bash
date -u                      # run on client, API host and FreeIPA server
chronyc tracking             # if chrony is running
```

Expect the three to agree within a minute. A skew failure can masquerade as
other errors, so check it early.

## 3. DNS resolves the name, forward and reverse

Run from the **client**.

```bash
host api.example.com
host 10.0.0.5
```

Expect:

```
api.example.com has address 10.0.0.5
5.0.0.10.in-addr.arpa domain name pointer api.example.com.
```

The reverse record should name the same host you dialled. If it names something
else, for example `srv.example.com` when you asked for `api.example.com`, step 4
decides whether that matters.

If the forward lookup fails, that is the root cause of any workaround involving
an IP address. Fix the resolver or add a hosts entry:

```bash
echo "10.0.0.5  api.example.com api" | sudo tee -a /etc/hosts
```

## 4. The client is not rewriting the name

```bash
grep -E "default_realm|rdns|dns_lookup" /etc/krb5.conf
```

Expect:

```
  default_realm = EXAMPLE.COM
  dns_lookup_realm = true
  dns_lookup_kdc = true
  rdns = false
```

`rdns = false` is what `ipa-client-install` writes, and it is what you want.
With it true, the library reverse-resolves the address and uses the PTR name as
the service principal, so you end up asking for a name you never typed. Fix it
here rather than by adding extra service principals.

## 5. The service principal exists in FreeIPA

On any host with an admin ticket:

```bash
kinit admin
ipa service-show HTTP/api.example.com
```

Expect:

```
  Principal name: HTTP/api.example.com@EXAMPLE.COM
  Keytab: True
  Managed by: api.example.com
```

`Keytab: True` means a key has been issued. `False` means the principal exists
but no keytab was ever retrieved, so the API cannot decrypt anything.

`ipa: ERROR: HTTP/api.example.com: service not found` means it was never
created. Go to step 12.

**In the web UI:** Identity, then Services. One row per principal, with a
Principal name column reading `HTTP/api.example.com@EXAMPLE.COM`. Open the row
and read the Provisioning section: "Kerberos Key Present" is what you want,
"Kerberos Key Not Present" means no keytab exists yet.

## 6. The keytab on the API host holds that principal

Run on the **API host**.

```bash
sudo klist -k /etc/krb5.keytab.api
```

Expect several lines for the one principal, one per encryption type:

```
Keytab name: FILE:/etc/krb5.keytab.api
KVNO Principal
---- ---------------------------------------------------------------
   1 HTTP/api.example.com@EXAMPLE.COM
   1 HTTP/api.example.com@EXAMPLE.COM
   1 HTTP/api.example.com@EXAMPLE.COM
```

Check three things. The name must match what clients dial, character for
character. The file must be readable by the service account, mode `600` and
owned by whoever the unit runs as. The key version must match the KDC:

```bash
sudo klist -ke /etc/krb5.keytab.api      # adds encryption types
kinit admin && kvno HTTP/api.example.com # what the KDC currently holds
```

Expect the version numbers to agree:

```
HTTP/api.example.com@EXAMPLE.COM: kvno = 1
```

A mismatch is the cause of every decrypt and integrity failure. It happens when
the keytab was made before the host was enrolled, or when `ipa-getkeytab` was
run a second time somewhere else. **`ipa-getkeytab` regenerates the key by
default and invalidates every existing copy.** Use `-r` to retrieve the
existing key instead of making a new one.

## 7. The service reads that keytab

```bash
systemctl cat launcher-api | grep -i krb5
```

Expect at least:

```
Environment=KRB5_KTNAME=/etc/krb5.keytab.api
```

Then confirm the running process really has it:

```bash
sudo tr '\0' '\n' < /proc/$(pgrep -f LauncherApi | head -1)/environ | grep KRB5
```

A unit edited but not reloaded will not show it. `systemctl daemon-reload` and
restart after any change.

## 8. A real request succeeds

```bash
kdestroy && kinit jsmith
curl -k --negotiate -u : https://api.example.com/api/user
klist
```

The proof of success is a second line in the ticket cache:

```
Valid starting       Expires              Service principal
11/19/26 09:14:02    11/20/26 09:13:58    krbtgt/EXAMPLE.COM@EXAMPLE.COM
11/19/26 09:14:05    11/20/26 09:13:58    HTTP/api.example.com@EXAMPLE.COM
```

If that second line never appears, no service ticket was ever issued and the
fault is in steps 3 to 5, not in the API.

A 401 where the client never even asks the KDC means the client declined to
attempt Negotiate. For `curl` check that `--negotiate -u :` is present. For
Chromium or Electron the URL host must match the allowlist, which an IP address
will not do:

```
--auth-server-whitelist=*.example.com
--auth-negotiate-delegate-whitelist=*.example.com
```

Server-side, turn the handler's own logging up to see the decision:

```jsonc
"Logging": { "LogLevel": { "Microsoft.AspNetCore.Authentication": "Debug" } }
```

```bash
journalctl -u launcher-api -f
```

## 9. The API logs a generic authentication error

This is the next failure after the ticket starts arriving. The client gets a
service ticket, the server receives it, and the server cannot decrypt it. The
handler logs an outer message like "An exception occurred while processing the
authentication request" which says nothing on its own. **The answer is the
GSSAPI minor code underneath it, in parentheses.**

Get the full exception:

```jsonc
"Logging": { "LogLevel": { "Microsoft.AspNetCore.Authentication": "Debug" } }
```

Then add a Kerberos trace to the service, which prints which keytab entry it
looked for and why it rejected the ticket:

```bash
sudo mkdir -p /etc/systemd/system/launcher-api.service.d
sudo tee /etc/systemd/system/launcher-api.service.d/trace.conf <<'EOF'
[Service]
Environment=KRB5_TRACE=/dev/stderr
EOF
sudo systemctl daemon-reload && sudo systemctl restart launcher-api
journalctl -u launcher-api -f
```

Minor codes and what each means:

| Minor code | Cause |
| --- | --- |
| `Key table entry not found`, `Request ticket server HTTP/... kvno N not found in keytab` | The keytab has no entry for that principal at that key version |
| `Decrypt integrity check failed` | Right principal, wrong key. The keytab is stale. |
| `Keytab FILE:/... is nonexistent or empty` | Wrong path, or the service account cannot read it |
| `No key table entry found matching HTTP/...` | Principal name mismatch, including letter case |
| `Encryption type ... not permitted`, `KDC has no support for encryption type` | The ticket's encryption type is not in the keytab |
| `Clock skew too great` | More than five minutes of drift. See step 2. |

Remove the trace drop-in once you are done.

### The decisive test

`kvno -k` fetches a real service ticket and then decrypts it with the keytab,
which is exactly what the server does. It settles whether the fault is the
keytab or the application in one command:

```bash
sudo -i
kinit admin                                              # any user will do
kvno -k /etc/krb5.keytab.api HTTP/api.example.com
```

Success looks like:

```
HTTP/api.example.com@EXAMPLE.COM: kvno = 1, keytab entry valid
```

- **It succeeds.** The keytab is fine and can decrypt tickets for that service.
  The fault is in the application: the path it reads, the user it runs as, or
  the environment it was given. Go to the two checks below.
- **It fails.** The keytab is the problem. Go to "Replacing a stale keytab".

A second, narrower test asks whether the keytab's key still matches the KDC:

```bash
sudo kinit -k -t /etc/krb5.keytab.api HTTP/api.example.com && sudo klist
```

`Preauthentication failed` or `Password incorrect while getting initial
credentials` means the key in the file is no longer the key the KDC holds.

### If the keytab is good but the API still fails

Check which account the service runs as, and that it can read the file:

```bash
systemctl show -p User -p Group launcher-api
sudo -u launcher-api klist -k /etc/krb5.keytab.api
```

A keytab at mode `600` owned by root is unreadable by any other account, and
GSSAPI reports that as the keytab being nonexistent or empty. Either run the
service as root or give the account ownership:

```bash
sudo chown launcher-api /etc/krb5.keytab.api
sudo chmod 600 /etc/krb5.keytab.api
```

Then confirm the running process actually has the variable, because a unit file
edited without a reload does not:

```bash
sudo tr '\0' '\n' < /proc/$(pgrep -f LauncherApi | head -1)/environ | grep KRB5
```

### Encryption types

Compare what the ticket uses against what the keytab holds. On the client,
after a request:

```bash
klist -e
```

```
Etype (skey, tkt): aes256-cts-hmac-sha1-96, aes256-cts-hmac-sha1-96
```

On the API host:

```bash
sudo klist -ke /etc/krb5.keytab.api
```

The ticket's type must appear in the keytab. A keytab generated with a narrower
set of types than the KDC issues produces a key-not-found failure even though
the principal and version look right.

### Kerberos or NTLM?

.NET on Linux accepts Kerberos but not NTLM, and an NTLM token produces a
generic failure. Look at the token the client sent. Log it in nginx:

```
log_format spnego '$remote_addr "$request" auth="$http_authorization"';
```

A base64 token starting `YII` is Kerberos. One starting `TlRMTVNTUA`, which
decodes to `NTLMSSP`, is NTLM, and that will never work here. Clients fall back
to NTLM when they cannot get a service ticket, so fix the ticket path rather
than the server.

### Replacing a stale keytab

A keytab goes stale when the host is re-enrolled, or when `ipa-getkeytab` is
run again anywhere else, because **by default it generates a new key and
invalidates every existing copy**. Retrieve the current key instead of making a
new one:

```bash
kinit admin
ipa-getkeytab -r -p HTTP/api.example.com -k /etc/krb5.keytab.api
sudo klist -ke /etc/krb5.keytab.api
kvno HTTP/api.example.com          # version should now match the file
```

`-r` needs the retrieve-keytab permission, which FreeIPA grants with:

```bash
ipa service-allow-retrieve-keytab HTTP/api.example.com --hosts=api.example.com
```

Without `-r` the command mints a new key, which is fine when only one keytab
exists, and breaks every other copy when more than one does.

---

## 10. TLS is not the thing failing

An IP address in the URL also fails certificate validation, which can look like
an auth problem.

```bash
openssl s_client -connect api.example.com:443 </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates
```

Expect the subject to carry the name you dialled. The examples here use
`curl -k` because a self-signed certificate is normal in a lab.

---

## 11. The group lookup over LDAP

Authentication and group lookup fail independently. Once step 8 passes, test
the directory read separately. This is the part the API does to decide what a
caller may do.

First, can the service obtain its own ticket and bind?

```bash
sudo kinit -k -t /etc/krb5.keytab.api HTTP/api.example.com
sudo klist
ldapwhoami -Y GSSAPI -H ldaps://ipa.example.com
```

Expect `ldapwhoami` to report who you bound as:

```
SASL/GSSAPI authentication started
SASL username: HTTP/api.example.com@EXAMPLE.COM
dn: krbprincipalname=http/api.example.com@example.com,cn=services,cn=accounts,dc=example,dc=com
```

`Local error (-2)` here means there is no usable credentials cache. `Can't
contact LDAP server` means TLS or the port, not Kerberos. For TLS, the FreeIPA
CA must be trusted:

```bash
ls -l /etc/ipa/ca.crt
sudo cp /etc/ipa/ca.crt /etc/pki/ca-trust/source/anchors/ipa-ca.crt
sudo update-ca-trust extract
grep TLS_CACERT /etc/openldap/ldap.conf
```

Then read the membership the API will read:

```bash
ldapsearch -Y GSSAPI -H ldaps://ipa.example.com \
  -b "cn=users,cn=accounts,dc=example,dc=com" \
  "(&(objectClass=posixaccount)(uid=jsmith))" memberOf
```

Expect one `memberOf` line per group, already including nested groups because
FreeIPA expands them for you:

```
dn: uid=jsmith,cn=users,cn=accounts,dc=example,dc=com
memberOf: cn=launcher-users,cn=groups,cn=accounts,dc=example,dc=com
memberOf: cn=launcher-vm-users,cn=groups,cn=accounts,dc=example,dc=com
```

No `memberOf` lines at all, with the entry returned, means the bound account
cannot read the attribute. No entry at all means the uid does not match, so
check the exact login under Identity then Users.

If that search works and the API still grants nothing, the fault is in the
application's own configuration: the LDAP URI, the realm, or the group names in
the policy section not matching the group names above.

**In the web UI:** Identity, then Users, open the user, then the User Groups
tab. Toggle Direct and Indirect membership. The code sees both.

### Which credentials the service uses for the bind

```bash
systemctl cat launcher-api | grep -i krb5
```

For a GSSAPI bind the service needs a client identity of its own:

```
Environment=KRB5_KTNAME=/etc/krb5.keytab.api
Environment=KRB5_CLIENT_KTNAME=/etc/krb5.keytab.api
Environment=KRB5CCNAME=FILE:/run/launcher-api/krb5cc
RuntimeDirectory=launcher-api
```

`KRB5_KTNAME` is for decrypting inbound tickets. `KRB5_CLIENT_KTNAME` is for
the outbound bind, and MIT Kerberos obtains and renews a ticket from it on
demand, so no cron job is needed. On an enrolled host you can point the client
keytab at `/etc/krb5.keytab` and bind as the host instead.

### The native LDAP library

A .NET service using `System.DirectoryServices.Protocols` calls into OpenLDAP.
Without it you get a `DllNotFoundException` on the first lookup.

```bash
rpm -q openldap-clients            # RHEL, Fedora, Oracle Linux
dpkg -l | grep libldap             # Debian, Ubuntu
```

---

## 12. Is the host joined, and does it need to be?

```bash
ls -l /etc/ipa/default.conf          # exists only after enrolment
sudo klist -k /etc/krb5.keytab       # expect host/api.example.com@EXAMPLE.COM
systemctl status sssd
sssctl domain-list                   # if sssd-tools is installed
```

No `/etc/ipa/default.conf` and no host principal means the machine was never
enrolled. In the web UI, Identity then Hosts: an entry can exist without the
machine being enrolled, because `ipa host-add` pre-creates one. Open the host
and read the Provisioning section, the same way as for a service.

Enrolment is convenient but **not required** for SPNEGO. The API needs only a
service principal, a keytab for it, and a `krb5.conf` naming the realm. Create
the first two on the FreeIPA server and move the keytab across, which suits an
airgapped host:

```bash
# on the FreeIPA server
kinit admin
ipa host-add api.example.com --force --no-reverse    # only if absent
ipa service-add HTTP/api.example.com
ipa-getkeytab -p HTTP/api.example.com -k /tmp/api.keytab
# copy to the API host
sudo install -m 600 -o root -g root /tmp/api.keytab /etc/krb5.keytab.api
sudo klist -k /etc/krb5.keytab.api
```

Minimal `/etc/krb5.conf` on the API host if it is not enrolled:

```
[libdefaults]
  default_realm = EXAMPLE.COM
  dns_lookup_realm = true
  dns_lookup_kdc = true
  rdns = false

[realms]
  EXAMPLE.COM = {
    kdc = ipa.example.com
    admin_server = ipa.example.com
  }

[domain_realm]
  .example.com = EXAMPLE.COM
  example.com = EXAMPLE.COM
```

If you do enrol, generate the keytab **after** `ipa-client-install`. Enrolment
rotates the host keys and bumps the version, leaving any earlier keytab unable
to decrypt anything.

---

## What actually expires, and what renews itself

Worth being precise about, because "the keytab expired" sends you looking in
the wrong place.

### Keytabs do not expire

A keytab holds the long-term symmetric keys for a principal. There is no
validity period on the file or on the keys in it, and nothing renews them
because there is nothing to renew. `klist -k` prints KVNO and Principal, and
with `-t` a Timestamp, which is when the entry was written into the file.

**A keytab listing has no Expires column at all.** If you are reading one, you
are looking at a credentials cache rather than the keytab:

```bash
sudo klist -kt /etc/krb5.keytab.api   # keytab: KVNO, Timestamp, Principal
sudo klist                            # cache:  Valid starting, Expires, Service principal
```

A keytab stops working only when the key is **changed in the KDC**, which makes
the copy on disk wrong rather than out of date. Things that change it:

- `ipa-client-install`, including a re-enrolment, which rotates the host key
- `ipa-getkeytab` without `-r`, anywhere, which mints a new key and invalidates
  every existing copy
- `ipa service-disable` then enable, or an admin resetting the key

FreeIPA does **not** rotate host or service keys on a schedule. Active
Directory does rotate computer account passwords by default, which is where the
expectation usually comes from. On FreeIPA a keytab that worked yesterday and
fails today means something changed the key, so find out what.

```bash
# when the key was last changed in the directory
kinit admin
ipa service-show HTTP/api.example.com --all | grep -i -E "krblastpwdchange|krbprincipalexpiration"

# when the keytab entry was written
sudo klist -kt /etc/krb5.keytab.api
```

If the directory's last-change timestamp is **newer** than the keytab's, that is
your answer, and the fix is to retrieve the current key with
`ipa-getkeytab -r`.

### Tickets expire, and they live somewhere else

Tickets are in a credentials cache, not a keytab. The realm's policy sets the
lifetimes:

```bash
ipa krbtpolicy-show
```

This matters for exactly one half of the system:

- **Inbound authentication never touches a ticket cache.** GSSAPI reads the
  keytab on each request to decrypt what the client sent. Inbound auth cannot
  fail because something expired. If it worked and then stopped, the key
  changed.
- **The outbound LDAP bind does use a cache**, so it is the only place where
  expiry bites.

### The outbound bind renews itself if you set it up to

```
Environment=KRB5_CLIENT_KTNAME=/etc/krb5.keytab.api
Environment=KRB5CCNAME=FILE:/run/launcher-api/krb5cc
RuntimeDirectory=launcher-api
```

With a client keytab configured, MIT Kerberos acquires a ticket when the cache
is empty or expired and re-acquires it later on its own. No cron job, no
renewal daemon, nothing to keep alive.

#### A client keytab alone is not enough: give the service its own cache

Step-by-step version of this fix, with the checks and the rollback:
[FIX-SERVICE-TICKET-REFRESH.md](FIX-SERVICE-TICKET-REFRESH.md).


`KRB5_CLIENT_KTNAME` is the mechanism that acquires credentials.
`KRB5CCNAME` only says where the cache lives, and leaving it out is how this
breaks.

With no cache path of its own, the service falls back to `default_ccache_name`
from `/etc/krb5.conf`, which resolves per user. A service running as root then
shares root's cache with every `sudo kinit` an administrator has ever run. The
client keytab fills a cache that is empty and refreshes credentials for the
principal it holds, but it will **not** discard credentials belonging to a
different principal. So a leftover expired `admin@EXAMPLE.COM` ticket in root's
cache stops the service acquiring its own, and every lookup fails with a ticket
expired error even though the keytab is perfectly good.

The symptom is that lookups work while an administrator is logged in and break
roughly a day later, which reads as though the service needs a human to keep
refreshing a ticket.

Confirm it without restarting anything:

```bash
sudo klist          # shows admin@EXAMPLE.COM, expired?
sudo kdestroy       # then exercise the API again
```

Working immediately after `kdestroy` proves the stale cache was the blocker.
Fix it permanently with a drop-in, so the service has a private cache that is
cleared on every restart:

```bash
sudo mkdir -p /etc/systemd/system/launcher-api.service.d
sudo tee /etc/systemd/system/launcher-api.service.d/kerberos.conf <<'EOF'
[Service]
Environment=KRB5_CLIENT_KTNAME=/etc/krb5.keytab.api
Environment=KRB5CCNAME=FILE:/run/launcher-api/krb5cc
RuntimeDirectory=launcher-api
EOF
sudo systemctl daemon-reload && sudo systemctl restart launcher-api
```

The same mix-up has a security side. Borrowing an administrator's cache means
the service was binding to the directory as a full directory admin, which is
far more access than reading `memberOf` needs.

What does **not** renew is a one-off `kinit -k` at startup. That ticket dies
when its lifetime runs out and nothing replaces it, so group lookups start
failing roughly a day after a restart while inbound authentication keeps
working. If you see that asymmetry, this is why. Check what the running process
has:

```bash
sudo tr '\0' '\n' < /proc/$(pgrep -f LauncherApi | head -1)/environ | grep KRB5
sudo KRB5CCNAME=FILE:/run/launcher-api/krb5cc klist
```

### Certificates are the thing that auto-renews

Certmonger tracks and renews certificates, not keytabs. People conflate the
two because certmonger is the FreeIPA component that does renew things on a
schedule.

```bash
sudo getcert list | grep -E "status|expires|certificate:"
```

A self-signed certificate generated by a setup script is not tracked by
certmonger and will simply expire, typically after a year. That breaks TLS, not
Kerberos, and shows up as a certificate error rather than an authentication
one.

---

## Groups the application expects

The policy section maps action names you invent to real FreeIPA group names.
Only the group names have to exist in the directory:

```bash
kinit admin
ipa group-show launcher-vm-users
ipa group-add-member launcher-vm-users --users=jsmith
```

Nesting needs no application support, because FreeIPA keeps `memberOf`
expanded:

```bash
ipa group-add-member launcher-users --groups=launcher-vm-users
```

**In the web UI:** Identity, then Groups, User Groups. The Group name column is
the exact string to use in configuration. Do not use the description.

Group membership is cached by the application, five minutes by default, so a
change takes that long to show up. Restart the service to apply it at once.

---

## One-shot check

```bash
#!/bin/bash
# Substitute the four values, run on the API host.
API=api.example.com; IPA=ipa.example.com
REALM=EXAMPLE.COM;   BASE="cn=users,cn=accounts,dc=example,dc=com"

echo "== time =="        ; date -u
echo "== dns =="         ; host "$API"; host "$(dig +short "$API" | head -1)"
echo "== krb5.conf =="   ; grep -E "default_realm|rdns" /etc/krb5.conf
echo "== keytab =="      ; sudo klist -k /etc/krb5.keytab.api
echo "== kdc kvno =="    ; kvno "HTTP/$API" 2>&1 | tail -1
echo "== can decrypt ==" ; kvno -k /etc/krb5.keytab.api "HTTP/$API" 2>&1 | tail -1
echo "== service env ==" ; systemctl cat launcher-api 2>/dev/null | grep -i krb5
echo "== ldap bind =="   ; sudo kinit -k -t /etc/krb5.keytab.api "HTTP/$API" \
                             && ldapwhoami -Y GSSAPI -H "ldaps://$IPA" 2>&1 | tail -2
echo "== memberOf =="    ; ldapsearch -Y GSSAPI -H "ldaps://$IPA" -b "$BASE" \
                             "(uid=jsmith)" memberOf 2>&1 | grep -i "^memberOf" \
                             || echo "none returned"
```

Every section should print something recognisable from the steps above. The
first one that does not is where to start.
