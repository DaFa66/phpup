#![cfg_attr(windows, windows_subsystem = "windows")]

mod assets;
mod backend;
mod screens;
mod theme;

use backend::{Backend, Component, Event, Source, Status};
use eframe::egui::{
    self, Align, Color32, CornerRadius, Frame, Layout, Margin, RichText, Stroke, Vec2,
};
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, Sender};
use std::time::{Duration, Instant};
use theme::{palette, Palette, ThemePref};
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

const LOG_CAP: usize = 2000;

const ON_ACCENT: Color32 = Color32::from_rgb(0x1a, 0x1d, 0x25);
const TOAST_TTL: Duration = Duration::from_secs(7);

fn main() -> eframe::Result<()> {
    // No console window, in release or debug: a stray console is the one thing
    // that makes this look unfinished. Panics go to a file instead.
    std::panic::set_hook(Box::new(|info| {
        if let Some(dir) = backend::cache_dir() {
            let _ = std::fs::create_dir_all(&dir);
            let _ = std::fs::write(dir.join("panic.log"), format!("{info}\n"));
        }
    }));

    let settings = Settings::load();
    let elevated = backend::is_elevated();

    // `--run <verb>`: set when this instance was started by an elevated
    // relaunch, so the action the user asked for happens without a second click.
    let mut pending_verb: Option<String> = None;
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if let Some(pos) = argv.iter().position(|a| a == "--run") {
        pending_verb = argv.get(pos + 1).cloned();
    }

    let mut viewport = egui::ViewportBuilder::default()
        .with_title(if elevated { "phpup — as administrator" } else { "phpup" })
        .with_app_id("phpup-panel")
        .with_min_inner_size([760.0, 520.0]);
    match settings.window {
        // Reopen where it was left, not at a size chosen on the developer's screen.
        Some(win) => {
            viewport = viewport.with_inner_size([win.w, win.h]);
            if let (Some(x), Some(y)) = (win.x, win.y) {
                // Only while that spot still exists: a monitor unplugged, a
                // docking change or a drag that ended past the edge leaves an
                // x/y that draws the panel where nothing can be clicked. No
                // position at all is a window Windows places for us.
                if screens::position_is_reachable(x, y, win.w, win.h) {
                    viewport = viewport.with_position([x, y]);
                }
            }
            if win.maximized {
                viewport = viewport.with_maximized(true);
            }
        }
        None => viewport = viewport.with_inner_size([980.0, 860.0]),
    }
    if let Some(icon) = assets::window_icon() {
        viewport = viewport.with_icon(std::sync::Arc::new(icon));
    }

    let options = eframe::NativeOptions {
        viewport,
        ..Default::default()
    };

    eframe::run_native(
        "phpup",
        options,
        Box::new(move |cc| Ok(Box::new(App::new(cc, settings, pending_verb)))),
    )
}

// ---------------------------------------------------------------- settings

#[derive(Clone)]
struct Settings {
    theme: ThemePref,
    /// GitHub by default: run the published script. Local is for phpup work.
    source: Source,
    script: Option<String>,
    interval: u32,
    /// 0.0 follows the OS; anything else is a fixed zoom factor.
    zoom: f32,
    /// Elevate the whole panel at launch instead of per action.
    always_admin: bool,
    /// Start hidden in the tray: no window, no taskbar button, tray icon only.
    start_in_tray: bool,
    /// Where the window was when it was last closed. Reopening at a fixed
    /// 980x860 throws away whatever the user sized it to.
    window: Option<WindowBox>,
}

#[derive(Clone, Copy)]
struct WindowBox {
    w: f32,
    h: f32,
    x: Option<f32>,
    y: Option<f32>,
    maximized: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            theme: ThemePref::System,
            source: Source::Github,
            script: None,
            interval: 5,
            zoom: 0.0,
            always_admin: false,
            start_in_tray: false,
            window: None,
        }
    }
}

impl Settings {
    fn path() -> Option<PathBuf> {
        #[cfg(windows)]
        let base = std::env::var_os("APPDATA").map(PathBuf::from);
        #[cfg(not(windows))]
        let base = std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")));
        base.map(|b| b.join("phpup").join("panel.json"))
    }

    fn load() -> Self {
        #[derive(serde::Deserialize)]
        struct Raw {
            theme: Option<String>,
            source: Option<String>,
            script: Option<String>,
            interval: Option<u32>,
            zoom: Option<f32>,
            always_admin: Option<bool>,
            start_in_tray: Option<bool>,
            window: Option<RawWindow>,
        }
        #[derive(serde::Deserialize)]
        struct RawWindow {
            w: f32,
            h: f32,
            x: Option<f32>,
            y: Option<f32>,
            #[serde(default)]
            maximized: bool,
        }
        let Some(path) = Self::path() else {
            return Self::default();
        };
        let Ok(text) = std::fs::read_to_string(path) else {
            return Self::default();
        };
        match serde_json::from_str::<Raw>(&text) {
            Ok(raw) => Self {
                theme: raw.theme.as_deref().map(ThemePref::from_str).unwrap_or(ThemePref::System),
                source: raw.source.as_deref().map(Source::from_str).unwrap_or(Source::Github),
                script: raw.script,
                interval: raw.interval.unwrap_or(5).clamp(2, 10),
                zoom: raw.zoom.unwrap_or(0.0),
                always_admin: raw.always_admin.unwrap_or(false),
                start_in_tray: raw.start_in_tray.unwrap_or(false),
                window: raw.window.map(|w| WindowBox {
                    w: w.w.max(760.0),
                    h: w.h.max(520.0),
                    x: w.x,
                    y: w.y,
                    maximized: w.maximized,
                }),
            },
            Err(_) => Self::default(),
        }
    }

    fn save(&self) {
        let Some(path) = Self::path() else { return };
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let body = serde_json::json!({
            "theme": self.theme.as_str(),
            "source": self.source.as_str(),
            "script": self.script,
            "interval": self.interval,
            "zoom": self.zoom,
            "always_admin": self.always_admin,
            "start_in_tray": self.start_in_tray,
            "window": self.window.map(|w| serde_json::json!({
                "w": w.w,
                "h": w.h,
                "x": w.x,
                "y": w.y,
                "maximized": w.maximized,
            })),
        });
        let _ = std::fs::write(path, serde_json::to_string_pretty(&body).unwrap_or_default());
    }
}

// -------------------------------------------------------------------- app

struct Tray {
    _icon: TrayIcon,
    show: MenuItem,
    start: MenuItem,
    stop: MenuItem,
    restart: MenuItem,
    quit: MenuItem,
}

#[derive(Clone, Copy)]
enum TrayCmd {
    Show,
    Start,
    Stop,
    Restart,
    Quit,
}

fn build_tray() -> Option<Tray> {
    let (rgba, width, height) = assets::tray_icon()?;
    let icon = Icon::from_rgba(rgba, width, height).ok()?;

    let menu = Menu::new();
    let show = MenuItem::new("Show panel", true, None);
    let start = MenuItem::new("Start stack", true, None);
    let stop = MenuItem::new("Stop stack", true, None);
    let restart = MenuItem::new("Restart stack", true, None);
    let quit = MenuItem::new("Quit", true, None);
    let _ = menu.append_items(&[
        &show,
        &PredefinedMenuItem::separator(),
        &start,
        &stop,
        &restart,
        &PredefinedMenuItem::separator(),
        &quit,
    ]);

    let tray = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_tooltip("phpup")
        .with_icon(icon)
        .build()
        .ok()?;

    Some(Tray {
        _icon: tray,
        show,
        start,
        stop,
        restart,
        quit,
    })
}

struct Toast {
    text: String,
    ok: bool,
    at: Instant,
}

struct App {
    settings: Settings,
    backend: Option<Backend>,
    tx: Sender<Event>,
    rx: Receiver<Event>,
    status: Option<Status>,
    /// Last `switch --json` payload: registered roots plus port ownership.
    switch: Option<backend::SwitchPayload>,
    switch_error: Option<String>,
    switch_busy: bool,
    /// The in-flight switch was `--add`, so a success clears the path field.
    switch_adding: bool,
    /// Arguments of a switch that came back `elevation_required`, kept so the
    /// "Run as administrator" button can repeat the exact same call.
    switch_admin_args: Option<Vec<String>>,
    /// Arguments of the last switch issued, for the same reason.
    switch_last_args: Vec<String>,
    /// When the in-flight switch started, so a call that never reports back can
    /// be given up on instead of pinning the block on "Refreshing…" for ever.
    switch_started: Option<Instant>,
    /// Last time the block re-read the snapshot on its own timer.
    switch_last_poll: Option<Instant>,
    /// A snapshot is in flight. It is a whole phpup run — port probes, service
    /// queries — so on a slow machine it can take longer than the interval. The
    /// panel spawned one every five seconds regardless, and the runs piled up
    /// until Windows itself became unresponsive. One at a time, always.
    switch_poll_inflight: bool,
    /// The snapshot has failed in a way that will not heal by asking again (a
    /// script with no `switch` verb, for instance). Polling stops for the session.
    switch_poll_failed: bool,
    /// Window geometry, mirrored into the settings every frame so any later save
    /// (a theme change, say) cannot write the size away.
    win: WindowBox,
    /// Last geometry written to disk, and when. Closing to the tray does not
    /// run `Drop`, so the size has to be persisted as it changes rather than
    /// only on exit.
    /// Heights measured last frame: the stack strip and the card column. The
    /// console is then given whatever is left, so slack lands in the log pane
    /// instead of as dead space under the cards.
    strip_h: f32,
    body_h: f32,
    /// What the cards need when nothing squeezes them. `content_size` reports the
    /// clipped height once the body is short, so a plain reading would ratchet the
    /// body smaller every frame and clip the cards for good.
    body_need: f32,
    /// Frames left in which the console is pinned to its floor so the cards can
    /// report their real height. `content_size` never exceeds the viewport, so a
    /// squeezed body cannot measure itself.
    calibrate: u8,
    win_saved: Option<(f32, f32, Option<f32>, Option<f32>, bool)>,
    win_saved_at: Option<std::time::Instant>,
    /// Port ownership as last written to the console, so the line appears when
    /// it changes rather than every poll.
    ports_logged: String,
    new_stack_path: String,
    last_error: Option<String>,
    last_seen: Option<Instant>,
    action: Option<&'static str>,
    /// Verb that came back exit 4, waiting for the user to consent to UAC.
    admin_verb: Option<String>,
    toast: Option<Toast>,
    sized_once: bool,
    settings_open: bool,
    /// Last drawn rect of the slide-out, so a click outside it can dismiss.
    settings_rect: Option<egui::Rect>,
    settings_toggle_rect: Option<egui::Rect>,
    brand: Option<assets::Brand>,
    about_open: bool,
    quitting: bool,
    /// This process is running with an elevated token.
    elevated: bool,
    /// Verb to run once an elevated relaunch completes.
    pending_verb: Option<String>,
    title_applied: bool,
    /// One-shot: the position on disk was checked against the monitors once the
    /// real DPI scale was known.
    pos_checked: bool,
    /// One-shot: honours Settings::start_in_tray in the first few frames only.
    tray_start_applied: bool,
    /// Frames drawn so far; the tray start is deferred until the window is
    /// actually mapped, because winit drops commands on the first frame.
    frames_seen: u32,
    /// Mirrors the per-user Run entry, which is the source of truth for autostart.
    autostart: bool,
    /// The elevated instance started; shut this one down.
    relaunch_ok: bool,
    /// One-shot: the startup elevation attempt has been made.
    startup_elevation_done: bool,
    applied_zoom: Option<f32>,
    script_input: String,
    applied_dark: Option<bool>,
    applied_pref: Option<ThemePref>,
    log: VecDeque<String>,
    log_pinned: bool,
    console_open: bool,
    tray: Option<Tray>,
}

