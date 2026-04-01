# VM Management Feature — Design & Implementation Plan

## Overview

Two-tier VM management: **local VMs** on the user's laptop (VirtualBox) and **remote VMs** on the server (KVM via authenticated API). Non-technical users can start/stop VMs and get console access without touching hypervisor UIs.

## Current State

The codebase already has a VM management system (`libvirtIPC.ts`, `vm-dashboard.tsx`) built around `virsh`/KVM commands. This needs to be **replaced** with a dual-provider architecture:

- **Local provider**: VirtualBox (`VBoxManage` CLI)
- **Remote provider**: KVM via the .NET Core API (authenticated with Kerberos SPNEGO)

The existing IPC pattern (YAML config → IPC handlers → React screens) stays the same.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Electron Launcher (Laptop)                             │
│                                                         │
│  ┌─────────────┐   ┌──────────────────────────────────┐ │
│  │  VM Dashboard│   │  IPC Layer                       │ │
│  │  (React UI)  │──▶│                                  │ │
│  │             │   │  localVmIPC.ts   (VBoxManage)    │ │
│  │  - Local tab │   │  remoteVmIPC.ts  (API calls)    │ │
│  │  - Remote tab│   │                                  │ │
│  └─────────────┘   └────────┬───────────┬─────────────┘ │
│                              │           │               │
│                     VBoxManage CLI   net.request()       │
│                              │       (SPNEGO auth)       │
└──────────────────────────────┼───────────┼───────────────┘
                               │           │
                    ┌──────────┘           │
                    ▼                      ▼
           ┌──────────────┐     ┌────────────────────┐
           │  VirtualBox   │     │  API Server         │
           │  (Laptop)     │     │  (.NET Core)        │
           │               │     │                     │
           │  OVA images   │     │  VmController.cs    │
           │  in config    │     │    ├ GET  /api/vms   │
           │  directory    │     │    ├ POST /api/vms   │
           │               │     │    ├ POST /start     │
           │               │     │    ├ POST /stop      │
           │               │     │    ├ DELETE /api/vms │
           │               │     │    └ GET  /console   │
           │               │     │                     │
           └──────────────┘     │  virsh / libvirt    │
                                │  on server           │
                                └────────────────────┘
```

---

## Part 1: Local VMs (VirtualBox)

### How It Works

1. During the laptop build process, OVA files are placed in a known directory (e.g. `/opt/launcher-apps/vms/`)
2. A YAML config file describes each available VM template
3. The Electron app reads the config, imports OVAs into VirtualBox if needed, and manages lifecycle via `VBoxManage`

### Config Format: `config/local-vms.yaml`

```yaml
settings:
  imagesDirectory: /opt/launcher-apps/vms  # where OVA files live
  autoRefresh: true
  refreshInterval: 5000  # ms

vms:
  - name: sift-workstation
    displayName: SIFT Workstation
    description: SANS digital forensics and incident response environment
    category: forensics
    ovaFile: sift-workstation.ova        # relative to imagesDirectory
    specs:
      memory: 4096   # MB
      cpus: 2
    tags:
      - forensics
      - dfir
      - ubuntu

  - name: remnux
    displayName: REMnux
    description: Malware analysis and reverse engineering toolkit
    category: malware-analysis
    ovaFile: remnux.ova
    specs:
      memory: 4096
      cpus: 2
    tags:
      - malware
      - reversing
      - sandbox
