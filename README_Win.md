# getPHP for Windows — Local Web Stack. One Script. Done.

Launch your local PHP web stack on Windows 11 with a single PowerShell script. Enjoy a full development environment without the bloat of a desktop application like XAMPP.

> **This is the official Windows port of [getPHP.org](https://getphp.org).**  
> The original Mac/Linux script lives at [getphporg/getphp](https://github.com/getphporg/getphp).

## Quick Start

```powershell
# Right-click PowerShell → Run as Administrator, then:
& "D:\dev\getphp\install_webstack.ps1"
```

Press **I** to install. That's it.

## What It Installs

| Component | Source | Latest? |
|-----------|--------|---------|
| **Apache** | [Apache Lounge](https://www.apachelounge.com/download/) | ✅ Resolves latest VS18 build dynamically |
| **PHP** | [windows.php.net](https://windows.php.net/downloads/releases/) | ✅ Parses releases.json for latest 8.x TS VS17 (falls back to VS16) |
| **MariaDB** | [mariadb.org](https://downloads.mariadb.org/rest-api/mariadb/) | ✅ Queries REST API for latest Stable (Rolling > LTS) |
| **phpMyAdmin** | [phpmyadmin.net](https://www.phpmyadmin.net/downloads/) | ✅ Scrapes downloads page for latest stable |

All installed to `D:\webstack\` — no system-wide changes, no services registered, no cruft.

## Directory Layout

```
D:\webstack\
├── apache\          # Apache Lounge (VS18, port 80)
│   ├── bin\
│   ├── conf\
│   └── ...
├── php\             # PHP 8.x thread-safe x64
│   ├── php.exe
│   ├── ext\
│   └── ...
├── mariadb\         # MariaDB
│   ├── bin\
│   ├── data\
│   └── ...
└── www\             # ← Your websites go here
    ├── phpinfo.php  # (auto-created test file)
    └── phpmyadmin\  # phpMyAdmin
```

## Dashboard Commands

After running the script, you'll see the getPHP dashboard:

```
┌────────────────────────────────────┐
│             _   ____  _   _ ____   │
│   __ _  ___| |_|  _ \| | | |  _ \  │
│  / _` |/ _ \ __| |_) | |_| | |_) | │
│ | (_| |  __/ |_|  __/|  _  |  __/  │
│  \__, |\___|\__|_|   |_| |_|_|     │
│  |___/              www.getPHP.org │
└────────────────────────────────────┘

Your Web Stack:
~~~~~~~~~~~~~~~
Apache -------> 2.4.67
MariaDB ------> 11.4.5
PHP ----------> 8.4.7
phpMyAdmin ---> available

Service Status:
~~~~~~~~~~~~~~~
Apache -------> running
MariaDB ------> running
PHP ----------> CLI available

Stack Commands:
~~~~~~~~~~~~~~~
U  Update all components
R  Restart all services
S  Stop all services
T  Start all services
D  Delete the web stack
Q  Quit
```

| Key | Action |
|-----|--------|
| **I** | Install the web stack (download + configure + start) |
| **U** | Update all components to their latest stable versions |
| **R** | Restart Apache + MariaDB |
| **S** | Stop all services |
| **T** | Start all services |
| **D** | Delete the web stack (preserves `www\` files and MariaDB data) |
| **Q** | Quit |

## After Installation

| Question | Answer |
|----------|--------|
| Where to put website files? | `D:\webstack\www` |
| How to test your PHP setup? | http://localhost/phpinfo.php |
| Where to access phpMyAdmin? | http://localhost/phpmyadmin |
| How to log into phpMyAdmin? | Username: `root` / Password: *(blank)* |

## What the Installer Configures

- **Apache** — Port 80, DocumentRoot `D:/webstack/www`, mod_rewrite, AllowOverride All, PHP module, phpMyAdmin alias, logs in `www/`
- **PHP** — `extension_dir`, essential extensions (curl, gd, mbstring, mysqli, openssl, pdo_mysql, pdo_sqlite), display_errors On
- **MariaDB** — Data directory initialised with blank root password
- **phpMyAdmin** — Auto-generated `config.inc.php` with blowfish secret and passwordless root login

## Prerequisites

- **Windows 10/11** (64-bit)
- **Run as Administrator** (required for port 80 binding)
- **Visual C++ Redistributable** — Apache Lounge VS18 binaries require the [latest VC++ Redistributable (x64)](https://aka.ms/vs/17/release/vc_redist.x64.exe). The script will warn you about this during install if it's needed.

## Zero Footprint

The `install_webstack.ps1` script runs entirely in-memory and never installs itself on your machine. Only the web stack is added to `D:\webstack\` if you choose to install it. To manage services, update, or uninstall the stack, simply re-run the script at any time.

## Uninstalling

Run the script and press **D** (Delete). This removes Apache, PHP, MariaDB, and phpMyAdmin but **preserves** your website files in `D:\webstack\www\` and your MariaDB data directory. To perform a complete wipe, delete `D:\webstack\` manually after running Delete.

## How It Resolves Latest Versions

Unlike most installers that hardcode version numbers, `install_webstack.ps1` dynamically resolves the latest stable version of every component every time you install or update:

- **Apache** — Scrapes the Apache Lounge download page, finds all VS## x64 zips, picks the highest VS version × Apache version combination
- **PHP** — Queries the `releases.json` API from windows.php.net, filters for PHP 8.x thread-safe x64, prefers VS17 builds over VS16
- **MariaDB** — Queries the MariaDB REST API (`/rest-api/mariadb/`), sorts stable releases by support policy (Rolling > LTS), then by version number
- **phpMyAdmin** — Scrapes the phpMyAdmin downloads page, finds all stable `all-languages.zip` files (excluding snapshots), picks the highest version

## Support & Contributions

If you run into any errors or bugs, please open an [issue](https://github.com/getphporg/getphp/issues) or send a [pull request](https://github.com/getphporg/getphp/pulls).

You can also contact us through the [Support Page](https://getphp.org/support.php) at [getPHP.org](https://getphp.org).

---

> **Disclaimer:** getPHP is an independent, open-source tool and is not affiliated with, sponsored by, or endorsed by the PHP Group, the PHP Foundation, Apache Lounge, MariaDB Foundation, or phpMyAdmin.
