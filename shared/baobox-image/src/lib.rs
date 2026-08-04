//! Baobox 共享图像层。
//!
//! 三个平台的抓屏结果统一为 RGBA8 之后走这里落盘，因此在哪个系统上截出来的 PNG
//! 格式完全一致。灰度转换供长截屏拼接使用（`baobox_core::stitch` 吃的是灰度）。

#![forbid(unsafe_code)]

use std::fs::File;
use std::io::BufWriter;
use std::path::Path;

/// 把 RGBA8 缓冲编码成 PNG 字节流（内存里，供剪贴板使用）。
pub fn encode_rgba(width: u32, height: u32, rgba: &[u8]) -> Result<Vec<u8>, String> {
    let expected = width as usize * height as usize * 4;
    if rgba.len() != expected {
        return Err(format!("像素数据长度不符：{} 字节，应为 {expected}", rgba.len()));
    }
    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().map_err(|e| format!("PNG 头写入失败：{e}"))?;
        writer.write_image_data(rgba).map_err(|e| format!("PNG 数据写入失败：{e}"))?;
    }
    Ok(out)
}

/// 把 RGBA8 缓冲写成 PNG 文件。
pub fn write_rgba(path: &Path, width: u32, height: u32, rgba: &[u8]) -> Result<(), String> {
    let expected = width as usize * height as usize * 4;
    if rgba.len() != expected {
        return Err(format!("像素数据长度不符：{} 字节，应为 {expected}", rgba.len()));
    }
    if let Some(dir) = path.parent() {
        if !dir.as_os_str().is_empty() {
            std::fs::create_dir_all(dir).map_err(|e| format!("无法创建目录 {}：{e}", dir.display()))?;
        }
    }
    let file = File::create(path).map_err(|e| format!("无法写入 {}：{e}", path.display()))?;
    let mut encoder = png::Encoder::new(BufWriter::new(file), width, height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().map_err(|e| format!("PNG 头写入失败：{e}"))?;
    writer.write_image_data(rgba).map_err(|e| format!("PNG 数据写入失败：{e}"))?;
    Ok(())
}

/// 把 PNG 字节流解回 RGBA8。
///
/// # 为什么需要它
///
/// 剪贴板历史里的图片是以 PNG 存在磁盘上的（未压缩的位图一张全屏就十几 MB）。
/// 从历史里粘贴一张图时，Windows 的剪贴板要的是**原始像素**（`CF_DIB`），
/// 所以必须先解回来。X11 那边可以直接把 PNG 字节交出去，用不着这一步。
///
/// # 输出一律是 RGBA8
///
/// 调用方拿到的永远是四通道、每通道一字节 —— 不必再分情况。
/// 灰度、调色板、带 tRNS 的图都在这里铺开；16 位的截成 8 位。
pub fn decode_rgba(png_bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), String> {
    let mut decoder = png::Decoder::new(png_bytes);
    // EXPAND：调色板 → RGB、低位深灰度 → 8 位、tRNS → 真的 alpha 通道
    // STRIP_16：16 位截成 8 位
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().map_err(|e| format!("PNG 读取失败：{e}"))?;
    let mut buffer = vec![0u8; reader.output_buffer_size()];
    let info = reader
        .next_frame(&mut buffer)
        .map_err(|e| format!("PNG 解码失败：{e}"))?;
    buffer.truncate(info.buffer_size());

    let rgba = match info.color_type {
        png::ColorType::Rgba => buffer,
        png::ColorType::Rgb => buffer
            .chunks_exact(3)
            .flat_map(|p| [p[0], p[1], p[2], 255])
            .collect(),
        png::ColorType::GrayscaleAlpha => buffer
            .chunks_exact(2)
            .flat_map(|p| [p[0], p[0], p[0], p[1]])
            .collect(),
        png::ColorType::Grayscale => buffer.iter().flat_map(|&g| [g, g, g, 255]).collect(),
        // EXPAND 之后不该再有调色板，真出现了也不要猜
        other => return Err(format!("暂不支持的 PNG 颜色类型：{other:?}")),
    };

    let expected = info.width as usize * info.height as usize * 4;
    if rgba.len() != expected {
        return Err(format!(
            "PNG 像素数量不符：{} 字节，应为 {expected}",
            rgba.len()
        ));
    }
    Ok((info.width, info.height, rgba))
}

/// 把 RGBA 转成灰度，供长截屏拼接使用（`baobox_core::stitch` 要的是灰度）。
///
/// 用 Rec. 601 亮度权重而不是简单平均：拼接靠的是行与行之间的差异，
/// 而人眼感知的亮度差更能代表「内容变了没有」。
pub fn to_gray(rgba: &[u8]) -> Vec<u8> {
    rgba.chunks_exact(4)
        .map(|p| {
            let r = p[0] as f32 * 0.299;
            let g = p[1] as f32 * 0.587;
            let b = p[2] as f32 * 0.114;
            (r + g + b).round().clamp(0.0, 255.0) as u8
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_mismatched_buffer() {
        let err = write_rgba(Path::new("/tmp/nope.png"), 2, 2, &[0u8; 8]).unwrap_err();
        assert!(err.contains("长度不符"));
    }

    #[test]
    fn gray_uses_luminance_weights() {
        let green = to_gray(&[0, 255, 0, 255]);
        let blue = to_gray(&[0, 0, 255, 255]);
        assert_eq!(green[0], 150);
        assert_eq!(blue[0], 29);
        assert!(green[0] > blue[0]);
    }

    #[test]
    fn encodes_a_png_in_memory() {
        let rgba: Vec<u8> = (0..2 * 2 * 4).map(|i| (i % 256) as u8).collect();
        let bytes = encode_rgba(2, 2, &rgba).unwrap();
        assert_eq!(&bytes[..8], &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        assert!(encode_rgba(2, 2, &[0u8; 4]).is_err(), "长度不符应拒绝");
    }

    #[test]
    fn a_round_trip_through_png_returns_the_same_pixels() {
        // 从剪贴板历史里粘贴一张图走的就是这条路：存进去是 PNG，
        // 交给 Windows 剪贴板时要的是原始像素
        let rgba: Vec<u8> = (0..3 * 5 * 4).map(|i| (i % 256) as u8).collect();
        let bytes = encode_rgba(3, 5, &rgba).unwrap();
        let (width, height, back) = decode_rgba(&bytes).unwrap();
        assert_eq!((width, height), (3, 5));
        assert_eq!(back, rgba);
    }

    #[test]
    fn decoding_rubbish_fails_instead_of_panicking() {
        assert!(decode_rgba(&[]).is_err());
        assert!(decode_rgba(b"not a png at all").is_err());
        // 头对、后面被截断
        let mut truncated = encode_rgba(2, 2, &[0u8; 16]).unwrap();
        truncated.truncate(20);
        assert!(decode_rgba(&truncated).is_err());
    }

    #[test]
    fn writes_a_real_png_file() {
        let path = std::env::temp_dir().join("baobox-test-out.png");
        let _ = std::fs::remove_file(&path);
        let rgba: Vec<u8> = (0..4 * 4 * 4).map(|i| (i % 256) as u8).collect();
        write_rgba(&path, 4, 4, &rgba).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(&bytes[..8], &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        std::fs::remove_file(&path).ok();
    }
}
