# Launcher Apps — Architecture & Design Documentation

## Overview

This project provides a **zero-login authenticated desktop launcher** for cybersecurity tools. An Electron application running on a domain-joined workstation authenticates to a .NET Core API using **Kerberos SPNEGO** (Simple and Protected GSSAPI Negotiation Mechanism) — meaning users never enter a password into the application. Their domain login is the authentication.

### Diagrams

- [Network Architecture](diagrams/network-architecture.excalidraw) — VM layout, services, networking
- [Kerberos Auth Flow](diagrams/kerberos-auth-flow.excalidraw) — Step-by-step SPNEGO sequence
- [Deployment Flow](diagrams/deployment-flow.excalidraw) — Terraform provisioning pipeline

---

## Why This Architecture?

### The Problem

Enterprise environments need authenticated access to tools without:
- Users managing separate credentials for each application
- Passwords stored in config files or environment variables
- Token management burden on the application developer
- Any opportunity for credential interception on the wire

### The Solution: Kerberos + SPNEGO

Kerberos provides **mutual authentication** — the client proves its identity to the server AND the server proves its identity to the client. SPNEGO wraps Kerberos tickets in HTTP headers, making it work transparently with web APIs.

**Why not OAuth/OIDC?** OAuth requires a browser redirect flow, token storage, and refresh management. Kerberos/SPNEGO is invisible — the OS ticket cache handles everything. For desktop apps in a domain environment, it's strictly simpler and more secure.

**Why not mTLS?** Client certificates require PKI management and distribution. Kerberos tickets are time-limited (typically 24h) and automatically renewed. Less operational overhead.

---

## The Three VMs

### 1. Identity Server (`idm.lab.forge.local` / 10.0.1.10)

The identity server is the **trust anchor** for the entire environment. It runs:

**FreeIPA** — An integrated identity management solution providing:
- **Kerberos KDC** (Key Distribution Center) — Issues and validates tickets
- **389 Directory Server** (LDAP) — User and group store
- **BIND DNS** — Authoritative DNS for `lab.forge.local` zone
- **Dogtag CA** — Certificate authority (PKI)

**Keycloak** (Docker) — OpenID Connect / SAML identity provider. Federates to FreeIPA's LDAP for user data. Included for future web-based auth flows but not used by the Electron launcher (which uses Kerberos directly).

**Why FreeIPA over standalone Kerberos?** FreeIPA bundles KDC + LDAP + DNS + CA into a single managed stack. Standalone MIT Kerberos requires manual LDAP integration, separate DNS management, and manual principal database administration. FreeIPA gives us `ipa` CLI commands that handle the complexity.

### 2. API Server (`api.lab.forge.local` / 10.0.1.11)

The API server hosts the .NET Core 8 application behind an Nginx reverse proxy:

**Nginx** handles:
- TLS termination (self-signed cert for dev, CA-signed for prod)
- Passing the `Authorization: Negotiate` header to Kestrel
- Large buffer sizes (128KB+) for Kerberos tokens (they grow with group memberships)

**ASP.NET Core** with `Microsoft.AspNetCore.Authentication.Negotiate`:
- Validates SPNEGO tokens using a **keytab file** — a file containing the service's Kerberos key
- Extracts the authenticated user principal (e.g., `testuser@LAB.FORGE.LOCAL`)
- Makes identity available via standard `HttpContext.User` claims

**Why .NET Core for the API?** The `Negotiate` auth middleware is mature and well-tested. It handles the full SPNEGO handshake including mutual auth. The keytab-based validation means no network call to the KDC at request time — validation is purely cryptographic.

### 3. Workstation (`ws1.lab.forge.local` / 10.0.1.12)

The domain-joined workstation runs the Electron launcher:

**Domain membership** via `ipa-client-install`:
- SSSD provides PAM/NSS integration — FreeIPA users can log in
- Kerberos configuration (`/etc/krb5.conf`) points at the FreeIPA KDC
- `kinit` works immediately after login

**Electron with Chromium flags**:
```
--auth-server-whitelist=*.lab.forge.local
--auth-negotiate-delegate-whitelist=*.lab.forge.local
```
These tell Chromium to automatically use Kerberos tickets for any request to `*.lab.forge.local`. No application code handles authentication.

---

## How Kerberos SPNEGO Works (In This System)

This is the core flow — understanding it is essential for debugging auth issues.

### Prerequisites (happen at deployment time)
1. FreeIPA KDC has a service principal: `HTTP/api.lab.forge.local@LAB.FORGE.LOCAL`
2. API server has a **keytab** file containing the service's encryption key
3. Workstation is domain-joined and can reach the KDC
4. User has run `kinit` (or logged in via SSSD/GDM which does it automatically)

### The Authentication Flow

