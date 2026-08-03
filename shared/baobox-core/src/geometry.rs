//! 矩形运算：选区手柄、跨屏映射、边界裁剪。
//!
//! 对应 macOS 侧 `mac/Sources/Core/Geometry.swift` 与 `WindowManager` 里的跨屏映射规则，
//! 但这里是纯运算，不依赖任何图形框架。

/// 左上角原点、y 轴向下的矩形。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    /// 左边缘
    pub x: f64,
    /// 上边缘
    pub y: f64,
    /// 宽（保持非负；`normalized` 负责纠正）
    pub w: f64,
    /// 高
    pub h: f64,
}

impl Rect {
    /// 构造一个矩形。
    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Self {
        Self { x, y, w, h }
    }

    /// 由两个对角点构造，自动归一化（拖拽方向任意）。
    pub fn from_points(ax: f64, ay: f64, bx: f64, by: f64) -> Self {
        Self {
            x: ax.min(bx),
            y: ay.min(by),
            w: (bx - ax).abs(),
            h: (by - ay).abs(),
        }
    }

    /// 右边缘。
    pub fn right(&self) -> f64 {
        self.x + self.w
    }

    /// 下边缘。
    pub fn bottom(&self) -> f64 {
        self.y + self.h
    }

    /// 面积。
    pub fn area(&self) -> f64 {
        (self.w.max(0.0)) * (self.h.max(0.0))
    }

    /// 宽或高为负时翻正。
    pub fn normalized(&self) -> Rect {
        let x = if self.w < 0.0 { self.x + self.w } else { self.x };
        let y = if self.h < 0.0 { self.y + self.h } else { self.y };
        Rect::new(x, y, self.w.abs(), self.h.abs())
    }

    /// 点是否落在矩形内（含边界）。
    pub fn contains(&self, px: f64, py: f64) -> bool {
        px >= self.x && px <= self.right() && py >= self.y && py <= self.bottom()
    }

    /// 与另一矩形的交集；不相交返回 `None`（而不是一个零尺寸矩形 ——
    /// 「不相交」和「相交但面积为 0」在选屏时是两回事）。
    pub fn intersection(&self, other: &Rect) -> Option<Rect> {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        let right = self.right().min(other.right());
        let bottom = self.bottom().min(other.bottom());
        if right <= x || bottom <= y {
            return None;
        }
        Some(Rect::new(x, y, right - x, bottom - y))
    }

    /// 交集面积（不相交为 0）。
    pub fn intersection_area(&self, other: &Rect) -> f64 {
        self.intersection(other).map_or(0.0, |r| r.area())
    }

    /// 裁剪到边界内：先缩到不超过边界的尺寸，再推回边界内。
    ///
    /// 顺序很重要 —— 反过来先推再缩，会在矩形比边界还大时把它推出去。
    pub fn clamped_to(&self, bounds: &Rect) -> Rect {
        let w = self.w.min(bounds.w);
        let h = self.h.min(bounds.h);
        let x = self.x.clamp(bounds.x, bounds.right() - w);
        let y = self.y.clamp(bounds.y, bounds.bottom() - h);
        Rect::new(x, y, w, h)
    }

    /// 平移。
    pub fn offset(&self, dx: f64, dy: f64) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.w, self.h)
    }

    /// 能同时装下两个矩形的最小矩形。
    ///
    /// 标注编辑器用它算窗口大小 —— 窗口要同时盖住图像和它下面的工具条。
    pub fn union(&self, other: &Rect) -> Rect {
        let x = self.x.min(other.x);
        let y = self.y.min(other.y);
        Rect::new(
            x,
            y,
            self.right().max(other.right()) - x,
            self.bottom().max(other.bottom()) - y,
        )
    }
}

/// 八个方向的缩放手柄。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Handle {
    /// 左上
    TopLeft,
    /// 上
    Top,
    /// 右上
    TopRight,
    /// 右
    Right,
    /// 右下
    BottomRight,
    /// 下
    Bottom,
    /// 左下
    BottomLeft,
    /// 左
    Left,
}

impl Handle {
    /// 全部八个手柄，顺时针自左上开始。
    pub const ALL: [Handle; 8] = [
        Handle::TopLeft,
        Handle::Top,
        Handle::TopRight,
        Handle::Right,
        Handle::BottomRight,
        Handle::Bottom,
        Handle::BottomLeft,
        Handle::Left,
    ];

