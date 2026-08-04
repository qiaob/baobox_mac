//! 剪贴板面板：搜一下、选一条、回车粘出去。
//!
//! 用 GTK（设置窗口已经把它引进来了）。这个面板的设计目标只有一个：
//! **从按下快捷键到内容落进目标窗口，中间不需要用鼠标**。
//!
//! - 面板一出来焦点就在搜索框，直接打字就是搜
//! - ↑↓ 选，⏎ 粘贴，Esc 关掉
//! - Ctrl+1–9 直接选中对应的那条
//!
//! # 两层：条目 → 文本工具
//!
//! Ctrl+T 把列表切成第二层：这段文字被认成了什么（JSON / JWT / 时间戳 / URL…）、
//! 能拿它做什么（格式化、解码、转大小写…）。选中一个动作按 ⏎，
//! 就把**转换后的结果**粘出去。再按 Esc 退回第一层。
//!
//! macOS 版那块预览区能自由排版（徽章一行、表格一块、按钮一排），
//! 这里只有一个列表控件，所以压成一张平表 —— 压平的规则在
//! `baobox_core::textformat::action_list`，两个平台共用一份。
//!
//! # 面板必须先关掉再粘贴
//!
//! 面板开着的时候焦点在我们这儿，合成的 Ctrl+V 会打到自己身上。
//! 所以选中之后的顺序是：关窗口 → 等焦点回位 → 放剪贴板 → 合成按键。
//! 这个顺序由调用方（`clipboard_module`）负责，面板只管把「选了哪一条」交出去。
//!
//! # 敏感内容
//!
//! 列表里一律打码显示，**也进不了文本工具那一层** —— 那一层会把内容拆开摆出来，
//! 正是打码要防的事。面板是会被人从背后看到的东西，
//! 而「我只是想找上一条」不该顺带把密码亮出来。

use baobox_core::clipboard::{Item, Kind, Store};
use baobox_core::textformat;
use gtk::gdk;
use gtk::prelude::*;
use std::cell::RefCell;
use std::rc::Rc;

/// 列表里一条最多显示多少个字符。
const PREVIEW_CHARS: usize = 120;

/// 用户在面板里选了什么。
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// 粘贴这一条
    Paste(String),
    /// 把这一条转换之后再粘贴（条目 id，动作 id）
    Transform(String, String),
    /// 收藏 / 取消收藏
    TogglePin(String),
    /// 删掉这一条
    Delete(String),
    /// 什么都没选
    Cancelled,
}

/// 列表现在显示的是哪一层。
enum Mode {
    /// 历史条目
    Browse,
    /// 某一条的文本工具
    Tools {
        item: String,
        entries: Vec<textformat::Entry>,
    },
}

