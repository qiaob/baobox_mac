//! 把截图放进 X11 剪贴板。
//!
//! # 为什么这件事在 Linux 上比别处麻烦
//!
//! X11 没有「剪贴板服务」。**数据一直留在源进程里**：你只是宣告自己是 `CLIPBOARD`
//! selection 的所有者，别的程序要粘贴时会向你发一个 `SelectionRequest`，
//! 你把数据写进它指定的属性再回一个 `SelectionNotify`。
//!
//! 直接后果是：**进程退出，剪贴板内容就没了**。所以 `xclip` 才有 `-loops` 参数。
//! 这里的做法是复制完继续服务一段时间（常驻模式下则一直服务），
//! 直到别的程序接管所有权或超时。
//!
//! 提供的格式是 `image/png` —— GIMP、Firefox、LibreOffice、各类聊天软件都认。

use std::time::{Duration, Instant};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    Atom, AtomEnum, ConnectionExt as _, EventMask, PropMode, SelectionNotifyEvent,
    SelectionRequestEvent, Window, SELECTION_NOTIFY_EVENT,
};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

/// 所有权丢失前最多服务多久（一次性命令用；常驻模式传 `None` 一直服务）。
pub const DEFAULT_SERVE: Duration = Duration::from_secs(60);

/// 剪贴板服务需要的几个 atom。
struct Atoms {
    clipboard: Atom,
    targets: Atom,
    png: Atom,
    utf8: Atom,
}

impl Atoms {
    fn load(conn: &RustConnection) -> Result<Self, String> {
        let intern = |name: &str| -> Result<Atom, String> {
            Ok(conn
                .intern_atom(false, name.as_bytes())
                .map_err(|e| e.to_string())?
                .reply()
                .map_err(|e| e.to_string())?
                .atom)
        };
        Ok(Self {
            clipboard: intern("CLIPBOARD")?,
            targets: intern("TARGETS")?,
            png: intern("image/png")?,
            utf8: intern("UTF8_STRING")?,
        })
    }
}

/// 宣告自己持有剪贴板，并把 PNG 数据服务出去。
///
/// `serve` 为 `None` 时一直服务（常驻模式）；给了时长则到点返回，
/// 期间别的程序接管所有权也会提前返回。
pub fn serve_png(
    conn: &RustConnection,
    owner: Window,
    png: &[u8],
    serve: Option<Duration>,
) -> Result<(), String> {
    let atoms = Atoms::load(conn)?;

    conn.set_selection_owner(owner, atoms.clipboard, x11rb::CURRENT_TIME)
        .map_err(|e| format!("宣告剪贴板所有权失败：{e}"))?
        .check()
        .map_err(|e| format!("宣告剪贴板所有权被拒：{e}"))?;
    conn.flush().map_err(|e| e.to_string())?;

    // 确认真的拿到了 —— 有窗口管理器会拒绝
    let current = conn
        .get_selection_owner(atoms.clipboard)
        .map_err(|e| e.to_string())?
        .reply()
        .map_err(|e| e.to_string())?
        .owner;
    if current != owner {
        return Err("没能取得剪贴板所有权".to_string());
    }

    let deadline = serve.map(|d| Instant::now() + d);
    loop {
        if let Some(deadline) = deadline {
            if Instant::now() >= deadline {
                return Ok(());
            }
        }
        // 用 poll 而不是 wait，才能在超时后退出
        match conn.poll_for_event().map_err(|e| e.to_string())? {
            Some(Event::SelectionRequest(request)) => {
                answer(conn, &atoms, &request, png);
            }
            // 别的程序接管了剪贴板 —— 我们的数据已经不需要了
            Some(Event::SelectionClear(_)) => return Ok(()),
            Some(_) => {}
            None => std::thread::sleep(Duration::from_millis(20)),
        }
    }
}

/// 回应一个粘贴请求。
///
/// 请求方给不了合适的属性（`property == 0`，老客户端的写法）时，
/// 按惯例把 target 当作属性名用。
fn answer(conn: &RustConnection, atoms: &Atoms, request: &SelectionRequestEvent, png: &[u8]) {
    let property = if request.property == x11rb::NONE {
        request.target
    } else {
        request.property
    };

    let handled = if request.target == atoms.targets {
        // 告诉对方我们能提供什么
        let targets = [atoms.targets, atoms.png];
        conn.change_property32(
            PropMode::REPLACE,
            request.requestor,
            property,
            AtomEnum::ATOM,
            &targets,
        )
        .is_ok()
    } else if request.target == atoms.png {
        conn.change_property8(
            PropMode::REPLACE,
            request.requestor,
            property,
            atoms.png,
            png,
        )
        .is_ok()
    } else {
        // 不支持的格式（比如有人来要 UTF8_STRING）→ 明确拒绝
        let _ = atoms.utf8;
        false
    };

    // 无论成功与否都要回一个 SelectionNotify，否则请求方会一直等到超时
    let notify = SelectionNotifyEvent {
        response_type: SELECTION_NOTIFY_EVENT,
        sequence: 0,
        time: request.time,
        requestor: request.requestor,
        selection: request.selection,
        target: request.target,
        property: if handled { property } else { x11rb::NONE },
    };
    let _ = conn.send_event(false, request.requestor, EventMask::NO_EVENT, notify);
    let _ = conn.flush();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_serve_window_is_long_enough_to_paste_but_not_forever() {
        // 太短用户来不及粘贴；太长一次性命令会像卡死
        assert!(DEFAULT_SERVE >= Duration::from_secs(10));
        assert!(DEFAULT_SERVE <= Duration::from_secs(300));
    }
}
