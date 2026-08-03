//! 长截屏拼接：按相邻画面的重叠区域自动对齐。
//!
//! 这是长截屏里唯一真正有算法的部分，也**完全与平台无关** —— 输入是两帧灰度像素，
//! 输出是「第二帧相对第一帧向下滚了多少」。三个平台共用同一份实现，
//! 因此拼接质量在哪个系统上都一致。
//!
//! 算法：在候选偏移范围内滑动，对重叠部分逐行算平均绝对差（MAD），取最小者。
//! 逐行而不是逐像素比较是因为滚动是竖直的 —— 行是天然的匹配单元，
//! 一行 4000 像素压成一个特征值后，比较次数从 O(H²·W) 降到 O(H²)。

/// 一帧灰度画面。
#[derive(Debug, Clone)]
pub struct Frame {
    /// 宽（像素）
    pub width: usize,
    /// 高（像素）
    pub height: usize,
    /// 逐行的行特征（长度 = height）
    row_signatures: Vec<f64>,
}

impl Frame {
    /// 从灰度像素构造（`pixels.len()` 必须是 `width * height`）。
    ///
    /// 行特征取该行像素的平均值。简单，但对竖直滚动足够 ——
    /// 内容整体上移时，行的顺序不变，特征序列也就跟着平移。
    pub fn from_gray(width: usize, height: usize, pixels: &[u8]) -> Option<Frame> {
        if width == 0 || height == 0 || pixels.len() != width * height {
            return None;
        }
        let mut row_signatures = Vec::with_capacity(height);
        for row in 0..height {
            let start = row * width;
            let sum: u64 = pixels[start..start + width].iter().map(|&p| p as u64).sum();
            row_signatures.push(sum as f64 / width as f64);
        }
        Some(Frame {
            width,
            height,
            row_signatures,
        })
    }

    /// 行特征序列，供对齐使用。
    pub fn signatures(&self) -> &[f64] {
        &self.row_signatures
    }
}

/// 一次对齐的结果。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Alignment {
    /// 第二帧相对第一帧向下滚动了多少行
    pub offset: usize,
    /// 重叠区域的平均绝对差；越小越可信
    pub score: f64,
    /// 重叠了多少行
    pub overlap: usize,
}

/// 判定「对齐可信」的阈值。MAD 超过它就认为两帧不连续（比如用户跳着滚了一大段）。
pub const MAX_TRUSTED_SCORE: f64 = 6.0;

/// 至少要有这么多行重叠才认为对齐有效。
pub const MIN_OVERLAP_ROWS: usize = 8;

/// 求第二帧相对第一帧的竖直偏移。
///
/// 返回 `None` 表示没找到可信的重叠 —— 调用方应当提示用户「没拼到内容」，
/// 而不是硬拼出一张错位的长图。
pub fn align(previous: &Frame, next: &Frame) -> Option<Alignment> {
    if previous.width != next.width {
        return None;
    }
    let (a, b) = (previous.signatures(), next.signatures());
    if a.len() < MIN_OVERLAP_ROWS || b.len() < MIN_OVERLAP_ROWS {
        return None;
    }

    let max_offset = a.len().saturating_sub(MIN_OVERLAP_ROWS);
    let mut best: Option<Alignment> = None;

    for offset in 0..=max_offset {
        let overlap = (a.len() - offset).min(b.len());
        if overlap < MIN_OVERLAP_ROWS {
            continue;
        }
        let mut total = 0.0;
        for row in 0..overlap {
            total += (a[offset + row] - b[row]).abs();
        }
        let score = total / overlap as f64;
        let candidate = Alignment {
            offset,
            score,
            overlap,
        };
        // 分数相同时取偏移更大的：滚动截屏里更大的偏移意味着更多新内容，
        // 而重复纹理（等宽代码、表格）常常在小偏移处出现同分假匹配。
        match &best {
            Some(current) if current.score <= score => {}
            _ => best = Some(candidate),
        }
    }

    best.filter(|alignment| alignment.score <= MAX_TRUSTED_SCORE)
}

