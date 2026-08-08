//! 工具条的样子：底板、按钮底色、图标。
//!
//! # 为什么图标也自己画
//!
//! 换成图片资源就要维护三套（不同 DPI、不同格式），换成系统图标库
//! （SF Symbols / Segoe Fluent Icons）在 Linux 上根本没有对应物。
//! 这些图标全是直线、方框、椭圆，用 [`crate`] 里已有的几个图元画出来最省事，
//! 而且**三平台逐像素一致** —— 与标注本身同一个理由。
//!
//! 布局不在这里，在 `baobox_core::toolbar`：那边算矩形，这边照着画。

use crate::{fill_circle, fill_rect, fill_round_rect, line, stroke_ellipse_in, stroke_rect_in, Canvas};
use baobox_core::annotation::{Color, Tool};
use baobox_core::geometry::Rect;
use baobox_core::toolbar::{Item, Toolbar, PALETTE};

/// 工具条底板色：mac 是 `white 0.13 @ 0.96` ≈ #212121 @96%
/// （见 docs/screenshot-parity/MAC_ALIGNMENT.md §2.1）。
pub const PANEL: Color = Color {
    r: 0x21,
    g: 0x21,
    b: 0x21,
    a: 0xF5,
};

/// 底板圆角（mac 是 9）。
pub const PANEL_RADIUS: f64 = 9.0;

/// 选中项的图标色（accent 深档 #2BC4B8）。
/// mac 的选中态**只染图标色，没有背景块**（MAC_ALIGNMENT.md §2.5）。
pub const ACCENT: Color = Color::rgb(0x2B, 0xC4, 0xB8);

/// 图标常规色（mac `white 0.92` ≈ #EBEBEB）。
pub const ICON: Color = Color::rgb(0xEB, 0xEB, 0xEB);

/// 粗细档未选中时的色（mac `white 0.75`，刻意比工具按钮更暗）。
pub const SIZE_IDLE: Color = Color::rgb(0xBF, 0xBF, 0xBF);

/// 不可用时的图标色（撤销栈空了的撤销按钮）。
pub const ICON_DISABLED: Color = Color::rgb(0x6A, 0x6E, 0x74);

/// 分隔竖线色（mac `white @ 0.22`）。
pub const SEPARATOR: Color = Color {
    r: 0xFF,
    g: 0xFF,
    b: 0xFF,
    a: 0x38,
};

/// 图标线宽。
const STROKE: f64 = 1.6;

/// 图标相对按钮的内缩。
const INSET: f64 = 7.0;

/// 粗细三档的圆点直径（mac circle.fill pointSize 4.5 / 6.5 / 9）。
const SIZE_DOTS: [f64; 3] = [4.5, 6.5, 9.0];

/// 画工具条时需要知道的当前状态。
#[derive(Debug, Clone, Copy)]
pub struct ToolbarState {
    /// 当前工具。选区调整阶段还没选工具，是 `None`（mac 无默认工具）
    pub tool: Option<Tool>,
    /// 当前颜色在 [`PALETTE`] 里的下标
    pub color_index: usize,
    /// 当前粗细档
    pub size_index: usize,
    /// 撤销可用吗
    pub can_undo: bool,
    /// 重做可用吗
    pub can_redo: bool,
    /// 鼠标悬停在哪一项上。mac 没有 hover 视觉，这里保留字段但不画
    pub hovered: Option<Item>,
}

/// 把整条工具条画到画布上。
///
/// 坐标是**画布坐标** —— 调用方先把工具条矩形从屏幕坐标平移过来。
pub fn draw_toolbar(canvas: &mut Canvas<'_>, toolbar: &Toolbar, state: &ToolbarState) {
    fill_round_rect(canvas, &toolbar.frame, PANEL_RADIUS, PANEL);
    for separator in &toolbar.separators {
        fill_rect(canvas, separator, SEPARATOR);
    }
    for button in &toolbar.buttons {
        draw_button(canvas, &button.frame, button.item, state);
    }
}

