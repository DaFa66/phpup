//! Brand assets.
//!
//! The app icon is embedded from `panel/assets/` (tracked), so the tray and
//! title bar work on a fresh clone. The big logo lives in the git-ignored
//! `images/` folder and is optional: no file simply means no hero image.

use eframe::egui::{self, ColorImage, TextureHandle, Vec2};
use image::ImageReader;
use std::path::{Path, PathBuf};

const ICON_256: &[u8] = include_bytes!("../assets/favicon-256.png");
const ICON_32: &[u8] = include_bytes!("../assets/favicon-32.png");

pub struct Brand {
    pub texture: TextureHandle,
    pub size: Vec2,
}

fn decode(bytes: &[u8]) -> Option<image::RgbaImage> {
    image::load_from_memory(bytes).ok().map(|img| img.to_rgba8())
}

/// Title-bar icon.
pub fn window_icon() -> Option<egui::IconData> {
    let img = decode(ICON_256)?;
    Some(egui::IconData {
        width: img.width(),
        height: img.height(),
        rgba: img.into_raw(),
    })
}

/// Tray icon: 32px is crisp at 100-200% Windows scaling.
pub fn tray_icon() -> Option<(Vec<u8>, u32, u32)> {
    let img = decode(ICON_32)?;
    let (w, h) = img.dimensions();
    Some((img.into_raw(), w, h))
}

fn candidates() -> Vec<PathBuf> {
    let mut out = Vec::new();

    if let Ok(exe) = std::env::current_exe() {
        let mut dir = exe.parent().map(Path::to_path_buf);
        for _ in 0..6 {
            let Some(d) = dir else { break };
            out.push(d.join("images").join("phpup-logo1.jpg"));
            out.push(d.join("..").join("images").join("phpup-logo1.jpg"));
            dir = d.parent().map(Path::to_path_buf);
        }
    }

    if let Some(home) = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")) {
        let home = PathBuf::from(home);
        out.push(home.join("dev").join("phpup").join("images").join("phpup-logo1.jpg"));
    }
    out.push(PathBuf::from("D:/dev/phpup/images/phpup-logo1.jpg"));
    if cfg!(windows) {
        out.push(PathBuf::from("C:/phpup/images/phpup-logo1.jpg"));
    }
    out
}

pub fn find_logo() -> Option<PathBuf> {
    candidates().into_iter().find(|p| p.is_file())
}

pub fn load(ctx: &egui::Context) -> Option<Brand> {
    let path = find_logo()?;
    let img = ImageReader::open(&path).ok()?.decode().ok()?.to_rgba8();
    let (w, h) = img.dimensions();
    let pixels = img.as_raw().clone();

    let color = ColorImage::from_rgba_unmultiplied([w as usize, h as usize], &pixels);
    let texture = ctx.load_texture("phpup-logo", color, egui::TextureOptions::LINEAR);

    Some(Brand {
        texture,
        size: Vec2::new(w as f32, h as f32),
    })
}
