//! AI 助手（Claude Code / Codex）：找日志、读日志、算用量。
//!
//! **这一整块没有一行是平台相关的** —— 只用 `std::fs` 与 `std::env`，
//! 所以它住在共享层而不是在两个平台各放一份（仓库约定 1）。
//! 一开始它确实是两份拷贝，review 时收掉了：888 行的重复迟早会漂。
//!
//! 助手工具是这几个里唯一完全没有平台耦合的，因此它的测试在开发机上
//! 全都能真跑，这也是它排在最前面移植的原因。
//!
//! # 未安装即降级
//!
//! 目录不存在就当「没装」：菜单里显示一条置灰的引导，不报错、
//! 不起后台任务（根 `CLAUDE.md` 约定 7）。用户没装 Claude Code 是常态，
//! 不该看到一串报错。
//!
//! # 扫目录是有代价的，所以放后台
//!
//! `~/.claude/projects/` 底下几百个 `.jsonl`，加起来几十上百 MB 是常事。
//! 每次弹菜单都扫一遍会卡住整个界面（根 `CLAUDE.md` 约定 2：菜单构建零磁盘 IO）。
//! 所以扫描交给后台线程，菜单只读内存里的那份快照。

use baobox_core::aisession::{parse_file, Flavor, Session};
use baobox_core::aiusage::Entry;
use std::path::{Path, PathBuf};

/// 一次扫描的结果。
#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    /// 所有用量记录
    pub entries: Vec<Entry>,
    /// 会话，**最近的排最前**
    pub sessions: Vec<Session>,
    /// 扫了多少份文件
    pub files: usize,
}

/// 菜单里最多列几条会话。
pub const MENU_SESSIONS: usize = 8;

/// 单份日志的大小上限。
///
/// 超过这个的不读 —— 一份几百 MB 的日志能把内存吃干，而它多半是
/// 某次跑飞了的循环留下的，里面的用量数据也没什么参考价值。
pub const MAX_FILE_BYTES: u64 = 64 * 1024 * 1024;

/// 只统计最近多少天的用量。
///
/// 5 小时窗口只关心当下，周窗口最多回看 7 天 —— 扫两年前的日志纯属浪费，
/// 而那恰恰是让「点开菜单卡三秒」的原因。
pub const LOOKBACK_DAYS: i64 = 30;

/// Claude Code 的家在哪。
///
/// 认 `CLAUDE_CONFIG_DIR`（官方支持的覆盖），否则 `~/.claude`。
pub fn claude_home() -> Option<PathBuf> {
    home_from(
        std::env::var("CLAUDE_CONFIG_DIR").ok().as_deref(),
        home().as_deref(),
        ".claude",
    )
}

/// Codex 的家在哪。
pub fn codex_home() -> Option<PathBuf> {
    home_from(
        std::env::var("CODEX_HOME").ok().as_deref(),
        home().as_deref(),
        ".codex",
    )
}

/// 「覆盖变量 + 主目录 + 默认子目录」→ 家在哪。
///
/// 单独拎出来是为了**能测**：直接读环境变量的话，测试就得
/// `set_var`，而那是进程级的 —— 并行跑的两条测试会互相踩，
/// 表现是「CI 偶尔红一次，重跑又好了」。这个仓库为它红过一次 CI。
pub fn home_from(custom: Option<&str>, home: Option<&Path>, default_name: &str) -> Option<PathBuf> {
    if let Some(custom) = custom {
        if !custom.trim().is_empty() {
            return Some(PathBuf::from(custom));
        }
    }
    home.map(|h| h.join(default_name))
}

/// 用户主目录。Windows 上 `HOME` 常常没有，所以也认 `USERPROFILE`。
fn home() -> Option<PathBuf> {
    std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .ok()
        .filter(|h| !h.trim().is_empty())
        .map(PathBuf::from)
}

/// 会话日志在哪个子目录下。
pub fn sessions_dir(home: &Path, flavor: Flavor) -> PathBuf {
    match flavor {
        Flavor::ClaudeCode => home.join("projects"),
        Flavor::Codex => home.join("sessions"),
    }
}

/// 装了吗。目录不在就是没装。
pub fn installed(flavor: Flavor) -> bool {
    let home = match flavor {
        Flavor::ClaudeCode => claude_home(),
        Flavor::Codex => codex_home(),
    };
    home.map(|h| h.is_dir()).unwrap_or(false)
}

