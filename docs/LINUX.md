# phpup on Linux

> Native apt-based web stack for Debian and Ubuntu (x86_64 + arm64).
> Apache, PHP, MariaDB, and phpMyAdmin — installed, configured, and ready to use.

## Prerequisites

- **Debian or Ubuntu** (including WSL2)
- **sudo access** — phpup installs system packages and writes to `/etc`
- **curl** — installed automatically if missing

## Quick Start

```bash
if ! command -v curl &> /dev/null; then sudo apt install -y curl; fi && source <(curl -fsSL https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.sh)
```

The script auto-detects Linux and uses native `apt` package management. After launching, press **I** to install. On subsequent runs the script remembers your setup and goes straight to the dashboard.

## Architecture

phpup on Linux uses **apt** — the system package manager. No Homebrew, no third-party package managers. The script auto-detects the platform at runtime and installs everything through `apt`:

| Backend | Package manager | Platforms |
|---------|:--------------:|-----------|
| apt | `apt-get` / `dpkg` | Debian, Ubuntu (native + WSL2) |

> **Why apt, not Homebrew on Linux?** Homebrew on Linux ARM64 has poor bottle coverage. Homebrew on Linux is unofficial and fragile for production-grade services. apt is the native package manager with full ARM64 support and reliable package availability.

## What Gets Installed

