//! Windows 交互式截图覆盖层（分层窗口 + GDI）。
//!
//! 与 Linux 的 `overlay.rs` 是同一件事的两种画法，**交互规则完全共用**
//! `baobox_core::selection::Selection` —— 悬停高亮窗口、拖拽拉选区、八向手柄、
//! 方向键微调、⏎ 确认、Esc / 右键取消。
//!
//! 选区内重绘桌面快照，使其保持明亮，同时保留鼠标命中。

#![cfg(windows)]

use baobox_core::geometry::{Handle, Rect};
use baobox_core::selection::{Key, Outcome, Phase, Selection};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, CreateSolidBrush, DeleteDC,
    DeleteObject, EndPaint, FillRect, FrameRect, GetDC, InvalidateRect, ReleaseDC, SelectObject,
    SetBkMode, SetTextColor, StretchDIBits, TextOutW, BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
    DIB_RGB_COLORS, HBITMAP, HBRUSH, HDC, HGDIOBJ, PAINTSTRUCT, SRCCOPY, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetKeyState, ReleaseCapture, SetCapture, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetMessageW,
    GetWindowLongPtrW, LoadCursorW, RegisterClassW, SetForegroundWindow, SetWindowLongPtrW,
    ShowWindow, TranslateMessage, UnregisterClassW, CS_HREDRAW, CS_VREDRAW, GWLP_USERDATA,
    IDC_CROSS, MSG, SW_SHOW, WM_CLOSE, WM_KEYDOWN, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEMOVE,
    WM_PAINT, WM_RBUTTONDOWN, WNDCLASSW, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
};

/// 覆盖层窗口类名。
const CLASS_NAME: PCWSTR = w!("BaoboxCaptureOverlay");

/// 选区边框色（Baobox accent，GDI 是 BGR 顺序）。
const ACCENT_BGR: u32 = 0x0098_A317;

/// 手柄边长。
const HANDLE_SIZE: i32 = 8;

/// 覆盖层运行结果。
pub struct OverlayResult {
    /// 用户选择的目标
    pub outcome: Outcome,
    /// 窗口列表（`Outcome::Window(i)` 的下标指向它）
    pub windows: Vec<Rect>,
}

/// 挂在窗口上的可变状态。窗口过程通过 `GWLP_USERDATA` 拿到它。
struct OverlayState {
    selection: Selection,
    /// 覆盖窗左上角在屏幕坐标里的位置 —— 窗口消息给的是**客户区坐标**，
    /// 而状态机用的是屏幕坐标，两者要来回换算
    origin: (f64, f64),
    backdrop: crate::gdi::Capture,
    dimmed: Vec<u8>,
    surface: Option<Surface>,
}

struct Surface {
    dc: HDC,
    bitmap: HBITMAP,
    previous: HGDIOBJ,
}

impl Surface {
    unsafe fn new(width: i32, height: i32) -> Option<Self> {
        let screen = GetDC(None);
        let dc = CreateCompatibleDC(screen);
        let bitmap = CreateCompatibleBitmap(screen, width, height);
        ReleaseDC(None, screen);
        if dc.is_invalid() || bitmap.is_invalid() {
            if !dc.is_invalid() {
                let _ = DeleteDC(dc);
            }
            if !bitmap.is_invalid() {
                let _ = DeleteObject(bitmap);
            }
            return None;
        }
        let previous = SelectObject(dc, bitmap);
        if previous.is_invalid() {
            let _ = DeleteObject(bitmap);
            let _ = DeleteDC(dc);
            return None;
        }
        Some(Self {
            dc,
            bitmap,
            previous,
        })
    }
}

impl Drop for Surface {
    fn drop(&mut self) {
        unsafe {
            SelectObject(self.dc, self.previous);
            let _ = DeleteObject(self.bitmap);
            let _ = DeleteDC(self.dc);
        }
    }
}

impl OverlayState {
    fn to_screen(&self, x: i32, y: i32) -> (f64, f64) {
        (self.origin.0 + x as f64, self.origin.1 + y as f64)
    }

