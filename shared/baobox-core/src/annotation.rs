//! 标注模型：图形、撤销 / 重做、橡皮「点删整笔」。
//!
//! 与 macOS 侧 `Annotation.swift` 同一套语义，但这里不含任何绘制代码 ——
//! 平台层负责按 [`Shape`] 画出来。

use crate::geometry::Rect;

/// 标注工具。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tool {
    /// 空心矩形
    Rect,
    /// 空心椭圆
    Ellipse,
    /// 箭头
    Arrow,
    /// 自由手绘
    Pen,
    /// 半透明荧光笔
    Highlighter,
    /// 马赛克
    Mosaic,
    /// 文字
    Text,
    /// 橡皮（点一下删掉整笔）
    Eraser,
}

impl Tool {
    /// 该工具是否由「两点」定义（矩形 / 椭圆 / 箭头），其余是折线或文字。
    pub fn is_two_point(&self) -> bool {
        matches!(self, Tool::Rect | Tool::Ellipse | Tool::Arrow)
    }

    /// 橡皮不产生图形，只删别人。
    pub fn draws(&self) -> bool {
        !matches!(self, Tool::Eraser)
    }
}

/// RGBA 颜色。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Color {
    /// 红
    pub r: u8,
    /// 绿
    pub g: u8,
    /// 蓝
    pub b: u8,
    /// 不透明度
    pub a: u8,
}

impl Color {
    /// 不透明颜色。
    pub const fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b, a: 255 }
    }
}

/// 一笔标注。
#[derive(Debug, Clone, PartialEq)]
pub struct Shape {
    /// 用哪个工具画的
    pub tool: Tool,
    /// 折线点（两点型图形只用首尾两个）
    pub points: Vec<(f64, f64)>,
    /// 颜色
    pub color: Color,
    /// 线宽 / 字号
    pub width: f64,
    /// 文字内容（仅 `Tool::Text`）
    pub text: Option<String>,
}

impl Shape {
    /// 包围盒。空图形返回零矩形。
    pub fn bounds(&self) -> Rect {
        if self.points.is_empty() {
            return Rect::new(0.0, 0.0, 0.0, 0.0);
        }
        let (mut min_x, mut min_y) = self.points[0];
        let (mut max_x, mut max_y) = self.points[0];
        for &(x, y) in &self.points {
            min_x = min_x.min(x);
            min_y = min_y.min(y);
            max_x = max_x.max(x);
            max_y = max_y.max(y);
        }
        Rect::new(min_x, min_y, max_x - min_x, max_y - min_y)
    }

    /// 点是否落在这一笔上（容差 = 线宽的一半再加一点，方便点中细线）。
    pub fn hit(&self, px: f64, py: f64) -> bool {
        let tolerance = (self.width / 2.0).max(4.0);
        match self.tool {
            // 两点型按包围盒的**边框**判定，中间是空的
            Tool::Rect | Tool::Ellipse => {
                let b = self.bounds();
                let outer = Rect::new(
                    b.x - tolerance,
                    b.y - tolerance,
                    b.w + tolerance * 2.0,
                    b.h + tolerance * 2.0,
                );
                if !outer.contains(px, py) {
                    return false;
                }
                let inner = Rect::new(
                    b.x + tolerance,
                    b.y + tolerance,
                    (b.w - tolerance * 2.0).max(0.0),
                    (b.h - tolerance * 2.0).max(0.0),
                );
                !inner.contains(px, py)
            }
            // 其余按到折线各段的距离判定
            _ => self
                .points
                .windows(2)
                .any(|seg| distance_to_segment((px, py), seg[0], seg[1]) <= tolerance),
        }
    }
}

