//! 常驻进程：注册全局快捷键，按下即唤起截图覆盖层。
//!
//! 没有它，截图工具就只能从终端调起 —— 那不叫截图工具。
//!
//! # X11 的锁定修饰键陷阱
//!
//! `GrabKey` 匹配的是**精确的修饰键掩码**。用户开着 NumLock 时，事件里会多一个
//! `Mod2`，于是「Ctrl+Shift+S」这个 grab 就不匹配了 —— 表现为「快捷键有时灵有时不灵」，
//! 而用户根本想不到是 NumLock 的锅。
//!
//! 正确做法是把 Lock（CapsLock）、Mod2（NumLock）、Mod5（ScrollLock）的
//! **所有组合**都各 grab 一遍，共 8 次。

use baobox_core::hotkey::{KeyCode, KeyCombo};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{ConnectionExt as _, GrabMode, ModMask};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;

/// X11 keysym 常量（只列主键会用到的）。
mod keysym {
    /// XK_space
    pub const SPACE: u32 = 0x20;
    /// XK_Return
    pub const RETURN: u32 = 0xff0d;
    /// XK_Print
    pub const PRINT: u32 = 0xff61;
    /// XK_F1；F1–F24 连续
    pub const F1: u32 = 0xffbe;
}

/// 锁定类修饰键的原始位值。`ModMask::bits()` 不是 const，无法在常量里用，
/// 所以这里写字面量 —— 下面有测试锁死它们与 `ModMask` 一致，改动会被立刻发现。
const LOCK_BIT: u16 = 2; // CapsLock
const NUM_BIT: u16 = 16; // NumLock（Mod2）
const SCROLL_BIT: u16 = 128; // ScrollLock（Mod5）

/// 会干扰 `GrabKey` 精确匹配的锁定修饰键的**全部 8 种组合**。
const LOCK_MASKS: [u16; 8] = [
    0,
    LOCK_BIT,
    NUM_BIT,
    SCROLL_BIT,
    LOCK_BIT | NUM_BIT,
    LOCK_BIT | SCROLL_BIT,
    NUM_BIT | SCROLL_BIT,
    LOCK_BIT | NUM_BIT | SCROLL_BIT,
];

/// 把平台无关的 `KeyCode` 映射成 X11 keysym。
pub fn keysym_for(key: KeyCode) -> Option<u32> {
    match key {
        KeyCode::Char(c) if c.is_ascii_alphanumeric() => Some(c.to_ascii_lowercase() as u32),
        KeyCode::Char(_) => None,
        KeyCode::F(n) if (1..=24).contains(&n) => Some(keysym::F1 + (n as u32 - 1)),
        KeyCode::F(_) => None,
        KeyCode::Space => Some(keysym::SPACE),
        KeyCode::Enter => Some(keysym::RETURN),
        KeyCode::PrintScreen => Some(keysym::PRINT),
    }
}

/// 把组合里的修饰键转成 X11 掩码。
pub fn modmask_for(combo: &KeyCombo) -> u16 {
    let mut mask = 0u16;
    if combo.shift {
        mask |= ModMask::SHIFT.bits();
    }
    if combo.ctrl {
        mask |= ModMask::CONTROL.bits();
    }
    if combo.alt {
        mask |= ModMask::M1.bits(); // 惯例：Alt 落在 Mod1
    }
    if combo.meta {
        mask |= ModMask::M4.bits(); // 惯例：Super 落在 Mod4
    }
    mask
}

/// keysym → keycode 的反查。
///
/// X11 只给 keycode（物理位置），要在键盘映射里找哪个 keycode 能产生目标 keysym。
/// 同一个 keysym 可能挂在多个 keycode 上（主键盘与小键盘），取第一个即可。
pub fn keycode_for(conn: &RustConnection, keysym: u32) -> Result<u8, String> {
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
    Err(format!("当前键盘布局里找不到这个键（keysym 0x{keysym:x}）"))
}

