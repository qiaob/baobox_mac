//! 常驻 App（Windows）：托盘 + 全局快捷键 + 设置窗口。
//!
//! 与 Linux 的 `app.rs` 对应，对应 macOS 侧的 `AppDelegate`。
//! **它不认识任何具体工具** —— 只把注册表里的东西接上托盘、快捷键与设置窗口。
//! 加一个工具只要在 [`build_registry`] 里多注册一行。
//!
//! # 为什么全在一条线程上
//!
//! Win32 的窗口、菜单、热键消息都绑定在**创建它们的那条线程**上，
//! 而我们的动作（覆盖层、编辑器、贴图）本来就是模态的、一次一个。
//! 所以整个 App 就是一条线程一个消息循环 —— 比 Linux 那边（GTK + X11 + DBus
//! 三套事件源）简单得多，也少了一大类跨线程的坑。
//!
//! 唯一的代价是执行动作期间消息循环会停住。截图是模态操作，用户本来
//! 也不会同时去点托盘，可以接受。

#![cfg(windows)]

use crate::{keyboardnav_module, caffeinate_module, clipboard_module, hotkeys, windowmanager_module, screenshot_module, settings_window, store, tray};
use baobox_app::menu::{ACTION_ABOUT, ACTION_QUIT, ACTION_SETTINGS};
use baobox_app::{HotkeySpec, ToolRegistry};
use baobox_core::config::Config;
use baobox_core::hotkey::KeyCombo;
use windows::core::w;
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::{
    DefWindowProcW, DispatchMessageW, GetMessageW, MessageBoxW, PostQuitMessage, TranslateMessage,
    MB_ICONINFORMATION, MB_OK, MSG, WM_DESTROY, WM_HOTKEY, WM_LBUTTONUP, WM_RBUTTONUP,
};

/// 装配所有工具。**注册顺序 = 菜单顺序**，与 macOS / Linux 一致。
pub fn build_registry() -> ToolRegistry {
    let mut registry = ToolRegistry::new();
    registry.register(Box::new(screenshot_module::ScreenshotTool::new()));
    registry.register(Box::new(clipboard_module::ClipboardTool::new()));
    registry.register(Box::new(caffeinate_module::CaffeinateTool::new()));
    registry.register(Box::new(windowmanager_module::WindowManagerTool::new()));
    // 两个助手是同一份实现，只有读哪个目录 / 用什么命令续接不同
    registry.register(Box::new(baobox_app::assistant_tool::AssistantTool::new(
        baobox_core::aisession::Flavor::ClaudeCode,
        crate::terminal::open,
    )));
    registry.register(Box::new(baobox_app::assistant_tool::AssistantTool::new(
        baobox_core::aisession::Flavor::Codex,
        crate::terminal::open,
    )));
    registry.register(Box::new(keyboardnav_module::KeyboardNavTool::new()));
    registry
}

/// App 的全部状态。窗口过程通过 `GWLP_USERDATA` 拿到它。
struct App {
    registry: ToolRegistry,
    config: Config,
    tray: tray::Tray,
    hotkeys: hotkeys::HotkeyCenter,
    hwnd: HWND,
    /// 打开着的设置窗口
    settings: Option<HWND>,
    /// 托盘图标「任务栏常显」还剩几次重试。explorer 要在图标出现之后
    /// 才建那个注册表子键，所以首启时得多试几下（见 `tray::promote_in_taskbar`）
    promote_tries: u32,
}

impl App {
    /// 执行一个动作。
    fn dispatch(&mut self, action: &str) {
        match action {
            ACTION_QUIT => unsafe { PostQuitMessage(0) },
            ACTION_SETTINGS => self.open_settings(),
            ACTION_ABOUT => about(self.hwnd),
            other => match self.registry.perform(other) {
                Ok(message) if !message.is_empty() => notify(self.hwnd, &message),
                Ok(_) => {}
                // 用户主动取消也走这条路，不该一律当成故障弹窗
                Err(why) => eprintln!("{why}"),
            },
        }
    }