impl App {
    fn new(cc: &eframe::CreationContext<'_>, settings: Settings, pending_verb: Option<String>) -> Self {
        let (tx, rx) = backend::channel_pair();
        let brand = assets::load(&cc.egui_ctx);

        cc.egui_ctx.all_styles_mut(|style| {
            style.spacing.item_spacing = Vec2::new(10.0, 10.0);
            style.spacing.button_padding = Vec2::new(12.0, 7.0);
        });

        let window0 = settings.window.unwrap_or(WindowBox {
            w: 980.0,
            h: 860.0,
            x: None,
            y: None,
            maximized: false,
        });

        let mut app = Self {
            settings,
            backend: None,
            tx,
            rx,
            status: None,
            switch: None,
            switch_error: None,
            switch_busy: false,
            switch_adding: false,
            switch_admin_args: None,
            switch_last_args: Vec::new(),
            switch_started: None,
            switch_last_poll: None,
            switch_poll_inflight: false,
            switch_poll_failed: false,
            win: window0,
            strip_h: 0.0,
            body_h: 0.0,
            body_need: 0.0,
            calibrate: 12,
            win_saved: None,
            win_saved_at: None,
            ports_logged: String::new(),
            new_stack_path: String::new(),
            last_error: None,
            last_seen: None,
            action: None,
            admin_verb: None,
            toast: None,
            // First run opens Settings: the source choice is the first thing a
            // new user needs to see. PHPUP_PANEL_OPEN_SETTINGS forces it open,
            // which is how the panel gets screenshotted without clicking.
            sized_once: false,
            settings_open: std::env::var("PHPUP_PANEL_OPEN_SETTINGS").is_ok()
                || !Settings::path().map(|p| p.is_file()).unwrap_or(false),
            settings_rect: None,
            settings_toggle_rect: None,
            about_open: false,
            quitting: false,
            elevated: backend::is_elevated(),
            pending_verb,
            title_applied: false,
            pos_checked: false,
            tray_start_applied: false,
            frames_seen: 0,
            autostart: backend::autostart_enabled(),
            relaunch_ok: false,
            startup_elevation_done: false,
            applied_zoom: None,
            brand,
            script_input: String::new(),
            applied_dark: None,
            applied_pref: None,
            log: VecDeque::new(),
            log_pinned: true,
            console_open: true,
            tray: build_tray(),
        };
        app.push_log("panel ready".to_string());
        app.attach();
        if app.backend.is_some() {
            if let Some(verb) = app.pending_verb.take() {
                // start_action takes a &'static str: the panel only ever runs
                // these three verbs, so map the argument onto one of them.
                let known = match verb.as_str() {
                    "start" => Some("start"),
                    "stop" => Some("stop"),
                    "restart" => Some("restart"),
                    _ => None,
                };
                match known {
                    Some(v) => {
                        app.push_log(format!(
                            "running {v} as requested by the elevated relaunch"
                        ));
                        app.start_action(v);
                    }
                    None => app.push_log(format!("ignoring unknown --run verb: {verb}")),
                }
            }
        }
        if app.tray.is_none() {
            app.push_log("tray icon unavailable on this desktop".to_string());
        }
        app
    }

    /// Second look at the restored position, now that the real DPI scale is
    /// known.
    ///
    /// The check at load time compares the saved position, which egui keeps in
    /// points, against monitor rectangles, which Windows reports in pixels. At
    /// 100% that is the same number twice; at 150% it is not, and a position far
    /// enough off can still pass. One frame in, the scale is known, so convert
    /// and ask again — and if the window landed nowhere, bring it back rather
    /// than leaving the user with a process, a tray icon and no window.
    fn rescue_window(&mut self, ctx: &egui::Context) {
        if self.pos_checked {
            return;
        }
        self.pos_checked = true;
        let info = ctx.input(|i| i.viewport().clone());
        let Some(rect) = info.outer_rect else {
            return;
        };
        let px = ctx.pixels_per_point();
        if screens::position_is_reachable(
            rect.min.x * px,
            rect.min.y * px,
            rect.width() * px,
            rect.height() * px,
        ) {
            return;
        }
        ctx.send_viewport_cmd(egui::ViewportCommand::OuterPosition(egui::pos2(80.0, 80.0)));
        self.push_log("the saved window position was off screen; moved the panel back".to_string());
    }

    fn push_log(&mut self, line: String) {
        let line = strip_ansi(&line);
        if line.trim().is_empty() {
            return;
        }
        self.log.push_back(line);
        while self.log.len() > LOG_CAP {
            self.log.pop_front();
        }
    }

    /// Resolve the script and start the status stream.
    fn attach(&mut self) {
        // A re-attach may point at a different script: nothing about the old
        // stack list survives it.
        self.switch = None;
        self.switch_error = None;
        self.switch_busy = false;
        self.switch_adding = false;
        match backend::resolve_script(self.settings.source, self.settings.script.as_ref()) {
            Ok(path) => {
                self.script_input = path.display().to_string();
                // Persist what discovery found: otherwise the settings file keeps
                // a null script and every later save writes it back that way.
                if self.settings.script.as_deref() != Some(self.script_input.as_str()) {
                    self.settings.script = Some(self.script_input.clone());
                    self.settings.save();
                }
                match backend::probe_cli(&path) {
                    Ok(version) => {
                        let be = Backend::new(path, self.settings.interval);
                        be.spawn_watch(self.tx.clone());
                        // The Stacks block lists registered roots from this
                        // snapshot; without it the section has nothing to show
                        // until the user asks for a switch. It is a poll, so it
                        // does not claim the busy flag: only an action does.
                        be.spawn_switch(Vec::new(), self.tx.clone());
                        self.push_log(format!(
                            "phpup {version}: {} [{}], polling every {}s",
                            be.script.display(),
                            self.settings.source.label(),
                            self.settings.interval
                        ));
                        self.backend = Some(be);
                        self.last_error = None;
                        self.status = None;
                        self.admin_verb = None;
                    }
                    Err(why) => {
                        self.backend = None;
                        self.status = None;
                        self.push_log(format!(
                            "not usable: {} ({why})",
                            path.display()
                        ));
                        self.last_error = Some(if self.settings.source == Source::Github {
                            format!(
                                "The published phpup.ps1 has no machine-readable CLI yet ({why}), \
                                 so the panel cannot read it. Switch Source to Local file and point \
                                 it at your checkout."
                            )
                        } else {
                            format!(
                                "{} does not answer `version --json` ({why}). It needs the \
                                 status/start/stop CLI.",
                                path.display()
                            )
                        });
                    }
                }
            }
            Err(msg) => {
                self.backend = None;
                self.status = None;
                self.push_log(format!("cannot start phpup: {msg}"));
                self.last_error = Some(if self.settings.source == Source::Github {
                    format!(
                        "Could not fetch phpup from GitHub ({msg}). Check the connection, refresh in \
                         Settings, or switch the source to a local file."
                    )
                } else {
                    format!("{msg}. Point the panel at phpup.ps1 in Settings.")
                });
            }
        }
    }

    fn start_action(&mut self, verb: &'static str) {
        if self.action.is_some() {
            return;
        }
        let Some(be) = &self.backend else { return };
        be.spawn_action(verb, self.tx.clone());
        self.action = Some(verb);
        self.push_log(format!("> {verb}"));
        if let Some(s) = &self.status {
            self.push_log(format!(
                "  was: apache {}, mariadb {}",
                on_off(s.components.apache.running()),
                on_off(s.components.mariadb.running())
            ));
        }
    }

    /// Hand one `switch` invocation to the CLI. Serialised on purpose: switch is
    /// read-modify-write, so two in flight would race over the same state.
    fn run_switch(&mut self, args: Vec<String>) {
        if self.switch_busy {
            return;
        }
        let Some(be) = &self.backend else { return };
        be.spawn_switch(args.clone(), self.tx.clone());
        self.switch_busy = true;
        self.switch_started = Some(Instant::now());
        self.switch_error = None;
        self.switch_admin_args = None;
        self.switch_last_args = args.clone();
        self.switch_adding = matches!(args.first().map(String::as_str), Some("--add"));
        let mut line = String::from("> switch");
        for a in &args {
            line.push(' ');
            line.push_str(a);
        }
        self.push_log(line);
    }

    /// Repeat the last switch with Administrator.
    ///
    /// A handover stops and starts registered services, which Windows refuses
    /// without an elevated token, so `switch --to <stack>` answers exit 4 from an
    /// ordinary panel. Elevating just the command keeps the tray and the window
    /// out of it; the UAC prompt is the one the user is being asked to accept.
    fn run_switch_elevated(&mut self) {
        if self.switch_busy {
            return;
        }
        let Some(args) = self.switch_admin_args.take() else { return };
        let Some(be) = &self.backend else { return };
        backend::spawn_switch_elevated(be.script.clone(), args.clone(), self.tx.clone());
        self.switch_busy = true;
        self.switch_started = Some(Instant::now());
        self.switch_adding = false;
        self.switch_last_args = args.clone();
        let mut line = String::from("> switch (elevated)");
        for a in &args {
            line.push(' ');
            line.push_str(a);
        }
        self.push_log(line);
        // The "needs Administrator rights" message was the reason this button
        // existed; once the button has been pressed it is out of date, and a
        // stale warning sitting next to a switch that is running reads as a failure.
        self.switch_error = None;
        self.push_log("  waiting for the consent prompt".to_string());
    }

