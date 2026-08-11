# Release Policy

phpup uses **milestone-based releases** — we tag only when a significant
threshold is crossed, not for every patch or feature.

## What qualifies as a milestone

- **Cross-platform parity** — a new platform lands, or all three platforms reach equivalent capability
- **Major architectural feature** — cross-series PHP upgrade, new package backend, structural rework
- **Stability threshold** — `-beta` suffix dropped, production-ready declaration
- **Breaking changes or rebrands** — renamed project, changed defaults, removed platform support

## What doesn't

- Individual bug fixes
- Documentation updates
- Minor UX polish (colours, labels, layout)
- Single-platform features without cross-platform significance

## The CHANGELOG is the record

Every change — large and small — is documented in [`CHANGELOG.md`](CHANGELOG.md) regardless
of whether it gets a tag. Tags are the curated headlines; the changelog is the
permanent historical record.

## Current milestones

| Tag | Date | Milestone |
|---|---|---|
| `v1.0.0-win` | 2026-06-05 | First Windows release — original fork contribution |
| `v2.0.0-win` | 2026-06-28 | Rebrand from getPHP to phpup (Windows) |
| `v2.2.0-win` | 2026-07-25 | First cross-platform release (Windows) |
| `v1.1.0-nix` | 2026-07-25 | First cross-platform release (macOS/Linux) |
| `v0.9.0-beta-nix` | 2026-08-07 | Cross-series PHP upgrade, dashboard parity (macOS/Linux) |
| `v1.0.0-nix` | 2026-08-11 | First stable — production-ready (macOS/Linux) |
