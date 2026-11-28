#!/usr/bin/env bash
# tests/harness-ports-series.sh
# Ad-hoc verification for phpup.sh's MacPorts series resolution: the helpers
# that make install/update follow the ports tree instead of the pinned
# php85 / mariadb-12.3 defaults (which is how the Mac froze on MariaDB 12.3).
#
# The functions are extracted from phpup.sh by marker, so the script itself is
# never executed and nothing on the machine is touched. `port` is a stub.
#
# Run:  bash tests/harness-ports-series.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO/phpup.sh"

pass=0
fail=0
check() { # check <label> <actual> <expected>
    if [[ "$2" == "$3" ]]; then
        pass=$((pass + 1)); printf '  [PASS] %s\n' "$1"
    else
        fail=$((fail + 1)); printf '  [FAIL] %s (got [%s] expected [%s])\n' "$1" "$2" "$3"
    fi
}

# ---- extract the helper block, byte for byte ------------------------------
START='# ---- MacPorts: follow the ports tree'
END='# ---- PATH Management'
block=$(awk -v s="$START" -v e="$END" 'index($0,s){f=1} f && index($0,e){exit} f' "$SCRIPT")
if [[ -z "$block" ]]; then
    printf 'could not extract the MacPorts helper block\n' >&2
    exit 1
fi

# ---- stub environment -----------------------------------------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/phpup-ports-XXXXXX") || exit 1
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/port" <<'STUB'
#!/usr/bin/env bash
# Minimal `port` stand-in: serves $PORTS_TREE / $PORTS_INSTALLED fixtures.
for a in "$@"; do
    case "$a" in
        search)
            [[ -n "${PORTS_TREE_FILE:-}" && -f "$PORTS_TREE_FILE" ]] || exit 1
            while read -r n; do printf '%s @0.0.0 lang/%s\n' "$n" "$n"; done < "$PORTS_TREE_FILE"
            exit 0 ;;
        list)
            [[ -n "${PORTS_LIST_FILE:-}" && -f "$PORTS_LIST_FILE" ]] || exit 1
            while read -r n; do printf '%s @0.0.0\n' "$n"; done < "$PORTS_LIST_FILE"
            exit 0 ;;
    esac
done
exit 0
STUB
chmod +x "$TMP/bin/port"

PORT_PREFIX="$TMP"
print_info() { :; }
print_ok()   { :; }
print_warn() { :; }
print_err()  { :; }

eval "$block"

# MariaDB's API stand-in: the harness sets MARIADB_STABLE to pretend the API
# answered (13.1 today, with 13.2 still an RC), or leaves it empty to prove the
# tree is used when the API cannot answer.
latest_mariadb_series() { [[ -n "${MARIADB_STABLE:-}" ]] && printf '%s' "$MARIADB_STABLE"; }
MARIADB_STABLE=13.1

# ---- fixtures -------------------------------------------------------------
# A ports tree like 2026-11: php74 .. php86, MariaDB 10.11 .. 13.2
cat > "$TMP/tree" <<'TREE'
php74
php80
php81
php82
php83
php84
php85
php86
mariadb-10.11
mariadb-11.4
mariadb-12.3
mariadb-13.0
mariadb-13.1
mariadb-13.2
mariadb-devel
TREE
cp "$TMP/tree" "$TMP/tree.copy"

printf '\nNewest series in the tree:\n'
export PORTS_TREE_FILE="$TMP/tree" PORTS_LIST_FILE="$TMP/tree"
check 'php86 is the newest PHP port'      "$(ports_latest_php)"     "php86"
check 'mariadb-13.1 is the newest STABLE MariaDB (13.2 is RC)' "$(ports_latest_mariadb)" "mariadb-13.1"

printf '\nOlder tree (the Mac today):\n'
cat > "$TMP/oldtree" <<'OLD'
php82
php83
php84
php85
mariadb-11.4
mariadb-12.3
OLD
export PORTS_TREE_FILE="$TMP/oldtree"
check 'php85 when 8.6 does not exist yet'  "$(ports_latest_php)"     "php85"
check 'mariadb-12.3 in an older tree'      "$(ports_latest_mariadb)" "mariadb-12.3"