    /// Re-read the switch snapshot on a timer, and give up on a call that never
    /// reports back.
    ///
    /// Everything the block shows can be changed by something else — a terminal,
    /// the other stack's own control panel — so state is pulled rather than
    /// assumed. A handover is also long enough that waiting for one event at the
    /// end is the worst way to watch it; the watchdog means a spawn that never
    /// returns costs one stale minute, not a session.
    fn poll_switch(&mut self, ctx: &egui::Context) {
        // One snapshot at a time, and rarely: each is a full phpup run. While the
        // window is in the background there is no one to read the result anyway.
        const FOCUSED: Duration = Duration::from_secs(20);
        const IDLE: Duration = Duration::from_secs(60);
        /// A snapshot that never comes back must not block the block forever.
        const STUCK: Duration = Duration::from_secs(90);
        if self.switch_poll_failed {
            return;
        }
        // A handover that waits on a UAC prompt and then on Start-Service can
        // take minutes: the observed run sat over a minute at the consent prompt
        // before the services even started. Long enough to be patient, short
        // enough that a genuinely lost call unlocks the buttons in this session.
        const GIVE_UP: Duration = Duration::from_secs(180);

        let now = Instant::now();
        if self.switch_busy {
            let stale = self
                .switch_started
                .map(|at| now.duration_since(at) > GIVE_UP)
                .unwrap_or(false);
            if stale {
                self.switch_busy = false;
                self.switch_started = None;
                self.push_log(
                    "  switch did not report back; re-reading the state".to_string(),
                );
                self.switch_last_poll = None;
            } else {
                // One thing at a time: the action's own payload lands next.
                ctx.request_repaint_after(Duration::from_millis(600));
                return;
            }
        }

        if self.switch_poll_inflight {
            let stuck = self
                .switch_last_poll
                .map(|at| now.duration_since(at) > STUCK)
                .unwrap_or(true);
            if stuck {
                // Give up on it rather than spawning its replacement on top.
                self.switch_poll_inflight = false;
            } else {
                return;
            }
        }

        let every = if ctx.input(|i| i.focused) { FOCUSED } else { IDLE };
        let due = self
            .switch_last_poll
            .map(|at| now.duration_since(at) >= every)
            .unwrap_or(true);
        if !due {
            return;
        }
        if let Some(be) = &self.backend {
            self.switch_last_poll = Some(now);
            self.switch_poll_inflight = true;
            be.spawn_switch(Vec::new(), self.tx.clone());
        }
    }

    fn drain(&mut self) {
        while let Ok(ev) = self.rx.try_recv() {
            match ev {
                Event::Status(status) => {
                    let before = self
                        .status
                        .as_ref()
                        .map(|s| (s.components.apache.running(), s.components.mariadb.running()));
                    let after = (
                        status.components.apache.running(),
                        status.components.mariadb.running(),
                    );
                    if status.schema != 1 {
                        self.push_log(format!(
                            "warning: payload schema {} — this panel understands schema 1",
                            status.schema
                        ));
                    }
                    if let Some(before) = before {
                        if before != after {
                            self.push_log(format!(
                                "stack: apache {}, mariadb {}",
                                on_off(after.0),
                                on_off(after.1)
                            ));
                        }
                    }
                    self.status = Some(*status);
                    self.last_seen = Some(Instant::now());
                    if self.last_error.is_some() {
                        self.last_error = None;
                    }
                }
                Event::ActionFinished {
                    verb,
                    exit,
                    result,
                    raw,
                } => {
                    self.action = None;
                    let code = result.as_ref().and_then(|r| r.code.clone());
                    let changed = result.as_ref().map(|r| r.changed).unwrap_or(false);
                    let detail = result
                        .as_ref()
                        .and_then(|r| r.errors.first().cloned())
                        .or_else(|| code.clone())
                        .unwrap_or_else(|| raw.trim().to_string());

                    let mut summary = format!("{verb}: exit {exit}");
                    if let Some(code) = &code {
                        summary.push_str(" · ");
                        summary.push_str(code);
                    }
                    if changed {
                        summary.push_str(" · changed");
                    }
                    self.push_log(summary);
                    if !detail.is_empty() && exit != 0 {
                        self.push_log(format!("  {detail}"));
                    }

                    self.toast = Some(match exit {
                        0 if changed => Toast {
                            text: format!("{verb}: done"),
                            ok: true,
                            at: Instant::now(),
                        },
                        0 => Toast {
                            text: format!("{verb}: already in that state"),
                            ok: true,
                            at: Instant::now(),
                        },
                        4 => {
                            self.admin_verb = Some(verb.clone());
                            self.push_log(
                                "  needs Administrator: use Run elevated".to_string(),
                            );
                            Toast {
                                text: format!("{verb} needs Administrator"),
                                ok: false,
                                at: Instant::now(),
                            }
                        }
                        5 => Toast {
                            text: format!("Port conflict: {detail}"),
                            ok: false,
                            at: Instant::now(),
                        },
                        3 => Toast {
                            text: "No stack installed yet".to_string(),
                            ok: false,
                            at: Instant::now(),
                        },
                        _ => Toast {
                            text: format!(
                                "{verb} failed{}",
                                if detail.is_empty() {
                                    String::new()
                                } else {
                                    format!(": {detail}")
                                }
                            ),
                            ok: false,
                            at: Instant::now(),
                        },
                    });
                }
                Event::Switch {
                    payload,
                    from_action,
                } => {
                    // The backend says whether the user asked for this. A
                    // snapshot that happens to be in flight when a button is
                    // pressed must never stand in for the action's result.
                    self.switch_poll_inflight = false;
                    if from_action {
                        self.switch_busy = false;
                        self.switch_started = None;
                    }
                    let acted = from_action;
                    if payload.ok {
                        // Only a successful *action* clears the message; the snapshot
                        // that follows it is always ok, and would wipe the very error
                        // the user is still reading.
                        if acted {
                            self.switch_error = None;
                        }
                        // Only clear what the user typed if phpup actually
                        // registered it; a rejected path has to stay editable.
                        if self.switch_adding {
                            self.new_stack_path.clear();
                        }
                    } else {
                        self.switch_error =
                            payload.first_error().or_else(|| Some("switch failed".to_string()));
                    }
                    // When the only thing missing is the elevated token, keep the
                    // arguments so the block can offer to repeat the exact call.
                    // Only a payload from a user action may change this: the
                    // snapshot that follows every action is ok and would drop the
                    // offer a second after it appeared.
                    if acted {
                        self.switch_admin_args = if payload.code.as_deref()
                            == Some("elevation_required")
                        {
                            Some(self.switch_last_args.clone())
                        } else {
                            None
                        };
                    }
                    self.switch_adding = false;
                    // Snapshots are silent: a line every few seconds would bury
                    // the account of what the user actually did.
                    if acted {
                        self.push_log(switch_summary(&payload));
                    }
                    // Warnings and steps are the only account of what phpup did;
                    // the Stacks block shows state, the console shows the work.
                    for w in payload.warnings.iter().filter(|w| !w.trim().is_empty()) {
                        self.push_log(format!("  warning: {w}"));
                    }
                    for step in payload.steps.iter().filter(|s| !s.trim().is_empty()) {
                        self.push_log(format!("  {step}"));
                    }
                    // A payload without ports (an --add answers with ports:null because
                    // it never probes) must not wipe what the block is already showing.
                    let mut payload = payload;
                    if payload.ports.is_none() {
                        if let Some(prev) = &self.switch {
                            payload.ports = prev.ports.clone();
                        }
                    }
                    let hint = self.switch.as_ref().and_then(switch_holder);
                    let (ports_line, _) = switch_port_line(&payload, hint.as_deref());
                    self.switch = Some(*payload);
                    // The ownership line belongs with the other diagnostics, not
                    // above the stack list; it is written when it changes.
                    if !ports_line.is_empty() && ports_line != self.ports_logged {
                        self.ports_logged = ports_line.clone();
                        self.push_log(format!("ports: {ports_line}"));
                    }
                    // An --add answers with ports:null because it never probes. Re-read
                    // the snapshot so a successful registration cannot leave the block
                    // sitting on "unknown", and so --to lands with fresh owners.
                    if acted {
                        if let Some(be) = &self.backend {
                            be.spawn_switch(Vec::new(), self.tx.clone());
                        }
                    }
                }
                Event::Relaunched(res) => match res {
                    Ok(()) => {
                        self.push_log("elevated instance is starting; closing this one".to_string());
                        self.relaunch_ok = true;
                    }
                    Err(e) => self.push_log(format!("elevation failed: {e}")),
                },
                Event::Log(line) => self.push_log(line),
                Event::Failed(msg) => {
                    self.action = None;
                    self.switch_started = None;
                    // The snapshot that was in flight is gone with it; without
                    // this the block would wait for a payload that is never coming.
                    self.switch_poll_inflight = false;
                    // A switch that never produced JSON is finished as far as
                    // the UI is concerned; otherwise its buttons stay disabled
                    // for the rest of the session.
                    if self.switch_busy {
                        self.switch_busy = false;
                        self.switch_adding = false;
                        self.switch_error = Some(msg.clone());
                        self.push_log(format!("error: {msg}"));
                    }
                    else if msg.starts_with("switch:") && !self.switch_poll_failed {
                        // A snapshot against a phpup.ps1 with no `switch` verb
                        // answers "help for usage" forever. Say it once and stop
                        // asking: the console is not a place to repeat a fact.
                        self.switch_poll_failed = true;
                        self.push_log(format!("error: {msg}"));
                        self.push_log(
                            "  stack switching is off for this session: that phpup.ps1 has no `switch` verb"
                                .to_string(),
                        );
                    }
                    self.last_error = Some(msg);
                }
            }
        }
        if let Some(t) = &self.toast {
            if t.at.elapsed() > TOAST_TTL {
                self.toast = None;
            }
        }
    }

