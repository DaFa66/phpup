# Changelog

All notable changes to phpup will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

Versions for `phpup.ps1` (Windows) and `phpup.sh` (Mac/Linux) are tracked independently
using platform suffixes: **`-win`** for Windows, **`-nix`** for macOS and Linux.

The last digit is a patch: fixes, corrections and small behaviour changes release as
`x.y.z` → `x.y.z+1`. The middle digit is reserved for a feature milestone, so it only
moves when a release genuinely adds a capability worth calling out. Both scripts move
together, keeping their own numbering.

Jump to the [Version History Summary](#version-history-summary) table for a quick
overview of every release.

---

## [2.5.6-win] / [1.3.5-nix] — 2026-11-27

### Windows (phpup.ps1 v2.5.6) and macOS/Linux (phpup.sh v1.3.5)

*Previous platform update: [2.5.5-win] / [1.3.4-nix](#255-win--134-nix--2026-11-22).*

A failed MariaDB update can no longer take the stack down with it, and a MacPorts install
now follows the ports tree to the newest series instead of freezing on the one that was
current when it was installed.

### Fixed — stack updates (Windows)

- **`u` no longer removes a component before it has the replacement.** Every needed zip is
  downloaded into `downloads\` first, and the run stops with `Nothing has been changed` if a
  download fails or arrives under 1 MB. The old order deleted the install first, so a failed
  download left the component gone: the MariaDB 13.1 update removed `mariadb\` and left the
  databases in `data_backup_update`.
- **The MariaDB archive URL is built from the full release, not the series.** The REST API
  reports `release_id` as a series (`13.1`) while the individual builds are the keys of
  `releases` (`13.1.2`), and `archive.mariadb.org` is keyed by the build, so the series-based
  path 404'd. `Test-UrlAvailable` now cuts a HEAD (then one-byte GET) probe and falls through
  to the next build when one is unavailable.
- **MariaDB databases are restored even when the extract fails** — the restore moved into a
  `finally`, so data cannot be stranded in `data_backup_update`.
- **`$FALLBACK_URLS` tracks the stack again:** Apache `2.4.69-261002` → `2.4.71-261112`,
  PHP `8.5.12-1-vs17` → `8.6.0-vs18`, MariaDB `13.0.2` → `13.1.2`. The block now carries a
  note to bump all four whenever a component release moves.

### Fixed — MacPorts series tracking (macOS)

- **`u` moves to a newer series, not just a newer patch.** `port upgrade outdated` only
  upgrades ports that are already installed, and the port name carries the series
  (`php85` → `php86`, `mariadb-12.3` → `mariadb-13.1`), so a Mac stayed on whatever was
  newest when the stack was installed — this one was on MariaDB 12.3 with 13.1 released.
  Update asks the ports tree for the newest series, lists it as
  `PHP php85 → php86 (newer series)`, and moves on confirmation.
- **The MariaDB move is dump → install → init → restore, and the old series is left
  installed.** Each series owns its own datadir, so nothing old is touched: the dump goes to
  `~/phpup/dumps/<port>-<timestamp>.sql`, and a failed install or restore leaves the old
  server serving.
- **A fresh MacPorts install targets the newest series in the tree** instead of the pinned
  `php85` / `mariadb-12.3` defaults, which are now only a fallback for when `port search`
  cannot answer.
- **MariaDB's own Stable list decides, not the tree alone.** A ports tree can carry a
  release-candidate series (`mariadb-13.2` while 13.2 is an RC), so the pick defers to the
  REST API's Stable series when it answers, and to the tree when it cannot.
- **The MariaDB datadir sniff only matched `mariadb-1[12].*`**, so a 13.x datadir was
  invisible to the pre-1.1.0 config migration. It matches any series now.
- **The cached `PORTS_MARIADB_*` paths are gone.** They were computed once at load and never
  refreshed when `MARIADB_PORT` changed mid-run; paths are derived from it at each use.

### Added (tests)

- `tests/harness-mariadb-url.ps1` — offline regression test for the MariaDB archive path
  (build-based URL, series-only path rejected, fall-through when a build is unavailable),
  wired into `tests/run-all.ps1`.
- **`B` backs up the databases and the users as one portable file — on both platforms.**
  Every database plus
  every account and grant is written to `~/phpup/dumps/phpup-backup-<version>-<timestamp>.sql`.
  Users are captured as `CREATE USER`/`GRANT` statements rather than raw `mysql` table rows,
  so the file restores into a different MariaDB series — which is what a series move or a
  backend switch does. The dump uses the active backend's own client, so a neighbour stack's
  server is never the one being read.
- **`phpup backup` is a CLI verb on both platforms.** The dashboard's `B` key as a
  non-interactive command: writes the dump, prints its path, and accepts `--json` for the
  path, MariaDB version, database, user and grant counts, and byte size. Stream discipline
  and exit codes follow the existing contract (`0` written, `1` failed or MariaDB stopped,
  `3` not installed, `2` for `--fast`/`--watch`, which it does not accept). `--quiet` is
  silent, so `f=$(phpup backup --quiet)` works in a script.
- **Install and Update offer to restore the newest portable backup.** After the stack comes
  up, phpup looks for the newest `phpup-backup-*.sql` in `~/phpup/dumps/`, names its date and
  how many databases and users it holds, and asks before restoring anything. It asks once per
  file, never offers a dump that the current stack made itself, and restores with
  `CREATE USER IF NOT EXISTS` so the accounts the fresh server already has do not abort the
  run. This is the step people skip when moving from Homebrew to MacPorts, and it turns a
  four-step manual migration into three keystrokes and one `y`.
- `tests/harness-backup.sh` / `tests/harness-backup.ps1` — the dump binary follows the active
  backend on macOS/Linux (ports series path, both fallbacks), the dump stays portable (users as
  SQL, no raw grant tables), and the command refuses when the database is down. Wired into
  `tests/run-all.sh` and `tests/run-all.ps1`.
- **phpMyAdmin's storage wiring on MacPorts now names every table, and the control
  user is created on every run.** The override only ever wrote `pmadb`, so phpMyAdmin
  reported "configuration storage is not completely configured" and left relation
  features disabled — and because that block was appended only when `pmadb` was
  absent, the missing lines could never be added afterwards. The control user is also
  created outside the "schema missing" branch: a restored `pma` schema can outlive the
  `pma` account, which is exactly what a MariaDB series move leaves behind, and the
  failure used to be swallowed. The account is now verified over TCP, the way
  phpMyAdmin uses it, and a failure is reported.
- **A MacPorts series move now carries the accounts, not just the schemas.** The
  pre-move dump runs with `--system=users`, so user accounts and grants travel with
  the databases; the restore rewrites `CREATE USER` to `CREATE USER IF NOT EXISTS`
  because the freshly initialised datadir already holds `root@localhost` and a plain
  `CREATE USER` aborts the whole restore at the first duplicate. When there are no
  user databases, the accounts are still saved to their own file.
- **The MariaDB data directory probes run under `sudo`.** `/opt/local/var/db/<series>/mysql`
  is `0700 _mysql`, so an unprivileged `ls` answered "permission denied" — an empty
  result that read as "not initialised", printed "manual init required" after a
  successful init, and worse, treated a populated datadir as safe to wipe. Emptiness
  now only counts when `sudo` could actually list the directory.
- `tests/harness-ports-series.sh` — offline regression test for the MacPorts series helpers
  (newest phpNN / mariadb series from a stubbed tree, the Stable-list preference, the
  installed-ports fallback, series comparison and arithmetic), wired into `tests/run-all.sh`.

### Docs

- Version sweep across `README.md`, `docs/WINDOWS.md`, `docs/CLI.md`, `docs/LINUX.md`,
  `docs/INSTALL-OLDER-MAC.md`, `docs/PANEL-PLATFORMS.md` and `panel/README.md`: PHP 8.5 →
  8.6.0, Apache 2.4.68/2.4.69 → 2.4.71, MariaDB 12.3/13.0 → 13.1.2, panel 0.2.1 → 0.2.2
  (download link, zip name and tag), and the MacPorts `php85` / `mariadb-12.3` examples →
  `php86` / `mariadb-13.1`.
- `docs/WINDOWS.md`: the `php_min_series` paragraph no longer calls
  `%APPDATA%\phpup\config.json` the config — it lives in `config.json` in the stack folder
  (`C:\phpup\config.json`), and `%APPDATA%` holds only the discovery pointer for a moved
  install.
- `docs/MACOS.md` and `docs/INSTALL-OLDER-MAC.md` describe the MacPorts series tracking:
  `U` lists `php85 → php86 (newer series)`, MariaDB moves by dump and restore, and the old
  series stays installed. The MacPorts log path is quoted as
  `/opt/local/var/log/mariadb-<series>` rather than a fixed 12.3.
- Version stamps follow the release: `2.5.6-win` / `1.3.5-nix` in the headers, `VERSION_CACHE`,
  `PHPUP_VERSION`, `docs/CLI.md`, `panel/README.md` and this file's summary table.

## [panel 0.2.2-beta-win] — 2026-11-23

### Windows panel (Rust + egui, 0.2.2 beta)

*Previous panel update: [panel 0.2.1-beta](#panel-021-beta-win--2026-11-22).*

The window can no longer reopen somewhere it cannot be seen.

### Fixed

- **A remembered window position is checked against the monitors before it is honoured.**
  Dragging the panel towards another screen could leave `panel.json` holding an x beyond the
  edge of the leftmost monitor — `x: -4719` with that screen starting at `-2560` — and every
  launch after it drew the window where nothing could be clicked: the process was running,
  the tray icon was there, and the panel was invisible. Restoring a position now asks Windows
  (`MonitorFromRect` with `MONITOR_DEFAULTTONULL`) whether any part of the window lands on a
  screen, and requires at least a 120×120 corner of it to be there. If not, the position is
  dropped and Windows places the window itself.
- **A position that cannot be found again is never recorded.** The geometry mirror writes x/y
  only while the window is reachable, so a drag that ends past the edge leaves the previous
  good position on disk instead of making the next launch invisible.

## [2.5.5-win] / [1.3.4-nix] — 2026-11-22

### Windows (phpup.ps1 v2.5.5) and macOS/Linux (phpup.sh v1.3.4)

*Previous platform update: [2.5.4-win] / [1.3.3-nix](#254-win--133-nix--2026-11-21).*

The handover now refuses rather than half-committing, and process ownership no longer
reaches for WMI on the path that polls.

### Fixed

- **A handover can no longer leave phpup disabled with nothing recording why.** On
  Windows, `Get-ServiceStartType` swallowed a failed `sc.exe qc` and returned `$null`,
  which flowed into the saved handover record; the restore step then saw an empty value
  and restored nothing. The switch now refuses before it stops anything:
  `Could not read the current start type of phpup_Apache (sc.exe qc failed), so it could
  not be restored afterwards. Nothing was changed.`
- **`Set-ServiceStartType … 'disabled'` was called with its verified read-back discarded**,
  so a refused `sc.exe config` still reported a successful handover and a reboot brought
  phpup's stack back alongside the one holding the ports. The disable is now checked; on
  failure every start type that did change is put back and the switch is refused.
- **The same failure on macOS/Linux was silent.** `sudo systemctl disable … || true` made
  a refused disable look like success. The result is read back with `systemctl is-enabled`
  and reported in the payload warnings: `apache2 is still enabled at boot; it may start on
  the next reboot and take the ports back.`
- **A failed registry write was reported as a successful switch.** `switch --add` printed
  `Registered xampp at D:\xampp` and exited 0 whatever the write did, and the handover
  wrote the registry and then disabled phpup's own services without looking. Both now stop
  with `action_failed` before anything is changed.
- **`Get-ProcessExePath` called `Get-CimInstance Win32_Process` on the polling path**, for
  every listener whose `ExecutablePath` came back empty. Behind a security filter driver
  that call can block indefinitely, which is how a `status --watch` poll wedged and a
  scheduled task stacked up behind it. It now uses kernel32
  `QueryFullProcessImageNameW` with a PID + start-time cache, and reaches for CIM only
  when nothing else answers.
- **`--to <alias>` picked the first registered match when two roots shared a name.**
  `C:\xampp` and `D:\xampp` are both `xampp`; the switch could hand the ports to one and
  then refuse to take them back. The payload now carries `active_path`, and an ambiguous
  alias is refused with `'xampp' matches 2 registered stacks: D:\xampp, C:\xampp. Pass
  --path to say which one.`

### Added

- **`switch --remove`** — unregister a stack. It refuses while that root holds the ports:
  `C:\xampp holds the ports right now; run switch --to phpup first, then remove it.`
- **`active_path`** in the switch payload, so a caller knows which root holds the ports
  rather than which one happens to be first in the registry.
- **A PATH note** after a successful handover, naming the foreign stack's binaries, because
  `php -v` in a fresh shell still answers with phpup's: `PATH still resolves php and mysql
  to phpup; use D:\xampp\php\php.exe and D:\xampp\mysql\bin\mysql.exe while
  D:\xampp holds the ports.`

### Changed

- **One config write per handover.** The `saved_start` values and the `foreign_active`
  marker are written together, so a rebuild of the registry can no longer drop the start
  types the switch depends on.
- **The registry dedupes by alias and path**, so registering the same root twice is a
  no-op instead of a duplicate row.

### Windows-specific — `tests/harness-switch.ps1`

- Now **82 checks**, up from 74: an unreadable start type and a refused `sc.exe config`
  are driven through the real `Get-ServiceStartType` / `Set-ServiceStartType` against
  `sc.exe` stubs, and both assert that nothing was stopped and no handover was recorded.
- Passes on Windows PowerShell 5.1 and on PowerShell 7.

*The macOS/Linux harness gained the marker and `--remove` checks in the same round
(36 checks).*

## [panel 0.2.1-beta-win] — 2026-11-22

### Windows panel (Rust + egui, 0.2.1 beta)

*Previous panel update: [panel 0.2.0-beta](#panel-020-beta-win--2026-11-21).*

A layout round on the panel: the log pane takes the space the cards do not need, the
controls that are not status moved into a menu, and every card answers the same question
in the same two colours.

### Fixed

- **The empty band under the cards is gone.** The Output pane is sized from the slack
  instead of a fixed default. Three separate faults kept it small: `min_size(88.0)` after
  `exact_size()` re-widened the clamp so the height restored from a previous session won;
  the collapse animation interpolates the reserved height and could stay pinned at a
  fraction when repaints stop; and `content_size` never reports more than the viewport, so
  a squeezed body measured its own clipping. The cards keep a 340pt floor and the console
  takes the remainder.
- **The REFRESH slider changed nothing but the footer's own text.** `status --watch` takes
  its interval as an argument, so a new rate needs a new process. The slider now stops that
  child and starts a fresh watch, and logs `polling every Ns`.
- **The panel reopened at a fixed 980x860** whatever it had been sized to. Size, position
  and maximised state are stored in `panel.json` and reapplied; geometry is saved as you
  resize (debounced two seconds) because close-to-tray never runs the exit path.

### Added

- **`Links` menu** in the header: localhost, phpinfo, phpMyAdmin, logs, the www folder.
- **Green and red chips on every card.** PHP and phpMyAdmin are not processes, so `ready`
  plays the part of `running`, and a component that is missing is as red as one that is
  stopped.

### Changed

- **Start, Restart and Stop are back on the body**, next to the cards they act on; About is
  back in the header. A menu hid both two clicks deep.
- A refresh interval or script change no longer waits for a re-attach to take effect.

## [panel 0.2.0-beta-win] — 2026-11-21

### Desktop panel (phpup-panel v0.2.0, beta)

Improvements on top of `panel 0.1.0-beta`, released as `panel 0.2.0-beta-win`. Panel releases bump
no script version and ship as their own zip.

#### Added

- **Panel: Stacks** — the registered XAMPP roots, listed under the component cards, with
  `Switch to` handing ports 80/3306 over and `Return to phpup` taking them back. `Browse…`
  registers further installs through `switch --add` with the native folder picker, without
  touching the ports, and each port is shown with its owner and PID. A rejected path stays in
  the field with the reason beside it, and a failed switch never leaves the block claiming it
  does not know who holds the ports. A handover stops and starts services, which Windows refuses
  without Administrator, so an exit-4 answer offers `Run as administrator` and repeats the same
  call elevated rather than making the user restart the panel.
- **Panel: start in the tray at launch** - Settings -> Window. On, the panel starts with no
  window and no taskbar button, tray icon only, which is what an autostart launch wants. Off
  by default, so the window opens. Uses the same `Visible(false)` path as the close button and
  is applied a few frames after launch, because a viewport command issued before the window is
  mapped is dropped. Verified against the real UI window via `EnumWindows`, since
  `MainWindowHandle` points at a hidden helper window and reports the wrong state.
- **Panel: Start with Windows** - per-user `HKCU\...\Run` entry written with `reg.exe`, so it
  needs no elevation and no scheduled task. The checkbox mirrors the registry rather than
  storing its own copy, so it cannot disagree with what Windows does at sign-in. Off by
  default.
- **Panel: per-service startup type** - `Auto` / `Disabled` on each registered service,
  applied with `sc.exe config <name> start=`. Only `sc.exe` is elevated, through
  `Start-Process -Verb RunAs`.
- **Panel: hover states** - buttons lighten, take an accent edge and grow slightly on hover.
  Applied in `theme.rs`: the panel's explicit button fills had been suppressing egui's hover
  fill, which is why hover did nothing visible.

#### Changed

- **Panel: the window opens taller, and the console starts smaller** - 980x860 (still clamped to
  85% of the monitor) with the console at 120pt instead of 160pt, so the Stacks block, its error
  line and the path field all fit above the console on a 1080p screen. At the old 700pt height
  the block sat below the fold.
- **Panel: Settings manages boot behaviour only** - the service rows no longer carry their own
  Start/Stop. `Start` / `Restart` / `Stop` above the cards control the running processes;
  `Auto` / `Disabled` control the service registration. Two meanings of "stop" on one screen
  was confusing, and the process controls already existed.
- **Panel: quick links moved beneath the component cards** - opening the Settings slide-out
  narrows the content area and had been pushing localhost / phpinfo / phpMyAdmin / logs /
  www folder into the Start-Restart-Stop buttons.

## [2.5.4-win] / [1.3.3-nix] — 2026-11-21

### macOS/Linux (phpup.sh v1.3.3)

### Added

- **`switch --add --path <dir>`** registers a foreign root without touching the ports or services,
  so a GUI can list several XAMPP installs before the user chooses one. `--dry-run` reports the
  alias and writes nothing; a path that is not a stack exits 2 and leaves the registry alone.
  `phpup.ps1` gains the same `-Add` flag.

### Fixed

- **`stack` is an array in every branch of `switch --json`** — the handover paths assigned a single
  resolved stack object while `--list` and `--add` assigned an array, so the field had two shapes
  and a client obeying the documented one failed on exactly the payload that carried the reason
  the switch had not run.
- **The switch fixes are covered now, and three rough edges are gone** — `foreign_exe_running`
  replaces the `pgrep -f` probe: the command line must *start* with the executable, so a `tail -f`
  or `grep` that merely mentions the path no longer counts as a running daemon, and a directory
  containing regex metacharacters can no longer break the match. `brew_services` resolves the brew
  binary absolutely, because after `sudo -u … env -u SUDO_*` the PATH is the invoking shell's and
  is not guaranteed to hold brew under cron or a `secure_path`. The last two `brew services start`
  calls (php-fpm, and the `fu` switch) no longer discard stderr, which was the exact pattern that
  hid the original failure behind "One or more services did not start".
- **`tests/harness-switch.sh` now exercises the handover logic** — 34 checks became 42 on a POSIX
  host: an unreadable listener attributed to the stack by its own daemon, a `tail` mentioning the
  binary deliberately not counted, `mysqld` found in `sbin/` or `bin/`, a foreign root not credited
  to another stack, `brew services` receiving the verb and formula, and the `sbin/` version probe.
  On a filesystem that cannot express an exec bit the exec-dependent checks report `[SKIP]` rather
  than a false failure, so the suite is honest on Windows and complete on macOS and CI.

### Windows (phpup.ps1 v2.5.4)

Adds the `switch` verb: hand ports 80 and 3306 to an existing XAMPP install and take them
back. Windows first; the macOS and Linux mapping (`/Applications/XAMPP/xamppfiles`,
`/opt/lampp`) follows in the same contract.

### Added

- **`switch` hands the ports to another stack and takes them back** — for users whose older
  projects live in XAMPP, phpup can now shut its own stack down, release 80 and 3306, start
  the named XAMPP root, and later reverse it. `--to <alias>`, `--path <root>`, `--list`,
  `--dry-run` and `--json`, with the same exit codes as every other verb (2 usage, 4
  elevation, 5 port held by a stack phpup cannot attribute). Idempotent: a second press
  reports `changed: false`. It records the phpup service start types it released
  (`sc.exe qc`) and restores them on the way back, so a handover cannot leave phpup disabled
  after a reboot. Refusals, deliberately: no data migration, no shared data directory
  (phpup's MariaDB 13.x would upgrade XAMPP's 10.4 datadir one way and irreversibly), no
  writes inside the foreign stack, no guessing which XAMPP root, and no killing by port: a
  stop is filtered by executable path, and a process whose path cannot be read is reported
  instead of killed. The stack's own binaries are started directly (`httpd.exe`,
  `mysqld.exe --defaults-file`), never the `.bat` launchers, which run in the foreground and,
  in this install, still contain an unsubstituted `@@BITROCK_INSTALLDIR@@` token in their
  stop scripts.
- **`tests/harness-switch.ps1`** — 62 assertions against the real function bodies with the
  leaves stubbed: footprint detection and refusals, port-owner classification (including a
  service PID whose executable path is unreadable unelevated), path-filtered stopping with a
  decoy `mysqld` from another root, dry-run purity, both handover directions, idempotence,
  config preservation and the elevation/conflict refusals. Mutation-tested: removing the path
  filter turns exactly the two safety assertions red.

### Changed

- **`Save-Config` preserves the foreign stack registry** — it gained `-ForeignStacks` and,
  like `MinSeries`, keeps the existing key when a caller does not pass it. `Save-Config`
  rebuilds its object from scratch, so without this any unrelated save would have silently
  dropped the registry and the handover state with it.

### Fixed

- **`stack` is an array in every branch of `switch --json`.** The handover paths built a single
  resolved stack object while the list paths built an array, so the same field had two shapes and
  a client obeying the documented one choked on exactly the payload that carried the reason it had
  failed. The emitter now wraps whichever it is handed.
- **A pre-release install no longer passes as the matching stable** — with 8.6.0 RC7 installed
  and the 8.6.0 final released, `u` answered "Stack is up to date" and `I` skipped PHP, because
  the version parse drops the suffix and both sides read as 8.6.0. `u`, `I` and the fu menu now
  treat a final release as newer than its own alpha/beta/RC, while a pre-release of a *newer*
  branch is left alone. In `fu` the series row reads `8.6.0 (newer) — current: 8.6.0 RC7`, the
  stable variant sorts above the RC it supersedes, and the installed RC keeps its `(current)`.

---

## [1.3.2-nix] — 2026-11-20

### macOS/Linux (phpup.sh v1.3.2)

*Previous platform update: [1.3.1-nix](#251-win--131-nix--2026-11-01).*

The `switch` verb reaches macOS and Linux, and live testing against a real XAMPP install on an Intel Mac turned up five defects in the handover path — most of them only visible when the stack on the other side runs as a different user.

### Added

- **`switch` hands the ports to another stack and takes them back** — same verb, same payload and
  same exit codes as Windows. macOS drives XAMPP's own `xampp startapache|startmysql` (never bare
  `start`, which also brings up ProFTPD) and disables any launchd agent that references the stack's
  path, found by path rather than by label because the labels are user-created and vary. Linux
  drives `/opt/lampp` and records `systemctl is-enabled` for `apache2`/`mariadb` so the handover can
  disable them at boot and restore them afterwards. A directory without `xamppfiles` is treated as
  XAMPP-VM and refused: its stack lives inside a VM and never binds the host's 3306.
- **The registry is its own file** (`~/phpup/foreign_stacks.tsv`) rather than a key in `config.json`,
  because `save_config()` regenerates `config.json` wholesale on every install and update, which
  would drop anything added there. One line per stack; the boot state a handover released lives in
  the last two columns and is cleared when the ports are handed back.
- **Port ownership trusts `port_owner_active()` before any listener path** — on macOS Apache runs as
  root (invisible to an unprivileged `lsof`) and the MariaDB binary sits in the brew prefix, not
  under `~/phpup`, so path matching alone reported phpup's own stack as `other`. Stopping a foreign
  stack still only kills listeners whose executable path is provably under the named root.
- **`tests/harness-switch.sh`** — 32 assertions against the real function bodies with `sudo`, `lsof`,
  `ps`, `launchctl` and `systemctl` stubbed: detection (including the XAMPP-VM refusal), aliases,
  registry round trip, port classification, "kill only its own listeners", and payload JSON
  validity. Runs green on macOS bash 3.2.
- **A pre-release build is labelled, and never offered as the latest stable** — the dashboard
  PHP row now reads `8.6.0RC7 (pre-release)` in yellow, matching the Windows label, and
  `latest_php_version()` skips `preview` candidates as well as alpha/beta/RC. One helper,
  `php_is_prerelease`, decides both, so the marker and the search cannot drift apart. The update
  decision itself is still the package manager's, which already orders a pre-release below its
  final release.
- **`tests/harness-prerelease.sh`** — 17 assertions against the real function bodies with the
  package manager stubbed: detection across RC/beta/alpha/preview and Debian `~` forms, the
  latest-stable search skipping each of them, and the dashboard label for both states.
- **The update list now carries the versions** — `u` used to print brew's default names only
  (`httpd`, `mariadb`, `php`), so you could see that something was outdated but not what it would
  become. The list now reads `httpd 2.4.69_1 -> 2.4.71`, which also makes a revision-only rebuild
  (`php 8.5.12 -> 8.5.12_1`) readable and puts a major jump (`mariadb 12.3.3 -> 13.0.2_1`) in front
  of you before you answer the prompt.
- **`brew_stable_version`** now owns the `"stable"` parse shared by the newest-PHP-alias lookup and
  the update switch message, and survives both brew's pretty-printed JSON and a compact blob.
- **`tests/harness-brew.sh`** — 12 assertions covering the version formatting, the
  revision-only case, the unparsable-line fallback, and the PHP line enumeration in both the
  current metadata and the post-8.6.0 shape. Brew is stubbed, so it runs on Linux CI too.

### Fixed

- **A foreign stack can be attributed without root** — `switch --to phpup` refused with exit 5
  ("Port(s) held by something phpup cannot attribute") before stopping anything, because
  `port_owner_kind()` fell back to an unprivileged `lsof`, and macOS runs Apache as
  root/`daemon` and MySQL as `_mysql`, so both listeners read as ownerless. When the listener
  path cannot be read at all, the named stack is now asked whether one of its own daemons is
  running, matched by binary path (`xamppfiles/bin/httpd`, `xamppfiles/sbin/mysqld`,
  `/opt/lampp/...`). A readable path that lands outside the stack still reports `other`
  rather than being assumed foreign.
- **`brew services` runs as the invoking user, not as root** — an elevated switch started
  MariaDB with `brew services start mariadb`, which Homebrew refuses as root, and every caller
  discarded stderr, so the only symptom was "One or more services did not start — see the
  messages above" with no messages. A `brew_services` helper drops to `SUDO_USER` with the
  `SUDO_*` markers scrubbed, which also keeps the job in the `gui/` domain instead of the
  `user/` one brew picks when it detects sudo. The blanket `2>/dev/null` on the start calls is
  gone.
- **A free pair of ports is no longer reported as already held** — with 80 and 3306 free, the
  forward switch printed `Ports are already held by xampp` and did nothing, leaving both
  stacks down. It now starts the foreign stack, and the plan line says so.
- **The registry survives an elevated run, and remembers the stack** — `foreign_registry_set()`
  writes through `mktemp`, so a root-run left `~/phpup/foreign_stacks.tsv` owned by root at
  `0600`; the next unprivileged switch hit "Permission denied", read an empty registry and
  would have answered "Unknown target". The file is handed back to `SUDO_USER` after writing.
  The reverse switch also registers the stack it just switched from, so the next
  `switch --to xampp` needs no `--path`.
- **XAMPP's MySQL version is read from `sbin/`** — XAMPP on macOS ships `mysqld` in `sbin`,
  not `bin`, so the foreign stack reported a blank MySQL version. Both paths are checked.

---

## [2.5.3-win] — 2026-11-13

### Windows (phpup.ps1 v2.5.3)

*Previous platform update: [2.5.2-win](#252-win--2026-11-09).*

`u` reported the stack up to date while windows.php.net was publishing newer PHP: the
resolver was skipping every build whose version string carried a rebuild suffix. The same
release puts the alpha/beta/RC builds into the `fu` menu, stops `config.json` carrying a UTF-8
BOM, and carries the per-tick `php.exe` fix from 2026-11-11.

### Added

- **`fu` lists PHP pre-releases (alpha, beta, RC)** — the switch menu read stable releases only, so a
  build like `8.6.0RC7` could not be selected unless its zip was already in the cache. Pre-releases
  are now fetched from windows.php.net's QA index (`downloads/qa/releases.json`) and listed in their
  own block at the end of the menu, tagged `(pre-release — download & install)`, with a warning and
  a confirmation prompt before anything is downloaded. Only builds ahead of the stable release in
  their own series are offered, so a stale QA build (`8.2.27RC1`, January 2025) does not sit beside a
  newer stable patch, and `-dev` snapshots are excluded. `php_min_series` gates them as it gates
  stable series, and `-Offline` lists none. Harness, 14/14 under pwsh 7 and Windows PowerShell 5.1:
  index parsing, floor, offline, row numbering, the confirmation path, and `N` backing out unchanged.

### Fixed

- **`status` no longer forks `php.exe` on every poll** — `Get-CliStatus` called
  `Test-PhpApacheModuleWired`, which called `Get-PhpApacheModuleSymbol` with no argument, and
  that function's default parameter is `(Get-PhpVersion)`. Every tick therefore spawned
  `php.exe -v` (~225ms) to decide whether to look for `php7_module` or `php_module` in
  `httpd.conf`, when `Get-CliStatus` already held the installed version from `config.json`. The
  panel polls `status --watch 2 --fast`, so a tray panel left running spawned a PHP process every
  couple of seconds, indefinitely. Invisible while the machine has commit headroom; on a box that
  has run out of it the loader refuses the fork and Windows raises `php.exe - Application Error
  (0xC000012D)`, which reads as a random PHP crash on a stack that was working. The check now
  accepts an optional version and `status` passes the one it already has, while callers that do
  not know it still fall back to probing. Ad-hoc harness, 8/8: no-argument and empty-version calls
  still probe and return `$true`; `8.5.12` and `7.4.33` return the correct verdict with zero
  spawns; pwsh 7 and PS 5.1 parse clean; BOM intact. Instrumented `status --fast`:
  `Get-PhpVersionRaw` calls 1 → 0, JSON unchanged (`sapi=apache2handler`). A/B on a loaded Windows
  box: tick cost 522ms → 377ms.

- **`u` resolves the real latest PHP again** — `Get-LatestPhpUrl` demanded a bare `x.y.z`, but
  windows.php.net publishes newer builds with a rebuild suffix (`8.5.12-1`, `8.4.27-1`, `8.3.36-1`,
  `8.2.35-1`). Every suffixed entry was skipped, leaving `8.1.34` and `8.0.30` as the only matches, so
  the resolver answered `PHP 8.1.34 (VS16)` and `u` then reported the stack up to date because 8.1.34
  is older than any current install. The resolver now parses the base version out of either form,
  keeps the highest 8.x series, and uses the toolset only as a tie-breaker (VS18, VS17, VS16, VC15),
  so 8.6 cannot fall back to 8.5. Harness against the live `releases.json`, under pwsh 7 and Windows
  PowerShell 5.1: `PHP 8.5.12 (VS17) -> .../php-8.5.12-1-Win32-vs17-x64.zip`.

- **`Get-VersionFromUrl` reads rebuild-suffixed PHP URLs** — `php-([\d.]+)-Win32-` could not match
  `php-8.5.12-1-Win32-vs17-x64.zip`, so the resolved version came back `$null`, and the update flow
  treats an unknown resolved version as a replacement: every `u` would have re-downloaded and
  reinstalled the PHP you already had. The pattern now tolerates `(?:-\d+)?`. Verified on three URL
  forms: `8.4.27`, `8.5.12-1` → `8.5.12`, `8.1.34`.

- **The pinned PHP fallback no longer 404s** — `$FALLBACK_URLS.PHP` pointed at
  `php-8.5.12-Win32-vs17-x64.zip`, which windows.php.net pruned when the rebuild superseded it
  (HTTP 404, measured). Repointed at `php-8.5.12-1-Win32-vs17-x64.zip`, verified 206. The fallback
  only runs once live resolution has already failed, which is the worst moment to find a dead link.

- **`config.json` is written as UTF-8 without a BOM** — `Save-Config` used
  `Out-File -Encoding UTF8`, and in Windows PowerShell 5.1 that encoding means UTF-8 *with*
  a BOM while pwsh 7 means without one, so the same call produced different bytes depending
  on which shell launched phpup. Users arrive through `phpup-boot.ps1 | iex`, which lands in
  5.1, so the stack config carried `ef bb bf` at byte 0. phpup's own reader tolerated it
  (`Get-Content -Encoding UTF8` strips the mark) but every strict JSON consumer refuses a
  config that starts with one: PHP's `json_decode`, JS `JSON.parse` and Rust's `serde_json`
  all fail on byte 0. Both the canonical config and the `%APPDATA%` discovery pointer now go
  through a `Write-Utf8File` helper that uses `UTF8Encoding($false)`, the only form both
  shells write identically. Harness, pwsh 7 and PS 5.1: helper and `Save-Config` output start
  `7b 0d 0a`, round-trip through `ConvertFrom-Json`, and decode under a strict UTF-8 reader.

## [2.5.2-win] — 2026-11-09

### Windows (phpup.ps1 v2.5.2)

*Previous platform update: [2.5.1-win](#251-win--131-nix--2026-11-01).*

Patch release. Every PHP switch run from Windows PowerShell 5.1 aborted on a healthy
download: the staged-tree check could not read `php.exe`'s exit code, so the version banner
it had just printed was reported as the failure. `phpup.sh` is unchanged, still 1.3.1.

### Fixed

- **PHP switching no longer aborts on a good staged tree under Windows PowerShell 5.1** —
  the pre-swap check launches `php.exe -v` with `Start-Process -PassThru` and then reads
  `$proc.ExitCode`. PowerShell 5.1 cannot re-open a process handle once the process has
  exited, so `ExitCode` came back `$null` — and `$null -ne 0` is true — so the switch died
  with `PHP switch aborted - the staged tree is not runnable: php.exe exited with : PHP
  8.5.12 (cli) ...` on a tree that had started perfectly. The handle is now cached while the
  process is alive, and a `$null` exit code is treated as unknown rather than as a failure,
  so the verdict comes from what php actually printed. Reproduced on both hosts: 5.1 returned
  `ExitCode=[]`, PowerShell 7 returned `0`, same exe, same code. Affected every switch on
  5.1, not one PHP version: a user on 8.1.35 could not move to 8.5.12 and `D:\phpup\php`
  was untouched throughout.

## [2.5.1-win] / [1.3.1-nix] — 2026-11-01

### Windows (phpup.ps1 v2.5.1) and macOS/Linux (phpup.sh v1.3.1)

Patch release. Windows: PHP could not make a single HTTPS request (OpenSSL 4 and a CA bundle), the streamed install path works, sessions moved out of the machine temp directory into a stack-owned store, and `fu` no longer leaves a half-switched PHP tree behind. macOS/Linux: the streamed install path and dashboard version were fixed, sessions moved to the stack in the same way, and the `u` path stops claiming success when the stack did not come up.

### Changed

- **Version shown in the dashboard banner wordmark** (`phpup v2.5.1`, `phpup v1.3.1`) instead
  of on the architecture line, and in the panel's About popup only. `docs/CLI.md` updated.

- **Windows: PHP sessions now live in a stack-owned directory** - `session.save_path` is set to
  `C:\phpup\tmp\sessions` and the directory is created during install, update and forced update.
  Left unset, PHP wrote sessions to the machine temp directory: one store shared by every PHP
  process on the box and deleted by Windows cleanup tools, so two local projects could read each
  other's session data and logins vanished without warning. The edit targets the column-0
  directive in PHP's template and appends when there is none, since the template also carries
  indented commented examples that a looser match would leave silently commented out.

- **mac/Linux: sessions now live in the stack too** - `session.save_path` is set to
  `~/phpup/sessions` inside `apply_php_ini_policy`, so brew, apt and MacPorts all get it from
  one place. Debian and Ubuntu put sessions in `/var/lib/php/sessions`, which every PHP
  application on the host writes to as `www-data`; brew and MacPorts fall back to the system
  temp directory. `ensure_sessions_dir` creates the directory group-owned by the web server
  user with mode 2775 and the developer as owner, matching the document root pattern. Verified
  on Ubuntu 24.04 and on an Intel Mac: one active directive after repeated runs, and a request
  through the web server writing `sess_*` into the store.

- **`fu`: the PHP list offers every supported series, not just the cached ones** -
  `windows.php.net` publishes rebuild suffixes (`8.2.35-1`, `8.5.12-1`) and
  `Resolve-PhpSeriesUrl` demanded a bare `x.y.z`, so it rejected every entry and the menu fell
  back to the download cache alone. It now accepts the optional suffix, reports the base
  version, and prefers the VS18 toolchain that 8.6+ builds ship with. With `php_min_series` at
  8.2 the menu offers 8.2.35, 8.3.36, 8.4.27 and 8.5.12, downloading whichever one is missing
  when it is selected.

### Fixed

- **Windows: `fu` could leave a half-switched PHP tree with no `php.ini`** - the switch deleted
  the PHP folder first and then extracted over it, ignoring whether the extract worked. A
  `php.exe` still running (wedged on a loader dialog) made Windows refuse to replace the locked
  files, so the folder ended up holding the new DLLs, the old `php.exe`, no `php8ts.dll` and no
  `php.ini`, and every later launch opened the same error dialog in a loop. `fu` now stops stray
  `php.exe` processes from the stack, extracts to `php.new`, checks the core DLL is there and
  that `php.exe -v` answers within 15 seconds, probes the live folder for locks, and only then
  renames the old tree to `php.old` and promotes the new one. A switch that fails leaves the
  previous PHP untouched; a failed health check rolls back to it.

- **Windows: PHP could not make a single HTTPS request, so STARTTLS mail relays and every API call failed** - `php_openssl.dll` and `php_curl.dll` both refused to load under Apache, logging `PHP Startup: Unable to load dynamic library 'php_openssl.dll' ... The specified module could not be found` even though the DLL sat in `php\ext`. Apache's `bin` carries OpenSSL 3 for `apr_crypto`, PHP 8.6 is built against OpenSSL 4, and Windows resolves an extension's dependencies from the Apache process first, so the pair looked for a bundled dependency that was never there. `Invoke-CopyPhpDlls` copied ICU, libssh2, nghttp2 and libsodium but never the OpenSSL pair; it now copies whichever `libssl*` and `libcrypto*` PHP ships. The filenames differ by major, so both can live in Apache's bin without disturbing `mod_ssl`.

- **Windows: no CA bundle, so HTTPS verification failed even once the extensions loaded** - `curl.cainfo` and `openssl.cafile` were unset and PHP for Windows ships no certificate store, which surfaces as `SSL certificate problem: unable to get local issuer certificate`. `Invoke-ConfigurePhp` now fetches `cacert.pem` into `php\extras\ssl\` and points both directives at it. Verified on a live stack: a Trongate contact form went from `mail_sent = 0` (Gmail STARTTLS refused) to `mail_sent = 1`, with a Cloudflare Turnstile check returning `success: true` from the same request, and `siteverify` reachable from the Apache SAPI.

- **mac/Linux: TLS capability was never checked after a version switch** - the `fu` verification block now runs `verify_php_tls`, which asks PHP for a small HTTPS resource and prints `ok` or `failed (CA bundle / openssl)`. Same class of failure as the Windows bug above, caught at the moment a switch could introduce it.

- **Windows: the documented `irm ... | iex` command failed with a parse error** - `phpup.ps1` keeps a
  UTF-8 BOM so Windows PowerShell 5.1 decodes its box characters, and piped into `iex` that BOM
  attaches to the first comment, so the first line is read as a command (`The term '?' is not
  recognized`) and the `param` block below it mis-binds (`Cannot convert "0" ... to SwitchParameter`).
  Added `phpup-boot.ps1`, a BOM-free launcher that fetches the script, strips the marker and runs it;
  the README and `docs/WINDOWS.md` now install through it. Verified under PowerShell 7 and 5.1.

- **Version missing from the mac/Linux dashboard when streamed** - the banner read `phpup v`
  with nothing after it. `script_version()` grepped `$0`, which is the shell and not a file
  when the script runs the documented way (`source <(curl ...)`, `bash -c "$(curl ...)"`), so
  it came back empty. It now reads a literal, which also fixes `phpup.sh version` and the
  `phpup.version` field in `--json`. Windows had the same hole: `Get-ScriptVersion` fell back
  to `0.0.0` under `irm | iex`, and now falls back to the header version without throwing.

- **Dashboards: the wordmark reads in dark and light terminals** - `phpup` was drawn in ANSI blue with the version in cyan, both dark variants, so on a dark terminal profile the wordmark was near invisible and the version hard to read. Both dashboards now use bold default foreground, inheriting the theme's own contrast (`phpup.ps1` used `-ForegroundColor Blue`, which maps to dark blue).

- **Windows: pinned fallback URLs were stale, and the PHP one was dead** - these are the last
  resort when live version resolution fails, and they pointed at PHP 8.5.9, which
  `windows.php.net` has since removed (HTTP 404), plus Apache 2.4.68 and MariaDB 12.3.2 while
  the installer ships 2.4.69 and 13.0.2. All three refreshed to the versions the script
  installs, each verified by HEAD request before being written in. `phpMyAdmin` 5.2.3 and the
  VC redist were already current.

- **`u` claimed "[ OK ] UPDATE COMPLETE!" even when the stack did not come up** — `cmd_update`
  printed that line unconditionally after all three backend branches. Each `start_services`
  call now sets `update_ok=0` on failure, and the closing message distinguishes "packages
  updated and stack up" from "packages updated, stack did not come up". Found on the Debian
  box, where ports 80 and 3306 were held by the Ubuntu stack in the same WSL2 network
  namespace.

- **The apt update path could block on a dpkg conffile prompt** — `cmd_update`'s `apt upgrade`
  was the only apt call in the script without `DEBIAN_FRONTEND=noninteractive`, so a `php.ini`
  or `httpd.conf` conffile question could stall an unattended run and swallow whatever was
  queued on stdin. Observed on Debian: the prompt consumed the remaining scripted answers.

## [panel 0.1.0-beta-win] — 2026-10-22

### Desktop panel (phpup-panel v0.1.0, beta)

*First published build of the Windows panel. Separate product chain: the panel versions
independently of `phpup.ps1` and `phpup.sh`, so this entry affects neither script version.*

Rust + egui control surface for phpup. It reads the CLI's schema-1 status payload and shells
out to the script for every action, so the scripts stay the source of truth.

#### Added

- Tray-first launch: Settings -> Window -> *Start hidden in the tray* starts the panel with
  no window and no taskbar button, so an autostart leaves a clean taskbar. Off by default.
- Start with Windows: per-user `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` entry
  written with `reg.exe`, no elevation. The checkbox mirrors the registry rather than a
  stored copy, so it cannot disagree with what Windows will do at sign-in.
- Per-service startup type (`Auto` / `Disabled`) through `sc.exe config <name> start=`,
  with only `sc.exe` elevated per action.
- Hover feedback on every button, applied in `theme.rs`.
- Release zip with `install.ps1`: copies the exe into `<install_path>\bin`, prints the
  installed SHA256, needs no elevation and touches no registry keys.

#### Known limits in this beta

- **Windows x64 only.** macOS and Linux are planned. `phpup.sh` already emits the same
  schema-1 payload, so the data path is portable; the work is the action layer and builds.
- **No embedded version metadata** in the binary yet: identify a build by the zip name or
  the release checksum.
- **Unsigned binary**, so SmartScreen warns on first run.
- **Per-action elevation**: a UAC prompt for each service change unless the panel runs
  elevated (Settings -> Privileges -> always admin), which then reads
  `phpup - as administrator` in the title bar.
- **Tray visibility** depends on the Windows tray overflow area: if the icon is tucked
  behind the chevron the panel looks like it never started. Pin it to the tray.

## [2.5.0-win] / [1.3.0-nix] — 2026-10-22

### Windows (phpup.ps1 v2.5.0) and macOS/Linux (phpup.sh v1.3.0)

Feature release adding a machine-readable CLI, so a GUI, tray app or CI job can drive phpup
without the interactive dashboard. Contract: [`docs/CLI.md`](docs/CLI.md).

### Added
- **Desktop control panel (`panel/`, version 0.1.0, unreleased)** — a Rust + egui control
  surface that drives the same CLI verbs, with no webview and no Node toolchain:
  - live component cards (version, state, PIDs, ports, SAPI, service names) fed by
    `status --watch --fast`;
  - Start / Restart / Stop, repainting from each verb's own JSON;
  - terminal-style output pane carrying phpup's stderr, with copy, clear and follow/pause
    that releases when you scroll up;
  - tray icon from the favicon, menu of Show / Start / Stop / Restart / Quit, close-to-tray;
  - Settings slide-out (Status, Appearance, Zoom, Privileges, Source, Services) that closes
    on Escape, the Close button or a click outside, plus an About popup;
  - administrator modes: per-action elevation, or an always-elevated panel whose title bar
    reads `phpup - as administrator`;
  - Trongate's own palette for active controls (`--primary #4682b4`, white text), System /
    Light / Dark themes, zoom Auto / 85% / 100% / 115% / 130%;
  - window sized to 90% of the monitor on first frame, so high-DPI scaling cannot push it
    off the screen.

### Fixed
- **Windows reported as "Windows 10" on Windows 11** — the registry still stores
  `ProductName = "Windows 10 Pro"` on Windows 11, so the banner and `platform.distro`
  were wrong. The build number now decides: 22000 and above is Windows 11.
- **`platform.distro` was null in `--fast` and kept its "Windows " prefix in full mode** —
  the strip pattern expected "Microsoft Windows", which the registry does not supply. The
  registry read costs ~2ms, so it now runs in both paths.
- **`Get-Process -Name` replaced with .NET lookups** (`GetProcessesByName`) for every
  process check and stop path on Windows. Windows PowerShell 5.1 writes
  `Exception of type 'System.OutOfMemoryException' was thrown` to the error stream when the
  name matches nothing, which polluted redirected stderr with a stack trace pointing at a
  line that was doing nothing wrong.

### Added
- **`status`, `start`, `stop`, `restart`, `version`, `help` verbs** on both scripts, with
  `--json` (PowerShell `-Json`) emitting a stable schema on stdout. No arguments behaves
  exactly as before: the dashboard is untouched.
- **`--fast`** for polling: skips prerequisites and the OS caption on Windows, and on
  macOS/Linux is effectively a no-op because there is no local prerequisite to check.
- **`--watch N`**: one long-lived process emitting one NDJSON status line every N seconds.
  Measured reason: a fresh PowerShell process costs ~0.85s, so per-tick process spawning
  would hold ~40% of a core at a 2s interval. One process with lazy probes costs ~237ms a
  tick on Windows and ~340ms per invocation on Linux.
- **`--quiet`**, plus documented exit codes: 0 ok, 1 failed, 2 usage, 3 not installed,
  4 elevation required, 5 port conflict. Codes 4 and 5 exist so a caller can relaunch
  elevated or name the foreign process instead of parsing English.
- **`services.items[]`** in the payload: per-service `{name, registered, enabled}`, so the
  registered services are visible on every platform, not just as Windows service names.
- Single source of truth for derived paths (`Initialize-Paths` on Windows, globals on unix),
  and the header comment is now the only place a version is written: both `--version` paths
  read it rather than duplicating it.

### Fixed
- **Windows `status` and `start` could take 4-8s before doing anything** — `Test-TcpPortListening`
  called `Get-NetTCPConnection`, which measured **3.8s cold** on every fresh process (the
  NetTCPIP module autoloads per process, and every CLI call is a fresh process). It now
  enumerates listeners through `System.Net.NetworkInformation` (~60ms), with the old netstat
  parse kept as a fallback. `Assert-StackPortsFree` calls it twice, so `start` and `restart`
  were paying that cost on the interactive path too.
- **Linux paid ~420ms for `brew --version` on every run** — the Homebrew probe at the top of
  `phpup.sh` ran unconditionally, including on apt systems where brew is irrelevant. Now
  gated on `USE_APT == 0`. Interactive `status` on the Ubuntu test box went from 0.74s to
  0.34s.
- **The OS caption cost ~530-1100ms per dashboard render and per full status** — resolved via
  the registry (`CurrentVersion` `ProductName` + `DisplayVersion`, ~2ms) with the CIM query
  kept only as a fallback. The dashboard line reads `Windows: 11 Pro` either way.
- **Full status scanned the Uninstall registry twice** (~400ms each) for the VC++ version.
  One pass now: `Get-VcRedistVersion` result is compared against the minimum.
- **Version detection spawned three binaries per status call** (`httpd -v` alone is 579ms).
  Config values are used first, which install/update already write from the live filesystem,
  and probing is a per-component fallback. `version_source` reports `config` or `mixed`.
- **`$DOWNLOAD_CACHE` never followed a custom install path** — it was derived from the
  default `C:\phpup` at line 18 and never re-derived, so a moved stack pointed at the wrong
  cache. Now derived with the other paths.
- **PIDs vanished from the payload when running unelevated** — `ExecutablePath` is unreadable
  for other users' processes, so the path filter silently dropped service PIDs. Service mode
  now asks the SCM (`sc queryex`, ~70ms, full status only), and the fast path uses the process
  table, which needs no elevation.
- **`phpup.ps1` could not run under Windows PowerShell 5.1 at all** — the file was UTF-8
  without a BOM, so 5.1 decoded it as Windows-1252, every em dash inside a double-quoted
  string became a stray `"` that terminated the string early, and the parser reported ~58
  errors. Adding a UTF-8 BOM fixes it: 5.1 now parses and runs the script, `pwsh` behaviour is
  unchanged, and the non-ASCII banner and em dashes decode correctly (verified: the em dash
  reports as char 8212 under 5.1 rather than as three mojibake bytes).
- **A PHP upgrade could leave the install unloadable and still report success** — the `I`/`U`
  path extracted Apache and PHP straight over a live stack. httpd maps `php8ts.dll`, the
  loaded extension DLLs and their dependencies, so `Expand-Archive`'s overwrite failed
  NON-terminating, `Invoke-ExtractZip` still printed `[ OK ] PHP extracted`, and
  `Invoke-CopyPhpDlls`' `Copy-Item -Force` into `Apache\bin` failed the same way. The result
  was six extensions (openssl, curl, fileinfo, gd, intl, mbstring) failing with
  `The specified procedure could not be found`, and Apache refusing to serve. The install
  path now stops the stack and clears the destination before extracting Apache/PHP, exactly
  as the MariaDB branch already did.
- **Extraction failures were reported as successes** — `Expand-Archive` is now
  `-ErrorAction Stop` in `Invoke-ExtractZip` and `Invoke-DownloadAndExtract`, an empty
  destination throws, and nothing prints `[ OK ] extracted` unless it really extracted.
  `Invoke-CopyPhpDlls` size-verifies every copy, so a DLL locked by a running service is
  reported instead of being claimed as `Copied`.
- **PHP is verified after extraction** — new `Test-PhpRuntimeHealthy` runs `php.exe -v` and
  rejects a tree whose extensions fail to load, matching both PHP wordings
  (`Unable to load dynamic library` and `Unable to initialize module`). It runs in the
  install path and on the `fu` apply path, so a bad PHP tree is named at extraction time
  instead of being blamed on Apache later.
- **A service set to `Disabled` only ever reported "check Windows Event Viewer"** —
  `Start-WebStackServices` swallowed `Start-Service`'s error with `-ErrorAction
  SilentlyContinue` and sampled the status once after a fixed sleep. New `Start-PhpupService`
  reads the start type first (a `Disabled` service can never start, so it is set back to
  Automatic), surfaces the real exception, and polls for `Running`. Used for Apache and
  MariaDB.
- **`start_services` claimed success on Linux even when a unit had failed** — the apt branch
  ran `systemctl start ... 2>/dev/null` for Apache, MariaDB and the active PHP-FPM unit with
  no verification, then printed `Services started` unconditionally. Each unit is now checked
  with `systemctl is-active`, a failure is named (with the matching `journalctl` command) and
  the function returns 1, so the existing `start_services || print_warn ...` call sites fire.
  The brew and ports branches set the same failure flag, so no branch can fall through to a
  success message.
- **A failed phpMyAdmin unpack was recorded as an installed version** — `install_pma_tarball`
  ignored `tar`'s exit status (and the first `mv`'s), then wrote `phpup-version.txt` and
  returned 0. A bad tarball or an unpack that produced nothing now fails loudly, and the
  version is only stamped once `index.php` is present.
- **`switch_php_apt` reported the meta-package sync as successful** — the `apt-get
  --only-upgrade` call ended in `|| true` followed by an unconditional `print_ok`. A failed
  sync now warns and continues with what is installed instead of claiming success.

### Verified
- `bash -n` clean. Windows: `pwsh` parse clean; `status --json` validated as JSON on a live
  stack (Apache 2.4.69, PHP 8.5.11, MariaDB 13.0.2, phpMyAdmin 5.2.3) with correct PIDs, port
  ownership and `services.mode: service`; `start` correctly returned exit 4 unelevated with
  registered services; unknown verb returned 2; interactive run still hits the unchanged admin
  gate.
- Linux (WSL Ubuntu 24.04, apt backend): `status --json` validated, PIDs resolved for
  `apache2`/`mariadbd`/`php-fpm`, `services.items` reporting the systemd units and their
  enabled state, `start --json` returned exit 4 without cached sudo, `--watch 1` produced
  valid NDJSON lines.
- **Windows PowerShell 5.1 now fully supported** (was: parse failure on the whole script).
  Verified under 5.1: `version`, `version -Json`, `status`, `status -Json` (valid JSON, correct
  PIDs and port ownership), `bogus` → exit 2, `start` unelevated → exit 4, `status -Watch 1`
  producing valid NDJSON, and the interactive run still hitting the unchanged admin gate.
  `pwsh` 7 verified identically. 5.1 is ~0.1s slower per invocation than 7 (1.24s vs 1.15s for
  `status --fast` on this machine), which is startup, not script work.
- Note for the GUI: launch with `powershell.exe` (5.1, present everywhere) or `pwsh` (7); both
  work now. Keep the BOM in the file, or 5.1 support silently reappears as a parse failure.
- **Windows upgrade round trip verified live** (2026-10-22, Apache 2.4.69, MariaDB 13.0.2,
  phpMyAdmin 5.2.3): `fu` moved PHP 8.5.12 → 8.4.27 and back to 8.5.12 through the real
  interactive menu. Each hop stopped the services, cleared and re-extracted PHP, copied the
  dependency DLLs (`[ OK ] Copied` for all seven), printed
  `[ OK ] PHP <version> verified - core and extensions load`, and restarted both services.
  After the return trip the tree matched the 8.5.12 manifest exactly (79 files plus `php.ini`,
  no stale or missing entries) and all ten enabled extensions reported LOADED through
  `mod_php` (`apache2handler`).
- **Upgrade-path sandbox tests against the real zips**: extraction into a destination holding
  a locked file returns false and never prints `[ OK ] extracted`; a locked dependency DLL
  copy is reported as `Could not copy ...` rather than `Copied`; cross-minor extension drift
  (8.4 extensions in an 8.5 tree) is rejected by `Test-PhpRuntimeHealthy`; patch-level drift
  was disproved as a cause, because 8.5.11 extension DLLs over an 8.5.12 core load cleanly.
- **Nix failure paths verified on Ubuntu 24.04.4 LTS (bash 5.2.21)** using AST-style function
  extraction with stubbed `systemctl`/`stack_proc`: all services up returns 0 and prints
  `Services started`; Apache, MariaDB and PHP-FPM failures each return 1, name the failing
  unit and never print `Services started`. `install_pma_tarball`: a good tarball installs and
  stamps the version, while a corrupt tarball and an unpack missing `index.php` both return 1
  and leave no version stamp. 19 assertions, 19 passed.


## [1.2.7-nix] — 2026-09-13

### macOS & Linux (phpup.sh v1.2.7)

*Previous platform update: [1.2.6-nix](#126-nix--2026-09-12).*

Patch release fixing the `fu` version-switch menu, which was unusable on both macOS backends. The shared menu helper (extracted from the two inline menu blocks in the 2026-08-29 dedupe, `99ed3b5`) printed its UI to stdout while both callers captured it with `$( )` — so the menu went into the variable that was meant to hold the chosen version, and nothing reached the screen.

### Fixed
- **`fu` printed no version list and went ahead with a switch when the user pressed Enter to skip** — `php_switch_prompt` rendered the list, the prompt and its errors on stdout, but both callers invoke it as `target=$(php_switch_prompt …)`, and command substitution captures stdout. The whole menu therefore landed in `$target` instead of on the terminal: `read` waited with nothing displayed (the apparent hang), Enter returned a ~200-character blob rather than an empty string, the `[[ -n "$target" ]]` skip guard saw it as a real selection and carried on into the switch, and `print_info "Switching PHP to ${target}…"` then dumped the swallowed menu onto the screen mid-sentence — the stray `…` after `press Enter to skip: ` being `print_info`'s own ellipsis. The helper's user-facing output now goes to stderr (14 sites) and stdout carries nothing but the returned target. This affected the Homebrew *and* MacPorts menus identically; the helper has been in the script since that refactor and was never exercised through `$( )` on either backend until the Intel Mac leg.
- **`fu` mapped a menu number to the wrong version** — the candidate list is re-indexed from 0 when `"$@"` is assigned, while the printed menu numbers from 1, so the number was used directly as an array subscript: `1` selected `php@8.2`, `3` selected `php@8.4`, and the last entry (`5`) resolved to an unset element — an accidental skip. Now `target="${php_names[$((choice - 1))]}"`. Dotted (`8.4`) and bare formula (`php@8.3`) input were always correct. With the stream fix alone this would have become a *silent* wrong-version switch, which is why both are fixed together.
- **An abandoned `fu` switch could leave the stack with no `php` on `PATH`** — the Homebrew leg unlinks every PHP keg *before* installing the target, so a target that was not a formula name unlinked the stack and then failed at the install. A formula-name guard now runs ahead of the unlink loop, so an unvalidated value can never reach the destructive step.

### Verified
- `bash -n` OK · ad-hoc sandbox harness (the real `php_switch_prompt` sliced out of the script, run through the real `$( )` call shape with `print_*` stubbed): the menu and prompt now appear on stderr, Enter returns an empty target with `rc=0` so the caller skips, `1`–`5` return `php@8.1`–`php@8.5` exactly as printed, dotted and bare-formula input still resolve, and invalid input (`99`, `rm -rf /`) is still rejected with `rc=1` and the error visible. The MacPorts leg shares the fixed helper; the apt leg has its own inline menu and is untouched.

---

## [1.2.6-nix] — 2026-09-12

### macOS & Linux (phpup.sh v1.2.6)

*Previous platform update: [1.2.5-nix](#125-nix--2026-09-06).*

Patch release from the macOS leg of the 1.2.5 verification — the leg the previous release notes left outstanding. A dual-stack Mac (Homebrew beside MacPorts) exposed the dashboard and the `S` toggle reading the *neighbouring* stack's processes, and showed that Apache's PHP module was wired to a different formula than the one phpup manages.

### Added
- **`fu` now offers the newest PHP line** — the menu was built from `php@X.Y` formulae alone, and brew keeps its NEWEST line as the un-suffixed meta `php` formula (`php@8.5` is an alias for it), so the version most users actually want was structurally invisible. Lines now come from brew's own metadata (`brew info --json=v2 php`) instead of `brew search`, which lists that alias inconsistently between invocations; the newest line is displayed in its versioned form (`php@8.5`) and mapped back to the canonical formula when acted on. This also fixes the `(current)` marker silently vanishing whenever the newest line was linked — it was derived from the running binary's major.minor, yielding `php@8.5`, which matched no menu entry.
- **`u` offers a move onto the newest PHP line** — brew updates previously only patched within the active line, so a stack sitting on an older line had no in-place route forward (the apt branch has offered cross-series upgrades since 1.1.0). `u` now detects that the meta `php` formula is on a newer line and offers it, e.g. `PHP 8.4.24 → 8.5.10 (moves onto the newest line)` — advertising the version the upgrade will leave behind — then relinks on confirm, with `configure_apache` re-pointing the module.

### Fixed
- **Service Status no longer reads another stack's processes** — every check is pinned to the active backend's executable path via `stack_proc`, the helper the port guard already used. Bare `pgrep -x httpd` matched ANY stack's httpd, so on a mixed brew/ports Mac the dashboard reported the neighbour as running and the `S` toggle took the stop branch forever — it could never start. MacPorts' `mysqld` is matched alongside `mariadbd`. Linux is unaffected (systemd units are already stack-specific).
- **`S` verifies a stop instead of assuming one** — `stop_services` pre-checks whether anything is actually running (`Services were not running`) and verifies afterwards, returning non-zero and naming what is still up rather than printing `[ OK ] Services stopped` unconditionally. `S` announces a stop only when one really happened.
- **`R` asks for the password once on Homebrew, not twice** — the brew start phase runs `apachectl restart`, itself a stop+start, so stopping Apache in the stop phase was redundant work *and* a second `sudo` prompt. The start phase now owns Apache on brew; MacPorts still gets its unload and apt still starts with `systemctl start`.
- **Port guard names the holder on macOS** — `port_holder_label` used `ss` (Linux-only), so the guard refused to start without saying what held :80/:3306. It now falls back to `sudo -n lsof` and reports e.g. `httpd (PID 23797)`. The Linux `ss` path is unchanged.
- **PHP version no longer read from bare `php` on PATH** — the Homebrew branch of `detect_php` called bare `php`, so a MacPorts/getphp/stale-MAMP `php` earlier on `PATH` reported *that* stack's version while phpup manages brew's. It now resolves the formula phpup actually manages — the same bug class as the apt `update-alternatives` fix in 1.1.0.
- **The dashboard reports the PHP Apache actually serves** — the version is read from the `LoadModule php_module` path in `httpd.conf`, not from the `php` CLI symlink. The two can point at different kegs (module on the meta `php`, symlink on a versioned `php@X.Y`); only the module describes what is really serving requests — the number `phpinfo` shows.
- **Apache's PHP module now follows the active formula** — `configure_apache` hardcoded `$(brew --prefix)/opt/php/lib/httpd/modules/libphp.so` and only appended the `LoadModule` line *if absent*, so an existing line was never rewritten. Switching PHP relinked the CLI and changed nothing that actually ran: Apache kept serving the previous keg's module. The path is now derived from the active formula and the line replaced (delete-then-add — the approach the MacPorts branch already used), so install, update and `fu` all repoint it, and the reported, served and managed versions can no longer drift apart.
- **`u` no longer upgrades the PHP formula it is switching away from** — it was added to the `brew upgrade` list alongside the target, so moving from `php@8.4` onto the newest line first compiled `php@8.4`'s own patch update as well: a wasted PHP build, and on an Intel Mac (where brew has no bottles) roughly half an hour of it. The outgoing formula is now left at its current patch — still installed, so `fu` can switch back — and its patch update is no longer advertised in the update list either.
- **`configure_php` no longer reads PHP's extension directory from bare `php`** — it asked `php -r 'echo PHP_EXTENSION_DIR;'`, so on a dual-stack Mac (MacPorts earlier on `PATH`) it got *MacPorts'* extension directory, found `.so` files belonging to the other stack, and uncommented `extension=mysqli` — plus `curl`, `gd`, `intl`, `mbstring`, `openssl`, `pdo_mysql`, `pdo_sqlite`, `sqlite3` — in **brew's** `php.ini`, where they do not exist and are not needed (Homebrew compiles them into the binary). Every PHP process then emitted ten `PHP Startup: Unable to load dynamic library` warnings on startup, and because the dashboard parses `php`'s stdout, all ten landed in the PHP row instead of the version. Extension enabling now uses THIS stack's binary (`stack_php_bin`), skips anything that binary already provides statically, and only then checks for a real `.so`. The `php.ini` discovery fallbacks (`php_ini_loaded_file()`, `php -i`) use the same binary, so they can no longer report the neighbouring stack's ini, and constant-only probes now pass `-n` so a damaged `php.ini` can never corrupt the dashboard again. Same PATH-shadowing bug class as the `detect_php` fix above.
- **`PHPPUP_BACKEND` is now honoured on Apple Silicon** — the Apple Silicon branch returned before the override was consulted, so `PHPPUP_BACKEND=port` was silently ignored there, despite both the README and `docs/MACOS.md` documenting it as working. The explicit choice is now evaluated first. The Apple Silicon *default* is unchanged (still Homebrew).

### Changed
- **Service Status labels PHP by how it is served** — `PHP-FPM` was hardcoded for every backend, so on macOS the dashboard read `PHP-FPM → Active (mod_php)`, contradicting itself. macOS now reports `mod_php` (PHP runs inside Apache); Linux keeps `PHP-FPM`.
- **phpup no longer drives brew's php-fpm on macOS** — Apache serves PHP via `mod_php` there, so the standalone `php-fpm` service is not part of this stack and is no longer started, stopped or killed. A stack genuinely wired to `proxy_fcgi` is still treated as FPM.
- **The Intel/Homebrew notice no longer sits on top of every dashboard** — `detect_backend` printed a two-line `[ WAIT ]` banner on *every* render, which made the top of the dashboard permanently noisy and used a waiting-state tag for a policy note. It is now spread across the three places it is actually useful: a clause on the dashboard header line (`Homebrew: /usr/local (Intel — PHP builds from source)`), a one-time `[ NOTE ]` that names the way out (`PHPPUP_BACKEND=port`), and — the part that matters — a cost warning **at the point of decision**, before the user commits to the build: above `u`'s apply prompt, in `fu` (only when the target formula still has to be built), and at install. Homebrew's own Intel notice appears only *after* the compile has started; phpup now says it beforehand.
- **New `print_note()` helper** — `[  NOTE ]` (cyan) for advisory messages, leaving `[  WAIT ]` to mean a genuine wait. Used by the Intel/Homebrew notices above.
- **Intel Macs now route to MacPorts** — Homebrew retired Intel x86_64 in September 2026 (Tier 3: no new bottles, source-compile only) and now tells Intel users to move to MacPorts, which still bottles the platform. `detect_backend` routes every Intel Mac to MacPorts regardless of macOS version. An existing Homebrew stack is still kept — rather than migrating a live stack and its databases out from under the user — but with a warning that names the cost and the `PHPPUP_BACKEND=port` route. `BREW_MIN_OS_MAJOR` is retired with it: the OS-version gate only ever applied to Intel.

### Docs
- README and `docs/MACOS.md` updated for `mod_php` reporting and the module re-pointing on `u`/`fu`; added a `PATH`-order troubleshooting note for `php -v` reporting another stack's PHP. Backend tables in the README and `docs/MACOS.md` corrected for the Intel retirement, and `docs/INSTALL-OLDER-MAC.md` re-scoped from "an older Mac (10.15–13)" to any Intel Mac.

### Verified
- `bash -n` OK · 12-assertion sandbox harness (real functions against a fake Homebrew prefix and a real `httpd.conf`): the module line is repointed in both directions, stays a single `LoadModule` line with a single `FilesMatch` block, and is idempotent across runs; the reported version follows the module and falls back to the active formula when the module line is missing, relative, or points at a missing keg. Stack pinning confirmed live both directions on the dual-stack Mac (ports `Stopped/Stopped/Stopped`, brew `Running/Running/Running`, `S` stopping the right stack; `R` single password prompt). apt/Linux paths untouched. The `fu` line list and the `u` cross-line detection are covered by an 11-assertion harness (real functions, stubbed brew: menu construction, alias normalisation, offline fallback, and a guard against ever offering a downgrade).

---

## [2.4.5-win] — 2026-09-06

### Windows (phpup.ps1 v2.4.5)

*Previous platform update: [2.4.4-win](#244-win--2026-08-30).*

Feature parity release: phpup refuses to start into ports another stack holds (IIS, Docker, XAMPP, a second database server...), mirroring the nix guard — and names the holder instead of failing blind.

### Added
- **Start refuses to run into another stack's ports** — `Assert-StackPortsFree` checks whether :80/:3306 are already listening (`Get-NetTCPConnection`, netstat fallback) before `Start-WebStackServices` runs, and all start paths (install, update, restart, S toggle) funnel through that one function. phpup's own running components are exempt, so restart over a live phpup stack passes.
- **Named holders** — `Get-PortHolderName` resolves the listener's PID via `Get-Process`, so the refusal reads `Port 80 is in use by another stack — httpd (PID 1234)` rather than leaving the user to run netstat themselves.

### Verified
- PS1 PARSE OK · mirrors the nix `check_stack_ports_free` guard, which was validated live on Debian 13 (silent pass over phpup's own stack, loud refusal with named holders for a brew/getphp stack)

---

## [1.2.5-nix] — 2026-09-06

### macOS & Linux (phpup.sh v1.2.5)

*Previous platform update: [1.2.4-nix](#124-nix--2026-09-06).*

Patch release from the Debian 13 live test: phpMyAdmin broke after an update with `Access denied for user 'pma'@'localhost'` — the controluser password in MariaDB had drifted from the one in phpup's config override.

### Fixed
- **Update flow no longer configures phpMyAdmin while MariaDB is stopped** — `cmd_update` stopped all services, ran `configure_phpmyadmin`, then started services. Every MariaDB step in PMA config (storage tables, control-user password) silently failed against the dead server, but the override was still rewritten, so the configured controlpass drifted from the DB. `configure_phpmyadmin` now runs after `start_services` in all three update branches (apt, MacPorts, Homebrew).
- **Control password is captured before the override rewrite** — the "reuse existing pass" logic read the override *after* the rewrite heredoc had erased it, so every configure generated a fresh random pass (and an update with MariaDB down wrote it without ever reaching the DB). The existing pass is now captured first and only generated when none exists.
- **Silent failures are now loud** — the pma control-user alignment only runs when MariaDB is reachable, verifies the login afterwards, and prints a warning (instead of `2>/dev/null || true`) whenever alignment is skipped or fails. Config stays stable when the DB is down.
- **Delete no longer reports a partial stack when brew/getphp shims remain** — apt PHP detection now only counts a dpkg-owned binary as the stack's PHP, so a Homebrew/getphp `php` left on PATH (brew shellenv in `~/.bashrc`) can't masquerade as the stack once delete removed the alternatives link.
- **Start refuses to run into another stack's ports** — `start_services` now checks whether :80/:3306 are already listening (ss, netstat fallback) before starting, and fails loudly instead of the old silent `systemctl start` + unconditional "[ OK ] Services started". phpup's own running services are exempt, so restart/reinstall over a live phpup stack still passes; install, restart and the S toggle all surface the failure.
- **Delete removes the apt MariaDB-generated `feedback.cnf`** — `feedback=OFF` is unknown to MySQL 26+ (aborts on start), and a brew/ports MySQL on Linux reads the same `/etc/mysql` include chain, so the file left in `/etc/mysql/mariadb.conf.d` would break a foreign MySQL after a phpup reinstall. Removed in the shared delete tail on all backends (harmless no-op on macOS); other `/etc` configs remain untouched.

### Verified
- `bash -n` OK · PS1 PARSE OK · live on Debian 13: PMA controluser drift reproduced + realigned (login OK), full delete → reinstall cycle restored t2 (8/8 tables) with clean "not installed" detection despite brew/getphp shims present, foreign-stack port guard refused with named holders (httpd/mysqld), feedback.cnf disabled lets brew MySQL start · Mac (brew/ports) leg still to run

---

## [1.2.4-nix] — 2026-09-06

### macOS & Linux (phpup.sh v1.2.4)

*Previous platform update: [1.2.3-nix](#123-nix--2026-09-06).*

Patch release from the fu live test on Debian 13 (PHP 8.6 alpha1): the fu menu listed pre-release series exactly like stable ones, making an alpha switch look like a routine bump.

### Changed
- **fu menu flags pre-release series** — a series whose apt candidate is an alpha/beta/RC (e.g. PHP 8.6 at `8.6.0~alpha1`) now carries a yellow `(pre-release)` marker in the version list, matching the honest-disclosure rule Windows fu has followed since v2.4.0. Pre-releases remain selectable for testing, just no longer silently.

### Verified
- `bash -n` OK · label logic dry-run (alpha/beta/RC flagged after lowercase, stable versions clean) · follows the Debian 13 live fu test that exposed the gap (8.6 alpha1 install + switch back to 8.5)

---

## [1.2.3-nix] — 2026-09-06

### macOS & Linux (phpup.sh v1.2.3)

*Previous platform update: [1.2.2-nix](#122-nix--2026-08-30).*

Patch release from the Debian 13 live test: the update check's "Updates available" list dumped every raw `apt list --upgradable` line (long sury archive suffixes, one line per PHP module), making a routine point-release look like a wall of noise.

### Changed
- **Update check groups pending updates per component family** — new `summarize_apt_outdated` helper collapses the raw apt lines into one readable row per family (`PHP 8.4   8.4.24 → 8.4.25   (16 packages)`), with versions stripped of epoch + Debian revision so only the upstream version shows. Apache and MariaDB each keep their own single line when they have updates. The package set actually upgraded is unchanged.

### Verified
- `bash -n` OK (repo + LF test copy) · summarizer dry-run against the live Debian 13 output (php8.4 ×16, php8.5 ×15 → two grouped lines, no packages dropped) · user live run of `u` on Debian 13 confirmed the summary display

---

## [2.4.4-win] — 2026-08-30

### Windows (phpup.ps1 v2.4.4)

*Previous platform update: [2.4.3-win](#243-win--2026-08-30).*

Patch release from the delete + reinstall live test: download UX clean-up and config-pointer simplification.

### Fixed
- **Download progress bars restored on the install/update path** — `Invoke-DownloadAndExtract` suppressed `$ProgressPreference` around the *entire* function, hiding the live progress bar for every component download (most painfully MariaDB, where a blank "Downloading..." line looked like the script had hung). Suppression now covers only the `Expand-Archive` steps; `Invoke-WebRequest` downloads render their progress bars again.
- **Delete/extract progress flash silenced** — `Remove-Item -Recurse` rendered "Removed X of Y files [MB at MB/s]" over the dashboard during delete, update, and install flows. New `Remove-Tree` helper (save/restore around the call) applied to all flow-level wipes: delete flow (all 5 components), update flow, install MariaDB upgrade branches (online + offline), SQLite temp dir, config/data backup-dir cleanup. Extract helpers and the fu apply block keep their existing scoped suppression.

### Changed
- **`%APPDATA%` discovery pointer written only for non-default install paths** — the legacy pointer at `%APPDATA%\phpup\config.json` is load-bearing only when the stack lives somewhere other than the default `C:\phpup` (custom/moved installs rediscover their location through it). Default-path installs no longer create the redundant file; `Get-Config` behavior unchanged, so custom-path discovery still works. Added `$DEFAULT_BASE` as the anchor constant.

### Verified
- PS1 PARSE OK · 11/11 progress behavior tests (no global suppression, download live, both `Expand-Archive` sites wrapped, `Remove-Tree` suppresses) · 5/5 pointer tests (default → no pointer, custom → pointer + refresh) · user delete → clear cache → reinstall live test: clean install display, no noise, download bars on all components, database backup restored, services up

---

## [2.4.3-win] — 2026-08-30

### Windows (phpup.ps1 v2.4.3)

*Previous platform update: [2.4.2-win](#242-win--2026-08-28).*

Patch release from the Windows live test: the fu download/extract path regressed in the v2.4.2 helper refactor, plus hardening for partial-stack recovery and version-swap data safety.

**Fixed**
- `fu` PHP download no longer produces a `True C:\phpup\downloads\...` path — `Invoke-WebRetry -OutFile` returned `$true` into the caller's output stream, so `Invoke-DownloadToCache` returned an array (`@($true, $path)`) instead of a string and `Expand-Archive` failed with "Cannot convert value to type System.String", wiping the PHP folder and cascading into a missing php.ini / Apache start failure (regression from the v2.4.2 retry-helper refactor)
- Apache configuration no longer appends duplicate `Listen 80` lines — the replace-vs-append decision compared content instead of presence, so an already-correct `Listen 80` was treated as missing and a new line was appended on every install/update, eventually failing with "Cannot define multiple Listeners" (`AH00526`); the step now removes every existing `Listen` line and appends exactly one (idempotent and self-healing)
- MariaDB upgrade during install now stops services, backs up the data directory, and restores it after extracting the new version — previously the install path extracted over the live install while the server was running (binaries locked, extraction silently failed and reported `[ OK ]`; had the server been stopped, a data-dir wipe was possible)
- Install no longer re-downloads/re-extracts phpMyAdmin when the installed version is already at or above the resolved version (matches the Apache/PHP/MariaDB skip logic)

**Added**
- Partial-stack recovery notice on the dashboard: when one or more components are missing (failed `fu` apply, manual deletion, partial install), the script now says so and tells the user that `I` Install recovers the missing components without touching websites, databases or settings

---

## [1.2.2-nix] — 2026-08-30

### macOS & Linux (phpup.sh v1.2.2)

*Previous platform update: [1.2.1-nix](#121-nix--2026-08-30).*

Patch release: MariaDB data-dir safety on the Mac/Linux fallback paths, mirroring the Windows data-safety fix.

### Changed
- **MariaDB data dir preserved before re-init** — the brew fallback in `configure_mariadb_brew` previously wiped `${BREW_PREFIX}/var/mysql` whenever root access couldn't be auto-confirmed; a user with a non-blank root password would lose every database. It now moves a populated data dir aside to `var/mysql.backup-<date>` and warns instead of destroying it; only an empty/missing dir is wiped for a fresh init.
- **Same protection on MacPorts** — the `datadir_initialized` failure path preserves an existing data dir (`.preserved-<date>`) when user databases are present alongside a missing `mysql/` system schema, instead of wiping the whole tree.

### Fixed
- ShellCheck SC2155 (declare-and-assign masking return values) on the two new backup-dir lines.

### Verified
- `bash -n` OK · ShellCheck 0 errors · brew guard sandbox 4/4 (populated preserved, empty wiped, missing fresh-init, system-schema-only preserved) · partial-stack notice shared dashboard (brew/ports included) · full fu round-trip + live stack checks on Ubuntu 24.04 (FPM path)

---

## [1.2.1-nix] — 2026-08-30

### macOS & Linux (phpup.sh v1.2.1)

*Previous platform update: [1.2.0-nix](#120-nix--2026-08-29).*

Patch release: partial-stack recovery visibility, matching the Windows dashboard behavior from v2.4.3.

**Added**
- Partial-stack recovery notice on the dashboard: when one or more components are missing (failed `fu` apply, manual deletion, partial install), the script now says so and tells the user that Install recovers the missing components without touching websites, databases or settings

---

## [1.2.0-nix] — 2026-08-29

### macOS & Linux (phpup.sh v1.2.0)

Feature release: phpup gains a **real, persistent config** — `config.json` now lives inside the install folder (`~/phpup/config.json`) on all platforms, with automatic migration of the legacy `~/.config/phpup` location on first run. *Previous platform update: [1.1.0-nix](#110-nix--2026-08-28).*

**Added**
- Config co-located with the stack: install folder on Linux/Mac (`~/phpup/config.json`) and Windows (`$BASE\config.json`)
- Legacy migration: pre-1.2.0 configs are moved automatically on first run (old directory removed)
- Windows: the old `%APPDATA%` config becomes a discovery pointer, refreshed on every save, so moved/custom-path stacks stay findable
- `php_min_series` config key — the minimum PHP series `fu` offers (default `8.2`)
- `PHPPUP_PHP_MIN_SERIES` environment override (precedence: env > config > default)
- `mariadb_port` / `php_port` persisted to config (detection prefers config; datadir sniff demoted to migration shim)

**Changed**
- Config schema flattened: `versions.apache` → `apache_version`, etc.
- `fu` floor filters and switch listing now read the configured floor instead of a hardcoded `8.2`

**Fixed**
- Floor comparison parsed major/minor correctly (previously compared `8` vs `8.2`, which excluded every version at the default floor — found live on Ubuntu 24.04)

**Verified**
- Live on Debian 13 and Ubuntu 24.04: migration, floor filtering (7.4/8.2/8.4), env override, corrupt-config fallback
- Windows config suite: 7/7 harness tests (migration, moved stack, pointer refresh, clear, corrupt fallback)

## [2.4.2-win] — 2026-08-28

### Windows (phpup.ps1 v2.4.2)

*Previous platform update: [2.4.1-win](#241-win--2026-08-18).*

**Added**
- Dashboard Process Status now reports the real PHP integration state instead of `CLI available`: `mod_php ------> active` (green) when the module is wired and Apache is running, `stopped` (red) when Apache is down, `not wired` (yellow) when the LoadModule line is missing or points at a dead DLL, and `not installed` (red) when php.exe is absent
- New helper `Test-PhpApacheModuleWired` — verifies httpd.conf carries the LoadModule line for the **current** PHP major's symbol (`php_module` for 8.x, `php7_module` for 7.x) and that the referenced DLL exists, catching a stale module line after a broken version switch

**Changed**
- Dashboard Process Status ordering groups the web server with its PHP engine: `Apache`, `mod_php`, `MariaDB` (PHP row moved directly under Apache, mirroring the Mac/Linux `Active (mod_php)` / `Stopped` status pattern)

---

## [1.1.0-nix] — 2026-08-28

### macOS & Linux (phpup.sh v1.1.0)

Feature release: the Linux web stack moves from the monolithic `mod_php` Apache module to **Apache + PHP-FPM** (`mod_proxy_fcgi` → `phpX.Y-fpm`), with automatic migration of existing mod_php installs. *Previous platform update: [1.0.2-nix](#102-nix--2026-08-21).*

**Added**
- Linux PHP now runs as **PHP-FPM**: versioned `phpX.Y-fpm` packages, managed Apache conf (`/etc/apache2/conf-available/phpup-php-fpm.conf`) routing `.php` through `mod_proxy_fcgi` to the active version's socket, `proxy`/`proxy_fcgi` enabled, legacy `libapache2-mod-php*` disabled
- Dashboard Service Status reports the live FPM runtime — `PHP-FPM -----> Running (8.5)` / `Stopped (8.5)` — while the Web Stack row shows the CLI version, and both re-detect on every render so they can never go stale
- `fu` version switch moves CLI (`update-alternatives`) + FPM service + Apache wiring together, with full-stack rollback (service, conf, CLI) if the target FPM fails to start or verify
- Same-version `fu` selection on a legacy mod_php box now runs the migration (install FPM packages, rewire Apache, disable mod_php) instead of short-circuiting
- phpMyAdmin apt config now writes a stable `blowfish_secret` (no more "temporary key" warning) and uses `/var/lib/phpmyadmin/tmp` for the template cache (Debian's php-fpm unit ships `ProtectSystem=full`, making `/usr/share` unwritable by FPM)

**Fixed**
- apt PHP version detection resolves via `update-alternatives` instead of bare `php` from PATH — a getphp/Homebrew php shim on PATH (from `brew shellenv` in `~/.bashrc`) could report the wrong active version, block `fu` switches, and desync the dashboard rows
- `systemctl stop php*-fpm` / `is-active php*-fpm` glob does not match FPM units — stop/detect each installed FPM version by explicit unit name so `S` (toggle) actually stops PHP-FPM with Apache and MariaDB

**Performance**
- Benchmark (identical workload, same load tool, same hardware): FPM vs mod_php throughput is within ~12% at low concurrency; at 100 concurrent requests mod_php's Apache exhausted prefork workers and died mid-run while FPM stayed up — FPM's win is robustness under concurrency plus a lower memory footprint, not raw speed. See [docs/LINUX.md](docs/LINUX.md)

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
| [**panel 0.2.2-beta**](#panel-022-beta-win--2026-11-23) | 2026-11-23 | A remembered window position is verified against the current monitors before it is restored, and an unreachable one is never written back — the panel can no longer launch off-screen |
| [**2.5.6-win**](#256-win--135-nix--2026-11-27) / [**1.3.5-nix**](#256-win--135-nix--2026-11-27) | 2026-11-27 | `u` downloads every zip before it deletes anything and MariaDB's archive URL is built from the full release; MacPorts install and update follow the newest series in the tree (PHP 8.6, MariaDB 13.1) with a dump-restore move; `$FALLBACK_URLS` and the docs track the current stack |
| [**2.5.5-win**](#255-win--134-nix--2026-11-22) | 2026-11-22 | The handover refuses instead of half-committing (unreadable start type, refused boot-disable, failed registry write); `sc.exe`-free process image paths off the polling path; `--remove`, alias ambiguity refusal and `active_path` |
| [**panel 0.2.1-beta**](#panel-021-beta-win--2026-11-22) | 2026-11-22 | Output pane takes the slack under the cards, `Links` menu, About back in the header, green/red chips on all four cards, a refresh slider that re-polls, window geometry remembered |
| [**2.5.4-win**](#254-win--133-nix--2026-11-21) | 2026-11-21 | `switch` reaches Windows and gains `--add`, which registers a stack without touching the ports; the switch payload is one shape on both platforms; a pre-release install no longer passes as the matching stable |
| [**panel 0.2.0-beta**](#panel-020-beta-win--2026-11-21) | 2026-11-21 | Stacks block: registered XAMPP roots, one-click handover of 80/3306 and back, add-a-root by path; taller window, smaller console default |
| [**2.5.3-win**](#253-win--2026-11-13) | 2026-11-13 | `u` resolves the real latest PHP again (rebuild suffixes hid 8.2–8.5); version parsing and the pinned fallback fixed; `fu` lists alpha/beta/RC builds from the QA index; `config.json` written without a BOM; `status` stops forking `php.exe` every poll |
| [**2.5.2-win**](#252-win--2026-11-09) | 2026-11-09 | PHP switching no longer aborts on a healthy staged tree under Windows PowerShell 5.1 (`$null` exit code read as a failure) |
| [**2.5.1-win**](#251-win--131-nix--2026-11-01) | 2026-11-01 | Sessions moved to a stack-owned store out of the Windows temp directory; PHP on Windows can make HTTPS requests at all (OpenSSL 4 + CA bundle); streamed install path fixed; `fu` stages and verifies a PHP switch instead of deleting first, and lists every supported PHP series; `u` stops claiming success when the stack stays down |
| [**panel 0.1.0-beta**](#panel-010-beta-win--2026-10-22) | 2026-10-22 | First Windows beta of the desktop panel: tray-first launch, Start with Windows, per-service startup type, release zip with install.ps1 |
| [**2.5.0-win**](#250-win--130-nix--2026-10-22) | 2026-10-22 | Machine-readable CLI (`status`/`start`/`stop`/`restart`, `--json`, `--watch`) + Rust control panel; upgrades stop the stack before re-extracting PHP and verify the extensions load |
| [**2.4.5-win**](#245-win--2026-09-06) | 2026-09-06 | Refuses to start into another stack's ports; names the holder |
| [**2.4.4-win**](#244-win--2026-08-30) | 2026-08-30 | Download progress bars restored, delete/extract progress silenced, %APPDATA% pointer default-path only |
| [**2.4.3-win**](#243-win--2026-08-30) | 2026-08-30 | fu download `True` path fix, Listen dedupe, partial-stack recovery notice, MariaDB data backup before upgrade, PMA skip |
| [**2.4.2-win**](#242-win--2026-08-28) | 2026-08-28 | Dashboard mod_php status + wiring check, Process Status reorder |
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
| [**1.3.4-nix**](#255-win--134-nix--2026-11-22) | 2026-11-22 | Handover aborts before phpup's boot state is touched when the registry write fails; a refused `systemctl disable` is read back and warned about instead of swallowed; `--remove`, `active_path`, `foreign_active` marker |
| [**1.3.3-nix**](#254-win--133-nix--2026-11-21) | 2026-11-21 | `switch --add` registers a stack without touching the ports; the switch payload is one shape on both platforms; the handover logic is covered by the harness (34 → 42 checks on a POSIX host) |
| [**1.3.2-nix**](#132-nix--2026-11-20) | 2026-11-20 | `switch` hands the ports to XAMPP and back on macOS/Linux; a foreign stack is attributable without root; `brew services` runs as the invoking user; the registry remembers the stack and survives an elevated run |
| [**1.3.1-nix**](#251-win--131-nix--2026-11-01) | 2026-11-01 | Sessions moved into the stack (`~/phpup/sessions`) on brew, apt and MacPorts; streamed installs report their version; dashboards readable on dark and light terminals; `u` stops claiming success when the stack stays down; apt update no longer blocks on a dpkg conffile prompt |
| [**1.3.0-nix**](#250-win--130-nix--2026-10-22) | 2026-10-22 | Machine-readable CLI (`status`/`start`/`stop`/`restart`), `--json`, `--watch`, documented exit codes |
| [**1.2.7-nix**](#127-nix--2026-09-13) | 2026-09-13 | `fu` version-switch menu: stderr stream contract, 1-based selection, unlink guard |
| [**1.2.6-nix**](#126-nix--2026-09-12) | 2026-09-12 | Stack-aware service status, Apache PHP module follows the active formula, dashboard reports the served PHP |
| [**1.2.5-nix**](#125-nix--2026-09-06) | 2026-09-06 | Update flow PMA control-user password drift fixed (configure after start, stable pass) |
| [**1.2.4-nix**](#124-nix--2026-09-06) | 2026-09-06 | fu menu flags pre-release series (alpha/beta/RC) |
| [**1.2.3-nix**](#123-nix--2026-09-06) | 2026-09-06 | Update check groups pending apt updates per component family |
| [**1.2.2-nix**](#122-nix--2026-08-30) | 2026-08-30 | MariaDB data dir preserved before re-init (brew + ports), SC2155 cleanup |
| [**1.2.1-nix**](#121-nix--2026-08-30) | 2026-08-30 | Partial-stack recovery notice (dashboard) |
| [**1.1.0-nix**](#110-nix--2026-08-28) | 2026-08-28 | Apache + PHP-FPM, mod_php auto-migration, rollback-safe fu, PMA secret/tmp fixes |
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
