# Launcher Apps — Authenticated Environment Plan

## Overview

Three-VM architecture on Azure providing a domain-joined workstation running the Electron launcher, a .NET Core API server, and a FreeIPA + Keycloak identity server. Authentication flows via Kerberos (SPNEGO/Negotiate) so the launcher automatically picks up the workstation's domain credentials to call the API — no manual login required.

All VMs run **Oracle Linux** (matching production).

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Azure Virtual Network                        │
│                         10.0.0.0/16                                 │
│                                                                     │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐ │
│  │  VM 1: Identity  │  │  VM 2: API      │  │  VM 3: Workstation  │ │
│  │  Server          │  │  Server         │  │                     │ │
│  │                  │  │                 │  │  Electron Launcher  │ │
│  │  FreeIPA         │  │  .NET Core API  │  │  (domain-joined)    │ │
│  │   - Kerberos KDC │  │  (systemd)      │  │                     │ │
│  │   - LDAP/389 DS  │  │                 │  │  Kerberos ticket    │ │
│  │   - DNS          │  │  Nginx reverse  │  │  → SPNEGO header    │ │
│  │                  │  │  proxy (HTTPS)  │  │  → API call         │ │
│  │  Keycloak        │  │                 │  │                     │ │
│  │  (federated to   │  │                 │  │                     │ │
│  │   FreeIPA)       │  │                 │  │                     │ │
│  │                  │  │                 │  │                     │ │
│  │  10.0.1.10       │  │  10.0.1.11      │  │  10.0.1.12          │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────────┘ │
│                                                                     │
│  Subnet: 10.0.1.0/24                                               │
└─────────────────────────────────────────────────────────────────────┘
```

### Authentication Flow

```
Workstation (VM3)                API Server (VM2)              FreeIPA (VM1)
     │                                │                            │
     │  1. User logs in (domain)      │                            │
     │  ───── kinit / SSO ──────────────────────────────────────►  │
     │  ◄──── TGT issued ──────────────────────────────────────── │
     │                                │                            │
     │  2. Launcher calls API         │                            │
     │  ── GET /api/foo ─────────────►│                            │
     │     Authorization: Negotiate   │                            │
     │     <base64 SPNEGO token>      │                            │
     │                                │  3. Validate ticket        │
     │                                │  ─── krb5 verify ────────►│
     │                                │  ◄── identity confirmed ──│
     │                                │                            │
     │  ◄── 200 OK (authenticated) ──│                            │
     │                                │                            │
