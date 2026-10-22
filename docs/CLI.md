# phpup CLI contract (v1)

Machine-readable status and non-interactive control, so a GUI, tray app, or CI job can
drive phpup without the interactive dashboard.

Non-goal: a daemon, a socket API, or a rewrite of the install/update engine.

**Status:** implemented — `phpup.ps1` 2.5.0 on Windows and `phpup.sh` 1.3.0 on macOS/Linux,
both unreleased. The Windows desktop panel in [`panel/`](../panel/README.md) consumes this
contract; it is the reason the contract exists.

---

## 1. Invocation

Windows:

```
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\phpup\phpup.ps1 status -Json
```

macOS / Linux:

```
/bin/bash ~/phpup/phpup.sh status --json
```

`-NoProfile` is not optional for the GUI: a profile costs 200-400ms and the panel polls.

No arguments = today's interactive dashboard, byte-for-byte unchanged.

---

## 2. Verbs (v1)

| Verb      | Side effects | Notes                                              |
|-----------|--------------|----------------------------------------------------|
| `status`  | none         | read-only probe, never writes, never prompts       |
| `start`   | starts       | idempotent                                         |
| `stop`    | stops        | idempotent                                         |
| `restart` | stop + start | idempotent                                         |
| `version` | none         | prints script version, no config or stack access   |
| `help`    | none         | usage text, exit 0                                 |

Reserved for v2, do not alias these names: `install`, `update`, `delete`, `switch`, `doctor`.

### `version` output

Both scripts answer `version`, and with `--json` they emit a single object and nothing else:

```json
{ "schema": 1, "version": "2.5.0", "script": "ps1" }
```

`script` is `ps1` on Windows and `sh` on macOS/Linux, so a caller can tell which
implementation answered. The same pair appears as `phpup.version` and `phpup.script` in
the `status` payload (section 6), and it is required on both scripts — consumers must not
infer the running version from the components. Each interactive dashboard prints it on the
architecture line, and the desktop panel shows it in its About popup.

## 3. Flags

| Flag | PowerShell | Meaning |
|------|-----------|---------|
| `--json` | `-Json` | payload on stdout |
| `--fast` | `-Fast` | `status` only: skip prerequisites and OS caption |
| `--watch N` | `-Watch N` | `status` only: repeat every N seconds as NDJSON, implies JSON |
| `--quiet` | `-Quiet` | suppress human log lines on stderr |
| `--no-color` | `-NoColor` | strip ANSI (auto-off in `--json`, auto-off when not a tty) |
| `--help` | `-Help` | usage |
| `--version` | `-Version` | version line |

`-Offline` stays as-is and is orthogonal.

---

## 4. I/O rules (hard requirements)

1. **stdout carries only the payload.** No banner, no spinner, no colour, no progress.
2. **stderr carries human logs.** Free, once stdout is redirected (see §8).
3. **Never read stdin.** No `Read-Host`, no `read`, in any CLI path. Enforce with a guard that
   throws if an interactive prompt is reached while a verb is active.
4. **Never require a TTY.** `phpup.sh`'s `main()` currently opens with `exec < /dev/tty`;
   CLI mode must skip that.
5. **No ANSI escapes in the payload** in `--json` mode.
6. **`status` must not write to disk.** Today the pre-loop block syncs `services_registered`
   into `config.json`; CLI mode skips that write.

---

## 5. Exit codes

| Code | Meaning |
|-----:|---------|
| 0 | success. For `status`: probe completed, regardless of stack state |
| 1 | operation failed (target state not reached) |
| 2 | usage error (unknown verb or flag) |
| 3 | not installed (verb needs a stack that is absent or incomplete) |
| 4 | elevation required |
| 5 | blocked by a port conflict / another stack holding the port |

`--json` repeats the same code in the payload as `ok` + `code`. Consumers branch on the
numeric code first and the message second.

Rationale for 0 on `status` when the stack is absent: the probe succeeded, "absent" is data
(`install.state`), not an error. Verbs that cannot act return 3.

---

## 6. `status` schema v1

