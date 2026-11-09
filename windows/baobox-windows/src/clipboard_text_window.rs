//! Independent clipboard editor and pinned text card.

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWA_USE_IMMERSIVE_DARK_MODE};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::{
    SetWindowTheme, EM_GETSEL, EM_LIMITTEXT, EM_SCROLLCARET, EM_SETRECTNP, EM_SETSEL,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetKeyState, SetFocus, VK_CONTROL, VK_MENU, VK_SHIFT,
};
use windows::Win32::UI::Shell::{DefSubclassProc, SetWindowSubclass};
use windows::Win32::UI::WindowsAndMessaging::*;

const CARD: PCWSTR = w!("BaoboxClipboardTextCard");
const EDITOR: PCWSTR = w!("BaoboxClipboardTextEditor");
const PANEL: COLORREF = COLORREF(0x2c2825);
const SURFACE: COLORREF = COLORREF(0x35302d);
const TEXT: COLORREF = COLORREF(0xf4efeb);
const MUTED: COLORREF = COLORREF(0xbab0a6);
const COPY: usize = 2;
const FIND: usize = 3;
const QUERY: usize = 4;
const NEXT: usize = 5;
const DISMISS: usize = 6;
const FOOTER: i32 = 48;

struct Card {
    text: String,
    preview: Vec<u16>,
    font: HFONT,
    opacity: u8,
}

impl Drop for Card {
    fn drop(&mut self) {
        unsafe {
            let _ = DeleteObject(self.font);
        }
    }
}

struct Editor {
    text: HWND,
    copy: HWND,
    find: HWND,
    query: HWND,
    next: HWND,
    dismiss: HWND,
    status: HWND,
    font: HFONT,
    body_font: HFONT,
    searching: bool,
}

impl Drop for Editor {
    fn drop(&mut self) {
        unsafe {
            let _ = DeleteObject(self.font);
            let _ = DeleteObject(self.body_font);
        }
    }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}

unsafe fn register(class: PCWSTR, proc: WNDPROC, instance: HINSTANCE) {
    RegisterClassW(&WNDCLASSW {
        style: CS_DBLCLKS,
        hInstance: instance,
        lpszClassName: class,
        lpfnWndProc: proc,
        hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
        ..Default::default()
    });
}

unsafe fn work_area() -> RECT {
    let mut point = POINT::default();
    let _ = GetCursorPos(&mut point);
    let mut info = MONITORINFO {
        cbSize: std::mem::size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    if GetMonitorInfoW(MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST), &mut info).as_bool() {
        info.rcWork
    } else {
        RECT {
            left: 0,
            top: 0,
            right: GetSystemMetrics(SM_CXSCREEN),
            bottom: GetSystemMetrics(SM_CYSCREEN),
        }
    }
}

