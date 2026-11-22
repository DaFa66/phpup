//! Bridge to the phpup CLI.
//!
//! The panel never parses human output: it reads the JSON contract
//! (`.junk/cli-contract.md`) from `status --watch` for live state and from
//! one-shot `start|stop|restart --json` calls for actions.

use serde::Deserialize;
use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
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

// ------------------------------------------------------------ switch payload

/// A registered root phpup can hand ports 80/3306 to. Named "foreign" in the
/// contract because it is not phpup's own install.
#[derive(Debug, Deserialize, Clone, Default)]
pub struct ForeignStack {
    #[serde(default)]
    pub alias: String,
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    #[allow(dead_code)] // "xampp" | "custom"; the panel shows alias and path
    pub kind: String,
}

/// One port in the switch payload. Deliberately not `PortInfo`: that name is
/// already the status stream's record (port/listening/ours), and the two
/// payloads describe a port differently.
#[derive(Debug, Deserialize, Clone, Default)]
pub struct SwitchPort {
    /// "phpup" | "foreign" | "other" | "unknown" | "free".
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub owner: Option<String>,
}

/// The ports map tolerates a malformed entry: losing the whole payload would
/// hide the errors[] text exactly when the switch failed and the user needs it.
fn ports_lenient<'de, D>(d: D) -> Result<Option<HashMap<String, SwitchPort>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<serde_json::Value>::deserialize(d)?;
    Ok(value.and_then(|v| serde_json::from_value(v).ok()))
}

/// `stack` arrives as an array from the list branches (`switch`, `switch --add`,
/// `switch --list`) and as a single object from the handover branches of older
/// builds, before the payload was made uniform. Both shapes are in the wild, so
/// accept either: refusing the object turned a perfectly good "elevation
/// required" payload into "unreadable payload" and hid the reason from the user.
fn stack_list<'de, D>(d: D) -> Result<Vec<ForeignStack>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Shape {
        Many(Vec<ForeignStack>),
        One(Box<ForeignStack>),
    }
    Ok(match Option::<Shape>::deserialize(d)? {
        Some(Shape::Many(v)) => v,
        Some(Shape::One(s)) => vec![*s],
        None => Vec::new(),
    })
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct SwitchPayload {
    #[serde(default, deserialize_with = "bool_or_false")]
    pub ok: bool,
    #[serde(default)]
    pub code: Option<String>,
    /// Target alias. JSON null on phpup.sh, "" on phpup.ps1, so it must stay
    /// optional: a bare String makes every Unix payload unparseable.
    #[serde(default)]
    pub to: Option<String>,
    /// Which stack holds ports 80/3306 right now, as recorded by the handover.
    /// Null when phpup holds them. Lets the block name the stack instead of
    /// showing "unknown" for a listener it cannot inspect.
    #[serde(default)]
    pub active: Option<String>,
    /// The holder's root. `active` alone cannot identify it: C:\xampp and
    /// D:\xampp are both aliased "xampp", so a client that only knows the alias
    /// has to guess — and guessed wrong once, refusing a legitimate way back.
    #[serde(default)]
    pub active_path: Option<String>,
    #[serde(default, deserialize_with = "bool_or_false")]
    pub changed: bool,
    #[serde(default, deserialize_with = "bool_or_false")]
    pub dry_run: bool,
    #[serde(default, deserialize_with = "stack_list")]
    pub stack: Vec<ForeignStack>,
    #[serde(default, deserialize_with = "ports_lenient")]
    pub ports: Option<HashMap<String, SwitchPort>>,
    #[serde(default, deserialize_with = "null_vec")]
    pub steps: Vec<String>,
    #[serde(default, deserialize_with = "null_vec")]
    pub warnings: Vec<String>,
    #[serde(default, deserialize_with = "null_vec")]
    pub errors: Vec<String>,
}

impl SwitchPayload {
    pub fn port(&self, port: &str) -> Option<&SwitchPort> {
        self.ports.as_ref().and_then(|m| m.get(port))
    }

    /// First thing worth showing the user: an error, else the code.
    pub fn first_error(&self) -> Option<String> {
        self.errors
            .iter()
            .find(|e| !e.trim().is_empty())
            .cloned()
            .or_else(|| self.code.clone())
    }
}

// ------------------------------------------------------------------ events

