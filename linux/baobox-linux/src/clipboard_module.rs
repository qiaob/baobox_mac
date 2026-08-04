//! 剪贴板工具接进 App 框架。
//!
//! 与截图那个适配层一样，这里**不含剪贴板逻辑** —— 历史规则在
//! `baobox_core::clipboard`，读在 `clipboard_read`，写在 `clipboard`，
//! 粘贴在 `paste`，面板在 `clipboard_panel`，落盘在 `clipboard_store`。
//! 这个文件只回答框架的四个问题，外加把监听线程管起来。
//!
//! # 关键字展开还没接
//!
//! 片段本身可用（新建、收藏、从面板粘贴），但「打 `;sig` 自动替换」那一步
//! **没有接**：它需要一个全局键盘监听（X11 上是 XRecord），
//! 那是整个产品里最需要谨慎的一段代码，而这里没有图形环境可以验证它。
//! 匹配规则已经写好并测过了（`baobox_core::snippet`），缺的只是喂给它按键的那一层。
//!
//! 与其在设置里摆一个打开了也不生效的开关 —— 那比不给这个选项更糟 ——
//! 不如先不给，等能真机验证时再接上。
//!
//! # 监听为什么要单开一条线程
//!
//! 剪贴板变化是**随时**发生的，而主线程在跑 GTK 主循环、可能正卡在
//! 一个模态的截图覆盖层里。监听必须独立，否则用户在截图期间复制的东西会丢。
//!
//! 那条线程只做「读出来 → 塞进队列」，**不碰 Store** —— Store 归主线程，
//! 免得为它上锁（上锁之后主线程画面板时会被监听线程卡住）。

use crate::{clipboard, clipboard_panel, clipboard_read, clipboard_store, paste, x11capture};
use baobox_app::{Field, HotkeySpec, MenuItem, SettingsPage, ToolModule};
use baobox_core::clipboard::{Item, Kind, Store};
use baobox_core::config::Config;
use baobox_core::hotkey::KeyCombo;
use baobox_core::privacy;
use std::sync::mpsc::{channel, Receiver, Sender};
use x11rb::connection::Connection;
use std::sync::{Arc, Mutex};

/// 工具 id，同时是配置里的节名。
pub const ID: &str = "clipboard";

/// 动作 id。
pub const PANEL: &str = "clipboard.panel";
/// 动作 id。
pub const CLEAR: &str = "clipboard.clear";
/// 动作 id。
pub const NEW_SNIPPET: &str = "clipboard.snippet";

/// 从配置读出来的偏好。
struct Settings {
    limit: usize,
    record_concealed: bool,
    expire_days: i64,
    paste_style: paste::Style,
}

impl Settings {
    fn read(config: &Config) -> Self {
        Self {
            limit: config.usize_or(ID, "history_limit", Store::DEFAULT_LIMIT),
            record_concealed: config.bool_or(ID, "record_concealed", false),
            expire_days: config.usize_or(ID, "expire_days", 0) as i64,
            paste_style: paste::Style::from_str(&config.string_or(ID, "paste_style", "normal")),
        }
    }
}

/// 监听线程捞到的一条新内容。
enum Caught {
    Text(String),
    Image(Vec<u8>),
    Files(Vec<String>),
}

/// 剪贴板工具。
pub struct ClipboardTool {
    settings: Settings,
    store: Store,
    protection: clipboard_store::Protection,
    /// 监听线程送来的新内容
    inbox: Option<Receiver<Caught>>,
    /// 让监听线程停下来
    stop: Arc<Mutex<bool>>,
    /// `activate` 过了吗。没有的话 Store 是空的，绝不能落盘
    loaded: bool,
}

impl Default for ClipboardTool {
    fn default() -> Self {
        Self::new()
    }
}

