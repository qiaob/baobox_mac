//! 屏幕取字：把识别引擎吐出来的一堆词块拼成**人能读的顺序**。
//!
//! 识别引擎（macOS 的 Vision、Windows 的 `Windows.Media.Ocr`、Linux 的 tesseract）
//! 给的都是「一个个带位置的词」，顺序不保证、也不带换行。把它们拼成一段文字
//! 是纯几何问题，与用哪个引擎无关 —— 所以放在这里，三平台共用一份规则，
//! 免得同一张图在三个系统上复制出三种排版。
//!
//! 规则：
//!
//! 1. 竖直方向上互相重叠得够多的词算同一行
//! 2. 行内按左边缘从左到右排
//! 3. 行与行按上边缘从上到下排
//! 4. 同一行内，两个词之间**空得够开**才补一个空格 —— CJK 文字词与词之间
//!    本来就不该有空格，靠间距判断比靠语言判断可靠

use crate::geometry::Rect;

/// 识别出来的一个词 / 一小块文字。
#[derive(Debug, Clone, PartialEq)]
pub struct TextBlock {
    /// 内容
    pub text: String,
    /// 在图像里的位置
    pub rect: Rect,
    /// 置信度 0–1。引擎给不出时填 1.0
    pub confidence: f32,
}

/// 两个词竖直方向重叠多少比例才算同一行。
///
/// 取 0.5 而不是更严：同一行里大小写字母、带标点的词高度本来就有出入，
/// 卡太严会把一行拆成好几行。
pub const SAME_LINE_OVERLAP: f64 = 0.5;

/// 词间距超过行高的这个倍数就补空格。
pub const SPACE_GAP_RATIO: f64 = 0.25;

/// 低于这个置信度的词直接丢掉 —— 识别引擎在噪点上经常吐出孤零零的标点。
pub const MIN_CONFIDENCE: f32 = 0.3;

