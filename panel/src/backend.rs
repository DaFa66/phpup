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
use std::time::Duration;

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
    #[serde(default)]
    pub registered: bool,
    #[serde(default)]
    pub enabled: bool,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct Services {
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub registered: bool,
    #[serde(default)]
    pub autostart: bool,
    #[serde(default, deserialize_with = "null_vec")]
    pub items: Vec<SvcItem>,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct Component {
    #[serde(default)]
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
    #[serde(default)]
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
    #[serde(default)]
    pub listening: bool,
    #[serde(default)]
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

    pub fn complete(&self) -> bool {
        self.stack_state() == "complete"
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

/// Relaunch the panel elevated so actions that need Administrator can run.
#[cfg(windows)]
pub fn relaunch_elevated() -> std::io::Result<()> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let exe = std::env::current_exe()?;
    let mut c = Command::new("powershell.exe");
    c.arg("-NoProfile")
        .arg("-Command")
        .arg(format!(
            "Start-Process -FilePath '{}' -Verb RunAs",
            exe.display()
        ));
    c.creation_flags(CREATE_NO_WINDOW);
    c.spawn()?;
    Ok(())
}

#[cfg(not(windows))]
pub fn relaunch_elevated() -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "not supported on this platform",
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

/// Small pause used when a watch stream has to be restarted.
pub const RESTART_PAUSE: Duration = Duration::from_millis(300);
