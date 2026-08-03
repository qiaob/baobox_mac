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

use baobox_core::config::Config;
use baobox_core::history::{decode_index, encode_index, Entry, History};
use std::path::{Path, PathBuf};

/// 索引文件名。
const INDEX: &str = "index.tsv";

/// 配置文件名。
const CONFIG: &str = "config.ini";

/// 配置文件的完整路径。
///
/// 与历史放同一个目录下 —— Windows 上没有 XDG 那种「配置与数据分家」的惯例，
/// `%APPDATA%\Baobox\` 一处放全更符合用户的预期（也更好备份）。
pub fn config_path() -> Option<PathBuf> {
    dir().and_then(|d| d.parent().map(|base| base.join(CONFIG)))
}

/// 读配置。读不出来就当是空的 —— 配置坏了不该让程序起不来。
pub fn load_config() -> Config {
    match config_path().and_then(|path| std::fs::read_to_string(path).ok()) {
        Some(text) => Config::parse(&text),
        None => Config::new(),
    }
}

/// 写配置。
pub fn save_config(config: &Config) -> Result<(), String> {
    let path = config_path().ok_or("找不到配置目录（%APPDATA% 未设置）")?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("创建配置目录失败：{e}"))?;
    }
    std::fs::write(path, config.to_text()).map_err(|e| format!("写入配置失败：{e}"))
}

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
/// `limit` 为 `None` 时用默认上限（命令行下没有配置可读）。
pub fn remember(path: &Path, width: u32, height: u32, created_at: i64, limit: Option<usize>) {
    let Some(dir) = dir() else { return };
    let mut history = load(limit.unwrap_or(History::DEFAULT_LIMIT));
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
    fn the_config_sits_beside_the_module_directories_not_inside_one() {
        // 配置是整个 App 的，不属于哪个工具，所以在 Baobox\ 而不是 Baobox\screenshot\
        let previous = std::env::var("APPDATA").ok();
        std::env::set_var("APPDATA", "C:/roaming");
        let config = config_path().unwrap();
        let history = dir().unwrap();
        assert_eq!(config, PathBuf::from("C:/roaming").join("Baobox").join("config.ini"));
        assert!(history.starts_with(config.parent().unwrap()));
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
