//! X11 抓屏与窗口枚举。
//!
//! 对应 macOS 侧的 `CaptureEngine`（ScreenCaptureKit）与 `WindowDetector`。
//! 用纯 Rust 的 `x11rb` 而不是绑定 libX11：少一个 C 依赖，交叉编译也简单。
//!
//! # 关于 Wayland
//!
//! 这条路只覆盖 X11 与 XWayland。原生 Wayland 会话下客户端**无权直接抓屏**，
//! 必须走 `xdg-desktop-portal` 的 ScreenCast 接口（DBus + PipeWire），
//! 那是另一套完全不同的实现。`is_wayland_session()` 用来提前识别并给出明确提示，
//! 而不是让用户拿到一张全黑的图。

use baobox_core::geometry::Rect;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    AtomEnum, ConnectionExt as _, ImageFormat, Window,
};
use x11rb::rust_connection::RustConnection;

/// 一块屏幕 / 一个窗口的抓取结果，像素为 RGBA8。
pub struct Capture {
    /// 宽（像素）
    pub width: u32,
    /// 高（像素）
    pub height: u32,
    /// RGBA8 像素，长度 = width * height * 4
    pub rgba: Vec<u8>,
}

/// 一个可见的顶层窗口。
#[derive(Debug, Clone)]
pub struct WindowInfo {
    /// X11 窗口 id
    pub id: u32,
    /// 屏幕坐标下的位置与尺寸
    pub frame: Rect,
    /// 窗口标题（取不到时为空串）
    pub title: String,
}

/// 当前是否是原生 Wayland 会话（此时 X11 抓屏拿不到别的窗口）。
pub fn is_wayland_session() -> bool {
    std::env::var("XDG_SESSION_TYPE")
        .map(|v| v.eq_ignore_ascii_case("wayland"))
        .unwrap_or(false)
        || std::env::var("WAYLAND_DISPLAY").is_ok()
}

/// 一个已连接的 X11 会话。
pub struct X11Session {
    conn: RustConnection,
    root: Window,
    /// `conn.setup().roots` 里的下标
    screen_num: usize,
    /// 整个虚拟屏幕（所有显示器合起来）的范围
    screen: Rect,
}

impl X11Session {
    /// 连接到 `$DISPLAY`。
    pub fn open() -> Result<Self, String> {
        let (conn, screen_num) = x11rb::connect(None).map_err(|e| {
            format!(
                "无法连接 X 服务器（$DISPLAY={}）：{e}",
                std::env::var("DISPLAY").unwrap_or_else(|_| "未设置".into())
            )
        })?;
        let setup = conn.setup();
        let screen = &setup.roots[screen_num];
        let root = screen.root;
        let rect = Rect::new(
            0.0,
            0.0,
            screen.width_in_pixels as f64,
            screen.height_in_pixels as f64,
        );
        Ok(Self {
            conn,
            root,
            screen_num,
            screen: rect,
        })
    }

    /// 整个虚拟屏幕的范围。
    pub fn screen_rect(&self) -> Rect {
        self.screen
    }

    /// 底层连接，供覆盖层复用（不另开一条连接：抓取与覆盖层必须看到同一份服务器状态）。
    pub fn connection(&self) -> &RustConnection {
        &self.conn
    }

    /// 当前屏幕的 setup 信息（覆盖层建窗要用它的 visual 与 colormap）。
    pub fn screen(&self) -> &x11rb::protocol::xproto::Screen {
        &self.conn.setup().roots[self.screen_num]
    }

    /// 建一个不映射的小窗口，用来持有剪贴板 selection。
    ///
    /// X11 的剪贴板所有权必须挂在某个窗口上，而覆盖层那会儿已经销毁了，
    /// 所以这里单开一个"隐形"窗口专门干这件事。
    pub fn create_owner_window(&self) -> Result<Window, String> {
        let window = self.conn.generate_id().map_err(|e| e.to_string())?;
        self.conn
            .create_window(
                x11rb::COPY_DEPTH_FROM_PARENT,
                window,
                self.root,
                0,
                0,
                1,
                1,
                0,
                x11rb::protocol::xproto::WindowClass::INPUT_OUTPUT,
                x11rb::COPY_FROM_PARENT,
                &x11rb::protocol::xproto::CreateWindowAux::new()
                    .override_redirect(1)
                    .event_mask(x11rb::protocol::xproto::EventMask::PROPERTY_CHANGE),
            )
            .map_err(|e| format!("创建剪贴板宿主窗口失败：{e}"))?;
        self.conn.flush().map_err(|e| e.to_string())?;
        Ok(window)
    }