/// 打开面板，阻塞到用户选完或关掉。
///
/// 必须在 GTK 主线程上调用。
pub fn open(store: &Store) -> Outcome {
    if !gtk::is_initialized() && gtk::init().is_err() {
        return Outcome::Cancelled;
    }

    let result = Rc::new(RefCell::new(Outcome::Cancelled));
    let window = gtk::Window::new(gtk::WindowType::Toplevel);
    window.set_title("剪贴板");
    window.set_default_size(560, 460);
    window.set_position(gtk::WindowPosition::CenterAlways);
    window.set_keep_above(true);
    window.set_skip_taskbar_hint(true);

    let column = gtk::Box::new(gtk::Orientation::Vertical, 6);
    column.set_margin_top(10);
    column.set_margin_bottom(10);
    column.set_margin_start(10);
    column.set_margin_end(10);

    let search = gtk::SearchEntry::new();
    search.set_placeholder_text(Some("搜索（↑↓ 选择 · ⏎ 粘贴 · Esc 关闭 · ⌃1–9 直接选）"));
    column.pack_start(&search, false, false, 0);

    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::Single);
    let scroller = gtk::ScrolledWindow::new(gtk::Adjustment::NONE, gtk::Adjustment::NONE);
    scroller.set_policy(gtk::PolicyType::Never, gtk::PolicyType::Automatic);
    scroller.add(&list);
    column.pack_start(&scroller, true, true, 0);

    let hint = gtk::Label::new(Some(HINT_BROWSE));
    hint.set_xalign(0.0);
    hint.style_context().add_class("dim-label");
    column.pack_start(&hint, false, false, 0);

    window.add(&column);

    // 当前列表里显示的是哪些 id —— 第一层是条目 id，第二层是动作 id
    let visible: Rc<RefCell<Vec<String>>> = Rc::new(RefCell::new(Vec::new()));
    let mode = Rc::new(RefCell::new(Mode::Browse));
    let snapshot: Vec<Item> = store.items().to_vec();

    let refill = {
        let list = list.clone();
        let visible = Rc::clone(&visible);
        let mode = Rc::clone(&mode);
        let snapshot = snapshot.clone();
        move |query: &str| {
            for child in list.children() {
                list.remove(&child);
            }
            let mut ids = Vec::new();
            match &*mode.borrow() {
                Mode::Browse => {
                    let needle = query.trim().to_lowercase();
                    for item in &snapshot {
                        if !matches(item, &needle) {
                            continue;
                        }
                        list.add(&row_for(item, ids.len()));
                        ids.push(item.id.clone());
                    }
                }
                Mode::Tools { entries, .. } => {
                    for entry in entries {
                        list.add(&tool_row_for(entry));
                        ids.push(entry.action.to_string());
                    }
                }
            }
            *visible.borrow_mut() = ids;
            list.show_all();
            if let Some(first) = list.row_at_index(0) {
                list.select_row(Some(&first));
            }
        }
    };
    refill("");

    {
        let refill = refill.clone();
        let mode = Rc::clone(&mode);
        search.connect_search_changed(move |entry| {
            // 第二层不参与搜索：那一层就十来行，搜反而碍事
            if matches!(&*mode.borrow(), Mode::Browse) {
                refill(&entry.text());
            }
        });
    }

    /// 当前选中的是列表里的第几个。
    fn selected_index(list: &gtk::ListBox) -> Option<usize> {
        let index = list.selected_row()?.index();
        if index < 0 {
            None
        } else {
            Some(index as usize)
        }
    }

    // ⏎ / ⌃P / ⌃D：拿当前选中的那条收尾
    let finish = {
        let result = Rc::clone(&result);
        let list = list.clone();
        let visible = Rc::clone(&visible);
        let mode = Rc::clone(&mode);
        move |outcome: fn(String) -> Outcome| {
            let Some(index) = selected_index(&list) else {
                return;
            };
            let Some(id) = visible.borrow().get(index).cloned() else {
                return;
            };
            let picked = match &*mode.borrow() {
                Mode::Browse => outcome(id),
                Mode::Tools { item, .. } => {
                    // 第二层只认「粘贴」这一个出口；收藏 / 删除是针对条目的
                    if id.is_empty() {
                        // 说明行，选中了也不做事
                        return;
                    }
                    Outcome::Transform(item.clone(), id)
                }
            };
            *result.borrow_mut() = picked;
            gtk::main_quit();
        }
    };

    // Ctrl+T：进 / 出文本工具那一层
    let toggle_tools = {
        let list = list.clone();
        let visible = Rc::clone(&visible);
        let mode = Rc::clone(&mode);
        let snapshot = snapshot.clone();
        let refill = refill.clone();
        let hint = hint.clone();
        let search = search.clone();
        move || {
            let next = match &*mode.borrow() {
                Mode::Tools { .. } => Some(Mode::Browse),
                Mode::Browse => {
                    let index = selected_index(&list)?;
                    let id = visible.borrow().get(index).cloned()?;
                    let item = snapshot.iter().find(|e| e.id == id)?;
                    match tools_for(item) {
                        Some(entries) => Some(Mode::Tools {
                            item: id,
                            entries,
                        }),
                        // 图片、打码的内容、认不出任何动作的：留在第一层
                        None => None,
                    }
                }
            }?;
            let browsing = matches!(next, Mode::Browse);
            *mode.borrow_mut() = next;
            hint.set_text(if browsing { HINT_BROWSE } else { HINT_TOOLS });
            refill(&search.text());
            Some(())
        }
    };

    {
        let finish = finish.clone();
        list.connect_row_activated(move |_, _| finish(Outcome::Paste));
    }

    {
        let finish = finish.clone();
        let list = list.clone();
        let result = Rc::clone(&result);
        let mode = Rc::clone(&mode);
        let toggle_tools = toggle_tools;
        window.connect_key_press_event(move |_, event| {
            let key = event.keyval();
            let ctrl = event.state().contains(gdk::ModifierType::CONTROL_MASK);
            match key {
                gdk::keys::constants::Escape => {
                    // 第二层的 Esc 是「退回上一层」，不是「关掉面板」
                    if matches!(&*mode.borrow(), Mode::Tools { .. }) {
                        toggle_tools();
                        return glib::Propagation::Stop;
                    }
                    *result.borrow_mut() = Outcome::Cancelled;
                    gtk::main_quit();
                    glib::Propagation::Stop
                }
                gdk::keys::constants::Return | gdk::keys::constants::KP_Enter => {
                    finish(Outcome::Paste);
                    glib::Propagation::Stop
                }
                gdk::keys::constants::t if ctrl => {
                    toggle_tools();
                    glib::Propagation::Stop
                }
                gdk::keys::constants::p if ctrl => {
                    finish(Outcome::TogglePin);
                    glib::Propagation::Stop
                }
                gdk::keys::constants::d if ctrl => {
                    finish(Outcome::Delete);
                    glib::Propagation::Stop
                }
                // ↑↓ 交给列表自己处理，但焦点在搜索框上，所以要转发过去
                gdk::keys::constants::Up | gdk::keys::constants::Down => {
                    move_selection(&list, key == gdk::keys::constants::Down);
                    glib::Propagation::Stop
                }
                _ => {
                    // 1–9 直接选中第 n 条。带 Ctrl 才生效，否则打不了数字
                    if ctrl {
                        if let Some(digit) = key.to_unicode().and_then(|c| c.to_digit(10)) {
                            if digit >= 1 {
                                if let Some(row) = list.row_at_index(digit as i32 - 1) {
                                    list.select_row(Some(&row));
                                    finish(Outcome::Paste);
                                    return glib::Propagation::Stop;
                                }
                            }
                        }
                    }
                    glib::Propagation::Proceed
                }
            }
        });
    }

    window.connect_delete_event(|_, _| {
        gtk::main_quit();
        glib::Propagation::Stop
    });

    window.show_all();
    window.present();
    search.grab_focus();
    gtk::main();

    unsafe { window.destroy() };
    while gtk::events_pending() {
        gtk::main_iteration_do(false);
    }

    let outcome = result.borrow().clone();
    outcome
}

