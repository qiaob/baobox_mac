//! 键盘点击工具接进 App 框架（Linux）。
//!
//! 标签怎么发、打字之后怎么反应在 `baobox_core::hints`；
//! 屏幕上有哪些可点的东西、怎么点在 `keyboardnav`。这个文件只回答框架的问题，
//! 外加跑那个「显示标签 → 收键盘 → 点下去」的循环。
//!
//! # 覆盖层借 GTK
//!
//! 标签要画在**所有窗口之上**，而且要能收键盘。截图覆盖层是 X11 手绘的，
//! 但那套只画矩形；标签要画文字，而 X11 核心字体画中文都成问题。
//! GTK 已经为设置窗口引进来了，借它既有文字又有透明窗口。
//!
//! # 键盘滚动没有做
//!
//! mac 那边还有「j/k 滚页面」。它要一个「只收滚动键、别的都放行」的
//! **全局键盘监听** —— 与关键字展开是同一类代码，也是同一个理由没做：
//! 这里没有图形环境能验证它，而一个吃掉用户所有按键却又不生效的模式，
//! 比不给这个功能糟得多。键位映射（`hints::Scroll`）已经写好并测过了。
//!
//! # 扫描要在覆盖层出现**之前**
//!
//! 反过来的话，覆盖层自己会被扫进去 —— 它也是一个窗口，
//! 里面那些标签在 AT-SPI 看来都是可点的元素。

use crate::keyboardnav;
use baobox_app::{HotkeySpec, MenuItem, SettingsPage, ToolModule, Field};
use baobox_core::config::Config;
use baobox_core::hints::{self, Session};

/// 工具 id，同时是配置里的节名。**必须与其他平台一致**。
pub const ID: &str = "keyboardnav";

/// 动作 id：给可点元素打标签。
pub const CLICK: &str = "keyboardnav.click";

/// 从配置读出来的偏好。
struct Settings {
    alphabet: String,
    continuous: bool,
}

impl Settings {
    fn read(config: &Config) -> Self {
        let alphabet = config.string_or(ID, "alphabet", hints::DEFAULT_ALPHABET);
        Self {
            // 用户可能填了重复字符或者空的 —— 那会让标签发不出来，退回默认
            alphabet: sanitize_alphabet(&alphabet),
            continuous: config.bool_or(ID, "continuous", false),
        }
    }
}

/// 把用户填的字母表洗干净：去重、只留 ASCII 字母、太短就退回默认。
///
/// 重复字符会让两个不同的目标拿到同一个标签；少于两个字符会让
/// 标签退化成 `a` / `aa` / `aaa`，打起来毫无意义。
pub fn sanitize_alphabet(raw: &str) -> String {
    let mut seen = std::collections::HashSet::new();
    let cleaned: String = raw
        .chars()
        .map(|c| c.to_ascii_lowercase())
        .filter(|c| c.is_ascii_lowercase())
        .filter(|c| seen.insert(*c))
        .collect();
    if cleaned.chars().count() < 2 {
        return hints::DEFAULT_ALPHABET.to_string();
    }
    cleaned
}

/// 键盘点击工具。
pub struct KeyboardNavTool {
    settings: Settings,
}

impl Default for KeyboardNavTool {
    fn default() -> Self {
        Self::new()
    }
}

impl KeyboardNavTool {
    /// 新建。
    pub fn new() -> Self {
        Self {
            settings: Settings::read(&Config::new()),
        }
    }

    /// 打标签 → 收键盘 → 点下去。
    fn run_click(&mut self) -> Result<String, String> {
        // 扫描必须在覆盖层出现之前 —— 否则覆盖层自己会被扫进去
        let targets = keyboardnav::scan()?;
        if targets.is_empty() {
            return Err("这个窗口里没找到可点的元素".to_string());
        }
        let hints = hints::assign(targets, &self.settings.alphabet);
        let mut session = Session::new(hints, &self.settings.alphabet, self.settings.continuous);

        // 覆盖层跑完整场再回来 —— 每按一个键重建一次会闪，
        // 而且重新抓键盘那几十毫秒里用户打的字会漏到底下的程序里
        let picked = crate::hint_overlay::run(&mut session)?;
        if picked.is_empty() {
            return Ok(String::new());
        }

        let session_x11 = crate::x11capture::X11Session::open()?;
        let root = session_x11.screen().root;
        for hit in &picked {
            keyboardnav::click(session_x11.connection(), root, hit.target.x, hit.target.y)?;
        }
        Ok(format!("点了 {} 下", picked.len()))
    }

}

