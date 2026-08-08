//! Windows 托盘图标 + 动态菜单。
//!
//! 取代原来那个只有两项写死菜单的 `daemon.rs`：菜单**按注册表生成**，
//! 与 Linux 侧共用同一份 `baobox_app::MenuModel`，所以两边的菜单
//! 内容与顺序一致，只是这边建的是原生 `HMENU`。
//!
//! # 三个必须知道的坑
//!
//! 1. **`TrackPopupMenu` 前必须 `SetForegroundWindow`**：否则菜单在鼠标点向
//!    别处时不会消失，会一直挂在屏幕上 —— Win32 上最经典的托盘菜单 bug。
//! 2. **消息专用窗口**（`HWND_MESSAGE` 作父窗口）：常驻进程不需要可见窗口，
//!    但 `RegisterHotKey` 与托盘回调都要有个 HWND 收消息。
//! 3. **菜单项 id 每次重建都要重编**：菜单是运行期生成的，
//!    所以要留一张 id → 动作字符串的表，`WM_COMMAND` 回来时反查。

#![cfg(windows)]

use baobox_app::MenuItem;
use baobox_app::MenuModel;
use std::collections::HashMap;
use windows::core::w;
use windows::Win32::Foundation::{HINSTANCE, HWND, POINT};
use windows::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreatePopupMenu, DestroyMenu, GetCursorPos, LoadIconW, SetForegroundWindow,
    TrackPopupMenu, HMENU, IDI_APPLICATION, MF_DISABLED, MF_GRAYED, MF_POPUP, MF_SEPARATOR,
    MF_STRING, TPM_BOTTOMALIGN, TPM_RETURNCMD, TPM_RIGHTALIGN, TPM_RIGHTBUTTON,
};

/// 托盘图标回调消息（自定义，必须落在 `WM_APP` 之后）。
pub const WM_TRAY: u32 = windows::Win32::UI::WindowsAndMessaging::WM_APP + 1;

/// 菜单项 id 从这里开始编。
const FIRST_ITEM: u32 = 1000;

/// 托盘图标。析构时从通知区移除。
pub struct Tray {
    data: NOTIFYICONDATAW,
    /// 菜单项 id → 动作字符串
    actions: HashMap<u32, String>,
}

impl Tray {
    /// 把图标放上通知区。
    pub fn start(hwnd: HWND, tip: &str) -> Result<Self, String> {
        unsafe {
            let mut data = NOTIFYICONDATAW {
                cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
                hWnd: hwnd,
                uID: 1,
                uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP,
                uCallbackMessage: WM_TRAY,
                hIcon: LoadIconW(None, IDI_APPLICATION).unwrap_or_default(),
                ..Default::default()
            };
            write_tip(&mut data.szTip, tip);
            if Shell_NotifyIconW(NIM_ADD, &data).as_bool() {
                Ok(Self {
                    data,
                    actions: HashMap::new(),
                })
            } else {
                Err("无法添加托盘图标".to_string())
            }
        }
    }

    /// 弹出菜单，返回用户选了哪个动作。
    ///
    /// 用 `TPM_RETURNCMD` 直接拿返回值而不是等 `WM_COMMAND` —— 菜单是模态的，
    /// 直接返回少一次消息往返，也不必担心 `WM_COMMAND` 和别的控件混在一起。
    pub fn popup(&mut self, hwnd: HWND, model: &MenuModel) -> Option<String> {
        unsafe {
            self.actions.clear();
            let mut next = FIRST_ITEM;
            let menu = CreatePopupMenu().ok()?;
            self.append(menu, &model.items, &mut next);

            let mut point = POINT::default();
            let _ = GetCursorPos(&mut point);
            // 不调这一句的话，菜单在用户点向别处时不会消失
            let _ = SetForegroundWindow(hwnd);

            let chosen = TrackPopupMenu(
                menu,
                TPM_RIGHTALIGN | TPM_BOTTOMALIGN | TPM_RETURNCMD | TPM_RIGHTBUTTON,
                point.x,
                point.y,
                0, // 保留参数，必须为 0
                hwnd,
                None,
            );
            let _ = DestroyMenu(menu);

            let id = chosen.0 as u32;
            self.actions.get(&id).cloned()
        }
    }

