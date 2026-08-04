//! 防休眠（Linux）：DBus inhibit。
//!
//! 这个平台上没有「一个 API 搞定」的办法，因为「谁负责让机器睡」本身就有两家：
//!
//! | 接口 | 谁实现 | 管什么 |
//! |---|---|---|
//! | `org.freedesktop.login1.Manager` | systemd | 系统挂起 / 空闲 |
//! | `org.freedesktop.ScreenSaver` | GNOME / KDE / xfce 各自的屏保 | 锁屏与关显示器 |
//!
//! 两家都要打招呼：只跟 systemd 说，屏保照样会把显示器关掉；
//! 只跟屏保说，机器照样会挂起。
//!
//! # 抑制靠「握着一个东西不放」
//!
//! 两家的机制不同，但道理一样 —— 抑制在你**持有某个东西**期间有效：
//!
//! - login1 给你一个**文件描述符**，闭上它抑制就结束（进程崩了也会自动结束，
//!   这是刻意设计：没人希望一个崩掉的程序把机器永远钉醒）
//! - 屏保给你一个 **cookie**，要显式 `UnInhibit` 交回去
//!
//! 所以 [`Inhibitor`] 必须一直被持有着，`drop` 就是解除。
//!
//! # 一家都联系不上时说实话
//!
//! headless、没有 systemd、屏保没跑 —— 都可能。这时不能假装开好了：
//! 用户按了「防休眠」，机器照睡不误，而他毫不知情。所以 [`engage`]
//! 会把「哪家答应了」报回去，一家都没答应就是错误。

use zbus::blocking::Connection;

/// 正在生效的抑制。**丢掉它就等于解除**。
pub struct Inhibitor {
    /// systemd 给的文件描述符。闭上它抑制就结束
    _sleep: Option<zbus::zvariant::OwnedFd>,
    /// 屏保给的 cookie，要显式交回去
    screensaver: Option<(Connection, u32)>,
}

impl Drop for Inhibitor {
    fn drop(&mut self) {
        if let Some((conn, cookie)) = self.screensaver.take() {
            let _ = screensaver_proxy(&conn)
                .and_then(|proxy| proxy.call::<_, _, ()>("UnInhibit", &(cookie)));
        }
        // 文件描述符靠 Drop 自己闭上 —— 这正是 login1 选它的原因
    }
}

impl Inhibitor {
    /// 这次是谁答应的，给用户看。
    pub fn describe(&self) -> String {
        match (self._sleep.is_some(), self.screensaver.is_some()) {
            (true, true) => "系统休眠与屏保都已挡住".to_string(),
            (true, false) => "已挡住系统休眠（屏保接口不可用，显示器仍会关）".to_string(),
            (false, true) => "已挡住屏保（systemd 不可用，系统仍可能挂起）".to_string(),
            (false, false) => "没有任何一家接受抑制".to_string(),
        }
    }
}

/// 为什么要防休眠 —— 会显示在 `systemd-inhibit --list` 里。
const REASON: &str = "用户从 Baobox 开启了防休眠";

/// 开始防休眠。`display` 为真时连屏保一起挡。
///
/// 一家都联系不上时返回错误 —— 不能让用户以为开好了。
pub fn engage(display: bool) -> Result<Inhibitor, String> {
    let sleep = inhibit_sleep();
    let screensaver = if display { inhibit_screensaver() } else { None };

    if sleep.is_none() && screensaver.is_none() {
        return Err(if display {
            "联系不上 systemd-logind，也联系不上屏保服务，防休眠没能开启。".to_string()
        } else {
            "联系不上 systemd-logind，防休眠没能开启。".to_string()
        });
    }
    Ok(Inhibitor {
        _sleep: sleep,
        screensaver,
    })
}

/// 跟 systemd 要一个抑制用的文件描述符。
fn inhibit_sleep() -> Option<zbus::zvariant::OwnedFd> {
    let conn = Connection::system().ok()?;
    let proxy = zbus::blocking::Proxy::new(
        &conn,
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager",
    )
    .ok()?;
    // what 用冒号分隔；"block" 是硬抑制（"delay" 只是拖一会儿，挡不住）
    proxy
        .call::<_, _, zbus::zvariant::OwnedFd>(
            "Inhibit",
            &("idle:sleep", "Baobox", REASON, "block"),
        )
        .ok()
}

/// 跟屏保要一个 cookie。
///
/// 用会话总线而不是系统总线 —— 屏保是跟着登录会话走的。
fn inhibit_screensaver() -> Option<(Connection, u32)> {
    let conn = Connection::session().ok()?;
    let cookie: u32 = screensaver_proxy(&conn)
        .ok()?
        .call("Inhibit", &("com.baobox.app", REASON))
        .ok()?;
    Some((conn, cookie))
}

fn screensaver_proxy(conn: &Connection) -> zbus::Result<zbus::blocking::Proxy<'_>> {
    zbus::blocking::Proxy::new(
        conn,
        "org.freedesktop.ScreenSaver",
        "/org/freedesktop/ScreenSaver",
        "org.freedesktop.ScreenSaver",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 造一个不持有任何东西的抑制器，只为测文案。
    fn empty() -> Inhibitor {
        Inhibitor {
            _sleep: None,
            screensaver: None,
        }
    }

    #[test]
    fn a_partial_success_says_what_is_still_not_covered() {
        // 只挡住一半却说「已开启」，用户会以为万事大吉，然后机器该睡还是睡
        let text = empty().describe();
        assert!(text.contains("没有"), "一家都没答应时不能说得像成功了：{text}");
    }

    #[test]
    fn engaging_without_any_bus_reports_failure_instead_of_pretending() {
        // 这个环境里既没有 systemd 也没有屏保 —— 正好是 headless 的样子。
        // 有总线的机器上这条测试会拿到 Ok，那也对，所以只在失败时检查文案
        if let Err(why) = engage(true) {
            assert!(why.contains("没能开启"), "要说清楚没开成：{why}");
        }
    }

    #[test]
    fn the_reason_is_something_a_person_can_recognise_in_systemd_inhibit_list() {
        // 用户在 `systemd-inhibit --list` 里看到的就是这句话
        assert!(REASON.contains("Baobox"));
    }
}
