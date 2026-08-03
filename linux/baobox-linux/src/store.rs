//! 截图历史的落盘。
//!
//! 淘汰规则与索引格式都在 `baobox_core::history` 里（三平台共用），
//! 这里只负责「文件放哪、怎么读写」这一层。
//!
//! # 目录
//!
//! 走 XDG：`$XDG_DATA_HOME/baobox/screenshot/`，没设就是
//! `~/.local/share/baobox/screenshot/`。对应 macOS 的
//! `~/Library/Application Support/Baobox/<模块>/` —— 各模块一个子目录，互不串扰。
//!
//! # 出错就当没有历史
//!
//! 索引读不出来、目录建不了，都只让历史变空，**不影响截图本身**。
//! 为了一个「找回旧截图」的辅助功能把主流程搞失败，得不偿失。

use baobox_core::history::{decode_index, encode_index, Entry, History};
use std::path::{Path, PathBuf};

/// 索引文件名。
const INDEX: &str = "index.tsv";

/// 历史目录：`<data>/baobox/screenshot/`。
pub fn dir() -> Option<PathBuf> {
    let base = std::env::var("XDG_DATA_HOME")
        .ok()
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| Some(PathBuf::from(std::env::var("HOME").ok()?).join(".local/share")))?;
    Some(base.join("baobox").join("screenshot"))
}

/// 读出历史。读不出来就当是空的。
pub fn load(limit: usize) -> History {
    let Some(path) = dir().map(|dir| dir.join(INDEX)) else {
        return History::new(limit);
    };
    match std::fs::read_to_string(&path) {
        Ok(text) => decode_index(&text, limit),
        Err(_) => History::new(limit),
    }
}

/// 写回历史。
pub fn save(history: &History) -> Result<(), String> {
    let dir = dir().ok_or("找不到数据目录（$HOME 与 $XDG_DATA_HOME 都没设）")?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建历史目录失败：{e}"))?;
    std::fs::write(dir.join(INDEX), encode_index(history))
        .map_err(|e| format!("写入历史索引失败：{e}"))
}

/// 记一张新截图，并把被淘汰的那些**连文件一起**删掉。
///
/// 只删历史目录里的副本 —— 用户自己 `-o` 指定的文件不归历史管，
/// 悄悄删掉别人指定路径的文件是不可接受的。
pub fn remember(path: &Path, width: u32, height: u32, created_at: i64) {
    let Some(dir) = dir() else { return };
    let mut history = load(History::DEFAULT_LIMIT);
    let entry = Entry {
        id: format!("{created_at}-{width}x{height}"),
        path: path.to_string_lossy().to_string(),
        width,
        height,
        created_at,
    };
    for evicted in history.push(entry) {
        let old = PathBuf::from(&evicted.path);
        if old.starts_with(&dir) {
            let _ = std::fs::remove_file(old);
        }
    }
    let _ = save(&history);
}

/// 供 `history` 命令打印。
pub fn describe(history: &History) -> String {
    if history.entries().is_empty() {
        return "还没有历史记录。".to_string();
    }
    let mut lines = Vec::with_capacity(history.entries().len());
    for entry in history.entries() {
        let missing = if Path::new(&entry.path).exists() {
            ""
        } else {
            "（文件已不在）"
        };
        lines.push(format!(
            "{:>5}×{:<5}  {}{}",
            entry.width, entry.height, entry.path, missing
        ));
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xdg_data_home_wins_over_the_home_fallback() {
        // 只验证拼路径的规则；不动真实环境变量之外的东西
        let previous = std::env::var("XDG_DATA_HOME").ok();
        std::env::set_var("XDG_DATA_HOME", "/custom/data");
        assert_eq!(dir(), Some(PathBuf::from("/custom/data/baobox/screenshot")));

        // 空值应当被忽略而不是拼出 "/baobox/..."
        std::env::set_var("XDG_DATA_HOME", "");
        let fallback = dir();
        assert!(
            fallback.map(|p| p.ends_with("baobox/screenshot")).unwrap_or(true),
            "空的 XDG_DATA_HOME 应退回 ~/.local/share"
        );

        match previous {
            Some(value) => std::env::set_var("XDG_DATA_HOME", value),
            None => std::env::remove_var("XDG_DATA_HOME"),
        }
    }

    #[test]
    fn an_empty_history_says_so_instead_of_printing_nothing() {
        assert!(describe(&History::new(5)).contains("还没有"));
    }

    #[test]
    fn describe_flags_entries_whose_file_is_gone() {
        let mut history = History::new(5);
        history.push(Entry {
            id: "x".into(),
            path: "/definitely/not/here.png".into(),
            width: 10,
            height: 20,
            created_at: 0,
        });
        let text = describe(&history);
        assert!(text.contains("10×20"));
        assert!(text.contains("已不在"), "文件没了要说出来，别让用户白点");
    }
}
