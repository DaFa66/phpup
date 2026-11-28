#!/usr/bin/env bash
# Contract checks for the hidden `phpup restore` verb. No stack needed: these
# read the source, and the live behaviour is proven separately against MariaDB.
set -u
cd "$(dirname "$0")/.." || exit 2

PASS=0; FAIL=0
check() {
    if grep -qF -- "$2" <<<"$3"; then
        PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"
    else
        FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"
    fi
}
refute() {
    if grep -qF -- "$2" <<<"$3"; then
        FAIL=$((FAIL+1)); printf '  [FAIL] %s (found: %s)\n' "$1" "$2"
    else
        PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"
    fi
}

printf 'The hidden restore verb:\n'

check 'is accepted as a verb'        'status|start|stop|restart|switch|backup|restore|version|help)' "$(cat phpup.sh)"
refute 'is not advertised in help'   'phpup.sh restore' "$(awk '/^cmd_cli_usage\(\) \{/,/^}/' phpup.sh)"

body=$(awk '/^cmd_cli_restore\(\) \{/{f=1} f{print} f&&/^\}/{exit}' phpup.sh)
check 'dispatches to cmd_cli_restore' 'restore) cmd_cli_restore' "$(cat phpup.sh)"
check 'lists when given no target'    'restore_list_human' "$body"
check 'refuses a target it cannot find' 'No backup matches' "$body"
check 'takes a safety copy first'     'Taking a safety copy before restoring' "$body"
check 'stops when the copy fails'     'nothing was restored' "$body"
check 'asks for a typed yes'          'Type yes to continue' "$body"
check 'never trusts a yes-prefix'     '"$ans" != "yes"' "$body"
check 'restores accounts idempotently' 'CREATE USER IF NOT EXISTS' "$body"
check 'supports --dry-run'            'CLI_DRY == 1' "$body"
check 'refuses a stopped server'      'MariaDB is not running' "$body"

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