impl ClipboardTool {
    /// 新建。此时还没读配置，`activate` 才读。
    pub fn new() -> Self {
        Self {
            settings: Settings::read(&Config::new()),
            store: Store::new(Store::DEFAULT_LIMIT),
            protection: clipboard_store::Protection::PlainText,
            inbox: None,
            stop: Arc::new(Mutex::new(false)),
            loaded: false,
        }
    }

    /// 把监听线程送来的东西收进历史。主线程每次要用 Store 之前调一下。
    ///
    /// 返回 `true` 表示真收进了东西（菜单里的计数得跟着变）。
    pub fn drain(&mut self) -> bool {
        let Some(inbox) = &self.inbox else { return false };
        let caught: Vec<Caught> = inbox.try_iter().collect();
        if caught.is_empty() {
            return false;
        }
        let now = crate::now_seconds();
        for one in caught {
            let item = match one {
                Caught::Text(text) => {
                    // 敏感内容默认根本不入库
                    let sensitive = privacy::classify(&text, false);
                    if sensitive.is_some() && !self.settings.record_concealed {
                        continue;
                    }
                    let mut item = Item::text(&fresh_id(now), &text, now);
                    item.concealed = sensitive.is_some();
                    item
                }
                Caught::Files(paths) => {
                    let mut item = Item::text(&fresh_id(now), &paths.join("\n"), now);
                    item.kind = Kind::File;
                    item
                }
                Caught::Image(png) => {
                    let Some(name) = self.save_image(&png, now) else {
                        continue;
                    };
                    let mut item = Item::text(&fresh_id(now), "", now);
                    item.kind = Kind::Image;
                    item.image_file = name;
                    item
                }
            };
            for evicted in self.store.add(item) {
                self.delete_image(&evicted);
            }
        }
        self.persist();
        true
    }

    /// 图片存成文件，返回文件名。
    fn save_image(&self, png: &[u8], now: i64) -> Option<String> {
        let dir = clipboard_store::image_dir()?;
        std::fs::create_dir_all(&dir).ok()?;
        let name = format!("{now}-{}.png", std::process::id());
        std::fs::write(dir.join(&name), png).ok()?;
        Some(name)
    }

    /// 条目被淘汰时把它的图片一起删掉，否则目录会一直涨。
    fn delete_image(&self, item: &Item) {
        if item.image_file.is_empty() {
            return;
        }
        if let Some(dir) = clipboard_store::image_dir() {
            let _ = std::fs::remove_file(dir.join(&item.image_file));
        }
    }

    /// 落盘。**没 `activate` 过就不写** —— 那时 Store 还是空的，
    /// 写下去等于把用户磁盘上那份历史清掉。命令行子命令与单元测试都不
    /// `activate`，这条守卫拦的正是它们。
    fn persist(&mut self) {
        if !self.loaded {
            return;
        }
        match clipboard_store::save(&self.store) {
            Ok(level) => self.protection = level,
            Err(why) => eprintln!("剪贴板历史存不下来：{why}"),
        }
    }

    /// 打开面板，按用户的选择收尾。
    fn open_panel(&mut self) -> Result<String, String> {
        let _ = self.drain();
        let outcome = clipboard_panel::open(&self.store);
        match outcome {
            clipboard_panel::Outcome::Cancelled => Ok(String::new()),
            clipboard_panel::Outcome::TogglePin(id) => {
                self.store.toggle_pin(&id);
                self.persist();
                Ok("已切换收藏".to_string())
            }
            clipboard_panel::Outcome::Delete(id) => {
                if let Some(item) = self.store.remove(&id) {
                    self.delete_image(&item);
                }
                self.persist();
                Ok("已删除".to_string())
            }
            clipboard_panel::Outcome::Paste(id) => self.paste(&id),
            clipboard_panel::Outcome::Transform(id, action) => self.transform(&id, &action),
        }
    }

