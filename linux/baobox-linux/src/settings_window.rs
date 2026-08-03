//! 设置窗口（GTK3）。
//!
//! 界面用**原生控件**画，但「有哪些设置」不在这里 —— 全部来自
//! `baobox_app::SettingsPage`，与 Windows 侧共用同一份声明。
//! 这个文件只做一件事：把声明翻译成 GTK 控件，再把改动写回配置。
//!
//! # 为什么改一下就存一次
//!
//! 没有「确定 / 取消」按钮。改完立刻生效、立刻落盘，与 macOS 的系统设置、
//! 与本项目 mac 版的行为一致。带确定按钮的对话框在常驻小工具上是负担 ——
//! 用户改完关窗口，然后发现没生效。
//!
//! # 快捷键怎么录
//!
//! 快捷键那一行是个按钮，点下去进入「录制」态，接下来的第一个按键组合就是新值。
//! 录制期间要 `Esc` 取消、`Backspace` 解绑 —— 解绑写的是**空串**，
//! 与「配置里没这个键」区分开（见 `baobox_app::HotkeySpec::resolve`）。

use baobox_app::settings::{FieldKind, SettingsPage};
use baobox_core::config::Config;
use gtk::gdk;
use gtk::prelude::*;
use std::cell::RefCell;
use std::rc::Rc;

/// 配置被改动时回调：参数是改完之后的整份配置。
pub type OnChange = Rc<dyn Fn(&Config)>;

/// 打开（或前置）设置窗口。
///
/// 必须在 GTK 主线程上调用。
pub fn open(pages: Vec<SettingsPage>, config: Config, on_change: OnChange) {
    let config = Rc::new(RefCell::new(config));

    let window = gtk::Window::new(gtk::WindowType::Toplevel);
    window.set_title("Baobox 设置");
    window.set_default_size(560, 480);
    window.set_position(gtk::WindowPosition::Center);

    // 左侧一列工具，右侧对应的一页 —— 与 mac 版设置窗口同一个形状
    let notebook = gtk::Notebook::new();
    notebook.set_tab_pos(gtk::PositionType::Left);

    for page in &pages {
        let content = build_page(page, Rc::clone(&config), Rc::clone(&on_change));
        let scroller = gtk::ScrolledWindow::new(gtk::Adjustment::NONE, gtk::Adjustment::NONE);
        scroller.set_policy(gtk::PolicyType::Never, gtk::PolicyType::Automatic);
        scroller.add(&content);
        notebook.append_page(&scroller, Some(&gtk::Label::new(Some(&page.title))));
    }

    if pages.is_empty() {
        let empty = gtk::Label::new(Some("还没有任何工具提供设置项。"));
        notebook.append_page(&empty, Some(&gtk::Label::new(Some("设置"))));
    }

    window.add(&notebook);
    // 关掉窗口不等于退出 App —— 这是个常驻程序，托盘图标还在
    window.connect_delete_event(|window, _| {
        unsafe { window.destroy() };
        glib::Propagation::Stop
    });
    window.show_all();
}

