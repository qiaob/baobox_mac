//! 常驻 App：托盘 + 全局快捷键 + 设置窗口。
//!
//! 对应 macOS 侧的 `AppDelegate` —— **它不认识任何具体工具**，
//! 只负责把注册表里的东西接上托盘、快捷键与设置窗口。加一个工具只要在
//! [`build_registry`] 里多注册一行。
//!
//! # 线程怎么分
//!
//! ```text
//! 主线程      GTK 主循环：设置窗口 + 执行动作 + 刷新托盘
//! 快捷键线程  自己一条 X11 连接，只负责 grab 与派发
//! zbus 线程   zbus 自己起的，负责应答桌面对托盘/菜单的调用
//! ```
//!
//! **注册表留在主线程**：工具不是 `Send`（截图那套持有 X11 连接与 GTK 无关的状态），
//! 而且动作本来就是一次一个、带模态覆盖层的，放主线程最简单也最不容易出错。
//! 三条线之间只传 `String` 形式的动作 id。
//!
//! # 快捷键为什么要轮询
//!
//! 用户在设置里改了快捷键，要立刻生效就得让快捷键线程重新 grab。
//! 而那条线程若阻塞在 `wait_for_event` 上就叫不醒它。所以改成
//! `poll_for_event` + 30ms 睡眠，每圈看一眼「要不要重新注册」的标志位 ——
//! 每秒三十次空转的代价，换来「改完立刻生效」。

use crate::{clipboard_module, hotkeys, screenshot_module, settings_window, store, x11capture};
use baobox_app::menu::{ACTION_ABOUT, ACTION_QUIT, ACTION_SETTINGS};
use baobox_app::{HotkeySpec, ToolRegistry};
use baobox_core::config::Config;
use baobox_core::hotkey::KeyCombo;
use gtk::prelude::*;
use x11rb::connection::Connection;
use std::cell::RefCell;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// 快捷键线程的轮询间隔。
const POLL: Duration = Duration::from_millis(30);

/// 主线程排空动作队列的间隔。
const DRAIN: Duration = Duration::from_millis(50);

/// 装配所有工具。**注册顺序 = 菜单顺序**，与 macOS 侧一致。
///
/// 加工具就在这里多一行。框架其余部分不需要任何改动。
pub fn build_registry() -> ToolRegistry {
    let mut registry = ToolRegistry::new();
    registry.register(Box::new(screenshot_module::ScreenshotTool::new()));
    registry.register(Box::new(clipboard_module::ClipboardTool::new()));
    registry
}

/// 跑起来，直到用户从菜单退出。
pub fn run() -> Result<String, String> {
    let mut registry = build_registry();

    // 首次启动时把默认值写成一份完整的配置文件，用户照着改就行，
    // 不必去翻文档才知道有哪些键
    let mut config = store::load_config();
    for page in registry.settings_pages() {
        page.fill_defaults(&mut config);
    }
    if let Err(why) = store::save_config(&config) {
        eprintln!("提示：配置存不下来（{why}），这次的改动不会保留。");
    }
    registry.activate_all(&config);

    gtk::init().map_err(|e| format!("GTK 初始化失败：{e}。常驻模式需要图形环境。"))?;

    let (tx, rx) = channel::<String>();
    let shared = Shared::new(&registry, &config);

    // 托盘放不上去不是致命错误 —— 快捷键仍然能用，所以只提示不退出
    let tray = match crate::tray::Tray::start(&registry.menu(&config), tray_sender(tx.clone())) {
        Ok(tray) => Some(tray),
        Err(why) => {
            eprintln!("{why}");
            None
        }
    };

    spawn_hotkey_thread(Arc::clone(&shared), tx.clone());

    let state = Rc::new(RefCell::new(AppState {
        registry,
        config,
        tray,
        shared,
        sender: tx,
    }));
    pump(Rc::clone(&state), rx);

    gtk::main();

    state.borrow_mut().shutdown();
    Ok("已退出。".to_string())
}

/// 主线程持有的一切。
struct AppState {
    registry: ToolRegistry,
    config: Config,
    tray: Option<crate::tray::Tray>,
    shared: Arc<Shared>,
    sender: Sender<String>,
}

