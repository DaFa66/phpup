#!/usr/bin/env bash
# tests/harness-switch.sh
# Ad-hoc verification for phpup.sh's switch verb (stack handover).
# Extracts the REAL function bodies from phpup.sh and stubs only the leaves
# (lsof, ps, sudo, launchctl, systemctl, port checks). Touches nothing real.
#
# Run: bash tests/harness-switch.sh

set -u
cd "$(dirname "$0")/.." || exit 1
bash -n phpup.sh || { echo "ABORT: phpup.sh has a syntax error"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
check() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

PY=python3; command -v python3 >/dev/null 2>&1 || PY=python

extract_fn() {
    "$PY" - "$1" <<'PYEOF'
import sys, re
name = sys.argv[1]
src = open('phpup.sh').read().split('\n')
start = None
for i, line in enumerate(src):
    if line.startswith(name + '() {'):
        start = i
        break
if start is None:
    sys.exit(2)
depth = 0
out = []
for line in src[start:]:
    depth += line.count('{') - line.count('}')
    out.append(line)
    if depth <= 0 and line.strip() == '}':
        break
print('\n'.join(out))
PYEOF
}

WANTED="detect_foreign_stack foreign_alias_for foreign_registry_lines foreign_registry_field
foreign_registry_set foreign_registry_clear_state port_listener_pid process_path_for_pid
port_owner_kind foreign_listener_paths stop_foreign_stack foreign_versions switch_json_array
switch_ports_json switch_stack_json emit_switch_payload json_escape jstr jbool
foreign_exe_running foreign_daemon_running brew_services"
LOADED=0
for fn in $WANTED; do
    body=$(extract_fn "$fn") || { echo "ABORT: could not extract $fn"; exit 1; }
    eval "$body"
    LOADED=$((LOADED+1))
done

echo ""
echo "phpup.sh switch harness ($(uname -s))"
echo "  extracted $LOADED/$(( $(echo $WANTED | wc -w) )) real function bodies"
echo ""

# ---- sandbox ----------------------------------------------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/phpup-switch-harness.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
BASE_DIR="$TMP/phpup"
FOREIGN_REGISTRY="$BASE_DIR/foreign_stacks.tsv"
mkdir -p "$BASE_DIR"

# fake XAMPP classic tree
XROOT="$TMP/XAMPP"
mkdir -p "$XROOT/xamppfiles/bin" "$XROOT/xamppfiles/htdocs"
for b in xampp bin/apachectl bin/mysql.server bin/httpd bin/mysqld bin/php; do
    : > "$XROOT/xamppfiles/$b"; chmod +x "$XROOT/xamppfiles/$b"
done

# XAMPP-VM lookalike: an app bundle with no xamppfiles
mkdir -p "$TMP/XAMPP-VM.app/Contents/MacOS"

# ---- stubs ------------------------------------------------------------
LISTENING="80 3306"
PID80=5001; PID3306=5002; DECOY=5003; NOPATH=5004
KILLED=""; SUDO_CALLS=""; ACTIVE_OWNER_RC=1
PID80_OVERRIDE=""

tcp_port_listening() { case " $LISTENING " in *" $1 "*) return 0 ;; esac; return 1; }
port_owner_active() { return $ACTIVE_OWNER_RC; }
port_holder_label() { printf 'stub-holder'; }
pids_for() {
    case "$1" in
        80)   printf '%s' "${PID80_OVERRIDE:-$PID80}" ;;
        3306) printf '%s' "$PID3306" ;;
    esac
}
lsof() {
    local port=""
    for a in "$@"; do case "$a" in -iTCP:*) port="${a#-iTCP:}" ;; esac; done
    local pid; pid=$(pids_for "$port")
    [[ -n "$pid" ]] && printf '%s\n' "$pid"
    return 0
}
ps() {
    if [[ "${1:-}" == "-axo" && "${2:-}" == "args=" ]]; then
        [[ -n "$FAKE_ARGS" ]] && printf '%s\n' "$FAKE_ARGS"
        return 0
    fi
    [[ "${1:-}" == "-p" ]] && path_for "${2:-}"
}
BREW_CALLS=""
brew() { BREW_CALLS="$BREW_CALLS|$*"; return 0; }
FAKE_ARGS=""
path_for() {
    case "$1" in
        5001) printf '%s' "$XROOT/xamppfiles/bin/httpd" ;;
        5002) printf '%s' "$XROOT/xamppfiles/bin/mysqld" ;;
        5003) printf '%s' "/opt/otherstack/bin/mysqld" ;;
        5004) printf '' ;;
    esac
}
sudo() {
    SUDO_CALLS="$SUDO_CALLS|$*"
    # A kill records the PID, which is the LAST argument (sudo kill -TERM <pid>).
    if [[ "${1:-}" == "kill" ]]; then
        local last=""
        for a in "$@"; do last="$a"; done
        KILLED="$KILLED $last"
    fi
    return 0
}
launchctl() { return 0; }
systemctl() { return 0; }
print_err() { :; }

