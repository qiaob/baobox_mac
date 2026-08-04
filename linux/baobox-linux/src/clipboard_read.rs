//! 读剪贴板，以及在它变化时收到通知。
//!
//! 写剪贴板在 `clipboard.rs`（我们当所有者）；这里是反过来的方向 ——
//! **别人是所有者，我们去要内容**。
//!
//! # 要内容是一次三步的往返
//!
//! X11 没有「读剪贴板」这个操作。流程是：
//!
//! 1. `ConvertSelection`：告诉所有者「把 CLIPBOARD 转成这个格式，放到我窗口的这个属性上」
//! 2. 等所有者回一个 `SelectionNotify`
//! 3. `GetProperty` 把内容读出来，读完删掉属性
//!
//! 所有者不理我们（程序卡死、已经退出）时第 2 步会一直等 —— 所以必须有超时。
//!
//! # 内容大的时候是分片来的
//!
//! 超过一定大小，所有者不会直接给数据，而是给一个 `INCR` 类型的属性，
//! 然后我们每删一次属性它就补下一片，直到给一个空片。截图与长文本
//! 都会走到这条路上，**不实现 INCR 就等于「大内容读不到」**。
//!
//! # 变化通知靠 XFIXES
//!
//! 核心协议没有「剪贴板变了」这个事件，所以传统做法是定时轮询
//! （`xclip` 之类都这么干）。XFIXES 扩展提供了
//! `SelectionNotify` 事件，服务器在所有者变更时主动告诉我们 ——
//! 不轮询、不漏、也不浪费 CPU。这个扩展在现代 X 服务器上必有。

use x11rb::connection::Connection;
use x11rb::protocol::xfixes::{self, ConnectionExt as _, SelectionEventMask};
use x11rb::protocol::xproto::{
    Atom, AtomEnum, ConnectionExt as _, CreateWindowAux, EventMask, Property, Window, WindowClass,
};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;
use std::time::{Duration, Instant};

/// 等所有者回应的上限。
///
/// 所有者可能已经卡死或退出，不能无限等。1 秒对本机往返来说非常宽裕，
/// 而用户也不会觉得「复制完过了一会儿才进历史」有什么问题。
const REPLY_TIMEOUT: Duration = Duration::from_secs(1);

/// 单次 `GetProperty` 取多少（32 位字）。1 MiB 一片，够大也不至于撑爆请求。
const CHUNK_WORDS: u32 = 256 * 1024;

/// 剪贴板里读到了什么。
#[derive(Debug, Clone, PartialEq)]
pub enum Content {
    /// 一段文本
    Text(String),
    /// 一张图（PNG 字节）
    Image(Vec<u8>),
    /// 一批文件路径
    Files(Vec<String>),
    /// 剪贴板是空的，或者内容是我们不认的格式
    Nothing,
}

/// 读剪贴板要用到的一堆 atom。
pub struct Atoms {
    clipboard: Atom,
    targets: Atom,
    utf8: Atom,
    png: Atom,
    uri_list: Atom,
    incr: Atom,
    /// 我们自己的属性，内容会被放到这里
    slot: Atom,
}

impl Atoms {
    /// 全部 intern 一遍。
    pub fn load(conn: &RustConnection) -> Result<Self, String> {
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
            utf8: intern("UTF8_STRING")?,
            png: intern("image/png")?,
            uri_list: intern("text/uri-list")?,
            incr: intern("INCR")?,
            slot: intern("BAOBOX_CLIPBOARD")?,
        })
    }
}

/// 一个专门用来收剪贴板内容的隐形窗口。
pub struct Reader {
    window: Window,
    atoms: Atoms,
}

impl Reader {
    /// 建窗口、订阅剪贴板变化。
    pub fn new(conn: &RustConnection, root: Window) -> Result<Self, String> {
        let atoms = Atoms::load(conn)?;
        let window = conn.generate_id().map_err(|e| e.to_string())?;
        conn.create_window(
            x11rb::COPY_DEPTH_FROM_PARENT,
            window,
            root,
            0,
            0,
            1,
            1,
            0,
            WindowClass::INPUT_OUTPUT,
            x11rb::COPY_FROM_PARENT,
            &CreateWindowAux::new()
                .override_redirect(1)
                // 收 INCR 分片要靠属性变更事件
                .event_mask(EventMask::PROPERTY_CHANGE),
        )
        .map_err(|e| format!("创建剪贴板接收窗口失败：{e}"))?;

        // XFIXES：让服务器在剪贴板所有者变化时主动通知我们，不必轮询
        xfixes::query_version(conn, 5, 0)
            .map_err(|e| format!("XFIXES 不可用：{e}"))?
            .reply()
            .map_err(|e| format!("XFIXES 版本协商失败：{e}"))?;
        conn.xfixes_select_selection_input(
            window,
            atoms.clipboard,
            SelectionEventMask::SET_SELECTION_OWNER,
        )
        .map_err(|e| format!("订阅剪贴板变化失败：{e}"))?;
        conn.flush().map_err(|e| e.to_string())?;

        Ok(Self { window, atoms })
    }

