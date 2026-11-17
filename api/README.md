# Launcher API

ASP.NET Core 8 Web API with Negotiate (Kerberos/SPNEGO) authentication and
FreeIPA group-based authorization. Source lives in `src/LauncherApi/`, tests in
`tests/LauncherApi.Tests/` (`dotnet test`).

## FreeIPA group authorization

Kerberos says *who* the caller is. It does not say *what they may do*: FreeIPA
runs MIT Kerberos and issues no PAC, so unlike Active Directory the ticket
carries no group membership. The API therefore does a second lookup -- one LDAP
search of the user entry reads `memberOf`, which FreeIPA keeps fully expanded
so nested groups are already included -- and adds each group to the principal
as a role claim. Results are cached in memory for five minutes. If the
directory is unreachable the caller resolves to no groups, so gated endpoints
deny rather than allow.

The bind is SASL/GSSAPI using the API host's own Kerberos credentials, so no
directory password is stored anywhere. `infrastructure/scripts/setup-api.sh`
puts this in the systemd unit:

```ini
Environment=KRB5_CLIENT_KTNAME=/etc/krb5.keytab
Environment=KRB5CCNAME=FILE:/run/launcher-api/krb5cc
RuntimeDirectory=launcher-api
```

MIT Kerberos obtains and renews the ticket from that keytab on demand.

Three files do the work: `Services/IpaGroupService.cs` (the LDAP search),
`Authorization/IpaGroupsClaimsTransformation.cs` (groups onto the principal),
and the policy registration in `Program.cs`.

### Matching groups to actions

Policies live in `appsettings.json`, so group names are configuration rather
than code. Membership of any listed group satisfies the policy:

```jsonc
"Authorization": {
  "Policies": {
    "vm.view":      [ "launcher-users", "launcher-vm-users", "launcher-admins" ],
    "vm.manage":    [ "launcher-vm-users", "launcher-admins" ],
    "tools.view":   [ "launcher-users", "launcher-vm-users", "launcher-admins" ],
    "tools.launch": [ "launcher-users", "launcher-vm-users", "launcher-admins" ]
  }
}
```

Guarding an endpoint is then one attribute:

```csharp
[HttpPost("instances")]
[Authorize(Policy = LauncherPolicies.VmManage)]
public async Task<ActionResult<VmInstance>> CreateInstance(...)
```

Group names are also plain role claims, so these work too:

```csharp
[Authorize(Roles = "launcher-admins")]                       // on an action
if (User.IsInRole("launcher-admins")) { ... }                // inline
```

To add a policy, add it to `Authorization:Policies` and reference it by name.
Adding a constant to `LauncherPolicies` is only worth it when a controller
refers to it, so the name is checked at compile time.

### Groups in FreeIPA

The provisioning scripts create these; by hand it is:

```bash
kinit admin
ipa group-add launcher-users    --desc="Launcher: view tools and VMs"
ipa group-add launcher-vm-users --desc="Launcher: create and control VMs"
ipa group-add launcher-admins   --desc="Launcher: full access"

# Nesting needs no extra code, FreeIPA expands memberOf
ipa group-add-member launcher-users --groups=launcher-vm-users

ipa group-add-member launcher-vm-users --users=launcheruser
```

### Examples

Run `kinit <user>` first; `curl --negotiate -u :` then sends the ticket.

**What am I in, and what does it allow?** The launcher can call this at startup
and grey out whatever comes back false, instead of discovering the 403 after
the user clicks.

```bash
curl -sk --negotiate -u : https://api.lab.forge.local/api/user/groups | jq
```

```json
{
  "user": "launcheruser@LAB.FORGE.LOCAL",
  "groups": ["launcher-users", "launcher-vm-users"],
  "permissions": {
    "tools.launch": true,
    "tools.view": true,
    "vm.manage": true,
    "vm.view": true
  }
}
```

`testuser`, who is only in `launcher-users`, gets `"vm.manage": false`.

**A denied action.** `vm.manage` lists neither of `testuser`'s groups, so the
authorization middleware returns a bare 403 and the API log says why:

```bash
curl -sk --negotiate -u : -X POST \
  -H 'Content-Type: application/json' -d '{"templateId":"kali-2024"}' \
  -o /dev/null -w '%{http_code}\n' \
  https://api.lab.forge.local/api/vms/instances
```
```
403
```

**After changing a group.** Membership is cached for `FreeIpa:CacheSeconds`, so
an `ipa group-add-member` takes up to five minutes to show up. Restart the
service to apply it at once.

**Checking the lookup by hand** on the API host, which is the same search the
API runs:

```bash
sudo KRB5CCNAME=FILE:/tmp/t kinit -k -t /etc/krb5.keytab
sudo KRB5CCNAME=FILE:/tmp/t ldapsearch -Y GSSAPI -H ldaps://idm.lab.forge.local \
  -b "cn=users,cn=accounts,dc=lab,dc=forge,dc=local" "(uid=testuser)" memberOf
```

If that returns nothing, so will the API. Common causes are a missing ticket
for the host principal, the IPA CA not being trusted, or port 636 blocked.
A 401 rather than a 403 is authentication, not authorization: see the Kerberos
notes in `../docs/ARCHITECTURE.md`.

## Building a deployable artifact

The `Dockerfile` in this directory is **build-only**. Its final stage is
`scratch` -- the image is never meant to be run. It exists so you can
produce a self-contained `linux-x64` publish bundle (with the .NET runtime
included) without installing the .NET SDK on your machine.

From this directory:

```bash
docker build --target export --output type=local,dest=./out .
```

That drops a single file on your host:

```
./out/launcher-api.tar.gz
```

Upload that tarball to Artifactory (or any object store / file share).

### Build args

| Arg                  | Default                              | Notes                         |
| -------------------- | ------------------------------------ | ----------------------------- |
| `DOTNET_SDK_IMAGE`   | `mcr.microsoft.com/dotnet/sdk:8.0`   | Override to pin a patch level |
| `RUNTIME_IDENTIFIER` | `linux-x64`                          | e.g. `linux-arm64`            |

Example:

```bash
docker build \
  --build-arg RUNTIME_IDENTIFIER=linux-arm64 \
  --target export --output type=local,dest=./out .
```

## Deploying on a Linux host

No .NET install required on the target -- the runtime is bundled.

```bash
tar xzf launcher-api.tar.gz -C /opt
ASPNETCORE_URLS=http://0.0.0.0:5000 /opt/launcher-api/LauncherApi
```

A minimal systemd unit:

```ini
[Unit]
Description=Launcher API
After=network.target

[Service]
WorkingDirectory=/opt/launcher-api
ExecStart=/opt/launcher-api/LauncherApi
Environment=ASPNETCORE_URLS=http://0.0.0.0:5000
Environment=ASPNETCORE_ENVIRONMENT=Production
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Kerberos auth additionally requires a keytab on the host (e.g.
`Environment=KRB5_KTNAME=/etc/krb5.keytab.api`); see
`infrastructure/scripts/setup-api.sh` for the full provisioning flow.

## How the Dockerfile works

1. **`build` stage** (`mcr.microsoft.com/dotnet/sdk:8.0`) restores NuGet
   packages, then runs `dotnet publish -c Release -r $RID
   --self-contained true` and tars the output to
   `/launcher-api.tar.gz`.
2. **`export` stage** (`scratch`) contains only that tarball. With
   `--output type=local,dest=./out`, Docker writes the stage's contents
   directly to disk instead of building an image -- no layers are
   pushed anywhere.
