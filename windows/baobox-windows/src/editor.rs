//! Windows 标注编辑器窗口（DIB section + GDI）。
//!
//! 与 Linux 的 `editor.rs` 是同一件事的两种画法：**交互规则完全共用**
//! `baobox_core::editor::Editor`，图形光栅化共用 `baobox_render`，
//! 工具条位置共用 `baobox_core::toolbar`。这里只负责三件事：
//! Win32 消息 → 编辑器输入、把合成结果贴到屏幕上、结束时把最终图像交出去。
//!
//! # 为什么用 DIB section 而不是 `CreateCompatibleBitmap`
//!
//! DIB section 是**我们自己能直接读写像素**的位图：`CreateDIBSection` 会回传一个
//! 指向像素的指针。于是同一块内存既能被我们逐像素合成（标注），
//! 又能被 GDI 当画布用（文字），最后还能直接读出来存成 PNG ——
//! 不需要 `GetDIBits` 再拷一遍。
//!
//! 兼容位图做不到这一点：它的像素在驱动那边，每次都得 `GetDIBits` 搬出来。
//!
//! # 一块像素，既是看到的也是保存的
//!
//! 屏幕上显示的和存进文件的走同一条渲染路径（合成 → 画字 → 输出），
//! 只是导出时不画工具条。分成两套迟早会让文字位置对不上。
//!
//! # 高度取负
//!
//! `biHeight` 为正时 DIB 是**自下而上**的（第一行在内存末尾）。取负才是自上而下，
//! 与我们和 `baobox_render` 用的坐标系一致。忘了取负的表现是整张图上下颠倒。

#![cfg(windows)]

use baobox_core::annotation::Color;
use baobox_core::editor::{Editor, EditorKey, EditorOutcome, Modifiers};
use baobox_core::geometry::Rect;
use baobox_render::chrome::{draw_toolbar, ToolbarState};
use baobox_render::{Canvas, TextDraw};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleDC, CreateDIBSection, CreateFontW, CreateSolidBrush, DeleteDC,
    DeleteObject, EndPaint, BeginPaint, FrameRect, GetDC, InvalidateRect, ReleaseDC, SelectObject,
    SetBkMode, SetTextColor, TextOutW, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DEFAULT_CHARSET,
    DEFAULT_PITCH, DIB_RGB_COLORS, FF_DONTCARE, FW_SEMIBOLD, HBITMAP, HDC, OUT_DEFAULT_PRECIS,
    PAINTSTRUCT, SRCCOPY, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetKeyState, VK_CONTROL, VK_SHIFT};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetMessageW,
    GetWindowLongPtrW, LoadCursorW, PostQuitMessage, RegisterClassW, SetForegroundWindow,
    SetWindowLongPtrW, ShowWindow,
    TranslateMessage, UnregisterClassW, CS_HREDRAW, CS_VREDRAW, GWLP_USERDATA, IDC_CROSS, MSG,
    SW_SHOW, WM_CHAR, WM_DESTROY, WM_KEYDOWN, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEMOVE,
    WM_PAINT, WM_RBUTTONDOWN, WNDCLASSW, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP, WS_VISIBLE,
};

/// 编辑器窗口类名。
const CLASS_NAME: PCWSTR = w!("BaoboxAnnotationEditor");

/// 图像之外那一圈的底色（与 Linux 版同色）。
const BACKDROP: [u8; 4] = [0x16, 0x18, 0x1B, 0xFF];

/// 截到的图四周的描边色（Baobox accent，GDI 是 BGR 顺序）。
///
/// 编辑器原位等大地覆盖在截图位置上，画面与桌面逐像素相同 ——
/// 不描边的话用户完全看不出「截到的是哪一块」（用户实测反馈）。
const ACCENT_BGR: u32 = 0x0098_A317;

/// 编辑器的最终产物。
pub struct EditorResult {
    /// 用户选了哪个出口
    pub outcome: EditorOutcome,
    /// 带标注的最终图像（RGBA8）
    pub rgba: Vec<u8>,
    /// 宽
    pub width: u32,
    /// 高
    pub height: u32,
}

/// 一块能被我们直接写像素、也能被 GDI 画字的位图。
///
/// `Drop` 里把 DC 与位图都还回去 —— GDI 对象泄漏在常驻进程里会一路累积到系统上限。
struct Surface {
    dc: HDC,
    bitmap: HBITMAP,
    previous: windows::Win32::Graphics::Gdi::HGDIOBJ,
    bits: *mut u8,
    width: usize,
    height: usize,
}

