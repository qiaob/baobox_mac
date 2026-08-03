//! 用 X11 核心字体把标注里的文字画上去。
//!
//! # 为什么不引 Xft
//!
//! Xft/fontconfig 是 C 库，一引进来就得链 libfontconfig + libfreetype，
//! 交叉编译与静态分发都变复杂，而这里只需要「在一个位置画一行字」。
//! X11 核心协议自带的字体机制虽然老，但零依赖、纯协议，`x11rb` 直接支持。
//!
//! # 代价（已知且明确）
//!
//! - 字形取决于 X 服务器装了哪些字体。优先要 `iso10646-1`（Unicode）编码的字体，
//!   这类字体在多数发行版上覆盖 CJK；实在没有就退回 `fixed`，那时只能画 Latin-1。
//! - 没有字距调整、没有复杂文种排版。截图标注写的是短句，够用。
//!
//! # `poly_text` 而不是 `image_text`
//!
//! `image_text8` 会用背景色把整个文字盒子刷一遍 —— 标注要压在截图上，
//! 刷一块底色就把下面的画面盖掉了。`poly_text8` 只画字形本身，背景透过去。
//! 代价是参数要自己按协议编码（长度 + 偏移 + 字节），见 [`encode8`] / [`encode16`]。

use x11rb::connection::Connection;
use x11rb::protocol::xproto::{ChangeGCAux, ConnectionExt as _, Drawable, Font, Gcontext};
use x11rb::rust_connection::RustConnection;

/// 优先尝试的字体，从上到下。前面几个是 Unicode 编码且多数发行版自带的。
const CANDIDATES: [&str; 5] = [
    "-*-*-medium-r-normal--16-*-*-*-*-*-iso10646-1",
    "-*-*-medium-r-*--16-*-*-*-*-*-iso10646-1",
    "-*-*-medium-r-normal--*-*-*-*-*-*-iso10646-1",
    "9x15",
    "fixed",
];

/// 一个打开好的 X11 字体。
pub struct TextFont {
    font: Font,
    /// 基线到字顶的距离 —— `TextDraw` 给的是左上角，X11 要的是基线
    ascent: i16,
    /// 是否是 Unicode 编码的字体（决定用 16 位还是 8 位的画字调用）
    unicode: bool,
}

impl TextFont {
    /// 按 [`CANDIDATES`] 的顺序打开第一个可用的字体。
    ///
    /// 一个都开不出来才返回 `Err` —— 那种情况下 X 服务器基本是坏的。
    pub fn open(conn: &RustConnection) -> Result<Self, String> {
        for (index, name) in CANDIDATES.iter().enumerate() {
            let font = match conn.generate_id() {
                Ok(id) => id,
                Err(e) => return Err(e.to_string()),
            };
            let opened = conn
                .open_font(font, name.as_bytes())
                .ok()
                .and_then(|cookie| cookie.check().ok())
                .is_some();
            if !opened {
                continue;
            }
            let ascent = conn
                .query_font(font)
                .ok()
                .and_then(|cookie| cookie.reply().ok())
                .map(|reply| reply.font_ascent)
                .unwrap_or(12);
            return Ok(Self {
                font,
                ascent,
                // 前三个候选是 iso10646-1，也就是 Unicode 编码
                unicode: index < 3,
            });
        }
        Err("X 服务器里一个可用的字体都没有".to_string())
    }

    /// 在 `drawable` 上画一行字。`(x, y)` 是**左上角**，内部换算成基线。
    ///
    /// 画不出来只是少一行字，不该让整个编辑器失败，所以错误在这里就地吞掉。
    pub fn draw(
        &self,
        conn: &RustConnection,
        drawable: Drawable,
        gc: Gcontext,
        x: i16,
        y: i16,
        text: &str,
    ) {
        if text.is_empty() {
            return;
        }
        if conn
            .change_gc(gc, &ChangeGCAux::new().font(self.font))
            .is_err()
        {
            return;
        }
        let baseline = y.saturating_add(self.ascent);
        if self.unicode {
            let _ = conn.poly_text16(drawable, gc, x, baseline, &encode16(text));
        } else {
            let _ = conn.poly_text8(drawable, gc, x, baseline, &encode8(text));
        }
    }
}

