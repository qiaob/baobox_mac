//! 剪贴板工具接进 App 框架（Windows）。
//!
//! 与 Linux 的同名文件是**同一个适配层的两种实现**：菜单、动作 id、快捷键、
//! 设置声明逐字对齐，只有「内容怎么读、怎么粘」这一段换成 Win32 那一套。
//!
//! 剪贴板逻辑本身不在这里 —— 历史规则在 `baobox_core::clipboard`，
//! 读在 `clipboard_read`，写在 `clipboard`，粘贴在 `paste`，
//! 面板在 `clipboard_panel`，落盘在 `clipboard_store`。
//!
//! # 监听为什么不用单开线程（与 Linux 不同）
//!
//! Linux 那边要自己开一条线程去 poll X11 事件；这里不用：
//! `AddClipboardFormatListener` 把 `WM_CLIPBOARDUPDATE` 送到我们自己的
//! 消息窗口上，而 App 本来就有一条消息循环在跑。连模态操作期间也不会漏 ——
//! 覆盖层、编辑器、面板跑的都是**嵌套的**消息循环，同一条线程上的
//! 消息照样派发。
//!
//! 代价是收消息的窗口过程是个自由函数，拿不到 `&mut self`，所以捞到的东西
//! 先进一个全局队列，由主线程在用 Store 之前 [`ClipboardTool::drain`] 收走。
//!
//! # 关键字展开还没接
//!
//! 片段本身可用（新建、收藏、从面板粘贴），但「打 `;sig` 自动替换」那一步
//! **没有接**：它需要一个全局键盘钩子（`WH_KEYBOARD_LL`），那是整个产品里
//! 最需要谨慎的一段代码，而这里没有真机可以验证它。匹配规则已经写好并测过了
//! （`baobox_core::snippet`），缺的只是喂给它按键的那一层。
//!
//! 与其在设置里摆一个打开了也不生效的开关 —— 那比不给这个选项更糟 ——
//! 不如先不给，等能真机验证时再接上。两个平台在这件事上保持一致。

#![cfg(windows)]

use crate::{clipboard, clipboard_panel, clipboard_read, clipboard_store, paste};
use baobox_app::{Field, HotkeySpec, MenuItem, SettingsPage, ToolModule};
use baobox_core::clipboard::{Item, Kind, Store};
use baobox_core::config::Config;
use baobox_core::hotkey::KeyCombo;
use baobox_core::privacy;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};

/// 工具 id，同时是配置里的节名。**必须与 Linux 侧一致**。
pub const ID: &str = "clipboard";

/// 动作 id。
pub const PANEL: &str = "clipboard.panel";
/// 动作 id。
pub const CLEAR: &str = "clipboard.clear";
/// 动作 id。
pub const NEW_SNIPPET: &str = "clipboard.snippet";

/// 监听窗口捞到的一条新内容。
enum Caught {
    Text(String),
    Image(Vec<u8>),
    Files(Vec<String>),
}

/// 窗口过程与主线程之间的队列。
///
/// 窗口过程是自由函数，拿不到 `&mut self`，只能走全局。里面只放**已经读出来的
/// 内容**，不放 Store —— Store 归主线程，免得为它上锁。
static INBOX: Mutex<Vec<Caught>> = Mutex::new(Vec::new());

/// 「下一次变化是我们自己弄出来的，别记」。
///
/// 从历史里粘贴时我们会先把内容写回剪贴板，那必然触发一次
/// `WM_CLIPBOARDUPDATE`。不挡掉的话这一条会被重新推到最前，
/// 看着像是程序在跟自己较劲。
///
/// 理论上别的程序可能恰好在这几毫秒里也写了一次剪贴板，那一条就会被漏掉。
/// 这个窗口只有几毫秒，而且我们与消息在同一条线程上（写完之后下一条
/// `WM_CLIPBOARDUPDATE` 才会被派发），实际上撞不上。
static SUPPRESS_NEXT: AtomicBool = AtomicBool::new(false);

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

