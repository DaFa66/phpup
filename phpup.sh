#!/usr/bin/env bash
# ============================================================
#  phpup — Mac & Linux Web Stack Installer & Dashboard
#  Inspired by getphp.org (Mac, Linux)
#  GitHub: https://github.com/DaFa66/phpup
#  Author: Simon Field (aka - DaFa)
#  License: MIT
#  Date: 2026-08-29
#  Version: 1.2.0
# ============================================================

# ---- Config -------------------------------------------------
REMOTE_URL='https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.sh'
BASE_DIR="${HOME}/phpup"
DOC_ROOT="${BASE_DIR}/www"
LOGS_DIR="${BASE_DIR}/logs"
CONFIG_DIR="${BASE_DIR}"
CONFIG_FILE="${BASE_DIR}/config.json"
LEGACY_CONFIG_DIR="${HOME}/.config/phpup"
PHP_MIN_SERIES="8.2"    # fu download floor; overridable via config.json
DATA_BACKUP_DIR="${BASE_DIR}/data_backup"

# ---- Colour Constants ---------------------------------------
ESC='\033'
RED="${ESC}[31m"
GREEN="${ESC}[32m"
YELLOW="${ESC}[33m"
BLUE="${ESC}[34m"
CYAN="${ESC}[36m"
BOLD="${ESC}[1m"
UNDERLINE="${ESC}[4m"
RESET="${ESC}[0m"

# ---- Platform Detection -------------------------------------
ARCH=$(uname -m)
OS_TYPE="${OSTYPE}"

if [[ "${OS_TYPE}" == "darwin"* ]]; then
    OS_NAME="macOS"
    OS_DISTRO="macOS"
    OS_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
    OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
    SHELL_PROFILE="${HOME}/.zshrc"
    HTTPD_USER="_www"
    USE_APT=0
elif [[ "${OS_TYPE}" == "linux-gnu"* ]]; then
    OS_NAME="Linux"
    if command -v lsb_release &>/dev/null; then
        OS_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
        OS_DISTRO=$(lsb_release -is 2>/dev/null || echo "Linux")
    elif [[ -f /etc/os-release ]]; then
        # lsb_release not installed on minimal Debian — parse os-release instead
        OS_DISTRO=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | sed 's/.*/\u&/')
        OS_VERSION=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        [[ -z "$OS_DISTRO" ]] && OS_DISTRO="Linux"
        [[ -z "$OS_VERSION" ]] && OS_VERSION="unknown"
    else
        OS_VERSION="unknown"
        OS_DISTRO="Linux"
    fi
    SHELL_PROFILE="${HOME}/.bashrc"
    HTTPD_USER="www-data"
    USE_APT=1
else
    OS_NAME="Unknown"
    OS_DISTRO="Unknown"
    OS_VERSION="unknown"
    SHELL_PROFILE="${HOME}/.bashrc"
    HTTPD_USER="www-data"
    USE_APT=0
fi

# ---- Homebrew Detection -------------------------------------
HOMEBREW=0
BREW_PREFIX=""
if brew --version &>/dev/null; then
    HOMEBREW=1
    BREW_PREFIX=$(brew --prefix)
fi

# ---- MacPorts Detection -------------------------------------
USE_PORTS=0            # 1 = MacPorts backend active (Intel macOS only)
MACPORTS=0             # 1 = /opt/local/bin/port present on machine
PORT_PREFIX="/opt/local"
MACPORTS_PATHS_FILE="/etc/paths.d/macports"   # new-login-shell PATH entry (self-healed by manage_path)
BREW_MIN_OS_MAJOR=14   # Homebrew officially supports the latest 3 macOS releases (14/15/26 as of 2026-08)
MARIADB_PORT="mariadb-12.3"   # fallback candidate: mariadb-11.4
PHP_PORT="php85"               # active PHP port (changes on fu switch)
PMA_DIR="/opt/local/share/phpmyadmin"   # ports backend tarball target
MACPORTS_VERSION="2.12.5"      # bump when a new MacPorts release ships (see install.php)
MACPORTS_MIN_OS="10.15"        # below this: machine not viable for a modern stack

# ---- MacPorts paths (single source of truth) ----------------
PORTS_APACHE_CONF="${PORT_PREFIX}/etc/apache2/httpd.conf"
PORTS_APACHE_MODDIR="${PORT_PREFIX}/lib/apache2/modules"
PORTS_APACHE_DOCROOT="${PORT_PREFIX}/www/apache2/html"
PORTS_APACHECTL="${PORT_PREFIX}/sbin/apachectl"
PORTS_MARIADB_DATADIR="${PORT_PREFIX}/var/db/${MARIADB_PORT}"
PORTS_MARIADB_SOCKET="${PORT_PREFIX}/var/run/${MARIADB_PORT}/mysqld.sock"
PORTS_MARIADB_CONF="${PORT_PREFIX}/etc/${MARIADB_PORT}/my.cnf"
PORTS_MARIADB_INSTALL_DB="${PORT_PREFIX}/lib/${MARIADB_PORT}/bin/mariadb-install-db"
PORTS_MARIADB_SERVER_PORT="${MARIADB_PORT}-server"

if [[ -x "${PORT_PREFIX}/bin/port" ]]; then
    MACPORTS=1
fi

APACHE=0
MARIADB=0
PHP=0
PHPMYADMIN=0
STACK=0

# ---- JSON Helpers (no jq dependency) ------------------------
json_get() {
    # Usage: json_get "$json_string" "key"
    # Extremely naive JSON parser — sufficient for our flat config
    local json="$1" key="$2"
    echo "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/'
}

# ---- Config Persistence -------------------------------------
migrate_config() {
    # Pre-1.2.0 installs wrote config to ~/.config/phpup; co-locate it
    # with the stack so the config travels with the install folder.
    if [[ -f "$LEGACY_CONFIG_DIR/config.json" && ! -f "$CONFIG_FILE" ]]; then
        cp "$LEGACY_CONFIG_DIR/config.json" "$CONFIG_FILE"
        rm -rf "$LEGACY_CONFIG_DIR"
        print_ok "Migrated phpup config to $CONFIG_FILE"
    fi
}

load_config() {
    # Read config.json into globals. Missing/corrupt config falls back
    # to defaults — never blocks startup. Precedence for php_min_series:
    # PHPPUP_PHP_MIN_SERIES env > config.json > built-in default.
    local json
    if [[ -f "$CONFIG_FILE" ]]; then
        json=$(cat "$CONFIG_FILE")
    else
        return 0
    fi

    # shellcheck disable=SC2155
    local min_series mariadb_port php_port
    min_series=$(json_get "$json" "php_min_series")
    mariadb_port=$(json_get "$json" "mariadb_port")
    php_port=$(json_get "$json" "php_port")

    if [[ -n "${PHPPUP_PHP_MIN_SERIES:-}" ]]; then
        PHP_MIN_SERIES="$PHPPUP_PHP_MIN_SERIES"
    elif [[ -n "$min_series" ]]; then
        PHP_MIN_SERIES="$min_series"
    fi
    [[ -n "$mariadb_port" ]] && MARIADB_PORT="$mariadb_port"
    [[ -n "$php_port" ]] && PHP_PORT="$php_port"
}

save_config() {
    local install_path="$1"
    local apache_ver="$2"
    local mariadb_ver="$3"
    local php_ver="$4"
    local phpmyadmin_ver="$5"

    mkdir -p "$CONFIG_DIR"

    local now
    now=$(date "+%Y-%m-%dT%H:%M:%S")

    local pkg_mgr="brew"
    [[ $USE_APT == 1 ]] && pkg_mgr="apt"
    [[ $USE_PORTS == 1 ]] && pkg_mgr="port"

    cat > "$CONFIG_FILE" << EOF
{
  "install_path": "${install_path}",
  "installed_at": "${now}",
  "package_manager": "${pkg_mgr}",
  "brew_prefix": "${BREW_PREFIX}",
  "port_prefix": "${PORT_PREFIX}",
  "architecture": "${ARCH}",
  "os": "${OS_DISTRO} ${OS_VERSION}",
  "php_min_series": "${PHP_MIN_SERIES}",
  "apache_version": "${apache_ver}",
  "mariadb_version": "${mariadb_ver}",
  "php_version": "${php_ver}",
  "phpmyadmin_version": "${phpmyadmin_ver}",
  "mariadb_port": "${MARIADB_PORT}",
  "php_port": "${PHP_PORT}"
}
EOF
}

clear_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
    fi
    if [[ -d "$LEGACY_CONFIG_DIR" ]]; then
        rm -rf "$LEGACY_CONFIG_DIR"
    fi
}

# ---- Component Detection ------------------------------------
detect_apache() {
    if [[ $USE_APT == 1 ]]; then
        # ^ii = installed. rc (removed, config kept) must NOT count as installed —
        # otherwise delete leaves rc packages and reinstall skips them.
        if dpkg -l apache2 2>/dev/null | grep -q '^ii'; then
            APACHE=1
            APACHE_VERSION=$(dpkg -s apache2 2>/dev/null | grep '^Version:' | awk '{print $2}' | cut -d- -f1)
        else
            APACHE=0
            APACHE_VERSION=""
        fi
    elif [[ $USE_PORTS == 1 ]]; then
        if [[ -f "${PORT_PREFIX}/etc/apache2/httpd.conf" ]]; then
            APACHE=1
            APACHE_VERSION=$("${PORT_PREFIX}/sbin/httpd" -v 2>/dev/null | sed -n 's/.*Apache\/\([0-9.]*\).*/\1/p')
        else
            APACHE=0
            APACHE_VERSION=""
        fi
    elif [[ -d "${BREW_PREFIX}/Cellar/httpd" ]]; then
        APACHE=1
        APACHE_VERSION=$(find "${BREW_PREFIX}/Cellar/httpd" -maxdepth 1 -mindepth 1 -exec basename {} \; 2>/dev/null | sort -V | tail -1)
    else
        APACHE=0
        APACHE_VERSION=""
    fi
}

detect_mariadb() {
    if [[ $USE_APT == 1 ]]; then
        if dpkg -l mariadb-server 2>/dev/null | grep -q '^ii'; then
            MARIADB=1
            MARIADB_VERSION=$(dpkg -s mariadb-server 2>/dev/null | grep '^Version:' | awk '{print $2}' | cut -d- -f1 | cut -d: -f2 | sed 's/+maria~.*//')
        else
            MARIADB=0
            MARIADB_VERSION=""
        fi
    elif [[ $USE_PORTS == 1 ]]; then
        # MARIADB_PORT comes from config.json (persisted at install/switch);
        # this sniff is a last-resort migration shim for configs written
        # before ports were persisted (pre-1.1.0). If the configured series
        # datadir is absent but any other mariadb-1[12].* datadir exists,
        # adopt that series so the stack still resolves.
        if [[ ! -d "${PORT_PREFIX}/var/db/${MARIADB_PORT}" ]]; then
            local found_series
            found_series=$(find "${PORT_PREFIX}/var/db" -maxdepth 1 -type d -name 'mariadb-1[12].*' 2>/dev/null | sed 's@.*/@@' | sort -V | tail -1)
            [[ -n "$found_series" ]] && MARIADB_PORT="$found_series"
        fi
        if [[ -d "${PORT_PREFIX}/var/db/${MARIADB_PORT}" ]]; then
            MARIADB=1
            # MacPorts installs the client at the versioned path (no
            # /opt/local/bin/mariadb symlink) and prints "from X.Y.Z-MariaDB"
            # (not "Distrib X.Y.Z" like brew). Try the versioned client first,
            # fall back to the generic path, then extract any dotted version.
            local maria_client="${PORT_PREFIX}/lib/${MARIADB_PORT}/bin/mariadb"
            MARIADB_VERSION=$("$maria_client" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            [[ -z "$MARIADB_VERSION" ]] && \
                MARIADB_VERSION=$("${PORT_PREFIX}/bin/mariadb" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        else
            MARIADB=0
            MARIADB_VERSION=""
        fi
    elif [[ -d "${BREW_PREFIX}/Cellar/mariadb" ]]; then
        MARIADB=1
        MARIADB_VERSION=$(find "${BREW_PREFIX}/Cellar/mariadb" -maxdepth 1 -mindepth 1 -exec basename {} \; 2>/dev/null | sort -V | tail -1)
    else
        MARIADB=0
        MARIADB_VERSION=""
    fi
}

# Resolve the ACTIVE Homebrew PHP formula from the linked binary:
# meta 'php' (Cellar/php) or a versioned one (Cellar/php@X.Y after a fu
# switch). Falls back to 'php' when nothing is linked.
brew_active_php() {
    local php_link
    php_link=$(readlink "${BREW_PREFIX}/bin/php" 2>/dev/null || true)
    if [[ "$php_link" == *"/php@"* ]]; then
        printf 'php@%s' "$(printf '%s' "$php_link" | sed -n 's|.*/php@\([0-9.]*\)/.*|\1|p')"
    else
        printf 'php'
    fi
}

APT_PHP_BIN_CACHE=""

apt_php_bin() {
    # The system PHP binary phpup manages on apt (update-alternatives).
    # Resolves via the alternatives link so Homebrew/getphp shims on PATH
    # (brew shellenv in ~/.bashrc) can't shadow it. Memoized: the link only
    # changes at the two update-alternatives sites, which clear the cache.
    if [[ -n "$APT_PHP_BIN_CACHE" && -x "$APT_PHP_BIN_CACHE" ]]; then
        echo "$APT_PHP_BIN_CACHE"
        return
    fi
    local bin
    bin=$(readlink -f /etc/alternatives/php 2>/dev/null || true)
    if [[ -z "$bin" || ! -x "$bin" ]]; then
        bin=$(command -v php 2>/dev/null || true)
    fi
    if [[ -n "$bin" && -x "$bin" ]]; then
        APT_PHP_BIN_CACHE="$bin"
        echo "$bin"
    fi
}

detect_php() {
    if [[ $USE_APT == 1 ]]; then
        if command -v php &>/dev/null 2>&1; then
            PHP=1
            # Report the active version from the managed binary (versioned
            # installs have no php meta package)
            PHP_VERSION=$("$(apt_php_bin)" -r 'echo PHP_VERSION;' 2>/dev/null || dpkg -s php 2>/dev/null | grep '^Version:' | awk '{print $2}' | cut -d- -f1 | cut -d: -f2)
        else
            PHP=0
            PHP_VERSION=""
        fi
    elif [[ $USE_PORTS == 1 ]]; then
        if [[ -x "${PORT_PREFIX}/bin/php" ]]; then
            PHP=1
            PHP_VERSION=$("${PORT_PREFIX}/bin/php" -r 'echo PHP_VERSION;' 2>/dev/null)
        else
            PHP=0
            PHP_VERSION=""
        fi
    elif [[ -d "${BREW_PREFIX}/Cellar/php" ]] || compgen -G "${BREW_PREFIX}/Cellar/php@*" >/dev/null 2>&1; then
        PHP=1
        # Report the ACTIVE version from the linked binary — after a fu switch
        # the linked formula may be a versioned one (php@8.4), NOT the meta
        # 'php'; the Cellar/php dir alone would keep reporting the old meta.
        PHP_VERSION=$(php -r 'echo PHP_VERSION;' 2>/dev/null)
        if [[ -z "$PHP_VERSION" ]]; then
            # Nothing linked/in PATH — fall back to the highest installed
            # version across the meta formula and any php@X.Y kegs.
            local best_ver=""
            for d in "${BREW_PREFIX}/Cellar/php" "${BREW_PREFIX}"/Cellar/php@*; do
                [[ -d "$d" ]] || continue
                local v
                v=$(find "$d" -maxdepth 1 -mindepth 1 -exec basename {} \; 2>/dev/null | sort -V | tail -1)
                if [[ -n "$v" && "$v" > "$best_ver" ]]; then
                    best_ver="$v"
                fi
            done
            PHP_VERSION="$best_ver"
        fi
    else
        PHP=0
        PHP_VERSION=""
    fi
}

detect_phpmyadmin() {
    if [[ $USE_APT == 1 ]]; then
        # Check tarball install first (phpup-version.txt written by install_pma_tarball)
        if [[ -f /usr/share/phpmyadmin/phpup-version.txt ]]; then
            PHPMYADMIN=1
            PHPMYADMIN_VERSION=$(cat /usr/share/phpmyadmin/phpup-version.txt)
        elif dpkg -l phpmyadmin 2>/dev/null | grep -q '^ii'; then
            PHPMYADMIN=1
            PHPMYADMIN_VERSION=$(dpkg -s phpmyadmin 2>/dev/null | grep '^Version:' | awk '{print $2}' | cut -d- -f1 | cut -d: -f2)
        else
            PHPMYADMIN=0
            PHPMYADMIN_VERSION=""
        fi
    elif [[ $USE_PORTS == 1 ]]; then
        if [[ -f "${PMA_DIR}/phpup-version.txt" ]]; then
            PHPMYADMIN=1
            PHPMYADMIN_VERSION=$(cat "${PMA_DIR}/phpup-version.txt")
        else
            PHPMYADMIN=0
            PHPMYADMIN_VERSION=""
        fi
    elif [[ -d "${BREW_PREFIX}/Cellar/phpmyadmin" ]]; then
        PHPMYADMIN=1
        PHPMYADMIN_VERSION=$(find "${BREW_PREFIX}/Cellar/phpmyadmin" -maxdepth 1 -mindepth 1 -exec basename {} \; 2>/dev/null | sort -V | tail -1)
    else
        PHPMYADMIN=0
        PHPMYADMIN_VERSION=""
    fi
}

is_service_running() {
    local svc="$1"
    if [[ $USE_APT == 1 ]]; then
        case "$svc" in
            apache|httpd)
                systemctl is-active --quiet apache2 2>/dev/null && return 0 || return 1
                ;;
            mariadb)
                systemctl is-active --quiet mariadb 2>/dev/null && return 0 || return 1
                ;;
            php)
                # FPM units don't reliably match the php*-fpm glob (verified:
                # systemd returns no match), so check the ACTIVE version explicitly
                local _fpm
                _fpm=$(fpm_active_version || true)
                [[ -n "$_fpm" ]] && systemctl is-active --quiet "php${_fpm}-fpm" 2>/dev/null && return 0 || return 1
                ;;
            *) return 1 ;;
        esac
    else
        case "$svc" in
            apache|httpd)
                pgrep -x "httpd" &>/dev/null && return 0 || return 1
                ;;
            mariadb)
                # MacPorts runs the server as "mysqld" (no mariadbd binary name);
                # brew/apt use "mariadbd". Match either so detection works on all
                # three backends.
                { pgrep -x "mariadbd" &>/dev/null || pgrep -x "mysqld" &>/dev/null; } && return 0 || return 1
                ;;
            php)
                if [[ $USE_PORTS == 1 ]]; then
                    # mod_php inside Apache — no standalone PHP-FPM service
                    is_service_running apache && return 0 || return 1
                fi
                pgrep -f "(^|/)php-fpm" &>/dev/null && return 0 || return 1
                ;;
            *) return 1 ;;
        esac
    fi
}

# ---- PHP-FPM Helpers (apt) ----------------------------------
fpm_service()       { echo "php${1}-fpm"; }
fpm_socket()        { echo "/run/php/php${1}-fpm.sock"; }
apache_fpm_conf()   { echo "/etc/apache2/conf-available/phpup-php-fpm.conf"; }

fpm_versions_installed() {
    # Installed PHP-FPM versions, e.g. "8.4 8.5" (excludes the php-fpm meta)
    dpkg -l 'php*-fpm' 2>/dev/null | awk '/^ii/{print $2}' | grep -E '^php[0-9]' | sed 's/^php\([0-9.]*\)-fpm$/\1/' | sort -V
}

fpm_active_version() {
    # The FPM version phpup currently wires into Apache: the managed conf is the
    # source of truth, then an enabled FPM service, then the highest installed.
    local conf ver
    conf=$(apache_fpm_conf)
    if [[ -f "$conf" ]]; then
        ver=$(grep -oP 'php\K[0-9.]+(?=-fpm\.sock)' "$conf" 2>/dev/null | head -1)
        [[ -n "$ver" ]] && { echo "$ver"; return 0; }
    fi
    local v
    for v in $(fpm_versions_installed | sort -Vr); do
        if systemctl is-enabled "php${v}-fpm" 2>/dev/null | grep -q enabled; then
            echo "$v"; return 0
        fi
    done
    return 1
}

