//! 窗口管理（Linux）：EWMH。
//!
//! 几何全在 `baobox_core::layout`（三平台共用），这里只做四件事：
//! 找到当前窗口、算出每块屏的可用区域、取消最大化、把窗口挪过去。
//!
//! # 摆窗口要发消息，不能直接 `ConfigureWindow`
//!
//! 直接改窗口几何是绕过窗口管理器的：WM 不知道这事，它记的位置还是旧的，
//! 下一次它自己重排（换工作区、插拔显示器）就会把窗口弹回去。
//! EWMH 为此定义了 `_NET_MOVERESIZE_WINDOW` —— 发给根窗口，由 WM 执行。
//!
//! # 坐标说的是**客户区**，不是带边框的整个窗口
//!
//! `_NET_MOVERESIZE_WINDOW` 里的 x/y/宽/高 指的是客户窗口，而用户看到的
//! 是**带标题栏和边框**的那一整块。不换算的话，每个窗口都会比预期大一圈
//! （多出来的正是边框），两个半屏窗口会互相压着。
//!
//! 边框有多厚由 `_NET_FRAME_EXTENTS` 给出。这段算术是纯的，
//! [`client_rect_for`] 单独测。
//!
//! # 先取消最大化
//!
//! 最大化的窗口，WM 会忽略掉挪位置的请求（它正按自己的规则占满屏）。
//! 所以要先发一条 `_NET_WM_STATE` 把 `MAXIMIZED_HORZ` / `MAXIMIZED_VERT` 去掉。
//!
//! # 可用区域：`_NET_WORKAREA` 在多屏下不够用
//!
//! 那个属性给的是**整个桌面**的一块矩形，多屏时它是所有屏的并集 ——
//! 拿它当「这块屏的可用区域」，副屏上的窗口会被摆到主屏去。
//! 所以这里逐屏算：显示器矩形减去与它相交的那些 strut（任务栏、Dock
//! 用 `_NET_WM_STRUT_PARTIAL` 声明自己占了哪一条边）。

use baobox_core::geometry::Rect;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    AtomEnum, ClientMessageEvent, ConnectionExt as _, EventMask, Window, CLIENT_MESSAGE_EVENT,
};
use x11rb::rust_connection::RustConnection;

/// 一条边上被占掉多少（任务栏、Dock 之类声明的）。
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Strut {
    /// 左边占了多少
    pub left: f64,
    /// 右边占了多少
    pub right: f64,
    /// 上边占了多少
    pub top: f64,
    /// 下边占了多少
    pub bottom: f64,
    /// 这条 strut 沿边的起止（`_NET_WM_STRUT_PARTIAL` 才有）。
    ///
    /// 有了它才能判断「这条任务栏在哪块屏上」—— 只看厚度的话，
    /// 主屏底部的任务栏会把每一块屏的底部都削掉一截
    pub left_span: (f64, f64),
    /// 同上
    pub right_span: (f64, f64),
    /// 同上
    pub top_span: (f64, f64),
    /// 同上
    pub bottom_span: (f64, f64),
}

/// 窗口四周的装饰有多厚（`_NET_FRAME_EXTENTS`）。
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct FrameExtents {
    /// 左边框
    pub left: f64,
    /// 右边框
    pub right: f64,
    /// 标题栏
    pub top: f64,
    /// 下边框
    pub bottom: f64,
}