impl Surface {
    /// 建一块自上而下的 32 位 DIB。
    unsafe fn new(width: usize, height: usize) -> Result<Self, String> {
        if width == 0 || height == 0 {
            return Err("画布尺寸为零".to_string());
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
                biWidth: width as i32,
                // 负数 = 自上而下，与 baobox_render 的坐标系一致
                biHeight: -(height as i32),
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
        unsafe { std::slice::from_raw_parts_mut(self.bits, self.width * self.height * 4) }
    }

    /// 把 RGBA 写进去（顺带换成 BGRA）。
    fn write_rgba(&mut self, rgba: &[u8]) {
        let target = self.bgra();
        let count = target.len().min(rgba.len()) / 4;
        for index in 0..count {
            let at = index * 4;
            target[at] = rgba[at + 2]; // B
            target[at + 1] = rgba[at + 1]; // G
            target[at + 2] = rgba[at]; // R
            target[at + 3] = 0xFF;
        }
    }

    /// 读回 RGBA。
    fn read_rgba(&mut self) -> Vec<u8> {
        let source = self.bgra();
        let mut out = Vec::with_capacity(source.len());
        for pixel in source.chunks_exact(4) {
            out.extend_from_slice(&[pixel[2], pixel[1], pixel[0], 0xFF]);
        }
        out
    }

    /// 用系统字体把标注里的文字画上去。
    ///
    /// 文字是 `baobox_render` 唯一交回平台的东西 —— 字形栅格化与 CJK 排版
    /// 只有系统字体引擎做得对。
    unsafe fn draw_texts(&self, texts: &[TextDraw]) {
        SetBkMode(self.dc, TRANSPARENT);
        for text in texts {
            let font = CreateFontW(
                text.size.round() as i32,
                0,
                0,
                0,
                FW_SEMIBOLD.0 as i32,
                0,
                0,
                0,
                DEFAULT_CHARSET.0 as u32,
                OUT_DEFAULT_PRECIS.0 as u32,
                // 剪裁 / 质量用默认值：0 就是 DEFAULT_*，没有具名常量更清楚
                0,
                0,
                (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
                // 字体名留空 = 让系统按字符集挑，中文环境下会挑到能显示中文的字体
                PCWSTR::null(),
            );
            let previous = SelectObject(self.dc, font);
            SetTextColor(self.dc, to_colorref(text.color));
            let encoded: Vec<u16> = text.text.encode_utf16().collect();
            let _ = TextOutW(
                self.dc,
                text.x.round() as i32,
                text.y.round() as i32,
                &encoded,
            );
            SelectObject(self.dc, previous);
            let _ = DeleteObject(font);
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

/// GDI 的 `COLORREF` 是 **BGR**，不是 RGB。搞反了红蓝会互换。
fn to_colorref(color: Color) -> COLORREF {
    COLORREF(((color.b as u32) << 16) | ((color.g as u32) << 8) | color.r as u32)
}

/// 挂在窗口上的可变状态。
struct EditorState {
    editor: Editor,
    /// 窗口左上角在屏幕坐标里的位置
    origin: (f64, f64),
    /// 原图像素
    base: Vec<u8>,
    /// 图像在屏幕坐标里的位置
    image: Rect,
    surface: Surface,
}

impl EditorState {
    fn to_screen(&self, x: i32, y: i32) -> (f64, f64) {
        (self.origin.0 + x as f64, self.origin.1 + y as f64)
    }
}

/// 打开编辑器，跑到用户按下某个出口为止。
///
/// `initial_click` 是覆盖层工具栏上那一下点击（屏幕坐标）：两边的工具栏
/// 由同一份 `Toolbar::layout` 摆在同一个位置，所以直接交给编辑器的
/// 点击逻辑解释 —— 画笔类 = 带着选好的工具开窗；复制 / 保存 / 贴图 /
/// 取消 = 立刻出结果，**窗口都不用开**。
pub fn run(
    screen: Rect,
    image: Rect,
    rgba: Vec<u8>,
    initial_click: Option<(f64, f64)>,
) -> Result<EditorResult, String> {
    unsafe {
        let mut editor = Editor::new(image, screen);
        if let Some(point) = initial_click {
            editor.mouse_down(point);
            editor.mouse_up(point);
        }
        if let Some(outcome) = editor.outcome() {
            // 点的是出口类按钮：不开窗，原图直接交回去
            return Ok(EditorResult {
                outcome,
                rgba,
                width: image.w.round() as u32,
                height: image.h.round() as u32,
            });
        }

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
        RegisterClassW(&class);
        let frame = image.union(&editor.toolbar().frame).clamped_to(&screen);
        let (fw, fh) = (frame.w.round() as usize, frame.h.round() as usize);

        let mut state = Box::new(EditorState {
            editor,
            origin: (frame.x, frame.y),
            base: rgba,
            image,
            surface: Surface::new(fw, fh)?,
        });

        let hwnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
            CLASS_NAME,
            w!("Baobox"),
            WS_POPUP | WS_VISIBLE,
            frame.x as i32,
            frame.y as i32,
            fw as i32,
            fh as i32,
            None,
            None,
            instance,
            None,
        )
        .map_err(|e| format!("创建编辑器窗口失败：{e}"))?;

        SetWindowLongPtrW(hwnd, GWLP_USERDATA, state.as_mut() as *mut EditorState as isize);
        let _ = ShowWindow(hwnd, SW_SHOW);
        // 从快捷键唤起时前台还是别的应用；不抢过来的话工具切换 / 打字全打不进编辑器
        let _ = SetForegroundWindow(hwnd);

        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
            if state.editor.outcome().is_some() {
                break;
            }
        }

        // 先撤掉窗口再导出，用户按下按钮后画面应立刻消失
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        let _ = DestroyWindow(hwnd);
        let _ = UnregisterClassW(CLASS_NAME, instance);
        crate::overlay::strip_stale_quit();

        let outcome = state.editor.outcome().unwrap_or(EditorOutcome::Cancel);
        if outcome == EditorOutcome::Cancel {
            // 取消不必再合成一遍
            return Ok(EditorResult {
                outcome,
                width: state.image.w.round() as u32,
                height: state.image.h.round() as u32,
                rgba: std::mem::take(&mut state.base),
            });
        }
        let (rgba, width, height) = export(&state)?;
        Ok(EditorResult {
            outcome,
            rgba,
            width,
            height,
        })
    }
}

/// 导出最终图像：只有图像本身，没有工具条也没有底衬。
unsafe fn export(state: &EditorState) -> Result<(Vec<u8>, u32, u32), String> {
    let (iw, ih) = (
        state.image.w.round() as usize,
        state.image.h.round() as usize,
    );
    let mut surface = Surface::new(iw, ih)?;
    let mut pixels = compose(&state.image, &state.base, state.image);
    let texts = draw_annotations(&mut pixels, iw, ih, &state.editor, &state.image, false);
    surface.write_rgba(&pixels);
    surface.draw_texts(&texts);
    Ok((surface.read_rgba(), iw as u32, ih as u32))
}

unsafe extern "system" fn wndproc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut EditorState;
    if pointer.is_null() {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    let state = &mut *pointer;

    match message {
        WM_MOUSEMOVE => {
            let (x, y) = lparam_to_point(lparam);
            state.editor.mouse_moved(state.to_screen(x, y));
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_LBUTTONDOWN => {
            let (x, y) = lparam_to_point(lparam);
            state.editor.mouse_down(state.to_screen(x, y));
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            let (x, y) = lparam_to_point(lparam);
            state.editor.mouse_up(state.to_screen(x, y));
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_RBUTTONDOWN => {
            // 出结果靠 run() 循环里的检查退出，**不能** PostQuitMessage：
            // 循环在派发完这条消息后就 break，来不及消费 WM_QUIT，
            // 残留的 WM_QUIT 会把常驻模式的 App 主循环一并杀掉
            state.editor.key_down(EditorKey::Escape, Modifiers::NONE);
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_KEYDOWN => {
            let modifiers = current_modifiers();
            let typing = state.editor.pending_text().is_some();
            if let Some(key) = translate_key(wparam.0 as u32, modifiers.ctrl, typing) {
                // 同上：不发 WM_QUIT
                state.editor.key_down(key, modifiers);
            }
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        // 文字输入走 WM_CHAR：它是**经过键盘布局与输入法之后**的字符，
        // 中文、重音字母都在这里出来。用 WM_KEYDOWN 的虚拟键码是打不出中文的。
        WM_CHAR => {
            if let Some(character) = char::from_u32(wparam.0 as u32) {
                state.editor.type_char(character);
                let _ = InvalidateRect(hwnd, None, false);
            }
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

unsafe fn paint(hwnd: HWND, state: &mut EditorState) {
    let mut ps = PAINTSTRUCT::default();
    let hdc = BeginPaint(hwnd, &mut ps);

    let frame = Rect::new(
        state.origin.0,
        state.origin.1,
        state.surface.width as f64,
        state.surface.height as f64,
    );
    let (fw, fh) = (state.surface.width, state.surface.height);
    let mut pixels = compose(&frame, &state.base, state.image);
    let texts = draw_annotations(&mut pixels, fw, fh, &state.editor, &frame, true);
    state.surface.write_rgba(&pixels);
    state.surface.draw_texts(&texts);

    // 图四周描一圈 2px 的 accent 边（见 ACCENT_BGR 的注释）
    let image_client = RECT {
        left: (state.image.x - state.origin.0) as i32,
        top: (state.image.y - state.origin.1) as i32,
        right: (state.image.x - state.origin.0 + state.image.w) as i32,
        bottom: (state.image.y - state.origin.1 + state.image.h) as i32,
    };
    let accent = CreateSolidBrush(COLORREF(ACCENT_BGR));
    FrameRect(state.surface.dc, &image_client, accent);
    let inner = RECT {
        left: image_client.left + 1,
        top: image_client.top + 1,
        right: image_client.right - 1,
        bottom: image_client.bottom - 1,
    };
    FrameRect(state.surface.dc, &inner, accent);
    let _ = DeleteObject(accent);

    let _ = BitBlt(hdc, 0, 0, fw as i32, fh as i32, state.surface.dc, 0, 0, SRCCOPY);
    let _ = EndPaint(hwnd, &ps);
}

/// 铺底 + 把原图贴到它在 `frame` 里的位置。与 Linux 版是同一份逻辑。
fn compose(frame: &Rect, base: &[u8], image: Rect) -> Vec<u8> {
    let (fw, fh) = (frame.w.round() as usize, frame.h.round() as usize);
    let (iw, ih) = (image.w.round() as usize, image.h.round() as usize);
    let mut pixels = Vec::with_capacity(fw * fh * 4);
    for _ in 0..(fw * fh) {
        pixels.extend_from_slice(&BACKDROP);
    }

    let offset_x = (image.x - frame.x).round() as isize;
    let offset_y = (image.y - frame.y).round() as isize;
    for row in 0..ih {
        let target_y = offset_y + row as isize;
        if target_y < 0 || target_y as usize >= fh {
            continue;
        }
        for column in 0..iw {
            let target_x = offset_x + column as isize;
            if target_x < 0 || target_x as usize >= fw {
                continue;
            }
            let source = (row * iw + column) * 4;
            let target = (target_y as usize * fw + target_x as usize) * 4;
            if source + 4 <= base.len() {
                pixels[target..target + 4].copy_from_slice(&base[source..source + 4]);
            }
        }
    }
    pixels
}

/// 画标注（和可选的工具条），返回还要交给 GDI 补画的文字。
fn draw_annotations(
    pixels: &mut [u8],
    width: usize,
    height: usize,
    editor: &Editor,
    frame: &Rect,
    with_toolbar: bool,
) -> Vec<TextDraw> {
    let Some(mut canvas) = Canvas::new(width, height, pixels) else {
        return Vec::new();
    };
    let shapes: Vec<_> = editor
        .visible_shapes()
        .into_iter()
        .map(|mut shape| {
            for point in &mut shape.points {
                point.0 -= frame.x;
                point.1 -= frame.y;
            }
            shape
        })
        .collect();
    // 图形的坐标已经平移过，`render` 交回的文字位置也就已经是画布坐标，不必再减一次
    let texts = baobox_render::render(&shapes, &mut canvas);

    if with_toolbar {
        let mut toolbar = editor.toolbar().clone();
        toolbar.frame = toolbar.frame.offset(-frame.x, -frame.y);
        for button in &mut toolbar.buttons {
            button.frame = button.frame.offset(-frame.x, -frame.y);
        }
        draw_toolbar(
            &mut canvas,
            &toolbar,
            &ToolbarState {
                tool: editor.tool(),
                color_index: editor.color_index(),
                can_undo: editor.can_undo(),
                can_redo: editor.can_redo(),
                hovered: editor.toolbar().hit(editor.cursor()),
            },
        );
    }
    texts
}

/// 读当前的修饰键状态。
///
/// `WM_KEYDOWN` 不带修饰键信息，只能现查 —— 与覆盖层里查 Shift 是同一个套路。
fn current_modifiers() -> Modifiers {
    unsafe {
        Modifiers {
            ctrl: (GetKeyState(VK_CONTROL.0 as i32) as u16 & 0x8000) != 0,
            shift: (GetKeyState(VK_SHIFT.0 as i32) as u16 & 0x8000) != 0,
        }
    }
}

/// 虚拟键码 → 编辑器认得的命令。返回 `None` 表示「交给 `WM_CHAR` 当字符处理」。
///
/// # 为什么要看正在不正在打字
///
/// Windows 会把一次按键拆成 `WM_KEYDOWN` + `WM_CHAR` 两条消息，所以字母键
/// 不会像 Linux 那边一样被吃掉。但 `[` / `]` 会：它们既是调线宽的命令，
/// 又是能打进文字标注里的字符 —— 不加判断的话，用户在文字里打一个 `[`
/// 会顺手把画笔变粗。
fn translate_key(virtual_key: u32, ctrl: bool, typing: bool) -> Option<EditorKey> {
    const VK_BACK: u32 = 0x08;
    const VK_RETURN: u32 = 0x0D;
    const VK_ESCAPE: u32 = 0x1B;
    const VK_C: u32 = 0x43;
    const VK_S: u32 = 0x53;
    const VK_Y: u32 = 0x59;
    const VK_Z: u32 = 0x5A;
    const VK_OEM_4: u32 = 0xDB; // [
    const VK_OEM_6: u32 = 0xDD; // ]
    match virtual_key {
        // 这三个在任何状态下都是命令 —— 它们本来也打不出字符
        VK_ESCAPE => Some(EditorKey::Escape),
        VK_RETURN => Some(EditorKey::Enter),
        VK_BACK => Some(EditorKey::Backspace),
        // 字母键只有配合 Ctrl 才是快捷键；单按时 WM_CHAR 会把它打进去
        VK_Z if ctrl => Some(EditorKey::Z),
        VK_Y if ctrl => Some(EditorKey::Y),
        VK_C if ctrl => Some(EditorKey::C),
        VK_S if ctrl => Some(EditorKey::S),
        // 调线宽，只在没打字时有意义
        VK_OEM_4 if !typing => Some(EditorKey::BracketLeft),
        VK_OEM_6 if !typing => Some(EditorKey::BracketRight),
        _ => None,
    }
}

/// `LPARAM` 里打包的客户区坐标，**必须按有符号解**（同覆盖层）。
fn lparam_to_point(lparam: LPARAM) -> (i32, i32) {
    let value = lparam.0 as u32;
    (
        (value & 0xFFFF) as i16 as i32,
        ((value >> 16) & 0xFFFF) as i16 as i32,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colorref_is_bgr_not_rgb() {
        // 搞反的话红色标注会画成蓝色
        let red = to_colorref(Color::rgb(0xFF, 0x00, 0x00));
        assert_eq!(red.0, 0x0000_00FF);
        let blue = to_colorref(Color::rgb(0x00, 0x00, 0xFF));
        assert_eq!(blue.0, 0x00FF_0000);
    }

    #[test]
    fn editor_keys_map_from_virtual_key_codes() {
        let idle = |k: u32| translate_key(k, false, false);
        assert_eq!(idle(0x1B), Some(EditorKey::Escape));
        assert_eq!(idle(0x08), Some(EditorKey::Backspace));
        assert_eq!(idle(0xDB), Some(EditorKey::BracketLeft));
        assert_eq!(idle(0xDD), Some(EditorKey::BracketRight));
        // 普通字母交给 WM_CHAR 处理，不该在这里被吃掉
        assert_eq!(idle(0x41), None);
        assert_eq!(idle(0x5A), None, "单按 Z 是打字，不是撤销");
        assert_eq!(translate_key(0x5A, true, false), Some(EditorKey::Z));
    }

    #[test]
    fn typing_a_bracket_does_not_also_change_the_pen_width() {
        // `[` 既是调线宽的命令又是一个字符；打字时必须让位给 WM_CHAR
        assert_eq!(translate_key(0xDB, false, true), None);
        assert_eq!(translate_key(0xDD, false, true), None);
        // 但打字途中仍要能撤销、能落定、能删字
        assert_eq!(translate_key(0x5A, true, true), Some(EditorKey::Z));
        assert_eq!(translate_key(0x1B, false, true), Some(EditorKey::Escape));
        assert_eq!(translate_key(0x08, false, true), Some(EditorKey::Backspace));
    }

    #[test]
    fn negative_coordinates_survive_lparam_unpacking() {
        let packed = ((-7i16 as u16 as u32) | ((-3i16 as u16 as u32) << 16)) as isize;
        assert_eq!(lparam_to_point(LPARAM(packed)), (-7, -3));
    }

    #[test]
    fn composing_puts_the_image_where_it_belongs() {
        let base = vec![255u8, 0, 0, 255].repeat(4);
        let image = Rect::new(11.0, 21.0, 2.0, 2.0);
        let frame = Rect::new(10.0, 20.0, 4.0, 4.0);
        let pixels = compose(&frame, &base, image);
        assert_eq!(pixels.len(), 4 * 4 * 4);
        assert_eq!(&pixels[0..4], &BACKDROP);
        let at = (1 * 4 + 1) * 4;
        assert_eq!(&pixels[at..at + 4], &[255, 0, 0, 255]);
    }
}
