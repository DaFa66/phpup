//! Palette and visuals. Two hand-tuned themes sharing the logo's colours:
//! hexagon yellow as the accent, indigo as the secondary, on slate surfaces.

use eframe::egui::{self, Color32, Stroke, ThemePreference, Visuals};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ThemePref {
    System,
    Light,
    Dark,
}

impl ThemePref {
    pub fn as_str(self) -> &'static str {
        match self {
            ThemePref::System => "system",
            ThemePref::Light => "light",
            ThemePref::Dark => "dark",
        }
    }

    pub fn from_str(s: &str) -> Self {
        match s {
            "light" => ThemePref::Light,
            "dark" => ThemePref::Dark,
            _ => ThemePref::System,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            ThemePref::System => "System",
            ThemePref::Light => "Light",
            ThemePref::Dark => "Dark",
        }
    }

    /// egui resolves "system" itself (winit reports the OS preference), so the
    /// panel does not read registry keys or `defaults` to follow the desktop.
    pub fn to_egui(self) -> ThemePreference {
        match self {
            ThemePref::System => ThemePreference::System,
            ThemePref::Light => ThemePreference::Light,
            ThemePref::Dark => ThemePreference::Dark,
        }
    }
}

#[derive(Clone, Copy)]
pub struct Palette {
    pub bg: Color32,
    pub surface: Color32,
    pub surface_2: Color32,
    pub border: Color32,
    pub text: Color32,
    pub muted: Color32,
    pub accent: Color32,
    pub indigo: Color32,
    pub ok: Color32,
    pub warn: Color32,
    pub err: Color32,
}

pub fn palette(dark: bool) -> Palette {
    if dark {
        Palette {
            bg: Color32::from_rgb(0x12, 0x14, 0x19),
            surface: Color32::from_rgb(0x1a, 0x1d, 0x25),
            surface_2: Color32::from_rgb(0x22, 0x26, 0x31),
            border: Color32::from_rgb(0x2c, 0x31, 0x3d),
            text: Color32::from_rgb(0xe8, 0xea, 0xef),
            muted: Color32::from_rgb(0x95, 0x9c, 0xaa),
            accent: Color32::from_rgb(0xff, 0xd2, 0x1a),
            indigo: Color32::from_rgb(0x6a, 0x6f, 0xd8),
            ok: Color32::from_rgb(0x3d, 0xd0, 0x84),
            warn: Color32::from_rgb(0xf5, 0xa5, 0x24),
            err: Color32::from_rgb(0xf0, 0x5a, 0x5f),
        }
    } else {
        Palette {
            bg: Color32::from_rgb(0xf5, 0xf6, 0xf8),
            surface: Color32::WHITE,
            surface_2: Color32::from_rgb(0xee, 0xf0, 0xf4),
            border: Color32::from_rgb(0xdd, 0xe1, 0xe8),
            text: Color32::from_rgb(0x1b, 0x1e, 0x25),
            muted: Color32::from_rgb(0x5d, 0x64, 0x70),
            accent: Color32::from_rgb(0xe8, 0xb8, 0x00),
            indigo: Color32::from_rgb(0x4a, 0x4f, 0xae),
            ok: Color32::from_rgb(0x1f, 0x9d, 0x63),
            warn: Color32::from_rgb(0xc2, 0x7c, 0x00),
            err: Color32::from_rgb(0xd4, 0x3a, 0x3f),
        }
    }
}

pub fn apply(ctx: &egui::Context, dark: bool) {
    let p = palette(dark);
    let mut v = if dark { Visuals::dark() } else { Visuals::light() };

    v.panel_fill = p.bg;
    v.window_fill = p.surface;
    v.extreme_bg_color = p.surface_2;
    v.faint_bg_color = p.surface_2;
    v.override_text_color = Some(p.text);
    v.hyperlink_color = p.indigo;

    v.widgets.noninteractive.bg_fill = p.surface;
    v.widgets.noninteractive.bg_stroke = Stroke::new(1.0, p.border);
    v.widgets.noninteractive.fg_stroke = Stroke::new(1.0, p.muted);

    v.widgets.inactive.bg_fill = p.surface_2;
    v.widgets.inactive.weak_bg_fill = p.surface_2;
    v.widgets.inactive.bg_stroke = Stroke::new(1.0, p.border);
    v.widgets.inactive.fg_stroke = Stroke::new(1.0, p.text);

    v.widgets.hovered.bg_fill = if dark {
        Color32::from_rgb(0x2a, 0x2f, 0x3b)
    } else {
        Color32::from_rgb(0xe4, 0xe8, 0xef)
    };
    v.widgets.hovered.weak_bg_fill = v.widgets.hovered.bg_fill;
    v.widgets.hovered.bg_stroke = Stroke::new(1.0, p.border);
    v.widgets.hovered.fg_stroke = Stroke::new(1.0, p.text);

    v.widgets.active.bg_fill = p.indigo;
    v.widgets.active.weak_bg_fill = p.indigo;
    v.widgets.active.bg_stroke = Stroke::new(1.0, p.indigo);
    // Note: egui resolves RichText::strong() through this colour, so it must be
    // readable body text. Buttons that need white-on-accent ask for it.
    v.widgets.active.fg_stroke = Stroke::new(1.0, p.text);

    v.selection.bg_fill = p.indigo.gamma_multiply(0.45);
    v.selection.stroke = Stroke::new(1.0, p.text);

    ctx.set_visuals(v);
}