pub enum Event {
    Status(Box<Status>),
    /// A `switch` invocation finished and produced a payload. Boxed: the
    /// payload is several times larger than any other variant.
    ///
    /// `from_action` says whether the user asked for this or the panel polled.
    /// Without it a snapshot that happened to be in flight when a button was
    /// pressed could take the action's place: the error vanished, the busy flag
    /// cleared early, and the block reported a snapshot as if it were the result.
    Switch {
        payload: Box<SwitchPayload>,
        from_action: bool,
    },
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

// --------------------------------------------------------------------- job

/// A job object every child is assigned to. Windows terminates every process in
/// a job when its last handle closes, which happens even when the panel itself is
/// ended abruptly - the one case where `Drop` and `shutdown()` never run.
#[cfg(windows)]
mod job {
    use std::ffi::c_void;
    use std::os::windows::io::AsRawHandle;
    use std::process::Child;

    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };

    /// Opaque handle, kept as an integer so `Backend` stays `Send + Sync`.
    #[derive(Clone, Copy)]
    pub struct Job(isize);

    impl Job {
        pub fn create() -> Option<Job> {
            unsafe {
                let handle: HANDLE = CreateJobObjectW(std::ptr::null(), std::ptr::null());
                if handle == 0 {
                    return None;
                }
                let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                let ok = SetInformationJobObject(
                    handle,
                    JobObjectExtendedLimitInformation,
                    &mut info as *mut _ as *const c_void,
                    std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                );
                if ok == 0 {
                    let _ = CloseHandle(handle);
                    return None;
                }
                Some(Job(handle as isize))
            }
        }

        pub fn assign(&self, child: &Child) {
            unsafe {
                let _ =
                    AssignProcessToJobObject(self.0 as HANDLE, child.as_raw_handle() as HANDLE);
            }
        }
    }
}

// ----------------------------------------------------------------- backend

pub struct Backend {
    pub script: PathBuf,
    pub interval: u32,
    /// Children are assigned here so the OS ends them with the panel.
    #[cfg(windows)]
    job: Option<job::Job>,
    /// Every child this backend starts, so the panel can take them with it.
    /// A forced close used to leave `status --watch` and any switch run behind,
    /// each holding a conhost and, in the switch's case, still probing ports.
    children: Arc<Mutex<Vec<u32>>>,
    /// The `status --watch` process. Its interval arrives as an argument, so a
    /// new rate means replacing this child, not editing it.
    watch: Arc<Mutex<Option<u32>>>,
}

impl Backend {
    pub fn new(script: PathBuf, interval: u32) -> Self {
        #[cfg(windows)]
        let job = job::Job::create();
        Self {
            script,
            interval,
            #[cfg(windows)]
            job,
            children: Arc::new(Mutex::new(Vec::new())),
            watch: Arc::new(Mutex::new(None)),
        }
    }

    /// Stop only the status stream, leaving any switch run alone.
    pub fn stop_watch(&self) {
        let id = match self.watch.lock() {
            Ok(mut w) => w.take(),
            Err(_) => None,
        };
        let Some(id) = id else { return };
        if let Ok(mut list) = self.children.lock() {
            list.retain(|c| *c != id);
        }
        let mut cmd = Command::new("taskkill");
        cmd.arg("/F").arg("/T").arg("/PID").arg(id.to_string());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        cmd.stdout(Stdio::null()).stderr(Stdio::null());
        let _ = cmd.status();
    }

    /// Kill everything this backend started. Called when the window closes, so a
    /// closed panel leaves no phpup processes behind.
    pub fn shutdown(&self) {
        let ids: Vec<u32> = match self.children.lock() {
            Ok(mut list) => list.drain(..).collect(),
            Err(_) => return,
        };
        for id in ids {
            let mut cmd = Command::new("taskkill");
            cmd.arg("/F").arg("/T").arg("/PID").arg(id.to_string());
            #[cfg(windows)]
            {
                use std::os::windows::process::CommandExt;
                cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
            }
            cmd.stdout(Stdio::null()).stderr(Stdio::null());
            let _ = cmd.status();
        }
    }

