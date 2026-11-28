#!/usr/bin/env bash
# tests/harness-backup.sh
# Ad-hoc verification for the `b` backup command: it must use the ACTIVE
# backend's own client and dump binary (never a neighbour stack's), and the dump
# must be version-portable — users as CREATE USER/GRANT, not raw grant-table rows.
#
# backup_bin() is extracted from phpup.sh and run against fake prefixes; the rest
# is a source contract, because the dump itself needs a live server.
#
# Run:  bash tests/harness-backup.sh

set -u
cd "$(dirname "$0")/.." || exit 1
bash -n phpup.sh || { echo "ABORT: phpup.sh has a syntax error"; exit 1; }

PASS=0; FAIL=0
eq() { # eq <label> <actual> <expected>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1";
    else FAIL=$((FAIL+1)); printf '  [FAIL] %s (got [%s] expected [%s])\n' "$1" "$2" "$3"; fi
}

PY=python3; command -v python3 >/dev/null 2>&1 || PY=python
extract_fn() {
    "$PY" - "$1" <<'PYEOF'
import sys
name = sys.argv[1]
src = open('phpup.sh').read().split('\n')
for i, line in enumerate(src):
    if line.startswith(name + '() {'):
        depth = 0
        out = []
        for l in src[i:]:
            depth += l.count('{') - l.count('}')
            out.append(l)
            if depth <= 0 and l.strip() == '}':
                break
        print('\n'.join(out))
        break
else:
    sys.exit(2)
PYEOF
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/phpup-backup-XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/brew/bin" "$TMP/brew/opt/mariadb/bin" "$TMP/ports/bin" "$TMP/ports/lib/mariadb-13.1/bin"
for f in "$TMP/brew/bin/mysql" "$TMP/brew/opt/mariadb/bin/mariadb-dump" \
         "$TMP/ports/bin/mysql" "$TMP/ports/bin/mariadb-dump" "$TMP/ports/lib/mariadb-13.1/bin/mariadb-dump"; do
    printf '#!/bin/sh\nexit 0\n' > "$f"; chmod +x "$f"
done

extract_fn backup_bin > "$TMP/lib.sh" || { echo "ABORT: backup_bin"; exit 1; }
# shellcheck disable=SC1090
. "$TMP/lib.sh"

USE_APT=0; USE_PORTS=0
BREW_PREFIX="$TMP/brew"; PORT_PREFIX="$TMP/ports"; MARIADB_PORT="mariadb-13.1"

printf '\nThe dump binary follows the ACTIVE backend:\n'
eq 'ports uses the series-bundled mariadb-dump' \
   "$(USE_PORTS=1 backup_bin dump)" "$TMP/ports/lib/mariadb-13.1/bin/mariadb-dump"
eq 'ports falls back to the prefix binary' \
   "$(USE_PORTS=1 MARIADB_PORT=mariadb-9.9 backup_bin dump)" "$TMP/ports/bin/mariadb-dump"
eq 'brew uses the formula-pinned dump' \
   "$(USE_PORTS=0 backup_bin dump)" "$TMP/brew/opt/mariadb/bin/mariadb-dump"
eq 'ports client comes from the ports prefix' "$(USE_PORTS=1 backup_bin mysql)" "$TMP/ports/bin/mysql"
eq 'brew client comes from the brew prefix'   "$(USE_PORTS=0 backup_bin mysql)" "$TMP/brew/bin/mysql"
rm -f "$TMP/brew/opt/mariadb/bin/mariadb-dump"
eq 'brew falls back to the prefix binary' \
   "$(USE_PORTS=0 backup_bin dump)" "$TMP/brew/bin/mariadb-dump"

printf '\nPortable, not backend-specific:\n'
body=$(awk '/^cmd_backup\(\) \{/,/^\}/' phpup.sh)
case "$body" in
    *"--system=users"*)      PASS=$((PASS+1)); printf '  [PASS] users dumped as CREATE USER/GRANT\n' ;;
    *) FAIL=$((FAIL+1)); printf '  [FAIL] users dumped as CREATE USER/GRANT (no --system=users)\n' ;;