    fn to_client(&self, rect: &Rect) -> RECT {
        RECT {
            left: (rect.x - self.origin.0) as i32,
            top: (rect.y - self.origin.1) as i32,
            right: (rect.x - self.origin.0 + rect.w) as i32,
            bottom: (rect.y - self.origin.1 + rect.h) as i32,
        }
    }
}

/// 铺覆盖层并跑消息循环，直到用户确认或取消。
pub fn run(screen: Rect, windows: Vec<Rect>) -> Result<OverlayResult, String> {
    unsafe {
        let instance: HINSTANCE = GetModuleHandleW(None)
            .map_err(|e| format!("GetModuleHandle 失败：{e}"))?
            .into();

        let class = WNDCLASSW {
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(wndproc),
            hInstance: instance,
            lpszClassName: CLASS_NAME,
            hCursor: LoadCursorW(None, IDC_CROSS).unwrap_or_default(),
            ..Default::default()
        };
        // 重复注册返回 0，这里不当错误：同一进程内可能多次开覆盖层
        RegisterClassW(&class);

        let mut backdrop = crate::gdi::capture(screen)?;
        for pixel in backdrop.rgba.chunks_exact_mut(4) {
            pixel.swap(0, 2);
        }
        let mut dimmed = backdrop.rgba.clone();
        for pixel in dimmed.chunks_exact_mut(4) {
            for channel in &mut pixel[..3] {
                *channel = (u16::from(*channel) * 153 / 255) as u8;
            }
        }
        let mut state = Box::new(OverlayState {
            selection: Selection::new(screen, windows.clone()),
            origin: (screen.x, screen.y),
            backdrop,
            dimmed,
            surface: Surface::new(screen.w as i32, screen.h as i32),
        });

        let hwnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
            CLASS_NAME,
            w!("Baobox"),
            WS_POPUP,
            screen.x as i32,
            screen.y as i32,
            screen.w as i32,
            screen.h as i32,
            None,
            None,
            instance,
            None,
        )
        .map_err(|e| format!("创建覆盖窗失败：{e}"))?;

        SetWindowLongPtrW(
            hwnd,
            GWLP_USERDATA,
            state.as_mut() as *mut OverlayState as isize,
        );

        let _ = ShowWindow(hwnd, SW_SHOW);
        let _ = SetForegroundWindow(hwnd);

        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
            // 状态机出结果就收摊
            if state.selection.outcome().is_some() {
                break;
            }
        }

        // 先销毁窗口再返回：否则接下来的抓屏会把覆盖层本身也截进去
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        let _ = DestroyWindow(hwnd);
        let _ = UnregisterClassW(CLASS_NAME, instance);

        let outcome = state
            .selection
            .outcome()
            .cloned()
            .unwrap_or(Outcome::Cancelled);
        Ok(OverlayResult { outcome, windows })
    }
}