/// 扫一遍日志。**这会读磁盘，只能在后台线程上调**。
///
/// `now` 传当前 Unix 秒，用来算「只看最近 N 天」。
pub fn scan(flavor: Flavor, now: i64) -> Snapshot {
    let home = match flavor {
        Flavor::ClaudeCode => claude_home(),
        Flavor::Codex => codex_home(),
    };
    let Some(home) = home else {
        return Snapshot::default();
    };
    scan_dir(&sessions_dir(&home, flavor), flavor, now)
}

/// 扫某个目录。`scan` 是它加一层「家在哪」。
///
/// 分开是为了**能测**：测试给一个临时目录即可，不必去动环境变量。
pub fn scan_dir(dir: &Path, flavor: Flavor, now: i64) -> Snapshot {
    if !dir.is_dir() {
        return Snapshot::default();
    }

    let cutoff = now - LOOKBACK_DAYS * 86_400;
    let mut snapshot = Snapshot::default();
    for path in jsonl_files(dir) {
        let Ok(meta) = std::fs::metadata(&path) else {
            continue;
        };
        if meta.len() > MAX_FILE_BYTES {
            continue;
        }
        // 先看文件的修改时间，早于回看窗口的**连读都不读** ——
        // 这是把「点开菜单卡三秒」降到毫秒的关键一步
        if let Some(modified) = modified_seconds(&meta) {
            if modified < cutoff {
                continue;
            }
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let id = path
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();
        let parsed = parse_file(&id, &text, flavor);
        snapshot.files += 1;
        snapshot
            .entries
            .extend(parsed.entries.into_iter().filter(|e| e.timestamp >= cutoff));
        if let Some(session) = parsed.session {
            snapshot.sessions.push(session);
        }
    }
    // 最近的排最前 —— 用户要续接的几乎总是刚才那个
    snapshot.sessions.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    snapshot
}

fn modified_seconds(meta: &std::fs::Metadata) -> Option<i64> {
    meta.modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs() as i64)
}

/// 把目录底下所有 `.jsonl` 找出来（递归）。
///
/// 自己走而不是引 walkdir：这一段就十几行，而多一个依赖要多一份维护。
pub fn jsonl_files(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    collect(dir, 0, &mut found);
    found
}

/// 目录最多下探几层。
///
/// Claude 的布局是 `projects/<项目>/<会话>.jsonl`，Codex 的是
/// `sessions/<年>/<月>/<日>/<会话>.jsonl` —— 五层足够，
/// 而有上限才不会被一个符号链接环拖住。
const MAX_DEPTH: usize = 5;

fn collect(dir: &Path, depth: usize, found: &mut Vec<PathBuf>) {
    if depth > MAX_DEPTH {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        // 用 `file_type` 而不是 `path.is_dir()`：后者会跟着符号链接走，
        // 一个指回上层的链接就能让这里转到天荒地老
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_dir() {
            collect(&path, depth + 1, found);
        } else if kind.is_file()
            && path.extension().map(|e| e == "jsonl").unwrap_or(false)
        {
            found.push(path);
        }
    }
}

