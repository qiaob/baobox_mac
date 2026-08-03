//! Baobox 应用框架：**框架不认识具体工具**。
//!
//! 这是 macOS 侧 `Sources/Core/ToolModule.swift` + `ToolRegistry.swift` 的 Rust 对应物，
//! 由 Windows 与 Linux 两个平台共用。加一个工具 = 实现 [`ToolModule`] 并注册，
//! 托盘菜单、全局快捷键、设置窗口的那一页就都有了 —— 与 mac 版是同一套结构，
//! 免得同一个产品在三个系统上长成三种形状。
//!
//! # 为什么这里可以有 trait
//!
//! `baobox-core` 里刻意没有平台 trait（抓屏、剪贴板在三个系统上形状差太远）。
//! 但 [`ToolModule`] 不是平台抽象，是**应用结构**抽象：它的每个方法都返回
//! 平台无关的数据（菜单项、快捷键规格、设置声明），两个 Rust 平台的实现者
//! 恰好是同一批工具。抽象的是「工具怎么接进 App」，不是「系统怎么干活」。
//!
//! # 设置是声明出来的，不是画出来的
//!
//! 工具用 [`SettingsPage`] **声明**自己有哪些选项（开关、下拉、输入框、快捷键），
//! 由平台层用**各自的原生控件**渲染 —— Windows 用 Win32 通用控件，Linux 用 GTK。
//! 这样界面是原生外观，而「有哪些设置、叫什么、默认值是什么」只有一份定义。

#![forbid(unsafe_code)]

pub mod menu;
pub mod settings;

pub use menu::{MenuItem, MenuModel};
pub use settings::{Field, FieldKind, SettingsPage};

use baobox_core::config::Config;
use baobox_core::hotkey::KeyCombo;

/// 一个全局快捷键的规格。
///
/// `id` 在整个 App 内唯一，形如 `screenshot.capture` —— 它同时是配置文件里的键名，
/// 所以改了 id 就等于让用户已有的绑定失效，不要轻易改。
#[derive(Debug, Clone, PartialEq)]
pub struct HotkeySpec {
    /// 唯一标识，同时是配置键名
    pub id: String,
    /// 给用户看的名字
    pub label: String,
    /// 出厂默认组合。**容易冲突的组合应当留 `None`**，让用户自己设 ——
    /// 与 macOS 侧同一条约定（`CLAUDE.md` 约定 6）
    pub default: Option<KeyCombo>,
}

impl HotkeySpec {
    /// 造一条规格。
    pub fn new(id: &str, label: &str, default: Option<KeyCombo>) -> Self {
        Self {
            id: id.to_string(),
            label: label.to_string(),
            default,
        }
    }

    /// 用户实际绑定的组合：配置里有就用配置的，没有就用默认的。
    ///
    /// 配置里显式写成空串表示**用户主动解绑**，这时返回 `None` ——
    /// 与「配置里没这个键」是两回事，不能退回默认值，否则用户解不掉。
    pub fn resolve(&self, config: &Config) -> Option<KeyCombo> {
        match config.get("hotkey", &self.id) {
            Some("") => None,
            Some(text) => KeyCombo::parse(text).ok(),
            None => self.default.clone(),
        }
    }
}

/// 一个工具。实现它并注册，就接进了菜单、快捷键与设置。
///
/// 与 macOS 的 `ToolModule` 协议一一对应。
pub trait ToolModule {
    /// 唯一标识，也是配置文件里的节名（如 `screenshot`）。
    fn id(&self) -> &str;

    /// 菜单与设置里显示的名字。
    fn name(&self) -> &str;

    /// 托盘菜单里这个工具的二级菜单项。
    ///
    /// **不许在这里读磁盘**：菜单每次弹出都会重建，卡在 IO 上用户立刻能感觉到。
    /// 需要外部数据就在 [`ToolModule::activate`] 起的后台任务里刷进内存缓存。
    /// 与 macOS 侧同一条约定（`CLAUDE.md` 约定 2）。
    fn menu_items(&self) -> Vec<MenuItem>;

    /// 这个工具要的全局快捷键。用不到就返回空。
    fn hotkeys(&self) -> Vec<HotkeySpec> {
        Vec::new()
    }

    /// 设置窗口里这个工具的一页。没有设置就返回 `None`。
    fn settings_page(&self) -> Option<SettingsPage> {
        None
    }

    /// App 启动时调一次：起后台服务、准备缓存。
    fn activate(&mut self, _config: &Config) {}

    /// 配置被改动后调一次，让工具重新读自己的那一节。
    fn config_changed(&mut self, _config: &Config) {}

    /// App 退出前调一次：停后台服务、落盘。
    fn will_terminate(&mut self) {}

