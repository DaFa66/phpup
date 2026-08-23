# Changelog

All notable changes to phpup will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

Versions for `phpup.ps1` (Windows) and `phpup.sh` (Mac/Linux) are tracked independently
using platform suffixes: **`-win`** for Windows, **`-nix`** for macOS and Linux.

Jump to the [Version History Summary](#version-history-summary) table for a quick
overview of every release.

---

## [1.0.2-nix] — 2026-08-21

### macOS & Linux (phpup.sh v1.0.2)

Patch release from the dual-stack test (MacPorts alongside Homebrew on one Mac): ports-backend fixes and machine-level self-healing so a fresh install "just works" on any Mac. *Previous platform update: [1.0.1-nix](#101-nix--2026-08-11).*

**Fixed**
- `detect_*` in ports mode no longer falls through to the brew Cellar — a dual-stack machine now reports the correct stack (previously a brew install hid the Install option)
- macOS version token for the MacPorts installer: 11+ drops the minor (15.7 → `15-Sequoia`); 10.x keeps major.minor — previously the token fell through to "not viable" on every 11+ release with a minor
- Service-start/stop verification is now stack-aware: `stack_proc()` pins the process to the active backend by executable path, so "Apache started"/"MariaDB started" can no longer be false positives from a coexisting brew stack, and stopping one stack never kills the other's processes
- phpMyAdmin blowfish secret: per-install random 32 bytes on ALL backends (was a static known-default on brew, absent on ports — PMA showed the "temporary key" warning)
- MariaDB data-dir init is verified post-install (mysql system DB present) — a partial/raced init wipes and retries once instead of silently failing later with "Table 'mysql.plugin' doesn't exist"

**Added**
- Detect damaged CLT 16 C++ headers before a ports source build and print the known fix (MacPorts hotlist #clts16 — `'new' file not found`)
- Detect and repair a world-writable sudo timestamp dir (the "password spam" UX: sudo prompts on every invocation because it distrusts the cache)

### Notes
- No tag: patch-level per RELEASES.md (milestone tags only; CHANGELOG is the record)


---

## [2.4.1-win] — 2026-08-18

*Previous platform update: [2.4.0-win](#240-win--2026-08-17).*

### Windows (phpup.ps1 v2.4.1)

**Fixed**
- `fu` (forced update) no longer orphans the phpMyAdmin `Alias` on a subsequent run — the `DocumentRoot` `<Directory>` block rewrite is now scoped to the old document root exactly, instead of greedily rewriting every quoted `<Directory>` block to `www`. (Fixes a 403 Access Denied when switching PHP versions on a stack with phpMyAdmin installed).
- `fu` now properly self-heals a missing phpMyAdmin `<Directory>` block (access grant) if it was dropped or corrupted, instead of skipping the grant check when the `Alias` alone is present.

---

## [2.4.0-win] — 2026-08-17

*Previous platform update: [2.3.0-win](#230-win--2026-08-17).*

### Windows (phpup.ps1 v2.4.0)

**Added**
- `fu` now manages PHP versions by series (8.2 → newest stable): a series with nothing cached is offered as `(not cached — download & install)`; a cached version behind the latest patch in its series is flagged (`8.2.32 (older → 8.2.33 is available)`) and selecting it asks install-latest vs use-existing, offering to delete the old cached copy after a fresh download
- Multiple cached variants of a PHP series are marked `*`; selecting one opens a sub-menu where each variant can be installed or deleted (`[d]` + row number, Yes/No confirm) — gives pre-release zips their first in-app delete path. The currently installed build is never offered for deletion, and selecting it is a no-op ("already installed")
- Pre-release builds now show their suffix in the fu menu (`8.6.0 alpha3`, `8.6.0 beta1`) instead of both rendering as `8.6.0`
- `fu` checks windows.php.net online for the latest stable per series; `-Offline` keeps it cache-only (labels and variant markers still apply)
- New config key `php_min_series` (default `8.2`) sets the oldest PHP series offered as a download candidate; cached zips are always listed regardless
- `php_min_series` accepts 7.x floors too (e.g. `7.0`): the series filter now covers every `N.M` series present in releases.json, and the resolver falls back to the VC15 toolchain used by 7.x builds (`ts-vc15-x64`)
- Variant sub-menus re-render through a shared renderer after a delete; deleting down to only the installed build returns to the version-switch menu (re-scanning the cache) instead of a dead-end list
- Delete accepts both `d<number>` and `<number>d` forms (`d2` and `2d`); a bare `d` prints the format hint. Install and menu choices are strictly numeric — `2d`/`2x` are rejected with "Invalid choice" instead of being silently coerced
- Selecting a PHP version now prints a confirmation (`PHP → 8.2.33`) matching the component menus, so the choice is visible before the next menu appears
- Stack dashboard and fu summary flag pre-release installs (`8.6.0 beta1 (pre-release)` in yellow) instead of a bare numeric version that implies a stable release
- Apache PHP module follows the installed PHP major: 7.x loads `php7apache2_4.dll` with `LoadModule php7_module`, 8.x loads `php8apache2_4.dll` with `LoadModule php_module` (the symbol PHP 8 exports). httpd.conf is re-pointed automatically after any PHP switch, so 8↔7 switches keep Apache loadable
- `php_min_series` is now persisted to `config.json` by `Save-Config` (default `8.2`) — visible and editable instead of an invisible code default; an existing user-set value is preserved, and older configs missing the key fall back to the default
- `versions.php` in config.json records the full pre-release label (`8.6.0 beta1`) instead of a bare numeric version

**Changed**
- `fu` header no longer says "(offline)" — it scans cached zips and may consult the network
- New helpers: `Get-PhpReleasesJson`, `Resolve-PhpSeriesUrl`, `Invoke-DownloadToCache`, `Get-PhpZipLabel`

---

## [2.3.0-win] — 2026-08-17

*Previous platform update: [2.2.4-win](#224-win--2026-08-17).*

### Windows (phpup.ps1 v2.3.0)

**Added**
- ARM64 support (soft): the hard architecture block is replaced with a warning — the x64 stack runs under Windows-on-ARM emulation (Prism), expected to work but untested and slower than native x64. 32-bit Windows remains hard-blocked
- VC++ Redistributable install now passes `--architecture x64` to winget so it resolves correctly on ARM64 hosts (the stack is x64-only, so the x64 runtime is required even under emulation)

**Fixed**
- Stale pinned PHP fallback URL bumped 8.5.8 → 8.5.9 (the 8.5.8 zip 404s; live resolution was covering it, but the safety net is now valid again)

**Changed**
- README platform table and `docs/WINDOWS.md` updated — ARM64 is documented as emulation-only with the VC++ runtime explanation, and the CLI-opcache note (phar tools) is now explicit
- Redistributable URL now referenced from `$FALLBACK_URLS.Redist` everywhere (was hardcoded in four places) — single source of truth

---

## [2.2.4-win] — 2026-08-17

*Previous platform update: [2.2.1-win](#221-win--111-nix--2026-07-26).*

### Windows (phpup.ps1 v2.2.4)

**Fixed**
- `opcache.enable_cli` is now set to `0` (was `1`) — with opcache + JIT tracing enabled for CLI, phar tools (Composer, artisan) segfaulted with exit 139. Web SAPI keeps opcache and JIT; only CLI runs without them, so one-shot tools work again.

---

## [1.0.1-nix] — 2026-08-11

### macOS & Linux (phpup.sh v1.0.1)

Patch release: Homebrew backend `fu` parity with the MacPorts numbered menu, formula-aware `u`/service management, and accurate PHP version reporting after a switch.

**Added**
- `fu` on the Homebrew backend now presents a numbered PHP version menu exactly like MacPorts: lists `php@X.Y` formulae, marks the active one `(current)`, and accepts a menu number, a dotted version (8.4), or a formula name (php@8.4) — validated against the actual formula list before any brew command runs
- `fu` guards against switching to the already-active PHP version — prints a clear message instead of reinstalling; invalid/out-of-range/unavailable input is rejected with "nothing was changed"
- `u` on Homebrew now confirms the active PHP is current within its version line (e.g. `PHP 8.4.24 (php@8.4) is up to date within its version line`) and, when a newer PHP line exists, hints `PHP 8.5 is available in Homebrew — use fu to switch PHP versions.` (shown as "also available" when updates are pending)
- `brew_active_php()` helper resolves the ACTIVE formula from the linked `bin/php` symlink — meta `php` or versioned `php@X.Y`

**Changed**
- `u` on Homebrew now checks/upgrades the ACTIVE PHP formula (via `brew_active_php()`) instead of the hardcoded meta `php` — after a `fu` switch to `php@8.4`, updates target `php@8.4`, not the unlinked meta
- `fu`, `start_services()` and `stop_services()` manage the ACTIVE php service (stop the current formula before switching, start the target after) instead of always `brew services ... php`
- `detect_php()` on Homebrew reports the version of the ACTIVE linked formula — after `fu` switched to `php@8.4`, the dashboard shows 8.4.24 instead of the meta formula's 8.5.9; falls back to the highest installed Cellar version when nothing is linked, and supports versioned-only installs (no meta `php`)
- `brew install`/`brew link` in `fu` stream live output and capture `$?` — a failed install is never reported as a successful switch

**Fixed**
- `current_php` detection in `fu` used a malformed PHP one-liner (escaped quotes) that failed under real php — `(current)` marker now resolves correctly

**Verified**
- Ad-hoc behavioral harness 21/21: menu render + current marker, number/dotted/formula input, guards, service stop/start formula-awareness, u hint in all four scenarios (older line + hint, newest line + no hint, updates + 'also', stale-global safety), detect_php active/fallback/no-php
- PTY boot smoke test: dashboard renders with correct active PHP version, clean `q` exit

## [1.0.0-nix] — 2026-08-11

### macOS & Linux (phpup.sh v1.0.0)

First stable release of the macOS and Linux backend. The `-beta` suffix is dropped — phpup.sh is now production-ready on all supported platforms.

**Added**
- `manage_path()` now self-heals `/etc/paths.d/macports` and prepends `/opt/local/bin` to the shell profile on the MacPorts backend — `php` and `mysql` resolve to MacPorts binaries instead of Apple's bundled versions
- `cmd_delete()` removes the phpup-added PATH lines from the shell profile on MacPorts so `D` restores the system default PATH
- Apache start check on MacPorts now retries for up to 10 seconds — eliminates false "may have failed" errors on slow VMs
- Comprehensive platform documentation: `docs/WINDOWS.md`, `docs/MACOS.md`, `docs/LINUX.md`, and updated `docs/INSTALL-OLDER-MAC.md`

**Changed**
- README.md restructured as a concise project overview — platform-specific setup details moved to dedicated OS documentation files
- README now links to [brew.sh](https://brew.sh), [macports.org](https://www.macports.org/), [Apache Lounge](https://www.apachelounge.com/download/), [windows.php.net](https://windows.php.net), [ondrej/php](https://deb.sury.org/), [mariadb.org](https://mariadb.org), and [phpmyadmin.net](https://www.phpmyadmin.net)
- `docs/INSTALL-OLDER-MAC.md` now links to [macports.org](https://www.macports.org/)
- macOS backend documentation split: `docs/MACOS.md` for the Homebrew path, `docs/INSTALL-OLDER-MAC.md` for the MacPorts path
- `PHPPUP_BACKEND` usage documented with examples in README and MACOS.md

**Fixed**
- `php -v` on fresh MacPorts installs now correctly resolves to the MacPorts PHP instead of Apple's bundled `/usr/bin/php` (macOS Catalina ships PHP 7.3.11)

**Verified**
- Full Phase 4 VM test pass (Catalina 10.15.5): install, update, delete, reinstall, restart, PHP version switch — all clean

## [0.11.0-beta-nix] — 2026-08-09

### macOS & Linux (phpup.sh v0.11.0-beta)

**Added**
- `check_prerequisites()` re-verifies Xcode Command Line Tools are actually installed after `xcode-select --install` — phpup now waits and rechecks before proceeding into source builds instead of trusting the prompt (never compiles without CLT)
- `cmd_delete()` prints an info note that the MacPorts build cache (`/opt/local/var/macports/software/`) survives delete — reinstalls and version switches reuse compiled archives instead of hours of recompiling (clear with `sudo port clean --all`)
- Screenshot-led install guide for older Intel Macs: `docs/INSTALL-OLDER-MAC.md` (Catalina → Ventura, MacPorts backend)

**Changed**
- `fu` (forced update / PHP version switch) on MacPorts now presents a numbered menu with full version strings, marks the current version, and accepts number, dotted version (8.4), or port name (php84) — validates against the actual port list before any sudo runs
- `fu` guards against reinstalling the already-active PHP version — prints a clear message and exits instead of a pointless recompile
- `configure_php_ports()` now uses the `PHP_PORT` variable (php84, php85) for config paths instead of `php -r` runtime detection — eliminates a dotted-version vs port-name mismatch that silently broke php.ini creation and extension scanning
- `port selfupdate`, `port upgrade outdated`, and `port -N install` now stream output live instead of `| tail -5` — users see build progress and `$?` captures the real exit status (eliminates the fragile `${PIPESTATUS[0]}` pattern)
- `detect_mariadb()` on MacPorts now uses the versioned client path (`/opt/local/lib/mariadb-12.3/bin/mariadb`) and parses the MacPorts `from X.Y.Z-MariaDB` version format (not brew's `Distrib X.Y.Z`) — dashboard shows the real MariaDB version instead of a blank row
- `configure_phpmyadmin_ports()` forces `$cfg['Servers'][1]['host'] = '127.0.0.1'` (TCP) and uses the versioned mysql client with a generic-path fallback — phpMyAdmin logs in over TCP instead of failing on the mismatched MacPorts socket path
- `fu`'s MacPorts PHP version list removes a redundant alpha/beta/rc version-filter — the port-name regex already excludes devel/pre-release ports; adds a guard for an empty version list with a hint to run Update

**Fixed**
- Apache `LoadModule` on MacPorts: `configure_apache_ports()` and `fu` wrote `phpXX_module`, but MacPorts' `mod_phpXX.so` exports the module struct as `php_module` (no version suffix) — Apache failed with "Can't locate API module structure". Both sites now write `php_module`; the dedup sed still strips legacy versioned lines
- MariaDB `my.cnf` on MacPorts: `log-error` was appended with no section header, but MySQL/MariaDB require every option under a `[group]` — MacPorts' my.cnf only has a comment + `!include`, so `[mysqld]` is now added first (guarded, idempotent)
- MariaDB error log path on MacPorts: `log-error` pointed at `~/phpup/logs` (user-owned) but mariadbd runs as `_mysql` — it aborted at startup with "Permission denied" and wrote no log. Now `/opt/local/var/log/<port>/mariadb_error.log` is created and chowned `_mysql`; `start_services()` failure-tail updated
- MariaDB service detection on MacPorts: phpup grepped `pgrep -x mariadbd`, but MacPorts' launchd startupitem runs the server as `mysqld` — MariaDB always appeared "failed to start"/"Stopped" even when running. `is_service_running()`, `start_services()` and `stop_services()` now match either process name (mariadbd for brew/apt, mysqld for MacPorts)
- Apache startup check on MacPorts: `port load apache2` can take longer than 1 second to actually spawn httpd on slow machines (e.g. virtualized Intel), so the single `sleep 1` + `pgrep` produced a false `[ERROR] Apache may have failed to start` even when Apache came up cleanly. `start_services()` now polls `pgrep -x httpd` for up to 10 seconds before declaring failure — parity with the MariaDB check
- MacPorts shell PATH: `manage_path()` trusted the MacPorts pkg installer to add `/opt/local/bin` to new login shells, but the paths.d entry was sometimes missing, and even when present it sits *after* `/usr/bin` — so Apple's bundled PHP (e.g. 7.3.11 on Catalina) shadowed the installed stack and `php -v` reported the wrong version. `manage_path()` now self-heals `/etc/paths.d/macports` when absent **and** prepends `/opt/local/bin:/opt/local/sbin` to the shell profile (the layer that actually wins over `/usr/bin`); `cmd_delete()` removes those lines again so `D` restores the original shell PATH. The PATH line is version-agnostic, so `fu`/`U` switches need no profile edits

**Verified**
- Catalina 10.15.5 VM test (fresh install, MacPorts 2.12.5): Apache 2.4.68 + PHP 8.5.9 + MariaDB 12.3.2 + phpMyAdmin 5.2.3 — phpinfo 200, PMA root/blank login works, storage DB (19 tables) configured
- Phase 4 lifecycle on the same VM: `fu` 8.5↔8.4 switch (one live LoadModule line), `U` update, `D` delete (datadir backup, www intact), `I` reinstall, `R` restart — all clean
- Shell PATH fix verified live on the guest: an interactive login shell resolves `php` → `/opt/local/bin/php` (8.5.9) instead of Apple's `/usr/bin/php` (7.3.11)
- All fixes regression-checked for the brew (macOS) and apt (Linux) backends — shared service-management functions match either process name without changing brew/apt behavior

---

## [0.10.0-beta-nix] — 2026-08-07

### macOS & Linux (phpup.sh v0.10.0-beta)

**Added**
- MacPorts backend (`port`) on Intel Macs — full install/update/restart/delete + PHP version switching
- Automatic backend selection: MacPorts when Homebrew is unavailable/unsupported on the macOS version or `PHPPUP_BACKEND=port` is set; Homebrew stays default on Apple Silicon and supported Intel macOS
- `install_macports()` bootstraps MacPorts 2.12.5 from the official .pkg installer (per-macOS-version URL map)
- `configure_apache_ports`, `configure_php_ports`, `configure_mariadb_ports`, `configure_phpmyadmin_ports` — mod_php (php85-apache2handler) + MariaDB 12.3 + phpMyAdmin tarball
- MariaDB root auth reset (unix_socket → mysql_native_password) and networking enabled for MacPorts MariaDB (skip-networking removed)
- PHP↔MariaDB socket wiring (`mysqli`/`pdo_mysql`/`mysql` default_socket) required by MacPorts layouts
- Dashboard shows `Package: port`; macOS < 10.15 prints an explicit end-of-life message instead of attempting a stack

**Changed**
- `detect_*` and service management understand the `/opt/local` layout (port load/unload/reload)
- `U` runs `port selfupdate` + `port upgrade outdated` on the ports backend
- `D` uninstalls ports leaf-first (no `port -y` dry-run trap) and cleans `/opt/local` runtime state after backing up the data dir
- `fu` switches PHP via `port select --set php`
- `install_pma_tarball()` takes a target directory (backend-specific: /usr/share, /opt/local/share, brew Cellar)
- macOS < 11 installs route through MacPorts with the existing source-compile warning; Catalina is the supported floor
- An existing Homebrew stack is never silently migrated to MacPorts — backend selection keeps brew when a brew stack is detected installed (even on macOS 11–13), and only routes to ports when no brew stack exists or `PHPPUP_BACKEND=port` is explicit

**Fixed**
- `fu` no longer corrupts httpd.conf on a failed PHP install — install failure is captured via `PIPESTATUS` and the LoadModule rewrite is gated on success; `php_ver` input is validated before any sudo'd sed
- Stale `LoadModule php*_module` lines are stripped before appending the current one — fu → D → I cycles leave exactly one live module line (no dead-module Apache crash)
- `mariadb-11.4` fallback persists across sessions — `detect_mariadb` self-heals by scanning for any installed `mariadb-1[12].*` datadir and adopting that series
- Q4 floor gate uses numeric version comparison (macOS 10.6–10.9 no longer slip past the end-of-life check)
- `U` reports update failure instead of a false "UPDATE COMPLETE!" banner on the ports backend
- phpMyAdmin storage DB rename now matches both SQL forms (backticked `` `phpmyadmin` `` and bare `USE phpmyadmin;`) — the import no longer aborts leaving an empty `pma` DB
- MariaDB 12.x does not auto-create users on `GRANT` — `CREATE USER IF NOT EXISTS 'pma'@'localhost'` added before the grant
- phpMyAdmin tmp-dir creation no longer silently lies on failure — if the web-server group can't be set, a warn with the exact sudo fix command is printed instead of a false OK (all three backends)
- `detect_mariadb` ports branch falls through to brew detection when no `/opt/local` datadir exists (mirrors `detect_apache`) — fixes mixed dashboard state when forcing `PHPPUP_BACKEND=port` on a brew machine
- The "keeping Homebrew backend" notice only prints when MacPorts migration was actually considered, not on every brew install

---

## [0.9.0-beta-nix] — 2026-08-07

### Linux (phpup.sh v0.9.0-beta)

**Added**
- Cross-series PHP upgrade detection in `U` (apt list won't flag 8.4→8.5 as different packages)
- `U` now installs stable PHP series only (alpha/beta/RC releases are skipped)
- Apache module auto-switch during cross-series PHP upgrades (a2dismod old, a2enmod new)
- MariaDB version cleaned on dashboard (`12.3.2+maria~deb13` → `12.3.2`)
- `U` cleans up stale `data_backup_pre_upgrade` after MariaDB upgrades
- Download cache path shown in Quick Info (matches Windows dashboard)

**Changed**
- Dashboard colours now match Windows: section headers are bold white, arrows are default (no cyan), Quick Info labels are default with cyan values
- `PHP-FPM` label changed to `PHP` with mode shown in status: `Active (mod_php)` or `Running (FPM)`
- Dashboard columns use fixed-width labels + consistent `----->` arrows for alignment
- `fu` simplified to PHP version switching only (`U` keeps everything else at latest)
- Removed `switch_maria_db_apt`, `switch_pma_apt`, `switch_apache_apt` (dead code)
- `apt_update_quiet` fully silenced (no more noise leaking through)
- `fu` skips per-component menu, goes straight to PHP version selector
- Date bumped to 2026-08-07

### Windows (phpup.ps1 v2.2.3)

**Added**
- Architecture / OS line on dashboard (`Architecture: x86_64 | OS: Windows 11 Pro`) matching Linux format

---

## [0.8.0-beta-nix] — 2026-08-06

### Linux (phpup.sh v0.8.0-beta)

**Added**
- Fresh installs now get the latest phpMyAdmin via tarball from phpmyadmin.net (replaces apt package)
- Fresh installs add the official MariaDB.org repo for latest MariaDB (e.g. 12.3 on Debian)
- `U` (update) now checks for newer phpMyAdmin tarball versions

**Changed**
- `detect_phpmyadmin` on apt: checks for tarball install first, falls back to dpkg
- `configure_phpmyadmin_apt`: no longer requires apt package config file
- `cmd_delete`: removes phpMyAdmin tarball install, drops `phpmyadmin` from apt removal list

---

## [0.7.3-beta-nix] — 2026-08-06

### Linux (phpup.sh v0.7.3-beta)

**Fixed**
- `fu` meta sync: suppressed "Skipping X, it is not installed" noise when metas aren't installed (versioned-only systems)

---

## [0.7.2-beta-nix] — 2026-08-04

### Linux (phpup.sh v0.7.2-beta)

**Added**
- Fresh Linux installs now install the latest stable PHP (e.g. 8.5) — ondrej/php (deb.sury.org) repo auto-added, versioned packages installed, Apache module + CLI alternative activated
- Complete MariaDB data backup before delete on apt (sudo cp — datadir is 700 mysql:mysql)
- Delete on apt preserves configs in /etc (apt remove keeps conffiles — no config backup needed on Linux)

**Fixed**
- phpMyAdmin storage database (`pma`) + control user now created explicitly on apt — dbconfig-common skips DB creation under noninteractive, leaving a dead controluser reference
- Restore of user databases now runs BEFORE phpMyAdmin config — the restore previously wiped the freshly-created control DB
- Duplicate stock `phpmyadmin` control database (restored from pre-rename backups) now dropped during configure — guarded to never touch a DB with user data
- apt "WARNING: apt does not have a stable CLI interface" noise suppressed in update/install/fu flows

---

## [0.6.2-beta-nix] — 2026-08-04

### Linux (phpup.sh v0.6.2-beta)

**Added**
- `fu` (forced update) now works on apt: adds the ondrej/php repository (deb.sury.org), lists PHP versions 8.2 → latest with `(active)`/`(installed)` tags, numbered selection, installs versioned packages, switches the Apache module + CLI alternative, re-applies PHP config and restarts Apache
- Previous PHP version stays installed after switching — switch back anytime with another `fu`
- PHP meta packages synced to the repo's versions on every `fu` run so `U` doesn't list them

**Fixed**
- Version list colour tags rendered as literal `\033` text (now `%b` in printf)
- Dashboard showed `OS: Linux unknown` on minimal Debian (no lsb_release) — now falls back to `/etc/os-release` and shows the distro name (`OS: Debian 13`, `OS: Ubuntu 24.04`)
- phpMyAdmin alias now active immediately after install (Apache reloaded after `a2enconf`)

---

## 2.2.2-win / [0.5.11-beta-nix] — 2026-08-01

### Linux (phpup.sh v0.5.11-beta)

**Added**
- Apache `<Directory>` grant for custom DocumentRoot (default Ubuntu policy denies non-`/var/www` paths)
- phpMyAdmin Apache alias auto-creation (`/etc/apache2/conf-available/phpmyadmin.conf`)
- phpMyAdmin conf.d override system (`/etc/phpmyadmin/conf.d/phpup.php`) — works across all versions without fragile sed
- Home directory traversal fix (`chmod o+x "$HOME"`) — allows `www-data` to reach `~/phpup/www`
- `DEBIAN_FRONTEND=noninteractive` on all apt install commands — suppresses debconf prompts (phpMyAdmin password popup)

**Changed**
- Linux platform status: 🧪 Untested → ✅ Stable (Ubuntu/WSL)
- Service status colours: Running = Green, Stopped = Red, Not available = Red
- PHP-FPM dashboard: now shows "Active (mod_php)" when using `libapache2-mod-php` (apt default)
- Quit command uses `return` instead of `exit` — no longer closes the terminal when script is sourced

**Fixed**
- Removed non-existent `php-sodium` from apt package lists (sodium is built into PHP core)
- MariaDB root auth plugin: switched from `unix_socket` to `mysql_native_password` for phpMyAdmin TCP login
- phpMyAdmin `AllowNoPassword` now iterates all servers (was targeting stale `$i` index)
- Suppressed apt "N packages can be upgraded" noise in update checks

---

## 2.2.2-win / [0.4.8-beta-nix] — 2026-07-30

### Windows (phpup.ps1 v2.2.2)

**Changed**
- Banner "phpup" text colour Cyan → Blue (matches colour spec: arrows Yellow/Green/Cyan, text Blue)

### macOS (phpup.sh v0.4.8-beta)

**Added**
- Service start health checks — MariaDB and PHP-FPM verify startup with `pgrep` retry loops (5s timeout)
- Full phpMyAdmin storage database setup (`pma` database with 18 configuration tables)
- `pma@localhost` database user for PMA storage tables
- macOS version check on install — warns pre-Big Sur users that PHP compiles from source
- `sudo -v` at install start to establish credential timeout upfront

**Changed**
- Banner arrows now coloured (Yellow/Green/Cyan) and "phpup" in Blue — matches Windows
- Dashboard version numbers and status indicators now use colour (Green for installed/running)
- PMA config directives (`VersionCheck`, `SendErrorReports`, `LoginCookieValidity`, `TempDir`) now use append-if-missing — handles brew configs that omit these directives
- Apache PHP module loading guarded by `libphp.so` existence check
- Configure functions bail early if component not detected
- `brew update` suppressed during update checks (less noise)
- `HOMEBREW_NO_ENV_HINTS=1` on all brew installs — suppresses Caveats output
- `brew link --overwrite --force phpmyadmin` after install — fixes stale Cellar linking
- Delete confirmation lists preserved paths with colour-coding

**Fixed**
- MariaDB socket authentication now reset to native password — brew 12.3.2 defaults to `unix_socket` which blocks PHP/PMA access
- Service stop now kills processes with `pkill` after `brew services stop` — ensures actual termination
- Apache stop only runs when service is detected running (no more "not running" noise)
- PMA blowfish secret regex now handles brew's trailing comment after `'';`
- Document root permissions use `sudo sh -c` single invocation instead of separate sudo calls
- Delete now force-uninstalls lingering Cellar kegs (PMA twig cache owned by `_www` blocks `rm -rf`)
- Delete removes stale LaunchAgent plists and MariaDB data directory
- Delete warns about remaining Cellar skeletons
- `detect_all` called after service toggle — dashboard reflects actual state

**Removed**
- Config backup/restore on delete (brew preserves configs natively)
- Offline/cache info from main loop

### Linux (phpup.sh v0.4.8-beta)

**Added**
- Service start health checks — Apache, MariaDB, PHP-FPM verified after start
- Full phpMyAdmin storage database setup

**Changed**
- Dashboard version numbers and status indicators now coloured
- PMA config directives use append-if-missing pattern
- Configure functions bail early if component not detected
- `brew update` suppressed (n/a on apt but code path shared)

**Fixed**
- PMA config `sed` escaping corrected for `sudo` context (extra backslash layers)
- Service stop now more aggressive — ensures all processes terminate
- Delete removes logs directory

---

## [2.2.1-win] / [1.1.1-nix] — 2026-07-26

### Windows (phpup.ps1 v2.2.1)

**Added**
- Upload limits: `upload_max_filesize=50M`, `post_max_size=55M`, `max_execution_time=300`, `max_input_time=300`
- `session.gc_maxlifetime=14400` in php.ini (matches PMA `LoginCookieValidity`)

**Changed**
- PMA config: `ShowStats=false`, `LoginCookieValidity=14400`, `SendErrorReports=never`, `VersionCheck=false`

**Fixed**
- PMA storage database name corrected to `pma` (was `phpmyadmin`)
- `ShowStats` directive name (was incorrectly `ShowDbStats` in earlier attempts)
- `TempDir` created with correct group ownership for template cache

### macOS & Linux (phpup.sh v1.1.1)

**Added**
- `session.gc_maxlifetime=14400` in php.ini

**Changed**
- PMA config: `ShowStats`, `LoginCookieValidity`, `SendErrorReports`, `VersionCheck`
- PMA tmp directory created with `chgrp` for web server user

**Fixed**
- PMA `ShowStats` directive name corrected

---

## [2.2.0-win] / [1.1.0-nix] — 2026-07-25

### Windows (phpup.ps1 v2.2.0)

**Added**
- Upload limits: 50 MB files, 300s timeout (for large PMA imports)
- Config backup/restore on delete — preserves httpd.conf, php.ini, my.ini, config.inc.php
- `config_backup/` directory in delete preserved paths

**Changed**
- `Save-PostUpdateConfig` now detects all versions from live filesystem (self-healing)
- Forced update (`fu`) summary shows all cached versions per component
- ICU DLLs discovered dynamically (no hardcoded versions — survives PHP version switches)

**Fixed**
- `$env:VAR` interpolation for literal paths (`C:\phpup` — not `$env:c`)
- Save-Config no longer wipes version data on toggle/register/install-path changes
- Install-AsServices no longer stops services before registering when nothing is running
- NTS PHP builds excluded from forced update selection with cyan info message

### macOS & Linux (phpup.sh v1.1.0)

**Added**
- PHP upload limits: `upload_max_filesize=50M`, `post_max_size=55M`, `max_execution_time=300`, `max_input_time=300`

---

## [2.1.1-win] — 2026-07-05

### Windows (phpup.ps1 v2.1.1)

**Added**
- PowerShell alias installation instructions in README Quick Start

**Changed**
- VC++ section header suppressed when prerequisite already met (cleaner dashboard)

---

## [2.1.0-win] — 2026-07-05

### Windows (phpup.ps1 v2.1.0)

**Changed**
- `S` and `T` commands merged into a single `S` toggle (four-state: start/stop × registered/process)
- Dashboard sections reordered: Prerequisites → Stack → Process Status → Services → Info → Commands
- "Service Status" renamed to "Process Status" to disambiguate from "Windows Services"

**Fixed**
- VC++ section header hidden when already installed
- Dashboard Info block labels aligned at 30-character column

---

## [2.0.0-win] — 2026-06-28

### Windows (phpup.ps1 v2.0.0)

**Changed**
- **Rebranded from getPHP to phpup** — new identity, new repo (`DaFa66/phpup`)
- Default install path: `C:\phpup` (was `C:\getphp`)
- Service names: `phpup_Apache`, `phpup_MariaDB` (was `getPHP_Apache`, `getPHP_MariaDB`)
- Download cache: `C:\phpup\downloads\` (was `%TEMP%\webstack_downloads` — no longer cleaned by Disk Cleanup)
- phpMyAdmin at stack root: `C:\phpup\phpmyadmin\` (was under `www\`)
- Config file: `%APPDATA%\phpup\config.json`

**Fixed**
- Apache Lounge fallback URL updated to current build
- Banner phpup text aligned with arrows
- Cyan border bleed in multi-colour banner rendering

---

## [1.0.6-win] — 2026-06-20

### Windows (getphp.ps1 v1.0.6)

**Changed**
- "pro" tag added to ASCII banner
- Banner removed from VC++ prerequisite check (cleaner output)

**Fixed**
- `#Requires -RunAsAdministrator` removed — custom admin check with friendly message now works
- `Get-VersionFromZipName` PHP regex handles RC releases (e.g. `php-8.5.8RC1-Win32-vs17-x64.zip`)

---

## [1.0.5-win] — 2026-06-16

### Windows (getphp.ps1 v1.0.5)

**Added**
- Forced update (`fu`) — offline version switching from cached zips
- Multi-version selection per component with colour-coded tags (current/newer/older)
- `Get-VersionFromZipName` with 3-part version normalisation
- `Backup-MariaDbData` and `Restore-MariaDbData` shared helpers
- Database backup during updates (`data_backup_update/`)

**Fixed**
- NTS PHP builds excluded from forced update (incompatible with Apache)
- phpMyAdmin snapshot filename regex (handles `+snapshot` suffix)
- PHP prerelease filename regex (handles `RC1`, `alpha2`, `beta1` without dash separator)
- Empty cache fallback uses `Write-Info` (cyan) instead of `Write-Err` (red)

---

## [1.0.4-win] — 2026-06-14

### Windows (getphp.ps1 v1.0.4)

**Added**
- Sodium PHP extension enabled
- `-Offline` switch — installs from cached zips only, no network
- `Invoke-ExtractZip` — offline zip extractor with wrapper flattening

**Changed**
- Extraction skip logic: only skips when destination already populated AND using cached zip

**Fixed**
- `Invoke-ExtractZip` handles multi-file zips with known wrapper patterns (Apache Lounge, PHP, MariaDB)
- Progress bars suppressed during bulk file flattening (preserves download progress)

---

## [1.0.3-win] — 2026-06-13

### Windows (getphp.ps1 v1.0.3)

**Added**
- Downloaded zip caching in `%TEMP%\webstack_downloads` for reuse on reinstall
- PHP fallback URL
- VC++ installer cached (not deleted after use)
- SQLite3 DLL zip cached in download directory

**Changed**
- VC++ redistributable URL standardised to `aka.ms/vc14/vc_redist.x64.exe`
- Service registration de-duplicated — routes through `Install-AsServices`
- Logs consolidated to `C:\getphp\logs\`

**Fixed**
- Logs directory removed on delete
- phpMyAdmin zip extracted in offline mode
- MariaDB download uses archive URL (not REST API redirector)

---

## [1.0.2-win] — 2026-06-08

### Windows (getphp.ps1 v1.0.2)

**Added**
- PHP JIT compilation enabled (tracing JIT, 100 MB buffer)
- OPCache enabled for CLI (JIT requirement)
- Service registration state persisted in config.json
- Dashboard "Windows Services" section showing registration status
- ARM64/ARM CPU architectures blocked at startup

**Changed**
- VC++ prerequisite check is now blocking (minimum version 14.51.36231 required)
- CPU architecture detection uses `PROCESSOR_ARCHITECTURE` env var (not .NET API)
- Asset resolution hardened — fallback URLs, retry logic, offline mode

**Fixed**
- JIT directives appended when absent from default php.ini
- MariaDB download retry on failure
- Config serialization for complex objects

---

## [1.0.1-win] — 2026-06-06

### Windows (getphp.ps1 v1.0.1)

**Added**
- Smart update — checks all components for newer versions, updates selectively
- Optional Windows service registration for auto-start on boot
- `data_backup/` preservation on delete with restore offer on reinstall
- Delete output cleaned up — no duplicate stop banner or service warnings

**Changed**
- Shared helper functions extracted and consolidated
- Constants consolidated at script top

**Fixed**
- `Get-Service` null reference when service doesn't exist
- CPU architecture check uses .NET API for robustness
- Pre-existing `data_backup` on delete handled gracefully (archived with timestamp)

---

## [1.0.0-win] — 2026-06-05

### Windows (getphp.ps1 v1.0.0)

**Added**
- Initial PowerShell release
- Apache, PHP, MariaDB, phpMyAdmin install/update/delete
- Interactive dashboard with command menu (I, U, S, T, R, D, Q)
- VC++ Redistributable auto-check and install
- Config persistence (`%APPDATA%\getphp\config.json`)
- PATH management for PHP and MariaDB CLI tools
- phpMyAdmin version detection
- Database backup on delete (`data_backup/`)

---

## Pre-fork History — getphp.sh (Mac)

*The original `getphp.sh` was created by Balázs Zatik for the [getphp.org](https://getphp.org) project. phpup's Mac/Linux script began as a fork of this work.*

### macOS (getphp.sh — Balázs Zatik, 2026-03-26 to 2026-07-19)

- Initial ZAMPP Dashboard (v1.0.0, 2026-03-26)
- Homebrew-based Apache, PHP, MariaDB, phpMyAdmin install
- Interactive dashboard with service management
- Linux compatibility (Ubuntu, Debian, Mint) via Homebrew on Linux
- Delete with confirmation prompt
- Platform detection and Homebrew PATH management

*phpup forked from upstream on 2026-07-19, adding native apt support for Linux, service hardening, and extensive configuration fixes.*

---

## Version History Summary

### Windows (phpup.ps1)

| Version | Date | Key Changes |
|---------|------|-------------|
| [**2.4.1-win**](#241-win--2026-08-18) | 2026-08-18 | fu phpMyAdmin Alias fix, Directory self-heal |
| [**2.4.0-win**](#240-win--2026-08-17) | 2026-08-17 | fu series management, variants, pre-release labels |
| [**2.3.0-win**](#230-win--2026-08-17) | 2026-08-17 | Soft ARM64 (Prism), VC++ arch-aware |
| [**2.2.4-win**](#224-win--2026-08-17) | 2026-08-17 | opcache CLI off — phar tools segfault fix |
| **2.2.2-win** | 2026-07-27 | Banner colour fix |
| [**2.2.1-win**](#221-win--111-nix--2026-07-26) | 2026-07-26 | PMA config, upload limits, session lifetime |
| [**2.2.0-win**](#220-win--110-nix--2026-07-25) | 2026-07-25 | Forced update, config persistence, upload limits |
| [**2.1.1-win**](#211-win--2026-07-05) | 2026-07-05 | PowerShell alias, VC++ section fix |
| [**2.1.0-win**](#210-win--2026-07-05) | 2026-07-05 | S+T toggle merge, dashboard reorder |
| [**2.0.0-win**](#200-win--2026-06-28) | 2026-06-28 | Rebrand to phpup |
| [**1.0.6-win**](#106-win--2026-06-20) | 2026-06-20 | RC regex, admin message fix |
| [**1.0.5-win**](#105-win--2026-06-16) | 2026-06-16 | Forced update (`fu`) |
| [**1.0.4-win**](#104-win--2026-06-14) | 2026-06-14 | Sodium, offline switch, extraction fixes |
| [**1.0.3-win**](#103-win--2026-06-13) | 2026-06-13 | Zip caching, MariaDB fixes, log consolidation |
| [**1.0.2-win**](#102-win--2026-06-08) | 2026-06-08 | JIT, fallback URLs, service registration |
| [**1.0.1-win**](#101-win--2026-06-06) | 2026-06-06 | Smart update, service registration |
| [**1.0.0-win**](#100-win--2026-06-05) | 2026-06-05 | Initial release |

### Mac & Linux (phpup.sh)

| Version | Date | Key Changes |
|---------|------|-------------|
| [**1.0.2-nix**](#102-nix--2026-08-21) | 2026-08-21 | Dual-stack machine fixes, stack-aware services, PMA blowfish |
| [**1.0.1-nix**](#101-nix--2026-08-11) | 2026-08-11 | Homebrew `fu` numbered menu, formula-aware `u` |
| [**1.0.0-nix**](#100-nix--2026-08-11) | 2026-08-11 | First stable, MacPorts backend |
| [**0.11.0-beta-nix**](#0110-beta-nix--2026-08-09) | 2026-08-09 | MacPorts hardening, Apache LoadModule fix |
| [**0.10.0-beta-nix**](#0100-beta-nix--2026-08-07) | 2026-08-07 | MacPorts backend for older Intel Macs |
| [**0.9.0-beta-nix**](#090-beta-nix--2026-08-07) | 2026-08-07 | Cross-series PHP upgrade, dashboard parity |
| [**0.8.0-beta-nix**](#080-beta-nix--2026-08-06) | 2026-08-06 | pma tarball, MariaDB.org repo |
| [**0.7.3-beta-nix**](#073-beta-nix--2026-08-06) | 2026-08-06 | Suppress meta sync noise in `fu` |
| [**0.7.2-beta-nix**](#072-beta-nix--2026-08-04) | 2026-08-04 | Latest PHP on fresh installs, pma control DB fix |
| [**0.6.2-beta-nix**](#062-beta-nix--2026-08-04) | 2026-08-04 | `fu` PHP version switching on apt |
| **0.5.11-beta-nix** | 2026-08-01 | First Linux apt support |
| **0.4.8-beta-nix** | 2026-07-30 | Service overhaul, PMA storage, delete hardening |
| [**1.1.1-nix**](#221-win--111-nix--2026-07-26) | 2026-07-26 | PMA config, session lifetime |
| [**1.1.0-nix**](#220-win--110-nix--2026-07-25) | 2026-07-25 | PHP upload limits |
| **1.0.0-nix** | 2026-07-19 | Initial phpup fork — native apt, 19 fixes |

[1.0.1-nix]: https://github.com/DaFa66/phpup/releases/tag/v1.0.0-nix
[1.0.0-nix]: https://github.com/DaFa66/phpup/releases/tag/v1.0.0-nix
[0.11.0-beta-nix]: https://github.com/DaFa66/phpup/releases/tag/v0.9.0-beta-nix
[0.10.0-beta-nix]: https://github.com/DaFa66/phpup/releases/tag/v0.9.0-beta-nix
[0.9.0-beta-nix]: https://github.com/DaFa66/phpup/releases/tag/v0.9.0-beta-nix
[0.8.0-beta-nix]: https://github.com/DaFa66/phpup/releases/tag/v0.9.0-beta-nix
[0.7.3-beta-nix]: https://github.com/DaFa66/phpup/releases/tag/v0.9.0-beta-nix
[0.7.2-beta-nix]: https://github.com/DaFa66/phpup/releases/tag/v0.9.0-beta-nix
[0.6.2-beta-nix]: https://github.com/DaFa66/phpup/releases/tag/v0.9.0-beta-nix
[0.5.11-beta-nix]: https://github.com/DaFa66/phpup/releases/tag/v0.9.0-beta-nix
[0.4.8-beta-nix]: https://github.com/DaFa66/phpup/releases/tag/v0.9.0-beta-nix
[2.2.2-win]: https://github.com/DaFa66/phpup/releases/tag/v2.2.0-win
[2.2.1-win]: https://github.com/DaFa66/phpup/releases/tag/v2.2.0-win
[2.2.0-win]: https://github.com/DaFa66/phpup/releases/tag/v2.2.0-win
[1.1.1-nix]: https://github.com/DaFa66/phpup/releases/tag/v1.1.0-nix
[1.1.0-nix]: https://github.com/DaFa66/phpup/releases/tag/v1.1.0-nix
[2.1.1-win]: https://github.com/DaFa66/phpup/releases/tag/v2.0.0-win
[2.1.0-win]: https://github.com/DaFa66/phpup/releases/tag/v2.0.0-win
[2.0.0-win]: https://github.com/DaFa66/phpup/releases/tag/v2.0.0-win
[1.0.6-win]: https://github.com/DaFa66/phpup/releases/tag/v1.0.0-win
[1.0.5-win]: https://github.com/DaFa66/phpup/releases/tag/v1.0.0-win
[1.0.4-win]: https://github.com/DaFa66/phpup/releases/tag/v1.0.0-win
[1.0.3-win]: https://github.com/DaFa66/phpup/releases/tag/v1.0.0-win
[1.0.2-win]: https://github.com/DaFa66/phpup/releases/tag/v1.0.0-win
[1.0.1-win]: https://github.com/DaFa66/phpup/releases/tag/v1.0.0-win
[1.0.0-win]: https://github.com/DaFa66/phpup/releases/tag/v1.0.0-win
