//! Windows 常驻：全局快捷键 + 托盘图标。
//!
//! 与 Linux 的 `daemon.rs` 对应。没有它，截图工具就只能从命令行调起。
//!
//! # 三个必须知道的坑
//!
//! 1. **`MOD_NOREPEAT`**：不加的话按住快捷键会连续触发，覆盖层被反复唤起。
//! 2. **`TrackPopupMenu` 前必须 `SetForegroundWindow`**：否则菜单在鼠标点向别处时
//!    不会消失，会一直挂在屏幕上 —— 这是 Win32 上最经典的托盘菜单 bug。
//! 3. **消息专用窗口**（`HWND_MESSAGE` 作父窗口）：常驻进程不需要可见窗口，
//!    但 `RegisterHotKey` 与托盘回调都要有个 HWND 收消息。

#![cfg(windows)]

use baobox_core::hotkey::{KeyCode, KeyCombo};
use windows::core::w;
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    RegisterHotKey, UnregisterHotKey, HOT_KEY_MODIFIERS, MOD_ALT, MOD_CONTROL, MOD_NOREPEAT,
    MOD_SHIFT, MOD_WIN,
};
use windows::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DestroyWindow,
    DispatchMessageW, GetCursorPos, GetMessageW, LoadIconW, PostQuitMessage, RegisterClassW,
    SetForegroundWindow, TrackPopupMenu, TranslateMessage, HWND_MESSAGE, IDI_APPLICATION, MF_STRING,
    MSG, TPM_BOTTOMALIGN, TPM_RIGHTALIGN, WINDOW_EX_STYLE, WINDOW_STYLE, WM_APP, WM_COMMAND,
    WM_DESTROY, WM_HOTKEY, WM_RBUTTONUP, WNDCLASSW,
};

/// 托盘图标回调消息（自定义，必须落在 `WM_APP` 之后）。
const WM_TRAY: u32 = WM_APP + 1;

/// 快捷键 id —— 本进程只注册一个。
const HOTKEY_ID: i32 = 1;

/// 托盘菜单项 id。
const MENU_CAPTURE: usize = 100;
const MENU_QUIT: usize = 101;

/// 常驻进程要做的动作。
pub enum Action {
    /// 用户按了快捷键，或从托盘菜单点了「截图」
    Capture,
    /// 用户要退出
    Quit,
}