impl AppState {
    /// 执行一个动作，把结果告诉用户。
    fn dispatch(&mut self, action: &str) {
        match action {
            ACTION_QUIT => {
                self.shared.quit.store(true, Ordering::Relaxed);
                gtk::main_quit();
            }
            ACTION_SETTINGS => self.open_settings(),
            ACTION_ABOUT => about(),
            other => match self.registry.perform(other) {
                Ok(message) if !message.is_empty() => notify(&message),
                Ok(_) => {}
                // 用户主动取消也走这条路，所以不能一律当成故障弹窗
                Err(why) => eprintln!("{why}"),
            },
        }
        // 动作可能改变菜单（比如开始录制之后那一项变成「停止录制」）
        self.refresh_menu();
    }

    fn open_settings(&mut self) {
        let pages = self.registry.settings_pages();
        let sender = self.sender.clone();
        settings_window::open(
            pages,
            self.config.clone(),
            Rc::new(move |updated: &Config| {
                // 设置窗口在同一条 GTK 线程上，但它拿不到 AppState
                // （已经被自己借出去了），所以走同一个动作队列绕回来
                if let Err(why) = store::save_config(updated) {
                    eprintln!("配置存不下来：{why}");
                }
                let _ = sender.send(RELOAD_CONFIG.to_string());
            }),
        );
    }

    /// 配置在设置窗口里被改过了，重新读一遍并让各处跟上。
    fn reload_config(&mut self) {
        self.config = store::load_config();
        self.registry.config_changed_all(&self.config);
        // 快捷键可能变了，让快捷键线程重新 grab
        let specs = resolve_hotkeys(&self.registry, &self.config);
        if let Ok(mut slot) = self.shared.specs.lock() {
            *slot = specs;
        }
        self.shared.reload.store(true, Ordering::Relaxed);
        self.refresh_menu();
    }

    fn refresh_menu(&self) {
        if let Some(tray) = &self.tray {
            tray.refresh(&self.registry.menu(&self.config));
        }
    }

    fn shutdown(&mut self) {
        self.registry.terminate_all();
    }
}

/// 动作队列里的一条内部消息：配置变了。
///
/// 用一个不会与任何工具动作撞名的 id（工具动作一律带 `.`）。
const RELOAD_CONFIG: &str = "app:reload-config";

/// 主线程与快捷键线程之间共享的东西。
struct Shared {
    /// 当前该注册哪些快捷键
    specs: Mutex<Vec<(HotkeySpec, Option<KeyCombo>)>>,
    /// 置位表示「重新 grab 一遍」
    reload: AtomicBool,
    /// 置位表示「收摊」
    quit: AtomicBool,
}

impl Shared {
    fn new(registry: &ToolRegistry, config: &Config) -> Arc<Self> {
        Arc::new(Self {
            specs: Mutex::new(resolve_hotkeys(registry, config)),
            reload: AtomicBool::new(false),
            quit: AtomicBool::new(false),
        })
    }
}

/// 把注册表里的快捷键规格与用户的配置合起来。
fn resolve_hotkeys(
    registry: &ToolRegistry,
    config: &Config,
) -> Vec<(HotkeySpec, Option<KeyCombo>)> {
    registry
        .hotkeys()
        .into_iter()
        .map(|spec| {
            let combo = spec.resolve(config);
            (spec, combo)
        })
        .collect()
}

/// 托盘事件 → 动作 id。
fn tray_sender(tx: Sender<String>) -> Sender<crate::tray::TrayEvent> {
    let (tray_tx, tray_rx) = channel::<crate::tray::TrayEvent>();
    std::thread::spawn(move || {
        while let Ok(crate::tray::TrayEvent::Action(action)) = tray_rx.recv() {
            if tx.send(action).is_err() {
                break;
            }
        }
    });
    tray_tx
}

/// 起快捷键线程。
fn spawn_hotkey_thread(shared: Arc<Shared>, tx: Sender<String>) {
    std::thread::spawn(move || {
        // 单独一条 X11 连接：与截图用的那条互不干扰
        let Ok(session) = x11capture::X11Session::open() else {
            eprintln!("连不上 X 服务器，全局快捷键不可用。");
            return;
        };
        let conn = session.connection();
        let mut center = hotkeys::HotkeyCenter::new(session.screen().root);

        loop {
            if shared.quit.load(Ordering::Relaxed) {
                center.unregister_all(conn);
                return;
            }
            // 第一圈以及每次配置变更都会走到这里
            if shared.reload.swap(false, Ordering::Relaxed) || center.is_empty() {
                center.unregister_all(conn);
                if let Ok(specs) = shared.specs.lock() {
                    let report = center.register_all(conn, &specs);
                    if report.has_problems() {
                        eprintln!("{}", report.describe());
                    }
                }
            }
            match conn.poll_for_event() {
                Ok(Some(x11rb::protocol::Event::KeyPress(key))) => {
                    if let Some(action) = center.action_for(key.detail, u16::from(key.state)) {
                        if tx.send(action.to_string()).is_err() {
                            return;
                        }
                    }
                }
                Ok(Some(_)) => {}
                Ok(None) => std::thread::sleep(POLL),
                Err(_) => {
                    eprintln!("与 X 服务器的连接断了，全局快捷键停止工作。");
                    return;
                }
            }
        }
    });
}

