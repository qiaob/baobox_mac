//! 回填粘贴：把内容放进剪贴板，然后替用户按一下 Ctrl+V。
//!
//! 对应 macOS 侧的 `PasteService`。这是剪贴板历史真正好用的关键 ——
//! 从面板里选一条，它直接落到你刚才在打字的那个窗口里，
//! 而不是「复制好了，现在请你自己去粘贴」。
//!
//! # 靠 XTEST 合成按键
//!
//! X11 的 XTEST 扩展能让我们伪造一次按键，事件走的路径和真按键完全一样，
//! 所以目标程序分辨不出来（也就不会有程序单独把它挡掉）。
//!
//! # 三个必须做对的顺序问题
//!
//! 1. **面板要先关掉**。面板是我们自己的窗口，它开着的时候焦点在我们这儿，
//!    合成的 Ctrl+V 会打到自己身上。
//! 2. **要等焦点真的回到原来那个窗口**。关窗口是异步的，紧接着就发按键
//!    多半会落空 —— 所以中间要停一下（[`FOCUS_SETTLE`]）。
//! 3. **修饰键要按下去、也要抬起来**。只按不抬的话，用户接下来打的每一个字
//!    都会带着 Ctrl —— 这是这类功能最经典、也最气人的 bug。
//!
//! # 关键字展开会用到这里
//!
//! 「打 `;sig` 自动替换」那条路还没接（缺的是全局键盘监听，见
//! `clipboard_module` 的模块说明）。接上之后它需要的就是这里的 [`send`]，
//! 外加先合成若干次退格 —— 逐字符合成按键是不行的，那在中文、emoji
//! 以及任何非当前键盘布局的字符上都会打错。

use std::time::Duration;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::ConnectionExt as _;
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::rust_connection::RustConnection;

/// 关掉面板之后等焦点回位的时间。
///
/// 太短按键会落到空处；太长用户能感觉到延迟。
pub const FOCUS_SETTLE: Duration = Duration::from_millis(120);

/// 按下 / 抬起之间的间隔。有些程序对「同一毫秒按下又抬起」反应不过来。
const KEY_GAP: Duration = Duration::from_millis(12);

/// X11 keysym。
const XK_CONTROL_L: u32 = 0xffe3;
const XK_SHIFT_L: u32 = 0xffe1;
const XK_V: u32 = 0x76;

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
/// **调用方必须先关掉面板并等焦点回位** —— 否则按键会打到我们自己身上。
pub fn send(conn: &RustConnection, style: Style) -> Result<(), String> {
    let control = keycode_for(conn, XK_CONTROL_L)?;
    let shift = keycode_for(conn, XK_SHIFT_L)?;
    let v = keycode_for(conn, XK_V)?;

    let mut modifiers = vec![control];
    if style == Style::Terminal {
        modifiers.push(shift);
    }

    // 按下修饰键 → 按 V → 抬起 V → 抬起修饰键（倒序）
    for key in &modifiers {
        press(conn, *key, true)?;
    }
    press(conn, v, true)?;
    std::thread::sleep(KEY_GAP);
    press(conn, v, false)?;
    for key in modifiers.iter().rev() {
        // 抬起必须发出去。只按不抬的话，用户接下来打的每个字都带着 Ctrl
        press(conn, *key, false)?;
    }
    conn.flush().map_err(|e| e.to_string())?;
    Ok(())
}

fn press(conn: &RustConnection, keycode: u8, down: bool) -> Result<(), String> {
    // 2 = KeyPress，3 = KeyRelease
    let event_type = if down { 2 } else { 3 };
    conn.xtest_fake_input(event_type, keycode, 0, x11rb::NONE, 0, 0, 0)
        .map_err(|e| format!("合成按键失败（XTEST 可用吗？）：{e}"))?;
    Ok(())
}

/// keysym → keycode。
fn keycode_for(conn: &RustConnection, keysym: u32) -> Result<u8, String> {
    let setup = conn.setup();
    let first = setup.min_keycode;
    let count = setup.max_keycode - setup.min_keycode + 1;
    let reply = conn
        .get_keyboard_mapping(first, count)
        .map_err(|e| e.to_string())?
        .reply()
        .map_err(|e| format!("读取键盘映射失败：{e}"))?;
    let per = reply.keysyms_per_keycode as usize;
    if per == 0 {
        return Err("键盘映射为空".to_string());
    }
    for (index, chunk) in reply.keysyms.chunks(per).enumerate() {
        if chunk.contains(&keysym) {
            return Ok(first + index as u8);
        }
    }
    Err(format!("当前键盘布局里找不到 keysym 0x{keysym:x}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_style_is_read_leniently() {
        assert_eq!(Style::from_str("terminal"), Style::Terminal);
        assert_eq!(Style::from_str("  Ctrl+Shift+V "), Style::Terminal);
        assert_eq!(Style::from_str("normal"), Style::Normal);
        // 认不出的按普通处理，而不是报错让粘贴整个失效
        assert_eq!(Style::from_str("香蕉"), Style::Normal);
        assert_eq!(Style::from_str(""), Style::Normal);
    }

    #[test]
    fn the_focus_delay_is_perceptible_but_short() {
        // 太短按键会落到空处；太长用户能感觉到延迟
        assert!(FOCUS_SETTLE >= Duration::from_millis(50));
        assert!(FOCUS_SETTLE <= Duration::from_millis(300));
    }
}
