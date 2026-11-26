# Fix: the API's Kerberos ticket expires and is never replaced

**Symptom.** The service acquires a ticket once, that ticket expires, and every
LDAP group lookup then fails with a ticket expired error. `KRB5_CLIENT_KTNAME`
is set, the clock is correct, and the keytab is good.

**Cause.** Refreshing a ticket means *writing* a new one into the credentials
cache. `KRB5_CLIENT_KTNAME` says where to get credentials from;
**`KRB5CCNAME` says where to put them**. With no cache path of its own the
service falls back to `default_ccache_name` from `/etc/krb5.conf`, which on a
FreeIPA-enrolled host is normally a kernel keyring. A systemd service cannot
reliably rewrite that, so the expired ticket stays and GSSAPI keeps presenting
it.

Substitute `api.example.com`, `EXAMPLE.COM` and `launcher-api` for your own
names throughout.

> **If `kinit -k -t` fails with "Preauthentication failed", stop and go to
> [the keytab is stale](#the-keytab-is-stale). That is a different root cause,
> and it also explains generic GSSAPI failures on inbound requests, because the
> same keytab serves both directions.**

---

## Step 1: find the cache you are using now

```bash
# what the running process was actually given
sudo tr '\0' '\n' < /proc/$(pgrep -f LauncherApi | head -1)/environ | grep -i krb5

# where credentials go when KRB5CCNAME is unset
grep -i default_ccache_name /etc/krb5.conf

# is the file path from the fix already there?
ls -l /run/launcher-api/krb5cc 2>/dev/null || echo "not present"

# every cache belonging to this user, and what is in them
sudo klist -l
sudo klist -A
```

How to read it:

| What you see | Meaning |
| --- | --- |
| `KRB5_CLIENT_KTNAME` present, `KRB5CCNAME` absent | This is the fault. Go to step 2. |
| `/run/launcher-api/krb5cc` not present | Expected. Nothing creates that path until the fix is applied. |
| `default_ccache_name = KEYRING:...` or `KCM:...` | Not a file, so `ls` will never find it. This is the cache that cannot be rewritten. |
| `klist -A` shows the service principal with a past Expires | Confirms the stale ticket is sitting in that cache. |

---

## Step 2: apply the fix

```bash
sudo mkdir -p /etc/systemd/system/launcher-api.service.d

sudo tee /etc/systemd/system/launcher-api.service.d/kerberos.conf <<'EOF'
[Service]
Environment=KRB5CCNAME=FILE:/run/launcher-api/krb5cc
RuntimeDirectory=launcher-api
EOF

sudo systemctl daemon-reload
sudo systemctl restart launcher-api
```

Two lines, two jobs. `KRB5CCNAME` gives the service a cache it owns and can
write. `RuntimeDirectory` makes systemd create `/run/launcher-api` on start and
**delete it on stop**, so a stale ticket can never outlive a restart.

If you would rather put it in the unit itself, the same two lines go in the
`[Service]` section alongside the existing `KRB5_KTNAME` line.

---

## Step 3: verify

The cache is empty immediately after a restart. It fills on the first group
lookup, so exercise one first.

```bash
# from a workstation, as an ordinary user
kinit jsmith
curl -k --negotiate -u : https://api.example.com/api/user/groups
```

Then on the API host:

```bash
ls -l /run/launcher-api/
date
sudo KRB5CCNAME=FILE:/run/launcher-api/krb5cc klist
```

Correct looks like this, with the **Expires column ahead of the date above**:

```
Default principal: HTTP/api.example.com@EXAMPLE.COM

Valid starting       Expires              Service principal
11/22/26 08:02:11    11/23/26 08:02:11    krbtgt/EXAMPLE.COM@EXAMPLE.COM
11/22/26 08:02:11    11/23/26 08:02:11    ldap/ipa.example.com@EXAMPLE.COM
```

Three things to check:

1. The default principal is the **service's** own principal, not `admin` and not
   a user. If it says `admin`, the service is borrowing an administrator's cache
   and this fix has not taken effect.
2. The file `/run/launcher-api/krb5cc` now exists and is owned by whoever the
   service runs as. Check with `systemctl show -p User launcher-api`.
3. The Expires timestamp is in the future.

From here the ticket refreshes itself from the keytab for as long as the service
runs. No `kinit`, no cron job, nobody logging in.

---

## If it says "no Kerberos credentials available" and names the new cache

Good sign: the service is reading the cache you gave it. The cache is simply
empty, because nothing has put a ticket in it yet.

A plain `kinit` does **not** fill it. `kinit` writes to *your* default cache,
so `klist` will look perfectly healthy while the service still has nothing.
They are two separate files. Always name the cache explicitly:

```bash
# fill the service's cache from the keytab
sudo kinit -k -t /etc/krb5.keytab.api -c FILE:/run/launcher-api/krb5cc \
  HTTP/api.example.com

# read that cache, not yours
sudo klist -c FILE:/run/launcher-api/krb5cc
```

Now exercise a group lookup. If it works, everything is correct except that
nothing seeds the cache at startup, which is the next block.

### Seed the cache on every start

`ExecStartPre` runs after systemd has created `RuntimeDirectory` and before the
app starts, so the cache is always populated by the time the first request
arrives:

```bash
sudo tee /etc/systemd/system/launcher-api.service.d/kerberos.conf <<'EOF'
[Service]
Environment=KRB5CCNAME=FILE:/run/launcher-api/krb5cc
Environment=KRB5_CLIENT_KTNAME=/etc/krb5.keytab.api
RuntimeDirectory=launcher-api
ExecStartPre=/usr/bin/kinit -k -t /etc/krb5.keytab.api -c FILE:/run/launcher-api/krb5cc HTTP/api.example.com
EOF

sudo systemctl daemon-reload
sudo systemctl restart launcher-api
sudo klist -c FILE:/run/launcher-api/krb5cc
```

That is the deterministic version: `ExecStartPre` guarantees credentials exist
from the first second, and `KRB5_CLIENT_KTNAME` refreshes them from the same
keytab as they age, because the principal in the cache now matches the keytab.

If the service fails to start after this, `ExecStartPre` is the thing that
failed, and the reason is in the log:

```bash
journalctl -u launcher-api -n 30
```

A preauthentication failure there means the keytab key no longer matches the
KDC. Go to [the keytab is stale](#the-keytab-is-stale).

---

## The keytab is stale

```
kinit: Preauthentication failed while getting initial credentials
kinit: Password incorrect while getting initial credentials
```

Either message from `kinit -k -t` means the key in the keytab file is no longer
the key the KDC holds for that principal. Nothing in the application can work
around it. The keytab must be replaced.

It is not caused by the account you are logged in as. `kinit -k -t` only needs
to read the file and match its key against the KDC.

### Why a keytab goes stale

- The host was re-enrolled with `ipa-client-install`, which rotates keys
- `ipa-getkeytab` was run again, anywhere, without `-r`, which mints a new key
  and invalidates every existing copy
- The service was disabled and re-enabled, or an admin reset the key

FreeIPA does not rotate these on a schedule, so one of the above happened.

### Replace it

You need a **domain admin ticket** for this. A local account has none, and
`kinit` with no principal reuses whatever a leftover cache held, so name the
principal. Work as root throughout, because `sudo` will not carry your own
ticket cache across to root.

```bash
sudo -i
kinit admin                     # the domain admin password
klist                           # must show admin@EXAMPLE.COM
```

Then retrieve the existing key, which leaves other copies working:

```bash
ipa-getkeytab -s ipa.example.com -r \
  -p HTTP/api.example.com -k /etc/krb5.keytab.api
```

If that is refused for lack of permission, drop `-r` and generate a new key.
That is safe when this host holds the only copy, and it updates inbound and
outbound at the same time because both read this one file:

```bash
ipa-getkeytab -s ipa.example.com \
  -p HTTP/api.example.com -k /etc/krb5.keytab.api
chmod 600 /etc/krb5.keytab.api
```

### Verify before restarting anything

```bash
klist -kte /etc/krb5.keytab.api         # principal and key version in the file
kvno HTTP/api.example.com               # key version the KDC holds: must match
```

Then prove the new key works, using a scratch cache so the admin ticket is left
alone:

```bash
ktest=$(mktemp)        # -c below tells kinit to write its cache here
kinit -k -t /etc/krb5.keytab.api -c "FILE:$ktest" HTTP/api.example.com
klist -c "FILE:$ktest"
kdestroy -c "FILE:$ktest"; rm -f "$ktest"
```

`-c` is what makes this safe to run on a live host: `kinit` writes to that
scratch file instead of replacing the cache the admin or the service is using.
Nothing creates it in advance, `kinit` does.

No error and a ticket for `HTTP/api.example.com@EXAMPLE.COM` means the keytab
is good.

### Restart and check both directions

```bash
exit                            # leave the root shell
sudo systemctl restart launcher-api
sudo klist -c FILE:/run/launcher-api/krb5cc
```

Outbound is working when that cache shows the service's own principal with a
future expiry. Inbound is working when a request from a workstation succeeds:

```bash
kinit jsmith
curl -k --negotiate -u : https://api.example.com/api/user/groups
```

Both should come right together, since the stale key was breaking both.

---

## Undo

```bash
sudo rm /etc/systemd/system/launcher-api.service.d/kerberos.conf
sudo systemctl daemon-reload && sudo systemctl restart launcher-api
```

---

## Why the two variables are not interchangeable

| Variable | Job | Omit it and |
| --- | --- | --- |
| `KRB5_KTNAME` | Keytab for decrypting **inbound** tickets | Negotiate authentication fails entirely |
| `KRB5_CLIENT_KTNAME` | Keytab the service authenticates **outbound** with | No credentials are ever acquired for the LDAP bind |
| `KRB5CCNAME` | Where acquired credentials are **stored** | They go to a cache the service may not be able to rewrite, so the first ticket is never replaced |

Longer diagnostics for the surrounding layers are in
[KERBEROS-TROUBLESHOOTING.md](KERBEROS-TROUBLESHOOTING.md).
