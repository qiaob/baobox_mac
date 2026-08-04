//! 防休眠工具接进 App 框架（Windows）。
//!
//! 与 Linux 的同名文件**逐字对齐**：菜单、动作 id、设置声明都一样，
//! 只有「怎么让系统别睡」那一句换成 `SetThreadExecutionState`。
//!
//! # 到期靠 `tick`，不另起线程
//!
//! 「15 分钟后自动关掉」不需要一条定时线程 —— 框架本来就在定期喂 `tick`
//! （剪贴板监听那次加的）。到点了在 `tick` 里解除即可，顺带回报「变了」。
//!
//! # 解除必须在同一条线程上
//!
//! `SetThreadExecutionState` 是**按线程**记的，而我们整个 App 就一条线程
//! （见 `app.rs`），所以开与关天然在同一条线上。将来真要挪到别的线程去调，
//! 记得这一条 —— 在另一条线程上「关」是关不掉的，而且没有任何报错。

#![cfg(windows)]

use crate::caffeinate;
use baobox_app::{Field, HotkeySpec, MenuItem, SettingsPage, ToolModule};
use baobox_core::caffeinate::{
    duration_from_config, status_text, Session, DEFAULT_DURATION_CHOICES, PRESETS,
};
use baobox_core::config::Config;

/// 工具 id，同时是配置里的节名。**必须与其他平台一致**。
pub const ID: &str = "caffeinate";

/// 动作 id：按默认时长开 / 关。
pub const TOGGLE: &str = "caffeinate.toggle";
/// 动作 id：关掉。
pub const STOP: &str = "caffeinate.stop";
/// 每一档预设的动作 id 前缀，后面接秒数（`0` = 一直开着）。
pub const PRESET_PREFIX: &str = "caffeinate.preset.";

/// 某一档预设的动作 id。
fn preset_action(seconds: Option<i64>) -> String {
    format!("{PRESET_PREFIX}{}", seconds.unwrap_or(0))
}

/// 某一档预设在菜单上显示成什么样：生效中的前面带一个勾。
///
/// 前缀宽度保持一致（勾 vs 两个空格），不然那一列的文字会左右跳。
fn preset_label(title: &str, session: Option<&Session>, seconds: Option<i64>) -> String {
    let ticked = session.is_some_and(|s| s.matches(seconds));
    format!("{} {title}", if ticked { "✓" } else { " " })
}

/// 从配置读出来的偏好。
struct Settings {
    default_duration: Option<i64>,
    prevent_display_sleep: bool,
}

impl Settings {
    fn read(config: &Config) -> Self {
        Self {
            default_duration: duration_from_config(&config.string_or(
                ID,
                "default_duration",
                "0",
            )),
            prevent_display_sleep: config.bool_or(ID, "prevent_display_sleep", false),
        }
    }
}

/// 防休眠工具。
pub struct CaffeinateTool {
    settings: Settings,
    session: Option<Session>,
}

impl Default for CaffeinateTool {
    fn default() -> Self {
        Self::new()
    }
}

impl CaffeinateTool {
    /// 新建。
    pub fn new() -> Self {
        Self {
            settings: Settings::read(&Config::new()),
            session: None,
        }
    }

    /// 开始防休眠。
    fn start(&mut self, duration: Option<i64>) -> Result<String, String> {
        // 同一条线程上再调一次就是覆盖，不会叠加 —— 但先归零更好读
        self.stop();
        caffeinate::engage(self.settings.prevent_display_sleep)?;
        self.session = Some(Session::start(crate::now_seconds(), duration));
        let note = if self.settings.prevent_display_sleep {
            "系统与显示器都不会休眠"
        } else {
            "系统不会休眠（显示器仍会关）"
        };
        Ok(match duration {
            Some(seconds) => format!("防休眠已开启 {} 分钟 · {note}", seconds / 60),
            None => format!("防休眠已开启（一直开着）· {note}"),
        })
    }

    /// 解除。
    fn stop(&mut self) {
        if self.session.is_some() {
            caffeinate::release();
        }
        self.session = None;
    }
}

impl ToolModule for CaffeinateTool {
    fn id(&self) -> &str {
        ID
    }

    fn name(&self) -> &str {
        "防休眠"
    }

