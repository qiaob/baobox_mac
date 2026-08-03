//! Baobox 共享图像层。
//!
//! 三个平台的抓屏结果统一为 RGBA8 之后走这里落盘，因此在哪个系统上截出来的 PNG
//! 格式完全一致。灰度转换供长截屏拼接使用（`baobox_core::stitch` 吃的是灰度）。

#![forbid(unsafe_code)]

use std::fs::File;
use std::io::BufWriter;
use std::path::Path;

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
