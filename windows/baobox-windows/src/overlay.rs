//! Windows 交互式截图覆盖层（分层窗口 + GDI）。
//!
//! 与 Linux 的 `overlay.rs` 是同一件事的两种画法，**交互规则完全共用**
//! `baobox_core::selection::Selection` —— 悬停高亮窗口、拖拽拉选区、八向手柄、
//! 方向键微调、⏎ 确认、Esc / 右键取消。
//!
//! 选区内重绘桌面快照，使其保持明亮，同时保留鼠标命中。

#![cfg(windows)]

use crate::editor::{self, EditorResult, ExtraAction};
use baobox_core::editor::Editor;
use baobox_core::geometry::{handle_at, Handle, Rect};
use baobox_core::selection::{Key, Outcome, Phase, Selection, HANDLE_TOLERANCE};
use baobox_core::toolbar::Item;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, CreateSolidBrush, DeleteDC,
    DeleteObject, EndPaint, FillRect, FrameRect, GetDC, IntersectClipRect, InvalidateRect,
    ReleaseDC, RestoreDC, SaveDC, SelectObject, SetBkMode, SetTextColor, StretchDIBits, TextOutW,
    BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HBITMAP, HBRUSH, HDC, HGDIOBJ,
    PAINTSTRUCT, SRCCOPY, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetKeyState, ReleaseCapture, SetCapture, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetCursorPos, GetMessageW,
    GetWindowLongPtrW, LoadCursorW, RegisterClassW, SetForegroundWindow, SetWindowLongPtrW,
    ShowWindow, TranslateMessage, UnregisterClassW, CS_HREDRAW, CS_VREDRAW, GWLP_USERDATA,
    IDC_CROSS, MSG, SW_SHOW, WM_CAPTURECHANGED, WM_CHAR, WM_CLOSE, WM_KEYDOWN, WM_LBUTTONDOWN,
    WM_LBUTTONUP, WM_MOUSEMOVE, WM_PAINT, WM_RBUTTONDOWN, WM_SETCURSOR, WNDCLASSW,
    WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
};

/// 覆盖层窗口类名。
const CLASS_NAME: PCWSTR = w!("BaoboxCaptureOverlay");

/// 选区边框色（GDI 是 BGR 顺序）。
const ACCENT_BGR: u32 = 0x00F4_F4F4;

/// 手柄边长。
const HANDLE_SIZE: i32 = 8;

/// 覆盖层运行结果。
pub struct OverlayResult {
    /// 用户选择的目标
    pub outcome: Outcome,
    /// 窗口列表（`Outcome::Window(i)` 的下标指向它）
    pub windows: Vec<Rect>,
    pub captured: Option<(Rect, crate::gdi::Capture)>,
    pub edited: Option<(Rect, EditorResult)>,
}

/// 挂在窗口上的可变状态。窗口过程通过 `GWLP_USERDATA` 拿到它。
struct OverlayState {
    selection: Selection,
    confirm_pressed: bool,
    move_grab: Option<(f64, f64)>,
    inline: bool,
    screen: Rect,
    editor: Option<Editor>,
    extra: Option<ExtraAction>,
    tool_active: bool,
    drawing: bool,
    toolbar_press: Option<(f64, f64)>,
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
    fn sync_editor(&mut self) {
        let Phase::Adjusting { rect, .. } = *self.selection.phase() else {
            return;
        };
        if !self.inline || rect.w < 1.0 || rect.h < 1.0 {
            return;
        }
        if let Some(editor) = &mut self.editor {
            let toolbar = editor::inline_toolbar(rect, self.screen, self.tool_active);
            if editor.image() != rect || editor.toolbar().frame != toolbar.frame {
                editor.set_layout(rect, toolbar);
            }
        } else {
            let mut editor =
                Editor::with_toolbar(rect, editor::inline_toolbar(rect, self.screen, false));
            editor.set_palette(&editor::WINDOWS_PALETTE);
            editor.set_width(3.0);
            self.editor = Some(editor);
        }
    }

    fn drag_to(&mut self, point: (f64, f64)) {
        if let Some((offset_x, offset_y)) = self.move_grab {
            self.selection
                .move_region_to(point.0 - offset_x, point.1 - offset_y);
        } else if !self.confirm_pressed {
            self.selection.mouse_moved(point);
        }
    }

