#![cfg_attr(windows, windows_subsystem = "windows")]

mod assets;
mod backend;
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

    let mut viewport = egui::ViewportBuilder::default()
        .with_title("phpup")
        .with_app_id("phpup-panel")
        .with_inner_size([980.0, 700.0])
        .with_min_inner_size([760.0, 520.0]);
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
        Box::new(move |cc| Ok(Box::new(App::new(cc, settings)))),
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
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            theme: ThemePref::System,
            source: Source::Github,
            script: None,
            interval: 2,
            zoom: 0.0,
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
                interval: raw.interval.unwrap_or(2).clamp(1, 10),
                zoom: raw.zoom.unwrap_or(0.0),
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
    last_error: Option<String>,
    last_seen: Option<Instant>,
    action: Option<&'static str>,
    /// Verb that came back exit 4, waiting for the user to consent to UAC.
    admin_verb: Option<String>,
    toast: Option<Toast>,
    settings_open: bool,
    brand: Option<assets::Brand>,
    about_open: bool,
    quitting: bool,
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
    fn new(cc: &eframe::CreationContext<'_>, settings: Settings) -> Self {
        let (tx, rx) = backend::channel_pair();
        let brand = assets::load(&cc.egui_ctx);

        cc.egui_ctx.all_styles_mut(|style| {
            style.spacing.item_spacing = Vec2::new(10.0, 10.0);
            style.spacing.button_padding = Vec2::new(12.0, 7.0);
        });

        let mut app = Self {
            settings,
            backend: None,
            tx,
            rx,
            status: None,
            last_error: None,
            last_seen: None,
            action: None,
            admin_verb: None,
            toast: None,
            // First run opens Settings: the source choice is the first thing a
            // new user needs to see.
            settings_open: !Settings::path().map(|p| p.is_file()).unwrap_or(false),
            about_open: false,
            quitting: false,
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
        if app.tray.is_none() {
            app.push_log("tray icon unavailable on this desktop".to_string());
        }
        app
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
        match backend::resolve_script(self.settings.source, self.settings.script.as_ref()) {
            Ok(path) => {
                self.script_input = path.display().to_string();
                match backend::probe_cli(&path) {
                    Ok(version) => {
                        let be = Backend::new(path, self.settings.interval);
                        be.spawn_watch(self.tx.clone());
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
                Event::Log(line) => self.push_log(line),
                Event::Failed(msg) => {
                    self.action = None;
                    self.push_log(format!("error: {msg}"));
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
                        if filled_nav(ui, p, "Settings") {
                            toggle_settings = true;
                        }
                        if filled_nav(ui, p, "Output") {
                            toggle_console = true;
                        }
                        if plain_nav(ui, p, "About") {
                            toggle_about = true;
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
    fn console(&mut self, ui: &mut egui::Ui, p: &Palette) {
        let mut open = self.console_open;
        let mut clear = false;
        let mut copy = false;
        let mut toggle_pin = false;
        let pinned = self.log_pinned;
        let lines: Vec<String> = std::mem::take(&mut self.log).into_iter().collect();
        let count = lines.len();

        egui::Panel::bottom("console")
            .resizable(true)
            .default_size(160.0)
            .min_size(88.0)
            .max_size(520.0)
            .frame(
                Frame::group(ui.style())
                    .fill(p.surface)
                    .inner_margin(Margin::same(12)),
            )
            .show_collapsible(ui, &mut open, |ui| {
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
        let mut do_attach = false;
        let mut refresh = false;
        let mut open = self.settings_open;
        let mut want_close = false;

        egui::Panel::right("settings")
            .resizable(false)
            .exact_size(340.0)
            .frame(
                Frame::group(ui.style())
                    .fill(p.surface)
                    .inner_margin(Margin::same(18))
                    .stroke(Stroke::new(1.0, p.border)),
            )
            .show_collapsible(ui, &mut open, |ui| {
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
                                                RichText::new(name)
                                                    .size(11.0)
                                                    .monospace()
                                                    .color(p.text),
                                            );
                                            ui.with_layout(
                                                Layout::right_to_left(Align::Center),
                                                |ui| {
                                                    ui.label(
                                                        RichText::new(state)
                                                            .size(10.5)
                                                            .color(colour),
                                                    );
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
                        ui.horizontal(|ui| {
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
                        }
                    });
            });

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
        if do_attach {
            self.attach();
        }
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
                egui::ScrollArea::vertical()
                    .auto_shrink([false, false])
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
                                                    RichText::new("Run elevated")
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
                    });
            });

        if let Some(verb) = pending {
            self.start_action(verb);
        }
        if open_settings {
            self.settings_open = true;
        }
        // Elevate the verb, not the panel: no second instance, no stray console.
        if let Some(verb) = elevated {
            if let Some(be) = &self.backend {
                let script = be.script.clone();
                let tx = self.tx.clone();
                self.push_log(format!("> {verb} (elevated)"));
                std::thread::spawn(move || match backend::run_elevated(&script, &verb) {
                    Ok(()) => {
                        let _ = tx.send(Event::Log(
                            "  UAC accepted; the live view follows in a moment".to_string(),
                        ));
                    }
                    Err(e) => {
                        let _ = tx.send(Event::Log(format!("  elevation failed: {e}")));
                    }
                });
                self.admin_verb = None;
            }
        }
        if let Some(url) = open_url {
            backend::open_in_default_app(&url);
        }
    }

    fn status_area(
        &self,
        ui: &mut egui::Ui,
        p: &Palette,
        status: &Status,
        pending: &mut Option<&'static str>,
        open_url: &mut Option<String>,
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

        // Actions
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
            .fill(p.surface_2)
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
            .fill(p.surface_2)
            .corner_radius(CornerRadius::same(10))
            .min_size(Vec2::new(92.0, 34.0));
            if ui.add_enabled(stop_on, stop).clicked() {
                *pending = Some("stop");
            }

            if let Some(verb) = self.action {
                ui.add_space(6.0);
                ui.spinner();
                ui.label(RichText::new(format!("{verb}…")).size(12.0).color(p.muted));
            }

            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if let Some(www) = &status.paths.www {
                    if ui.link(RichText::new("www folder").size(12.0)).clicked() {
                        *open_url = Some(www.clone());
                    }
                }
                if let Some(logs) = &status.paths.logs {
                    if ui.link(RichText::new("logs").size(12.0)).clicked() {
                        *open_url = Some(logs.clone());
                    }
                }
                if let Some(pma) = &status.urls.phpmyadmin {
                    if ui.link(RichText::new("phpMyAdmin").size(12.0)).clicked() {
                        *open_url = Some(pma.clone());
                    }
                }
                if let Some(info) = &status.urls.phpinfo {
                    if ui.link(RichText::new("phpinfo").size(12.0)).clicked() {
                        *open_url = Some(info.clone());
                    }
                }
                if let Some(root) = &status.urls.root {
                    if ui.link(RichText::new("localhost").size(12.0)).clicked() {
                        *open_url = Some(root.clone());
                    }
                }
            });
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

        ui.add_space(18.0);

    }
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        self.drain();

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
        }

        self.header(ui, &p);
        self.footer(ui, &p);
        self.console(ui, &p);
        self.settings_panel(ui, &p);
        self.body(ui, &p);
        self.about_window(ui, &p);

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

fn filled_nav(ui: &mut egui::Ui, p: &Palette, label: &str) -> bool {
    ui.add(
        egui::Button::new(RichText::new(label).size(12.5).color(p.text))
            .fill(p.surface_2)
            .corner_radius(CornerRadius::same(9)),
    )
    .clicked()
}

fn plain_nav(ui: &mut egui::Ui, p: &Palette, label: &str) -> bool {
    ui.add(
        egui::Button::new(RichText::new(label).size(12.0).color(p.muted))
            .fill(Color32::TRANSPARENT)
            .corner_radius(CornerRadius::same(8)),
    )
    .clicked()
}

fn section_label(ui: &mut egui::Ui, p: &Palette, text: &str) {
    ui.label(RichText::new(text).size(10.5).color(p.muted).strong());
    ui.add_space(2.0);
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
                    let (text, colour) = match comp.running {
                        Some(true) => ("running", p.ok),
                        Some(false) => ("stopped", p.err),
                        None if comp.installed => ("ready", p.muted),
                        None => ("not installed", p.muted),
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