/// 一块屏减掉压在它身上的那些 strut，剩下的可用区域。
///
/// 只减**真的压在这块屏上**的：主屏底部的任务栏不该把副屏的底部也削掉。
/// 判断依据是 strut 沿边的起止范围与这块屏在那个方向上有没有重叠。
pub fn work_area(monitor: &Rect, struts: &[Strut], screen: &Rect) -> Rect {
    let mut left = monitor.x;
    let mut top = monitor.y;
    let mut right = monitor.right();
    let mut bottom = monitor.bottom();

    for strut in struts {
        // strut 的厚度是从**整个屏幕**的边算起的，不是从这块显示器的边
        if strut.left > 0.0
            && overlaps(strut.left_span, (monitor.y, monitor.bottom()))
            && screen.x + strut.left > left
        {
            left = (screen.x + strut.left).min(right);
        }
        if strut.right > 0.0
            && overlaps(strut.right_span, (monitor.y, monitor.bottom()))
            && screen.right() - strut.right < right
        {
            right = (screen.right() - strut.right).max(left);
        }
        if strut.top > 0.0
            && overlaps(strut.top_span, (monitor.x, monitor.right()))
            && screen.y + strut.top > top
        {
            top = (screen.y + strut.top).min(bottom);
        }
        if strut.bottom > 0.0
            && overlaps(strut.bottom_span, (monitor.x, monitor.right()))
            && screen.bottom() - strut.bottom < bottom
        {
            bottom = (screen.bottom() - strut.bottom).max(top);
        }
    }
    Rect::new(left, top, (right - left).max(0.0), (bottom - top).max(0.0))
}

/// 两段区间有没有重叠。空区间（起止相等）当成「整条边」——
/// `_NET_WM_STRUT`（老的、不带 span 的那个）就是这么用的。
fn overlaps(span: (f64, f64), range: (f64, f64)) -> bool {
    if span.0 >= span.1 {
        return true;
    }
    span.0 < range.1 && span.1 > range.0
}

/// 「希望看到的整块矩形」→「该写进 `_NET_MOVERESIZE_WINDOW` 的客户区矩形」。
///
/// 不做这一步的话每个窗口都会比预期大一圈（多出来的正是边框与标题栏），
/// 两个半屏窗口会互相压着。
pub fn client_rect_for(visible: &Rect, extents: &FrameExtents) -> Rect {
    Rect::new(
        visible.x + extents.left,
        visible.y + extents.top,
        (visible.w - extents.left - extents.right).max(1.0),
        (visible.h - extents.top - extents.bottom).max(1.0),
    )
}

/// `_NET_MOVERESIZE_WINDOW` 的 flags 字段。
///
/// 低 8 位是重力，8–11 位说「x/y/宽/高 这四个我给了哪些」，12–13 位是来源。
/// 重力用 **StaticGravity(10)**：这样坐标明确指客户窗口本身，
/// 不受窗口自己声明的 `win_gravity` 影响 —— 否则同一段代码在不同程序上
/// 会摆到不同的地方，而且毫无规律。
pub fn move_resize_flags() -> u32 {
    const STATIC_GRAVITY: u32 = 10;
    const HAS_X: u32 = 1 << 8;
    const HAS_Y: u32 = 1 << 9;
    const HAS_WIDTH: u32 = 1 << 10;
    const HAS_HEIGHT: u32 = 1 << 11;
    // 2 = 直接来自用户操作的程序（pager），WM 对它比对普通程序更配合
    const SOURCE_PAGER: u32 = 2 << 12;
    STATIC_GRAVITY | HAS_X | HAS_Y | HAS_WIDTH | HAS_HEIGHT | SOURCE_PAGER
}

/// 现在是哪个窗口在最前面。
pub fn active_window(conn: &RustConnection, root: Window) -> Option<Window> {
    let atom = intern(conn, "_NET_ACTIVE_WINDOW")?;
    let reply = conn
        .get_property(false, root, atom, AtomEnum::WINDOW, 0, 1)
        .ok()?
        .reply()
        .ok()?;
    let window = reply.value32()?.next()?;
    if window == x11rb::NONE {
        return None;
    }
    Some(window)
}