    fn header(&mut self, ui: &mut egui::Ui, p: &Palette) {
        let mut toggle_settings = false;
        let mut toggle_console = false;
        let mut toggle_about = false;

        egui::Panel::top("header")
            .frame(
                Frame::group(ui.style())
                    .fill(p.surface)
                    .inner_margin(Margin::symmetric(18, 14)),
            )
            .show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.label(RichText::new("phpup").size(21.0).strong().color(p.text));
                    ui.add_space(6.0);
                    ui.label(
                        RichText::new("— Bare-metal PHP for local development")
                            .size(12.0)
                            .color(p.muted),
                    );

                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        let settings_btn = filled_nav(ui, p, "Settings");
                        self.settings_toggle_rect = Some(settings_btn.rect);
                        if settings_btn.clicked() {
                            toggle_settings = true;
                        }
                        if filled_nav(ui, p, "Output").clicked() {
                            toggle_console = true;
                        }

                        if plain_nav(ui, p, "About") {
                            toggle_about = true;
                        }

                        // Links only: the three actions live on the body, next to
                        // the cards they act on.
                        let links = match &self.status {
                            Some(st) => (
                                st.urls.root.clone(),
                                st.urls.phpinfo.clone(),
                                st.urls.phpmyadmin.clone(),
                                st.paths.logs.clone(),
                                st.paths.www.clone(),
                            ),
                            None => (None, None, None, None, None),
                        };
                        let mut open_url: Option<String> = None;

                        ui.menu_button(RichText::new("Links").size(12.0), |ui| {
                            if let Some(url) = &links.0 {
                                if ui.button("localhost").clicked() {
                                    open_url = Some(url.clone());
                                    ui.close();
                                }
                            }
                            if let Some(url) = &links.1 {
                                if ui.button("phpinfo").clicked() {
                                    open_url = Some(url.clone());
                                    ui.close();
                                }
                            }
                            if let Some(url) = &links.2 {
                                if ui.button("phpMyAdmin").clicked() {
                                    open_url = Some(url.clone());
                                    ui.close();
                                }
                            }
                            if let Some(path) = &links.3 {
                                if ui.button("logs").clicked() {
                                    open_url = Some(path.clone());
                                    ui.close();
                                }
                            }
                            if let Some(path) = &links.4 {
                                if ui.button("www folder").clicked() {
                                    open_url = Some(path.clone());
                                    ui.close();
                                }
                            }
                        });

                        if let Some(url) = open_url {
                            backend::open_in_default_app(&url);
                        }
                    });
                });
            });

        if toggle_settings {
            self.settings_open = !self.settings_open;
        }
        if toggle_console {
            self.console_open = !self.console_open;
        }
        if toggle_about {
            self.about_open = true;
        }
    }

    /// Logo, tagline, versions, links. The image earns its place here rather
    /// than as a banner above the settings form.
    fn about_window(&mut self, ui: &mut egui::Ui, p: &Palette) {
        let mut open = self.about_open;
        let mut link: Option<String> = None;

        egui::Window::new("About phpup")
            .open(&mut open)
            .collapsible(false)
            .resizable(false)
            .anchor(egui::Align2::CENTER_CENTER, Vec2::ZERO)
            .frame(
                Frame::group(ui.style())
                    .fill(p.surface)
                    .inner_margin(Margin::same(18))
                    .stroke(Stroke::new(1.0, p.border)),
            )
            .show(ui.ctx(), |ui| {
                ui.set_max_width(360.0);

                if let Some(brand) = &self.brand {
                    let width = ui.available_width();
                    let inset = 0.06;
                    let height = width * (brand.size.y / brand.size.x);
                    let sized = egui::load::SizedTexture::new(brand.texture.id(), brand.size);
                    let uv = egui::Rect::from_min_max(
                        egui::pos2(inset, inset),
                        egui::pos2(1.0 - inset, 1.0 - inset),
                    );
                    ui.add(
                        egui::Image::new(sized)
                            .uv(uv)
                            .fit_to_exact_size(Vec2::new(width, height))
                            .corner_radius(CornerRadius::same(10)),
                    );
                    ui.add_space(12.0);
                }

                ui.label(RichText::new("phpup").size(18.0).strong().color(p.text));
                ui.label(
                    RichText::new("Bare-metal PHP for local development")
                        .size(12.0)
                        .color(p.muted),
                );

                ui.add_space(10.0);
                ui.label(
                    RichText::new(
                        "Apache, PHP, MariaDB and phpMyAdmin in a single directory. No container, \
                         no virtual machine, no global install — just a stack you can switch, \
                         back up and delete. This panel is the control surface; phpup itself does \
                         the installing and updating.",
                    )
                    .size(11.5)
                    .color(p.text),
                );

                ui.add_space(12.0);
                let phpup_version = self
                    .status
                    .as_ref()
                    .and_then(|s| s.phpup.version.clone())
                    .unwrap_or_else(|| "not connected".to_string());
                for (label, value) in [
                    ("Panel", env!("CARGO_PKG_VERSION").to_string()),
                    ("phpup", phpup_version),
                ] {
                    ui.horizontal(|ui| {
                        ui.label(RichText::new(label).size(11.0).color(p.muted));
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            ui.label(
                                RichText::new(value).size(11.0).monospace().color(p.text),
                            );
                        });
                    });
                }

                ui.add_space(10.0);
                if ui
                    .link(RichText::new("github.com/DaFa66/phpup").size(11.5))
                    .clicked()
                {
                    link = Some("https://github.com/DaFa66/phpup".to_string());
                }
            });

        self.about_open = open;
        if let Some(url) = link {
            backend::open_in_default_app(&url);
        }
    }

    fn footer(&mut self, ui: &mut egui::Ui, p: &Palette) {
        let updated = self
            .status
            .as_ref()
            .and_then(|s| s.generated_at.as_deref())
            .and_then(|g| g.get(11..19))
            .map(|t| t.to_string())
            .unwrap_or_else(|| "-".to_string());
        let version = self
            .status
            .as_ref()
            .and_then(|s| s.phpup.version.clone())
            .unwrap_or_else(|| "-".to_string());
        let install = self
            .status
            .as_ref()
            .and_then(|s| s.install.path.clone())
            .unwrap_or_else(|| "-".to_string());
        let script = self
            .backend
            .as_ref()
            .map(|b| b.script.display().to_string())
            .unwrap_or_else(|| "no script".to_string());
        let source = self.settings.source.label();
        let interval = self.settings.interval;

        egui::Panel::bottom("footer")
            .frame(
                Frame::group(ui.style())
                    .fill(p.surface)
                    .inner_margin(Margin::symmetric(18, 8)),
            )
            .show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.label(
                        RichText::new(format!(
                            "{install}   ·   phpup {version}   ·   every {interval}s   ·   updated {updated}"
                        ))
                        .size(11.0)
                        .color(p.muted),
                    );
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        ui.label(
                            RichText::new(format!("[{source}]"))
                                .size(10.5)
                                .color(p.muted),
                        );
                        ui.label(RichText::new(script).size(11.0).color(p.muted));
                    });
                });
            });
    }

    /// The job log: everything phpup says on stderr, plus panel events. This
    /// is where install/update progress will stream once those verbs exist.
    fn console(&mut self, ui: &mut egui::Ui, p: &Palette, want: f32) {
        let open = self.console_open;
        let mut clear = false;
        let mut copy = false;
        let mut toggle_pin = false;
        let pinned = self.log_pinned;
        let lines: Vec<String> = std::mem::take(&mut self.log).into_iter().collect();
        let count = lines.len();

        // Height is decided by the caller: whatever the cards and the stack
        // strip do not need. A fixed pane left the slack under the cards, which
        // reads as a layout bug rather than as space to type in.
        // Not resizable: eframe restores the dragged size from the previous
        // session, which fought the exact size computed here and left the gap
        // under the cards intact no matter what the caller asked for.
        // Plain show, not show_collapsible: the collapse animation interpolates the
        // reserved height, and when repaints stop mid-slide the panel stays pinned
        // at that fraction — which is what kept the log at ~120pt while the caller
        // asked for the slack. Hidden is simply not drawn.
        if !open {
            self.log = lines.into_iter().collect();
            return;
        }
        // exact_size sets both bounds. A following min_size() re-widens the range,
        // which let the height persisted from an earlier session win — that is why
        // the pane stayed at its old 120pt however much slack the caller passed.
        egui::Panel::bottom("console")
            .exact_size(want.max(88.0))
            .frame(
                Frame::group(ui.style())
                    .fill(p.surface)
                    .inner_margin(Margin::same(12)),
            )
            .show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.label(RichText::new("Output").size(12.0).strong().color(p.text));
                    ui.label(
                        RichText::new(format!("{count} lines"))
                            .size(10.5)
                            .color(p.muted),
                    );
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if ui.small_button("Clear").clicked() {
                            clear = true;
                        }
                        if ui.small_button("Copy").clicked() {
                            copy = true;
                        }
                        if ui
                            .small_button(if pinned { "Following" } else { "Paused" })
                            .clicked()
                        {
                            toggle_pin = true;
                        }
                    });
                });
                ui.add_space(2.0);
                egui::ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .stick_to_bottom(pinned)
                    .show(ui, |ui| {
                        if lines.is_empty() {
                            ui.label(
                                RichText::new("Nothing yet.")
                                    .monospace()
                                    .size(11.0)
                                    .color(p.muted),
                            );
                        }
                        for line in &lines {
                            ui.label(RichText::new(line).monospace().size(11.0).color(p.muted));
                        }
                    });
            });

        self.log = lines.into_iter().collect();
        self.console_open = open;
        if toggle_pin {
            self.log_pinned = !self.log_pinned;
        }
        if clear {
            self.log.clear();
        }
        if copy {
            let all = self.log.iter().cloned().collect::<Vec<_>>().join("\n");
            ui.ctx().copy_text(all);
        }
    }

    fn settings_panel(&mut self, ui: &mut egui::Ui, p: &Palette) {
        let mut dirty = false;
        let mut interval_changed = false;
        let mut do_attach = false;
        let mut refresh = false;
        let mut elevate_now = false;
        let mut open = self.settings_open;
        let mut want_close = false;
        // Set when a service start type chip is clicked; applied after the status
        // borrow is released.
        let mut service_change: Option<(String, String)> = None;

        let resp = egui::Panel::right("settings")
            .resizable(false)
            .exact_size(358.0)
            .frame(
                Frame::group(ui.style())
                    .fill(p.surface)
                    // Extra right margin: the auto scrollbar otherwise sits on
                    // top of the last column of text and clips it.
                    .inner_margin(Margin {
                        left: 16,
                        right: 14,
                        top: 18,
                        bottom: 18,
                    })
                    .stroke(Stroke::new(1.0, p.border)),
            )
            .show_collapsible(ui, &mut open, |ui| {
                // A floating scrollbar is drawn on top of the content, so the
                // last column sits underneath it. Reserve the lane instead.
                ui.style_mut().spacing.scroll.floating = false;
                ui.style_mut().spacing.scroll.bar_outer_margin = 8.0;
                egui::ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        ui.horizontal(|ui| {
                            ui.label(
                                RichText::new("Settings").size(16.0).strong().color(p.text),
                            );
                            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                                if plain_nav(ui, p, "Close") {
                                    want_close = true;
                                }
                            });
                        });
                        ui.add_space(12.0);

                        // State, mode and registration live here now: in the
                        // header they read as broken menus.
                        section_label(ui, p, "STATUS");
                        match &self.status {
                            Some(s) => {
                                let mut facts = vec![s.stack_state().to_string()];
                                if self.elevated {
                                    facts.push("administrator".to_string());
                                }
                                if let Some(mode) = &s.services.mode {
                                    facts.push(format!("{mode} mode"));
                                }
                                facts.push(
                                    if s.services.registered {
                                        "registered".to_string()
                                    } else {
                                        "not registered".to_string()
                                    },
                                );
                                if s.services.autostart {
                                    facts.push("autostart".to_string());
                                }
                                ui.add(
                                    egui::Label::new(
                                        RichText::new(facts.join("  ·  "))
                                            .size(11.0)
                                            .color(p.muted),
                                    )
                                    .wrap(),
                                );

                                let os = s.platform.os.clone().unwrap_or_else(|| "-".into());
                                let arch = s.platform.arch.clone().unwrap_or_else(|| "-".into());
                                let backend_name =
                                    s.platform.backend.clone().unwrap_or_else(|| "-".into());
                                let mut line = format!("{os} {arch}  ·  {backend_name}");
                                if let Some(distro) = &s.platform.distro {
                                    line = format!("{distro}  ·  {line}");
                                }
                                ui.add(
                                    egui::Label::new(
                                        RichText::new(line).size(11.0).color(p.muted),
                                    )
                                    .wrap(),
                                );

                                if !s.services.items.is_empty() {
                                    ui.add_space(10.0);
                                    section_label(ui, p, "SERVICES");
                                    for item in &s.services.items {
                                        let name = item.name.clone().unwrap_or_default();
                                        let (state, colour) = if item.enabled {
                                            ("enabled", p.ok)
                                        } else if item.registered {
                                            ("disabled", p.muted)
                                        } else {
                                            ("absent", p.muted)
                                        };
                                        ui.horizontal(|ui| {
                                            ui.label(
                                                RichText::new(name.clone())
                                                    .size(11.0)
                                                    .monospace()
                                                    .color(p.text),
                                            );
                                            ui.with_layout(
                                                Layout::right_to_left(Align::Center),
                                                |ui| {
                                                    // Keep the controls off the scrollbar.
                                                    ui.add_space(10.0);
                                                    if item.registered {
                                                        // right_to_left lays out rightmost
                                                        // first, so this reads [Auto][Disabled].
                                                        if chip(ui, p, "Disabled", !item.enabled)
                                                            && item.enabled
                                                        {
                                                            service_change = Some((
                                                                name.clone(),
                                                                "disabled".to_string(),
                                                            ));
                                                        }
                                                        if chip(ui, p, "Auto", item.enabled)
                                                            && !item.enabled
                                                        {
                                                            service_change = Some((
                                                                name.clone(),
                                                                "auto".to_string(),
                                                            ));
                                                        }
                                                    } else {
                                                        ui.label(
                                                            RichText::new(state)
                                                                .size(10.5)
                                                                .color(colour),
                                                        );
                                                    }
                                                },
                                            );
                                        });
                                    }
                                }
                            }
                            None => {
                                ui.label(
                                    RichText::new("no status yet").size(11.0).color(p.muted),
                                );
                            }
                        }

                        if let Some((name, mode)) = service_change.take() {
                            match backend::set_service_start(&name, &mode) {
                                Ok(()) => {
                                    self.push_log(format!("{name}: startup type set to {mode}"))
                                }
                                Err(e) => self.push_log(format!(
                                    "{name}: could not set startup type to {mode}: {e}"
                                )),
                            }
                        }

                        ui.add_space(16.0);
                        section_label(ui, p, "APPEARANCE");
                        ui.horizontal(|ui| {
                            for pref in [ThemePref::System, ThemePref::Light, ThemePref::Dark] {
                                let selected = self.settings.theme == pref;
                                let text = RichText::new(pref.label()).size(12.0).color(
                                    if selected { p.accent_text } else { p.text },
                                );
                                let button = egui::Button::new(text)
                                    .fill(if selected { p.accent } else { p.surface_2 })
                                    .corner_radius(CornerRadius::same(8));
                                if ui.add(button).clicked() && !selected {
                                    self.settings.theme = pref;
                                    dirty = true;
                                }
                            }
                        });

                        ui.add_space(16.0);
                        section_label(ui, p, "ZOOM");
                        ui.horizontal_wrapped(|ui| {
                            for (label, value) in [
                                ("Auto", 0.0f32),
                                ("85%", 0.85),
                                ("100%", 1.0),
                                ("115%", 1.15),
                                ("130%", 1.3),
                            ] {
                                let selected = (self.settings.zoom - value).abs() < 0.001;
                                let text = RichText::new(label).size(11.5).color(
                                    if selected { p.accent_text } else { p.text },
                                );
                                let button = egui::Button::new(text)
                                    .min_size(Vec2::new(0.0, 22.0))
                                    .fill(if selected { p.accent } else { p.surface_2 })
                                    .corner_radius(CornerRadius::same(8));
                                if ui.add(button).clicked() && !selected {
                                    self.settings.zoom = value;
                                    dirty = true;
                                }
                            }
                        });
                        ui.label(
                            RichText::new("Auto follows the monitor's own scaling.")
                                .size(10.5)
                                .color(p.muted),
                        );

                        ui.add_space(16.0);
                        section_label(ui, p, "WINDOW");
                        let mut in_tray = self.settings.start_in_tray;
                        if ui
                            .checkbox(
                                &mut in_tray,
                                RichText::new("Start hidden in the tray")
                                    .size(12.0)
                                    .color(p.text),
                            )
                            .changed()
                        {
                            self.settings.start_in_tray = in_tray;
                            dirty = true;
                            self.push_log(
                                if in_tray {
                                    "launches to the tray: no window, no taskbar button"
                                } else {
                                    "launches with the window open"
                                }
                                .to_string(),
                            );
                        }
                        ui.add(egui::Label::new(
                            RichText::new("Tray icon only at launch; click it to show the window.")
                                .size(10.5)
                                .color(p.muted),
                        ));

                        ui.add_space(16.0);
                        section_label(ui, p, "STARTUP");
                        let mut autostart = self.autostart;
                        if ui
                            .checkbox(
                                &mut autostart,
                                RichText::new("Start with Windows").size(12.0).color(p.text),
                            )
                            .changed()
                        {
                            match backend::set_autostart(autostart) {
                                Ok(()) => {
                                    self.autostart = autostart;
                                    self.push_log(
                                        if autostart {
                                            "panel will start when you sign in"
                                        } else {
                                            "panel will not start when you sign in"
                                        }
                                        .to_string(),
                                    );
                                }
                                Err(e) => {
                                    // Show what is actually registered, not what was asked for.
                                    self.autostart = backend::autostart_enabled();
                                    self.push_log(format!("could not change autostart: {e}"));
                                }
                            }
                        }
                        ui.add(egui::Label::new(
                            RichText::new("Per-user Run entry; no administrator needed.")
                                .size(10.5)
                                .color(p.muted),
                        ));

                        ui.add_space(16.0);
                        section_label(ui, p, "PRIVILEGES");
                        ui.add(
                            egui::Label::new(
                                RichText::new(if self.elevated {
                                    "Running as administrator. Actions that touch the services will not prompt."
                                } else {
                                    "Not elevated. Actions that touch the services will ask for Administrator."
                                })
                                .size(11.0)
                                .color(p.muted),
                            )
                            .wrap(),
                        );
                        ui.add_space(6.0);
                        let mut always = self.settings.always_admin;
                        if ui
                            .checkbox(
                                &mut always,
                                RichText::new("Always run as administrator").size(12.0).color(p.text),
                            )
                            .changed()
                        {
                            self.settings.always_admin = always;
                            dirty = true;
                            self.push_log(
                                if always {
                                    "administrator mode on: the panel elevates itself at launch"
                                } else {
                                    "administrator mode off: actions ask only when they need it"
                                }
                                .to_string(),
                            );
                        }
                        ui.add(egui::Label::new(
                            RichText::new("One prompt at launch, then no interruptions.")
                                .size(10.5)
                                .color(p.muted),
                        ));
                        if !self.elevated {
                            ui.add_space(6.0);
                            if ui
                                .add(
                                    egui::Button::new(
                                        RichText::new("Run as administrator now").color(p.accent_text),
                                    )
                                    .fill(p.accent)
                                    .corner_radius(CornerRadius::same(8)),
                                )
                                .clicked()
                            {
                                elevate_now = true;
                            }
                        }

                        ui.add_space(14.0);
                        section_label(ui, p, "SOURCE");
                        ui.horizontal(|ui| {
                            for src in [Source::Github, Source::Local] {
                                let selected = self.settings.source == src;
                                let text = RichText::new(src.label()).size(12.0).color(
                                    if selected { p.accent_text } else { p.text },
                                );
                                let button = egui::Button::new(text)
                                    .fill(if selected { p.accent } else { p.surface_2 })
                                    .corner_radius(CornerRadius::same(8));
                                if ui.add(button).clicked() && !selected {
                                    self.settings.source = src;
                                    do_attach = true;
                                    dirty = true;
                                }
                            }
                        });

                        match self.settings.source {
                            Source::Github => {
                                ui.add_space(6.0);
                                let repo = if cfg!(windows) {
                                    "DaFa66/phpup · phpup.ps1"
                                } else {
                                    "DaFa66/phpup · phpup.sh"
                                };
                                ui.add(
                                    egui::Label::new(
                                        RichText::new(repo).size(10.5).color(p.muted),
                                    )
                                    .truncate(),
                                )
                                .on_hover_text(backend::remote_url());
                                if let Some(path) = backend::cached_script() {
                                    let state = if path.is_file() {
                                        "cached"
                                    } else {
                                        "not downloaded yet"
                                    };
                                    ui.add(
                                        egui::Label::new(
                                            RichText::new(format!(
                                                "{state}: {}",
                                                path.display()
                                            ))
                                            .size(10.5)
                                            .color(p.muted),
                                        )
                                        .truncate(),
                                    )
                                    .on_hover_text(path.display().to_string());
                                }
                                if ui
                                    .add(
                                        egui::Button::new(
                                            RichText::new("Refresh from GitHub")
                                                .size(12.0)
                                                .color(p.text),
                                        )
                                        .fill(p.surface_2)
                                        .corner_radius(CornerRadius::same(8)),
                                    )
                                    .clicked()
                                {
                                    refresh = true;
                                }
                            }
                            Source::Local => {
                                ui.add_space(6.0);
                                ui.add(
                                    egui::TextEdit::singleline(&mut self.script_input)
                                        .desired_width(f32::INFINITY)
                                        .font(egui::TextStyle::Small),
                                );
                                ui.horizontal(|ui| {
                                    if plain_nav(ui, p, "Detect") {
                                        self.settings.script = None;
                                        do_attach = true;
                                        dirty = true;
                                    }
                                    let input = self.script_input.trim().to_string();
                                    let changed =
                                        !input.is_empty()
                                            && self.settings.script.as_deref() != Some(input.as_str());
                                    if changed && plain_nav(ui, p, "Use path") {
                                        self.settings.script = Some(input);
                                        do_attach = true;
                                        dirty = true;
                                    }
                                });
                            }
                        }

                        ui.add_space(16.0);
                        section_label(ui, p, "REFRESH");
                        if ui
                            .add(
                                egui::Slider::new(&mut self.settings.interval, 1..=10)
                                    .suffix(" s"),
                            )
                            .changed()
                        {
                            dirty = true;
                            interval_changed = true;
                        }
                    });
            });

        self.settings_rect = resp.map(|r| r.response.rect);

        if want_close {
            open = false;
        }
        self.settings_open = open;
        if dirty {
            self.settings.save();
        }
        if refresh {
            self.push_log(format!("fetching {}", backend::remote_url()));
            match backend::fetch_remote() {
                Ok(path) => {
                    self.push_log(format!("saved {}", path.display()));
                    do_attach = true;
                }
                Err(e) => {
                    self.push_log(format!("fetch failed: {e}"));
                    self.last_error = Some(format!("GitHub fetch failed: {e}"));
                }
            }
        }
        if elevate_now {
            let tx = self.tx.clone();
            self.push_log("raising the panel to administrator".to_string());
            std::thread::spawn(move || match backend::relaunch_panel(None) {
                Ok(()) => {
                    let _ = tx.send(Event::Relaunched(Ok(())));
                }
                Err(e) => {
                    let _ = tx.send(Event::Log(format!("  elevation failed: {e}")));
                }
            });
        }
        if interval_changed {
            self.restart_watch();
        }
        if do_attach {
            self.attach();
        }
    }

    /// The watch child takes its interval as an argument, so a new rate means a
    /// new process. Sliding the control used to rewrite the footer and nothing else.
    fn restart_watch(&mut self) {
        let interval = self.settings.interval;
        let tx = self.tx.clone();
        let Some(be) = self.backend.as_mut() else {
            return;
        };
        be.interval = interval;
        be.stop_watch();
        be.spawn_watch(tx);
        self.push_log(format!("polling every {interval}s"));
    }

    fn body(&mut self, ui: &mut egui::Ui, p: &Palette) {
        let mut pending: Option<&'static str> = None;
        let mut elevated: Option<String> = None;
        let mut open_url: Option<String> = None;
        let mut open_settings = false;

        egui::CentralPanel::no_frame()
            .frame(
                Frame::group(ui.style())
                    .fill(p.bg)
                    .inner_margin(Margin::same(18)),
            )
            .show(ui, |ui| {
                // [false, true]: full width, but only as tall as its contents —
                // otherwise it reports the whole panel and the console can never
                // claim the slack (the dead space under the cards).
                let scrolled = egui::ScrollArea::vertical()
                    .auto_shrink([false, true])
                    .show(ui, |ui| {
                        if let Some(verb) = self.admin_verb.clone() {
                            Frame::group(ui.style())
                                .fill(p.surface)
                                .stroke(Stroke::new(1.0, p.warn))
                                .corner_radius(CornerRadius::same(12))
                                .inner_margin(Margin::same(14))
                                .show(ui, |ui| {
                                    ui.horizontal_wrapped(|ui| {
                                        ui.label(
                                            RichText::new(format!(
                                                "`{verb}` needs Administrator: phpup's services are registered."
                                            ))
                                            .size(12.5)
                                            .color(p.text),
                                        );
                                        if ui
                                            .add(
                                                egui::Button::new(
                                                    RichText::new("Run as administrator")
                                                        .color(ON_ACCENT)
                                                        .strong(),
                                                )
                                                .fill(p.accent)
                                                .corner_radius(CornerRadius::same(8)),
                                            )
                                            .clicked()
                                        {
                                            elevated = Some(verb.clone());
                                        }
                                    });
                                });
                            ui.add_space(10.0);
                        }

                        if let Some(status) = &self.status {
                            self.status_area(ui, p, status, &mut pending, &mut open_url);
                        } else if let Some(err) = &self.last_error {
                            Frame::group(ui.style())
                                .fill(p.surface)
                                .stroke(Stroke::new(1.0, p.border))
                                .corner_radius(CornerRadius::same(14))
                                .inner_margin(Margin::same(20))
                                .show(ui, |ui| {
                                    ui.label(RichText::new("Not connected").size(16.0).strong());
                                    ui.add_space(4.0);
                                    ui.label(RichText::new(err).size(12.5).color(p.muted));
                                    ui.add_space(8.0);
                                    if ui.button("Open Settings").clicked() {
                                        open_settings = true;
                                    }
                                });
                        } else {
                            ui.add_space(40.0);
                            ui.vertical_centered(|ui| {
                                ui.label(RichText::new("Waiting for phpup…").size(14.0).color(p.muted));
                            });
                        }

                        // The stack switcher used to sit here, at the bottom of a
                        // scrolling column, where its rows fell off the window edge.
                        // It is a strip above the console now.
                        ui.min_rect().height()
                    });
                // The scroll content's height, not the panel's: `inner` is the
                // panel-sized Ui (always full height), which is why the console
                // could never claim the slack and the gap sat under the cards.
                self.body_h = scrolled.content_size.y;
                self.body_need = self.body_need.max(self.body_h);
            });

        if let Some(verb) = pending {
            self.start_action(verb);
        }
        if open_settings {
            self.settings_open = true;
        }
        // Elevate the panel itself: one UAC prompt, then every later action runs
        // without asking again. The verb is handed to the new instance.
        if let Some(verb) = elevated {
            if let Some(be) = &self.backend {
                let script = be.script.clone();
                let tx = self.tx.clone();
                self.push_log(format!("> {verb} (elevated)"));
                let always = self.settings.always_admin;
                std::thread::spawn(move || {
                    // Administrator mode elevates the panel and hands it the verb;
                    // otherwise only this one action is elevated.
                    if always {
                        match backend::relaunch_panel(Some(&verb)) {
                            Ok(()) => {
                                let _ = tx.send(Event::Relaunched(Ok(())));
                                return;
                            }
                            Err(e) => {
                                let _ = tx.send(Event::Log(format!("  panel elevation declined: {e}")));
                            }
                        }
                    } else {
                        match backend::run_elevated(&script, &verb) {
                            Ok(()) => {
                                let _ = tx.send(Event::Log(
                                    "  ran the action elevated; panel stays unelevated".to_string(),
                                ));
                                return;
                            }
                            Err(e) => {
                                let _ = tx.send(Event::Log(format!("  elevation failed: {e}")));
                                return;
                            }
                        }
                    }
                    // Administrator mode failed: fall back to a one-off elevation.
                    match backend::run_elevated(&script, &verb) {
                        Ok(()) => {
                            let _ = tx.send(Event::Log(
                                "  ran the action elevated instead; panel stays unelevated".to_string(),
                            ));
                        }
                        Err(e) => {
                            let _ = tx.send(Event::Log(format!("  elevation failed: {e}")));
                        }
                    }
                });
                self.admin_verb = None;
            }
        }
        if let Some(url) = open_url {
            backend::open_in_default_app(&url);
        }
    }

    /// Mirror the live window geometry into the settings, so closing the panel
    /// (or any later save) writes the size the user actually chose.
    fn track_window(&mut self, ctx: &egui::Context) {
        let info = ctx.input(|i| i.viewport().clone());
        if info.maximized == Some(true) {
            // A maximised window's inner_rect is the screen, not a size worth
            // restoring as "normal"; keep the last normal size instead.
            self.win.maximized = true;
        } else {
            self.win.maximized = false;
            if let Some(rect) = info.inner_rect {
                self.win.w = rect.width();
                self.win.h = rect.height();
            }
            if let Some(rect) = info.outer_rect {
                // Never record a spot that cannot be found again: a drag that
                // ends past the edge of the last monitor would otherwise make
                // the next launch invisible. The previous good position stays.
                if screens::position_is_reachable(rect.min.x, rect.min.y, self.win.w, self.win.h) {
                    self.win.x = Some(rect.min.x);
                    self.win.y = Some(rect.min.y);
                }
            }
        }
        self.settings.window = Some(self.win);

        let now_state = (self.win.w, self.win.h, self.win.x, self.win.y, self.win.maximized);
        let due = self
            .win_saved_at
            .map(|t| t.elapsed() >= std::time::Duration::from_secs(2))
            .unwrap_or(true);
        if due && self.win_saved != Some(now_state) {
            self.settings.save();
            self.win_saved = Some(now_state);
            self.win_saved_at = Some(std::time::Instant::now());
        }
    }

    /// The stack switcher, as a strip directly above the console.
    ///
    /// It sits here because it is the one control that changes everything the
    /// cards above report, and at the bottom of the scrolling column it fell off
    /// the window edge as soon as anything pushed the content down.
    fn stacks_strip(&mut self, ui: &mut egui::Ui, p: &Palette) {
        let strip_h = egui::Panel::bottom("stacks_strip")
            .resizable(false)
            .frame(
                Frame::NONE
                    .fill(p.bg)
                    .inner_margin(Margin::symmetric(18, 6))
                    .stroke(Stroke::new(1.0, p.border)),
            )
            .show(ui, |ui| {
                // The links line lives here now: directly above the switcher and
                // sharing its rule, instead of floating at the bottom of a
                // scrolling column with dead space beneath it.
                self.stacks_block(ui, p);
            })
            .response
            .rect
            .height();
        self.strip_h = strip_h;
    }

    fn stacks_block(&mut self, ui: &mut egui::Ui, p: &Palette) {
        // Registering and handing over roots. Lives outside Settings because
        // handing the ports over is an action, not a preference.
        // Nothing to say until the first snapshot lands (or it failed).
        if self.switch.is_none() && !self.switch_busy && self.switch_error.is_none() {
            return;
        }

        let busy = self.switch_busy;
        let stacks: Vec<backend::ForeignStack> = self
            .switch
            .as_ref()
            .map(|s| s.stack.clone())
            .unwrap_or_default();
        let holder_path = self.switch.as_ref().and_then(|sw| {
            // The recorded path is evidence. A matching alias is only a guess:
            // two roots named "xampp" is exactly how the wrong stack got named.
            if let Some(p) = sw.active_path.as_ref().filter(|p| !p.trim().is_empty()) {
                return Some(p.clone());
            }
            let holder = switch_holder(sw)?;
            let matches: Vec<&backend::ForeignStack> =
                sw.stack.iter().filter(|s| s.alias == holder).collect();
            if matches.len() == 1 {
                Some(matches[0].path.clone())
            } else {
                None
            }
        });
        let foreign = match self.switch.as_ref() {
            Some(sw) => {
                let (_, foreign) = switch_port_line(sw, None);
                // The recorded handover is evidence even when the payload could
                // not attribute the listener; either is enough to offer the way back.
                foreign || sw.active.as_deref().is_some_and(|a| !a.trim().is_empty())
            }
            None => false,
        };

        let mut queued: Option<Vec<String>> = None;
        let mut dismiss = false;
        let mut elevate = false;

        ui.add_space(16.0);
        ui.horizontal_wrapped(|ui| {
            section_label(ui, p, "STACKS");
            // Adding a root is a folder choice, not a path to type: the picker
            // validates and registers in one click, so there is no field to get
            // wrong and nothing to press Add on afterwards.
            if verb_button(ui, p, "Browse…", !busy).clicked() {
                if let Some(dir) = rfd::FileDialog::new()
                    .set_title("Choose the stack root (the folder holding apache and mysql)")
                    .pick_folder()
                {
                    let picked = dir.display().to_string();
                    queued = Some(vec!["--add".to_string(), "--path".to_string(), picked]);
                }
            }
            if foreign && verb_button(ui, p, "Return to phpup", !busy).clicked() {
                let mut args = vec!["--to".to_string(), "phpup".to_string()];
                if let Some(path) = &holder_path {
                    args.push("--path".to_string());
                    args.push(path.clone());
                }
                queued = Some(args);
            }
            if busy {
                ui.label(RichText::new("refreshing…").size(10.5).color(p.muted));
            }
        });

        // Above the list and the field on purpose: the console pane takes the
        // bottom of this section in a small window, and an error painted below
        // the add row was invisible exactly when it needed reading.
        if let Some(err) = self.switch_error.clone() {
            ui.add_space(4.0);
            ui.horizontal_wrapped(|ui| {
                ui.label(RichText::new(format!("! {err}")).size(11.5).color(p.warn));
                // Exit 4 is the one failure the user can fix from here: repeat the
                // same call with an elevated token.
                if self.switch_admin_args.is_some()
                    && verb_button(ui, p, "Run as administrator", !busy).clicked()
                {
                    elevate = true;
                }
                if plain_nav(ui, p, "Dismiss") {
                    dismiss = true;
                }
            });
        }

        if stacks.is_empty() {
            ui.add_space(2.0);
            ui.label(
                RichText::new("No other stack registered yet.")
                    .size(11.0)
                    .color(p.muted),
            );
        }

        for stack in &stacks {
            ui.add_space(2.0);
            ui.horizontal_wrapped(|ui| {
                ui.label(RichText::new(&stack.alias).size(12.5).strong().color(p.text));
                // The path is the widest thing on the row and the slide-out can
                // leave ~300pt, so it truncates and keeps the whole thing on hover.
                ui.add(
                    egui::Label::new(RichText::new(&stack.path).size(11.0).color(p.muted))
                        .truncate(),
                )
                .on_hover_text(&stack.path);
                if verb_button(ui, p, "Switch to", !busy).clicked() {
                    // By path: two roots can share the alias "xampp", and the
                    // script refuses an ambiguous alias rather than guessing.
                    queued = Some(vec![
                        "--to".to_string(),
                        stack.alias.clone(),
                        "--path".to_string(),
                        stack.path.clone(),
                    ]);
                }
                if plain_nav(ui, p, "Remove") {
                    queued = Some(vec![
                        "--remove".to_string(),
                        "--path".to_string(),
                        stack.path.clone(),
                    ]);
                }
            });
        }

        if dismiss {
            self.switch_error = None;
            self.switch_admin_args = None;
        }
        if elevate {
            self.run_switch_elevated();
        }
        if let Some(args) = queued {
            self.run_switch(args);
        }
    }

    fn status_area(
        &self,
        ui: &mut egui::Ui,
        p: &Palette,
        status: &Status,
        pending: &mut Option<&'static str>,
        _open_url: &mut Option<String>,
    ) {
        // State, mode and registration live in the header as plain text now;
        // duplicating them here as pills made them read like buttons.

        if let Some(toast) = &self.toast {
            ui.add_space(10.0);
            Frame::group(ui.style())
                .fill(p.surface)
                .stroke(Stroke::new(1.0, if toast.ok { p.ok } else { p.err }))
                .corner_radius(CornerRadius::same(10))
                .inner_margin(Margin::symmetric(12, 8))
                .show(ui, |ui| {
                    ui.label(
                        RichText::new(&toast.text)
                            .size(12.0)
                            .color(if toast.ok { p.ok } else { p.err }),
                    );
                });
        }

        if !status.warnings.is_empty() {
            ui.add_space(10.0);
            for w in &status.warnings {
                let code = w.code.clone().unwrap_or_default();
                let who = w.component.clone().unwrap_or_default();
                Frame::group(ui.style())
                    .fill(p.surface)
                    .stroke(Stroke::new(1.0, p.warn.gamma_multiply(0.6)))
                    .corner_radius(CornerRadius::same(10))
                    .inner_margin(Margin::symmetric(12, 8))
                    .show(ui, |ui| {
                        ui.label(
                            RichText::new(w.message.clone().unwrap_or_default())
                                .size(12.0)
                                .color(p.warn),
                        );
                        let tag = [who, code]
                            .into_iter()
                            .filter(|s| !s.is_empty())
                            .collect::<Vec<_>>()
                            .join(" · ");
                        if !tag.is_empty() {
                            ui.label(RichText::new(tag).size(10.0).color(p.muted));
                        }
                    });
            }
        }

        // A port held by something else is the one failure the panels cannot
        // fix themselves, so name the process holding it.
        let foreign: Vec<&backend::PortInfo> = status
            .ports
            .iter()
            .filter(|p| p.listening && !p.ours)
            .collect();
        if !foreign.is_empty() {
            ui.add_space(10.0);
            for port in foreign {
                ui.label(
                    RichText::new(format!(
                        "port {} held by {}",
                        port.port,
                        port.owner
                            .clone()
                            .unwrap_or_else(|| "another process".to_string())
                    ))
                    .size(11.5)
                    .color(p.err),
                );
            }
        }

        ui.add_space(16.0);

        // Actions on the body, not in a menu: they act on the cards below, and
        // burying them two clicks deep made the panel feel read-only.
        ui.horizontal(|ui| {
            let idle = self.action.is_none();
            let all_up = status.all_running();
            let start_on = idle && !all_up;
            let stop_on = idle && status.any_running();

            let start = egui::Button::new(
                RichText::new("Start")
                    .strong()
                    .color(if start_on { ON_ACCENT } else { p.muted }),
            )
            .fill(if start_on {
                p.accent
            } else {
                p.accent.gamma_multiply(0.28)
            })
            .corner_radius(CornerRadius::same(10))
            .min_size(Vec2::new(92.0, 34.0));
            if ui.add_enabled(start_on, start).clicked() {
                *pending = Some("start");
            }

            let restart = egui::Button::new(
                RichText::new("Restart").color(if idle { p.text } else { p.muted }),
            )
            .corner_radius(CornerRadius::same(10))
            .min_size(Vec2::new(92.0, 34.0));
            if ui.add_enabled(idle, restart).clicked() {
                *pending = Some("restart");
            }

            let stop = egui::Button::new(RichText::new("Stop").color(if stop_on {
                p.err
            } else {
                p.muted
            }))
            .corner_radius(CornerRadius::same(10))
            .min_size(Vec2::new(92.0, 34.0));
            if ui.add_enabled(stop_on, stop).clicked() {
                *pending = Some("stop");
            }
        });

        ui.add_space(18.0);

        // Component cards, two per row.
        let gap = 12.0;
        let col_width = ((ui.available_width() - gap) / 2.0).max(240.0);
        ui.horizontal_top(|ui| {
            ui.vertical(|ui| {
                ui.set_width(col_width);
                card(ui, p, "Apache", &status.components.apache, PortKind::Web);
                ui.add_space(gap);
                card(ui, p, "MariaDB", &status.components.mariadb, PortKind::Db);
            });
            ui.add_space(gap);
            ui.vertical(|ui| {
                ui.set_width(col_width);
                card(ui, p, "PHP", &status.components.php, PortKind::None);
                ui.add_space(gap);
                card(ui, p, "phpMyAdmin", &status.components.phpmyadmin, PortKind::None);
            });
        });

    }
}