    /// 这个事件是「剪贴板变了」吗。
    pub fn is_clipboard_change(&self, event: &Event) -> bool {
        matches!(event, Event::XfixesSelectionNotify(notify)
            if notify.selection == self.atoms.clipboard)
    }

    /// 现在是谁持有剪贴板。
    ///
    /// 调用方拿它去问 `clipboard::is_ours` —— 自己写进去的东西不该再被自己
    /// 记一遍，否则「从历史里粘贴」会把那一条重新推到最前，
    /// 看着像是程序在跟自己较劲。
    pub fn current_owner(&self, conn: &RustConnection) -> Option<Window> {
        let owner = conn
            .get_selection_owner(self.atoms.clipboard)
            .ok()?
            .reply()
            .ok()?
            .owner;
        if owner == x11rb::NONE {
            return None;
        }
        Some(owner)
    }

    /// 把剪贴板内容读出来。
    ///
    /// 先问所有者「你有哪些格式」，再按 图片 → 文件 → 文本 的优先级要一种。
    /// 图片优先是因为很多程序复制图片时会**同时**提供一段说明文字，
    /// 只取文本的话用户会发现「复制的图变成了一串字」。
    pub fn read(&self, conn: &RustConnection) -> Content {
        let targets = self.request_targets(conn);

        if targets.contains(&self.atoms.png) {
            if let Some(bytes) = self.request(conn, self.atoms.png) {
                if !bytes.is_empty() {
                    return Content::Image(bytes);
                }
            }
        }
        if targets.contains(&self.atoms.uri_list) {
            if let Some(bytes) = self.request(conn, self.atoms.uri_list) {
                let paths = parse_uri_list(&String::from_utf8_lossy(&bytes));
                if !paths.is_empty() {
                    return Content::Files(paths);
                }
            }
        }
        for target in [self.atoms.utf8, AtomEnum::STRING.into()] {
            if let Some(bytes) = self.request(conn, target) {
                let text = String::from_utf8_lossy(&bytes).to_string();
                if !text.is_empty() {
                    return Content::Text(text);
                }
            }
        }
        Content::Nothing
    }

    /// 问所有者支持哪些格式。取不到就当成空 —— 那样会退回逐个尝试。
    fn request_targets(&self, conn: &RustConnection) -> Vec<Atom> {
        let Some(bytes) = self.request(conn, self.atoms.targets) else {
            return Vec::new();
        };
        bytes
            .chunks_exact(4)
            .map(|c| u32::from_ne_bytes([c[0], c[1], c[2], c[3]]))
            .collect()
    }

    /// 要一种格式的内容。
    fn request(&self, conn: &RustConnection, target: Atom) -> Option<Vec<u8>> {
        // 先把属性删干净：上一次的残留会让我们把旧内容当成新的
        let _ = conn.delete_property(self.window, self.atoms.slot);
        conn.convert_selection(
            self.window,
            self.atoms.clipboard,
            target,
            self.atoms.slot,
            x11rb::CURRENT_TIME,
        )
        .ok()?;
        conn.flush().ok()?;

        // 等所有者回应。它可能已经卡死或退出，所以必须有超时
        let deadline = Instant::now() + REPLY_TIMEOUT;
        loop {
            if Instant::now() >= deadline {
                return None;
            }
            match conn.poll_for_event().ok()? {
                Some(Event::SelectionNotify(notify)) => {
                    // property = None 表示所有者拒绝提供这个格式
                    if notify.property == x11rb::NONE {
                        return None;
                    }
                    break;
                }
                Some(_) => continue,
                None => std::thread::sleep(Duration::from_millis(5)),
            }
        }

        let reply = conn
            .get_property(
                false,
                self.window,
                self.atoms.slot,
                AtomEnum::ANY,
                0,
                CHUNK_WORDS,
            )
            .ok()?
            .reply()
            .ok()?;

        if reply.type_ == self.atoms.incr {
            return self.read_incrementally(conn);
        }
        let _ = conn.delete_property(self.window, self.atoms.slot);
        Some(reply.value)
    }

