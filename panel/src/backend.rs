//! Bridge to the phpup CLI.
//!
//! The panel never parses human output: it reads the JSON contract
//! (`.junk/cli-contract.md`) from `status --watch` for live state and from
//! one-shot `start|stop|restart --json` calls for actions.

use serde::Deserialize;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::thread;

// ---------------------------------------------------------------- payload

fn null_vec<'de, D, T>(d: D) -> Result<Vec<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::Deserialize<'de>,
{
    Ok(Option::<Vec<T>>::deserialize(d)?.unwrap_or_default())
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct Pkg {
    #[serde(default)]
    pub version: Option<String>,
    /// Present in the payload for completeness; the panel runs the script it
    /// resolved itself, so this is informational only.
    #[allow(dead_code)]
    #[serde(default)]
    pub script: Option<String>,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct Platform {
    #[serde(default)]
    pub os: Option<String>,
    #[serde(default)]
    pub arch: Option<String>,
    #[serde(default)]
    pub backend: Option<String>,
    #[serde(default)]
    pub distro: Option<String>,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct Install {
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub state: Option<String>,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct SvcItem {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default, deserialize_with = "bool_or_false")]
    pub registered: bool,
    #[serde(default, deserialize_with = "bool_or_false")]
    pub enabled: bool,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct Services {
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default, deserialize_with = "bool_or_false")]
    pub registered: bool,
    #[serde(default, deserialize_with = "bool_or_false")]
    pub autostart: bool,
    #[serde(default, deserialize_with = "null_vec")]
    pub items: Vec<SvcItem>,
}

/// The contract allows `null` for anything that is not known yet, including
/// booleans (fast status cannot ask the SCM, PHP has no process of its own).
/// Missing knowledge is not a parse error: it is false.
fn bool_or_false<'de, D>(deserializer: D) -> Result<bool, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(Option::<bool>::deserialize(deserializer)?.unwrap_or(false))
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct Component {
    #[serde(default, deserialize_with = "bool_or_false")]
    pub installed: bool,
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default)]
    pub running: Option<bool>,
    #[serde(default, deserialize_with = "null_vec")]
    pub pids: Vec<u32>,
    #[serde(default, deserialize_with = "null_vec")]
    pub ports: Vec<u16>,
    #[serde(default)]
    pub service: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub sapi: Option<String>,
    #[serde(default, deserialize_with = "bool_or_false")]
    pub cli_on_path: bool,
}