    /// Long-lived `status --watch`, parsed line by line. One process instead of
    /// one per poll: process startup is ~0.85s on Windows.
    pub fn spawn_watch(&self, tx: Sender<Event>) {
        let script = self.script.clone();
        let interval = self.interval.to_string();
        let children = self.children.clone();
        let watch = self.watch.clone();
        #[cfg(windows)]
        let job = self.job;
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
            if let Some(job) = job {
                job.assign(&child);
            }
            if let Ok(mut list) = children.lock() {
                list.push(child.id());
            }
            if let Ok(mut w) = watch.lock() {
                *w = Some(child.id());
            }

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
        let children = self.children.clone();
        #[cfg(windows)]
        let job = self.job;
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
            if let Some(job) = job {
                job.assign(&child);
            }
            if let Ok(mut list) = children.lock() {
                list.push(child.id());
            }

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

    /// Run `switch <args> --json`.
    ///
    /// `switch` is read-modify-write rather than a lifecycle verb: a plain call
    /// with no arguments is the snapshot the Stacks block renders, so the same
    /// path serves listing, adding and handing the ports over.
    pub fn spawn_switch(&self, args: Vec<String>, tx: Sender<Event>) {
        let script = self.script.clone();
        let children = self.children.clone();
        #[cfg(windows)]
        let job = self.job;
        thread::spawn(move || {
            let no_args = args.is_empty();
            let mut extra = args;
            extra.push("--json".to_string());
            let mut cmd = build_command(&script, "switch", &extra);
            cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
            let mut child = match cmd.spawn() {
                Ok(c) => c,
                Err(e) => {
                    let _ = tx.send(Event::Failed(format!("switch could not run: {e}")));
                    return;
                }
            };
            if let Some(job) = job {
                job.assign(&child);
            }
            if let Ok(mut list) = children.lock() {
                list.push(child.id());
            }

            // Same stderr handling as spawn_action, so a refused switch explains
            // itself in the console pane rather than vanishing.
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
                    let exit = o.status.code().unwrap_or(-1);
                    match parse_switch_payload(&stdout, exit) {
                        Ok(payload) => {
                            // No arguments is the snapshot; anything else was asked for.
                            let _ = tx.send(Event::Switch {
                                payload: Box::new(payload),
                                from_action: !no_args,
                            });
                        }
                        Err(msg) => {
                            let _ = tx.send(Event::Failed(msg));
                        }
                    }
                }
                Err(e) => {
                    let _ = tx.send(Event::Failed(format!("switch failed: {e}")));
                }
            }
        });
    }
}

/// Long JSON on one line would flood the console; the head is enough to see
/// what went wrong.
fn first_line(text: &str) -> String {
    let line = text.lines().next().unwrap_or("").trim();
    if line.chars().count() > 200 {
        let head: String = line.chars().take(200).collect();
        format!("{head}…")
    } else {
        line.to_string()
    }
}

/// One parser for a switch payload, whether it arrived on a pipe or in a file.
///
/// Exit 2/4/5 still carry a payload with `ok: false` and `errors`; those are
/// answers. Only text that is not JSON at all is a parse failure, and it has to
/// name the exit code and the head of the text or the console shows nothing.
fn parse_switch_payload(stdout: &str, exit: i32) -> Result<SwitchPayload, String> {
    // Out-File can prepend a BOM; serde_json rejects it as an unexpected char.
    let text = stdout.trim().trim_start_matches('\u{feff}').trim();
    // The PowerShell console host writes warnings to stdout when stdout is a
    // pipe rather than a console, so an elevated run can hand back
    // "WARNING: Waiting for service 'phpup_Apache' to start..." in front of the
    // payload. Take the outermost JSON object and ignore the rest.
    let candidate = match (text.find('{'), text.rfind('}')) {
        (Some(first), Some(last)) if last > first => &text[first..=last],
        _ => text,
    };
    match serde_json::from_str::<SwitchPayload>(candidate) {
        Ok(payload) => Ok(payload),
        Err(e) => {
            let raw = if candidate.is_empty() {
                format!("no payload on stdout (exit {exit})")
            } else {
                format!("exit {exit}: {}", first_line(candidate))
            };
            Err(format!("switch: unreadable payload ({e}) — {raw}"))
        }
    }
}

pub fn channel_pair() -> (Sender<Event>, Receiver<Event>) {
    channel()
}

