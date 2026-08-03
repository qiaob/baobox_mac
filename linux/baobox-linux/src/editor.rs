//! X11 标注编辑器窗口。
//!
//! 截完图先进这里：画框、打码、写字，然后复制 / 保存 / 贴图 / 丢弃。
//!
//! **交互规则一行都不在这里** —— 全部来自 `baobox_core::editor::Editor`，
//! 图形的光栅化来自 `baobox_render`，工具条的位置来自 `baobox_core::toolbar`。
//! 这个文件只干四件事：把 X11 事件翻译成编辑器的输入、把编辑器的状态合成一张 RGBA、
//! 把它送进 X 服务器、结束时把最终图像取回来。
//!
//! # 一块像素，既是看到的也是保存的
//!
//! 合成结果先 `put_image` 进一个 **Pixmap**，文字用核心字体画在同一个 Pixmap 上，
//! 然后 `copy_area` 给窗口显示。导出时再对着同样的流程做一遍（只是不画工具条），
//! 用 `get_image` 把 Pixmap 读回来。
//!
//! 这样「屏幕上看到的」和「存进 PNG 的」走的是同一条渲染路径 ——
//! 如果分成两套（屏幕上用 X11 画字、导出时用别的方式），文字迟早会对不上位置。
//!
//! # 已知限制
//!
//! 文字输入**不接 XIM**，所以中文输入法在这里用不了，只能打键盘直接产生的字符。
//! 接 XIM 需要 libX11 的 C 接口（`Xutf8LookupString`），与本实现「纯 Rust 协议层」
//! 的取舍冲突。Windows 侧走 `WM_CHAR`，没有这个问题。

use crate::text::TextFont;
use baobox_core::editor::{Editor, EditorKey, EditorOutcome, Modifiers};
use baobox_core::geometry::Rect;
use baobox_render::chrome::{draw_toolbar, ToolbarState};
use baobox_render::Canvas;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    self, ChangeGCAux, ConnectionExt as _, CreateGCAux, CreateWindowAux, Drawable, EventMask,
    Gcontext, GrabMode, ImageFormat, ImageOrder, Pixmap, Screen, Window, WindowClass,
};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;
use x11rb::COPY_DEPTH_FROM_PARENT;

/// 图像之外的区域（工具条脚下那一圈）的底色。
const BACKDROP: [u8; 4] = [0x16, 0x18, 0x1B, 0xFF];

/// 编辑器的最终产物。
pub struct EditorResult {
    /// 用户选了哪个出口
    pub outcome: EditorOutcome,
    /// 带标注的最终图像（RGBA8）
    pub rgba: Vec<u8>,
    /// 宽
    pub width: u32,
    /// 高
    pub height: u32,
}

/// 打开编辑器，跑到用户按下某个出口为止。
///
/// `image` 是截图在屏幕坐标里的位置，`rgba` 是它的像素。
pub fn run(
    conn: &RustConnection,
    screen: &Screen,
    screen_rect: Rect,
    image: Rect,
    rgba: Vec<u8>,
) -> Result<EditorResult, String> {
    let depth = screen.root_depth;
    let bits = bits_per_pixel(conn, depth)?;
    if bits != 32 {
        return Err(format!(
            "标注编辑需要 32 位像素格式，当前显示是 {bits} 位。可以用 --no-edit 直接出图。"
        ));
    }
    let msb_first = conn.setup().image_byte_order == ImageOrder::MSB_FIRST;

    let mut editor = Editor::new(image, screen_rect);
    // 窗口要同时盖住图像和它的工具条
    let frame = image.union(&editor.toolbar().frame).clamped_to(&screen_rect);
    let (fw, fh) = (frame.w.round() as u16, frame.h.round() as u16);

    let window = create_window(conn, screen, &frame)?;
    let gc = create_gc(conn, window)?;
    let pixmap = conn.generate_id().map_err(|e| e.to_string())?;
    conn.create_pixmap(depth, pixmap, window, fw, fh)
        .map_err(|e| format!("创建离屏缓冲失败：{e}"))?;

    let font = TextFont::open(conn).ok();
    let keymap = KeyMap::load(conn)?;
    grab_input(conn, window);

    let outcome = event_loop(
        conn, window, pixmap, gc, &mut editor, &frame, &rgba, image, font.as_ref(), &keymap,
        msb_first, depth,
    );

    // 先撤掉窗口，再导出 —— 导出走的是离屏 Pixmap，与窗口无关，
    // 但用户按下按钮后窗口应立刻消失，不该等导出算完
    ungrab_input(conn);
    let _ = conn.destroy_window(window);
    let _ = conn.flush();

    let outcome = outcome?;
    let exported = if outcome == EditorOutcome::Cancel {
        // 取消不需要导出，省一次全图合成
        (rgba, image.w.round() as u32, image.h.round() as u32)
    } else {
        export(
            conn, gc, screen, depth, &editor, &rgba, image, font.as_ref(), msb_first,
        )?
    };
    let _ = conn.free_pixmap(pixmap);
    let _ = conn.free_gc(gc);
    let _ = conn.flush();

    Ok(EditorResult {
        outcome,
        rgba: exported.0,
        width: exported.1,
        height: exported.2,
    })
}