esac
case "$body" in
    *"--single-transaction"*) PASS=$((PASS+1)); printf '  [PASS] consistent snapshot of a live server\n' ;;
    *) FAIL=$((FAIL+1)); printf '  [FAIL] consistent snapshot of a live server\n' ;;
esac
case "$body" in
    *"--all-databases"*)
        FAIL=$((FAIL+1)); printf '  [FAIL] must not use --all-databases (it carries raw mysql.* grant tables)\n' ;;
    *) PASS=$((PASS+1)); printf '  [PASS] does not carry raw mysql.* grant tables\n' ;;
esac
case "$body" in
    *"is_service_running mariadb"*) PASS=$((PASS+1)); printf '  [PASS] refuses when the database is not running\n' ;;
    *) FAIL=$((FAIL+1)); printf '  [FAIL] refuses when the database is not running\n' ;;
esac

printf '\nReachable from the dashboard:\n'
grep -q 'UNDERLINE}B${RESET}.*ackup' phpup.sh \
    && { PASS=$((PASS+1)); printf '  [PASS] menu shows a B entry\n'; } \
    || { FAIL=$((FAIL+1)); printf '  [FAIL] menu shows a B entry\n'; }
grep -q '\[bB\]|\[bB\]ackup)' phpup.sh \
    && { PASS=$((PASS+1)); printf '  [PASS] b is dispatched\n'; } \
    || { FAIL=$((FAIL+1)); printf '  [FAIL] b is dispatched\n'; }

printf '\nThe restore offer after a backend switch:\n'
offer=$(awk '/^offer_dump_restore\(\) \{/{f=1} f{print} f&&/^\}/{exit}' phpup.sh)
case "$offer" in
    *"phpup-backup-*.sql"*)        PASS=$((PASS+1)); printf '  [PASS] looks for a portable backup\n' ;;
    *)                             FAIL=$((FAIL+1)); printf '  [FAIL] looks for a portable backup\n' ;;
esac
case "$offer" in
    *"CREATE USER IF NOT EXISTS"*) PASS=$((PASS+1)); printf '  [PASS] restores accounts without aborting on duplicates\n' ;;
    *)                             FAIL=$((FAIL+1)); printf '  [FAIL] restores accounts without aborting on duplicates\n' ;;
esac
case "$offer" in
    *'.handled'*)                  PASS=$((PASS+1)); printf '  [PASS] asks about a file only once\n' ;;
    *)                             FAIL=$((FAIL+1)); printf '  [FAIL] asks about a file only once\n' ;;
esac
case "$offer" in
    *'MARIADB_VERSION'*)           PASS=$((PASS+1)); printf '  [PASS] never offers this stack its own dump\n' ;;
    *)                             FAIL=$((FAIL+1)); printf '  [FAIL] never offers this stack its own dump\n' ;;
esac
grep -q 'offer_dump_restore' phpup.sh && [ "$(grep -c '^        offer_dump_restore\|^    \[\[ "${update_ok:-1}" == 1 \]\] && offer_dump_restore' phpup.sh)" -eq 2 ] \
    && { PASS=$((PASS+1)); printf '  [PASS] called from both Install and Update\n'; } \
    || { FAIL=$((FAIL+1)); printf '  [FAIL] called from both Install and Update\n'; }

printf '\nThe CLI verb:\n'
grep -q 'status|start|stop|restart|switch|backup|version|help' phpup.sh \
    && { PASS=$((PASS+1)); printf '  [PASS] backup is accepted as a verb\n'; } \
    || { FAIL=$((FAIL+1)); printf '  [FAIL] backup is accepted as a verb\n'; }
grep -q 'backup)  cmd_cli_backup' phpup.sh \
    && { PASS=$((PASS+1)); printf '  [PASS] dispatch reaches cmd_cli_backup\n'; } \
    || { FAIL=$((FAIL+1)); printf '  [FAIL] dispatch reaches cmd_cli_backup\n'; }
grep -q '"schema":1,"ok":true,"file"' phpup.sh \
    && { PASS=$((PASS+1)); printf '  [PASS] --json carries the file and the counts\n'; } \
    || { FAIL=$((FAIL+1)); printf '  [FAIL] --json carries the file and the counts\n'; }
grep -q 'CLI_QUIET == 1 ]] ; then' phpup.sh || true

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