/// Run `switch <args> --json` elevated and read the payload back.
///
/// A handover stops and starts registered services, so Windows answers exit 4
/// `elevation_required` without Administrator. Elevate the one command rather
/// than the panel, for the reasons the lifecycle verbs already follow: no extra
/// console window, no second tray icon. `Start-Process` cannot hand back an
/// elevated child's stdout, so a generated wrapper writes the JSON to a temp file
/// and the panel reads that.
#[cfg(windows)]
pub fn spawn_switch_elevated(script: PathBuf, args: Vec<String>, tx: Sender<Event>) {
    thread::spawn(move || {
        let mut arg_list = args;
        arg_list.push("--json".to_string());

        let q = |s: &str| format!("'{}'", s.replace('\'', "''"));
        let dir = std::env::temp_dir();
        let stamp = std::process::id();
        let out = dir.join(format!("phpup-switch-{stamp}.json"));
        let wrapper = dir.join(format!("phpup-switch-{stamp}.ps1"));
        let _ = std::fs::remove_file(&out);

        let call = std::iter::once("switch".to_string())
            .chain(arg_list.iter().cloned())
            .map(|a| q(&a))
            .collect::<Vec<_>>()
            .join(" ");
        // Invoke through `-File`, the same way the panel calls the script
        // everywhere else. A direct `& script switch --to xampp` binds `--to` as a
        // parameter name and dies with "A positional parameter cannot be found",
        // because the script's own argument parser never sees it.
        let body = format!(
            "& 'powershell.exe' -NoProfile -NonInteractive -ExecutionPolicy Bypass -File {} {call} \
             | Out-File -FilePath {} -Encoding utf8\r\nexit $LASTEXITCODE\r\n",
            q(&script.display().to_string()),
            q(&out.display().to_string())
        );
        if let Err(e) = std::fs::write(&wrapper, body) {
            let _ = tx.send(Event::Failed(format!("switch could not elevate: {e}")));
            return;
        }

        // NOT `-Wait`: Start-Process -Wait waits for the process *tree*, and the
        // tree includes the httpd/mysqld the handover just started — which never
        // exit. The panel then sat on "refreshing…" with buttons disabled while
        // the switch had in fact succeeded. Wait on this one process only.
        let shell = format!(
            "$p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden \
             -PassThru -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',{}; \
             if ($null -eq $p) {{ exit 4 }}; \
             if (-not $p.WaitForExit(900000)) {{ exit 3 }}; \
             exit $p.ExitCode",
            q(&wrapper.display().to_string())
        );
        let status = {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            // A GUI process spawning a console app gets a console window unless it
            // says otherwise — the same reason run_elevated sets this.
            Command::new("powershell.exe")
                .arg("-NoProfile")
                .arg("-NonInteractive")
                .arg("-WindowStyle")
                .arg("Hidden")
                .arg("-Command")
                .arg(shell)
                .creation_flags(CREATE_NO_WINDOW)
                .status()
        };

        let text = std::fs::read_to_string(&out).unwrap_or_default();
        let _ = std::fs::remove_file(&out);
        let _ = std::fs::remove_file(&wrapper);

        match status {
            Ok(s) if s.success() => match parse_switch_payload(&text, 0) {
                Ok(payload) => {
                    let _ = tx.send(Event::Switch {
                        payload: Box::new(payload),
                        from_action: true,
                    });
                }
                Err(msg) => {
                    let _ = tx.send(Event::Failed(msg));
                }
            },
            // Declining UAC is an answer, not a crash: say so plainly.
            _ => {
                let _ = tx.send(Event::Failed("switch: elevation was declined".to_string()));
            }
        }
    });
}

#[cfg(not(windows))]
pub fn spawn_switch_elevated(script: PathBuf, args: Vec<String>, tx: Sender<Event>) {
    // The Unix scripts sudo internally, so there is nothing to elevate here.
    let _ = (script, args);
    let _ = tx.send(Event::Failed(
        "switch: elevation is not needed on this platform".to_string(),
    ));
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

/// Run sc.exe elevated and wait. Start type and service control both need this.
#[cfg(windows)]
fn run_elevated_sc(args: &[&str], what: &str) -> std::io::Result<()> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let list = args
        .iter()
        .map(|a| format!("'{a}'"))
        .collect::<Vec<_>>()
        .join(",");
    let inner = format!(
        "$p = Start-Process -FilePath 'sc.exe' -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList {list}; exit $p.ExitCode"
    );
    let status = Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-WindowStyle",
            "Hidden",
            "-Command",
            &inner,
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(std::io::Error::other(format!(
            "{what}: sc.exe exited with {status} (declined or denied)"
        )))
    }
}

