//! 贴图：把截图钉在屏幕最上层。
//!
//! 对照做别的事的时候很有用 —— 图一直浮在那儿，不用来回切窗口。
//!
//! # 为什么用 override-redirect 而不是普通窗口
//!
//! 普通窗口会被窗口管理器加标题栏、被工作区切换带走、被「显示桌面」最小化。
//! 贴图要的是「一直在那儿」，所以直接绕过窗口管理器（override-redirect），
//! 同时也标上 `_NET_WM_STATE_ABOVE`，让认这条属性的合成器把它排在最上面。
//!
//! # 交互
//!
//! - 按住左键拖动 = 挪位置
//! - Esc / 右键 / 双击 = 关掉
//!
//! 拖动用 `ConfigureWindow` 直接改窗口位置，不走窗口管理器的 `_NET_WM_MOVERESIZE`
//! ——override-redirect 的窗口本来就不归它管。

use baobox_core::geometry::Rect;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    self, AtomEnum, ConfigureWindowAux, ConnectionExt as _, CreateGCAux, CreateWindowAux, EventMask,
    PropMode, Screen, Window, WindowClass,
};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;
use x11rb::COPY_DEPTH_FROM_PARENT;

/// 双击判定的时间窗口（毫秒）。X11 的事件自带时间戳，直接用它。
const DOUBLE_CLICK_MS: u32 = 400;

/// 钉一张图到屏幕上，阻塞到用户关掉为止。
///
/// `at` 是初始位置（一般就是截图原来的位置，视觉上「留在原地」）。
pub fn show(
    conn: &RustConnection,
    screen: &Screen,
    at: Rect,
    rgba: &[u8],
    width: u32,
    height: u32,
) -> Result<(), String> {
    let depth = screen.root_depth;
    let msb_first = conn.setup().image_byte_order == xproto::ImageOrder::MSB_FIRST;
    let window = conn.generate_id().map_err(|e| e.to_string())?;
    let aux = CreateWindowAux::new()
        .override_redirect(1)
        .background_pixel(0x0000_0000)
        .event_mask(
            EventMask::EXPOSURE
                | EventMask::BUTTON_PRESS
                | EventMask::BUTTON_RELEASE
                | EventMask::POINTER_MOTION
                | EventMask::KEY_PRESS,
        );
    conn.create_window(
        COPY_DEPTH_FROM_PARENT,
        window,
        screen.root,
        at.x as i16,
        at.y as i16,
        width as u16,
        height as u16,
        0,
        WindowClass::INPUT_OUTPUT,
        x11rb::COPY_FROM_PARENT,
        &aux,
    )
    .map_err(|e| format!("创建贴图窗口失败：{e}"))?;

    mark_always_on_top(conn, window);
    conn.map_window(window).map_err(|e| e.to_string())?;

    let gc = conn.generate_id().map_err(|e| e.to_string())?;
    conn.create_gc(gc, window, &CreateGCAux::new())
        .map_err(|e| e.to_string())?;

    // 直接画进窗口：贴图内容不会变，重绘时再画一次即可，不必留 Pixmap
    let paint = |()| -> Result<(), String> {
        crate::editor::upload_rgba(
            conn,
            window,
            gc,
            width as usize,
            height as usize,
            rgba,
            msb_first,
            depth,
        )
    };
    paint(())?;
    conn.flush().map_err(|e| e.to_string())?;

    // 抓键盘，Esc 才能关掉 —— 不抓的话按键会送给下面那个有焦点的 App
    let _ = conn.grab_keyboard(
        false,
        window,
        x11rb::CURRENT_TIME,
        xproto::GrabMode::ASYNC,
        xproto::GrabMode::ASYNC,
    );

    let mut drag: Option<Drag> = None;
    let mut last_click: u32 = 0;
    let mut position = (at.x as i16, at.y as i16);

    loop {
        let event = conn.wait_for_event().map_err(|e| e.to_string())?;
        match event {
            Event::Expose(_) => {
                paint(())?;
                conn.flush().map_err(|e| e.to_string())?;
            }
            Event::ButtonPress(press) => match press.detail {
                1 => {
                    if press.time.saturating_sub(last_click) <= DOUBLE_CLICK_MS {
                        break;
                    }
                    last_click = press.time;
                    drag = Some(Drag {
                        grab: (press.root_x, press.root_y),
                        origin: position,
                    });
                }
                // 右键与中键都关掉 —— 贴图没有别的操作，多给一条出路
                _ => break,
            },
            Event::ButtonRelease(_) => drag = None,
            Event::MotionNotify(motion) => {
                let Some(state) = &drag else { continue };
                position = (
                    state.origin.0 + (motion.root_x - state.grab.0),
                    state.origin.1 + (motion.root_y - state.grab.1),
                );
                conn.configure_window(
                    window,
                    &ConfigureWindowAux::new()
                        .x(position.0 as i32)
                        .y(position.1 as i32),
                )
                .map_err(|e| e.to_string())?;
                conn.flush().map_err(|e| e.to_string())?;
            }
            // 任意按键都关掉：贴图窗口抓着键盘，留着它会挡住别人打字
            Event::KeyPress(_) => break,
            _ => {}
        }
    }

    let _ = conn.ungrab_keyboard(x11rb::CURRENT_TIME);
    let _ = conn.free_gc(gc);
    let _ = conn.destroy_window(window);
    conn.flush().map_err(|e| e.to_string())?;
    Ok(())
}

/// 一次拖动：记下抓取点与窗口当时的位置，移动量按差值算。
struct Drag {
    /// 按下时指针在根窗口里的位置
    grab: (i16, i16),
    /// 按下时窗口的位置
    origin: (i16, i16),
}

/// 标上 `_NET_WM_STATE_ABOVE`。
///
/// override-redirect 已经绕过了窗口管理器，这条属性是给**合成器**看的 ——
/// 有些合成器仍会按它排序。取不到 atom 就跳过，不影响主要功能。
fn mark_always_on_top(conn: &RustConnection, window: Window) {
    let atom = |name: &str| -> Option<u32> {
        conn.intern_atom(false, name.as_bytes())
            .ok()?
            .reply()
            .ok()
            .map(|reply| reply.atom)
    };
    if let (Some(state), Some(above)) = (atom("_NET_WM_STATE"), atom("_NET_WM_STATE_ABOVE")) {
        let _ = conn.change_property32(PropMode::REPLACE, window, state, AtomEnum::ATOM, &[above]);
    }
    if let (Some(kind), Some(utility)) = (
        atom("_NET_WM_WINDOW_TYPE"),
        atom("_NET_WM_WINDOW_TYPE_UTILITY"),
    ) {
        let _ = conn.change_property32(PropMode::REPLACE, window, kind, AtomEnum::ATOM, &[utility]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dragging_moves_by_the_pointer_delta_not_to_the_pointer() {
        // 抓在图的中间往右下拖，窗口应该跟着走同样的距离，
        // 而不是把左上角跳到指针位置
        let drag = Drag {
            grab: (500, 400),
            origin: (100, 100),
        };
        let moved = (
            drag.origin.0 + (560 - drag.grab.0),
            drag.origin.1 + (430 - drag.grab.1),
        );
        assert_eq!(moved, (160, 130));
    }

    #[test]
    fn double_click_window_is_a_human_scale_interval() {
        // 太短双击关不掉，太长会把两次独立的点击误判成双击
        assert!(DOUBLE_CLICK_MS >= 200 && DOUBLE_CLICK_MS <= 600);
    }
}
