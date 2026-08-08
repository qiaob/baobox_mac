//! 读剪贴板，以及在它变化时收到通知（Windows）。
//!
//! 与 Linux 那边比，这里简单得多：剪贴板由系统托管，
//! `AddClipboardFormatListener` 会在内容变化时给我们发 `WM_CLIPBOARDUPDATE`，
//! 不需要 XFIXES、不需要 INCR 分片、不需要跟所有者往返。
//!
//! # 三个必须做对的地方
//!
//! 1. **`OpenClipboard` 之后一定要 `CloseClipboard`**：剪贴板是全局独占的，
//!    开着不关会让整个系统的复制粘贴都卡住。
//! 2. **别人也在用**：`OpenClipboard` 会失败（另一个程序正开着），要重试几次。
//! 3. **`GetClipboardData` 返回的句柄不归我们**，绝不能释放，也不能在
//!    `CloseClipboard` 之后继续用 —— 必须在关之前把内容拷出来。

#![cfg(windows)]

use windows::Win32::Foundation::{HGLOBAL, HWND};
use windows::Win32::System::DataExchange::{
    AddClipboardFormatListener, CloseClipboard, GetClipboardData, IsClipboardFormatAvailable,
    OpenClipboard, RemoveClipboardFormatListener,
};
use windows::Win32::System::Memory::{GlobalLock, GlobalSize, GlobalUnlock};

/// `CF_UNICODETEXT`。
const CF_UNICODETEXT: u32 = 13;
/// `CF_DIB`。
const CF_DIB: u32 = 8;
/// `CF_HDROP`（拖放 / 复制文件）。
const CF_HDROP: u32 = 15;

/// 打不开剪贴板时重试几次。别的程序可能正开着它。
const OPEN_ATTEMPTS: u32 = 8;

/// 每次重试之间等多久。
const OPEN_RETRY: std::time::Duration = std::time::Duration::from_millis(20);

/// 剪贴板里读到了什么。
#[derive(Debug, Clone, PartialEq)]
pub enum Content {
    /// 一段文本
    Text(String),
    /// 一张位图（DIB 原始字节，含 `BITMAPINFOHEADER`）
    Dib(Vec<u8>),
    /// 一批文件路径
    Files(Vec<String>),
    /// 空的，或者是我们不认的格式
    Nothing,
}

/// 订阅剪贴板变化。窗口会开始收到 `WM_CLIPBOARDUPDATE`。
pub fn listen(hwnd: HWND) -> Result<(), String> {
    unsafe {
        AddClipboardFormatListener(hwnd).map_err(|e| format!("订阅剪贴板变化失败：{e}"))
    }
}

/// 取消订阅。
pub fn unlisten(hwnd: HWND) {
    unsafe {
        let _ = RemoveClipboardFormatListener(hwnd);
    }
}

/// 把剪贴板内容读出来。
///
/// 优先级：**文件 → 图片 → 文本**。
///
/// 文件必须排在图片前面：在资源管理器里复制一个图片**文件**时，Explorer
/// 会同时放一份渲染好的 `CF_DIB` —— 先取图的话「复制的文件」会被记成一张图，
/// 文件名与路径全丢。图片仍在文本之前：很多程序复制图片时**同时**提供
/// 一段说明文字，只取文本的话用户会发现「复制的图变成了一串字」。
pub fn read(hwnd: HWND) -> Content {
    unsafe {
        if !open(hwnd) {
            return Content::Nothing;
        }
        // 无论走哪条分支都必须关掉 —— 开着不关会卡住整个系统的复制粘贴
        let content = read_opened();
        let _ = CloseClipboard();
        content
    }
}

/// 剪贴板是全局独占的，别人正开着时会失败，重试几次。
unsafe fn open(hwnd: HWND) -> bool {
    for _ in 0..OPEN_ATTEMPTS {
        if OpenClipboard(hwnd).is_ok() {
            return true;
        }
        std::thread::sleep(OPEN_RETRY);
    }
    false
}