    /// 抓一块区域。区域会先裁进屏幕范围 —— 越界的请求在 X11 上会直接报错，
    /// 而用户拖出屏幕边缘是很常见的操作，不该因此失败。
    pub fn capture(&self, region: Rect) -> Result<Capture, String> {
        let clamped = region.clamped_to(&self.screen);
        let (x, y) = (clamped.x.round() as i16, clamped.y.round() as i16);
        let (w, h) = (clamped.w.round() as u16, clamped.h.round() as u16);
        if w == 0 || h == 0 {
            return Err("选区为空".to_string());
        }

        let reply = self
            .conn
            .get_image(ImageFormat::Z_PIXMAP, self.root, x, y, w, h, !0)
            .map_err(|e| format!("发起抓屏请求失败：{e}"))?
            .reply()
            .map_err(|e| format!("抓屏失败：{e}"))?;

        let rgba = to_rgba(&reply.data, w as usize, h as usize, reply.depth)?;
        Ok(Capture {
            width: w as u32,
            height: h as u32,
            rgba,
        })
    }

    /// 抓整个屏幕。
    pub fn capture_screen(&self) -> Result<Capture, String> {
        self.capture(self.screen)
    }

    /// 枚举可见的顶层窗口，按 z 序从前到后。
    ///
    /// 读 `_NET_CLIENT_LIST_STACKING`（栈序，前面的在下面），取不到时退回
    /// `_NET_CLIENT_LIST`（EWMH 规定的窗口列表，顺序不保证）。
    pub fn windows(&self) -> Result<Vec<WindowInfo>, String> {
        let ids = self
            .property_windows("_NET_CLIENT_LIST_STACKING")
            .or_else(|_| self.property_windows("_NET_CLIENT_LIST"))
            .unwrap_or_default();

        let mut out = Vec::new();
        // 栈序是从下到上，我们要从前到后 → 反过来
        for id in ids.into_iter().rev() {
            let Ok(geometry) = self.conn.get_geometry(id).and_then(|c| Ok(c.reply())) else {
                continue;
            };
            let Ok(geometry) = geometry else { continue };
            // 换算到屏幕坐标：窗口的 x/y 是相对父窗口的
            let translated = self
                .conn
                .translate_coordinates(id, self.root, 0, 0)
                .ok()
                .and_then(|c| c.reply().ok());
            let (sx, sy) = translated
                .map(|t| (t.dst_x as f64, t.dst_y as f64))
                .unwrap_or((geometry.x as f64, geometry.y as f64));

            out.push(WindowInfo {
                id,
                frame: Rect::new(sx, sy, geometry.width as f64, geometry.height as f64),
                title: self.window_title(id),
            });
        }
        Ok(out)
    }

    /// 读一个存放窗口 id 列表的根窗口属性。
    fn property_windows(&self, name: &str) -> Result<Vec<Window>, String> {
        let atom = self
            .conn
            .intern_atom(false, name.as_bytes())
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| e.to_string())?
            .atom;
        let reply = self
            .conn
            .get_property(false, self.root, atom, AtomEnum::WINDOW, 0, u32::MAX)
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| e.to_string())?;
        reply
            .value32()
            .map(|iter| iter.collect())
            .ok_or_else(|| format!("{name} 不是窗口列表"))
    }

    /// 取窗口标题：优先 `_NET_WM_NAME`（UTF-8），退回 `WM_NAME`。
    fn window_title(&self, window: Window) -> String {
        if let Some(title) = self.utf8_property(window, "_NET_WM_NAME") {
            if !title.is_empty() {
                return title;
            }
        }
        self.conn
            .get_property(false, window, AtomEnum::WM_NAME, AtomEnum::STRING, 0, 1024)
            .ok()
            .and_then(|c| c.reply().ok())
            .map(|r| String::from_utf8_lossy(&r.value).to_string())
            .unwrap_or_default()
    }

    fn utf8_property(&self, window: Window, name: &str) -> Option<String> {
        let atom = self
            .conn
            .intern_atom(false, name.as_bytes())
            .ok()?
            .reply()
            .ok()?
            .atom;
        let utf8 = self
            .conn
            .intern_atom(false, b"UTF8_STRING")
            .ok()?
            .reply()
            .ok()?
            .atom;
        let reply = self
            .conn
            .get_property(false, window, atom, utf8, 0, 1024)
            .ok()?
            .reply()
            .ok()?;
        Some(String::from_utf8_lossy(&reply.value).to_string())
    }
}