```
User (ws1)              Electron/Chromium           FreeIPA KDC              API Server
   |                         |                          |                        |
   | 1. kinit testuser       |                          |                        |
   |------------------------>|                          |                        |
   |                         |--- AS-REQ (password) --->|                        |
   |                         |<-- AS-REP (TGT) --------|                        |
   |                         |  [TGT stored in cache]   |                        |
   |                         |                          |                        |
   | 2. Click "View Tools"   |                          |                        |
   |------------------------>|                          |                        |
   |                         |--- GET /api/tools ------>|                        |
   |                         |<-- 401 + WWW-Authenticate: Negotiate ------------|
   |                         |                          |                        |
   |                         | 3. Chromium sees 401 + Negotiate                  |
   |                         |    URL matches --auth-server-whitelist            |
   |                         |--- TGS-REQ (need HTTP/api.lab.forge.local) ----->|
   |                         |<-- TGS-REP (service ticket) --------------------|
   |                         |                          |                        |
   |                         | 4. Wraps ticket in SPNEGO token                   |
   |                         |--- GET /api/tools + Authorization: Negotiate YIIG..-->|
   |                         |                          |    5. Decrypt with     |
   |                         |                          |       keytab (KVNO     |
   |                         |                          |       must match!)     |
   |                         |<-- 200 OK + tools JSON --|                        |
   | 6. Display tools        |                          |                        |
   |<------------------------|                          |                        |
```

### Key Concepts

**TGT (Ticket-Granting Ticket)**: Obtained via `kinit`. Proves "I am testuser" to the KDC. Stored in `/tmp/krb5cc_<uid>`. Typically valid for 24 hours.

**Service Ticket**: Obtained automatically by Chromium when it needs to authenticate. Proves "I am testuser" to a specific service (`HTTP/api.lab.forge.local`). The KDC encrypts it with the service's key.

**Keytab**: A file containing the service's Kerberos key. The API server uses it to decrypt service tickets without contacting the KDC. **The KVNO (Key Version Number) in the keytab must match the KDC's record** — this is the #1 cause of auth failures.

**SPNEGO**: The negotiation protocol that wraps Kerberos tokens in HTTP headers. The `WWW-Authenticate: Negotiate` challenge triggers Chromium to acquire a service ticket and send it back as `Authorization: Negotiate <base64-token>`.

---

## The Keytab KVNO Problem (And How We Solved It)

This is the most subtle deployment issue. Understanding it prevents hours of debugging.

### The Problem

Every time a Kerberos principal's key changes, the **Key Version Number (KVNO)** increments. A keytab file embeds the KVNO at generation time. If the KDC's KVNO for a principal doesn't match the keytab's KVNO, decryption fails silently — you get `GenericFailure` in the .NET logs with no useful details.

### How It Happens

1. Identity server creates SPN `HTTP/api.lab.forge.local` and generates keytab (KVNO=1)
2. API server runs `ipa-client-install` — this **re-enrolls the host**, which changes the host's keys, bumping KVNO for associated principals
3. Now the keytab has KVNO=1 but the KDC has KVNO=2+
4. Every Negotiate request fails

### Our Solution

The API server generates its **own keytab after domain enrollment**:

```bash
# Step 3: Domain join (this changes KVNOs)
ipa-client-install --unattended ...

# Step 4: Generate keytab AFTER join (gets current KVNO)
kinit admin
ipa-getkeytab -s idm.lab.forge.local -p HTTP/api.lab.forge.local -k /etc/krb5.keytab.api
```

The identity server still creates the service principal, but it does NOT generate the keytab. The API server fetches its own keytab with the current KVNO.

---

## Deployment Architecture

### Source Code Upload

The source repository is not necessarily available on GitHub (or the VMs might not have GitHub access). Instead of `git clone`, Terraform:

1. Creates tarballs locally: `tar czf /tmp/launcher-api-src.tar.gz api/`
2. Uploads them via SSH file provisioner
3. Scripts extract on the target VM

### Credential Handling

Terraform suppresses ALL remote-exec output when sensitive variables appear in the command line. To preserve visibility into provisioning progress:

1. Credentials are written to a `.setup-creds` file via Terraform's `content` file provisioner
2. Scripts `source` the file to load credentials as environment variables
3. The file is deleted at the end of each script

### Provisioning Order

```
terraform apply
     |
     v
[Create all Azure resources]  (~5 min)
     |
     v
[Identity Server provisioning]  (~20 min)
  - FreeIPA install is the bottleneck
  - DNS, SPN, users, Docker, Keycloak
     |
     +---> [API Server]  (~10 min)        [Workstation]  (~15 min)
     |     - Domain join                   - Domain join
     |     - Keytab (after join!)          - Node.js + pnpm
     |     - .NET build + deploy           - Electron deps + build
     |     - Nginx + TLS                   - API config
     |
     v
[All done - environment ready]  (~30 min total)
```

API and workstation provision **in parallel** after identity completes, since both need FreeIPA available for domain join.

---

## API Endpoints

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| `GET` | `/api/health` | Anonymous | Health check — returns 200 if API is running |
| `GET` | `/api/user` | Negotiate | Returns authenticated user's Kerberos principal and claims |
| `GET` | `/api/tools` | Negotiate | Lists available cybersecurity tools |
| `POST` | `/api/tools/{id}/launch` | Negotiate | Audit log entry for tool launch |
| `GET` | `/api/session` | Negotiate | Server environment information |

All endpoints except `/api/health` require Kerberos authentication (enforced via `FallbackPolicy = DefaultPolicy`).