/// 增量拼接器：喂进一帧帧画面，累计出总高度与每帧应贴的位置。
#[derive(Debug, Default)]
pub struct Stitcher {
    previous: Option<Frame>,
    /// 每帧在最终长图里的起始行
    placements: Vec<usize>,
    total_height: usize,
    width: usize,
}

impl Stitcher {
    /// 新建。
    pub fn new() -> Self {
        Self::default()
    }

    /// 已接受的帧数。
    pub fn frame_count(&self) -> usize {
        self.placements.len()
    }

    /// 每帧在长图中的起始行。
    pub fn placements(&self) -> &[usize] {
        &self.placements
    }

    /// 当前长图总高度（像素）。
    pub fn total_height(&self) -> usize {
        self.total_height
    }

    /// 长图宽度。
    pub fn width(&self) -> usize {
        self.width
    }

    /// 送入一帧。返回这一帧是否被接受。
    ///
    /// 被拒绝的情况：宽度不一致、与上一帧对不上、或者**完全没有新内容**
    /// （用户没滚动 —— 此时静默忽略，不能把同一屏重复贴进长图）。
    pub fn push(&mut self, frame: Frame) -> bool {
        let Some(previous) = self.previous.take() else {
            self.width = frame.width;
            self.total_height = frame.height;
            self.placements.push(0);
            self.previous = Some(frame);
            return true;
        };

        let Some(alignment) = align(&previous, &frame) else {
            self.previous = Some(previous);
            return false;
        };
        if alignment.offset == 0 {
            // 画面没动，丢弃这一帧但保留上一帧作为基准
            self.previous = Some(previous);
            return false;
        }

        let start = self.placements.last().copied().unwrap_or(0) + alignment.offset;
        let end = start + frame.height;
        self.total_height = self.total_height.max(end);
        self.placements.push(start);
        self.previous = Some(frame);
        true
    }
}


