#!/usr/bin/env bash
# ============================================================
#  phpup — Mac & Linux Web Stack Installer & Dashboard
#  Inspired by getphp.org (Mac, Linux)
#  GitHub: https://github.com/DaFa66/phpup
#  Author: Simon Field (aka - DaFa)
#  License: MIT
#  Date: 2026-07-19
#  Version: 1.0.0
# ============================================================

# ---- Config -------------------------------------------------
REMOTE_URL='https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.sh'
BASE_DIR="${HOME}/phpup"
DOC_ROOT="${BASE_DIR}/www"
LOGS_DIR="${BASE_DIR}/logs"
CONFIG_DIR="${HOME}/.config/phpup"
CONFIG_FILE="${CONFIG_DIR}/config.json"
DATA_BACKUP_DIR="${BASE_DIR}/data_backup"

# ---- Colour Constants ---------------------------------------
ESC='\033'
RED="${ESC}[31m"
GREEN="${ESC}[32m"
YELLOW="${ESC}[33m"
CYAN="${ESC}[36m"
BOLD="${ESC}[1m"
UNDERLINE="${ESC}[4m"
RESET="${ESC}[0m"

# ---- Platform Detection -------------------------------------
ARCH=$(uname -m)
OS_TYPE="${OSTYPE}"

if [[ "${OS_TYPE}" == "darwin"* ]]; then
    OS_NAME="macOS"
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
    else
        OS_VERSION="unknown"
        OS_DISTRO="Linux"
    fi
    SHELL_PROFILE="${HOME}/.bashrc"
    HTTPD_USER="www-data"
    USE_APT=1
else
    OS_NAME="Unknown"
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

json_get_versions() {
    local json="$1" component="$2"

    # Extract the versions block and find the component version
    echo "$json" | grep -o "\"${component}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/'
}

# ---- Config Persistence -------------------------------------
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        cat "$CONFIG_FILE"
    else
        echo ""
    fi
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

    cat > "$CONFIG_FILE" << EOF
{
  "install_path": "${install_path}",
  "installed_at": "${now}",
  "brew_prefix": "${BREW_PREFIX}",
  "architecture": "${ARCH}",
  "os": "${OS_NAME} ${OS_VERSION}",
  "versions": {
    "apache": "${apache_ver}",
    "mariadb": "${mariadb_ver}",
    "php": "${php_ver}",
    "phpmyadmin": "${phpmyadmin_ver}"
  }
}
EOF
}

clear_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
    fi
    if [[ -d "$CONFIG_DIR" ]]; then
        rmdir "$CONFIG_DIR" 2>/dev/null || true
    fi
}

# ---- Component Detection ------------------------------------
detect_apache() {
    if [[ $USE_APT == 1 ]]; then
        if dpkg -l apache2 &>/dev/null 2>&1 && dpkg -s apache2 &>/dev/null 2>&1; then
            APACHE=1
            APACHE_VERSION=$(dpkg -s apache2 2>/dev/null | grep '^Version:' | awk '{print $2}' | cut -d- -f1)
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
        if dpkg -l mariadb-server &>/dev/null 2>&1 && dpkg -s mariadb-server &>/dev/null 2>&1; then
            MARIADB=1
            MARIADB_VERSION=$(dpkg -s mariadb-server 2>/dev/null | grep '^Version:' | awk '{print $2}' | cut -d- -f1 | cut -d: -f2)
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

detect_php() {
    if [[ $USE_APT == 1 ]]; then
        if dpkg -l php &>/dev/null 2>&1 && dpkg -s php &>/dev/null 2>&1; then
            PHP=1
            PHP_VERSION=$(dpkg -s php 2>/dev/null | grep '^Version:' | awk '{print $2}' | cut -d- -f1 | cut -d: -f2)
        else
            PHP=0
            PHP_VERSION=""
        fi
    elif [[ -d "${BREW_PREFIX}/Cellar/php" ]]; then
        PHP=1
        PHP_VERSION=$(find "${BREW_PREFIX}/Cellar/php" -maxdepth 1 -mindepth 1 -exec basename {} \; 2>/dev/null | sort -V | tail -1)
    else
        PHP=0
        PHP_VERSION=""
    fi
}

detect_phpmyadmin() {
    if [[ $USE_APT == 1 ]]; then
        if dpkg -l phpmyadmin &>/dev/null 2>&1 && dpkg -s phpmyadmin &>/dev/null 2>&1; then
            PHPMYADMIN=1
            PHPMYADMIN_VERSION=$(dpkg -s phpmyadmin 2>/dev/null | grep '^Version:' | awk '{print $2}' | cut -d- -f1 | cut -d: -f2)
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
                systemctl is-active --quiet php*-fpm 2>/dev/null && return 0 || return 1
                ;;
            *) return 1 ;;
        esac
    else
        case "$svc" in
            apache|httpd)
                pgrep -x "httpd" &>/dev/null && return 0 || return 1
                ;;
            mariadb)
                pgrep -x "mariadbd" &>/dev/null && return 0 || return 1
                ;;
            php)
                pgrep -f "(^|/)php-fpm" &>/dev/null && return 0 || return 1
                ;;
            *) return 1 ;;
        esac
    fi
}

