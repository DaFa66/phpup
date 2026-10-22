# phpup panel: cross-platform port plan

Status: proposed, not started. Written 2026-10-22.

This is a plans document: it describes intended work, not shipped behaviour. To
install phpup or the panel, see the [README](../README.md) and
[panel/README.md](../panel/README.md).

## Why this is cheaper than it looks

Measured in the repo, not assumed:

- `phpup.sh` already emits the **same schema-1 payload** as `phpup.ps1` (`phpup.sh:4213`):
  `platform`, `install`, `services.items`, `components`, `urls`, `paths`, `logs`, `ports`,
  `warnings`. The panel parses it unchanged.
- `phpup.sh` implements `status --json`, `--fast`, `--watch N` and
  `start|stop|restart --json` (`phpup.sh:4302-4409`, action JSON at `4321`).
- The panel already chooses its script per platform: `script_name()` returns `phpup.ps1` or
  `phpup.sh`, and `build_command()` has a `#[cfg(not(windows))]` branch that runs
  `bash phpup.sh <verb>`.
- Every dependency is cross-platform: `eframe 0.37` (glow, x11, wayland), `tray-icon 0.24`,
  `serde`, `serde_json`, `image`.
- Windows-only code is 8 functions in `backend.rs`: `find_in_path`, `build_command`,
  `run_elevated`, `run_elevated_sc`, `check_phpup_service`, `set_service_start`,
  `autostart_enabled`, `set_autostart`. Plus one settings-path branch in `main.rs`.

So this is a port of an action layer plus builds, packaging and wording. No second UI, no
fork, no rewrite of the data path.

## Architecture

New module `panel/src/platform.rs`. Same public surface on every OS, cfg-gated internals:

| Function | Windows | Linux | macOS |
| --- | --- | --- | --- |
| `set_service_start(name, mode)` | `sc.exe config start=` | `systemctl enable/disable` | `brew services start/stop` |
| `autostart_enabled()` / `set_autostart(bool)` | `HKCU\...\Run` | XDG autostart `.desktop` | LaunchAgent plist |
| `elevate(cmd)` | `Start-Process -Verb RunAs` | `pkexec` + polkit policy | none (brew is per-user) |
| `open_path(target)` | `explorer`/`cmd start` | `xdg-open` | `open` |

Rules carried over from today's work:

1. The panel never learns platform quirks: state always comes from the script's JSON.
2. Settings stay one file with one shape; unknown keys are ignored per platform.
3. UI wording is per-platform (`Start with Windows` vs `Start at login`), never a lie.
4. Start / Restart / Stop remain process controls everywhere; startup type stays boot
   behaviour. That separation is what took all evening to get right, do not undo it.

## Phase 0 - extract `platform.rs` (0.5-1 day)

1. Create `panel/src/platform.rs`; move the 8 Windows functions there, add Linux and macOS
   implementations (stubs that return `Unsupported` until each phase).
2. Replace direct `backend::` calls in `main.rs` with `platform::`.
3. Per-platform label constants for "Start with Windows" / "Start at login" and the
   privileges row.
4. Hide Settings -> Privileges on non-Windows (UAC concept does not exist there).

Verify: Windows build behaves identically (rebuild, tray start, autostart toggle, service
chips), `cargo clippy` clean, no new warnings.

## Phase 1 - Linux x64 (2-3 days)

Decision needed: elevation. `systemctl` needs root, so either `pkexec` with an installed
polkit `.policy` (clean GUI prompt, needs packaging) or spawning a terminal for the `sudo`
prompt (simpler, uglier).

Tasks:

1. `set_service_start`: `systemctl enable|disable <unit>`, read state with `is-enabled`.
2. Autostart: `~/.config/autostart/phpup-panel.desktop` pointing at the binary, with
   `Hidden=` removal to turn it off. Mirrors the Run-key semantics closely.
3. Tray: document `libayatana-appindicator3` as a runtime dependency; note that stock GNOME
   needs the AppIndicator extension or the icon is invisible.
4. Package as AppImage (`.desktop` entry, icon, `AppRun`) or tarball; decide whether `.deb`
   and `.rpm` are worth it.
5. CI job on `ubuntu-22.04` with the X11/Wayland dev libs.

Verify: needs a real Linux desktop, not WSL. WSLg is enough to prove it renders, but not to
prove tray behaviour or polkit prompts.

## Phase 2 - Linux ARM64 (0.5-1 day)

1. Build with `cross` or a native ARM64 runner; identical AppImage.
2. Verify on ARM64 hardware (VM or Pi). Watch for `glow`/GL driver differences on Pi.

## Phase 3 - macOS Intel + Apple Silicon (2-3 days plus paperwork)

Decision needed: notarisation. An unsigned `.app` is blocked by Gatekeeper, so either buy a
Developer ID (about GBP 79/year, `codesign` + `notarytool` + stapling) or ship unsigned and
document right-click-Open plus `xattr -d com.apple.quarantine`.

Tasks:

1. `.app` bundle: `Info.plist`, `.icns` from `images/favicon.svg`.
2. Universal binary via `lipo` (or two artefacts). Builds must run on macOS runners
   (`macos-13` x64, `macos-14` arm64); this cannot be cross-compiled from Windows.
3. `set_service_start` via `brew services start|stop`, state via `brew services list`.
4. Wording: `brew services start` both starts the service **and** registers it at login, so
   Auto/Disabled stops being independent of Start/Stop. Label accordingly instead of
   pretending the platforms agree.
5. Autostart: LaunchAgent plist in `~/Library/LaunchAgents`, or lean on brew's own login item.
6. Hide Privileges; the panel stays unelevated.
7. Package as `.dmg`, sign, notarise, staple.

Verify: on both Intel Macs available for testing, and on Apple Silicon. Confirm Gatekeeper
opens the app cleanly from a fresh download.

## Phase 4 - Windows ARM64 (0.5 day)

1. `cargo build --release --target aarch64-pc-windows-msvc`.
2. Same UAC and registry code path, so no code change.
3. Surface the emulation fact: on ARM64 the PHP stack runs x64 under emulation (see
   `phpup-windows-arm64`), so the panel should say so rather than implying native binaries.

## Phase 5 - docs and release (0.5 day)

1. `README.md`: platform matrix for the panel.
2. `docs/MACOS.md` and `docs/LINUX.md`: panel sections, tray dependency, elevation model.
3. `panel/README.md`: per-OS requirements, build and packaging.
4. `CHANGELOG.md`: panel version bump (suggest 0.2.0) with the port.
5. Release artefacts named per target; document where each one installs.

## Risks, worst first

1. **Linux tray visibility.** `libayatana-appindicator3` plus a GNOME extension. Same class of
   problem as the Windows tray confusion, and less obvious to diagnose.
2. **polkit UX.** Wording, no credential caching, and a `.policy` file that must be installed
   by the package rather than dropped next to the binary.
3. **macOS notarisation.** Cost, account, certificates, and stapling failures that only show
   on a clean machine.
4. **macOS semantic coupling.** `brew services` couples "start now" with "start at login", so
   the clean two-axis model from Windows does not survive intact.
5. **ARM build infrastructure.** No ARM hardware on hand; everything must be proven on CI,
   with Pi/VM spot checks.
6. **WSLg is not a Linux desktop.** It proves pixels, not tray, polkit, or autostart.

## Open decisions

1. Linux elevation: `pkexec` with a polkit policy, or a terminal `sudo` prompt?
2. Apple: pay for notarisation, or ship unsigned with instructions?
3. Packaging: AppImage only, or also `.deb` and `.rpm`?
4. Panel version: bump to 0.2.0 when the port lands?
