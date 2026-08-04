//! Windows 抓屏与窗口枚举（GDI）。
//!
//! 对应 macOS 侧的 `CaptureEngine` 与 Linux 侧的 `x11capture`。
//!
//! # 为什么用 GDI 而不是 Windows.Graphics.Capture
//!
//! WGC（Windows 10 1903+）性能更好、能抓被遮挡的窗口，但要走 WinRT + D3D11 纹理，
//! 依赖链长得多，而且抓单帧时优势有限。截图是**低频、单帧**的操作，
//! GDI 的 `BitBlt` 足够，且从 Win7 到 Win11 一路可用。
//! 录屏若要做，那时再上 WGC —— 那才是它的主场。
//!
//! # DPI
//!
//! 进程必须先声明 Per-Monitor V2 DPI 感知，否则在缩放的显示器上系统会返回
//! **被拉伸过的虚拟坐标**，抓出来的图是模糊的。`prepare()` 负责这件事，
//! 必须在任何窗口/坐标 API 之前调用。

#![cfg(windows)]

use baobox_core::geometry::Rect;
use windows::core::PCWSTR;
use windows::Win32::Foundation::{BOOL, HWND, LPARAM, RECT, TRUE};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_EXTENDED_FRAME_BOUNDS};
use windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits,
    ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HBITMAP, HDC,
    SRCCOPY,
};
use windows::Win32::UI::HiDpi::{
    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetSystemMetrics, GetWindowTextLengthW, GetWindowTextW, IsIconic, IsWindowVisible,
    SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};

/// 抓取结果，像素为 RGBA8。与 Linux 侧同一形状，便于共用后续流程。
pub struct Capture {
    /// 宽（像素）
    pub width: u32,
    /// 高（像素）
    pub height: u32,
    /// RGBA8，长度 = width * height * 4
    pub rgba: Vec<u8>,
}

/// 一个可见的顶层窗口。
#[derive(Debug, Clone)]
pub struct WindowInfo {
    /// 窗口句柄（以整数形式给 CLI 使用）
    pub id: isize,
    /// 屏幕坐标下的位置与尺寸
    pub frame: Rect,
    /// 标题
    pub title: String,
}

/// 声明 DPI 感知。**必须在任何坐标 / 抓屏调用之前执行一次。**
///
/// 失败不致命（系统太老或已被清单文件设置过），因此只返回是否成功供诊断用。
pub fn prepare() -> bool {
    unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2).is_ok() }
}

/// 整个虚拟屏幕（所有显示器合起来）的范围。
///
/// 注意左上角**不一定是 (0,0)** —— 副屏摆在主屏左边时 x 是负的。
pub fn virtual_screen() -> Rect {
    unsafe {
        Rect::new(
            GetSystemMetrics(SM_XVIRTUALSCREEN) as f64,
            GetSystemMetrics(SM_YVIRTUALSCREEN) as f64,
            GetSystemMetrics(SM_CXVIRTUALSCREEN) as f64,
            GetSystemMetrics(SM_CYVIRTUALSCREEN) as f64,
        )
    }
}

/// 抓一块屏幕区域。区域先裁进虚拟屏幕范围。
pub fn capture(region: Rect) -> Result<Capture, String> {
    let bounds = virtual_screen();
    let clamped = region.clamped_to(&bounds);
    let width = clamped.w.round() as i32;
    let height = clamped.h.round() as i32;
    if width <= 0 || height <= 0 {
        return Err("选区为空".to_string());
    }

    unsafe {
        let screen_dc = GetDC(None);
        if screen_dc.is_invalid() {
            return Err("无法获取屏幕 DC".to_string());
        }
        // 用 guard 保证任何一步失败都能还回去 —— GDI 对象泄漏在长期驻留的进程里是致命的
        let result = capture_inner(screen_dc, &clamped, width, height);
        ReleaseDC(None, screen_dc);
        result
    }
}

unsafe fn capture_inner(
    screen_dc: HDC,
    region: &Rect,
    width: i32,
    height: i32,
) -> Result<Capture, String> {
    let mem_dc = CreateCompatibleDC(screen_dc);
    if mem_dc.is_invalid() {
        return Err("无法创建内存 DC".to_string());
    }
    let bitmap: HBITMAP = CreateCompatibleBitmap(screen_dc, width, height);
    if bitmap.is_invalid() {
        let _ = DeleteDC(mem_dc);
        return Err("无法创建位图".to_string());
    }
    let previous = SelectObject(mem_dc, bitmap);

    let copied = BitBlt(
        mem_dc,
        0,
        0,
        width,
        height,
        screen_dc,
        region.x.round() as i32,
        region.y.round() as i32,
        SRCCOPY,
    );

    let outcome = if copied.is_err() {
        Err("BitBlt 失败".to_string())
    } else {
        read_pixels(mem_dc, bitmap, width, height)
    };

    SelectObject(mem_dc, previous);
    let _ = DeleteObject(bitmap);
    let _ = DeleteDC(mem_dc);
    outcome
}