impl Drop for App {
    fn drop(&mut self) {
        // Take the children with us. `status --watch` and any switch run are
        // phpup processes; a panel that disappears must not leave them (and
        // their conhosts) behind.
        if let Some(be) = &self.backend {
            be.shutdown();
        }
        // Reopen where this window was left.
        self.settings.window = Some(self.win);
        self.settings.save();
    }
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        self.drain();
        self.rescue_window(&ctx);
        self.track_window(&ctx);
        // The ports change outside the panel too: a switch run from a terminal,
        // a stack started by hand. Polling the snapshot is the only way the block
        // can be right about state it did not create.
        self.poll_switch(&ctx);

        // Windows does not decorate the title bar for elevated processes the way
        // it does for the UAC prompt, so say it plainly.
        if !self.title_applied {
            let title = if self.elevated { "phpup — as administrator" } else { "phpup" };
            ctx.send_viewport_cmd(egui::ViewportCommand::Title(title.to_string()));
            self.title_applied = true;
        }

        // Administrator mode: raise the panel once, at launch, so the user is
        // not prompted mid-session every time a service action runs.
        if !self.startup_elevation_done {
            self.startup_elevation_done = true;
            if self.settings.always_admin && !self.elevated {
                self.push_log("administrator mode is on: asking for elevation".to_string());
                let tx = self.tx.clone();
                std::thread::spawn(move || match backend::relaunch_panel(None) {
                    Ok(()) => {
                        let _ = tx.send(Event::Relaunched(Ok(())));
                    }
                    Err(e) => {
                        let _ = tx.send(Event::Log(format!(
                            "  elevation declined ({e}); continuing without it"
                        )));
                    }
                });
            }
        }