impl Component {
    pub fn running(&self) -> bool {
        self.running.unwrap_or(false)
    }
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct Components {
    #[serde(default)]
    pub apache: Component,
    #[serde(default)]
    pub php: Component,
    #[serde(default)]
    pub mariadb: Component,
    #[serde(default)]
    pub phpmyadmin: Component,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct Urls {
    #[serde(default)]
    pub root: Option<String>,
    #[serde(default)]
    pub phpmyadmin: Option<String>,
    #[serde(default)]
    pub phpinfo: Option<String>,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct Paths {
    #[serde(default)]
    pub www: Option<String>,
    #[serde(default)]
    pub logs: Option<String>,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct PortInfo {
    #[serde(default)]
    pub port: u16,
    #[serde(default, deserialize_with = "bool_or_false")]
    pub listening: bool,
    #[serde(default, deserialize_with = "bool_or_false")]
    pub ours: bool,
    #[serde(default)]
    pub owner: Option<String>,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct Warning {
    #[serde(default)]
    pub code: Option<String>,
    #[serde(default)]
    pub component: Option<String>,
    #[serde(default)]
    pub message: Option<String>,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct Status {
    #[serde(default)]
    pub schema: u32,
    #[serde(default)]
    pub generated_at: Option<String>,
    #[serde(default)]
    pub phpup: Pkg,
    #[serde(default)]
    pub platform: Platform,
    #[serde(default)]
    pub install: Install,
    #[serde(default)]
    pub services: Services,
    #[serde(default)]
    pub components: Components,
    #[serde(default)]
    pub urls: Urls,
    #[serde(default)]
    pub paths: Paths,
    #[serde(default, deserialize_with = "null_vec")]
    pub ports: Vec<PortInfo>,
    #[serde(default, deserialize_with = "null_vec")]
    pub warnings: Vec<Warning>,
}

impl Status {
    pub fn stack_state(&self) -> &str {
        self.install.state.as_deref().unwrap_or("unknown")
    }

    pub fn any_running(&self) -> bool {
        self.components.apache.running()
            || self.components.mariadb.running()
            || self.components.php.running()
    }

    pub fn all_running(&self) -> bool {
        self.components.apache.running() && self.components.mariadb.running()
    }
}

#[derive(Debug, Deserialize, Clone, Default)]
#[allow(dead_code)] // mirrors the contract; the panel reads exit codes instead
pub struct ActionResult {
    #[serde(default)]
    pub ok: bool,
    #[serde(default)]
    pub code: Option<String>,
    #[serde(default)]
    pub action: Option<String>,
    #[serde(default)]
    pub changed: bool,
    #[serde(default, deserialize_with = "null_vec")]
    pub errors: Vec<String>,
}

// ------------------------------------------------------------------ events

pub enum Event {
    Status(Box<Status>),
    /// One line of human output from phpup (its stderr channel).
    Log(String),
    /// The elevated instance is starting, so this one should shut down.
    Relaunched(Result<(), String>),
    ActionFinished {
        verb: String,
        exit: i32,
        result: Option<ActionResult>,
        raw: String,
    },
    Failed(String),
}

// ---------------------------------------------------------------- platform

#[cfg(windows)]
fn find_in_path(exe: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|d| d.join(exe))
        .find(|p| p.is_file())
}

#[cfg(windows)]
fn build_command(script: &Path, verb: &str, extra: &[String]) -> Command {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    // pwsh 7 when present (slightly faster startup), 5.1 otherwise. Both work.
    let exe = if find_in_path("pwsh.exe").is_some() {
        "pwsh.exe"
    } else {
        "powershell.exe"
    };
    let mut c = Command::new(exe);
    c.arg("-NoProfile")
        .arg("-NonInteractive")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-File")
        .arg(script)
        .arg(verb);
    for e in extra {
        match e.strip_prefix("--") {
            Some(flag) => {
                let mut chars = flag.chars();
                let mut name = String::from("-");
                if let Some(first) = chars.next() {
                    name.push(first.to_ascii_uppercase());
                    name.push_str(chars.as_str());
                }
                c.arg(name);
            }
            None => {
                c.arg(e);
            }
        }
    }
    c.creation_flags(CREATE_NO_WINDOW);
    c
}

#[cfg(not(windows))]
fn build_command(script: &Path, verb: &str, extra: &[String]) -> Command {
    let mut c = Command::new("bash");
    c.arg(script).arg(verb);
    for e in extra {
        c.arg(e);
    }
    c
}

/// Where the panel gets phpup from.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Source {
    /// Published script from the phpup repo, cached locally. The default.
    Github,
    /// A checkout on disk, for phpup development.
    Local,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::Github => "github",
            Source::Local => "local",
        }
    }

    pub fn from_str(s: &str) -> Self {
        if s.eq_ignore_ascii_case("local") {
            Source::Local
        } else {
            Source::Github
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Source::Github => "GitHub",
            Source::Local => "Local file",
        }
    }
}

const REMOTE_PS1: &str = "https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.ps1";
const REMOTE_SH: &str = "https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.sh";

pub fn remote_url() -> &'static str {
    if cfg!(windows) {
        REMOTE_PS1
    } else {
        REMOTE_SH
    }
}

pub fn cache_dir() -> Option<PathBuf> {
    #[cfg(windows)]
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
    #[cfg(not(windows))]
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| home_dir().map(|h| h.join(".cache")));
    base.map(|b| b.join("phpup").join("panel"))
}

pub fn cached_script() -> Option<PathBuf> {
    cache_dir().map(|d| d.join(script_name()))
}