fn draw_button(canvas: &mut Canvas<'_>, frame: &Rect, item: Item, state: &ToolbarState) {
    // mac 的选中态没有背景块、也没有 hover 底色 —— 只换图标颜色
    draw_icon(canvas, frame, item, icon_color(item, state));
    // 颜色选中效果 = 色点最外圈一道白环（MAC_ALIGNMENT.md §2.4）
    if let Item::Color(index) = item {
        if index == state.color_index {
            let ring = 18.0;
            let ring_rect = Rect::new(
                frame.x + (frame.w - ring) / 2.0 + 0.5,
                frame.y + (frame.h - ring) / 2.0 + 0.5,
                ring - 1.0,
                ring - 1.0,
            );
            stroke_ellipse_in(canvas, &ring_rect, 1.5, Color::rgb(0xFF, 0xFF, 0xFF));
        }
    }
}

fn is_active(item: Item, state: &ToolbarState) -> bool {
    match item {
        Item::Tool(tool) => Some(tool) == state.tool,
        Item::Size(index) => index == state.size_index,
        _ => false,
    }
}

fn icon_color(item: Item, state: &ToolbarState) -> Color {
    match item {
        _ if is_active(item, state) => ACCENT,
        Item::Size(_) => SIZE_IDLE,
        Item::Undo if !state.can_undo => ICON_DISABLED,
        Item::Redo if !state.can_redo => ICON_DISABLED,
        // 取消按钮与其他出口一样是常规色 —— mac 没有红色警示态
        _ => ICON,
    }
}

