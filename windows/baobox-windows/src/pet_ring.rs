#![cfg(windows)]

use std::{cell::Cell, time::Instant};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, CreateFontW, CreatePen, CreateSolidBrush, DeleteObject, DrawTextW, Ellipse,
    EndPaint, FillRect, GetMonitorInfoW, InvalidateRect, MonitorFromWindow, RoundRect,
    SelectObject, SetBkMode, SetTextColor, DT_CENTER, DT_SINGLELINE, DT_VCENTER, MONITORINFO,
    MONITOR_DEFAULTTONEAREST, PAINTSTRUCT, PS_SOLID, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::{DRAWITEMSTRUCT, ODS_FOCUS, ODS_SELECTED};
use windows::Win32::UI::WindowsAndMessaging::*;

pub const WM_RING_ACTION: u32 = WM_APP + 5;
pub const MORE: &str = "desktop-pet.more";
pub const ADVANCED: &str = "desktop-pet.advanced";
pub const ITEMS: [(&str, &str); 8] = [
    (crate::screenshot_module::QUICK_CAPTURE, "截图"),
    (crate::caffeinate_module::TOGGLE, "防休眠"),
    (crate::pet::NEXT_CHARACTER, "换形象"),
    (crate::clipboard_module::PANEL, "剪贴板"),
    ("desktop-pet.pet", "摸摸"),
    (crate::screenshot_module::OCR, "取字"),
    (crate::pet_notify::QUIET, "安静"),
    (MORE, "更多"),
];const CLASS: PCWSTR = w!("BaoboxPetRing");
const KEY: COLORREF = COLORREF(0xff00ff);
const ICONS: [u16; 8] = [
    0xe722, 0xec32, 0xe8ab, 0xe77f, 0xeb51, 0xe8a5, 0xe708, 0xe712,
];

pub struct Ring {
    window: HWND,
    commands: Vec<&'static str>,
    state: Box<RingState>,
}

struct RingState {
    owner: HWND,
    start: Instant,
    hovered: Cell<HWND>,
    icons: Vec<u16>,
    points: Vec<(i32, i32)>,
    center: (i32, i32),
    inner: usize,
    more: Option<usize>,
    outer_started: Cell<Option<Instant>>,
    faded_in: Cell<bool>,
}