    /// 执行一个菜单动作 / 快捷键。`action` 是 [`MenuItem`] 或
    /// [`HotkeySpec`] 里的 id。
    ///
    /// 返回一句给用户看的话（平台层决定是弹通知还是打印）；
    /// 用户主动取消这类「不是错误的失败」返回 `Err`，平台层不会当成故障。
    fn perform(&mut self, action: &str) -> Result<String, String>;
}

/// 工具注册表。**注册顺序 = 菜单顺序**，与 macOS 侧一致。
#[derive(Default)]
pub struct ToolRegistry {
    tools: Vec<Box<dyn ToolModule>>,
}

impl ToolRegistry {
    /// 空注册表。
    pub fn new() -> Self {
        Self::default()
    }

    /// 注册一个工具。同 id 重复注册会被拒绝（返回 `false`）——
    /// 悄悄接受重复 id 会让配置与快捷键互相覆盖，排查起来非常痛苦。
    pub fn register(&mut self, tool: Box<dyn ToolModule>) -> bool {
        if self.tools.iter().any(|existing| existing.id() == tool.id()) {
            return false;
        }
        self.tools.push(tool);
        true
    }

    /// 全部工具，按注册顺序。
    pub fn tools(&self) -> &[Box<dyn ToolModule>] {
        &self.tools
    }

    /// 全部工具（可变）。
    pub fn tools_mut(&mut self) -> &mut [Box<dyn ToolModule>] {
        &mut self.tools
    }

    /// 按 id 找一个工具。
    pub fn find_mut(&mut self, id: &str) -> Option<&mut Box<dyn ToolModule>> {
        self.tools.iter_mut().find(|tool| tool.id() == id)
    }

    /// 整个 App 的全局快捷键，按注册顺序展开。
    pub fn hotkeys(&self) -> Vec<HotkeySpec> {
        self.tools.iter().flat_map(|tool| tool.hotkeys()).collect()
    }

    /// 建出整棵托盘菜单。
    pub fn menu(&self, config: &Config) -> MenuModel {
        MenuModel::build(&self.tools, config)
    }

    /// 设置窗口的全部页，按注册顺序。
    pub fn settings_pages(&self) -> Vec<SettingsPage> {
        self.tools
            .iter()
            .filter_map(|tool| tool.settings_page())
            .collect()
    }

    /// 逐个 `activate`。
    pub fn activate_all(&mut self, config: &Config) {
        for tool in &mut self.tools {
            tool.activate(config);
        }
    }

    /// 逐个通知配置变了。
    pub fn config_changed_all(&mut self, config: &Config) {
        for tool in &mut self.tools {
            tool.config_changed(config);
        }
    }

    /// 逐个 `will_terminate`，**按注册的倒序** —— 后注册的可能依赖先注册的，
    /// 倒着关与依赖方向一致。
    pub fn terminate_all(&mut self) {
        for tool in self.tools.iter_mut().rev() {
            tool.will_terminate();
        }
    }