| Component   | apt Package(s)                                    | Config Location                        |
| ----------- | ------------------------------------------------- | -------------------------------------- |
| **Apache**  | `apache2`                                         | `/etc/apache2/sites-available/000-default.conf` |
| **MariaDB** | `mariadb-server` (latest via [mariadb.org repo](https://mariadb.org/download/)) | `/etc/mysql/mariadb.conf.d/50-server.cnf` |
| **PHP**     | `php8.x-*` versioned packages (via [ondrej/php repo](https://deb.sury.org/)) | `/etc/php/{version}/apache2/php.ini` |
| **phpMyAdmin** | Tarball from [phpmyadmin.net](https://www.phpmyadmin.net/) | `/etc/phpmyadmin/conf.d/phpup.php` |

phpup adds two external apt repositories for the latest versions:
- **[ondrej/php](https://deb.sury.org/)** — provides PHP 8.2 through latest stable (currently 8.5), kept current by the repo maintainer
- **[MariaDB.org](https://mariadb.org/download/)** — provides the latest stable MariaDB series instead of the distro default

Both repos support `x86_64` and `arm64`.

## Directory Layout

phpup uses standard Linux system paths:

```
~/phpup/
├── www/             # ← Your websites go here
│   └── phpinfo.php  # (auto-created test file)
├── logs/            # Apache access/error logs
└── data_backup/     # (created on delete — MariaDB databases preserved)

System paths (managed by apt):
/etc/apache2/                        # Apache configuration
/etc/php/{version}/apache2/php.ini   # PHP configuration
/etc/mysql/mariadb.conf.d/           # MariaDB configuration
/etc/phpmyadmin/conf.d/              # phpMyAdmin overrides
/usr/share/phpmyadmin/               # phpMyAdmin web files
/var/lib/mysql/                      # MariaDB data directory
~/.config/phpup/config.json          # phpup persistent config
```

## What the Installer Configures

### Apache

- Port 80, bound as root via `systemctl`
- DocumentRoot set to `~/phpup/www` with `<Directory>` grant
- Home directory made world-executable so `www-data` can traverse to `~/phpup/www`
- `mod_rewrite` enabled with `AllowOverride All` — `.htaccess` rewrites work out of the box
- PHP module loaded via `libapache2-mod-php`
- phpMyAdmin alias at `/phpmyadmin`

### PHP

- **Extensions:** `curl`, `fileinfo`, `gd`, `intl`, `mbstring`, `mysql`, `sqlite3`, `xml`, `zip`, `bcmath`, `bz2` — installed as separate apt packages, auto-enabled
- `display_errors = On`
- Upload limits: 50 MB files, 300s timeout (suitable for phpMyAdmin imports)
- OPCache enabled with JIT
- `session.gc_maxlifetime = 14400` (4 hours, matches phpMyAdmin session timeout)
- PHP runs as an **Apache module** (`mod_php`), not PHP-FPM

### MariaDB

- Data directory initialized with blank root password
- Auth switched from `unix_socket` to `mysql_native_password` so phpMyAdmin can connect over TCP
- Error log configured with `[mysqld]` group header

### phpMyAdmin

- Installed from the official tarball (not the apt package, to avoid `dbconfig-common` complications)
- conf.d override at `/etc/phpmyadmin/conf.d/phpup.php` — survives delete
- `AllowNoPassword` enabled for root login
- Version check disabled, 4-hour session timeout
- Template cache directory configured
- Configuration storage database (`pma`) with bookmark, history, and designer support

## PHP Version Switching (`fu`)

The hidden **`fu`** command switches between PHP versions using the [ondrej/php repository](https://deb.sury.org/). Select a version from the numbered list (8.2 → latest stable). The previous PHP stays installed — switching back is another `fu`.

`fu` handles:
- Installing the new versioned packages
- Switching the Apache module (`a2dismod` old → `a2enmod` new)
- Switching the CLI default (`update-alternatives --set php`)
- Re-applying PHP configuration

## Service Management

phpup uses `systemctl` for service management:

| Dashboard Key | Action |
| ------------- | ------ |
| **R** | Restart Apache + MariaDB (`systemctl restart`) |
| **S** | Toggle — stops if running, starts if stopped |

## Safe Delete

Pressing **D**:
- Backs up MariaDB data to `~/phpup/data_backup/`
- Removes packages (`apt remove`) — configs in `/etc` are **preserved** by apt
- Purges runtime state (`/var/lib/apache2`, `/var/lib/php`, `/var/lib/phpmyadmin`, `/var/lib/mysql`)
- Keeps `~/phpup/www/` and `~/phpup/data_backup/` untouched

On reinstall, configs in `/etc` are re-applied automatically. MariaDB data is restored from `data_backup/`.

## After Installation

| Question                    | Answer                                 |
| --------------------------- | -------------------------------------- |
| Where to put website files? | `~/phpup/www`                          |
| Test your PHP setup?        | http://localhost/phpinfo.php           |
| Access phpMyAdmin?          | http://localhost/phpmyadmin            |
| Login to phpMyAdmin?        | Username: `root` / Password: _(blank)_ |
| PHP from terminal?          | `php` available via update-alternatives |

## WSL2

Works out of the box on Ubuntu and Debian under WSL2. The script:

- Auto-configures Apache directory permissions for the home directory (`chmod o+x $HOME`)
- Adds the `<Directory>` grant required when DocumentRoot is outside `/var/www`
- Uses the same apt packages as native Linux

**Finding your website:** Visit `http://localhost` in your Windows browser. WSL2 forwards `localhost` automatically.

## ARM (Raspberry Pi, ARM64 servers)

Both the ondrej/php and MariaDB.org repositories provide `arm64` packages. phpup detects the architecture via `uname -m` (display only — apt selects the correct architecture automatically from the same repo URLs).

ARM testing is ongoing — feedback welcome.

## Troubleshooting

**Apache returns 403 Forbidden:**
The home directory may not be world-executable. Run: `chmod o+x $HOME`

**phpMyAdmin login fails with "Access denied for user 'phpmyadmin'":**
The `dbconfig-common` package may have written credentials without creating the user. The latest phpup creates the control user explicitly — re-run the install (press **I**).

**MariaDB fails to start after delete + reinstall:**
The data directory may have stale files. phpup purges `/var/lib/mysql` on delete and re-initialises on install. If you manually deleted without phpup, run:
```bash
sudo rm -rf /var/lib/mysql/*
mariadb-install-db --user=mysql --datadir=/var/lib/mysql
sudo systemctl start mariadb
```

**PHP version shown in dashboard doesn't match `phpinfo()`:**
The Apache module may not have switched. Run `fu` again — it handles both the CLI alternative (`update-alternatives`) and the Apache module (`a2enmod`).

**"command not found: curl" on first run:**
The Quick Start command already handles this (`sudo apt install -y curl`). If you downloaded the script directly, install curl first: `sudo apt install -y curl`

## Support

Open an [issue](https://github.com/DaFa66/phpup/issues) or submit a [pull request](https://github.com/DaFa66/phpup/pulls).