    fn menu_items(&self) -> Vec<MenuItem> {
        let now = crate::now_seconds();
        let mut items = vec![
            MenuItem::disabled(&status_text(self.session.as_ref(), now)),
            MenuItem::Separator,
        ];
        // 没开着时给一条「按默认时长开」——「默认时长」这个设置项
        // 得有个能按到的地方，否则用户改了它什么都不会发生
        if self.session.is_none() {
            items.push(MenuItem::action(TOGGLE, "按默认时长开启"));
            items.push(MenuItem::Separator);
        }
        for preset in PRESETS {
            // 当前生效的那一档标出来。勾写进标签里而不是用 `with_hint` ——
            // 那个位置在框架里是留给快捷键的，借来打勾迟早会串
            items.push(MenuItem::action(
                &preset_action(preset.seconds),
                &preset_label(preset.title, self.session.as_ref(), preset.seconds),
            ));
        }
        items.push(MenuItem::Separator);
        items.push(if self.session.is_some() {
            MenuItem::action(STOP, "关闭防休眠")
        } else {
            MenuItem::disabled("关闭防休眠")
        });
        items
    }

    fn hotkeys(&self) -> Vec<HotkeySpec> {
        // 纯菜单操作，不占用组合键（与 macOS 侧一致）
        Vec::new()
    }

    fn settings_page(&self) -> Option<SettingsPage> {
        Some(SettingsPage::new(
            ID,
            "防休眠",
            vec![
                Field::choice(
                    "default_duration",
                    "默认时长",
                    &DEFAULT_DURATION_CHOICES,
                    "0",
                )
                .with_help("菜单里「按默认时长开启」用的就是它"),
                Field::toggle("prevent_display_sleep", "同时不让显示器关掉", false)
                    .with_help("除了挡住系统休眠，再挡住屏保 —— 看视频、盯监控时用得上"),
            ],
        ))
    }

    fn activate(&mut self, config: &Config) {
        self.settings = Settings::read(config);
    }

    fn config_changed(&mut self, config: &Config) {
        let was_display = self.settings.prevent_display_sleep;
        self.settings = Settings::read(config);
        // 「同时不让显示器关掉」改了、而且正开着：用新口径重建一次，
        // **保留剩下的时间**（不然用户改个开关会顺手把计时清零）
        if was_display != self.settings.prevent_display_sleep {
            if let Some(session) = self.session {
                let remaining = session.until.map(|until| (until - crate::now_seconds()).max(1));
                let requested = session.requested;
                if let Ok(_) = self.start(remaining) {
                    // start 会把 requested 写成「剩余秒数」，那样菜单里
                    // 四个预设会一个勾都没有 —— 还原成用户当初选的那一档
                    if let Some(current) = self.session.as_mut() {
                        current.requested = requested;
                    }
                }
            }
        }
    }

    fn tick(&mut self) -> bool {
        let Some(session) = self.session else {
            return false;
        };
        if !session.is_expired(crate::now_seconds()) {
            return false;
        }
        self.stop();
        true
    }

    fn will_terminate(&mut self) {
        // 退出前一定要解除，否则这台机器会一直不睡，而用户已经找不到是谁干的了
        self.stop();
    }

