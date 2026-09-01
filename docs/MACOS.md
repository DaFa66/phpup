# phpup on macOS (Homebrew)

> The smooth path. Apple Silicon, modern Intel — if your Mac still gets
> OS updates, you're probably on this one. Homebrew does the heavy lifting,
> phpup does the thinking.

## Prerequisites

- **macOS 11 Big Sur or newer** (macOS 10.x uses the [MacPorts backend](INSTALL-OLDER-MAC.md) instead)
- **Xcode Command Line Tools** — phpup offers to install them if missing (`xcode-select --install`). You'll know they're needed if `git` or `make` aren't found.
- **An internet connection** — first install downloads bottles, not source. It's fast.

That's it. phpup installs [Homebrew](https://brew.sh) automatically if you don't have it. No other dependencies.

## Quick Start

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.sh)"
```

Press **I** to install. That's the whole Quick Start. There isn't a Step 2.

## Backend Selection

On a modern Mac, phpup uses Homebrew. Always. Here's exactly when:

| Your Mac                             | Backend                                           | Why                                                  |
| ------------------------------------ | ------------------------------------------------- | ---------------------------------------------------- |
| Apple Silicon (M1/M2/M3/M4)          | [Homebrew](https://brew.sh) — always              | Native bottles, fast, no reason not to               |
| Intel, macOS 14+ (Sonoma/Sequoia)    | [Homebrew](https://brew.sh) — while supported     | Still in Homebrew's 3-release window                 |
| Intel, macOS 11–13 (Big Sur–Ventura) | [MacPorts](https://www.macports.org/) — automatic | Homebrew is phasing out Intel; ports keeps you going |

Running an older Intel Mac? You want the [MacPorts install guide](INSTALL-OLDER-MAC.md) instead — that's the one with screenshots and coffee recommendations.

## Forcing a backend

If you know what you're doing:

### Force Homebrew (even on older Intel Macs where phpup would pick MacPorts)

```bash
PHPPUP_BACKEND=brew /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.sh)"
```

### Force MacPorts (even on Apple Silicon or modern Intel)

```bash
PHPPUP_BACKEND=port /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.sh)"
```

phpup remembers your existing stack — if you've already got a working Homebrew setup, it won't silently switch you to MacPorts. The override is for new installs or deliberate migrations.

## What Gets Installed

| Component      | Homebrew Formula                                | Config Location                                  |
| -------------- | ----------------------------------------------- | ------------------------------------------------ |
| **Apache**     | `httpd`                                         | `$(brew --prefix)/etc/httpd/httpd.conf`          |
| **MariaDB**    | `mariadb`                                       | `$(brew --prefix)/etc/my.cnf`                    |
| **PHP**        | `php` (latest) or `php@8.x` (switched via `fu`) | `$(brew --prefix)/etc/php/{version}/php.ini`     |
| **phpMyAdmin** | `phpmyadmin` (bottle)                           | `$(brew --prefix)/etc/phpmyadmin.config.inc.php` |

Everything lives under the Homebrew prefix — `/opt/homebrew` on Apple Silicon, `/usr/local` on Intel. phpup never hardcodes the path; it asks Homebrew at runtime.

## Directory Layout

```
~/phpup/
├── www/             # ← Your websites go here
│   └── phpinfo.php  # (auto-created test file)
├── logs/            # Apache access/error logs
└── data_backup/     # (created on delete — MariaDB databases preserved)