/// 把一页声明翻译成一列控件。
fn build_page(page: &SettingsPage, config: Rc<RefCell<Config>>, on_change: OnChange) -> gtk::Box {
    let column = gtk::Box::new(gtk::Orientation::Vertical, 12);
    column.set_margin_top(18);
    column.set_margin_bottom(18);
    column.set_margin_start(18);
    column.set_margin_end(18);

    for field in &page.fields {
        let section = page.section.clone();
        let current = field.value(&config.borrow(), &section);
        let row = gtk::Box::new(gtk::Orientation::Vertical, 4);

        let control: gtk::Box = match &field.kind {
            FieldKind::Toggle { .. } => {
                let line = gtk::Box::new(gtk::Orientation::Horizontal, 8);
                let switch = gtk::Switch::new();
                switch.set_active(current == "true");
                switch.set_halign(gtk::Align::Start);
                let label = gtk::Label::new(Some(&field.label));
                label.set_xalign(0.0);
                line.pack_start(&label, true, true, 0);
                line.pack_end(&switch, false, false, 0);

                let field = field.clone();
                let config = Rc::clone(&config);
                let on_change = Rc::clone(&on_change);
                switch.connect_state_set(move |_, on| {
                    let mut config = config.borrow_mut();
                    field.store(&mut config, &section, if on { "true" } else { "false" });
                    on_change(&config);
                    glib::Propagation::Proceed
                });
                line
            }
            FieldKind::Choice { options, .. } => {
                let line = labelled(&field.label);
                let combo = gtk::ComboBoxText::new();
                for (value, title) in options {
                    combo.append(Some(value), title);
                }
                combo.set_active_id(Some(&current));

                let field = field.clone();
                let config = Rc::clone(&config);
                let on_change = Rc::clone(&on_change);
                combo.connect_changed(move |combo| {
                    let Some(value) = combo.active_id() else { return };
                    let mut config = config.borrow_mut();
                    field.store(&mut config, &section, &value);
                    on_change(&config);
                });
                line.pack_end(&combo, false, false, 0);
                line
            }
            FieldKind::Text { placeholder, .. } => {
                let line = labelled(&field.label);
                let entry = gtk::Entry::new();
                entry.set_text(&current);
                entry.set_placeholder_text(Some(placeholder));
                entry.set_width_chars(24);

                let field = field.clone();
                let config = Rc::clone(&config);
                let on_change = Rc::clone(&on_change);
                // 每敲一个字就存一次。文本框没有「提交」时机，
                // 等失焦再存的话用户直接关窗口就丢了
                entry.connect_changed(move |entry| {
                    let mut config = config.borrow_mut();
                    field.store(&mut config, &section, &entry.text());
                    on_change(&config);
                });
                line.pack_end(&entry, false, false, 0);
                line
            }
            FieldKind::Number { min, max, .. } => {
                let line = labelled(&field.label);
                let spin = gtk::SpinButton::with_range(*min as f64, *max as f64, 1.0);
                spin.set_value(current.parse::<f64>().unwrap_or(*min as f64));

                let field = field.clone();
                let config = Rc::clone(&config);
                let on_change = Rc::clone(&on_change);
                spin.connect_value_changed(move |spin| {
                    let mut config = config.borrow_mut();
                    field.store(&mut config, &section, &(spin.value() as i64).to_string());
                    on_change(&config);
                });
                line.pack_end(&spin, false, false, 0);
                line
            }
            FieldKind::Hotkey { .. } => {
                let line = labelled(&field.label);
                let button = gtk::Button::with_label(&hotkey_label(&current));
                let field = field.clone();
                let config = Rc::clone(&config);
                let on_change = Rc::clone(&on_change);
                button.connect_clicked(move |button| {
                    record_hotkey(
                        button,
                        field.clone(),
                        section.clone(),
                        Rc::clone(&config),
                        Rc::clone(&on_change),
                    );
                });
                line.pack_end(&button, false, false, 0);
                line
            }
        };

        row.pack_start(&control, false, false, 0);
        if let Some(help) = &field.help {
            let hint = gtk::Label::new(Some(help));
            hint.set_xalign(0.0);
            hint.style_context().add_class("dim-label");
            // 说明文字小一号，别和标题抢注意力
            hint.set_margin_start(2);
            row.pack_start(&hint, false, false, 0);
        }
        column.pack_start(&row, false, false, 0);
    }
    column
}

/// 一行「标题 …… 控件」的骨架。
fn labelled(text: &str) -> gtk::Box {
    let line = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let label = gtk::Label::new(Some(text));
    label.set_xalign(0.0);
    line.pack_start(&label, true, true, 0);
    line
}

/// 按钮上显示的快捷键文字。
fn hotkey_label(value: &str) -> String {
    if value.is_empty() {
        "未设置".to_string()
    } else {
        value.to_string()
    }
}

/// 进入录制态，抓下一个按键组合。
fn record_hotkey(
    button: &gtk::Button,
    field: baobox_app::Field,
    section: String,
    config: Rc<RefCell<Config>>,
    on_change: OnChange,
) {
    button.set_label("按下新的组合…（Esc 取消，Backspace 解绑）");
    // 抓键盘，否则组合会被别的控件（比如输入框）先吃掉
    button.grab_focus();

    let handler: Rc<RefCell<Option<glib::SignalHandlerId>>> = Rc::new(RefCell::new(None));
    let stored = Rc::clone(&handler);
    let id = button.connect_key_press_event(move |button, event| {
        let key = event.keyval();
        // 只按修饰键不算数 —— 用户按 Ctrl 的那一刻就落定，那永远录不到组合
        if is_modifier(key) {
            return glib::Propagation::Stop;
        }

        let finish = |button: &gtk::Button, value: Option<&str>| {
            if let Some(value) = value {
                let mut config = config.borrow_mut();
                field.store(&mut config, &section, value);
                on_change(&config);
                button.set_label(&hotkey_label(value));
            } else {
                let current = field.value(&config.borrow(), &section);
                button.set_label(&hotkey_label(&current));
            }
            if let Some(id) = stored.borrow_mut().take() {
                button.disconnect(id);
            }
        };

        match key {
            gdk::keys::constants::Escape => finish(button, None),
            gdk::keys::constants::BackSpace => finish(button, Some("")),
            _ => match combo_text(event) {
                Some(text) => finish(button, Some(&text)),
                // 没带修饰键的组合会把这个键从所有 App 手里抢走，不接受
                None => button.set_label("要带上 Ctrl / Alt / Super"),
            },
        }
        glib::Propagation::Stop
    });
    *handler.borrow_mut() = Some(id);
}