/// 一个窗口现在的**可见**矩形（含边框）与它的边框厚度。
pub fn geometry(conn: &RustConnection, root: Window, window: Window) -> Option<(Rect, FrameExtents)> {
    let geometry = conn.get_geometry(window).ok()?.reply().ok()?;
    // 窗口的 x/y 是相对父窗口的，要换算到根窗口坐标
    let point = conn
        .translate_coordinates(window, root, 0, 0)
        .ok()?
        .reply()
        .ok()?;
    let extents = frame_extents(conn, window);
    let client = Rect::new(
        point.dst_x as f64,
        point.dst_y as f64,
        geometry.width as f64,
        geometry.height as f64,
    );
    // 客户区 → 用户看到的那一整块
    let visible = Rect::new(
        client.x - extents.left,
        client.y - extents.top,
        client.w + extents.left + extents.right,
        client.h + extents.top + extents.bottom,
    );
    Some((visible, extents))
}

/// 读 `_NET_FRAME_EXTENTS`。没有这个属性（无边框窗口）就是全零。
pub fn frame_extents(conn: &RustConnection, window: Window) -> FrameExtents {
    let Some(atom) = intern(conn, "_NET_FRAME_EXTENTS") else {
        return FrameExtents::default();
    };
    let Some(values) = cardinals(conn, window, atom, 4) else {
        return FrameExtents::default();
    };
    FrameExtents {
        left: values[0],
        right: values[1],
        top: values[2],
        bottom: values[3],
    }
}

/// 每块显示器的矩形。
///
/// 走 RandR 1.5 的 `GetMonitors`；拿不到（老服务器、没有 RandR）就退回
/// 整块屏幕当一块 —— 单显示器下这与真实情况一致，多显示器下会退化成
/// 「整个桌面算一块屏」，半屏会横跨两块。**不假装成功**：调用方据此提示。
pub fn monitors(conn: &RustConnection, root: Window, screen: &Rect) -> (Vec<Rect>, bool) {
    use x11rb::protocol::randr::ConnectionExt as _;
    let found = conn
        .randr_get_monitors(root, true)
        .ok()
        .and_then(|c| c.reply().ok())
        .map(|reply| {
            reply
                .monitors
                .iter()
                .map(|m| Rect::new(m.x as f64, m.y as f64, m.width as f64, m.height as f64))
                .collect::<Vec<Rect>>()
        })
        .unwrap_or_default();
    if found.is_empty() {
        (vec![*screen], false)
    } else {
        (found, true)
    }
}

/// 读所有客户窗口声明的 strut。
pub fn struts(conn: &RustConnection, root: Window) -> Vec<Strut> {
    let Some(list_atom) = intern(conn, "_NET_CLIENT_LIST") else {
        return Vec::new();
    };
    let Some(partial) = intern(conn, "_NET_WM_STRUT_PARTIAL") else {
        return Vec::new();
    };
    let plain = intern(conn, "_NET_WM_STRUT");

    let windows: Vec<Window> = conn
        .get_property(false, root, list_atom, AtomEnum::WINDOW, 0, u32::MAX)
        .ok()
        .and_then(|c| c.reply().ok())
        .and_then(|r| r.value32().map(|iter| iter.collect()))
        .unwrap_or_default();

    let mut found = Vec::new();
    for window in windows {
        // 优先带 span 的那个：只有它说得清「这条任务栏在哪一段边上」
        if let Some(v) = cardinals(conn, window, partial, 12) {
            found.push(Strut {
                left: v[0],
                right: v[1],
                top: v[2],
                bottom: v[3],
                left_span: (v[4], v[5]),
                right_span: (v[6], v[7]),
                top_span: (v[8], v[9]),
                bottom_span: (v[10], v[11]),
            });
            continue;
        }
        if let Some(atom) = plain {
            if let Some(v) = cardinals(conn, window, atom, 4) {
                // 老属性没有 span，按「占满整条边」处理
                found.push(Strut {
                    left: v[0],
                    right: v[1],
                    top: v[2],
                    bottom: v[3],
                    ..Default::default()
                });
            }
        }
    }
    found
}