```json
{
  "schema": 1,
  "generated_at": "2026-10-20T12:34:56+11:00",
  "phpup": { "version": "2.5.0", "script": "ps1" },
  "platform": {
    "os": "windows",
    "arch": "x86_64",
    "backend": "direct",
    "distro": "Windows 11 Pro 23H2"
  },
  "install": {
    "path": "C:\\phpup",
    "state": "complete",
    "config_file": "C:\\phpup\\config.json"
  },
  "services": {
    "mode": "service",
    "registered": true,
    "autostart": true
  },
  "components": {
    "apache": {
      "installed": true, "version": "2.4.68", "running": true,
      "pids": [4321], "ports": [80],
      "service": "phpup_Apache", "owned_by_phpup": true, "notes": null
    },
    "php": {
      "installed": true, "version": "8.5.9", "label": "8.5.9", "prerelease": false,
      "running": null, "pids": [], "ports": [],
      "sapi": "apache2handler", "cli_on_path": true, "series_floor": "8.2", "notes": null
    },
    "mariadb": {
      "installed": true, "version": "12.3.2", "running": true,
      "pids": [5122], "ports": [3306],
      "service": "phpup_MariaDB", "owned_by_phpup": true, "notes": null
    },
    "phpmyadmin": {
      "installed": true, "version": "5.2.3", "running": null,
      "pids": [], "ports": [],
      "url": "http://localhost/phpmyadmin", "notes": null
    }
  },
  "urls": {
    "root": "http://localhost/",
    "phpmyadmin": "http://localhost/phpmyadmin",
    "phpinfo": "http://localhost/phpinfo.php"
  },
  "paths": {
    "www": "C:\\phpup\\www",
    "logs": "C:\\phpup\\logs",
    "downloads": "C:\\phpup\\downloads"
  },
  "logs": {
    "apache_error": "C:\\phpup\\logs\\apache_error.log",
    "apache_access": "C:\\phpup\\logs\\apache_access.log",
    "php_errors": "C:\\phpup\\logs\\php_errors.log",
    "mariadb_error": "C:\\phpup\\logs\\mariadb_error.log"
  },
  "prerequisites": {
    "vc_redist": { "ok": true, "version": "14.51.36231", "minimum": "14.51.36231" }
  },
  "ports": [
    { "port": 80,   "listening": true,  "ours": true,  "owner": "httpd (PID 4321)" },
    { "port": 3306, "listening": true,  "ours": true,  "owner": "mariadbd (PID 5122)" }
  ],
  "warnings": [],
  "errors": []
}
```

### Field rules

- **Every declared key is always present.** Unknown or not-applicable values are `null`,
  never omitted. Consumers index blindly, no defensive `??`.
- `components.php.running` is `null` where "running" is meaningless (mod_php inside Apache,
  or CLI-only). Use `sapi` to interpret: `apache2handler`, `fpm`, `cli`.
- `pids` and `ports` sorted ascending, unique.
- `ports` covers only the stack's ports (80, 3306, plus configured overrides), not a
  full socket dump.
- `prerequisites` is `null` on macOS/Linux.
- `backed` enums: `services.mode` = `none` | `process` | `service` | `mixed`;
  `install.state` = `absent` | `partial` | `complete`;
  `platform.backend` = `direct` | `brew` | `apt` | `ports`.
- `warnings` / `errors` entries: `{ "code": "...", "component": "...|null", "message": "human text" }`.
  Codes in v1: `port_conflict`, `services_not_registered`, `stack_partial`,
  `php_prerelease`, `vc_redist_missing`, `php_not_on_path`, `php_apache_module_missing`,
  `foreign_stack_detected`.
- `generated_at` is ISO-8601 with UTC offset. Consumers exclude it from equality checks.

### Evolution

Additive changes only within `schema: 1`. Renames, removals, or enum changes require
`schema: 2`, and the consumer must then refuse to guess. A panel built against schema 1
should warn, not crash, if it sees a higher schema.

---

## 7. `start` / `stop` / `restart` semantics

- **Idempotent.** `start` when already running: exit 0, `changed: false`.
- **Port precheck** reuses the existing `Assert-StackPortsFree` /
  `check_stack_ports_free` logic, exempting phpup's own processes. Conflict: exit 5,
  `code: "port_conflict"`, and no start is attempted.
- **Bounded wait inside the verb.** Apache health check plus MariaDB readiness, then report
  the final observed state. The GUI does not blind-poll after a verb.
- **Never prompt for service registration.** If unregistered, start in process mode and
  emit `services_not_registered`. That is the interactive state-D path minus the question.
- **Elevation.** Windows service mode and service registration need admin. If needed and
  absent: exit 4, `code: "elevation_required"`, message names the action. The GUI relaunches
  elevated.
- **Verb payload:**

```json
{
  "schema": 1,
  "ok": true,
  "code": null,
  "action": "start",
  "changed": true,
  "components": { "apache": { "...": "post-state" } },
  "warnings": [],
  "errors": []
}
```

`components` is the same shape as `status.components` after the action, so the GUI repaints
from the verb response without a second call.

---

## 8. Implementation notes

### phpup.ps1

- Param block becomes: `[Parameter(Position=0)][string]$Command`, `[switch]$Json`,
  `[switch]$Fast`, `[switch]$Quiet`, `[switch]$NoColor`, plus the existing `[switch]$Offline`.
- Dispatch immediately after the config load and path derivation (~line 3440), **before**
  `while ($true) { Show-Dashboard ... }`, then `exit $code` there so the trailing `Pause`
  never runs.
- `$OS_CAPTION = (Get-CimInstance Win32_OperatingSystem).Caption` at line 24 executes on
  every invocation (~150-300ms). Move it behind a lazily-called `Get-PlatformCaption`, used
  by the dashboard and by full `status` only.
- Skip the pre-loop config sync write when `$Command` is set (it can call `Save-Config`).
- stdout is already clean: `Write-Host` writes to the information stream, not stdout. Emit
  the payload with `Write-Output` only. `ConvertTo-Json -Depth 6 -Compress` for one line.