reset_state() {
    LISTENING="80 3306"; PID80=5001; PID3306=5002; PID80_OVERRIDE=""
    KILLED=""; SUDO_CALLS=""; ACTIVE_OWNER_RC=1
    FAKE_ARGS=""; BREW_CALLS=""; BREW_PREFIX=""
    FOREIGN_ROOT=""; FOREIGN_KIND=""; FOREIGN_APACHE=""; FOREIGN_MYSQL=""
    FOREIGN_PHP=""; FOREIGN_HTDOCS=""; FOREIGN_UNTOUCHABLE=""
    FV_APACHE=""; FV_MARIADB=""; FV_PHP=""
    rm -f "$FOREIGN_REGISTRY"
}

# ======================================================================
echo "1. Foreign stack detection"
reset_state
# A filesystem without an exec bit (MSYS with noacl, some network mounts) cannot make
# the fixture below look runnable, so those checks would fail for a host reason rather
# than a code reason. Probe once and say so, instead of reporting a false failure.
EXEC_OK=0
_probe=$(mktemp -d)
: > "$_probe/x"; chmod +x "$_probe/x" 2>/dev/null
[[ -x "$_probe/x" ]] && EXEC_OK=1
rm -rf "$_probe"
if [[ $EXEC_OK -eq 1 ]] && detect_foreign_stack "$XROOT"; then
    ok "classic XAMPP root recognised"
    check '[[ "$FOREIGN_KIND" == "xampp" ]]' "kind is xampp"
    check '[[ "$FOREIGN_APACHE" == "$XROOT/xamppfiles/bin/apachectl" ]]' "apachectl resolved"
    check '[[ "$FOREIGN_MYSQL" == "$XROOT/xamppfiles/bin/mysql.server" ]]' "mysql.server resolved"
    check '[[ "$FOREIGN_HTDOCS" == "$XROOT/xamppfiles/htdocs" ]]' "htdocs resolved"
elif [[ $EXEC_OK -eq 1 ]]; then
    bad "classic XAMPP root recognised"
else
    echo "  [SKIP] XAMPP tree checks: this filesystem does not carry an exec bit"
    echo "         (run the suite on macOS or Linux to exercise them; CI does)"
fi
check '! detect_foreign_stack "$TMP/XAMPP-VM.app"' "XAMPP-VM (no xamppfiles) is refused"
check '! detect_foreign_stack "$TMP/nothing-here"' "a missing path is refused"
check '! detect_foreign_stack "$BASE_DIR"' "a plain directory is refused (no lampp, no xamppfiles)"

echo ""
echo "2. Aliases"
check '[[ "$(foreign_alias_for /Applications/XAMPP)" == "xampp" ]]' "/Applications/XAMPP -> xampp"
check '[[ "$(foreign_alias_for /Applications/XAMPP-v7.4.33)" == "xampp_v7_4_33" ]]' "versioned root gets its own alias"
check '[[ "$(foreign_alias_for /opt/lampp/)" == "lampp" ]]' "trailing slash handled"

echo ""
echo "3. Registry round trip"
reset_state
foreign_registry_set "xampp" "/Applications/XAMPP" "xampp" "enabled" "enabled"
check '[[ "$(foreign_registry_field xampp 2)" == "/Applications/XAMPP" ]]' "path stored"
check '[[ "$(foreign_registry_field xampp 4)" == "enabled" ]]' "saved apache boot state stored"
foreign_registry_set "xampp" "/Applications/XAMPP" "xampp" "enabled" "disabled"
check '[[ "$(foreign_registry_lines | wc -l | tr -d " ")" == "1" ]]' "re-registering replaces rather than duplicates"
check '[[ "$(foreign_registry_field xampp 5)" == "disabled" ]]' "saved mariadb boot state updated"
foreign_registry_clear_state "xampp"
check '[[ -z "$(foreign_registry_field xampp 4)" ]]' "handover state cleared"
check '[[ "$(foreign_registry_field xampp 2)" == "/Applications/XAMPP" ]]' "stack stays registered after clearing"
foreign_registry_set "other" "/opt/lampp" "lampp" "" ""
check '[[ "$(foreign_registry_lines | wc -l | tr -d " ")" == "2" ]]' "a second stack is added, not merged"

echo ""
echo "4. Port ownership"
reset_state
check '[[ "$(port_owner_kind 80 "$XROOT")" == "foreign" ]]' "listener under the foreign root reads as foreign"
PID80_OVERRIDE=""
LISTENING="3306"
check '[[ "$(port_owner_kind 80 "$XROOT")" == "free" ]]' "a quiet port reads as free"
LISTENING="80 3306"
PID80=5003
check '[[ "$(port_owner_kind 80 "$XROOT")" == "other" ]]' "a third-party listener reads as other"
PID80=5004
ACTIVE_OWNER_RC=0
check '[[ "$(port_owner_kind 80 "$XROOT")" == "phpup" ]]' "unreadable path + our own active owner reads as phpup"
ACTIVE_OWNER_RC=1
check '[[ "$(port_owner_kind 80 "$XROOT")" == "unknown" ]]' "unreadable path + no owner reads as unknown"
PID80=5001