/// 让 GTK 主循环定时来排空动作队列。
fn pump(state: Rc<RefCell<AppState>>, rx: Receiver<String>) {
    glib::timeout_add_local(DRAIN, move || {
        // 一次排空所有攒下的动作。按住快捷键连按时会攒好几个，
        // 一圈只处理一个的话会拖出可见的延迟
        while let Ok(action) = rx.try_recv() {
            let mut state = state.borrow_mut();
            if action == RELOAD_CONFIG {
                state.reload_config();
            } else {
                state.dispatch(&action);
            }
        }
        glib::ControlFlow::Continue
    });
}

/// 关于对话框。
fn about() {
    let dialog = gtk::AboutDialog::new();
    dialog.set_program_name("Baobox");
    dialog.set_version(Some(env!("CARGO_PKG_VERSION")));
    dialog.set_comments(Some("菜单栏效率工具集合 —— Linux 版"));
    dialog.set_website(Some("https://github.com/qiaob/baobox_mac"));
    dialog.connect_response(|dialog, _| unsafe { dialog.destroy() });
    dialog.show_all();
}

/// 把一句话告诉用户。
///
/// 走 `notify-send` 而不是自己弹窗：桌面通知不抢焦点、会进通知中心，
/// 而截图完成这类消息本来就不该打断用户手上的事。没装 libnotify
/// （极少见）就退回打印到终端。
fn notify(message: &str) {
    let sent = std::process::Command::new("notify-send")
        .arg("--app-name=Baobox")
        .arg("--icon=applets-screenshooter")
        .arg("Baobox")
        .arg(message)
        .status()
        .map(|status| status.success())
        .unwrap_or(false);
    if !sent {
        println!("{message}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_registry_ships_with_the_screenshot_tool() {
        let registry = build_registry();
        let ids: Vec<&str> = registry.tools().iter().map(|tool| tool.id()).collect();
        assert_eq!(ids, vec![screenshot_module::ID, clipboard_module::ID]);
    }

    #[test]
    fn the_internal_reload_message_cannot_collide_with_a_tool_action() {
        // 工具动作一律形如 `工具id.动作`，内部消息用冒号避开
        assert!(!RELOAD_CONFIG.contains('.'));
        let registry = build_registry();
        for spec in registry.hotkeys() {
            assert_ne!(spec.id, RELOAD_CONFIG);
            assert!(spec.id.contains('.'), "动作 id 要靠 . 前缀派发");
        }
    }

    #[test]
    fn hotkeys_resolve_against_the_users_config() {
        let registry = build_registry();
        let mut config = Config::new();
        let default = resolve_hotkeys(&registry, &config);
        let capture = default
            .iter()
            .find(|(spec, _)| spec.id == screenshot_module::CAPTURE)
            .expect("截图动作应当有快捷键规格");
        assert_eq!(capture.1.as_ref().unwrap().to_string(), "Ctrl+Shift+S");

        config.set("hotkey", screenshot_module::CAPTURE, "Ctrl+Alt+P");
        let changed = resolve_hotkeys(&registry, &config);
        let capture = changed
            .iter()
            .find(|(spec, _)| spec.id == screenshot_module::CAPTURE)
            .unwrap();
        assert_eq!(capture.1.as_ref().unwrap().to_string(), "Ctrl+Alt+P");
    }

    #[test]
    fn unbound_hotkeys_resolve_to_nothing_and_are_simply_skipped() {
        let registry = build_registry();
        let config = Config::new();
        let resolved = resolve_hotkeys(&registry, &config);
        // 出厂绑定的：截图与剪贴板面板各一个
        assert_eq!(resolved.iter().filter(|(_, combo)| combo.is_some()).count(), 2);
        assert!(resolved.len() > 1, "其余规格仍然要列出来，设置里才看得到");
    }

    #[test]
    fn polling_intervals_stay_responsive_without_spinning() {
        // 太长用户会觉得快捷键迟钝，太短是白烧 CPU
        assert!(POLL <= Duration::from_millis(50));
        assert!(POLL >= Duration::from_millis(10));
        assert!(DRAIN <= Duration::from_millis(100));
    }
}
