# Build Progress Log

## Session: 2026-03-17

### Phase 1: Terraform Infrastructure
**Status**: Complete

- Created `infrastructure/` directory with modular terraform files
- `main.tf` — provider config, resource group
- `network.tf` — VNet (10.0.0.0/16), subnet (10.0.1.0/24), NSG with rules for SSH/HTTPS/Kerberos/internal traffic, 3x static public IPs, 3x NICs with static private IPs (10.0.1.10/11/12)
- `vms.tf` — 3 Oracle Linux 8 VMs using `Oracle:Oracle-Linux:ol88-lvm-gen2:latest` image
- `provisioning.tf` — Ordered provisioning with `depends_on` (identity first, then api + workstation)
- `variables.tf` — All configurable inputs including domain, realm, IPA passwords (sensitive)
- `outputs.tf` — IPs, SSH commands, URLs for all 3 VMs
- **Decision**: Used `Standard_D4s_v3` (4 vCPU, 16GB) — sufficient for all roles, cheaper than D8s
- **Decision**: Static private IPs to avoid DNS issues during setup
- **Decision**: Separate public IPs on all VMs for SSH access during development

### Phase 2: Identity Server (FreeIPA + Keycloak)
**Status**: Complete

- `scripts/setup-identity.sh` — 8-step automated setup
- FreeIPA installed via `idm:DL1` module (Oracle Linux 8 compatible, RHEL-based)
- Integrated DNS with A records for all 3 VMs + reverse PTR records
- Service principal created: `HTTP/api.lab.forge.local` with keytab export
- Test users created: `testuser`, `launcheruser`
- Keycloak via Docker Compose (v22.0.2) with PostgreSQL 15 backend
- **Decision**: Used `--no-forwarders` for FreeIPA DNS — Azure DNS (168.63.129.16) added to resolv.conf separately to avoid conflicts
- **Decision**: `--no-ntp` since Azure VMs have time sync built in
- **Decision**: Keycloak runs on port 8443 to avoid conflict with FreeIPA's own HTTPS on 443
- **Note**: Keycloak LDAP federation to FreeIPA must be configured via admin UI post-deployment (connection URL, users DN, bind credentials). This is intentional — realm config varies.

### Phase 3: .NET Core API
**Status**: Complete

- Created `api/` directory with ASP.NET Core 8 Web API project
- `Microsoft.AspNetCore.Authentication.Negotiate` for Kerberos/SPNEGO auth
- 4 controllers:
  - `HealthController` — `[AllowAnonymous]` health check at `/api/health`
  - `UserController` — Returns Kerberos principal and claims at `/api/user`
  - `ToolsController` — Tool listing + launch audit at `/api/tools`
  - `SessionController` — Environment info at `/api/session`
- Auth debug logging enabled in appsettings.json for troubleshooting
- **Decision**: `FallbackPolicy = DefaultPolicy` — all endpoints require auth by default, explicit `[AllowAnonymous]` on health only
- **Decision**: Self-contained=false for publish — .NET runtime installed on server, keeps artifact smaller

### Phase 3b: API Server Setup + Nginx
**Status**: Complete

- `scripts/setup-api.sh` — 9-step automated setup
- Domain join via `ipa-client-install --unattended`
- Keytab retrieved via `ipa-getkeytab` for `HTTP/api.lab.forge.local`
- Systemd service with `KRB5_KTNAME` environment variable pointing at keytab
- Nginx reverse proxy with self-signed TLS cert
- **Decision**: Self-signed cert — FreeIPA's Dogtag CA could be used, but adds complexity. Self-signed is fine for test env. Will need to handle cert trust on workstation.
- **Decision**: SELinux `httpd_can_network_connect` boolean set for nginx proxy
- **Decision**: DNS resolution pointed at FreeIPA server with Azure DNS as fallback
- `nginx-api.conf` — Proxies `/api/*` to Kestrel on port 5000, passes Authorization header, large buffer sizes for Negotiate tokens (128k+), WebSocket support for future SignalR

### Phase 4: Workstation Setup
**Status**: Complete

- `scripts/setup-workstation.sh` — 7-step automated setup
- Domain join via `ipa-client-install --unattended`
- Node.js 20 + pnpm installed
- Electron GUI dependencies (GTK3, NSS, ALSA, mesa, etc.)
- Git clone + `pnpm install` + `pnpm run make` (RPM build)
- API config (`config/api.yaml`) written with domain-specific base URL
- **Decision**: Attempted RPM install from Electron Forge output, with fallback to dev mode if build fails
- **Decision**: Installed "Server with GUI" group for desktop environment — needed for Electron
- **Note**: `Xvfb` installed as fallback for headless testing

### Phase 5: Launcher App Code Changes
**Status**: Complete

- New `src/ipc/apiIPC.ts` — 6 IPC handlers using Electron's `net.request()` for native Negotiate support
  - `api:health` — unauthenticated connectivity check
  - `api:user` — authenticated user identity
  - `api:tools` — server-side tool listing
  - `api:launch-tool` — audit trail for tool launches
  - `api:session` — server environment info
  - `api:reload-config` — hot-reload API config
- New `config/api.yaml` — API base URL and auth method config
- Modified `src/main.ts`:
  - Added `--auth-server-whitelist` and `--auth-negotiate-delegate-whitelist` Chromium flags for `*.lab.forge.local`
  - Registered `setupApiIPC()` in app ready handler
