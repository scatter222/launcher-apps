#!/usr/bin/env bash
# diagnose-kerberos-auth.sh -- end-to-end Kerberos / FreeIPA diagnostic
# for the Launcher API. Read-only; never mutates system state. Prints a
# verdict and copy-paste remediation commands.
#
# Run on the IPA-enrolled host that runs the API, as root:
#   sudo bash diagnose-kerberos-auth.sh
#
# Handles the common case where the API is reached via a virtual hostname
# (the SPN host) that is different from the physical machine's FQDN
# (the enrolled host). Example:
#   --enrolled-host sensor01.main.system   # this physical box, in /etc/krb5.keytab
#   --service-host  launchpad.main.system  # SPN: HTTP/launchpad.main.system
#
# Auto-detected defaults (override with the flags below):
#   --enrolled-host    hostname -f
#   --service-host     same as --enrolled-host (single-name deployment)
#   --realm            default_realm in /etc/krb5.conf, then /etc/ipa/default.conf
#   --ipa-server       server in /etc/ipa/default.conf, then KDC in krb5.conf
#   --keytab           KRB5_KTNAME from launcher-api.service, default /etc/krb5.keytab.api
#   --service-class    HTTP
#
# Tee for sharing:
#   sudo bash diagnose-kerberos-auth.sh 2>&1 | tee /tmp/krb-diag.log

set -u
LC_ALL=C
export LC_ALL

# ----------------------------------------------------------- args
ENROLLED_OVERRIDE=""
SERVICE_OVERRIDE=""
REALM_OVERRIDE=""
IPA_SERVER_OVERRIDE=""
KEYTAB_OVERRIDE=""
SERVICE_CLASS="HTTP"

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --enrolled-host)  ENROLLED_OVERRIDE="$2"; shift 2 ;;
        --service-host)   SERVICE_OVERRIDE="$2";  shift 2 ;;
        --realm)          REALM_OVERRIDE="$2";    shift 2 ;;
        --ipa-server)     IPA_SERVER_OVERRIDE="$2"; shift 2 ;;
        --keytab)         KEYTAB_OVERRIDE="$2";   shift 2 ;;
        --service-class)  SERVICE_CLASS="$2";     shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) printf 'Unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

# ----------------------------------------------------------- TTY/colors
if [ -t 1 ]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; BLUE=$'\033[34m'; NC=$'\033[0m'
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

PROBLEMS=()
problem() { PROBLEMS+=("$1"); }

section() {
    printf '\n%s==========================================%s\n' "$BLUE" "$NC"
    printf '%s %s%s\n' "$BLUE" "$1" "$NC"
    printf '%s==========================================%s\n' "$BLUE" "$NC"
}
ok()    { printf '  %s[OK]%s    %s\n' "$GREEN"  "$NC" "$1"; }
warn()  { printf '  %s[WARN]%s  %s\n' "$YELLOW" "$NC" "$1"; }
fail()  { printf '  %s[FAIL]%s  %s\n' "$RED"    "$NC" "$1"; }
info()  { printf '          %s\n' "$1"; }
runv()  { printf '  $ %s\n' "$*"; "$@" 2>&1 | sed 's/^/      /'; return ${PIPESTATUS[0]}; }

# ----------------------------------------------------------- isolate cred cache
# Run kinit/etc. into a private credential cache so we never disturb the
# user's existing TGT (e.g. an admin shell open in another window).
DIAG_CC="$(mktemp -u /tmp/krb-diag-cc.XXXXXX)"
export KRB5CCNAME="FILE:${DIAG_CC}"
cleanup() { kdestroy -c "FILE:${DIAG_CC}" 2>/dev/null || true; rm -f "${DIAG_CC}"; }
trap cleanup EXIT

# ----------------------------------------------------------- detect defaults
DETECTED_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
ENROLLED_HOST="${ENROLLED_OVERRIDE:-$DETECTED_HOSTNAME}"
SERVICE_HOST="${SERVICE_OVERRIDE:-$ENROLLED_HOST}"

