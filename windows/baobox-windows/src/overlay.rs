//! Windows 交互式截图覆盖层（冻结底图 + GDI 双缓冲）。
//!
//! 与 Linux 的 `overlay.rs` 是同一件事的两种画法，**交互规则完全共用**
//! `baobox_core::selection::Selection` —— 悬停高亮窗口、拖拽拉选区、八向手柄、
//! 方向键微调、⏎ 确认、Esc / 右键取消。
//!
//! # 为什么是「冻结底图」而不是透明分层窗口
//!
//! 第一版用 `WS_EX_LAYERED` + `LWA_COLORKEY` 把选区内部涂成 color key 挖空。
//! 但 Windows 对分层窗口的命中测试**跟着透明走**：涂成 color key 的像素连鼠标
//! 消息一起放过去，直接打到底下的应用上。悬停高亮会把光标所在的整个窗口区域
//! 挖空，于是覆盖层从此收不到任何鼠标按下 / 移动 —— 表现就是「屏幕像定住了，
//! 拖动也拉不出选区」。
//!
//! 所以改用截图工具的标准做法：开覆盖层**之前**先把整块屏幕抓下来当冻结底图。
//! 覆盖窗完全不透明（所有输入都归它），每帧自己画「压暗的底图 + 原亮度的选区」，
//! 再整帧 BitBlt 上屏（双缓冲，不闪）。选区里看到的是底图里的画面 ——
//! 反正确认后抓的就是同一屏内容，两者不会对不上。

#![cfg(windows)]

use baobox_core::geometry::{Handle, Rect};
use baobox_core::selection::{Key, Outcome, Phase, Selection};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, BitBlt, CreateCompatibleDC, CreateDIBSection, CreateSolidBrush, DeleteDC,
    DeleteObject, EndPaint, FillRect, FrameRect, GetDC, InvalidateRect, ReleaseDC, SelectObject,
    SetBkMode, SetTextColor, TextOutW, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS,
    HBITMAP, HBRUSH, HDC, PAINTSTRUCT, SRCCOPY, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetKeyState, SetFocus, VK_SHIFT};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetMessageW, GetWindowLongPtrW,
    LoadCursorW, PostQuitMessage, RegisterClassW, SetForegroundWindow, SetWindowLongPtrW,
    ShowWindow, TranslateMessage, UnregisterClassW, CS_DBLCLKS, CS_HREDRAW, CS_VREDRAW,
    GWLP_USERDATA, IDC_CROSS, MSG, SW_SHOW, WM_DESTROY, WM_ERASEBKGND, WM_KEYDOWN,
    WM_LBUTTONDBLCLK, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEMOVE, WM_PAINT, WM_RBUTTONDOWN,
    WNDCLASSW, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP, WS_VISIBLE,
};

/// 覆盖层窗口类名。
const CLASS_NAME: PCWSTR = w!("BaoboxCaptureOverlay");

/// 压暗层保留的亮度（x/255）。153/255 ≈ 60%，等效于旧版压一层 alpha 0x66 的黑。
const DIM_KEEP: u32 = 153;

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

/// 一块 32 位自上而下的 DIB 及其内存 DC。
///
/// `Drop` 里把 DC 与位图都还回去 —— GDI 对象泄漏在常驻进程里会一路累积到系统上限。
struct Surface {
    dc: HDC,
    bitmap: HBITMAP,
    previous: windows::Win32::Graphics::Gdi::HGDIOBJ,
    bits: *mut u8,
    width: i32,
    height: i32,
}