write_apache_fpm_conf() {
    # Regenerate the phpup-managed Apache PHP-FPM config for $1. Idempotent:
    # full rewrite each time; the first run keeps a .phpup.bak of the original.
    local version="$1" conf sock
    conf=$(apache_fpm_conf)
    sock=$(fpm_socket "$version")
    [[ -f "$conf" && ! -f "${conf}.phpup.bak" ]] && sudo cp "$conf" "${conf}.phpup.bak"
    sudo tee "$conf" > /dev/null <<EOF
# phpup — PHP-FPM integration (managed; regenerated on version switch)
<FilesMatch "\.php$">
    SetHandler "proxy:unix:${sock}|fcgi://localhost"
</FilesMatch>
<Proxy "fcgi://localhost/">
    Require all granted
</Proxy>
EOF
    sudo a2enconf phpup-php-fpm 2>/dev/null || true
}

enable_apache_fpm_modules() {
    # proxy + proxy_fcgi + setenvif — the modules FastCGI proxying needs
    local mod
    for mod in proxy proxy_fcgi setenvif; do
        sudo a2enmod "$mod" 2>/dev/null || true
    done
}

disable_mod_php() {
    # Disable any enabled mod_php module (php7.4/php8.5…) — FPM is the runtime now
    local mod
    mod=$(a2query -m 2>/dev/null | awk '{print $1}' | grep '^php' | head -1)
    if [[ -n "$mod" ]]; then
        sudo a2dismod "$mod" 2>/dev/null || true
        print_ok "Disabled Apache PHP module ($mod)"
    fi
}

# Wire Apache to proxy .php to the active FPM socket: write the phpup-managed
# conf, ensure FastCGI modules, disable mod_php. The caller reloads Apache
# (reload semantics differ per context).
wire_apache_fpm() {
    local version="$1"
    write_apache_fpm_conf "$version"
    enable_apache_fpm_modules
    disable_mod_php
}

# Enable + start the given FPM version; disable + stop every other installed one.
set_fpm_active() {
    local version="$1" installed="$2" v
    for v in $installed; do
        if [[ "$v" == "$version" ]]; then
            sudo systemctl enable "php${v}-fpm" 2>/dev/null || true
            sudo systemctl restart "php${v}-fpm" 2>/dev/null || true
        else
            sudo systemctl disable "php${v}-fpm" 2>/dev/null || true
            sudo systemctl stop "php${v}-fpm" 2>/dev/null || true
        fi
    done
}

switch_fpm_apt() {
    # Switch the Apache PHP-FPM runtime to $1, with rollback: on failure the
    # previous FPM version + Apache conf are restored.
    local target="$1"
    local prev conf conf_backup installed
    prev=$(fpm_active_version || true)
    conf=$(apache_fpm_conf)
    installed=$(fpm_versions_installed)
    [[ -f "$conf" ]] && conf_backup=$(cat "$conf")

    set_fpm_active "$target" "$installed"

    wire_apache_fpm "$target"
    sudo systemctl reload apache2 2>/dev/null || sudo systemctl restart apache2 2>/dev/null || true

    # Verify the target FPM is actually up before declaring success
    if ! systemctl is-active --quiet "php${target}-fpm" 2>/dev/null; then
        print_err "php${target}-fpm failed to start"
        # Always restore a sane Apache conf — never leave it pointing at a dead socket
        if [[ -n "$conf_backup" ]]; then
            printf '%s\n' "$conf_backup" | sudo tee "$conf" > /dev/null
        else
            sudo rm -f "$conf" 2>/dev/null || true
        fi
        if [[ -n "$prev" ]]; then
            print_warn "Restoring previous PHP-FPM ${prev}..."
            set_fpm_active "$prev" "$installed"
            # CLI follows the FPM runtime — restore the previous alternative too
            sudo update-alternatives --set php "/usr/bin/php${prev}" 2>/dev/null || true
            APT_PHP_BIN_CACHE=""
        fi
        sudo systemctl reload apache2 2>/dev/null || true
        return 1
    fi
    return 0
}

verify_apache_php() {
    # Version string Apache actually serves through PHP-FPM (phpinfo probe)
    local probe="${DOC_ROOT}/phpinfo.php"
    if [[ ! -f "$probe" ]]; then
        printf "<?php echo PHP_VERSION; ?>\n" | sudo tee "$probe" > /dev/null
    fi
    curl -s --max-time 5 "http://localhost/phpinfo.php" 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1
}


# True if any process matching the pgrep args ($@) belongs to the ACTIVE
# backend. pgrep -x alone matches whichever stack owns the name (brew AND
# ports both run "httpd", and MacPorts' MariaDB daemon is "mysqld" while
# brew/apt run "mariadbd") — on a dual-stack machine that false-positives.
# The process command line includes the binary/config path, which pins it to
# one backend. brew php-fpm's master prints "php-fpm: master process
# (/usr/local/etc/php/8.4/php-fpm.conf)" — no binary path in argv[0], but the
# config path carries the prefix, so grep the whole command line.
stack_proc() {
    local prefix="$PORT_PREFIX"
    [[ $USE_PORTS == 1 ]] || prefix="$BREW_PREFIX"
    # Empty prefix (broken/absent brew with USE_PORTS=0) would match every
    # process — degenerate to the old false-positive. Treat as no-match.
    [[ -n "$prefix" ]] || return 1
    local pid
    for pid in $(pgrep "$@" 2>/dev/null); do
        ps -o command= -p "$pid" 2>/dev/null | grep -qF "$prefix" && return 0
    done
    return 1
}

stack_kill() {
    # Kill processes matching the pgrep patterns ($2..) that belong to the
    # ACTIVE backend (prefix-pinned via the same rule as stack_proc) — so
    # stopping one stack never takes down a coexisting stack's processes.
    # Usage: stack_kill <pgrep-flag> <pattern...>  (pgrep -x accepts only ONE
    # pattern, so run it once per pattern).
    local flag="$1"; shift
    local prefix="$PORT_PREFIX"
    [[ $USE_PORTS == 1 ]] || prefix="$BREW_PREFIX"
    local _pat _sp
    for _pat in "$@"; do
        for _sp in $(pgrep "$flag" "$_pat" 2>/dev/null); do
            ps -o command= -p "$_sp" 2>/dev/null | grep -qF "$prefix" && kill "$_sp" 2>/dev/null || true
        done
    done
}

detect_all() {
    if [[ $USE_APT == 0 ]] && [[ $HOMEBREW == 0 ]] && [[ $MACPORTS == 0 ]]; then
        return
    fi
    detect_apache
    detect_mariadb
    detect_php
    detect_phpmyadmin

    if [[ $APACHE == 1 && $MARIADB == 1 && $PHP == 1 && $PHPMYADMIN == 1 ]]; then
        STACK=1
    fi
}

# ---- Utility Functions --------------------------------------
print_ok()    { printf "[${GREEN}  OK  ${RESET}] %s\n" "$1"; }
print_err()   { printf "[${RED} ERROR ${RESET}] %s\n" "$1"; }
print_warn()  { printf "[${YELLOW}  WAIT ${RESET}] %s\n" "$1"; }
print_info()  { printf "${CYAN}%s${RESET}\n" "$1"; }

# 32-byte phpMyAdmin blowfish secret. PMA warns on missing AND on >32 bytes —
# token_hex(16) is exactly 32 chars = 32 bytes. Generated per-install; never a
# static known-default.
pma_secret() {
    python3 -c 'import secrets; print(secrets.token_hex(16))' 2>/dev/null \
        || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# Quiet apt update: suppress the "no stable CLI" warning apt emits when its
# output is piped (non-TTY), plus the "can be upgraded" notices. Real errors pass through.
apt_update_quiet() {
    sudo apt update -qq > /dev/null 2>&1 || true
}

# ---- Prerequisites Check ------------------------------------
check_prerequisites() {
    # Linux: apt prerequisites
    if [[ "${OS_TYPE}" == "linux-gnu"* ]]; then
        local need_apt=0
        for pkg in build-essential procps file git curl; do
            if ! dpkg -s "$pkg" &>/dev/null; then
                need_apt=1
                break
            fi
        done
        if [[ $need_apt == 1 ]]; then
            printf "\n"
            print_warn "Installing Linux prerequisites (build-essential, procps, file, git, curl)..."
            apt_update_quiet && sudo apt install -y build-essential procps file git curl
            print_ok "Linux prerequisites installed"
        fi
    fi

    # macOS: Xcode CLT
    if [[ "${OS_TYPE}" == "darwin"* ]]; then
        if ! xcode-select -p &>/dev/null; then
            printf "\n"
            print_warn "Xcode Command Line Tools required. Starting installation..."
            xcode-select --install 2>/dev/null || true
            printf "\n"
            print_warn "Press Enter after the Xcode CLT installation completes..."
            # Recheck CLT in a loop — never proceed into source builds without it
            # (missing CLT wastes an hour of build time on older Macs).
            while ! xcode-select -p &>/dev/null; do
                print_warn "Xcode CLT is still not installed. Waiting for installation to finish..."
                print_warn "Press Enter once the Xcode CLT installation has completed..."
                read -r || return 1
            done
            print_ok "Xcode CLT detected."
        fi
        if [[ $USE_PORTS == 1 ]]; then
            print_info "MacPorts backend: packages compile from source — Xcode CLT is required."
            # CLT 16+ installer bug (MacPorts hotlist #clts16): updating an older
            # CLT leaves /usr/include/c++/v1 stripped to a __cxx_version marker —
            # clang then fails EVERY C++ compile ('new' file not found) even when
            # the SDK is intact. Detect BEFORE a ports source build burns 10-20
            # minutes. A healthy CLT has ~185 headers; <10 means damage.
            local clt_cpp="${DEVELOPER_DIR:-$(xcode-select -p)}/usr/include/c++/v1"
            if [[ -d "$clt_cpp" ]] && [[ "$(ls -A "$clt_cpp" 2>/dev/null | wc -l | tr -d ' ')" -lt 10 ]]; then
                print_warn "CLT C++ headers appear damaged (${clt_cpp} is near-empty)."
                print_warn "This breaks source C++ builds (e.g. MariaDB). Fix:"
                print_warn "  sudo rm -rf /Library/Developer/CommandLineTools/usr/include/c++"
                print_warn "  (MacPorts hotlist: https://trac.macports.org/wiki/ProblemHotlist#clts16)"
            fi
        fi
        # sudo timestamp dir world-writable (e.g. 702/733) makes sudo distrust
        # the cache and prompt on EVERY invocation — the "password spam" UX
        # (seen live 2026-08-13: 3-4 instant asks, no 5-min caching). One-line
        # fix; detection signature: writable but NOT readable (the broken modes
        # grant others write-only; a healthy 755 dir is readable).
        if [[ -d /var/db/sudo/ts ]] && [[ -w /var/db/sudo/ts ]] && [[ ! -r /var/db/sudo/ts ]]; then
            print_warn "sudo timestamp dir /var/db/sudo/ts is world-writable — sudo cannot cache credentials (prompts every time)."
            sudo chmod 755 /var/db/sudo /var/db/sudo/ts 2>/dev/null && print_ok "Fixed sudo ts dir permissions (755)" \
                || print_warn "Could not fix — run: sudo chmod 755 /var/db/sudo /var/db/sudo/ts"
        fi
    fi
}

check_brew_path() {
    # Ensure brew is in PATH (critical on Linux where it may not auto-configure)
    if [[ $HOMEBREW == 1 ]] && ! command -v brew &>/dev/null; then
        if [[ -f /home/linuxbrew/.linuxbrew/bin/brew ]]; then
            eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
        elif [[ -f /usr/local/bin/brew ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
        elif [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
    fi
}

# ---- Install Homebrew ---------------------------------------
install_homebrew() {
    if [[ $HOMEBREW == 1 ]]; then
        return
    fi

    printf "\n"
    print_warn "Homebrew not found. Installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Post-install PATH setup
    if [[ "${OS_TYPE}" == "linux-gnu"* ]]; then
        if [[ -f /home/linuxbrew/.linuxbrew/bin/brew ]]; then
            eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
            if ! grep -q 'linuxbrew/bin/brew shellenv' "$SHELL_PROFILE" 2>/dev/null; then
                echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "$SHELL_PROFILE"
            fi
            print_ok "Added Homebrew to PATH in ${SHELL_PROFILE}"
        fi
    fi

    if command -v brew &>/dev/null; then
        HOMEBREW=1
        BREW_PREFIX=$(brew --prefix)
        print_ok "Homebrew installed successfully"
    else
        print_err "Homebrew installation failed"
        exit 1
    fi
}

# ---- Install MacPorts ---------------------------------------
install_macports() {
    [[ $MACPORTS == 1 ]] && return
    printf "\n"
    print_warn "MacPorts not found. Installing MacPorts ${MACPORTS_VERSION}..."
    local osver token
    osver=$(sw_vers -productVersion)
    if [[ "${osver%%.*}" -ge 11 ]]; then
        # 11+ tokens are single-component (11, 12, ... 26) — drop the minor
        osver="${osver%%.*}"
    else
        # 10.x tokens are two-component (10.6 ... 10.15) — keep major.minor
        osver=$(echo "$osver" | cut -d. -f1-2)
    fi
    case "$osver" in
        10.6) token="10.6-SnowLeopard";; 10.7) token="10.7-Lion";;
        10.8) token="10.8-MountainLion";; 10.9) token="10.9-Mavericks";;
        10.10) token="10.10-Yosemite";;  10.11) token="10.11-ElCapitan";;
        10.12) token="10.12-Sierra";;    10.13) token="10.13-HighSierra";;
        10.14) token="10.14-Mojave";;    10.15) token="10.15-Catalina";;
        11) token="11-BigSur";; 12) token="12-Monterey";; 13) token="13-Ventura";;
        14) token="14-Sonoma";; 15) token="15-Sequoia";; 26) token="26-Tahoe";;
        *) print_err "No MacPorts installer for macOS ${osver} — this machine is not viable for a modern web stack."; return 1 ;;
    esac
    local ver="$MACPORTS_VERSION"
    local url="https://github.com/macports/macports-base/releases/download/v${ver}/MacPorts-${ver}-${token}.pkg"
    local pkg="/tmp/MacPorts-${ver}-${token}.pkg"
    if ! curl -fsSL --connect-timeout 30 "$url" -o "$pkg"; then
        print_err "Failed to download MacPorts installer: $url"
        return 1
    fi
    sudo installer -pkg "$pkg" -target / || { print_err "MacPorts installer failed"; return 1; }
    rm -f "$pkg"
    export PATH="${PORT_PREFIX}/bin:${PORT_PREFIX}/sbin:${PATH}"
    MACPORTS=1
    print_ok "MacPorts installed"
    print_info "Updating ports tree (first selfupdate can take a few minutes)..."
    sudo "${PORT_PREFIX}/bin/port" -v selfupdate || print_warn "port selfupdate failed — ports tree may be stale"
}

# ---- PATH Management ----------------------------------------
manage_path() {
    # On Linux/apt, binaries are already in standard system paths (/usr/bin)
    if [[ $USE_APT == 1 ]]; then
        print_ok "php and mysql available via system PATH"
        return
    fi

    # MacPorts backend — /opt/local must come BEFORE /usr/bin so the active
    # MacPorts php/mysql win over Apple's bundled binaries (e.g. /usr/bin/php
    # 7.3.x on Catalina). Two layers:
    #   1. /etc/paths.d/macports — self-heal if the pkg installer missed it
    #      (adds /opt/local to new login shells, but AFTER /usr/bin)
    #   2. SHELL_PROFILE prepend — the layer that actually beats /usr/bin
    if [[ $USE_PORTS == 1 ]]; then
        local macports_paths_file="$MACPORTS_PATHS_FILE"
        if [[ -f "$macports_paths_file" ]] && grep -q '^/opt/local/bin$' "$macports_paths_file" 2>/dev/null; then
            print_ok "MacPorts paths.d entry present (${macports_paths_file})"
        else
            printf '/opt/local/bin\n/opt/local/sbin\n' | sudo tee "$macports_paths_file" >/dev/null 2>&1
            print_ok "Created ${macports_paths_file} for new login shells"
        fi

        local marker="# phpup: keep MacPorts binaries ahead of system (/usr/bin)"
        local path_line='export PATH="/opt/local/bin:/opt/local/sbin:$PATH"'
        if grep -qF "$path_line" "$SHELL_PROFILE" 2>/dev/null; then
            print_ok "MacPorts binaries ahead of /usr/bin in ${SHELL_PROFILE}"
        else
            printf '\n%s\n%s\n' "$marker" "$path_line" >> "$SHELL_PROFILE"
            print_ok "Prepended /opt/local/bin to PATH in ${SHELL_PROFILE}"
        fi

        if [[ -x "${PORT_PREFIX}/bin/php" ]]; then
            print_ok "php available: ${PORT_PREFIX}/bin/php"
        fi
        if [[ -x "${PORT_PREFIX}/bin/mysql" ]] || [[ -x "${PORT_PREFIX}/bin/mariadb" ]]; then
            print_ok "mariadb client available: ${PORT_PREFIX}/bin/mysql"
        fi
        return
    fi

    # On macOS, brew is already in PATH. On Linux, ensure shellenv is in profile.
    if [[ "${OS_TYPE}" == "linux-gnu"* ]]; then
        if ! grep -q 'linuxbrew/bin/brew shellenv' "$SHELL_PROFILE" 2>/dev/null; then
            if [[ -f /home/linuxbrew/.linuxbrew/bin/brew ]]; then
                echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "$SHELL_PROFILE"
                print_ok "Added Homebrew to PATH in ${SHELL_PROFILE}"
            fi
        fi
    fi

    # Verify php and mysql are reachable
    local brew_bin="${BREW_PREFIX}/bin"
    if [[ -x "${brew_bin}/php" ]]; then
        print_ok "php available: ${brew_bin}/php"
    fi
    if [[ -x "${brew_bin}/mariadb" ]] || [[ -x "${brew_bin}/mysql" ]]; then
        print_ok "mariadb client available: ${brew_bin}/mariadb"
    fi
}

# ---- Dashboard Display --------------------------------------
show_banner() {
    printf "\n"
    printf "┌─────────────────────────────┐\n"
    printf "│    ____  _   _ ____         │\n"
    printf "│   |  _ \\| | | |  _ \\  /\\    │\n"
    printf "│   | |_) | |_| | |_) | || |  │\n"
    printf "│   |  __/|  _  |  __/| || |  │\n"
    printf "│   |_|   |_| |_|_|    ||_|   │\n"
    printf "│         "
    printf "${YELLOW}▲${RESET} ${GREEN}▲${RESET} ${CYAN}▲${RESET}"
    printf "               │\n"
    printf "│         "
    printf "${BLUE}phpup${RESET}"
    printf "               │\n"
    printf "└─────────────────────────────┘\n"
    printf "\n"
}