/// 一个 `PolyText` item 最多能带多少个字符。
///
/// 255 被协议征用为「换字体」的转义码，所以上限是 254。
const MAX_PER_ITEM: usize = 254;

/// 把字符串编码成 `PolyText8` 的参数。
///
/// 格式是若干个 item，每个 item = `[字符数, 水平偏移, 字节…]`。
/// 偏移一律为 0：我们一次画一整行，不需要在中途挪位置。
///
/// 非 Latin-1 的字符换成 `?` —— 8 位字体本来就画不了，
/// 与其静默丢字，不如留个明显的占位符让用户知道这里有内容。
pub fn encode8(text: &str) -> Vec<u8> {
    let bytes: Vec<u8> = text
        .chars()
        .map(|c| if (c as u32) < 0x100 { c as u8 } else { b'?' })
        .collect();
    let mut out = Vec::with_capacity(bytes.len() + 2);
    for chunk in bytes.chunks(MAX_PER_ITEM) {
        out.push(chunk.len() as u8);
        out.push(0); // delta
        out.extend_from_slice(chunk);
    }
    out
}

/// 把字符串编码成 `PolyText16` 的参数。
///
/// 与 [`encode8`] 同构，只是每个字符占两个字节且**大端**（X11 协议规定）。
/// BMP 之外的字符（emoji 等）换成 `?`：核心字体机制只认 16 位字符号。
pub fn encode16(text: &str) -> Vec<u8> {
    let chars: Vec<u16> = text
        .chars()
        .map(|c| u16::try_from(c as u32).unwrap_or(b'?' as u16))
        .collect();
    let mut out = Vec::with_capacity(chars.len() * 2 + 2);
    for chunk in chars.chunks(MAX_PER_ITEM) {
        out.push(chunk.len() as u8);
        out.push(0); // delta
        for value in chunk {
            out.extend_from_slice(&value.to_be_bytes());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eight_bit_encoding_carries_length_delta_then_bytes() {
        assert_eq!(encode8("Hi"), vec![2, 0, b'H', b'i']);
        assert!(encode8("").is_empty());
    }

    #[test]
    fn non_latin1_becomes_a_visible_placeholder_not_a_silent_drop() {
        // 8 位字体画不了中文；丢掉会让用户以为文字没保存上
        let encoded = encode8("a中b");
        assert_eq!(encoded, vec![3, 0, b'a', b'?', b'b']);
    }

    #[test]
    fn sixteen_bit_encoding_is_big_endian() {
        // '中' = U+4E2D
        let encoded = encode16("中");
        assert_eq!(encoded, vec![1, 0, 0x4E, 0x2D]);
    }

    #[test]
    fn characters_beyond_the_bmp_fall_back_rather_than_wrapping_around() {
        // U+1F600 截断成 16 位会变成别的字，必须换占位符
        let encoded = encode16("\u{1F600}");
        assert_eq!(encoded, vec![1, 0, 0x00, b'?']);
    }

    #[test]
    fn long_strings_split_into_items_of_at_most_254() {
        // 255 是协议里的换字体转义码，一个 item 塞 255 个字符会被解释成换字体
        let long = "a".repeat(600);
        let encoded = encode8(&long);
        // 254 + 254 + 92，每段两字节头
        assert_eq!(encoded.len(), 600 + 3 * 2);
        assert_eq!(encoded[0], 254);
        assert_eq!(encoded[256], 254);
        assert_eq!(encoded[512], 92);

        let wide = encode16(&"中".repeat(300));
        assert_eq!(wide[0], 254);
        assert_eq!(wide[254 * 2 + 2], 46);
    }
}
