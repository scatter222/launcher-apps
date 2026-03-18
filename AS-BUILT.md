# As-Built Documentation — Launcher Apps Authenticated Environment

## 1. Solution Overview

A three-VM environment providing authenticated access from an Electron desktop launcher to a .NET Core API, using Kerberos (SPNEGO/Negotiate) for zero-login single sign-on.

| VM | Role | OS | Private IP | Azure Size |
|----|------|----|------------|------------|
| Identity Server | FreeIPA (KDC, LDAP, DNS) + Keycloak | Oracle Linux 8 | 10.0.1.10 | Standard_D4s_v3 |
| API Server | .NET Core 8 API + Nginx (HTTPS) | Oracle Linux 8 | 10.0.1.11 | Standard_D4s_v3 |
| Workstation | Electron Launcher (domain-joined) | Oracle Linux 8 | 10.0.1.12 | Standard_D4s_v3 |

**Domain**: `lab.forge.local`
**Kerberos Realm**: `LAB.FORGE.LOCAL`

---

## 2. Network Architecture

```

```

No passwords are transmitted. The Kerberos ticket from domain login is used transparently.

---

## 4. Component Details

### 4.1 Identity Server (10.0.1.10)

**FreeIPA**
- Package: `@idm:DL1/dns` module stream
- Services: KDC (krb5kdc), LDAP (389-ds), DNS (named), HTTP (httpd)
- Admin: `admin@LAB.FORGE.LOCAL`
- Web UI: `https://idm.lab.forge.local`

**DNS Records Created**
- `idm.lab.forge.local` → 10.0.1.10
- `api.lab.forge.local` → 10.0.1.11
- `ws1.lab.forge.local` → 10.0.1.12
- Reverse PTR records in `1.0.10.in-addr.arpa`

**Service Principals**
- `HTTP/api.lab.forge.local@LAB.FORGE.LOCAL` — for API Negotiate auth

**Test Users**
- `testuser` / `launcheruser` — created with IPA admin password (must change on first login)

**Keycloak**
- Version: 22.0.2 (Docker container)
- Database: PostgreSQL 15 (Docker container, port 5433)
- Access: `https://idm.lab.forge.local:8443`
- Admin: `admin/admin`
- LDAP Federation: Configure post-deployment via admin UI
  - Provider: `ldap://idm.lab.forge.local`
  - Users DN: `cn=users,cn=accounts,dc=lab,dc=forge,dc=local`

### 4.2 API Server (10.0.1.11)

**Domain Membership**
- Joined via `ipa-client-install`
- SSSD configured for domain auth

**Keytab**
- Location: `/etc/krb5.keytab.api`
- Principal: `HTTP/api.lab.forge.local`
- Loaded via `KRB5_KTNAME` environment variable in systemd unit

**.NET Core API**
- Framework: ASP.NET Core 8.0
- Auth: `Microsoft.AspNetCore.Authentication.Negotiate`
- Published to: `/opt/launcher-api/`
- Systemd unit: `launcher-api.service`
- Kestrel listens: `http://0.0.0.0:5000`

**API Endpoints**

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| GET | `/api/health` | Anonymous | Health check |
| GET | `/api/user` | Negotiate | Authenticated user info |
| GET | `/api/tools` | Negotiate | Available tools list |
| POST | `/api/tools/{id}/launch` | Negotiate | Audit tool launch |
| GET | `/api/session` | Negotiate | Server environment info |

**Nginx Reverse Proxy**
- Listens: 443 (TLS) with self-signed certificate
- Proxies to Kestrel on port 5000
- Passes `Authorization` header for SPNEGO tokens
- Buffer sizes increased (128k+) for Negotiate token handling
- HTTP→HTTPS redirect on port 80
- SELinux: `httpd_can_network_connect = on`

**Systemd Service**: `launcher-api.service`
```
WorkingDirectory=/opt/launcher-api
ExecStart=/opt/launcher-api/LauncherApi
Environment=ASPNETCORE_URLS=http://0.0.0.0:5000
Environment=KRB5_KTNAME=/etc/krb5.keytab.api
Restart=always
```

