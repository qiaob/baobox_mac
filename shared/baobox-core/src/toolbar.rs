//! 标注工具条的布局与命中测试。
//!
//! 平台层只负责按这里给出的矩形把按钮画出来、把点击坐标丢进 [`Toolbar::hit`]。
//! 于是「工具条在选区下方、贴不下就翻到上方、再贴不下就压进选区内部」这条规则
//! 三平台一致，不必各写一遍（也就不会各错一遍）。

use crate::annotation::Tool;
use crate::geometry::Rect;

/// 工具条上的一项。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Item {
    /// 切换到某个标注工具
    Tool(Tool),
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

/// 按钮边长（正方形）。
pub const BUTTON_SIZE: f64 = 28.0;

/// 按钮间距。
pub const BUTTON_GAP: f64 = 4.0;

/// 工具条内边距。
pub const PADDING: f64 = 6.0;

/// 工具条与选区的间隙。
pub const MARGIN: f64 = 8.0;

/// 分组之间的额外间隙（工具 / 编辑 / 输出三组）。
pub const GROUP_GAP: f64 = 10.0;

/// 工具条上的项，按显示顺序。分组用 `None` 隔开。
const LAYOUT: &[Option<Item>] = &[
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
    Some(Item::Pin),
    Some(Item::Save),
    Some(Item::Copy),
    Some(Item::Cancel),
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
}

impl Toolbar {
    /// 按选区与屏幕范围算出工具条位置。
    ///
    /// 放置优先级：选区下方 → 选区上方 → 压在选区内部底端。
    /// 最后一种是兜底 —— 选区几乎占满屏幕时上下都放不下，压进去总比跑到屏幕外好。
    pub fn layout(selection: &Rect, screen: &Rect) -> Toolbar {
        let width = Self::content_width() + PADDING * 2.0;
        let height = BUTTON_SIZE + PADDING * 2.0;

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
            // 上下都放不下 → 压在选区内部底端
            (selection.bottom() - height - MARGIN).max(screen.y)
        };

        let frame = Rect::new(x, y, width, height);
        let mut buttons = Vec::new();
        let mut cursor = x + PADDING;
        for slot in LAYOUT {
            match slot {
                Some(item) => {
                    buttons.push(Button {
                        item: *item,
                        frame: Rect::new(cursor, y + PADDING, BUTTON_SIZE, BUTTON_SIZE),
                    });
                    cursor += BUTTON_SIZE + BUTTON_GAP;
                }
                None => cursor += GROUP_GAP,
            }
        }
        Toolbar { frame, buttons }
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

    /// 工具条里按钮区域的总宽（不含左右内边距）。
    fn content_width() -> f64 {
        let mut width = 0.0;
        let mut buttons = 0usize;
        for slot in LAYOUT {
            match slot {
                Some(_) => {
                    width += BUTTON_SIZE + BUTTON_GAP;
                    buttons += 1;
                }
                None => width += GROUP_GAP,
            }
        }
        let _ = buttons;
        // 最后一个按钮后面不需要间距
        (width - BUTTON_GAP).max(0.0)
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
        // 选区几乎占满屏幕，上下都放不下
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
        // 选区贴着左边缘，工具条比它宽
        let narrow = Rect::new(0.0, 100.0, 40.0, 40.0);
        let bar = Toolbar::layout(&narrow, &screen());
        assert!(bar.frame.x >= screen().x, "不能越过左边缘");

        // 选区贴着右边缘
        let right = Rect::new(1880.0, 100.0, 40.0, 40.0);
        let bar = Toolbar::layout(&right, &screen());
        assert!(bar.frame.right() <= screen().right() + 1e-9, "不能越过右边缘");
    }

    #[test]
    fn every_declared_item_gets_a_button() {
        let bar = Toolbar::layout(&Rect::new(100.0, 100.0, 800.0, 400.0), &screen());
        let expected = LAYOUT.iter().filter(|slot| slot.is_some()).count();
        assert_eq!(bar.buttons.len(), expected);
        // 八个标注工具都在
        for tool in [
            Tool::Rect,
            Tool::Ellipse,
            Tool::Arrow,
            Tool::Pen,
            Tool::Highlighter,
            Tool::Mosaic,
            Tool::Text,
            Tool::Eraser,
        ] {
            assert!(
                bar.buttons.iter().any(|b| b.item == Item::Tool(tool)),
                "{tool:?} 应当有按钮"
            );
        }
    }

    #[test]
    fn buttons_do_not_overlap_and_stay_inside_the_bar() {
        let bar = Toolbar::layout(&Rect::new(100.0, 100.0, 800.0, 400.0), &screen());
        for pair in bar.buttons.windows(2) {
            assert!(
                pair[0].frame.right() <= pair[1].frame.x + 1e-9,
                "按钮不应重叠"
            );
        }
        for button in &bar.buttons {
            assert!(button.frame.x >= bar.frame.x - 1e-9);
            assert!(button.frame.right() <= bar.frame.right() + 1e-9);
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
        // 工具条外面点不中任何按钮
        assert_eq!(bar.hit((0.0, 0.0)), None);
        assert!(!bar.contains((0.0, 0.0)));
        assert!(bar.contains(center));
    }

    #[test]
    fn clicks_in_the_group_gaps_hit_nothing() {
        let bar = Toolbar::layout(&Rect::new(100.0, 100.0, 800.0, 400.0), &screen());
        // 第八个按钮（橡皮）与第九个（撤销）之间是分组间隙
        let eraser = bar.buttons[7];
        let undo = bar.buttons[8];
        let gap_x = (eraser.frame.right() + undo.frame.x) / 2.0;
        let gap_y = eraser.frame.y + eraser.frame.h / 2.0;
        assert_eq!(bar.hit((gap_x, gap_y)), None, "分组间隙不该命中按钮");
        assert!(bar.contains((gap_x, gap_y)), "但它仍在工具条范围内");
    }
}