unsafe fn read_opened() -> Content {
    if IsClipboardFormatAvailable(CF_HDROP).is_ok() {
        let paths = files();
        if !paths.is_empty() {
            return Content::Files(paths);
        }
    }
    if IsClipboardFormatAvailable(CF_DIB).is_ok() {
        if let Some(bytes) = bytes_of(CF_DIB) {
            if !bytes.is_empty() {
                return Content::Dib(bytes);
            }
        }
    }
    if IsClipboardFormatAvailable(CF_UNICODETEXT).is_ok() {
        if let Some(text) = text() {
            if !text.is_empty() {
                return Content::Text(text);
            }
        }
    }
    Content::Nothing
}

/// 读一段 UTF-16 文本。
unsafe fn text() -> Option<String> {
    let handle = GetClipboardData(CF_UNICODETEXT).ok()?;
    let global = HGLOBAL(handle.0);
    let pointer = GlobalLock(global) as *const u16;
    if pointer.is_null() {
        return None;
    }
    // 以 NUL 结尾，长度得自己数
    let mut length = 0usize;
    while *pointer.add(length) != 0 {
        length += 1;
    }
    let slice = std::slice::from_raw_parts(pointer, length);
    let text = String::from_utf16_lossy(slice);
    let _ = GlobalUnlock(global);
    Some(text)
}

/// 把某个格式的原始字节拷出来。
///
/// **必须拷贝**：句柄不归我们，`CloseClipboard` 之后就不能再碰了。
unsafe fn bytes_of(format: u32) -> Option<Vec<u8>> {
    let handle = GetClipboardData(format).ok()?;
    let global = HGLOBAL(handle.0);
    let size = GlobalSize(global);
    if size == 0 {
        return None;
    }
    let pointer = GlobalLock(global) as *const u8;
    if pointer.is_null() {
        return None;
    }
    let bytes = std::slice::from_raw_parts(pointer, size).to_vec();
    let _ = GlobalUnlock(global);
    Some(bytes)
}

/// 读 `CF_HDROP` 里的文件路径。
unsafe fn files() -> Vec<String> {
    use windows::Win32::UI::Shell::{DragQueryFileW, HDROP};
    let Ok(handle) = GetClipboardData(CF_HDROP) else {
        return Vec::new();
    };
    let drop = HDROP(handle.0);
    // 传 u32::MAX 作为下标是「问总数」的约定写法
    let count = DragQueryFileW(drop, u32::MAX, None);
    let mut paths = Vec::with_capacity(count as usize);
    for index in 0..count {
        let length = DragQueryFileW(drop, index, None);
        if length == 0 {
            continue;
        }
        // +1 给结尾的 NUL
        let mut buffer = vec![0u16; length as usize + 1];
        let written = DragQueryFileW(drop, index, Some(&mut buffer));
        if written > 0 {
            paths.push(String::from_utf16_lossy(&buffer[..written as usize]));
        }
    }
    paths
}