    fn crop_snapshot(&self, area: Rect) -> Result<(Rect, crate::gdi::Capture), String> {
        let bounds = self.to_client(&area);
        let width = (bounds.right - bounds.left).max(0) as usize;
        let height = (bounds.bottom - bounds.top).max(0) as usize;
        if width == 0 || height == 0 {
            return Err("选区太小，请重新框选".into());
        }
        let mut rgba = Vec::with_capacity(width * height * 4);
        let stride = self.backdrop.width as usize * 4;
        for y in bounds.top as usize..bounds.bottom as usize {
            let start = y * stride + bounds.left as usize * 4;
            rgba.extend_from_slice(&self.backdrop.rgba[start..start + width * 4]);
        }
        for pixel in rgba.chunks_exact_mut(4) {
            pixel.swap(0, 2);
        }
        Ok((
            area,
            crate::gdi::Capture {
                width: width as u32,
                height: height as u32,
                rgba,
            },
        ))
    }

    fn confirm_button(&self) -> Option<RECT> {
        if self.inline || !matches!(self.selection.phase(), Phase::Adjusting { .. }) {
            return None;
        }
        let area = self.to_client(&self.selection.current_rect()?);
        let width = self.backdrop.width as i32;
        let height = self.backdrop.height as i32;
        const GAP: i32 = 8;
        const BUTTON_HEIGHT: i32 = 36;
        let button_width = 124.min(width - 2 * GAP).max(1);
        let right = area.right.clamp(button_width + GAP, width - GAP);
        let top = if area.bottom + GAP + BUTTON_HEIGHT <= height - GAP {
            area.bottom + GAP
        } else {
            (area.top - GAP - BUTTON_HEIGHT).max(GAP)
        };
        Some(RECT {
            left: right - button_width,
            right,
            top,
            bottom: top + BUTTON_HEIGHT,
        })
    }

    fn is_confirm(&self, x: i32, y: i32) -> bool {
        self.confirm_button().is_some_and(|rect| {
            x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom
        })
    }

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
    run_overlay(screen, windows, false, false)
}

pub fn run_capture(screen: Rect, windows: Vec<Rect>) -> Result<OverlayResult, String> {
    run_overlay(screen, windows, true, false)
}

pub fn run_editor(screen: Rect, windows: Vec<Rect>) -> Result<OverlayResult, String> {
    run_overlay(screen, windows, true, true)
}

