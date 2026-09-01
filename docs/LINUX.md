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

PHP is served through **Apache + PHP-FPM** (`mod_proxy_fcgi` → `phpX.Y-fpm`), not the legacy `mod_php` Apache module. phpup migrates existing `mod_php` stacks automatically on the next version switch.

> **Why apt, not Homebrew on Linux?** Homebrew on Linux ARM64 has poor bottle coverage. Homebrew on Linux is unofficial and fragile for production-grade services. apt is the native package manager with full ARM64 support and reliable package availability.

## What Gets Installed

| Component   | apt Package(s)                                    | Config Location                        |
| ----------- | ------------------------------------------------- | -------------------------------------- |
| **Apache**  | `apache2`                                         | `/etc/apache2/sites-available/000-default.conf` |
| **MariaDB** | `mariadb-server` (latest via [mariadb.org repo](https://mariadb.org/download/)) | `/etc/mysql/mariadb.conf.d/50-server.cnf` |
| **PHP**     | `php8.x-cli` + `php8.x-fpm` versioned packages (via [ondrej/php repo](https://deb.sury.org/)) | `/etc/php/{version}/fpm/php.ini` |
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
/etc/apache2/conf-available/phpup-php-fpm.conf   # Apache ↔ FPM wiring
/etc/php/{version}/fpm/php.ini      # PHP configuration (FPM runtime)
/etc/php/{version}/cli/php.ini      # PHP configuration (CLI)
/etc/mysql/mariadb.conf.d/          # MariaDB configuration
/etc/phpmyadmin/conf.d/             # phpMyAdmin overrides
/var/lib/phpmyadmin/tmp/            # phpMyAdmin template cache
/usr/share/phpmyadmin/              # phpMyAdmin web files
/var/lib/mysql/                     # MariaDB data directory
~/phpup/config.json                # phpup persistent config (co-located with stack)
```

## What the Installer Configures

### Apache

- Port 80, bound as root via `systemctl`
- DocumentRoot set to `~/phpup/www` with `<Directory>` grant
- Home directory made world-executable so `www-data` can traverse to `~/phpup/www`
- `mod_rewrite` enabled with `AllowOverride All` — `.htaccess` rewrites work out of the box
- **PHP wired via PHP-FPM**: managed conf at `/etc/apache2/conf-available/phpup-php-fpm.conf` routes `.php` requests through `mod_proxy_fcgi` to the active version's FPM socket (`/run/php/phpX.Y-fpm.sock`)
- `proxy` + `proxy_fcgi` modules enabled, legacy `mod_php` (`libapache2-mod-php*`) disabled
- phpMyAdmin alias at `/phpmyadmin`

### PHP

- **Extensions:** `curl`, `fileinfo`, `gd`, `intl`, `mbstring`, `mysql`, `sqlite3`, `xml`, `zip`, `bcmath`, `bz2` — installed as separate apt packages, auto-enabled
- `display_errors = On`
- Upload limits: 50 MB files, 300s timeout (suitable for phpMyAdmin imports)
- OPCache enabled with JIT
- `session.gc_maxlifetime = 14400` (4 hours, matches phpMyAdmin session timeout)
- PHP runs as **PHP-FPM** (`phpX.Y-fpm` systemd service) — the CLI default (`update-alternatives`) and the FPM runtime move together on version switch

### MariaDB

- Data directory initialized with blank root password
- Auth switched from `unix_socket` to `mysql_native_password` so phpMyAdmin can connect over TCP
- Error log configured with `[mysqld]` group header
- Data dir is never wiped: if blank-root auth can't be confirmed, phpup warns and leaves it untouched

### phpMyAdmin

- Installed from the official tarball (not the apt package, to avoid `dbconfig-common` complications)
- conf.d override at `/etc/phpmyadmin/conf.d/phpup.php` — survives delete
- `AllowNoPassword` enabled for root login
- Version check disabled, 4-hour session timeout
- Template cache directory configured at `/var/lib/phpmyadmin/tmp` (outside systemd's read-only `/usr` — see Troubleshooting)
- Configuration storage database (`pma`) with bookmark, history, and designer support

## PHP Version Switching (`fu`)

The hidden **`fu`** command switches between PHP versions using the [ondrej/php repository](https://deb.sury.org/). Select a version from the numbered list (8.2 → latest stable). The previous PHP stays installed — switching back is another `fu`.

**Partial stack?** If one or more components are missing (a failed `fu` apply, a manually deleted directory, an interrupted install), the dashboard shows a **partial stack detected** notice and Install recovers only what's missing — websites, databases, and settings are preserved.

`fu` handles:
- Installing the new versioned packages (`phpX.Y-cli` + `phpX.Y-fpm`)
- Switching the FPM service (`systemctl` stop old `phpX.Y-fpm` → start new)
- Re-wiring Apache to the active version's FPM socket (idempotent conf rewrite)
- Switching the CLI default (`update-alternatives --set php`)
- Re-applying PHP configuration to both `cli` and `fpm` INIs

**Migrating from a legacy mod_php stack?** Selecting the already-active version in `fu` still runs the migration — FPM packages are installed, Apache is rewired to the FPM socket, and `mod_php` is disabled. No separate migration step needed.

**Failure safety:** if the FPM service fails to start or verify after a switch, the whole stack rolls back — FPM service, Apache wiring, and the CLI alternative are all restored to the previous version.

## Service Management

phpup uses `systemctl` for service management:

| Dashboard Key | Action |
| ------------- | ------ |
| **R** | Restart Apache + MariaDB + active PHP-FPM (`systemctl restart`) |
| **S** | Toggle — stops if running, starts if stopped (all FPM versions stopped explicitly — systemd's `php*-fpm` glob is unreliable) |

## Why PHP-FPM over mod_php?

phpup moved Linux from the legacy `mod_php` Apache module to **Apache + PHP-FPM**. Benchmarks (identical PHP workload, same load tool, on the same hardware) show the shape of the difference:

| Concurrency | PHP-FPM | mod_php |
| ----------- | ------- | ------- |
| 10 | 647 RPS | 692 RPS |
| 50 | 620 RPS | 694 RPS |
| 100 | 675 RPS | 642 RPS |

- **Raw throughput is a wash** (within ~12%; mod_php edges ahead at low concurrency because the FastCGI proxy hop is a small per-request cost)
- **FPM wins on robustness**: at 100 concurrent requests, the mod_php Apache exhausted its prefork workers and died mid-benchmark; FPM took the same load and stayed up
- **Memory footprint**: mod_php loads the full PHP interpreter into every Apache worker; FPM keeps Apache workers lean with a dedicated PHP pool — less memory pressure, especially on modest hardware (WSL2 included)
- PHP itself runs the same Zend engine either way — the gains are process isolation, memory, and concurrency behaviour, not raw execution speed

## Safe Delete

Pressing **D**:
- Backs up MariaDB data to `~/phpup/data_backup/`
- Removes packages (`apt remove`) — configs in `/etc` are **preserved** by apt
- Purges runtime state (`/var/lib/apache2`, `/var/lib/php`, `/var/lib/phpmyadmin`, `/var/lib/mysql`)
- Keeps `~/phpup/www/` and `~/phpup/data_backup/` untouched

On reinstall, configs in `/etc` are re-applied automatically. MariaDB data is restored from `data_backup/`.

## Configuration

phpup keeps a persistent config at **`~/phpup/config.json`** — co-located with the stack so the config travels with the install folder. It's written on install, update, version switch, and delete, and read at startup.

```json
{
  "install_path": "/home/dafa/phpup",
  "installed_at": "2026-08-29T12:00:00",
  "package_manager": "apt",
  "brew_prefix": "",
  "port_prefix": "",
  "architecture": "x86_64",
  "os": "Debian 13",
  "php_min_series": "8.2",
  "apache_version": "2.4.68",
  "mariadb_version": "12.3.3",
  "php_version": "8.5.9",
  "phpmyadmin_version": "6.0.2",
  "mariadb_port": "mariadb-12.3",
  "php_port": "php85"
}
```

Notable keys:

- **`php_min_series`** — the minimum PHP series `fu` will offer (default `8.2`). Lower it (e.g. to `7.4`) to enable installing EOL series for legacy codebases. Override per-run with `PHPPUP_PHP_MIN_SERIES=7.4 ./phpup.sh` (env wins over config — handy for CI/testing).
- **`mariadb_port` / `php_port`** — the MacPorts series/port chosen at install; detection reads these instead of sniffing the filesystem.
- **`install_path`** — informational on Linux/macOS (the stack location is derived from the script); on Windows this is the real install root.

**Legacy migration:** configs from before v1.2.0 lived at `~/.config/phpup/config.json` — they're moved automatically to the stack folder on first run. The old location is removed; no manual step needed.

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
The dashboard re-detects the live stack on every render, so both rows should agree (Web Stack = CLI version, Service Status = FPM version). If they differ, a Homebrew/getphp php may be shadowing `/usr/bin/php` on PATH — phpup resolves the apt-managed binary via `update-alternatives` so this can't happen, but `brew shellenv` in `~/.bashrc` can confuse other tools. Run `fu` again to re-sync.

**PHP-FPM won't stop via `systemctl stop php*-fpm`:**
systemd's glob does not match FPM unit names reliably — it can silently leave `php8.5-fpm` running. phpup stops each installed FPM version by explicit unit name. For manual stops use the explicit name: `sudo systemctl stop php8.5-fpm`.

**phpMyAdmin warns "The $cfg['TempDir'] ... is not accessible":**
Debian's `php-fpm` systemd unit ships `ProtectSystem=full`, which makes `/usr` read-only to the FPM process — so `/usr/share/phpmyadmin/tmp` can never be written no matter the permissions. phpup uses `/var/lib/phpmyadmin/tmp` (outside the read-only mount) instead.

**phpMyAdmin warns about a missing cookie encryption key:**
The `$cfg['blowfish_secret']` was missing. Re-run the install (press **I**) or configure — phpup writes a stable secret to `/etc/phpmyadmin/conf.d/phpup.php` so PMA cookies survive restarts.

**"command not found: curl" on first run:**
The Quick Start command already handles this (`sudo apt install -y curl`). If you downloaded the script directly, install curl first: `sudo apt install -y curl`

## Support

Open an [issue](https://github.com/DaFa66/phpup/issues) or submit a [pull request](https://github.com/DaFa66/phpup/pulls).
