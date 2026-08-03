//! 标注编辑器状态机。
//!
//! 与 [`crate::selection`] 是同一个套路：**规则写一份，画法各写各的**。
//! 平台层把鼠标键盘事件喂进来，读走「当前该画哪些图形」和「用户最后按了什么」，
//! 三个平台的标注行为因此不会各自漂移。
//!
//! 规格（三平台必须一致）：
//!
//! - 点在工具条上**永远不落笔** —— 这是最容易漏的一条，漏了就会「点按钮的同时画一道」
//! - 矩形 / 椭圆 / 箭头 / 马赛克：按下拖到松开，一次画成
//! - 画笔 / 荧光笔：按住的轨迹全程记录
//! - 文字：点一下开输入框，再打字，⏎ 落定
//! - 橡皮：点一下删掉命中的**最上面那一整笔**
//! - Ctrl+Z 撤销 / Ctrl+Shift+Z 与 Ctrl+Y 重做 / Ctrl+C 复制 / Ctrl+S 保存
//! - `[` `]` 调线宽
//! - Esc：正在输入文字时只取消这段文字，否则退出编辑器
//!
//! # 为什么正在画的那一笔不进文档
//!
//! 拖拽过程中的图形放在 [`Editor::pending`]，松手才 `Document::add`。
//! 否则每移动一像素都会往撤销栈压一层，一次拖拽结束后要按几百下 Ctrl+Z 才撤销得掉。

use crate::annotation::{Color, Document, Shape, Tool};
use crate::geometry::Rect;
use crate::toolbar::{Item, Toolbar, DEFAULT_COLOR, PALETTE};

/// 默认线宽。
pub const DEFAULT_WIDTH: f64 = 4.0;

/// 线宽可调范围。
pub const MIN_WIDTH: f64 = 1.0;
/// 线宽可调范围。
pub const MAX_WIDTH: f64 = 32.0;

/// `[` / `]` 每次调整的量。
pub const WIDTH_STEP: f64 = 1.0;

/// 文字工具的字号相对线宽的倍数 —— 线宽 4 时约 16pt，接近截图标注的常用大小。
pub const TEXT_SIZE_FACTOR: f64 = 4.0;

/// 编辑器结束时用户选了什么。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditorOutcome {
    /// 复制到剪贴板
    Copy,
    /// 保存到文件
    Save,
    /// 钉在屏幕上
    Pin,
    /// 放弃这张截图
    Cancel,
}

/// 编辑器认得的按键。字符输入走 [`Editor::type_char`]，不在这里。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditorKey {
    /// Esc
    Escape,
    /// ⏎
    Enter,
    /// 退格（文字输入时删一个字）
    Backspace,
    /// Z
    Z,
    /// Y
    Y,
    /// C
    C,
    /// S
    S,
    /// `[`
    BracketLeft,
    /// `]`
    BracketRight,
}

/// 按键时按住的修饰键。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Modifiers {
    /// Ctrl（macOS 上是 ⌘，由那边映射）
    pub ctrl: bool,
    /// Shift
    pub shift: bool,
}

impl Modifiers {
    /// 什么都没按。
    pub const NONE: Modifiers = Modifiers {
        ctrl: false,
        shift: false,
    };

    /// 只按了 Ctrl。
    pub const CTRL: Modifiers = Modifiers {
        ctrl: true,
        shift: false,
    };
}

/// 正在输入的一段文字。
#[derive(Debug, Clone, PartialEq)]
pub struct PendingText {
    /// 左上角位置
    pub origin: (f64, f64),
    /// 已经打进去的内容
    pub text: String,
}

/// 标注编辑器。
#[derive(Debug, Clone)]
pub struct Editor {
    document: Document,
    toolbar: Toolbar,
    /// 图像在屏幕坐标里的位置与尺寸；落笔点会被夹进这个范围
    image: Rect,
    tool: Tool,
    color_index: usize,
    width: f64,
    /// 正在拖的那一笔（还没进文档）
    pending: Option<Shape>,
    /// 正在输入的文字
    pending_text: Option<PendingText>,
    /// 鼠标当前位置，供平台层画光标提示
    cursor: (f64, f64),
    outcome: Option<EditorOutcome>,
}