show_dashboard() {
    show_banner

    # Architecture line
    if [[ $USE_APT == 1 ]]; then
        printf "Architecture: ${CYAN}%s${RESET} | OS: ${CYAN}%s %s${RESET} | Package: ${CYAN}apt${RESET}\n" \
            "$ARCH" "$OS_DISTRO" "$OS_VERSION"
    elif [[ $USE_PORTS == 1 ]]; then
        printf "Architecture: ${CYAN}%s${RESET} | OS: ${CYAN}%s %s${RESET} | Package: ${CYAN}port${RESET}\n" \
            "$ARCH" "$OS_NAME" "$OS_VERSION"
    else
        printf "Architecture: ${CYAN}%s${RESET} | OS: ${CYAN}%s %s${RESET} | Homebrew: ${CYAN}%s${RESET}\n" \
            "$ARCH" "$OS_NAME" "$OS_VERSION" "$BREW_PREFIX"
    fi
    printf "\n"

    # Stack Status
    printf "${BOLD}Your Web Stack:${RESET}\n"
    printf "~~~~~~~~~~~~~~~\n"

    printf "%-10s -----> " "Apache"
    if [[ $APACHE == 1 ]]; then
        printf "${GREEN}%s${RESET}\n" "$APACHE_VERSION"
    else
        printf "${RED}Not installed${RESET}\n"
    fi

    printf "%-10s -----> " "MariaDB"
    if [[ $MARIADB == 1 ]]; then
        printf "${GREEN}%s${RESET}\n" "$MARIADB_VERSION"
    else
        printf "${RED}Not installed${RESET}\n"
    fi

    printf "%-10s -----> " "PHP"
    if [[ $PHP == 1 ]]; then
        printf "${GREEN}%s${RESET}\n" "$PHP_VERSION"
    else
        printf "${RED}Not installed${RESET}\n"
    fi

    printf "%-10s -----> " "phpMyAdmin"
    if [[ $PHPMYADMIN == 1 ]]; then
        printf "${GREEN}%s${RESET}\n" "$PHPMYADMIN_VERSION"
    else
        printf "${RED}Not installed${RESET}\n"
    fi

    printf "\n"

    # Service Status
    printf "${BOLD}Service Status:${RESET}\n"
    printf "~~~~~~~~~~~~~~~\n"

    printf "%-10s -----> " "Apache"
    if [[ $APACHE == 1 ]]; then
        is_service_running apache && printf "${GREEN}Running${RESET}\n" || printf "${RED}Stopped${RESET}\n"
    else
        printf "${RED}Not available${RESET}\n"
    fi

    printf "%-10s -----> " "MariaDB"
    if [[ $MARIADB == 1 ]]; then
        is_service_running mariadb && printf "${GREEN}Running${RESET}\n" || printf "${RED}Stopped${RESET}\n"
    else
        printf "${RED}Not available${RESET}\n"
    fi

    printf "%-10s -----> " "PHP-FPM"
    if [[ $PHP == 1 ]]; then
        if [[ $USE_APT == 1 ]]; then
            local fpm_ver
            fpm_ver=$(fpm_active_version || true)
            if [[ -n "$fpm_ver" ]]; then
                if systemctl is-active --quiet "php${fpm_ver}-fpm" 2>/dev/null; then
                    printf "${GREEN}Running${RESET} (%s)\n" "$fpm_ver"
                else
                    printf "${RED}Stopped${RESET} (%s)\n" "$fpm_ver"
                fi
            elif dpkg -l 'php*-fpm' 2>/dev/null | grep -q '^ii'; then
                printf "${RED}FPM installed — none active${RESET}\n"
            else
                is_service_running apache && printf "${GREEN}Active (mod_php)${RESET}\n" || printf "${RED}Stopped${RESET}\n"
            fi
        elif [[ $USE_PORTS == 1 ]]; then
            # ports: mod_php inside Apache (phpXX-apache2handler)
            is_service_running apache && printf "${GREEN}Active (mod_php)${RESET}\n" || printf "${RED}Stopped${RESET}\n"
        else
            is_service_running php && printf "${GREEN}Running${RESET}\n" || printf "${RED}Stopped${RESET}\n"
        fi
    else
        printf "${RED}Not available${RESET}\n"
    fi

    printf "\n"

    # Quick Info (only when stack is complete)
    if [[ $STACK == 1 ]]; then
        printf "${BOLD}Quick Info:${RESET}\n"
        printf "~~~~~~~~~~~\n"
        printf "Where to put website files?  ${CYAN}%s${RESET}\n" "$DOC_ROOT"
        printf "How to test your PHP setup?  ${CYAN}http://localhost/phpinfo.php${RESET}\n"
        printf "Where to access phpMyAdmin?  ${CYAN}http://localhost/phpmyadmin${RESET}\n"
        printf "How to log into phpMyAdmin?  ${CYAN}Username: root | Password: [blank]${RESET}\n"
        printf "\n"
    fi

    # Commands
    printf "${BOLD}Stack Commands:${RESET}\n"
    printf "~~~~~~~~~~~~~~~\n"

    if [[ $STACK == 0 ]]; then
        printf "${CYAN}${UNDERLINE}I${RESET}${CYAN}nstall${RESET}  Install the PHP stack.\n"
    else
        printf "${CYAN}${UNDERLINE}U${RESET}${CYAN}pdate${RESET}   Update components to latest versions.\n"
        printf "${CYAN}${UNDERLINE}R${RESET}${CYAN}estart${RESET}  Restart all services.\n"
        printf "${CYAN}${UNDERLINE}S${RESET}${CYAN}tart${RESET}    Start / Stop services.\n"
        printf "${CYAN}${UNDERLINE}D${RESET}${CYAN}elete${RESET}   Delete the web stack.\n"
    fi
    printf "${CYAN}${UNDERLINE}Q${RESET}${CYAN}uit${RESET}     Quit this application.\n"

    printf "\n"
}

# ---- Service Management -------------------------------------
start_services() {
    print_info "Starting services..."
    if [[ $USE_APT == 1 ]]; then
        [[ $APACHE == 1 ]] && sudo systemctl start apache2 2>/dev/null
        [[ $MARIADB == 1 ]] && sudo systemctl start mariadb 2>/dev/null
        # Start only the ACTIVE FPM version — others stay stopped
        if [[ $PHP == 1 ]]; then
            local fpm_ver
            fpm_ver=$(fpm_active_version || true)
            [[ -n "$fpm_ver" ]] && sudo systemctl start "php${fpm_ver}-fpm" 2>/dev/null
        fi
    elif [[ $USE_PORTS == 1 ]]; then
        if [[ $APACHE == 1 ]]; then
            sudo "${PORT_PREFIX}/bin/port" load apache2 >/dev/null 2>&1
            local apache_started=0
            for ((_i=0; _i<10; _i++)); do
                if stack_proc -x httpd &>/dev/null; then print_ok "Apache started on port 80"; apache_started=1; break; fi
                sleep 1
            done
            if [[ $apache_started == 0 ]]; then
                print_err "Apache may have failed to start — check ${LOGS_DIR}/apache_error.log"
                sudo "${PORT_PREFIX}/sbin/apachectl" configtest 2>&1 | tail -3
            fi
        fi
        if [[ $MARIADB == 1 ]]; then
            sudo "${PORT_PREFIX}/bin/port" load "${MARIADB_PORT}-server" >/dev/null 2>&1
            local mariadb_started=0
            for ((_i=0; _i<10; _i++)); do
                if { stack_proc -x mariadbd &>/dev/null || stack_proc -x mysqld &>/dev/null; }; then print_ok "MariaDB started"; mariadb_started=1; break; fi
                sleep 1
            done
            if [[ $mariadb_started == 0 ]]; then
                print_err "MariaDB failed to start — check ${PORT_PREFIX}/var/log/${MARIADB_PORT}/mariadb_error.log"
                tail -50 "${PORT_PREFIX}/var/log/${MARIADB_PORT}/mariadb_error.log" 2>/dev/null || \
                    tail -50 "${PORT_PREFIX}/var/db/${MARIADB_PORT}/"*.err 2>/dev/null || true
            fi
        fi
        # No PHP service — mod_php inside Apache
    else
        if [[ $APACHE == 1 ]]; then
            sudo "${BREW_PREFIX}/bin/apachectl" restart >/dev/null 2>&1
            sleep 1
            if stack_proc -x httpd &>/dev/null; then
                print_ok "Apache started on port 80"
            else
                print_err "Apache may have failed to start — check ${LOGS_DIR}/apache_error.log"
                sudo "${BREW_PREFIX}/bin/apachectl" configtest 2>&1 | tail -3
            fi
        fi

        if [[ $MARIADB == 1 ]]; then
            brew services start mariadb 2>/dev/null
            local mariadb_started=0
            for ((_i=0; _i<5; _i++)); do
                if { stack_proc -x mariadbd &>/dev/null || stack_proc -x mysqld &>/dev/null; }; then print_ok "MariaDB started"; mariadb_started=1; break; fi
                sleep 1
            done
            if [[ $mariadb_started == 0 ]]; then
                print_err "MariaDB failed to start — check ${LOGS_DIR}/mariadb_error.log"
                tail -50 "${LOGS_DIR}/mariadb_error.log" 2>/dev/null || true
            fi
        fi

        if [[ $PHP == 1 ]]; then
            local brew_php_svc
            brew_php_svc=$(brew_active_php)
            brew services start "$brew_php_svc" 2>/dev/null
            for ((_i=0; _i<5; _i++)); do
                stack_proc -f "(^|/)php-fpm" &>/dev/null && { print_ok "PHP-FPM started"; break; }
                sleep 1
            done
            stack_proc -f "(^|/)php-fpm" &>/dev/null || print_err "PHP-FPM failed to start — check ${LOGS_DIR}/php_errors.log"
        fi
    fi
    sleep 2
    print_ok "Services started"
}

stop_services() {
    print_info "Stopping services..."
    if [[ $USE_APT == 1 ]]; then
        [[ $APACHE == 1 ]] && sudo systemctl stop apache2 2>/dev/null
        [[ $MARIADB == 1 ]] && sudo systemctl stop mariadb 2>/dev/null
        # php*-fpm glob does NOT match FPM units (systemd quirk) — stop each
        # installed FPM version explicitly so nothing is left running
        if [[ $PHP == 1 ]]; then
            local _f
            for _f in $(fpm_versions_installed); do
                sudo systemctl stop "php${_f}-fpm" 2>/dev/null || true
            done
        fi
    elif [[ $USE_PORTS == 1 ]]; then
        [[ $APACHE == 1 ]] && sudo "${PORT_PREFIX}/bin/port" unload apache2 >/dev/null 2>&1 || true
        [[ $MARIADB == 1 ]] && sudo "${PORT_PREFIX}/bin/port" unload "${MARIADB_PORT}-server" >/dev/null 2>&1 || true
        # Belt-and-braces: launchd will not restart after unload. Kill only the
        # ACTIVE backend's processes (prefix-pinned) so stopping the ports
        # stack never takes down a coexisting brew stack's httpd/mysqld.
        stack_kill -x httpd
        stack_kill -x mysqld mariadbd
    else
        # Kill the brew stack's httpd only (path-pinned; a coexisting ports
        # stack may be running its own httpd on another machine state)
        if [[ $APACHE == 1 ]] && is_service_running apache; then
            sudo "${BREW_PREFIX}/bin/apachectl" stop >/dev/null 2>&1
            sleep 1
            if ! stack_proc -x httpd &>/dev/null; then
                print_ok "Apache stopped"
            fi
        fi
        [[ $MARIADB == 1 ]] && brew services stop mariadb
        stack_kill -x mysqld mariadbd
        [[ $PHP == 1 ]] && brew services stop "$(brew_active_php)"
        stack_kill -f "(^|/)php-fpm"
    fi
    sleep 3
    print_ok "Services stopped"
}

restart_services() {
    stop_services
    start_services
}

toggle_services() {
    local any_running=0
    is_service_running apache && any_running=1
    is_service_running mariadb && any_running=1
    is_service_running php && any_running=1

    if [[ $any_running == 1 ]]; then
        stop_services
        printf "\n${CYAN}Services stopped. Press S again to start them.${RESET}\n"
    else
        start_services
    fi
}

# ---- Apache Configuration -----------------------------------
configure_apache() {
    if [[ $USE_APT == 1 ]]; then
        configure_apache_apt
        return
    fi
    if [[ $USE_PORTS == 1 ]]; then
        configure_apache_ports
        return
    fi

    local conf="${BREW_PREFIX}/etc/httpd/httpd.conf"

    if [[ ! -f "$conf" ]]; then
        print_err "Apache config not found: $conf"
        return 1
    fi

    # Backup original
    if [[ ! -f "${conf}.phpup.bak" ]]; then
        cp "$conf" "${conf}.phpup.bak"
    fi

    print_info "Configuring Apache..."

    sed -i.bak "s/Listen 8080/Listen 80/" "$conf"
    print_ok "Enabled port 80"

    sed -i.bak "s/#ServerName www.example.com:8080/ServerName localhost:80/g" "$conf"
    print_ok "Set ServerName to localhost:80"

    sed -i.bak "s@${BREW_PREFIX}/var/www@$DOC_ROOT@g" "$conf"
    print_ok "Set DocumentRoot to ${DOC_ROOT}"

    sed -i.bak "s@${BREW_PREFIX}/var/log/httpd/error_log@${LOGS_DIR}/apache_error.log@g" "$conf"
    sed -i.bak "s@${BREW_PREFIX}/var/log/httpd/access_log@${LOGS_DIR}/apache_access.log@g" "$conf"
    print_ok "Routed logs to ${LOGS_DIR}"

    sed -i.bak "s@#LoadModule rewrite_module lib/httpd/modules/mod_rewrite.so@LoadModule rewrite_module lib/httpd/modules/mod_rewrite.so@g" "$conf"
    sed -i.bak "s/AllowOverride None/AllowOverride All/g" "$conf"
    print_ok "Enabled mod_rewrite"

    sed -i.bak "s/DirectoryIndex index.html/DirectoryIndex index.php index.html/" "$conf"
    print_ok "Added index.php to DirectoryIndex"

    # Linux-specific: change user/group to www-data
    if [[ "${OS_TYPE}" == "linux-gnu"* ]]; then
        sed -i.bak "s/User _www/User www-data/" "$conf"
        sed -i.bak "s/Group _www/Group www-data/" "$conf"
        print_ok "Set Apache user/group to www-data (Linux)"
    fi

    # PHP module — skip if libphp.so doesn't exist (brew install may have failed)
    local php_module_path="${BREW_PREFIX}/opt/php/lib/httpd/modules/libphp.so"
    if [[ -f "$php_module_path" ]]; then
        if ! grep -q "LoadModule php_module" "$conf"; then
            printf "\\nLoadModule php_module %s\\n" "$php_module_path" >> "$conf"
        fi

        if ! grep -q '<FilesMatch \\.php$>' "$conf"; then
            cat >> "$conf" << 'PHPFILESMATCH'

<FilesMatch \.php$>
    SetHandler application/x-httpd-php
</FilesMatch>
PHPFILESMATCH
        fi
        print_ok "Enabled php_module"
    else
        print_warn "PHP module not found (${php_module_path}) — PHP may not have installed correctly"
    fi

    # phpMyAdmin alias
    local pma_path="${BREW_PREFIX}/share/phpmyadmin"
    if ! grep -q "Alias /phpmyadmin" "$conf"; then
        cat >> "$conf" << PMAALIAS

Alias /phpmyadmin ${pma_path}
<Directory ${pma_path}/>
    Options Indexes FollowSymLinks MultiViews
    AllowOverride All
    Require local
</Directory>
PMAALIAS
    fi
    print_ok "Created phpMyAdmin alias"

    # Ensure www directory is writable by both user and Apache
    sudo sh -c "chgrp -R _www '$DOC_ROOT' && chmod -R 775 '$DOC_ROOT'" 2>/dev/null || chgrp -R _www "$DOC_ROOT" && chmod -R 775 "$DOC_ROOT" 2>/dev/null || true
    print_ok "Set ${DOC_ROOT} group to _www (775)"

    # Clean up sed backup files
    rm -f "${conf}.bak"
}

# ---- Apache Configuration (apt) ------------------------------
configure_apache_apt() {
    local site_conf="/etc/apache2/sites-available/000-default.conf"
    local main_conf="/etc/apache2/apache2.conf"

    print_info "Configuring Apache (apt)..."

    sudo a2enmod rewrite 2>/dev/null
    print_ok "Enabled mod_rewrite"

    # Configure 000-default.conf — the default site
    if [[ -f "$site_conf" ]]; then
        if [[ ! -f "${site_conf}.phpup.bak" ]]; then
            sudo cp "$site_conf" "${site_conf}.phpup.bak"
        fi

        sudo sed -i "s@DocumentRoot /var/www/html@DocumentRoot ${DOC_ROOT}@" "$site_conf"
        print_ok "Set DocumentRoot to ${DOC_ROOT}"

        # Add Directory grant for new doc root (default Apache policy denies non-/var/www paths)
        if ! grep -q "<Directory ${DOC_ROOT}>" "$site_conf"; then
            sudo sed -i "s|</VirtualHost>|\t<Directory ${DOC_ROOT}>\n\t\tOptions Indexes FollowSymLinks\n\t\tAllowOverride All\n\t\tRequire all granted\n\t</Directory>\n\n</VirtualHost>|" "$site_conf"
            print_ok "Added Directory grant for ${DOC_ROOT}"
        fi

        # AllowOverride All for .htaccess
        sudo sed -i "s/AllowOverride None/AllowOverride All/g" "$site_conf"
        print_ok "Set AllowOverride All"

        sudo sed -i "s/DirectoryIndex index.html/DirectoryIndex index.php index.html/" "$site_conf"
        print_ok "Added index.php to DirectoryIndex"

        sudo sed -i "s@\${APACHE_LOG_DIR}/error.log@${LOGS_DIR}/apache_error.log@" "$site_conf"
        sudo sed -i "s@\${APACHE_LOG_DIR}/access.log@${LOGS_DIR}/apache_access.log@" "$site_conf"
        print_ok "Routed logs to ${LOGS_DIR}"
    fi

    # ServerName in apache2.conf
    if [[ -f "$main_conf" ]]; then
        if ! grep -q "ServerName localhost" "$main_conf"; then
            echo "ServerName localhost:80" | sudo tee -a "$main_conf" > /dev/null
            print_ok "Set ServerName to localhost:80"
        fi
    fi

    # Ensure www directory is writable by both user and Apache
    sudo chgrp -R www-data "$DOC_ROOT" 2>/dev/null || true
    sudo chmod -R 775 "$DOC_ROOT" 2>/dev/null || true
    print_ok "Set ${DOC_ROOT} group to www-data (775)"

    # Ensure Apache can traverse the home directory (default 700 blocks www-data)
    chmod o+x "$HOME" 2>/dev/null || true

    # PHP-FPM integration — Apache proxies .php to the active FPM socket
    local fpm_ver
    fpm_ver=$(fpm_active_version || true)
    [[ -z "$fpm_ver" ]] && fpm_ver=$("$(apt_php_bin)" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null)
    if [[ -n "$fpm_ver" ]]; then
        wire_apache_fpm "$fpm_ver"
    fi

    # Reload Apache to apply changes
    sudo systemctl reload apache2 2>/dev/null || sudo systemctl start apache2 2>/dev/null
    print_ok "Apache configured"
}

# ---- Apache Configuration (MacPorts) ------------------------
configure_apache_ports() {
    local conf="${PORT_PREFIX}/etc/apache2/httpd.conf"
    if [[ ! -f "$conf" ]]; then print_err "Apache config not found: $conf"; return 1; fi
    if [[ ! -f "${conf}.phpup.bak" ]]; then sudo cp "$conf" "${conf}.phpup.bak"; fi
    print_info "Configuring Apache (MacPorts)..."

    # ServerName — stock conf has commented "ServerName www.example.com:80"
    sudo sed -i.bak "s/#ServerName www.example.com:80/ServerName localhost:80/g" "$conf"
    print_ok "Set ServerName to localhost:80"

    # DocumentRoot + its <Directory> block (both reference /opt/local/www/apache2/html)
    sudo sed -i.bak "s@${PORT_PREFIX}/www/apache2/html@$DOC_ROOT@g" "$conf"
    print_ok "Set DocumentRoot to ${DOC_ROOT}"

    # Logs — handle both relative ("logs/error_log", ServerRoot-dependent) and absolute forms
    sudo sed -i.bak "s@^ErrorLog.*@ErrorLog ${LOGS_DIR}/apache_error.log@" "$conf"
    sudo sed -i.bak "s@^CustomLog.*@CustomLog ${LOGS_DIR}/apache_access.log combined@" "$conf"
    print_ok "Routed logs to ${LOGS_DIR}"

    # mod_rewrite — uncomment both possible stock spellings
    sudo sed -i.bak "s@#LoadModule rewrite_module lib/apache2/modules/mod_rewrite.so@LoadModule rewrite_module lib/apache2/modules/mod_rewrite.so@" "$conf"
    sudo sed -i.bak "s@#LoadModule rewrite_module modules/mod_rewrite.so@LoadModule rewrite_module modules/mod_rewrite.so@" "$conf"
    sudo sed -i.bak "s/AllowOverride None/AllowOverride All/g" "$conf"
    print_ok "Enabled mod_rewrite"

    sudo sed -i.bak "s/DirectoryIndex index.html/DirectoryIndex index.php index.html/" "$conf"
    print_ok "Added index.php to DirectoryIndex"

    # PHP module — strip-then-append (idempotent; fu→D→I cycles must not leave
    # dead lines). MacPorts' mod_phpXX.so exports "php_module" (no suffix).
    sudo sed -i.bak "/^LoadModule php[0-9]*_module /d" "$conf"
    local php_module="${PORT_PREFIX}/lib/apache2/modules/mod_${PHP_PORT}.so"
    if [[ -f "$php_module" ]]; then
        printf "\nLoadModule php_module %s\n" "$php_module" | sudo tee -a "$conf" > /dev/null
        if ! grep -q '<FilesMatch \\.php$>' "$conf"; then
            cat << 'PHPFILESMATCH' | sudo tee -a "$conf" > /dev/null

<FilesMatch \.php$>
    SetHandler application/x-httpd-php
</FilesMatch>
PHPFILESMATCH
        fi
        print_ok "Enabled ${PHP_PORT} module"
    else
        print_warn "PHP module not found (${php_module}) — PHP may not have installed correctly"
    fi

    # phpMyAdmin alias
    if ! grep -q "Alias /phpmyadmin" "$conf"; then
        cat << PMAALIAS | sudo tee -a "$conf" > /dev/null

Alias /phpmyadmin ${PMA_DIR}
<Directory ${PMA_DIR}/>
    Options Indexes FollowSymLinks MultiViews
    AllowOverride All
    Require local
</Directory>
PMAALIAS
    fi
    print_ok "Created phpMyAdmin alias"

    # www dir writable by Apache (macOS _www, same as brew path)
    sudo chgrp -R _www "$DOC_ROOT" 2>/dev/null || true
    sudo chmod -R 775 "$DOC_ROOT" 2>/dev/null || true
    print_ok "Set ${DOC_ROOT} group to _www (775)"

    sudo rm -f "${conf}.bak"
}

