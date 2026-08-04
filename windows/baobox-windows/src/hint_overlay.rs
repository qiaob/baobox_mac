//! 标签覆盖层（Windows）：把字母标签画在所有窗口之上，收键盘。
//!
//! 交互规则全在 `baobox_core::hints::Session`，这里只做两件事：
//! 把标签画出来、把按键喂给它。
//!
//! # 分层窗口 + color key，与截图覆盖层同一个套路
//!
//! 全屏铺一个 `WS_EX_LAYERED` 窗口，底色刷成一个约定的「透明色」，
//! 再用 `LWA_COLORKEY` 让那个颜色整片透过去。标签就画在这块布上。
//!
//! # 必须自己抢焦点
//!
//! 覆盖层是快捷键唤起的，不 `SetForegroundWindow` 的话它开在别人后面，
//! 而且**收不到键盘** —— 用户打的字会全落到原来那个程序里去，
//! 那可能是一个正在编辑的文档。

#![cfg(windows)]

use baobox_core::hints::{Hint, Outcome, Session};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, InvalidateRect, CreateFontW, CreateSolidBrush, DeleteObject, EndPaint, FillRect, SelectObject,
    SetBkMode, SetTextColor, TextOutW, DEFAULT_CHARSET, DEFAULT_PITCH, FF_DONTCARE, FW_BOLD,
    OUT_DEFAULT_PRECIS, PAINTSTRUCT, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetMessageW,
    GetWindowLongPtrW, LoadCursorW, PostQuitMessage, RegisterClassW,
    SetForegroundWindow, SetLayeredWindowAttributes, SetWindowLongPtrW, ShowWindow,
    TranslateMessage, UnregisterClassW, GWLP_USERDATA, IDC_ARROW, LWA_COLORKEY, MSG, SW_SHOW,
    WM_CHAR, WM_DESTROY, WM_KEYDOWN, WM_PAINT, WNDCLASSW, WS_EX_LAYERED, WS_EX_TOOLWINDOW,
    WS_EX_TOPMOST, WS_POPUP, WS_VISIBLE,
};

/// 覆盖层窗口类名。
const CLASS_NAME: PCWSTR = w!("BaoboxHintOverlay");

/// 被当成「透过去」的颜色。
///
/// 挑一个真实界面里几乎不会出现的品红：标签底板万一用到它就会被挖穿。
const TRANSPARENT_KEY: u32 = 0x00FF_00FF;

/// 标签底板的颜色（与设计稿的 accent 同色，BGR 序）。
const ACCENT: u32 = 0x0098_A317;
/// 没匹配上的标签底板。
const DIMMED: u32 = 0x0059_5959;

/// 标签底板的内边距与字号。
const PAD: i32 = 3;
const FONT_SIZE: i32 = 15;

/// 虚拟键码。
const VK_ESCAPE: u32 = 0x1B;
const VK_BACK: u32 = 0x08;

struct OverlayState {
    session: Session,
    picked: Vec<Hint>,
    origin: (i32, i32),
    done: bool,
}