Homebrew paths (managed by brew):
$(brew --prefix)/etc/httpd/             # Apache configuration
$(brew --prefix)/etc/php/{version}/     # PHP configuration
$(brew --prefix)/etc/my.cnf             # MariaDB configuration
$(brew --prefix)/etc/phpmyadmin.config.inc.php  # phpMyAdmin configuration
$(brew --prefix)/share/phpmyadmin/      # phpMyAdmin web files
$(brew --prefix)/var/mysql/             # MariaDB data directory
~/phpup/config.json                    # phpup persistent config
```

> Run `brew --prefix` to see the actual path on your machine.

## What the Installer Configures

### Apache

- Port 80, bound via `sudo apachectl` (brew services runs as your user, can't bind low ports)
- DocumentRoot: `~/phpup/www` with group write for `_www`
- `mod_rewrite` enabled — `.htaccess` works out of the box
- PHP module loaded via `libphp.so`
- phpMyAdmin alias at `/phpmyadmin`

### PHP

- **Extensions:** Most are compiled statically into the Homebrew PHP binary — `curl`, `gd`, `intl`, `mbstring`, `mysqli`, `openssl`, `pdo_mysql`, `sodium`, `sqlite3`, `xml`, `zip`. Extensions that ship as separate `.so` files are enabled automatically if the file exists.
- `display_errors = On`
- Upload limits: 50 MB files, 300s timeout
- OPCache enabled with JIT
- `session.gc_maxlifetime = 14400` (4 hours)

### MariaDB

- Data directory initialized with blank root password
- Auth switched from `unix_socket` to `mysql_native_password` so phpMyAdmin can connect over TCP
- Service managed via `brew services`
- If blank-root auth can't be confirmed, a populated data dir is **preserved** (moved aside to `var/mysql.backup-<date>`) rather than wiped. Only an empty or missing data dir is re-initialized

### phpMyAdmin

- Installed from the Homebrew bottle
- `config.inc.php` with blowfish secret and blank-password root login
- Version check disabled, 4-hour session timeout
- Template cache in `$(brew --prefix)/share/phpmyadmin/tmp`
- Configuration storage database (`pma`)

## PHP Version Switching (`fu`)

The hidden **`fu`** command switches PHP versions using Homebrew formulae (`php@8.2`, `php@8.3`, …, `php@8.5`). Pick a version from the numbered list — the previous one stays installed, so switching back is instant.

Under the hood, `fu` uses `brew link --overwrite --force php@X.Y` to repoint the `php` symlink. The Apache module and PHP-FPM (if installed) are restarted automatically.

## Service Management

phpup uses `brew services` (which wraps launchd) to manage Apache and MariaDB:

| Dashboard Key | Action                                       |
| ------------- | -------------------------------------------- |
| **R**         | Restart Apache + MariaDB                     |
| **S**         | Toggle — stops if running, starts if stopped |

Apache binds port 80 via `sudo apachectl` (brew services runs as your user and can't do low ports). The `sudo` prompt is normal and expected.

## Safe Delete

Pressing **D**:

- Stops all services
- Backs up MariaDB data to `~/phpup/data_backup/`
- Runs `brew uninstall` on each component
- Removes lingering Cellar directories and LaunchAgent plists
- Keeps `~/phpup/www/` and `~/phpup/data_backup/` untouched

Config files live in the Homebrew prefix and are wiped on uninstall — that's brew's normal behaviour. phpup re-generates them on reinstall, so there's nothing to back up.

## After Installation

| Question                    | Answer                                 |
| --------------------------- | -------------------------------------- |
| Where to put website files? | `~/phpup/www`                          |
| Test your PHP setup?        | http://localhost/phpinfo.php           |
| Access phpMyAdmin?          | http://localhost/phpmyadmin            |
| Login to phpMyAdmin?        | Username: `root` / Password: _(blank)_ |
| PHP from terminal?          | `php` available via brew's symlink     |

## Intel Macs & the Homebrew Phase-Out

A note for Intel Mac owners: Homebrew is winding down Intel support. Intel moves to Tier 3 (no new bottles, source-compile only) in September 2026 and becomes fully unsupported in September 2027.

**What this means for you:**

- **macOS 14+ (Sonoma/Sequoia):** You're fine for now — Homebrew still ships bottles. phpup will keep using brew.
- **macOS 11–13 (Big Sur–Ventura):** phpup automatically switches to [MacPorts](https://www.macports.org/) so you don't get stranded. See the [MacPorts install guide](INSTALL-OLDER-MAC.md).
- **Apple Silicon:** Unaffected — this is an Intel-only issue.

phpup handles the transition so you don't have to think about it. If you're on an Intel Mac, sooner or later you'll see `Package: port` on your dashboard instead of `Package: brew`. That's normal.

## Troubleshooting

**"Apache failed to start" but `configtest` passes:**
Another process might be on port 80. Check with `sudo lsof -i :80`. If you have the macOS built-in Apache enabled, disable it: `sudo apachectl stop` and `sudo launchctl unload -w /System/Library/LaunchDaemons/org.apache.httpd.plist`.

**phpMyAdmin login fails with "Cannot log in to the MySQL server":**
MariaDB might be using `unix_socket` auth. Run `mysql -u root` in the terminal — if it lets you in without a password but phpMyAdmin can't, the auth plugin needs switching. Re-run the install (press **I**) — phpup's `configure_mariadb` handles this.

**`php -v` shows the wrong version after `fu`:**
You might have multiple PHP versions linked. Run `brew unlink php && brew link --overwrite --force php@8.x` (replace `8.x` with your desired version), or just run `fu` again — it does this automatically.

**First install is taking forever:**
It shouldn't — Homebrew uses pre-built bottles on modern macOS. If you're seeing source compiles (lines like `==> make`), you might be on an older macOS where bottles aren't available. Check the [MacPorts guide](INSTALL-OLDER-MAC.md) — it covers the slow path and why it happens.

## Support

Open an [issue](https://github.com/DaFa66/phpup/issues) or submit a [pull request](https://github.com/DaFa66/phpup/pulls).
