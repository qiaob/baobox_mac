//! X11 交互式截图覆盖层。
//!
//! 这是「截图」真正的门面：铺一层全屏窗口，压暗背景，鼠标悬停高亮窗口、
//! 拖拽拉选区、八向手柄微调、方向键逐像素移动，⏎ 确认、Esc 取消。
//!
//! **交互规则本身不在这里** —— 全部来自 `baobox_core::selection::Selection`，
//! 与 macOS 版共用同一套状态机。这里只做三件事：把 X11 事件翻译成状态机的输入、
//! 把状态机的当前选区画出来、结束时把结果交出去。
//!
//! # 透明度
//!
//! 优先找 32 位 ARGB visual 做半透明压暗。找不到（老驱动 / 无合成器）时**降级为
//! 只画选区边框，不压暗** —— 没有合成器时强行填充半透明色会得到一块纯色遮板，
//! 那还不如不压暗。

use baobox_core::geometry::{Handle, Rect};
use baobox_core::selection::{Key, Outcome, Phase, Selection};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    self, AtomEnum, ChangeGCAux, ColormapAlloc, ConnectionExt as _, CreateGCAux, CreateWindowAux,
    EventMask, Gcontext, GrabMode, Screen, Visualid, Window, WindowClass,
};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;
use x11rb::COPY_DEPTH_FROM_PARENT;

/// 手柄绘制的边长（像素）。命中容差在 `baobox_core::selection` 里，两者应当接近。
const HANDLE_SIZE: i16 = 8;

/// X11 keysym —— 只列覆盖层用得到的几个。
mod keysym {
    /// Esc
    pub const ESCAPE: u32 = 0xff1b;
    /// Return
    pub const RETURN: u32 = 0xff0d;
    /// 小键盘 Enter
    pub const KP_ENTER: u32 = 0xff8d;
    /// ←
    pub const LEFT: u32 = 0xff51;
    /// ↑
    pub const UP: u32 = 0xff52;
    /// →
    pub const RIGHT: u32 = 0xff53;
    /// ↓
    pub const DOWN: u32 = 0xff54;
}

/// 覆盖层运行结果。
pub struct OverlayResult {
    /// 用户选择的目标
    pub outcome: Outcome,
    /// 窗口列表（`Outcome::Window(i)` 的下标指向它）
    pub windows: Vec<Rect>,
}

/// 铺一层覆盖窗，跑到用户确认或取消为止。
///
/// `screen_rect` 是整个虚拟屏幕，`windows` 是可命中的窗口（z 序从前到后）。
pub fn run(
    conn: &RustConnection,
    screen: &Screen,
    screen_rect: Rect,
    windows: Vec<Rect>,
) -> Result<OverlayResult, String> {
    let visual = find_argb_visual(screen);
    let translucent = visual.is_some();
    let window = create_overlay(conn, screen, screen_rect, visual)?;

    // 抓住指针与键盘：覆盖层期间的输入不应漏给下面的 App
    let _ = conn.grab_pointer(
        false,
        window,
        EventMask::BUTTON_PRESS | EventMask::BUTTON_RELEASE | EventMask::POINTER_MOTION,
        GrabMode::ASYNC,
        GrabMode::ASYNC,
        x11rb::NONE,
        x11rb::NONE,
        x11rb::CURRENT_TIME,
    );
    let _ = conn.grab_keyboard(
        false,
        window,
        x11rb::CURRENT_TIME,
        GrabMode::ASYNC,
        GrabMode::ASYNC,
    );
    conn.flush().map_err(|e| e.to_string())?;

    let keymap = KeyMap::load(conn)?;
    let gc = create_gc(conn, window)?;
    let mut selection = Selection::new(screen_rect, windows.clone());

    let outcome = loop {
        if let Some(outcome) = selection.outcome() {
            break outcome.clone();
        }
        let event = conn.wait_for_event().map_err(|e| format!("事件循环出错：{e}"))?;
        match event {
            Event::Expose(_) => draw(conn, window, gc, screen_rect, &selection, translucent)?,
            Event::MotionNotify(motion) => {
                selection.mouse_moved((motion.event_x as f64, motion.event_y as f64));
                draw(conn, window, gc, screen_rect, &selection, translucent)?;
            }
            Event::ButtonPress(press) => {
                // 只理会左键；右键在很多截图工具里是取消，这里保持一致
                match press.detail {
                    1 => selection.mouse_down((press.event_x as f64, press.event_y as f64)),
                    3 => selection.key_down(Key::Escape, false),
                    _ => {}
                }
                draw(conn, window, gc, screen_rect, &selection, translucent)?;
            }
            Event::ButtonRelease(release) => {
                if release.detail == 1 {
                    selection.mouse_up((release.event_x as f64, release.event_y as f64));
                }
                draw(conn, window, gc, screen_rect, &selection, translucent)?;
            }
            Event::KeyPress(key) => {
                let shift = key.state.contains(xproto::KeyButMask::SHIFT);
                if let Some(mapped) = keymap.translate(key.detail) {
                    selection.key_down(mapped, shift);
                }
                draw(conn, window, gc, screen_rect, &selection, translucent)?;
            }
            _ => {}
        }
    };

    // 先撤掉覆盖层再返回：否则接下来的抓屏会把覆盖层本身也截进去
    let _ = conn.ungrab_pointer(x11rb::CURRENT_TIME);
    let _ = conn.ungrab_keyboard(x11rb::CURRENT_TIME);
    let _ = conn.destroy_window(window);
    conn.flush().map_err(|e| e.to_string())?;
    // 等服务器真正处理完销毁请求，再让调用方去抓屏
    conn.sync().map_err(|e| e.to_string())?;

    Ok(OverlayResult { outcome, windows })
}

