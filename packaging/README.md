# RPM packaging notes

Reference material for shipping the libvirt-ui-derived Electron apps as
RPMs that can coexist on the same host.

## The problem

Two apps forked from libvirt-ui (or any common Electron base) will share
bit-identical Electron framework binaries. RPM auto-generates symlinks
under `/usr/lib/.build-id/<aa>/<bbbbbb...>` for every ELF file. When both
RPMs try to lay down the same symlink, `rpm -i` aborts the second install
with:

```
file /usr/lib/.build-id/3f/abc... from install of app-two-1.0
conflicts with file from package app-one-1.0
```

This is a packaging-metadata collision, not a real conflict.

## The fix (Electron Forge)

Tell `rpmbuild` not to generate the `.build-id` symlinks. The macro is
`%_build_id_links none`, and `rpmbuild` reads it from `~/.rpmmacros`.

`@electron-forge/maker-rpm` does not expose this directly, so write the
macro file from a Forge `generateAssets` hook -- the maker reads it at
build time without any further plumbing.

See [`forge.config.example.js`](./forge.config.example.js) for a
complete, annotated example. Copy the `hooks.generateAssets` and the
`MakerRpm` `options` block into each app's real `forge.config.js`,
edit the `APP` constants, then `npm run make`.

## The other half: distinct package identity

Disabling build-id links is necessary but not sufficient. If both forks
kept the same `name`, `executableName`, or `bin` from the libvirt-ui
template, you'll still hit normal file path collisions
(`/usr/bin/foo`, `/usr/lib/foo/`, etc.).

Each app must have distinct values for at least:

- `packagerConfig.name`
- `packagerConfig.executableName`
- `MakerRpm.config.options.name`
- `MakerRpm.config.options.productName`
- `MakerRpm.config.options.bin`

The example config makes this explicit via a single `APP` constant at
the top -- bumping it per app is one edit.

## Verifying before you install

[`verify-rpm-pair.sh`](./verify-rpm-pair.sh) takes two RPMs and reports
whether they can be installed side by side. It checks identical `Name:`,
overlapping `Provides:`, shared file paths, and the build-id symlink
case explicitly:

```bash
bash packaging/verify-rpm-pair.sh \
    out/make/rpm/x64/app-one-1.0.0-1.x86_64.rpm \
    out/make/rpm/x64/app-two-1.0.0-1.x86_64.rpm
```

Exit 0 means safe to install both with `rpm -i`. Exit 1 means it found
something; the script tells you what and how to fix it.

## Background

`%_build_id_links` controls how RPM's `find-debuginfo.sh` step stitches
ELF Build-IDs into the package. Possible values:

| Value | Behavior |
| --- | --- |
| `none` | No symlinks. Simplest, recommended for Electron apps that don't ship debuginfo subpackages. |
| `alldebug` | Symlinks live in the `-debuginfo` subpackage only (Fedora's default since 2017). Use if you actually ship debuginfo. |
| `compat` | Both layouts; can still collide. |

`none` is the right call here -- Electron apps don't typically ship
useful debuginfo, and the symlinks are the entire source of the
collision.