# ---- PHP Configuration --------------------------------------
configure_php() {
    if [[ $USE_APT == 1 ]]; then
        configure_php_apt
        return
    fi
    if [[ $USE_PORTS == 1 ]]; then
        configure_php_ports
        return
    fi

    if [[ $PHP == 0 ]]; then
        print_warn "PHP not installed — skipping configuration"
        return
    fi

    local php_ini="${BREW_PREFIX}/etc/php/$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null)/php.ini"

    # Fallback: search for php.ini
    if [[ ! -f "$php_ini" ]]; then
        php_ini=$(php -r 'echo php_ini_loaded_file();' 2>/dev/null)
    fi
    if [[ ! -f "$php_ini" ]]; then
        php_ini=$(php -i 2>/dev/null | grep "Loaded Configuration File" | awk -F' => ' '{print $2}')
    fi

    if [[ ! -f "$php_ini" ]]; then
        print_warn "Could not locate php.ini — skipping PHP configuration"
        return
    fi

    if [[ ! -f "${php_ini}.phpup.bak" ]]; then
        cp "$php_ini" "${php_ini}.phpup.bak"
    fi

    print_info "Configuring PHP..."

    # Enable extensions only if the .so file exists (Homebrew PHP 8.x compiles most statically)
    local ext_dir
    ext_dir=$(php -r 'echo PHP_EXTENSION_DIR;' 2>/dev/null)
    local extensions=("curl" "fileinfo" "gd" "intl" "mbstring" "mysqli" "openssl" "pdo_mysql" "pdo_sqlite" "sodium" "sqlite3")
    for ext in "${extensions[@]}"; do
        if [[ -f "${ext_dir}/${ext}.so" ]]; then
            sed -i.bak "s/^; *extension=${ext}/extension=${ext}/" "$php_ini" 2>/dev/null || true
        fi
    done
    print_ok "Enabled PHP extensions"

    apply_php_ini_policy "$php_ini"

    if grep -q "^;*opcache.enable=" "$php_ini" 2>/dev/null; then
        sed -i.bak "s/^;*opcache.enable=.*/opcache.enable=1/" "$php_ini"
        sed -i.bak "s/^;*opcache.memory_consumption=.*/opcache.memory_consumption=256/" "$php_ini"
        sed -i.bak "s/^;*opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=16/" "$php_ini"
        sed -i.bak "s/^;*opcache.max_accelerated_files=.*/opcache.max_accelerated_files=20000/" "$php_ini"
        print_ok "Configured OPCache (256MB, JIT-ready)"
    fi

    rm -f "${php_ini}.bak"
}

# ---- Shared php.ini policy ----------------------------------
# Apply the common phpup php.ini settings with set-or-append semantics.
# $1 = php.ini path, $2 = sed command (may include sudo; default sed -i.bak),
# $3 = append command (default tee -a), $4 = optional display label for the
# display_errors line (apt shows the ini context, e.g. "fpm").
apply_php_ini_policy() {
    local php_ini="$1"
    local sed_cmd="${2:-sed -i.bak}"
    local append_cmd="${3:-tee -a}"
    local label="$4"

    local key val
    set_ini_directive() {
        key="$1"; val="$2"
        if grep -q "^${key}" "$php_ini" 2>/dev/null; then
            # | delimiter: values carry slashes (error_log path)
            $sed_cmd "s|^${key}.*|${key} = ${val}|" "$php_ini" 2>/dev/null || true
        else
            echo "${key} = ${val}" | $append_cmd "$php_ini" > /dev/null
        fi
    }

    set_ini_directive display_errors On
    print_ok "Enabled display_errors${label:+ ($label)}"

    set_ini_directive error_log "${LOGS_DIR}/php_errors.log"
    print_ok "Set PHP error log to ${LOGS_DIR}/php_errors.log"

    for kv in "upload_max_filesize 50M" "post_max_size 55M" "max_execution_time 300" "max_input_time 300"; do
        set_ini_directive "${kv%% *}" "${kv#* }"
    done
    print_ok "Upload limits set: 50 MB files, 300s timeout"

    set_ini_directive session.gc_maxlifetime 14400
    print_ok "Session GC lifetime: 4 hours"
}

# ---- PHP Configuration (apt) ---------------------------------
configure_php_apt() {
    print_info "Configuring PHP (apt)..."
    local php_ver
    php_ver=$("$(apt_php_bin)" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null)
    local inis=("/etc/php/${php_ver}/fpm/php.ini" "/etc/php/${php_ver}/cli/php.ini")
    local php_ini found=0

    for php_ini in "${inis[@]}"; do
        [[ -f "$php_ini" ]] || continue
        found=1
        if [[ ! -f "${php_ini}.phpup.bak" ]]; then
            sudo cp "$php_ini" "${php_ini}.phpup.bak"
        fi

        apply_php_ini_policy "$php_ini" "sudo sed -i" "sudo tee -a" "$(basename "$(dirname "$php_ini")")"

        # OPCache (web runtime only — CLI keeps opcache off so phar tools work)
        if [[ "$php_ini" == *"/fpm/php.ini" ]] && grep -q "^;*opcache.enable=" "$php_ini" 2>/dev/null; then
            sudo sed -i "s/^;*opcache.enable=.*/opcache.enable=1/" "$php_ini"
            sudo sed -i "s/^;*opcache.memory_consumption=.*/opcache.memory_consumption=256/" "$php_ini"
            sudo sed -i "s/^;*opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=16/" "$php_ini"
            sudo sed -i "s/^;*opcache.max_accelerated_files=.*/opcache.max_accelerated_files=20000/" "$php_ini"
            print_ok "Configured OPCache (256MB, JIT-ready)"
        fi
    done

    if [[ $found == 0 ]]; then
        print_warn "Could not locate php.ini — skipping PHP configuration"
        return
    fi
    print_ok "PHP configured"
}

# ---- PHP Configuration (MacPorts) ---------------------------
configure_php_ports() {
    if [[ $PHP == 0 ]]; then print_warn "PHP not installed — skipping configuration"; return; fi
    local php_ini
    # Use the port-style name (php84, php85) — PHP_PORT tracks the active port
    # through fu switches. A dotted version (8.4) is NOT the MacPorts config dir.
    php_ini="${PORT_PREFIX}/etc/${PHP_PORT}/php.ini"

    # MacPorts ships only php.ini-development / php.ini-production — create php.ini.
    # Deliberate: dev tool → development template (loud errors, dev-friendly
    # timeouts). display_errors forced On below regardless; brew/apt ship
    # production defaults by comparison.
    if [[ ! -f "$php_ini" ]]; then
        sudo cp "${PORT_PREFIX}/etc/${PHP_PORT}/php.ini-development" "$php_ini" 2>/dev/null \
            || { print_warn "Could not create $php_ini — skipping PHP configuration"; return; }
        print_ok "Created php.ini from php.ini-development"
    fi
    if [[ ! -f "${php_ini}.phpup.bak" ]]; then sudo cp "$php_ini" "${php_ini}.phpup.bak"; fi

    print_info "Configuring PHP (MacPorts)..."
    # Extensions are auto-loaded from ${PORT_PREFIX}/var/db/${PHP_PORT}/*.ini (config-file-scan-dir)
    # — no extension= edits needed, but verify the mysql extensions loaded (warn only).
    if ! php -m 2>/dev/null | grep -qE 'mysqli|pdo_mysql'; then
        print_warn "mysqli/pdo_mysql not loaded — check that ${PHP_PORT}-mysql is installed"
    fi

    # MySQL socket wiring — REQUIRED for PHP↔MariaDB (mysqlnd has no matching default socket)
    local sock="${PORT_PREFIX}/var/run/${MARIADB_PORT}/mysqld.sock"
    for key in mysqli.default_socket pdo_mysql.default_socket mysql.default_socket; do
        if grep -q "^${key}" "$php_ini" 2>/dev/null; then
            sudo sed -i.bak "s@^${key}.*@${key} = ${sock}@" "$php_ini"
        else
            echo "${key} = ${sock}" | sudo tee -a "$php_ini" > /dev/null
        fi
    done
    print_ok "Pointed mysqli/pdo_mysql at ${sock}"

    apply_php_ini_policy "$php_ini" "sudo sed -i.bak" "sudo tee -a"

    # OPCache — compiled into php85 core (no php85-opcache port exists). Only
    # touch the settings if the runtime actually has the module loaded.
    if php -m 2>/dev/null | grep -qi 'Zend OPcache'; then
        if grep -q "^;*opcache.enable=" "$php_ini" 2>/dev/null; then
            sudo sed -i.bak "s/^;*opcache.enable=.*/opcache.enable=1/" "$php_ini"
            sudo sed -i.bak "s/^;*opcache.memory_consumption=.*/opcache.memory_consumption=256/" "$php_ini"
            sudo sed -i.bak "s/^;*opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=16/" "$php_ini"
            sudo sed -i.bak "s/^;*opcache.max_accelerated_files=.*/opcache.max_accelerated_files=20000/" "$php_ini"
            print_ok "Configured OPCache (256MB, JIT-ready)"
        fi
    fi

    sudo rm -f "${php_ini}.bak"
    print_ok "PHP configured (MacPorts)"
}

# ---- MariaDB Configuration ----------------------------------
configure_mariadb() {
    if [[ $USE_APT == 1 ]]; then
        configure_mariadb_apt
        return
    fi
    if [[ $USE_PORTS == 1 ]]; then
        configure_mariadb_ports
        return
    fi

    if [[ $MARIADB == 0 ]]; then
        print_warn "MariaDB not installed — skipping configuration"
        return
    fi

    print_info "Configuring MariaDB..."

    # Start MariaDB to initialise data directory
    brew services start mariadb 2>/dev/null
    sleep 3

    # Set blank root password with mysql_native_password plugin
    # brew MariaDB 12.3.2 defaults to unix_socket auth — only the OS user
    # named in the MariaDB account can connect.  PHP/PMA need native password.
    local mysql_user="${USER}"
    if mysql -u root -e "SELECT 1" &>/dev/null 2>&1; then
        mysql_user="root"
    elif mysql -u "${mysql_user}" -e "SELECT 1" &>/dev/null 2>&1; then
        : # current user works — will use it to ALTER root
    else
        mysql_user=""
    fi

    if [[ -n "$mysql_user" ]]; then
        mysql -u "${mysql_user}" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY ''; FLUSH PRIVILEGES;" 2>/dev/null || true
        print_ok "MariaDB root password set to blank (native auth)"
    elif mysql -u root -h 127.0.0.1 -e "SELECT 1" &>/dev/null 2>&1; then
        print_ok "MariaDB root access confirmed (no password)"
    else
        # Fallback: stop, wipe, and reinitialize
        brew services stop mariadb 2>/dev/null
        sleep 1
        rm -rf "${BREW_PREFIX}/var/mysql" 2>/dev/null || true
        brew services start mariadb 2>/dev/null
        sleep 5
        if mysql -u root -e "SELECT 1" &>/dev/null 2>&1; then
            mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY ''; FLUSH PRIVILEGES;" 2>/dev/null || true
            print_ok "MariaDB root password set to blank"
        else
            print_warn "Could not configure MariaDB root access — you may need to set it manually"
        fi
    fi

    # Configure my.cnf with error log
    local my_cnf="${BREW_PREFIX}/etc/my.cnf"
    if [[ ! -f "$my_cnf" ]]; then
        my_cnf="${BREW_PREFIX}/etc/my.cnf.d/server.cnf"
    fi

    if [[ -f "$my_cnf" ]] || [[ -d "$(dirname "$my_cnf")" ]]; then
        if ! grep -q "log-error" "$my_cnf" 2>/dev/null; then
            mkdir -p "$(dirname "$my_cnf")" 2>/dev/null || true
            echo "[mysqld]" >> "$my_cnf"
            echo "log-error = ${LOGS_DIR}/mariadb_error.log" >> "$my_cnf"
            print_ok "Set MariaDB error log to ${LOGS_DIR}/mariadb_error.log"
        fi
    else
        print_warn "Could not configure MariaDB my.cnf — log routing skipped"
    fi
}

# ---- MariaDB Configuration (apt) -----------------------------
configure_mariadb_apt() {
    print_info "Configuring MariaDB (apt)..."

    # Ensure MariaDB is running
    sudo systemctl start mariadb 2>/dev/null || true
    sleep 2

    # Set blank root password for TCP connections (switch from unix_socket auth)
    if sudo mysql -u root -e "SELECT 1" &>/dev/null 2>&1; then
        sudo mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING ''; FLUSH PRIVILEGES;" 2>/dev/null || true
        print_ok "MariaDB root access confirmed (no password via socket)"
    else
        print_warn "Could not connect to MariaDB as root — you may need to set a password manually"
    fi

    # Configure error log
    local mariadb_conf="/etc/mysql/mariadb.conf.d/50-server.cnf"
    if [[ -f "$mariadb_conf" ]]; then
        if ! grep -q "log_error" "$mariadb_conf" 2>/dev/null; then
            echo "log_error = ${LOGS_DIR}/mariadb_error.log" | sudo tee -a "$mariadb_conf" > /dev/null
            print_ok "Set MariaDB error log to ${LOGS_DIR}/mariadb_error.log"
        fi
    else
        print_warn "Could not configure MariaDB error log — config file not found"
    fi

    print_ok "MariaDB configured"
}

# ---- MariaDB Configuration (MacPorts) ------------------------
configure_mariadb_ports() {
    if [[ $MARIADB == 0 ]]; then print_warn "MariaDB not installed — skipping configuration"; return; fi
    print_info "Configuring MariaDB (MacPorts)..."

    # 1. Enable networking — MacPorts macports-default.cnf ships with skip-networking
    #    (allows multiple mysql ports to coexist). phpup needs TCP + socket.
    if [[ -f "${PORT_PREFIX}/etc/${MARIADB_PORT}/macports-default.cnf" ]] && \
       grep -q "skip-networking" "${PORT_PREFIX}/etc/${MARIADB_PORT}/macports-default.cnf"; then
        sudo sed -i.bak "s/^skip-networking/#skip-networking/" \
            "${PORT_PREFIX}/etc/${MARIADB_PORT}/macports-default.cnf"
        print_ok "Enabled MariaDB networking (removed skip-networking)"
    fi

    # 2. Initialize data dir if empty (server port pre-creates /opt/local/var/db/<port> owned by _mysql)
    local datadir="${PORT_PREFIX}/var/db/${MARIADB_PORT}"
    datadir_initialized() {
        [[ -d "$datadir/mysql" ]] && [[ -n "$(ls -A "$datadir/mysql" 2>/dev/null)" ]]
    }
    if [[ -d "$datadir" ]] && [[ -z "$(ls -A "$datadir" 2>/dev/null)" ]]; then
        print_info "Initializing MariaDB data directory..."
        # Prefer --auth-root-authentication-method=normal (native-password root, no
        # unix_socket dance) — documented for MariaDB 10.4+ (12.3/11.4 both qualify).
        # Fall back to the default init and let the sudo-ALTER chain below handle auth.
        sudo -u _mysql "${PORT_PREFIX}/lib/${MARIADB_PORT}/bin/mariadb-install-db" \
            --datadir="$datadir" --auth-root-authentication-method=normal 2>/dev/null \
            || sudo -u _mysql "${PORT_PREFIX}/lib/${MARIADB_PORT}/bin/mariadb-install-db" \
                --datadir="$datadir" 2>/dev/null \
            || print_warn "mariadb-install-db failed — data dir may need manual init"
    fi
    # Verify the init actually produced the mysql system DB (privilege tables).
    # A partial/raced init leaves InnoDB files but no mysql/ dir — mariadbd then
    # aborts with "Table 'mysql.plugin' doesn't exist" (seen live 2026-08-13).
    # Wipe and retry once; a second failure surfaces as a warning, not a silent
    # "MariaDB started" false positive.
    if ! datadir_initialized; then
        print_warn "MariaDB data dir incomplete — wiping and re-initializing"
        sudo "${PORT_PREFIX}/bin/port" unload "${MARIADB_PORT}-server" >/dev/null 2>&1
        sleep 1
        if [[ -d "$datadir" ]]; then
            sudo rm -rf "$datadir" 2>/dev/null || true
        fi
        sudo mkdir -p "$datadir"
        sudo chown _mysql:_mysql "$datadir"
        sudo -u _mysql "${PORT_PREFIX}/lib/${MARIADB_PORT}/bin/mariadb-install-db" \
            --datadir="$datadir" --auth-root-authentication-method=normal 2>/dev/null \
            || sudo -u _mysql "${PORT_PREFIX}/lib/${MARIADB_PORT}/bin/mariadb-install-db" --datadir="$datadir" 2>/dev/null || true
        datadir_initialized || print_warn "MariaDB data dir still incomplete — manual init required"
    fi

    # 3. Start
    sudo "${PORT_PREFIX}/bin/port" load "${MARIADB_PORT}-server" >/dev/null 2>&1
    sleep 3

    # 4. Root auth: unix_socket → mysql_native_password, blank password (same reset as apt path).
    #    `sudo mysql -u root` works because the OS root user matches the root@localhost account
    #    via the unix_socket plugin. Use absolute client path (sudo may not keep /opt/local/bin).
    local mysqlc="${PORT_PREFIX}/bin/mysql"
    if sudo "$mysqlc" -u root -e "SELECT 1" &>/dev/null 2>&1; then
        sudo "$mysqlc" -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING ''; FLUSH PRIVILEGES;" 2>/dev/null || true
        print_ok "MariaDB root password set to blank (native auth)"
    elif "$mysqlc" -u root -e "SELECT 1" &>/dev/null 2>&1; then
        "$mysqlc" -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING ''; FLUSH PRIVILEGES;" 2>/dev/null || true
        print_ok "MariaDB root password set to blank"
    elif "$mysqlc" -u root -h 127.0.0.1 -e "SELECT 1" &>/dev/null 2>&1; then
        print_ok "MariaDB root access confirmed (no password)"
    else
        # Fallback: stop, wipe, re-init with native auth, restart
        print_warn "Could not connect as root — wiping and re-initializing data directory"
        sudo "${PORT_PREFIX}/bin/port" unload "${MARIADB_PORT}-server" >/dev/null 2>&1
        sleep 1
        sudo rm -rf "$datadir" 2>/dev/null || true
        sudo mkdir -p "$datadir"
        sudo chown _mysql:_mysql "$datadir"
        sudo -u _mysql "${PORT_PREFIX}/lib/${MARIADB_PORT}/bin/mariadb-install-db" \
            --datadir="$datadir" --auth-root-authentication-method=normal 2>/dev/null \
            || sudo -u _mysql "${PORT_PREFIX}/lib/${MARIADB_PORT}/bin/mariadb-install-db" --datadir="$datadir" 2>/dev/null || true
        sudo "${PORT_PREFIX}/bin/port" load "${MARIADB_PORT}-server" >/dev/null 2>&1
        sleep 5
        sudo "$mysqlc" -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING ''; FLUSH PRIVILEGES;" 2>/dev/null || true
        print_ok "MariaDB root password set to blank"
    fi

    # 5. Error log in my.cnf (append to [mysqld] if missing)
    # NOTE: MariaDB runs as _mysql on MacPorts — ~/phpup/logs is user-owned and
    # _mysql cannot write there (mariadbd aborts: Permission denied). Use the
    # ports-native log dir instead; start_services() tails it on failure.
    local my_cnf="${PORT_PREFIX}/etc/${MARIADB_PORT}/my.cnf"
    local mariadb_log_dir="${PORT_PREFIX}/var/log/${MARIADB_PORT}"
    sudo mkdir -p "$mariadb_log_dir" 2>/dev/null || true
    sudo chown _mysql:_mysql "$mariadb_log_dir" 2>/dev/null || true
    if [[ -f "$my_cnf" ]] && ! grep -q "log-error" "$my_cnf" 2>/dev/null; then
        # MySQL/MariaDB require every option under a [group] — MacPorts' my.cnf
        # only contains a comment + !include, so append a [mysqld] header first.
        if ! grep -q "^\[mysqld\]" "$my_cnf" 2>/dev/null; then
            echo "[mysqld]" | sudo tee -a "$my_cnf" > /dev/null
        fi
        echo "log-error = ${mariadb_log_dir}/mariadb_error.log" | sudo tee -a "$my_cnf" > /dev/null
        print_ok "Set MariaDB error log to ${mariadb_log_dir}/mariadb_error.log"
    fi
}