fn ring_positions(
    body: RECT,
    screen: RECT,
    inner: usize,
    outer: usize,
) -> ((i32, i32), Vec<(i32, i32)>) {
    let body_center = (
        (body.left + body.right) as f32 / 2.0,
        (body.top + body.bottom) as f32 / 2.0,
    );
    let half = (
        (body.right - body.left) as f32 / 2.0,
        (body.bottom - body.top) as f32 / 2.0,
    );
    let radii = ((half.0 + 46.0).max(80.0), (half.1 + 40.0).max(80.0));
    let limits = (
        screen.left as f32 + 44.0,
        screen.top as f32 + 32.0,
        screen.right as f32 - 44.0,
        screen.bottom as f32 - 44.0,
    );
    let fit = |position: f32, min: f32, max: f32, radius: f32| {
        if min + radius <= max - radius {
            position.clamp(min + radius, max - radius)
        } else {
            (min + max) / 2.0
        }
    };
    let center = (
        fit(body_center.0, limits.0, limits.2, radii.0),
        fit(body_center.1, limits.1, limits.3, radii.1),
    );
    let mut placed = Vec::new();
    for (count, gap) in [(inner, 0.0), (outer, 74.0)] {
        if count == 0 {
            continue;
        }
        let samples: Vec<_> = (0..360)
            .map(|i| {
                let angle = (i as f32).to_radians();
                (
                    center.0 + angle.sin() * (radii.0 + gap),
                    center.1 - angle.cos() * (radii.1 + gap),
                )
            })
            .collect();
        let allowed: Vec<_> = samples
            .iter()
            .map(|&(x, y)| {
                let dx = (x - body_center.0) / (half.0 + 18.0);
                let dy = (y - body_center.1) / (half.1 + 18.0);
                x >= limits.0
                    && x <= limits.2
                    && y >= limits.1
                    && y <= limits.3
                    && dx * dx + dy * dy >= 1.0
            })
            .collect();
        let full = allowed.iter().all(|&ok| ok);
        let (start, length) = if full {
            (0, 361)
        } else {
            (0..360)
                .filter(|&i| allowed[i] && !allowed[(i + 359) % 360])
                .map(|start| {
                    (
                        start,
                        (0..360).take_while(|i| allowed[(start + i) % 360]).count(),
                    )
                })
                .max_by_key(|&(_, length)| length)
                .unwrap_or((0, 361))
        };
        let points: Vec<_> = (0..length).map(|i| samples[(start + i) % 360]).collect();
        let mut arc = vec![0.0];
        for pair in points.windows(2) {
            arc.push(arc.last().unwrap() + (pair[0].0 - pair[1].0).hypot(pair[0].1 - pair[1].1));
        }
        let span = *arc.last().unwrap();
        for index in 0..count {
            let fraction = if count == 1 {
                0.5
            } else {
                index as f32 / (if full { count } else { count - 1 }) as f32
            };
            let distance = span * fraction;
            let end = arc.partition_point(|&v| v < distance).min(points.len() - 1);
            let begin = end.saturating_sub(1);
            let f = (distance - arc[begin]) / (arc[end] - arc[begin]).max(0.001);
            let (a, b) = (points[begin], points[end]);
            let clamp =
                |value: f32, low: f32, high: f32| value.clamp(low, high.max(low)).round() as i32;
            placed.push((
                clamp(a.0 + (b.0 - a.0) * f, limits.0, limits.2),
                clamp(a.1 + (b.1 - a.1) * f, limits.1, limits.3),
            ));
        }
    }
    ((center.0.round() as i32, center.1.round() as i32), placed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn both_rings_fit_at_center_and_four_corners_on_a_secondary_monitor() {
        let screen = RECT {
            left: -1920,
            top: -90,
            right: 0,
            bottom: 990,
        };
        for (left, top) in [
            (-1050, 230),
            (-1920, -90),
            (-180, -90),
            (-1920, 510),
            (-180, 510),
        ] {
            let body = RECT {
                left,
                top,
                right: left + 180,
                bottom: top + 480,
            };
            let (_, points) = ring_positions(body, screen, 8, 8);
            assert_eq!(points.len(), 16);
            for (i, &(x, y)) in points.iter().enumerate() {
                assert!(x - 43 >= screen.left && x + 43 <= screen.right);
                assert!(y - 22 >= screen.top && y + 44 <= screen.bottom);
                for &(other_x, other_y) in &points[..i] {
                    assert!(
                        (x - other_x).abs() >= 30 || (y - other_y).abs() >= 30,
                        "icons overlap at {left},{top}: {x},{y} and {other_x},{other_y}"
                    );
                }
            }
        }
    }

    #[test]
    fn more_and_escape_toggle_outer_without_dismissing_inner() {
        unsafe {
            let instance: HINSTANCE = GetModuleHandleW(None).unwrap().into();
            let pet = CreateWindowExW(
                WS_EX_TOOLWINDOW,
                w!("STATIC"),
                w!("test pet"),
                WS_POPUP,
                100,
                120,
                160,
                230,
                None,
                None,
                instance,
                None,
            )
            .unwrap();
            let inner = [(MORE, "更多")];
            let outer = [(ADVANCED, "宠物动作")];
            let ring = Ring::open(pet, pet, &inner, &outer).unwrap();
            let outer_button = GetDlgItem(ring.window, 2).unwrap();
            assert!(!IsWindowVisible(outer_button).as_bool());
            SendMessageW(ring.window, WM_COMMAND, WPARAM(1), LPARAM(0));
            ring.state
                .outer_started
                .set(Some(Instant::now() - std::time::Duration::from_secs(1)));
            animate_ring(ring.window, &ring.state);
            assert!(IsWindowVisible(outer_button).as_bool());
            SendMessageW(ring.window, WM_KEYDOWN, WPARAM(0x1b), LPARAM(0));
            assert!(ring.visible());
            assert!(!IsWindowVisible(outer_button).as_bool());
            drop(ring);
            DestroyWindow(pet).unwrap();
        }
    }
}

impl Ring {
    pub fn open(
        owner: HWND,
        pet: HWND,
        inner: &[(&'static str, &'static str)],
        outer: &[(&'static str, &'static str)],
    ) -> Result<Self, windows::core::Error> {
        unsafe {
            let instance: HINSTANCE = GetModuleHandleW(None)?.into();
            RegisterClassW(&WNDCLASSW {
                lpfnWndProc: Some(wndproc),
                hInstance: instance,
                lpszClassName: CLASS,
                ..Default::default()
            });
            let mut pet_bounds = RECT::default();
            GetWindowRect(pet, &mut pet_bounds)?;
            let mut info = MONITORINFO {
                cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                ..Default::default()
            };
            let have_monitor =
                GetMonitorInfoW(MonitorFromWindow(pet, MONITOR_DEFAULTTONEAREST), &mut info)
                    .as_bool();
            let body = crate::pet::body_bounds(pet, pet_bounds);
            let screen = if have_monitor {
                info.rcMonitor
            } else {
                RECT {
                    left: 0,
                    top: 0,
                    right: GetSystemMetrics(SM_CXSCREEN),
                    bottom: GetSystemMetrics(SM_CYSCREEN),
                }
            };
            let (center, points) = ring_positions(body, screen, inner.len(), outer.len());
            let x = points
                .iter()
                .map(|p| p.0)
                .min()
                .unwrap_or(center.0)
                .min(center.0)
                - 43;
            let y = points
                .iter()
                .map(|p| p.1)
                .min()
                .unwrap_or(center.1)
                .min(center.1)
                - 22;
            let width = points
                .iter()
                .map(|p| p.0)
                .max()
                .unwrap_or(center.0)
                .max(center.0)
                + 43
                - x;
            let height = points
                .iter()
                .map(|p| p.1)
                .max()
                .unwrap_or(center.1)
                .max(center.1)
                + 44
                - y;
            let items: Vec<_> = inner.iter().chain(outer).copied().collect();
            let window = CreateWindowExW(
                WS_EX_LAYERED
                    | WS_EX_TOPMOST
                    | if crate::pet::is_preview() {
                        WS_EX_APPWINDOW
                    } else {
                        WS_EX_TOOLWINDOW
                    },
                CLASS,
                w!("BaoBox 宠物快捷菜单"),
                WS_POPUP,
                x,
                y,
                width,
                height,
                pet,
                None,
                instance,
                None,
            )?;
            let ring = Self {
                window,
                commands: items.iter().map(|(action, _)| *action).collect(),
                state: Box::new(RingState {
                    owner,
                    start: Instant::now(),
                    hovered: Cell::new(HWND::default()),
                    points: points
                        .into_iter()
                        .map(|(px, py)| (px - x - 43, py - y - 22))
                        .collect(),
                    center: (center.0 - x - 43, center.1 - y - 22),
                    inner: inner.len(),
                    more: inner.iter().position(|(id, _)| *id == MORE).map(|i| i + 1),
                    outer_started: Cell::new(None),
                    faded_in: Cell::new(false),
                    icons: items
                        .iter()
                        .map(|(action, _)| match *action {
                            crate::caffeinate_module::TOGGLE | crate::caffeinate_module::STOP => {
                                0xec32
                            }
                            crate::screenshot_module::RECORD => 0xe7c8,
                            crate::keyboardnav_module::CLICK => 0xe765,
                            crate::pet_notify::RESUME => 0xea8f,
                            "app.settings" => 0xe713,
                            _ => ITEMS
                                .iter()
                                .position(|(id, _)| id == action)
                                .map_or(0xe712, |i| ICONS[i]),
                        })
                        .collect(),
                }),
            };
            SetWindowLongPtrW(
                window,
                GWLP_USERDATA,
                &*ring.state as *const RingState as isize,
            );
            SetLayeredWindowAttributes(window, KEY, 100, LWA_COLORKEY | LWA_ALPHA)?;
            for (index, (_, title)) in items.iter().enumerate() {
                let title: Vec<u16> = title.encode_utf16().chain(Some(0)).collect();
                CreateWindowExW(
                    Default::default(),
                    w!("BUTTON"),
                    PCWSTR(title.as_ptr()),
                    WS_CHILD | WS_TABSTOP | WINDOW_STYLE(BS_OWNERDRAW as u32),
                    ring.state.points[index].0,
                    ring.state.points[index].1,
                    86,
                    66,
                    window,
                    HMENU((index + 1) as _),
                    instance,
                    None,
                )?;
            }
            if SetTimer(window, 1, 15, None) == 0 {
                return Err(windows::core::Error::from_win32());
            }
            let _ = ShowWindow(window, SW_SHOW);
            let _ = SetForegroundWindow(window);
            Ok(ring)
        }
    }

    pub fn visible(&self) -> bool {
        unsafe { IsWindowVisible(self.window).as_bool() }
    }

    pub fn action(&self, index: usize) -> Option<&'static str> {
        self.commands.get(index.checked_sub(1)?).copied()
    }
}

