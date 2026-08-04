//! 键盘点击（Windows）：UI Automation 枚举可点元素，`SendInput` 点它。
//!
//! 标签怎么发、打字之后怎么反应在 `baobox_core::hints`（三平台共用），
//! 这里只回答两个问题：**屏幕上有哪些可点的东西**、**怎么点**。
//!
//! # 为什么是 UI Automation 而不是老的 MSAA
//!
//! MSAA（`IAccessible`）是上世纪的接口，现代 UWP / WinUI 程序基本不实现。
//! UI Automation 是它的替代品，覆盖面广得多，而且**同一套接口**能问出
//! 控件类型、位置、有没有「调用」这个动作。
//!
//! # 只扫前台窗口那一棵树
//!
//! 扫整个桌面要遍历每个进程的 UI 树 —— 几秒起步，而这个功能的
//! 全部意义就是「比用鼠标快」。慢一点都不如直接伸手去够鼠标。
//!
//! # COM 得先初始化，而且只能初始化一次
//!
//! `CoInitializeEx` 在同一条线程上重复调会返回 `RPC_E_CHANGED_MODE`。
//! 我们的 App 只有一条线程，所以在这里记一个标志，第二次直接跳过 ——
//! 不挡的话第二次按快捷键就会报一个用户完全看不懂的 COM 错误码。

#![cfg(windows)]

use baobox_core::hints::Target;
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED,
};
use windows::core::VARIANT;
use windows::Win32::UI::Accessibility::{
    CUIAutomation, IUIAutomation, IUIAutomationCondition, IUIAutomationElement,
    TreeScope_Descendants, UIA_ButtonControlTypeId,
    UIA_CheckBoxControlTypeId, UIA_ComboBoxControlTypeId, UIA_EditControlTypeId,
    UIA_HyperlinkControlTypeId, UIA_ListItemControlTypeId, UIA_MenuItemControlTypeId,
    UIA_RadioButtonControlTypeId, UIA_TabItemControlTypeId, UIA_TreeItemControlTypeId,
};

/// 视为「可点」的控件类型。
///
/// 与 macOS 侧那张 role 表一一对应。**不收 `Text` 与 `Group`** ——
/// 收了的话一个网页能标出上千个标签，标签本身长到四五个字符，
/// 那时用键盘比用鼠标还慢。
const CLICKABLE: [i32; 10] = [
    UIA_ButtonControlTypeId.0,
    UIA_HyperlinkControlTypeId.0,
    UIA_CheckBoxControlTypeId.0,
    UIA_RadioButtonControlTypeId.0,
    UIA_ComboBoxControlTypeId.0,
    UIA_MenuItemControlTypeId.0,
    UIA_TabItemControlTypeId.0,
    UIA_ListItemControlTypeId.0,
    UIA_TreeItemControlTypeId.0,
    UIA_EditControlTypeId.0,
];

/// 最多标多少个。
///
/// 超过这个数，标签会长到三四个字符，而用户在几百个标签里找一个的时间
/// 早就超过伸手去够鼠标了。
pub const MAX_TARGETS: usize = 200;

/// 元素小于这个尺寸就不标 —— 多半是分隔线或者看不见的占位。
pub const MIN_SIZE: f64 = 6.0;

thread_local! {
    /// COM 初始化过了没。重复调会返回 `RPC_E_CHANGED_MODE`，
    /// 而那个错误码用户完全看不懂
    static COM_READY: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// 扫一遍前台窗口里可点的东西。
pub fn scan() -> Result<Vec<Target>, String> {
    unsafe {
        ensure_com()?;
        let automation: IUIAutomation =
            CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)
                .map_err(|e| format!("UI Automation 起不来：{e}"))?;

        let hwnd = crate::windowmanager::foreground().ok_or("现在没有活动窗口")?;
        let root = automation
            .ElementFromHandle(hwnd)
            .map_err(|e| format!("读不到这个窗口的界面树：{e}"))?;

        // 把过滤**真的**交给 UIA：按控件类型 OR 出一个条件，让它在目标进程
        // 那边筛完再回来。用 `CreateTrueCondition` 的话会把整棵树取回来，
        // 再对每个元素调一次 `CurrentControlType` —— 那是每个元素一次
        // 跨进程往返，浏览器上就是上万次，点一下要等好几秒
        let condition = clickable_condition(&automation)?;
        let found = root
            .FindAll(TreeScope_Descendants, &condition)
            .map_err(|e| format!("枚举界面元素失败：{e}"))?;
        let count = found.Length().unwrap_or(0);

        let mut targets = Vec::new();
        for index in 0..count {
            if targets.len() >= MAX_TARGETS {
                break;
            }
            let Ok(element) = found.GetElement(index) else {
                continue;
            };
            if let Some(target) = target_of(&element) {
                targets.push(target);
            }
        }
        Ok(targets)
    }
}

