//! Scrollable preview for a completed long screenshot.

use crate::gdi::Capture;
use windows::core::w;
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::{
    SetScrollInfo, DRAWITEMSTRUCT, ODS_DISABLED, ODS_FOCUS, ODS_SELECTED, WM_MOUSELEAVE,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    IsWindowEnabled, SetFocus, TrackMouseEvent, TME_LEAVE, TRACKMOUSEEVENT,
};
use windows::Win32::UI::Shell::{DefSubclassProc, SetWindowSubclass};
use windows::Win32::UI::WindowsAndMessaging::*;

const CLASS: windows::core::PCWSTR = w!("BaoboxLongScreenshotPreview");
const FOOTER: i32 = 48;
const FOOTER_COLOR: COLORREF = COLORREF(0x282525);

#[derive(Clone, Copy)]
pub enum Action {
    Save = 1,
    Ocr,
    Pin,
    Copy,
}

struct Preview {
    pixels: Vec<u8>,
    bitmap: BITMAPINFO,
    controls: [HWND; 4],
    dimensions: HWND,
    font: HFONT,
    offset: i32,
    closed: bool,
    action: Option<Action>,
}

impl Drop for Preview {
    fn drop(&mut self) {
        unsafe {
            let _ = DeleteObject(self.font);
        }
    }
}

pub fn run(shot: &Capture, mut on_action: impl FnMut(HWND, Action)) -> Result<(), String> {
    unsafe {
        let instance: HINSTANCE = GetModuleHandleW(None).map_err(|e| e.to_string())?.into();
        RegisterClassW(&WNDCLASSW {
            hInstance: instance,
            lpfnWndProc: Some(window_proc),
            lpszClassName: CLASS,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            ..Default::default()
        });
        let (width, height) = (shot.width as i32, shot.height as i32);
        let screen_width = GetSystemMetrics(SM_CXSCREEN);
        let screen_height = GetSystemMetrics(SM_CYSCREEN);
        let window_width = (width + 45).max(480).min(screen_width - 40);
        let window_height = (height + 100).max(280).min(screen_height - 100);
        let hwnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
            CLASS,
            w!("长截图预览"),
            WS_OVERLAPPEDWINDOW | WS_VSCROLL | WS_CLIPCHILDREN,
            (screen_width - window_width) / 2,
            (screen_height - window_height) / 2,
            window_width,
            window_height,
            None,
            None,
            instance,
            None,
        )
        .map_err(|e| format!("无法打开长截图预览：{e}"))?;

        let result = (|| {
            let mut state = Preview {
                pixels: shot.rgba.clone(),
                bitmap: BITMAPINFO {
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
                },
                controls: [HWND::default(); 4],
                dimensions: HWND::default(),
                font: crate::settings_window::settings_font(-14, 400),
                offset: 0,
                closed: false,
                action: None,
            };
            for pixel in state.pixels.chunks_exact_mut(4) {
                pixel.swap(0, 2);
            }
            for (index, title) in [w!("保存"), w!("取字"), w!("钉图"), w!("复制")]
                .into_iter()
                .enumerate()
            {
                let button = CreateWindowExW(
                    Default::default(),
                    w!("BUTTON"),
                    title,
                    WS_CHILD | WS_VISIBLE | WINDOW_STYLE(BS_OWNERDRAW as u32),
                    0,
                    0,
                    0,
                    0,
                    hwnd,
                    HMENU((index + 1) as _),
                    instance,
                    None,
                )
                .map_err(|e| e.to_string())?;
                SendMessageW(button, WM_SETFONT, WPARAM(state.font.0 as usize), LPARAM(1));
                style_button(button);
                state.controls[index] = button;
            }
            let title: Vec<u16> = format!("{width} × {height} 像素")
                .encode_utf16()
                .chain(Some(0))
                .collect();
            state.dimensions = CreateWindowExW(
                Default::default(),
                w!("STATIC"),
                windows::core::PCWSTR(title.as_ptr()),
                WS_CHILD | WS_VISIBLE,
                0,
                0,
                0,
                0,
                hwnd,
                None,
                instance,
                None,
            )
            .map_err(|e| e.to_string())?;
            SendMessageW(
                state.dimensions,
                WM_SETFONT,
                WPARAM(state.font.0 as usize),
                LPARAM(1),
            );
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, &mut state as *mut Preview as isize);
            layout(hwnd, &mut state);
            let _ = SetWindowPos(
                hwnd,
                HWND_TOPMOST,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW,
            );
            let _ = SetForegroundWindow(hwnd);
            let _ = SetFocus(hwnd);

            let mut message = MSG::default();
            while !state.closed {
                let status = GetMessageW(&mut message, hwnd, 0, 0).0;
                if status <= 0 {
                    if status == 0 {
                        PostQuitMessage(message.wParam.0 as i32);
                    }
                    break;
                }
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
                if let Some(action) = state.action.take() {
                    if state.closed {
                        let _ = ShowWindow(hwnd, SW_HIDE);
                    }
                    on_action(hwnd, action);
                }
            }
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            let _ = DestroyWindow(hwnd);
            Ok(())
        })();
        if IsWindow(hwnd).as_bool() {
            let _ = DestroyWindow(hwnd);
        }
        let _ = UnregisterClassW(CLASS, instance);
        result
    }
}