    fn open_settings(&mut self) {
        // 已经开着就不要再开一个
        if let Some(existing) = self.settings {
            unsafe {
                let _ = windows::Win32::UI::WindowsAndMessaging::SetForegroundWindow(existing);
            }
            return;
        }
        let pages = self.registry.settings_pages();
        let hwnd = self.hwnd;
        let opened = settings_window::open(
            pages,
            self.config.clone(),
            Box::new(move |updated: &Config| {
                if let Err(why) = store::save_config(updated) {
                    eprintln!("配置存不下来：{why}");
                }
                // 走消息队列绕回主循环，那边才拿得到 &mut App
                unsafe {
                    let _ = windows::Win32::UI::WindowsAndMessaging::PostMessageW(
                        hwnd,
                        WM_RELOAD_CONFIG,
                        WPARAM(0),
                        LPARAM(0),
                    );
                }
            }),
        );
        match opened {
            Ok(window) => self.settings = Some(window),
            Err(why) => eprintln!("打不开设置窗口：{why}"),
        }
    }

    /// 配置被改过了，重新读一遍并让各处跟上。
    fn reload_config(&mut self) {
        self.config = store::load_config();
        self.registry.config_changed_all(&self.config);
        // 快捷键可能变了：先全撤，再按新配置注册
        self.hotkeys.unregister_all();
        let report = self.hotkeys.register_all(&resolve_hotkeys(&self.registry, &self.config));
        if report.has_problems() {
            eprintln!("{}", report.describe());
        }
    }
}

/// 配置变更的自定义消息。
const WM_RELOAD_CONFIG: u32 = windows::Win32::UI::WindowsAndMessaging::WM_APP + 2;

/// 定时器 id：给工具喂 `tick`。
const TIMER_TICK: usize = 1;

/// 多久喂一次。
///
/// 剪贴板监听把内容攒在一个全局队列里，靠这一下并进工具自己的状态。
/// 200ms 对「复制完托盘菜单里的计数就对了」来说足够快，
/// 而空跑一次只是看一眼空队列，代价可以忽略。
const TICK_MS: u32 = 200;

/// 跑起来，直到用户从托盘菜单退出。
pub fn run() -> Result<String, String> {
    let mut registry = build_registry();

    // 首次启动时把默认值写成一份完整的配置文件，用户照着改就行
    let mut config = store::load_config();
    for page in registry.settings_pages() {
        page.fill_defaults(&mut config);
    }
    if let Err(why) = store::save_config(&config) {
        eprintln!("提示：配置存不下来（{why}），这次的改动不会保留。");
    }
    registry.activate_all(&config);
    crate::gdi::prepare();

    unsafe {
        let instance: HINSTANCE = GetModuleHandleW(None)
            .map_err(|e| format!("GetModuleHandle 失败：{e}"))?
            .into();
        let hwnd = tray::message_window(instance, wndproc)?;
        let tray = tray::Tray::start(hwnd, "Baobox —— 点击托盘图标打开菜单")?;
        // 尽量把图标提到任务栏常显，别让它一出生就躺在「隐藏的图标」里
        let promoted = tray::promote_in_taskbar();
        let mut center = hotkeys::HotkeyCenter::new(hwnd);
        let report = center.register_all(&resolve_hotkeys(&registry, &config));
        if report.has_problems() {
            eprintln!("{}", report.describe());
        }

        let mut app = Box::new(App {
            registry,
            config,
            tray,
            hotkeys: center,
            hwnd,
            settings: None,
            // 25 次 × 200ms 的 tick = 5 秒窗口，足够 explorer 把子键建出来
            promote_tries: if promoted { 0 } else { 25 },
        });
        windows::Win32::UI::WindowsAndMessaging::SetWindowLongPtrW(
            hwnd,
            windows::Win32::UI::WindowsAndMessaging::GWLP_USERDATA,
            app.as_mut() as *mut App as isize,
        );

        // 有后台数据源的工具（剪贴板监听）靠这个定时器把队列并进自己的状态
        windows::Win32::UI::WindowsAndMessaging::SetTimer(hwnd, TIMER_TICK, TICK_MS, None);

        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }

        let _ = windows::Win32::UI::WindowsAndMessaging::KillTimer(hwnd, TIMER_TICK);

        windows::Win32::UI::WindowsAndMessaging::SetWindowLongPtrW(
            hwnd,
            windows::Win32::UI::WindowsAndMessaging::GWLP_USERDATA,
            0,
        );
        // 设置窗口是另一个顶层窗口，退出前显式关掉，
        // 别让它在进程收尾时闪一下
        if let Some(settings) = app.settings.take() {
            settings_window::close(settings);
        }
        app.registry.terminate_all();
    }
    Ok("已退出。".to_string())
}