    /// 该手柄在矩形上的锚点坐标。
    pub fn anchor(&self, r: &Rect) -> (f64, f64) {
        let (cx, cy) = (r.x + r.w / 2.0, r.y + r.h / 2.0);
        match self {
            Handle::TopLeft => (r.x, r.y),
            Handle::Top => (cx, r.y),
            Handle::TopRight => (r.right(), r.y),
            Handle::Right => (r.right(), cy),
            Handle::BottomRight => (r.right(), r.bottom()),
            Handle::Bottom => (cx, r.bottom()),
            Handle::BottomLeft => (r.x, r.bottom()),
            Handle::Left => (r.x, cy),
        }
    }
}

/// 命中测试：点落在哪个手柄上（`tolerance` 是手柄的半径）。
///
/// 角优先于边 —— 角落处两者都在容差内时，用户想拉的几乎总是角。
pub fn handle_at(point: (f64, f64), rect: &Rect, tolerance: f64) -> Option<Handle> {
    let corners = [
        Handle::TopLeft,
        Handle::TopRight,
        Handle::BottomRight,
        Handle::BottomLeft,
    ];
    let edges = [Handle::Top, Handle::Right, Handle::Bottom, Handle::Left];
    for group in [corners.as_slice(), edges.as_slice()] {
        for handle in group {
            let (ax, ay) = handle.anchor(rect);
            if (point.0 - ax).abs() <= tolerance && (point.1 - ay).abs() <= tolerance {
                return Some(*handle);
            }
        }
    }
    None
}

/// 拖动某个手柄后的新矩形。
///
/// 拖过对边时自动翻正（`normalized`），这样用户把右边缘拖到左边缘左侧也不会得到负宽度。
pub fn resize(rect: &Rect, handle: Handle, dx: f64, dy: f64) -> Rect {
    let mut left = rect.x;
    let mut top = rect.y;
    let mut right = rect.right();
    let mut bottom = rect.bottom();

    match handle {
        Handle::TopLeft => {
            left += dx;
            top += dy;
        }
        Handle::Top => top += dy,
        Handle::TopRight => {
            right += dx;
            top += dy;
        }
        Handle::Right => right += dx,
        Handle::BottomRight => {
            right += dx;
            bottom += dy;
        }
        Handle::Bottom => bottom += dy,
        Handle::BottomLeft => {
            left += dx;
            bottom += dy;
        }
        Handle::Left => left += dx,
    }
    Rect::from_points(left, top, right, bottom)
}

/// 在若干显示器中挑出与给定矩形**交集面积最大**的那一块。
///
/// 与 macOS 侧窗口管理同一规则：取交集最大者，而不是取鼠标所在屏 ——
/// 一个窗口横跨两屏时，用户心里的「这个窗口在哪块屏上」就是面积多的那块。
/// 全都不相交时回退到第一块（而非报错，避免调用方到处判空）。
pub fn display_for(rect: &Rect, displays: &[Rect]) -> Option<usize> {
    if displays.is_empty() {
        return None;
    }
    let mut best = 0usize;
    let mut best_area = -1.0f64;
    for (index, display) in displays.iter().enumerate() {
        let area = rect.intersection_area(display);
        if area > best_area {
            best_area = area;
            best = index;
        }
    }
    Some(best)
}