/// X11 的 Z_PIXMAP 数据转成 RGBA8。
///
/// 常见深度是 24 与 32，两者在小端机器上的字节序都是 **BGRX / BGRA**。
/// 深度 32 时 alpha 通道**不可信**（很多合成器留的是 0），一律置为不透明 ——
/// 否则截出来的图在预览里整张透明。
pub fn to_rgba(data: &[u8], width: usize, height: usize, depth: u8) -> Result<Vec<u8>, String> {
    let pixels = width * height;
    match depth {
        24 | 32 => {
            if data.len() < pixels * 4 {
                return Err(format!(
                    "像素数据不足：{} 字节，至少需要 {}",
                    data.len(),
                    pixels * 4
                ));
            }
            let mut out = Vec::with_capacity(pixels * 4);
            for chunk in data.chunks_exact(4).take(pixels) {
                out.push(chunk[2]); // R
                out.push(chunk[1]); // G
                out.push(chunk[0]); // B
                out.push(255); // A：X11 的 alpha 不可信，统一不透明
            }
            Ok(out)
        }
        16 => {
            // RGB565，老显示配置下会遇到
            if data.len() < pixels * 2 {
                return Err("像素数据不足（16 位）".to_string());
            }
            let mut out = Vec::with_capacity(pixels * 4);
            for chunk in data.chunks_exact(2).take(pixels) {
                let value = u16::from_le_bytes([chunk[0], chunk[1]]);
                let r = ((value >> 11) & 0x1F) as u8;
                let g = ((value >> 5) & 0x3F) as u8;
                let b = (value & 0x1F) as u8;
                // 位扩展而不是简单左移，避免最亮值达不到 255
                out.push((r << 3) | (r >> 2));
                out.push((g << 2) | (g >> 4));
                out.push((b << 3) | (b >> 2));
                out.push(255);
            }
            Ok(out)
        }
        other => Err(format!("暂不支持 {other} 位色深")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bgrx_becomes_rgba_with_forced_opacity() {
        // 一个像素：B=10 G=20 R=30 X=0
        let data = [10u8, 20, 30, 0];
        let rgba = to_rgba(&data, 1, 1, 24).unwrap();
        assert_eq!(rgba, vec![30, 20, 10, 255]);
    }

    #[test]
    fn depth32_alpha_is_ignored_not_trusted() {
        // alpha 给 0，结果必须仍是不透明 —— 否则整张图在预览里消失
        let data = [10u8, 20, 30, 0];
        let rgba = to_rgba(&data, 1, 1, 32).unwrap();
        assert_eq!(rgba[3], 255);
    }

    #[test]
    fn rgb565_expands_to_full_range() {
        // 全白 0xFFFF 应当扩展成 255,255,255 而不是 248,252,248
        let data = 0xFFFFu16.to_le_bytes();
        let rgba = to_rgba(&data, 1, 1, 16).unwrap();
        assert_eq!(&rgba[..3], &[255, 255, 255]);
    }

    #[test]
    fn rejects_short_buffers_and_odd_depths() {
        assert!(to_rgba(&[0, 0], 4, 4, 24).is_err());
        assert!(to_rgba(&[0; 64], 4, 4, 8).is_err());
    }

    #[test]
    fn wayland_detection_reads_the_environment() {
        // 只验证函数不 panic 且返回布尔 —— 具体取值取决于运行环境
        let _ = is_wayland_session();
    }
}