impl Editor {
    /// 新建。`image` 是图像在屏幕坐标里的矩形，`screen` 用来给工具条找位置。
    pub fn new(image: Rect, screen: Rect) -> Self {
        Self {
            document: Document::new(),
            toolbar: Toolbar::layout(&image, &screen),
            image,
            tool: Tool::Rect,
            color_index: DEFAULT_COLOR,
            width: DEFAULT_WIDTH,
            pending: None,
            pending_text: None,
            cursor: (image.x, image.y),
            outcome: None,
        }
    }

    /// 工具条（位置已算好）。
    pub fn toolbar(&self) -> &Toolbar {
        &self.toolbar
    }

    /// 图像矩形。
    pub fn image(&self) -> Rect {
        self.image
    }

    /// 当前工具。
    pub fn tool(&self) -> Tool {
        self.tool
    }

    /// 当前颜色。
    pub fn color(&self) -> Color {
        PALETTE[self.color_index.min(PALETTE.len() - 1)]
    }

    /// 当前颜色在调色板里的下标（平台层据此高亮那个色块）。
    pub fn color_index(&self) -> usize {
        self.color_index
    }

    /// 当前线宽。
    pub fn width(&self) -> f64 {
        self.width
    }

    /// 鼠标当前位置。
    pub fn cursor(&self) -> (f64, f64) {
        self.cursor
    }

    /// 正在输入的文字。
    pub fn pending_text(&self) -> Option<&PendingText> {
        self.pending_text.as_ref()
    }

    /// 有没有可撤销 / 可重做的操作（平台层据此把按钮画成置灰）。
    pub fn can_undo(&self) -> bool {
        self.document.can_undo()
    }

    /// 有没有可撤销 / 可重做的操作。
    pub fn can_redo(&self) -> bool {
        self.document.can_redo()
    }

    /// 结果；未结束时为 `None`。
    pub fn outcome(&self) -> Option<EditorOutcome> {
        self.outcome
    }

    /// **当前应该画出来的全部图形**：已落定的 + 正在拖的那一笔 + 正在输入的文字。
    ///
    /// 平台层每帧调一次丢给 `baobox_render::render` 即可，不需要自己拼。
    pub fn visible_shapes(&self) -> Vec<Shape> {
        let mut shapes = self.document.shapes().to_vec();
        if let Some(pending) = &self.pending {
            shapes.push(pending.clone());
        }
        if let Some(text) = &self.pending_text {
            if !text.text.is_empty() {
                shapes.push(self.text_shape(text));
            }
        }
        shapes
    }

    /// 鼠标按下。
    pub fn mouse_down(&mut self, point: (f64, f64)) {
        self.cursor = point;
        // 点在工具条上只当作按按钮 —— 绝不能同时落笔
        if self.toolbar.contains(point) {
            if let Some(item) = self.toolbar.hit(point) {
                self.activate(item);
            }
            return;
        }
        // 在别处点一下 = 先把正在输入的文字落定，再开始新操作
        self.commit_text();

        let point = self.clamp(point);
        match self.tool {
            Tool::Eraser => {
                self.document.erase_at(point.0, point.1);
            }
            Tool::Text => {
                self.pending_text = Some(PendingText {
                    origin: point,
                    text: String::new(),
                });
            }
            tool => {
                self.pending = Some(Shape {
                    tool,
                    points: vec![point, point],
                    color: self.color(),
                    width: self.width,
                    text: None,
                });
            }
        }
    }

    /// 鼠标移动。
    pub fn mouse_moved(&mut self, point: (f64, f64)) {
        self.cursor = point;
        let point = self.clamp(point);
        let Some(pending) = &mut self.pending else {
            return;
        };
        if pending.tool.is_drag() {
            // 一次拖拽画成的图形只记首尾两点
            let first = pending.points[0];
            pending.points = vec![first, point];
        } else {
            // 自由笔迹：全程记录。相邻两点太近就跳过，省得一次拖拽攒出上万个点
            if pending
                .points
                .last()
                .map(|last| (point.0 - last.0).hypot(point.1 - last.1) >= 1.0)
                .unwrap_or(true)
            {
                pending.points.push(point);
            }
        }
    }

