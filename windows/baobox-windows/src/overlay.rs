//! Windows 交互式截图覆盖层（分层窗口 + GDI）。
//!
//! 与 Linux 的 `overlay.rs` 是同一件事的两种画法，**交互规则完全共用**
//! `baobox_core::selection::Selection` —— 悬停高亮窗口、拖拽拉选区、八向手柄、
//! 方向键微调、⏎ 确认、Esc / 右键取消。
//!
//! # 压暗与「挖空」
//!
//! 用 `WS_EX_LAYERED` + `LWA_COLORKEY | LWA_ALPHA`：整窗统一半透明，
//! 但涂成 color key 的像素**完全透明**。于是把选区内部填成 color key，
//! 就得到「背景压暗、选区透亮」的效果，不需要逐像素 alpha（`UpdateLayeredWindow`）。
//!
//! color key 取一个几乎不会与 UI 撞色的值；万一撞了也只是那块跟着透明，
//! 而覆盖层本身只画压暗层与边框，不存在误伤。

#![cfg(windows)]

use baobox_core::geometry::{Handle, Rect};
use baobox_core::selection::{Key, Outcome, Phase, Selection};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, CreateSolidBrush, DeleteObject, EndPaint, FillRect, FrameRect, InvalidateRect,
    SetBkMode, SetTextColor, TextOutW, HBRUSH, PAINTSTRUCT, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetKeyState, VK_SHIFT};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetMessageW, GetWindowLongPtrW,
    LoadCursorW, PostQuitMessage, RegisterClassW, SetLayeredWindowAttributes, SetWindowLongPtrW,
    ShowWindow, TranslateMessage, UnregisterClassW, CS_HREDRAW, CS_VREDRAW, GWLP_USERDATA, IDC_CROSS,
    LWA_ALPHA, LWA_COLORKEY, MSG, SW_SHOW, WM_DESTROY, WM_KEYDOWN, WM_LBUTTONDOWN, WM_LBUTTONUP,
    WM_MOUSEMOVE, WM_PAINT, WM_RBUTTONDOWN, WNDCLASSW, WS_EX_LAYERED, WS_EX_TOOLWINDOW,
    WS_EX_TOPMOST, WS_POPUP, WS_VISIBLE,
};

/// 覆盖层窗口类名。
const CLASS_NAME: PCWSTR = w!("BaoboxCaptureOverlay");

/// 「挖空」用的 color key —— 涂上它的像素完全透明。
const TRANSPARENT_KEY: u32 = 0x00FF_00FF; // 洋红，BGR 顺序下同值

/// 压暗层的不透明度（0-255）。
const DIM_ALPHA: u8 = 0x66;

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

        let mut state = Box::new(OverlayState {
            selection: Selection::new(screen, windows.clone()),
            origin: (screen.x, screen.y),
        });

        let hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
            CLASS_NAME,
            w!("Baobox"),
            WS_POPUP | WS_VISIBLE,
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

        SetWindowLongPtrW(hwnd, GWLP_USERDATA, state.as_mut() as *mut OverlayState as isize);

        // 统一半透明 + color key 挖空
        SetLayeredWindowAttributes(
            hwnd,
            COLORREF(TRANSPARENT_KEY),
            DIM_ALPHA,
            LWA_COLORKEY | LWA_ALPHA,
        )
        .map_err(|e| format!("设置分层属性失败：{e}"))?;

        let _ = ShowWindow(hwnd, SW_SHOW);

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
            state.selection.mouse_moved(state.to_screen(x, y));
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_LBUTTONDOWN => {
            let (x, y) = lparam_to_point(lparam);
            state.selection.mouse_down(state.to_screen(x, y));
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            let (x, y) = lparam_to_point(lparam);
            state.selection.mouse_up(state.to_screen(x, y));
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_RBUTTONDOWN => {
            // 右键取消，与 Linux 版一致
            state.selection.key_down(Key::Escape, false);
            PostQuitMessage(0);
            LRESULT(0)
        }
        WM_KEYDOWN => {
            let shift = (GetKeyState(VK_SHIFT.0 as i32) as u16 & 0x8000) != 0;
            if let Some(key) = translate_key(wparam.0 as u32) {
                state.selection.key_down(key, shift);
                if state.selection.outcome().is_some() {
                    PostQuitMessage(0);
                }
            }
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_PAINT => {
            paint(hwnd, state);
            LRESULT(0)
        }
        WM_DESTROY => {
            PostQuitMessage(0);
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
    let hdc = BeginPaint(hwnd, &mut ps);

    // 整窗铺一层黑（分层属性会把它变成半透明的压暗层）
    let dim = CreateSolidBrush(COLORREF(0x0000_0000));
    FillRect(hdc, &ps.rcPaint, dim);
    let _ = DeleteObject(dim);

    if let Some(rect) = state.selection.current_rect() {
        let client = state.to_client(&rect);

        // 选区内部涂成 color key → 完全透明，用户看得清自己框的是什么
        let hole = CreateSolidBrush(COLORREF(TRANSPARENT_KEY));
        FillRect(hdc, &client, hole);
        let _ = DeleteObject(hole);

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

    let _ = EndPaint(hwnd, &ps);
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