/// 底下那行提示。
const HINT_BROWSE: &str = "⌃T 文本工具 · ⌃P 收藏 · ⌃D 删除";
const HINT_TOOLS: &str = "⏎ 转换后粘贴 · Esc 返回";

/// 这一条能进文本工具那一层吗；能的话给出该显示的内容。
///
/// 图片没有文字可分析；**打码的内容一律不进** —— 那一层会把内容拆开摆出来，
/// 正是打码要防的事。
pub fn tools_for(item: &Item) -> Option<Vec<textformat::Entry>> {
    if item.concealed || item.kind == Kind::Image || item.text.trim().is_empty() {
        return None;
    }
    let entries = textformat::action_list(&item.text);
    if entries.is_empty() {
        return None;
    }
    Some(entries)
}

/// ↑↓ 换一行。列表不在焦点上，所以要自己算。
fn move_selection(list: &gtk::ListBox, down: bool) {
    let current = list.selected_row().map(|row| row.index()).unwrap_or(-1);
    let next = if down { current + 1 } else { current - 1 };
    if next < 0 {
        return;
    }
    if let Some(row) = list.row_at_index(next) {
        list.select_row(Some(&row));
    }
}

/// 这一条过不过搜索。空关键词全过。
fn matches(item: &Item, needle: &str) -> bool {
    if needle.is_empty() {
        return true;
    }
    // 敏感内容不参与内容搜索 —— 否则可以用搜索把打码的密码试出来
    if item.concealed {
        return item.title.to_lowercase().contains(needle);
    }
    item.text.to_lowercase().contains(needle) || item.title.to_lowercase().contains(needle)
}