        if self.relaunch_ok {
            self.relaunch_ok = false;
            self.quitting = true;
            self.tray = None;
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }

        // egui owns "follow the system": ThemePreference::System is resolved by
        // winit's OS preference, so nothing platform-specific lives here.
        if self.applied_pref != Some(self.settings.theme) {
            ctx.set_theme(self.settings.theme.to_egui());
            self.applied_pref = Some(self.settings.theme);
        }
        let dark = ctx.theme() == egui::Theme::Dark;
        if self.applied_dark != Some(dark) {
            theme::apply(&ctx, dark);
            self.applied_dark = Some(dark);
        }
        let p = palette(dark);

        // Zoom: 0.0 means follow the OS. Fixed factors are for mixed-DPI desks
        // where moving between monitors leaves everything the wrong size.
        if self.settings.zoom > 0.0 {
            if self.applied_zoom != Some(self.settings.zoom) {
                ui.ctx().set_zoom_factor(self.settings.zoom);
                self.applied_zoom = Some(self.settings.zoom);
            }
        } else if self.applied_zoom.is_some() {
            ui.ctx().set_zoom_factor(1.0);
            self.applied_zoom = None;
        }

        // Tray menu -> panel actions.
        let mut tray_cmd: Option<TrayCmd> = None;
        if let Some(tray) = &self.tray {
            while let Ok(ev) = MenuEvent::receiver().try_recv() {
                if ev.id == *tray.show.id() {
                    tray_cmd = Some(TrayCmd::Show);
                } else if ev.id == *tray.start.id() {
                    tray_cmd = Some(TrayCmd::Start);
                } else if ev.id == *tray.stop.id() {
                    tray_cmd = Some(TrayCmd::Stop);
                } else if ev.id == *tray.restart.id() {
                    tray_cmd = Some(TrayCmd::Restart);
                } else if ev.id == *tray.quit.id() {
                    tray_cmd = Some(TrayCmd::Quit);
                }
            }
        }
        match tray_cmd {
            Some(TrayCmd::Show) => {
                ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
            }
            Some(TrayCmd::Quit) => {
                // Drop the icon first (that removes it from the tray), then
                // leave. Closing via the viewport was being swallowed by the
                // close-to-tray handler, so hide-to-tray turned into a trap.
                self.quitting = true;
                self.tray = None;
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                std::process::exit(0);
            }
            Some(TrayCmd::Start) => self.start_action("start"),
            Some(TrayCmd::Stop) => self.start_action("stop"),
            Some(TrayCmd::Restart) => self.start_action("restart"),
            None => {}
        }

