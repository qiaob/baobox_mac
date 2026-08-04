//! 窗口管理工具接进 App 框架（Windows）。
//!
//! 与 Linux 的同名文件**逐字对齐**：菜单、动作 id、设置声明都一样，
//! 只有「怎么问出窗口与显示器、怎么把窗口挪过去」那一段换成 Win32。
//!
//! 几何在 `baobox_core::layout`，Win32 那一层在 `windowmanager`。
//!
//! # 「恢复原位」只记一步
//!
//! 摆之前把窗口原来的位置存下来，`restore` 摆回去。**只存一步**，
//! 而且按窗口 id 分别存 —— 存一整摞的话，用户按第二次「恢复」会跳到
//! 一个他早就忘了的位置，那比不给这个功能更让人困惑。

#![cfg(windows)]

use crate::windowmanager;
use baobox_app::{Field, HotkeySpec, MenuItem, SettingsPage, ToolModule};
use baobox_core::config::Config;
use baobox_core::geometry::{display_for, map_across_displays, Rect};
use baobox_core::layout::{self, Layout};
use std::collections::HashMap;

/// 工具 id，同时是配置里的节名。**必须与其他平台一致**。
pub const ID: &str = "windowmanager";

/// 动作 id 的前缀，后面接布局的 slug。
pub const ACTION_PREFIX: &str = "windowmanager.";

/// 某个布局的动作 id。
pub fn action_for(layout: Layout) -> String {
    format!("{ACTION_PREFIX}{}", layout.slug())
}

/// 从配置读出来的偏好。
struct Settings {
    gap: f64,
}

impl Settings {
    fn read(config: &Config) -> Self {
        Self {
            gap: config.usize_or(ID, "gap", layout::DEFAULT_GAP as usize) as f64,
        }
    }
}

/// 窗口管理工具。
pub struct WindowManagerTool {
    settings: Settings,
    /// 每个窗口动手之前在哪。只记一步。
    ///
    /// 用 `isize`（HWND 的数值）当键：`HWND` 自己不是 `Hash`，
    /// 而且句柄失效之后这条记录留着也无害 —— 下次那个窗口不在了，
    /// 「恢复」根本轮不到它
    previous: HashMap<isize, Rect>,
}

impl Default for WindowManagerTool {
    fn default() -> Self {
        Self::new()
    }
}

impl WindowManagerTool {
    /// 新建。
    pub fn new() -> Self {
        Self {
            settings: Settings::read(&Config::new()),
            previous: HashMap::new(),
        }
    }

    /// 执行一个布局。
    fn apply(&mut self, want: Layout) -> Result<String, String> {
        let hwnd = windowmanager::foreground()
            .ok_or("现在没有活动窗口（焦点可能在桌面上，或者窗口是最小化的）")?;
        let key = hwnd.0 as isize;
        let (current, shadow) = windowmanager::geometry(hwnd).ok_or("读不到这个窗口的位置")?;

        // rcWork 已经扣掉任务栏，不必像 X11 那边自己减 strut
        let areas = windowmanager::work_areas();
        if areas.is_empty() {
            return Err("读不到显示器布局".to_string());
        }
        let index = display_for(&current, &areas).ok_or("找不到这个窗口在哪块屏上")?;

        let target = match want {
            Layout::Restore => self
                .previous
                .get(&key)
                .copied()
                .ok_or("这个窗口还没有被摆过，没什么可恢复的")?,
            Layout::NextDisplay | Layout::PrevDisplay => {
                if areas.len() < 2 {
                    return Err("只有一块屏".to_string());
                }
                // 顺序要稳定，否则「下一块」两次调用可能指向不同的屏
                let order = layout::sort_displays(&areas);
                let at = order.iter().position(|&i| i == index).unwrap_or(0);
                let next = order[layout::neighbour_display(
                    at,
                    order.len(),
                    want == Layout::NextDisplay,
                )];
                map_across_displays(&current, &areas[index], &areas[next])
            }
            slicing => layout::target(slicing, &current, &areas[index], self.settings.gap),
        };

        // 记下动手之前在哪 —— 但「恢复」本身不该覆盖它，
        // 否则连按两次恢复会把窗口锁在原地
        if want != Layout::Restore {
            self.previous.insert(key, current);
        }

        windowmanager::place(hwnd, &target, &shadow)?;
        Ok(String::new())
    }
}

impl ToolModule for WindowManagerTool {
    fn id(&self) -> &str {
        ID
    }

    fn name(&self) -> &str {
        "窗口管理"
    }

