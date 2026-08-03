//! 截图历史的落盘（Windows）。
//!
//! 淘汰规则与索引格式在 `baobox_core::history` 里（三平台共用），
//! 这里只决定「文件放哪」。
//!
//! # 目录
//!
//! `%APPDATA%\Baobox\screenshot\` —— 对应 Linux 的 `~/.local/share/baobox/`
//! 与 macOS 的 `~/Library/Application Support/Baobox/`。
//! 用 `%APPDATA%` 而不是 `%LOCALAPPDATA%`：截图历史是用户数据，
//! 在域账号的漫游配置里跟着走是合理的。

use baobox_core::history::{decode_index, encode_index, Entry, History};
use std::path::{Path, PathBuf};

/// 索引文件名。
const INDEX: &str = "index.tsv";

/// 历史目录。
pub fn dir() -> Option<PathBuf> {
    let base = std::env::var("APPDATA")
        .ok()
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            // 一段一段 join，别写 "AppData\\Roaming" —— 那样在非 Windows 上
            // （交叉编译跑测试时）整串会被当成一个目录名
            Some(
                PathBuf::from(std::env::var("USERPROFILE").ok()?)
                    .join("AppData")
                    .join("Roaming"),
            )
        })?;
    Some(base.join("Baobox").join("screenshot"))
}

/// 读出历史。读不出来就当是空的 —— 索引是缓存，不该拖垮截图本身。
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
    let dir = dir().ok_or("找不到数据目录（%APPDATA% 未设置）")?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建历史目录失败：{e}"))?;
    std::fs::write(dir.join(INDEX), encode_index(history))
        .map_err(|e| format!("写入历史索引失败：{e}"))
}

/// 记一张新截图，并把被淘汰的那些连文件一起删掉。
///
/// **只删历史目录里的副本** —— 用户用 `-o` 指定的文件不归历史管。
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
    history
        .entries()
        .iter()
        .map(|entry| {
            let missing = if Path::new(&entry.path).exists() {
                ""
            } else {
                "（文件已不在）"
            };
            format!(
                "{:>5}×{:<5}  {}{}",
                entry.width, entry.height, entry.path, missing
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appdata_wins_and_an_empty_value_falls_back() {
        // 用 join 拼期望值而不是写死分隔符 —— 这样在 Linux 上跑测试
        // （交叉编译时的常态）也不会因为 `/` 与 `\` 的差别假失败
        let roaming = PathBuf::from("C:/Users/me/AppData/Roaming");
        let expected = roaming.join("Baobox").join("screenshot");

        let previous = std::env::var("APPDATA").ok();
        std::env::set_var("APPDATA", &roaming);
        assert_eq!(dir(), Some(expected.clone()));

        // 空字符串不该被当成有效路径，否则会拼出一个根目录下的路径
        std::env::set_var("APPDATA", "");
        std::env::set_var("USERPROFILE", "C:/Users/me");
        assert_eq!(dir(), Some(expected));

        match previous {
            Some(value) => std::env::set_var("APPDATA", value),
            None => std::env::remove_var("APPDATA"),
        }
    }

    #[test]
    fn an_empty_history_says_so() {
        assert!(describe(&History::new(5)).contains("还没有"));
    }

    #[test]
    fn describe_flags_entries_whose_file_is_gone() {
        let mut history = History::new(5);
        history.push(Entry {
            id: "x".into(),
            path: "Z:\\definitely\\not\\here.png".into(),
            width: 10,
            height: 20,
            created_at: 0,
        });
        assert!(describe(&history).contains("已不在"));
    }
}