#[allow(clippy::too_many_arguments)]
fn event_loop(
    conn: &RustConnection,
    window: Window,
    pixmap: Pixmap,
    gc: Gcontext,
    editor: &mut Editor,
    frame: &Rect,
    base: &[u8],
    image: Rect,
    font: Option<&TextFont>,
    keymap: &KeyMap,
    msb_first: bool,
    depth: u8,
) -> Result<EditorOutcome, String> {
    redraw(conn, window, pixmap, gc, editor, frame, base, image, font, msb_first, depth)?;
    loop {
        if let Some(outcome) = editor.outcome() {
            return Ok(outcome);
        }
        let event = conn
            .wait_for_event()
            .map_err(|e| format!("事件循环出错：{e}"))?;
        match event {
            Event::Expose(_) => {}
            Event::MotionNotify(motion) => editor.mouse_moved(to_screen(frame, motion.event_x, motion.event_y)),
            Event::ButtonPress(press) => match press.detail {
                1 => editor.mouse_down(to_screen(frame, press.event_x, press.event_y)),
                // 右键取消，与截图覆盖层一致
                3 => editor.key_down(EditorKey::Escape, Modifiers::NONE),
                _ => {}
            },
            Event::ButtonRelease(release) => {
                if release.detail == 1 {
                    editor.mouse_up(to_screen(frame, release.event_x, release.event_y));
                }
            }
            Event::KeyPress(key) => {
                let modifiers = Modifiers {
                    ctrl: key.state.contains(xproto::KeyButMask::CONTROL),
                    shift: key.state.contains(xproto::KeyButMask::SHIFT),
                };
                let keysym = keymap.keysym(key.detail, modifiers.shift);
                match command_for(keysym, modifiers.ctrl, editor.pending_text().is_some()) {
                    Some(mapped) => editor.key_down(mapped, modifiers),
                    None => {
                        // 带 Ctrl 的是快捷键，不是打字
                        if !modifiers.ctrl {
                            if let Some(character) = keysym.and_then(character_for) {
                                editor.type_char(character);
                            }
                        }
                    }
                }
            }
            _ => continue,
        }
        redraw(conn, window, pixmap, gc, editor, frame, base, image, font, msb_first, depth)?;
    }
}

/// 客户区坐标 → 屏幕坐标。编辑器状态机一律用屏幕坐标。
fn to_screen(frame: &Rect, x: i16, y: i16) -> (f64, f64) {
    (frame.x + x as f64, frame.y + y as f64)
}

/// 合成一帧并显示。
#[allow(clippy::too_many_arguments)]
fn redraw(
    conn: &RustConnection,
    window: Window,
    pixmap: Pixmap,
    gc: Gcontext,
    editor: &Editor,
    frame: &Rect,
    base: &[u8],
    image: Rect,
    font: Option<&TextFont>,
    msb_first: bool,
    depth: u8,
) -> Result<(), String> {
    let (fw, fh) = (frame.w.round() as usize, frame.h.round() as usize);
    let mut pixels = compose(frame, base, image);
    let texts = draw_annotations(&mut pixels, fw, fh, editor, frame, true);

    upload_rgba(conn, pixmap, gc, fw, fh, &pixels, msb_first, depth)?;
    if let Some(font) = font {
        for text in &texts {
            let _ = conn.change_gc(gc, &ChangeGCAux::new().foreground(text.1));
            font.draw(conn, pixmap, gc, text.2, text.3, &text.0);
        }
    }
    conn.copy_area(pixmap, window, gc, 0, 0, 0, 0, fw as u16, fh as u16)
        .map_err(|e| format!("刷新画面失败：{e}"))?;
    conn.flush().map_err(|e| e.to_string())?;
    Ok(())
}