detect_all() {
    if [[ $USE_APT == 0 ]] && [[ $HOMEBREW == 0 ]]; then
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
            sudo apt update -qq && sudo apt install -y build-essential procps file git curl
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
            read -r
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

# ---- PATH Management ----------------------------------------
manage_path() {
    # On Linux/apt, binaries are already in standard system paths (/usr/bin)
    if [[ $USE_APT == 1 ]]; then
        print_ok "php and mysql available via system PATH"
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
    printf "│         ▲ ▲ ▲               │\n"
    printf "│         phpup               │\n"
    printf "└─────────────────────────────┘\n"
    printf "\n"
}

show_dashboard() {
    show_banner

    # Architecture line
    if [[ $USE_APT == 1 ]]; then
        printf "Architecture: ${CYAN}%s${RESET} | OS: ${CYAN}%s %s${RESET} | Package: ${CYAN}apt${RESET}\n" \
            "$ARCH" "$OS_NAME" "$OS_VERSION"
    else
        printf "Architecture: ${CYAN}%s${RESET} | OS: ${CYAN}%s %s${RESET} | Homebrew: ${CYAN}%s${RESET}\n" \
            "$ARCH" "$OS_NAME" "$OS_VERSION" "$BREW_PREFIX"
    fi
    printf "\n"

    # Stack Status
    printf "Your Web Stack:\n"
    printf "~~~~~~~~~~~~~~~\n"

    printf "Apache ${CYAN}------->${RESET} "
    if [[ $APACHE == 1 ]]; then
        printf "%s\n" "$APACHE_VERSION"
    else
        printf "${RED}Not installed${RESET}\n"
    fi

    printf "MariaDB ${CYAN}------>${RESET} "
    if [[ $MARIADB == 1 ]]; then
        printf "%s\n" "$MARIADB_VERSION"
    else
        printf "${RED}Not installed${RESET}\n"
    fi

    printf "PHP ${CYAN}---------->${RESET} "
    if [[ $PHP == 1 ]]; then
        printf "%s\n" "$PHP_VERSION"
    else
        printf "${RED}Not installed${RESET}\n"
    fi

    printf "phpMyAdmin ${CYAN}--->${RESET} "
    if [[ $PHPMYADMIN == 1 ]]; then
        printf "%s\n" "$PHPMYADMIN_VERSION"
    else
        printf "${RED}Not installed${RESET}\n"
    fi

    printf "\n"

    # Service Status
    printf "Service Status:\n"
    printf "~~~~~~~~~~~~~~~\n"

    printf "Apache ${CYAN}------->${RESET} "
    if [[ $APACHE == 1 ]]; then
        is_service_running apache && printf "Running\n" || printf "Stopped\n"
    else
        printf "${RED}Not available${RESET}\n"
    fi

    printf "MariaDB ${CYAN}------>${RESET} "
    if [[ $MARIADB == 1 ]]; then
        is_service_running mariadb && printf "Running\n" || printf "Stopped\n"
    else
        printf "${RED}Not available${RESET}\n"
    fi

    printf "PHP-FPM ${CYAN}------>${RESET} "
    if [[ $PHP == 1 ]]; then
        is_service_running php && printf "Running\n" || printf "Stopped\n"
    else
        printf "${RED}Not available${RESET}\n"
    fi

    printf "\n"

    # Quick Info (only when stack is complete)
    if [[ $STACK == 1 ]]; then
        printf "Quick Info:\n"
        printf "~~~~~~~~~~~\n"
        printf "${CYAN}Where to put website files?${RESET} %s\n" "$DOC_ROOT"
        printf "${CYAN}How to test your PHP setup?${RESET} http://localhost/phpinfo.php\n"
        printf "${CYAN}Where to access phpMyAdmin?${RESET} http://localhost/phpmyadmin\n"
        printf "${CYAN}How to log into phpMyAdmin?${RESET} Username: root | Password: [blank]\n"
        printf "\n"
    fi

    # Commands
    printf "Stack Commands:\n"
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
        [[ $PHP == 1 ]] && sudo systemctl start php*-fpm 2>/dev/null
    else
        [[ $APACHE == 1 ]] && brew services start httpd 2>/dev/null
        [[ $MARIADB == 1 ]] && brew services start mariadb 2>/dev/null
        [[ $PHP == 1 ]] && brew services start php 2>/dev/null
    fi
    sleep 2
    print_ok "Services started"
}

stop_services() {
    print_info "Stopping services..."
    if [[ $USE_APT == 1 ]]; then
        [[ $APACHE == 1 ]] && sudo systemctl stop apache2 2>/dev/null
        [[ $MARIADB == 1 ]] && sudo systemctl stop mariadb 2>/dev/null
        [[ $PHP == 1 ]] && sudo systemctl stop php*-fpm 2>/dev/null
    else
        [[ $APACHE == 1 ]] && brew services stop httpd 2>/dev/null
        [[ $MARIADB == 1 ]] && brew services stop mariadb 2>/dev/null
        [[ $PHP == 1 ]] && brew services stop php 2>/dev/null
    fi
    sleep 2
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

    # Port 80
    sed -i.bak "s/Listen 8080/Listen 80/" "$conf"
    print_ok "Enabled port 80"

    # ServerName
    sed -i.bak "s/#ServerName www.example.com:8080/ServerName localhost:80/g" "$conf"
    print_ok "Set ServerName to localhost:80"

    # DocumentRoot
    sed -i.bak "s@${BREW_PREFIX}/var/www@$DOC_ROOT@g" "$conf"
    print_ok "Set DocumentRoot to ${DOC_ROOT}"

    # Log files
    sed -i.bak "s@${BREW_PREFIX}/var/log/httpd/error_log@${LOGS_DIR}/apache_error.log@g" "$conf"
    sed -i.bak "s@${BREW_PREFIX}/var/log/httpd/access_log@${LOGS_DIR}/apache_access.log@g" "$conf"
    print_ok "Routed logs to ${LOGS_DIR}"

    # mod_rewrite
    sed -i.bak "s@#LoadModule rewrite_module lib/httpd/modules/mod_rewrite.so@LoadModule rewrite_module lib/httpd/modules/mod_rewrite.so@g" "$conf"
    sed -i.bak "s/AllowOverride None/AllowOverride All/g" "$conf"
    print_ok "Enabled mod_rewrite"

    # DirectoryIndex
    sed -i.bak "s/DirectoryIndex index.html/DirectoryIndex index.php index.html/" "$conf"
    print_ok "Added index.php to DirectoryIndex"

    # Linux-specific: change user/group to www-data
    if [[ "${OS_TYPE}" == "linux-gnu"* ]]; then
        sed -i.bak "s/User _www/User www-data/" "$conf"
        sed -i.bak "s/Group _www/Group www-data/" "$conf"
        print_ok "Set Apache user/group to www-data (Linux)"
    fi

    # PHP module
    local php_module_path="${BREW_PREFIX}/opt/php/lib/httpd/modules/libphp.so"
    if ! grep -q "LoadModule php_module" "$conf"; then
        printf "\nLoadModule php_module %s\n" "$php_module_path" >> "$conf"
    fi

    if ! grep -q "<FilesMatch \\\.php\$>" "$conf"; then
        cat >> "$conf" << 'PHPFILESMATCH'

<FilesMatch \.php$>
    SetHandler application/x-httpd-php
</FilesMatch>
PHPFILESMATCH
    fi
    print_ok "Enabled php_module"

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

    # Clean up sed backup files
    rm -f "${conf}.bak"
}

# ---- Apache Configuration (apt) ------------------------------
configure_apache_apt() {
    local site_conf="/etc/apache2/sites-available/000-default.conf"
    local main_conf="/etc/apache2/apache2.conf"

    print_info "Configuring Apache (apt)..."

    # Enable mod_rewrite
    sudo a2enmod rewrite 2>/dev/null
    print_ok "Enabled mod_rewrite"

    # Configure 000-default.conf — the default site
    if [[ -f "$site_conf" ]]; then
        if [[ ! -f "${site_conf}.phpup.bak" ]]; then
            sudo cp "$site_conf" "${site_conf}.phpup.bak"
        fi

        # DocumentRoot
        sudo sed -i "s@DocumentRoot /var/www/html@DocumentRoot ${DOC_ROOT}@" "$site_conf"
        print_ok "Set DocumentRoot to ${DOC_ROOT}"

        # AllowOverride All for .htaccess
        sudo sed -i "s/AllowOverride None/AllowOverride All/g" "$site_conf"
        print_ok "Set AllowOverride All"

        # DirectoryIndex
        sudo sed -i "s/DirectoryIndex index.html/DirectoryIndex index.php index.html/" "$site_conf"
        print_ok "Added index.php to DirectoryIndex"

        # Log files — redirect to phpup logs
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

    # Ensure www directory is accessible (Apache runs as www-data)
    sudo chown -R www-data:www-data "$DOC_ROOT" 2>/dev/null || true
    sudo chmod 755 "$DOC_ROOT" 2>/dev/null || true
    print_ok "Set ownership of ${DOC_ROOT} to www-data"

    # Reload Apache to apply changes
    sudo systemctl reload apache2 2>/dev/null || sudo systemctl start apache2 2>/dev/null
    print_ok "Apache configured"
}

# ---- PHP Configuration --------------------------------------
configure_php() {
    if [[ $USE_APT == 1 ]]; then
        configure_php_apt
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

    # Backup
    if [[ ! -f "${php_ini}.phpup.bak" ]]; then
        cp "$php_ini" "${php_ini}.phpup.bak"
    fi

    print_info "Configuring PHP..."

    # Enable common extensions
    local extensions=("curl" "fileinfo" "gd" "intl" "mbstring" "mysqli" "openssl" "pdo_mysql" "pdo_sqlite" "sodium" "sqlite3")
    for ext in "${extensions[@]}"; do
        # Uncomment the extension line if it exists commented out
        sed -i.bak "s/^; *extension=${ext}/extension=${ext}/" "$php_ini" 2>/dev/null || true
    done
    print_ok "Enabled PHP extensions"

    # Display errors
    sed -i.bak "s/^display_errors = Off/display_errors = On/" "$php_ini" 2>/dev/null || true
    sed -i.bak "s/^display_errors = Off/display_errors = On/" "$php_ini" 2>/dev/null || true
    print_ok "Enabled display_errors"

    # Error log
    local error_log_line="error_log = ${LOGS_DIR}/php_errors.log"
    if ! grep -q "^error_log" "$php_ini" 2>/dev/null; then
        echo "$error_log_line" >> "$php_ini"
    else
        sed -i.bak "s@^error_log.*@${error_log_line}@" "$php_ini"
    fi
    print_ok "Set PHP error log to ${LOGS_DIR}/php_errors.log"

    # OPCache
    if grep -q "^;*opcache.enable=" "$php_ini" 2>/dev/null; then
        sed -i.bak "s/^;*opcache.enable=.*/opcache.enable=1/" "$php_ini"
        sed -i.bak "s/^;*opcache.memory_consumption=.*/opcache.memory_consumption=256/" "$php_ini"
        sed -i.bak "s/^;*opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=16/" "$php_ini"
        sed -i.bak "s/^;*opcache.max_accelerated_files=.*/opcache.max_accelerated_files=20000/" "$php_ini"
        print_ok "Configured OPCache (256MB, JIT-ready)"
    fi

    rm -f "${php_ini}.bak"
}

# ---- PHP Configuration (apt) ---------------------------------
configure_php_apt() {
    print_info "Configuring PHP (apt)..."

    # Find the Apache PHP ini
    local php_ver
    php_ver=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null)
    local php_ini="/etc/php/${php_ver}/apache2/php.ini"

    if [[ ! -f "$php_ini" ]]; then
        # Fallback: try CLI ini
        php_ini=$(php -r 'echo php_ini_loaded_file();' 2>/dev/null)
    fi

    if [[ ! -f "$php_ini" ]]; then
        print_warn "Could not locate php.ini — skipping PHP configuration"
        return
    fi

    if [[ ! -f "${php_ini}.phpup.bak" ]]; then
        sudo cp "$php_ini" "${php_ini}.phpup.bak"
    fi

    # Display errors
    sudo sed -i "s/^display_errors = Off/display_errors = On/" "$php_ini" 2>/dev/null || true
    print_ok "Enabled display_errors"

    # Error log
    if ! grep -q "^error_log" "$php_ini" 2>/dev/null; then
        echo "error_log = ${LOGS_DIR}/php_errors.log" | sudo tee -a "$php_ini" > /dev/null
    else
        sudo sed -i "s@^error_log.*@error_log = ${LOGS_DIR}/php_errors.log@" "$php_ini"
    fi
    print_ok "Set PHP error log to ${LOGS_DIR}/php_errors.log"

    # OPCache
    if grep -q "^;*opcache.enable=" "$php_ini" 2>/dev/null; then
        sudo sed -i "s/^;*opcache.enable=.*/opcache.enable=1/" "$php_ini"
        sudo sed -i "s/^;*opcache.memory_consumption=.*/opcache.memory_consumption=256/" "$php_ini"
        sudo sed -i "s/^;*opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=16/" "$php_ini"
        sudo sed -i "s/^;*opcache.max_accelerated_files=.*/opcache.max_accelerated_files=20000/" "$php_ini"
        print_ok "Configured OPCache (256MB, JIT-ready)"
    fi

    # Extensions should already be enabled via apt package dependencies
    print_ok "PHP configured"
}

