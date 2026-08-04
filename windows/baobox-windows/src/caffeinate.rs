//! 防休眠（Windows）：`SetThreadExecutionState`。
//!
//! 对应 macOS 的 IOPMAssertion、Linux 的 DBus inhibit。这个平台上最简单 ——
//! 一次调用就够，不需要句柄、不需要 cookie、不需要保持一条连接。
//!
//! # 但它是**按线程**记的
//!
//! `SetThreadExecutionState` 设的是**调用线程**的状态，线程一退出就自动失效。
//! 所以必须在 App 那条常驻的消息循环线程上调 —— 随手开个线程去设，
//! 那个线程结束的一瞬间防休眠就没了，而且完全无声无息。
//!
//! # `ES_CONTINUOUS` 是「持续」不是「一次」
//!
//! 不带 `ES_CONTINUOUS` 的调用只是「现在重置一下空闲计时器」，一次性的；
//! 带上它才是「从现在起一直保持」。关掉的方法是再调一次、只给
//! `ES_CONTINUOUS` —— 没有专门的「取消」函数，忘了这一步系统就再也不睡了。

#![cfg(windows)]

use windows::Win32::System::Power::{
    SetThreadExecutionState, ES_CONTINUOUS, ES_DISPLAY_REQUIRED, ES_SYSTEM_REQUIRED,
};

/// 让系统别睡。`display` 为真时连显示器也不关。
///
/// 必须在常驻的那条线程上调用 —— 状态是按线程记的。
pub fn engage(display: bool) -> Result<(), String> {
    let mut flags = ES_CONTINUOUS | ES_SYSTEM_REQUIRED;
    if display {
        flags |= ES_DISPLAY_REQUIRED;
    }
    // 返回上一次的状态；0 表示失败
    let previous = unsafe { SetThreadExecutionState(flags) };
    if previous.0 == 0 {
        return Err("系统拒绝了防休眠请求".to_string());
    }
    Ok(())
}

/// 恢复系统自己的休眠设置。
///
/// 只给 `ES_CONTINUOUS`（不带任何 `*_REQUIRED`）就是「我不再有要求了」。
/// 漏了这一步，系统在本进程活着的整段时间里都不会休眠。
pub fn release() {
    unsafe {
        SetThreadExecutionState(ES_CONTINUOUS);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_display_flag_is_the_only_difference_between_the_two_modes() {
        // 两种模式都必须带 ES_CONTINUOUS 与 ES_SYSTEM_REQUIRED，
        // 差别只在要不要连显示器一起留着
        let system_only = ES_CONTINUOUS | ES_SYSTEM_REQUIRED;
        let with_display = ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED;
        assert_ne!(system_only.0, with_display.0);
        assert_eq!(with_display.0 & system_only.0, system_only.0);
    }

    #[test]
    fn releasing_keeps_continuous_but_drops_every_requirement() {
        // 只给 ES_CONTINUOUS 才是「我不再有要求了」；
        // 传 0 是另一个意思（一次性重置计时器），关不掉
        assert_ne!(ES_CONTINUOUS.0, 0);
        assert_eq!(ES_CONTINUOUS.0 & ES_SYSTEM_REQUIRED.0, 0);
        assert_eq!(ES_CONTINUOUS.0 & ES_DISPLAY_REQUIRED.0, 0);
    }
}