/// 导出最终图像：只有图像本身，没有工具条也没有底衬。
#[allow(clippy::too_many_arguments)]
fn export(
    conn: &RustConnection,
    gc: Gcontext,
    screen: &Screen,
    depth: u8,
    editor: &Editor,
    base: &[u8],
    image: Rect,
    font: Option<&TextFont>,
    msb_first: bool,
) -> Result<(Vec<u8>, u32, u32), String> {
    let (iw, ih) = (image.w.round() as usize, image.h.round() as usize);
    let mut pixels = compose(&image, base, image);
    let texts = draw_annotations(&mut pixels, iw, ih, editor, &image, false);

    // 没有文字就不必绕一趟 X 服务器 —— 直接把合成结果交出去
    if texts.is_empty() || font.is_none() {
        return Ok((pixels, iw as u32, ih as u32));
    }

    // 有文字：借一块 Pixmap 让 X 把字画上，再读回来
    let pixmap = conn.generate_id().map_err(|e| e.to_string())?;
    conn.create_pixmap(depth, pixmap, screen.root, iw as u16, ih as u16)
        .map_err(|e| format!("创建导出缓冲失败：{e}"))?;
    upload_rgba(conn, pixmap, gc, iw, ih, &pixels, msb_first, depth)?;
    if let Some(font) = font {
        for text in &texts {
            let _ = conn.change_gc(gc, &ChangeGCAux::new().foreground(text.1));
            font.draw(conn, pixmap, gc, text.2, text.3, &text.0);
        }
    }
    let read = conn
        .get_image(ImageFormat::Z_PIXMAP, pixmap, 0, 0, iw as u16, ih as u16, !0)
        .map_err(|e| e.to_string())?
        .reply()
        .map_err(|e| format!("读回导出缓冲失败：{e}"))?;
    let _ = conn.free_pixmap(pixmap);
    let rgba = crate::x11capture::to_rgba(&read.data, iw, ih, read.depth)?;
    Ok((rgba, iw as u32, ih as u32))
}

/// 铺底 + 把原图贴到它在 `frame` 里的位置。
fn compose(frame: &Rect, base: &[u8], image: Rect) -> Vec<u8> {
    let (fw, fh) = (frame.w.round() as usize, frame.h.round() as usize);
    let (iw, ih) = (image.w.round() as usize, image.h.round() as usize);
    let mut pixels = Vec::with_capacity(fw * fh * 4);
    for _ in 0..(fw * fh) {
        pixels.extend_from_slice(&BACKDROP);
    }

    // 原图贴到它在窗口里的位置
    let offset_x = (image.x - frame.x).round() as isize;
    let offset_y = (image.y - frame.y).round() as isize;
    for row in 0..ih {
        let target_y = offset_y + row as isize;
        if target_y < 0 || target_y as usize >= fh {
            continue;
        }
        for column in 0..iw {
            let target_x = offset_x + column as isize;
            if target_x < 0 || target_x as usize >= fw {
                continue;
            }
            let source = (row * iw + column) * 4;
            let target = (target_y as usize * fw + target_x as usize) * 4;
            if source + 4 <= base.len() {
                pixels[target..target + 4].copy_from_slice(&base[source..source + 4]);
            }
        }
    }
    pixels
}

/// 把标注（和可选的工具条）画进已经铺好底的缓冲，返回还需要用字体补画的文字。
///
/// 返回值是 `(内容, X11 前景色, x, y)` —— 位置已经换算成缓冲内坐标。
fn draw_annotations(
    pixels: &mut [u8],
    width: usize,
    height: usize,
    editor: &Editor,
    frame: &Rect,
    with_toolbar: bool,
) -> Vec<(String, u32, i16, i16)> {
    let Some(mut canvas) = Canvas::new(width, height, pixels) else {
        return Vec::new();
    };

    // 标注的坐标是屏幕坐标，画布原点在 frame 左上角 —— 先平移
    let shapes: Vec<_> = editor
        .visible_shapes()
        .into_iter()
        .map(|mut shape| {
            for point in &mut shape.points {
                point.0 -= frame.x;
                point.1 -= frame.y;
            }
            shape
        })
        .collect();
    let texts = baobox_render::render(&shapes, &mut canvas);

    // 工具条只在窗口里画，导出时不要 —— 否则存下来的图上会印着一条工具条
    if with_toolbar {
        let mut toolbar = editor.toolbar().clone();
        toolbar.frame = toolbar.frame.offset(-frame.x, -frame.y);
        for button in &mut toolbar.buttons {
            button.frame = button.frame.offset(-frame.x, -frame.y);
        }
        draw_toolbar(
            &mut canvas,
            &toolbar,
            &ToolbarState {
                tool: editor.tool(),
                color_index: editor.color_index(),
                can_undo: editor.can_undo(),
                can_redo: editor.can_redo(),
                hovered: editor.toolbar().hit(editor.cursor()),
            },
        );
    }

    texts
        .into_iter()
        .map(|text| {
            let color = ((text.color.r as u32) << 16)
                | ((text.color.g as u32) << 8)
                | text.color.b as u32;
            (text.text, color, text.x as i16, text.y as i16)
        })
        .collect()
}