fn image_size(state: &Preview, client: RECT) -> (i32, i32) {
    let original = state.bitmap.bmiHeader;
    let width = original.biWidth.min(client.right.max(1));
    let height =
        (i64::from(-original.biHeight) * i64::from(width) / i64::from(original.biWidth)) as i32;
    (width, height.max(1))
}

unsafe fn layout(hwnd: HWND, state: &mut Preview) {
    let mut client = RECT::default();
    let _ = GetClientRect(hwnd, &mut client);
    let page = (client.bottom - FOOTER).max(1);
    let (_, height) = image_size(state, client);
    state.offset = state.offset.clamp(0, (height - page).max(0));
    let info = SCROLLINFO {
        cbSize: std::mem::size_of::<SCROLLINFO>() as u32,
        fMask: SIF_RANGE | SIF_PAGE | SIF_POS | SIF_DISABLENOSCROLL,
        nMin: 0,
        nMax: height - 1,
        nPage: page as u32,
        nPos: state.offset,
        nTrackPos: 0,
    };
    SetScrollInfo(hwnd, SB_VERT, &info, true);
    for (index, button) in state.controls.into_iter().enumerate() {
        let x = client.right - 12 - (4 - index as i32) * 68;
        let _ = MoveWindow(button, x, page + 9, 60, 30, true);
    }
    let _ = MoveWindow(state.dimensions, 12, page + 15, 164, 22, true);
    let _ = InvalidateRect(hwnd, None, false);
}

unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_DRAWITEM && (1..=4).contains(&wp.0) {
        return draw_button(lp, wp.0 == 4, FOOTER_COLOR);
    }
    if msg == WM_CTLCOLORSTATIC {
        let dc = HDC(wp.0 as _);
        SetTextColor(dc, COLORREF(0xeeeeee));
        SetBkColor(dc, FOOTER_COLOR);
        SetDCBrushColor(dc, FOOTER_COLOR);
        return LRESULT(GetStockObject(DC_BRUSH).0 as isize);
    }
    let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut Preview;
    let Some(state) = pointer.as_mut() else {
        return DefWindowProcW(hwnd, msg, wp, lp);
    };
    match msg {
        WM_CLOSE => state.closed = true,
        WM_SIZE => layout(hwnd, state),
        WM_COMMAND => {
            state.action = match wp.0 & 0xffff {
                1 => Some(Action::Save),
                2 => Some(Action::Ocr),
                3 => Some(Action::Pin),
                4 => Some(Action::Copy),
                _ => None,
            };
            state.closed = matches!(state.action, Some(Action::Copy | Action::Pin));
        }
        WM_KEYDOWN if wp.0 == 27 => state.closed = true,
        WM_KEYDOWN if wp.0 == 13 => {
            state.action = Some(Action::Copy);
            state.closed = true;
        }
        WM_MOUSEWHEEL => {
            state.offset -= (wp.0 >> 16) as i16 as i32 * 2 / 3;
            layout(hwnd, state);
        }
        WM_VSCROLL => {
            let mut info = SCROLLINFO {
                cbSize: std::mem::size_of::<SCROLLINFO>() as u32,
                fMask: SIF_ALL,
                ..Default::default()
            };
            let _ = GetScrollInfo(hwnd, SB_VERT, &mut info);
            state.offset = match SCROLLBAR_COMMAND((wp.0 & 0xffff) as i32) {
                SB_LINEUP => state.offset - 40,
                SB_LINEDOWN => state.offset + 40,
                SB_PAGEUP => state.offset - info.nPage as i32,
                SB_PAGEDOWN => state.offset + info.nPage as i32,
                SB_THUMBTRACK | SB_THUMBPOSITION => info.nTrackPos,
                SB_TOP => 0,
                SB_BOTTOM => info.nMax,
                _ => state.offset,
            };
            layout(hwnd, state);
        }
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            let mut client = RECT::default();
            let _ = GetClientRect(hwnd, &mut client);
            let dc = BeginPaint(hwnd, &mut ps);
            FillRect(dc, &ps.rcPaint, GetSysColorBrush(COLOR_WINDOW));
            let page = (client.bottom - FOOTER).max(1);
            let (width, height) = image_size(state, client);
            let saved = SaveDC(dc);
            if saved != 0 {
                IntersectClipRect(dc, 0, 0, client.right, page);
                StretchDIBits(
                    dc,
                    (client.right - width) / 2,
                    -state.offset,
                    width,
                    height,
                    0,
                    0,
                    state.bitmap.bmiHeader.biWidth,
                    -state.bitmap.bmiHeader.biHeight,
                    Some(state.pixels.as_ptr().cast()),
                    &state.bitmap,
                    DIB_RGB_COLORS,
                    SRCCOPY,
                );
                let _ = RestoreDC(dc, saved);
            }
            let footer = RECT {
                top: page,
                ..client
            };
            SetDCBrushColor(dc, FOOTER_COLOR);
            FillRect(dc, &footer, HBRUSH(GetStockObject(DC_BRUSH).0));
            let _ = EndPaint(hwnd, &ps);
        }
        _ => return DefWindowProcW(hwnd, msg, wp, lp),
    }
    LRESULT(0)
}