impl ToolModule for KeyboardNavTool {
    fn id(&self) -> &str {
        ID
    }

    fn name(&self) -> &str {
        "键盘点击"
    }

    fn menu_items(&self) -> Vec<MenuItem> {
        vec![MenuItem::action(CLICK, "给可点元素打标签")]
    }

    fn hotkeys(&self) -> Vec<HotkeySpec> {
        // 出厂不绑：这是「按下去整个屏幕就变样」的操作，
        // 误触的代价比别的工具大得多（根 CLAUDE.md 约定 6）
        vec![HotkeySpec::new(CLICK, "给可点元素打标签", None)]
    }

    fn settings_page(&self) -> Option<SettingsPage> {
        Some(SettingsPage::new(
            ID,
            "键盘点击",
            vec![
                Field::text("alphabet", "标签字母表", hints::DEFAULT_ALPHABET, "asdfghjk…")
                    .with_help("用哪些字母发标签；重复的会被去掉，少于两个则退回默认"),
                Field::toggle("continuous", "连续点击", false)
                    .with_help("点完一个不退出，可以接着点下一个；按 Esc 退出"),
            ],
        ))
    }

    fn activate(&mut self, config: &Config) {
        self.settings = Settings::read(config);
    }

    fn config_changed(&mut self, config: &Config) {
        self.settings = Settings::read(config);
    }

    fn perform(&mut self, action: &str) -> Result<String, String> {
        match action {
            CLICK => self.run_click(),
            other => Err(format!("键盘点击工具不认识动作 {other}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_menu_action_is_dispatchable_to_this_tool() {
        let tool = KeyboardNavTool::new();
        for item in tool.menu_items() {
            if let MenuItem::Action { id, enabled, .. } = item {
                if enabled {
                    assert!(id.starts_with("keyboardnav."), "{id} 会派发不到自己头上");
                }
            }
        }
    }

    #[test]
    fn an_unknown_action_is_refused() {
        let mut tool = KeyboardNavTool::new();
        assert!(tool.perform("keyboardnav.nope").unwrap_err().contains("不认识"));
    }

    #[test]
    fn every_declared_setting_is_actually_read_somewhere() {
        let page = KeyboardNavTool::new().settings_page().unwrap();
        let source = include_str!("keyboardnav_module.rs");
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
        assert_eq!(KeyboardNavTool::new().settings_page().unwrap().section, ID);
    }

    #[test]
    fn a_duplicate_letter_in_the_alphabet_is_dropped() {
        // 重复字符会让两个不同的目标拿到同一个标签
        assert_eq!(sanitize_alphabet("aabbcc"), "abc");
        assert_eq!(sanitize_alphabet("AbAb"), "ab");
    }

    #[test]
    fn a_useless_alphabet_falls_back_to_the_default() {
        // 少于两个字符会让标签退化成 a / aa / aaa，打起来毫无意义
        assert_eq!(sanitize_alphabet(""), hints::DEFAULT_ALPHABET);
        assert_eq!(sanitize_alphabet("a"), hints::DEFAULT_ALPHABET);
        assert_eq!(sanitize_alphabet("1234"), hints::DEFAULT_ALPHABET);
        assert_eq!(sanitize_alphabet("中文"), hints::DEFAULT_ALPHABET);
    }

    #[test]
    fn neither_hotkey_ships_bound() {
        // 这是「按下去整个屏幕就变样」的操作，误触代价比别的工具大
        let tool = KeyboardNavTool::new();
        assert!(tool.hotkeys().iter().all(|s| s.default.is_none()));
        assert_eq!(tool.hotkeys().len(), 1);
    }
}
