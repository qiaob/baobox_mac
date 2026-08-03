//! 托盘菜单的模型。
//!
//! 平台层拿这棵树去建各自的原生菜单（Windows 的 `HMENU`、Linux 的 dbusmenu）。
//! **菜单的内容与顺序只有一份定义**，两边不会长出不同的菜单。
//!
//! # 为什么带「置灰」而不是直接不显示
//!
//! 依赖外部 CLI 的工具（未来的 Claude Code / 抓包助手）在没装时，要显示一条
//! **置灰的引导**，而不是让菜单项凭空消失 —— 消失了用户会以为是 App 坏了。
//! 与 macOS 侧同一条约定（`CLAUDE.md` 约定 7）。

use crate::ToolModule;
use baobox_core::config::Config;

/// 一个菜单项。
#[derive(Debug, Clone, PartialEq)]
pub enum MenuItem {
    /// 可点的动作。`id` 形如 `screenshot.capture`，前缀决定派发给谁
    Action {
        /// 动作 id
        id: String,
        /// 显示文字
        label: String,
        /// 能不能点
        enabled: bool,
        /// 右侧显示的快捷键提示（平台层自己格式化）
        hint: Option<String>,
    },
    /// 分隔线
    Separator,
    /// 二级菜单
    Submenu {
        /// 显示文字
        label: String,
        /// 子项
        items: Vec<MenuItem>,
    },
}

impl MenuItem {
    /// 一条可点的动作。
    pub fn action(id: &str, label: &str) -> Self {
        MenuItem::Action {
            id: id.to_string(),
            label: label.to_string(),
            enabled: true,
            hint: None,
        }
    }

    /// 一条置灰的说明（比如「未检测到 tesseract」）。
    ///
    /// 仍然占一个位置，用户看得到「这里本该有个功能」。
    pub fn disabled(label: &str) -> Self {
        MenuItem::Action {
            id: String::new(),
            label: label.to_string(),
            enabled: false,
            hint: None,
        }
    }

    /// 给动作加一条快捷键提示。
    pub fn with_hint(self, hint: &str) -> Self {
        match self {
            MenuItem::Action {
                id, label, enabled, ..
            } => MenuItem::Action {
                id,
                label,
                enabled,
                hint: Some(hint.to_string()),
            },
            other => other,
        }
    }

    /// 这一项（含子项）里所有可点动作的 id。
    pub fn action_ids(&self) -> Vec<&str> {
        match self {
            MenuItem::Action { id, enabled, .. } if *enabled && !id.is_empty() => vec![id.as_str()],
            MenuItem::Submenu { items, .. } => {
                items.iter().flat_map(|item| item.action_ids()).collect()
            }
            _ => Vec::new(),
        }
    }
}

/// App 内建的动作 id —— 不属于任何工具，由框架自己处理。
pub const ACTION_SETTINGS: &str = "app.settings";
/// App 内建的动作 id。
pub const ACTION_ABOUT: &str = "app.about";
/// App 内建的动作 id。
pub const ACTION_QUIT: &str = "app.quit";

/// 整棵托盘菜单。
#[derive(Debug, Clone, PartialEq)]
pub struct MenuModel {
    /// 顶层菜单项
    pub items: Vec<MenuItem>,
}

impl MenuModel {
    /// 按注册表建菜单：每个工具一个二级菜单，末尾接上设置 / 关于 / 退出。
    ///
    /// 一个菜单项都不给的工具会被跳过 —— 空的二级菜单点开什么都没有，比不显示更糟。
    pub fn build(tools: &[Box<dyn ToolModule>], config: &Config) -> MenuModel {
        let mut items = Vec::new();
        for tool in tools {
            let children = decorate(tool, config);
            if children.is_empty() {
                continue;
            }
            items.push(MenuItem::Submenu {
                label: tool.name().to_string(),
                items: children,
            });
        }
        if !items.is_empty() {
            items.push(MenuItem::Separator);
        }
        items.push(MenuItem::action(ACTION_SETTINGS, "设置…"));
        items.push(MenuItem::action(ACTION_ABOUT, "关于 Baobox"));
        items.push(MenuItem::Separator);
        items.push(MenuItem::action(ACTION_QUIT, "退出"));
        MenuModel { items }
    }

    /// 菜单里所有可点动作的 id。平台层用它建 id → 菜单项号的映射。
    pub fn action_ids(&self) -> Vec<&str> {
        self.items.iter().flat_map(|item| item.action_ids()).collect()
    }
}