impl Drop for Ring {
    fn drop(&mut self) {
        unsafe {
            if IsWindow(self.window).as_bool() {
                SetWindowLongPtrW(self.window, GWLP_USERDATA, 0);
                let _ = DestroyWindow(self.window);
            }
        }
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, message: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let state = (GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const RingState).as_ref();
    match message {
        WM_TIMER if wp.0 == 1 => {
            if let Some(state) = state {
                animate_ring(hwnd, state);
            }
        }
        WM_DRAWITEM if lp.0 != 0 => {
            let item = &*(lp.0 as *const DRAWITEMSTRUCT);
            draw_button(
                item,
                state.is_some_and(|state| state.hovered.get() == item.hwndItem),
                state
                    .and_then(|state| state.icons.get(item.CtlID.saturating_sub(1) as usize))
                    .copied()
                    .unwrap_or(0xe712),
            );
            return LRESULT(1);
        }
        WM_PAINT => {
            let mut paint = PAINTSTRUCT::default();
            let dc = BeginPaint(hwnd, &mut paint);
            let brush = CreateSolidBrush(KEY);
            FillRect(dc, &paint.rcPaint, brush);
            let _ = DeleteObject(brush);
            let _ = EndPaint(hwnd, &paint);
        }
        WM_ACTIVATE if wp.0 & 0xffff == WA_INACTIVE as usize => {
            let _ = ShowWindow(hwnd, SW_HIDE);
        }
        WM_COMMAND => {
            if let Some(state) = state {
                if state.more == Some(wp.0 & 0xffff) && state.inner < state.points.len() {
                    toggle_outer(hwnd, state);
                    return LRESULT(0);
                }
                let _ = PostMessageW(
                    state.owner,
                    WM_RING_ACTION,
                    WPARAM(wp.0 & 0xffff),
                    LPARAM(0),
                );
            }
            let _ = ShowWindow(hwnd, SW_HIDE);
        }
        WM_KEYDOWN if wp.0 == 0x1b => {
            if let Some(state) = state.filter(|state| state.outer_started.get().is_some()) {
                toggle_outer(hwnd, state);
                return LRESULT(0);
            }
            let _ = ShowWindow(hwnd, SW_HIDE);
        }
        _ => return DefWindowProcW(hwnd, message, wp, lp),
    }
    LRESULT(0)
}

unsafe fn toggle_outer(hwnd: HWND, state: &RingState) {
    let open = state.outer_started.get().is_none();
    state.outer_started.set(open.then(Instant::now));
    if !open {
        for index in state.inner..state.points.len() {
            if let Ok(button) = GetDlgItem(hwnd, (index + 1) as i32) {
                let _ = ShowWindow(button, SW_HIDE);
            }
        }
    }
    if let Some(index) = state.more {
        if let Ok(button) = GetDlgItem(hwnd, index as i32) {
            let _ = SetWindowTextW(button, if open { w!("收起") } else { w!("更多") });
            let _ = InvalidateRect(button, None, false);
        }
    }
}

unsafe fn animate_ring(hwnd: HWND, state: &RingState) {
    let elapsed = state.start.elapsed().as_secs_f32();
    if !state.faded_in.get() {
        let alpha = 100 + (130.0 * (elapsed / 0.22).min(1.0)) as u8;
        let _ = SetLayeredWindowAttributes(hwnd, KEY, alpha, LWA_COLORKEY | LWA_ALPHA);
        state.faded_in.set(elapsed >= 0.22);
    }
    for (index, &(x, y)) in state.points.iter().enumerate() {
        let (elapsed, offset) = if index < state.inner {
            (elapsed, index)
        } else {
            let Some(start) = state.outer_started.get() else {
                continue;
            };
            (start.elapsed().as_secs_f32(), index - state.inner)
        };
        let age = elapsed - offset as f32 * 0.018;
        if age < 0.0 {
            continue;
        }
        let Ok(button) = GetDlgItem(hwnd, (index + 1) as i32) else {
            continue;
        };
        if age > 0.22 && IsWindowVisible(button).as_bool() {
            continue;
        }
        let progress = (age / 0.18).clamp(0.0, 1.0);
        let radius = 1.0 - 0.35 * (1.0 - progress).powi(3);
        let _ = SetWindowPos(
            button,
            None,
            state.center.0 + ((x - state.center.0) as f32 * radius).round() as i32,
            state.center.1 + ((y - state.center.1) as f32 * radius).round() as i32,
            0,
            0,
            SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOSIZE | SWP_SHOWWINDOW,
        );
    }
    let mut cursor = windows::Win32::Foundation::POINT::default();
    let hovered = if GetCursorPos(&mut cursor).is_ok() {
        WindowFromPoint(cursor)
    } else {
        HWND::default()
    };
    let hovered = if GetParent(hovered).is_ok_and(|parent| parent == hwnd) {
        hovered
    } else {
        HWND::default()
    };
    let old = state.hovered.replace(hovered);
    if old != hovered {
        for button in [old, hovered] {
            if !button.is_invalid() {
                let _ = InvalidateRect(button, None, false);
            }
        }
    }
}

unsafe fn draw_button(item: &DRAWITEMSTRUCT, hovered: bool, icon: u16) {
    let dc = item.hDC;
    let bounds = item.rcItem;
    let clear = CreateSolidBrush(KEY);
    FillRect(dc, &bounds, clear);
    let _ = DeleteObject(clear);

    let active = hovered || item.itemState.0 & (ODS_SELECTED.0 | ODS_FOCUS.0) != 0;
    let center = (bounds.left + bounds.right) / 2;
    let surface = CreateSolidBrush(COLORREF(if active { 0xb8c42b } else { 0x24221c }));
    let outline = CreatePen(
        PS_SOLID,
        1,
        COLORREF(if active { 0xb8c42b } else { 0x3a382f }),
    );
    let old_brush = SelectObject(dc, surface);
    let old_pen = SelectObject(dc, outline);
    let radius = if item.itemState.0 & ODS_SELECTED.0 != 0 {
        19
    } else {
        22
    };
    let _ = Ellipse(
        dc,
        center - radius,
        22 - radius,
        center + radius,
        22 + radius,
    );

    let mut label = [0u16; 48];
    let count = GetWindowTextW(item.hwndItem, &mut label).max(0) as usize;
    let label_half = (count as i32 * 7 + 10).clamp(22, 42);
    SelectObject(dc, old_pen);
    SelectObject(dc, old_brush);
    let label_brush = CreateSolidBrush(COLORREF(0x24221c));
    SelectObject(dc, label_brush);
    SelectObject(dc, outline);
    let _ = RoundRect(dc, center - label_half, 47, center + label_half, 64, 17, 17);
    SelectObject(dc, old_pen);
    SelectObject(dc, old_brush);
    let _ = DeleteObject(outline);
    let _ = DeleteObject(surface);
    let _ = DeleteObject(label_brush);

    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, COLORREF(if active { 0xffffff } else { 0xb8c42b }));
    let icon_font = CreateFontW(
        -17,
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        1,
        0,
        0,
        4,
        0,
        w!("Segoe MDL2 Assets"),
    );
    let old_font = SelectObject(dc, icon_font);
    let mut icon = [icon];
    let mut icon_rect = RECT {
        left: center - 21,
        top: 1,
        right: center + 21,
        bottom: 43,
    };
    DrawTextW(
        dc,
        &mut icon,
        &mut icon_rect,
        DT_CENTER | DT_VCENTER | DT_SINGLELINE,
    );
    let label_font = CreateFontW(
        -11,
        0,
        0,
        0,
        500,
        0,
        0,
        0,
        1,
        0,
        0,
        4,
        0,
        w!("Microsoft YaHei UI"),
    );
    SelectObject(dc, label_font);
    SetTextColor(dc, COLORREF(0xe1dfdc));
    let mut label_rect = RECT {
        left: center - label_half,
        top: 46,
        right: center + label_half,
        bottom: 65,
    };
    DrawTextW(
        dc,
        &mut label[..count],
        &mut label_rect,
        DT_CENTER | DT_VCENTER | DT_SINGLELINE,
    );
    SelectObject(dc, old_font);
    let _ = DeleteObject(label_font);
    let _ = DeleteObject(icon_font);
}