/// 跑一整场：显示标签、收键盘，返回用户点掉的那些。
pub fn run(session: &mut Session) -> Result<Vec<Hint>, String> {
    unsafe {
        let instance: HINSTANCE = GetModuleHandleW(None)
            .map_err(|e| format!("GetModuleHandle 失败：{e}"))?
            .into();
        let class = WNDCLASSW {
            lpfnWndProc: Some(wndproc),
            hInstance: instance,
            lpszClassName: CLASS_NAME,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            ..Default::default()
        };
        RegisterClassW(&class);

        let screen = crate::gdi::virtual_screen();
        let mut state = Box::new(OverlayState {
            session: session.clone(),
            picked: Vec::new(),
            origin: (screen.x as i32, screen.y as i32),
            done: false,
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
        .map_err(|e| format!("创建覆盖层失败：{e}"))?;

        // 那个颜色整片透过去；其余部分照常画
        let _ = SetLayeredWindowAttributes(hwnd, COLORREF(TRANSPARENT_KEY), 255, LWA_COLORKEY);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, state.as_mut() as *mut OverlayState as isize);
        let _ = ShowWindow(hwnd, SW_SHOW);
        // 不抢焦点的话，用户打的字会全落到原来那个程序里去 ——
        // 那可能是一个正在编辑的文档
        let _ = SetForegroundWindow(hwnd);

        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
            if state.done {
                break;
            }
        }

        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        let _ = DestroyWindow(hwnd);
        let _ = UnregisterClassW(CLASS_NAME, instance);
        Ok(std::mem::take(&mut state.picked))
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
        WM_PAINT => {
            let mut paint = PAINTSTRUCT::default();
            let dc = BeginPaint(hwnd, &mut paint);
            draw(dc, state);
            let _ = EndPaint(hwnd, &paint);
            LRESULT(0)
        }
        WM_KEYDOWN => {
            match wparam.0 as u32 {
                VK_ESCAPE => state.done = true,
                VK_BACK => {
                    if state.session.backspace() == Outcome::Cancel {
                        state.done = true;
                    }
                    let _ = InvalidateRect(hwnd, None, true);
                }
                _ => {}
            }
            LRESULT(0)
        }
        WM_CHAR => {
            // 用 WM_CHAR 而不是 WM_KEYDOWN 拿字母：后者给的是虚拟键码，
            // 换个键盘布局就对不上了
            if let Some(c) = char::from_u32(wparam.0 as u32) {
                match state.session.push(c) {
                    Outcome::Activate(hit) => {
                        state.picked.push(hit);
                        if !state.session.is_continuous() {
                            state.done = true;
                        }
                    }
                    Outcome::Cancel => state.done = true,
                    Outcome::Filtering(_) => {}
                }
                let _ = InvalidateRect(hwnd, None, true);
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            state.done = true;
            PostQuitMessage(0);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

/// 把标签画出来。
unsafe fn draw(dc: windows::Win32::Graphics::Gdi::HDC, state: &OverlayState) {
    use windows::Win32::Graphics::Gdi::HBRUSH;

    // 整块布先刷成「透明色」，标签之外的地方就全透过去了
    let backdrop: HBRUSH = CreateSolidBrush(COLORREF(TRANSPARENT_KEY));
    let screen = crate::gdi::virtual_screen();
    let full = RECT {
        left: 0,
        top: 0,
        right: screen.w as i32,
        bottom: screen.h as i32,
    };
    FillRect(dc, &full, backdrop);
    let _ = DeleteObject(backdrop);

    let font = CreateFontW(
        FONT_SIZE,
        0,
        0,
        0,
        FW_BOLD.0 as i32,
        0,
        0,
        0,
        DEFAULT_CHARSET.0.into(),
        OUT_DEFAULT_PRECIS.0.into(),
        Default::default(),
        Default::default(),
        (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
        w!("Consolas"),
    );
    let previous = SelectObject(dc, font);
    SetBkMode(dc, TRANSPARENT);

    let typed = state.session.typed();
    let accent: HBRUSH = CreateSolidBrush(COLORREF(ACCENT));
    let dimmed: HBRUSH = CreateSolidBrush(COLORREF(DIMMED));

    for hint in state.session.hints() {
        let dim = !hint.tag.starts_with(typed);
        let chars = hint.tag.chars().count() as i32;
        // 等宽字体，宽度按字符数估 —— 差一两个像素不影响可读性
        let w = chars * (FONT_SIZE * 6 / 10) + PAD * 2;
        let h = FONT_SIZE + PAD * 2;
        // 屏幕坐标 → 窗口坐标：虚拟屏幕的原点不一定是 (0,0)
        let x = hint.target.x.round() as i32 - state.origin.0 - w / 2;
        let y = hint.target.y.round() as i32 - state.origin.1 - h / 2;

        let rect = RECT {
            left: x,
            top: y,
            right: x + w,
            bottom: y + h,
        };
        FillRect(dc, &rect, if dim { dimmed } else { accent });
        // 没匹配上的淡出去而不是不画 —— 全都还在，用户才看得出
        // 「我打的这个字缩小了多少范围」
        SetTextColor(dc, COLORREF(if dim { 0x00AA_AAAA } else { 0x00FF_FFFF }));
        let wide: Vec<u16> = hint.tag.encode_utf16().collect();
        let _ = TextOutW(dc, x + PAD, y + PAD, &wide);
    }

    let _ = DeleteObject(accent);
    let _ = DeleteObject(dimmed);
    SelectObject(dc, previous);
    let _ = DeleteObject(font);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_transparent_key_is_a_colour_no_real_ui_uses() {
        // 标签底板万一用到它就会被挖穿
        assert_ne!(TRANSPARENT_KEY, ACCENT);
        assert_ne!(TRANSPARENT_KEY, DIMMED);
        assert_ne!(TRANSPARENT_KEY, 0x0000_0000, "黑色到处都是");
        assert_ne!(TRANSPARENT_KEY, 0x00FF_FFFF, "白色到处都是");
    }

    #[test]
    fn the_label_stays_readable() {
        assert!(PAD > 0);
        assert!(FONT_SIZE >= 10, "太小的话密密麻麻一片看不清");
    }
}