fn run_overlay(
    screen: Rect,
    windows: Vec<Rect>,
    return_pixels: bool,
    inline: bool,
) -> Result<OverlayResult, String> {
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
            confirm_pressed: false,
            move_grab: None,
            inline,
            screen,
            editor: None,
            extra: None,
            tool_active: false,
            drawing: false,
            toolbar_press: None,
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
            if state.selection.outcome().is_some()
                || state.extra.is_some()
                || state
                    .editor
                    .as_ref()
                    .is_some_and(|editor| editor.outcome().is_some())
            {
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
        let edited = state
            .editor
            .as_ref()
            .map(|editor| {
                let (rect, shot) = state.crop_snapshot(editor.image())?;
                Ok::<_, String>((rect, editor::finish_inline(editor, state.extra, shot.rgba)?))
            })
            .transpose()?;
        let captured = if return_pixels && edited.is_none() {
            let target = match outcome {
                Outcome::Region(rect) => Some(rect),
                Outcome::Window(index) => windows.get(index).copied(),
                Outcome::FullScreen => Some(screen),
                Outcome::Cancelled => None,
            };
            target
                .map(|rect| state.crop_snapshot(rect.clamped_to(&screen)))
                .transpose()?
        } else {
            None
        };
        Ok(OverlayResult {
            outcome,
            windows,
            captured,
            edited,
        })
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
        WM_SETCURSOR => {
            if let Some(editor) = &state.editor {
                if editor::set_toolbar_cursor(editor.toolbar()) {
                    return LRESULT(1);
                }
            } else if state.confirm_button().is_some() {
                let mut cursor = POINT::default();
                if GetCursorPos(&mut cursor).is_ok()
                    && state.is_confirm(
                        cursor.x - state.origin.0 as i32,
                        cursor.y - state.origin.1 as i32,
                    )
                    && editor::set_hand_cursor()
                {
                    return LRESULT(1);
                }
            }
            DefWindowProcW(hwnd, message, wparam, lparam)
        }
        WM_MOUSEMOVE => {
            let (x, y) = lparam_to_point(lparam);
            let point = state.to_screen(x, y);
            if let Some(editor) = &mut state.editor {
                editor.mouse_moved(point);
                if !state.drawing {
                    state.drag_to(point);
                    state.sync_editor();
                }
                let _ = InvalidateRect(hwnd, None, false);
                return LRESULT(0);
            }
            let previous = state.selection.current_rect();
            let previous_button = state.confirm_button();
            state.drag_to(state.to_screen(x, y));
            let current = state.selection.current_rect();
            if previous != current {
                for button in previous_button.into_iter().chain(state.confirm_button()) {
                    let _ = InvalidateRect(hwnd, Some(&button), false);
                }
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
            state.confirm_pressed = state.is_confirm(x, y);
            if !state.confirm_pressed {
                let point = state.to_screen(x, y);
                if let Some(editor) = &mut state.editor {
                    let toolbar = editor.toolbar();
                    if toolbar.contains(point) {
                        state.toolbar_press = Some(point);
                        return LRESULT(0);
                    }
                    let image = editor.image();
                    if state.tool_active
                        && image.contains(point.0, point.1)
                        && handle_at(point, &image, HANDLE_TOLERANCE).is_none()
                    {
                        state.drawing = true;
                        editor.mouse_down(point);
                        let _ = InvalidateRect(hwnd, None, false);
                        return LRESULT(0);
                    }
                    if !image.contains(point.0, point.1)
                        && handle_at(point, &image, HANDLE_TOLERANCE).is_none()
                    {
                        state.editor = None;
                        state.tool_active = false;
                    }
                }
                state.move_grab = match *state.selection.phase() {
                    Phase::Adjusting { rect, .. }
                        if rect.contains(point.0, point.1)
                            && handle_at(point, &rect, HANDLE_TOLERANCE).is_none() =>
                    {
                        Some((point.0 - rect.x, point.1 - rect.y))
                    }
                    _ => None,
                };
                if state.move_grab.is_none() {
                    state.selection.mouse_down(point);
                }
            }
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            let (x, y) = lparam_to_point(lparam);
            let point = state.to_screen(x, y);
            if let Some(start) = state.toolbar_press.take() {
                if let Some(editor) = &mut state.editor {
                    let toolbar = editor.toolbar();
                    state.extra = editor::extra_buttons(toolbar.frame)
                        .into_iter()
                        .find(|(_, bounds)| {
                            bounds.contains(start.0, start.1) && bounds.contains(point.0, point.1)
                        })
                        .map(|(action, _)| action);
                    let width = editor::width_at(toolbar.frame, point)
                        .filter(|width| Some(*width) == editor::width_at(toolbar.frame, start));
                    if let Some(item) = toolbar
                        .hit(point)
                        .filter(|item| Some(*item) == toolbar.hit(start))
                    {
                        state.tool_active |= matches!(item, Item::Tool(_));
                        editor.activate(item);
                    }
                    if let Some(width) = width {
                        editor.set_width(width);
                    }
                }
                state.sync_editor();
                let _ = InvalidateRect(hwnd, None, false);
                let _ = ReleaseCapture();
                return LRESULT(0);
            }
            if std::mem::take(&mut state.drawing) {
                if let Some(editor) = &mut state.editor {
                    editor.mouse_up(point);
                }
                let _ = InvalidateRect(hwnd, None, false);
                let _ = ReleaseCapture();
                return LRESULT(0);
            }
            if std::mem::take(&mut state.confirm_pressed) {
                if state.is_confirm(x, y) {
                    state.selection.key_down(Key::Enter, false);
                }
            } else {
                state.drag_to(point);
                if state.move_grab.take().is_none() {
                    state.selection.mouse_up(point);
                }
            }
            state.sync_editor();
            let _ = InvalidateRect(hwnd, None, false);
            let _ = ReleaseCapture();
            LRESULT(0)
        }
        WM_CAPTURECHANGED => {
            state.move_grab = None;
            state.confirm_pressed = false;
            state.drawing = false;
            state.toolbar_press = None;
            LRESULT(0)
        }
        WM_RBUTTONDOWN => {
            // 右键取消，与 Linux 版一致
            state.selection.key_down(Key::Escape, false);

            LRESULT(0)
        }
        WM_KEYDOWN => {
            if let Some(editor) = &mut state.editor {
                let modifiers = editor::current_modifiers();
                let typing = editor.pending_text().is_some();
                if let Some(key) = editor::translate_key(wparam.0 as u32, modifiers.ctrl, typing) {
                    editor.key_down(key, modifiers);
                    let _ = InvalidateRect(hwnd, None, false);
                    return LRESULT(0);
                }
            }
            let shift = (GetKeyState(VK_SHIFT.0 as i32) as u16 & 0x8000) != 0;
            if let Some(key) = translate_key(wparam.0 as u32) {
                state.selection.key_down(key, shift);
                state.sync_editor();
            }
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_CHAR => {
            if let (Some(editor), Some(character)) =
                (&mut state.editor, char::from_u32(wparam.0 as u32))
            {
                editor.type_char(character);
                let _ = InvalidateRect(hwnd, None, false);
            }
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
        if let Some(editor) = &state.editor {
            if !editor.visible_shapes().is_empty() {
                if let Ok((_, shot)) = state.crop_snapshot(editor.image()) {
                    editor::paint_inline_image(hdc, editor, state.origin, shot.rgba);
                }
            }
        }

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

    if let Some(button) = state.confirm_button() {
        draw_confirm_button(hdc, button, state.confirm_pressed);
    }
    if let Some(editor) = &state.editor {
        if let Ok((_, mut shot)) = state.crop_snapshot(editor.toolbar().frame) {
            for pixel in shot.rgba.chunks_exact_mut(4) {
                for channel in &mut pixel[..3] {
                    *channel = (u16::from(*channel) * 153 / 255) as u8;
                }
            }
            editor::paint_inline_toolbar(hdc, editor, state.origin, state.tool_active, shot.rgba);
        }
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

unsafe fn draw_confirm_button(dc: HDC, mut bounds: RECT, pressed: bool) {
    use windows::Win32::Graphics::Gdi::{
        CreatePen, DrawTextW, RoundRect, DT_CENTER, DT_SINGLELINE, DT_VCENTER, PS_SOLID,
    };
    let brush = CreateSolidBrush(COLORREF(if pressed { 0x474442 } else { 0x252222 }));
    let pen = CreatePen(PS_SOLID, 1, COLORREF(0x565350));
    let font = crate::settings_window::settings_font(-15, 600);
    let old_brush = SelectObject(dc, brush);
    let old_pen = SelectObject(dc, pen);
    let old_font = SelectObject(dc, font);
    let _ = RoundRect(
        dc,
        bounds.left,
        bounds.top,
        bounds.right,
        bounds.bottom,
        12,
        12,
    );
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, COLORREF(0xf4f2ef));
    let mut label: Vec<u16> = "✓  确认选区".encode_utf16().collect();
    DrawTextW(
        dc,
        &mut label,
        &mut bounds,
        DT_CENTER | DT_SINGLELINE | DT_VCENTER,
    );
    SelectObject(dc, old_font);
    SelectObject(dc, old_pen);
    SelectObject(dc, old_brush);
    let _ = DeleteObject(font);
    let _ = DeleteObject(pen);
    let _ = DeleteObject(brush);
}

unsafe fn draw_snapshot(dc: HDC, state: &OverlayState, rect: &RECT, pixels: &[u8]) {
    let image = &state.backdrop;
    let saved = SaveDC(dc);
    if saved == 0 {
        return;
    }
    IntersectClipRect(dc, rect.left, rect.top, rect.right, rect.bottom);
    let width = image.width as i32;
    let height = image.height as i32;
    let info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    // Keep both layers anchored to the same desktop origin. GDI clips the
    // destination; a partial source rectangle can use a different Y origin.
    StretchDIBits(
        dc,
        0,
        0,
        width,
        height,
        0,
        0,
        width,
        height,
        Some(pixels.as_ptr().cast()),
        &info,
        DIB_RGB_COLORS,
        SRCCOPY,
    );
    let _ = RestoreDC(dc, saved);
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
