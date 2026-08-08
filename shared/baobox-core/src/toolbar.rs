//! 标注工具条的布局与命中测试。
//!
//! 平台层只负责按这里给出的矩形把按钮画出来、把点击坐标丢进 [`Toolbar::hit`]。
//! 于是「工具条在选区下方、贴不下就翻到上方、再贴不下就压进选区内部」这条规则
//! 三平台一致，不必各写一遍（也就不会各错一遍）。
//!
//! **一切数值以 `docs/screenshot-parity/MAC_ALIGNMENT.md` 为准**（提取自 macOS
//! 实现）：双行结构 —— 第 1 行是工具 + 撤销重做 + 出口，第 2 行是粗细三档 +
//! 七色盘，第 2 行只在所选工具需要样式时展开（橡皮、马赛克不展开）。

use crate::annotation::{Color, Tool};
use crate::geometry::Rect;

/// 工具条上的一项。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Item {
    /// 切换到某个标注工具
    Tool(Tool),
    /// 切换画笔颜色（下标指向 [`PALETTE`]）
    Color(usize),
    /// 切换粗细档（下标指向 [`STROKE_SIZES`] / [`TEXT_SIZES`]）
    Size(usize),
    /// 撤销
    Undo,
    /// 重做
    Redo,
    /// 复制到剪贴板并结束
    Copy,
    /// 保存到文件并结束
    Save,
    /// 钉到屏幕上
    Pin,
    /// 取消
    Cancel,
}

/// 可选颜色。与 mac 端一致的 7 色（AppKit 系统色的 sRGB 定值），红打头且默认。
pub const PALETTE: [Color; 7] = [
    Color::rgb(0xFF, 0x3B, 0x30), // systemRed
    Color::rgb(0xFF, 0x95, 0x00), // systemOrange
    Color::rgb(0xFF, 0xCC, 0x00), // systemYellow
    Color::rgb(0x28, 0xCD, 0x41), // systemGreen
    Color::rgb(0x00, 0x7A, 0xFF), // systemBlue
    Color::rgb(0x00, 0x00, 0x00), // 黑
    Color::rgb(0xFF, 0xFF, 0xFF), // 白（深色截图上用）
];

/// 出厂默认颜色在 [`PALETTE`] 里的下标。
pub const DEFAULT_COLOR: usize = 0;

/// 线宽三档（细 / 中 / 粗），与 mac 一致。
pub const STROKE_SIZES: [f64; 3] = [2.0, 3.0, 5.0];

/// 字号三档，与线宽档一一对应。
pub const TEXT_SIZES: [f64; 3] = [14.0, 18.0, 24.0];

/// 出厂默认档位（中档）。
pub const DEFAULT_SIZE: usize = 1;

/// 按钮宽（mac 是 28 × 26）。
pub const BUTTON_W: f64 = 28.0;
/// 按钮高。
pub const BUTTON_H: f64 = 26.0;

/// 第 1 行按钮间距。
pub const ROW1_GAP: f64 = 2.0;

/// 第 2 行按钮间距。
pub const ROW2_GAP: f64 = 5.0;

/// 两行之间的间距。
pub const ROW_SPACING: f64 = 4.0;

/// 工具条水平内边距。
pub const PADDING_X: f64 = 8.0;
/// 工具条垂直内边距。
pub const PADDING_Y: f64 = 6.0;

/// 分隔符宽（1 × 16 竖线）。
pub const SEPARATOR_W: f64 = 1.0;
/// 分隔符高。
pub const SEPARATOR_H: f64 = 16.0;
/// 分隔符两侧的留白。
pub const SEPARATOR_PAD: f64 = 4.0;

/// 工具条与选区的间隙。
pub const MARGIN: f64 = 8.0;