/// 把位图读成 RGBA8。
///
/// `GetDIBits` 给的是自下而上的 BGRA（`biHeight` 为正时），所以要**逐行翻转**；
/// 把 `biHeight` 设成负数可以要求自上而下，但那在部分驱动上不可靠，
/// 这里显式翻转更稳。
unsafe fn read_pixels(
    dc: HDC,
    bitmap: HBITMAP,
    width: i32,
    height: i32,
) -> Result<Capture, String> {
    let mut info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: height, // 正数 = 自下而上
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };

    let stride = width as usize * 4;
    let mut raw = vec![0u8; stride * height as usize];
    let scanned = GetDIBits(
        dc,
        bitmap,
        0,
        height as u32,
        Some(raw.as_mut_ptr().cast()),
        &mut info,
        DIB_RGB_COLORS,
    );
    if scanned == 0 {
        return Err("GetDIBits 读取失败".to_string());
    }

    let mut rgba = vec![0u8; raw.len()];
    for row in 0..height as usize {
        let src = (height as usize - 1 - row) * stride; // 翻转
        let dst = row * stride;
        for column in 0..width as usize {
            let s = src + column * 4;
            let d = dst + column * 4;
            rgba[d] = raw[s + 2]; // R
            rgba[d + 1] = raw[s + 1]; // G
            rgba[d + 2] = raw[s]; // B
            rgba[d + 3] = 255; // A：GDI 不保证 alpha，统一不透明
        }
    }

    Ok(Capture {
        width: width as u32,
        height: height as u32,
        rgba,
    })
}

/// 枚举可见的顶层窗口（跳过最小化与无标题的）。
pub fn windows() -> Vec<WindowInfo> {
    let mut found: Vec<WindowInfo> = Vec::new();
    unsafe {
        let _ = EnumWindows(
            Some(enum_proc),
            LPARAM(&mut found as *mut Vec<WindowInfo> as isize),
        );
    }
    found
}

unsafe extern "system" fn enum_proc(hwnd: HWND, param: LPARAM) -> BOOL {
    let list = &mut *(param.0 as *mut Vec<WindowInfo>);

    if !IsWindowVisible(hwnd).as_bool() || IsIconic(hwnd).as_bool() {
        return TRUE;
    }
    let title = window_title(hwnd);
    if title.is_empty() {
        return TRUE; // 无标题的多半是工具窗 / 隐藏窗口
    }
    if let Some(frame) = window_frame(hwnd) {
        if frame.w >= 1.0 && frame.h >= 1.0 {
            list.push(WindowInfo {
                id: hwnd.0 as isize,
                frame,
                title,
            });
        }
    }
    TRUE
}

/// 窗口的可见边界。
///
/// 优先 DWM 的 `DWMWA_EXTENDED_FRAME_BOUNDS`：Win10 起 `GetWindowRect` 返回的矩形
/// **包含不可见的阴影边距**，直接拿去截图会在四周多出一圈背景。
///
/// 窗口管理也要它 —— 那边是拿它和 `GetWindowRect` 作差，算出阴影有多厚。
pub fn visible_frame(hwnd: HWND) -> Option<Rect> {
    unsafe { window_frame(hwnd) }
}

unsafe fn window_frame(hwnd: HWND) -> Option<Rect> {
    let mut rect = RECT::default();
    let ok = DwmGetWindowAttribute(
        hwnd,
        DWMWA_EXTENDED_FRAME_BOUNDS,
        &mut rect as *mut RECT as *mut _,
        std::mem::size_of::<RECT>() as u32,
    );
    if ok.is_err() {
        return None;
    }
    Some(Rect::new(
        rect.left as f64,
        rect.top as f64,
        (rect.right - rect.left) as f64,
        (rect.bottom - rect.top) as f64,
    ))
}

unsafe fn window_title(hwnd: HWND) -> String {
    let length = GetWindowTextLengthW(hwnd);
    if length <= 0 {
        return String::new();
    }
    let mut buffer = vec![0u16; length as usize + 1];
    let copied = GetWindowTextW(hwnd, &mut buffer);
    if copied <= 0 {
        return String::new();
    }
    String::from_utf16_lossy(&buffer[..copied as usize])
}

/// 供 CLI 用：把 `PCWSTR` 转成 String（保留给后续窗口查找使用）。
#[allow(dead_code)]
pub unsafe fn pcwstr_to_string(value: PCWSTR) -> String {
    if value.is_null() {
        return String::new();
    }
    value.to_string().unwrap_or_default()
}
