//! 回填粘贴（Windows）：把内容放进剪贴板，然后替用户按一下 Ctrl+V。
//!
//! 与 Linux 的 `paste.rs` 对应。用 `SendInput` 合成按键 ——
//! 它注入的是系统级的输入事件，目标程序分辨不出来。
//!
//! # 三个必须做对的顺序问题（与 Linux 侧同源）
//!
//! 1. **面板要先关掉**，否则合成的 Ctrl+V 打到自己身上。
//! 2. **要等焦点回到原来那个窗口**（[`FOCUS_SETTLE`]）。
//! 3. **修饰键要按下去、也要抬起来**。只按不抬的话用户接下来打的每个字
//!    都带着 Ctrl —— 这是这类功能最经典也最气人的 bug。
//!
//! # `KEYEVENTF_KEYUP` 不能漏
//!
//! `SendInput` 的按下与抬起是两条独立的记录，靠 `dwFlags` 区分。
//! 少发一条抬起，那个修饰键就会**一直卡在按下状态**，
//! 而且用户没法自己解开（他手上那个键本来就没按下去过）。

#![cfg(windows)]

use std::time::Duration;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    VIRTUAL_KEY, VK_CONTROL, VK_SHIFT, VK_V,
};

/// 关掉面板之后等焦点回位的时间。
pub const FOCUS_SETTLE: Duration = Duration::from_millis(120);

/// 合成完之后等系统把注入的按键处理过「热键匹配」那一步，再恢复被挂起的注册。
/// 立刻恢复的话，刚注入的组合还在输入队列里，恢复的热键会把它吞回去。
const HOTKEY_RESUME_DELAY: Duration = Duration::from_millis(60);

/// 粘贴时用哪种组合。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Style {
    /// Ctrl+V，绝大多数程序
    Normal,
    /// Ctrl+Shift+V，终端里粘贴用的是这个
    Terminal,
}

impl Style {
    /// 从配置里的文本读出来。认不出的按普通处理。
    pub fn from_str(value: &str) -> Style {
        match value.trim().to_lowercase().as_str() {
            "terminal" | "ctrl+shift+v" => Style::Terminal,
            _ => Style::Normal,
        }
    }
}

/// 合成一次粘贴。
///
/// **调用方必须先关掉面板并等焦点回位**。
pub fn send(style: Style) -> Result<(), String> {
    // 我们自己的全局热键对合成的组合一样生效（RegisterHotKey 不区分注入的输入）。
    // 「剪贴板历史」默认的 Ctrl+Shift+V 恰好与终端风格的粘贴同键 ——
    // 先把撞车的注册挂起，粘完再恢复（guard drop 时）
    let _guard = crate::hotkeys::suspend_matching(true, style == Style::Terminal, false, 'v');

    let mut modifiers = vec![VK_CONTROL];
    if style == Style::Terminal {
        modifiers.push(VK_SHIFT);
    }

    let mut records = Vec::with_capacity(modifiers.len() * 2 + 2);
    for key in &modifiers {
        records.push(key_record(*key, false));
    }
    records.push(key_record(VK_V, false));
    records.push(key_record(VK_V, true));
    // 倒序抬起。少发一条的话那个修饰键会一直卡在按下状态，
    // 而用户没法自己解开 —— 他手上那个键本来就没按下去过
    for key in modifiers.iter().rev() {
        records.push(key_record(*key, true));
    }

    let sent = unsafe { SendInput(&records, std::mem::size_of::<INPUT>() as i32) };
    if sent as usize != records.len() {
        return Err("合成按键失败（可能被更高权限的窗口挡住了）".to_string());
    }
    std::thread::sleep(HOTKEY_RESUME_DELAY);
    Ok(())
}

/// 一条按键记录。
fn key_record(key: VIRTUAL_KEY, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: key,
                wScan: 0,
                dwFlags: if up {
                    KEYEVENTF_KEYUP
                } else {
                    KEYBD_EVENT_FLAGS(0)
                },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_style_is_read_leniently_exactly_like_on_linux() {
        assert_eq!(Style::from_str("terminal"), Style::Terminal);
        assert_eq!(Style::from_str("  Ctrl+Shift+V "), Style::Terminal);
        assert_eq!(Style::from_str("normal"), Style::Normal);
        // 认不出的按普通处理，而不是让粘贴整个失效
        assert_eq!(Style::from_str("香蕉"), Style::Normal);
        assert_eq!(Style::from_str(""), Style::Normal);
    }

    #[test]
    fn a_key_record_marks_up_and_down_differently() {
        let down = key_record(VK_V, false);
        let up = key_record(VK_V, true);
        unsafe {
            assert_eq!(down.Anonymous.ki.dwFlags.0, 0);
            assert_ne!(up.Anonymous.ki.dwFlags.0 & KEYEVENTF_KEYUP.0, 0);
            assert_eq!(down.Anonymous.ki.wVk, VK_V);
        }
    }

    #[test]
    fn the_focus_delay_matches_the_linux_side() {
        assert!(FOCUS_SETTLE >= Duration::from_millis(50));
        assert!(FOCUS_SETTLE <= Duration::from_millis(300));
    }
}