- New `src/app/hooks/useApiConnection.ts` — React hook with polling (30s default) for connection state + user identity
- New `src/app/components/connection-status.tsx` — Status indicator (Connected/Offline + username)
- Modified `src/app/components/sidebar.tsx` — Added ConnectionStatus widget above bottom section
- **Key insight**: Electron's Chromium engine handles SPNEGO natively when `--auth-server-whitelist` matches. No need for the `kerberos` npm package or manual token handling. `net.request()` will automatically acquire and send Negotiate tokens using the system's Kerberos ticket cache.

---

## Session: 2026-03-18 — Deployment

### Terraform Apply
**Status**: Partial — VMs created, identity provisioner failed mid-script

- `terraform apply` created all 17 resources (3 VMs, networking, provisioners)
- Identity server provisioner started but was killed (exit code 9 / SIGKILL) ~40 minutes in
  - FreeIPA installed and running (steps 1-5 completed)
  - Steps 6-8 (SPN, users, Docker) did not complete
  - **Root cause**: Terraform suppresses remote-exec output when command contains sensitive variables. The script ran for a long time and the SSH connection may have been dropped. Not OOM (checked dmesg).
- API and workstation provisioners never started (depend_on identity which failed)

### Manual Completion — Identity Server (13.70.124.37)

**Issues found and fixed:**

1. **kinit piping doesn't work**: `echo "password" | kinit admin` fails on Oracle Linux 8 — kinit reads from TTY, not stdin. **Fix**: Use file redirect: `echo pw > /tmp/.pw && kinit admin < /tmp/.pw && rm /tmp/.pw`

2. **`ipa service-add` requires host to exist**: Can't add `HTTP/api.lab.forge.local` until the host entry exists in IPA. **Fix**: Added `ipa host-add api.lab.forge.local --force --no-reverse` before service-add.

3. **`ipa host-add` with `--ip-address` conflicts**: Fails because DNS A record already exists. **Fix**: Use `--no-reverse` flag instead of `--ip-address`.

4. **Keycloak port conflict**: Ports 8080 and 8443 are used by FreeIPA's Dogtag PKI (Java process). **Fix**: Remapped Keycloak to 9080:8080 and 9443:8443.

5. **Keycloak `start` vs `start-dev`**: `command: start` requires HTTPS/TLS configuration. For dev environment without certs: **Fix**: Changed to `start-dev`.

6. **User password reset on first login**: `ipa passwd` sets a temporary password flagged for mandatory change. kinit rejects it. **Fix**: Set password via LDAP directory manager (`ldappasswd`) and extended `krbPasswordExpiration` via `ldapmodify`.

All steps (DNS, SPN, keytab, users, Docker, Keycloak) completed manually. Scripts updated with fixes for future deployments.

### Manual Provisioning — API Server (13.75.223.136)

**Issues found and fixed:**

1. **Git clone fails**: The repo `scatter222/launcher-apps` doesn't exist on GitHub (it's a local development repo). **Fix**: Tar'd the `api/` directory and uploaded via SCP instead.

2. **Keytab KVNO mismatch**: Keytab was generated on identity server (KVNO=1), then `ipa-client-install` on the API server re-enrolled the host bumping KVNO. The old keytab couldn't decrypt tickets. **Fix**: Regenerated keytab **after** domain enrollment. New keytab has KVNO=3 and works.

All services running: launcher-api.service (systemd), nginx (HTTPS proxy), FreeIPA client enrolled.

### Manual Provisioning — Workstation (20.211.166.230)

**Issues found and fixed:**

1. **Git clone fails**: Same as API server — local repo not on GitHub. **Fix**: Tar'd `libvirt-ui/` and uploaded via SCP.

2. **pnpm not in PATH**: `npm install -g pnpm` installs to `/usr/local/bin/` but the script's environment under `sudo` doesn't include it. **Fix**: Explicit `export PATH=/usr/local/bin:$PATH` before pnpm commands.

Domain joined, Node.js 20 + pnpm installed, launcher dependencies installed.

### End-to-End Auth Test
**Status**: PASSING

From the workstation:
```
$ kinit testuser@LAB.FORGE.LOCAL
$ curl -sk --negotiate -u : https://api.lab.forge.local/api/user

{"name":"testuser@LAB.FORGE.LOCAL","authenticationType":"Kerberos","isAuthenticated":true}

$ curl -sk --negotiate -u : https://api.lab.forge.local/api/tools

{"user":"testuser@LAB.FORGE.LOCAL","tools":[...5 tools...]}

$ curl -sk --negotiate -u : https://api.lab.forge.local/api/session

{"user":"testuser@LAB.FORGE.LOCAL","hostname":"api","environment":"Production",...}
```

Full Kerberos SPNEGO flow verified:
1. Workstation kinit → FreeIPA KDC issues TGT
2. curl --negotiate → KDC issues service ticket for HTTP/api.lab.forge.local
3. SPNEGO token sent in Authorization header through nginx proxy
4. ASP.NET Core Negotiate middleware validates via keytab
5. User identity (`testuser@LAB.FORGE.LOCAL`) available in controller

### Environment Summary

| VM | Public IP | Role | Status |
|----|-----------|------|--------|
| Identity | 13.70.124.37 | FreeIPA + Keycloak | Running |
| API | 13.75.223.136 | .NET Core API + Nginx | Running |
| Workstation | 20.211.166.230 | Launcher (domain-joined) | Ready |

---

_This document tracks decisions, issues, and resolutions as we build. It will feed into the final AS-BUILT.md._