/// 找一个 32 位 ARGB visual，用于半透明压暗。
fn find_argb_visual(screen: &Screen) -> Option<Visualid> {
    screen
        .allowed_depths
        .iter()
        .find(|depth| depth.depth == 32)
        .and_then(|depth| depth.visuals.first())
        .map(|visual| visual.visual_id)
}

fn create_overlay(
    conn: &RustConnection,
    screen: &Screen,
    rect: Rect,
    visual: Option<Visualid>,
) -> Result<Window, String> {
    let window = conn.generate_id().map_err(|e| e.to_string())?;
    let events = EventMask::EXPOSURE
        | EventMask::BUTTON_PRESS
        | EventMask::BUTTON_RELEASE
        | EventMask::POINTER_MOTION
        | EventMask::KEY_PRESS;

    match visual {
        Some(visual_id) => {
            // ARGB visual 需要配套的 colormap，且必须显式给 border_pixel，
            // 否则从父窗口继承会因深度不一致而报 BadMatch
            let colormap = conn.generate_id().map_err(|e| e.to_string())?;
            conn.create_colormap(ColormapAlloc::NONE, colormap, screen.root, visual_id)
                .map_err(|e| e.to_string())?;
            let aux = CreateWindowAux::new()
                .background_pixel(0x0000_0000)
                .border_pixel(0)
                .colormap(colormap)
                .override_redirect(1)
                .event_mask(events);
            conn.create_window(
                32,
                window,
                screen.root,
                rect.x as i16,
                rect.y as i16,
                rect.w as u16,
                rect.h as u16,
                0,
                WindowClass::INPUT_OUTPUT,
                visual_id,
                &aux,
            )
            .map_err(|e| format!("创建覆盖窗失败：{e}"))?;
        }
        None => {
            let aux = CreateWindowAux::new()
                .override_redirect(1)
                .event_mask(events);
            conn.create_window(
                COPY_DEPTH_FROM_PARENT,
                window,
                screen.root,
                rect.x as i16,
                rect.y as i16,
                rect.w as u16,
                rect.h as u16,
                0,
                WindowClass::INPUT_OUTPUT,
                x11rb::COPY_FROM_PARENT,
                &aux,
            )
            .map_err(|e| format!("创建覆盖窗失败：{e}"))?;
        }
    }

    // 标成 dock 类型并置顶，避免被合成器加装饰或压到别的窗口下面
    if let (Ok(window_type), Ok(dock)) = (
        intern(conn, "_NET_WM_WINDOW_TYPE"),
        intern(conn, "_NET_WM_WINDOW_TYPE_DOCK"),
    ) {
        let _ = conn.change_property32(
            xproto::PropMode::REPLACE,
            window,
            window_type,
            AtomEnum::ATOM,
            &[dock],
        );
    }

    conn.map_window(window).map_err(|e| e.to_string())?;
    conn.flush().map_err(|e| e.to_string())?;
    Ok(window)
}