DETECTED_REALM=""
[ -r /etc/krb5.conf ] && DETECTED_REALM="$(awk -F= '
    /^[[:space:]]*default_realm[[:space:]]*=/ { gsub(/[[:space:]]/,"",$2); print $2; exit }
' /etc/krb5.conf)"
if [ -z "$DETECTED_REALM" ] && [ -r /etc/ipa/default.conf ]; then
    DETECTED_REALM="$(awk -F= '
        /^realm[[:space:]]*=/ { gsub(/[[:space:]]/,"",$2); print $2; exit }
    ' /etc/ipa/default.conf)"
fi
REALM="${REALM_OVERRIDE:-${DETECTED_REALM:-}}"

DETECTED_IPA_SERVER=""
[ -r /etc/ipa/default.conf ] && DETECTED_IPA_SERVER="$(awk -F= '
    /^server[[:space:]]*=/ { gsub(/[[:space:]]/,"",$2); print $2; exit }
' /etc/ipa/default.conf)"
if [ -z "$DETECTED_IPA_SERVER" ] && [ -r /etc/krb5.conf ]; then
    DETECTED_IPA_SERVER="$(awk '/kdc[[:space:]]*=/{print $NF; exit}' /etc/krb5.conf)"
fi
IPA_SERVER="${IPA_SERVER_OVERRIDE:-${DETECTED_IPA_SERVER:-}}"

DETECTED_KEYTAB=""
for svc in /etc/systemd/system/launcher-api.service /usr/lib/systemd/system/launcher-api.service; do
    [ -r "$svc" ] || continue
    DETECTED_KEYTAB="$(awk -F= '/KRB5_KTNAME/{print $NF; exit}' "$svc" | tr -d '" ')"
    [ -n "$DETECTED_KEYTAB" ] && break
done
KEYTAB="${KEYTAB_OVERRIDE:-${DETECTED_KEYTAB:-/etc/krb5.keytab.api}}"

SPN="${SERVICE_CLASS}/${SERVICE_HOST}"
SPN_REALM="${SPN}@${REALM}"
HOST_PRINC="host/${ENROLLED_HOST}@${REALM}"

# ----------------------------------------------------------- header
section "Launcher API Kerberos / IPA Diagnostic"
printf '  Enrolled host (this box) : %s\n' "$ENROLLED_HOST"
printf '  Service host (SPN host)  : %s\n' "$SERVICE_HOST"
printf '  Realm                    : %s\n' "${REALM:-<unknown>}"
printf '  IPA server               : %s\n' "${IPA_SERVER:-<unknown>}"
printf '  Service SPN              : %s\n' "$SPN_REALM"
printf '  Service keytab           : %s\n' "$KEYTAB"
printf '  Host principal           : %s\n' "$HOST_PRINC"
[ "$ENROLLED_HOST" != "$SERVICE_HOST" ] && \
    info "(virtual SPN deployment: kinit'ing as host/${ENROLLED_HOST} to fetch HTTP/${SERVICE_HOST})"

if [ "$(id -u)" -ne 0 ]; then
    warn "not running as root -- keytab reads, kinit, and ipa-getkeytab will fail"
    warn "re-run with: sudo bash $0"
    problem "script not run as root"
fi

# ----------------------------------------------------------- 1. tools
section "1. Required tools"
TOOLS_MISSING=0
for t in klist kinit kdestroy kvno ipa-getkeytab ipa awk getent host chronyc curl; do
    if command -v "$t" >/dev/null 2>&1; then
        ok "$t"
    else
        fail "$t not found"
        TOOLS_MISSING=1
    fi
done
[ "$TOOLS_MISSING" = 1 ] && \
    problem "missing required tools (install krb5-workstation, ipa-client, bind-utils, chrony, curl)"

# ----------------------------------------------------------- 2. krb5.conf
section "2. /etc/krb5.conf"
if [ ! -r /etc/krb5.conf ]; then
    fail "/etc/krb5.conf missing or unreadable"
    problem "/etc/krb5.conf missing"