echo ""
echo "5. Stopping a foreign stack kills only its own listeners"
reset_state
detect_foreign_stack "$XROOT" >/dev/null
stop_foreign_stack
check '[[ "$KILLED" == " 5001 5002" || "$KILLED" == " 5001" || "$KILLED" == " 5002 5001" ]]' "killed only the two XAMPP listeners"
check '[[ "$KILLED" != *"5003"* ]]' "the third-party process survived"
check '[[ -z "$FOREIGN_UNTOUCHABLE" ]]' "nothing reported untouchable"
reset_state
detect_foreign_stack "$XROOT" >/dev/null
PID80=5004
stop_foreign_stack
check '[[ "$FOREIGN_UNTOUCHABLE" == *"80"* ]]' "a listener with no readable path is reported, not killed"
check '[[ "$KILLED" != *"5004"* ]]' "the unidentifiable listener was not killed"

echo ""
echo "6. Payload is valid JSON"
reset_state
detect_foreign_stack "$XROOT" >/dev/null
SW_OK=1; SW_CODE=""; SW_TO="xampp"; SW_CHANGED=1; SW_DRY=0
SW_STEPS="stop phpup apache and mariadb
start xampp apache and mariadb"
SW_WARN='a warning with a "quote" and a \backslash'
SW_ERR=""
SW_STACK=$(switch_stack_json "xampp")
SW_PORTS=$(switch_ports_json)
payload=$( ( emit_switch_payload ) 3>&1 )
if printf '%s' "$payload" | "$PY" -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "payload parses as JSON"
else
    bad "payload parses as JSON: $payload"
fi
check 'printf "%s" "$payload" | grep -q "\"changed\":true"' "changed flag present"
check 'printf "%s" "$payload" | grep -q "\"steps\":\[" ' "steps array present"
check 'printf "%s" "$payload" | grep -q "\\\\\""' "quotes are escaped inside strings"

# ======================================================================
echo ""
echo "7. A listener we cannot see is still attributable (macOS: Apache runs as root)"
reset_state
LISTENING="80"; PID80=5004
check '[[ "$(port_owner_kind 80 "$XROOT")" == "unknown" ]]' \
    "invisible listener, no matching daemon: unknown"
FAKE_ARGS="$XROOT/xamppfiles/bin/httpd -k start"
check '[[ "$(port_owner_kind 80 "$XROOT")" == "foreign" ]]' \
    "invisible listener, httpd running: foreign"
FAKE_ARGS="/usr/bin/tail -f $XROOT/xamppfiles/bin/httpd"
check '[[ "$(port_owner_kind 80 "$XROOT")" == "unknown" ]]' \
    "a tail that mentions the binary is not a daemon"
FAKE_ARGS="$XROOT/xamppfiles/bin/httpd-other -k start"
check '[[ "$(port_owner_kind 80 "$XROOT")" == "unknown" ]]' \
    "a prefix-similar binary is not a match"

LISTENING="3306"; PID3306=5004
FAKE_ARGS="$XROOT/xamppfiles/sbin/mysqld"
check '[[ "$(port_owner_kind 3306 "$XROOT")" == "foreign" ]]' \
    "mysqld in sbin/ (macOS layout) is recognised"
FAKE_ARGS="$XROOT/xamppfiles/bin/mysqld"
check '[[ "$(port_owner_kind 3306 "$XROOT")" == "foreign" ]]' \
    "mysqld in bin/ (older layout) is recognised"
FAKE_ARGS="$TMP/OtherStack/xamppfiles/sbin/mysqld"
check '[[ "$(port_owner_kind 3306 "$XROOT")" == "unknown" ]]' \
    "another root's daemon is not credited to this stack"

# ======================================================================
echo ""
echo "8. brew services is asked as the invoking user"
reset_state
brew_services start mariadb
check '[[ "$BREW_CALLS" == *"services start mariadb"* ]]' \
    "the verb and formula reach brew services"
check '[[ "$BREW_CALLS" != *"|sudo"* ]]' \
    "no sudo on the already-unprivileged path"

# ======================================================================
echo ""
echo "9. Foreign MySQL version, wherever the binary lives"
if [[ $EXEC_OK -eq 1 ]]; then
    reset_state
    mkdir -p "$TMP/FV/xamppfiles/sbin"
    printf '#!/bin/sh\necho "mysqld  Ver 10.4.32-MariaDB for osx10.15 on x86_64"\n' \
        > "$TMP/FV/xamppfiles/sbin/mysqld"
    chmod +x "$TMP/FV/xamppfiles/sbin/mysqld"
    FOREIGN_ROOT="$TMP/FV"; FOREIGN_KIND="xampp"
    foreign_versions
    check '[[ "$FV_MARIADB" == "10.4.32" ]]' \
        "mysqld in sbin/ reports its version"
else
    echo "  [SKIP] sbin/ mysqld probe: this filesystem does not carry an exec bit"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
if [[ $FAIL -eq 0 ]]; then echo "ALL CHECKS PASSED (ad-hoc, stubbed leaves)"; exit 0; fi
echo "CHECKS FAILED"
exit $FAIL