/// 把平台无关的 `KeyCode` 映射成 Windows 虚拟键码。
pub fn virtual_key_for(key: KeyCode) -> Option<u32> {
    match key {
        // VK 里字母用大写 ASCII，数字用 '0'–'9'
        KeyCode::Char(c) if c.is_ascii_alphanumeric() => Some(c.to_ascii_uppercase() as u32),
        KeyCode::Char(_) => None,
        KeyCode::F(n) if (1..=24).contains(&n) => Some(0x70 + (n as u32 - 1)), // VK_F1 = 0x70
        KeyCode::F(_) => None,
        KeyCode::Space => Some(0x20),      // VK_SPACE
        KeyCode::Enter => Some(0x0D),      // VK_RETURN
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

/// 常驻会话：持有消息窗口、快捷键与托盘图标，析构时全部还回去。
pub struct Daemon {
    hwnd: HWND,
    tray: NOTIFYICONDATAW,
}

impl Daemon {
    /// 注册快捷键并放上托盘图标。
    pub fn start(combo: &KeyCombo) -> Result<Self, String> {
        let virtual_key = virtual_key_for(combo.key)
            .ok_or_else(|| format!("这个键在 Windows 上没有对应的虚拟键码：{}", combo.key))?;

        unsafe {
            let instance: HINSTANCE = GetModuleHandleW(None)
                .map_err(|e| format!("GetModuleHandle 失败：{e}"))?
                .into();

            let class = WNDCLASSW {
                lpfnWndProc: Some(wndproc),
                hInstance: instance,
                lpszClassName: w!("BaoboxDaemon"),
                ..Default::default()
            };
            RegisterClassW(&class);

            // 消息专用窗口：不可见、不进任务栏，只用来收消息
            let hwnd = CreateWindowExW(
                WINDOW_EX_STYLE(0),
                w!("BaoboxDaemon"),
                w!("Baobox"),
                WINDOW_STYLE(0),
                0,
                0,
                0,
                0,
                HWND_MESSAGE,
                None,
                instance,
                None,
            )
            .map_err(|e| format!("创建消息窗口失败：{e}"))?;

            RegisterHotKey(hwnd, HOTKEY_ID, modifiers_for(combo), virtual_key).map_err(
                |e| {
                    format!("快捷键 {combo} 注册失败，可能已被其他程序占用：{e}")
                },
            )?;

            let mut tray = NOTIFYICONDATAW {
                cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
                hWnd: hwnd,
                uID: 1,
                uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP,
                uCallbackMessage: WM_TRAY,
                hIcon: LoadIconW(None, IDI_APPLICATION).unwrap_or_default(),
                ..Default::default()
            };
            write_tip(&mut tray.szTip, &format!("Baobox —— 按 {combo} 截图"));
            if Shell_NotifyIconW(NIM_ADD, &tray).as_bool() {
                Ok(Self { hwnd, tray })
            } else {
                let _ = UnregisterHotKey(hwnd, HOTKEY_ID);
                let _ = DestroyWindow(hwnd);
                Err("无法添加托盘图标".to_string())
            }
        }
    }

    /// 阻塞等待下一个动作。返回 `None` 表示消息循环结束。
    pub fn next_action(&self) -> Option<Action> {
        unsafe {
            let mut message = MSG::default();
            while GetMessageW(&mut message, None, 0, 0).as_bool() {
                match message.message {
                    WM_HOTKEY => return Some(Action::Capture),
                    WM_TRAY if message.lParam.0 as u32 == WM_RBUTTONUP => {
                        match show_menu(self.hwnd) {
                            Some(MENU_CAPTURE) => return Some(Action::Capture),
                            Some(MENU_QUIT) => return Some(Action::Quit),
                            _ => {}
                        }
                    }
                    _ => {
                        let _ = TranslateMessage(&message);
                        DispatchMessageW(&message);
                    }
                }
            }
            None
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        unsafe {
            let _ = Shell_NotifyIconW(NIM_DELETE, &self.tray);
            let _ = UnregisterHotKey(self.hwnd, HOTKEY_ID);
            let _ = DestroyWindow(self.hwnd);
        }
    }
}

/// 弹出托盘菜单，返回用户点了哪一项。
///
/// `SetForegroundWindow` 是必须的：不调用的话菜单在点向别处时不会消失，
/// 会一直挂在屏幕上（Win32 上最经典的托盘菜单 bug）。
unsafe fn show_menu(hwnd: HWND) -> Option<usize> {
    let menu = CreatePopupMenu().ok()?;
    let _ = AppendMenuW(menu, MF_STRING, MENU_CAPTURE, w!("截图"));
    let _ = AppendMenuW(menu, MF_STRING, MENU_QUIT, w!("退出 Baobox"));

    let mut point = POINT::default();
    let _ = GetCursorPos(&mut point);
    let _ = SetForegroundWindow(hwnd);

    // 不用 TPM_RETURNCMD，改由 WM_COMMAND 回来 —— 与消息循环的其余部分保持一致
    let _ = TrackPopupMenu(
        menu,
        TPM_RIGHTALIGN | TPM_BOTTOMALIGN,
        point.x,
        point.y,
        0, // 保留参数，必须为 0
        hwnd,
        None,
    );
    let _ = DestroyMenu(menu);

    // TrackPopupMenu 是阻塞的，命令已经作为 WM_COMMAND 投进队列，这里取出来
    let mut message = MSG::default();
    if GetMessageW(&mut message, None, 0, 0).as_bool() && message.message == WM_COMMAND {
        return Some((message.wParam.0 & 0xFFFF) as usize);
    }
    None
}

fn write_tip(buffer: &mut [u16; 128], text: &str) {
    let encoded: Vec<u16> = text.encode_utf16().take(buffer.len() - 1).collect();
    buffer[..encoded.len()].copy_from_slice(&encoded);
    buffer[encoded.len()] = 0;
}

unsafe extern "system" fn wndproc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match message {
        WM_DESTROY => {
            PostQuitMessage(0);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

/// 供 CLI 打印用。
pub fn describe(combo: &KeyCombo) -> String {
    format!("Baobox 已常驻：按 {combo} 截图，或右键托盘图标。")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn letters_map_to_uppercase_virtual_keys() {
        // VK 里字母用的是大写 ASCII
        assert_eq!(virtual_key_for(KeyCode::Char('s')), Some(0x53));
        assert_eq!(virtual_key_for(KeyCode::Char('S')), Some(0x53));
        assert_eq!(virtual_key_for(KeyCode::Char('4')), Some(0x34));
    }

    #[test]
    fn function_keys_start_at_vk_f1() {
        assert_eq!(virtual_key_for(KeyCode::F(1)), Some(0x70));
        assert_eq!(virtual_key_for(KeyCode::F(12)), Some(0x7B));
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
    }

    #[test]
    fn tip_is_truncated_and_null_terminated() {
        let mut buffer = [0u16; 128];
        write_tip(&mut buffer, &"很长".repeat(200));
        assert_eq!(buffer[127], 0, "必须留出结尾的 NUL");
        assert_ne!(buffer[0], 0);
    }
}