else
    if [ -n "$DETECTED_REALM" ]; then
        ok "default_realm = $DETECTED_REALM"
    else
        fail "no default_realm in [libdefaults]"
        problem "/etc/krb5.conf has no default_realm"
    fi

    KDC_LINES="$(awk -v realm="$REALM" '
        $0 ~ "^[[:space:]]*"realm"[[:space:]]*=[[:space:]]*\\{" { in_realm=1; next }
        in_realm && /^[[:space:]]*\\}/ { in_realm=0 }
        in_realm && /kdc[[:space:]]*=/ { print $NF }
    ' /etc/krb5.conf)"
    if [ -n "$KDC_LINES" ]; then
        info "KDC entries for $REALM:"
        printf '%s\n' "$KDC_LINES" | sed 's/^/      /'
    else
        warn "no [realms] block for $REALM (OK only if SRV records resolve)"
    fi

    if grep -qE 'dns_canonicalize_hostname[[:space:]]*=[[:space:]]*false' /etc/krb5.conf; then
        ok "dns_canonicalize_hostname = false (recommended)"
    else
        warn "dns_canonicalize_hostname not set to false"
        warn "  -- with virtual SPN hostnames (CNAMEs) this often causes SPN mismatches"
        problem "krb5.conf should set dns_canonicalize_hostname = false"
    fi
    if grep -qE 'rdns[[:space:]]*=[[:space:]]*false' /etc/krb5.conf; then
        ok "rdns = false (recommended)"
    else
        warn "rdns not set to false -- reverse DNS will be used to resolve SPN"
    fi
fi

# ----------------------------------------------------------- 3. IPA client
section "3. IPA client config"
if [ -r /etc/ipa/default.conf ]; then
    ok "/etc/ipa/default.conf exists -- host appears IPA-enrolled"
    grep -E '^(realm|domain|server|xmlrpc_uri)[[:space:]]*=' /etc/ipa/default.conf | sed 's/^/      /'
else
    warn "/etc/ipa/default.conf missing -- ipa-client-install was not run on this host"
    problem "host not IPA-enrolled (no /etc/ipa/default.conf)"
fi

# ----------------------------------------------------------- 4. DNS
section "4. DNS"
check_dns() {
    local name="$1" label="$2"
    if getent hosts "$name" >/dev/null 2>&1; then
        local ip; ip="$(getent hosts "$name" | awk '{print $1; exit}')"
        ok "$label '$name' resolves to $ip"
        local rev; rev="$(getent hosts "$ip" 2>/dev/null | awk '{print $2; exit}')"
        if [ -n "$rev" ] && [ "$rev" != "$name" ]; then
            warn "  reverse DNS for $ip returns '$rev' (forward was '$name')"
            warn "  this triggers SPN canonicalization issues unless rdns=false"
        fi
        printf '%s' "$ip"
    else
        fail "$label '$name' does NOT resolve"
        problem "DNS for $label '$name' fails"
        printf ''
    fi
}
ENROLLED_IP="$(check_dns "$ENROLLED_HOST" 'enrolled host')"
if [ "$ENROLLED_HOST" != "$SERVICE_HOST" ]; then
    SERVICE_IP="$(check_dns "$SERVICE_HOST" 'service host')"
    if [ -n "$ENROLLED_IP" ] && [ -n "$SERVICE_IP" ] && [ "$ENROLLED_IP" != "$SERVICE_IP" ]; then
        warn "service host and enrolled host resolve to different IPs ($SERVICE_IP vs $ENROLLED_IP)"
        warn "  the API runs on $ENROLLED_IP but clients hit $SERVICE_IP -- traffic will not arrive"
        problem "service-host DNS does not point at this machine"
    elif [ "$ENROLLED_IP" = "$SERVICE_IP" ]; then
        ok "service host points at this machine"
    fi
fi
[ -n "$IPA_SERVER" ] && check_dns "$IPA_SERVER" 'IPA server' >/dev/null