/// 把多帧 RGBA 按各自的起始行合成为一张长图。
///
/// 后来的帧覆盖先前的帧（重叠区取新的）—— 滚动截屏里越靠后的帧内容越新，
/// 而且新帧的重叠区不会有上一帧残留的滚动条拖影。
///
/// `frames` 与 `placements` 一一对应；长度不符或尺寸不符返回 `None`。
pub fn compose_rgba(
    frames: &[&[u8]],
    frame_height: usize,
    placements: &[usize],
    width: usize,
    total_height: usize,
) -> Option<Vec<u8>> {
    if frames.len() != placements.len() || width == 0 || total_height == 0 {
        return None;
    }
    let stride = width * 4;
    if frames.iter().any(|f| f.len() != stride * frame_height) {
        return None;
    }

    let mut canvas = vec![0u8; stride * total_height];
    for (frame, &start) in frames.iter().zip(placements) {
        for row in 0..frame_height {
            let target = start + row;
            if target >= total_height {
                break;
            }
            let src = row * stride;
            let dst = target * stride;
            canvas[dst..dst + stride].copy_from_slice(&frame[src..src + stride]);
        }
    }
    Some(canvas)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 造一张竖直渐变图，行 i 的灰度 = (base + i) % 256，模拟「滚动」时行内容平移。
    fn scroll_frame(width: usize, height: usize, base: usize) -> Frame {
        let mut pixels = Vec::with_capacity(width * height);
        for row in 0..height {
            let value = ((base + row) % 256) as u8;
            pixels.extend(std::iter::repeat(value).take(width));
        }
        Frame::from_gray(width, height, &pixels).unwrap()
    }

    #[test]
    fn rejects_malformed_input() {
        assert!(Frame::from_gray(0, 10, &[]).is_none());
        assert!(Frame::from_gray(4, 4, &[0u8; 8]).is_none(), "像素数不匹配应当拒绝");
    }

    #[test]
    fn finds_the_exact_scroll_offset() {
        let a = scroll_frame(64, 100, 0);
        let b = scroll_frame(64, 100, 30); // 向下滚了 30 行
        let alignment = align(&a, &b).expect("应当对齐成功");
        assert_eq!(alignment.offset, 30);
        assert!(alignment.score < 0.001, "完全一致的重叠区分数应接近 0");
    }

    #[test]
    fn detects_no_scroll_as_zero_offset() {
        let a = scroll_frame(64, 100, 0);
        let b = scroll_frame(64, 100, 0);
        assert_eq!(align(&a, &b).unwrap().offset, 0);
    }

    #[test]
    fn refuses_frames_of_different_width() {
        let a = scroll_frame(64, 100, 0);
        let b = scroll_frame(48, 100, 10);
        assert!(align(&a, &b).is_none());
    }

    #[test]
    fn refuses_unrelated_frames() {
        let a = scroll_frame(64, 100, 0);
        // 全黑，与渐变图毫无关系
        let b = Frame::from_gray(64, 100, &[0u8; 6400]).unwrap();
        assert!(
            align(&a, &b).is_none(),
            "不相关的两帧不应硬拼出一个偏移"
        );
    }

    #[test]
    fn stitcher_accumulates_height_across_frames() {
        let mut s = Stitcher::new();
        assert!(s.push(scroll_frame(64, 100, 0)));
        assert_eq!(s.total_height(), 100);

        assert!(s.push(scroll_frame(64, 100, 30)));
        assert_eq!(s.placements(), &[0, 30]);
        assert_eq!(s.total_height(), 130);

        assert!(s.push(scroll_frame(64, 100, 60)));
        assert_eq!(s.placements(), &[0, 30, 60]);
        assert_eq!(s.total_height(), 160);
        assert_eq!(s.frame_count(), 3);
    }

    #[test]
    fn stitcher_ignores_frames_where_nothing_moved() {
        let mut s = Stitcher::new();
        s.push(scroll_frame(64, 100, 0));
        // 用户没滚动 —— 同一屏不能被重复贴进长图
        assert!(!s.push(scroll_frame(64, 100, 0)));
        assert_eq!(s.frame_count(), 1);
        assert_eq!(s.total_height(), 100);
    }

    #[test]
    fn stitcher_skips_a_frame_it_cannot_align_but_keeps_going() {
        let mut s = Stitcher::new();
        s.push(scroll_frame(64, 100, 0));
        // 跳变的一帧：对不上，应被拒绝
        assert!(!s.push(Frame::from_gray(64, 100, &[200u8; 6400]).unwrap()));
        assert_eq!(s.frame_count(), 1);
        // 基准仍是第一帧，后续正常帧照样能接上
        assert!(s.push(scroll_frame(64, 100, 25)));
        assert_eq!(s.placements(), &[0, 25]);
    }

    #[test]
    fn compose_places_frames_at_their_offsets() {
        let width = 2;
        let height = 2;
        let stride = width * 4;
        // 两帧：全 10 与全 20，第二帧从第 1 行开始
        let a = vec![10u8; stride * height];
        let b = vec![20u8; stride * height];
        let canvas = compose_rgba(&[&a, &b], height, &[0, 1], width, 3).unwrap();
        assert_eq!(canvas.len(), stride * 3);
        // 第 0 行来自第一帧
        assert!(canvas[0..stride].iter().all(|&v| v == 10));
        // 第 1 行重叠 —— 后来的帧覆盖先前的
        assert!(canvas[stride..stride * 2].iter().all(|&v| v == 20));
        // 第 2 行只有第二帧
        assert!(canvas[stride * 2..].iter().all(|&v| v == 20));
    }

    #[test]
    fn compose_rejects_mismatched_input() {
        let a = vec![0u8; 16];
        assert!(compose_rgba(&[&a], 2, &[0, 1], 2, 4).is_none(), "帧数与位置数不符");
        assert!(compose_rgba(&[&a], 3, &[0], 2, 4).is_none(), "帧尺寸不符");
        assert!(compose_rgba(&[&a], 2, &[0], 0, 4).is_none(), "零宽");
    }

    #[test]
    fn compose_clips_frames_that_run_past_the_canvas() {
        let width = 1;
        let stride = 4;
        let a = vec![7u8; stride * 3];
        // 画布只有 2 行，帧高 3 行 —— 不应越界 panic
        let canvas = compose_rgba(&[&a], 3, &[0], width, 2).unwrap();
        assert_eq!(canvas.len(), stride * 2);
    }
}