pub fn pin(text: &str) -> Result<(), String> {
    if text.is_empty() {
        return Ok(());
    }
    unsafe {
        let instance = GetModuleHandleW(None).map_err(|e| e.to_string())?.into();
        register(CARD, Some(card_proc), instance);
        let state = Box::new(Card {
            text: text.into(),
            preview: text
                .lines()
                .take(40)
                .collect::<Vec<_>>()
                .join("\n")
                .chars()
                .take(16_384)
                .collect::<String>()
                .encode_utf16()
                .collect(),
            font: crate::settings_window::settings_font(-15, 400),
            opacity: 247,
        });
        let area = work_area();
        let max_width = (area.right - area.left - 54).clamp(140, 420);
        let mut measured = RECT {
            right: max_width,
            ..Default::default()
        };
        let dc = GetDC(None);
        let previous = SelectObject(dc, state.font);
        let mut contents = state.preview.clone();
        DrawTextW(
            dc,
            &mut contents,
            &mut measured,
            DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX | DT_EDITCONTROL,
        );
        SelectObject(dc, previous);
        ReleaseDC(None, dc);
        let width = measured.right.clamp(140, max_width) + 28;
        let height = (measured.bottom + 24).clamp(48, (area.bottom - area.top - 24).clamp(48, 584));
        let mut offset = 0;
        let mut after = HWND::default();
        loop {
            after = FindWindowExW(None, after, CARD, None).unwrap_or_default();
            if after.is_invalid() {
                break;
            }
            offset = (offset + 24) % 192;
        }
        let x = ((area.left + area.right - width) / 2 + offset)
            .clamp(area.left, (area.right - width).max(area.left));
        let y = ((area.top + area.bottom - height) / 2 + offset)
            .clamp(area.top, (area.bottom - height).max(area.top));
        let hwnd = CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED,
            CARD,
            w!("置顶文本"),
            WS_POPUP,
            x,
            y,
            width,
            height,
            None,
            None,
            instance,
            None,
        )
        .map_err(|e| format!("无法打开置顶卡片：{e}"))?;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, Box::into_raw(state) as isize);
        let shape = CreateRoundRectRgn(0, 0, width + 1, height + 1, 18, 18);
        if !shape.is_invalid() && SetWindowRgn(hwnd, shape, false) == 0 {
            let _ = DeleteObject(shape);
        }
        let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 247, LWA_ALPHA);
        let _ = SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW | SWP_NOACTIVATE,
        );
        Ok(())
    }
}

unsafe extern "system" fn card_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if let Some(result) = crate::tray::paint_menu(msg, lp) {
        return result;
    }
    let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut Card;
    if pointer.is_null() {
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
    match msg {
        WM_NCHITTEST => return LRESULT(HTCAPTION as isize),
        WM_NCLBUTTONDBLCLK | WM_CLOSE => {
            let _ = DestroyWindow(hwnd);
        }
        WM_KEYDOWN if wp.0 == 27 => {
            let _ = DestroyWindow(hwnd);
        }
        WM_KEYDOWN if wp.0 == 0x43 && GetKeyState(VK_CONTROL.0 as i32) < 0 => {
            let _ = crate::clipboard::copy_text(&(*pointer).text);
        }
        WM_NCRBUTTONUP | WM_CONTEXTMENU => {
            let mut at = POINT::default();
            let _ = GetCursorPos(&mut at);
            let _ = SetForegroundWindow(hwnd);
            match crate::tray::popup_text_actions(
                hwnd,
                at.x,
                at.y,
                &[("复制内容".into(), None), ("关闭".into(), None)],
            ) {
                Some(0) => {
                    let _ = crate::clipboard::copy_text(&(*pointer).text);
                }
                Some(1) => {
                    let _ = DestroyWindow(hwnd);
                }
                _ => {}
            }
        }
        WM_MOUSEWHEEL if GetKeyState(VK_MENU.0 as i32) < 0 => {
            let delta = (wp.0 >> 16) as i16;
            let opacity = (i16::from((*pointer).opacity) + delta / 12).clamp(51, 255) as u8;
            (*pointer).opacity = opacity;
            let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), opacity, LWA_ALPHA);
        }
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            let dc = BeginPaint(hwnd, &mut ps);
            let mut rect = RECT::default();
            let _ = GetClientRect(hwnd, &mut rect);
            crate::settings_window::rounded(dc, rect, 18, PANEL, COLORREF(0x625a53));
            let old = SelectObject(dc, (*pointer).font);
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, TEXT);
            rect.left += 14;
            rect.right -= 14;
            rect.top += 12;
            rect.bottom -= 10;
            let mut text = (*pointer).preview.clone();
            DrawTextW(
                dc,
                &mut text,
                &mut rect,
                DT_WORDBREAK | DT_NOPREFIX | DT_EDITCONTROL | DT_END_ELLIPSIS,
            );
            SelectObject(dc, old);
            let _ = EndPaint(hwnd, &ps);
        }
        WM_NCDESTROY => {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            drop(Box::from_raw(pointer));
            return DefWindowProcW(hwnd, msg, wp, lp);
        }
        _ => return DefWindowProcW(hwnd, msg, wp, lp),
    }
    LRESULT(0)
}

