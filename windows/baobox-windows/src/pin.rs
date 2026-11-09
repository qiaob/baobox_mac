//! 贴图：把截图钉在屏幕最上层（Windows）。
//!
//! 与 Linux 的 `pin.rs` 对应，交互一致：拖动挪位置，任意键 / 右键 / 双击关掉。
//!
//! # 无边框窗口怎么拖
//!
//! 常规做法是在 `WM_NCHITTEST` 里把整个客户区谎报成 `HTCAPTION`，
//! 让系统以为用户在拖标题栏 —— 一行代码就有了完整的拖动手感（含贴边吸附）。
//! 自己在 `WM_MOUSEMOVE` 里算偏移也行，但要处理鼠标捕获、双击、离屏，
//! 何必重写系统已经做对的事。
//!
//! # 为什么用 `WS_EX_TOOLWINDOW`
//!
//! 不加的话贴图会出现在 Alt+Tab 列表和任务栏里 —— 它是一张图，不是一个应用。

#![cfg(windows)]

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, BitBlt, CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, EndPaint,
    GetDC, ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HBITMAP,
    HDC, PAINTSTRUCT, SRCCOPY,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetMessageW,
    GetWindowLongPtrW, IsWindow, LoadCursorW, RegisterClassW, SetWindowLongPtrW, ShowWindow,
    TranslateMessage, CS_DBLCLKS, GWLP_USERDATA, HTCAPTION, IDC_SIZEALL, MSG, SW_SHOWNOACTIVATE,
    WM_CLOSE, WM_KEYDOWN, WM_NCDESTROY, WM_NCHITTEST, WM_NCLBUTTONDBLCLK, WM_NCRBUTTONUP, WM_PAINT,
    WNDCLASSW, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
};

/// 贴图窗口类名。
const CLASS_NAME: PCWSTR = w!("BaoboxPinnedShot");

/// 窗口持有的位图。
struct PinState {
    dc: HDC,
    bitmap: HBITMAP,
    previous: windows::Win32::Graphics::Gdi::HGDIOBJ,
    width: i32,
    height: i32,
}

impl Drop for PinState {
    fn drop(&mut self) {
        unsafe {
            SelectObject(self.dc, self.previous);
            let _ = DeleteObject(self.bitmap);
            let _ = DeleteDC(self.dc);
        }
    }
}

/// 钉一张图到屏幕上，阻塞到用户关掉为止。
///
/// `at` 是初始位置（一般就是截图原来的位置，视觉上「留在原地」）。
pub fn show(at: (i32, i32), rgba: &[u8], width: u32, height: u32) -> Result<(), String> {
    let hwnd = open(at, rgba, width, height)?;
    unsafe {
        let mut message = MSG::default();
        while IsWindow(hwnd).as_bool() && GetMessageW(&mut message, None, 0, 0).0 > 0 {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    Ok(())
}

pub fn open(at: (i32, i32), rgba: &[u8], width: u32, height: u32) -> Result<HWND, String> {
    if width == 0 || height == 0 {
        return Err("贴图尺寸为零".to_string());
    }
    unsafe {
        let instance: HINSTANCE = GetModuleHandleW(None)
            .map_err(|e| format!("GetModuleHandle 失败：{e}"))?
            .into();
        let class = WNDCLASSW {
            // CS_DBLCLKS：不声明就收不到 WM_LBUTTONDBLCLK，双击关不掉
            style: CS_DBLCLKS,
            lpfnWndProc: Some(wndproc),
            hInstance: instance,
            lpszClassName: CLASS_NAME,
            hCursor: LoadCursorW(None, IDC_SIZEALL).unwrap_or_default(),
            ..Default::default()
        };
        RegisterClassW(&class);

        let state = Box::new(create_bitmap(rgba, width, height)?);

        let hwnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
            CLASS_NAME,
            w!("Baobox"),
            WS_POPUP,
            at.0,
            at.1,
            width as i32,
            height as i32,
            None,
            None,
            instance,
            None,
        )
        .map_err(|e| format!("创建贴图窗口失败：{e}"))?;

        SetWindowLongPtrW(hwnd, GWLP_USERDATA, Box::into_raw(state) as isize);
        let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        Ok(hwnd)
    }
}

pub fn close_all() {
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetClassNameW, GetWindowThreadProcessId, PostMessageW,
    };
    unsafe extern "system" fn close(hwnd: HWND, _: LPARAM) -> windows::Win32::Foundation::BOOL {
        let mut pid = 0;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid != std::process::id() {
            return true.into();
        }
        let mut class = [0u16; 32];
        let len = GetClassNameW(hwnd, &mut class).max(0) as usize;
        if class[..len] == *CLASS_NAME.as_wide() {
            let _ = PostMessageW(hwnd, WM_CLOSE, WPARAM(0), LPARAM(0));
        }
        true.into()
    }
    unsafe {
        let _ = EnumWindows(Some(close), LPARAM(0));
    }
}
/// 把 RGBA 灌进一块自上而下的 DIB，留着给 `WM_PAINT` 用。
unsafe fn create_bitmap(rgba: &[u8], width: u32, height: u32) -> Result<PinState, String> {
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
            biHeight: -(height as i32), // 负数 = 自上而下
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

    // SAFETY: CreateDIBSection 保证这块内存有 width*height*4 字节
    let target = std::slice::from_raw_parts_mut(bits.cast::<u8>(), (width * height * 4) as usize);
    let count = target.len().min(rgba.len()) / 4;
    for index in 0..count {
        let at = index * 4;
        target[at] = rgba[at + 2]; // B
        target[at + 1] = rgba[at + 1]; // G
        target[at + 2] = rgba[at]; // R
        target[at + 3] = 0xFF;
    }

    let previous = SelectObject(dc, bitmap);
    Ok(PinState {
        dc,
        bitmap,
        previous,
        width: width as i32,
        height: height as i32,
    })
}

unsafe extern "system" fn wndproc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut PinState;
    if pointer.is_null() {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    let state = &*pointer;

    match message {
        // 把整个客户区谎报成标题栏 —— 于是系统自己负责拖动
        WM_NCHITTEST => LRESULT(HTCAPTION as isize),
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            let hdc = BeginPaint(hwnd, &mut ps);
            let _ = BitBlt(
                hdc,
                0,
                0,
                state.width,
                state.height,
                state.dc,
                0,
                0,
                SRCCOPY,
            );
            let _ = EndPaint(hwnd, &ps);
            LRESULT(0)
        }
        // 三条关掉的路：双击、右键、任意按键
        WM_NCLBUTTONDBLCLK | WM_NCRBUTTONUP | WM_KEYDOWN | WM_CLOSE => {
            let _ = DestroyWindow(hwnd);
            LRESULT(0)
        }
        WM_NCDESTROY => {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            drop(Box::from_raw(pointer));
            DefWindowProcW(hwnd, message, wparam, lparam)
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}
