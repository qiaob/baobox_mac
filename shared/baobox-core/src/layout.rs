//! 窗口布局：半屏 / 四分屏 / 最大化 / 居中 / 跨屏，全是纯几何。
//!
//! 对应 macOS 侧 `WindowLayout.swift`。**这里不碰任何窗口系统** ——
//! 拿到「窗口现在多大」「屏幕的可用区域是多大」，算出「该摆到哪」，
//! 谁去执行是平台的事（AX / EWMH / `SetWindowPos`）。
//!
//! # 坐标系：左上原点
//!
//! 与 `shared` 里其余部分一致（见 `docs/multiplatform/ARCHITECTURE.md`）。
//! macOS 那份 Swift 用的是 AppKit 的**左下**原点，所以那边 `.top` 是
//! **较大**的 y、这边 `.top` 是**较小**的 y —— 照抄那份代码的坐标会上下颠倒。
//! 翻转在 mac 侧的边界上做，这里不管。
//!
//! # 基准是「可用区域」，不是整块屏
//!
//! 传进来的 `work` 必须已经**扣掉任务栏 / Dock / 菜单栏**。用整块屏的话，
//! 半屏窗口会有一半压在任务栏底下 —— 而且每块屏的任务栏还可能不一样，
//! 所以这个值必须逐屏取，不能拿主屏的凑合。
//!
//! # 间距怎么留
//!
//! 四周内缩 `gap`，**切分线两侧各留 `gap/2`**。这样两个半屏窗口中间的缝
//! 与它们到屏幕边缘的距离看起来一样宽 —— 各留一个整 `gap` 的话中缝会显得过宽。

use crate::geometry::Rect;

/// 一种布局。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Layout {
    /// 左半屏
    Left,
    /// 右半屏
    Right,
    /// 上半屏
    Top,
    /// 下半屏
    Bottom,
    /// 左上四分之一
    TopLeft,
    /// 右上四分之一
    TopRight,
    /// 左下四分之一
    BottomLeft,
    /// 右下四分之一
    BottomRight,
    /// 铺满可用区域
    Maximize,
    /// 保持大小，挪到正中
    Center,
    /// 挪到下一块屏
    NextDisplay,
    /// 挪到上一块屏
    PrevDisplay,
    /// 恢复到动手之前的位置
    Restore,
}

impl Layout {
    /// 是不是「在同一块屏上切一块地方」这类布局。
    ///
    /// 跨屏与恢复不是 —— 它们要的是别的信息（有哪些屏、之前在哪），
    /// 不能只看当前这块屏。
    pub fn is_slicing(&self) -> bool {
        !matches!(self, Layout::NextDisplay | Layout::PrevDisplay | Layout::Restore)
    }

    /// 动作 id 里用的那一段，也是配置里的快捷键键名。
    ///
    /// **三个平台必须逐字一致**，否则同一份配置换个系统就失效。
    pub fn slug(&self) -> &'static str {
        match self {
            Layout::Left => "left",
            Layout::Right => "right",
            Layout::Top => "top",
            Layout::Bottom => "bottom",
            Layout::TopLeft => "topleft",
            Layout::TopRight => "topright",
            Layout::BottomLeft => "bottomleft",
            Layout::BottomRight => "bottomright",
            Layout::Maximize => "maximize",
            Layout::Center => "center",
            Layout::NextDisplay => "nextdisplay",
            Layout::PrevDisplay => "prevdisplay",
            Layout::Restore => "restore",
        }
    }

    /// 菜单上的字。
    pub fn title(&self) -> &'static str {
        match self {
            Layout::Left => "左半屏",
            Layout::Right => "右半屏",
            Layout::Top => "上半屏",
            Layout::Bottom => "下半屏",
            Layout::TopLeft => "左上四分之一",
            Layout::TopRight => "右上四分之一",
            Layout::BottomLeft => "左下四分之一",
            Layout::BottomRight => "右下四分之一",
            Layout::Maximize => "最大化",
            Layout::Center => "居中",
            Layout::NextDisplay => "移到下一块屏",
            Layout::PrevDisplay => "移到上一块屏",
            Layout::Restore => "恢复原位",
        }
    }

    /// 从 slug 读回来。
    pub fn from_slug(slug: &str) -> Option<Layout> {
        ALL.iter().copied().find(|layout| layout.slug() == slug)
    }
}

/// 全部布局，顺序就是菜单顺序。
pub const ALL: [Layout; 13] = [
    Layout::Left,
    Layout::Right,
    Layout::Top,
    Layout::Bottom,
    Layout::TopLeft,
    Layout::TopRight,
    Layout::BottomLeft,
    Layout::BottomRight,
    Layout::Maximize,
    Layout::Center,
    Layout::NextDisplay,
    Layout::PrevDisplay,
    Layout::Restore,
];

/// 窗口边之间留多少像素的默认值。
pub const DEFAULT_GAP: f64 = 0.0;