```

---

## Domain & Naming

| Item | Value |
|------|-------|
| Domain | `lab.forge.local` |
| Kerberos Realm | `LAB.FORGE.LOCAL` |
| FreeIPA hostname | `idm.lab.forge.local` |
| API Server hostname | `api.lab.forge.local` |
| Workstation hostname | `ws1.lab.forge.local` |
| API SPN | `HTTP/api.lab.forge.local@LAB.FORGE.LOCAL` |

---

## VM Specifications

| VM | Role | Azure Size | OS | Static IP |
|----|------|------------|-----|-----------|
| identity-server | FreeIPA + Keycloak | Standard_D4s_v3 | Oracle Linux 8 | 10.0.1.10 |
| api-server | .NET Core API + Nginx | Standard_D4s_v3 | Oracle Linux 8 | 10.0.1.11 |
| workstation | Electron Launcher | Standard_D4s_v3 | Oracle Linux 8 | 10.0.1.12 |

---

## Work Breakdown

### Phase 1: Terraform Infrastructure

> **Goal**: Stand up 3 Oracle Linux VMs on Azure with correct networking and DNS.

- [ ] **1.1** Create terraform project structure under `infrastructure/`
  - `main.tf` — provider, resource group
  - `network.tf` — VNet, subnet, NSG, NICs, public IPs
  - `vms.tf` — 3 Oracle Linux VMs with static private IPs
  - `variables.tf` — configurable inputs (SSH keys, VM sizes, domain name, etc.)
  - `outputs.tf` — public IPs, SSH commands, URLs
  - `terraform.tfvars` — user-specific values

- [ ] **1.2** Networking & NSG rules
  - Allow SSH (22) inbound from user IP
  - Allow HTTPS (443) to API server
  - Allow internal traffic between all 3 VMs on subnet (all ports)
  - Allow Kerberos ports internally (88/TCP+UDP, 464/TCP+UDP)
  - Allow LDAP/LDAPS internally (389, 636)
  - Allow DNS internally (53/TCP+UDP)
  - Allow Keycloak (8443) to identity server

- [ ] **1.3** Oracle Linux VM image
  - Use `Oracle:Oracle-Linux:ol88-lvm-gen2:latest` (or equivalent Oracle Linux 8.x marketplace image)
  - SSH key auth only, no password

- [ ] **1.4** Provisioning scripts (uploaded via file provisioner, run via remote-exec — same pattern as blue-forge test-environment)
  - `scripts/setup-identity.sh` — FreeIPA + Keycloak bootstrap
  - `scripts/setup-api.sh` — .NET API deployment
  - `scripts/setup-workstation.sh` — Domain join + launcher install

---

### Phase 2: Identity Server (VM1)

> **Goal**: FreeIPA providing Kerberos KDC + LDAP + DNS, Keycloak federated to it.

- [ ] **2.1** FreeIPA installation script (`setup-identity.sh`)
  - Install `ipa-server` and `ipa-server-dns` packages
  - Run `ipa-server-install` unattended with:
    - Domain: `lab.forge.local`
    - Realm: `LAB.FORGE.LOCAL`
    - Integrated DNS with forwarders (Azure DNS: 168.63.129.16)
    - Admin password from variable
    - DS password from variable
  - Create DNS A records for all 3 VMs
  - Create service principal: `HTTP/api.lab.forge.local`
  - Export keytab for API server: `/etc/krb5.keytab.api`
  - Create test user accounts (e.g., `testuser`, `admin`)

- [ ] **2.2** Keycloak setup (Docker Compose, same pattern as existing test-env)
  - PostgreSQL backend container
  - Keycloak container with HTTPS (self-signed or Let's Encrypt)
  - User Federation → LDAP provider pointing at FreeIPA
    - Connection URL: `ldap://localhost`
    - Users DN: `cn=users,cn=accounts,dc=lab,dc=forge,dc=local`
    - Bind DN: `uid=admin,cn=users,cn=accounts,dc=lab,dc=forge,dc=local`
    - Kerberos integration enabled
  - Create realm: `forge`
  - Create client: `launcher-api` (for future OAuth2 flows if needed)

- [ ] **2.3** Copy API keytab to API server
  - Use SCP via provisioner or a shared mechanism to transfer the keytab

---

### Phase 3: API Server (VM2)

> **Goal**: .NET Core API accepting Kerberos/Negotiate auth, served via Nginx with HTTPS.

- [ ] **3.1** Create .NET Core Web API project (`api/`)
  - New ASP.NET Core 8 Web API project
  - Target framework: `net8.0`
  - Project structure:
    ```
    api/
    ├── LauncherApi.sln
    └── src/
        └── LauncherApi/
            ├── Program.cs
            ├── appsettings.json
            ├── Controllers/
            │   ├── HealthController.cs        # GET /api/health (anonymous)
            │   ├── UserController.cs          # GET /api/user (authenticated)
            │   ├── ToolsController.cs         # Tool management endpoints
            │   └── SessionController.cs       # Session/environment info
            ├── Auth/
            │   └── NegotiateDefaults.cs       # Negotiate auth config
            └── Models/
                └── ...

    ```

- [ ] **3.2** Configure Negotiate/SPNEGO authentication
  - Add `Microsoft.AspNetCore.Authentication.Negotiate` NuGet package
  - In `Program.cs`:
    ```csharp
    builder.Services.AddAuthentication(NegotiateDefaults.AuthenticationScheme)
        .AddNegotiate();
    builder.Services.AddAuthorization(options =>
    {
        options.FallbackPolicy = options.DefaultPolicy; // require auth by default
    });
    ```
  - `[AllowAnonymous]` on health endpoint
  - `[Authorize]` on all other controllers
  - `User.Identity.Name` gives the Kerberos principal (e.g. `testuser@LAB.FORGE.LOCAL`)