        // Closing the window parks the panel in the tray; Quit is a tray menu
        // item. Without a tray there is nothing to park into, so close normally.
        if !self.quitting && self.tray.is_some() && ctx.input(|i| i.viewport().close_requested()) {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
            self.push_log("hidden to tray — quit from the tray menu".to_string());
            self.settings.window = Some(self.win);
            self.settings.save();
        }

        self.header(ui, &p);
        self.footer(ui, &p);
        // Bottom panels are taken from the window edge in call order, so the
        // console claims the bottom first and the stack strip lands directly
        // above it — which is where the switcher belongs.
        let avail = ui.available_height();
        // First frame has no measurements: fall back to the old default rather
        // than guessing a size from zero.
        if self.calibrate > 0 {
            self.calibrate -= 1;
        }
        let console_h = if self.calibrate > 0 || self.body_need <= 0.0 {
            88.0
        } else {
            // The console gets whatever is left once the cards have what they
            // asked for — never more, because a squeezed body clips the cards.
            // `content_size` stops at the viewport, so the last few points of the
            // second card row are invisible to the measurement; the floor covers
            // them and keeps the pane from clipping the card detail lines.
            const BODY_FLOOR: f32 = 340.0;
            let body = self.body_need.max(BODY_FLOOR);
            let slack = avail - self.strip_h - body;
            slack.clamp(88.0, (avail * 0.60).max(88.0))
        };
        self.console(ui, &p, console_h);
        self.stacks_strip(ui, &p);
        self.settings_panel(ui, &p);
        self.body(ui, &p);
        self.about_window(ui, &p);