/// Download the published script into the panel cache. Uses the platform's own
/// downloader: one less dependency, and it inherits whatever proxy the user
/// already has configured.
pub fn fetch_remote() -> Result<PathBuf, String> {
    let dir = cache_dir().ok_or("no cache directory available")?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let dest = dir.join(script_name());
    let part = dir.join(format!("{}.part", script_name()));
    let url = remote_url();

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let ps = format!(
            "try {{ Invoke-WebRequest -UseBasicParsing -Uri '{url}' -OutFile '{}' -TimeoutSec 30; exit 0 }} \
             catch {{ Write-Error $_.Exception.Message; exit 1 }}",
            part.display()
        );
        let mut c = Command::new("powershell.exe");
        c.arg("-NoProfile")
            .arg("-NonInteractive")
            .arg("-Command")
            .arg(ps);
        c.creation_flags(CREATE_NO_WINDOW);
        let out = c.output().map_err(|e| e.to_string())?;
        if !out.status.success() {
            let msg = String::from_utf8_lossy(&out.stderr).trim().to_string();
            return Err(if msg.is_empty() {
                "download failed".to_string()
            } else {
                msg
            });
        }
    }

    #[cfg(not(windows))]
    {
        let out = Command::new("curl")
            .args(["-fsSL", "--max-time", "30", "-o"])
            .arg(&part)
            .arg(url)
            .output()
            .map_err(|e| e.to_string())?;
        if !out.status.success() {
            return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
        }
    }

    std::fs::rename(&part, &dest).map_err(|e| e.to_string())?;
    Ok(dest)
}

/// Ask the script to identify itself in JSON.
///
/// This is how the panel distinguishes a CLI-capable phpup build from an older
/// published one, instead of discovering it through parse errors later.
pub fn probe_cli(script: &Path) -> Result<String, String> {
    let mut cmd = build_command(script, "version", &["--json".to_string()]);
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let out = cmd.output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!("exit {}", out.status.code().unwrap_or(-1)));
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let line = stdout
        .lines()
        .find(|l| l.trim_start().starts_with('{'))
        .ok_or("no JSON on stdout")?;
    let value: serde_json::Value = serde_json::from_str(line.trim()).map_err(|e| e.to_string())?;
    value
        .get("version")
        .and_then(|v| v.as_str())
        .map(|v| v.to_string())
        .ok_or_else(|| "no version field".to_string())
}

/// The script to run for the chosen source.
pub fn resolve_script(source: Source, saved: Option<&String>) -> Result<PathBuf, String> {
    match source {
        Source::Github => {
            let cached = cached_script().ok_or("no cache directory available")?;
            if cached.is_file() {
                Ok(cached)
            } else {
                fetch_remote()
            }
        }
        Source::Local => {
            discover_script(saved).ok_or_else(|| "no local phpup script found".to_string())
        }
    }
}

fn script_name() -> &'static str {
    if cfg!(windows) {
        "phpup.ps1"
    } else {
        "phpup.sh"
    }
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
}

/// Find the phpup script: an explicit choice first, then the usual places.
pub fn discover_script(saved: Option<&String>) -> Option<PathBuf> {
    if let Some(s) = saved {
        let p = PathBuf::from(s);
        if p.is_file() {
            return Some(p);
        }
    }

    let name = script_name();
    let mut candidates: Vec<PathBuf> = Vec::new();

    // Walk up from the executable: panel/target/debug/panel.exe -> repo root.
    if let Ok(exe) = std::env::current_exe() {
        let mut dir = exe.parent().map(|p| p.to_path_buf());
        for _ in 0..6 {
            let Some(d) = dir else { break };
            candidates.push(d.join(name));
            candidates.push(d.join("..").join(name));
            dir = d.parent().map(|p| p.to_path_buf());
        }
    }

    if let Some(home) = home_dir() {
        candidates.push(home.join("phpup").join(name));
        candidates.push(home.join("dev").join("phpup").join(name));
        candidates.push(home.join(".config").join("phpup").join(name));
    }
    candidates.push(PathBuf::from(format!("D:/dev/phpup/{name}")));
    if cfg!(windows) {
        candidates.push(PathBuf::from(format!("C:/phpup/{name}")));
    } else {
        candidates.push(PathBuf::from(format!("/usr/local/share/phpup/{name}")));
    }

    candidates.into_iter().find(|p| p.is_file()).map(normalize)
}

/// Absolute, `\\?\`-free path: the raw walk-up candidates read like
/// `panel\..\phpup.ps1` and that is what would end up in the UI.
fn normalize(path: PathBuf) -> PathBuf {
    let canonical = std::fs::canonicalize(&path).unwrap_or(path);
    #[cfg(windows)]
    {
        let text = canonical.to_string_lossy().to_string();
        if let Some(stripped) = text.strip_prefix(r"\\?\") {
            return PathBuf::from(stripped.to_string());
        }
    }
    canonical
}

// ----------------------------------------------------------------- backend

pub struct Backend {
    pub script: PathBuf,
    pub interval: u32,
}