/// 「没装」时菜单里那条引导。
pub fn not_installed_hint(flavor: Flavor) -> String {
    match flavor {
        Flavor::ClaudeCode => "没找到 ~/.claude —— 装了 Claude Code 之后这里会显示用量".to_string(),
        Flavor::Codex => "没找到 ~/.codex —— 装了 Codex 之后这里会显示用量".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_home_directory_can_be_overridden_the_way_the_official_tools_allow() {
        // 用户把配置搬走是官方支持的用法，写死 ~/.claude 会让这些人看到「没装」
        let home = PathBuf::from("/home/me");
        assert_eq!(
            home_from(Some("/custom/claude"), Some(&home), ".claude"),
            Some(PathBuf::from("/custom/claude"))
        );
        // 没设覆盖时按默认
        assert_eq!(
            home_from(None, Some(&home), ".claude"),
            Some(PathBuf::from("/home/me/.claude"))
        );
        // 空值当没设，而不是当成根目录
        assert_eq!(
            home_from(Some("   "), Some(&home), ".codex"),
            Some(PathBuf::from("/home/me/.codex"))
        );
        // 连主目录都没有时诚实地返回 None
        assert_eq!(home_from(None, None, ".claude"), None);
    }

    #[test]
    fn the_two_flavours_look_in_different_subdirectories() {
        let home = Path::new("/home/me/.claude");
        assert!(sessions_dir(home, Flavor::ClaudeCode).ends_with("projects"));
        assert!(sessions_dir(home, Flavor::Codex).ends_with("sessions"));
    }

    #[test]
    fn scanning_a_missing_directory_is_empty_rather_than_an_error() {
        // 没装 Claude Code 是常态，不该看到一串报错
        let snapshot = scan_dir(
            Path::new("/这个目录一定不存在/x"),
            Flavor::ClaudeCode,
            1_785_846_896,
        );
        assert_eq!(snapshot.files, 0);
        assert!(snapshot.entries.is_empty());
        assert!(snapshot.sessions.is_empty());
    }

    #[test]
    fn a_real_directory_of_logs_is_read_end_to_end() {
        let root = std::env::temp_dir().join("baobox-assistant-test");
        let _ = std::fs::remove_dir_all(&root);
        let project = root.join("-home-me-repo");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(
            project.join("sess-1.jsonl"),
            "{\"type\":\"assistant\",\"timestamp\":\"2026-08-04T12:00:00Z\",\"cwd\":\"/home/me/repo\",\
             \"message\":{\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20}}}\n",
        )
        .unwrap();
        // 不是 jsonl 的不该被读进来
        std::fs::write(project.join("readme.txt"), "别读我").unwrap();

        let now = baobox_core::aisession::parse_iso8601("2026-08-04T13:00:00Z").unwrap();
        let snapshot = scan_dir(&root, Flavor::ClaudeCode, now);
        assert_eq!(snapshot.files, 1, "只该读到那一份 jsonl");
        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].input, 100);
        assert_eq!(snapshot.sessions.len(), 1);
        assert_eq!(snapshot.sessions[0].id, "sess-1");
        assert_eq!(snapshot.sessions[0].project(), "repo");

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn logs_older_than_the_lookback_are_not_even_opened() {
        // 这是把「点开菜单卡三秒」降到毫秒的关键一步
        let root = std::env::temp_dir().join("baobox-assistant-old");
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(
            root.join("ancient.jsonl"),
            "{\"type\":\"assistant\",\"timestamp\":\"2020-01-01T00:00:00Z\",\
             \"message\":{\"model\":\"sonnet\",\"usage\":{\"input_tokens\":1}}}\n",
        )
        .unwrap();
        // 文件的 mtime 是「刚才」，所以它会被打开；但里面的记录早于回看窗口，
        // 那一条不该进统计
        let now = baobox_core::aisession::parse_iso8601("2026-08-04T13:00:00Z").unwrap();
        let snapshot = scan_dir(&root, Flavor::ClaudeCode, now);
        assert!(snapshot.entries.is_empty(), "太老的记录不进统计");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn sessions_come_back_with_the_most_recent_first() {
        // 用户要续接的几乎总是刚才那个
        let root = std::env::temp_dir().join("baobox-assistant-order");
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        for (name, at) in [("old", "2026-08-01T00:00:00Z"), ("new", "2026-08-04T00:00:00Z")] {
            std::fs::write(
                root.join(format!("{name}.jsonl")),
                format!(
                    "{{\"type\":\"assistant\",\"timestamp\":\"{at}\",\"message\":{{\"model\":\"sonnet\",\"usage\":{{\"input_tokens\":1}}}}}}\n"
                ),
            )
            .unwrap();
        }
        let now = baobox_core::aisession::parse_iso8601("2026-08-04T13:00:00Z").unwrap();
        let snapshot = scan_dir(&root, Flavor::ClaudeCode, now);
        assert_eq!(snapshot.sessions.len(), 2);
        assert_eq!(snapshot.sessions[0].id, "new");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_lookback_covers_the_weekly_window_with_room_to_spare() {
        // 周窗口最多回看 7 天；扫两年前的日志纯属浪费，而那正是「菜单卡三秒」的原因
        assert!(LOOKBACK_DAYS >= 7);
        assert!(LOOKBACK_DAYS <= 90);
    }

    #[test]
    fn the_directory_walk_has_a_depth_limit_so_a_symlink_loop_cannot_hang_it() {
        assert!(MAX_DEPTH >= 4, "Codex 的布局是 年/月/日/文件，至少四层");
        assert!(MAX_DEPTH <= 8);
    }

    #[test]
    fn a_missing_directory_yields_no_files_rather_than_panicking() {
        assert!(jsonl_files(Path::new("/这个目录一定不存在/y")).is_empty());
    }

    #[test]
    fn both_hints_tell_the_user_what_to_install() {
        assert!(not_installed_hint(Flavor::ClaudeCode).contains(".claude"));
        assert!(not_installed_hint(Flavor::Codex).contains(".codex"));
    }
}