/// 造一行。
fn row_for(item: &Item, index: usize) -> gtk::ListBoxRow {
    let row = gtk::ListBoxRow::new();
    let line = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    line.set_margin_top(4);
    line.set_margin_bottom(4);
    line.set_margin_start(6);
    line.set_margin_end(6);

    // 前九条给个序号，配 Ctrl+数字直接选
    let badge = gtk::Label::new(Some(&if index < 9 {
        format!("{}", index + 1)
    } else {
        String::new()
    }));
    badge.set_width_chars(2);
    badge.style_context().add_class("dim-label");
    line.pack_start(&badge, false, false, 0);

    let text = gtk::Label::new(Some(&preview(item)));
    text.set_xalign(0.0);
    text.set_ellipsize(gtk::pango::EllipsizeMode::End);
    line.pack_start(&text, true, true, 0);

    let mut tags = Vec::new();
    if item.is_snippet() {
        tags.push("片段");
    } else if item.pinned {
        tags.push("收藏");
    }
    if item.concealed {
        tags.push("敏感");
    }
    if !tags.is_empty() {
        let tag = gtk::Label::new(Some(&tags.join(" · ")));
        tag.style_context().add_class("dim-label");
        line.pack_end(&tag, false, false, 0);
    }

    row.add(&line);
    row
}

/// 文本工具那一层的一行。
fn tool_row_for(entry: &textformat::Entry) -> gtk::ListBoxRow {
    let row = gtk::ListBoxRow::new();
    let label = gtk::Label::new(Some(&entry.label));
    label.set_xalign(0.0);
    label.set_margin_top(4);
    label.set_margin_bottom(4);
    label.set_margin_start(6);
    label.set_margin_end(6);
    label.set_ellipsize(gtk::pango::EllipsizeMode::End);
    // 说明行灰一点，动作行是正常字重 —— 用户一眼能看出哪些能按
    if entry.action.is_empty() {
        label.style_context().add_class("dim-label");
    }
    if entry.warning {
        label.style_context().add_class("warning");
    }
    row.add(&label);
    row
}

/// 一条在列表里显示成什么样。
///
/// 多行内容压成一行 —— 列表里一条占三行的话，一屏就看不到几条了。
pub fn preview(item: &Item) -> String {
    let title = item.display_title();
    let flat: String = title.chars().take(PREVIEW_CHARS).collect();
    if title.chars().count() > PREVIEW_CHARS {
        format!("{flat}…")
    } else {
        flat
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(text: &str) -> Item {
        Item::text("id", text, 0)
    }

    #[test]
    fn long_content_is_truncated_for_the_list() {
        let long = "x".repeat(PREVIEW_CHARS * 2);
        let shown = preview(&item(&long));
        assert!(shown.chars().count() <= PREVIEW_CHARS + 1);
        assert!(shown.ends_with('…'));
    }

    #[test]
    fn multiline_content_collapses_to_its_first_line() {
        // 列表里一条占三行的话，一屏就看不到几条了
        let shown = preview(&item("第一行\n第二行\n第三行"));
        assert!(!shown.contains('\n'));
        assert_eq!(shown, "第一行");
    }

    #[test]
    fn concealed_items_never_show_their_content() {
        let mut secret = item("hunter2");
        secret.concealed = true;
        assert!(!preview(&secret).contains("hunter"));
    }

    #[test]
    fn search_cannot_be_used_to_fish_out_concealed_content() {
        let mut secret = item("hunter2");
        secret.concealed = true;
        secret.title = "密码".into();
        assert!(!matches(&secret, "hunter"), "打码的内容不能被搜出来");
        assert!(matches(&secret, "密码"), "标题仍可搜");
        assert!(matches(&secret, ""), "空关键词照样列出来");
    }

    #[test]
    fn ordinary_items_are_searchable_by_content() {
        assert!(matches(&item("Hello World"), "hello"));
        assert!(!matches(&item("Hello World"), "nope"));
    }

    #[test]
    fn the_text_tools_refuse_to_open_on_concealed_content() {
        // 那一层会把内容拆开摆出来，正是打码要防的事
        let mut secret = item(r#"{"password":"hunter2"}"#);
        secret.concealed = true;
        assert!(tools_for(&secret).is_none());
    }

    #[test]
    fn the_text_tools_refuse_to_open_on_images_and_empty_entries() {
        let mut image = item("");
        image.kind = Kind::Image;
        image.image_file = "a.png".into();
        assert!(tools_for(&image).is_none());
        assert!(tools_for(&item("   ")).is_none());
    }

    #[test]
    fn the_text_tools_open_on_ordinary_text_and_recognise_json() {
        let entries = tools_for(&item(r#"{"a":1}"#)).unwrap();
        assert!(entries.iter().any(|e| e.action == "json.pretty"));
        // 说明行不是动作，选中了不该做事
        assert!(entries.iter().any(|e| e.action.is_empty()));
    }
}
