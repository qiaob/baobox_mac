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
    BeginPaint, BitBlt, CreateCompatibleDC, CreateDIBSection, CreateFontW, CreateSolidBrush,
    DeleteDC, DeleteObject, EndPaint, FillRect, FrameRect, GetDC, InvalidateRect, ReleaseDC,
    SelectObject, SetBkMode, SetTextColor, TextOutW, BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
    DEFAULT_CHARSET, DEFAULT_PITCH, DIB_RGB_COLORS, FF_DONTCARE, FW_SEMIBOLD, HBITMAP, HBRUSH,
    HDC, OUT_DEFAULT_PRECIS, PAINTSTRUCT, SRCCOPY, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetKeyState, SetFocus, VK_SHIFT};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetMessageW, GetWindowLongPtrW,
    LoadCursorW, PostQuitMessage, RegisterClassW, SetForegroundWindow, SetWindowLongPtrW,
    ShowWindow, TranslateMessage, UnregisterClassW, CS_HREDRAW, CS_VREDRAW,
    GWLP_USERDATA, IDC_CROSS, MSG, SW_SHOW, WM_DESTROY, WM_ERASEBKGND, WM_KEYDOWN,
    WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEMOVE, WM_PAINT, WM_RBUTTONDOWN,
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

/// 动作按钮的尺寸与间距（屏幕像素）。
const BUTTON_H: f64 = 34.0;
const BUTTON_W: f64 = 64.0;
const CANCEL_W: f64 = 34.0;
const BUTTON_GAP: f64 = 8.0;
/// 按钮条与选区的距离。
const BUTTON_MARGIN: f64 = 10.0;

/// 覆盖层的用途，决定「拖完选区之后」的交互。
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// 截图：拖完选区**停在可调整状态**，选区旁出现动作按钮
    /// （编辑 / 复制 / 保存 / 贴图 / 取消），按了按钮才定稿 —— CleanShot 式。
    Capture,
    /// 只是选一块区域（屏幕取字、录屏）：松开鼠标即确认，没有按钮。
    Pick,
}

/// 用户在按钮条上选了什么去向。`Mode::Pick` 与键盘回车一律算 [`PostAction::Annotate`]。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PostAction {
    /// 进标注编辑器（默认去向）
    Annotate,
    /// 只复制到剪贴板
    Copy,
    /// 只保存到文件
    Save,
    /// 保存并钉在屏幕上
    Pin,
}

/// 按钮条上的一颗按钮。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum OverlayButton {
    Annotate,
    Copy,
    Save,
    Pin,
    Cancel,
}

impl OverlayButton {
    const ALL: [OverlayButton; 5] = [
        OverlayButton::Annotate,
        OverlayButton::Copy,
        OverlayButton::Save,
        OverlayButton::Pin,
        OverlayButton::Cancel,
    ];

    fn label(self) -> &'static str {
        match self {
            OverlayButton::Annotate => "编辑",
            OverlayButton::Copy => "复制",
            OverlayButton::Save => "保存",
            OverlayButton::Pin => "贴图",
            OverlayButton::Cancel => "✕",
        }
    }

    fn width(self) -> f64 {
        if self == OverlayButton::Cancel {
            CANCEL_W
        } else {
            BUTTON_W
        }
    }
}

/// 按钮条的摆放（屏幕坐标）：右对齐在选区下方；下方放不下翻到上方；
/// 上下都没地方（全屏选区）就贴在选区内部的右下角。永不出屏。
fn button_layout(rect: &Rect, screen: &Rect) -> Vec<(OverlayButton, Rect)> {
    let total: f64 = OverlayButton::ALL.iter().map(|b| b.width()).sum::<f64>()
        + BUTTON_GAP * (OverlayButton::ALL.len() as f64 - 1.0);
    let x = (rect.right() - total)
        .min(screen.right() - total - 4.0)
        .max(screen.x + 4.0);
    let below = rect.bottom() + BUTTON_MARGIN;
    let above = rect.y - BUTTON_MARGIN - BUTTON_H;
    let y = if below + BUTTON_H + 4.0 <= screen.bottom() {
        below
    } else if above >= screen.y + 4.0 {
        above
    } else {
        rect.bottom() - BUTTON_H - BUTTON_MARGIN
    };
    let mut cursor = x;
    OverlayButton::ALL
        .iter()
        .map(|button| {
            let frame = Rect::new(cursor, y, button.width(), BUTTON_H);
            cursor += button.width() + BUTTON_GAP;
            (*button, frame)
        })
        .collect()
}