/// 算出目标矩形。
///
/// `work` 是**这块屏的可用区域**（已扣掉任务栏 / Dock）。
/// 跨屏与恢复类布局原样返回 `window` —— 它们由调用方另行处理。
pub fn target(layout: Layout, window: &Rect, work: &Rect, gap: f64) -> Rect {
    let g = gap.max(0.0);
    // 切分线两侧各留一半，中缝才和四周的边距看起来一样宽
    let half = g / 2.0;
    let left = work.x + g;
    let top = work.y + g;
    let full_w = (work.w - 2.0 * g).max(0.0);
    let full_h = (work.h - 2.0 * g).max(0.0);
    // 半屏的宽 = 半块可用区域，再减掉外侧的 gap 与中缝的一半
    let half_w = (work.w / 2.0 - g - half).max(0.0);
    let half_h = (work.h / 2.0 - g - half).max(0.0);
    let mid_x = work.x + work.w / 2.0 + half;
    let mid_y = work.y + work.h / 2.0 + half;

    match layout {
        Layout::Maximize => Rect::new(left, top, full_w, full_h),
        Layout::Center => {
            // 只平移，不改大小 —— 用户要的是「摆正」，不是「重排」
            let w = window.w.min(work.w);
            let h = window.h.min(work.h);
            Rect::new(
                work.x + (work.w - w) / 2.0,
                work.y + (work.h - h) / 2.0,
                w,
                h,
            )
        }
        Layout::Left => Rect::new(left, top, half_w, full_h),
        Layout::Right => Rect::new(mid_x, top, half_w, full_h),
        // 左上原点：上半屏在**小**的 y。mac 那份 Swift 是反过来的
        Layout::Top => Rect::new(left, top, full_w, half_h),
        Layout::Bottom => Rect::new(left, mid_y, full_w, half_h),
        Layout::TopLeft => Rect::new(left, top, half_w, half_h),
        Layout::TopRight => Rect::new(mid_x, top, half_w, half_h),
        Layout::BottomLeft => Rect::new(left, mid_y, half_w, half_h),
        Layout::BottomRight => Rect::new(mid_x, mid_y, half_w, half_h),
        Layout::NextDisplay | Layout::PrevDisplay | Layout::Restore => *window,
    }
}

/// 跨屏：下一块 / 上一块是第几块。
///
/// 屏幕顺序由调用方保证稳定（按 x 再按 y 排，见 [`sort_displays`]），
/// 否则「下一块」在两次调用之间可能指向不同的屏。首尾相接地转圈。
pub fn neighbour_display(current: usize, count: usize, forward: bool) -> usize {
    if count == 0 {
        return 0;
    }
    if forward {
        (current + 1) % count
    } else {
        (current + count - 1) % count
    }
}

