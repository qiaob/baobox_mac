//! 屏幕取字：把框选区域里的文字识别出来。
//!
//! # 为什么在 Linux 上要外挂 tesseract
//!
//! macOS 有 Vision、Windows 有 `Windows.Media.Ocr`，都是系统自带的。
//! Linux **没有系统级 OCR** —— 发行版里没有这样一个组件。剩下两条路：
//!
//! 1. 把一个识别引擎（tesseract 的 Rust 绑定 / 一个 ONNX 模型）编进二进制
//! 2. 调用用户自己装的 tesseract
//!
//! 选 2。原因是第 1 条要么引入一大串 C 依赖（leptonica、libtesseract），
//! 要么把几十 MB 的模型塞进一个截图工具里，而语言包又得按需下载 ——
//! 最后还是变成「让用户装东西」，只是绕了一大圈。
//!
//! 没装 tesseract 时**明确告诉用户装什么**，而不是报一个看不懂的错 ——
//! 这与项目里其他依赖外部 CLI 的模块是同一条约定。
//!
//! # 为什么用 TSV 而不是直接要纯文本
//!
//! tesseract 直接输出的纯文本已经排过版了，但**排版规则是它自己的**。
//! 要 TSV（带每个词的坐标）再用 `baobox_core::ocr::assemble` 拼，
//! 三个平台的取字结果才会是同一种排版。

use baobox_core::ocr::{assemble, TextBlock};
use baobox_core::geometry::Rect;
use std::path::Path;
use std::process::Command;

/// 默认语言包：简体中文 + 英文。用户可以用 `--lang` 换。
pub const DEFAULT_LANGS: &str = "chi_sim+eng";

/// tesseract 的置信度是 0–100，这里换算成 0–1。
const CONFIDENCE_SCALE: f32 = 100.0;

/// 识别一张 PNG 里的文字。
///
/// `png` 是已经写好的临时文件路径 —— tesseract 只认文件，不认管道里的图。
pub fn recognize(png: &Path, langs: &str) -> Result<String, String> {
    let output = Command::new("tesseract")
        .arg(png)
        .arg("stdout")
        .arg("-l")
        .arg(langs)
        .arg("tsv")
        .output()
        .map_err(|e| unavailable(&e))?;

    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr);
        // 最常见的失败是语言包没装，单独认出来给一句能照做的提示
        if detail.contains("Failed loading language") || detail.contains("Error opening data file")
        {
            return Err(format!(
                "tesseract 缺少语言包 {langs}。\
                 Debian/Ubuntu：sudo apt install tesseract-ocr-chi-sim tesseract-ocr-eng；\
                 Arch：sudo pacman -S tesseract-data-chi_sim tesseract-data-eng"
            ));
        }
        return Err(format!("tesseract 识别失败：{}", detail.trim()));
    }
    Ok(assemble(&parse_tsv(&String::from_utf8_lossy(&output.stdout))))
}

/// tesseract 没装时给一句能照做的话。
fn unavailable(error: &std::io::Error) -> String {
    if error.kind() == std::io::ErrorKind::NotFound {
        return "没找到 tesseract。屏幕取字需要它：\
                Debian/Ubuntu `sudo apt install tesseract-ocr tesseract-ocr-chi-sim`，\
                Arch `sudo pacman -S tesseract tesseract-data-chi_sim`，\
                Fedora `sudo dnf install tesseract tesseract-langpack-chi_sim`。"
            .to_string();
    }
    format!("无法运行 tesseract：{error}")
}

/// 解析 tesseract 的 TSV 输出。
///
/// 列是固定的 12 列：`level page block par line word left top width height conf text`。
/// 只要 `level == 5`（词一级）的行；其余是页 / 块 / 行的汇总，没有文字内容。
///
/// **任何一行看不懂就跳过**：TSV 是外部程序的输出，格式随版本变过，
/// 为一行解析不了就整个失败不值得。
pub fn parse_tsv(tsv: &str) -> Vec<TextBlock> {
    let mut blocks = Vec::new();
    for line in tsv.lines().skip(1) {
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() < 12 || fields[0] != "5" {
            continue;
        }
        let (Ok(left), Ok(top), Ok(width), Ok(height)) = (
            fields[6].parse::<f64>(),
            fields[7].parse::<f64>(),
            fields[8].parse::<f64>(),
            fields[9].parse::<f64>(),
        ) else {
            continue;
        };
        let confidence = fields[10].parse::<f32>().unwrap_or(0.0) / CONFIDENCE_SCALE;
        let text = fields[11..].join("\t");
        if text.trim().is_empty() {
            continue;
        }
        blocks.push(TextBlock {
            text,
            rect: Rect::new(left, top, width, height),
            confidence,
        });
    }
    blocks
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEADER: &str =
        "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext";

    #[test]
    fn only_word_level_rows_become_blocks() {
        let tsv = format!(
            "{HEADER}\n\
             1\t1\t0\t0\t0\t0\t0\t0\t800\t600\t-1\t\n\
             5\t1\t1\t1\t1\t1\t10\t20\t50\t18\t96\thello\n\
             4\t1\t1\t1\t1\t0\t10\t20\t200\t18\t-1\t\n\
             5\t1\t1\t1\t1\t2\t70\t20\t60\t18\t92\tworld\n"
        );
        let blocks = parse_tsv(&tsv);
        assert_eq!(blocks.len(), 2, "只要词一级的行");
        assert_eq!(blocks[0].text, "hello");
        assert_eq!(blocks[0].rect, Rect::new(10.0, 20.0, 50.0, 18.0));
        assert!((blocks[0].confidence - 0.96).abs() < 1e-6);
        assert_eq!(assemble(&blocks), "hello world");
    }

    #[test]
    fn malformed_rows_are_skipped_not_fatal() {
        let tsv = format!(
            "{HEADER}\n\
             5\t1\t1\t1\t1\t1\tx\t20\t50\t18\t96\tbad\n\
             这一行完全不是 TSV\n\
             5\t1\t1\t1\t1\t2\t10\t20\t50\t18\t90\tgood\n"
        );
        let blocks = parse_tsv(&tsv);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].text, "good");
    }

    #[test]
    fn blank_words_are_dropped() {
        let tsv = format!("{HEADER}\n5\t1\t1\t1\t1\t1\t0\t0\t1\t1\t95\t \n");
        assert!(parse_tsv(&tsv).is_empty());
    }

    #[test]
    fn a_word_containing_a_tab_is_kept_whole() {
        // text 是最后一列，里面出现制表符时后面的字段都属于它
        let tsv = format!("{HEADER}\n5\t1\t1\t1\t1\t1\t0\t0\t10\t10\t95\ta\tb\n");
        assert_eq!(parse_tsv(&tsv)[0].text, "a\tb");
    }

    #[test]
    fn a_missing_binary_explains_what_to_install() {
        let error = unavailable(&std::io::Error::from(std::io::ErrorKind::NotFound));
        assert!(error.contains("tesseract"));
        assert!(error.contains("apt install"), "要给出能直接照做的命令");
    }
}