printf '\nUnreadable tree falls back to installed ports:\n'
export PORTS_TREE_FILE="$TMP/does-not-exist" PORTS_LIST_FILE="$TMP/oldtree"
check 'installed php85'                   "$(ports_latest_php)"     "php85"
check 'installed mariadb-12.3'            "$(ports_latest_mariadb)" "mariadb-12.3"

printf '\nNothing readable at all:\n'
export PORTS_TREE_FILE="$TMP/does-not-exist" PORTS_LIST_FILE="$TMP/does-not-exist"
check 'php empty'                         "$(ports_latest_php)"     ""
check 'mariadb empty'                     "$(ports_latest_mariadb)" ""

printf '\nAPI unreachable falls back to the tree:\n'
export PORTS_TREE_FILE="$TMP/tree" PORTS_LIST_FILE="$TMP/tree"
MARIADB_STABLE=""
check 'newest tree series when API is silent' "$(ports_latest_mariadb)" "mariadb-13.2"

printf '\nAPI names a series the tree does not have:\n'
MARIADB_STABLE="12.9"
check 'ignores an absent stable series'        "$(ports_latest_mariadb)" "mariadb-13.2"
MARIADB_STABLE=13.1

printf '\nSeries comparison:\n'
export PORTS_TREE_FILE="$TMP/tree" PORTS_LIST_FILE="$TMP/tree"
check 'php86 is newer than php85'         "$(ports_is_newer php86 php85 && echo yes || echo no)"   "yes"
check 'php85 is not newer than php86'     "$(ports_is_newer php85 php86 && echo yes || echo no)"   "no"
check 'same series is never newer'        "$(ports_is_newer php86 php86 && echo yes || echo no)"   "no"
check 'mariadb-13.1 newer than 12.3'      "$(ports_is_newer mariadb-13.1 mariadb-12.3 && echo yes || echo no)" "yes"
check '10.6 is not newer than 9.9'        "$(ports_is_newer mariadb-10.6 mariadb-9.9 && echo yes || echo no)"   "yes"
check 'empty candidate is not newer'      "$(ports_is_newer '' php85 && echo yes || echo no)"      "no"

printf '\nSeries arithmetic:\n'
check 'php86 -> 8.6'                      "$(ports_series_of php86)"           "8.6"
check 'mariadb-13.1 -> 13.1'              "$(ports_series_of mariadb-13.1)"    "13.1"

printf '\nThe series move carries the accounts, and cannot mistake a 0700 datadir for an empty one:\n'
move=$(awk '/^ports_move_mariadb\(\) \{/,/^}/' "$SCRIPT")
cfg=$(awk '/^configure_mariadb_ports\(\) \{/,/^}/' "$SCRIPT")
check 'move dumps users as well as data'      "$(printf '%s' "$move" | grep -c '\"\$dump_bin\" -u root --system=users')" "2"
check 'restore tolerates existing accounts'   "$(printf '%s' "$move" | grep -c 'CREATE USER IF NOT EXISTS')" "1"
check 'users saved when there are no databases' "$(printf '%s' "$move" | grep -c 'users-\$(date')" "1"
check 'datadir probe runs under sudo'         "$(printf '%s' "$cfg" | grep -A2 'datadir_initialized() {' | grep -c 'sudo ls -A')" "1"
check 'wipe needs proof of emptiness'         "$(printf '%s' "$cfg" | grep -c 'wipe_ok -eq 1')" "1"

printf '\nphpMyAdmin storage wiring on MacPorts:\n'
# Ends on the function's closing print, not on "}": the heredoc that writes
# config.inc.php contains a column-0 "}" of its own.
pma=$(awk '/^configure_phpmyadmin_ports\(\) \{/{f=1} f{print} /^    print_ok "phpMyAdmin configured \(MacPorts\)"$/{exit}' "$SCRIPT")
check 'storage names the bookmark table'   "$(printf '%s' "$pma" | grep -c -F bookmarktable)" "1"
check 'storage names the export templates' "$(printf '%s' "$pma" | grep -c -F export_templates)" "1"
check 'control user created every run'     "$(printf '%s' "$pma" | grep -c -F "CREATE USER IF NOT EXISTS 'pma'@'localhost'")" "1"
check 'control user verified over TCP'     "$(printf '%s' "$pma" | grep -c -F 'reaches the storage schema')" "1"

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]] || exit 1
