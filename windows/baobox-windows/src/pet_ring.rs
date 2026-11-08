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
pub const BACK: &str = "desktop-pet.ring-back";
pub const ITEMS: [(&str, &str); 8] = [
    (crate::screenshot_module::QUICK_CAPTURE, "截图"),
    (crate::screenshot_module::OCR, "屏幕取字"),
    (crate::clipboard_module::PANEL, "剪贴板"),
    ("desktop-pet.pet", "摸摸"),
    ("desktop-pet.feed", "喂食"),
    ("desktop-pet.play", "陪玩"),
    (crate::pet_notify::QUIET, "安静一小时"),
    (MORE, "更多"),
];
const CLASS: PCWSTR = w!("BaoboxPetRing");
const KEY: COLORREF = COLORREF(0xff00ff);
const ICONS: [u16; 8] = [
    0xe722, 0xe8a5, 0xe77f, 0xeb51, 0xed56, 0xe7fc, 0xe708, 0xe712,
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
    settled: Cell<bool>,
    icons: Vec<u16>,
}

impl Ring {
    pub fn open(
        owner: HWND,
        pet: HWND,
        items: &[(&'static str, &'static str)],
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
            let width = 344;
            let height = 260;
            let mut x = (pet_bounds.left + pet_bounds.right - width) / 2;
            let mut y = (pet_bounds.top + pet_bounds.bottom - height) / 2;
            if have_monitor {
                x = x.clamp(
                    info.rcWork.left,
                    (info.rcWork.right - width).max(info.rcWork.left),
                );
                y = y.clamp(
                    info.rcWork.top,
                    (info.rcWork.bottom - height).max(info.rcWork.top),
                );
            }
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
                    settled: Cell::new(false),
                    icons: items
                        .iter()
                        .map(|(action, _)| match *action {
                            crate::caffeinate_module::TOGGLE | crate::caffeinate_module::STOP => {
                                0xec32
                            }
                            crate::screenshot_module::RECORD => 0xe7c8,
                            crate::keyboardnav_module::CLICK => 0xe765,
                            "desktop-pet.next-character" => 0xe8ab,
                            "app.settings" => 0xe713,
                            BACK => 0xe72b,
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
                let angle = index as f32 * std::f32::consts::TAU / items.len() as f32
                    - std::f32::consts::FRAC_PI_2;
                let title: Vec<u16> = title.encode_utf16().chain(Some(0)).collect();
                CreateWindowExW(
                    Default::default(),
                    w!("BUTTON"),
                    PCWSTR(title.as_ptr()),
                    WS_CHILD | WS_TABSTOP | WINDOW_STYLE(BS_OWNERDRAW as u32),
                    width / 2 + (angle.cos() * 124.0) as i32 - 43,
                    height / 2 + (angle.sin() * 92.0) as i32 - 33,
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
            let _ = ShowWindow(hwnd, SW_HIDE);
        }
        _ => return DefWindowProcW(hwnd, message, wp, lp),
    }
    LRESULT(0)
}

unsafe fn animate_ring(hwnd: HWND, state: &RingState) {
    let elapsed = state.start.elapsed().as_secs_f32();
    if !state.settled.get() {
        let alpha = 100 + (130.0 * (elapsed / 0.22).min(1.0)) as u8;
        let _ = SetLayeredWindowAttributes(hwnd, KEY, alpha, LWA_COLORKEY | LWA_ALPHA);
        for index in 0..state.icons.len() {
            let age = elapsed - index as f32 * 0.018;
            if age < 0.0 {
                continue;
            }
            let Ok(button) = GetDlgItem(hwnd, (index + 1) as i32) else {
                continue;
            };
            let angle = index as f32 * std::f32::consts::TAU / state.icons.len() as f32
                - std::f32::consts::FRAC_PI_2;
            let progress = (age / 0.18).clamp(0.0, 1.0);
            let radius = 1.0 - 0.23 * (1.0 - progress).powi(3);
            let _ = SetWindowPos(
                button,
                None,
                129 + (angle.cos() * 124.0 * radius) as i32,
                97 + (angle.sin() * 92.0 * radius) as i32,
                0,
                0,
                SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOSIZE | SWP_SHOWWINDOW,
            );
        }
        state.settled.set(elapsed >= 0.36);
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
    let surface = CreateSolidBrush(COLORREF(if active { 0x835c45 } else { 0x352a23 }));
    let outline = CreatePen(
        PS_SOLID,
        1,
        COLORREF(if active { 0xeed4af } else { 0x997561 }),
    );
    let old_brush = SelectObject(dc, surface);
    let old_pen = SelectObject(dc, outline);
    let radius = if active { 22 } else { 19 };
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
    if active {
        let _ = RoundRect(dc, center - label_half, 46, center + label_half, 65, 14, 14);
    }
    SelectObject(dc, old_pen);
    SelectObject(dc, old_brush);
    let _ = DeleteObject(outline);
    let _ = DeleteObject(surface);

    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, COLORREF(0xf9f0e3));
    let icon_font = CreateFontW(
        -22,
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
        -13,
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
    let mut label_rect = RECT {
        left: center - label_half,
        top: 46,
        right: center + label_half,
        bottom: 65,
    };
    DrawTextW(
        dc,
        &mut label[..if active { count } else { 0 }],
        &mut label_rect,
        DT_CENTER | DT_VCENTER | DT_SINGLELINE,
    );
    SelectObject(dc, old_font);
    let _ = DeleteObject(label_font);
    let _ = DeleteObject(icon_font);
}