    fn menu_items(&self) -> Vec<MenuItem> {
        let mut items = Vec::new();
        for want in layout::ALL {
            // 跨屏与恢复跟切分布局分开摆，中间加条线
            if matches!(want, Layout::NextDisplay) {
                items.push(MenuItem::Separator);
            }
            items.push(MenuItem::action(&action_for(want), want.title()));
        }
        items
    }

    fn hotkeys(&self) -> Vec<HotkeySpec> {
        // 出厂**一个都不绑**：窗口管理的组合键（Ctrl+Alt+方向键之类）
        // 在每个桌面环境里都已经被占了，绑上去要么冲突要么静默失效。
        // 规格仍然全部列出来，用户在设置里自己挑（根 CLAUDE.md 约定 6）
        layout::ALL
            .iter()
            .map(|want| HotkeySpec::new(&action_for(*want), want.title(), None))
            .collect()
    }

    fn settings_page(&self) -> Option<SettingsPage> {
        Some(SettingsPage::new(
            ID,
            "窗口管理",
            vec![Field::number("gap", "窗口间距（像素）", layout::DEFAULT_GAP as i64, 0, 64)
                .with_help("窗口之间与到屏幕边缘留多少空隙；0 = 严丝合缝")],
        ))
    }

    fn activate(&mut self, config: &Config) {
        self.settings = Settings::read(config);
    }

    fn config_changed(&mut self, config: &Config) {
        self.settings = Settings::read(config);
    }

    fn perform(&mut self, action: &str) -> Result<String, String> {
        let slug = action
            .strip_prefix(ACTION_PREFIX)
            .ok_or_else(|| format!("窗口管理工具不认识动作 {action}"))?;
        let want = Layout::from_slug(slug)
            .ok_or_else(|| format!("窗口管理工具不认识动作 {action}"))?;
        self.apply(want)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_menu_action_is_dispatchable_to_this_tool() {
        let tool = WindowManagerTool::new();
        for item in tool.menu_items() {
            if let MenuItem::Action { id, enabled, .. } = item {
                if enabled {
                    assert!(id.starts_with(ACTION_PREFIX), "{id} 会派发不到自己头上");
                }
            }
        }
    }

    #[test]
    fn an_unknown_action_is_refused() {
        let mut tool = WindowManagerTool::new();
        assert!(tool.perform("windowmanager.nope").unwrap_err().contains("不认识"));
        assert!(tool.perform("别的工具的动作").unwrap_err().contains("不认识"));
    }

    #[test]
    fn every_declared_setting_is_actually_read_somewhere() {
        let page = WindowManagerTool::new().settings_page().unwrap();
        let source = include_str!("windowmanager_module.rs");
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
        assert_eq!(WindowManagerTool::new().settings_page().unwrap().section, ID);
    }

    #[test]
    fn every_layout_gets_a_menu_entry_and_a_hotkey_spec() {
        let tool = WindowManagerTool::new();
        let actions: Vec<String> = tool
            .menu_items()
            .iter()
            .filter_map(|item| match item {
                MenuItem::Action { id, .. } => Some(id.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(actions.len(), layout::ALL.len());
        let specs: Vec<String> = tool.hotkeys().into_iter().map(|s| s.id).collect();
        assert_eq!(specs, actions, "菜单与快捷键规格必须一一对应");
    }

    #[test]
    fn no_window_hotkey_ships_bound() {
        // Ctrl+Alt+方向键之类在每个桌面环境里都已经被占了，
        // 出厂绑上去要么冲突要么静默失效
        let tool = WindowManagerTool::new();
        assert!(tool.hotkeys().iter().all(|spec| spec.default.is_none()));
        assert!(!tool.hotkeys().is_empty(), "规格仍要列出来，设置里才看得到");
    }

    #[test]
    fn every_action_id_round_trips_through_the_layout_slug() {
        // 动作 id 是配置里的快捷键键名，读不回来就等于绑定失效
        for want in layout::ALL {
            let action = action_for(want);
            let slug = action.strip_prefix(ACTION_PREFIX).unwrap();
            assert_eq!(Layout::from_slug(slug), Some(want));
        }
    }

    #[test]
    fn restoring_does_not_overwrite_the_remembered_position() {
        // 连按两次「恢复」会把窗口锁在原地 —— 第二次记的是第一次恢复后的位置
        let mut tool = WindowManagerTool::new();
        tool.previous.insert(42, Rect::new(100.0, 100.0, 800.0, 600.0));
        // 这里没有真的窗口，apply 会在取前台窗口那步就失败；只验「记忆没被动过」
        let _ = tool.perform(&action_for(Layout::Restore));
        assert_eq!(
            tool.previous.get(&42),
            Some(&Rect::new(100.0, 100.0, 800.0, 600.0))
        );
    }
}
