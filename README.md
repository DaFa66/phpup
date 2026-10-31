# phpup — Bare-metal PHP for local development

> Install, update and manage complete PHP development environments from a single command.

**[phpup.org](https://phpup.org)** — install guides per platform, screenshots of the panel and
links to the docs.

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
irm https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup-boot.ps1 | iex
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

| Platform | Architecture                   | Package Manager                                                     | Status    | Docs                               |
| -------- | ------------------------------ | ------------------------------------------------------------------- | --------- | ---------------------------------- |
| Windows  | x64 (+ ARM64 via emulation)    | Direct binary downloads                                             | ✅ Stable | [docs/WINDOWS.md](docs/WINDOWS.md) |
| macOS    | x86_64 + arm64                 | [Homebrew](https://brew.sh) / [MacPorts](https://www.macports.org/) | ✅ Stable | [docs/MACOS.md](docs/MACOS.md)     |
| Linux    | x86_64 + arm64                 | apt (Debian/Ubuntu/WSL2)                                            | ✅ Stable | [docs/LINUX.md](docs/LINUX.md)     |

## Special mention on macOS backends for Apple silicon and Intel Macs

phpup picks the right package manager for your Mac automatically:

| Your Mac                                 | Backend                                                    |
| ---------------------------------------- | ---------------------------------------------------------- |
| Apple Silicon (all M-series)             | [Homebrew](https://brew.sh) — always                       |
| Intel (any macOS version)                | [MacPorts](https://www.macports.org/) — automatic          |

You can override the automatic selection with an environment variable:

### Force Homebrew (even on an Intel Mac, where phpup now picks MacPorts)

```bash
PHPPUP_BACKEND=brew /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.sh)"
```

### Force MacPorts (even on Apple Silicon)

```bash
PHPPUP_BACKEND=port /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.sh)"
```

If you already have a working Homebrew stack, phpup keeps it — it never silently migrates you to MacPorts, and it never nags. On an Intel Mac the dashboard header carries the caveat (`Homebrew: /usr/local (Intel — PHP builds from source)`), a one-time `[ NOTE ]` explains it and names the way out (`PHPPUP_BACKEND=port`), and any install, update or `fu` that is about to compile PHP from source says so **before** it starts, with the expected time.

> **On an Intel Mac?** Homebrew no longer supports the platform at all, so follow the step-by-step, screenshot-led guide: **[docs/INSTALL-OLDER-MAC.md](docs/INSTALL-OLDER-MAC.md)**

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

The dashboard shows installed versions, running services, useful paths, and available commands — all in one place. The **Process Status** section groups the web server with its PHP engine (`Apache` → `PHP` → `MariaDB`):

- **Windows/macOS** — PHP reports `active` when the module is wired and running, `stopped` when Apache is down, `not wired` when the module line is missing or stale, and `not installed` when no PHP is present. On macOS the row is labelled `mod_php` (PHP runs inside Apache) and the Web Stack version is read from the module Apache actually loads — so it matches `phpinfo`
- **Linux** — PHP runs as **PHP-FPM**, reported as `Running (8.5)` / `Stopped (8.5)` with the active FPM version shown; the Web Stack section shows the CLI version separately

### Commands

| Key    | Action                                                                                          |
| ------ | ----------------------------------------------------------------------------------------------- |
| **I**  | Install the web stack                                                                           |
| **U**  | Update outdated components                                                                      |
| **fu** | _(hidden)_ PHP version switch (package manager on Mac/Linux, cached zips on Windows with a missing series downloaded on demand — flags newer patches, handles pre-release labels; on Linux switches Apache's PHP-FPM runtime + CLI together) |
| **R**  | Restart Apache + MariaDB                                                                        |
| **S**  | Toggle services — stops if running, starts if stopped. On Windows, offers service registration. |
| **D**  | Delete the stack (preserves `www/` and databases)                                               |
| **Q**  | Quit                                                                                            |

## Control panel (Windows)

A desktop control surface for phpup — Rust + egui, one static binary, no webview and no Node
toolchain. It reads the CLI contract below and drives the same verbs, so the scripts stay the
single source of truth for installation, updates and version switching.

**Download:** Windows x64 zip with `install.ps1`:
[phpup panel 0.1.0 beta](https://github.com/DaFa66/phpup/releases/tag/panel-v0.1.0-beta-win).
It is a pre-release, so GitHub keeps it out of the *Latest* slot; that link, or
**Releases -> show more**, is the way in.

- Live component cards: versions, running state, PIDs, ports, SAPI, service names
- Start / Restart / Stop with exit-code handling instead of parsed text
- Terminal-style output pane fed by phpup's stderr, with copy and follow/pause
- Tray icon, close-to-tray, quick links, System/Light/Dark theme, zoom, hover states
- Service startup type per registered service (`Auto` / `Disabled`): boot behaviour only,
  since Start / Restart / Stop already control the running processes
- Optional start in the tray at launch (no window, no taskbar button) and a Start with
  Windows toggle, both off by default
- Optional administrator mode: per action, or an always-elevated panel (no repeated UAC
  prompts) with `phpup - as administrator` in the title bar

Download the beta from [Releases](https://github.com/DaFa66/phpup/releases)
(`phpup-panel-0.1.0-beta-win-x64.zip`), extract it and run `\.install.ps1`. That copies the exe into
`<install_path>\bin` and needs no elevation. Or build it yourself:

```
cd panel
cargo build --release
copy target\release\phpup-panel.exe C:\phpup\bin
```

**Settings → Startup → Start with Windows** registers it at logon through a per-user `Run`
entry, no elevation needed. Pair it with **Settings → Window → Start hidden in the tray** so
login produces no taskbar entry, only the tray icon. For an *elevated* start, use a scheduled
task with `/RL HIGHEST` instead, and use one or the other rather than both:

```
schtasks /Create /TN "phpup panel" /TR "\"C:\phpup\bin\phpup-panel.exe\"" /SC ONLOGON /RL HIGHEST /F
```

The panel is at **0.1.0** and not yet released as a download. Full build notes, settings and
troubleshooting: [`panel/README.md`](panel/README.md).

## Scripted use (CLI)

Every verb accepts flags, so a GUI, tray app or CI job can drive phpup without the dashboard:

```
phpup status [--json] [--fast] [--watch N] [--quiet]
phpup start|stop|restart [--json] [--quiet]
phpup version
phpup help
```

- **Stream discipline** — stdout carries only the machine payload; all human-readable output
  goes to stderr. `--json` is therefore safe to pipe.
- **`--fast`** skips the expensive probes (service manager, ownership checks) for a status
  that is cheap enough to poll: ~250ms against ~2s for the full one.
- **`--watch N`** stays resident and emits one JSON object per line every N seconds, instead
  of paying PowerShell start-up on each tick.
- **Exit codes** are part of the contract: `0` ok · `1` failed · `2` usage · `3` not
  installed · `4` elevation required · `5` port conflict.
- The status schema is versioned (`schema: 1`), always fully populated — unknown values are
  `null`, never omitted — and additive only.

`install`, `update`, `delete`, `switch` and `doctor` are reserved for v2, once they have
non-interactive modes. The full contract — schema, stream rules, semantics — is in
[`docs/CLI.md`](docs/CLI.md).

## How Version Resolution Works

phpup doesn't hardcode version numbers. Every install and update dynamically resolves the latest stable release of each component:

| Component      | Source                                                                                     | Method                                                          |
| -------------- | ------------------------------------------------------------------------------------------ | --------------------------------------------------------------- |
| **Apache**     | [Apache Lounge](https://www.apachelounge.com/download/) / apt / brew / port                | Windows: scrapes download page. Mac/Linux: package manager      |
| **PHP**        | [windows.php.net](https://windows.php.net) / [ondrej](https://deb.sury.org/) / brew / port | Windows: queries `releases.json`. Mac/Linux: package manager    |
| **MariaDB**    | [mariadb.org](https://mariadb.org)                                                         | REST API, sorts by support policy (Rolling > LTS), then version |
| **phpMyAdmin** | [phpmyadmin.net](https://www.phpmyadmin.net)                                               | Latest stable release                                           |

PHP is always the latest stable major version (8.2+, currently 8.5). Use the hidden **`fu`** command to switch versions — on Windows it manages cached zips and can fill missing series (including EOL ones like 7.4 if the `php_min_series` floor is lowered), flags newer patches, shows pre-release labels (`8.6.0 beta1`), and re-points Apache's PHP module automatically when you cross major versions. On Linux it switches the Apache PHP-FPM runtime and the CLI default together, with automatic rollback if the new version fails to start. On macOS it relinks the formula **and** re-points Apache's `php_module` at that same formula, so the version serving requests always matches the version phpup reports.

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

## Roadmap

[**docs/PANEL-PLATFORMS.md**](docs/PANEL-PLATFORMS.md): the plan for porting the desktop panel
to macOS (Intel and Apple silicon), Linux (x86_64 and arm64) and Windows on ARM.
Proposed, not yet started.

## Support

- Project site: **[phpup.org](https://phpup.org)**
- Releases and pre-releases: [Releases](https://github.com/DaFa66/phpup/releases)
- Docs: [`docs/`](docs)

Open an [issue](https://github.com/DaFa66/phpup/issues) or submit a [pull request](https://github.com/DaFa66/phpup/pulls).

---

> **Disclaimer:** phpup is an independent, open-source tool and is not affiliated with, sponsored by, or endorsed by the PHP Group, the PHP Foundation, Apache Lounge, MariaDB Foundation, or phpMyAdmin.
