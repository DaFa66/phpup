#!/usr/bin/env bash
# tests/run-all.sh
# The nix gate in one command: syntax, encoding, then every harness.
#
#   bash tests/run-all.sh           everything (what CI and a release run)
#   bash tests/run-all.sh --quick   skip the slower switch suite
#
# Exit status is 0 only when every gate passes, so a pre-push check or CI job
# needs nothing but the exit code.
set -u
cd "$(dirname "$0")/.." || exit 1

quick=0
for arg in "$@"; do
    case "$arg" in
        --quick) quick=1 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

checks=0; failures=0; suites=0; skipped=0
pass() { echo "  [PASS] $*"; checks=$((checks + 1)); }
fail() { echo "  [FAIL] $*"; checks=$((checks + 1)); failures=$((failures + 1)); }
skip() { echo "  [SKIP] $*"; skipped=$((skipped + 1)); }

echo "== syntax =="
for f in phpup.sh tests/*.sh; do
    if bash -n "$f" 2>/dev/null; then pass "bash -n $f"; else fail "bash -n $f"; fi
done

echo "== encoding (the streamed installer needs LF and no BOM) =="
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        skip "CR/BOM checks: this filesystem stores CRLF by policy" ;;
    *)
        for f in phpup.sh tests/*.sh; do
            cr=$(tr -dc '\r' < "$f" | wc -c | tr -d ' ')
            bom=$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')
            if [ "$cr" != "0" ]; then
                fail "$f carries $cr CR bytes"
            elif [ "$bom" = "efbbbf" ]; then
                fail "$f starts with a UTF-8 BOM"
            else
                pass "$f: LF, no BOM"
            fi
        done ;;
esac

run_suite() {
    suites=$((suites + 1))
    echo "== $1 =="
    if bash "$1"; then pass "suite $1"; else fail "suite $1"; fi
}

if [ "$quick" = "1" ]; then
    skip "tests/harness-switch.sh (--quick)"
else
    run_suite tests/harness-switch.sh
fi
run_suite tests/harness-prerelease.sh

echo ""
printf 'RESULT: %d gates, %d failed, %d suites, %d skipped\n' \
    "$checks" "$failures" "$suites" "$skipped"
[ "$failures" -eq 0 ]
