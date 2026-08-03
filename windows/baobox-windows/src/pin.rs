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
    GetWindowLongPtrW, LoadCursorW, PostQuitMessage, RegisterClassW, SetWindowLongPtrW, ShowWindow,
    TranslateMessage, UnregisterClassW, GWLP_USERDATA, HTCAPTION, IDC_SIZEALL, MSG, SW_SHOW,
    WM_DESTROY, WM_KEYDOWN, WM_LBUTTONDBLCLK, WM_NCHITTEST, WM_PAINT, WM_RBUTTONDOWN, WNDCLASSW,
    CS_DBLCLKS, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP, WS_VISIBLE,
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

        let mut state = Box::new(create_bitmap(rgba, width, height)?);

        let hwnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
            CLASS_NAME,
            w!("Baobox"),
            WS_POPUP | WS_VISIBLE,
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

        SetWindowLongPtrW(hwnd, GWLP_USERDATA, state.as_mut() as *mut PinState as isize);
        let _ = ShowWindow(hwnd, SW_SHOW);

        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }

        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        let _ = DestroyWindow(hwnd);
        let _ = UnregisterClassW(CLASS_NAME, instance);
        Ok(())
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
            let _ = BitBlt(hdc, 0, 0, state.width, state.height, state.dc, 0, 0, SRCCOPY);
            let _ = EndPaint(hwnd, &ps);
            LRESULT(0)
        }
        // 三条关掉的路：双击、右键、任意按键
        WM_LBUTTONDBLCLK | WM_RBUTTONDOWN | WM_KEYDOWN => {
            PostQuitMessage(0);
            LRESULT(0)
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}
