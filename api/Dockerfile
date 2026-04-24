# Build-only container for the Launcher API.
#
# Produces a self-contained linux-x64 publish bundle (the .NET runtime is
# included), packaged as a tarball, so the artifact runs on any modern
# glibc Linux host without requiring .NET to be installed. The final
# stage is `scratch` -- this image is never meant to be run, only used
# to export the build output.
#
# Build (from the api/ directory):
#   docker build --target export --output type=local,dest=./out .
#
# Output:
#   ./out/launcher-api.tar.gz
#
# Upload ./out/launcher-api.tar.gz to Artifactory, then on the target host:
#   tar xzf launcher-api.tar.gz -C /opt
#   ASPNETCORE_URLS=http://0.0.0.0:5000 /opt/launcher-api/LauncherApi
#
# Override the target architecture or SDK image with --build-arg:
#   docker build --build-arg RUNTIME_IDENTIFIER=linux-arm64 ...

ARG DOTNET_SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:8.0
ARG RUNTIME_IDENTIFIER=linux-x64

FROM ${DOTNET_SDK_IMAGE} AS build
ARG RUNTIME_IDENTIFIER
WORKDIR /src

# Restore in its own layer so the NuGet cache survives source-only changes.
COPY src/LauncherApi/LauncherApi.csproj src/LauncherApi/
RUN dotnet restore src/LauncherApi/LauncherApi.csproj -r "${RUNTIME_IDENTIFIER}"

COPY . .

RUN dotnet publish src/LauncherApi/LauncherApi.csproj \
        -c Release \
        -r "${RUNTIME_IDENTIFIER}" \
        --self-contained true \
        --no-restore \
        -o /out/launcher-api \
 && tar -C /out -czf /launcher-api.tar.gz launcher-api

# Export stage: nothing but the artifact, so `--output type=local` drops
# the tarball straight onto the host without any image layers to push.
FROM scratch AS export
COPY --from=build /launcher-api.tar.gz /launcher-api.tar.gz