    /// 把一条内容放进剪贴板并替用户粘出去。
    fn paste(&mut self, id: &str) -> Result<String, String> {
        let Some(item) = self.store.items().iter().find(|e| e.id == id).cloned() else {
            return Err("这一条已经不在了".to_string());
        };
        let payload = match item.kind {
            Kind::Image => {
                let dir = clipboard_store::image_dir().ok_or("找不到图片目录")?;
                let png = std::fs::read(dir.join(&item.image_file))
                    .map_err(|e| format!("读不到这张图：{e}"))?;
                clipboard::Payload::Png(png)
            }
            _ => clipboard::Payload::Text(item.text.clone()),
        };
        self.deliver(payload)
    }

    /// 转换之后再粘出去（文本工具那一层的出口）。
    ///
    /// **转换结果不入历史** —— 用户要的是把它粘到别处，不是在历史里
    /// 多出一条自己没复制过的东西。真想留着的话，粘完再复制一次即可。
    fn transform(&mut self, id: &str, action: &str) -> Result<String, String> {
        let Some(item) = self.store.items().iter().find(|e| e.id == id).cloned() else {
            return Err("这一条已经不在了".to_string());
        };
        let output = baobox_core::textformat::apply(action, &item.text)
            .ok_or("这个动作对这段内容不适用")?;
        self.deliver(clipboard::Payload::Text(output))
    }

    /// 放进剪贴板，然后替用户按一下 Ctrl+V。
    ///
    /// 顺序不能错：面板已经在 `open_panel` 里关掉了，这里先等焦点回位，
    /// 再放剪贴板，最后合成按键。
    fn deliver(&mut self, payload: clipboard::Payload) -> Result<String, String> {
        let session = x11capture::X11Session::open()?;
        clipboard::serve_detached(payload);

        // 等焦点从面板回到原来那个窗口，否则按键会打到空处
        std::thread::sleep(paste::FOCUS_SETTLE);
        paste::send(session.connection(), self.settings.paste_style)?;
        Ok(String::new())
    }

    /// 起监听线程。
    fn start_monitor(&mut self) {
        let (tx, rx) = channel();
        self.inbox = Some(rx);
        let stop = Arc::clone(&self.stop);
        std::thread::spawn(move || monitor_loop(tx, stop));
    }
}

/// 新条目的 id。时间 + 计数，够唯一了 —— 这里没有 UUID 可用。
fn fresh_id(now: i64) -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    format!("{now}-{}", COUNTER.fetch_add(1, Ordering::Relaxed))
}

/// 监听线程：剪贴板一变就读出来丢进队列。
///
/// 自己一条 X11 连接 —— 主线程那条正忙着跑界面。
fn monitor_loop(tx: Sender<Caught>, stop: Arc<Mutex<bool>>) {
    let Ok(session) = x11capture::X11Session::open() else {
        eprintln!("连不上 X 服务器，剪贴板监听不可用。");
        return;
    };
    let conn = session.connection();
    let Ok(reader) = clipboard_read::Reader::new(conn, session.screen().root) else {
        eprintln!("剪贴板监听起不来（XFIXES 不可用？），历史不会更新。");
        return;
    };
    loop {
        if *stop.lock().unwrap_or_else(|e| e.into_inner()) {
            return;
        }
        match conn.poll_for_event() {
            Ok(Some(event)) => {
                if !reader.is_clipboard_change(&event) {
                    continue;
                }
                // 自己刚放进去的东西不该再被自己记一遍 —— 否则「从历史里粘贴」
                // 会把那一条重新推到最前，看着像是自己在跟自己较劲
                if reader.current_owner(conn).is_some_and(clipboard::is_ours) {
                    continue;
                }
                let caught = match reader.read(conn) {
                    clipboard_read::Content::Text(text) if !text.trim().is_empty() => {
                        Caught::Text(text)
                    }
                    clipboard_read::Content::Image(png) => Caught::Image(png),
                    clipboard_read::Content::Files(paths) => Caught::Files(paths),
                    _ => continue,
                };
                if tx.send(caught).is_err() {
                    return;
                }
            }
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(40)),
            Err(_) => return,
        }
    }
}

