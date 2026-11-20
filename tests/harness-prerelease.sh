#!/usr/bin/env bash
# tests/harness-prerelease.sh
# Ad-hoc verification for phpup.sh's pre-release handling: the alpha/beta/RC
# detection shared by the dashboard label and the latest-stable search.
# Extracts the REAL function bodies from phpup.sh and stubs only the package
# manager. Touches nothing real.
#
# Run: bash tests/harness-prerelease.sh

set -u
cd "$(dirname "$0")/.." || exit 1
bash -n phpup.sh || { echo "ABORT: phpup.sh has a syntax error"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1 (got [$2] expected [$3])"; FAIL=$((FAIL+1)); }
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

for fn in php_is_prerelease latest_php_version; do
    body=$(extract_fn "$fn") || { echo "ABORT: could not extract $fn"; exit 1; }
    eval "$body"
done

echo "Detection (a pre-release is not the stable release its number implies):"
for v in 8.6.0RC7 8.6.0rc7 8.6.0-rc7 8.6.0~rc7-1 8.6.0beta2 8.6.0alpha1 8.6.0~preview9; do
    if php_is_prerelease "$v"; then ok "pre-release: $v"; else bad "pre-release: $v" no yes; fi
done
for v in 8.6.0 8.5.13 8.4.27 7.4.33; do
    if php_is_prerelease "$v"; then bad "stable: $v" yes no; else ok "stable: $v"; fi
done

echo "latest_php_version picks a stable series, never a preview:"
apt_php_series() { echo "8.4 8.5 8.6"; }

apt-cache() {
    case "$2" in
        php8.4) echo "Candidate: 8.4.27-1+deb.sury.org+1" ;;
        php8.5) echo "Candidate: 8.5.13-1+deb.sury.org+1" ;;
        php8.6) echo "Candidate: 8.6.0~rc7-1+deb.sury.org+1" ;;
    esac
}
eq 'RC candidate skipped, 8.5 wins' "$(latest_php_version)" '8.5'

apt-cache() {
    case "$2" in
        php8.4) echo "Candidate: 8.4.27-1" ;;
        php8.5) echo "Candidate: 8.5.13-1" ;;
        php8.6) echo "Candidate: 8.6.0~preview3-1" ;;
    esac
}
eq 'preview candidate skipped too' "$(latest_php_version)" '8.5'

apt-cache() {
    case "$2" in
        php8.4) echo "Candidate: 8.4.27-1" ;;
        php8.5) echo "Candidate: 8.5.13-1" ;;
        php8.6) echo "Candidate: 8.6.0-1" ;;
    esac
}
eq 'a stable 8.6 is offered' "$(latest_php_version)" '8.6'

apt-cache() { :; }
eq 'nothing resolvable yields empty' "$(latest_php_version)" ''

echo "Dashboard label (the same helper the PHP row calls):"
row_label() {
    if php_is_prerelease "$1"; then printf '%s (pre-release)' "$1"; else printf '%s' "$1"; fi
}
eq 'RC build is marked'  "$(row_label 8.6.0RC7)" '8.6.0RC7 (pre-release)'
eq 'stable is not marked' "$(row_label 8.6.0)"   '8.6.0'

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