### 4.3 Workstation (10.0.1.12)

**Domain Membership**
- Joined via `ipa-client-install`
- SSSD configured with `--mkhomedir`
- Users can log in with FreeIPA credentials

**Installed Software**
- Node.js 20, pnpm
- Electron GUI dependencies (GTK3, NSS, ALSA, mesa, etc.)
- "Server with GUI" package group (GNOME desktop)
- Xvfb (headless fallback)

**Launcher App**
- Source: `/opt/launcher-apps/src/libvirt-ui/`
- Built via `pnpm run make` → RPM package
- Config: `config/api.yaml` points to `https://api.lab.forge.local`

**Kerberos Integration**
- Electron launched with Chromium flags:
  - `--auth-server-whitelist=*.lab.forge.local`
  - `--auth-negotiate-delegate-whitelist=*.lab.forge.local`
- `net.request()` automatically uses system Kerberos ticket cache
- No application-level password handling

---

## 5. File Inventory

### Infrastructure (`infrastructure/`)

| File | Purpose |
|------|---------|
| `main.tf` | Provider, resource group |
| `network.tf` | VNet, subnet, NSG, public IPs, NICs |
| `vms.tf` | 3 Oracle Linux 8 VMs |
| `provisioning.tf` | Ordered provisioning (identity → api → workstation) |
| `variables.tf` | All configurable inputs |
| `outputs.tf` | IPs, SSH commands, URLs |
| `terraform.tfvars.example` | Template for user values |
| `nginx-api.conf` | Nginx reverse proxy config for API server |
| `docker-compose.keycloak.yml` | Keycloak + PostgreSQL containers |
| `scripts/setup-identity.sh` | FreeIPA + Keycloak bootstrap (8 steps) |
| `scripts/setup-api.sh` | Domain join + API deploy (9 steps) |
| `scripts/setup-workstation.sh` | Domain join + launcher build (7 steps) |

### .NET API (`api/`)

| File | Purpose |
|------|---------|
| `LauncherApi.sln` | Solution file |
| `src/LauncherApi/LauncherApi.csproj` | Project file (net8.0 + Negotiate package) |
| `src/LauncherApi/Program.cs` | App startup with Negotiate auth |
| `src/LauncherApi/appsettings.json` | Logging config |
| `src/LauncherApi/Controllers/HealthController.cs` | Anonymous health endpoint |
| `src/LauncherApi/Controllers/UserController.cs` | Authenticated user info |
| `src/LauncherApi/Controllers/ToolsController.cs` | Tool listing + launch audit |
| `src/LauncherApi/Controllers/SessionController.cs` | Server environment info |
| `src/LauncherApi/Models/ToolInfo.cs` | Tool data model |

### Launcher App Changes (`libvirt-ui/`)

| File | Change |
|------|--------|
| `config/api.yaml` | NEW — API connection config |
| `src/main.ts` | MODIFIED — Kerberos flags + apiIPC setup |
| `src/ipc/apiIPC.ts` | NEW — 6 authenticated API IPC handlers |
| `src/app/hooks/useApiConnection.ts` | NEW — React hook for connection state |
| `src/app/components/connection-status.tsx` | NEW — UI status indicator |
| `src/app/components/sidebar.tsx` | MODIFIED — Added ConnectionStatus widget |

---

## 6. Deployment Instructions

### Prerequisites
- Azure subscription (contributor access)
- SSH key pair
- Git deploy key authorized on the repository
- Terraform >= 1.5
- `az login` authenticated

### Deploy

```bash
cd infrastructure/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your SSH key, passwords, etc.

terraform init
terraform plan
terraform apply
```

Provisioning order is automatic:
1. Identity server (~15 min) — FreeIPA install is the longest step
2. API server (~5 min) — domain join + .NET build
3. Workstation (~10 min) — domain join + Node.js + Electron build

### Post-Deployment