/// 把 RGBA 缓冲送进一个 Drawable（窗口或 Pixmap 都行）。
///
/// **必须分片**：X11 单个请求的长度有上限（`maximum_request_length`），
/// 一整屏 4K 图像远远超过，不分片会直接被服务器拒掉。
///
/// 贴图窗口也用它，所以是 `pub`。
#[allow(clippy::too_many_arguments)]
pub fn upload_rgba(
    conn: &RustConnection,
    drawable: Drawable,
    gc: Gcontext,
    width: usize,
    height: usize,
    rgba: &[u8],
    msb_first: bool,
    depth: u8,
) -> Result<(), String> {
    if width == 0 || height == 0 {
        return Ok(());
    }
    let stride = width * 4;
    let rows_per_chunk = max_rows(conn, stride);

    let mut row = 0usize;
    while row < height {
        let rows = rows_per_chunk.min(height - row);
        let start = row * stride;
        let end = start + rows * stride;
        if end > rgba.len() {
            break;
        }
        let data = to_x11_pixels(&rgba[start..end], msb_first);
        conn.put_image(
            ImageFormat::Z_PIXMAP,
            drawable,
            gc,
            width as u16,
            rows as u16,
            0,
            row as i16,
            0,
            depth,
            &data,
        )
        .map_err(|e| format!("上传像素失败：{e}"))?;
        row += rows;
    }
    Ok(())
}

/// 一个 `PutImage` 请求最多能带多少行。
///
/// `maximum_request_length` 的单位是 4 字节；扣掉请求头（`PutImage` 是 24 字节，
/// 这里留 64 字节余量）之后除以每行字节数。至少给 1 行 —— 否则一行像素都传不出去。
fn max_rows(conn: &RustConnection, stride: usize) -> usize {
    let limit = conn.setup().maximum_request_length as usize * 4;
    let usable = limit.saturating_sub(64);
    (usable / stride.max(1)).max(1)
}

/// RGBA → X11 的 Z_PIXMAP 字节序。
///
/// 小端机器（绝大多数）上是 BGRX，大端机器上是 XRGB。搞反了整张图会偏蓝或偏红。
fn to_x11_pixels(rgba: &[u8], msb_first: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(rgba.len());
    for pixel in rgba.chunks_exact(4) {
        if msb_first {
            out.extend_from_slice(&[0, pixel[0], pixel[1], pixel[2]]);
        } else {
            out.extend_from_slice(&[pixel[2], pixel[1], pixel[0], 0]);
        }
    }
    out
}

/// 查这个色深下每个像素占多少位。深度 24 通常是 32 位（多一个填充字节）。
fn bits_per_pixel(conn: &RustConnection, depth: u8) -> Result<u8, String> {
    conn.setup()
        .pixmap_formats
        .iter()
        .find(|format| format.depth == depth)
        .map(|format| format.bits_per_pixel)
        .ok_or_else(|| format!("X 服务器没有报告 {depth} 位色深的像素格式"))
}

fn create_window(conn: &RustConnection, screen: &Screen, frame: &Rect) -> Result<Window, String> {
    let window = conn.generate_id().map_err(|e| e.to_string())?;
    let aux = CreateWindowAux::new()
        .background_pixel(0x0016_181B)
        .override_redirect(1)
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
        frame.x as i16,
        frame.y as i16,
        frame.w.round() as u16,
        frame.h.round() as u16,
        0,
        WindowClass::INPUT_OUTPUT,
        x11rb::COPY_FROM_PARENT,
        &aux,
    )
    .map_err(|e| format!("创建编辑器窗口失败：{e}"))?;
    conn.map_window(window).map_err(|e| e.to_string())?;
    conn.flush().map_err(|e| e.to_string())?;
    Ok(window)
}

