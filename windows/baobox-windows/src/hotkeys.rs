//! 全局快捷键中心（Win32）。
//!
//! 与 Linux 的 `hotkeys.rs` 对应：按注册表里每个工具声明的 [`HotkeySpec`]
//! 一次注册多个，按下时按 **热键 id** 反查是哪个动作。对应 macOS 侧的 `HotkeyCenter`。
//!
//! # 三个必须知道的点
//!
//! 1. **`MOD_NOREPEAT`**：不加的话按住快捷键会连续触发。
//! 2. **id 是进程内唯一的整数**，`WM_HOTKEY` 的 `wParam` 就是它 —— 所以要留一张
//!    id → 动作字符串的表。
//! 3. **注册失败必须报出来**：`RegisterHotKey` 在组合被别的程序占用时返回失败，
//!    忽略掉的话用户只会看到「按了没反应」，这是最难查的一类故障。

#![cfg(windows)]

use baobox_app::HotkeySpec;
use baobox_core::hotkey::{KeyCode, KeyCombo};
use std::collections::HashMap;
use windows::Win32::Foundation::HWND;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    RegisterHotKey, UnregisterHotKey, HOT_KEY_MODIFIERS, MOD_ALT, MOD_CONTROL, MOD_NOREPEAT,
    MOD_SHIFT, MOD_WIN,
};

/// 热键 id 从这里开始编。0 是合法值，但从 1 开始更容易在调试时看出「没设」。
const FIRST_ID: i32 = 1;

/// 一次注册的结果。与 Linux 版同一形状。
pub struct Registration {
    /// 成功注册了几个
    pub bound: usize,
    /// 没能注册的，`(动作 id, 原因)`
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

/// 快捷键中心：持有全部注册，析构时还回去。
pub struct HotkeyCenter {
    hwnd: HWND,
    /// 热键 id → 动作字符串
    actions: HashMap<i32, String>,
    next_id: i32,
}

impl HotkeyCenter {
    /// 空的中心。消息会投递到 `hwnd`。
    pub fn new(hwnd: HWND) -> Self {
        Self {
            hwnd,
            actions: HashMap::new(),
            next_id: FIRST_ID,
        }
    }

    /// 按规格批量注册。
    pub fn register_all(&mut self, specs: &[(HotkeySpec, Option<KeyCombo>)]) -> Registration {
        let mut result = Registration {
            bound: 0,
            conflicts: Vec::new(),
        };
        for (spec, combo) in specs {
            // 没绑定（出厂不绑，或用户解绑）就跳过，不是错误
            let Some(combo) = combo else { continue };
            match self.register(&spec.id, combo) {
                Ok(()) => result.bound += 1,
                Err(why) => result.conflicts.push((spec.id.clone(), why)),
            }
        }
        result
    }

    /// 注册一个组合。
    pub fn register(&mut self, action: &str, combo: &KeyCombo) -> Result<(), String> {
        let key = virtual_key_for(combo.key)
            .ok_or_else(|| format!("这个键在 Windows 上没有对应的虚拟键码：{}", combo.key))?;
        let id = self.next_id;
        unsafe {
            RegisterHotKey(self.hwnd, id, modifiers_for(combo), key)
                .map_err(|e| format!("{e}"))?;
        }
        self.actions.insert(id, action.to_string());
        self.next_id += 1;
        Ok(())
    }

    /// 全部撤销。用户在设置里改了快捷键时先撤再重注册。
    pub fn unregister_all(&mut self) {
        for id in self.actions.keys() {
            unsafe {
                let _ = UnregisterHotKey(self.hwnd, *id);
            }
        }
        self.actions.clear();
        // id 不复用：撤销与系统里真正解除之间有个窗口期，
        // 复用 id 可能撞上还没解除干净的那个
        self.next_id = self.next_id.max(FIRST_ID);
    }