# ---- phpMyAdmin Configuration -------------------------------
# Create the phpMyAdmin tmp dir and verify Apache can write it. $1 = dir,
# $2 = Apache group (_www on macOS, www-data on Linux).
ensure_pma_tmp() {
    local pma_tmp="$1" pma_group="$2"
    local pma_tmp_ok=0
    sudo sh -c "mkdir -p '$pma_tmp' && chgrp $pma_group '$pma_tmp' && chmod 775 '$pma_tmp'" 2>/dev/null && pma_tmp_ok=1
    if [[ $pma_tmp_ok == 0 ]]; then
        # stat syntax differs: -f (BSD/macOS) vs -c (GNU/Linux)
        local stat_out
        if [[ $OS_NAME == "macOS" ]]; then
            stat_out=$(stat -f '%Sg' "$pma_tmp" 2>/dev/null)
        else
            stat_out=$(stat -c '%G' "$pma_tmp" 2>/dev/null)
        fi
        [[ "$stat_out" == "$pma_group" ]] && pma_tmp_ok=1
    fi
    if [[ $pma_tmp_ok == 1 ]]; then
        print_ok "Created phpMyAdmin tmp directory"
    else
        print_warn "phpMyAdmin tmp dir not writable by Apache — run: sudo chgrp $pma_group '$pma_tmp' && sudo chmod 775 '$pma_tmp'"
    fi
}

configure_phpmyadmin() {
    if [[ $USE_APT == 1 ]]; then
        configure_phpmyadmin_apt
        return
    fi
    if [[ $USE_PORTS == 1 ]]; then
        configure_phpmyadmin_ports
        return
    fi

    if [[ $PHPMYADMIN == 0 ]]; then
        print_warn "phpMyAdmin not installed — skipping configuration"
        return
    fi

    local pma_conf="${BREW_PREFIX}/etc/phpmyadmin.config.inc.php"

    if [[ ! -f "$pma_conf" ]]; then
        print_warn "phpMyAdmin config not found — skipping"
        return
    fi

    if [[ ! -f "${pma_conf}.phpup.bak" ]]; then
        cp "$pma_conf" "${pma_conf}.phpup.bak"
    fi

    print_info "Configuring phpMyAdmin..."

    # Blowfish secret (brew config has trailing comment after '';). Per-install
    # random 32 bytes — never a static known-default. Remediate existing installs
    # too: the ≤1.0.1 static value 12345678901234567890123456789012 is replaced,
    # an already-random secret is left untouched (no rotation on re-configure).
    if grep -q "12345678901234567890123456789012" "$pma_conf" 2>/dev/null || \
       grep -q "\$cfg\['blowfish_secret'\] = '';" "$pma_conf" 2>/dev/null; then
        local pma_secret_val
        pma_secret_val=$(pma_secret)
        sed -i.bak "s/\$cfg\['blowfish_secret'\] = '.*';.*/\$cfg\['blowfish_secret'\] = '${pma_secret_val}';/" "$pma_conf"
    fi
    print_ok "Set blowfish secret"

    # Allow passwordless root login
    sed -i.bak "s/\$cfg\['Servers'\]\[\$i\]\['AllowNoPassword'\] = false;/\$cfg\['Servers'\]\[\$i\]\['AllowNoPassword'\] = true;/" "$pma_conf"
    print_ok "Enabled passwordless root login"

    # Disable version check — append if missing (brew default omits this directive)
    if grep -q "\$cfg\['VersionCheck'\]" "$pma_conf" 2>/dev/null; then
        sed -i.bak "s/\$cfg\['VersionCheck'\] = true;/\$cfg\['VersionCheck'\] = false;/" "$pma_conf"
    else
        echo "\$cfg['VersionCheck'] = false;" >> "$pma_conf"
    fi
    print_ok "Disabled version check"

    # Disable error reporting — append if missing
    if grep -q "\$cfg\['SendErrorReports'\]" "$pma_conf" 2>/dev/null; then
        sed -i.bak "s/\$cfg\['SendErrorReports'\] = 'ask';/\$cfg\['SendErrorReports'\] = 'never';/" "$pma_conf"
    else
        echo "\$cfg['SendErrorReports'] = 'never';" >> "$pma_conf"
    fi
    print_ok "Disabled error reporting"

    # Extend login cookie to 4 hours — append if missing
    if grep -q "\$cfg\['LoginCookieValidity'\]" "$pma_conf" 2>/dev/null; then
        sed -i.bak "s/\$cfg\['LoginCookieValidity'\] = 1440;/\$cfg\['LoginCookieValidity'\] = 14400;/" "$pma_conf"
    else
        echo "\$cfg['LoginCookieValidity'] = 14400;" >> "$pma_conf"
    fi
    print_ok "Extended login cookie to 4 hours"

    # Template cache directory — append if missing
    if grep -q "\$cfg\['TempDir'\]" "$pma_conf" 2>/dev/null; then
        sed -i.bak "s|\$cfg\['TempDir'\] = '/tmp';|\$cfg\['TempDir'\] = '${BREW_PREFIX}/share/phpmyadmin/tmp';|" "$pma_conf"
    else
        echo "\$cfg['TempDir'] = '${BREW_PREFIX}/share/phpmyadmin/tmp';" >> "$pma_conf"
    fi
    print_ok "Set TempDir for template cache"

    # Create phpMyAdmin tmp directory (required for template cache)
    ensure_pma_tmp "${BREW_PREFIX}/share/phpmyadmin/tmp" "_www"

    # Configure phpMyAdmin storage database (for bookmarks, relations, etc.)
    local pma_sql="${BREW_PREFIX}/share/phpmyadmin/sql/create_tables.sql"
    if [[ -f "$pma_sql" ]]; then
        if ! mysql -u root -e "USE pma" &>/dev/null 2>&1; then
            print_info "Setting up phpMyAdmin storage database..."
            # Replace phpmyadmin with pma in the SQL so the db is named 'pma'.
            # Match BOTH forms: backticked (`phpmyadmin`) and bare (USE phpmyadmin;)
            sed 's/phpmyadmin/pma/g' "$pma_sql" | mysql -u root 2>/dev/null || true
            # Grant pma user limited privileges for the storage tables.
            # MariaDB 12.x does NOT auto-create users on GRANT — CREATE USER first.
            mysql -u root -e "CREATE USER IF NOT EXISTS 'pma'@'localhost' IDENTIFIED BY ''; GRANT SELECT, INSERT, UPDATE, DELETE ON pma.* TO 'pma'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true
        fi
        # Add storage config if not already present
        # Table list mirrors phpup.ps1 Get-PmaStorageConfig — keep both in sync
        # with phpMyAdmin's upstream sql/create_tables.sql.
        if ! grep -q "Servers\[\\\$i\]\['pmadb'\]" "$pma_conf" 2>/dev/null; then
            cat >> "$pma_conf" << 'PMASTORAGE'

/**
 * phpMyAdmin configuration storage settings.
 */
$cfg['Servers'][$i]['pmadb'] = 'pma';
$cfg['Servers'][$i]['bookmarktable'] = 'pma__bookmark';
$cfg['Servers'][$i]['relation'] = 'pma__relation';
$cfg['Servers'][$i]['table_info'] = 'pma__table_info';
$cfg['Servers'][$i]['table_coords'] = 'pma__table_coords';
$cfg['Servers'][$i]['pdf_pages'] = 'pma__pdf_pages';
$cfg['Servers'][$i]['column_info'] = 'pma__column_info';
$cfg['Servers'][$i]['history'] = 'pma__history';
$cfg['Servers'][$i]['table_uiprefs'] = 'pma__table_uiprefs';
$cfg['Servers'][$i]['tracking'] = 'pma__tracking';
$cfg['Servers'][$i]['userconfig'] = 'pma__userconfig';
$cfg['Servers'][$i]['recent'] = 'pma__recent';
$cfg['Servers'][$i]['favorite'] = 'pma__favorite';
$cfg['Servers'][$i]['users'] = 'pma__users';
$cfg['Servers'][$i]['usergroups'] = 'pma__usergroups';
$cfg['Servers'][$i]['navigationhiding'] = 'pma__navigationhiding';
$cfg['Servers'][$i]['savedsearches'] = 'pma__savedsearches';
$cfg['Servers'][$i]['central_columns'] = 'pma__central_columns';
$cfg['Servers'][$i]['designer_settings'] = 'pma__designer_settings';
$cfg['Servers'][$i]['export_templates'] = 'pma__export_templates';
PMASTORAGE
            print_ok "Configured phpMyAdmin storage database"
        fi
    else
        print_info "phpMyAdmin storage tables not found — skipping storage setup"
    fi

    rm -f "${pma_conf}.bak"
}