fn create_gc(conn: &RustConnection, window: Window) -> Result<Gcontext, String> {
    let gc = conn.generate_id().map_err(|e| e.to_string())?;
    conn.create_gc(gc, window, &CreateGCAux::new())
        .map_err(|e| format!("创建 GC 失败：{e}"))?;
    Ok(gc)
}

fn grab_input(conn: &RustConnection, window: Window) {
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
    let _ = conn.flush();
}

fn ungrab_input(conn: &RustConnection) {
    let _ = conn.ungrab_pointer(x11rb::CURRENT_TIME);
    let _ = conn.ungrab_keyboard(x11rb::CURRENT_TIME);
}

/// 这一下按键算不算命令。返回 `None` 表示「当成一个字符打进去」。
///
/// # 为什么不能只看 keysym
///
/// `z` 既是「Ctrl+Z 撤销」的一半，也是一个能打进文字标注里的字母。
/// 只按 keysym 判断的话，用户在文字工具里永远打不出 z / y / c / s / `[` / `]`
/// —— 按下去被当成命令吃掉，而那些命令在没有 Ctrl 时又什么都不做。
///
/// 所以要看两个上下文：
///
/// - 按着 Ctrl：一律当命令（Ctrl+Z / Ctrl+C 之类）
/// - 正在输入文字：只有 Esc / ⏎ / 退格是命令，其余全是字符
/// - 没在输入文字：整套命令都生效（`[` `]` 调线宽等）
fn command_for(keysym: Option<u32>, ctrl: bool, typing: bool) -> Option<EditorKey> {
    let key = keysym?;
    // 这三个在任何状态下都是命令 —— 它们本来也打不出字符
    let always = match key {
        0xff1b => Some(EditorKey::Escape),
        0xff0d | 0xff8d => Some(EditorKey::Enter),
        0xff08 => Some(EditorKey::Backspace),
        _ => None,
    };
    if always.is_some() {
        return always;
    }
    if typing && !ctrl {
        return None;
    }
    match key {
        0x7a | 0x5a => Some(EditorKey::Z),
        0x79 | 0x59 => Some(EditorKey::Y),
        0x63 | 0x43 => Some(EditorKey::C),
        0x73 | 0x53 => Some(EditorKey::S),
        // `[` `]` 调线宽，只在没打字时有意义
        0x5b if !typing => Some(EditorKey::BracketLeft),
        0x5d if !typing => Some(EditorKey::BracketRight),
        _ => None,
    }
}

/// keysym → 字符。
///
/// Latin-1 区间的 keysym 数值就是字符本身；`0x0100_0000` 之上的是
/// 「Unicode 码点 + 0x01000000」，这是 X11 给非 Latin 键定的编码方式。
fn character_for(keysym: u32) -> Option<char> {
    if (0x20..0x7f).contains(&keysym) || (0xa0..0x100).contains(&keysym) {
        return char::from_u32(keysym);
    }
    if keysym >= 0x0100_0000 {
        return char::from_u32(keysym - 0x0100_0000);
    }
    None
}