impl ToolModule for ClipboardTool {
    fn id(&self) -> &str {
        ID
    }

    fn name(&self) -> &str {
        "剪贴板"
    }

    fn menu_items(&self) -> Vec<MenuItem> {
        // 只读内存，零磁盘 IO
        let count = self.store.items().len();
        vec![
            MenuItem::action(PANEL, "剪贴板历史…"),
            MenuItem::action(NEW_SNIPPET, "新建文本片段…"),
            MenuItem::Separator,
            MenuItem::disabled(&format!("共 {count} 条 · {}", self.protection.describe())),
            MenuItem::action(CLEAR, "清空历史（保留收藏）"),
        ]
    }

    fn hotkeys(&self) -> Vec<HotkeySpec> {
        vec![HotkeySpec::new(
            PANEL,
            "剪贴板历史",
            // ⌃⌥V 之类在 Linux 上不好写，用一个不太会撞的组合
            KeyCombo::parse("Ctrl+Alt+V").ok(),
        )]
    }

    fn settings_page(&self) -> Option<SettingsPage> {
        Some(SettingsPage::new(
            ID,
            "剪贴板",
            vec![
                Field::number("history_limit", "保留条数", Store::DEFAULT_LIMIT as i64, 10, 2000)
                    .with_help("收藏与片段不占这个额度，也永远不会被挤掉"),
                Field::number("expire_days", "自动清理（天）", 0, 0, 365)
                    .with_help("0 = 不自动清理"),
                Field::toggle("record_concealed", "记录敏感内容", false)
                    .with_help("密码、私钥、银行卡号默认根本不入库；打开之后会记录，但在面板里打码显示"),
                Field::choice(
                    "paste_style",
                    "粘贴方式",
                    &[("normal", "Ctrl+V"), ("terminal", "Ctrl+Shift+V")],
                    "normal",
                )
                .with_help("终端里粘贴用的是 Ctrl+Shift+V"),
            ],
        ))
    }

    fn activate(&mut self, config: &Config) {
        self.settings = Settings::read(config);
        let (store, protection) = clipboard_store::load(self.settings.limit);
        self.store = store;
        self.protection = protection;
        self.loaded = true;
        // 启动时先按配置清一次过期的
        let expired = self
            .store
            .prune_expired(self.settings.expire_days, crate::now_seconds());
        for item in &expired {
            self.delete_image(item);
        }
        if !expired.is_empty() {
            self.persist();
        }
        self.start_monitor();
    }

    fn config_changed(&mut self, config: &Config) {
        let was_recording = self.settings.record_concealed;
        self.settings = Settings::read(config);
        for evicted in self.store.set_limit(self.settings.limit) {
            self.delete_image(&evicted);
        }
        // 用户把「记录敏感内容」关掉了：已经记下的要立刻删干净，
        // 只是「以后不再记」远远不够
        if was_recording && !self.settings.record_concealed {
            for item in self.store.remove_concealed() {
                self.delete_image(&item);
            }
        }
        self.persist();
    }

    fn tick(&mut self) -> bool {
        // 监听是随时在收东西的，而 `perform` 只在用户点了什么时才调 ——
        // 不定期排空的话，菜单里的计数一直是旧的，队列还会一直涨
        // （图片是按字节攒在内存里的）
        self.drain()
    }

    fn will_terminate(&mut self) {
        if let Ok(mut stop) = self.stop.lock() {
            *stop = true;
        }
        let _ = self.drain();
        self.persist();
    }