impl Backend {
    pub fn new(script: PathBuf, interval: u32) -> Self {
        Self { script, interval }
    }

    /// Long-lived `status --watch`, parsed line by line. One process instead of
    /// one per poll: process startup is ~0.85s on Windows.
    pub fn spawn_watch(&self, tx: Sender<Event>) {
        let script = self.script.clone();
        let interval = self.interval.to_string();
        thread::spawn(move || {
            let mut cmd = build_command(
                &script,
                "status",
                &["--watch".to_string(), interval, "--fast".to_string()],
            );
            cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
            let mut child = match cmd.spawn() {
                Ok(c) => c,
                Err(e) => {
                    let _ = tx.send(Event::Failed(format!("cannot start phpup: {e}")));
                    return;
                }
            };

            // phpup writes its human chatter to stderr; forward it to the
            // console pane so failures are visible without a terminal.
            if let Some(err) = child.stderr.take() {
                let tx_err = tx.clone();
                thread::spawn(move || {
                    for line in BufReader::new(err).lines() {
                        match line {
                            Ok(l) => {
                                if tx_err.send(Event::Log(l)).is_err() {
                                    break;
                                }
                            }
                            Err(_) => break,
                        }
                    }
                });
            }

            if let Some(out) = child.stdout.take() {
                for line in BufReader::new(out).lines() {
                    let Ok(line) = line else { break };
                    let line = line.trim();
                    if line.is_empty() {
                        continue;
                    }
                    match serde_json::from_str::<Status>(line) {
                        Ok(status) => {
                            if tx.send(Event::Status(Box::new(status))).is_err() {
                                break;
                            }
                        }
                        Err(e) => {
                            let _ = tx.send(Event::Failed(format!("unreadable status line: {e}")));
                        }
                    }
                }
            }
            let _ = child.wait();
        });
    }

    pub fn spawn_action(&self, verb: &'static str, tx: Sender<Event>) {
        let script = self.script.clone();
        thread::spawn(move || {
            let mut cmd = build_command(&script, verb, &["--json".to_string()]);
            cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
            let mut child = match cmd.spawn() {
                Ok(c) => c,
                Err(e) => {
                    let _ = tx.send(Event::Failed(format!("{verb} could not run: {e}")));
                    return;
                }
            };

            // Stream stderr to the console as it arrives; stdout is the JSON
            // payload and is captured whole.
            let stderr_reader = child.stderr.take().map(|err| {
                let tx_err = tx.clone();
                thread::spawn(move || {
                    for line in BufReader::new(err).lines() {
                        match line {
                            Ok(l) => {
                                if tx_err.send(Event::Log(l)).is_err() {
                                    break;
                                }
                            }
                            Err(_) => break,
                        }
                    }
                })
            });

            match child.wait_with_output() {
                Ok(o) => {
                    if let Some(handle) = stderr_reader {
                        let _ = handle.join();
                    }
                    let stdout = String::from_utf8_lossy(&o.stdout).to_string();
                    let result = serde_json::from_str::<ActionResult>(stdout.trim()).ok();
                    let raw = if result.is_none() {
                        stdout.trim().to_string()
                    } else {
                        String::new()
                    };
                    let _ = tx.send(Event::ActionFinished {
                        verb: verb.to_string(),
                        exit: o.status.code().unwrap_or(-1),
                        result,
                        raw,
                    });
                }
                Err(e) => {
                    let _ = tx.send(Event::Failed(format!("{verb} failed: {e}")));
                }
            }
        });
    }
}

pub fn channel_pair() -> (Sender<Event>, Receiver<Event>) {
    channel()
}

/// Run one lifecycle verb elevated, without spawning a second panel.
///
/// Elevating the whole application was wrong: it left a console window behind
/// and created a duplicate tray icon. Elevate just the verb instead, let it
/// finish, and the watch stream reports the resulting state a second later.
#[cfg(windows)]
pub fn run_elevated(script: &Path, verb: &str) -> std::io::Result<()> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let script_arg = script.display().to_string().replace('\'', "''");
    let inner = format!(
        "Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden \
         -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','{script_arg}','{verb}'"
    );
    let mut c = Command::new("powershell.exe");
    c.arg("-NoProfile")
        .arg("-NonInteractive")
        .arg("-WindowStyle")
        .arg("Hidden")
        .arg("-Command")
        .arg(inner);
    c.creation_flags(CREATE_NO_WINDOW);
    let status = c.status()?;
    if status.success() {
        Ok(())
    } else {
        Err(std::io::Error::other("elevation was declined"))
    }
}