---

## Electron Integration

### How `net.request()` Does Kerberos

Electron's `net` module uses Chromium's network stack, which has native SPNEGO support. When:

1. A response comes back with `WWW-Authenticate: Negotiate`
2. The request URL matches `--auth-server-whitelist`
3. A valid TGT exists in the system ticket cache

...Chromium automatically handles the TGS exchange and sends the SPNEGO token. **No application code is involved in authentication.**

### IPC Architecture

```
Renderer Process                    Main Process                     API Server
(React UI)                         (Node.js)                        (.NET Core)
     |                                  |                                |
     |-- ipcRenderer.invoke('api:user') |                                |
     |--------------------------------->|                                |
     |                                  |-- net.request(GET /api/user) ->|
     |                                  |   [Chromium adds Negotiate]    |
     |                                  |<- 200 + user JSON ------------|
     |<- { name, isAuthenticated } -----|                                |
     |                                  |                                |
```

The `apiIPC.ts` module registers 6 IPC handlers that bridge the renderer's React hooks to the main process's `net.request()` calls.

---

## DNS Architecture

FreeIPA runs an authoritative BIND DNS server for `lab.forge.local`:

| Record | Type | Value |
|--------|------|-------|
| `idm.lab.forge.local` | A | 10.0.1.10 |
| `api.lab.forge.local` | A | 10.0.1.11 |
| `ws1.lab.forge.local` | A | 10.0.1.12 |
| `10.1.0.10.in-addr.arpa` | PTR | `idm.lab.forge.local` |
| `11.1.0.10.in-addr.arpa` | PTR | `api.lab.forge.local` |
| `12.1.0.10.in-addr.arpa` | PTR | `ws1.lab.forge.local` |

All VMs use FreeIPA as their primary DNS with Azure DNS (168.63.129.16) as a forwarder for external resolution. FreeIPA is configured with Azure DNS as a global forwarder via `ipa dnsconfig-mod`.

**Why FreeIPA DNS matters for Kerberos**: Kerberos relies on forward AND reverse DNS. If `api.lab.forge.local` doesn't resolve, or if the reverse lookup of 10.0.1.11 doesn't return `api.lab.forge.local`, the service ticket request may target the wrong principal name and authentication fails.

---

## Security Considerations

### What's Secure

- **No passwords on the wire** after initial `kinit` — all subsequent auth uses encrypted Kerberos tickets
- **Mutual authentication** — the service proves its identity to the client via the SPNEGO response
- **Time-limited tickets** — TGTs expire (default 24h), service tickets expire (default 10h)
- **Keytab file permissions** — 600, readable only by the service account

### What's Dev-Only (Fix for Production)

1. **Self-signed TLS cert** — Replace with CA-signed cert (FreeIPA's Dogtag CA can issue them)
2. **NSG allows SSH from anywhere** — Restrict `source_address_prefix` to your IP
3. **Keycloak admin password is `admin`** — Change it
4. **FreeIPA admin password in terraform.tfvars** — Use a secrets manager or env var
5. **`NODE_TLS_REJECT_UNAUTHORIZED=0`** may be needed for self-signed certs — Remove with proper CA

---

## Troubleshooting

### "GenericFailure" on Negotiate Auth

**KVNO mismatch.** Verify with:
```bash
# On API server — check keytab KVNO
klist -k /etc/krb5.keytab.api

# On identity server — check KDC's KVNO
kadmin.local -q "getprinc HTTP/api.lab.forge.local" | grep "Key:"
```
If they don't match, regenerate the keytab on the API server after domain join.

### 502 Bad Gateway from Nginx

**Buffer too small for Kerberos token.** Check nginx error log:
```bash
tail /var/log/nginx/error.log
```
Increase `proxy_buffer_size` and `proxy_buffers` in nginx config. Users with many group memberships produce larger tokens.

### `kinit: Password incorrect` for Test Users

**Password flagged for mandatory change.** The setup script uses `ldappasswd` via Directory Manager to set permanent passwords, but if this step failed, the user has a temporary password. Fix with:
```bash
# On identity server
ldappasswd -x -D "cn=Directory Manager" -w <ds_password> \
  -s <new_password> \
  "uid=testuser,cn=users,cn=accounts,dc=lab,dc=forge,dc=local"
```

### DNS Resolution Fails After FreeIPA Install

**Missing forwarder.** FreeIPA becomes the DNS server but can't resolve external names without a forwarder:
```bash
kinit admin
ipa dnsconfig-mod --forwarder=168.63.129.16
```
Also verify `/etc/resolv.conf` has a fallback nameserver.

### Electron Doesn't Send Negotiate Token

Verify Chromium flags are set:
```bash
# In main.ts, before app.on('ready'):
app.commandLine.appendSwitch('auth-server-whitelist', '*.lab.forge.local');
app.commandLine.appendSwitch('auth-negotiate-delegate-whitelist', '*.lab.forge.local');
```
And verify the user has a valid TGT: `klist` should show a ticket for `krbtgt/LAB.FORGE.LOCAL@LAB.FORGE.LOCAL`.