# ---- phpMyAdmin Configuration (apt) --------------------------
configure_phpmyadmin_apt() {
    print_info "Configuring phpMyAdmin (apt)..."

    # Use conf.d override — works across all phpMyAdmin versions without fragile sed
    local pma_override="/etc/phpmyadmin/conf.d/phpup.php"
    sudo mkdir -p /etc/phpmyadmin/conf.d 2>/dev/null || true
    # Capture the existing blowfish secret BEFORE the overwriting heredoc below
    # erases it — re-appending the SAME value keeps re-configures idempotent
    # (a fresh random secret per run would rotate PMA cookies/sessions on every U).
    local pma_secret_val
    pma_secret_val=$(sed -n "s/.*'\\([0-9a-f]\\{32\\}\\)'.*/\\1/p" "$pma_override" 2>/dev/null | tail -1)
    [[ -n "$pma_secret_val" ]] || pma_secret_val=$(pma_secret)
    sudo tee "$pma_override" > /dev/null <<'PMACONF'
<?php
// phpup — phpMyAdmin configuration overrides
// Scoped to phpMyAdmin only: silence twig 3.21 deprecation notices on PHP 8.5.
// Warnings/errors are NOT suppressed — only E_DEPRECATED.
error_reporting(E_ALL & ~E_DEPRECATED);
$cfg['VersionCheck'] = false;
$cfg['SendErrorReports'] = 'never';
$cfg['LoginCookieValidity'] = 14400;
$cfg['TempDir'] = '/var/lib/phpmyadmin/tmp';
PMACONF
    # Blowfish secret: PMA warns on missing (temporary key). Always (re)append the
    # captured/generated 32-byte secret so the file is complete after the heredoc
    # rewrite without rotating it.
    echo "\$cfg['blowfish_secret'] = '${pma_secret_val}';" | sudo tee -a "$pma_override" > /dev/null
    print_ok "Applied phpMyAdmin overrides (performance, 4h cookie, blowfish secret)"

    # Tarball install: phpMyAdmin ships without config.inc.php (uses config.default.php
    # internally). Create one that loads /etc/conf.d/ overrides so AllowNoPassword
    # and other phpup settings take effect.
    local tarball_conf="/usr/share/phpmyadmin/config.inc.php"
    if [[ ! -f "$tarball_conf" ]] || ! grep -q "conf.d" "$tarball_conf" 2>/dev/null; then
        sudo tee "$tarball_conf" > /dev/null <<'CONFDINCLUDE'
<?php
// phpup — load distro conf.d overrides + AllowNoPassword
$conf_d_dir = '/etc/phpmyadmin/conf.d/';
if (is_dir($conf_d_dir)) {
    foreach (glob($conf_d_dir . '*.php') as $conf_file) {
        include $conf_file;
    }
}
// AllowNoPassword for root (conf.d loads before $cfg['Servers'] is populated)
$cfg['Servers'][1]['AllowNoPassword'] = true;
CONFDINCLUDE
        print_ok "Created tarball config with conf.d include"
    fi

    # Create phpMyAdmin tmp directory (required for template cache).
    # NOT under /usr/share: Debian's php-fpm unit ships ProtectSystem=full,
    # which makes /usr read-only to the FPM process, so a tmp dir there is
    # unwritable no matter the permissions (is_writable false in web context).
    ensure_pma_tmp "/var/lib/phpmyadmin/tmp" "www-data"

    # Configure phpMyAdmin storage database (named 'pma', matching the Mac path).
    # Debian's dbconfig-common skips DB creation under noninteractive, so the
    # controluser it references in config-db.php never exists — create it here.
    local pma_sql="/usr/share/phpmyadmin/sql/create_tables.sql"
    if [[ -f "$pma_sql" ]]; then
        if ! mariadb -u root -e "USE pma" &>/dev/null 2>&1; then
            print_info "Setting up phpMyAdmin storage database..."
            # Rename the db to 'pma' throughout the SQL (backticked and bare
            # forms — Debian's script uses `USE phpmyadmin;` without backticks)
            sed 's/phpmyadmin/pma/g' "$pma_sql" | mariadb -u root 2>/dev/null || true
        fi
        # Stable control password: reuse one already written to the override
        # (survives delete via /etc), else generate one.
        local pma_pass=""
        if [[ -f "$pma_override" ]]; then
            pma_pass=$(grep -oP "(?<=controlpass'\] = ')[^']*" "$pma_override" 2>/dev/null | head -1)
        fi
        [[ -z "$pma_pass" ]] && pma_pass=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
        # Ensure the pma control user exists with the configured password
        mariadb -u root -e "CREATE USER IF NOT EXISTS 'pma'@'localhost' IDENTIFIED BY '${pma_pass}'; ALTER USER 'pma'@'localhost' IDENTIFIED BY '${pma_pass}'; GRANT SELECT, INSERT, UPDATE, DELETE ON pma.* TO 'pma'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true
        # Wire controluser + storage into the override using server index 1
        # (avoids $cfg['Servers'] array_key issue when conf.d loads early).
        sudo tee -a "$pma_override" > /dev/null <<EOF
\$cfg['Servers'][1]['controluser'] = 'pma';
\$cfg['Servers'][1]['controlpass'] = '${pma_pass}';
\$cfg['Servers'][1]['pmadb'] = 'pma';
EOF
        print_ok "Configured phpMyAdmin storage database (pma)"
    else
        print_info "phpMyAdmin storage tables not found — skipping storage setup"
    fi

    # Ubuntu's dbconfig-common (or an old backup restored before this rename)
    # can leave the stock 'phpmyadmin' control DB behind; we wire phpMyAdmin
    # to 'pma' instead, so drop the stock copy — but only when it holds just
    # the pma__* control tables (never a DB with user data).
    if mariadb -u root -e "USE phpmyadmin" &>/dev/null 2>&1; then
        local nonstock
        nonstock=$(mariadb -u root -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='phpmyadmin' AND table_name NOT LIKE 'pma__%'" 2>/dev/null)
        if [[ "${nonstock:-1}" == "0" ]]; then
            mariadb -u root -e "DROP DATABASE phpmyadmin; DROP USER IF EXISTS 'phpmyadmin'@'localhost';" 2>/dev/null || true
            print_ok "Removed duplicate stock phpmyadmin control database"
        fi
    fi

    # Ensure Apache alias is configured (apt package may skip this in noninteractive mode)
    local pma_apache_conf="/etc/apache2/conf-available/phpmyadmin.conf"
    if [[ ! -f "$pma_apache_conf" ]]; then
        sudo tee "$pma_apache_conf" > /dev/null <<'PMACONF'
Alias /phpmyadmin /usr/share/phpmyadmin
<Directory /usr/share/phpmyadmin>
    Options FollowSymLinks
    DirectoryIndex index.php
    Require all granted
</Directory>
PMACONF
        print_ok "Created Apache phpMyAdmin alias"
    fi
    sudo a2enconf phpmyadmin 2>/dev/null || true
    sudo systemctl reload apache2 2>/dev/null || true

    print_ok "phpMyAdmin configured"
}

# ---- phpMyAdmin Configuration (MacPorts) ---------------------
configure_phpmyadmin_ports() {
    print_info "Configuring phpMyAdmin (MacPorts)..."
    if [[ $PHPMYADMIN == 0 ]]; then
        print_warn "phpMyAdmin not installed — skipping configuration"
        return
    fi

    # Tarball install (no port): use the conf.d override pattern from the apt
    # path so overrides live under /opt/local/etc (preserved across upgrades).
    local pma_override_dir="${PORT_PREFIX}/etc/phpmyadmin/conf.d"
    local pma_override="${pma_override_dir}/phpup.php"
    sudo mkdir -p "$pma_override_dir" 2>/dev/null || true
    # Capture the existing blowfish secret BEFORE the overwriting heredoc below
    # erases it — re-appending the SAME value keeps re-configures idempotent
    # (a fresh random secret per run would rotate PMA cookies/sessions on every U).
    local pma_secret_val
    pma_secret_val=$(sed -n "s/.*'\([0-9a-f]\{32\}\)'.*/\1/p" "$pma_override" 2>/dev/null | tail -1)
    [[ -n "$pma_secret_val" ]] || pma_secret_val=$(pma_secret)
    sudo tee "$pma_override" > /dev/null <<'PMACONF'
<?php
// phpup — phpMyAdmin configuration overrides (MacPorts)
error_reporting(E_ALL & ~E_DEPRECATED);
$cfg['VersionCheck'] = false;
$cfg['SendErrorReports'] = 'never';
$cfg['LoginCookieValidity'] = 14400;
PMACONF
    # TempDir needs shell expansion (quoted heredoc above), so append separately
    echo "\$cfg['TempDir'] = '${PMA_DIR}/tmp';" | sudo tee -a "$pma_override" > /dev/null
    # Blowfish secret: PMA warns on missing (temporary key) — ports path writes
    # none by default. Always (re)append the captured/generated 32-byte secret so
    # the file is complete after the heredoc rewrite without rotating it.
    echo "\$cfg['blowfish_secret'] = '${pma_secret_val}';" | sudo tee -a "$pma_override" > /dev/null
    print_ok "Set blowfish secret"
    print_ok "Applied phpMyAdmin overrides (performance, 4h cookie)"

    # Tarball ships without config.inc.php — create one that loads the conf.d
    # overrides so AllowNoPassword and the rest take effect.
    local tarball_conf="${PMA_DIR}/config.inc.php"
    if [[ ! -f "$tarball_conf" ]] || ! grep -q "conf.d" "$tarball_conf" 2>/dev/null; then
        sudo tee "$tarball_conf" > /dev/null <<CONFDINCLUDE
<?php
// phpup — load MacPorts conf.d overrides + AllowNoPassword
\$conf_d_dir = '${pma_override_dir}/';
if (is_dir(\$conf_d_dir)) {
    foreach (glob(\$conf_d_dir . '*.php') as \$conf_file) {
        include \$conf_file;
    }
}
\$cfg['Servers'][1]['AllowNoPassword'] = true;
CONFDINCLUDE
        print_ok "Created tarball config with conf.d include"
    fi

    # Create phpMyAdmin tmp directory (required for template cache)
    ensure_pma_tmp "${PMA_DIR}/tmp" "_www"

    # Configure phpMyAdmin storage database (named 'pma')
    local pma_sql="${PMA_DIR}/sql/create_tables.sql"
    # MacPorts installs the client at the versioned path (no /opt/local/bin/mysql)
    local mysqlc="${PORT_PREFIX}/lib/${MARIADB_PORT}/bin/mysql"
    [[ -x "$mysqlc" ]] || mysqlc="${PORT_PREFIX}/bin/mysql"
    if [[ -f "$pma_sql" ]]; then
        if ! "$mysqlc" -u root -e "USE pma" &>/dev/null 2>&1; then
            print_info "Setting up phpMyAdmin storage database..."
            # Rename the db to 'pma' throughout the SQL
            sed 's/phpmyadmin/pma/g' "$pma_sql" | "$mysqlc" -u root 2>/dev/null || true
            # Grant pma user limited privileges for the storage tables.
            # MariaDB 12.x does NOT auto-create users on GRANT — CREATE USER first.
            "$mysqlc" -u root -e "CREATE USER IF NOT EXISTS 'pma'@'localhost' IDENTIFIED BY ''; GRANT SELECT, INSERT, UPDATE, DELETE ON pma.* TO 'pma'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true
        fi
        # Wire storage into the override using server index 1 (conf.d loads early).
        # Force TCP host: MacPorts' socket lives at the versioned run dir which
        # PHP's mysqli does not default to (login fails: No such file or directory).
        if ! grep -q "pmadb" "$pma_override" 2>/dev/null; then
            sudo tee -a "$pma_override" > /dev/null <<'PMASTORAGE'

$cfg['Servers'][1]['host'] = '127.0.0.1';
$cfg['Servers'][1]['controluser'] = 'pma';
$cfg['Servers'][1]['controlpass'] = '';
$cfg['Servers'][1]['pmadb'] = 'pma';
PMASTORAGE
            print_ok "Configured phpMyAdmin storage database (pma, TCP host)"
        fi
    else
        print_info "phpMyAdmin storage tables not found — skipping storage setup"
    fi

    print_ok "phpMyAdmin configured (MacPorts)"
}

# ---- Install Command ----------------------------------------
cmd_install() {
    if [[ $STACK == 1 ]]; then
        print_err "Stack is already installed. Use U to update or D to delete first."
        printf "\\n"
        read -r -p "Press Enter to continue..."
        return
    fi

    printf "\n${BOLD}phpup — Install Web Stack${RESET}\n\n"

    # macOS version check — pre-11 Big Sur compiles PHP from source
    if [[ $OS_MAJOR -lt 11 && $OS_NAME == "macOS" ]]; then
        printf "${YELLOW}ℹ  macOS ${OS_VERSION} detected — PHP will be compiled from source.${RESET}\n"
        printf "${YELLOW}   This takes longer and needs Xcode CLT.  macOS 11+ has pre-built bottles.${RESET}\n\n"
    fi

    # Q4: macOS below the supported floor is not viable for a modern stack.
    # Numeric compare — a lexicographic string compare would let 10.6–10.9 slip
    # through ('6' > '1' at the third char), so derive minor from OS_VERSION.
    if [[ $USE_PORTS == 1 ]]; then
        local os_minor min_major min_minor
        os_minor=$(echo "$OS_VERSION" | cut -d. -f2)
        min_major="${MACPORTS_MIN_OS%%.*}"
        min_minor="${MACPORTS_MIN_OS##*.}"
        if [[ $OS_MAJOR -lt $min_major ]] || { [[ $OS_MAJOR -eq $min_major ]] && [[ "$os_minor" =~ ^[0-9]+$ ]] && [[ $os_minor -lt $min_minor ]]; }; then
            printf "${RED}macOS ${OS_VERSION} is below the supported floor (10.15 Catalina).${RESET}\n"
            printf "${RED}This machine is not viable as a dev machine for a modern web stack — no package manager\n"
            printf "${RED}(Homebrew or MacPorts) can deliver a current PHP/Apache/MariaDB here.${RESET}\n\n"
            read -r -p "Press Enter to return to the dashboard..."
            return
        fi
    fi

    # Prerequisites
    check_prerequisites

    # Establish sudo credential early (extends 5-minute timeout)
    sudo -v || true

    # Create directories
    mkdir -p "$DOC_ROOT"
    print_ok "Created directory: ${DOC_ROOT}"

    mkdir -p "$LOGS_DIR"
    print_ok "Created directory: ${LOGS_DIR}"

    # Install packages (apt or brew)
    if [[ $USE_APT == 1 ]]; then
        printf "\n"
        print_info "Installing packages via apt..."
        printf "\n"
        apt_update_quiet
        [[ $APACHE == 0 ]] && sudo DEBIAN_FRONTEND=noninteractive apt install -y apache2 && APACHE=1
        if [[ $MARIADB == 0 ]]; then
            ensure_mariadb_repo || true
            sudo DEBIAN_FRONTEND=noninteractive apt install -y mariadb-server && MARIADB=1
        fi
        if [[ $PHP == 0 ]]; then
            # Install latest stable PHP (8.2+) via ondrej/php repo — mirrors Windows/macOS behaviour
            ensure_php_repo
            local php_latest
            php_latest=$(latest_php_version)
            if [[ -n "$php_latest" ]]; then
                print_info "Installing latest PHP ${php_latest} (ondrej/php repo)..."
                if install_php_version_apt "$php_latest"; then
                    PHP=1
                else
                    print_warn "Versioned install failed — falling back to distro default PHP"
                    sudo DEBIAN_FRONTEND=noninteractive apt install -y php php-curl php-fileinfo php-gd php-intl php-mbstring php-mysql php-sqlite3 php-fpm && PHP=1
                fi
            else
                print_warn "Could not detect latest PHP — installing distro default"
                sudo DEBIAN_FRONTEND=noninteractive apt install -y php php-curl php-fileinfo php-gd php-intl php-mbstring php-mysql php-sqlite3 php-fpm && PHP=1
            fi
        fi
        if [[ $PHPMYADMIN == 0 ]]; then
            local pma_latest
            pma_latest=$(latest_pma_version)
            if [[ -n "$pma_latest" ]] && install_pma_tarball "$pma_latest" /usr/share/phpmyadmin; then
                PHPMYADMIN=1
            else
                print_warn "phpMyAdmin tarball download failed — falling back to apt package"
                sudo DEBIAN_FRONTEND=noninteractive apt install -y phpmyadmin && PHPMYADMIN=1
            fi
        fi

    elif [[ $USE_PORTS == 1 ]]; then
        install_macports || { print_err "MacPorts bootstrap failed"; read -r -p "Press Enter..."; return; }
        export PATH="${PORT_PREFIX}/bin:${PORT_PREFIX}/sbin:${PATH}"

        printf "\n"; print_info "Installing packages via MacPorts (compiled from source — this can take a long time on Intel)..."; printf "\n"
        # Source builds take hours — refresh the sudo credential before each long command
        sudo -v || true
        [[ $APACHE == 0 ]] && sudo "${PORT_PREFIX}/bin/port" -N install apache2 && APACHE=1
        if [[ $MARIADB == 0 ]]; then
            sudo -v || true
            if sudo "${PORT_PREFIX}/bin/port" -N install "${MARIADB_PORT}" "${MARIADB_PORT}-server"; then
                MARIADB=1
            else
                print_warn "mariadb-12.3 failed — falling back to mariadb-11.4 (LTS)"
                MARIADB_PORT="mariadb-11.4"
                sudo "${PORT_PREFIX}/bin/port" -N install "${MARIADB_PORT}" "${MARIADB_PORT}-server" && MARIADB=1
            fi
        fi
        if [[ $PHP == 0 ]]; then
            sudo -v || true
            sudo "${PORT_PREFIX}/bin/port" -N install "${PHP_PORT}" "${PHP_PORT}-apache2handler" "${PHP_PORT}-mysql" \
                "${PHP_PORT}-curl" "${PHP_PORT}-gd" "${PHP_PORT}-intl" "${PHP_PORT}-mbstring" \
                "${PHP_PORT}-sqlite" "${PHP_PORT}-openssl" && PHP=1
        fi
        sudo "${PORT_PREFIX}/bin/port" select --set php "${PHP_PORT}" 2>/dev/null || true
        sudo "${PORT_PREFIX}/bin/port" select --set mysql "${MARIADB_PORT}" 2>/dev/null || true
        if [[ $PHPMYADMIN == 0 ]]; then
            local pma_latest
            pma_latest=$(latest_pma_version)
            if [[ -n "$pma_latest" ]] && install_pma_tarball "$pma_latest" "$PMA_DIR"; then
                PHPMYADMIN=1
            else
                print_warn "phpMyAdmin tarball download failed"
            fi
        fi

    else
        # Install Homebrew
        install_homebrew

        printf "\n"
        print_info "Installing packages via Homebrew..."
        printf "\n"

        [[ $APACHE == 0 ]] && printf 'y\n' | HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew install httpd && APACHE=1
        [[ $MARIADB == 0 ]] && { printf 'y\n' | HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew install mariadb || true; }
        [[ $PHP == 0 ]] && printf 'y\n' | HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew install php && PHP=1
        [[ $PHPMYADMIN == 0 ]] && printf 'y\n' | HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew install phpmyadmin && brew link --overwrite --force phpmyadmin 2>/dev/null && PHPMYADMIN=1

        # Refresh detection
        check_brew_path
        BREW_PREFIX=$(brew --prefix)
        detect_all

        # Linux: setcap for port 80
        if [[ "${OS_TYPE}" == "linux-gnu"* ]]; then
            if command -v httpd &>/dev/null; then
                local httpd_path
                httpd_path=$(readlink -f "$(which httpd)")
                sudo setcap 'cap_net_bind_service=+ep' "$httpd_path" 2>/dev/null && \
                    print_ok "Enabled port 80 binding for httpd (setcap)" || \
                    print_warn "Could not set port 80 capability — Apache may fail to bind port 80"
            fi
        fi
    fi

    # Create phpinfo.php (before chown takes ownership from user)
    printf "<?php phpinfo(); ?>\n" > "${DOC_ROOT}/phpinfo.php"
    print_ok "Created: ${DOC_ROOT}/phpinfo.php"

    # Configure components
    configure_apache
    configure_php
    configure_mariadb

    # Restore previous databases BEFORE phpMyAdmin config — the restore replaces
    # the datadir, which would otherwise wipe the pma control DB just created.
    check_restore_data

    configure_phpmyadmin

    # PATH management
    manage_path

    # Refresh sudo credential (brew installs may have taken 5+ minutes)
    sudo -v || true

    # Start services
    printf "\n"
    start_services

    # Detect versions post-install
    detect_all

    # Save config
    save_config "$BASE_DIR" "$APACHE_VERSION" "$MARIADB_VERSION" "$PHP_VERSION" "$PHPMYADMIN_VERSION"

    # Installation result
    if [[ $STACK == 1 ]]; then
        printf "\n"
        print_ok "INSTALLATION COMPLETE!"
        printf "\n"
        printf "${CYAN}Where to put website files?${RESET} %s\n" "$DOC_ROOT"
        printf "${CYAN}How to test your PHP setup?${RESET} http://localhost/phpinfo.php\n"
        printf "${CYAN}Where to access phpMyAdmin?${RESET} http://localhost/phpmyadmin\n"
        printf "${CYAN}How to log into phpMyAdmin?${RESET} Username: root | Password: [blank]\n"
        printf "\n"
    else
        print_err "INSTALLATION FAILED! Check the output above for errors."
    fi

    printf "\n"
    read -r -p "Press Enter to return to the dashboard..."
}

# ---- Update Command -----------------------------------------
cmd_update() {
    if [[ $STACK == 0 ]]; then
        print_err "Nothing to update — stack is not installed."
        printf "\n"
        read -r -p "Press Enter to continue..."
        return
    fi

    printf "\n${BOLD}phpup — Update Web Stack${RESET}\n\n"

    # Check for updates
    print_info "Checking for updates..."
    if [[ $USE_APT == 1 ]]; then
        apt_update_quiet
        local outdated
        outdated=$(apt list --upgradable 2>/dev/null | grep -E '^(apache2|mariadb-server|libapache2-mod-php|php)' || true)

        # Also detect when PHP has been downgraded to an older series —
        # apt list won't flag cross-series switches because the packages differ.
        local php_current php_latest
        php_current=$("$(apt_php_bin)" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null)

        # Find the latest STABLE PHP series (skip alpha/beta/RC previews)
        # and capture its full version string for the prompt.
        php_latest=""
        local php_latest_full="" v candidate_ver
        for v in $(apt-cache pkgnames 'php8.' 2>/dev/null | grep -E '^php8\.[0-9]+$' | sed 's/^php//' | sort -Vr | awk -F. -v fmaj="${PHP_MIN_SERIES%%.*}" -v fmin="${PHP_MIN_SERIES##*.}" '$1 > fmaj || ($1 == fmaj && $2 >= fmin)'); do
            candidate_ver=$(apt-cache show "php${v}-cli" 2>/dev/null | grep '^Version:' | head -1 | tr '[:upper:]' '[:lower:]')
            if [[ "$candidate_ver" != *alpha* && "$candidate_ver" != *beta* && "$candidate_ver" != *rc* && "$candidate_ver" != *preview* ]]; then
                php_latest="$v"
                php_latest_full=$(echo "$candidate_ver" | sed 's/^version: *//' | cut -d- -f1 | cut -d: -f2)
                break
            fi
        done

        if [[ -n "$php_latest" && "$php_current" != "$php_latest" ]]; then
            # Resolve full current version from the running binary
            local php_current_full
            php_current_full=$("$(apt_php_bin)" -r 'echo PHP_VERSION;' 2>/dev/null)
            local msg="PHP ${php_current_full} → ${php_latest_full}"
            if [[ -z "$outdated" ]]; then
                outdated="$msg"
            else
                outdated="${msg}"$'\n'"${outdated}"
            fi
        fi

        if [[ -z "$outdated" ]]; then
            print_ok "All components are up to date"
            printf "\n"
            read -r -p "Press Enter to continue..."
            return
        fi

        printf "\n${CYAN}Updates available:${RESET}\n"
        printf "%s\n" "$outdated"
        printf "\n"

        printf "${BOLD}Apply these updates? [y/N]:${RESET} "
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" && "$confirm" != "yes" && "$confirm" != "Yes" ]]; then
            print_info "Update cancelled."
            printf "\n"
            read -r -p "Press Enter to continue..."
            return
        fi

        stop_services
        printf "\n"
        print_info "Upgrading packages via apt..."
        print_info "This can take a minute or two while packages download and install."

        # If PHP is on an older series, install the versioned packages for the
        # latest series, then switch CLI + FPM + Apache to it.
        if [[ -n "$php_latest" && "$php_current" != "$php_latest" ]]; then
            print_info "Upgrading PHP ${php_current} → ${php_latest}..."
            install_php_version_apt "$php_latest"
            configure_php_apt
            switch_fpm_apt "$php_latest"
        fi
        sudo apt upgrade -y apache2 mariadb-server $(php_active_pkgs)

        # Check for newer phpMyAdmin tarball
        local pma_latest
        pma_latest=$(latest_pma_version)
        if [[ -n "$pma_latest" && "$PHPMYADMIN_VERSION" != "$pma_latest" ]]; then
            printf "\n${CYAN}phpMyAdmin ${pma_latest} available (installed: ${PHPMYADMIN_VERSION})${RESET}\n"
            printf "${BOLD}Upgrade phpMyAdmin? [Y/n]:${RESET} "
            read -r pma_upgrade
            if [[ "$pma_upgrade" != "n" && "$pma_upgrade" != "N" ]]; then
                install_pma_tarball "$pma_latest" /usr/share/phpmyadmin || print_warn "phpMyAdmin tarball upgrade failed"
            fi
        fi

        configure_apache
        configure_php
        configure_phpmyadmin
        start_services
    elif [[ $USE_PORTS == 1 ]]; then
        print_info "Updating ports tree (port selfupdate)..."
        print_info "This can take a minute or two — the ports tree is a large download."
        # Stream live so the user sees progress (no | tail buffering) —
        # $? captures port's real exit status directly.
        sudo "${PORT_PREFIX}/bin/port" selfupdate 2>&1
        local selfupdate_status=$?
        if [[ $selfupdate_status -ne 0 ]]; then
            # Non-fatal: the `port outdated` gate below is self-correcting, but be honest
            print_warn "port selfupdate failed (exit ${selfupdate_status}) — continuing with the current ports tree"
        fi
        local outdated
        outdated=$("${PORT_PREFIX}/bin/port" outdated 2>/dev/null | grep -E "apache2|${PHP_PORT}|php8|mariadb" || true)
        if [[ -z "$outdated" ]]; then
            print_ok "All stack components are up to date"; printf "\n"; read -r -p "Press Enter to continue..."; return
        fi
        printf "\n${CYAN}Updates available:${RESET}\n"; printf "%s\n" "$outdated"; printf "\n"
        printf "${BOLD}Apply these updates? [y/N]:${RESET} "
        read -r confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" && "$confirm" != "yes" ]] && { print_info "Update cancelled."; printf "\n"; read -r -p "Press Enter to continue..."; return; }
        stop_services
        printf "\n"; print_info "Upgrading packages via MacPorts..."
        print_info "This can take several minutes — upgraded ports may recompile from source."
        # N1: stream live so the user sees progress — $? captures port's real
        # exit status so a failed upgrade is never reported as "UPDATE COMPLETE!"
        sudo "${PORT_PREFIX}/bin/port" upgrade outdated 2>&1
        local upgrade_status=$?
        if [[ $upgrade_status -ne 0 ]]; then
            print_err "port upgrade failed (exit ${upgrade_status}) — no updates were applied"
            printf "\n"
            read -r -p "Press Enter to return to the dashboard..."
            return
        fi
        # phpMyAdmin tarball upgrade (same as apt branch)
        local pma_latest
        pma_latest=$(latest_pma_version)
        if [[ -n "$pma_latest" && "$PHPMYADMIN_VERSION" != "$pma_latest" ]]; then
            printf "\n${CYAN}phpMyAdmin ${pma_latest} available (installed: ${PHPMYADMIN_VERSION})${RESET}\n"
            printf "${BOLD}Upgrade phpMyAdmin? [Y/n]:${RESET} "
            read -r pma_upgrade
            [[ "$pma_upgrade" != "n" && "$pma_upgrade" != "N" ]] && install_pma_tarball "$pma_latest" "$PMA_DIR" || print_warn "phpMyAdmin upgrade failed"
        fi
        configure_apache; configure_php; configure_phpmyadmin
        start_services
    else
        brew update &>/dev/null
        # Detect the ACTIVE PHP formula — meta 'php' or a versioned php@X.Y
        # (after a fu switch, the versioned formula is the one linked into
        # the prefix; update THAT, not the unlinked meta).
        local active_php
        active_php=$(brew_active_php)
        # Newest PHP line available in Homebrew — used for the fu hint so a
        # user on an older line knows a newer one exists (u only patches
        # within the ACTIVE line; fu is the line switcher).
        local newest_line
        newest_line=$(brew search '/php@/' 2>/dev/null | tr ' ' '\n' | grep -E '^php@[0-9]+\.[0-9]+$' | sort -V | tail -1)
        local outdated
        outdated=$(brew outdated --formula httpd mariadb "$active_php" phpmyadmin 2>/dev/null)

        if [[ -z "$outdated" ]]; then
            print_ok "All stack components are up to date"
            local cur_ver
            cur_ver=$(php -r 'echo PHP_VERSION;' 2>/dev/null)
            [[ -z "$cur_ver" ]] && cur_ver="$PHP_VERSION"
            print_info "PHP ${cur_ver} (${active_php}) is up to date within its version line"
            if [[ -n "$newest_line" && "$newest_line" != "$active_php" ]]; then
                print_info "PHP ${newest_line#php@} is available in Homebrew — use fu to switch PHP versions."
            fi
            printf "\n"
            read -r -p "Press Enter to continue..."
            return
        fi

        printf "\n${CYAN}Updates available:${RESET}\n"
        printf "%s\n" "$outdated"
        if [[ -n "$newest_line" && "$newest_line" != "$active_php" ]]; then
            print_info "PHP ${newest_line#php@} is also available in Homebrew — use fu to switch PHP versions."
        fi
        printf "\n"

        printf "${BOLD}Apply these updates? [y/N]:${RESET} "
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" && "$confirm" != "yes" && "$confirm" != "Yes" ]]; then
            print_info "Update cancelled."
            printf "\n"
            read -r -p "Press Enter to continue..."
            return
        fi

        stop_services
        printf "\n"
        print_info "Upgrading packages via Homebrew..."
        HOMEBREW_NO_AUTO_UPDATE=1 printf 'y\n' | brew upgrade httpd mariadb "$active_php" phpmyadmin
        detect_all
        configure_apache
        configure_php
        configure_phpmyadmin
        start_services
    fi

    # Save new versions
    detect_all
    save_config "$BASE_DIR" "$APACHE_VERSION" "$MARIADB_VERSION" "$PHP_VERSION" "$PHPMYADMIN_VERSION"

    # Clean up stale upgrade backup (MariaDB data snapshot left by a prior fu upgrade)
    local stale_backup="${BASE_DIR}/data_backup_pre_upgrade"
    [[ -d "$stale_backup" ]] && sudo rm -rf "$stale_backup" 2>/dev/null || true

    print_ok "UPDATE COMPLETE!"
    printf "\n"
    read -r -p "Press Enter to return to the dashboard..."
}

# ---- Delete Command -----------------------------------------
cmd_delete() {
    if [[ $STACK == 0 ]]; then
        print_err "Nothing to delete — stack is not installed."
        printf "\n"
        read -r -p "Press Enter to continue..."
        return
    fi

    printf "\n"
    printf "${RED}THIS WILL BE DELETED:${RESET}\n"
    printf "${RED}- Apache, MariaDB, PHP, and phpMyAdmin.${RESET}\n"
    printf "${RED}- Services, logs, and runtime state.${RESET}\n\n"
    printf "${GREEN}THIS WILL NOT BE DELETED:${RESET}\n"
    printf "${GREEN}- Your website files in %s${RESET}\n" "$DOC_ROOT"
    printf "${GREEN}- Your MariaDB databases (backed up to %s)${RESET}\n" "$DATA_BACKUP_DIR"
    if [[ $USE_PORTS == 1 ]]; then
        printf "${GREEN}- Your config files (kept in /opt/local/etc — restored on reinstall)${RESET}\n"
    else
        printf "${GREEN}- Your config files (kept in /etc — restored on reinstall)${RESET}\n"
    fi
    printf "\n"
    printf "${BOLD}Type DELETE to confirm:${RESET} "
    read -r confirm_delete

    if [[ "$confirm_delete" != "DELETE" ]]; then
        printf "\n"
        print_ok "Nothing was deleted."
        printf "\n"
        read -r -p "Press Enter to continue..."
        return
    fi

    printf "\n"

    # Stop services
    stop_services
    print_ok "Stopped all services"

    # Backup MariaDB data
    local mariadb_data
    if [[ $USE_APT == 1 ]]; then
        mariadb_data="/var/lib/mysql"
    elif [[ $USE_PORTS == 1 ]]; then
        mariadb_data="${PORT_PREFIX}/var/db/${MARIADB_PORT}"
    else
        mariadb_data="${BREW_PREFIX}/var/mysql"
    fi

    if [[ -d "$mariadb_data" ]] && [[ "$(ls -A "$mariadb_data" 2>/dev/null)" ]]; then
        # Handle existing backup
        if [[ -d "$DATA_BACKUP_DIR" ]]; then
            local timestamp
            timestamp=$(date "+%Y%m%d_%H%M%S")
            local archived_backup="${BASE_DIR}/data_backup_${timestamp}"
            if [[ $USE_APT == 1 ]] || [[ $USE_PORTS == 1 ]]; then
                sudo mv "$DATA_BACKUP_DIR" "$archived_backup" 2>/dev/null || true
            else
                mv "$DATA_BACKUP_DIR" "$archived_backup" 2>/dev/null || true
            fi
            print_ok "Archived existing backup to ${archived_backup}"
        fi

        # Copy entire data directory for full restore on reinstall.
        # apt datadir is 700 mysql:mysql — must copy as root or the system
        # schema and user databases are silently skipped (cp exits 0).
        # ports datadir is owned by _mysql — same sudo requirement.
        if [[ $USE_APT == 1 ]] || [[ $USE_PORTS == 1 ]]; then
            sudo cp -r "$mariadb_data" "$DATA_BACKUP_DIR" 2>/dev/null || true
        else
            cp -r "$mariadb_data" "$DATA_BACKUP_DIR" 2>/dev/null || true
        fi
        print_ok "Backed up MariaDB data to ${DATA_BACKUP_DIR}"
    else
        print_info "No MariaDB data to back up"
    fi

    # Uninstall packages
    if [[ $USE_APT == 1 ]]; then
        # Collect ALL installed php packages (versioned + metas + phpmyadmin deps),
        # so nothing lingers regardless of which PHP versions are present
        local php_all
        php_all=$(dpkg -l 2>/dev/null | awk '/^ii/{print $2}' | grep -E '^(php|libapache2-mod-php)' | tr '\n' ' ')
        sudo DEBIAN_FRONTEND=noninteractive apt remove -y apache2 mariadb-server $php_all 2>/dev/null || true
        sudo DEBIAN_FRONTEND=noninteractive apt autoremove -y 2>/dev/null || true

        # Remove phpMyAdmin tarball install (if present)
        sudo rm -rf /usr/share/phpmyadmin 2>/dev/null || true

        # Remove runtime state dirs — configs in /etc are preserved by apt remove
        # (conffiles), user data is in www/ + data_backup. /var/lib holds only
        # runtime state (sessions, tmp, sockets) safe to purge for a fresh start.
        sudo rm -rf /var/lib/apache2 /var/lib/php /var/lib/phpmyadmin 2>/dev/null || true
        # Remove the phpup-managed Apache FPM conf (regenerated on reinstall)
        sudo rm -f "$(apache_fpm_conf)" "$(apache_fpm_conf).phpup.bak" 2>/dev/null || true
        # /var/lib/mysql is the live datadir — its contents were backed up above;
        # removing it gives a genuinely fresh reinstall. Configs stay in /etc/mysql.
        sudo rm -rf /var/lib/mysql 2>/dev/null || true
        print_ok "Removed runtime state (/var/lib)"
        print_ok "Uninstalled packages"
    elif [[ $USE_PORTS == 1 ]]; then
        # Uninstall leaf-first (dependents before dependencies) so port does not
        # prompt. Do NOT use `port -y` — it is a dry run, not confirm-skip.
        local stack_ports=("${PHP_PORT}-apache2handler" "${PHP_PORT}-mysql" "${PHP_PORT}-curl" \
            "${PHP_PORT}-gd" "${PHP_PORT}-intl" "${PHP_PORT}-mbstring" "${PHP_PORT}-sqlite" \
            "${PHP_PORT}-openssl" "${PHP_PORT}" "apache2" "${MARIADB_PORT}-server" "${MARIADB_PORT}")
        for p in "${stack_ports[@]}"; do
            sudo "${PORT_PREFIX}/bin/port" uninstall "$p" 2>/dev/null || true
        done
        # Safety net if any uninstall was blocked by dependents
        sudo "${PORT_PREFIX}/bin/port" uninstall --follow-dependents "${MARIADB_PORT}-server" apache2 2>/dev/null || true
        print_ok "Uninstalled packages"
    else
        brew uninstall httpd 2>/dev/null || true
        brew uninstall mariadb 2>/dev/null || true
        brew uninstall php 2>/dev/null || true
        brew uninstall phpmyadmin 2>/dev/null || true
        brew autoremove 2>/dev/null || true
        brew cleanup 2>/dev/null || true
        # Force-remove any lingering kegs (phpMyAdmin twig cache owned by _www can block rm -rf)
        for f in httpd mariadb php phpmyadmin; do
            brew uninstall --force --ignore-dependencies "$f" 2>/dev/null || true
        done
        print_ok "Uninstalled packages"
    fi

    # Clean up backend leftovers that survive uninstall
    if [[ $USE_PORTS == 1 ]]; then
        # MariaDB data dir (already backed up above) + runtime state; keep
        # /opt/local/etc configs (parity with apt keeping /etc — restored on reinstall)
        sudo rm -rf "${PORT_PREFIX}/var/db/${MARIADB_PORT}" 2>/dev/null || true
        sudo rm -rf "${PORT_PREFIX}/var/log/${MARIADB_PORT}" 2>/dev/null || true
        sudo rm -rf "${PORT_PREFIX}/var/run/${MARIADB_PORT}" 2>/dev/null || true
        sudo rm -rf "${PMA_DIR}" 2>/dev/null || true
        print_ok "Removed MariaDB data dir and phpMyAdmin tarball"
        # Build cache note: MacPorts keeps compiled port archives in
        # /opt/local/var/macports/software — uninstall leaves them in place,
        # so reinstall/version-switch reuse the cache instead of recompiling.
        print_info "MacPorts build cache kept (reinstall will be fast). Clear with: sudo port clean --all"
        [[ -d "${PORT_PREFIX}/var/db/${MARIADB_PORT}" ]] && print_warn "Run: sudo rm -rf ${PORT_PREFIX}/var/db/${MARIADB_PORT}"
        # Restore PATH: remove the phpup-added shell profile lines so new
        # login shells no longer point at /opt/local (Apple's /usr/bin php
        # returns as the default after the stack is gone).
        local marker="# phpup: keep MacPorts binaries ahead of system (/usr/bin)"
        if grep -qF "$marker" "$SHELL_PROFILE" 2>/dev/null; then
            local filtered_profile
            filtered_profile=$(grep -vF -e "$marker" -e 'export PATH="/opt/local/bin:/opt/local/sbin:$PATH"' "$SHELL_PROFILE" 2>/dev/null)
            printf '%s\n' "$filtered_profile" > "$SHELL_PROFILE" 2>/dev/null
            print_ok "Restored shell PATH in ${SHELL_PROFILE}"
        fi
    elif [[ $USE_APT == 0 ]]; then
        # Remove MariaDB data dir (brew uninstall leaves it behind)
        local mariadb_data="${BREW_PREFIX}/var/mysql"
        rm -rf "$mariadb_data" 2>/dev/null || true
        print_ok "Removed MariaDB data directory"

        # Warn if any Cellar skeletons remain (broken package state)
        for cellar_dir in httpd mariadb php phpmyadmin; do
            if [[ -d "${BREW_PREFIX}/Cellar/${cellar_dir}" ]]; then
                print_warn "Cellar/${cellar_dir} still present — run: sudo rm -rf ${BREW_PREFIX}/Cellar/${cellar_dir}"
            fi
        done

        # Remove stale launchagent plists
        rm -f "${HOME}/Library/LaunchAgents/homebrew.mxcl.*.plist" 2>/dev/null || true
        print_ok "Removed stale LaunchAgent plists"
    fi

    # Remove remaining logs
    rm -rf "$LOGS_DIR" 2>/dev/null || true
    print_ok "Removed logs"

    # Clear config
    clear_config
    print_ok "Cleared phpup config"

    # Reset detection
    APACHE=0; MARIADB=0; PHP=0; PHPMYADMIN=0; STACK=0

    printf "\n"
    print_ok "DELETION COMPLETE!"
    printf "${GREEN}Your website files are preserved in: %s${RESET}\n" "$DOC_ROOT"
    printf "${GREEN}Your databases are preserved in:   %s${RESET}\n" "$DATA_BACKUP_DIR"
    if [[ $USE_PORTS == 1 ]]; then
        printf "${GREEN}Your config files are preserved in: /opt/local/etc (restored on reinstall)${RESET}\n"
    else
        printf "${GREEN}Your config files are preserved in: /etc (restored on reinstall)${RESET}\n"
    fi
    printf "\n"
    read -r -p "Press Enter to continue..."
}

# ---- Forced Update / Version Switching ----------------------
latest_php_version() {
    # Latest stable PHP version available via apt (e.g. 8.5), skipping pre-releases
    local version candidate latest=""
    for version in $(apt-cache pkgnames 'php8.' 2>/dev/null | grep -E '^php8\.[0-9]+$' | sed 's/^php//' | sort -V); do
        candidate=$(apt-cache policy "php${version}" 2>/dev/null | awk '/Candidate:/{print $2; exit}')
        [[ -n "$candidate" ]] || continue
        case "$candidate" in
            *alpha*|*beta*|*RC*|*rc*) continue ;;
        esac
        latest="$version"
    done
    echo "$latest"
}