#[cfg(not(windows))]
pub fn run_elevated(script: &Path, verb: &str) -> std::io::Result<()> {
    // The Unix scripts sudo internally, so there is nothing to elevate here.
    let _ = (script, verb);
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "not needed on this platform",
    ))
}

/// Set a phpup service's start type: "auto" or "disabled".
///
/// Start type is machine configuration, so this has to run elevated. The panel
/// itself stays unelevated and the prompt covers only sc.exe; the watch stream
/// reports the resulting state on its next tick, so nothing is assumed locally.
#[cfg(windows)]
pub fn set_service_start(name: &str, mode: &str) -> std::io::Result<()> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    if mode != "auto" && mode != "disabled" {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "mode must be auto or disabled",
        ));
    }
    if !name.starts_with("phpup_") {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "refusing to change a service that is not phpup's",
        ));
    }
    let inner = format!(
        "$p = Start-Process -FilePath 'sc.exe' -Verb RunAs -WindowStyle Hidden \
         -Wait -PassThru -ArgumentList 'config','{name}','start=','{mode}'; exit $p.ExitCode"
    );
    let mut c = Command::new("powershell.exe");
    c.arg("-NoProfile")
        .arg("-NonInteractive")
        .arg("-WindowStyle")
        .arg("Hidden")
        .arg("-Command")
        .arg(inner);
    c.creation_flags(CREATE_NO_WINDOW);
    let status = c.status()?;
    if status.success() {
        Ok(())
    } else {
        Err(std::io::Error::other(format!(
            "sc.exe exited with {status} (declined or denied)"
        )))
    }
}

#[cfg(not(windows))]
pub fn set_service_start(_name: &str, _mode: &str) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "Windows services only",
    ))
}

pub fn open_in_default_app(target: &str) {
    #[cfg(windows)]
    {
        let _ = Command::new("cmd")
            .arg("/C")
            .arg("start")
            .arg("")
            .arg(target)
            .spawn();
    }
    #[cfg(target_os = "macos")]
    {
        let _ = Command::new("open").arg(target).spawn();
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let _ = Command::new("xdg-open").arg(target).spawn();
    }
}

/// True when this process already holds an elevated token.
///
/// `whoami /groups` costs ~20ms and, unlike spawning PowerShell, does not make
/// the panel feel like it is starting twice.
pub fn is_elevated() -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let mut c = Command::new("whoami.exe");
        c.arg("/groups");
        c.creation_flags(CREATE_NO_WINDOW);
        match c.output() {
            // S-1-16-12288 is High mandatory level, S-1-16-16384 is System.
            Ok(out) => {
                let groups = String::from_utf8_lossy(&out.stdout);
                groups.contains("S-1-16-12288") || groups.contains("S-1-16-16384")
            }
            Err(_) => false,
        }
    }
    #[cfg(not(windows))]
    {
        Command::new("id")
            .arg("-u")
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "0")
            .unwrap_or(false)
    }
}

/// Relaunch the panel elevated, optionally running a verb once it starts.
///
/// Blocks until the user answers UAC: `Ok` means the elevated instance is on its
/// way, so the caller should drop its tray icon and exit. `Err` means the prompt
/// was declined or could not be shown.
pub fn relaunch_panel(pending: Option<&str>) -> Result<(), String> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let exe = exe.display().to_string().replace('\'', "''");
        let args = match pending {
            Some(verb) => format!("--run {verb}"),
            None => String::new(),
        };
        let inner = if args.is_empty() {
            format!("Start-Process -FilePath '{exe}' -Verb RunAs")
        } else {
            format!("Start-Process -FilePath '{exe}' -Verb RunAs -ArgumentList '{args}'")
        };
        let mut c = Command::new("powershell.exe");
        c.args(["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", &inner]);
        c.creation_flags(CREATE_NO_WINDOW);
        let status = c.status().map_err(|e| e.to_string())?;
        if status.success() {
            Ok(())
        } else {
            Err("UAC declined".to_string())
        }
    }
    #[cfg(not(windows))]
    {
        let _ = pending;
        Err("not supported on this platform".to_string())
    }
}