    /// 大内容是分片来的：每删一次属性，所有者补下一片，空片表示结束。
    ///
    /// 截图与长文本都会走到这里 —— 不实现它就等于「大内容读不到」。
    fn read_incrementally(&self, conn: &RustConnection) -> Option<Vec<u8>> {
        let mut collected = Vec::new();
        // 删掉 INCR 那个属性，所有者会开始送第一片
        let _ = conn.delete_property(self.window, self.atoms.slot);
        let _ = conn.flush();

        let deadline = Instant::now() + REPLY_TIMEOUT * 30;
        loop {
            if Instant::now() >= deadline {
                // 送到一半断了：宁可把已经拿到的丢掉，也不要交出半张图
                return None;
            }
            match conn.poll_for_event().ok()? {
                Some(Event::PropertyNotify(notify))
                    if notify.window == self.window
                        && notify.atom == self.atoms.slot
                        && notify.state == Property::NEW_VALUE =>
                {
                    let reply = conn
                        .get_property(
                            true, // 读完即删，这也是在跟所有者要下一片
                            self.window,
                            self.atoms.slot,
                            AtomEnum::ANY,
                            0,
                            CHUNK_WORDS,
                        )
                        .ok()?
                        .reply()
                        .ok()?;
                    if reply.value.is_empty() {
                        return Some(collected);
                    }
                    collected.extend_from_slice(&reply.value);
                }
                Some(_) => continue,
                None => std::thread::sleep(Duration::from_millis(5)),
            }
        }
    }
}

/// `text/uri-list` → 本地路径。
///
/// 只留 `file://` 的：拖来的 http 链接不是文件，当成文件路径会误导。
pub fn parse_uri_list(text: &str) -> Vec<String> {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .filter_map(|line| line.strip_prefix("file://"))
        .map(|rest| {
            // 有的程序会带主机名（`file://localhost/path`），去掉它
            let path = match rest.strip_prefix("localhost") {
                Some(stripped) => stripped,
                None => rest,
            };
            percent_decode_path(path)
        })
        .filter(|path| !path.is_empty())
        .collect()
}

/// 路径里的百分号编码要还原，否则带空格或中文的文件名会是一串 `%20`。
///
/// 用 `percent_decode_path` 而不是 `percent_decode`：后者把 `+` 当成空格
/// （那是 query 的规矩），拿去解 `c++.txt` 会得到一个不存在的文件名。
fn percent_decode_path(path: &str) -> String {
    baobox_core::textformat::percent_decode_path(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uri_lists_become_local_paths() {
        let text = "file:///home/me/a.txt\r\nfile:///home/me/b.png\r\n";
        assert_eq!(
            parse_uri_list(text),
            vec!["/home/me/a.txt", "/home/me/b.png"]
        );
    }

    #[test]
    fn percent_escapes_in_paths_are_decoded() {
        // 带空格或中文的文件名不解码的话会是一串 %20
        assert_eq!(
            parse_uri_list("file:///home/me/my%20file.txt"),
            vec!["/home/me/my file.txt"]
        );
        assert_eq!(
            parse_uri_list("file:///home/me/%E4%B8%AD%E6%96%87.txt"),
            vec!["/home/me/中文.txt"]
        );
    }

    #[test]
    fn a_plus_in_a_filename_stays_a_plus() {
        // `+` 代表空格是 query 的规矩，路径里不是 ——
        // 弄错的话 c++.txt 会变成一个根本不存在的文件
        assert_eq!(parse_uri_list("file:///home/me/c++.txt"), vec!["/home/me/c++.txt"]);
    }

    #[test]
    fn the_optional_localhost_authority_is_stripped() {
        assert_eq!(
            parse_uri_list("file://localhost/home/me/a.txt"),
            vec!["/home/me/a.txt"]
        );
    }

    #[test]
    fn non_file_uris_and_comments_are_ignored() {
        // 拖来的 http 链接不是文件，当成文件路径会误导
        let text = "#comment\nhttps://example.com/a\nfile:///real/path\n\n";
        assert_eq!(parse_uri_list(text), vec!["/real/path"]);
    }

    #[test]
    fn an_empty_list_produces_no_paths() {
        assert!(parse_uri_list("").is_empty());
        assert!(parse_uri_list("\r\n\r\n").is_empty());
    }

    #[test]
    fn the_reply_timeout_is_generous_but_finite() {
        // 所有者可能已经卡死或退出，不能无限等；本机往返 1 秒非常宽裕
        assert!(REPLY_TIMEOUT >= Duration::from_millis(200));
        assert!(REPLY_TIMEOUT <= Duration::from_secs(5));
    }
}
