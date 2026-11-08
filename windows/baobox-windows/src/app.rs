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
use crate::pet_notify::{self, Center, Level, Notice};
use windows::core::w;
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::{
    DefWindowProcW, DispatchMessageW, GetMessageW, MessageBoxW, PostQuitMessage, TranslateMessage,
    MB_ICONINFORMATION, MB_OK, MSG, WM_DESTROY, WM_HOTKEY, WM_LBUTTONUP, WM_RBUTTONUP,
};

/// 装配所有工具。**注册顺序 = 菜单顺序**，与 macOS / Linux 一致。
pub fn build_registry(owner: HWND) -> ToolRegistry {
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
    registry.register(Box::new(crate::pet::PetTool::new(owner)));
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
    notices: Center,
    pet_ring: Option<crate::pet_ring::Ring>,
    screenshot_target: Option<crate::paste::PasteTarget>,
}

impl App {
    fn open_pet_ring(&mut self, outer: bool) {
        use crate::{caffeinate_module as awake, pet_ring as ring};
        let has_action = |tool_id: &str, action: &str| {
            self.registry.tools().iter().find(|tool| tool.id() == tool_id)
                .is_some_and(|tool| tool.menu_items().iter().any(|item| item.action_ids().contains(&action)))
        };
        let mut items = if outer {
            let mut items = vec![
                ("desktop-pet.feed", "喂食"), ("desktop-pet.play", "陪玩"),
                (crate::keyboardnav_module::CLICK, "键盘点击"),
                (screenshot_module::HISTORY, "截图历史"), (ACTION_SETTINGS, "设置"),
                (ring::ADVANCED, "宠物动作"), (ring::BACK, "返回"),
            ];
            if let Some(baobox_app::MenuItem::Action { label, .. }) = self.registry.tools().iter()
                .find(|tool| tool.id() == screenshot_module::ID)
                .and_then(|tool| tool.menu_items().into_iter().find(|item| item.action_ids().contains(&screenshot_module::RECORD))) {
                let title = if label.contains("停止") { "停止录制" } else { "录屏" };
                items.insert(0, (screenshot_module::RECORD, title));
            }
            items
        } else {
            let mut items = ring::ITEMS.to_vec();
            items[4] = if has_action(awake::ID, awake::STOP) { (awake::STOP, "关闭防休眠") } else { (awake::TOGGLE, "防休眠") };
            items[5] = (crate::pet::NEXT_CHARACTER, "换形象");
            if self.notices.manually_quiet() { items[6] = (pet_notify::RESUME, "结束勿扰"); }
            items
        };
        items.retain(|(id, _)| !matches!(*id, "desktop-pet.feed" | "desktop-pet.play") || has_action(crate::pet::ID, id));
        self.pet_ring = crate::pet::anchor().and_then(|pet| ring::Ring::open(self.hwnd, pet, &items).ok());
        crate::pet::set_menu_open(self.pet_ring.is_some());
        if self.pet_ring.is_none() { self.pet_menu(); }
    }

    fn pet_menu(&mut self) {
        use baobox_app::{MenuItem, menu::MenuModel};
        let mut items = vec![
            MenuItem::action(screenshot_module::CAPTURE, "截图"),
            MenuItem::action(screenshot_module::OCR, "屏幕取字"),
            MenuItem::action(clipboard_module::PANEL, "剪贴板"),
            MenuItem::Separator,
        ];
        if let Some(tool) = self.registry.tools().iter().find(|tool| tool.id() == crate::pet::ID) {
            items.extend(tool.menu_items());
        }
        items.push(MenuItem::action(ACTION_SETTINGS, "设置"));
        if let Some(action) = self.tray.popup(self.hwnd, &MenuModel { items }) {
            self.dispatch(&action);
        }
    }