/// keycode → keysym 的查表。与覆盖层那份是同一件事，但这里要区分是否按住 Shift。
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

    /// 取这个键在当前 Shift 状态下的 keysym。
    ///
    /// 每个 keycode 有一组 keysym，第 0 个是无修饰、第 1 个是按住 Shift。
    /// 按住 Shift 但那一格是空的（很多功能键如此）时退回第 0 个。
    fn keysym(&self, keycode: u8, shift: bool) -> Option<u32> {
        if keycode < self.first || self.per_code == 0 {
            return None;
        }
        let base = (keycode - self.first) as usize * self.per_code;
        let shifted = if shift && self.per_code > 1 {
            self.keysyms.get(base + 1).copied().filter(|k| *k != 0)
        } else {
            None
        };
        shifted.or_else(|| self.keysyms.get(base).copied()).filter(|k| *k != 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pixels_are_byte_swapped_for_the_servers_endianness() {
        let rgba = [10u8, 20, 30, 255];
        // 小端：BGRX
        assert_eq!(to_x11_pixels(&rgba, false), vec![30, 20, 10, 0]);
        // 大端：XRGB
        assert_eq!(to_x11_pixels(&rgba, true), vec![0, 10, 20, 30]);
    }

    #[test]
    fn commands_are_recognised_when_nothing_is_being_typed() {
        let idle = |k: u32| command_for(Some(k), false, false);
        assert_eq!(idle(0xff1b), Some(EditorKey::Escape));
        assert_eq!(idle(0xff08), Some(EditorKey::Backspace));
        assert_eq!(idle(0x7a), Some(EditorKey::Z));
        assert_eq!(idle(0x5a), Some(EditorKey::Z), "大写也算");
        assert_eq!(idle(0x5b), Some(EditorKey::BracketLeft));
        assert_eq!(idle(0x61), None, "'a' 不是功能键");
        assert_eq!(command_for(None, false, false), None);
    }

    #[test]
    fn typing_a_letter_that_is_also_a_shortcut_still_types_it() {
        // 这是个真实存在过的 bug：文字标注里打不出 z / y / c / s / [ / ]，
        // 因为它们被当成命令吃掉了，而那些命令没有 Ctrl 时又什么都不做
        for key in [0x7a, 0x79, 0x63, 0x73, 0x5b, 0x5d] {
            assert_eq!(
                command_for(Some(key), false, true),
                None,
                "正在打字时 0x{key:x} 应当是个字符，不是命令"
            );
        }
        // 但按着 Ctrl 时仍然是快捷键 —— 打字途中也要能撤销
        assert_eq!(command_for(Some(0x7a), true, true), Some(EditorKey::Z));
        // Esc / ⏎ / 退格在打字时仍是命令，否则文字没法落定也没法删字
        assert_eq!(command_for(Some(0xff1b), false, true), Some(EditorKey::Escape));
        assert_eq!(command_for(Some(0xff0d), false, true), Some(EditorKey::Enter));
        assert_eq!(command_for(Some(0xff08), false, true), Some(EditorKey::Backspace));
    }

    #[test]
    fn latin1_and_unicode_keysyms_both_become_characters() {
        assert_eq!(character_for(0x61), Some('a'));
        assert_eq!(character_for(0x20), Some(' '));
        assert_eq!(character_for(0xe9), Some('é'));
        // U+4E2D 的 X11 keysym 编码
        assert_eq!(character_for(0x0100_4e2d), Some('中'));
        // 功能键不该被当成字符打进去
        assert_eq!(character_for(0xff1b), None);
        assert_eq!(character_for(0xffbe), None);
    }

    #[test]
    fn shift_picks_the_second_keysym_and_falls_back_when_it_is_empty() {
        let map = KeyMap {
            first: 8,
            per_code: 2,
            // keycode 8: 'a'/'A'；keycode 9: Escape，第二格为空
            keysyms: vec![0x61, 0x41, 0xff1b, 0],
        };
        assert_eq!(map.keysym(8, false), Some(0x61));
        assert_eq!(map.keysym(8, true), Some(0x41));
        assert_eq!(map.keysym(9, true), Some(0xff1b), "第二格为空时退回第一格");
        assert_eq!(map.keysym(7, false), None, "低于 min_keycode 的应忽略");
        assert_eq!(map.keysym(200, false), None, "越界的应忽略而不是 panic");
    }

    #[test]
    fn composing_puts_the_image_where_it_belongs_and_backfills_the_rest() {
        // 图像 2×2 全红，窗口 4×4 —— 图像在 (1,1)
        let base = vec![255u8, 0, 0, 255].repeat(4);
        let image = Rect::new(11.0, 21.0, 2.0, 2.0);
        let frame = Rect::new(10.0, 20.0, 4.0, 4.0);
        let pixels = compose(&frame, &base, image);

        assert_eq!(pixels.len(), 4 * 4 * 4);
        // (0,0) 是底衬
        assert_eq!(&pixels[0..4], &BACKDROP);
        // (1,1) 是图像的第一个像素
        let at = (1 * 4 + 1) * 4;
        assert_eq!(&pixels[at..at + 4], &[255, 0, 0, 255]);
        // (3,3) 在图像外，仍是底衬
        let corner = (3 * 4 + 3) * 4;
        assert_eq!(&pixels[corner..corner + 4], &BACKDROP);
    }

    #[test]
    fn an_image_hanging_off_the_frame_is_clipped_not_panicking() {
        // 图像左上角在窗口之外
        let base = vec![9u8; 4 * 4 * 4];
        let image = Rect::new(0.0, 0.0, 4.0, 4.0);
        let frame = Rect::new(2.0, 2.0, 4.0, 4.0);
        let pixels = compose(&frame, &base, image);
        assert_eq!(pixels.len(), 4 * 4 * 4);
    }
}