- [ ] **3.3** API endpoints (initial set)
  - `GET /api/health` — unauthenticated health check
  - `GET /api/user` — returns authenticated user info (principal, groups)
  - `GET /api/tools` — returns available tools for the user
  - `POST /api/tools/{id}/launch` — log/authorize tool launch
  - `GET /api/sessions` — active sessions

- [ ] **3.4** Deployment setup (`setup-api.sh`)
  - Install .NET 8 SDK/runtime
  - Install `krb5-workstation` packages
  - Join to FreeIPA domain: `ipa-client-install --unattended`
  - Place API keytab at `/etc/krb5.keytab`
  - Set `KRB5_KTNAME` environment variable for the service
  - `dotnet publish` the API in Release mode
  - Create systemd unit `launcher-api.service`:
    ```ini
    [Unit]
    Description=Launcher API
    After=network.target

    [Service]
    WorkingDirectory=/opt/launcher-api
    ExecStart=/opt/launcher-api/LauncherApi
    Environment=ASPNETCORE_URLS=http://0.0.0.0:5000
    Environment=KRB5_KTNAME=/etc/krb5.keytab
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
    ```

- [ ] **3.5** Nginx reverse proxy with HTTPS
  - Self-signed cert (or internal CA from FreeIPA)
  - Proxy `/api/` → `http://localhost:5000`
  - Pass `Authorization` header through
  - WebSocket support for future SignalR hubs

---

### Phase 4: Workstation (VM3)

> **Goal**: Domain-joined Oracle Linux workstation running the Electron launcher with Kerberos SSO to the API.

- [ ] **4.1** Domain join script (`setup-workstation.sh`)
  - Install `ipa-client` packages
  - Run `ipa-client-install --unattended` with:
    - Domain: `lab.forge.local`
    - Server: `idm.lab.forge.local`
    - Principal: `admin`
    - Password from variable
  - Configure SSSD for domain login
  - Verify with `kinit testuser` + `klist`

- [ ] **4.2** Install workstation dependencies
  - Node.js 20 (for building the Electron app)
  - pnpm
  - Desktop environment (GNOME/XFCE) if needed for GUI
  - `krb5-workstation` (should come with ipa-client)
  - Electron runtime dependencies (libgtk, libnotify, libnss, etc.)

- [ ] **4.3** Build and install launcher
  - Clone repo, `pnpm install`, `pnpm run make`
  - Install the RPM package (Electron Forge already has RPM maker configured)
  - Or run in dev mode: `pnpm run start`

---

### Phase 5: Launcher App Code Changes

> **Goal**: Add authenticated API communication to the Electron launcher using the workstation's Kerberos ticket.

- [ ] **5.1** New IPC module: `src/ipc/apiIPC.ts`
  - API base URL from config (e.g., `https://api.lab.forge.local`)
  - Uses Electron's `net.request()` which **natively supports Negotiate/Kerberos auth** on Linux when `krb5` is configured — this is the key integration point
  - Alternatively, use Node.js `fetch()` with `negotiate` auth via the `kerberos` npm package
  - Expose IPC channels:
    - `api:health` — check API connectivity
    - `api:user` — get current authenticated user
    - `api:tools` — fetch tools from server
    - `api:launch-tool` — notify server of tool launch

- [ ] **5.2** Config additions
  - New config file `config/api.yaml`:
    ```yaml
    api:
      baseUrl: https://api.lab.forge.local
      timeout: 10000
      auth:
        method: negotiate  # kerberos/SPNEGO
    ```

- [ ] **5.3** Preload script updates (`src/preload.ts`)
  - Add `api:*` channels to the whitelist

- [ ] **5.4** UI updates
  - Add connection status indicator in the titlebar (connected/disconnected to API)
  - Show authenticated user identity somewhere in the sidebar
  - Dashboard shows server-sourced data alongside local data
  - Handle auth failures gracefully (prompt user to `kinit` or re-login)

