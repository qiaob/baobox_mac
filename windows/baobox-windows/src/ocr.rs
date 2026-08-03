//! 屏幕取字（Windows）。
//!
//! 用系统自带的 `Windows.Media.Ocr` —— Win10 起就有，**不需要用户装任何东西**，
//! 这一点比 Linux 那边外挂 tesseract 舒服得多。识别语言跟随系统的
//! 「首选语言」列表：装了中文语言包就能识别中文。
//!
//! # 为什么还要绕 `baobox_core::ocr::assemble`
//!
//! `OcrResult` 自带一个 `Text()`，直接拿来用最省事 —— 但那是 **Windows 的排版规则**，
//! 与 macOS 的 Vision、Linux 的 tesseract 各不相同，同一张图会复制出三种结果。
//! 所以这里只取「词 + 位置」，拼接交给共用的那份规则。
//!
//! # 尺寸下限
//!
//! `OcrEngine` 拒绝太小的图（长宽都得 ≥ 40）。用户框一个词的时候很容易低于这个数，
//! 所以提前检查并说人话，而不是把 WinRT 的 HRESULT 原样吐出来。
//!
//! # 只有真正碰 WinRT 的部分加 `cfg(windows)`
//!
//! 尺寸检查与像素换算是纯计算，放在门外面，这样它们的测试在开发机上也跑得到。

#[cfg(windows)]
use baobox_core::geometry::Rect;
#[cfg(windows)]
use baobox_core::ocr::{assemble, TextBlock};
#[cfg(windows)]
use windows::Graphics::Imaging::{BitmapPixelFormat, SoftwareBitmap};
#[cfg(windows)]
use windows::Media::Ocr::OcrEngine;
#[cfg(windows)]
use windows::Storage::Streams::DataWriter;

/// `OcrEngine` 能接受的最小边长。
pub const MIN_SIDE: u32 = 40;

/// `OcrEngine` 能接受的最大边长。
pub const MAX_SIDE: u32 = 10_000;

/// 识别一块 RGBA 图像里的文字。
#[cfg(windows)]
pub fn recognize(rgba: &[u8], width: u32, height: u32) -> Result<String, String> {
    check_size(width, height)?;

    let bgra = to_bgra(rgba);
    let writer = DataWriter::new().map_err(|e| format!("创建缓冲失败：{e}"))?;
    writer
        .WriteBytes(&bgra)
        .map_err(|e| format!("写入缓冲失败：{e}"))?;
    let buffer = writer
        .DetachBuffer()
        .map_err(|e| format!("取出缓冲失败：{e}"))?;

    let bitmap = SoftwareBitmap::CreateCopyFromBuffer(
        &buffer,
        BitmapPixelFormat::Bgra8,
        width as i32,
        height as i32,
    )
    .map_err(|e| format!("构造位图失败：{e}"))?;

    // 跟随系统首选语言。没有任何可用语言包时这里会失败
    let engine = OcrEngine::TryCreateFromUserProfileLanguages().map_err(|e| {
        format!(
            "系统里没有可用的 OCR 语言包（{e}）。\
             在「设置 → 时间和语言 → 语言和区域」里给中文或英文加上「文本识别」可选功能。"
        )
    })?;

    let result = engine
        .RecognizeAsync(&bitmap)
        .and_then(|operation| operation.get())
        .map_err(|e| format!("识别失败：{e}"))?;

    Ok(assemble(&collect_blocks(&result)))
}

/// 把 `OcrResult` 拆成词块。
///
/// 任何一层取不到就跳过 —— WinRT 的每个 getter 都可能失败，
/// 为一个取不到边界的词让整次识别失败没有意义。
#[cfg(windows)]
fn collect_blocks(result: &windows::Media::Ocr::OcrResult) -> Vec<TextBlock> {
    let mut blocks = Vec::new();
    let Ok(lines) = result.Lines() else {
        return blocks;
    };
    for line in lines {
        let Ok(words) = line.Words() else { continue };
        for word in words {
            let (Ok(text), Ok(bounds)) = (word.Text(), word.BoundingRect()) else {
                continue;
            };
            blocks.push(TextBlock {
                text: text.to_string(),
                rect: Rect::new(
                    bounds.X as f64,
                    bounds.Y as f64,
                    bounds.Width as f64,
                    bounds.Height as f64,
                ),
                // Windows 的 OCR 不给逐词置信度；全部当作可信，
                // 过滤交给 assemble 里的空白判断
                confidence: 1.0,
            });
        }
    }
    blocks
}

/// 尺寸检查。太小 / 太大都提前说清楚。
pub fn check_size(width: u32, height: u32) -> Result<(), String> {
    if width < MIN_SIDE || height < MIN_SIDE {
        return Err(format!(
            "选区太小（{width}×{height}）。系统的识别引擎要求长宽都不小于 {MIN_SIDE} 像素，请框大一点。"
        ));
    }
    if width > MAX_SIDE || height > MAX_SIDE {
        return Err(format!(
            "选区太大（{width}×{height}）。系统的识别引擎最多处理 {MAX_SIDE} 像素，请分几次框。"
        ));
    }
    Ok(())
}

/// RGBA → BGRA。`SoftwareBitmap` 的 `Bgra8` 就是这个顺序，弄反了不会报错，
/// 只是识别率莫名其妙地差 —— 因为红蓝互换后文字与背景的对比度变了。
fn to_bgra(rgba: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(rgba.len());
    for pixel in rgba.chunks_exact(4) {
        out.extend_from_slice(&[pixel[2], pixel[1], pixel[0], pixel[3]]);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channels_are_swapped_for_the_bgra_bitmap() {
        assert_eq!(to_bgra(&[1, 2, 3, 4]), vec![3, 2, 1, 4]);
    }

    #[test]
    fn sizes_outside_the_engines_range_are_refused_with_an_explanation() {
        let small = check_size(30, 100).unwrap_err();
        assert!(small.contains("太小"));
        assert!(small.contains("40"), "要说清楚下限是多少");

        assert!(check_size(100, 20).is_err(), "高度也要检查");
        assert!(check_size(40, 40).is_ok(), "刚好到下限应当放行");
        assert!(check_size(20_000, 100).unwrap_err().contains("太大"));
    }
}
