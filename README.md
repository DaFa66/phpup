# phpup — Bare-metal PHP for local development

> Install, update and manage complete PHP development environments from a single command.

Originally inspired by getPHP, **phpup** has evolved into an independent project focused on giving developers complete control over their local PHP environment.

## Why phpup?

- Always installs the latest stable component versions
- One-command installation
- Automatic configuration
- Built-in update manager
- Cross-platform — Windows, macOS, and Linux
- Version switching
- Safe delete with database preservation
- Designed for developers and power users

## Quick Start

### Windows

Right-click PowerShell → **Run as Administrator**, then:

```powershell
irm https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.ps1 | iex
```

### macOS

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.sh)"
```

### Linux

```bash
if ! command -v curl &> /dev/null; then sudo apt install -y curl; fi && source <(curl -fsSL https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.sh)
```

After launching, press **I** to install. On subsequent runs the script remembers your setup and goes straight to the dashboard.

## Platform Support

| Platform | Architecture   | Package Manager                                                     | Status    | Docs                               |
| -------- | -------------- | ------------------------------------------------------------------- | --------- | ---------------------------------- |
| Windows  | x64            | Direct binary downloads                                             | ✅ Stable | [docs/WINDOWS.md](docs/WINDOWS.md) |
| macOS    | x86_64 + arm64 | [Homebrew](https://brew.sh) / [MacPorts](https://www.macports.org/) | ✅ Stable | [docs/MACOS.md](docs/MACOS.md)     |
| Linux    | x86_64 + arm64 | apt (Debian/Ubuntu/WSL2)                                            | ✅ Stable | [docs/LINUX.md](docs/LINUX.md)     |

## Special mention on macOS backends for Apple silicon and Intel Macs

phpup picks the right package manager for your Mac automatically:

| Your Mac                                 | Backend                                                    |
| ---------------------------------------- | ---------------------------------------------------------- |
| Apple Silicon (M1/M2/M3/M4)              | [Homebrew](https://brew.sh) — always                       |
| Intel, macOS 14+ (Sonoma/Sequoia)        | [Homebrew](https://brew.sh) — while supported              |
| Intel, macOS 10.15–13 (Catalina–Ventura) | [MacPorts](https://www.macports.org/) — automatic fallback |

You can override the automatic selection with an environment variable:

### Force Homebrew (even on older Intel Macs where phpup would pick MacPorts)

```bash
PHPPUP_BACKEND=brew /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.sh)"
```

### Force MacPorts (even on Apple Silicon or modern Intel)

```bash
PHPPUP_BACKEND=port /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.sh)"
```

If you already have a working Homebrew stack, phpup keeps it — it never silently migrates you to MacPorts.

> **On an older Intel Mac (Catalina → Ventura)?** Follow the step-by-step, screenshot-led guide: **[docs/INSTALL-OLDER-MAC.md](docs/INSTALL-OLDER-MAC.md)**

## The Dashboard

```
┌─────────────────────────────┐
│    ____  _   _ ____         │
│   |  _ \| | | |  _ \  /\    │
│   | |_) | |_| | |_) | || |  │
│   |  __/|  _  |  __/| || |  │
│   |_|   |_| |_|_|    ||_|   │
│         ▲ ▲ ▲               │
│         phpup               │
└─────────────────────────────┘
```

The dashboard shows installed versions, running services, useful paths, and available commands — all in one place.

### Commands

| Key    | Action                                                                                          |
| ------ | ----------------------------------------------------------------------------------------------- |
| **I**  | Install the web stack                                                                           |
| **U**  | Update outdated components                                                                      |
| **fu** | _(hidden)_ PHP version switch (package manager on Mac/Linux, offline zips on Windows)           |
| **R**  | Restart Apache + MariaDB                                                                        |
| **S**  | Toggle services — stops if running, starts if stopped. On Windows, offers service registration. |
| **D**  | Delete the stack (preserves `www/` and databases)                                               |
| **Q**  | Quit                                                                                            |

## How Version Resolution Works

phpup doesn't hardcode version numbers. Every install and update dynamically resolves the latest stable release of each component:

| Component      | Source                                                                                     | Method                                                          |
| -------------- | ------------------------------------------------------------------------------------------ | --------------------------------------------------------------- |
| **Apache**     | [Apache Lounge](https://www.apachelounge.com/download/) / apt / brew / port                | Windows: scrapes download page. Mac/Linux: package manager      |
| **PHP**        | [windows.php.net](https://windows.php.net) / [ondrej](https://deb.sury.org/) / brew / port | Windows: queries `releases.json`. Mac/Linux: package manager    |
| **MariaDB**    | [mariadb.org](https://mariadb.org)                                                         | REST API, sorts by support policy (Rolling > LTS), then version |
| **phpMyAdmin** | [phpmyadmin.net](https://www.phpmyadmin.net)                                               | Latest stable release                                           |

PHP is always the latest stable major version (8.2+, currently 8.5). Use the hidden **`fu`** command to switch versions.

## After Installation

| Question                    | Answer                                 |
| --------------------------- | -------------------------------------- |
| Where to put website files? | `www/` under your install directory    |
| Test your PHP setup?        | http://localhost/phpinfo.php           |
| Access phpMyAdmin?          | http://localhost/phpmyadmin            |
| Login to phpMyAdmin?        | Username: `root` / Password: _(blank)_ |

## Safe Delete

Pressing **D** removes the stack while preserving your website files and databases. On reinstall, backups are automatically detected and offered for restoration. Config files are preserved according to each platform's conventions — see the OS-specific docs for details.

## Platform-Specific Details

For prerequisites, directory layouts, component configuration, offline mode, service registration, persistent config, troubleshooting, and platform-specific behaviour:

| Platform                | Documentation                                          |
| ----------------------- | ------------------------------------------------------ |
| **Windows**             | [docs/WINDOWS.md](docs/WINDOWS.md)                     |
| **macOS (Homebrew)**    | [docs/MACOS.md](docs/MACOS.md)                         |
| **macOS (older Intel)** | [docs/INSTALL-OLDER-MAC.md](docs/INSTALL-OLDER-MAC.md) |
| **Linux**               | [docs/LINUX.md](docs/LINUX.md)                         |

## Support

Open an [issue](https://github.com/DaFa66/phpup/issues) or submit a [pull request](https://github.com/DaFa66/phpup/pulls).

---

> **Disclaimer:** phpup is an independent, open-source tool and is not affiliated with, sponsored by, or endorsed by the PHP Group, the PHP Foundation, Apache Lounge, MariaDB Foundation, or phpMyAdmin.