/// 取消最大化。最大化的窗口，WM 会忽略掉挪位置的请求。
pub fn unmaximize(conn: &RustConnection, root: Window, window: Window) {
    const REMOVE: u32 = 0;
    let (Some(state), Some(horz), Some(vert)) = (
        intern(conn, "_NET_WM_STATE"),
        intern(conn, "_NET_WM_STATE_MAXIMIZED_HORZ"),
        intern(conn, "_NET_WM_STATE_MAXIMIZED_VERT"),
    ) else {
        return;
    };
    send(conn, root, window, state, [REMOVE, horz, vert, 2, 0]);
}

/// 把窗口摆到目标位置。`target` 是**希望看到的**整块矩形（含边框）。
pub fn place(
    conn: &RustConnection,
    root: Window,
    window: Window,
    target: &Rect,
    extents: &FrameExtents,
) -> Result<(), String> {
    let atom = intern(conn, "_NET_MOVERESIZE_WINDOW")
        .ok_or("这个窗口管理器不支持 _NET_MOVERESIZE_WINDOW")?;
    let client = client_rect_for(target, extents);
    send(
        conn,
        root,
        window,
        atom,
        [
            move_resize_flags(),
            client.x.round() as i32 as u32,
            client.y.round() as i32 as u32,
            client.w.round().max(1.0) as u32,
            client.h.round().max(1.0) as u32,
        ],
    );
    conn.flush().map_err(|e| format!("摆放窗口失败：{e}"))
}

/// 往根窗口发一条 EWMH 客户消息。
fn send(conn: &RustConnection, root: Window, window: Window, atom: u32, data: [u32; 5]) {
    let event = ClientMessageEvent {
        response_type: CLIENT_MESSAGE_EVENT,
        format: 32,
        sequence: 0,
        window,
        type_: atom,
        data: data.into(),
    };
    // EWMH 规定这类消息发给**根窗口**，掩码要带这两个 —— WM 是靠它们收到的
    let _ = conn.send_event(
        false,
        root,
        EventMask::SUBSTRUCTURE_NOTIFY | EventMask::SUBSTRUCTURE_REDIRECT,
        event,
    );
}

fn intern(conn: &RustConnection, name: &str) -> Option<u32> {
    Some(
        conn.intern_atom(false, name.as_bytes())
            .ok()?
            .reply()
            .ok()?
            .atom,
    )
}