```

### VBoxManage Operations

| Operation | Command |
|-----------|---------|
| Import OVA | `VBoxManage import <path>.ova --vsys 0 --vmname <name>` |
| List VMs | `VBoxManage list vms` + `VBoxManage showvminfo <name> --machinereadable` |
| Start VM | `VBoxManage startvm <name> --type gui` |
| Start headless | `VBoxManage startvm <name> --type headless` |
| Stop (ACPI) | `VBoxManage controlvm <name> acpipowerbutton` |
| Force stop | `VBoxManage controlvm <name> poweroff` |
| Get state | `VBoxManage showvminfo <name> --machinereadable \| grep VMState=` |
| Console/RDP | VirtualBox handles this — `startvm --type gui` opens the console window |
| Delete | `VBoxManage unregistervm <name> --delete` |
| Modify RAM | `VBoxManage modifyvm <name> --memory <MB>` |
| Modify CPUs | `VBoxManage modifyvm <name> --cpus <N>` |

### IPC Handlers: `src/ipc/localVmIPC.ts`

```
local-vms:list          → List all configured local VMs with live state from VBoxManage
local-vms:start         → Import OVA if not yet imported, then start (--type gui)
local-vms:stop          → ACPI shutdown (graceful), with force option
local-vms:restart       → Stop then start
local-vms:open-console  → Start with GUI if not running, or bring window to front
local-vms:delete        → Unregister and delete VM files
local-vms:get-state     → Get current state of a single VM
local-vms:reload-config → Re-read local-vms.yaml
```

### State Mapping

| VBoxManage VMState | UI State |
|-------------------|----------|
| `running` | running |
| `poweroff` | stopped |
| `saved` | suspended |
| `paused` | paused |
| `aborted` | stopped (error) |
| (not imported) | available |

The "available" state is key — it means the OVA exists in config but hasn't been imported yet. The UI shows an "Import & Start" button instead of "Start".

---

## Part 2: Remote VMs (KVM via API)

### How It Works

1. The API server has a pool of VM templates (qcow2 base images) defined in its config
2. Users can **spawn an instance** of a template — the API creates a copy-on-write overlay and boots a new VM
3. Each instance is **owned by a user** (identified by their Kerberos principal)
4. Multiple laptops can each have their own instances of the same template
5. Users can start/stop/delete their own instances and get console access via SPICE/VNC URLs

### API Endpoints: `VmController.cs`

```
GET    /api/vms/templates              → List available VM templates
GET    /api/vms/instances              → List current user's VM instances
POST   /api/vms/instances              → Spawn a new instance from a template
POST   /api/vms/instances/{id}/start   → Start an instance
POST   /api/vms/instances/{id}/stop    → Stop an instance (graceful)
POST   /api/vms/instances/{id}/restart → Restart an instance
DELETE /api/vms/instances/{id}         → Destroy an instance (stop + delete)
GET    /api/vms/instances/{id}/console → Get SPICE/VNC console connection info
```

### Server-Side Config: `config/vm-templates.json`

Lives on the API server. Defines available base images:

```json
{
  "settings": {
    "baseImageDir": "/var/lib/libvirt/images/base",
    "instanceDir": "/var/lib/libvirt/images/instances",
    "defaultNetwork": "default",
    "maxInstancesPerUser": 5
  },
  "templates": [
    {
      "id": "kali-2024",
      "name": "Kali Linux 2024",
      "description": "Penetration testing and security auditing OS",
      "baseImage": "kali-2024.qcow2",
      "specs": {
        "memory": 4096,
        "cpus": 2,
        "diskSize": 40
      },
      "category": "offensive",
      "tags": ["pentest", "kali", "offensive"]
    },
    {
      "id": "win10-target",
      "name": "Windows 10 Target",
      "description": "Windows 10 target machine for testing",
      "baseImage": "win10-target.qcow2",
      "specs": {
        "memory": 4096,
        "cpus": 2,
        "diskSize": 60
      },
      "category": "targets",
      "tags": ["windows", "target", "vulnerable"]
    }
  ]
}
```

### Instance Model

When a user spawns a VM, the server creates:

1. A **copy-on-write overlay** disk: `{instanceDir}/{user}_{templateId}_{shortId}.qcow2` backed by the base image
2. A **libvirt domain** with the user's name in the metadata
3. An **instance record** tracked in a JSON file on disk (`/var/lib/libvirt/instances.json`)

Instance record:

```json
{
  "id": "abc123",
  "templateId": "kali-2024",
  "owner": "testuser@LAB.FORGE.LOCAL",
  "name": "kali-2024-testuser-abc123",
  "createdAt": "2026-04-01T10:30:00Z",
  "state": "running",
  "consolePort": 5901,
  "consoleType": "vnc"
}
```

### Server-Side VM Operations (virsh)

| Operation | Implementation |
|-----------|---------------|
| Create overlay | `qemu-img create -f qcow2 -b <base>.qcow2 -F qcow2 <instance>.qcow2` |
| Define domain | `virsh define <xml>` (generated XML with user metadata) |
| Start | `virsh start <domain>` |
| Stop | `virsh shutdown <domain>` (graceful) |
| Force stop | `virsh destroy <domain>` |
| Delete | `virsh undefine <domain> --remove-all-storage` |
| Get state | `virsh domstate <domain>` |
| Console info | `virsh domdisplay <domain>` (returns vnc://host:port or spice://...) |
| List user's VMs | Filter `virsh list --all` by metadata owner |

### IPC Handlers (Electron side): `src/ipc/remoteVmIPC.ts`

These call the API using the same authenticated `net.request()` pattern from `apiIPC.ts`:

```
remote-vms:list-templates  → GET /api/vms/templates
remote-vms:list-instances  → GET /api/vms/instances
remote-vms:spawn           → POST /api/vms/instances { templateId }
remote-vms:start           → POST /api/vms/instances/{id}/start
remote-vms:stop            → POST /api/vms/instances/{id}/stop
remote-vms:restart         → POST /api/vms/instances/{id}/restart
remote-vms:delete          → DELETE /api/vms/instances/{id}
remote-vms:console         → GET /api/vms/instances/{id}/console
remote-vms:reload          → Re-fetch templates + instances
```

---

## Part 3: UI Design

### VM Dashboard Tabs

The existing `vm-dashboard.tsx` is replaced with a tabbed layout:

```
┌──────────────────────────────────────────────────┐
│  Virtual Machines                                 │
│                                                   │
│  [ Local VMs ]  [ Remote VMs ]                    │
│  ─────────────────────────────────────            │
│                                                   │
│  (Tab content below)                              │
└──────────────────────────────────────────────────┘
```

### Local VMs Tab

Shows VM cards from `local-vms.yaml`. Each card shows:

- Name, description, category badge
- Specs (RAM, CPU)
- Tags
- State badge: **Available** (grey), **Running** (green), **Stopped** (red), **Suspended** (yellow)
- Actions:
  - Available → **Import & Start** button
  - Stopped → **Start**, **Delete**
  - Running → **Stop**, **Open Console**

### Remote VMs Tab

Two sections:

**1. Available Templates** (top)
Cards for each server template. Each has a **Spawn Instance** button.

**2. My Instances** (bottom)
Cards for the current user's running/stopped instances. Each shows:
- Template name, owner, created time
- State badge
- Actions: **Start**, **Stop**, **Delete**, **Console** (opens VNC/SPICE viewer or shows connection URL)

---

## Part 4: Implementation Order

### Phase 1 — Local VMs (VirtualBox)
1. Create `src/ipc/localVmIPC.ts` — VBoxManage wrapper with all IPC handlers
2. Create `config/local-vms.yaml` — sample config with 2 VMs
3. Update `vm-dashboard.tsx` — add tabs, wire up local VM tab
4. Update `main.ts` — register new IPC setup
5. Test on a machine with VirtualBox

### Phase 2 — Remote VMs (API)
6. Create `VmController.cs` — API endpoints with virsh backend
7. Create `VmService.cs` — Business logic (instance tracking, virsh commands, ownership)
8. Create `VmTemplate.cs`, `VmInstance.cs` — Models
9. Create server config `vm-templates.json`
10. Create `src/ipc/remoteVmIPC.ts` — API-calling IPC handlers
11. Update `vm-dashboard.tsx` — wire up remote VM tab
12. Deploy and test end-to-end

### Phase 3 — Cleanup
13. Remove old `libvirtIPC.ts` (replaced by local + remote)
14. Fix the existing `dashboard.tsx` bug (`vms:list` → `local-vms:list`)
15. Update setup-workstation.sh to install VirtualBox
16. Update documentation and Excalidraw diagrams

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| VirtualBox for local, KVM for remote | VBox is standard on laptops; KVM is standard on Linux servers. Users won't install both. |
| OVA files for local templates | Standard, portable format. Non-devs can export from any VirtualBox and drop in a directory. |
| Copy-on-write overlays for remote | Fast instance creation (~1s vs minutes for full copy). Base images shared. |
| JSON file for instance tracking (not DB) | Simple, no extra infrastructure. The API server is already stateful. Good enough for <100 instances. |
| Ownership by Kerberos principal | Already have the user identity from SPNEGO. No extra auth layer needed. |
| Console via VNC/SPICE URL | Works cross-platform. VirtualBox handles local console natively with `--type gui`. |
| Tabs (local/remote) not mixed list | Clear mental model — "my laptop" vs "the server". Different capabilities (e.g., can't spawn local). |
| YAML config for local, JSON API for remote | Matches existing patterns (local config is YAML, API responses are JSON). |

---

## Files to Create/Modify

### New Files
| File | Purpose |
|------|---------|
| `libvirt-ui/src/ipc/localVmIPC.ts` | VirtualBox management via VBoxManage |
| `libvirt-ui/src/ipc/remoteVmIPC.ts` | Remote VM management via authenticated API |
| `libvirt-ui/config/local-vms.yaml` | Local VM template definitions |
| `api/src/LauncherApi/Controllers/VmController.cs` | VM API endpoints |
| `api/src/LauncherApi/Services/VmService.cs` | VM business logic (virsh, instance tracking) |
| `api/src/LauncherApi/Models/VmTemplate.cs` | Template model |
| `api/src/LauncherApi/Models/VmInstance.cs` | Instance model |
| `api/src/LauncherApi/config/vm-templates.json` | Server-side VM template config |

### Modified Files
| File | Change |
|------|--------|
| `libvirt-ui/src/ipc/libvirtIPC.ts` | **Delete** — replaced by localVmIPC + remoteVmIPC |
| `libvirt-ui/src/app/screens/vm-dashboard.tsx` | Rewrite with tabs, local + remote sections |
| `libvirt-ui/src/app/components/vm-card.tsx` | Update to handle both local and remote VM types |
| `libvirt-ui/src/main.ts` | Register new IPC handlers, remove old libvirtIPC |
| `libvirt-ui/src/app/screens/dashboard.tsx` | Fix `vms:list` bug, show both local + remote counts |
| `infrastructure/scripts/setup-workstation.sh` | Add VirtualBox installation |