pub fn edit(text: &str) -> Result<(), String> {
    unsafe {
        let instance = GetModuleHandleW(None).map_err(|e| e.to_string())?.into();
        register(EDITOR, Some(editor_proc), instance);
        let area = work_area();
        let width = (area.right - area.left - 40).clamp(300, 900);
        let height = (area.bottom - area.top - 40).clamp(220, 640);
        let hwnd = CreateWindowExW(
            Default::default(),
            EDITOR,
            w!("剪贴板文本编辑"),
            WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
            (area.left + area.right - width) / 2,
            (area.top + area.bottom - height) / 2,
            width,
            height,
            None,
            None,
            instance,
            None,
        )
        .map_err(|e| format!("无法打开文本编辑器：{e}"))?;
        let dark = 1i32;
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE,
            (&dark as *const i32).cast(),
            4,
        );
        let mut state = Box::new(Editor {
            text: HWND::default(),
            copy: HWND::default(),
            find: HWND::default(),
            query: HWND::default(),
            next: HWND::default(),
            dismiss: HWND::default(),
            status: HWND::default(),
            font: crate::settings_window::settings_font(-14, 400),
            body_font: crate::settings_window::settings_font(-16, 400),
            searching: false,
        });
        let create = |class, text, style, id, font: HFONT| -> Result<HWND, String> {
            let child = CreateWindowExW(
                Default::default(),
                class,
                text,
                style,
                0,
                0,
                1,
                1,
                hwnd,
                HMENU(id as _),
                instance,
                None,
            )
            .map_err(|e| e.to_string())?;
            SendMessageW(child, WM_SETFONT, WPARAM(font.0 as usize), LPARAM(0));
            Ok(child)
        };
        let setup = (|| {
            state.text = create(
                w!("EDIT"),
                w!(""),
                WS_CHILD
                    | WS_VISIBLE
                    | WS_VSCROLL
                    | WS_TABSTOP
                    | WINDOW_STYLE(
                        (ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN | ES_NOHIDESEL) as u32,
                    ),
                1,
                state.body_font,
            )?;
            let initial = wide(&text.replace("\r\n", "\n").replace('\n', "\r\n"));
            let _ = SetWindowTextW(state.text, PCWSTR(initial.as_ptr()));
            SendMessageW(state.text, EM_LIMITTEXT, WPARAM(0x7fff_ffff), LPARAM(0));
            state.query = create(
                w!("EDIT"),
                w!(""),
                WS_CHILD | WS_TABSTOP | WINDOW_STYLE(ES_AUTOHSCROLL as u32),
                QUERY,
                state.font,
            )?;
            SendMessageW(
                state.query,
                windows::Win32::UI::Controls::EM_SETCUEBANNER,
                WPARAM(1),
                LPARAM(w!("查找文本").0 as isize),
            );
            let button = |text, id, visible| {
                let style = WS_CHILD
                    | WS_TABSTOP
                    | WINDOW_STYLE(BS_OWNERDRAW as u32)
                    | if visible { WS_VISIBLE } else { WINDOW_STYLE(0) };
                let button = create(w!("BUTTON"), text, style, id, state.font)?;
                crate::screenshot_preview::style_button(button);
                Ok::<_, String>(button)
            };
            state.copy = button(w!("复制全文"), COPY, true)?;
            state.find = button(w!("查找"), FIND, true)?;
            state.next = button(w!("下一个"), NEXT, false)?;
            state.dismiss = button(w!("关闭查找"), DISMISS, false)?;
            state.status = create(
                w!("STATIC"),
                w!("纯文本编辑"),
                WS_CHILD | WS_VISIBLE,
                0,
                state.font,
            )?;
            for control in [state.text, state.query] {
                let _ = SetWindowTheme(control, w!("DarkMode_Explorer"), None);
                let _ = SetWindowSubclass(control, Some(edit_keys), 1, 0);
            }
            Ok::<_, String>(())
        })();
        if let Err(error) = setup {
            let _ = DestroyWindow(hwnd);
            return Err(error);
        }
        let pointer = Box::into_raw(state);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, pointer as isize);
        layout(hwnd, &*pointer);
        let _ = SetWindowPos(
            hwnd,
            HWND_TOP,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW,
        );
        let _ = SetForegroundWindow(hwnd);
        let _ = SetFocus((*pointer).text);
        Ok(())
    }
}