/// 读一串 CARDINAL。数量不足就当没有 —— 半截的属性没法用。
fn cardinals(conn: &RustConnection, window: Window, atom: u32, count: u32) -> Option<Vec<f64>> {
    let reply = conn
        .get_property(false, window, atom, AtomEnum::CARDINAL, 0, count)
        .ok()?
        .reply()
        .ok()?;
    let values: Vec<f64> = reply.value32()?.map(|v| v as f64).collect();
    if values.len() < count as usize {
        return None;
    }
    Some(values)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen() -> Rect {
        // 两块 1920×1080 并排
        Rect::new(0.0, 0.0, 3840.0, 1080.0)
    }

    fn primary() -> Rect {
        Rect::new(0.0, 0.0, 1920.0, 1080.0)
    }

    fn secondary() -> Rect {
        Rect::new(1920.0, 0.0, 1920.0, 1080.0)
    }

    /// 主屏底部一条 40 像素高的任务栏。
    fn taskbar_on_primary() -> Strut {
        Strut {
            bottom: 40.0,
            bottom_span: (0.0, 1920.0),
            ..Default::default()
        }
    }

    #[test]
    fn a_taskbar_shrinks_the_screen_it_actually_sits_on() {
        let area = work_area(&primary(), &[taskbar_on_primary()], &screen());
        assert_eq!(area, Rect::new(0.0, 0.0, 1920.0, 1040.0));
    }

    #[test]
    fn a_taskbar_on_one_screen_does_not_shrink_the_other() {
        // 只看厚度不看 span 的话，副屏的底部也会被削掉一截 ——
        // 那块屏上什么都没有，凭空少了 40 像素
        let area = work_area(&secondary(), &[taskbar_on_primary()], &screen());
        assert_eq!(area, secondary(), "副屏不该受主屏任务栏影响");
    }

    #[test]
    fn the_old_strut_property_without_spans_applies_to_every_screen() {
        // `_NET_WM_STRUT` 没有 span，按「占满整条边」处理 —— 保守但不会摆错
        let old = Strut {
            bottom: 40.0,
            ..Default::default()
        };
        assert_eq!(work_area(&secondary(), &[old], &screen()).h, 1040.0);
    }

    #[test]
    fn struts_are_measured_from_the_whole_screen_not_from_the_monitor() {
        // 左边一条 60 宽的 Dock。副屏的左边缘在 x=1920，
        // 而 strut 说的是「从整个屏幕的左边算 60」——
        // 拿它去减副屏的左边会把副屏削掉 60，那是错的
        let dock = Strut {
            left: 60.0,
            left_span: (0.0, 1080.0),
            ..Default::default()
        };
        assert_eq!(work_area(&primary(), &[dock], &screen()).x, 60.0);
        assert_eq!(work_area(&secondary(), &[dock], &screen()), secondary());
    }

    #[test]
    fn several_struts_stack_up() {
        let top = Strut {
            top: 30.0,
            top_span: (0.0, 1920.0),
            ..Default::default()
        };
        let area = work_area(&primary(), &[taskbar_on_primary(), top], &screen());
        assert_eq!(area, Rect::new(0.0, 30.0, 1920.0, 1010.0));
    }

    #[test]
    fn absurd_struts_do_not_produce_a_negative_work_area() {
        // 一个行为不端的面板声明自己占了整块屏
        let greedy = Strut {
            top: 5000.0,
            bottom: 5000.0,
            ..Default::default()
        };
        let area = work_area(&primary(), &[greedy], &screen());
        assert!(area.w >= 0.0 && area.h >= 0.0);
    }

    #[test]
    fn the_frame_is_subtracted_so_the_visible_window_lands_where_asked() {
        // 不减的话每个窗口都会比预期大一圈，两个半屏窗口互相压着
        let extents = FrameExtents {
            left: 1.0,
            right: 1.0,
            top: 28.0,
            bottom: 1.0,
        };
        let visible = Rect::new(0.0, 0.0, 960.0, 1040.0);
        let client = client_rect_for(&visible, &extents);
        assert_eq!(client, Rect::new(1.0, 28.0, 958.0, 1011.0));
        // 反推回去正好是原来那块
        assert_eq!(client.x - extents.left, visible.x);
        assert_eq!(client.w + extents.left + extents.right, visible.w);
    }

    #[test]
    fn an_undecorated_window_is_placed_verbatim() {
        let visible = Rect::new(10.0, 20.0, 300.0, 400.0);
        assert_eq!(client_rect_for(&visible, &FrameExtents::default()), visible);
    }

    #[test]
    fn a_frame_thicker_than_the_target_still_produces_a_usable_size() {
        // 目标比边框还小时不能算出 0 或负数 —— X 会直接拒绝那种请求
        let fat = FrameExtents {
            left: 100.0,
            right: 100.0,
            top: 100.0,
            bottom: 100.0,
        };
        let client = client_rect_for(&Rect::new(0.0, 0.0, 50.0, 50.0), &fat);
        assert!(client.w >= 1.0 && client.h >= 1.0);
    }

    #[test]
    fn the_move_resize_flags_say_all_four_fields_are_present() {
        let flags = move_resize_flags();
        for bit in 8..=11 {
            assert_ne!(flags & (1 << bit), 0, "第 {bit} 位（x/y/宽/高）没置上");
        }
        // 低 8 位是重力，必须是 StaticGravity —— 否则同一段代码在不同程序上
        // 会摆到不同的地方
        assert_eq!(flags & 0xFF, 10);
    }
}