    /// 鼠标松开：把正在拖的那一笔落定。
    pub fn mouse_up(&mut self, point: (f64, f64)) {
        self.cursor = point;
        self.mouse_moved(point);
        let Some(mut shape) = self.pending.take() else {
            return;
        };
        // 原地点一下就松手：两点型图形退化成一个点，画上去只是个噪点，丢掉
        if shape.tool.is_drag() {
            let bounds = shape.bounds();
            if bounds.w < 1.0 && bounds.h < 1.0 {
                return;
            }
        } else {
            shape.points.dedup();
        }
        self.document.add(shape);
    }

    /// 键盘。字符输入走 [`Editor::type_char`]。
    pub fn key_down(&mut self, key: EditorKey, modifiers: Modifiers) {
        match key {
            EditorKey::Escape => {
                // 正在打字时 Esc 只丢掉这段文字，不该把整张截图也丢了
                if self.pending_text.take().is_some() {
                    return;
                }
                self.pending = None;
                self.outcome = Some(EditorOutcome::Cancel);
            }
            EditorKey::Enter => {
                if self.pending_text.is_some() {
                    self.commit_text();
                } else {
                    // 没在打字时 ⏎ = 完成，走与「复制」相同的默认出口
                    self.outcome = Some(EditorOutcome::Copy);
                }
            }
            EditorKey::Backspace => {
                if let Some(text) = &mut self.pending_text {
                    text.text.pop();
                }
            }
            EditorKey::Z if modifiers.ctrl => {
                if modifiers.shift {
                    self.document.redo();
                } else {
                    self.document.undo();
                }
            }
            EditorKey::Y if modifiers.ctrl => {
                self.document.redo();
            }
            EditorKey::C if modifiers.ctrl => {
                self.commit_text();
                self.outcome = Some(EditorOutcome::Copy);
            }
            EditorKey::S if modifiers.ctrl => {
                self.commit_text();
                self.outcome = Some(EditorOutcome::Save);
            }
            EditorKey::BracketLeft => self.set_width(self.width - WIDTH_STEP),
            EditorKey::BracketRight => self.set_width(self.width + WIDTH_STEP),
            // 带修饰键才有意义的键，单按时不做事（免得打字时被吃掉）
            EditorKey::Z | EditorKey::Y | EditorKey::C | EditorKey::S => {}
        }
    }

    /// 输入一个字符。只有在文字工具的输入过程中才有效果。
    ///
    /// 平台层把 IME / 键盘布局解出来的**字符**送进来，不要送键码 ——
    /// 中文输入法与非 US 布局全靠这一层。
    pub fn type_char(&mut self, character: char) {
        if let Some(text) = &mut self.pending_text {
            if !character.is_control() {
                text.text.push(character);
            }
        }
    }

    /// 点了工具条上的某一项。平台层也可以直接调（比如右键菜单）。
    pub fn activate(&mut self, item: Item) {
        match item {
            Item::Tool(tool) => {
                self.commit_text();
                self.tool = tool;
            }
            Item::Color(index) => {
                self.color_index = index.min(PALETTE.len() - 1);
                // 正在输入的文字跟着变色，所见即所得
                if let Some(text) = self.pending_text.clone() {
                    self.pending_text = Some(text);
                }
            }
            Item::Undo => {
                self.commit_text();
                self.document.undo();
            }
            Item::Redo => {
                self.commit_text();
                self.document.redo();
            }
            Item::Copy => {
                self.commit_text();
                self.outcome = Some(EditorOutcome::Copy);
            }
            Item::Save => {
                self.commit_text();
                self.outcome = Some(EditorOutcome::Save);
            }
            Item::Pin => {
                self.commit_text();
                self.outcome = Some(EditorOutcome::Pin);
            }
            Item::Cancel => {
                self.outcome = Some(EditorOutcome::Cancel);
            }
        }
    }

    /// 设线宽，自动夹进可用范围。
    pub fn set_width(&mut self, width: f64) {
        self.width = width.clamp(MIN_WIDTH, MAX_WIDTH);
    }