    fn perform(&mut self, action: &str) -> Result<String, String> {
        let _ = self.drain();
        match action {
            PANEL => self.open_panel(),
            CLEAR => {
                let dropped = self.store.clear();
                for item in &dropped {
                    self.delete_image(item);
                }
                self.persist();
                Ok(format!("已清空 {} 条（收藏与片段保留）", dropped.len()))
            }
            NEW_SNIPPET => {
                // 片段的内容取当前剪贴板里的东西 —— 用户多半刚复制好
                let latest = self
                    .store
                    .items()
                    .first()
                    .filter(|e| !e.concealed && e.kind != Kind::Image)
                    .map(|e| e.text.clone())
                    .unwrap_or_default();
                if latest.is_empty() {
                    return Err("先复制一段文字，再新建片段".to_string());
                }
                let id = fresh_id(crate::now_seconds());
                let title: String = latest.lines().next().unwrap_or("片段").chars().take(20).collect();
                self.store
                    .add_snippet(&id, &title, &latest, "", crate::now_seconds());
                self.persist();
                Ok(format!("已创建片段「{title}」，可在设置里给它加关键字"))
            }
            other => Err(format!("剪贴板工具不认识动作 {other}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_menu_action_is_dispatchable_to_this_tool() {
        let tool = ClipboardTool::new();
        for item in tool.menu_items() {
            if let MenuItem::Action { id, enabled, .. } = item {
                if enabled {
                    assert!(id.starts_with("clipboard."), "{id} 会派发不到自己头上");
                }
            }
        }
    }

    #[test]
    fn an_unknown_action_is_refused() {
        let mut tool = ClipboardTool::new();
        assert!(tool.perform("clipboard.nope").unwrap_err().contains("不认识"));
    }

    #[test]
    fn every_declared_setting_is_actually_read_somewhere() {
        let page = ClipboardTool::new().settings_page().unwrap();
        let source = include_str!("clipboard_module.rs");
        for key in baobox_app::settings::declared_keys(&page) {
            let mentions = source.matches(&format!("\"{key}\"")).count();
            assert!(
                mentions >= 2,
                "{key} 在设置里声明了却没人读它（源码里只出现 {mentions} 次）"
            );
        }
    }

    #[test]
    fn the_settings_section_matches_the_tool_id() {
        assert_eq!(ClipboardTool::new().settings_page().unwrap().section, ID);
    }

    #[test]
    fn recording_sensitive_content_ships_switched_off() {
        let page = ClipboardTool::new().settings_page().unwrap();
        let field = page
            .fields
            .iter()
            .find(|f| f.key == "record_concealed")
            .unwrap();
        assert_eq!(field.value(&Config::new(), ID), "false");
    }

    #[test]
    fn turning_off_sensitive_recording_deletes_what_was_already_kept() {
        // 「以后不再记」远远不够 —— 已经记下的必须立刻删干净
        let mut tool = ClipboardTool::new();
        let mut secret = Item::text("s", "hunter2", 100);
        secret.concealed = true;
        tool.store.add(secret);
        tool.settings.record_concealed = true;

        let mut config = Config::new();
        config.set_bool(ID, "record_concealed", false);
        tool.config_changed(&config);

        assert!(
            tool.store.items().iter().all(|e| !e.concealed),
            "关掉开关之后不能还留着敏感条目"
        );
    }

#[test]
    fn a_tool_that_never_activated_refuses_to_write_to_disk() {
        // 没 activate 过时 Store 是空的，落盘等于把用户磁盘上那份历史清掉。
        // 命令行子命令与这些单元测试走的都是这条路
        let mut tool = ClipboardTool::new();
        assert!(!tool.loaded, "新建出来就不该允许落盘");
        tool.persist();
        assert!(!tool.loaded, "persist 不该顺手把这个开关打开");
    }

    #[test]
    fn fresh_ids_do_not_collide_within_the_same_second() {
        let now = 1_700_000_000;
        let ids: std::collections::HashSet<String> = (0..100).map(|_| fresh_id(now)).collect();
        assert_eq!(ids.len(), 100, "同一秒内建的条目 id 不能撞");
    }
}