    /// 执行一个动作。
    fn dispatch(&mut self, action: &str) {
        use crate::screenshot_module::{CAPTURE, CAPTURE_FULL, QUICK_CAPTURE, OCR};
        let capture = matches!(action, CAPTURE | CAPTURE_FULL | QUICK_CAPTURE);
        let paste_target = if action == QUICK_CAPTURE { self.screenshot_target.take() } else { None };
        let _visibility = (capture || action == OCR).then(crate::pet::CaptureVisibility::hide);
        match action {
            ACTION_QUIT => unsafe { PostQuitMessage(0) },
            ACTION_SETTINGS => self.open_settings(),
            ACTION_ABOUT => about(self.hwnd),
            crate::pet_ring::MORE => self.open_pet_ring(true),
            crate::pet_ring::BACK => self.open_pet_ring(false),
            crate::pet_ring::ADVANCED => self.pet_menu(),
            "app.open-screenshot-folder" => {
                let history = store::load(1);
                if let Some(folder) = history.entries().first().and_then(|entry| std::path::Path::new(&entry.path).parent()) {
                    let _ = std::process::Command::new("explorer.exe").arg(folder).spawn();
                }
            }
            pet_notify::HISTORY => {
                let history = self.notices.history();
                let wide: Vec<u16> = history.encode_utf16().chain(Some(0)).collect();
                unsafe {
                    MessageBoxW(self.hwnd, windows::core::PCWSTR(wide.as_ptr()), w!("通知历史"), MB_OK);
                }
            }
            pet_notify::QUIET => {
                self.notices.quiet(Some(std::time::Duration::from_secs(3600)));
                self.notices.post(Notice::feedback("已安静一小时"));
            }
            pet_notify::QUIET_TODAY => self.notices.quiet_today(),
            pet_notify::RESUME => {
                self.notices.quiet(None);
                self.notices.post(Notice::feedback("已结束勿扰"));
            }
            pet_notify::TEST | pet_notify::TEST_TOAST | pet_notify::TEST_ALERT => {
                let mut notice = Notice::ambient(crate::pet::ID, "这是一条宠物提醒");
                notice.level = match action {
                    pet_notify::TEST => Level::Card,
                    pet_notify::TEST_ALERT => Level::Alert,
                    _ => Level::Ambient,
                };
                notice.dedupe = None;
                if notice.level != Level::Ambient {
                    notice.body = "BaoBox 的消息会出现在宠物上方。".into();
                    notice.actions.push((pet_notify::HISTORY, "通知历史"));
                }
                if notice.level == Level::Alert {
                    notice.expires = std::time::Instant::now() + std::time::Duration::from_secs(3600);
                }
                self.notices.post(notice);
            }
            other => match self.registry.perform(other) {
                Ok(mut message) if !message.is_empty() => {
                    let source = other.split_once('.').map_or(other, |(source, _)| source);
                    if capture {
                        if message.contains("已复制到剪贴板") && paste_target.is_some_and(|target| target.paste_image()) {
                            message.push_str("，已向原输入框发出粘贴");
                        }
                        let mut notice = Notice::ambient("capture-result", "截图完成");
                        notice.level = Level::Card;
                        notice.dedupe = None;
                        if message.starts_with("已保存 ") {
                            notice.actions.push(("app.open-screenshot-folder", "打开截图文件夹"));
                        }
                        notice.body = message;
                        self.notices.post(notice);
                    } else if matches!(other, crate::caffeinate_module::TOGGLE | crate::caffeinate_module::STOP | crate::pet::NEXT_CHARACTER) {
                        self.notices.post(Notice::feedback(&message));
                    } else {
                        self.notices.post(Notice::ambient(source, &message));
                    }
                }
                Ok(_) => {}
                // 用户主动取消也走这条路，不该一律当成故障弹窗
                Err(why) if capture && why != "已取消" => {
                    let wide: Vec<u16> = why.encode_utf16().chain(Some(0)).collect();
                    unsafe {
                        MessageBoxW(self.hwnd, windows::core::PCWSTR(wide.as_ptr()), w!("BaoBox 截图未完成"), MB_OK);
                    }
                }
                Err(why) => eprintln!("{why}"),
            },
        }
    }

