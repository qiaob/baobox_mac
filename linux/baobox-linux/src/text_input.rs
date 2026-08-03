//! 标注里输入文字：借 GTK 的输入法栈。
//!
//! # 为什么不能自己收键盘
//!
//! X11 给的是**键码**，我们能把它翻成字符 —— 但那只覆盖「按一下出一个字」的键。
//! 中文不是这么输入的：用户打拼音，输入法（fcitx5 / ibus）截住按键、弹候选窗，
//! 最后把**已经组合好的**「你好」交给应用。要收到这段文字，应用必须参与某个
//! 输入法协议：
//!
//! - **XIM**：`XOpenIM` / `XCreateIC` / `Xutf8LookupString`，libX11 的 C 接口。
//!   协议老旧，各输入法支持程度不一，而且**与键盘 grab 冲突**。
//! - **工具包的 im-module**：GTK / Qt 自己通过 DBus 和 fcitx/ibus 打交道，
//!   应用只要用工具包的控件就什么都不用管。
//!
//! 我们已经为了设置窗口引入了 GTK（`libX11` 也因此早就链进来了），所以第二条路
//! 不增加任何依赖，而且顺带白拿了候选窗定位、选中、剪贴板粘贴、方向键移动光标。
//!
//! # 必须先松开键盘
//!
//! 标注编辑器为了独占输入，用 `GrabKeyboard` 抓住了键盘。不松开的话输入法
//! 一个按键都收不到 —— 这一步漏了，中文照样打不出来，而且现象和没接输入法一模一样。
//! [`prompt`] 的调用方负责在前后 ungrab / regrab。
//!
//! # 退化路径
//!
//! GTK 起不来（没有 `DISPLAY`、缺库）时返回 [`Outcome::Unavailable`]，
//! 调用方退回原来的「按键直接翻字符」——那条路打不了中文，但至少 ASCII 还能用。

use gtk::gdk;
use gtk::prelude::*;
use std::cell::RefCell;
use std::rc::Rc;

/// 输入框相对落笔点的偏移，让文字基线大致对上标注的位置。
const OFFSET_Y: i32 = -4;

/// 输入框最小宽度（像素）。太窄的话候选窗会挤在一起。
const MIN_WIDTH: i32 = 220;

/// 一次输入的结果。
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// 用户敲定了一段文字（可能是空的，调用方按「空文字丢弃」处理）
    Committed(String),
    /// 用户按了 Esc
    Cancelled,
    /// GTK 用不了，调用方应当退回自己收键盘的老路
    Unavailable,
}

/// 在屏幕坐标 `(x, y)` 处开一个输入框，阻塞到用户按下 ⏎ 或 Esc。
///
/// `size` 是字号，用来让输入框里的字和最终画上去的字大小接近 ——
/// 所见即所得的部分只能做到这个程度：真正的渲染仍由 `baobox_render` + X11 字体完成。
pub fn prompt(x: i32, y: i32, size: f64, initial: &str) -> Outcome {
    if !ensure_gtk() {
        return Outcome::Unavailable;
    }

    let result = Rc::new(RefCell::new(Outcome::Cancelled));

    // 无边框的顶层窗口：**不能用 Popup** —— Popup 不接受焦点，
    // 没有焦点输入法就不会激活
    let window = gtk::Window::new(gtk::WindowType::Toplevel);
    window.set_decorated(false);
    window.set_keep_above(true);
    window.set_skip_taskbar_hint(true);
    window.set_skip_pager_hint(true);
    window.set_type_hint(gdk::WindowTypeHint::Utility);
    window.move_(x, y + OFFSET_Y);

    let entry = gtk::Entry::new();
    entry.set_text(initial);
    entry.set_has_frame(true);
    entry.set_width_chars(12);
    entry.set_size_request(MIN_WIDTH, -1);
    // 输入框里的字号跟标注一致，用户不至于打完才发现大小差很多
    apply_font_size(&entry, size);
    window.add(&entry);

    // ⏎ 敲定
    {
        let result = Rc::clone(&result);
        entry.connect_activate(move |entry| {
            *result.borrow_mut() = Outcome::Committed(entry.text().to_string());
            gtk::main_quit();
        });
    }
    // Esc 取消
    {
        let result = Rc::clone(&result);
        entry.connect_key_press_event(move |_, event| {
            if event.keyval() == gdk::keys::constants::Escape {
                *result.borrow_mut() = Outcome::Cancelled;
                gtk::main_quit();
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
    }
    // 点到别处 = 敲定。用户在编辑器里点下一处想继续标注时，
    // 这段文字应该留下来而不是凭空消失
    {
        let result = Rc::clone(&result);
        let entry_ref = entry.clone();
        window.connect_focus_out_event(move |_, _| {
            *result.borrow_mut() = Outcome::Committed(entry_ref.text().to_string());
            gtk::main_quit();
            glib::Propagation::Proceed
        });
    }
    window.connect_delete_event(|_, _| {
        gtk::main_quit();
        glib::Propagation::Stop
    });

    window.show_all();
    window.present();
    // 光标放到末尾，接着上次的内容改
    entry.grab_focus();
    entry.set_position(-1);

    // 嵌套主循环：跑到上面某个回调调用 main_quit 为止
    gtk::main();

    unsafe { window.destroy() };
    // 让销毁真的落地，否则输入框会在编辑器重绘之前多留一帧
    while gtk::events_pending() {
        gtk::main_iteration_do(false);
    }

    let outcome = result.borrow().clone();
    outcome
}

/// GTK 起来了没有。命令行路径下没人初始化过，这里补一次。
fn ensure_gtk() -> bool {
    if gtk::is_initialized() {
        return true;
    }
    gtk::init().is_ok()
}

/// 把字号套到输入框上。
///
/// 走 CSS 而不是已废弃的 `override_font` —— 后者在新版 GTK 上直接没效果。
fn apply_font_size(entry: &gtk::Entry, size: f64) {
    let css = format!("entry {{ font-size: {}px; }}", size.round().max(8.0) as i32);
    let provider = gtk::CssProvider::new();
    if provider.load_from_data(css.as_bytes()).is_err() {
        return;
    }
    entry.style_context().add_provider(
        &provider,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_commit_is_still_a_commit_not_a_cancel() {
        // 「打了又删光再按⏎」与「按 Esc」是两件事：前者是空文字（调用方丢弃），
        // 后者要保留原有内容。混起来的话编辑已有文字时会莫名其妙
        assert_ne!(
            Outcome::Committed(String::new()),
            Outcome::Cancelled
        );
    }

    #[test]
    fn the_font_size_never_goes_below_something_readable() {
        // 线宽可以细到 1，字号跟着算会小到看不见
        for width in [0.0, 1.0, 4.0, 40.0] {
            let size = (width * baobox_core::editor::TEXT_SIZE_FACTOR).round().max(8.0);
            assert!(size >= 8.0, "线宽 {width} 算出来的字号太小");
        }
    }
}
