//! 把截图放进 Windows 剪贴板。
//!
//! 用 `CF_DIB`：兼容性最好，从记事本到 Photoshop 都认。不用 `CF_DIBV5`（带 alpha）
//! 是因为不少程序对它的 alpha 处理各不相同，截图本来就不透明，为此冒兼容性风险不值。
//!
//! DIB 的两个约定容易踩错：像素是 **BGRA 顺序**，且**自下而上**存放。

#![cfg(windows)]

use windows::Win32::Foundation::{GlobalFree, HANDLE, HGLOBAL};
use windows::Win32::Graphics::Gdi::{BITMAPINFOHEADER, BI_RGB};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};

/// `CF_DIB` 的剪贴板格式号。
const CF_DIB: u32 = 8;

/// `CF_UNICODETEXT` 的剪贴板格式号。
///
/// 不用 `CF_TEXT`：那是 ANSI 代码页，中文在非中文系统上会变成问号。
const CF_UNICODETEXT: u32 = 13;

/// 把一段文字放进剪贴板（屏幕取字用）。
pub fn copy_text(text: &str) -> Result<(), String> {
    // Windows 要求以 NUL 结尾的 UTF-16
    let mut encoded: Vec<u16> = text.encode_utf16().collect();
    encoded.push(0);
    let bytes = encoded.len() * 2;

    unsafe {
        let handle: HGLOBAL =
            GlobalAlloc(GMEM_MOVEABLE, bytes).map_err(|e| format!("分配剪贴板内存失败：{e}"))?;
        let pointer = GlobalLock(handle);
        if pointer.is_null() {
            let _ = GlobalFree(handle);
            return Err("锁定剪贴板内存失败".to_string());
        }
        std::ptr::copy_nonoverlapping(encoded.as_ptr(), pointer as *mut u16, encoded.len());
        let _ = GlobalUnlock(handle);

        if OpenClipboard(None).is_err() {
            let _ = GlobalFree(handle);
            return Err("无法打开剪贴板（可能被其他程序占用）".to_string());
        }
        let _ = EmptyClipboard();
        let result = SetClipboardData(CF_UNICODETEXT, HANDLE(handle.0));
        let _ = CloseClipboard();

        match result {
            // 成功即交出所有权，绝不能再 GlobalFree
            Ok(_) => Ok(()),
            Err(e) => {
                let _ = GlobalFree(handle);
                Err(format!("写入剪贴板失败：{e}"))
            }
        }
    }
}

/// 把 RGBA 图像放进剪贴板。
pub fn copy_rgba(width: u32, height: u32, rgba: &[u8]) -> Result<(), String> {
    let expected = width as usize * height as usize * 4;
    if rgba.len() != expected || width == 0 || height == 0 {
        return Err("图像数据不完整，无法复制".to_string());
    }

    let header_size = std::mem::size_of::<BITMAPINFOHEADER>();
    let total = header_size + expected;

    unsafe {
        let handle: HGLOBAL =
            GlobalAlloc(GMEM_MOVEABLE, total).map_err(|e| format!("分配剪贴板内存失败：{e}"))?;
        let pointer = GlobalLock(handle);
        if pointer.is_null() {
            let _ = GlobalFree(handle);
            return Err("锁定剪贴板内存失败".to_string());
        }

        // 头
        let header = BITMAPINFOHEADER {
            biSize: header_size as u32,
            biWidth: width as i32,
            biHeight: height as i32, // 正数 = 自下而上
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            biSizeImage: expected as u32,
            ..Default::default()
        };
        std::ptr::write_unaligned(pointer as *mut BITMAPINFOHEADER, header);

        // 像素：RGBA → BGRA，并逐行翻转
        let pixels = (pointer as *mut u8).add(header_size);
        let stride = width as usize * 4;
        for row in 0..height as usize {
            let src = (height as usize - 1 - row) * stride;
            let dst = row * stride;
            for column in 0..width as usize {
                let s = src + column * 4;
                let d = dst + column * 4;
                *pixels.add(d) = rgba[s + 2]; // B
                *pixels.add(d + 1) = rgba[s + 1]; // G
                *pixels.add(d + 2) = rgba[s]; // R
                *pixels.add(d + 3) = rgba[s + 3]; // A
            }
        }
        let _ = GlobalUnlock(handle);

        if OpenClipboard(None).is_err() {
            let _ = GlobalFree(handle);
            return Err("无法打开剪贴板（可能被其他程序占用）".to_string());
        }
        let _ = EmptyClipboard();
        // 交给系统之后**不能再 free** —— 所有权已经转移，free 会导致其他程序读到野指针
        let result = SetClipboardData(CF_DIB, HANDLE(handle.0));
        let _ = CloseClipboard();

        match result {
            Ok(_) => Ok(()),
            Err(e) => {
                // 设置失败时所有权仍在我们手上，要还回去
                let _ = GlobalFree(handle);
                Err(format!("写入剪贴板失败：{e}"))
            }
        }
    }
}