/// DIB 字节 → RGBA 像素。
///
/// 剪贴板里的图是 DIB（`BITMAPINFOHEADER` + 像素），而我们要存成 PNG。
/// 两个坑：**自下而上**（`biHeight` 为正时）与**不可信的 alpha**
/// （很多程序把 alpha 全填 0，直接用的话整张图透明）。
pub fn dib_to_rgba(dib: &[u8]) -> Option<(u32, u32, Vec<u8>)> {
    // BITMAPINFOHEADER 至少 40 字节
    if dib.len() < 40 {
        return None;
    }
    let read_i32 = |at: usize| -> i32 {
        i32::from_le_bytes([dib[at], dib[at + 1], dib[at + 2], dib[at + 3]])
    };
    let header_size = read_i32(0) as usize;
    let width = read_i32(4);
    let height_raw = read_i32(8);
    let bit_count = u16::from_le_bytes([dib[14], dib[15]]);
    if width <= 0 || height_raw == 0 || !(24..=32).contains(&bit_count) {
        return None;
    }
    let bottom_up = height_raw > 0;
    let height = height_raw.unsigned_abs();
    let bytes_per_pixel = (bit_count / 8) as usize;
    // 每行按 4 字节对齐
    let stride = ((width as usize * bytes_per_pixel) + 3) & !3;
    let offset = header_size.max(40);
    let needed = offset + stride * height as usize;
    if dib.len() < needed {
        return None;
    }

    let mut rgba = Vec::with_capacity(width as usize * height as usize * 4);
    for row in 0..height as usize {
        let source_row = if bottom_up {
            height as usize - 1 - row
        } else {
            row
        };
        let start = offset + source_row * stride;
        for column in 0..width as usize {
            let at = start + column * bytes_per_pixel;
            rgba.push(dib[at + 2]); // R
            rgba.push(dib[at + 1]); // G
            rgba.push(dib[at]); // B
            // alpha 不可信：很多程序填 0，直接用的话整张图透明
            rgba.push(255);
        }
    }
    Some((width as u32, height, rgba))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 造一份最小的 DIB：宽 2 高 2，24 位，自下而上。
    fn tiny_dib(bottom_up: bool) -> Vec<u8> {
        let mut dib = vec![0u8; 40];
        dib[0] = 40; // biSize
        dib[4] = 2; // biWidth
        let height: i32 = if bottom_up { 2 } else { -2 };
        dib[8..12].copy_from_slice(&height.to_le_bytes());
        dib[14] = 24; // biBitCount
        // 两行像素，每行 2 个 BGR = 6 字节，补齐到 8
        // 第一行（内存里的）：红、绿
        dib.extend_from_slice(&[0, 0, 255, 0, 255, 0, 0, 0]);
        // 第二行：蓝、白
        dib.extend_from_slice(&[255, 0, 0, 255, 255, 255, 0, 0]);
        dib
    }

    #[test]
    fn a_bottom_up_dib_is_flipped_so_the_image_is_not_upside_down() {
        let (w, h, rgba) = dib_to_rgba(&tiny_dib(true)).unwrap();
        assert_eq!((w, h), (2, 2));
        // 自下而上：内存里的最后一行是图像的第一行 → 左上角应当是蓝色
        assert_eq!(&rgba[0..4], &[0, 0, 255, 255]);
    }

    #[test]
    fn a_top_down_dib_is_left_alone() {
        let (_, _, rgba) = dib_to_rgba(&tiny_dib(false)).unwrap();
        // 自上而下：内存里的第一行就是图像第一行 → 左上角是红色
        assert_eq!(&rgba[0..4], &[255, 0, 0, 255]);
    }

    #[test]
    fn alpha_is_forced_opaque_because_the_source_cannot_be_trusted() {
        // 很多程序把 alpha 全填 0，直接用的话整张图在预览里消失
        let (_, _, rgba) = dib_to_rgba(&tiny_dib(true)).unwrap();
        assert!(rgba.chunks_exact(4).all(|p| p[3] == 255));
    }

    #[test]
    fn malformed_dibs_are_refused_rather_than_panicking() {
        assert!(dib_to_rgba(&[]).is_none());
        assert!(dib_to_rgba(&[0u8; 39]).is_none());
        // 头说有像素，实际没有
        let mut truncated = tiny_dib(true);
        truncated.truncate(40);
        assert!(dib_to_rgba(&truncated).is_none());
        // 宽为 0
        let mut zero = tiny_dib(true);
        zero[4] = 0;
        assert!(dib_to_rgba(&zero).is_none());
    }

    #[test]
    fn odd_widths_respect_the_four_byte_row_padding() {
        // 每行按 4 字节对齐；忘了这条的话图会一行比一行斜
        let mut dib = vec![0u8; 40];
        dib[0] = 40;
        dib[4] = 1; // 宽 1 → 3 字节，补齐到 4
        dib[8..12].copy_from_slice(&1i32.to_le_bytes());
        dib[14] = 24;
        dib.extend_from_slice(&[10, 20, 30, 0]);
        let (w, h, rgba) = dib_to_rgba(&dib).unwrap();
        assert_eq!((w, h), (1, 1));
        assert_eq!(rgba, vec![30, 20, 10, 255]);
    }

    #[test]
    fn opening_is_retried_because_another_app_may_hold_the_clipboard() {
        assert!(OPEN_ATTEMPTS > 1, "剪贴板是全局独占的，一次打不开很正常");
        assert!(OPEN_ATTEMPTS * OPEN_RETRY.as_millis() as u32 <= 500, "重试总时长不该让界面卡顿");
    }
}