/// 覆盖层运行结果。
pub struct OverlayResult {
    /// 用户选择的目标
    pub outcome: Outcome,
    /// 窗口列表（`Outcome::Window(i)` 的下标指向它）
    pub windows: Vec<Rect>,
    /// 截图完成后的去向（按钮条的选择；键盘回车 = 默认进编辑器）
    pub action: PostAction,
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
    /// 整个虚拟屏幕（按钮条摆放要拿它算边界）
    screen: Rect,
    mode: Mode,
    /// 用户按了哪颗按钮
    action: PostAction,
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

    /// 这一点（屏幕坐标）落在按钮条的哪颗按钮上。
    /// 只有截图模式的调整阶段才有按钮条。
    fn hit_button(&self, point: (f64, f64)) -> Option<OverlayButton> {
        if self.mode != Mode::Capture {
            return None;
        }
        if !matches!(self.selection.phase(), Phase::Adjusting { .. }) {
            return None;
        }
        let rect = self.selection.current_rect()?;
        button_layout(&rect, &self.screen)
            .into_iter()
            .find(|(_, frame)| frame.contains(point.0, point.1))
            .map(|(button, _)| button)
    }
}

/// 铺覆盖层并跑消息循环，直到用户确认或取消。
pub fn run(screen: Rect, windows: Vec<Rect>, mode: Mode) -> Result<OverlayResult, String> {
    unsafe {
        // 先抓整屏当冻结底图 —— 必须在建窗之前，否则会把覆盖层自己抓进去
        let shot = crate::gdi::capture(screen)?;
        let frozen = Frozen::from_capture(shot.width as i32, shot.height as i32, &shot.rgba)?;

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
            frozen,
            screen,
            mode,
            action: PostAction::Annotate,
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
        Ok(OverlayResult {
            outcome,
            windows,
            action: state.action,
        })
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
            let point = state.to_screen(x, y);
            // 先看是不是点在按钮条上 —— 按钮可能悬在选区内部（全屏选区时），
            // 不先拦的话这一下会被状态机当成「开始挪动选区」
            if let Some(button) = state.hit_button(point) {
                match button {
                    OverlayButton::Cancel => state.selection.key_down(Key::Escape, false),
                    other => {
                        state.action = match other {
                            OverlayButton::Copy => PostAction::Copy,
                            OverlayButton::Save => PostAction::Save,
                            OverlayButton::Pin => PostAction::Pin,
                            _ => PostAction::Annotate,
                        };
                        state.selection.key_down(Key::Enter, false);
                    }
                }
                return LRESULT(0);
            }
            state.selection.mouse_down(point);
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            let (x, y) = lparam_to_point(lparam);
            state.selection.mouse_up(state.to_screen(x, y));
            // 屏幕取字 / 录屏只要一块区域：松开鼠标即确认，没有按钮条。
            // 截图（Capture 模式）则停在可调整状态，让用户拖手柄改选区、
            // 在按钮条上选去向 —— CleanShot 式交互
            if state.mode == Mode::Pick
                && matches!(state.selection.phase(), Phase::Adjusting { .. })
            {
                state.selection.key_down(Key::Enter, false);
            }
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
        let adjusting = matches!(state.selection.phase(), Phase::Adjusting { .. });
        if adjusting {
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

        // 选区可调期间挂出动作按钮条；选区挪到哪它跟到哪
        if adjusting && state.mode == Mode::Capture {
            draw_buttons(frozen.back.dc, state, &rect);
        }

        draw_size_label(frozen.back.dc, &client, &rect);
    }

    // 整帧上屏
    let _ = BitBlt(hdc, 0, 0, w, h, frozen.back.dc, 0, 0, SRCCOPY);
    let _ = EndPaint(hwnd, &ps);
}

/// 画按钮条。文字要选一个真字体 —— 覆盖层 DC 里的库存字体显示不了中文。
unsafe fn draw_buttons(hdc: HDC, state: &OverlayState, rect: &Rect) {
    let font = CreateFontW(
        18,
        0,
        0,
        0,
        FW_SEMIBOLD.0 as i32,
        0,
        0,
        0,
        DEFAULT_CHARSET.0 as u32,
        OUT_DEFAULT_PRECIS.0 as u32,
        0,
        0,
        (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
        // 字体名留空 = 让系统按字符集挑，中文环境下会挑到能显示中文的字体
        PCWSTR::null(),
    );
    let previous_font = SelectObject(hdc, font);
    SetBkMode(hdc, TRANSPARENT);

    for (button, frame) in button_layout(rect, &state.screen) {
        let client = state.to_client(&frame);
        // 主按钮（编辑）用 accent，其余深灰底白字
        let background = if button == OverlayButton::Annotate {
            ACCENT_BGR
        } else {
            0x0033_2E2B
        };
        let fill = CreateSolidBrush(COLORREF(background));
        FillRect(hdc, &client, fill);
        let _ = DeleteObject(fill);
        let border = CreateSolidBrush(COLORREF(0x0077_7777));
        FrameRect(hdc, &client, border);
        let _ = DeleteObject(border);

        SetTextColor(hdc, COLORREF(0x00FF_FFFF));
        let label: Vec<u16> = button.label().encode_utf16().collect();
        // 居中的近似：一个 18px 的 CJK 字宽约 18px
        let approx_width = label.len() as i32 * 18;
        let text_x = client.left + (((client.right - client.left) - approx_width) / 2).max(4);
        let _ = TextOutW(hdc, text_x, client.top + 7, &label);
    }

    SelectObject(hdc, previous_font);
    let _ = DeleteObject(font);
}

/// 在选区左上角上方标出尺寸。
unsafe fn draw_size_label(hdc: HDC, client: &RECT, rect: &Rect) {
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

    #[test]
    fn the_button_bar_hugs_the_selection_and_never_leaves_the_screen() {
        let screen = Rect::new(0.0, 0.0, 1920.0, 1080.0);

        // 常规：右对齐挂在选区下方
        let rect = Rect::new(100.0, 100.0, 400.0, 300.0);
        let buttons = button_layout(&rect, &screen);
        assert_eq!(buttons.len(), 5);
        assert!(buttons.iter().all(|(_, f)| f.y == rect.bottom() + BUTTON_MARGIN));
        assert!(buttons.last().unwrap().1.right() <= rect.right() + 0.1);

        // 选区贴到屏幕底部：翻到选区上方
        let low = Rect::new(100.0, 700.0, 400.0, 360.0);
        let above = button_layout(&low, &screen);
        assert!(above[0].1.bottom() <= low.y, "下方放不下要翻上去");

        // 全屏选区：上下都没地方，进选区内部，且永不出屏
        let full = Rect::new(0.0, 0.0, 1920.0, 1080.0);
        for (_, frame) in button_layout(&full, &screen) {
            assert!(frame.x >= 0.0 && frame.right() <= 1920.0);
            assert!(frame.y >= 0.0 && frame.bottom() <= 1080.0);
        }
    }

    #[test]
    fn dimming_keeps_sixty_percent_brightness() {
        assert_eq!(dim_channel(0), 0);
        assert_eq!(dim_channel(255), 153);
        // 单调不减，不会因整数除法出现反转
        assert!(dim_channel(128) <= dim_channel(129));
    }
}