pub(crate) unsafe fn style_button(button: HWND) {
    let _ = SetWindowSubclass(button, Some(button_proc), 1, 0);
}

unsafe extern "system" fn button_proc(
    hwnd: HWND,
    msg: u32,
    wp: WPARAM,
    lp: LPARAM,
    _: usize,
    _: usize,
) -> LRESULT {
    match msg {
        WM_SETCURSOR if IsWindowEnabled(hwnd).as_bool() && crate::editor::set_hand_cursor() => {
            return LRESULT(1);
        }
        WM_MOUSEMOVE => {
            if IsWindowEnabled(hwnd).as_bool() {
                crate::editor::set_hand_cursor();
            }
            let mut tracking = TRACKMOUSEEVENT {
                cbSize: std::mem::size_of::<TRACKMOUSEEVENT>() as u32,
                dwFlags: TME_LEAVE,
                hwndTrack: hwnd,
                dwHoverTime: 0,
            };
            let _ = TrackMouseEvent(&mut tracking);
            let _ = InvalidateRect(hwnd, None, false);
        }
        WM_MOUSELEAVE | WM_ENABLE => {
            let _ = InvalidateRect(hwnd, None, false);
        }
        _ => {}
    }
    DefSubclassProc(hwnd, msg, wp, lp)
}

pub(crate) unsafe fn draw_button(lp: LPARAM, primary: bool, panel: COLORREF) -> LRESULT {
    let Some(item) = (lp.0 as *const DRAWITEMSTRUCT).as_ref() else {
        return LRESULT(0);
    };
    if item.rcItem.right - item.rcItem.left <= 2 || item.rcItem.bottom - item.rcItem.top <= 2 {
        return LRESULT(1);
    }
    let state = item.itemState;
    let mut pointer = windows::Win32::Foundation::POINT::default();
    let hovered = GetCursorPos(&mut pointer).is_ok() && WindowFromPoint(pointer) == item.hwndItem;
    let (background, border, foreground) = if state.0 & ODS_DISABLED.0 != 0 {
        (0x363332, 0x403d3b, 0x918b87)
    } else if primary {
        let fill = if state.0 & ODS_SELECTED.0 != 0 {
            0x9caa49
        } else if hovered {
            0xc9d581
        } else {
            0xbcc567
        };
        (fill, fill, 0x2b3020)
    } else {
        let fill = if state.0 & ODS_SELECTED.0 != 0 {
            0x514c49
        } else if hovered {
            0x474340
        } else {
            0x363332
        };
        (fill, 0x55504c, 0xf3efed)
    };
    SetDCBrushColor(item.hDC, panel);
    FillRect(item.hDC, &item.rcItem, HBRUSH(GetStockObject(DC_BRUSH).0));
    let mut bounds = RECT {
        left: item.rcItem.left + 1,
        top: item.rcItem.top + 1,
        right: item.rcItem.right - 1,
        bottom: item.rcItem.bottom - 1,
    };
    crate::settings_window::rounded(
        item.hDC,
        bounds,
        12,
        COLORREF(background),
        COLORREF(if state.0 & ODS_FOCUS.0 != 0 {
            0xece9e6
        } else {
            border
        }),
    );
    let font = SendMessageW(item.hwndItem, WM_GETFONT, WPARAM(0), LPARAM(0));
    let old = if font.0 != 0 {
        Some(SelectObject(item.hDC, HFONT(font.0 as _)))
    } else {
        None
    };
    SetBkMode(item.hDC, TRANSPARENT);
    SetTextColor(item.hDC, COLORREF(foreground));
    let mut text = [0u16; 40];
    let len = GetWindowTextW(item.hwndItem, &mut text).max(0) as usize;
    DrawTextW(
        item.hDC,
        &mut text[..len],
        &mut bounds,
        DT_CENTER | DT_VCENTER | DT_SINGLELINE,
    );
    if let Some(old) = old {
        SelectObject(item.hDC, old);
    }
    LRESULT(1)
}