impl Surface {
    unsafe fn new(width: i32, height: i32) -> Result<Self, String> {
        if width <= 0 || height <= 0 {
            return Err("覆盖层尺寸为零".to_string());
        }
        let screen = GetDC(None);
        let dc = CreateCompatibleDC(screen);
        ReleaseDC(None, screen);
        if dc.is_invalid() {
            return Err("无法创建内存 DC".to_string());
        }
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width,
                // 负数 = 自上而下
                biHeight: -height,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        let bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &mut bits, None, 0)
            .map_err(|e| format!("创建 DIB 失败：{e}"))?;
        if bits.is_null() {
            let _ = DeleteObject(bitmap);
            let _ = DeleteDC(dc);
            return Err("DIB 没有回传像素指针".to_string());
        }
        let previous = SelectObject(dc, bitmap);
        Ok(Self {
            dc,
            bitmap,
            previous,
            bits: bits.cast(),
            width,
            height,
        })
    }

    /// 像素缓冲。布局是 **BGRA**（Windows 的 32 位 DIB 就是这个顺序）。
    fn bgra(&mut self) -> &mut [u8] {
        // SAFETY: CreateDIBSection 保证这块内存至少有 width*height*4 字节，
        // 且它的生命周期与 self.bitmap 绑定，由 Drop 负责释放。
        unsafe {
            std::slice::from_raw_parts_mut(self.bits, self.width as usize * self.height as usize * 4)
        }
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

/// 冻结底图的两个版本 + 合成用的后备缓冲。
struct Frozen {
    /// 原亮度（选区内部露出它）
    bright: Surface,
    /// 压暗版（选区之外铺它）
    dim: Surface,
    /// 每帧在这里合成，再整帧上屏
    back: Surface,
}

impl Frozen {
    /// 把抓下来的整屏 RGBA 一次性铺进 bright / dim 两块 DIB。
    unsafe fn from_capture(width: i32, height: i32, rgba: &[u8]) -> Result<Self, String> {
        let mut bright = Surface::new(width, height)?;
        let mut dim = Surface::new(width, height)?;
        let back = Surface::new(width, height)?;
        {
            let bright_px = bright.bgra();
            let dim_px = dim.bgra();
            let count = (bright_px.len() / 4).min(rgba.len() / 4);
            for index in 0..count {
                let at = index * 4;
                let (r, g, b) = (rgba[at], rgba[at + 1], rgba[at + 2]);
                bright_px[at] = b;
                bright_px[at + 1] = g;
                bright_px[at + 2] = r;
                bright_px[at + 3] = 0xFF;
                dim_px[at] = dim_channel(b);
                dim_px[at + 1] = dim_channel(g);
                dim_px[at + 2] = dim_channel(r);
                dim_px[at + 3] = 0xFF;
            }
        }
        Ok(Self { bright, dim, back })
    }
}

/// 单个通道压暗到 60%。
fn dim_channel(value: u8) -> u8 {
    ((value as u32 * DIM_KEEP) / 255) as u8
}

/// 挂在窗口上的可变状态。窗口过程通过 `GWLP_USERDATA` 拿到它。
struct OverlayState {
    selection: Selection,
    /// 覆盖窗左上角在屏幕坐标里的位置 —— 窗口消息给的是**客户区坐标**，
    /// 而状态机用的是屏幕坐标，两者要来回换算
    origin: (f64, f64),
    frozen: Frozen,
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
        // 先抓整屏当冻结底图 —— 必须在建窗之前，否则会把覆盖层自己抓进去
        let shot = crate::gdi::capture(screen)?;
        let frozen = Frozen::from_capture(shot.width as i32, shot.height as i32, &shot.rgba)?;

        let instance: HINSTANCE = GetModuleHandleW(None)
            .map_err(|e| format!("GetModuleHandle 失败：{e}"))?
            .into();

        let class = WNDCLASSW {
            // CS_DBLCLKS：不加的话窗口根本收不到 WM_LBUTTONDBLCLK ——
            // 而「双击选区完成截图」是纯鼠标用户唯一的确认途径
            style: CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS,
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
            frozen,
        });

        let hwnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
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

        let _ = ShowWindow(hwnd, SW_SHOW);
        // 快捷键唤起时前台还是别的应用；不抢过来的话 Esc / ⏎ / 方向键全打不进覆盖层
        let _ = SetForegroundWindow(hwnd);
        let _ = SetFocus(hwnd);

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
        strip_stale_quit();

        let outcome = state
            .selection
            .outcome()
            .cloned()
            .unwrap_or(Outcome::Cancelled);
        Ok(OverlayResult { outcome, windows })
    }
}

