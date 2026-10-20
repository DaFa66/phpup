# phpup panel

A desktop control panel for phpup. Rust + egui (glow), one static binary.

It is a **control surface**, not a second implementation: everything it shows and does comes
from the phpup CLI contract (`phpup.ps1 status --watch`, `start|stop|restart --json`). See
`.junk/cli-contract.md` in the repo root.

## What works

- Live state from `status --watch --fast`: Apache, PHP, MariaDB and phpMyAdmin cards with
  version, running state, PIDs, ports, SAPI and service names.
- Chips for stack state, service mode, registration and platform.
- Start / Restart / Stop, idempotent, repainting from the verb's own JSON.
- Exit code handling: 4 shows an "Administrator required" banner with a relaunch button,
  5 names the process holding the port, 3 says the stack is not installed.
- Output pane: every line phpup writes to stderr, plus panel events. Follow/pause, copy,
  clear, resizable split, capped at 2000 lines.
- Theme: System / Light / Dark, persisted. System follows the OS via egui.
- Tray icon and menu (Show panel, Start, Stop, Restart, Quit). Closing the window hides to
  the tray; Quit lives in the tray menu.
- Quick links: localhost, phpMyAdmin, logs, www folder.

## Not yet

`install`, `update` and `fu`. They are interactive in the scripts today (install path,
service registration, database restore, version menu), so the panel would hang on the first
prompt. They need a non-interactive mode with streamed progress first:

```
install --yes          # defaults: C:\phpup, register services = yes, restore data = yes, never reboot
update  --yes
fu      --yes --to 8.4.5
```

with NDJSON on stdout: `{"event":"step",...}`, `{"event":"log",...}`, `{"event":"done",...}`.

## Build

```
cd panel
cargo build            # debug
cargo build --release  # ~7 MB binary, no runtime dependencies
```

Requires Rust (stable) and, on Windows, the MSVC linker from VS Build Tools.

**Windows quirk on this machine:** a lowercase `tmp` environment variable points into a
`.hermes-tmp` directory, and Windows resolves `tmp` as `TMP`. MSVC's linker then chases a
nonexistent path and fails with `LNK1104`. Override it for the build:

```
export tmp="C:\\Users\\<you>\\AppData\\Local\\Temp"
export TMP="$tmp" TEMP="$tmp"
cargo build
```

## Assets

- `assets/favicon-*.png` are generated from `../images/favicon.svg` (tracked, because the
  `images/` folder is git-ignored):
  ```
  magick -background none -density 512 ../images/favicon.svg -resize 256x256 assets/favicon-256.png
  magick assets/favicon-256.png -resize 64x64 assets/favicon-64.png
  magick assets/favicon-256.png -resize 32x32 assets/favicon-32.png
  ```
  They are embedded with `include_bytes!` for the title bar and the tray.
- `../images/phpup-logo1.jpg` is loaded at runtime for the header tile and the Settings card.
  If it is missing the panel still runs, just without the logo.

## Settings

`%APPDATA%\phpup\panel.json` (or `$XDG_CONFIG_HOME/phpup/panel.json`):

```json
{ "theme": "system", "script": null, "interval": 2 }
```

`script` is auto-detected when null: walks up from the executable, then `~/phpup`,
`~/dev/phpup`, `D:/dev/phpup`, `C:/phpup`.