/// 第 1 行的项，按显示顺序。`None` = 分隔符。
/// ⚠️ 出口组顺序与 mac 一致：**取消最左、复制最右**。
const ROW1: &[Option<Item>] = &[
    Some(Item::Tool(Tool::Rect)),
    Some(Item::Tool(Tool::Ellipse)),
    Some(Item::Tool(Tool::Arrow)),
    Some(Item::Tool(Tool::Pen)),
    Some(Item::Tool(Tool::Highlighter)),
    Some(Item::Tool(Tool::Mosaic)),
    Some(Item::Tool(Tool::Text)),
    Some(Item::Tool(Tool::Eraser)),
    None,
    Some(Item::Undo),
    Some(Item::Redo),
    None,
    Some(Item::Cancel),
    Some(Item::Pin),
    Some(Item::Save),
    Some(Item::Copy),
];

/// 第 2 行（参数行）：粗细三档 | 分隔 | 七色。
const ROW2: &[Option<Item>] = &[
    Some(Item::Size(0)),
    Some(Item::Size(1)),
    Some(Item::Size(2)),
    None,
    Some(Item::Color(0)),
    Some(Item::Color(1)),
    Some(Item::Color(2)),
    Some(Item::Color(3)),
    Some(Item::Color(4)),
    Some(Item::Color(5)),
    Some(Item::Color(6)),
];

/// 一个已经算好位置的按钮。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Button {
    /// 这个按钮干什么
    pub item: Item,
    /// 屏幕坐标下的矩形
    pub frame: Rect,
}

/// 算好位置的工具条。
#[derive(Debug, Clone)]
pub struct Toolbar {
    /// 工具条整体的矩形
    pub frame: Rect,
    /// 全部按钮
    pub buttons: Vec<Button>,
    /// 分隔竖线（平台层照着画）
    pub separators: Vec<Rect>,
}

impl Toolbar {
    /// 单行工具条（选区调整阶段：还没选工具，参数行不展开）。
    pub fn layout(selection: &Rect, screen: &Rect) -> Toolbar {
        Self::layout_with_style_row(selection, screen, false)
    }

    /// 按选区与屏幕范围算出工具条位置。
    ///
    /// `style_row` = 是否展开参数行（粗细 + 颜色）。
    /// 放置优先级：选区下方 → 选区上方 → 压在选区内部顶端（mac 同序）。
    pub fn layout_with_style_row(selection: &Rect, screen: &Rect, style_row: bool) -> Toolbar {
        let row1_width = row_width(ROW1, ROW1_GAP);
        let row2_width = row_width(ROW2, ROW2_GAP);
        let content_width = if style_row {
            row1_width.max(row2_width)
        } else {
            row1_width
        };
        let width = content_width + PADDING_X * 2.0;
        let height = if style_row {
            BUTTON_H * 2.0 + ROW_SPACING + PADDING_Y * 2.0
        } else {
            BUTTON_H + PADDING_Y * 2.0
        };

        // 水平方向：与选区右端对齐，超出屏幕则往回收
        let mut x = selection.right() - width;
        x = x.clamp(screen.x, (screen.right() - width).max(screen.x));

        let below = selection.bottom() + MARGIN;
        let above = selection.y - MARGIN - height;
        let y = if below + height <= screen.bottom() {
            below
        } else if above >= screen.y {
            above
        } else {
            // 上下都放不下 → 压在选区内部顶端（mac 同侧）
            (selection.y + MARGIN).max(screen.y)
        };

        let frame = Rect::new(x, y, width, height);
        let mut buttons = Vec::new();
        let mut separators = Vec::new();
        fill_row(
            ROW1,
            ROW1_GAP,
            x + PADDING_X,
            y + PADDING_Y,
            &mut buttons,
            &mut separators,
        );
        if style_row {
            fill_row(
                ROW2,
                ROW2_GAP,
                x + PADDING_X,
                y + PADDING_Y + BUTTON_H + ROW_SPACING,
                &mut buttons,
                &mut separators,
            );
        }
        Toolbar {
            frame,
            buttons,
            separators,
        }
    }

    /// 点在哪个按钮上。
    pub fn hit(&self, point: (f64, f64)) -> Option<Item> {
        self.buttons
            .iter()
            .find(|button| button.frame.contains(point.0, point.1))
            .map(|button| button.item)
    }

    /// 点是否落在工具条上（落在上面就不该被当成画笔落笔）。
    pub fn contains(&self, point: (f64, f64)) -> bool {
        self.frame.contains(point.0, point.1)
    }
}

