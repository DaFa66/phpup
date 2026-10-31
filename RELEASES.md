# Release Guide

How phpup is versioned and how a release is cut. Short version: every release gets a tag,
and fixes move the last digit.

## Versioning

- `phpup.ps1` (Windows) and `phpup.sh` (macOS/Linux) are versioned independently, tagged with
  the `-win` and `-nix` suffixes. Both move together at release time, each keeping its own numbers.
- **Last digit — patch.** Bug fixes, corrections and small behaviour changes. Most releases are
  these: `2.5.0` → `2.5.1`, `1.3.0` → `1.3.1`.
- **Middle digit — feature milestone.** A release that genuinely adds a capability worth calling
  out: a new backend, a cross-series PHP upgrade, platform parity, a new component.
- **First digit — structural.** Rebrand, breaking change, or a platform dropped.
- The desktop panel is released separately with its own numbering (`panel-v0.1.0-beta-win`).
- Headers hold the **last released** version. The bump happens as the release commit, never while
  work is still landing — that is how the numbers drifted before.

## Cutting a release

1. Land the work on `main`. Commit messages carry the harness or test output that proves it.
2. Bump the version everywhere it is stated:
   - `phpup.ps1` — header `#  Version:` **and** `$script:VERSION_CACHE` (the fallback used when
     the script is streamed and there is no file to read)
   - `phpup.sh` — header `#  Version:` **and** `PHPUP_VERSION`
   - `docs/CLI.md` — status line, `version --json` example, `status` payload example, banner
     example, and section 10
   - `panel/README.md` — the "phpup X+ for the CLI verbs" requirement
   - any CHANGELOG bullet that names a version (e.g. the dashboard banner example)
3. `CHANGELOG.md`:
   - retitle the top section `## [x.y.z-win] / [x.y.z-nix] — YYYY-MM-DD`
   - keep the subheading `### Windows (phpup.ps1 vX) and macOS/Linux (phpup.sh vY)`
   - entries under `### Changed` and `### Fixed`, newest first
   - add **both** rows to the Version History Summary tables, with anchors matching the heading
     slug (`## [2.5.1-win] / [1.3.1-nix]` → `#251-win--131-nix--2026-11-01`)
   - panel work that ships separately stays under `## [Unreleased]`
4. Documentation that describes the behaviour lands in the same commit: `docs/WINDOWS.md`,
   `docs/LINUX.md`, `docs/MACOS.md`, `docs/CLI.md`.
5. Verify before tagging:

   ```
   pwsh -NoProfile -File ./phpup.ps1 version
   bash phpup.sh version
   pwsh -NoProfile -Command '$e=$null; $null=[System.Management.Automation.Language.Parser]::ParseFile("phpup.ps1",[ref]$null,[ref]$e); "parse errors: " + $e.Count'
   bash -n phpup.sh
   git grep -n -E "2\.6\.0|1\.4\.0" -- .     # no stale numbers left behind
   ```

6. Commit the bump on its own, then tag the tip:

   ```
   git tag -a v2.5.1-win -m "phpup 2.5.1 (Windows) — <headline>"
   git tag -a v1.3.1-nix -m "phpup 1.3.1 (macOS/Linux) — <headline>"
   git push origin main v2.5.1-win v1.3.1-nix
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
| `v2.5.1-win` / `v1.3.1-nix` | 2026-11-01 | Sessions in a stack-owned store on both platforms, Windows HTTPS fixed (OpenSSL 4 + CA bundle), `fu` stages and verifies PHP switches and offers every supported series |
| `v2.5.0-win` / `v1.3.0-nix` | 2026-10-22 | Machine-readable CLI (`status`/`--json`/`--watch`) and the Rust control panel |
| `panel-v0.1.0-beta-win` | 2026-10-22 | First Windows panel beta |
| `v1.0.0-nix` | 2026-08-11 | First stable release (macOS/Linux) |
| `v0.9.0-beta-nix` | 2026-08-07 | Cross-series PHP upgrade, dashboard parity (macOS/Linux) |
| `v2.2.0-win` / `v1.1.0-nix` | 2026-07-25 | First cross-platform release |
| `v2.0.0-win` | 2026-06-28 | Rebrand from getPHP to phpup (Windows) |
| `v1.0.0-win` | 2026-06-05 | First Windows release |