# ----------------------------------------------------------- 5. clock
section "5. Clock sync (Kerberos requires within ~5 min)"
if command -v chronyc >/dev/null 2>&1; then
    if chronyc tracking >/dev/null 2>&1; then
        OFFSET="$(chronyc tracking 2>/dev/null | awk -F: '/Last offset/{print $2}' | xargs)"
        info "chrony last offset: ${OFFSET:-?}"
        ok "chronyd is responding"
    else
        warn "chronyd not running or not configured"
    fi
else
    warn "chronyc not installed"
fi

# ----------------------------------------------------------- 6. host keytab
section "6. Host keytab (/etc/krb5.keytab)"
HOST_KEYTAB_OK=0
if [ ! -r /etc/krb5.keytab ]; then
    fail "/etc/krb5.keytab missing or unreadable"
    problem "host keytab missing -- ipa-client-install incomplete"
else
    ok "/etc/krb5.keytab readable"
    HKE="$(klist -kt /etc/krb5.keytab 2>/dev/null)"
    info "Entries:"; printf '%s\n' "$HKE" | sed 's/^/      /'
    if printf '%s' "$HKE" | grep -q "host/${ENROLLED_HOST}"; then
        ok "contains host/${ENROLLED_HOST}"
        HOST_KEYTAB_OK=1
    else
        fail "no entry for host/${ENROLLED_HOST}"
        problem "host keytab does not contain host/${ENROLLED_HOST}"
    fi
fi

# ----------------------------------------------------------- 7. service keytab
section "7. Service keytab ($KEYTAB)"
SERVICE_KEYTAB_OK=0
if [ ! -e "$KEYTAB" ]; then
    fail "$KEYTAB does not exist"
    problem "service keytab $KEYTAB missing -- ipa-getkeytab not yet run successfully"
elif [ ! -r "$KEYTAB" ]; then
    fail "$KEYTAB exists but is unreadable (perms?)"
    runv ls -la "$KEYTAB"
    problem "service keytab unreadable"
else
    ok "$KEYTAB exists and readable"
    runv ls -la "$KEYTAB"
    SKE="$(klist -kt "$KEYTAB" 2>/dev/null)"
    info "Entries:"; printf '%s\n' "$SKE" | sed 's/^/      /'
    if printf '%s' "$SKE" | grep -q "${SPN}@"; then
        ok "contains ${SPN}"
        SERVICE_KEYTAB_OK=1
    else
        fail "no entry for ${SPN}"
        problem "service keytab missing ${SPN} (wrong principal fetched, case mismatch, or different SPN)"
    fi
fi

# ----------------------------------------------------------- 8. host TGT
section "8. Acquire host TGT for IPA queries"
TGT_OK=0
if [ "$HOST_KEYTAB_OK" = 1 ]; then
    if kinit -kt /etc/krb5.keytab "host/${ENROLLED_HOST}" 2>&1 | sed 's/^/      /'; then
        ok "kinit as host/${ENROLLED_HOST} succeeded"
        TGT_OK=1
        runv klist
    else
        fail "kinit as host/${ENROLLED_HOST} failed"
        problem "host TGT could not be acquired (KVNO drift between host keytab and KDC?)"
    fi
else
    warn "skipped (host keytab unusable)"
fi

