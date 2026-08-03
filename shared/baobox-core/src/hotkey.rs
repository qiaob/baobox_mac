//! 快捷键组合：解析、格式化、平台无关的键位表示。
//!
//! 对应 macOS 侧的 `KeyCombo`。三平台的**表示与文本格式一致**，
//! 因此配置文件在哪台机器上写的都能读；映射到各自的键码由平台层负责
//! （X11 keysym / Windows 虚拟键码 / Carbon key code）。
//!
//! 文本格式：修饰键用 `+` 连接，主键放最后，大小写不敏感。
//!
//! ```
//! use baobox_core::hotkey::{KeyCombo, KeyCode};
//! let combo = KeyCombo::parse("Ctrl+Shift+S").unwrap();
//! assert_eq!(combo.key, KeyCode::Char('s'));
//! assert!(combo.ctrl && combo.shift);
//! assert_eq!(combo.to_string(), "Ctrl+Shift+S");
//! ```

use std::fmt;

/// 主键。只列截图工具用得到的，不做全键盘覆盖 ——
/// 用不到的键位留在这里只会让三个平台各写一份没人验证的映射。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyCode {
    /// 字母或数字，统一存小写
    Char(char),
    /// 功能键 F1–F24
    F(u8),
    /// Print Screen —— Windows 上截图的习惯键
    PrintScreen,
    /// 空格
    Space,
    /// 回车
    Enter,
}

impl fmt::Display for KeyCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            KeyCode::Char(c) => write!(f, "{}", c.to_ascii_uppercase()),
            KeyCode::F(n) => write!(f, "F{n}"),
            KeyCode::PrintScreen => write!(f, "PrintScreen"),
            KeyCode::Space => write!(f, "Space"),
            KeyCode::Enter => write!(f, "Enter"),
        }
    }
}

/// 一个快捷键组合。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyCombo {
    /// 主键
    pub key: KeyCode,
    /// Control
    pub ctrl: bool,
    /// Shift
    pub shift: bool,
    /// Alt / Option
    pub alt: bool,
    /// Super / Windows / Command
    pub meta: bool,
}

impl KeyCombo {
    /// 只有主键、不带修饰的组合。
    pub fn new(key: KeyCode) -> Self {
        Self {
            key,
            ctrl: false,
            shift: false,
            alt: false,
            meta: false,
        }
    }

    /// 是否至少带一个修饰键。
    ///
    /// 不带修饰的全局快捷键会把该键从所有 App 手里抢走 —— 除了 PrintScreen
    /// 这种本来就是系统级功能键的，其余一律应当拒绝。
    pub fn is_safe_global(&self) -> bool {
        self.ctrl || self.shift || self.alt || self.meta || self.key == KeyCode::PrintScreen
    }

    /// 解析 `"Ctrl+Shift+S"` 这样的文本。大小写不敏感，允许空格。
    ///
    /// 修饰键别名：`Cmd` / `Command` / `Win` / `Super` / `Meta` 都映射到 `meta`；
    /// `Opt` / `Option` / `Alt` 都映射到 `alt`。这样同一份配置在三个平台上都读得懂。
    pub fn parse(text: &str) -> Result<Self, String> {
        let parts: Vec<&str> = text
            .split('+')
            .map(str::trim)
            .filter(|p| !p.is_empty())
            .collect();
        if parts.is_empty() {
            return Err("快捷键为空".to_string());
        }

        let mut combo = KeyCombo {
            key: KeyCode::Space,
            ctrl: false,
            shift: false,
            alt: false,
            meta: false,
        };
        let mut key_seen = false;

        for part in parts {
            let lower = part.to_ascii_lowercase();
            match lower.as_str() {
                "ctrl" | "control" => combo.ctrl = true,
                "shift" => combo.shift = true,
                "alt" | "opt" | "option" => combo.alt = true,
                "cmd" | "command" | "win" | "super" | "meta" => combo.meta = true,
                _ => {
                    if key_seen {
                        return Err(format!("快捷键里出现了多个主键：{text}"));
                    }
                    combo.key = parse_key(&lower)?;
                    key_seen = true;
                }
            }
        }

        if !key_seen {
            return Err(format!("快捷键缺少主键：{text}"));
        }
        Ok(combo)
    }
}