#[cfg(windows)]
fn check_phpup_service(name: &str) -> std::io::Result<()> {
    if name.starts_with("phpup_") {
        Ok(())
    } else {
        Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "refusing to touch a service that is not phpup's",
        ))
    }
}

/// Set a phpup service's start type: "auto" or "disabled".
#[cfg(windows)]
pub fn set_service_start(name: &str, mode: &str) -> std::io::Result<()> {
    if mode != "auto" && mode != "disabled" {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "mode must be auto or disabled",
        ));
    }
    check_phpup_service(name)?;
    run_elevated_sc(&["config", name, "start=", mode], "set start type")
}

#[cfg(not(windows))]
pub fn set_service_start(_name: &str, _mode: &str) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "Windows services only",
    ))
}

/// Per-user Run key. Writing it needs no elevation, so this never prompts.
#[cfg(windows)]
const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
#[cfg(windows)]
const AUTOSTART_VALUE: &str = "phpup-panel";

/// True when the per-user Run entry exists. The registry is the source of truth,
/// so the checkbox cannot drift from what Windows will actually do at sign-in.
#[cfg(windows)]
pub fn autostart_enabled() -> bool {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    Command::new("reg.exe")
        .args(["query", RUN_KEY, "/v", AUTOSTART_VALUE])
        .creation_flags(CREATE_NO_WINDOW)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Add or remove the per-user Run entry for this executable.
#[cfg(windows)]
pub fn set_autostart(enabled: bool) -> std::io::Result<()> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let mut c = Command::new("reg.exe");
    if enabled {
        let exe = std::env::current_exe()?;
        c.args(["add", RUN_KEY, "/v", AUTOSTART_VALUE, "/t", "REG_SZ", "/d"])
            .arg(format!("\"{}\"", exe.display()))
            .arg("/f");
    } else {
        c.args(["delete", RUN_KEY, "/v", AUTOSTART_VALUE, "/f"]);
    }
    c.creation_flags(CREATE_NO_WINDOW);
    let status = c.status()?;
    // Deleting an entry that is not there is a no-op, not a failure.
    if status.success() || !enabled {
        Ok(())
    } else {
        Err(std::io::Error::other(format!("reg.exe exited with {status}")))
    }
}

#[cfg(not(windows))]
pub fn autostart_enabled() -> bool {
    false
}

