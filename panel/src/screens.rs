//! Where the window is allowed to reappear.
//!
//! A remembered position is only worth honouring while it still exists. The
//! laptop gets undocked, the 2K monitor gets rearranged, a drag across two
//! screens ends past the edge of the leftmost one — and the saved x/y then
//! draws the panel where nothing can be clicked. The user reports that as "it
//! runs but I can't see it", which is indistinguishable from a crash.
//!
//! So restoring a position is a question about the current monitors, not a
//! fact about the last session: ask Windows whether any of the window actually
//! lands on a screen, and throw the position away when it does not.

/// A rectangle in points: (x, y, width, height).
pub type Rect = (f32, f32, f32, f32);

/// How much of the window must be on a screen before the position is worth
/// restoring. A 120pt corner is enough to see the window and grab its edge;
/// a strip of pixels is not, and neither is a window parked past the edge.
const GRABBABLE: f32 = 120.0;

/// The overlap of two rectangles, or `None` when they do not touch.
pub fn intersection(a: Rect, b: Rect) -> Option<Rect> {
    let x0 = a.0.max(b.0);
    let y0 = a.1.max(b.1);
    let x1 = (a.0 + a.2).min(b.0 + b.2);
    let y1 = (a.1 + a.3).min(b.1 + b.3);
    if x1 <= x0 || y1 <= y0 {
        None
    } else {
        Some((x0, y0, x1 - x0, y1 - y0))
    }
}

/// Is enough of the window on that screen to find and grab it?
pub fn enough_to_grab(visible: Option<Rect>) -> bool {
    matches!(visible, Some(r) if r.2 >= GRABBABLE && r.3 >= GRABBABLE)
}

/// The part of the window that lands on the monitor Windows considers closest.
#[cfg(windows)]
pub fn on_screen(x: f32, y: f32, w: f32, h: f32) -> Option<Rect> {
    use windows_sys::Win32::Foundation::RECT;
    use windows_sys::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MonitorFromRect, MONITORINFO, MONITOR_DEFAULTTONULL,
    };

    let rc = RECT {
        left: x as i32,
        top: y as i32,
        right: (x + w) as i32,
        bottom: (y + h) as i32,
    };
    unsafe {
        // DEFAULTTONULL answers "no monitor" rather than "the nearest one",
        // which is exactly the difference between reachable and lost.
        let mon = MonitorFromRect(&rc, MONITOR_DEFAULTTONULL);
        if mon == 0 {
            return None;
        }
        let mut info: MONITORINFO = std::mem::zeroed();
        info.cbSize = std::mem::size_of::<MONITORINFO>() as u32;
        if GetMonitorInfoW(mon, &mut info) == 0 {
            return None;
        }
        let m = info.rcMonitor;
        let monitor = (
            m.left as f32,
            m.top as f32,
            (m.right - m.left) as f32,
            (m.bottom - m.top) as f32,
        );
        intersection((x, y, w, h), monitor)
    }
}

/// No monitor query off Windows: the panel ships for Windows, and claiming a
/// position is safe is better than silently discarding a good one.
#[cfg(not(windows))]
pub fn on_screen(x: f32, y: f32, w: f32, h: f32) -> Option<Rect> {
    Some((x, y, w, h))
}

/// True when a window of this size at this position can still be found.
pub fn position_is_reachable(x: f32, y: f32, w: f32, h: f32) -> bool {
    enough_to_grab(on_screen(x, y, w, h))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The layout that produced the report: 1920x1080 primary at the origin and
    /// a 2560x1440 screen to its left. Disjoint and at odd offsets, which is
    /// what makes a stale position so easy to produce.
    const LEFT: Rect = (-2560.0, 736.0, 2560.0, 1440.0);
    const PRIMARY: Rect = (0.0, 0.0, 1920.0, 1080.0);

    #[test]
    fn a_position_beyond_the_leftmost_screen_is_refused() {
        // x = -4719 with a window 993 wide ends 1759pt left of that screen.
        let vis = intersection((-4719.0, 434.0, 993.0, 896.0), LEFT);
        assert_eq!(vis, None);
        assert!(!enough_to_grab(vis));
    }

    #[test]
    fn a_position_on_the_primary_screen_is_kept() {
        let vis = intersection((200.0, 120.0, 980.0, 860.0), PRIMARY);
        assert!(enough_to_grab(vis));
    }

    #[test]
    fn a_sliver_is_not_something_you_can_grab() {
        // 30pt of the window's right edge poking onto the primary screen.
        let vis = intersection((-950.0, 120.0, 980.0, 860.0), PRIMARY);
        assert!(vis.is_some());
        assert!(!enough_to_grab(vis));
    }

    #[test]
    fn a_window_straddling_two_screens_is_kept() {
        let vis = intersection((-490.0, 120.0, 980.0, 860.0), PRIMARY);
        assert!(enough_to_grab(vis));
    }

    #[test]
    fn a_window_hanging_off_the_bottom_is_kept_while_a_corner_shows() {
        let vis = intersection((300.0, 700.0, 980.0, 860.0), PRIMARY);
        assert!(enough_to_grab(vis));
    }
}