- Derivation sources, all existing: `Test-*-Installed`, `Get-*-Version`, `Test-*-Running`,
  `Test-ServicesInstalled`, `Test-TcpPortListening`, `Get-PortHolderName`,
  `Test-VcRedistInstalled`, `Get-VcRedistVersion`, `Get-Config`.
- **PID filtering gap:** `Test-ApacheRunning` matches any `httpd` on the machine. For the
  payload, filter `Get-Process` results by `ExecutablePath` starting with `$BASE` and set
  `owned_by_phpup: false` when a listener on 80/3306 belongs to someone else.

### phpup.sh

- `main()` opens with `exec < /dev/tty`. Add `parse_args "$@"` before it; for CLI verbs skip
  the tty reconnect entirely.
- Redirect at CLI entry, so the existing `print_*` helpers land on stderr with zero edits:

  ```bash
  exec 3>&1 1>&2      # fd3 = original stdout (payload), fd1 = stderr from here on
  ... verb runs, human output goes to stderr ...
  printf '%s\n' "$json" >&3
  ```

- Derivation sources: `detect_all` (sets `STACK` and version globals), `is_service_running`,
  `tcp_port_listening`, `port_holder_label`, `load_config`, and `USE_APT` / `USE_PORTS` for
  `platform.backend`.
- **Naming trap:** `config.json`'s `mariadb_port` and `php_port` hold MacPorts *port names*
  (`mariadb-12.3`, `php85`), not TCP port numbers. Do not map them to numeric ports. Map to
  the component's `version`, and report TCP `3306` for `ports`. Renaming those keys is a
  later config migration, not v1.
- **MariaDB log path differs per backend:** MacPorts writes
  `${PORT_PREFIX}/var/log/${MARIADB_PORT}/mariadb_error.log`; brew and apt use
  `${LOGS_DIR}/mariadb_error.log`. `status` reports the path it would actually tail.

---

## 9. Performance budget (as measured, not as hoped)

| Path | Target | Measured |
|------|--------|----------|
| `status --fast --json`, Windows, one process per call | ≤ 400ms | **1.15s** (0.85s of that is PowerShell startup) |
| `status --fast` tick inside `--watch`, Windows | — | **237ms** |
| `status --json` full, Windows | ≤ 800ms | **2.0s** |
| `status --fast --json`, Linux | ≤ 150ms | **340ms** |

The Windows numbers are dominated by `pwsh` process startup (~850ms), which no amount of
lazy loading can remove. That is why `--watch` exists: at a 2s interval, one process per poll
would hold roughly 40% of a core just starting up, whereas a resident `--watch` costs about
12%, and at a 3s interval about 8%.

What the lazy work removed: `Get-CimInstance` OS caption (530-1100ms, now a registry read at
~2ms), `Get-NetTCPConnection` (3.8s, now a .NET listener enumeration at ~60ms), the duplicate
VC++ registry scan (~400ms), and three binary version probes (`httpd -v` alone is 579ms).
Full status on Windows went from 5.7s to 2.0s; `status` on Linux from 0.74s to 0.34s.

Fast path avoids `Get-CimInstance`, full `netstat -ano`, `sc queryex` and all binary probes.

GUI cadence: run `--watch 2` (or 3) as the poll source and take a full `status --json` every
30s for prerequisites and the OS caption.

---

## 10. Versioning and docs

- `phpup.ps1` → **2.5.0** (new functionality), `phpup.sh` → **1.3.0**.
- CHANGELOG entries, newest first.
- README gains a short **Automation** section with the two invocation lines above.
- This contract lives in `.junk/` until implemented, then promotes to `docs/CLI.md`.

---

## 11. Test checklist (before merge)

1. **stdout purity:** `... status -Json | python -c "import json,sys; json.load(sys.stdin)"`
2. **no tty:** `timeout 10 ~/phpup/phpup.sh status --json < /dev/null`; Windows via
   `-RedirectStandardInput NUL`.
3. **no prompt:** every verb with stdin closed and a 10s timeout; none may hang.
4. **idempotency:** `start` twice, second reports `changed: false`, exit 0.
5. **exit codes:** `stop` with the stack absent → 3; `start` with port 80 held by a foreign
   process → 5; service-mode `stop` unelevated → 4.
6. **schema:** key set matches §6; absent component → `installed: false` plus nulls.
7. **no disk writes from `status`:** record `config.json` mtime before and after.
8. **interactive regression:** no args still renders the dashboard and handles
   `I U R S D Q fu` exactly as before.

---

## 12. Decisions (settled)

1. `status` returns **0** on a machine with no stack, with `install.state: "absent"`. Exit 3 is
   reserved for verbs that cannot act. Confirmed.
2. **Registered services are reported on every platform**, not just Windows:
   `services.registered` plus a `services.items[]` array of `{name, registered, enabled}`.
   On apt that is the `apache2` / `mariadb` units and their `is-enabled` state; on brew and
   MacPorts it is the presence of the launchd plists.
3. **`--watch` is in v1**, because measurement forced the decision: process startup is
   0.85s on Windows, so a GUI polling with one process per tick would burn real CPU. `--watch`
   holds one process open and emits one NDJSON line per interval. Everything expensive is
   lazy: OS caption, version probes, prerequisite scans.