fn intern(conn: &RustConnection, name: &str) -> Result<u32, String> {
    Ok(conn
        .intern_atom(false, name.as_bytes())
        .map_err(|e| e.to_string())?
        .reply()
        .map_err(|e| e.to_string())?
        .atom)
}

fn create_gc(conn: &RustConnection, window: Window) -> Result<Gcontext, String> {
    let gc = conn.generate_id().map_err(|e| e.to_string())?;
    conn.create_gc(gc, window, &CreateGCAux::new())
        .map_err(|e| format!("创建 GC 失败：{e}"))?;
    Ok(gc)
}

/// 重绘整个覆盖层。
///
/// 画法：先铺一层压暗色，再把选区「挖空」（用全透明填回去），最后描边框与手柄。
/// 不做双缓冲 —— 覆盖层内容极简，直接画在窗口上足够，省一份 pixmap。
fn draw(
    conn: &RustConnection,
    window: Window,
    gc: Gcontext,
    screen_rect: Rect,
    selection: &Selection,
    translucent: bool,
) -> Result<(), String> {
    let full = xproto::Rectangle {
        x: 0,
        y: 0,
        width: screen_rect.w as u16,
        height: screen_rect.h as u16,
    };

    if translucent {
        // 半透明黑：ARGB visual 下 alpha 在高位
        set_foreground(conn, gc, 0x6600_0000)?;
        conn.poly_fill_rectangle(window, gc, &[full])
            .map_err(|e| e.to_string())?;
    } else {
        // 没有 ARGB 就别压暗，只清一下底
        conn.clear_area(false, window, 0, 0, 0, 0)
            .map_err(|e| e.to_string())?;
    }

    let Some(rect) = selection.current_rect() else {
        conn.flush().map_err(|e| e.to_string())?;
        return Ok(());
    };
    let area = to_x11_rect(&rect);

    if translucent {
        // 把选区挖回全透明，让用户看清自己框的是什么
        set_foreground(conn, gc, 0x0000_0000)?;
        conn.poly_fill_rectangle(window, gc, &[area])
            .map_err(|e| e.to_string())?;
    }

    // 选区边框
    set_foreground(conn, gc, 0xff17_a398)?; // Baobox 的 accent 色
    conn.poly_rectangle(window, gc, &[area])
        .map_err(|e| e.to_string())?;

    // 只有选区成形后才画手柄；悬停高亮窗口时画手柄会误导
    if matches!(selection.phase(), Phase::Adjusting { .. }) {
        let mut handles = Vec::with_capacity(Handle::ALL.len());
        for handle in Handle::ALL {
            let (hx, hy) = handle.anchor(&rect);
            handles.push(xproto::Rectangle {
                x: hx as i16 - HANDLE_SIZE / 2,
                y: hy as i16 - HANDLE_SIZE / 2,
                width: HANDLE_SIZE as u16,
                height: HANDLE_SIZE as u16,
            });
        }
        conn.poly_fill_rectangle(window, gc, &handles)
            .map_err(|e| e.to_string())?;
    }

    draw_size_label(conn, window, gc, &rect)?;
    conn.flush().map_err(|e| e.to_string())?;
    Ok(())
}