/// 一行内容的总宽（不含工具条左右内边距）。
fn row_width(row: &[Option<Item>], gap: f64) -> f64 {
    let mut width = 0.0;
    for slot in row {
        match slot {
            Some(_) => width += BUTTON_W + gap,
            None => width += SEPARATOR_PAD + SEPARATOR_W + SEPARATOR_PAD,
        }
    }
    (width - gap).max(0.0)
}

/// 把一行的按钮与分隔符摆出来。
fn fill_row(
    row: &[Option<Item>],
    gap: f64,
    start_x: f64,
    y: f64,
    buttons: &mut Vec<Button>,
    separators: &mut Vec<Rect>,
) {
    let mut cursor = start_x;
    for slot in row {
        match slot {
            Some(item) => {
                buttons.push(Button {
                    item: *item,
                    frame: Rect::new(cursor, y, BUTTON_W, BUTTON_H),
                });
                cursor += BUTTON_W + gap;
            }
            None => {
                cursor += SEPARATOR_PAD;
                separators.push(Rect::new(
                    cursor,
                    y + (BUTTON_H - SEPARATOR_H) / 2.0,
                    SEPARATOR_W,
                    SEPARATOR_H,
                ));
                cursor += SEPARATOR_W + SEPARATOR_PAD;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen() -> Rect {
        Rect::new(0.0, 0.0, 1920.0, 1080.0)
    }

    #[test]
    fn sits_below_the_selection_when_there_is_room() {
        let selection = Rect::new(100.0, 100.0, 400.0, 300.0);
        let bar = Toolbar::layout(&selection, &screen());
        assert!(bar.frame.y >= selection.bottom(), "应在选区下方");
        assert!(bar.frame.bottom() <= screen().bottom());
    }

    #[test]
    fn flips_above_when_the_selection_touches_the_bottom() {
        let selection = Rect::new(100.0, 900.0, 400.0, 175.0);
        let bar = Toolbar::layout(&selection, &screen());
        assert!(bar.frame.bottom() <= selection.y, "下方放不下时应翻到上方");
    }

    #[test]
    fn falls_back_inside_when_the_selection_fills_the_screen() {
        let selection = Rect::new(0.0, 0.0, 1920.0, 1080.0);
        let bar = Toolbar::layout(&selection, &screen());
        assert!(bar.frame.y >= screen().y, "不能跑到屏幕外");
        assert!(bar.frame.bottom() <= screen().bottom() + 1e-9);
        assert!(
            selection.contains(bar.frame.x, bar.frame.y),
            "兜底时应压在选区内部"
        );
    }

    #[test]
    fn never_runs_off_the_left_or_right_edge() {
        let narrow = Rect::new(0.0, 100.0, 40.0, 40.0);
        let bar = Toolbar::layout(&narrow, &screen());
        assert!(bar.frame.x >= screen().x, "不能越过左边缘");

        let right = Rect::new(1880.0, 100.0, 40.0, 40.0);
        let bar = Toolbar::layout(&right, &screen());
        assert!(bar.frame.right() <= screen().right() + 1e-9, "不能越过右边缘");
    }

    #[test]
    fn the_first_row_follows_the_mac_order_exactly() {
        // 顺序以 docs/screenshot-parity/MAC_ALIGNMENT.md §2.2 为准：
        // 8 工具 | 撤销 重做 | 取消 贴图 保存 复制（取消最左、复制最右）
        let bar = Toolbar::layout(&Rect::new(100.0, 100.0, 800.0, 400.0), &screen());
        let items: Vec<Item> = bar.buttons.iter().map(|b| b.item).collect();
        assert_eq!(
            items,
            vec![
                Item::Tool(Tool::Rect),
                Item::Tool(Tool::Ellipse),
                Item::Tool(Tool::Arrow),
                Item::Tool(Tool::Pen),
                Item::Tool(Tool::Highlighter),
                Item::Tool(Tool::Mosaic),
                Item::Tool(Tool::Text),
                Item::Tool(Tool::Eraser),
                Item::Undo,
                Item::Redo,
                Item::Cancel,
                Item::Pin,
                Item::Save,
                Item::Copy,
            ]
        );
        // 单行模式不出现参数行
        assert!(bar
            .buttons
            .iter()
            .all(|b| !matches!(b.item, Item::Color(_) | Item::Size(_))));
        // 第 1 行两条分隔符
        assert_eq!(bar.separators.len(), 2);
    }

    #[test]
    fn the_style_row_adds_sizes_and_the_seven_mac_colours() {
        let bar = Toolbar::layout_with_style_row(
            &Rect::new(100.0, 100.0, 800.0, 400.0),
            &screen(),
            true,
        );
        let sizes: Vec<usize> = bar
            .buttons
            .iter()
            .filter_map(|b| match b.item {
                Item::Size(index) => Some(index),
                _ => None,
            })
            .collect();
        assert_eq!(sizes, vec![0, 1, 2]);
        let mut colors: Vec<usize> = bar
            .buttons
            .iter()
            .filter_map(|b| match b.item {
                Item::Color(index) => Some(index),
                _ => None,
            })
            .collect();
        colors.sort_unstable();
        assert_eq!(colors, (0..PALETTE.len()).collect::<Vec<_>>());
        // 双行比单行高
        let single = Toolbar::layout(&Rect::new(100.0, 100.0, 800.0, 400.0), &screen());
        assert!(bar.frame.h > single.frame.h);
        // 第 2 行的按钮都在第 1 行下面
        let row1_bottom = bar.buttons[0].frame.bottom();
        for button in &bar.buttons {
            if matches!(button.item, Item::Color(_) | Item::Size(_)) {
                assert!(button.frame.y >= row1_bottom, "参数行该在第 1 行下面");
            }
        }
        // 分隔符：行 1 两条 + 行 2 一条
        assert_eq!(bar.separators.len(), 3);
    }

    #[test]
    fn buttons_do_not_overlap_and_stay_inside_the_bar() {
        let bar = Toolbar::layout_with_style_row(
            &Rect::new(100.0, 100.0, 800.0, 400.0),
            &screen(),
            true,
        );
        for button in &bar.buttons {
            assert!(button.frame.x >= bar.frame.x - 1e-9);
            assert!(button.frame.right() <= bar.frame.right() + 1e-9);
            assert!(button.frame.bottom() <= bar.frame.bottom() + 1e-9);
        }
    }

    #[test]
    fn hit_testing_finds_the_right_button() {
        let bar = Toolbar::layout(&Rect::new(100.0, 100.0, 800.0, 400.0), &screen());
        let first = bar.buttons[0];
        let center = (
            first.frame.x + first.frame.w / 2.0,
            first.frame.y + first.frame.h / 2.0,
        );
        assert_eq!(bar.hit(center), Some(first.item));
        assert_eq!(bar.hit((0.0, 0.0)), None);
        assert!(!bar.contains((0.0, 0.0)));
        assert!(bar.contains(center));
    }

    #[test]
    fn clicks_on_a_separator_hit_nothing_but_stay_inside_the_bar() {
        let bar = Toolbar::layout(&Rect::new(100.0, 100.0, 800.0, 400.0), &screen());
        let separator = bar.separators[0];
        let point = (separator.x, separator.y + separator.h / 2.0);
        assert_eq!(bar.hit(point), None, "分隔符不该命中按钮");
        assert!(bar.contains(point), "但它仍在工具条范围内");
    }

    #[test]
    fn palette_and_size_tables_line_up_with_the_mac_spec() {
        // 值以 MAC_ALIGNMENT.md §2.3 / §2.4 为准
        assert_eq!(PALETTE.len(), 7);
        assert_eq!(PALETTE[0], Color::rgb(0xFF, 0x3B, 0x30), "默认红是 systemRed");
        assert_eq!(DEFAULT_COLOR, 0);
        assert_eq!(STROKE_SIZES, [2.0, 3.0, 5.0]);
        assert_eq!(TEXT_SIZES, [14.0, 18.0, 24.0]);
        assert_eq!(DEFAULT_SIZE, 1, "默认中档");
        assert_eq!(STROKE_SIZES[DEFAULT_SIZE], 3.0);
    }
}