unsafe fn layout(hwnd: HWND, state: &Editor) {
    let mut rect = RECT::default();
    let _ = GetClientRect(hwnd, &mut rect);
    let top = if state.searching { 48 } else { 14 };
    let width = (rect.right - 28).max(1);
    let height = (rect.bottom - FOOTER - top - 8).max(1);
    let _ = MoveWindow(state.text, 14, top, width, height, true);
    let inset = RECT {
        left: 12,
        top: 10,
        right: (width - 12).max(13),
        bottom: (height - 8).max(11),
    };
    SendMessageW(
        state.text,
        EM_SETRECTNP,
        WPARAM(0),
        LPARAM(&inset as *const RECT as isize),
    );
    let footer = rect.bottom - FOOTER;
    let _ = MoveWindow(state.status, 16, footer + 16, 220, 22, true);
    let _ = MoveWindow(state.copy, rect.right - 110, footer + 8, 96, 32, true);
    let _ = MoveWindow(state.find, rect.right - 178, footer + 8, 60, 32, true);
    let _ = MoveWindow(state.query, 14, 12, (rect.right - 182).max(1), 27, true);
    let _ = MoveWindow(state.next, rect.right - 160, 10, 67, 30, true);
    let _ = MoveWindow(state.dismiss, rect.right - 86, 10, 72, 30, true);
    for control in [state.query, state.next, state.dismiss] {
        let _ = ShowWindow(control, if state.searching { SW_SHOW } else { SW_HIDE });
    }
    let _ = InvalidateRect(hwnd, None, false);
}

unsafe fn read_text(hwnd: HWND) -> Vec<u16> {
    let mut buffer = vec![0; GetWindowTextLengthW(hwnd).max(0) as usize + 1];
    let len = GetWindowTextW(hwnd, &mut buffer).max(0) as usize;
    buffer.truncate(len);
    buffer
}

unsafe fn find_next(state: &Editor, backward: bool) {
    let query = read_text(state.query);
    if query.is_empty() {
        return;
    }
    let text = read_text(state.text);
    let mut start = 0u32;
    let mut end = 0u32;
    SendMessageW(
        state.text,
        EM_GETSEL,
        WPARAM(&mut start as *mut u32 as usize),
        LPARAM(&mut end as *mut u32 as isize),
    );
    let candidates = || {
        text.windows(query.len())
            .enumerate()
            .filter(|(_, value)| *value == query)
    };
    let found = if backward {
        candidates()
            .rev()
            .find(|(i, _)| *i < start as usize)
            .or_else(|| candidates().next_back())
    } else {
        candidates()
            .find(|(i, _)| *i >= end as usize)
            .or_else(|| candidates().next())
    };
    if let Some((start, _)) = found {
        SendMessageW(
            state.text,
            EM_SETSEL,
            WPARAM(start),
            LPARAM((start + query.len()) as isize),
        );
        SendMessageW(state.text, EM_SCROLLCARET, WPARAM(0), LPARAM(0));
        let _ = SetWindowTextW(state.status, w!("找到匹配"));
    } else {
        let _ = SetWindowTextW(state.status, w!("没有找到匹配"));
    }
}

