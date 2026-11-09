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

/// 写入数据时必须给剪贴板一个本进程的窗口作为所有者。
unsafe fn publish(format: u32, handle: HGLOBAL) -> Result<(), String> {
    use windows::core::w;
    use windows::Win32::UI::WindowsAndMessaging::{CreateWindowExW, DestroyWindow, HWND_MESSAGE};
    let result = (|| {
        let owner = CreateWindowExW(
            Default::default(),
            w!("STATIC"),
            None,
            Default::default(),
            0,
            0,
            0,
            0,
            HWND_MESSAGE,
            None,
            None,
            None,
        )
        .map_err(|e| format!("创建剪贴板所有者失败：{e}"))?;
        let result = (|| {
            for attempt in 0..8 {
                match OpenClipboard(owner) {
                    Ok(()) => {
                        let result = EmptyClipboard()
                            .and_then(|()| SetClipboardData(format, HANDLE(handle.0)));
                        let _ = CloseClipboard();
                        return result
                            .map(|_| ())
                            .map_err(|e| format!("写入剪贴板失败：{e}"));
                    }
                    Err(e) if attempt == 7 => return Err(format!("无法打开剪贴板：{e}")),
                    Err(_) => std::thread::sleep(std::time::Duration::from_millis(20)),
                }
            }
            unreachable!()
        })();
        let _ = DestroyWindow(owner);
        result
    })();
    if result.is_err() {
        let _ = GlobalFree(handle);
    }
    result
}

fn copy_bytes(format: u32, bytes: &[u8]) -> Result<(), String> {
    unsafe {
        let handle = GlobalAlloc(GMEM_MOVEABLE, bytes.len())
            .map_err(|e| format!("分配剪贴板内存失败：{e}"))?;
        let pointer = GlobalLock(handle);
        if pointer.is_null() {
            let _ = GlobalFree(handle);
            return Err("锁定剪贴板内存失败".into());
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), pointer.cast(), bytes.len());
        let _ = GlobalUnlock(handle);
        publish(format, handle)
    }
}

pub fn copy_text(text: &str) -> Result<(), String> {
    let bytes: Vec<u8> = text
        .encode_utf16()
        .chain(Some(0))
        .flat_map(u16::to_le_bytes)
        .collect();
    copy_bytes(CF_UNICODETEXT, &bytes)
}

pub fn copy_files(paths: &str) -> Result<(), String> {
    // DROPFILES: offset, POINT, fNC, fWide. Paths end with a double NUL.
    let mut bytes = [20u32, 0, 0, 0, 1]
        .into_iter()
        .flat_map(u32::to_le_bytes)
        .collect::<Vec<_>>();
    for path in paths.lines().filter(|path| !path.is_empty()) {
        bytes.extend(
            path.encode_utf16()
                .chain(Some(0))
                .flat_map(u16::to_le_bytes),
        );
    }
    if bytes.len() == 20 {
        return Err("文件列表为空".into());
    }
    bytes.extend([0, 0]);
    copy_bytes(15, &bytes)
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

        publish(CF_DIB, handle)
    }
}