/// 把显示器排成稳定的顺序：先按左边缘，再按上边缘。
///
/// 返回的是**下标**，调用方据此重排自己那份列表 —— 直接排 `Rect` 的话
/// 就跟平台层的显示器句柄对不上了。
pub fn sort_displays(displays: &[Rect]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..displays.len()).collect();
    order.sort_by(|&a, &b| {
        let (l, r) = (&displays[a], &displays[b]);
        l.x.partial_cmp(&r.x)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(l.y.partial_cmp(&r.y).unwrap_or(std::cmp::Ordering::Equal))
    });
    order
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 一块 1920×1080 的屏，底下 40 像素被任务栏占了。
    fn work() -> Rect {
        Rect::new(0.0, 0.0, 1920.0, 1040.0)
    }

    fn window() -> Rect {
        Rect::new(300.0, 200.0, 800.0, 600.0)
    }

    #[test]
    fn halves_and_quarters_tile_the_work_area_exactly_when_there_is_no_gap() {
        let w = work();
        let left = target(Layout::Left, &window(), &w, 0.0);
        let right = target(Layout::Right, &window(), &w, 0.0);
        assert_eq!(left, Rect::new(0.0, 0.0, 960.0, 1040.0));
        assert_eq!(right, Rect::new(960.0, 0.0, 960.0, 1040.0));
        // 两半合起来正好是整块，不重叠也不留缝
        assert_eq!(left.w + right.w, w.w);
        assert_eq!(left.right(), right.x);

        let quarters = [
            target(Layout::TopLeft, &window(), &w, 0.0),
            target(Layout::TopRight, &window(), &w, 0.0),
            target(Layout::BottomLeft, &window(), &w, 0.0),
            target(Layout::BottomRight, &window(), &w, 0.0),
        ];
        let total: f64 = quarters.iter().map(|r| r.area()).sum();
        assert_eq!(total, w.area(), "四个四分屏合起来应当正好铺满");
    }

    #[test]
    fn the_top_half_is_at_the_smaller_y_because_the_origin_is_top_left() {
        // mac 那份 Swift 是左下原点，照抄它的坐标会上下颠倒
        let top = target(Layout::Top, &window(), &work(), 0.0);
        let bottom = target(Layout::Bottom, &window(), &work(), 0.0);
        assert!(top.y < bottom.y, "上半屏该在小的 y");
        assert_eq!(top.y, 0.0);
        assert_eq!(bottom.y, 520.0);
    }

    #[test]
    fn the_work_area_offset_is_respected_so_windows_do_not_hide_under_the_taskbar() {
        // 任务栏在顶上、副屏原点又是负数的情况
        let w = Rect::new(-1920.0, 40.0, 1920.0, 1000.0);
        let max = target(Layout::Maximize, &window(), &w, 0.0);
        assert_eq!(max, w, "最大化就该正好是可用区域");
        let left = target(Layout::Left, &window(), &w, 0.0);
        assert_eq!(left.x, -1920.0);
        assert_eq!(left.y, 40.0, "不能贴到屏幕物理顶边去");
    }

    #[test]
    fn the_seam_between_two_halves_is_as_wide_as_the_outer_margin() {
        // 中缝各留一个整 gap 的话会显得比四周宽一倍
        let gap = 10.0;
        let left = target(Layout::Left, &window(), &work(), gap);
        let right = target(Layout::Right, &window(), &work(), gap);
        let seam = right.x - left.right();
        assert_eq!(seam, gap, "中缝该和四周的边距一样宽");
        assert_eq!(left.x, gap);
        assert_eq!(work().right() - right.right(), gap);
    }

    #[test]
    fn centering_keeps_the_window_size_and_only_moves_it() {
        let win = window();
        let centred = target(Layout::Center, &win, &work(), 0.0);
        assert_eq!((centred.w, centred.h), (win.w, win.h), "居中不该改大小");
        assert_eq!(centred.x, (1920.0 - 800.0) / 2.0);
        assert_eq!(centred.y, (1040.0 - 600.0) / 2.0);
    }

    #[test]
    fn a_window_bigger_than_the_screen_is_shrunk_when_centring() {
        // 否则它会往两边溢出去，标题栏都够不着
        let huge = Rect::new(0.0, 0.0, 4000.0, 3000.0);
        let centred = target(Layout::Center, &huge, &work(), 0.0);
        assert_eq!((centred.w, centred.h), (1920.0, 1040.0));
        assert_eq!((centred.x, centred.y), (0.0, 0.0));
    }

    #[test]
    fn an_absurd_gap_does_not_produce_negative_sizes() {
        // 用户在配置里写了个 9999，不能算出负的宽高再让平台层去崩
        for layout in ALL.iter().filter(|l| l.is_slicing()) {
            let r = target(*layout, &window(), &work(), 9999.0);
            assert!(r.w >= 0.0 && r.h >= 0.0, "{} 算出了负数", layout.slug());
        }
        // 负的间距按 0 处理
        assert_eq!(
            target(Layout::Left, &window(), &work(), -50.0),
            target(Layout::Left, &window(), &work(), 0.0)
        );
    }

    #[test]
    fn cross_display_and_restore_layouts_leave_the_frame_alone() {
        // 它们要的是别的信息（有哪些屏、之前在哪），由调用方处理
        for layout in [Layout::NextDisplay, Layout::PrevDisplay, Layout::Restore] {
            assert_eq!(target(layout, &window(), &work(), 20.0), window());
            assert!(!layout.is_slicing());
        }
    }

    #[test]
    fn the_neighbour_display_wraps_around_in_both_directions() {
        assert_eq!(neighbour_display(0, 3, true), 1);
        assert_eq!(neighbour_display(2, 3, true), 0, "最后一块的下一块转回第一块");
        assert_eq!(neighbour_display(0, 3, false), 2, "第一块的上一块是最后一块");
        assert_eq!(neighbour_display(1, 3, false), 0);
        // 只有一块屏时哪儿也去不了，但不能除以零
        assert_eq!(neighbour_display(0, 1, true), 0);
        assert_eq!(neighbour_display(0, 0, true), 0);
    }

    #[test]
    fn displays_sort_left_to_right_then_top_to_bottom() {
        // 顺序不稳定的话，「下一块屏」在两次调用之间可能指向不同的屏
        let displays = [
            Rect::new(1920.0, 0.0, 1920.0, 1080.0),
            Rect::new(0.0, 1080.0, 1920.0, 1080.0),
            Rect::new(0.0, 0.0, 1920.0, 1080.0),
        ];
        assert_eq!(sort_displays(&displays), vec![2, 1, 0]);
        assert!(sort_displays(&[]).is_empty());
    }

    #[test]
    fn every_layout_has_a_unique_slug_that_round_trips() {
        // slug 是配置里的快捷键键名，撞了或者读不回来都会让绑定失效
        let mut seen = std::collections::HashSet::new();
        for layout in ALL {
            assert!(seen.insert(layout.slug()), "{} 撞名了", layout.slug());
            assert_eq!(Layout::from_slug(layout.slug()), Some(layout));
            assert!(!layout.title().is_empty());
        }
        assert_eq!(Layout::from_slug("不存在"), None);
    }
}