/// 把矩形从一块显示器等比映射到另一块，并裁剪进目标可见区域。
///
/// 保持「在屏内的相对位置与相对尺寸」，因此不同分辨率之间移动不会变形或溢出。
/// 与 macOS 侧跨屏移动、以及布局快照恢复用的是同一套规则。
pub fn map_across_displays(rect: &Rect, from: &Rect, to: &Rect) -> Rect {
    if from.w <= 0.0 || from.h <= 0.0 {
        return rect.clamped_to(to);
    }
    let rel_x = (rect.x - from.x) / from.w;
    let rel_y = (rect.y - from.y) / from.h;
    let rel_w = rect.w / from.w;
    let rel_h = rect.h / from.h;
    let mapped = Rect::new(
        to.x + rel_x * to.w,
        to.y + rel_y * to.h,
        rel_w * to.w,
        rel_h * to.h,
    );
    mapped.clamped_to(to)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_points_normalizes_any_drag_direction() {
        // 四个方向拖出来的选区应当完全一致。
        let expected = Rect::new(10.0, 20.0, 30.0, 40.0);
        assert_eq!(Rect::from_points(10.0, 20.0, 40.0, 60.0), expected);
        assert_eq!(Rect::from_points(40.0, 60.0, 10.0, 20.0), expected);
        assert_eq!(Rect::from_points(40.0, 20.0, 10.0, 60.0), expected);
        assert_eq!(Rect::from_points(10.0, 60.0, 40.0, 20.0), expected);
    }

    #[test]
    fn union_covers_both_rects_even_when_they_are_far_apart() {
        let image = Rect::new(100.0, 100.0, 200.0, 150.0);
        let toolbar = Rect::new(80.0, 300.0, 400.0, 40.0);
        let both = image.union(&toolbar);
        assert_eq!(both, Rect::new(80.0, 100.0, 400.0, 240.0));
        // 包含关系下并集就是大的那个
        let big = Rect::new(0.0, 0.0, 1000.0, 1000.0);
        assert_eq!(big.union(&image), big);
        // 交换律
        assert_eq!(image.union(&toolbar), toolbar.union(&image));
    }

    #[test]
    fn intersection_distinguishes_disjoint_from_touching() {
        let a = Rect::new(0.0, 0.0, 10.0, 10.0);
        // 仅边缘相接 → 视为不相交（面积为 0 的交集没有意义）
        assert_eq!(a.intersection(&Rect::new(10.0, 0.0, 5.0, 5.0)), None);
        assert_eq!(a.intersection(&Rect::new(20.0, 0.0, 5.0, 5.0)), None);
        assert_eq!(
            a.intersection(&Rect::new(5.0, 5.0, 10.0, 10.0)),
            Some(Rect::new(5.0, 5.0, 5.0, 5.0))
        );
    }

    #[test]
    fn clamp_shrinks_before_pushing() {
        let bounds = Rect::new(0.0, 0.0, 100.0, 100.0);
        // 比边界还大 → 先缩到边界大小，且仍在边界内
        let huge = Rect::new(-50.0, -50.0, 300.0, 300.0).clamped_to(&bounds);
        assert_eq!(huge, Rect::new(0.0, 0.0, 100.0, 100.0));
        // 越界但尺寸合适 → 推回来，尺寸不变
        let pushed = Rect::new(90.0, 90.0, 30.0, 30.0).clamped_to(&bounds);
        assert_eq!(pushed, Rect::new(70.0, 70.0, 30.0, 30.0));
    }

    #[test]
    fn handle_hit_test_prefers_corners_over_edges() {
        let r = Rect::new(0.0, 0.0, 100.0, 100.0);
        // 左上角同时落在 Top 与 Left 的容差里，应当判为 TopLeft
        assert_eq!(handle_at((0.0, 0.0), &r, 8.0), Some(Handle::TopLeft));
        assert_eq!(handle_at((50.0, 0.0), &r, 8.0), Some(Handle::Top));
        assert_eq!(handle_at((100.0, 50.0), &r, 8.0), Some(Handle::Right));
        assert_eq!(handle_at((50.0, 50.0), &r, 8.0), None);
    }

    #[test]
    fn resize_flips_when_dragged_past_opposite_edge() {
        let r = Rect::new(10.0, 10.0, 100.0, 100.0);
        // 把右边缘往左拖 150：越过左边缘，结果应翻正而不是负宽
        let flipped = resize(&r, Handle::Right, -150.0, 0.0);
        assert_eq!(flipped, Rect::new(-40.0, 10.0, 50.0, 100.0));
        assert!(flipped.w > 0.0);
    }

    #[test]
    fn display_for_picks_largest_intersection_not_first() {
        let displays = [
            Rect::new(0.0, 0.0, 100.0, 100.0),
            Rect::new(100.0, 0.0, 100.0, 100.0),
        ];
        // 大部分落在第二块屏上
        let window = Rect::new(80.0, 10.0, 100.0, 50.0);
        assert_eq!(display_for(&window, &displays), Some(1));
        // 完全不相交时回退到第一块，不是 None
        let far = Rect::new(500.0, 500.0, 10.0, 10.0);
        assert_eq!(display_for(&far, &displays), Some(0));
        assert_eq!(display_for(&far, &[]), None);
    }

    #[test]
    fn cross_display_mapping_keeps_relative_position_and_scale() {
        let from = Rect::new(0.0, 0.0, 1000.0, 1000.0);
        let to = Rect::new(2000.0, 0.0, 500.0, 500.0);
        // 原屏正中央、占四分之一 → 映射后仍在正中央、仍占四分之一
        let rect = Rect::new(250.0, 250.0, 500.0, 500.0);
        let mapped = map_across_displays(&rect, &from, &to);
        assert_eq!(mapped, Rect::new(2125.0, 125.0, 250.0, 250.0));
    }

    #[test]
    fn cross_display_mapping_never_overflows_target() {
        let from = Rect::new(0.0, 0.0, 1000.0, 1000.0);
        let to = Rect::new(0.0, 0.0, 400.0, 300.0);
        // 贴着原屏右下角的窗口，映射后必须仍在目标屏内
        let rect = Rect::new(900.0, 900.0, 200.0, 200.0);
        let mapped = map_across_displays(&rect, &from, &to);
        assert!(mapped.x >= to.x && mapped.y >= to.y);
        assert!(mapped.right() <= to.right() + 1e-9);
        assert!(mapped.bottom() <= to.bottom() + 1e-9);
    }
}
