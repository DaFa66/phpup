#!/usr/bin/env bash
# tests/harness-brew.sh
# Ad-hoc verification for the Homebrew paths that do not need a Mac: the update
# list formatting and the PHP line enumeration. Extracts the REAL function
# bodies from phpup.sh and stubs `brew`, so it runs anywhere, CI included.
#
# Run: bash tests/harness-brew.sh

set -u
cd "$(dirname "$0")/.." || exit 1
bash -n phpup.sh || { echo "ABORT: phpup.sh has a syntax error"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1 (got [$2] expected [$3])"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

PY=python3; command -v python3 >/dev/null 2>&1 || PY=python

extract_fn() {
    "$PY" - "$1" <<'PYEOF'
import sys
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

for fn in brew_outdated_lines brew_php_lines brew_newest_php_alias brew_stable_version; do
    body=$(extract_fn "$fn") || { echo "ABORT: could not extract $fn"; exit 1; }
    eval "$body"
done

BREW_PREFIX=/nonexistent

# ---- stub brew -------------------------------------------------------------
OUTDATED=""
INFO_JSON='{}'
brew() {
    case "$*" in
        "outdated --formula --verbose"*)
            [ -n "$OUTDATED" ] && printf '%s\n' "$OUTDATED"
            return 0 ;;
        "info --json=v2 php")
            printf '%s\n' "$INFO_JSON"
            return 0 ;;
    esac
    return 0
}

echo "Update list carries the versions:"
OUTDATED='httpd (2.4.69_1) < 2.4.71
php (8.5.12) < 8.5.12_1'
want=$(printf '  %-12s %s -> %s\n  %-12s %s -> %s\n' \
    httpd 2.4.69_1 2.4.71 php 8.5.12 8.5.12_1)
eq 'two lines, aligned, old -> new' "$(brew_outdated_lines httpd mariadb php phpmyadmin)" "$want"

OUTDATED='phpmyadmin (5.2.3) != 5.2.4'
eq 'a revision-only bump reads the same way' \
    "$(brew_outdated_lines phpmyadmin)" "$(printf '  %-12s %s -> %s\n' phpmyadmin 5.2.3 5.2.4)"

OUTDATED=''
eq 'nothing outdated prints nothing' "$(brew_outdated_lines httpd php)" ''

OUTDATED='a line brew changed shape on'
eq 'an unrecognised line still prints' \
    "$(brew_outdated_lines httpd)" '  a line brew changed shape on'

echo "PHP lines offered by fu (newest line is the meta formula, shown as php@X.Y):"
INFO_JSON='{"formulae":[{"versions":{"stable":"8.5.12"},"versioned_formulae":["php@8.4","php@8.3","php@8.2","php@8.1"],"aliases":["php@8.5"]}]}'
eq 'today: 8.1-8.4 plus the meta line for 8.5' \
    "$(brew_php_lines | tr '\n' ' ')" 'php@8.1 php@8.2 php@8.3 php@8.4 php '
eq 'today: newest alias is 8.5' "$(brew_newest_php_alias)" 'php@8.5'

INFO_JSON='{"formulae":[{"versions":{"stable":"8.6.0"},"versioned_formulae":["php@8.5","php@8.4","php@8.3","php@8.2","php@8.1"],"aliases":["php@8.6"]}]}'
eq 'once brew ships 8.6: 8.1-8.5 plus the meta line for 8.6' \
    "$(brew_php_lines | tr '\n' ' ')" 'php@8.1 php@8.2 php@8.3 php@8.4 php@8.5 php '
eq 'once brew ships 8.6: newest alias is 8.6' "$(brew_newest_php_alias)" 'php@8.6'

echo "Metadata shape (brew pretty-prints, a re-serialised blob is compact):"
eq 'compact JSON parses' "$(brew_stable_version php)" '8.6.0'
INFO_JSON='{
  "formulae": [
    {
      "name": "php",
      "versions": {
        "stable": "8.5.12"
      },
      "versioned_formulae": ["php@8.4", "php@8.3"],
      "aliases": ["php@8.5"]
    }
  ]
}'
eq 'pretty-printed JSON parses' "$(brew_stable_version php)" '8.5.12'
eq 'pretty-printed line list' "$(brew_php_lines | tr '\n' ' ')" 'php@8.3 php@8.4 php '

INFO_JSON='{"formulae":[]}'
eq 'no metadata still offers the meta formula' "$(brew_php_lines)" 'php'


# ---- warn_foreign_ports ----------------------------------------------------
# A foreign server on 3306 must be named BEFORE a long upgrade, not after it,
# and it must warn rather than block the update.
print_warn() { printf 'WARN: %s\n' "$*"; }
print_err()  { printf 'ERR: %s\n' "$*"; }
tcp_port_listening() { [[ "$1" == "3306" && "${PORT_BUSY:-0}" == "1" ]]; }
port_owner_active()  { [[ "${PORT_OURS:-0}" == "1" ]]; }
port_holder_label()  { printf 'mysqld (PID 316) /opt/local/lib/mariadb-11.4/bin/mysqld'; }

extract_fn warn_foreign_ports > /tmp/wfp.$$ || { echo "ABORT: could not extract warn_foreign_ports"; exit 1; }
# shellcheck disable=SC1090
. /tmp/wfp.$$
rm -f /tmp/wfp.$$

out=$(PORT_BUSY=1 warn_foreign_ports)
case "$out" in
    *"Port 3306 is already held by another stack — mysqld (PID 316) /opt/local/lib/mariadb-11.4/bin/mysqld"*)
        ok "names the foreign holder and its binary" ;;
    *) bad "names the foreign holder and its binary" "$out" "a warning naming 3306 and the binary" ;;
esac
case "$out" in
    *"cannot start on 3306"*) ok "says what will fail afterwards" ;;
    *) bad "says what will fail afterwards" "$out" "a note that phpup cannot start on 3306" ;;
esac
eq "silent when the port is free"   "$(PORT_BUSY=0 warn_foreign_ports)" ""
eq "silent when the port is ours"   "$(PORT_BUSY=1 PORT_OURS=1 warn_foreign_ports)" ""

echo ""
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
