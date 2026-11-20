# Release Guide

How phpup is versioned and how a release is cut. Short version: every release gets a tag,
and fixes move the last digit.

## Versioning

- `phpup.ps1` (Windows) and `phpup.sh` (macOS/Linux) are versioned independently, tagged with
  the `-win` and `-nix` suffixes. **Each script releases when it has something to release.** A fix
  that only touches one script bumps only that script, and ships under its own tag: `2.5.3-win`,
  then `2.5.2-win`, were Windows-only rounds, and `1.3.2-nix` was macOS/Linux-only. When both
  change in the same round they share a date and keep their own numbers, as `[2.5.1-win] /
  [1.3.1-nix]` did. There is no rule that forces the untouched script to move, which would put a
  version on code that never changed.
- **Last digit — patch.** Bug fixes, corrections and small behaviour changes. Most releases are
  these: `2.5.3` → `2.5.4`, `1.3.2` → `1.3.3`.
- **Middle digit — feature milestone.** A release that genuinely adds a capability worth calling
  out: a new backend, a cross-series PHP upgrade, platform parity, a new component.
- **First digit — structural.** Rebrand, breaking change, or a platform dropped.
- The desktop panel is released separately with its own numbering (`panel-v0.1.0-beta-win`).
- Headers hold the **last released** version. The bump happens as the release commit, never while
  work is still landing — that is how the numbers drifted before.

## Cutting a release

1. Land the work on `main`. Commit messages carry the harness or test output that proves it.
2. Bump the version **of the script(s) that changed**, everywhere that script's version is stated.
   A Windows-only round does not touch `phpup.sh`, and vice versa.
   - `phpup.ps1` — header `#  Version:` **and** `$script:VERSION_CACHE` (the fallback used when
     the script is streamed and there is no file to read)
   - `phpup.sh` — header `#  Version:` **and** `PHPUP_VERSION`
   - `docs/CLI.md` — status line, `version --json` example, `status` payload example, banner
     example, and section 10
   - `panel/README.md` — the "phpup X+ for the CLI verbs" requirement
   - any CHANGELOG bullet that names a version (e.g. the dashboard banner example)
3. `CHANGELOG.md`:
   - retitle the top section for the platform(s) that ship: `## [x.y.z-win]` for a Windows-only
     round, `## [x.y.z-nix]` for macOS/Linux only, or
     `## [x.y.z-win] / [x.y.z-nix] — YYYY-MM-DD` when both move together. Anything not released
     stays under `## [Unreleased]`.
   - the subheading names only the scripts that moved: `### Windows (phpup.ps1 vX)`,
     `### macOS/Linux (phpup.sh vY)`, or both when both moved
   - entries under `### Added` / `### Changed` / `### Fixed`, newest first
   - add a row per released version to the Version History Summary table, with the anchor matching
     the heading slug (`## [1.3.2-nix]` → `#132-nix--2026-11-20`;
     `## [2.5.1-win] / [1.3.1-nix]` → `#251-win--131-nix--2026-11-01`)
   - panel work that ships separately stays under `## [Unreleased]`
4. Documentation that describes the behaviour lands in the same commit: `docs/WINDOWS.md`,
   `docs/LINUX.md`, `docs/MACOS.md`, `docs/CLI.md`.
5. Verify before tagging:

   ```
   pwsh -NoProfile -File ./phpup.ps1 version
   bash phpup.sh version
   pwsh -NoProfile -Command '$e=$null; $null=[System.Management.Automation.Language.Parser]::ParseFile("phpup.ps1",[ref]$null,[ref]$e); "parse errors: " + $e.Count'
   bash -n phpup.sh
   git grep -n -E "<previous version>" -- phpup.sh phpup.ps1 docs README.md panel/README.md
   # no stale numbers in code or docs. CHANGELOG history will always match; that is correct.
   ```

6. Commit the bump on its own, then tag the tip:

   ```
   git tag -a v2.5.3-win -m "phpup 2.5.3 (Windows) — <headline>"
   git push origin main v2.5.3-win
   ```

7. GitHub Releases are opt-in. Tags are the record by default; release pages are only cut when
   Simon asks for them.

## Fixing a wrong tag

Delete it before cutting the right one. Never move a tag that has a GitHub Release attached —
cut a new patch instead.

```
git tag -d v2.6.0-win v1.4.0-nix
git push origin :refs/tags/v2.6.0-win :refs/tags/v1.4.0-nix
```

## Releases

| Tag | Date | Milestone |
|---|---|---|
| `v2.5.4-win` / `v1.3.3-nix` | 2026-11-21 | `switch --add` registers a stack without touching the ports; the switch payload is one shape on both platforms (`to` a string, `stack` an array); the handover logic is covered by the harness (34 → 42 checks on a POSIX host); `foreign_exe_running`, an absolute brew path and the last two silenced `brew services start` calls |
| `panel-v0.2.0-beta-win` | 2026-11-21 | Stacks block: registered XAMPP roots with one-click handover of 80/3306 and back, and a path field that registers further installs |
| `v1.3.2-nix` | 2026-11-20 | `switch` lands on macOS/Linux — hand 80/3306 to XAMPP and back, with the registry in `foreign_stacks.tsv`; live testing fixed attribution without root, `brew services` as the invoking user, a free-ports no-op, registry ownership after an elevated run, and the `sbin/mysqld` version probe |
| `v2.5.3-win` | 2026-11-13 | `u` resolves the real latest PHP again (rebuild-suffixed releases hid 8.2–8.5), version parsing and the pinned fallback fixed, `fu` lists alpha/beta/RC builds from the QA index, `config.json` written without a BOM, `status` stops forking `php.exe` every poll |
| `v2.5.2-win` | 2026-11-09 | PHP switching no longer aborts on a healthy staged tree under Windows PowerShell 5.1 (`$null` exit code read as a failure) |
| `v2.5.1-win` / `v1.3.1-nix` | 2026-11-01 | Sessions in a stack-owned store on both platforms, Windows HTTPS fixed (OpenSSL 4 + CA bundle), `fu` stages and verifies PHP switches and offers every supported series |
| `v2.5.0-win` / `v1.3.0-nix` | 2026-10-22 | Machine-readable CLI (`status`/`--json`/`--watch`) and the Rust control panel |
| `panel-v0.1.0-beta-win` | 2026-10-22 | First Windows panel beta |
| `v1.0.0-nix` | 2026-08-11 | First stable release (macOS/Linux) |
| `v0.9.0-beta-nix` | 2026-08-07 | Cross-series PHP upgrade, dashboard parity (macOS/Linux) |
| `v2.2.0-win` / `v1.1.0-nix` | 2026-07-25 | First cross-platform release |
| `v2.0.0-win` | 2026-06-28 | Rebrand from getPHP to phpup (Windows) |
| `v1.0.0-win` | 2026-06-05 | First Windows release |
