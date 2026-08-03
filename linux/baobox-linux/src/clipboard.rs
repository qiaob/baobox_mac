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
//! 提供两种内容：截图给 `image/png`（GIMP、Firefox、LibreOffice、各类聊天软件都认），
//! 屏幕取字给 `UTF8_STRING` + `TEXT` + `STRING`。同一套服务循环，只是能答的 target 不同。

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

/// 放进剪贴板的东西。
pub enum Payload {
    /// 一张 PNG
    Png(Vec<u8>),
    /// 一段文字
    Text(String),
}

impl Payload {
    fn bytes(&self) -> &[u8] {
        match self {
            Payload::Png(data) => data,
            Payload::Text(text) => text.as_bytes(),
        }
    }
}

/// 剪贴板服务需要的几个 atom。
struct Atoms {
    clipboard: Atom,
    targets: Atom,
    png: Atom,
    utf8: Atom,
    text: Atom,
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
            text: intern("TEXT")?,
        })
    }
}

/// 在后台线程上持有剪贴板，**立刻返回**。
///
/// 常驻 App 必须用这个而不是直接调 [`serve`]：X11 的剪贴板要靠本进程持续应答，
/// 而 [`serve`] 是阻塞的 —— 在 GTK 主线程上调它，整个界面会卡住整整
/// [`DEFAULT_SERVE`] 那么久（复制一次界面死一分钟，用户只会以为程序崩了）。
///
/// 线程自己开一条 X11 连接：主线程那条正忙着跑界面，共用会互相干扰。
/// 服务时长给 `None`（一直服务），因为常驻进程本来就不会退出；
/// 下一次复制会让别的程序 / 我们自己接管所有权，旧线程收到 `SelectionClear`
/// 就自己结束，不会攒起来。
pub fn serve_detached(payload: Payload) {
    std::thread::spawn(move || {
        let Ok(session) = crate::x11capture::X11Session::open() else {
            return;
        };
        let Ok(owner) = session.create_owner_window() else {
            return;
        };
        let _ = serve(session.connection(), owner, &payload, None);
    });
}

/// 宣告自己持有剪贴板，并把内容服务出去。
///
/// `serve` 为 `None` 时一直服务（常驻模式）；给了时长则到点返回，
/// 期间别的程序接管所有权也会提前返回。
pub fn serve(
    conn: &RustConnection,
    owner: Window,
    payload: &Payload,
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
                answer(conn, &atoms, &request, payload);
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
fn answer(
    conn: &RustConnection,
    atoms: &Atoms,
    request: &SelectionRequestEvent,
    payload: &Payload,
) {
    let property = if request.property == x11rb::NONE {
        request.target
    } else {
        request.property
    };

    // 能答哪些 target 取决于放进来的是图还是字
    let offered: Vec<Atom> = match payload {
        Payload::Png(_) => vec![atoms.targets, atoms.png],
        Payload::Text(_) => vec![
            atoms.targets,
            atoms.utf8,
            atoms.text,
            AtomEnum::STRING.into(),
        ],
    };

    let handled = if request.target == atoms.targets {
        // 告诉对方我们能提供什么
        conn.change_property32(
            PropMode::REPLACE,
            request.requestor,
            property,
            AtomEnum::ATOM,
            &offered,
        )
        .is_ok()
    } else if offered.contains(&request.target) {
        conn.change_property8(
            PropMode::REPLACE,
            request.requestor,
            property,
            request.target,
            payload.bytes(),
        )
        .is_ok()
    } else {
        // 不支持的格式（比如向一张图要 UTF8_STRING）→ 明确拒绝
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
    fn a_payload_hands_out_its_own_bytes() {
        assert_eq!(Payload::Png(vec![1, 2, 3]).bytes(), &[1, 2, 3]);
        assert_eq!(Payload::Text("hi".into()).bytes(), b"hi");
    }

    #[test]
    fn default_serve_window_is_long_enough_to_paste_but_not_forever() {
        // 太短用户来不及粘贴；太长一次性命令会像卡死
        assert!(DEFAULT_SERVE >= Duration::from_secs(10));
        assert!(DEFAULT_SERVE <= Duration::from_secs(300));
    }
}