php_active_pkgs() {
    # Versioned package set for the ACTIVE PHP version (e.g. php8.5-*), else meta fallback
    local pver
    pver=$("$(apt_php_bin)" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null)
    if [[ -n "$pver" ]]; then
        echo "php${pver} php${pver}-cli php${pver}-fpm php${pver}-curl php${pver}-gd php${pver}-intl php${pver}-mbstring php${pver}-mysql php${pver}-sqlite3 php${pver}-xml php${pver}-zip php${pver}-bcmath php${pver}-bz2"
    else
        echo "php php-curl php-gd php-intl php-mbstring php-mysql php-sqlite3 php-fpm"
    fi
}

install_php_version_apt() {
    # Install versioned PHP packages and make them the CLI default. FPM/Apache
    # activation is the caller's job (configure_apache_apt for fresh install,
    # switch_fpm_apt for version switches) so ini edits happen before FPM starts.
    local target="$1"
    if ! sudo DEBIAN_FRONTEND=noninteractive apt install -y \
        "php${target}" "php${target}-cli" "php${target}-fpm" "php${target}-curl" "php${target}-gd" \
        "php${target}-intl" "php${target}-mbstring" "php${target}-mysql" \
        "php${target}-sqlite3" "php${target}-xml" "php${target}-zip" \
        "php${target}-bcmath" "php${target}-bz2"; then
        return 1
    fi

    # Switch CLI alternative to the new version
    sudo update-alternatives --set php "/usr/bin/php${target}" 2>/dev/null || true
    APT_PHP_BIN_CACHE=""

    return 0
}

ensure_php_repo() {
    # ondrej/php repo (deb.sury.org) provides PHP 8.2+ on Debian & Ubuntu
    if grep -rq "packages.sury.org" /etc/apt/sources.list.d/ 2>/dev/null; then
        return 0
    fi

    local codename
    codename=$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2)
    if [[ -z "$codename" ]]; then
        print_err "Cannot determine OS codename — cannot add PHP repository."
        return 1
    fi

    print_info "Adding ondrej/php repository (deb.sury.org)..."
    sudo curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/trusted.gpg.d/php.gpg 2>/dev/null || {
        print_err "Failed to fetch PHP repository key."
        return 1
    }
    echo "deb https://packages.sury.org/php/ ${codename} main" | sudo tee /etc/apt/sources.list.d/phpup-php.list > /dev/null
    apt_update_quiet
    print_ok "Added ondrej/php repository"
    return 0
}

# ---- phpMyAdmin Tarball Helpers ------------------------------
latest_pma_version() {
    # Latest stable phpMyAdmin version from phpmyadmin.net
    curl -s https://www.phpmyadmin.net/home_page/version.txt 2>/dev/null | head -1 | tr -d '[:space:]'
}