/// 注册一个全局快捷键。
///
/// 已被别的程序独占时 X11 会回 `BadAccess`；这里把它翻译成人话，
/// 而不是抛一串协议错误码。
pub fn grab(conn: &RustConnection, root: u32, combo: &KeyCombo) -> Result<(), String> {
    let keysym = keysym_for(combo.key)
        .ok_or_else(|| format!("这个键在 X11 上没有对应的 keysym：{}", combo.key))?;
    let keycode = keycode_for(conn, keysym)?;
    let base = modmask_for(combo);

    for lock in LOCK_MASKS {
        let modifiers = ModMask::from(base | lock);
        // `check()` 会做一次往返并把 BadAccess 取回来 —— 不检查的话
        // 「快捷键被别的程序占了」会静默失败，用户只看到按键没反应
        conn.grab_key(
            true, // owner_events：事件仍投递给焦点窗口，避免打断输入法之类
            root,
            modifiers,
            keycode,
            GrabMode::ASYNC,
            GrabMode::ASYNC,
        )
        .map_err(|e| format!("注册快捷键失败：{e}"))?
        .check()
        .map_err(|e| {
            format!("快捷键 {combo} 注册失败，可能已被其他程序占用：{e}")
        })?;
    }
    conn.flush().map_err(|e| e.to_string())?;
    Ok(())
}

/// 撤销注册。
pub fn ungrab(conn: &RustConnection, root: u32, combo: &KeyCombo) {
    let Some(keysym) = keysym_for(combo.key) else {
        return;
    };
    let Ok(keycode) = keycode_for(conn, keysym) else {
        return;
    };
    let base = modmask_for(combo);
    for lock in LOCK_MASKS {
        let _ = conn.ungrab_key(keycode, root, ModMask::from(base | lock));
    }
    let _ = conn.flush();
}

/// 阻塞等待下一次快捷键按下。返回 `false` 表示连接断了，调用方应退出。
pub fn wait_for_trigger(conn: &RustConnection) -> bool {
    loop {
        match conn.wait_for_event() {
            Ok(Event::KeyPress(_)) => return true,
            Ok(_) => continue,
            Err(_) => return false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn letters_and_digits_map_to_their_ascii_keysyms() {
        assert_eq!(keysym_for(KeyCode::Char('s')), Some(0x73));
        assert_eq!(keysym_for(KeyCode::Char('S')), Some(0x73), "大小写应归一");
        assert_eq!(keysym_for(KeyCode::Char('4')), Some(0x34));
    }

    #[test]
    fn function_keys_are_contiguous_from_f1() {
        assert_eq!(keysym_for(KeyCode::F(1)), Some(0xffbe));
        assert_eq!(keysym_for(KeyCode::F(12)), Some(0xffc9));
        assert_eq!(keysym_for(KeyCode::F(24)), Some(0xffd5));
        assert_eq!(keysym_for(KeyCode::F(0)), None);
        assert_eq!(keysym_for(KeyCode::F(99)), None);
    }

    #[test]
    fn named_keys_map_to_the_right_keysyms() {
        assert_eq!(keysym_for(KeyCode::Space), Some(0x20));
        assert_eq!(keysym_for(KeyCode::Enter), Some(0xff0d));
        assert_eq!(keysym_for(KeyCode::PrintScreen), Some(0xff61));
    }

    #[test]
    fn non_ascii_keys_are_refused_rather_than_guessed() {
        assert_eq!(keysym_for(KeyCode::Char('中')), None);
    }

    #[test]
    fn modifiers_land_on_the_conventional_masks() {
        let combo = KeyCombo::parse("Ctrl+Shift+S").unwrap();
        let mask = modmask_for(&combo);
        assert_eq!(mask & ModMask::CONTROL.bits(), ModMask::CONTROL.bits());
        assert_eq!(mask & ModMask::SHIFT.bits(), ModMask::SHIFT.bits());
        assert_eq!(mask & ModMask::M1.bits(), 0);

        let alt = KeyCombo::parse("Alt+S").unwrap();
        assert_eq!(modmask_for(&alt), ModMask::M1.bits());
        let meta = KeyCombo::parse("Super+S").unwrap();
        assert_eq!(modmask_for(&meta), ModMask::M4.bits());
    }

    #[test]
    fn lock_bit_literals_match_x11rb() {
        // 常量里用不了 ModMask::bits()，所以写了字面量 —— 这条测试保证它们没写错
        assert_eq!(LOCK_BIT, ModMask::LOCK.bits());
        assert_eq!(NUM_BIT, ModMask::M2.bits());
        assert_eq!(SCROLL_BIT, ModMask::M5.bits());
    }

    #[test]
    fn every_lock_combination_is_covered() {
        // 少一个组合就意味着「开着 NumLock 时快捷键失灵」
        let mut seen = LOCK_MASKS.to_vec();
        seen.sort_unstable();
        seen.dedup();
        assert_eq!(seen.len(), 8, "8 种组合不应重复或缺失");
        assert!(seen.contains(&0), "必须覆盖「什么都没锁」");
        assert!(
            seen.contains(&(LOCK_BIT | NUM_BIT | SCROLL_BIT)),
            "必须覆盖「三个都锁」"
        );
    }
}