# ---- MariaDB Configuration ----------------------------------
configure_mariadb() {
    if [[ $USE_APT == 1 ]]; then
        configure_mariadb_apt
        return
    fi

    print_info "Configuring MariaDB..."

    # Start MariaDB to initialise data directory
    brew services start mariadb 2>/dev/null
    sleep 3

    # Set blank root password (Homebrew MariaDB often has no password by default)
    if mysql -u root -e "SELECT 1" &>/dev/null 2>&1; then
        print_ok "MariaDB root access confirmed (no password)"
    else
        # Try to set blank password via safe mode
        brew services stop mariadb 2>/dev/null
        sleep 1
        mysqld_safe --skip-grant-tables &
        sleep 3
        mysql -u root -e "FLUSH PRIVILEGES; ALTER USER 'root'@'localhost' IDENTIFIED BY ''; FLUSH PRIVILEGES;" 2>/dev/null || true
        killall mysqld_safe 2>/dev/null || true
        sleep 1
        brew services start mariadb 2>/dev/null
        sleep 2
        print_ok "MariaDB root password set to blank"
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

    # Set blank root password via Unix socket (default on Debian/Ubuntu)
    if sudo mysql -u root -e "SELECT 1" &>/dev/null 2>&1; then
        # Set blank password for TCP connections
        sudo mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY ''; FLUSH PRIVILEGES;" 2>/dev/null || true
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

# ---- phpMyAdmin Configuration -------------------------------
configure_phpmyadmin() {
    if [[ $USE_APT == 1 ]]; then
        configure_phpmyadmin_apt
        return
    fi

    local pma_conf="${BREW_PREFIX}/etc/phpmyadmin.config.inc.php"

    if [[ ! -f "$pma_conf" ]]; then
        print_warn "phpMyAdmin config not found — skipping"
        return
    fi

    # Backup
    if [[ ! -f "${pma_conf}.phpup.bak" ]]; then
        cp "$pma_conf" "${pma_conf}.phpup.bak"
    fi

    print_info "Configuring phpMyAdmin..."

    # Blowfish secret
    sed -i.bak "s/\$cfg\['blowfish_secret'\] = '';/\$cfg\['blowfish_secret'\] = '12345678901234567890123456789012';/" "$pma_conf"
    print_ok "Set blowfish secret"

    # Allow passwordless root login
    sed -i.bak "s/\$cfg\['Servers'\]\[\$i\]\['AllowNoPassword'\] = false;/\$cfg\['Servers'\]\[\$i\]\['AllowNoPassword'\] = true;/" "$pma_conf"
    print_ok "Enabled passwordless root login"

    rm -f "${pma_conf}.bak"
}

# ---- phpMyAdmin Configuration (apt) --------------------------
configure_phpmyadmin_apt() {
    local pma_conf="/etc/phpmyadmin/config.inc.php"

    if [[ ! -f "$pma_conf" ]]; then
        print_warn "phpMyAdmin config not found — skipping"
        return
    fi

    if [[ ! -f "${pma_conf}.phpup.bak" ]]; then
        sudo cp "$pma_conf" "${pma_conf}.phpup.bak"
    fi

    print_info "Configuring phpMyAdmin (apt)..."

    # Blowfish secret
    sudo sed -i "s/\\$cfg\\['blowfish_secret'\\] = '';/\\$cfg\\['blowfish_secret'\\] = '12345678901234567890123456789012';/" "$pma_conf"
    print_ok "Set blowfish secret"

    # Allow passwordless root login
    sudo sed -i "s/\\$cfg\\['Servers'\\]\\[\\$i\\]\\['AllowNoPassword'\\] = false;/\\$cfg\\['Servers'\\]\\[\\$i\\]\\['AllowNoPassword'\\] = true;/" "$pma_conf"
    print_ok "Enabled passwordless root login"

    print_ok "phpMyAdmin configured"
}

# ---- Install Command ----------------------------------------
cmd_install() {
    if [[ $STACK == 1 ]]; then
        print_err "Stack is already installed. Use U to update or D to delete first."
        printf "\n"
        read -r -p "Press Enter to continue..."
        return
    fi

    printf "\n${BOLD}phpup — Install Web Stack${RESET}\n\n"

    # Prerequisites
    check_prerequisites

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
        sudo apt update -qq
        [[ $APACHE == 0 ]] && sudo apt install -y apache2 && APACHE=1
        [[ $MARIADB == 0 ]] && sudo apt install -y mariadb-server && MARIADB=1
        [[ $PHP == 0 ]] && sudo apt install -y php php-curl php-fileinfo php-gd php-intl php-mbstring php-mysql php-sqlite3 php-sodium libapache2-mod-php && PHP=1
        [[ $PHPMYADMIN == 0 ]] && sudo apt install -y phpmyadmin && PHPMYADMIN=1

        detect_all
    else
        # Install Homebrew
        install_homebrew

        printf "\n"
        print_info "Installing packages via Homebrew..."
        printf "\n"

        [[ $APACHE == 0 ]] && brew install httpd && APACHE=1
        [[ $MARIADB == 0 ]] && brew install mariadb && MARIADB=1
        [[ $PHP == 0 ]] && brew install php && PHP=1
        [[ $PHPMYADMIN == 0 ]] && brew install phpmyadmin && PHPMYADMIN=1

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

    # Configure components
    configure_apache
    configure_php
    configure_mariadb
    configure_phpmyadmin

    # Check for database backup from previous install
    check_restore_data

    # Create phpinfo.php
    printf "<?php phpinfo(); ?>\n" > "${DOC_ROOT}/phpinfo.php"
    print_ok "Created: ${DOC_ROOT}/phpinfo.php"

    # PATH management
    manage_path

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
        sudo apt update -qq
        local outdated
        outdated=$(apt list --upgradable 2>/dev/null | grep -E '^(apache2|mariadb-server|php|phpmyadmin)/' || true)

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
        sudo apt upgrade -y apache2 mariadb-server php php-curl php-fileinfo php-gd php-intl php-mbstring php-mysql php-sqlite3 php-sodium libapache2-mod-php phpmyadmin
        detect_all
        configure_apache
        configure_php
        configure_phpmyadmin
        start_services
    else
        brew update
        local outdated
        outdated=$(brew outdated --formula httpd mariadb php phpmyadmin 2>/dev/null)

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
        print_info "Upgrading packages via Homebrew..."
        brew upgrade httpd mariadb php phpmyadmin
        detect_all
        configure_apache
        configure_php
        configure_phpmyadmin
        start_services
    fi

    # Save new versions
    detect_all
    save_config "$BASE_DIR" "$APACHE_VERSION" "$MARIADB_VERSION" "$PHP_VERSION" "$PHPMYADMIN_VERSION"

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
    printf "${RED}- Services, config files, and logs.${RESET}\n\n"
    printf "${GREEN}THIS WILL NOT BE DELETED:${RESET}\n"
    printf "${GREEN}- Your website files in %s${RESET}\n" "$DOC_ROOT"
    printf "${GREEN}- Your MariaDB databases (backed up to %s)${RESET}\n" "$DATA_BACKUP_DIR"
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
    else
        mariadb_data="${BREW_PREFIX}/var/mysql"
    fi

    if [[ -d "$mariadb_data" ]] && [[ "$(ls -A "$mariadb_data" 2>/dev/null)" ]]; then
        # Handle existing backup
        if [[ -d "$DATA_BACKUP_DIR" ]]; then
            local timestamp
            timestamp=$(date "+%Y%m%d_%H%M%S")
            local archived_backup="${BASE_DIR}/data_backup_${timestamp}"
            mv "$DATA_BACKUP_DIR" "$archived_backup"
            print_ok "Archived existing backup to ${archived_backup}"
        fi
        sudo cp -r "$mariadb_data" "$DATA_BACKUP_DIR" 2>/dev/null || cp -r "$mariadb_data" "$DATA_BACKUP_DIR"
        print_ok "Backed up MariaDB data to ${DATA_BACKUP_DIR}"
    else
        print_info "No MariaDB data to back up"
    fi

    # Uninstall packages
    if [[ $USE_APT == 1 ]]; then
        sudo apt remove -y apache2 mariadb-server php php-curl php-fileinfo php-gd php-intl php-mbstring php-mysql php-sqlite3 php-sodium libapache2-mod-php phpmyadmin 2>/dev/null || true
        sudo apt autoremove -y 2>/dev/null || true
    else
        brew uninstall httpd 2>/dev/null || true
        brew uninstall mariadb 2>/dev/null || true
        brew uninstall php 2>/dev/null || true
        brew uninstall phpmyadmin 2>/dev/null || true
        brew autoremove 2>/dev/null || true
        brew cleanup 2>/dev/null || true
    fi
    print_ok "Uninstalled packages"

    # Remove remaining config files
    rm -rf "$LOGS_DIR" 2>/dev/null || true
    print_ok "Removed config files and logs"

    # Clear config
    clear_config
    print_ok "Cleared phpup config"

    # Reset detection
    APACHE=0; MARIADB=0; PHP=0; PHPMYADMIN=0; STACK=0

    printf "\n"
    print_ok "DELETION COMPLETE!"
    printf "${GREEN}Your website files are preserved in: %s${RESET}\n" "$DOC_ROOT"
    printf "${GREEN}Your databases are preserved in:   %s${RESET}\n" "$DATA_BACKUP_DIR"
    printf "\n"
    read -r -p "Press Enter to continue..."
}

# ---- Forced Update / Version Switching ----------------------
cmd_forced_update() {
    if [[ $STACK == 0 ]]; then
        print_err "Nothing to switch — stack is not installed."
        printf "\n"
        read -r -p "Press Enter to continue..."
        return
    fi

    printf "\n${BOLD}phpup — Forced Update / Version Switch${RESET}\n\n"

    # Show installed versions
    printf "${CYAN}Currently installed:${RESET}\n"
    printf "  Apache:     %s\n" "${APACHE_VERSION:-unknown}"
    printf "  MariaDB:    %s\n" "${MARIADB_VERSION:-unknown}"
    printf "  PHP:        %s\n" "${PHP_VERSION:-unknown}"
    printf "  phpMyAdmin: %s\n" "${PHPMYADMIN_VERSION:-unknown}"
    printf "\n"

    # Show available PHP versions via Homebrew
    printf "${CYAN}Available PHP versions:${RESET}\n"
    local php_versions
    php_versions=$(brew search '/php@/' 2>/dev/null | grep -E 'php@[0-9]+\.[0-9]+' | sort -V)
    if [[ -z "$php_versions" ]]; then
        print_warn "No versioned PHP formulae found"
    else
        printf "%s\n" "$php_versions"
    fi
    printf "\n"

    printf "${BOLD}Enter PHP version to switch to (e.g. 8.3) or press Enter to skip:${RESET} "
    read -r php_ver

    if [[ -n "$php_ver" ]]; then
        local formula="php@${php_ver}"
        if brew info "$formula" &>/dev/null; then
            printf "\n"
            print_info "Switching PHP to ${formula}..."

            # Stop services
            brew services stop httpd 2>/dev/null
            brew services stop php 2>/dev/null

            # Unlink current, install and link target
            brew unlink php 2>/dev/null || true
            brew install "$formula" 2>/dev/null
            brew link --overwrite --force "$formula" 2>/dev/null

            # Re-apply Apache config (PHP module path may have changed)
            BREW_PREFIX=$(brew --prefix)
            detect_all
            configure_apache
            configure_php

            # Start services
            brew services start php 2>/dev/null
            brew services start httpd 2>/dev/null

            detect_all
            save_config "$BASE_DIR" "$APACHE_VERSION" "$MARIADB_VERSION" "$PHP_VERSION" "$PHPMYADMIN_VERSION"

            print_ok "PHP switched to ${PHP_VERSION}"
        else
            print_err "Formula '${formula}' not found in Homebrew"
        fi
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
        printf "${YELLOW}Homebrew may use cached bottles if available.${RESET}\n"
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

# ---- Main Entry Point ---------------------------------------
main() {
    # Homebrew detection (macOS and legacy Linux only)
    if [[ $USE_APT == 0 ]]; then
        check_brew_path
        if brew --version &>/dev/null; then
            HOMEBREW=1
            BREW_PREFIX=$(brew --prefix)
        fi
    fi

    # Detect installed components
    detect_all

    # Show offline/cache info (brew only)
    if [[ $USE_APT == 0 ]] && [[ $HOMEBREW == 1 ]]; then
        check_offline
    fi

    # Main loop
    while true; do
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
                    printf "\n"
                    read -r -p "Press Enter to continue..."
                fi
                ;;
            [dD]|[dD]elete)
                cmd_delete
                ;;
            fu|FU|fU|Fu)
                if [[ $USE_APT == 1 ]]; then
                    print_err "Forced update (version switching) is not available with apt. Use U to update."
                    printf "\n"
                    read -r -p "Press Enter to continue..."
                else
                    cmd_forced_update
                fi
                ;;
            [qQ]|[qQ]uit)
                printf "[${GREEN}  OK  ${RESET}] Goodbye!\n\n"
                exit 0
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