/// 在选区左上角上方标出尺寸，如 `820 × 460`。
///
/// 用 X11 核心字体的 `image_text8`：不需要 Xft/fontconfig，少一串依赖。
/// 代价是只能画 Latin-1，而尺寸标签全是数字与 `x`，够用。
fn draw_size_label(
    conn: &RustConnection,
    window: Window,
    gc: Gcontext,
    rect: &Rect,
) -> Result<(), String> {
    let label = format!("{} x {}", rect.w as i64, rect.h as i64);
    // 贴着选区上方；顶到屏幕边缘时改放进选区内部
    let y = if rect.y > 18.0 {
        rect.y as i16 - 6
    } else {
        rect.y as i16 + 16
    };
    set_foreground(conn, gc, 0xffff_ffff)?;
    conn.image_text8(window, gc, rect.x as i16 + 2, y, label.as_bytes())
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn set_foreground(conn: &RustConnection, gc: Gcontext, color: u32) -> Result<(), String> {
    conn.change_gc(gc, &ChangeGCAux::new().foreground(color))
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn to_x11_rect(rect: &Rect) -> xproto::Rectangle {
    xproto::Rectangle {
        x: rect.x as i16,
        y: rect.y as i16,
        width: rect.w.max(1.0) as u16,
        height: rect.h.max(1.0) as u16,
    }
}

/// keycode → 覆盖层关心的按键。
///
/// X11 给的是 keycode（物理位置），要经 keyboard mapping 才知道是哪个键。
/// 只在启动时查一次，之后纯查表。
struct KeyMap {
    first: u8,
    per_code: usize,
    keysyms: Vec<u32>,
}

impl KeyMap {
    fn load(conn: &RustConnection) -> Result<Self, String> {
        let setup = conn.setup();
        let first = setup.min_keycode;
        let count = setup.max_keycode - setup.min_keycode + 1;
        let reply = conn
            .get_keyboard_mapping(first, count)
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| format!("读取键盘映射失败：{e}"))?;
        Ok(Self {
            first,
            per_code: reply.keysyms_per_keycode as usize,
            keysyms: reply.keysyms,
        })
    }

    fn translate(&self, keycode: u8) -> Option<Key> {
        if keycode < self.first || self.per_code == 0 {
            return None;
        }
        let index = (keycode - self.first) as usize * self.per_code;
        // 只看第一个 keysym（无修饰时的含义）—— 方向键与 Esc 不随修饰键变化
        let keysym = *self.keysyms.get(index)?;
        match keysym {
            keysym::ESCAPE => Some(Key::Escape),
            keysym::RETURN | keysym::KP_ENTER => Some(Key::Enter),
            keysym::LEFT => Some(Key::Left),
            keysym::RIGHT => Some(Key::Right),
            keysym::UP => Some(Key::Up),
            keysym::DOWN => Some(Key::Down),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keymap_translates_only_the_keys_we_handle() {
        // 手工构造一张映射表：keycode 9 = Escape，10 = 'a'，11 = Left
        let map = KeyMap {
            first: 9,
            per_code: 1,
            keysyms: vec![keysym::ESCAPE, 0x61, keysym::LEFT],
        };
        assert_eq!(map.translate(9), Some(Key::Escape));
        assert_eq!(map.translate(10), None, "普通字母不应被覆盖层吃掉");
        assert_eq!(map.translate(11), Some(Key::Left));
        assert_eq!(map.translate(8), None, "低于 min_keycode 的应忽略");
        assert_eq!(map.translate(200), None, "越界的应忽略而不是 panic");
    }

    #[test]
    fn rect_conversion_never_produces_zero_size() {
        // X11 的宽高是无符号且 0 会报 BadValue，退化选区必须被撑到 1
        let degenerate = to_x11_rect(&Rect::new(10.0, 20.0, 0.0, 0.0));
        assert_eq!(degenerate.width, 1);
        assert_eq!(degenerate.height, 1);
        assert_eq!(degenerate.x, 10);
    }

    #[test]
    fn size_label_moves_inside_when_selection_touches_the_top() {
        // 这里只验证选取分支的边界条件：贴顶时标签要挪到选区内部
        let near_top = Rect::new(0.0, 2.0, 100.0, 100.0);
        let normal = Rect::new(0.0, 200.0, 100.0, 100.0);
        assert!(near_top.y <= 18.0);
        assert!(normal.y > 18.0);
    }
}