    /// 递归把菜单模型建成 `HMENU`。
    unsafe fn append(&mut self, menu: HMENU, items: &[MenuItem], next: &mut u32) {
        for item in items {
            match item {
                MenuItem::Separator => {
                    let _ = AppendMenuW(menu, MF_SEPARATOR, 0, None);
                }
                MenuItem::Action {
                    id,
                    label,
                    enabled,
                    hint,
                } => {
                    // Win32 菜单用制表符把快捷键推到右侧对齐 —— 这是系统的惯例写法
                    let text = match hint {
                        Some(hint) => format!("{label}\t{hint}"),
                        None => label.clone(),
                    };
                    let wide = wide(&text);
                    if *enabled && !id.is_empty() {
                        let item_id = *next;
                        *next += 1;
                        let _ = AppendMenuW(
                            menu,
                            MF_STRING,
                            item_id as usize,
                            windows::core::PCWSTR(wide.as_ptr()),
                        );
                        self.actions.insert(item_id, id.clone());
                    } else {
                        // 置灰项仍然占位置：功能消失会让用户以为程序坏了
                        let _ = AppendMenuW(
                            menu,
                            MF_STRING | MF_GRAYED | MF_DISABLED,
                            0,
                            windows::core::PCWSTR(wide.as_ptr()),
                        );
                    }
                }
                MenuItem::Submenu { label, items } => {
                    let Ok(child) = CreatePopupMenu() else { continue };
                    self.append(child, items, next);
                    let wide = wide(label);
                    let _ = AppendMenuW(
                        menu,
                        MF_POPUP,
                        child.0 as usize,
                        windows::core::PCWSTR(wide.as_ptr()),
                    );
                }
            }
        }
    }
}

impl Drop for Tray {
    fn drop(&mut self) {
        unsafe {
            let _ = Shell_NotifyIconW(NIM_DELETE, &self.data);
        }
    }
}

/// 建一个只收消息的隐形窗口。
///
/// 常驻进程不需要可见窗口，但托盘回调与全局快捷键都要有个 HWND 收消息。
pub fn message_window(
    instance: HINSTANCE,
    wndproc: unsafe extern "system" fn(
        HWND,
        u32,
        windows::Win32::Foundation::WPARAM,
        windows::Win32::Foundation::LPARAM,
    ) -> windows::Win32::Foundation::LRESULT,
) -> Result<HWND, String> {
    unsafe {
        let class = windows::Win32::UI::WindowsAndMessaging::WNDCLASSW {
            lpfnWndProc: Some(wndproc),
            hInstance: instance,
            lpszClassName: w!("BaoboxApp"),
            ..Default::default()
        };
        windows::Win32::UI::WindowsAndMessaging::RegisterClassW(&class);
        windows::Win32::UI::WindowsAndMessaging::CreateWindowExW(
            Default::default(),
            w!("BaoboxApp"),
            w!("Baobox"),
            Default::default(),
            0,
            0,
            0,
            0,
            windows::Win32::UI::WindowsAndMessaging::HWND_MESSAGE,
            None,
            instance,
            None,
        )
        .map_err(|e| format!("创建消息窗口失败：{e}"))
    }
}