/// 「是这些控件类型之一」的查询条件。
///
/// UIA 会拿它在**目标进程**那边筛，返回的就已经只有可点的元素了。
unsafe fn clickable_condition(
    automation: &IUIAutomation,
) -> Result<IUIAutomationCondition, String> {
    use windows::Win32::UI::Accessibility::UIA_ControlTypePropertyId;
    // 两两 OR 折起来，而不是 `CreateOrConditionFromArray` —— 后者要一个
    // `SAFEARRAY`，为几个条件手工造一个 COM 数组不值得
    let mut combined: Option<IUIAutomationCondition> = None;
    for kind in CLICKABLE {
        let one = automation
            .CreatePropertyCondition(UIA_ControlTypePropertyId, &VARIANT::from(kind))
            .map_err(|e| format!("构造查询条件失败：{e}"))?;
        combined = Some(match combined {
            None => one,
            Some(previous) => automation
                .CreateOrCondition(&previous, &one)
                .map_err(|e| format!("合并查询条件失败：{e}"))?,
        });
    }
    combined.ok_or_else(|| "可点控件类型表是空的".to_string())
}

/// 一个元素该不该标、标在哪。
unsafe fn target_of(element: &IUIAutomationElement) -> Option<Target> {
    // 控件类型已经由查询条件筛过了，这里不必再问一遍（那是一次跨进程往返）
    // 看不见的、被折叠起来的一律不标 —— 标了会点到一个用户根本没看到的东西
    if element.CurrentIsOffscreen().ok()?.as_bool() {
        return None;
    }
    if !element.CurrentIsEnabled().ok()?.as_bool() {
        return None;
    }
    let rect = element.CurrentBoundingRectangle().ok()?;
    let (w, h) = (
        (rect.right - rect.left) as f64,
        (rect.bottom - rect.top) as f64,
    );
    if w < MIN_SIZE || h < MIN_SIZE {
        return None;
    }
    let label = element
        .CurrentName()
        .map(|n| n.to_string())
        .unwrap_or_default();
    Some(Target {
        x: rect.left as f64 + w / 2.0,
        y: rect.top as f64 + h / 2.0,
        label,
    })
}

unsafe fn ensure_com() -> Result<(), String> {
    let ready = COM_READY.with(|c| c.get());
    if ready {
        return Ok(());
    }
    // 单线程套间：我们只有一条线程，而且 UIA 在这个模式下最省心
    CoInitializeEx(None, COINIT_APARTMENTTHREADED)
        .ok()
        .map_err(|e| format!("COM 初始化失败：{e}"))?;
    COM_READY.with(|c| c.set(true));
    Ok(())
}

/// 在某个点上点一下。
///
/// 用**合成鼠标事件**而不是 UIA 的 `Invoke()`：`Invoke` 走的是控件自己
/// 声明的动作，很多自绘界面（Electron、游戏、老 MFC）根本没实现它，
/// 点了毫无反应且不报错。合成的点击对谁都成立。
pub fn click(x: f64, y: f64) -> Result<(), String> {
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_LEFTDOWN,
        MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MOVE, MOUSEINPUT,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN,
        SM_YVIRTUALSCREEN,
    };
    unsafe {
        // 绝对坐标是 0..65535 归一化到**虚拟屏幕**的，不是主屏 ——
        // 按主屏算的话副屏上的元素永远点不到
        let (vx, vy) = (
            GetSystemMetrics(SM_XVIRTUALSCREEN) as f64,
            GetSystemMetrics(SM_YVIRTUALSCREEN) as f64,
        );
        let (vw, vh) = (
            GetSystemMetrics(SM_CXVIRTUALSCREEN).max(1) as f64,
            GetSystemMetrics(SM_CYVIRTUALSCREEN).max(1) as f64,
        );
        let nx = (((x - vx) / vw) * 65535.0).round() as i32;
        let ny = (((y - vy) / vh) * 65535.0).round() as i32;

        let mouse = |flags| INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx: nx,
                    dy: ny,
                    mouseData: 0,
                    dwFlags: flags,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };
        let records = [
            mouse(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE),
            mouse(MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_ABSOLUTE),
            mouse(MOUSEEVENTF_LEFTUP | MOUSEEVENTF_ABSOLUTE),
        ];
        let sent = SendInput(&records, std::mem::size_of::<INPUT>() as i32);
        if sent as usize != records.len() {
            return Err("合成点击失败（可能被更高权限的窗口挡住了）".to_string());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_text_and_groups_are_not_clickable() {
        // 收了的话一个网页能标出上千个标签，那时用键盘比用鼠标还慢
        use windows::Win32::UI::Accessibility::{UIA_GroupControlTypeId, UIA_TextControlTypeId};
        assert!(!CLICKABLE.contains(&UIA_TextControlTypeId.0));
        assert!(!CLICKABLE.contains(&UIA_GroupControlTypeId.0));
        assert!(CLICKABLE.contains(&UIA_ButtonControlTypeId.0));
        assert!(CLICKABLE.contains(&UIA_HyperlinkControlTypeId.0));
    }

    #[test]
    fn the_target_cap_keeps_labels_short_enough_to_be_worth_it() {
        // 超过这个数标签会长到三四个字符，找一个的时间早超过伸手够鼠标了
        assert!(MAX_TARGETS >= 50);
        assert!(MAX_TARGETS <= 500);
    }

    #[test]
    fn tiny_elements_are_skipped_because_they_are_usually_separators() {
        assert!(MIN_SIZE > 1.0);
        assert!(MIN_SIZE < 20.0);
    }
}
