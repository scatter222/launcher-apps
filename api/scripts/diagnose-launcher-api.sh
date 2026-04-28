#!/usr/bin/env bash
# Diagnose why a self-contained .NET publish bundle (Launcher API)
# fails to load libhostfxr.so on a Linux host.
#
# Targets RHEL-family (SELinux + fapolicyd) but works on any Linux.
# Sudo is recommended -- some checks (audit logs, fapolicyd) need it.
#
# Usage:
#   scp api/scripts/diagnose-launcher-api.sh user@host:/tmp/
#   ssh user@host 'sudo bash /tmp/diagnose-launcher-api.sh [install-dir]'
#
# Default install dir: /opt/launcher-api
#
# Tee the output if you want to share it:
#   sudo bash /tmp/diagnose-launcher-api.sh 2>&1 | tee /tmp/launcher-diag.log

INSTALL_DIR="${1:-/opt/launcher-api}"
BINARY="${INSTALL_DIR}/LauncherApi"
LIBHOSTFXR=""
FINDINGS=()

note()    { FINDINGS+=("$1"); }
section() { printf '\n==========================================\n %s\n==========================================\n' "$1"; }
run()     { printf '$ %s\n' "$*"; "$@" 2>&1; local rc=$?; [ "$rc" -ne 0 ] && printf '  (exit %s)\n' "$rc"; printf '\n'; return 0; }

# ------------------------------------------------------------ system
section "System info"
run uname -a
[ -r /etc/os-release ] && run cat /etc/os-release
run id
[ "$(id -u)" -ne 0 ] && echo "WARN: not running as root -- audit / fapolicyd checks will be incomplete."

# ------------------------------------------------------------ install dir
section "Install directory: ${INSTALL_DIR}"
if [ ! -d "${INSTALL_DIR}" ]; then
    echo "ERROR: ${INSTALL_DIR} does not exist."
    note "install dir missing"
    exit 1
fi
run ls -la "${INSTALL_DIR}"
run df -h "${INSTALL_DIR}"

LIBHOSTFXR="$(find "${INSTALL_DIR}" -name 'libhostfxr.so' 2>/dev/null | head -1)"
if [ -z "${LIBHOSTFXR}" ]; then
    echo "WARN: libhostfxr.so not found under ${INSTALL_DIR}"
    note "libhostfxr.so missing -- bundle is incomplete or wrong RID"
else
    echo "Found: ${LIBHOSTFXR}"
    run ls -la "${LIBHOSTFXR}"
    run file "${LIBHOSTFXR}"
fi

if [ -e "${BINARY}" ]; then
    run ls -la "${BINARY}"
    run file "${BINARY}"
else
    echo "WARN: ${BINARY} not found"
    note "main binary missing"
fi

# ------------------------------------------------------------ mount opts
section "Mount options (noexec / nosuid?)"
if command -v findmnt >/dev/null 2>&1; then
    MOUNT_LINE="$(findmnt -T "${INSTALL_DIR}" -o SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null)"
    echo "${MOUNT_LINE}"
else
    MOUNT_LINE="$(df "${INSTALL_DIR}" | awk 'NR==2{print $1}' | xargs -I{} grep -E " {} " /proc/mounts 2>/dev/null)"
    echo "${MOUNT_LINE}"
fi
if echo "${MOUNT_LINE}" | grep -qw noexec; then
    note "filesystem at ${INSTALL_DIR} is mounted NOEXEC -- root cannot bypass this"
fi

# ------------------------------------------------------------ SELinux
section "SELinux"
if command -v getenforce >/dev/null 2>&1; then
    SE_MODE="$(getenforce 2>/dev/null || echo unknown)"
    echo "Mode: ${SE_MODE}"
    run sestatus
    [ -n "${LIBHOSTFXR}" ] && run ls -lZ "${LIBHOSTFXR}"
    run ls -ldZ "${INSTALL_DIR}"
    if command -v ausearch >/dev/null 2>&1; then
        echo "Recent AVC denials:"
        ausearch -m avc -ts recent 2>/dev/null | tail -40 || echo "(none)"
        echo
    fi
    if [ "${SE_MODE}" = "Enforcing" ] && [ -n "${LIBHOSTFXR}" ]; then
        CTX="$(ls -Z "${LIBHOSTFXR}" 2>/dev/null | awk '{print $1}')"
        case "${CTX}" in
            *lib_t*|*usr_t*|*bin_t*|system_u:object_r:*) : ;;
            *) note "SELinux context on libhostfxr.so is '${CTX}' -- likely needs restorecon" ;;
        esac
    fi