        // Size once against the actual monitor: 980x700 points is bigger than a
        // 1080p screen at 200% scaling, which pushed the settings panel off the
        // edge entirely.
        if !self.sized_once {
            self.sized_once = true;
            // A remembered size is the user's decision; clamping it against this
            // monitor would silently undo it every launch.
            if self.settings.window.is_none() {
            if let Some(monitor) = ctx.input(|i| i.viewport().monitor_size) {
                let want = egui::vec2(
                    980.0_f32.min(monitor.x * 0.90),
                    860.0_f32.min(monitor.y * 0.85),
                );
                ctx.send_viewport_cmd(egui::ViewportCommand::InnerSize(want));
            }
            }
        }

        // Tray-first startup: when enabled, the panel never shows a window or a
        // taskbar button, exactly like the close button. Deferred a few frames
        // because a command issued before the window is mapped is dropped.
        self.frames_seen = self.frames_seen.saturating_add(1);
        if !self.tray_start_applied && self.frames_seen >= 3 {
            self.tray_start_applied = true;
            if self.settings.start_in_tray {
                ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
            }
        }

        // Escape or a click anywhere outside closes the settings slide-out.
        if self.about_open {
            if ctx.input(|i| i.key_pressed(egui::Key::Escape)) {
                self.about_open = false;
            }
        } else if self.settings_open {
            let escape = ctx.input(|i| i.key_pressed(egui::Key::Escape));
            let clicked_out = ctx.input(|i| i.pointer.any_pressed())
                && ctx.input(|i| i.pointer.interact_pos()).map_or(false, |pos| {
                    !self.settings_rect.map_or(false, |r| r.contains(pos))
                        && !self.settings_toggle_rect.map_or(false, |r| r.contains(pos))
                });
            if escape || clicked_out {
                self.settings_open = false;
            }
        }

        // The watch stream arrives on a thread, which cannot wake egui.
        ctx.request_repaint_after(Duration::from_millis(400));
    }
}

// ----------------------------------------------------------------- helpers

fn on_off(running: bool) -> &'static str {
    if running {
        "running"
    } else {
        "stopped"
    }
}

/// PowerShell colour codes would otherwise litter the console pane.
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            if chars.peek() == Some(&'[') {
                chars.next();
            }
            while let Some(&n) = chars.peek() {
                chars.next();
                if n.is_ascii_alphabetic() {
                    break;
                }
            }
        } else if c != '\r' {
            out.push(c);
        }
    }
    out
}

fn filled_nav(ui: &mut egui::Ui, p: &Palette, label: &str) -> egui::Response {
    ui.add(
        egui::Button::new(RichText::new(label).size(12.5).color(p.text))
            .fill(p.surface_2)
            .corner_radius(CornerRadius::same(9)),
    )
}

fn plain_nav(ui: &mut egui::Ui, p: &Palette, label: &str) -> bool {
    ui.add(
        egui::Button::new(RichText::new(label).size(12.0).color(p.muted))
            .fill(Color32::TRANSPARENT)
            .corner_radius(CornerRadius::same(8)),
    )
    .clicked()
}

/// A verb. Only actions get button chrome in the panel; stacks, paths and
/// aliases stay plain text so the row does not read as clickable.
fn verb_button(ui: &mut egui::Ui, p: &Palette, label: &str, enabled: bool) -> egui::Response {
    ui.add_enabled(
        enabled,
        egui::Button::new(
            RichText::new(label)
                .size(12.0)
                .color(if enabled { p.text } else { p.muted }),
        )
        .fill(p.surface_2)
        .corner_radius(CornerRadius::same(8)),
    )
}

/// "Ports 80/3306: 80 phpup — httpd (PID 45268) · …", plus whether either port
/// is held by something that is not phpup (which is when Return to phpup is the
/// only useful verb).
/// Which stack is holding the ports, as far as this payload knows: the recorded
/// handover first, then the single registered root.
fn switch_holder(sw: &backend::SwitchPayload) -> Option<String> {
    if let Some(a) = sw.active.clone().filter(|a| !a.trim().is_empty()) {
        return Some(a);
    }
    let mut aliases = sw.stack.iter().map(|s| s.alias.clone());
    let first = aliases.next()?;
    if aliases.next().is_none() {
        Some(first)
    } else {
        None
    }
}

fn switch_port_line(sw: &backend::SwitchPayload, hint: Option<&str>) -> (String, bool) {
    // Name the stack that holds the ports, not the word "foreign": phpup
    // recorded who it handed them to, and a listener whose image path cannot be
    // read is still identifiable by that record.
    let holder = switch_holder(sw)
        // A failed call answers with an empty stack list, so the last stack we
        // knew about is better than calling it "another stack".
        .or_else(|| hint.map(|h| h.to_string()));

    let mut parts: Vec<String> = Vec::new();
    let mut foreign = false;
    for port in ["80", "3306"] {
        match sw.port(port) {
            Some(info) => {
                if info.state == "foreign" {
                    foreign = true;
                }
                let state = match info.state.as_str() {
                    "foreign" => holder.clone().unwrap_or_else(|| "another stack".to_string()),
                    "" => "unknown".to_string(),
                    other => other.to_string(),
                };
                match info.owner.as_deref().filter(|o| !o.trim().is_empty()) {
                    Some(owner) => parts.push(format!("{port} {state} ({owner})")),
                    None => parts.push(format!("{port} {state}")),
                }
            }
            None => parts.push(format!("{port} unknown")),
        }
    }
    (parts.join(" · "), foreign)
}

/// One console line per switch. The ports line already carries the detail, so
/// this only has to say what was asked and whether anything moved.
fn switch_summary(payload: &backend::SwitchPayload) -> String {
    if !payload.ok {
        let why = payload
            .first_error()
            .unwrap_or_else(|| "failed".to_string());
        return format!("switch: {why}");
    }
    let mut line = String::from("switch");
    if let Some(to) = payload.to.as_deref().filter(|t| !t.trim().is_empty()) {
        line.push_str(&format!(" -> {to}"));
    }
    if payload.dry_run {
        line.push_str(" · dry run");
    }
    if payload.changed {
        line.push_str(" · changed");
    }
    line.push_str(&format!(" · {}", switch_port_line(payload, None).0));
    line
}

fn section_label(ui: &mut egui::Ui, p: &Palette, text: &str) {
    ui.label(RichText::new(text).size(10.5).color(p.muted).strong());
    ui.add_space(2.0);
}

/// Small segmented control, used for a service's start type.
fn chip(ui: &mut egui::Ui, p: &Palette, label: &str, selected: bool) -> bool {
    let text = RichText::new(label)
        .size(10.5)
        .color(if selected { p.accent_text } else { p.text });
    let button = egui::Button::new(text)
        .min_size(Vec2::new(0.0, 20.0))
        .corner_radius(CornerRadius::same(7));
    // Unselected chips keep the theme fill so the hover state can show through.
    let button = if selected { button.fill(p.accent) } else { button };
    ui.add(button).clicked()
}



enum PortKind {
    Web,
    Db,
    None,
}

fn card(ui: &mut egui::Ui, p: &Palette, title: &str, comp: &Component, kind: PortKind) {
    Frame::group(ui.style())
        .fill(p.surface)
        .stroke(Stroke::new(1.0, p.border))
        .corner_radius(CornerRadius::same(14))
        .inner_margin(Margin::same(14))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.horizontal(|ui| {
                ui.label(RichText::new(title).size(13.5).strong().color(p.text));
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    // Every card answers the same question — is this thing usable
                    // right now — so every card gets the same two colours. PHP and
                    // phpMyAdmin are not processes, so "ready" plays the part of
                    // "running", and a missing component is as red as a stopped one.
                    let (text, colour) = match comp.running {
                        Some(true) => ("running", p.ok),
                        Some(false) => ("stopped", p.err),
                        None if comp.installed => ("ready", p.ok),
                        None => ("not installed", p.err),
                    };
                    let (rect, _) = ui.allocate_exact_size(Vec2::splat(9.0), egui::Sense::hover());
                    ui.painter().circle_filled(rect.center(), 3.5, colour);
                    ui.label(RichText::new(text).size(11.0).color(colour));
                });
            });

            ui.add_space(2.0);
            ui.label(
                RichText::new(comp.version.clone().unwrap_or_else(|| "—".to_string()))
                    .size(12.0)
                    .color(p.muted),
            );

            let mut detail: Vec<String> = Vec::new();
            if !comp.pids.is_empty() {
                let pids: Vec<String> = comp.pids.iter().take(3).map(|v| v.to_string()).collect();
                detail.push(format!("PID {}", pids.join(", ")));
            }
            match kind {
                PortKind::Web | PortKind::Db => {
                    if !comp.ports.is_empty() {
                        let ports: Vec<String> =
                            comp.ports.iter().map(|v| format!(":{v}")).collect();
                        detail.push(ports.join(" "));
                    }
                }
                PortKind::None => {}
            }
            if let Some(sapi) = &comp.sapi {
                detail.push(format!("sapi {sapi}"));
            }
            if comp.cli_on_path {
                detail.push("cli on PATH".to_string());
            }
            if let Some(url) = &comp.url {
                detail.push(url.clone());
            }
            if let Some(service) = &comp.service {
                detail.push(service.clone());
            }
            if !detail.is_empty() {
                ui.add_space(1.0);
                ui.label(RichText::new(detail.join("  ·  ")).size(11.0).color(p.muted));
            }
        });
}
