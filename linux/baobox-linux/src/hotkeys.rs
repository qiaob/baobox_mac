//! 全局快捷键中心（X11）。
//!
//! 取代原来只认一个快捷键的 `daemon`：现在按注册表里每个工具声明的
//! [`HotkeySpec`] 一次注册多个，按下时按 **keycode + 修饰键掩码** 反查是哪一个，
//! 把动作 id 发出去。对应 macOS 侧的 `HotkeyCenter`。
//!
//! # X11 的锁定修饰键陷阱
//!
//! `GrabKey` 匹配的是**精确的**修饰键掩码。用户开着 NumLock 时事件里会多一个
//! `Mod2`，grab 就不匹配了 —— 表现为「快捷键有时灵有时不灵」，而用户根本
//! 想不到是 NumLock 的锅。所以每个组合都要把 CapsLock / NumLock / ScrollLock
//! 的**全部 8 种组合**各 grab 一遍，反查时也要先把这些位抹掉。
//!
//! # 冲突怎么办
//!
//! 两个工具绑了同一个组合时，**后注册的注册不上**（X11 会回 `BadAccess`）。
//! 这里把冲突收集起来交给调用方提示用户，而不是静默失效 ——
//! 静默失效是这类功能最难查的故障。

use baobox_app::HotkeySpec;
use baobox_core::hotkey::{KeyCode, KeyCombo};
use std::collections::HashMap;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{ConnectionExt as _, GrabMode, ModMask};
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

/// 锁定类修饰键的原始位值。`ModMask::bits()` 不是 const，无法写进常量数组，
/// 所以这里用字面量 —— 下面有测试锁死它们与 `ModMask` 一致。
const LOCK_BIT: u16 = 2; // CapsLock
const NUM_BIT: u16 = 16; // NumLock（Mod2）
const SCROLL_BIT: u16 = 128; // ScrollLock（Mod5）

/// 所有会干扰精确匹配的锁定修饰键组合。
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

/// 反查用的键：抹掉锁定位之后的 (keycode, 修饰键掩码)。
type Binding = (u8, u16);

/// 一次注册的结果。
pub struct Registration {
    /// 成功注册了几个
    pub bound: usize,
    /// 没能注册的，`(动作 id, 原因)`。多半是被别的程序占了
    pub conflicts: Vec<(String, String)>,
}

impl Registration {
    /// 有没有需要提示用户的问题。
    pub fn has_problems(&self) -> bool {
        !self.conflicts.is_empty()
    }

    /// 一句给用户看的话。
    pub fn describe(&self) -> String {
        if self.conflicts.is_empty() {
            return format!("已注册 {} 个全局快捷键。", self.bound);
        }
        let details: Vec<String> = self
            .conflicts
            .iter()
            .map(|(id, why)| format!("  {id}：{why}"))
            .collect();
        format!(
            "已注册 {} 个全局快捷键，{} 个没能注册（多半被别的程序占了，可在设置里换一个）：\n{}",
            self.bound,
            self.conflicts.len(),
            details.join("\n")
        )
    }
}

/// 快捷键中心：持有全部 grab，析构时还回去。
pub struct HotkeyCenter {
    root: u32,
    /// (keycode, 掩码) → 动作 id
    bindings: HashMap<Binding, String>,
    /// 为了 ungrab 留着
    grabbed: Vec<(u8, u16)>,
}

impl HotkeyCenter {
    /// 空的中心。
    pub fn new(root: u32) -> Self {
        Self {
            root,
            bindings: HashMap::new(),
            grabbed: Vec::new(),
        }
    }

    /// 按规格批量注册。`resolve` 已经把配置里的覆盖算进去了，
    /// 所以这里拿到的组合就是用户当前实际要的。
    pub fn register_all(
        &mut self,
        conn: &RustConnection,
        specs: &[(HotkeySpec, Option<KeyCombo>)],
    ) -> Registration {
        let mut result = Registration {
            bound: 0,
            conflicts: Vec::new(),
        };
        for (spec, combo) in specs {
            // 没绑定（出厂就不绑，或用户解绑了）就跳过，不是错误
            let Some(combo) = combo else { continue };
            match self.register(conn, &spec.id, combo) {
                Ok(()) => result.bound += 1,
                Err(why) => result.conflicts.push((spec.id.clone(), why)),
            }
        }
        let _ = conn.flush();
        result
    }