# ----------------------------------------------------------- 9. IPA queries
section "9. IPA queries for ${SPN}"
SERVICE_IN_IPA=0
ALLOW_OK=0
if [ "$TGT_OK" = 1 ] && command -v ipa >/dev/null 2>&1; then
    info "exact-match (ipa service-show ${SPN}):"
    SHOW_OUT="$(ipa service-show "${SPN}" 2>&1)"
    SHOW_RC=$?
    printf '%s\n' "$SHOW_OUT" | sed 's/^/      /'
    if [ "$SHOW_RC" = 0 ]; then
        ok "service ${SPN} exists in IPA"
        SERVICE_IN_IPA=1
        if printf '%s' "$SHOW_OUT" | grep -qiE 'allowed to retrieve keytab'; then
            ALLOWED="$(printf '%s' "$SHOW_OUT" | awk -F: '/[Aa]llowed to retrieve/{print $2}' | xargs)"
            info "Hosts allowed to retrieve keytab: ${ALLOWED:-<none>}"
            if printf '%s' "$ALLOWED" | grep -qw "$ENROLLED_HOST"; then
                ok "${ENROLLED_HOST} is permitted to retrieve this keytab"
                ALLOW_OK=1
            else
                fail "${ENROLLED_HOST} is NOT in allowed-retrieve list"
                problem "host ${ENROLLED_HOST} not in service-allow-retrieve-keytab list for ${SPN}"
            fi
        else
            warn "no 'allowed to retrieve keytab' line on service -- only admins can fetch"
            problem "service has no allow-retrieve permission set"
        fi
    else
        fail "service ${SPN} not found via ipa service-show"
        problem "service ${SPN} does not exist in IPA (case/realm/typo?)"
    fi

    info "substring search (ipa service-find ${SERVICE_CLASS}/${SERVICE_HOST}):"
    ipa service-find "${SERVICE_CLASS}/${SERVICE_HOST}" 2>&1 | sed 's/^/      /'

    info "lowercase sanity check (ipa service-find http/${SERVICE_HOST}):"
    LO="$(ipa service-find "http/${SERVICE_HOST}" 2>&1)"
    printf '%s\n' "$LO" | sed 's/^/      /'
    if printf '%s' "$LO" | grep -qE '[1-9][0-9]* services? matched'; then
        warn "lowercase 'http/' returned matches -- you may have a case-mismatched principal"
        problem "possible case-mismatched service principal (http/ vs HTTP/)"
    fi

    if [ "$ENROLLED_HOST" != "$SERVICE_HOST" ]; then
        info "host record for SPN host (ipa host-show ${SERVICE_HOST}):"
        if ipa host-show "${SERVICE_HOST}" 2>&1 | sed 's/^/      /'; then
            ok "host ${SERVICE_HOST} exists in IPA (required for the service principal)"
        else
            fail "host ${SERVICE_HOST} does NOT exist in IPA"
            problem "virtual host ${SERVICE_HOST} missing -- run: ipa host-add ${SERVICE_HOST} --force"
        fi
    fi
else
    warn "skipping IPA queries (no TGT or ipa CLI absent)"
fi

# ----------------------------------------------------------- 10. ipa-getkeytab dry run
section "10. ipa-getkeytab dry run (writes to /tmp, then deletes)"
DRY_KT="$(mktemp -u /tmp/krb-diag.XXXXXX.keytab)"
if [ "$TGT_OK" = 1 ] && [ -n "$IPA_SERVER" ] && command -v ipa-getkeytab >/dev/null 2>&1; then
    info "trying: ipa-getkeytab -s $IPA_SERVER -p ${SPN_REALM} -k $DRY_KT"
    if ipa-getkeytab -s "$IPA_SERVER" -p "${SPN_REALM}" -k "$DRY_KT" 2>&1 | sed 's/^/      /'; then
        ok "ipa-getkeytab succeeded"
        runv klist -kt "$DRY_KT"
    else
        fail "ipa-getkeytab failed -- error text above is the actual cause"
        problem "ipa-getkeytab fails to fetch ${SPN_REALM}"
    fi
    rm -f "$DRY_KT"
else
    warn "skipped (no TGT, missing ipa-server, or tool absent)"
fi

# ----------------------------------------------------------- 11. KVNO sync
section "11. KVNO sync (keytab vs KDC)"
if [ "$SERVICE_KEYTAB_OK" = 1 ] && [ "$TGT_OK" = 1 ]; then
    KEYTAB_KVNO="$(klist -kt "$KEYTAB" 2>/dev/null | awk -v spn="$SPN" '$0 ~ spn {v=$1} END{print v}')"
    info "Highest KVNO in $KEYTAB for $SPN: ${KEYTAB_KVNO:-?}"
    if KOUT="$(kvno "${SPN}" 2>&1)"; then
        info "kvno reply: $KOUT"
        KDC_KVNO="$(printf '%s' "$KOUT" | sed -n 's/.*kvno = \([0-9][0-9]*\).*/\1/p' | head -1)"
        if [ -n "$KEYTAB_KVNO" ] && [ -n "$KDC_KVNO" ] && [ "$KEYTAB_KVNO" = "$KDC_KVNO" ]; then
            ok "KVNO matches ($KEYTAB_KVNO)"
        else
            fail "KVNO mismatch: keytab=$KEYTAB_KVNO KDC=$KDC_KVNO"
            problem "KVNO mismatch -- regenerate the service keytab"
        fi
    else
        fail "kvno query failed: $KOUT"
        problem "kvno query failed (KDC unreachable, principal absent, or DNS)"
    fi