    fn open_settings(&mut self) {
        // 已经开着就不要再开一个
        if let Some(existing) = self.settings.filter(|&window| unsafe {
            windows::Win32::UI::WindowsAndMessaging::IsWindow(window).as_bool()
        }) {
            unsafe {
                let _ = windows::Win32::UI::WindowsAndMessaging::SetForegroundWindow(existing);
            }
            return;
        }
        self.settings = None;
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
        self.notices.configure(&self.config);
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
pub(crate) const WM_RELOAD_CONFIG: u32 = windows::Win32::UI::WindowsAndMessaging::WM_APP + 2;

/// 定时器 id：给工具喂 `tick`。
const TIMER_TICK: usize = 1;

/// 多久喂一次。
///
/// 剪贴板监听把内容攒在一个全局队列里，靠这一下并进工具自己的状态。
/// 200ms 对「复制完托盘菜单里的计数就对了」来说足够快，
/// 而空跑一次只是看一眼空队列，代价可以忽略。
const TICK_MS: u32 = 200;

/// 跑起来，直到用户从托盘菜单退出。
pub fn run(show_settings: bool) -> Result<String, String> {
    crate::pet::trace_desktop();
    crate::gdi::prepare();

    unsafe {
        let instance: HINSTANCE = GetModuleHandleW(None)
            .map_err(|e| format!("GetModuleHandle 失败：{e}"))?
            .into();
        let hwnd = tray::message_window(instance, wndproc)?;
        let mut registry = build_registry(hwnd);
        // 首次启动时把默认值写成一份完整的配置文件，用户照着改就行
        let mut config = store::load_config();
        for page in registry.settings_pages() {
            page.fill_defaults(&mut config);
        }
        if let Err(why) = store::save_config(&config) {
            eprintln!("提示：配置存不下来（{why}），这次的改动不会保留。");
        }
        registry.activate_all(&config);

        let tray = tray::Tray::start(hwnd, "Baobox —— 点击托盘图标打开菜单")?;
        let mut center = hotkeys::HotkeyCenter::new(hwnd);
        let report = center.register_all(&resolve_hotkeys(&registry, &config));
        if report.has_problems() {
            eprintln!("{}", report.describe());
        }

        let mut notices = Center::default();
        notices.configure(&config);
        let mut app = Box::new(App {
            registry,
            config,
            tray,
            hotkeys: center,
            hwnd,
            settings: None,
            notices,
            pet_ring: None,
            screenshot_target: None,
        });
        windows::Win32::UI::WindowsAndMessaging::SetWindowLongPtrW(
            hwnd,
            windows::Win32::UI::WindowsAndMessaging::GWLP_USERDATA,
            app.as_mut() as *mut App as isize,
        );

        // 有后台数据源的工具（剪贴板监听）靠这个定时器把队列并进自己的状态
        windows::Win32::UI::WindowsAndMessaging::SetTimer(hwnd, TIMER_TICK, TICK_MS, None);
        if show_settings {
            app.open_settings();
        }

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
    thread_local! {
        static IN_HANDLER: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    }
    struct HandlerGuard;
    impl Drop for HandlerGuard {
        fn drop(&mut self) {
            IN_HANDLER.set(false);
        }
    }
    // 原生菜单和模态窗口会嵌套消息循环，期间不能再次借用 App。
    if IN_HANDLER.replace(true) {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    let _guard = HandlerGuard;
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
        crate::pet::WM_PET_MENU => {
            let was_open = app.pet_ring.take().is_some_and(|ring| ring.visible());
            if !was_open {
                app.screenshot_target = crate::paste::PasteTarget::current();
                app.open_pet_ring(false);
            }
            crate::pet::set_menu_open(app.pet_ring.as_ref().is_some_and(|ring| ring.visible()));
            LRESULT(0)
        }
        crate::pet_ring::WM_RING_ACTION => {
            if let Some(action) = app.pet_ring.take().and_then(|ring| ring.action(wparam.0)) {
                crate::pet::set_menu_open(false);
                app.dispatch(action);
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
            crate::pet::set_quiet(app.notices.suppressed());
            crate::pet::set_menu_open(app.pet_ring.as_ref().is_some_and(|ring| ring.visible()));
            if let Some(action) = app.notices.tick(crate::pet::anchor(), |title, body| notify(hwnd, title, body)) {
                app.dispatch(action);
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
fn notify(hwnd: HWND, title: &str, body: &str) {
    use windows::Win32::UI::Shell::{Shell_NotifyIconW, NIF_INFO, NIM_MODIFY, NOTIFYICONDATAW};
    unsafe {
        let mut data = NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: hwnd,
            uID: 1,
            uFlags: NIF_INFO,
            ..Default::default()
        };
        write_field(&mut data.szInfo, if body.is_empty() { title } else { body });
        write_field(&mut data.szInfoTitle, if body.is_empty() { "BaoBox" } else { title });
        if !Shell_NotifyIconW(NIM_MODIFY, &data).as_bool() {
            // 气泡被系统的「专注助手」之类挡掉时，至少留个记录
            println!("{title} {body}");
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
        let registry = build_registry(HWND::default());
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
                keyboardnav_module::ID,
                crate::pet::ID,
            ]
        );
    }

    #[test]
    fn hotkeys_resolve_against_the_users_config() {
        let registry = build_registry(HWND::default());
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
        let resolved = resolve_hotkeys(&build_registry(HWND::default()), &Config::new());
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
        let registry = build_registry(HWND::default());
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
        let registry = build_registry(HWND::default());
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