    /// 注册一个组合。
    pub fn register(
        &mut self,
        conn: &RustConnection,
        action: &str,
        combo: &KeyCombo,
    ) -> Result<(), String> {
        let keysym = keysym_for(combo.key)
            .ok_or_else(|| format!("这个键在 X11 上没有对应的 keysym：{}", combo.key))?;
        let keycode = keycode_for(conn, keysym)?;
        let base = modmask_for(combo);

        if let Some(existing) = self.bindings.get(&(keycode, base)) {
            return Err(format!("与 {existing} 撞了同一个组合"));
        }

        for lock in LOCK_MASKS {
            // `check()` 会做一次往返把 BadAccess 取回来 —— 不检查的话
            // 「被别的程序占了」会静默失败，用户只看到按键没反应
            conn.grab_key(
                true, // owner_events：事件仍投递给焦点窗口，免得打断输入法
                self.root,
                ModMask::from(base | lock),
                keycode,
                GrabMode::ASYNC,
                GrabMode::ASYNC,
            )
            .map_err(|e| format!("发起注册失败：{e}"))?
            .check()
            .map_err(|e| format!("{e}"))?;
            self.grabbed.push((keycode, base | lock));
        }
        self.bindings.insert((keycode, base), action.to_string());
        Ok(())
    }

    /// 全部撤销。换快捷键（用户在设置里改了）时先撤再重注册。
    pub fn unregister_all(&mut self, conn: &RustConnection) {
        for (keycode, mask) in self.grabbed.drain(..) {
            let _ = conn.ungrab_key(keycode, self.root, ModMask::from(mask));
        }
        self.bindings.clear();
        let _ = conn.flush();
    }

    /// 还没注册过任何东西。常驻线程用它判断「第一圈要不要先注册」。
    pub fn is_empty(&self) -> bool {
        self.bindings.is_empty()
    }

    /// 一个按键事件对应哪个动作。
    pub fn action_for(&self, keycode: u8, state: u16) -> Option<&str> {
        // 抹掉锁定位再查 —— 事件里带着 NumLock 之类的位
        let cleaned = state & !(LOCK_BIT | NUM_BIT | SCROLL_BIT);
        self.bindings.get(&(keycode, cleaned)).map(String::as_str)
    }

}

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
        assert_eq!(keysym_for(KeyCode::F(24)), Some(0xffd5));
        assert_eq!(keysym_for(KeyCode::F(0)), None);
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
        assert_eq!(
            modmask_for(&KeyCombo::parse("Super+S").unwrap()),
            ModMask::M4.bits()
        );
    }

    #[test]
    fn lock_bit_literals_match_x11rb() {
        assert_eq!(LOCK_BIT, ModMask::LOCK.bits());
        assert_eq!(NUM_BIT, ModMask::M2.bits());
        assert_eq!(SCROLL_BIT, ModMask::M5.bits());
    }

    #[test]
    fn every_lock_combination_is_covered() {
        let mut seen = LOCK_MASKS.to_vec();
        seen.sort_unstable();
        seen.dedup();
        assert_eq!(seen.len(), 8, "少一个组合就意味着开着 NumLock 时失灵");
        assert!(seen.contains(&0));
        assert!(seen.contains(&(LOCK_BIT | NUM_BIT | SCROLL_BIT)));
    }

    #[test]
    fn lookup_ignores_the_lock_modifiers() {
        let mut center = HotkeyCenter::new(0);
        // 直接塞进映射表，绕开需要 X 服务器的 grab
        center
            .bindings
            .insert((25, ModMask::CONTROL.bits()), "screenshot.capture".into());

        let ctrl = ModMask::CONTROL.bits();
        assert_eq!(center.action_for(25, ctrl), Some("screenshot.capture"));
        // 开着 NumLock —— 这正是「有时灵有时不灵」的成因
        assert_eq!(
            center.action_for(25, ctrl | NUM_BIT),
            Some("screenshot.capture")
        );
        assert_eq!(
            center.action_for(25, ctrl | LOCK_BIT | SCROLL_BIT),
            Some("screenshot.capture")
        );
        // 但真正多按了一个修饰键就不该命中
        assert_eq!(center.action_for(25, ctrl | ModMask::SHIFT.bits()), None);
        assert_eq!(center.action_for(26, ctrl), None);
    }

    #[test]
    fn a_registration_report_reads_like_a_sentence() {
        let clean = Registration {
            bound: 3,
            conflicts: Vec::new(),
        };
        assert!(!clean.has_problems());
        assert!(clean.describe().contains("3"));

        let clashed = Registration {
            bound: 1,
            conflicts: vec![("screenshot.capture".into(), "BadAccess".into())],
        };
        assert!(clashed.has_problems());
        let text = clashed.describe();
        assert!(text.contains("screenshot.capture"));
        assert!(text.contains("设置"), "要告诉用户去哪儿改");
    }
}
