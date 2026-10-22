# phpup panel

A desktop control surface for phpup. Rust + egui (glow), one static binary, no webview and
no Node toolchain.

**Panel version 0.1.0, beta** — Windows x64. Tagged and downloadable as a pre-release.
It is a beta: expect rough edges, and read the known limits in the release notes before
trusting it with a stack you care about.

It is a control surface, not a second implementation: everything it shows and does comes
from the phpup CLI (`phpup.ps1 status --watch --fast`, `start|stop|restart --json`), whose
contract is documented in [`../docs/CLI.md`](../docs/CLI.md). The scripts remain the single
source of truth for installation, updates and version switching.

## Install from a release

Download `phpup-panel-0.1.0-beta-win-x64.zip` from
[Releases](https://github.com/DaFa66/phpup/releases), extract it, then run:

```
.\install.ps1              # installs into <install_path>\bin, default C:\phpup\bin
.\install.ps1 -NoStart     # install without launching it
```

`install.ps1` copies `phpup-panel.exe`, then prints the installed path and its SHA256. It
needs no elevation and writes no registry keys. `-Destination <dir>` installs elsewhere.
Compare the checksum with the release notes if you want to be sure the download is intact.

To build it yourself instead, see Build below.

## Requirements

- Windows 10/11 (x64). The panel is Windows-first; it builds on macOS and Linux but service
  control and elevation are Windows paths today.
- phpup 2.5.0+ for the CLI verbs. On an older `phpup.ps1` the panel says "not usable" and
  waits rather than guessing.
- To compile: Rust stable and the MSVC linker from Visual Studio Build Tools.

## What works

- **Component cards** — Apache, PHP, MariaDB, phpMyAdmin: version, running state, PIDs,
  ports, SAPI and registered service names, refreshed from `status --watch`.
- **Start / Restart / Stop** above the cards, idempotent, repainting from each verb's own
  JSON. Disabled states are explicit (`idle`, `all_up`, `start_on`, `stop_on`) rather than
  greyed-out guesswork.
- **Exit codes as behaviour**, never as parsed text: 4 raises the administrator banner, 5
  names the process holding the port, 3 says the stack is not installed.
- **Output pane** — every line phpup writes to stderr plus panel events: monospace
  scrollback capped at 2000 lines, follow/pause that releases when you scroll up, copy,
  clear, resizable split.
- **Administrator mode** — per-action by default; optional always-elevated panel with
  `phpup - as administrator` in the title bar. See below.
- **Settings slide-out** — Status, Services, Appearance, Zoom, Window, Startup, Privileges,
  Source, Refresh. Closes with Escape, the Close button, or a click outside.
- **Service startup type** — per registered service, `Auto` or `Disabled`, applied with
  `sc.exe config <name> start=`. Settings owns boot behaviour only; `Start` / `Restart` /
  `Stop` above the cards are the process controls.
- **Start in the tray** — optional launch with no window and no taskbar button, tray icon
  only. Off by default, in which case the window opens.
- **Start with Windows** — optional per-user `Run` entry written with `reg.exe`, so it never
  needs elevation. Off by default.
- **About popup** — panel version, live phpup version, GitHub link, one-paragraph summary.
- **Tray** — favicon icon, menu of Show panel / Start / Stop / Restart / Quit. Closing the
  window hides to the tray; Quit drops the icon and exits.
- **Quick links** — localhost, phpinfo, phpMyAdmin, logs, www folder, on their own row
  beneath the component cards so the settings slide-out cannot push them into the buttons.
- **Hover states** — buttons lighten, take an accent edge and grow a fraction on hover. The
  effect lives in `theme.rs`, so it applies to every button rather than per call site.
- **Theme and zoom** — System / Light / Dark, and Auto / 85% / 100% / 115% / 130%. Auto
  follows the monitor's DPI. Accent colours are Trongate's own: `--primary #4682b4`,
  `--primary-dark #38678f`, white text.

## Administrator model

phpup registers Windows services, so start/stop/restart need elevation. Two modes:

| Mode | Behaviour |
| --- | --- |
| Per action (default) | The panel stays a normal user. The first action that returns exit 4 shows a banner; accepting raises the panel (relaunch with the pending verb handed over) or elevates just that one verb. |
| Always run as administrator | Turned on in Settings → Privileges. The panel raises itself at launch, then every action runs without asking again. |

Raising the panel relaunches it elevated, hands any pending verb over via `--run <verb>`,
drops the tray icon and exits — one prompt, one window, one tray icon. Elevation is detected
with `whoami /groups` (~20ms) rather than by spawning PowerShell.

## Build

```
cd panel
cargo build            # debug
cargo build --release  # release binary, no runtime dependencies
```

The release binary is ~7.4 MB (7,729,664 bytes measured on Windows 11 x64) and needs no
runtime — no .NET, no VC++ redistributable beyond what the MSVC toolchain already links
statically.

**Windows quirk on this machine:** a lowercase `tmp` variable points into a `.hermes-tmp`
directory and Windows resolves `tmp` as `TMP`, so MSVC's linker chases a path that does not
exist and dies with `LNK1104`. Override it for the build:

```
export tmp="C:\\Users\\<you>\\AppData\\Local\\Temp"
export TMP="$tmp" TEMP="$tmp"
cargo build --release
```

Do not enable eframe's `accesskit` feature: its `windows` crate dependency crashes rustc
here. Do enable `clipboard` — without it egui has no clipboard at all and both the Copy
button and Ctrl+C silently do nothing (that was a real bug, not a UI glitch).

## Install a local build

1. Build the release binary (above).
2. Create the target folder and copy it in:

   ```
   mkdir C:\phpup\bin
   copy panel\target\release\phpup-panel.exe C:\phpup\bin\
   ```

3. Run it once. The favicons are embedded; `images/phpup-logo1.jpg` is optional and the
   panel runs without it.
4. Settings → **Source** picks where `phpup.ps1` comes from: GitHub (default, so a fresh
   install works before the CLI is published) or Local file. With Local, leave the path
   blank and the panel walks up from the executable, then checks `~/phpup`, `~/dev/phpup`,
   `D:/dev/phpup`, `C:/phpup`. Whatever it resolves is written back to the settings file.

## Run at startup

**Settings → Startup → Start with Windows** is the built-in option. It writes a per-user
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` entry pointing at the panel binary,
so it needs no elevation and no scheduled task. The checkbox reads the registry rather than a
stored copy, so it always shows what Windows will actually do at sign-in.

Pair it with **Settings → Window → Start hidden in the tray** to log in to a clean taskbar:
the panel launches with no window and no taskbar button, and the tray icon brings it up when
you want it. With that toggle off, the panel opens its window at logon.

**Task Scheduler** is still the way to start the panel *elevated* at logon, which the Run
entry cannot do:

```
schtasks /Create /TN "phpup panel" /TR "\"C:\phpup\bin\phpup-panel.exe\"" /SC ONLOGON /RL HIGHEST /F
schtasks /Query  /TN "phpup panel" /V /FO LIST
schtasks /Delete /TN "phpup panel" /F
```

`/RL HIGHEST` starts the panel elevated, so the title bar reads `phpup - as administrator`
and start/stop/restart never prompt. Do not use both: the Run entry and the task would each
launch a panel.

## Settings

`%APPDATA%\phpup\panel.json` (or `$XDG_CONFIG_HOME/phpup/panel.json`):

```json
{
  "theme": "system",
  "source": "local",
  "script": "D:\\dev\\phpup\\phpup.ps1",
  "interval": 2,
  "zoom": 0.0,
  "always_admin": false,
  "start_in_tray": false
}
```

| Key | Meaning |
| --- | --- |
| `theme` | `system`, `light`, `dark` |
| `source` | `github` or `local` |
| `script` | Resolved path; written back after discovery so it is never ambiguous |
| `interval` | Seconds between `status --watch` ticks |
| `zoom` | `0.0` = Auto (follow monitor DPI), otherwise 0.85 / 1.0 / 1.15 / 1.3 |
| `always_admin` | Start elevated (Settings → Privileges) |
| `start_in_tray` | Launch with no window and no taskbar button, tray icon only |

## Troubleshooting

- **`error: failed to remove ... phpup-panel.exe` / Access denied** — an elevated instance
  is still running and a normal-user build cannot overwrite it. Close it from the tray, or
  kill it from an elevated shell: `taskkill /PID <pid> /F`.
- **LNK1104 during build** — the `tmp`/`TMP` quirk above.
- **Window larger than the screen** — the panel sizes itself to 90% of the monitor on the
  first frame, so this should not happen; at 200% scaling a fixed 980×700 would not fit.
- **Copy does nothing** — the `clipboard` feature is missing from eframe. See Build.
- **Output shows "not usable: ... (exit 1)"** — you are on the GitHub source and the
  published `phpup.ps1` predates the CLI. Switch to Local until 2.5.0 ships.
- **Screenshotting the settings panel** — set `PHPUP_PANEL_OPEN_SETTINGS=1` to open it at
  launch.
- **Panic log** — `%LOCALAPPDATA%\phpup\panel\panic.log`. The release build has no console
  at all, so this is the only crash trail.

## Not yet

- `install`, `update` and `fu` are not wired: they are interactive in the scripts today
  (install path, service registration, database restore, version menu) so the panel would
  hang at the first prompt. They need `--yes` flags plus NDJSON progress:
  `{"event":"step"}`, `{"event":"log"}`, `{"event":"done"}`.
- No release packaging or installer for the panel itself.
- No single-instance guard: launching the panel while an elevated copy runs gives you two.
- Window geometry is not persisted between runs.

## Assets

`assets/favicon-*.png` are generated from `../images/favicon.svg` (tracked, because the
`images/` folder is git-ignored) and embedded with `include_bytes!` for the title bar and
tray:

```
magick -background none -density 512 ../images/favicon.svg -resize 256x256 assets/favicon-256.png
magick assets/favicon-256.png -resize 64x64 assets/favicon-64.png
magick assets/favicon-256.png -resize 32x32 assets/favicon-32.png
```