else
    warn "skipped (no usable service keytab or no host TGT)"
fi

# ----------------------------------------------------------- 12. self-auth
section "12. Self-auth test (kinit using the service keytab)"
if [ "$SERVICE_KEYTAB_OK" = 1 ]; then
    kdestroy 2>/dev/null || true
    if kinit -kt "$KEYTAB" "${SPN}" 2>&1 | sed 's/^/      /'; then
        ok "service can authenticate as ${SPN}"
        runv klist
    else
        fail "kinit -kt $KEYTAB ${SPN} failed -- keytab/KDC inconsistency"
        problem "service cannot self-auth with its own keytab"
    fi
    kdestroy 2>/dev/null || true
else
    warn "skipped (no usable service keytab)"
fi

# ----------------------------------------------------------- 13. systemd
section "13. launcher-api systemd service"
if systemctl list-unit-files 2>/dev/null | grep -q '^launcher-api.service'; then
    runv systemctl is-active launcher-api
    runv systemctl is-enabled launcher-api
    info "Environment in unit:"
    systemctl show launcher-api -p Environment --value 2>/dev/null | tr ' ' '\n' | sed 's/^/      /'
    if systemctl show launcher-api -p Environment --value 2>/dev/null | grep -q "KRB5_KTNAME=$KEYTAB"; then
        ok "service is configured with KRB5_KTNAME=$KEYTAB"
    else
        warn "KRB5_KTNAME in unit doesn't match $KEYTAB -- service may read a different keytab"
    fi
else
    warn "launcher-api.service not installed"
fi