    /// 把一个动作派发给它所属的工具。
    ///
    /// 动作 id 的前缀就是工具 id（`screenshot.capture` → `screenshot`），
    /// 所以派发不需要额外的表。
    pub fn perform(&mut self, action: &str) -> Result<String, String> {
        let owner = action
            .split_once('.')
            .map(|(prefix, _)| prefix)
            .unwrap_or(action);
        match self.find_mut(owner) {
            Some(tool) => tool.perform(action),
            None => Err(format!("没有哪个工具认领动作 {action}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use baobox_core::hotkey::KeyCombo;

    struct Fake {
        id: String,
        activated: bool,
        terminated: bool,
        performed: Vec<String>,
    }

    impl Fake {
        fn new(id: &str) -> Box<Fake> {
            Box::new(Fake {
                id: id.to_string(),
                activated: false,
                terminated: false,
                performed: Vec::new(),
            })
        }
    }

    impl ToolModule for Fake {
        fn id(&self) -> &str {
            &self.id
        }
        fn name(&self) -> &str {
            "假的"
        }
        fn menu_items(&self) -> Vec<MenuItem> {
            vec![MenuItem::action(&format!("{}.go", self.id), "去")]
        }
        fn hotkeys(&self) -> Vec<HotkeySpec> {
            vec![HotkeySpec::new(
                &format!("{}.go", self.id),
                "去",
                KeyCombo::parse("Ctrl+Shift+G").ok(),
            )]
        }
        fn activate(&mut self, _config: &Config) {
            self.activated = true;
        }
        fn will_terminate(&mut self) {
            self.terminated = true;
        }
        fn perform(&mut self, action: &str) -> Result<String, String> {
            self.performed.push(action.to_string());
            Ok(format!("做了 {action}"))
        }
    }

    #[test]
    fn registration_order_is_menu_order() {
        let mut registry = ToolRegistry::new();
        registry.register(Fake::new("b"));
        registry.register(Fake::new("a"));
        let ids: Vec<&str> = registry.tools().iter().map(|t| t.id()).collect();
        assert_eq!(ids, vec!["b", "a"], "菜单顺序应当就是注册顺序");
    }

    #[test]
    fn a_duplicate_id_is_refused_rather_than_silently_shadowing() {
        let mut registry = ToolRegistry::new();
        assert!(registry.register(Fake::new("x")));
        assert!(!registry.register(Fake::new("x")), "重复 id 必须被拒");
        assert_eq!(registry.tools().len(), 1);
    }

    #[test]
    fn actions_are_dispatched_by_their_prefix() {
        let mut registry = ToolRegistry::new();
        registry.register(Fake::new("alpha"));
        registry.register(Fake::new("beta"));
        assert_eq!(registry.perform("beta.go").unwrap(), "做了 beta.go");
        assert!(registry.perform("nobody.go").unwrap_err().contains("nobody"));
    }

    #[test]
    fn lifecycle_reaches_every_tool_and_shuts_down_in_reverse() {
        use std::cell::RefCell;
        use std::rc::Rc;

        /// 记下每个生命周期回调的到达顺序
        struct Logged {
            id: &'static str,
            log: Rc<RefCell<Vec<String>>>,
        }
        impl ToolModule for Logged {
            fn id(&self) -> &str {
                self.id
            }
            fn name(&self) -> &str {
                self.id
            }
            fn menu_items(&self) -> Vec<MenuItem> {
                Vec::new()
            }
            fn activate(&mut self, _config: &Config) {
                self.log.borrow_mut().push(format!("activate:{}", self.id));
            }
            fn config_changed(&mut self, _config: &Config) {
                self.log.borrow_mut().push(format!("changed:{}", self.id));
            }
            fn will_terminate(&mut self) {
                self.log.borrow_mut().push(format!("terminate:{}", self.id));
            }
            fn perform(&mut self, _action: &str) -> Result<String, String> {
                Ok(String::new())
            }
        }

        let log = Rc::new(RefCell::new(Vec::new()));
        let mut registry = ToolRegistry::new();
        for id in ["a", "b"] {
            registry.register(Box::new(Logged {
                id,
                log: Rc::clone(&log),
            }));
        }
        registry.activate_all(&Config::new());
        registry.config_changed_all(&Config::new());
        registry.terminate_all();

        assert_eq!(
            *log.borrow(),
            vec![
                "activate:a",
                "activate:b",
                "changed:a",
                "changed:b",
                // 关的时候倒着来：后注册的可能依赖先注册的
                "terminate:b",
                "terminate:a",
            ]
        );
    }

    #[test]
    fn hotkeys_from_all_tools_are_collected_in_order() {
        let mut registry = ToolRegistry::new();
        registry.register(Fake::new("a"));
        registry.register(Fake::new("b"));
        let ids: Vec<String> = registry.hotkeys().into_iter().map(|h| h.id).collect();
        assert_eq!(ids, vec!["a.go", "b.go"]);
    }

    #[test]
    fn a_binding_in_the_config_overrides_the_default() {
        let spec = HotkeySpec::new("s.c", "截图", KeyCombo::parse("Ctrl+Shift+S").ok());
        let mut config = Config::new();
        assert_eq!(spec.resolve(&config).unwrap().to_string(), "Ctrl+Shift+S");

        config.set("hotkey", "s.c", "Ctrl+Alt+P");
        assert_eq!(spec.resolve(&config).unwrap().to_string(), "Ctrl+Alt+P");
    }

    #[test]
    fn an_empty_binding_means_the_user_unbound_it_not_use_the_default() {
        let spec = HotkeySpec::new("s.c", "截图", KeyCombo::parse("Ctrl+Shift+S").ok());
        let mut config = Config::new();
        config.set("hotkey", "s.c", "");
        assert_eq!(
            spec.resolve(&config),
            None,
            "主动解绑之后不该又把默认值绑回去"
        );
    }

    #[test]
    fn an_unparsable_binding_falls_back_to_nothing_rather_than_crashing() {
        let spec = HotkeySpec::new("s.c", "截图", KeyCombo::parse("Ctrl+Shift+S").ok());
        let mut config = Config::new();
        config.set("hotkey", "s.c", "这不是快捷键");
        assert_eq!(spec.resolve(&config), None);
    }

    #[test]
    fn a_tool_with_no_hotkeys_or_settings_is_still_a_valid_tool() {
        struct Bare;
        impl ToolModule for Bare {
            fn id(&self) -> &str {
                "bare"
            }
            fn name(&self) -> &str {
                "光杆"
            }
            fn menu_items(&self) -> Vec<MenuItem> {
                Vec::new()
            }
            fn perform(&mut self, _action: &str) -> Result<String, String> {
                Ok(String::new())
            }
        }
        let mut registry = ToolRegistry::new();
        registry.register(Box::new(Bare));
        assert!(registry.hotkeys().is_empty());
        assert!(registry.settings_pages().is_empty());
    }
}