#[cfg(not(windows))]
pub fn set_autostart(_enabled: bool) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "start with Windows is Windows only",
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Windows shape, verbatim from `phpup.ps1 switch --json`.
    const WIN: &str = r#"{"schema":1,"ok":true,"code":null,"action":"switch","to":"","dry_run":false,"changed":false,"stack":[{"alias":"xampp","path":"C:\\xampp","kind":"xampp"}],"ports":{"80":{"state":"phpup","owner":"httpd (PID 45268)"},"3306":{"state":"phpup","owner":"mariadbd (PID 33504)"}},"steps":[],"warnings":[],"errors":[]}"#;

    /// Unix shape: `to`, `stack`, `ports`, `code` and `errors` all arrive null.
    /// This is the shape that broke every parse when `to` was a bare String.
    const UNIX: &str = r#"{"schema":1,"ok":false,"code":null,"action":"switch","to":null,"dry_run":false,"changed":false,"stack":null,"ports":null,"steps":null,"warnings":null,"errors":null}"#;

    #[test]
    fn windows_payload_parses() {
        let p: SwitchPayload = serde_json::from_str(WIN).expect("windows payload");
        assert!(p.ok);
        assert_eq!(p.to.as_deref(), Some(""));
        assert_eq!(p.stack.len(), 1);
        assert_eq!(p.stack[0].alias, "xampp");
        assert_eq!(p.stack[0].path, r"C:\xampp");
        assert_eq!(p.port("80").map(|x| x.state.as_str()), Some("phpup"));
        assert_eq!(p.port("3306").and_then(|x| x.owner.as_deref()), Some("mariadbd (PID 33504)"));
        assert!(p.errors.is_empty());
    }

    #[test]
    fn unix_payload_nulls_parse() {
        let p: SwitchPayload = serde_json::from_str(UNIX).expect("unix payload");
        assert!(!p.ok);
        assert_eq!(p.to, None);
        assert!(p.stack.is_empty());
        assert!(p.ports.is_none());
        assert!(p.steps.is_empty());
        assert!(p.warnings.is_empty());
        assert!(p.errors.is_empty());
        assert!(p.code.is_none());
    }

    /// The payload Windows sent when a handover needed Administrator: `stack` is
    /// a single object here, not an array. This failed with "invalid type: map,
    /// expected a sequence", so the panel said "unreadable payload" and never
    /// showed the reason — verbatim from the console, truncated at the same place.
    const WIN_ELEVATION: &str = r#"{"schema":1,"ok":false,"code":"elevation_required","action":"switch","to":"xampp","dry_run":false,"changed":false,"stack":{"alias":"xampp","path":"D:\\xampp","kind":"xampp","apache":{"version":"2.4.58","port":80}},"ports":null,"steps":[],"warnings":[],"errors":["Handing over registered services needs Administrator rights."]}"#;

    #[test]
    fn windows_elevation_payload_with_a_single_stack_object_parses() {
        let p: SwitchPayload = serde_json::from_str(WIN_ELEVATION).expect("elevation payload");
        assert!(!p.ok);
        assert_eq!(p.code.as_deref(), Some("elevation_required"));
        assert_eq!(p.stack.len(), 1);
        assert_eq!(p.stack[0].alias, "xampp");
        assert_eq!(p.stack[0].path, r"D:\xampp");
        assert!(p
            .first_error()
            .expect("the reason survives")
            .contains("Administrator"));
        assert!(p.port("80").is_none(), "ports were null, so show none");
    }

    #[test]
    fn a_stack_object_and_a_stack_array_agree() {
        let one: SwitchPayload = serde_json::from_str(r#"{"stack":{"alias":"a","path":"C:\\a"}}"#)
            .expect("single object");
        let many: SwitchPayload = serde_json::from_str(r#"{"stack":[{"alias":"a","path":"C:\\a"}]}"#)
            .expect("array");
        assert_eq!(one.stack.len(), many.stack.len());
        assert_eq!(one.stack[0].alias, many.stack[0].alias);
    }

    /// `Out-File -Encoding utf8` writes a BOM, and serde_json rejects it as an
    /// unexpected character. The elevated path reads the payload from such a file.
    #[test]
    fn a_utf8_bom_does_not_defeat_the_parser() {
        let body = format!("\u{feff}{WIN}");
        let p = parse_switch_payload(&body, 0).expect("bom tolerated");
        assert!(p.ok);
        assert_eq!(p.stack.len(), 1);
    }

    /// Observed from a real elevated handover: Start-Service wrote
    /// "WARNING: Waiting for service 'phpup_Apache (phpup_Apache)' to start..."
    /// to the same stream as the payload, first.
    #[test]
    fn a_warning_before_the_payload_is_ignored() {
        let body = format!(
            "\u{feff}WARNING: Waiting for service 'phpup_Apache (phpup_Apache)' to start...{}",
            WIN
        );
        let p = parse_switch_payload(&body, 0).expect("noise tolerated");
        assert!(p.ok);
    }

    /// The warning can also land after the payload, since it is written whenever
    /// the service finally reports in.
    #[test]
    fn a_warning_after_the_payload_is_ignored() {
        let body = format!(
            "{}WARNING: Waiting for service 'phpup_MariaDB (phpup_MariaDB)' to start...",
            WIN
        );
        let p = parse_switch_payload(&body, 0).expect("noise tolerated");
        assert!(p.ok);
    }

    #[test]
    fn missing_fields_default() {
        let p: SwitchPayload = serde_json::from_str(r#"{"ok":null}"#).expect("sparse payload");
        assert!(!p.ok);
        assert!(p.stack.is_empty());
        assert!(p.ports.is_none());
        assert!(p.errors.is_empty());
    }

    /// A switch that fails still has to surface its errors: a bad ports entry
    /// must cost the ports map, not the whole payload.
    #[test]
    fn broken_ports_entry_keeps_errors() {
        let json = r#"{"ok":false,"code":"usage","to":null,"ports":{"80":"nonsense"},"errors":["'C:\\nope' is not a stack phpup can switch to"]}"#;
        let p: SwitchPayload = serde_json::from_str(json).expect("payload with broken ports");
        assert!(!p.ok);
        assert!(p.ports.is_none());
        assert_eq!(p.code.as_deref(), Some("usage"));
        assert_eq!(p.first_error().as_deref(), Some("'C:\\nope' is not a stack phpup can switch to"));
    }
}