# ----------------------------------------------------------- VERDICT
section "VERDICT"
if [ ${#PROBLEMS[@]} -eq 0 ]; then
    printf '  %sAll checks passed.%s\n\n' "$GREEN" "$NC"
    printf '  Try the request from a workstation:\n'
    printf '    klist                                           # confirm a TGT for an IPA user\n'
    printf '    curl -v --negotiate -u : https://%s:9444/api/user\n' "$SERVICE_HOST"
    printf '\n  If it still fails, capture and share:\n'
    printf '    KRB5_TRACE=/dev/stderr curl --negotiate -u : https://%s:9444/api/user 2>&1 | tail -80\n' "$SERVICE_HOST"
    printf '    sudo journalctl -u launcher-api -n 200 --no-pager\n'
    exit 0
fi

printf '  %s%d problem(s) detected:%s\n' "$RED" "${#PROBLEMS[@]}" "$NC"
for p in "${PROBLEMS[@]}"; do printf '    - %s\n' "$p"; done

printf '\n  %sSuggested remediation (run as root unless noted):%s\n' "$BOLD" "$NC"
PRINTED_FETCH=0
for p in "${PROBLEMS[@]}"; do
    case "$p" in
        *"not run as root"*)
            printf '\n    # Re-run with sudo so the script can read keytabs and call kinit.\n'
            printf '    sudo bash %s\n' "$0" ;;
        *"missing required tools"*)
            printf '\n    # RHEL/Rocky/OL:\n'
            printf '    sudo dnf install -y krb5-workstation ipa-client bind-utils chrony curl\n' ;;
        *"krb5.conf missing"*|*"no default_realm"*)
            printf '\n    # Minimum /etc/krb5.conf:\n'
            printf '    [libdefaults]\n      default_realm = %s\n      dns_canonicalize_hostname = false\n      rdns = false\n' \
                "${REALM:-MAIN.SYSTEM}" ;;
        *"dns_canonicalize_hostname"*)
            printf '\n    # Add to /etc/krb5.conf [libdefaults]:\n'
            printf '      dns_canonicalize_hostname = false\n      rdns = false\n'
            printf '    # Critical when the SPN host (%s) is a virtual hostname.\n' "$SERVICE_HOST" ;;
        *"host not IPA-enrolled"*)
            printf '\n    sudo ipa-client-install --server=%s --domain=%s --no-ntp\n' \
                "${IPA_SERVER:-freeipa.main.system}" \
                "$(printf '%s' "${REALM:-MAIN.SYSTEM}" | tr '[:upper:]' '[:lower:]')" ;;
        *"DNS for "*"fails"*)
            printf '\n    # Fix DNS:\n'
            printf '    getent hosts %s ; getent hosts %s ; getent hosts %s\n' \
                "$ENROLLED_HOST" "$SERVICE_HOST" "$IPA_SERVER" ;;
        *"service-host DNS does not point at this machine"*)
            printf '\n    # The SPN host must resolve to this box. Add a CNAME or A record:\n'
            printf '    # In FreeIPA DNS:\n'
            printf '    ipa dnsrecord-add main.system %s --cname-rec=%s.\n' \
                "$(printf '%s' "$SERVICE_HOST" | sed 's/\.main\.system$//')" "$ENROLLED_HOST" ;;
        *"host keytab missing"*|*"host keytab does not contain"*)
            printf '\n    # Re-enroll to repopulate /etc/krb5.keytab:\n'
            printf '    sudo ipa-client-install --uninstall\n'
            printf '    sudo ipa-client-install --server=%s --domain=%s --no-ntp\n' \
                "$IPA_SERVER" "$(printf '%s' "$REALM" | tr '[:upper:]' '[:lower:]')" ;;
        *"virtual host"*"missing"*)
            printf '\n    # On any IPA-enrolled box with admin creds:\n'
            printf '    kinit admin\n'
            printf '    ipa host-add %s --force\n' "$SERVICE_HOST"
            printf '    ipa service-add %s\n' "$SPN"
            printf '    ipa service-allow-retrieve-keytab %s --hosts=%s\n' "$SPN" "$ENROLLED_HOST" ;;
        *"service ${SPN} does not exist"*|*"service "*"does not exist in IPA"*)
            printf '\n    # On any IPA-enrolled box with admin creds:\n'
            printf '    kinit admin\n'
            [ "$ENROLLED_HOST" != "$SERVICE_HOST" ] && \
                printf '    ipa host-add %s --force      # SPN host must exist as an IPA host\n' "$SERVICE_HOST"
            printf '    ipa service-add %s\n' "$SPN"
            printf '    ipa service-allow-retrieve-keytab %s --hosts=%s\n' "$SPN" "$ENROLLED_HOST" ;;
        *"case-mismatched"*)
            printf '\n    # Lowercase principal exists -- delete and recreate uppercase:\n'
            printf '    kinit admin\n'
            printf '    ipa service-del http/%s\n' "$SERVICE_HOST"
            printf '    ipa service-add %s\n' "$SPN"
            printf '    ipa service-allow-retrieve-keytab %s --hosts=%s\n' "$SPN" "$ENROLLED_HOST" ;;
        *"not in service-allow-retrieve"*|*"no allow-retrieve permission"*)
            printf '\n    kinit admin\n'
            printf '    ipa service-allow-retrieve-keytab %s --hosts=%s\n' "$SPN" "$ENROLLED_HOST" ;;
        *"service keytab "*"missing"*|*"ipa-getkeytab fails"*|*"KVNO mismatch"*|*"cannot self-auth"*)
            if [ "$PRINTED_FETCH" = 0 ]; then
                printf '\n    # Fetch / regenerate the service keytab on this host:\n'
                printf '    sudo kinit -kt /etc/krb5.keytab host/%s\n' "$ENROLLED_HOST"
                printf '    sudo ipa-getkeytab -s %s -p %s -k %s\n' "$IPA_SERVER" "$SPN_REALM" "$KEYTAB"
                printf '    sudo chmod 600 %s\n' "$KEYTAB"
                printf '    sudo systemctl restart launcher-api\n'
                printf '    # If "Principal not found": double-check the SPN exists exactly as %s\n' "$SPN_REALM"
                printf '    #                          (uppercase HTTP/, exact hostname, exact realm)\n'
                PRINTED_FETCH=1
            fi ;;
        *"KDC unreachable"*|*"kvno query failed"*)
            printf '\n    # Check connectivity to the KDC:\n'
            printf '    getent hosts %s\n    nc -vz %s 88\n    nc -vz -u %s 88\n' \
                "$IPA_SERVER" "$IPA_SERVER" "$IPA_SERVER" ;;
        *"host TGT could not be acquired"*)
            printf '\n    # Host KVNO drifted. Easiest fix is re-enroll:\n'
            printf '    sudo ipa-client-install --uninstall\n'
            printf '    sudo ipa-client-install --server=%s --domain=%s --no-ntp\n' \
                "$IPA_SERVER" "$(printf '%s' "$REALM" | tr '[:upper:]' '[:lower:]')" ;;
    esac
