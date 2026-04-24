# Launcher API

ASP.NET Core 8 Web API with Negotiate (Kerberos/SPNEGO) authentication.
Source lives in `src/LauncherApi/`.

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