unsafe extern "system" fn wndproc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut OverlayState;
    if pointer.is_null() {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    let state = &mut *pointer;

    match message {
        WM_MOUSEMOVE => {
            let (x, y) = lparam_to_point(lparam);
            let previous = state.selection.current_rect();
            state.selection.mouse_moved(state.to_screen(x, y));
            let current = state.selection.current_rect();
            if previous != current {
                for rect in previous.into_iter().chain(current) {
                    let client = state.to_client(&rect);
                    let dirty = RECT {
                        left: client.left - 8,
                        top: client.top - 22,
                        right: client.right.max(client.left + 140) + 8,
                        bottom: client.bottom.max(client.top + 22) + 8,
                    };
                    let _ = InvalidateRect(hwnd, Some(&dirty), false);
                }
            }
            LRESULT(0)
        }
        WM_LBUTTONDOWN => {
            SetCapture(hwnd);
            let (x, y) = lparam_to_point(lparam);
            state.selection.mouse_down(state.to_screen(x, y));
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            let _ = ReleaseCapture();
            let (x, y) = lparam_to_point(lparam);
            state.selection.mouse_up(state.to_screen(x, y));
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_RBUTTONDOWN => {
            // 右键取消，与 Linux 版一致
            state.selection.key_down(Key::Escape, false);

            LRESULT(0)
        }
        WM_KEYDOWN => {
            let shift = (GetKeyState(VK_SHIFT.0 as i32) as u16 & 0x8000) != 0;
            if let Some(key) = translate_key(wparam.0 as u32) {
                state.selection.key_down(key, shift);
            }
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_PAINT => {
            paint(hwnd, state);
            LRESULT(0)
        }
        WM_CLOSE => {
            state.selection.key_down(Key::Escape, false);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

/// 虚拟键码 → 覆盖层关心的按键。
fn translate_key(virtual_key: u32) -> Option<Key> {
    const VK_ESCAPE: u32 = 0x1B;
    const VK_RETURN: u32 = 0x0D;
    const VK_LEFT: u32 = 0x25;
    const VK_UP: u32 = 0x26;
    const VK_RIGHT: u32 = 0x27;
    const VK_DOWN: u32 = 0x28;
    match virtual_key {
        VK_ESCAPE => Some(Key::Escape),
        VK_RETURN => Some(Key::Enter),
        VK_LEFT => Some(Key::Left),
        VK_UP => Some(Key::Up),
        VK_RIGHT => Some(Key::Right),
        VK_DOWN => Some(Key::Down),
        _ => None,
    }
}

/// `LPARAM` 里打包的客户区坐标。**必须按有符号解**：
/// 鼠标拖到窗口左侧/上方时坐标是负数，按无符号解会得到 65535 这类天文数字。
fn lparam_to_point(lparam: LPARAM) -> (i32, i32) {
    let value = lparam.0 as u32;
    let x = (value & 0xFFFF) as i16 as i32;
    let y = ((value >> 16) & 0xFFFF) as i16 as i32;
    (x, y)
}

unsafe fn paint(hwnd: HWND, state: &OverlayState) {
    let mut ps = PAINTSTRUCT::default();
    let target = BeginPaint(hwnd, &mut ps);
    let hdc = state.surface.as_ref().map_or(target, |surface| surface.dc);

    draw_snapshot(hdc, state, &ps.rcPaint, &state.dimmed);

    if let Some(rect) = state.selection.current_rect() {
        let client = state.to_client(&rect);
        draw_snapshot(hdc, state, &client, &state.backdrop.rgba);

        // 边框
        let accent: HBRUSH = CreateSolidBrush(COLORREF(ACCENT_BGR));
        FrameRect(hdc, &client, accent);

        // 选区成形后才画手柄；悬停高亮窗口时画手柄会误导
        if matches!(state.selection.phase(), Phase::Adjusting { .. }) {
            for handle in Handle::ALL {
                let (hx, hy) = handle.anchor(&rect);
                let cx = (hx - state.origin.0) as i32;
                let cy = (hy - state.origin.1) as i32;
                let box_rect = RECT {
                    left: cx - HANDLE_SIZE / 2,
                    top: cy - HANDLE_SIZE / 2,
                    right: cx + HANDLE_SIZE / 2,
                    bottom: cy + HANDLE_SIZE / 2,
                };
                FillRect(hdc, &box_rect, accent);
            }
        }
        let _ = DeleteObject(accent);

        draw_size_label(hdc, &client, &rect);
    }

    if state.surface.is_some() {
        let rect = ps.rcPaint;
        let _ = BitBlt(
            target,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            hdc,
            rect.left,
            rect.top,
            SRCCOPY,
        );
    }
    let _ = EndPaint(hwnd, &ps);
}

unsafe fn draw_snapshot(dc: HDC, state: &OverlayState, rect: &RECT, pixels: &[u8]) {
    let image = &state.backdrop;
    let left = rect.left.clamp(0, image.width as i32);
    let top = rect.top.clamp(0, image.height as i32);
    let width = rect.right.clamp(0, image.width as i32) - left;
    let height = rect.bottom.clamp(0, image.height as i32) - top;
    if width <= 0 || height <= 0 {
        return;
    }
    let info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: image.width as i32,
            biHeight: -(image.height as i32),
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    StretchDIBits(
        dc,
        left,
        top,
        width,
        height,
        left,
        top,
        width,
        height,
        Some(pixels.as_ptr().cast()),
        &info,
        DIB_RGB_COLORS,
        SRCCOPY,
    );
}

/// 在选区左上角上方标出尺寸。
unsafe fn draw_size_label(hdc: windows::Win32::Graphics::Gdi::HDC, client: &RECT, rect: &Rect) {
    let label: Vec<u16> = format!("{} × {}", rect.w as i64, rect.h as i64)
        .encode_utf16()
        .collect();
    SetBkMode(hdc, TRANSPARENT);
    SetTextColor(hdc, COLORREF(0x00FF_FFFF));
    // 贴着选区上方；顶到屏幕边缘时改放进选区内部
    let y = if client.top > 20 {
        client.top - 18
    } else {
        client.top + 4
    };
    let _ = TextOutW(hdc, client.left + 2, y, &label);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn confirming_overlay_does_not_quit_the_calling_message_loop() {
        use windows::Win32::UI::WindowsAndMessaging::{
            FindWindowW, GetWindowThreadProcessId, KillTimer, PeekMessageW, SendMessageW, SetTimer,
            PM_REMOVE, WM_QUIT,
        };
        unsafe extern "system" fn confirm(_: HWND, _: u32, timer: usize, _: u32) {
            if let Ok(window) = FindWindowW(CLASS_NAME, w!("Baobox")) {
                let mut process = 0;
                GetWindowThreadProcessId(window, Some(&mut process));
                if process == std::process::id() {
                    let _ = KillTimer(None, timer);
                    SendMessageW(window, WM_LBUTTONDOWN, WPARAM(0), LPARAM(12 | (14 << 16)));
                    SendMessageW(window, WM_MOUSEMOVE, WPARAM(0), LPARAM(54 | (45 << 16)));
                    SendMessageW(window, WM_LBUTTONUP, WPARAM(0), LPARAM(54 | (45 << 16)));
                    SendMessageW(window, WM_KEYDOWN, WPARAM(0x0d), LPARAM(0));
                }
            }
        }
        unsafe {
            let timer = SetTimer(None, 0, 25, Some(confirm));
            assert_ne!(timer, 0);
            let result = run(Rect::new(0.0, 0.0, 160.0, 120.0), Vec::new());
            let _ = KillTimer(None, timer);
            let Outcome::Region(region) = result.unwrap().outcome else {
                panic!("drag did not produce a region");
            };
            let image = crate::gdi::capture(region).unwrap();
            assert_eq!((image.width, image.height), (42, 31));
            let mut message = MSG::default();
            assert!(!PeekMessageW(&mut message, None, WM_QUIT, WM_QUIT, PM_REMOVE).as_bool());
        }
    }

    #[test]
    fn negative_coordinates_survive_lparam_unpacking() {
        // 鼠标在窗口左上方时坐标为负 —— 按无符号解会变成 65535 这类值
        let packed = ((-5i16 as u16 as u32) | ((-9i16 as u16 as u32) << 16)) as isize;
        assert_eq!(lparam_to_point(LPARAM(packed)), (-5, -9));
        let positive = ((100u32) | (200u32 << 16)) as isize;
        assert_eq!(lparam_to_point(LPARAM(positive)), (100, 200));
    }

    #[test]
    fn virtual_keys_map_to_the_shared_state_machine() {
        assert_eq!(translate_key(0x1B), Some(Key::Escape));
        assert_eq!(translate_key(0x0D), Some(Key::Enter));
        assert_eq!(translate_key(0x25), Some(Key::Left));
        assert_eq!(translate_key(0x41), None, "字母键不该被覆盖层吃掉");
    }
}