unsafe extern "system" fn edit_keys(
    hwnd: HWND,
    msg: u32,
    wp: WPARAM,
    lp: LPARAM,
    _: usize,
    _: usize,
) -> LRESULT {
    if msg == WM_KEYDOWN {
        if let Ok(parent) = GetParent(hwnd) {
            let action = match wp.0 {
                0x46 if GetKeyState(VK_CONTROL.0 as i32) < 0 => Some(FIND),
                0x0d if GetKeyState(VK_CONTROL.0 as i32) < 0 => Some(COPY),
                0x0d if GetDlgCtrlID(hwnd) == QUERY as i32 => Some(NEXT),
                0x1b if GetDlgCtrlID(hwnd) == QUERY as i32 => Some(DISMISS),
                _ => None,
            };
            if let Some(action) = action {
                SendMessageW(parent, WM_COMMAND, WPARAM(action), LPARAM(0));
                return LRESULT(0);
            }
        }
    } else if msg == WM_CHAR
        && (matches!(wp.0, 6 | 27)
            || wp.0 == 13
                && (GetDlgCtrlID(hwnd) == QUERY as i32 || GetKeyState(VK_CONTROL.0 as i32) < 0))
    {
        return LRESULT(0);
    }
    DefSubclassProc(hwnd, msg, wp, lp)
}

unsafe extern "system" fn editor_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_DRAWITEM && matches!(wp.0, COPY | FIND | NEXT | DISMISS) {
        return crate::screenshot_preview::draw_button(lp, wp.0 == COPY, PANEL);
    }
    if matches!(msg, WM_CTLCOLOREDIT | WM_CTLCOLORSTATIC) {
        let dc = HDC(wp.0 as _);
        let (background, foreground) = if msg == WM_CTLCOLOREDIT {
            (SURFACE, TEXT)
        } else {
            (PANEL, MUTED)
        };
        SetTextColor(dc, foreground);
        SetBkColor(dc, background);
        SetDCBrushColor(dc, background);
        return LRESULT(GetStockObject(DC_BRUSH).0 as isize);
    }
    if msg == WM_GETMINMAXINFO {
        if let Some(info) = (lp.0 as *mut MINMAXINFO).as_mut() {
            info.ptMinTrackSize = POINT { x: 480, y: 360 };
        }
        return LRESULT(0);
    }
    let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut Editor;
    if pointer.is_null() {
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
    let state = &*pointer;
    match msg {
        WM_SIZE => layout(hwnd, state),
        WM_ERASEBKGND => return LRESULT(1),
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            let dc = BeginPaint(hwnd, &mut ps);
            SetDCBrushColor(dc, PANEL);
            let brush = HBRUSH(GetStockObject(DC_BRUSH).0);
            FillRect(dc, &ps.rcPaint, brush);
            let mut rect = RECT::default();
            let _ = GetClientRect(hwnd, &mut rect);
            let y = rect.bottom - FOOTER;
            SetDCBrushColor(dc, COLORREF(0x48413b));
            FillRect(
                dc,
                &RECT {
                    top: y,
                    bottom: y + 1,
                    ..rect
                },
                brush,
            );
            let _ = EndPaint(hwnd, &ps);
        }
        WM_COMMAND if wp.0 >> 16 == 0 => match wp.0 {
            COPY => {
                let text = String::from_utf16_lossy(&read_text(state.text));
                let copied = crate::clipboard::copy_text(&text).is_ok();
                let _ = SetWindowTextW(
                    state.status,
                    if copied {
                        w!("已复制全文")
                    } else {
                        w!("复制失败，请重试")
                    },
                );
            }
            FIND | DISMISS => {
                (*pointer).searching = wp.0 == FIND;
                let state = &*pointer;
                layout(hwnd, state);
                let _ = SetFocus(if state.searching {
                    state.query
                } else {
                    state.text
                });
                if state.searching {
                    SendMessageW(state.query, EM_SETSEL, WPARAM(0), LPARAM(-1));
                }
            }
            NEXT => find_next(state, GetKeyState(VK_SHIFT.0 as i32) < 0),
            _ => {}
        },
        WM_NCDESTROY => {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            drop(Box::from_raw(pointer));
            return DefWindowProcW(hwnd, msg, wp, lp);
        }
        _ => return DefWindowProcW(hwnd, msg, wp, lp),
    }
    LRESULT(0)
}