/// 把可能残留在队列里的 `WM_QUIT` 摘掉。
///
/// 模态循环靠「状态机出结果」break，若有哪条路径还发了 `WM_QUIT`，
/// 它会在循环退出后残留在队列里，杀掉**下一个**消息循环 ——
/// 常驻模式下那是 App 的主循环，表现为整个程序毫无征兆地退出；
/// 或者是紧接着打开的编辑器，表现为「截完图编辑器一闪而没」。
/// 上面已经不再从动作路径发 WM_QUIT，这里是最后一道保险。
pub(crate) unsafe fn strip_stale_quit() {
    use windows::Win32::UI::WindowsAndMessaging::{PeekMessageW, PM_REMOVE, WM_QUIT};
    let mut message = MSG::default();
    while PeekMessageW(&mut message, None, WM_QUIT, WM_QUIT, PM_REMOVE).as_bool() {}
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
        WM_LBUTTONDBLCLK => {
            // 双击选区内部 = 确认截图。选区调整阶段只有回车能确认的话，
            // 纯鼠标的用户会以为「框住了就完了」，等不来工具栏（issue 反馈）
            let (x, y) = lparam_to_point(lparam);
            let point = state.to_screen(x, y);
            let inside = matches!(state.selection.phase(), Phase::Adjusting { .. })
                && state
                    .selection
                    .current_rect()
                    .is_some_and(|rect| rect.contains(point.0, point.1));
            if inside {
                state.selection.key_down(Key::Enter, false);
            } else {
                // 选区外的双击当普通按下处理，别把这次点击吞掉
                state.selection.mouse_down(point);
            }
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
            // 右键取消，与 Linux 版一致。
            // 这里**不能** PostQuitMessage：run() 的循环在派发完这条消息后
            // 就会因状态机出结果而 break，来不及消费 WM_QUIT ——
            // 残留的 WM_QUIT 会杀掉下一个消息循环（常驻模式下是 App 主循环，
            // 表现为按个 Esc 整个程序就退出了）
            state.selection.key_down(Key::Escape, false);
            LRESULT(0)
        }
        WM_KEYDOWN => {
            let shift = (GetKeyState(VK_SHIFT.0 as i32) as u16 & 0x8000) != 0;
            if let Some(key) = translate_key(wparam.0 as u32) {
                // 同上：出结果靠 run() 循环里的检查退出，不发 WM_QUIT
                state.selection.key_down(key, shift);
            }
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        // 背景由 WM_PAINT 整帧覆盖，这里什么都不擦，免得闪
        WM_ERASEBKGND => LRESULT(1),
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
    let frozen = &state.frozen;
    let (w, h) = (frozen.back.width, frozen.back.height);

    // 后备缓冲上合成：压暗底图打底
    let _ = BitBlt(frozen.back.dc, 0, 0, w, h, frozen.dim.dc, 0, 0, SRCCOPY);

    if let Some(rect) = state.selection.current_rect() {
        let client = state.to_client(&rect);

        // 选区内部露出原亮度的底图，用户看得清自己框的是什么
        let (cw, ch) = (client.right - client.left, client.bottom - client.top);
        if cw > 0 && ch > 0 {
            let _ = BitBlt(
                frozen.back.dc,
                client.left,
                client.top,
                cw,
                ch,
                frozen.bright.dc,
                client.left,
                client.top,
                SRCCOPY,
            );
        }

        // 边框
        let accent: HBRUSH = CreateSolidBrush(COLORREF(ACCENT_BGR));
        FrameRect(frozen.back.dc, &client, accent);

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
                FillRect(frozen.back.dc, &box_rect, accent);
            }
        }
        let _ = DeleteObject(accent);

        draw_size_label(
            frozen.back.dc,
            &client,
            &rect,
            matches!(state.selection.phase(), Phase::Adjusting { .. }),
        );
    }

    // 整帧上屏
    let _ = BitBlt(hdc, 0, 0, w, h, frozen.back.dc, 0, 0, SRCCOPY);
    let _ = EndPaint(hwnd, &ps);
}

/// 在选区左上角上方标出尺寸；选区成形后顺带写明怎么确认 ——
/// 只有回车能确认的话，纯鼠标的用户会以为「框住了就完了」。
unsafe fn draw_size_label(hdc: HDC, client: &RECT, rect: &Rect, adjusting: bool) {
    let text = if adjusting {
        format!(
            "{} × {}    双击选区 / ⏎ 截图 · 拖动手柄调整 · Esc 取消",
            rect.w as i64, rect.h as i64
        )
    } else {
        format!("{} × {}", rect.w as i64, rect.h as i64)
    };
    let label: Vec<u16> = text.encode_utf16().collect();
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

    #[test]
    fn dimming_keeps_sixty_percent_brightness() {
        assert_eq!(dim_channel(0), 0);
        assert_eq!(dim_channel(255), 153);
        // 单调不减，不会因整数除法出现反转
        assert!(dim_channel(128) <= dim_channel(129));
    }
}