else
    echo "SELinux tools not present -- skipping."
fi

# ------------------------------------------------------------ fapolicyd
section "fapolicyd (RHEL file-access policy daemon)"
if command -v fapolicyd-cli >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q fapolicyd; then
    run systemctl is-active fapolicyd
    run systemctl status fapolicyd --no-pager --lines=5
    if command -v fapolicyd-cli >/dev/null 2>&1; then
        echo "Trust DB entries matching ${INSTALL_DIR}:"
        fapolicyd-cli --list 2>/dev/null | grep -F "${INSTALL_DIR}" || echo "(none -- bundle is NOT in trust DB)"
        echo
    fi
    if command -v ausearch >/dev/null 2>&1; then
        echo "Recent fanotify (fapolicyd) denials:"
        ausearch -m fanotify -ts recent 2>/dev/null | tail -40 || echo "(none)"
        echo
    fi
    if systemctl is-active --quiet fapolicyd 2>/dev/null; then
        note "fapolicyd is ACTIVE -- by default it only trusts /usr; ${INSTALL_DIR} is NOT trusted"
    fi
else
    echo "fapolicyd not installed -- skipping."
fi

# ------------------------------------------------------------ live load test
section "Live loader test"
if [ -x "${BINARY}" ]; then
    echo "ldd on binary:"
    run ldd "${BINARY}"
    [ -n "${LIBHOSTFXR}" ] && { echo "ldd on libhostfxr.so:"; run ldd "${LIBHOSTFXR}"; }

    echo "Launching binary (3s timeout) to capture the real error:"
    timeout 3 "${BINARY}" 2>&1 | head -30
    printf '\n'

    if command -v strace >/dev/null 2>&1; then
        echo "strace -- look for EPERM/EACCES on libhostfxr or any .so:"
        timeout 3 strace -f -e openat "${BINARY}" 2>&1 \
            | grep -E 'libhostfxr|\.so.*(EPERM|EACCES|ENOENT)' \
            | tail -30
        echo
    fi
else
    echo "Binary not executable -- skipping."
fi

# ------------------------------------------------------------ kernel
section "Recent kernel messages"
if command -v dmesg >/dev/null 2>&1; then
    dmesg -T 2>/dev/null | tail -30 || dmesg | tail -30
fi

# ------------------------------------------------------------ verdict
section "Verdict"
if [ ${#FINDINGS[@]} -eq 0 ]; then
    echo "No obvious culprits matched. Run the binary as the service user,"
    echo "then re-run this script -- audit logs may capture a fresh denial."
    exit 0
fi

echo "Likely culprits, in order:"
printf '  - %s\n' "${FINDINGS[@]}"
echo
echo "Suggested fixes (run as root):"
for f in "${FINDINGS[@]}"; do
    case "${f}" in
        *NOEXEC*)
            cat <<EOF
  # noexec on ${INSTALL_DIR}: install elsewhere or remount
  #   re-extract under /usr/local/launcher-api/ (typically not noexec)
  #   OR: edit /etc/fstab to drop noexec on the target mount, then:
  #       mount -o remount /<mount-point>
EOF
            ;;
        *fapolicyd*)
            cat <<EOF
  # fapolicyd is blocking ${INSTALL_DIR}: add to trust DB
  fapolicyd-cli --file add ${INSTALL_DIR}/
  fapolicyd-cli --update
  systemctl restart fapolicyd
EOF
            ;;
        *SELinux*|*restorecon*)
            cat <<EOF
  # SELinux: relabel the bundle
  restorecon -Rv ${INSTALL_DIR}
  # if still denied, label as bin/lib so it can be mmap'd executable:
  semanage fcontext -a -t bin_t '${INSTALL_DIR}(/.*)?'
  restorecon -Rv ${INSTALL_DIR}
EOF
            ;;
    esac
    echo
done