    /// `WM_HOTKEY` 的 `wParam` 对应哪个动作。
    pub fn action_for(&self, id: i32) -> Option<&str> {
        self.actions.get(&id).map(String::as_str)
    }
}

impl Drop for HotkeyCenter {
    fn drop(&mut self) {
        self.unregister_all();
    }
}

/// 把平台无关的 `KeyCode` 映射成 Windows 虚拟键码。
pub fn virtual_key_for(key: KeyCode) -> Option<u32> {
    match key {
        // VK 里字母用大写 ASCII，数字用 '0'–'9'
        KeyCode::Char(c) if c.is_ascii_alphanumeric() => Some(c.to_ascii_uppercase() as u32),
        KeyCode::Char(_) => None,
        KeyCode::F(n) if (1..=24).contains(&n) => Some(0x70 + (n as u32 - 1)), // VK_F1 = 0x70
        KeyCode::F(_) => None,
        KeyCode::Space => Some(0x20),       // VK_SPACE
        KeyCode::Enter => Some(0x0D),       // VK_RETURN
        KeyCode::PrintScreen => Some(0x2C), // VK_SNAPSHOT
    }
}

/// 把组合里的修饰键转成 `RegisterHotKey` 的标志。
///
/// 一律带上 `MOD_NOREPEAT`：不加的话按住不放会连续触发。
pub fn modifiers_for(combo: &KeyCombo) -> HOT_KEY_MODIFIERS {
    let mut flags = MOD_NOREPEAT;
    if combo.ctrl {
        flags |= MOD_CONTROL;
    }
    if combo.shift {
        flags |= MOD_SHIFT;
    }
    if combo.alt {
        flags |= MOD_ALT;
    }
    if combo.meta {
        flags |= MOD_WIN;
    }
    flags
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn letters_map_to_uppercase_virtual_keys() {
        assert_eq!(virtual_key_for(KeyCode::Char('s')), Some(0x53));
        assert_eq!(virtual_key_for(KeyCode::Char('S')), Some(0x53));
        assert_eq!(virtual_key_for(KeyCode::Char('4')), Some(0x34));
    }

    #[test]
    fn function_keys_start_at_vk_f1() {
        assert_eq!(virtual_key_for(KeyCode::F(1)), Some(0x70));
        assert_eq!(virtual_key_for(KeyCode::F(24)), Some(0x87));
        assert_eq!(virtual_key_for(KeyCode::F(25)), None);
    }

    #[test]
    fn print_screen_maps_to_vk_snapshot() {
        assert_eq!(virtual_key_for(KeyCode::PrintScreen), Some(0x2C));
    }

    #[test]
    fn non_ascii_is_refused_rather_than_guessed() {
        assert_eq!(virtual_key_for(KeyCode::Char('中')), None);
    }

    #[test]
    fn modifiers_always_include_norepeat() {
        let combo = KeyCombo::parse("Ctrl+Shift+S").unwrap();
        let flags = modifiers_for(&combo);
        // 不带 NOREPEAT 的话按住快捷键会反复唤起覆盖层
        assert_ne!(flags.0 & MOD_NOREPEAT.0, 0);
        assert_ne!(flags.0 & MOD_CONTROL.0, 0);
        assert_ne!(flags.0 & MOD_SHIFT.0, 0);
        assert_eq!(flags.0 & MOD_ALT.0, 0);
        assert_eq!(flags.0 & MOD_WIN.0, 0);
    }

    #[test]
    fn a_registration_report_reads_like_a_sentence() {
        let clean = Registration {
            bound: 3,
            conflicts: Vec::new(),
        };
        assert!(!clean.has_problems());
        assert!(clean.describe().contains('3'));

        let clashed = Registration {
            bound: 1,
            conflicts: vec![("screenshot.capture".into(), "占用".into())],
        };
        assert!(clashed.has_problems());
        let text = clashed.describe();
        assert!(text.contains("screenshot.capture"));
        assert!(text.contains("设置"), "要告诉用户去哪儿改");
    }
}