1. **Configure Keycloak LDAP Federation** (optional, for web-based auth flows):
   - Navigate to `http://<identity-ip>:9080` (Keycloak runs on port 9080 in dev mode)
   - Login as `admin/admin`
   - Create realm `forge`
   - Add User Federation → LDAP
   - Connection URL: `ldap://idm.lab.forge.local`
   - Users DN: `cn=users,cn=accounts,dc=lab,dc=forge,dc=local`

2. **Test Kerberos auth**:
   ```bash
   # SSH into workstation
   ssh azureuser@<workstation-ip>

   # Get a Kerberos ticket
   kinit testuser@LAB.FORGE.LOCAL

   # Test API auth
   curl -k --negotiate -u : https://api.lab.forge.local/api/user
   ```

3. **Launch the app**:
   ```bash
   cd /opt/launcher-apps/src/libvirt-ui
   pnpm run start
   ```

### Tear Down

```bash
terraform destroy
```

---

## 7. Known Considerations

1. **Self-signed certificates**: The API server uses a self-signed TLS cert. The workstation's Electron app and `curl` need `-k` / `NODE_TLS_REJECT_UNAUTHORIZED=0` or the cert must be added to the system trust store. For production, use FreeIPA's Dogtag CA or a proper CA.

2. **Keycloak LDAP federation**: Must be configured manually via the admin UI after deployment. This is by design — realm configuration varies between environments.

3. **User password expiry**: FreeIPA test users are created with the admin password and will be flagged for password change on first interactive login. Use `ipa user-mod testuser --password-expiration=20271231235959Z` to extend if needed.

4. **DNS resolution**: VMs use FreeIPA as primary DNS. If FreeIPA is down, the fallback Azure DNS won't resolve internal `.lab.forge.local` names. Hosts file entries provide a safety net.

5. **Firewall**: The NSG allows SSH from anywhere for development convenience. Restrict `source_address_prefix` to your IP in production.

6. **Negotiate token size**: Nginx buffer sizes are set to 128k+ to handle large Kerberos tokens (especially with many group memberships). If auth fails with 502 errors, increase `proxy_buffer_size`.

7. **Keytab KVNO ordering**: The API keytab MUST be generated AFTER `ipa-client-install` runs on the API server. Client enrollment changes the host keys in the KDC, invalidating any previously-generated keytabs. The setup scripts handle this correctly by ordering identity→api provisioning.

8. **kinit piping on Oracle Linux 8**: `echo "pw" | kinit user` does NOT work — kinit reads from TTY. Use file redirect: `echo "pw" > /tmp/.pw && kinit user < /tmp/.pw && rm /tmp/.pw`.

9. **FreeIPA port usage**: Dogtag PKI (part of FreeIPA) uses ports 8080 and 8443 for its Java process. Keycloak must be mapped to different ports (9080/9443).

10. **ipa service-add prerequisite**: You must create the host entry (`ipa host-add`) before adding a service to it. If the host enrolled itself via `ipa-client-install`, the host already exists — but if you're pre-creating the SPN before enrollment, add the host with `--force --no-reverse` first.

11. **User password first-login reset**: `ipa passwd` as admin sets a temporary password that kinit will reject until the user changes it. To bypass for test accounts, set passwords directly via LDAP directory manager (`ldappasswd -D "cn=Directory Manager"`) and extend `krbPasswordExpiration` via `ldapmodify`.

---

## 8. Deployed Environment (2026-03-18)

| VM | Public IP | Private IP | Status |
|----|-----------|------------|--------|
| Identity (FreeIPA + Keycloak) | 13.70.124.37 | 10.0.1.10 | Running |
| API (.NET Core + Nginx) | 13.75.223.136 | 10.0.1.11 | Running |
| Workstation (domain-joined) | 20.211.166.230 | 10.0.1.12 | Ready |

**Verified working:**
- FreeIPA: All services (KDC, LDAP, DNS, HTTP, PKI) active
- Keycloak: Running on port 9080 (dev mode)
- .NET Core API: Health check, Negotiate auth, all endpoints
- Kerberos auth flow: kinit → SPNEGO → API → authenticated response
- DNS resolution: All hostnames resolve via FreeIPA DNS