done

printf '\n  %sCorrect end-to-end flow for future reference:%s\n' "$BOLD" "$NC"
printf '    1. Enroll this box:\n'
printf '       sudo ipa-client-install --server=%s --domain=%s\n' \
    "$IPA_SERVER" "$(printf '%s' "$REALM" | tr '[:upper:]' '[:lower:]')"
if [ "$ENROLLED_HOST" != "$SERVICE_HOST" ]; then
    printf '    2. (admin shell) Add the virtual SPN host:\n'
    printf '       kinit admin && ipa host-add %s --force\n' "$SERVICE_HOST"
    printf '    3. (admin shell) Create the service principal:\n'
    printf '       ipa service-add %s\n' "$SPN"
    printf '    4. (admin shell) Allow this physical host to retrieve its keytab:\n'
    printf '       ipa service-allow-retrieve-keytab %s --hosts=%s\n' "$SPN" "$ENROLLED_HOST"
    printf '    5. (admin shell) Make sure DNS for %s points at this box:\n' "$SERVICE_HOST"
    printf '       ipa dnsrecord-add <zone> <short-name> --cname-rec=%s.\n' "$ENROLLED_HOST"
    printf '    6. On this box: get a host TGT, fetch the service keytab:\n'
    printf '       sudo kinit -kt /etc/krb5.keytab host/%s\n' "$ENROLLED_HOST"
    printf '       sudo ipa-getkeytab -s %s -p %s -k %s\n' "$IPA_SERVER" "$SPN_REALM" "$KEYTAB"
    printf '    7. sudo chmod 600 %s\n' "$KEYTAB"
    printf '    8. systemd unit: Environment=KRB5_KTNAME=%s\n' "$KEYTAB"
    printf '    9. sudo systemctl restart launcher-api\n'
else
    printf '    2. (admin shell) Create the service principal:\n'
    printf '       kinit admin && ipa service-add %s\n' "$SPN"
    printf '    3. (admin shell) Allow this host to retrieve its keytab:\n'
    printf '       ipa service-allow-retrieve-keytab %s --hosts=%s\n' "$SPN" "$ENROLLED_HOST"
    printf '    4. On this box: get a host TGT, fetch the service keytab:\n'
    printf '       sudo kinit -kt /etc/krb5.keytab host/%s\n' "$ENROLLED_HOST"
    printf '       sudo ipa-getkeytab -s %s -p %s -k %s\n' "$IPA_SERVER" "$SPN_REALM" "$KEYTAB"
    printf '    5. sudo chmod 600 %s\n' "$KEYTAB"
    printf '    6. systemd unit: Environment=KRB5_KTNAME=%s\n' "$KEYTAB"
    printf '    7. sudo systemctl restart launcher-api\n'
fi

exit 1