unsafe extern "system" fn wndproc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let pointer = windows::Win32::UI::WindowsAndMessaging::GetWindowLongPtrW(
        hwnd,
        windows::Win32::UI::WindowsAndMessaging::GWLP_USERDATA,
    ) as *mut App;
    if pointer.is_null() {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    let app = &mut *pointer;

    match message {
        // 左右键都弹菜单：托盘只有菜单这一种交互，多给一条路
        m if m == tray::WM_TRAY => {
            let button = lparam.0 as u32;
            if button == WM_LBUTTONUP || button == WM_RBUTTONUP {
                let model = app.registry.menu(&app.config);
                if let Some(action) = app.tray.popup(hwnd, &model) {
                    app.dispatch(&action);
                }
            }
            LRESULT(0)
        }
        WM_HOTKEY => {
            if let Some(action) = app.hotkeys.action_for(wparam.0 as i32).map(str::to_string) {
                app.dispatch(&action);
            }
            LRESULT(0)
        }
        m if m == WM_RELOAD_CONFIG => {
            app.reload_config();
            LRESULT(0)
        }
        windows::Win32::UI::WindowsAndMessaging::WM_TIMER if wparam.0 == TIMER_TICK => {
            // 托盘菜单是弹出时才建的（`menuNeedsUpdate` 那一套），
            // 所以这里不必因为「变了」去重建什么 —— 收进来就够了
            let _ = app.registry.tick_all();
            if app.promote_tries > 0 {
                app.promote_tries -= 1;
                if tray::promote_in_taskbar() {
                    app.promote_tries = 0;
                }
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

/// 把注册表里的快捷键规格与用户的配置合起来。
pub fn resolve_hotkeys(
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

/// 关于对话框。
fn about(hwnd: HWND) {
    unsafe {
        MessageBoxW(
            hwnd,
            w!("Baobox —— 菜单栏效率工具集合\n\nhttps://github.com/qiaob/baobox_mac"),
            w!("关于 Baobox"),
            MB_OK | MB_ICONINFORMATION,
        );
    }
}

/// 把一句话告诉用户。
///
/// 用托盘气泡而不是模态对话框：截图完成这类消息不该打断用户手上的事。
fn notify(hwnd: HWND, message: &str) {
    use windows::Win32::UI::Shell::{Shell_NotifyIconW, NIF_INFO, NIM_MODIFY, NOTIFYICONDATAW};
    unsafe {
        let mut data = NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: hwnd,
            uID: 1,
            uFlags: NIF_INFO,
            ..Default::default()
        };
        write_field(&mut data.szInfo, message);
        write_field(&mut data.szInfoTitle, "Baobox");
        if !Shell_NotifyIconW(NIM_MODIFY, &data).as_bool() {
            // 气泡被系统的「专注助手」之类挡掉时，至少留个记录
            println!("{message}");
        }
    }
}

/// 往定长的宽字符缓冲里写字符串，截断并留出结尾的 NUL。
fn write_field<const N: usize>(buffer: &mut [u16; N], text: &str) {
    let encoded: Vec<u16> = text.encode_utf16().take(N - 1).collect();
    buffer[..encoded.len()].copy_from_slice(&encoded);
    buffer[encoded.len()] = 0;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_registry_ships_with_every_tool_in_menu_order() {
        // 注册顺序 = 菜单顺序，三个平台一致
        let registry = build_registry();
        let ids: Vec<&str> = registry.tools().iter().map(|tool| tool.id()).collect();
        assert_eq!(
            ids,
            vec![
                screenshot_module::ID,
                clipboard_module::ID,
                caffeinate_module::ID,
                windowmanager_module::ID,
                baobox_app::assistant_tool::CLAUDE_ID,
                baobox_app::assistant_tool::CODEX_ID,
                keyboardnav_module::ID
            ]
        );
    }

    #[test]
    fn hotkeys_resolve_against_the_users_config() {
        let registry = build_registry();
        let mut config = Config::new();
        let capture = |resolved: &[(HotkeySpec, Option<KeyCombo>)]| -> String {
            resolved
                .iter()
                .find(|(spec, _)| spec.id == screenshot_module::CAPTURE)
                .and_then(|(_, combo)| combo.as_ref())
                .map(|combo| combo.to_string())
                .unwrap_or_default()
        };
        assert_eq!(capture(&resolve_hotkeys(&registry, &config)), "Ctrl+Shift+S");

        config.set("hotkey", screenshot_module::CAPTURE, "Ctrl+Alt+P");
        assert_eq!(capture(&resolve_hotkeys(&registry, &config)), "Ctrl+Alt+P");
    }

    #[test]
    fn only_two_hotkeys_ship_bound() {
        let resolved = resolve_hotkeys(&build_registry(), &Config::new());
        // 出厂绑定的：截图与剪贴板面板各一个。其余易冲突的组合留给用户自设
        assert_eq!(resolved.iter().filter(|(_, combo)| combo.is_some()).count(), 2);
        assert!(resolved.len() > 2, "其余规格仍要列出来，设置里才看得到");
    }

    #[test]
    fn custom_messages_sit_above_wm_app_and_do_not_collide() {
        use windows::Win32::UI::WindowsAndMessaging::WM_APP;
        assert!(WM_RELOAD_CONFIG > WM_APP);
        assert_ne!(WM_RELOAD_CONFIG, tray::WM_TRAY);
    }

    #[test]
    fn the_tick_timer_is_frequent_enough_to_feel_live_but_not_a_spin() {
        // 复制完托盘菜单里的计数就该是对的；但也不能一秒跑几十遍
        assert!(TICK_MS >= 50);
        assert!(TICK_MS <= 1000);
    }

    #[test]
    fn notification_fields_are_truncated_and_null_terminated() {
        let mut buffer = [0u16; 8];
        write_field(&mut buffer, "很长很长很长很长很长");
        assert_eq!(buffer[7], 0, "必须留出结尾的 NUL");
        assert_ne!(buffer[0], 0);
    }

    #[test]
    fn the_windows_tool_declares_the_same_actions_as_the_linux_one() {
        // 两个平台的动作 id 必须一致，否则同一份配置里的快捷键绑定
        // 在另一个系统上会失效
        let registry = build_registry();
        let ids: Vec<String> = registry.hotkeys().into_iter().map(|spec| spec.id).collect();
        // 窗口管理那 13 个由 layout::ALL 生成，另有一条测试盯着
        assert_eq!(
            &ids[..5],
            vec![
                screenshot_module::CAPTURE,
                screenshot_module::CAPTURE_FULL,
                screenshot_module::OCR,
                screenshot_module::RECORD,
                clipboard_module::PANEL,
            ],
            "前面这几个是逐字写死的 —— 它们是用户配置里的键名，改了等于让绑定失效"
        );
    }

    #[test]
    fn the_window_layout_actions_are_generated_from_the_shared_list() {
        // 两个平台的这一串都是从 baobox_core::layout::ALL 生成的，
        // 所以天然对得齐 —— 这条测试盯着「别哪天手写了一份」。
        //
        // **按前缀挑出来比，不按位置**：原本取的是 ids 的末尾 13 个，
        // 那假设了「窗口管理排在最后」；后来键盘点击加在它后面，
        // 这条测试就红了 —— 而它测的东西其实一点没变。
        let registry = build_registry();
        let mine: Vec<String> = registry
            .hotkeys()
            .into_iter()
            .map(|spec| spec.id)
            .filter(|id| id.starts_with(windowmanager_module::ACTION_PREFIX))
            .collect();
        let expected: Vec<String> = baobox_core::layout::ALL
            .iter()
            .map(|l| windowmanager_module::action_for(*l))
            .collect();
        assert_eq!(mine, expected);
    }
}