    fn perform(&mut self, action: &str) -> Result<String, String> {
        match action {
            TOGGLE => {
                if self.session.is_some() {
                    self.stop();
                    Ok("防休眠已关闭".to_string())
                } else {
                    self.start(self.settings.default_duration)
                }
            }
            STOP => {
                self.stop();
                Ok("防休眠已关闭".to_string())
            }
            other => match other.strip_prefix(PRESET_PREFIX) {
                Some(seconds) => {
                    let duration = duration_from_config(seconds);
                    // 再点一次当前生效的那一档 = 关掉，与 mac 的勾选手感一致
                    match &self.session {
                        Some(session) if session.matches(duration) => {
                            self.stop();
                            Ok("防休眠已关闭".to_string())
                        }
                        _ => self.start(duration),
                    }
                }
                None => Err(format!("防休眠工具不认识动作 {other}")),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_menu_action_is_dispatchable_to_this_tool() {
        let tool = CaffeinateTool::new();
        for item in tool.menu_items() {
            if let MenuItem::Action { id, enabled, .. } = item {
                if enabled {
                    assert!(id.starts_with("caffeinate."), "{id} 会派发不到自己头上");
                }
            }
        }
    }

    #[test]
    fn an_unknown_action_is_refused() {
        let mut tool = CaffeinateTool::new();
        assert!(tool.perform("caffeinate.nope").unwrap_err().contains("不认识"));
    }

    #[test]
    fn every_declared_setting_is_actually_read_somewhere() {
        let page = CaffeinateTool::new().settings_page().unwrap();
        let source = include_str!("caffeinate_module.rs");
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
        assert_eq!(CaffeinateTool::new().settings_page().unwrap().section, ID);
    }

    #[test]
    fn every_preset_gets_its_own_action_id_and_they_all_parse_back() {
        let mut seen = std::collections::HashSet::new();
        for preset in PRESETS {
            let action = preset_action(preset.seconds);
            assert!(seen.insert(action.clone()), "{action} 撞名了");
            let suffix = action.strip_prefix(PRESET_PREFIX).unwrap();
            assert_eq!(duration_from_config(suffix), preset.seconds);
        }
    }

    #[test]
    fn the_menu_offers_a_way_to_use_the_default_duration() {
        // mac 那边踩过：设置里那个显眼的「默认时长」没有任何入口能触发，
        // 用户改了 100% 不会有任何效果
        let tool = CaffeinateTool::new();
        let ids: Vec<String> = tool
            .menu_items()
            .iter()
            .filter_map(|item| match item {
                MenuItem::Action { id, enabled, .. } if *enabled => Some(id.clone()),
                _ => None,
            })
            .collect();
        assert!(ids.iter().any(|id| id == TOGGLE), "「按默认时长开启」得能按到");
    }

    #[test]
    fn stopping_is_greyed_out_rather_than_missing_when_nothing_is_running() {
        // 菜单项消失的话，用户会以为程序坏了
        let tool = CaffeinateTool::new();
        let labels: Vec<String> = tool
            .menu_items()
            .iter()
            .filter_map(|item| match item {
                MenuItem::Action { label, enabled, .. } if !*enabled => Some(label.clone()),
                _ => None,
            })
            .collect();
        assert!(labels.iter().any(|l| l.contains("关闭")));
    }

    #[test]
    fn an_expired_session_is_cleared_by_the_tick_and_reports_the_change() {
        let mut tool = CaffeinateTool::new();
        // 直接摆一个已经过期的会话，不去碰 DBus
        tool.session = Some(Session::start(crate::now_seconds() - 10_000, Some(60)));
        assert!(tool.tick(), "到期了要回报「变了」，托盘菜单才会跟上");
        assert!(tool.session.is_none());
        // 已经没了，再 tick 不该继续回报变化（否则菜单会一秒重建几十次）
        assert!(!tool.tick());
    }

    #[test]
    fn an_open_ended_session_is_never_expired_by_the_tick() {
        let mut tool = CaffeinateTool::new();
        tool.session = Some(Session::start(0, None));
        assert!(!tool.tick());
        assert!(tool.session.is_some(), "「一直开着」不该被自动关掉");
    }

    #[test]
    fn the_running_preset_is_ticked_in_the_menu() {
        let mut tool = CaffeinateTool::new();
        tool.session = Some(Session::start(crate::now_seconds(), Some(900)));
        let ticked = tool
            .menu_items()
            .iter()
            .filter(|item| matches!(item, MenuItem::Action { label, .. } if label.starts_with('✓')))
            .count();
        assert_eq!(ticked, 1, "当前生效的那一档要打勾，且只有一档");

        // 没开着的时候一个勾都不该有
        tool.session = None;
        assert!(!tool
            .menu_items()
            .iter()
            .any(|item| matches!(item, MenuItem::Action { label, .. } if label.starts_with('✓'))));
    }

    #[test]
    fn every_preset_label_keeps_the_same_prefix_width() {
        // 宽度不一致的话，打勾那一瞬间整列文字会左右跳一下
        let session = Session::start(0, Some(900));
        let on = preset_label("15 分钟", Some(&session), Some(900));
        let off = preset_label("15 分钟", Some(&session), Some(3600));
        assert_eq!(on.chars().count(), off.chars().count());
    }
}