install_pma_tarball() {
    local version="$1"
    local pma_dir="$2"    # backend-specific target: /usr/share, /opt/local/share, brew Cellar
    local url="https://files.phpmyadmin.net/phpMyAdmin/${version}/phpMyAdmin-${version}-all-languages.tar.gz"
    local tmp_dir="/tmp/phpup_pma_$$"

    print_info "Downloading phpMyAdmin ${version}..."
    mkdir -p "$tmp_dir"
    if ! curl -fsSL --connect-timeout 30 "$url" -o "${tmp_dir}/phpmyadmin.tar.gz"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    # Remove old install
    sudo rm -rf "$pma_dir"

    # Extract
    print_info "Extracting phpMyAdmin..."
    sudo mkdir -p "$pma_dir"
    sudo tar -xzf "${tmp_dir}/phpmyadmin.tar.gz" -C "$tmp_dir"
    sudo mv "${tmp_dir}/phpMyAdmin-${version}-all-languages"/* "$pma_dir/"
    sudo mv "${tmp_dir}/phpMyAdmin-${version}-all-languages"/.* "$pma_dir/" 2>/dev/null || true

    # Write version file for detection
    echo "$version" | sudo tee "$pma_dir/phpup-version.txt" > /dev/null

    # Cleanup
    rm -rf "$tmp_dir"
    return 0
}

# ---- MariaDB Repo Helpers ------------------------------------
latest_mariadb_series() {
    # Latest stable MariaDB major.minor series (e.g. "12.3")
    # The REST API returns minified JSON. Split on each release object,
    # find the first Stable one, and extract its release_id.
    curl -s "https://downloads.mariadb.org/rest-api/mariadb/" 2>/dev/null | \
        awk -v RS='{"release_id"' '/release_status.*Stable/{print $2; exit}' FS='"'
}

ensure_mariadb_repo() {
    if grep -rq "mariadb.org" /etc/apt/sources.list.d/ 2>/dev/null; then
        return 0
    fi

    local series
    series=$(latest_mariadb_series)
    if [[ -z "$series" ]]; then
        print_err "Cannot determine latest MariaDB version — skipping repo setup."
        return 1
    fi

    local distro_path codename
    . /etc/os-release
    if [[ "$ID" == "ubuntu" ]]; then
        distro_path="ubuntu"
    else
        distro_path="debian"
    fi
    codename=$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2)

    print_info "Adding MariaDB.org repository (${series})..."
    sudo curl -fsSL https://mariadb.org/mariadb_release_signing_key.asc \
        -o /etc/apt/trusted.gpg.d/mariadb.asc 2>/dev/null || {
        print_err "Failed to fetch MariaDB repository key."
        return 1
    }
    echo "deb [signed-by=/etc/apt/trusted.gpg.d/mariadb.asc] https://deb.mariadb.org/${series}/${distro_path} ${codename} main" | \
        sudo tee /etc/apt/sources.list.d/phpup-mariadb.list > /dev/null
    apt_update_quiet
    print_ok "Added MariaDB.org repository (${series})"
    return 0
}

switch_php_apt() {
    if ! ensure_php_repo; then
        printf "\n"
        read -r -p "Press Enter to return to the dashboard..."
        return
    fi

    # Sync php meta packages to the repo's versions so U doesn't list them
    # (metas are pointers only — active versioned FPM is untouched)
    print_info "Syncing PHP meta packages..."
    sudo apt-get install --only-upgrade -y \
        php php-curl php-gd php-intl php-mbstring php-mysql php-sqlite3 \
        php-xml php-zip php-bcmath php-bz2 php-fpm &>/dev/null || true
    print_ok "PHP meta packages up to date"

    # Current active version
    local current
    current=$("$(apt_php_bin)" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null)

    # Available versions (8.2 to latest)
    local versions
    versions=$(apt-cache pkgnames 'php8.' 2>/dev/null | grep -E '^php8\.[0-9]+$' | sed 's/^php//' | sort -V | awk -F. -v fmaj="${PHP_MIN_SERIES%%.*}" -v fmin="${PHP_MIN_SERIES##*.}" '$1 > fmaj || ($1 == fmaj && $2 >= fmin)')

    if [[ -z "$versions" ]]; then
        print_err "No PHP ${PHP_MIN_SERIES}+ versions found via apt."
        printf "\n"
        read -r -p "Press Enter to return to the dashboard..."
        return
    fi

    printf "\n${CYAN}Available PHP versions:${RESET}\n"

    local i=1 v
    declare -a opts=()
    while read -r v; do
        local tag=""
        if [[ "$v" == "$current" ]]; then
            tag=" ${GREEN}(active)${RESET}"
        elif [[ -x "/usr/bin/php${v}" ]]; then
            tag=" ${YELLOW}(installed)${RESET}"
        fi
        printf "  %d) PHP %s%b\n" "$i" "$v" "$tag"
        opts[$i]="$v"
        ((i++))
    done <<< "$versions"

    printf "\n${BOLD}Enter the number of the PHP version to switch to (or press Enter to cancel):${RESET} "
    read -r choice

    if [[ -z "$choice" ]]; then
        print_info "No change made."
        printf "\n"
        read -r -p "Press Enter to return to the dashboard..."
        return
    fi

    local target="${opts[$choice]}"
    if [[ -z "$target" ]]; then
        print_err "Invalid selection."
        printf "\n"
        read -r -p "Press Enter to return to the dashboard..."
        return
    fi

    # Short-circuit only when FPM is already serving this version. On a
    # legacy mod_php box (no FPM active) selecting the same version must still
    # run the migration: install FPM packages, wire Apache to the socket,
    # disable mod_php.
    if [[ "$target" == "$current" ]] && [[ "$(fpm_active_version || true)" == "$target" ]]; then
        print_ok "PHP ${target} is already active."
        printf "\n"
        read -r -p "Press Enter to return to the dashboard..."
        return
    fi

    print_info "Installing PHP ${target} packages..."

    if ! install_php_version_apt "$target"; then
        print_err "Failed to install PHP ${target}."
        printf "\n"
        read -r -p "Press Enter to return to the dashboard..."
        return
    fi

    # Re-apply PHP config for the new version (fpm + cli ini)
    configure_php_apt

    # Activate FPM + Apache for the new version (idempotent; rolls back on failure)
    if ! switch_fpm_apt "$target"; then
        print_err "PHP-FPM switch to ${target} failed."
        printf "\n"
        read -r -p "Press Enter to return to the dashboard..."
        return
    fi

    detect_all
    save_config "$BASE_DIR" "$APACHE_VERSION" "$MARIADB_VERSION" "$PHP_VERSION" "$PHPMYADMIN_VERSION"

    print_ok "PHP switched to ${target} (previous version kept installed — switch back anytime with fu)"
    printf "\n${BOLD}Verification:${RESET}\n"
    printf "  PHP CLI:    %s\n" "$("$(apt_php_bin)" -r 'echo PHP_VERSION;' 2>/dev/null)"
    printf "  PHP-FPM:    %s (%s)\n" "$target" "$(systemctl is-active "php${target}-fpm" 2>/dev/null)"
    printf "  Apache PHP: %s\n" "$(verify_apache_php || echo "unreachable")"
    printf "\n"
    read -r -p "Press Enter to return to the dashboard..."
}

cmd_forced_update() {
    if [[ $STACK == 0 ]]; then
        print_err "Nothing to switch — stack is not installed."
        printf "\n"
        read -r -p "Press Enter to continue..."
        return
    fi

    printf "\n${BOLD}PHP Version Switch${RESET}\n\n"

    if [[ $USE_APT == 1 ]]; then
        ensure_php_repo 2>/dev/null || true
        switch_php_apt
        return
    fi

    if [[ $USE_PORTS == 1 ]]; then
        # List AVAILABLE php8X ports from the tree (8.2 → latest stable). The port
        # name regex excludes devel/pre-release ports; MacPorts stable ports don't
        # use alpha/beta/rc version suffixes so no version-level filter is needed.
        local -a php_names
        local php_list current_php i choice target
        printf "${CYAN}Available PHP versions:${RESET}\n"
        # capture "name version" pairs, e.g. "php85 8.5.9"
        php_list=$("${PORT_PREFIX}/bin/port" list 'php8[0-9]' 2>/dev/null | \
            awk '$1 ~ /^php8[0-9]+$/ {v=$2; sub(/^@/, "", v); print $1, v}' | \
            awk -F'php8' '$2 >= 2 {print $0}' | \
            sort -V)
        current_php=$(sudo "${PORT_PREFIX}/bin/port" select --list php 2>/dev/null | awk '/\(active\)/ {print $1}')
        i=0
        while read -r name ver; do
            i=$((i+1))
            php_names[$i]="$name"
            if [[ "$name" == "$current_php" ]]; then
                printf "  ${GREEN}%d) %s (%s)${RESET} (current)\n" "$i" "$name" "$ver"
            else
                printf "  %d) %s (%s)\n" "$i" "$name" "$ver"
            fi
        done <<< "$php_list"
        if [[ $i -eq 0 ]]; then
            print_warn "No PHP versions found in the MacPorts tree — run Update (U) to refresh the ports tree first"
            printf "\n"
            read -r -p "Press Enter to return to the dashboard..."
            return
        fi
        printf "\n${BOLD}Enter the number of the version to switch to (e.g. 3), a version like 8.4, or press Enter to skip:${RESET} "
        read -r choice
        if [[ -n "$choice" ]]; then
            # N5: validate FIRST — only a menu number or a plain version string
            # may reach the sudo'd commands below (no free-form injection).
            target=""
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                if [[ "$choice" -ge 1 && "$choice" -le "$i" ]]; then
                    target="${php_names[$choice]}"
                else
                    print_err "Invalid choice '${choice}' — pick a number from the list (nothing was changed)"
                    printf "\n"
                    read -r -p "Press Enter to return to the dashboard..."
                    return
                fi
            elif [[ "$choice" =~ ^[0-9]+\.[0-9]+$ ]]; then
                # dotted version (8.4) → port name (php84) — port names have no dot
                target="php$(printf '%s' "$choice" | tr -d '.')"
                if ! printf '%s\n' "${php_names[@]}" | grep -qx "$target"; then
                    print_err "PHP ${choice} is not available on this MacPorts tree (nothing was changed)"
                    printf "\n"
                    read -r -p "Press Enter to return to the dashboard..."
                    return
                fi
            elif [[ "$choice" =~ ^php8[0-9]+$ ]]; then
                target="$choice"
                if ! printf '%s\n' "${php_names[@]}" | grep -qx "$target"; then
                    print_err "PHP ${choice} is not available on this MacPorts tree (nothing was changed)"
                    printf "\n"
                    read -r -p "Press Enter to return to the dashboard..."
                    return
                fi
            else
                print_err "Invalid input '${choice}' — expected a number or a version like 8.4 (nothing was changed)"
                printf "\n"
                read -r -p "Press Enter to return to the dashboard..."
                return
            fi
            # If the user picked the version already active, no work needed —
            # say so instead of reinstalling it.
            if [[ "$target" == "$current_php" ]]; then
                print_ok "${target} is already the active PHP version — nothing to do"
                printf "\n"
                read -r -p "Press Enter to return to the dashboard..."
                return
            fi
            print_info "Installing ${target} + Apache handler..."
            print_info "First switch may take a while — PHP compiles from source on macOS 10.x (later switches reuse the cache)."
            # F1: stream live so the user sees progress — $? captures port's real
            # exit status so a failed install can NEVER rewrite httpd.conf to a
            # dead LoadModule line.
            sudo "${PORT_PREFIX}/bin/port" -N install "$target" "${target}-apache2handler" "${target}-mysql" \
                "${target}-curl" "${target}-gd" "${target}-intl" "${target}-mbstring" \
                "${target}-sqlite" "${target}-openssl" 2>&1
            local install_status=$?
            if [[ $install_status -ne 0 ]]; then
                print_err "Failed to install ${target} (port install exited ${install_status}) — httpd.conf left untouched"
                printf "\n"
                read -r -p "Press Enter to return to the dashboard..."
                return
            fi
            sudo "${PORT_PREFIX}/bin/port" select --set php "$target" 2>/dev/null || true
            PHP_PORT="$target"
            detect_all
            configure_apache_ports
            configure_php_ports
            sudo "${PORT_PREFIX}/bin/port" reload apache2 >/dev/null 2>&1 || sudo "${PORT_PREFIX}/sbin/apachectl" restart >/dev/null 2>&1
            detect_all
            save_config "$BASE_DIR" "$APACHE_VERSION" "$MARIADB_VERSION" "$PHP_VERSION" "$PHPMYADMIN_VERSION"
            print_ok "PHP switched to ${PHP_VERSION}"
        fi
        printf "\n"
        read -r -p "Press Enter to return to the dashboard..."
        return
    fi

    # Homebrew path — PHP version switching (numbered menu, same UX as ports)
    local -a php_names
    local php_list current_php i choice target formula
    printf "${CYAN}Available PHP versions:${RESET}\n"
    # brew search returns space-separated formulae on one line — split and filter
    php_list=$(brew search '/php@/' 2>/dev/null | tr ' ' '\n' | grep -E '^php@[0-9]+\.[0-9]+$' | sort -V)
    # current = the versioned formula matching the ACTIVE php binary
    current_php="php@$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null)"
    i=0
    while read -r formula; do
        i=$((i+1))
        php_names[$i]="$formula"
        if [[ "$formula" == "$current_php" ]]; then
            printf "  ${GREEN}%d) %s${RESET} (current)\n" "$i" "$formula"
        else
            printf "  %d) %s\n" "$i" "$formula"
        fi
    done <<< "$php_list"
    if [[ $i -eq 0 ]]; then
        print_warn "No versioned PHP formulae found in Homebrew — run Update (U) to refresh first"
        printf "\n"
        read -r -p "Press Enter to return to the dashboard..."
        return
    fi
    printf "\n${BOLD}Enter the number of the version to switch to (e.g. 3), a version like 8.4, or press Enter to skip:${RESET} "
    read -r choice
    if [[ -n "$choice" ]]; then
        # Validate FIRST — only a menu number or a plain version/formula string
        # may reach the brew commands below (no free-form injection).
        target=""
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [[ "$choice" -ge 1 && "$choice" -le "$i" ]]; then
                target="${php_names[$choice]}"
            else
                print_err "Invalid choice '${choice}' — pick a number from the list (nothing was changed)"
                printf "\n"
                read -r -p "Press Enter to return to the dashboard..."
                return
            fi
        elif [[ "$choice" =~ ^[0-9]+\.[0-9]+$ ]]; then
            # dotted version (8.4) → formula (php@8.4)
            target="php@${choice}"
            if ! printf '%s\n' "${php_names[@]}" | grep -qx "$target"; then
                print_err "PHP ${choice} is not available in Homebrew (nothing was changed)"
                printf "\n"
                read -r -p "Press Enter to return to the dashboard..."
                return
            fi
        elif [[ "$choice" =~ ^php@[0-9]+\.[0-9]+$ ]]; then
            target="$choice"
            if ! printf '%s\n' "${php_names[@]}" | grep -qx "$target"; then
                print_err "PHP ${choice} is not available in Homebrew (nothing was changed)"
                printf "\n"
                read -r -p "Press Enter to return to the dashboard..."
                return
            fi
        else
            print_err "Invalid input '${choice}' — expected a number or a version like 8.4 (nothing was changed)"
            printf "\n"
            read -r -p "Press Enter to return to the dashboard..."
            return
        fi
        # If the user picked the version already active, no work needed
        if [[ "$target" == "$current_php" ]]; then
            print_ok "${target} is already the active PHP version — nothing to do"
            printf "\n"
            read -r -p "Press Enter to return to the dashboard..."
            return
        fi
        printf "\n"
        print_info "Switching PHP to ${target}..."

        # Stop services (the ACTIVE php service — may be php@X.Y, not meta)
        sudo "${BREW_PREFIX}/bin/apachectl" stop 2>/dev/null
        brew services stop "$(brew_active_php)" 2>/dev/null

        # Unlink any currently-linked PHP formula (meta or versioned), then
        # install + link the target — stream live so the user sees progress;
        # $? captures brew's real exit status so a failed install can never
        # be reported as a successful switch.
        for f in "${php_names[@]}" php; do
            brew unlink "$f" 2>/dev/null || true
        done
        HOMEBREW_NO_AUTO_UPDATE=1 brew install "$target" 2>&1
        local install_status=$?
        if [[ $install_status -ne 0 ]]; then
            print_err "Failed to install ${target} (brew install exited ${install_status}) — nothing was switched"
            printf "\n"
            read -r -p "Press Enter to return to the dashboard..."
            return
        fi
        HOMEBREW_NO_AUTO_UPDATE=1 brew link --overwrite --force "$target" 2>&1

        # Re-apply Apache config (PHP module path may have changed)
        BREW_PREFIX=$(brew --prefix)
        detect_all
        configure_apache
        configure_php

        # Start services (the NEW php service = the target formula)
        brew services start "$target" 2>/dev/null
        sudo "${BREW_PREFIX}/bin/apachectl" restart 2>/dev/null

        detect_all
        save_config "$BASE_DIR" "$APACHE_VERSION" "$MARIADB_VERSION" "$PHP_VERSION" "$PHPMYADMIN_VERSION"

        print_ok "PHP switched to ${PHP_VERSION}"
    fi

    printf "\n"
    read -r -p "Press Enter to return to the dashboard..."
}

# ---- Restore on Reinstall -----------------------------------
check_restore_data() {
    if [[ -d "$DATA_BACKUP_DIR" ]] && [[ "$(ls -A "$DATA_BACKUP_DIR" 2>/dev/null)" ]]; then
        printf "\n"
        printf "${CYAN}Found database backup from a previous install: %s${RESET}\n" "$DATA_BACKUP_DIR"
        printf "${BOLD}Restore previous databases? [Y/n]:${RESET} "
        read -r restore

        if [[ "$restore" != "n" && "$restore" != "N" && "$restore" != "no" && "$restore" != "No" ]]; then
            # Stop MariaDB, replace data dir, start
            if [[ $USE_APT == 1 ]]; then
                sudo systemctl stop mariadb 2>/dev/null
                sleep 1
                local mariadb_data="/var/lib/mysql"
                sudo rm -rf "$mariadb_data" 2>/dev/null || true
                sudo cp -r "$DATA_BACKUP_DIR" "$mariadb_data"
                sudo rm -rf "$DATA_BACKUP_DIR" 2>/dev/null || true
                sudo chown -R mysql:mysql "$mariadb_data" 2>/dev/null || true
                sudo systemctl start mariadb 2>/dev/null
            elif [[ $USE_PORTS == 1 ]]; then
                sudo "${PORT_PREFIX}/bin/port" unload "${MARIADB_PORT}-server" 2>/dev/null
                sleep 1
                local mariadb_data="${PORT_PREFIX}/var/db/${MARIADB_PORT}"
                sudo rm -rf "$mariadb_data" 2>/dev/null || true
                sudo cp -r "$DATA_BACKUP_DIR" "$mariadb_data"
                sudo rm -rf "$DATA_BACKUP_DIR" 2>/dev/null || true
                sudo chown -R _mysql:_mysql "$mariadb_data" 2>/dev/null || true
                sudo "${PORT_PREFIX}/bin/port" load "${MARIADB_PORT}-server" 2>/dev/null
            else
                brew services stop mariadb 2>/dev/null
                sleep 1
                local mariadb_data="${BREW_PREFIX}/var/mysql"
                rm -rf "$mariadb_data" 2>/dev/null || true
                cp -r "$DATA_BACKUP_DIR" "$mariadb_data"
                rm -rf "$DATA_BACKUP_DIR" 2>/dev/null || true
                brew services start mariadb 2>/dev/null
            fi
            sleep 2
            print_ok "Databases restored from backup"
        else
            print_info "Skipped database restore. Backup remains at: ${DATA_BACKUP_DIR}"
        fi
    fi
}

# ---- Offline Check ------------------------------------------
check_offline() {
    # Quick connectivity check
    if ! curl -s --connect-timeout 2 https://github.com &>/dev/null; then
        printf "${YELLOW}⚠ No internet connection detected.${RESET}\n"
        if [[ $USE_PORTS == 1 ]]; then
            printf "${YELLOW}MacPorts compiles everything from source — an online install is required.${RESET}\n"
        else
            printf "${YELLOW}Homebrew may use cached bottles if available.${RESET}\n"
        fi
        printf "\n"
        return 1
    fi

    # Check for cached bottles
    local cache_dir
    cache_dir=$(brew --cache 2>/dev/null)
    if [[ -d "$cache_dir" ]] && [[ "$(ls -A "$cache_dir" 2>/dev/null)" ]]; then
        local cache_count
        cache_count=$(find "$cache_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$cache_count" -gt 0 ]]; then
            printf "${CYAN}ℹ %s cached bottle(s) available for offline use${RESET}\n" "$cache_count"
            printf "\n"
        fi
    fi
    return 0
}

# ---- Backend Selection --------------------------------------
detect_backend() {
    [[ $USE_APT == 1 ]] && return          # Linux: apt, never touch
    if [[ "$ARCH" == "arm64" ]]; then      # Q1: Apple Silicon = brew only
        USE_PORTS=0
        return
    fi
    # Intel (x86_64) below
    local choice="${PHPPUP_BACKEND:-}"
    case "$choice" in
        port|macports) USE_PORTS=1; return ;;
        brew|homebrew) USE_PORTS=0; return ;;
    esac
    # No explicit choice → decide by availability/support
    # Natural routing first (without the brew-stack guard):
    local want_ports=0
    if [[ $OS_MAJOR -lt 11 ]]; then        # Catalina & older: brew cannot run modern formulas
        want_ports=1
    elif command -v brew &>/dev/null && [[ $OS_MAJOR -ge $BREW_MIN_OS_MAJOR ]]; then
        want_ports=0                        # supported brew present → keep (backward compat)
    elif [[ $MACPORTS == 1 ]]; then
        want_ports=1                        # brew absent/unsupported, ports present → prefer port
    elif [[ $OS_MAJOR -lt $BREW_MIN_OS_MAJOR ]]; then
        want_ports=1                        # brew unsupported on this OS → bootstrap MacPorts
    fi

    # N3: backward compat — a working Homebrew stack already installed wins over
    # the MacPorts route when the natural routing would have picked ports
    # (macOS 11–13 and older). MacPorts stays available via PHPPUP_BACKEND=port.
    if [[ $want_ports == 1 ]] && [[ -n "$BREW_PREFIX" ]] && { [[ -d "${BREW_PREFIX}/Cellar/httpd" ]] || [[ -d "${BREW_PREFIX}/Cellar/mariadb" ]] || [[ -d "${BREW_PREFIX}/Cellar/php" ]]; }; then
        USE_PORTS=0
        print_info "Homebrew stack detected — keeping Homebrew backend (MacPorts available via PHPPUP_BACKEND=port)"
        return
    fi

    USE_PORTS=$want_ports
}

# ---- Main Entry Point ---------------------------------------
main() {
    # Reconnect stdin to terminal (needed when piped via curl | bash)
    exec < /dev/tty

    # Homebrew detection (macOS and legacy Linux only)
    if [[ $USE_APT == 0 ]]; then
        check_brew_path
        if brew --version &>/dev/null; then
            HOMEBREW=1
            BREW_PREFIX=$(brew --prefix)
        fi
    fi

    # Backend selection (MacPorts vs Homebrew on Intel macOS)
    detect_backend
    if [[ $USE_PORTS == 1 ]]; then
        export PATH="${PORT_PREFIX}/bin:${PORT_PREFIX}/sbin:${PATH}"
    fi

    # Migrate pre-1.2.0 config, then load persisted state
    migrate_config
    load_config

    # Detect installed components
    detect_all

    # Main loop
    while true; do
        # Re-detect each render so the dashboard reflects the live system
        # (external changes — e.g. a fu switch in another terminal — can't
        # leave the Web Stack row stale)
        detect_all
        show_dashboard

        printf "${BOLD}==> Enter command:${RESET} "
        read -r command

        printf "\n"

        case "${command}" in
            [iI]|[iI]nstall)
                cmd_install
                # Re-detect for dashboard refresh
                if [[ $USE_APT == 0 ]]; then
                    check_brew_path
                    if brew --version &>/dev/null; then
                        HOMEBREW=1
                        BREW_PREFIX=$(brew --prefix)
                    fi
                fi
                # Re-check ports backend (a bootstrap may have added port)
                [[ $USE_PORTS == 1 ]] && { [[ -x /opt/local/bin/port ]] && MACPORTS=1; detect_backend; export PATH="/opt/local/bin:/opt/local/sbin:$PATH"; }
                detect_all
                ;;
            [uU]|[uU]pdate)
                cmd_update
                if [[ $USE_APT == 0 ]]; then
                    check_brew_path
                    if brew --version &>/dev/null; then
                        HOMEBREW=1
                        BREW_PREFIX=$(brew --prefix)
                    fi
                fi
                # Re-check ports backend (a bootstrap may have added port)
                [[ $USE_PORTS == 1 ]] && { [[ -x /opt/local/bin/port ]] && MACPORTS=1; detect_backend; export PATH="/opt/local/bin:/opt/local/sbin:$PATH"; }
                detect_all
                ;;
            [rR]|[rR]estart)
                if [[ $STACK == 0 ]]; then
                    print_err "Nothing to restart — stack is not installed."
                    printf "\n"
                    read -r -p "Press Enter to continue..."
                else
                    restart_services
                    print_ok "Waiting for services to stabilise..."
                    sleep 3
                fi
                ;;
            [sS]|[sS]tart|[sS]top)
                if [[ $STACK == 0 ]]; then
                    print_err "Nothing to start/stop — stack is not installed."
                    printf "\n"
                    read -r -p "Press Enter to continue..."
                else
                    toggle_services
                    detect_all
                    printf "\n"
                    read -r -p "Press Enter to continue..."
                fi
                ;;
            [dD]|[dD]elete)
                cmd_delete
                ;;
            fu|FU|fU|Fu)
                cmd_forced_update
                ;;
            [qQ]|[qQ]uit)
                printf "[${GREEN}  OK  ${RESET}] Goodbye!\n\n"
                return 0
                ;;
            *)
                print_err "Command not recognized."
                printf "\n"
                read -r -p "Press Enter to continue..."
                ;;
        esac
    done
}

# ---- Run ----------------------------------------------------
main