fn parse_key(lower: &str) -> Result<KeyCode, String> {
    match lower {
        "space" => return Ok(KeyCode::Space),
        "enter" | "return" => return Ok(KeyCode::Enter),
        "printscreen" | "prtsc" | "print" => return Ok(KeyCode::PrintScreen),
        _ => {}
    }
    if let Some(number) = lower.strip_prefix('f') {
        if let Ok(n) = number.parse::<u8>() {
            if (1..=24).contains(&n) {
                return Ok(KeyCode::F(n));
            }
            return Err(format!("功能键只支持 F1–F24，收到 F{n}"));
        }
    }
    let mut chars = lower.chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) if c.is_ascii_alphanumeric() => Ok(KeyCode::Char(c)),
        _ => Err(format!("无法识别的按键：{lower}")),
    }
}

impl fmt::Display for KeyCombo {
    /// 输出规范形式，修饰键顺序固定为 Ctrl → Alt → Shift → Meta。
    ///
    /// 顺序固定是为了让 `parse(x).to_string()` 稳定 —— 配置文件里不会因为
    /// 用户写法不同而产生无意义的 diff。
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut parts: Vec<String> = Vec::new();
        if self.ctrl {
            parts.push("Ctrl".to_string());
        }
        if self.alt {
            parts.push("Alt".to_string());
        }
        if self.shift {
            parts.push("Shift".to_string());
        }
        if self.meta {
            parts.push("Meta".to_string());
        }
        parts.push(self.key.to_string());
        write!(f, "{}", parts.join("+"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_typical_combo() {
        let combo = KeyCombo::parse("Ctrl+Shift+S").unwrap();
        assert_eq!(combo.key, KeyCode::Char('s'));
        assert!(combo.ctrl && combo.shift);
        assert!(!combo.alt && !combo.meta);
    }

    #[test]
    fn parsing_is_case_and_space_insensitive() {
        let a = KeyCombo::parse("ctrl+shift+s").unwrap();
        let b = KeyCombo::parse("  CTRL + Shift +  S ").unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn modifier_aliases_map_to_the_same_flag() {
        for alias in ["Cmd", "Command", "Win", "Super", "Meta"] {
            let combo = KeyCombo::parse(&format!("{alias}+S")).unwrap();
            assert!(combo.meta, "{alias} 应当映射到 meta");
        }
        for alias in ["Alt", "Opt", "Option"] {
            assert!(KeyCombo::parse(&format!("{alias}+S")).unwrap().alt);
        }
    }

    #[test]
    fn round_trip_is_stable_regardless_of_input_order() {
        // 用户怎么写都归一到同一个规范形式，配置文件不会产生无意义 diff
        let written = KeyCombo::parse("Shift+Ctrl+S").unwrap().to_string();
        assert_eq!(written, "Ctrl+Shift+S");
        assert_eq!(KeyCombo::parse(&written).unwrap().to_string(), written);
    }

    #[test]
    fn function_keys_and_named_keys() {
        assert_eq!(KeyCombo::parse("F5").unwrap().key, KeyCode::F(5));
        assert_eq!(KeyCombo::parse("f12").unwrap().key, KeyCode::F(12));
        assert_eq!(KeyCombo::parse("Ctrl+Space").unwrap().key, KeyCode::Space);
        assert_eq!(KeyCombo::parse("PrintScreen").unwrap().key, KeyCode::PrintScreen);
        assert_eq!(KeyCombo::parse("prtsc").unwrap().key, KeyCode::PrintScreen);
    }

    #[test]
    fn rejects_malformed_input_with_a_useful_message() {
        assert!(KeyCombo::parse("").is_err());
        assert!(KeyCombo::parse("Ctrl+").unwrap_err().contains("缺少主键"));
        assert!(KeyCombo::parse("Ctrl+S+A").unwrap_err().contains("多个主键"));
        assert!(KeyCombo::parse("F99").unwrap_err().contains("F1–F24"));
        assert!(KeyCombo::parse("Ctrl+抓").is_err());
    }

    #[test]
    fn unmodified_keys_are_rejected_as_global_hotkeys() {
        // 不带修饰会把这个键从所有 App 手里抢走
        assert!(!KeyCombo::parse("S").unwrap().is_safe_global());
        assert!(KeyCombo::parse("Ctrl+S").unwrap().is_safe_global());
        // PrintScreen 本来就是系统级功能键，例外
        assert!(KeyCombo::parse("PrintScreen").unwrap().is_safe_global());
    }
}