/// 给工具的菜单项补上快捷键提示。
///
/// 提示来自 [`crate::HotkeySpec::resolve`]，所以显示的**永远是用户当前实际绑定的**，
/// 而不是出厂默认值 —— 改过快捷键之后菜单里还写着旧的，是很讨厌的一类不一致。
fn decorate(tool: &Box<dyn ToolModule>, config: &Config) -> Vec<MenuItem> {
    let hotkeys = tool.hotkeys();
    tool.menu_items()
        .into_iter()
        .map(|item| match &item {
            MenuItem::Action { id, .. } if !id.is_empty() => {
                match hotkeys
                    .iter()
                    .find(|spec| &spec.id == id)
                    .and_then(|spec| spec.resolve(config))
                {
                    Some(combo) => item.with_hint(&combo.to_string()),
                    None => item,
                }
            }
            _ => item,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{HotkeySpec, ToolRegistry};
    use baobox_core::hotkey::KeyCombo;

    struct Tool {
        id: &'static str,
        items: Vec<MenuItem>,
    }

    impl ToolModule for Tool {
        fn id(&self) -> &str {
            self.id
        }
        fn name(&self) -> &str {
            "工具"
        }
        fn menu_items(&self) -> Vec<MenuItem> {
            self.items.clone()
        }
        fn hotkeys(&self) -> Vec<HotkeySpec> {
            vec![HotkeySpec::new(
                "t.go",
                "去",
                KeyCombo::parse("Ctrl+Shift+G").ok(),
            )]
        }
        fn perform(&mut self, _action: &str) -> Result<String, String> {
            Ok(String::new())
        }
    }

    fn registry(items: Vec<MenuItem>) -> ToolRegistry {
        let mut registry = ToolRegistry::new();
        registry.register(Box::new(Tool { id: "t", items }));
        registry
    }

    #[test]
    fn every_menu_ends_with_settings_about_and_quit() {
        let registry = registry(vec![MenuItem::action("t.go", "去")]);
        let menu = registry.menu(&Config::new());
        let ids = menu.action_ids();
        assert!(ids.contains(&ACTION_SETTINGS));
        assert!(ids.contains(&ACTION_ABOUT));
        assert_eq!(ids.last(), Some(&ACTION_QUIT), "退出应当在最后");
    }

    #[test]
    fn each_tool_becomes_a_submenu() {
        let registry = registry(vec![MenuItem::action("t.go", "去")]);
        let menu = registry.menu(&Config::new());
        assert!(matches!(&menu.items[0], MenuItem::Submenu { label, .. } if label == "工具"));
    }

    #[test]
    fn a_tool_with_no_items_is_skipped_rather_than_showing_an_empty_submenu() {
        let registry = registry(Vec::new());
        let menu = registry.menu(&Config::new());
        assert!(
            !menu.items.iter().any(|item| matches!(item, MenuItem::Submenu { .. })),
            "空的二级菜单点开什么都没有，不如不显示"
        );
        // 但内建项还在，托盘菜单不会变成空的
        assert!(menu.action_ids().contains(&ACTION_QUIT));
    }

    #[test]
    fn the_hint_shows_the_users_binding_not_the_factory_default() {
        let registry = registry(vec![MenuItem::action("t.go", "去")]);
        let mut config = Config::new();
        config.set("hotkey", "t.go", "Ctrl+Alt+P");
        let menu = registry.menu(&config);
        let MenuItem::Submenu { items, .. } = &menu.items[0] else {
            panic!("第一项应该是二级菜单");
        };
        assert!(
            matches!(&items[0], MenuItem::Action { hint, .. } if hint.as_deref() == Some("Ctrl+Alt+P")),
            "菜单里的提示应当跟着用户改过的绑定走"
        );
    }

    #[test]
    fn an_unbound_action_shows_no_hint() {
        let registry = registry(vec![MenuItem::action("t.go", "去")]);
        let mut config = Config::new();
        config.set("hotkey", "t.go", "");
        let menu = registry.menu(&config);
        let MenuItem::Submenu { items, .. } = &menu.items[0] else {
            panic!()
        };
        assert!(matches!(&items[0], MenuItem::Action { hint: None, .. }));
    }

    #[test]
    fn disabled_items_take_up_space_but_are_not_actionable() {
        let registry = registry(vec![
            MenuItem::disabled("未检测到 tesseract"),
            MenuItem::action("t.go", "去"),
        ]);
        let menu = registry.menu(&Config::new());
        let MenuItem::Submenu { items, .. } = &menu.items[0] else {
            panic!()
        };
        assert_eq!(items.len(), 2, "置灰项仍然占位置");
        // 但它不该出现在可点动作里
        assert_eq!(menu.action_ids().iter().filter(|id| **id == "t.go").count(), 1);
        assert!(!menu.action_ids().iter().any(|id| id.is_empty()));
    }

    #[test]
    fn action_ids_reach_into_submenus() {
        let nested = MenuItem::Submenu {
            label: "更多".into(),
            items: vec![MenuItem::action("t.deep", "深处")],
        };
        let registry = registry(vec![nested]);
        assert!(registry.menu(&Config::new()).action_ids().contains(&"t.deep"));
    }
}