/// 剪贴板工具。
pub struct ClipboardTool {
    settings: Settings,
    store: Store,
    protection: clipboard_store::Protection,
    /// 收 `WM_CLIPBOARDUPDATE` 的消息窗口
    monitor: Option<HWND>,
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
            monitor: None,
        }
    }

    /// 把监听窗口捞到的东西收进历史。主线程每次要用 Store 之前调一下。
    pub fn drain(&mut self) {
        let caught: Vec<Caught> = match INBOX.lock() {
            Ok(mut inbox) => std::mem::take(&mut *inbox),
            // 锁毒了（窗口过程里 panic 过）也要接着干活，历史不该因此停摆
            Err(poisoned) => std::mem::take(&mut *poisoned.into_inner()),
        };
        if caught.is_empty() {
            return;
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
                Caught::Image(dib) => {
                    let Some(name) = self.save_image(&dib, now) else {
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
    }

    /// DIB 存成 PNG 文件，返回文件名。
    ///
    /// 存 PNG 而不是原样存 DIB：历史目录会长期躺着几百张图，
    /// 未压缩的 DIB 一张全屏就是十几 MB。
    fn save_image(&self, dib: &[u8], now: i64) -> Option<String> {
        let (width, height, rgba) = clipboard_read::dib_to_rgba(dib)?;
        let dir = clipboard_store::image_dir()?;
        std::fs::create_dir_all(&dir).ok()?;
        let name = format!("{now}-{}.png", std::process::id());
        baobox_image::write_rgba(&dir.join(&name), width, height, &rgba).ok()?;
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

    fn persist(&mut self) {
        match clipboard_store::save(&self.store) {
            Ok(level) => self.protection = level,
            Err(why) => eprintln!("剪贴板历史存不下来：{why}"),
        }
    }

    /// 打开面板，按用户的选择收尾。
    fn open_panel(&mut self) -> Result<String, String> {
        self.drain();
        match clipboard_panel::open(&self.store) {
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
        match item.kind {
            Kind::Image => {
                let dir = clipboard_store::image_dir().ok_or("找不到图片目录")?;
                let png = std::fs::read(dir.join(&item.image_file))
                    .map_err(|e| format!("读不到这张图：{e}"))?;
                let (width, height, rgba) =
                    baobox_image::decode_rgba(&png).map_err(|e| format!("这张图打不开：{e}"))?;
                self.deliver(&mut || clipboard::copy_rgba(width, height, &rgba))
            }
            _ => self.deliver(&mut || clipboard::copy_text(&item.text)),
        }
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
        self.deliver(&mut || clipboard::copy_text(&output))
    }

    /// 放进剪贴板，然后替用户按一下 Ctrl+V。
    ///
    /// 顺序不能错：面板已经在 `open_panel` 里关掉了，这里先等焦点回位，
    /// 再放剪贴板，最后合成按键。
    fn deliver(&mut self, write: &mut dyn FnMut() -> Result<(), String>) -> Result<String, String> {
        // 我们自己写进去的这一次不该再被记一遍
        SUPPRESS_NEXT.store(true, Ordering::SeqCst);
        if let Err(why) = write() {
            // 没写成功就不会有那次变化，标记要收回来，
            // 否则它会去挡掉用户接下来真正复制的东西
            SUPPRESS_NEXT.store(false, Ordering::SeqCst);
            return Err(why);
        }

        // 等焦点从面板回到原来那个窗口，否则按键会打到空处
        std::thread::sleep(paste::FOCUS_SETTLE);
        paste::send(self.settings.paste_style)?;
        Ok(String::new())
    }

    /// 起监听：一个只收消息的窗口 + 一次 `AddClipboardFormatListener`。
    fn start_monitor(&mut self) {
        if self.monitor.is_some() {
            return;
        }
        match monitor_window() {
            Ok(hwnd) => {
                if let Err(why) = clipboard_read::listen(hwnd) {
                    eprintln!("{why}，剪贴板历史不会更新。");
                    return;
                }
                self.monitor = Some(hwnd);
            }
            Err(why) => eprintln!("{why}，剪贴板历史不会更新。"),
        }
    }
}

/// 新条目的 id。时间 + 计数，够唯一了 —— 这里没有 UUID 可用。
fn fresh_id(now: i64) -> String {
    use std::sync::atomic::AtomicU64;
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    format!("{now}-{}", COUNTER.fetch_add(1, Ordering::Relaxed))
}

/// 建一个只收 `WM_CLIPBOARDUPDATE` 的隐形窗口。
///
/// 不复用 App 那个消息窗口：那样这个模块就得知道 App 的存在，
/// 而 `ToolModule` 的整个意义就是工具不认识框架。
fn monitor_window() -> Result<HWND, String> {
    use windows::core::w;
    use windows::Win32::Foundation::HINSTANCE;
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, RegisterClassW, HWND_MESSAGE, WNDCLASSW,
    };
    unsafe {
        let instance: HINSTANCE = GetModuleHandleW(None)
            .map_err(|e| format!("GetModuleHandle 失败：{e}"))?
            .into();
        let class = WNDCLASSW {
            lpfnWndProc: Some(monitor_wndproc),
            hInstance: instance,
            lpszClassName: w!("BaoboxClipboardMonitor"),
            ..Default::default()
        };
        RegisterClassW(&class);
        CreateWindowExW(
            Default::default(),
            w!("BaoboxClipboardMonitor"),
            w!("Baobox"),
            Default::default(),
            0,
            0,
            0,
            0,
            HWND_MESSAGE,
            None,
            instance,
            None,
        )
        .map_err(|e| format!("创建剪贴板监听窗口失败：{e}"))
    }
}

/// 剪贴板变了。
///
/// 在这里就把内容读出来（而不是只记一个「变了」）：句柄在
/// `CloseClipboard` 之后就作废，而主线程要过一会儿才来收。
unsafe extern "system" fn monitor_wndproc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    use windows::Win32::UI::WindowsAndMessaging::{DefWindowProcW, WM_CLIPBOARDUPDATE};
    if message == WM_CLIPBOARDUPDATE {
        // 自己刚放进去的东西不该再被自己记一遍
        if SUPPRESS_NEXT.swap(false, Ordering::SeqCst) {
            return LRESULT(0);
        }
        let caught = match clipboard_read::read(hwnd) {
            clipboard_read::Content::Text(text) if !text.trim().is_empty() => Some(Caught::Text(text)),
            clipboard_read::Content::Dib(bytes) => Some(Caught::Image(bytes)),
            clipboard_read::Content::Files(paths) => Some(Caught::Files(paths)),
            _ => None,
        };
        if let Some(caught) = caught {
            if let Ok(mut inbox) = INBOX.lock() {
                inbox.push(caught);
            }
        }
        return LRESULT(0);
    }
    DefWindowProcW(hwnd, message, wparam, lparam)
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

    fn will_terminate(&mut self) {
        if let Some(hwnd) = self.monitor.take() {
            clipboard_read::unlisten(hwnd);
            unsafe {
                let _ = windows::Win32::UI::WindowsAndMessaging::DestroyWindow(hwnd);
            }
        }
        self.drain();
        self.persist();
    }

    fn perform(&mut self, action: &str) -> Result<String, String> {
        self.drain();
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
                let title: String =
                    latest.lines().next().unwrap_or("片段").chars().take(20).collect();
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
        let field = page.fields.iter().find(|f| f.key == "record_concealed").unwrap();
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
    fn fresh_ids_do_not_collide_within_the_same_second() {
        let now = 1_700_000_000;
        let ids: std::collections::HashSet<String> = (0..100).map(|_| fresh_id(now)).collect();
        assert_eq!(ids.len(), 100, "同一秒内建的条目 id 不能撞");
    }

    #[test]
    fn the_suppression_flag_only_swallows_one_update() {
        // 挡掉的必须只是我们自己那一次；挡多了会漏记用户真正复制的东西
        SUPPRESS_NEXT.store(true, Ordering::SeqCst);
        assert!(SUPPRESS_NEXT.swap(false, Ordering::SeqCst));
        assert!(!SUPPRESS_NEXT.swap(false, Ordering::SeqCst));
    }
}