/// 把词块拼成一段文字。
pub fn assemble(blocks: &[TextBlock]) -> String {
    let mut kept: Vec<&TextBlock> = blocks
        .iter()
        .filter(|block| block.confidence >= MIN_CONFIDENCE && !block.text.trim().is_empty())
        .collect();
    if kept.is_empty() {
        return String::new();
    }
    // 先按上边缘排，分行时只需和「当前行」比较
    kept.sort_by(|a, b| {
        a.rect
            .y
            .partial_cmp(&b.rect.y)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let mut lines: Vec<Vec<&TextBlock>> = Vec::new();
    for block in kept {
        match lines
            .iter_mut()
            .find(|line| line.iter().any(|other| same_line(other, block)))
        {
            Some(line) => line.push(block),
            None => lines.push(vec![block]),
        }
    }

    let mut out = Vec::with_capacity(lines.len());
    for mut line in lines {
        line.sort_by(|a, b| {
            a.rect
                .x
                .partial_cmp(&b.rect.x)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        out.push(join_line(&line));
    }
    out.join("\n")
}

/// 两个词是否在同一行：竖直方向的重叠占较矮那个的比例够大。
fn same_line(a: &TextBlock, b: &TextBlock) -> bool {
    let top = a.rect.y.max(b.rect.y);
    let bottom = a.rect.bottom().min(b.rect.bottom());
    let overlap = bottom - top;
    if overlap <= 0.0 {
        return false;
    }
    let shorter = a.rect.h.min(b.rect.h);
    if shorter <= 0.0 {
        return false;
    }
    overlap / shorter >= SAME_LINE_OVERLAP
}

/// 把一行里的词接起来，按间距决定要不要补空格。
fn join_line(line: &[&TextBlock]) -> String {
    let mut text = String::new();
    let mut previous_right: Option<f64> = None;
    let height = line
        .iter()
        .map(|block| block.rect.h)
        .fold(0.0f64, f64::max)
        .max(1.0);

    for block in line {
        if let Some(right) = previous_right {
            let gap = block.rect.x - right;
            // 词本身已经带了空格就别再补一个
            if gap > height * SPACE_GAP_RATIO && !text.ends_with(' ') {
                text.push(' ');
            }
        }
        text.push_str(block.text.trim());
        previous_right = Some(block.rect.right());
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block(text: &str, x: f64, y: f64, w: f64, h: f64) -> TextBlock {
        TextBlock {
            text: text.to_string(),
            rect: Rect::new(x, y, w, h),
            confidence: 1.0,
        }
    }

    #[test]
    fn words_on_one_line_join_left_to_right_regardless_of_input_order() {
        // 引擎给的顺序是乱的
        let blocks = vec![
            block("world", 60.0, 10.0, 50.0, 20.0),
            block("hello", 0.0, 10.0, 50.0, 20.0),
        ];
        assert_eq!(assemble(&blocks), "hello world");
    }

    #[test]
    fn lines_stack_top_to_bottom() {
        let blocks = vec![
            block("second", 0.0, 40.0, 60.0, 20.0),
            block("first", 0.0, 0.0, 50.0, 20.0),
            block("third", 0.0, 80.0, 50.0, 20.0),
        ];
        assert_eq!(assemble(&blocks), "first\nsecond\nthird");
    }

    #[test]
    fn slight_vertical_jitter_still_counts_as_one_line() {
        // 同一行里大写字母比小写高一点，不该因此被拆成两行
        let blocks = vec![
            block("Hello", 0.0, 10.0, 50.0, 22.0),
            block("there", 60.0, 13.0, 50.0, 18.0),
        ];
        assert_eq!(assemble(&blocks), "Hello there");
    }

    #[test]
    fn adjacent_cjk_characters_are_not_padded_with_spaces() {
        // 引擎常把中文一个字一个块地吐出来；补上空格就没法读了
        let blocks = vec![
            block("屏", 0.0, 0.0, 20.0, 20.0),
            block("幕", 20.0, 0.0, 20.0, 20.0),
            block("取", 40.0, 0.0, 20.0, 20.0),
            block("字", 60.0, 0.0, 20.0, 20.0),
        ];
        assert_eq!(assemble(&blocks), "屏幕取字");
    }

    #[test]
    fn a_wide_gap_becomes_a_space_even_between_cjk() {
        // 两栏之间隔着一大片空白 —— 那确实是分开的两块内容
        let blocks = vec![
            block("左边", 0.0, 0.0, 40.0, 20.0),
            block("右边", 200.0, 0.0, 40.0, 20.0),
        ];
        assert_eq!(assemble(&blocks), "左边 右边");
    }

    #[test]
    fn low_confidence_noise_is_dropped() {
        let mut noise = block(".", 100.0, 0.0, 4.0, 4.0);
        noise.confidence = 0.05;
        let blocks = vec![block("text", 0.0, 0.0, 40.0, 20.0), noise];
        assert_eq!(assemble(&blocks), "text");
    }

    #[test]
    fn empty_and_whitespace_only_input_produces_an_empty_string() {
        assert_eq!(assemble(&[]), "");
        assert_eq!(assemble(&[block("   ", 0.0, 0.0, 10.0, 10.0)]), "");
    }

    #[test]
    fn words_already_carrying_spaces_do_not_get_doubled() {
        let blocks = vec![
            block("hello ", 0.0, 0.0, 50.0, 20.0),
            block("world", 60.0, 0.0, 50.0, 20.0),
        ];
        // 前一个词自带的尾空格被 trim 掉，间距再补一个 —— 结果只有一个空格
        assert_eq!(assemble(&blocks), "hello world");
    }

    #[test]
    fn a_paragraph_keeps_both_orders_straight() {
        let blocks = vec![
            block("b", 20.0, 0.0, 20.0, 20.0),
            block("d", 20.0, 30.0, 20.0, 20.0),
            block("a", 0.0, 0.0, 20.0, 20.0),
            block("c", 0.0, 30.0, 20.0, 20.0),
        ];
        assert_eq!(assemble(&blocks), "ab\ncd");
    }
}