/// 把托盘图标从「隐藏的图标」溢出区提升到任务栏常显（Windows 11）。
///
/// Windows 没有公开 API 做这件事；Win11 把每个图标的偏好存在
/// `HKCU\Control Panel\NotifyIconSettings\<id>` 下，`IsPromoted=1` 即常显。
/// 那个子键由 explorer 在图标首次出现之后才建，所以第一次启动时
/// 调用方要在几秒内重试（挂在 App 的 tick 定时器上）。
///
/// 返回 `true` 表示**不必再试**：写成功了、或系统根本没有这套机制（Win10，
/// 那上面只能由用户手动把图标拖出来）。返回 `false` = 子键还没出现，稍后再试。
pub fn promote_in_taskbar() -> bool {
    use windows::core::PWSTR;
    use windows::Win32::System::Registry::{
        RegCloseKey, RegEnumKeyExW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW, HKEY,
        HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_READ, KEY_SET_VALUE, REG_DWORD, REG_VALUE_TYPE,
    };

    let Ok(exe) = std::env::current_exe() else {
        return true;
    };
    let exe = exe.to_string_lossy().to_lowercase();

    unsafe {
        let mut root = HKEY::default();
        if RegOpenKeyExW(
            HKEY_CURRENT_USER,
            w!("Control Panel\\NotifyIconSettings"),
            0,
            KEY_READ,
            &mut root,
        )
        .is_err()
        {
            // Win10 没有这个键，也就没有可编程的常显开关
            return true;
        }

        let mut found = false;
        let mut index = 0u32;
        loop {
            let mut name = [0u16; 64];
            let mut length = name.len() as u32;
            if RegEnumKeyExW(
                root,
                index,
                PWSTR(name.as_mut_ptr()),
                &mut length,
                None,
                PWSTR::null(),
                None,
                None,
            )
            .is_err()
            {
                break;
            }
            index += 1;

            let mut sub = HKEY::default();
            if RegOpenKeyExW(
                root,
                windows::core::PCWSTR(name.as_ptr()),
                0,
                KEY_QUERY_VALUE | KEY_SET_VALUE,
                &mut sub,
            )
            .is_err()
            {
                continue;
            }

            // 这个子键属不属于我们：按 ExecutablePath 匹配本程序
            let mut kind = REG_VALUE_TYPE::default();
            let mut buffer = [0u8; 1040];
            let mut size = buffer.len() as u32;
            let matched = RegQueryValueExW(
                sub,
                w!("ExecutablePath"),
                None,
                Some(&mut kind),
                Some(buffer.as_mut_ptr()),
                Some(&mut size),
            )
            .is_ok()
                && {
                    let chars: Vec<u16> = buffer[..size as usize]
                        .chunks_exact(2)
                        .map(|two| u16::from_le_bytes([two[0], two[1]]))
                        .take_while(|c| *c != 0)
                        .collect();
                    String::from_utf16_lossy(&chars).to_lowercase() == exe
                };

            if matched {
                found = true;
                let one = 1u32.to_le_bytes();
                let _ = RegSetValueExW(sub, w!("IsPromoted"), 0, REG_DWORD, Some(&one));
            }
            let _ = RegCloseKey(sub);
            if found {
                break;
            }
        }
        let _ = RegCloseKey(root);
        found
    }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

/// 悬停提示。缓冲区是定长的，超长要截断并留出结尾的 NUL。
fn write_tip(buffer: &mut [u16; 128], text: &str) {
    let encoded: Vec<u16> = text.encode_utf16().take(buffer.len() - 1).collect();
    buffer[..encoded.len()].copy_from_slice(&encoded);
    buffer[encoded.len()] = 0;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tip_is_truncated_and_null_terminated() {
        let mut buffer = [0u16; 128];
        write_tip(&mut buffer, &"很长".repeat(200));
        assert_eq!(buffer[127], 0, "必须留出结尾的 NUL");
        assert_ne!(buffer[0], 0);
    }

    #[test]
    fn wide_strings_are_null_terminated() {
        assert_eq!(wide("ab"), vec![b'a' as u16, b'b' as u16, 0]);
        assert_eq!(wide(""), vec![0]);
    }

    #[test]
    fn menu_item_ids_start_clear_of_the_system_range() {
        // 0 是「没选」，小 id 又和 IDOK 之类撞，所以从一个大数开始编
        assert!(FIRST_ITEM > 100);
    }

    #[test]
    fn the_tray_callback_message_sits_above_wm_app() {
        // 落在 WM_APP 之下会与系统消息撞号
        assert!(WM_TRAY > windows::Win32::UI::WindowsAndMessaging::WM_APP);
    }
}