/// 画一个图标。图标画在 `frame` 内缩之后的方框里。
pub fn draw_icon(canvas: &mut Canvas<'_>, frame: &Rect, item: Item, color: Color) {
    let box_rect = Rect::new(
        frame.x + INSET,
        frame.y + INSET,
        (frame.w - INSET * 2.0).max(2.0),
        (frame.h - INSET * 2.0).max(2.0),
    );
    let (left, top) = (box_rect.x, box_rect.y);
    let (right, bottom) = (box_rect.right(), box_rect.bottom());
    let (cx, cy) = (left + box_rect.w / 2.0, top + box_rect.h / 2.0);

    match item {
        Item::Tool(Tool::Rect) => stroke_rect_in(canvas, &box_rect, STROKE, color),
        Item::Tool(Tool::Ellipse) => stroke_ellipse_in(canvas, &box_rect, STROKE, color),
        Item::Tool(Tool::Arrow) => {
            // 左下 → 右上，带两条回勾
            let from = (left, bottom);
            let to = (right, top);
            line(canvas, from, to, STROKE, color);
            let head = box_rect.w * 0.42;
            line(canvas, to, (to.0 - head, to.1), STROKE, color);
            line(canvas, to, (to.0, to.1 + head), STROKE, color);
        }
        Item::Tool(Tool::Pen) => {
            // 一道波浪，表示自由手绘
            let mut previous = (left, cy + box_rect.h * 0.25);
            for step in 1..=4 {
                let t = step as f64 / 4.0;
                let x = left + box_rect.w * t;
                let y = if step % 2 == 0 {
                    cy + box_rect.h * 0.25
                } else {
                    cy - box_rect.h * 0.3
                };
                line(canvas, previous, (x, y), STROKE, color);
                previous = (x, y);
            }
        }
        Item::Tool(Tool::Highlighter) => {
            // 一条粗的半透明横杠
            let mut translucent = color;
            translucent.a = 0x88;
            fill_rect(
                canvas,
                &Rect::new(left, cy - box_rect.h * 0.22, box_rect.w, box_rect.h * 0.44),
                translucent,
            );
            line(canvas, (left, bottom), (right, bottom), STROKE, color);
        }
        Item::Tool(Tool::Mosaic) => {
            // 2×2 棋盘，对角两格填实
            let half_w = box_rect.w / 2.0;
            let half_h = box_rect.h / 2.0;
            fill_rect(canvas, &Rect::new(left, top, half_w, half_h), color);
            fill_rect(canvas, &Rect::new(cx, cy, half_w, half_h), color);
            stroke_rect_in(canvas, &box_rect, STROKE, color);
        }
        Item::Tool(Tool::Text) => {
            // 一个「T」
            line(canvas, (left, top), (right, top), STROKE, color);
            line(canvas, (cx, top), (cx, bottom), STROKE, color);
        }
        Item::Tool(Tool::Eraser) => {
            // 一块斜着的橡皮：平行四边形
            let slant = box_rect.w * 0.25;
            let corners = [
                (left + slant, top),
                (right, top),
                (right - slant, bottom),
                (left, bottom),
            ];
            for index in 0..corners.len() {
                line(
                    canvas,
                    corners[index],
                    corners[(index + 1) % corners.len()],
                    STROKE,
                    color,
                );
            }
        }
        Item::Color(index) => {
            // 圆形色点（mac：18 画布里 inset 3 的圆 = 直径 12），忽略传进来的 color
            let swatch = PALETTE[index.min(PALETTE.len() - 1)];
            fill_circle(canvas, (cx, cy), 6.0, swatch);
            // 常态描边 white 0.35 —— 白色点在深色底板上不描边会糊掉
            let outline = Rect::new(cx - 6.0, cy - 6.0, 12.0, 12.0);
            stroke_ellipse_in(
                canvas,
                &outline,
                1.0,
                Color {
                    r: 0xFF,
                    g: 0xFF,
                    b: 0xFF,
                    a: 0x59,
                },
            );
        }
        Item::Size(index) => {
            // 粗细档 = 实心圆点，直径按档位走
            let diameter = SIZE_DOTS[index.min(SIZE_DOTS.len() - 1)];
            fill_circle(canvas, (cx, cy), diameter / 2.0, color);
        }
        Item::Undo | Item::Redo => {
            // 一条横线加一个箭头，方向按撤销 / 重做分开
            let forward = matches!(item, Item::Redo);
            let (tail, tip) = if forward {
                ((left, cy), (right, cy))
            } else {
                ((right, cy), (left, cy))
            };
            line(canvas, tail, tip, STROKE, color);
            let head = box_rect.w * 0.4;
            let direction = if forward { -1.0 } else { 1.0 };
            line(
                canvas,
                tip,
                (tip.0 + head * direction, tip.1 - head * 0.7),
                STROKE,
                color,
            );
            line(
                canvas,
                tip,
                (tip.0 + head * direction, tip.1 + head * 0.7),
                STROKE,
                color,
            );
        }
        Item::Copy => {
            // 两个错开的方框
            let offset = box_rect.w * 0.25;
            stroke_rect_in(
                canvas,
                &Rect::new(left, top, box_rect.w - offset, box_rect.h - offset),
                STROKE,
                color,
            );
            stroke_rect_in(
                canvas,
                &Rect::new(
                    left + offset,
                    top + offset,
                    box_rect.w - offset,
                    box_rect.h - offset,
                ),
                STROKE,
                color,
            );
        }
        Item::Save => {
            // 向下的箭头落进一个托盘
            line(canvas, (cx, top), (cx, bottom - box_rect.h * 0.3), STROKE, color);
            let head = box_rect.w * 0.3;
            let tip = (cx, bottom - box_rect.h * 0.3);
            line(canvas, tip, (tip.0 - head, tip.1 - head), STROKE, color);
            line(canvas, tip, (tip.0 + head, tip.1 - head), STROKE, color);
            line(canvas, (left, bottom), (right, bottom), STROKE, color);
        }
        Item::Pin => {
            // 图钉：一个头加一根针
            stroke_ellipse_in(
                canvas,
                &Rect::new(cx - box_rect.w * 0.3, top, box_rect.w * 0.6, box_rect.h * 0.6),
                STROKE,
                color,
            );
            line(canvas, (cx, top + box_rect.h * 0.6), (cx, bottom), STROKE, color);
        }
        Item::Cancel => {
            line(canvas, (left, top), (right, bottom), STROKE, color);
            line(canvas, (right, top), (left, bottom), STROKE, color);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use baobox_core::geometry::Rect;

    fn blank(width: usize, height: usize) -> Vec<u8> {
        vec![0u8; width * height * 4]
    }

    fn state() -> ToolbarState {
        ToolbarState {
            tool: Some(Tool::Rect),
            color_index: 0,
            size_index: 1,
            can_undo: false,
            can_redo: false,
            hovered: None,
        }
    }

    /// 一个按钮框里有多少像素被画上了东西。
    fn ink(canvas: &Canvas<'_>, frame: &Rect) -> usize {
        let mut count = 0;
        for y in frame.y as i64..frame.bottom() as i64 {
            for x in frame.x as i64..frame.right() as i64 {
                if canvas.get(x, y).map(|p| p[3] != 0).unwrap_or(false) {
                    count += 1;
                }
            }
        }
        count
    }

    #[test]
    fn every_item_draws_something_and_nothing_escapes_its_button() {
        let items = [
            Item::Tool(Tool::Rect),
            Item::Tool(Tool::Ellipse),
            Item::Tool(Tool::Arrow),
            Item::Tool(Tool::Pen),
            Item::Tool(Tool::Highlighter),
            Item::Tool(Tool::Mosaic),
            Item::Tool(Tool::Text),
            Item::Tool(Tool::Eraser),
            Item::Color(2),
            Item::Size(0),
            Item::Size(2),
            Item::Undo,
            Item::Redo,
            Item::Copy,
            Item::Save,
            Item::Pin,
            Item::Cancel,
        ];
        for item in items {
            // 按钮放在画布正中，四周留白 —— 有东西溢出立刻看得出来
            let mut pixels = blank(60, 60);
            let mut canvas = Canvas::new(60, 60, &mut pixels).unwrap();
            let frame = Rect::new(16.0, 16.0, 28.0, 28.0);
            draw_icon(&mut canvas, &frame, item, ICON);

            assert!(ink(&canvas, &frame) > 4, "{item:?} 应该画出点东西");
            // 按钮之外一圈应当仍是空的
            for y in 0..60i64 {
                for x in 0..60i64 {
                    let inside = (16..44).contains(&x) && (16..44).contains(&y);
                    if !inside {
                        assert_eq!(
                            canvas.get(x, y).unwrap()[3],
                            0,
                            "{item:?} 的图标画到按钮外面去了：({x},{y})"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn selection_tints_the_icon_and_never_paints_a_background_block() {
        // mac 的选中态只染图标色（MAC_ALIGNMENT.md §2.5）
        assert_eq!(icon_color(Item::Tool(Tool::Rect), &state()), ACCENT);
        assert_eq!(icon_color(Item::Tool(Tool::Arrow), &state()), ICON);
        assert_eq!(icon_color(Item::Size(1), &state()), ACCENT);
        assert_eq!(icon_color(Item::Size(0), &state()), SIZE_IDLE, "未选中档更暗");

        // 没有背景块：按钮框的四角保持空白（图标画不到那里）
        let frame = Rect::new(4.0, 4.0, 28.0, 26.0);
        let mut pixels = blank(36, 36);
        let mut canvas = Canvas::new(36, 36, &mut pixels).unwrap();
        draw_button(&mut canvas, &frame, Item::Tool(Tool::Rect), &state());
        assert_eq!(canvas.get(5, 5).unwrap()[3], 0, "选中态不该再有底色块");

        // 选区阶段还没选工具（None）：谁都不该被染成 accent
        let mut none = state();
        none.tool = None;
        assert_eq!(icon_color(Item::Tool(Tool::Rect), &none), ICON);
    }

    #[test]
    fn undo_greys_out_when_there_is_nothing_to_undo() {
        let mut empty = state();
        empty.can_undo = false;
        assert_eq!(icon_color(Item::Undo, &empty), ICON_DISABLED);
        empty.can_undo = true;
        assert_eq!(icon_color(Item::Undo, &empty), ICON);
        // 取消与其他出口同色 —— mac 没有红色警示态
        assert_eq!(icon_color(Item::Cancel, &empty), ICON);
    }

    #[test]
    fn the_selected_swatch_gets_a_white_ring() {
        let frame = Rect::new(4.0, 4.0, 28.0, 26.0);
        let mut pixels = blank(36, 36);
        let mut canvas = Canvas::new(36, 36, &mut pixels).unwrap();
        // color_index = 0 → 选中
        draw_button(&mut canvas, &frame, Item::Color(0), &state());
        // 环在色点（直径 12）之外、按钮框之内 —— 检查环半径附近有白色像素
        let (cx, cy) = (4.0 + 14.0, 4.0 + 13.0);
        let probe = canvas.get((cx + 8.0) as i64, cy as i64).unwrap();
        assert!(probe[3] != 0, "选中色块外圈应有白环");
    }

    #[test]
    fn a_colour_swatch_shows_its_own_colour_not_the_icon_colour() {
        let mut pixels = blank(40, 40);
        let mut canvas = Canvas::new(40, 40, &mut pixels).unwrap();
        let frame = Rect::new(6.0, 6.0, 28.0, 28.0);
        // 传一个明显不同的图标色进去，色块应当无视它
        draw_icon(&mut canvas, &frame, Item::Color(2), Color::rgb(0, 0, 0));
        let center = canvas.get(20, 20).unwrap();
        let swatch = PALETTE[2];
        assert_eq!([center[0], center[1], center[2]], [swatch.r, swatch.g, swatch.b]);
    }

    #[test]
    fn an_out_of_range_swatch_index_clamps_instead_of_panicking() {
        let mut pixels = blank(40, 40);
        let mut canvas = Canvas::new(40, 40, &mut pixels).unwrap();
        draw_icon(
            &mut canvas,
            &Rect::new(6.0, 6.0, 28.0, 28.0),
            Item::Color(999),
            ICON,
        );
    }

    #[test]
    fn the_whole_bar_covers_its_frame_with_the_panel_colour() {
        let toolbar = Toolbar::layout(
            &Rect::new(20.0, 20.0, 700.0, 200.0),
            &Rect::new(0.0, 0.0, 1000.0, 600.0),
        );
        let width = 1000usize;
        let height = 600usize;
        let mut pixels = blank(width, height);
        let mut canvas = Canvas::new(width, height, &mut pixels).unwrap();
        draw_toolbar(&mut canvas, &toolbar, &state());

        // 底板铺满（避开圆角，取内缩 12 的点）
        for (x, y) in [
            (toolbar.frame.x + 12.0, toolbar.frame.y + 12.0),
            (toolbar.frame.right() - 12.0, toolbar.frame.bottom() - 12.0),
        ] {
            assert_ne!(
                canvas.get(x as i64, y as i64).unwrap()[3],
                0,
                "底板应铺满整个 frame"
            );
        }
        // 圆角：四个角尖上的像素被削掉
        assert_eq!(
            canvas
                .get(toolbar.frame.x as i64, toolbar.frame.y as i64)
                .unwrap()[3],
            0,
            "圆角处不该有底板"
        );
        // 底板之外没被碰过
        assert_eq!(
            canvas.get(toolbar.frame.x as i64 - 3, toolbar.frame.y as i64).unwrap()[3],
            0
        );
    }
}