    /// 把正在输入的文字落定成一笔。空文字直接丢弃 —— 点一下没打字就走开是常见操作。
    fn commit_text(&mut self) {
        let Some(text) = self.pending_text.take() else {
            return;
        };
        if text.text.is_empty() {
            return;
        }
        let shape = self.text_shape(&text);
        self.document.add(shape);
    }

    fn text_shape(&self, text: &PendingText) -> Shape {
        Shape {
            tool: Tool::Text,
            points: vec![text.origin],
            color: self.color(),
            width: self.width * TEXT_SIZE_FACTOR,
            text: Some(text.text.clone()),
        }
    }

    /// 把落笔点夹进图像范围。用户手滑拖到图外是常事，不该画出边界。
    fn clamp(&self, point: (f64, f64)) -> (f64, f64) {
        (
            point.0.clamp(self.image.x, self.image.right()),
            point.1.clamp(self.image.y, self.image.bottom()),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn editor() -> Editor {
        // 图像占屏幕中间一块，下方留得下工具条
        Editor::new(
            Rect::new(100.0, 100.0, 800.0, 400.0),
            Rect::new(0.0, 0.0, 1920.0, 1080.0),
        )
    }

    fn draw(editor: &mut Editor, from: (f64, f64), to: (f64, f64)) {
        editor.mouse_down(from);
        editor.mouse_moved(((from.0 + to.0) / 2.0, (from.1 + to.1) / 2.0));
        editor.mouse_up(to);
    }

    #[test]
    fn a_drag_produces_exactly_one_shape_not_one_per_pixel() {
        let mut e = editor();
        e.mouse_down((200.0, 200.0));
        for step in 0..50 {
            e.mouse_moved((200.0 + step as f64, 200.0 + step as f64));
        }
        // 拖拽过程中图形是"待定"的，还没进文档
        assert_eq!(e.visible_shapes().len(), 1, "拖拽时应看得见正在画的那一笔");
        e.mouse_up((250.0, 250.0));
        assert_eq!(e.visible_shapes().len(), 1);
        // 关键：一次拖拽只压一层撤销
        assert!(e.can_undo());
        e.key_down(EditorKey::Z, Modifiers::CTRL);
        assert!(e.visible_shapes().is_empty(), "一次 Ctrl+Z 就该撤销掉整笔");
    }

    #[test]
    fn clicking_the_toolbar_never_draws() {
        let mut e = editor();
        let button = e.toolbar().buttons[0];
        let center = (
            button.frame.x + button.frame.w / 2.0,
            button.frame.y + button.frame.h / 2.0,
        );
        e.mouse_down(center);
        e.mouse_moved((center.0 + 40.0, center.1 + 40.0));
        e.mouse_up((center.0 + 40.0, center.1 + 40.0));
        assert!(
            e.visible_shapes().is_empty(),
            "点工具条时绝不能同时画上一道"
        );
    }

    #[test]
    fn toolbar_buttons_switch_the_tool_and_the_colour() {
        let mut e = editor();
        assert_eq!(e.tool(), Tool::Rect);
        e.activate(Item::Tool(Tool::Arrow));
        assert_eq!(e.tool(), Tool::Arrow);

        let before = e.color();
        e.activate(Item::Color(3));
        assert_eq!(e.color_index(), 3);
        assert_ne!(e.color(), before);
        // 越界下标不该 panic，夹到最后一个
        e.activate(Item::Color(999));
        assert_eq!(e.color_index(), PALETTE.len() - 1);
    }

    #[test]
    fn freehand_records_the_path_but_a_dragged_box_keeps_two_points() {
        let mut e = editor();
        e.activate(Item::Tool(Tool::Pen));
        e.mouse_down((200.0, 200.0));
        for step in 1..20 {
            e.mouse_moved((200.0 + step as f64 * 3.0, 200.0));
        }
        e.mouse_up((260.0, 200.0));
        assert!(
            e.visible_shapes()[0].points.len() > 5,
            "画笔应记下整条轨迹"
        );

        let mut b = editor();
        b.activate(Item::Tool(Tool::Rect));
        draw(&mut b, (200.0, 200.0), (300.0, 260.0));
        assert_eq!(b.visible_shapes()[0].points.len(), 2, "矩形只需首尾两点");
    }

    #[test]
    fn a_click_without_dragging_leaves_no_stray_dot() {
        let mut e = editor();
        e.mouse_down((200.0, 200.0));
        e.mouse_up((200.0, 200.0));
        assert!(
            e.visible_shapes().is_empty(),
            "原地点一下不该留下一个退化的矩形"
        );
    }

    #[test]
    fn drawing_is_clamped_to_the_image() {
        let mut e = editor();
        // 从图像内部拖到远远的图像外
        draw(&mut e, (200.0, 200.0), (5000.0, 5000.0));
        let bounds = e.visible_shapes()[0].bounds();
        assert!(bounds.right() <= e.image().right() + 1e-9, "不能画出右边界");
        assert!(bounds.bottom() <= e.image().bottom() + 1e-9, "不能画出下边界");
    }

    #[test]
    fn eraser_removes_a_whole_stroke() {
        let mut e = editor();
        draw(&mut e, (200.0, 200.0), (400.0, 300.0));
        assert_eq!(e.visible_shapes().len(), 1);
        e.activate(Item::Tool(Tool::Eraser));
        // 点在矩形的上边框上
        e.mouse_down((300.0, 200.0));
        e.mouse_up((300.0, 200.0));
        assert!(e.visible_shapes().is_empty());
    }

    #[test]
    fn typing_text_needs_a_click_then_characters_then_enter() {
        let mut e = editor();
        e.activate(Item::Tool(Tool::Text));
        // 还没点，打字不该有反应
        e.type_char('x');
        assert!(e.pending_text().is_none());

        e.mouse_down((300.0, 300.0));
        e.mouse_up((300.0, 300.0));
        for character in "你好".chars() {
            e.type_char(character);
        }
        assert_eq!(e.pending_text().unwrap().text, "你好");
        // 打字过程中就该看得见
        assert_eq!(e.visible_shapes().len(), 1);

        e.key_down(EditorKey::Enter, Modifiers::NONE);
        assert!(e.pending_text().is_none());
        assert_eq!(e.visible_shapes()[0].text.as_deref(), Some("你好"));
        assert!(e.outcome().is_none(), "落定文字不该顺手把编辑器也关了");
    }

    #[test]
    fn escape_cancels_the_text_first_and_the_editor_second() {
        let mut e = editor();
        e.activate(Item::Tool(Tool::Text));
        e.mouse_down((300.0, 300.0));
        e.mouse_up((300.0, 300.0));
        e.type_char('a');

        e.key_down(EditorKey::Escape, Modifiers::NONE);
        assert!(e.pending_text().is_none());
        assert!(
            e.outcome().is_none(),
            "第一下 Esc 只该丢掉这段文字，不该关掉编辑器"
        );

        e.key_down(EditorKey::Escape, Modifiers::NONE);
        assert_eq!(e.outcome(), Some(EditorOutcome::Cancel));
    }

    #[test]
    fn empty_text_is_discarded_rather_than_committed() {
        let mut e = editor();
        e.activate(Item::Tool(Tool::Text));
        e.mouse_down((300.0, 300.0));
        e.mouse_up((300.0, 300.0));
        // 点了但什么都没打，换个工具走开
        e.activate(Item::Tool(Tool::Rect));
        assert!(e.visible_shapes().is_empty());
        assert!(!e.can_undo(), "空文字不该占一层撤销");
    }

    #[test]
    fn backspace_deletes_one_character_at_a_time() {
        let mut e = editor();
        e.activate(Item::Tool(Tool::Text));
        e.mouse_down((300.0, 300.0));
        e.mouse_up((300.0, 300.0));
        for character in "abc".chars() {
            e.type_char(character);
        }
        e.key_down(EditorKey::Backspace, Modifiers::NONE);
        assert_eq!(e.pending_text().unwrap().text, "ab");
    }

    #[test]
    fn undo_and_redo_respond_to_both_conventions() {
        let mut e = editor();
        draw(&mut e, (200.0, 200.0), (300.0, 300.0));
        e.key_down(EditorKey::Z, Modifiers::CTRL);
        assert!(e.visible_shapes().is_empty());

        // Ctrl+Shift+Z（macOS / Adobe 习惯）
        e.key_down(
            EditorKey::Z,
            Modifiers {
                ctrl: true,
                shift: true,
            },
        );
        assert_eq!(e.visible_shapes().len(), 1);

        e.key_down(EditorKey::Z, Modifiers::CTRL);
        // Ctrl+Y（Windows 习惯）
        e.key_down(EditorKey::Y, Modifiers::CTRL);
        assert_eq!(e.visible_shapes().len(), 1);
    }

    #[test]
    fn undo_shortcuts_do_nothing_without_ctrl() {
        let mut e = editor();
        draw(&mut e, (200.0, 200.0), (300.0, 300.0));
        e.key_down(EditorKey::Z, Modifiers::NONE);
        assert_eq!(e.visible_shapes().len(), 1, "光按 Z 不该撤销");
    }

    #[test]
    fn brackets_change_the_width_within_bounds() {
        let mut e = editor();
        assert_eq!(e.width(), DEFAULT_WIDTH);
        e.key_down(EditorKey::BracketRight, Modifiers::NONE);
        assert_eq!(e.width(), DEFAULT_WIDTH + WIDTH_STEP);
        for _ in 0..200 {
            e.key_down(EditorKey::BracketLeft, Modifiers::NONE);
        }
        assert_eq!(e.width(), MIN_WIDTH, "不该细到 0 或负数");
        for _ in 0..200 {
            e.key_down(EditorKey::BracketRight, Modifiers::NONE);
        }
        assert_eq!(e.width(), MAX_WIDTH);
    }

    #[test]
    fn the_four_exits_are_all_reachable() {
        for (item, expected) in [
            (Item::Copy, EditorOutcome::Copy),
            (Item::Save, EditorOutcome::Save),
            (Item::Pin, EditorOutcome::Pin),
            (Item::Cancel, EditorOutcome::Cancel),
        ] {
            let mut e = editor();
            e.activate(item);
            assert_eq!(e.outcome(), Some(expected));
        }
        // 快捷键出口
        let mut copy = editor();
        copy.key_down(EditorKey::C, Modifiers::CTRL);
        assert_eq!(copy.outcome(), Some(EditorOutcome::Copy));
        let mut save = editor();
        save.key_down(EditorKey::S, Modifiers::CTRL);
        assert_eq!(save.outcome(), Some(EditorOutcome::Save));
        let mut enter = editor();
        enter.key_down(EditorKey::Enter, Modifiers::NONE);
        assert_eq!(enter.outcome(), Some(EditorOutcome::Copy));
    }

    #[test]
    fn leaving_via_copy_commits_the_text_being_typed() {
        let mut e = editor();
        e.activate(Item::Tool(Tool::Text));
        e.mouse_down((300.0, 300.0));
        e.mouse_up((300.0, 300.0));
        e.type_char('h');
        e.key_down(EditorKey::C, Modifiers::CTRL);
        assert_eq!(e.outcome(), Some(EditorOutcome::Copy));
        assert_eq!(
            e.visible_shapes()[0].text.as_deref(),
            Some("h"),
            "打了一半就按复制，这段文字也该在图上"
        );
    }

    #[test]
    fn control_characters_never_enter_the_text() {
        let mut e = editor();
        e.activate(Item::Tool(Tool::Text));
        e.mouse_down((300.0, 300.0));
        e.mouse_up((300.0, 300.0));
        e.type_char('\u{8}'); // 退格的字符形式
        e.type_char('\n');
        e.type_char('a');
        assert_eq!(e.pending_text().unwrap().text, "a");
    }

    #[test]
    fn the_toolbar_sits_where_the_shared_layout_puts_it() {
        let e = editor();
        // 工具条不该压在图像上（图像下方有空间）
        assert!(e.toolbar().frame.y >= e.image().bottom());
        // 每个按钮都能被点到
        for button in &e.toolbar().buttons {
            let center = (
                button.frame.x + button.frame.w / 2.0,
                button.frame.y + button.frame.h / 2.0,
            );
            assert_eq!(e.toolbar().hit(center), Some(button.item));
        }
    }
}
