#!/usr/bin/env bash
# tests/harness-backend.sh
# Ad-hoc verification for backend selection: PHPPUP_BACKEND outranks everything,
# config.json's package_manager is honoured next, and only then do the platform
# defaults and the "an existing Homebrew stack wins" rule apply.
#
# The functions are extracted from phpup.sh by name, so the script is never
# executed and nothing on the machine is touched.
#
# Run:  bash tests/harness-backend.sh

set -u
cd "$(dirname "$0")/.." || exit 1
bash -n phpup.sh || { echo "ABORT: phpup.sh has a syntax error"; exit 1; }

PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1";
       else FAIL=$((FAIL+1)); printf '  [FAIL] %s (got [%s] expected [%s])\n' "$1" "$3" "$2"; fi; }

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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/phpup-backend-XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/brew/Cellar/mariadb/12.3.3" "$TMP/brew/bin" "$TMP/ports/bin" "$TMP/empty"
printf '#!/bin/sh\nexit 0\n' > "$TMP/ports/bin/port"; chmod +x "$TMP/ports/bin/port"
printf '#!/bin/sh\nexit 0\n' > "$TMP/brew/bin/brew";  chmod +x "$TMP/brew/bin/brew"

extract_fn config_value    > "$TMP/lib.sh" || { echo "ABORT: config_value"; exit 1; }
extract_fn detect_backend >> "$TMP/lib.sh" || { echo "ABORT: detect_backend"; exit 1; }
# shellcheck disable=SC1090
. "$TMP/lib.sh"

# globals detect_backend reads
USE_APT=0
USE_PORTS=0
INTEL_BREW_NO_BOTTLES=0
ARCH=x86_64
BREW_PREFIX="$TMP/brew"
PORT_PREFIX="$TMP/ports"
CONFIG_FILE="$TMP/config.json"

write_config() { # write_config <package_manager|""> [brew_prefix] [port_prefix]
    if [ -z "$1" ]; then rm -f "$TMP/config.json"; return; fi
    {
        printf '{\n  "install_path": "%s",\n  "package_manager": "%s",\n' "$TMP" "$1"
        [ -n "${2:-}" ] && printf '  "brew_prefix": "%s",\n' "$2"
        [ -n "${3:-}" ] && printf '  "port_prefix": "%s",\n' "$3"
        printf '  "php_version": "8.6.0"\n}\n'
    } > "$TMP/config.json"
}

run() { # run <env-backend|""> <config-pm|""> <arch> <brew-prefix|""> [config-brew-prefix] [config-port-prefix]
    PHPPUP_BACKEND="$1"
    write_config "$2" "${5:-}" "${6:-}"
    ARCH="$3"
    BREW_PREFIX="$4"
    USE_PORTS=0
    INTEL_BREW_NO_BOTTLES=0
    detect_backend
    printf '%s/%s' "$USE_PORTS" "$INTEL_BREW_NO_BOTTLES"
}

printf '\nconfig_value reads the saved backend:\n'
write_config port
eq 'port'  "$(config_value package_manager)" 'port'
write_config brew
eq 'brew'  "$(config_value package_manager)" 'brew'
write_config ""
eq 'no config file -> empty' "$(config_value package_manager || true)" ''
write_config port
eq 'unknown key -> empty'    "$(config_value nope || true)" ''

printf '\nPHPPUP_BACKEND outranks config:\n'
eq 'env port beats config brew' "1/0" "$(run port brew x86_64 "$TMP/brew")"
eq 'env brew beats config port' "0/1"    "$(run brew port x86_64 "$TMP/brew")"

printf '\nconfig.json decides when no env var is set:\n'
eq 'config port + brew Cellar present -> ports' "1/0" "$(run "" port x86_64 "$TMP/brew")"
eq 'config brew -> brew, Intel notice set'      "0/1" "$(run "" brew x86_64 "$TMP/brew")"
eq 'config port wins on arm64 too'              "1/0" "$(run "" port arm64 "$TMP/brew")"

printf '\nA saved backend that is no longer installed falls through:\n'
rm -f "$TMP/ports/bin/port"
eq 'config port but no port binary -> brew'     "0/1" "$(run "" port x86_64 "$TMP/brew")"
eq 'config port, no port binary, no Cellar -> ports' "1/0" "$(run "" port x86_64 "$TMP/empty")"
printf '#!/bin/sh\nexit 0\n' > "$TMP/ports/bin/port"; chmod +x "$TMP/ports/bin/port"
eq 'config brew but no brew prefix -> ports'    "1/0" "$(run "" brew x86_64 "")"

printf '\nWhen the package manager is not on PATH (ssh, GUI launch):\n'
eq 'brew off PATH, config records the prefix -> brew' \
   "$(run "" brew x86_64 "" "$TMP/brew")" "0/1"
PORT_PREFIX="$TMP/nowhere"
eq 'port off PATH, config records the prefix -> ports' \
   "$(run "" port x86_64 "$TMP/brew" "" "$TMP/ports")" "1/0"
PORT_PREFIX="$TMP/ports"

printf '\nPlatform defaults when there is no config at all:\n'
eq 'existing brew stack wins on Intel'          "0/1" "$(run "" "" x86_64 "$TMP/brew")"
eq 'no stacks -> ports on Intel'                "1/0" "$(run "" "" x86_64 "$TMP/empty")"
eq 'Apple silicon defaults to brew'             "0/0" "$(run "" "" arm64 "$TMP/brew")"

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
