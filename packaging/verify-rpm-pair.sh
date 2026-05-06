#!/usr/bin/env bash
# verify-rpm-pair.sh -- sanity-check two RPMs for install-time collisions
# before you actually try `rpm -i` on them.
#
# Usage:
#   bash verify-rpm-pair.sh path/to/app-one.rpm path/to/app-two.rpm
#
# Exits 0 if the two RPMs can coexist on the same host, 1 otherwise.
# Prints details of any collisions: identical Names, overlapping file
# paths, or shared /usr/lib/.build-id/... entries.

set -u

if [ $# -ne 2 ]; then
    printf 'Usage: %s <rpm-a> <rpm-b>\n' "$0" >&2
    exit 2
fi

A="$1"
B="$2"

for f in "$A" "$B"; do
    if [ ! -r "$f" ]; then
        printf 'cannot read %s\n' "$f" >&2
        exit 2
    fi
done

if ! command -v rpm >/dev/null 2>&1; then
    printf 'rpm command not found -- install rpm\n' >&2
    exit 2
fi

if [ -t 1 ]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; NC=$'\033[0m'
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; NC=""
fi

PROBLEMS=0
problem() { PROBLEMS=$((PROBLEMS + 1)); printf '  %s[FAIL]%s %s\n' "$RED" "$NC" "$1"; }
ok()      { printf '  %s[OK]%s   %s\n' "$GREEN" "$NC" "$1"; }
warn()    { printf '  %s[WARN]%s %s\n' "$YELLOW" "$NC" "$1"; }

section() { printf '\n%s== %s ==%s\n' "$BOLD" "$1" "$NC"; }

NAME_A="$(rpm -qp --queryformat '%{NAME}' "$A" 2>/dev/null)"
NAME_B="$(rpm -qp --queryformat '%{NAME}' "$B" 2>/dev/null)"
VER_A="$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$A" 2>/dev/null)"
VER_B="$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$B" 2>/dev/null)"

section "Package identity"
printf '  A: %s  (%s)  -- %s\n' "$NAME_A" "$VER_A" "$A"
printf '  B: %s  (%s)  -- %s\n' "$NAME_B" "$VER_B" "$B"

if [ "$NAME_A" = "$NAME_B" ]; then
    problem "both RPMs have Name: $NAME_A -- the second install is treated as an upgrade, not a parallel install"
else
    ok "distinct Name: fields"
fi

section "Provides"
PROV_A="$(rpm -qp --provides "$A" 2>/dev/null | sort -u)"
PROV_B="$(rpm -qp --provides "$B" 2>/dev/null | sort -u)"
SHARED_PROV="$(comm -12 <(printf '%s\n' "$PROV_A") <(printf '%s\n' "$PROV_B") \
    | grep -vE '^$|^rpmlib\(' || true)"
if [ -n "$SHARED_PROV" ]; then
    problem "both RPMs Provides: the same capabilities:"
    printf '%s\n' "$SHARED_PROV" | sed 's/^/      /'
else
    ok "no overlapping Provides:"
fi

section "File path collisions"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
rpm -qpl "$A" 2>/dev/null | sort -u > "$TMP/a.txt"
rpm -qpl "$B" 2>/dev/null | sort -u > "$TMP/b.txt"

ALL_OVERLAP="$(comm -12 "$TMP/a.txt" "$TMP/b.txt")"

# Separate build-id symlinks from "real" file collisions.
BUILD_ID_OVERLAP="$(printf '%s\n' "$ALL_OVERLAP" | grep -E '^/usr/lib/\.build-id/' || true)"
OTHER_OVERLAP="$(printf '%s\n' "$ALL_OVERLAP" | grep -vE '^/usr/lib/\.build-id/|^$' || true)"

if [ -n "$BUILD_ID_OVERLAP" ]; then
    BID_COUNT="$(printf '%s\n' "$BUILD_ID_OVERLAP" | wc -l)"
    problem "$BID_COUNT shared /usr/lib/.build-id/ entries -- classic Electron-fork issue"
    printf '%s\n' "$BUILD_ID_OVERLAP" | head -5 | sed 's/^/      /'
    [ "$BID_COUNT" -gt 5 ] && printf '      ... and %s more\n' "$((BID_COUNT - 5))"
    printf '\n  %sFix:%s add to ~/.rpmmacros and rebuild:\n' "$BOLD" "$NC"
    printf '    echo %%_build_id_links none >> ~/.rpmmacros\n'
    printf '    npm run make    # or yarn make / electron-forge make\n'
    printf '\n  See packaging/forge.config.example.js for the Forge-hook version.\n'
fi

if [ -n "$OTHER_OVERLAP" ]; then
    OTH_COUNT="$(printf '%s\n' "$OTHER_OVERLAP" | wc -l)"
    # Plain directory entries (e.g. /usr/share) often legitimately overlap.
    # Filter them out for the headline count.
    NONDIR_OVERLAP="$(printf '%s\n' "$OTHER_OVERLAP" | while read -r p; do
        # If both RPMs ship this as a directory, skip it.
        AD="$(rpm -qp --queryformat '[%{FILENAMES} %{FILEMODES:perms}\n]' "$A" 2>/dev/null \
            | awk -v p="$p" '$1 == p {print $2; exit}')"
        BD="$(rpm -qp --queryformat '[%{FILENAMES} %{FILEMODES:perms}\n]' "$B" 2>/dev/null \
            | awk -v p="$p" '$1 == p {print $2; exit}')"
        if [ "${AD:0:1}" = 'd' ] && [ "${BD:0:1}" = 'd' ]; then
            continue
        fi
        printf '%s\n' "$p"
    done)"

    if [ -n "$NONDIR_OVERLAP" ]; then
        NDC="$(printf '%s\n' "$NONDIR_OVERLAP" | wc -l)"
        problem "$NDC non-directory file path(s) ship in BOTH RPMs:"
        printf '%s\n' "$NONDIR_OVERLAP" | head -10 | sed 's/^/      /'
        [ "$NDC" -gt 10 ] && printf '      ... and %s more\n' "$((NDC - 10))"
        printf '\n  %sFix:%s use distinct values in forge.config.js for:\n' "$BOLD" "$NC"
        printf '    - packagerConfig.name / executableName\n'
        printf '    - makers[@electron-forge/maker-rpm].config.options.name\n'
        printf '    - makers[@electron-forge/maker-rpm].config.options.bin\n'
        printf '    - makers[@electron-forge/maker-rpm].config.options.productName\n'
    elif [ -z "$BUILD_ID_OVERLAP" ]; then
        ok "no real file collisions (only directory entries overlap)"
    fi
elif [ -z "$BUILD_ID_OVERLAP" ]; then
    ok "no overlapping files at all"
fi

section "Verdict"
if [ "$PROBLEMS" -eq 0 ]; then
    printf '  %sBoth RPMs can be installed side by side.%s\n' "$GREEN" "$NC"
    printf '\n  Try it:\n'
    printf '    sudo rpm -i %s %s\n' "$A" "$B"
    exit 0
else
    printf '  %s%d collision(s) detected -- rpm -i will refuse the second install.%s\n' \
        "$RED" "$PROBLEMS" "$NC"
    exit 1
fi