/// GDK 事件 → `baobox_core::hotkey::KeyCombo` 的文本形式。
///
/// 不带修饰键的一律返回 `None`：那种绑定会把该键从所有 App 手里抢走
/// （PrintScreen 例外，它本来就是系统级功能键）。
fn combo_text(event: &gdk::EventKey) -> Option<String> {
    let state = event.state();
    let key = event.keyval();
    let name = key_name(key)?;

    let mut parts = Vec::new();
    if state.contains(gdk::ModifierType::CONTROL_MASK) {
        parts.push("Ctrl");
    }
    if state.contains(gdk::ModifierType::MOD1_MASK) {
        parts.push("Alt");
    }
    if state.contains(gdk::ModifierType::SHIFT_MASK) {
        parts.push("Shift");
    }
    if state.contains(gdk::ModifierType::SUPER_MASK) || state.contains(gdk::ModifierType::MOD4_MASK)
    {
        parts.push("Super");
    }
    if parts.is_empty() && name != "PrintScreen" {
        return None;
    }
    parts.push(&name);
    Some(parts.join("+"))
}

/// keyval → `KeyCombo` 认得的主键名。
fn key_name(key: gdk::keys::Key) -> Option<String> {
    let raw = *key;
    // 字母数字
    if let Some(c) = key.to_unicode() {
        if c.is_ascii_alphanumeric() {
            return Some(c.to_ascii_uppercase().to_string());
        }
    }
    match raw {
        0xff61 => Some("PrintScreen".to_string()),
        0x20 => Some("Space".to_string()),
        0xff0d => Some("Enter".to_string()),
        // F1–F24 连续
        0xffbe..=0xffd5 => Some(format!("F{}", raw - 0xffbe + 1)),
        _ => None,
    }
}

/// 这个键是不是纯修饰键。
fn is_modifier(key: gdk::keys::Key) -> bool {
    matches!(
        *key,
        // Shift_L/R, Control_L/R, Caps_Lock, Meta_L/R, Alt_L/R, Super_L/R, Hyper_L/R
        0xffe1..=0xffee
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unset_hotkey_reads_as_words_not_an_empty_button() {
        assert_eq!(hotkey_label(""), "未设置");
        assert_eq!(hotkey_label("Ctrl+Shift+S"), "Ctrl+Shift+S");
    }

    #[test]
    fn modifier_keys_are_recognised_so_recording_waits_for_a_real_key() {
        // 按下 Ctrl 的那一刻就落定的话，永远录不到组合
        assert!(is_modifier(gdk::keys::constants::Control_L));
        assert!(is_modifier(gdk::keys::constants::Shift_R));
        assert!(is_modifier(gdk::keys::constants::Super_L));
        assert!(!is_modifier(gdk::keys::constants::a));
        assert!(!is_modifier(gdk::keys::constants::F1));
    }

    #[test]
    fn key_names_match_what_keycombo_can_parse() {
        use baobox_core::hotkey::KeyCombo;
        for key in [
            gdk::keys::constants::a,
            gdk::keys::constants::Z,
            gdk::keys::constants::_4,
            gdk::keys::constants::F1,
            gdk::keys::constants::F12,
            gdk::keys::constants::space,
            gdk::keys::constants::Return,
            gdk::keys::constants::Print,
        ] {
            let name = key_name(key).expect("这些键都该有名字");
            let text = format!("Ctrl+{name}");
            assert!(
                KeyCombo::parse(&text).is_ok(),
                "{text} 录出来却解析不回去，设置里绑的快捷键就注册不上"
            );
        }
        // 不认识的键不该编一个名字出来
        assert_eq!(key_name(gdk::keys::constants::Menu), None);
    }
}