/// 点到线段的距离。
fn distance_to_segment(p: (f64, f64), a: (f64, f64), b: (f64, f64)) -> f64 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let len_sq = dx * dx + dy * dy;
    if len_sq == 0.0 {
        return (p.0 - a.0).hypot(p.1 - a.1);
    }
    let t = (((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len_sq).clamp(0.0, 1.0);
    (p.0 - (a.0 + t * dx)).hypot(p.1 - (a.1 + t * dy))
}

/// 标注文档：图形列表 + 撤销 / 重做。
#[derive(Debug, Clone, Default)]
pub struct Document {
    shapes: Vec<Shape>,
    undo: Vec<Vec<Shape>>,
    redo: Vec<Vec<Shape>>,
}

impl Document {
    /// 空文档。
    pub fn new() -> Self {
        Self::default()
    }

    /// 当前所有图形（绘制顺序）。
    pub fn shapes(&self) -> &[Shape] {
        &self.shapes
    }

    /// 有没有可撤销的操作。
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    /// 有没有可重做的操作。
    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    /// 添加一笔。
    pub fn add(&mut self, shape: Shape) {
        self.checkpoint();
        self.shapes.push(shape);
    }

    /// 橡皮：删掉命中的**最上面那一笔**（整笔，不是擦局部）。返回是否删掉了东西。
    ///
    /// 从后往前找 —— 后画的盖在上面，用户点的是看得见的那一笔。
    pub fn erase_at(&mut self, px: f64, py: f64) -> bool {
        if let Some(index) = self.shapes.iter().rposition(|s| s.hit(px, py)) {
            self.checkpoint();
            self.shapes.remove(index);
            true
        } else {
            false
        }
    }

    /// 撤销。
    pub fn undo(&mut self) -> bool {
        if let Some(previous) = self.undo.pop() {
            self.redo.push(self.shapes.clone());
            self.shapes = previous;
            true
        } else {
            false
        }
    }

    /// 重做。
    pub fn redo(&mut self) -> bool {
        if let Some(next) = self.redo.pop() {
            self.undo.push(self.shapes.clone());
            self.shapes = next;
            true
        } else {
            false
        }
    }

    /// 清空（可撤销）。
    pub fn clear(&mut self) {
        if self.shapes.is_empty() {
            return;
        }
        self.checkpoint();
        self.shapes.clear();
    }

    /// 记一个快照，并清掉重做栈（新操作让原来的重做分支失效）。
    fn checkpoint(&mut self) {
        self.undo.push(self.shapes.clone());
        self.redo.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pen(points: Vec<(f64, f64)>) -> Shape {
        Shape {
            tool: Tool::Pen,
            points,
            color: Color::rgb(255, 0, 0),
            width: 4.0,
            text: None,
        }
    }

    #[test]
    fn undo_redo_walks_the_history_both_ways() {
        let mut doc = Document::new();
        assert!(!doc.can_undo());
        doc.add(pen(vec![(0.0, 0.0), (10.0, 10.0)]));
        doc.add(pen(vec![(20.0, 20.0), (30.0, 30.0)]));
        assert_eq!(doc.shapes().len(), 2);

        assert!(doc.undo());
        assert_eq!(doc.shapes().len(), 1);
        assert!(doc.undo());
        assert_eq!(doc.shapes().len(), 0);
        assert!(!doc.undo());

        assert!(doc.redo());
        assert!(doc.redo());
        assert_eq!(doc.shapes().len(), 2);
        assert!(!doc.redo());
    }

    #[test]
    fn a_new_edit_invalidates_the_redo_branch() {
        let mut doc = Document::new();
        doc.add(pen(vec![(0.0, 0.0), (10.0, 10.0)]));
        doc.undo();
        assert!(doc.can_redo());
        doc.add(pen(vec![(50.0, 50.0), (60.0, 60.0)]));
        assert!(!doc.can_redo(), "新操作之后不应该还能重做旧分支");
    }

    #[test]
    fn eraser_removes_the_whole_stroke_not_a_part() {
        let mut doc = Document::new();
        doc.add(pen(vec![(0.0, 0.0), (100.0, 0.0)]));
        // 点在这一笔中间
        assert!(doc.erase_at(50.0, 1.0));
        assert_eq!(doc.shapes().len(), 0, "整笔应被删掉");
        assert!(doc.undo(), "橡皮也要能撤销");
        assert_eq!(doc.shapes().len(), 1);
    }

    #[test]
    fn eraser_takes_the_topmost_stroke_under_the_cursor() {
        let mut doc = Document::new();
        doc.add(pen(vec![(0.0, 0.0), (100.0, 0.0)]));
        let mut top = pen(vec![(0.0, 0.0), (100.0, 0.0)]);
        top.color = Color::rgb(0, 0, 255);
        doc.add(top.clone());
        doc.erase_at(50.0, 0.0);
        // 删掉的应该是后画的那笔（蓝色），留下红色
        assert_eq!(doc.shapes().len(), 1);
        assert_eq!(doc.shapes()[0].color, Color::rgb(255, 0, 0));
    }

    #[test]
    fn eraser_misses_the_hollow_middle_of_a_rectangle() {
        let mut doc = Document::new();
        doc.add(Shape {
            tool: Tool::Rect,
            points: vec![(0.0, 0.0), (200.0, 200.0)],
            color: Color::rgb(0, 0, 0),
            width: 4.0,
            text: None,
        });
        // 正中央是空的，点不到
        assert!(!doc.erase_at(100.0, 100.0));
        // 边框上点得到
        assert!(doc.erase_at(0.0, 100.0));
    }

    #[test]
    fn two_point_tools_are_flagged_correctly() {
        assert!(Tool::Rect.is_two_point());
        assert!(Tool::Arrow.is_two_point());
        assert!(!Tool::Pen.is_two_point());
        assert!(!Tool::Eraser.draws());
        assert!(Tool::Mosaic.draws());
    }
}