- [ ] **5.5** Electron Kerberos configuration
  - Ensure Electron uses system Kerberos credentials:
    ```typescript
    // In main.ts, before creating window:
    app.commandLine.appendSwitch('auth-server-whitelist', '*.lab.forge.local');
    app.commandLine.appendSwitch('auth-negotiate-delegate-whitelist', '*.lab.forge.local');
    ```
  - This tells Chromium (Electron's engine) to use Negotiate auth for the domain

---

### Phase 6: Integration Testing & Validation

- [ ] **6.1** End-to-end auth flow test
  - SSH into workstation
  - `kinit testuser@LAB.FORGE.LOCAL`
  - `curl --negotiate -u : https://api.lab.forge.local/api/user` — should return user info
  - Launch Electron app — should pick up ticket automatically

- [ ] **6.2** Keycloak federation test
  - Log into Keycloak admin console
  - Verify FreeIPA users appear via User Federation
  - Authenticate via Keycloak login page using FreeIPA credentials

- [ ] **6.3** Failure mode testing
  - Expired ticket → launcher shows "re-authenticate" prompt
  - API server down → launcher degrades gracefully to local-only mode
  - FreeIPA down → existing tickets still work until expiry

---

## File Structure (New Code)

```
launcher-apps/
├── libvirt-ui/                          # Existing Electron app
│   ├── config/
│   │   ├── api.yaml                     # NEW — API server config
│   │   ├── vms.yaml
│   │   ├── tools.yaml
│   │   └── webapps.yaml
│   └── src/
│       ├── ipc/
│       │   ├── apiIPC.ts                # NEW — Authenticated API calls
│       │   ├── libvirtIPC.ts
│       │   ├── toolsIPC.ts
│       │   └── webappsIPC.ts
│       ├── main.ts                      # MODIFIED — Kerberos flags
│       └── preload.ts                   # MODIFIED — API channel whitelist
│
├── api/                                 # NEW — .NET Core API
│   ├── LauncherApi.sln
│   └── src/
│       └── LauncherApi/
│           ├── Program.cs
│           ├── appsettings.json
│           ├── Controllers/
│           └── Models/
│
└── infrastructure/                      # NEW — Terraform
    ├── main.tf
    ├── network.tf
    ├── vms.tf
    ├── variables.tf
    ├── outputs.tf
    ├── terraform.tfvars
    ├── nginx.conf
    ├── docker-compose.keycloak.yml
    └── scripts/
        ├── setup-identity.sh
        ├── setup-api.sh
        └── setup-workstation.sh
```

---

## Key Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Kerberos auth method | SPNEGO/Negotiate via Electron flags | Zero-login UX — picks up domain ticket automatically. Electron's Chromium engine supports it natively with `--auth-server-whitelist`. |
| API framework | ASP.NET Core 8 with `AddNegotiate()` | First-class Kerberos support on Linux via the `Microsoft.AspNetCore.Authentication.Negotiate` package. |
| Identity provider | FreeIPA | Provides Kerberos KDC + LDAP + DNS in one package. Standard for Linux domain environments. |
| Keycloak role | Federation + future OAuth2 | Federated to FreeIPA for web-based auth flows. Not in the critical path for launcher→API auth (that's pure Kerberos). |
| VM OS | Oracle Linux 8 | Matches production. RHEL-compatible, FreeIPA and .NET 8 both supported. |
| Provisioning | SSH + shell scripts (file provisioner) | Matches existing blue-forge pattern. Simple, debuggable, no Ansible/Chef dependency. |

---

## Order of Operations (Deployment)

1. `terraform apply` — creates all 3 VMs and networking
2. Identity server provisions first (FreeIPA install ~10 min)
3. API server provisions second (domain join depends on FreeIPA being up)
4. Workstation provisions last (domain join + launcher build)

Terraform `depends_on` will enforce this ordering.

---

## Prerequisites

- Azure subscription with contributor access
- SSH key pair (`~/.ssh/id_rsa` / `~/.ssh/id_rsa.pub`)
- Terraform >= 1.5 installed locally
- `az login` authenticated
- Git deploy key if cloning from private repo
