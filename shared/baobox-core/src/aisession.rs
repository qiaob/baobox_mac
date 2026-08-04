//! AI 助手的会话日志：把一行 JSONL 读成用量与会话信息。
//!
//! 对应 macOS 侧 `ClaudeSessionIndex.swift` / `CodexSessionIndex.swift` 里
//! 解析那一半。**找文件是平台的事**（各系统的用户目录不同），
//! 「一行长什么样、该怎么读」在这里，两个平台不会各写各的。
//!
//! # 两家的字段名不一样，形状一样
//!
//! Claude Code 的一行长这样（省略无关字段）：
//!
//! ```json
//! {"type":"assistant","timestamp":"2026-08-04T12:34:56.789Z","cwd":"/repo",
//!  "message":{"model":"claude-opus-5","usage":{"input_tokens":12,"output_tokens":34,
//!  "cache_creation_input_tokens":5,"cache_read_input_tokens":6}}}
//! ```
//!
//! Codex 把用量放在 `payload.info.total_token_usage` 里，时间戳字段也叫别的名。
//! 两家都用 [`Flavor`] 区分，其余共用。
//!
//! # 读不懂的行直接跳过
//!
//! 会话日志是**别人家程序**写的，格式随时会变，而且经常有写了一半的行
//! （进程正在写、或者上次崩在半道）。为一行读不懂就让整个用量统计失败，
//! 是最糟的选择 —— 用户只会看到「用量：读取失败」，却不知道是哪一行。

use crate::aiusage::Entry;
use crate::json::{self, Json};

/// 哪一家的日志。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Flavor {
    /// Claude Code：`~/.claude/projects/<项目>/<会话>.jsonl`
    ClaudeCode,
    /// Codex：`~/.codex/sessions/**/*.jsonl`
    Codex,
}

/// 一次会话的概要，用来在菜单里列出来。
#[derive(Debug, Clone, PartialEq)]
pub struct Session {
    /// 会话 id（就是文件名去掉扩展名），`--resume` 要用它
    pub id: String,
    /// 这个会话在哪个目录里跑的
    pub cwd: String,
    /// 第一条用户消息，当标题用
    pub title: String,
    /// 最后一条记录的时间
    pub updated_at: i64,
    /// 一共多少条消息
    pub messages: usize,
}

impl Session {
    /// 菜单上显示成什么样。
    ///
    /// 优先显示第一句话；没有的话退回目录名 —— 一行「（无标题）」
    /// 对用户毫无帮助，而目录名至少能认出是哪个活儿。
    pub fn display_title(&self) -> String {
        let title = self.title.trim();
        if !title.is_empty() {
            return one_line(title, TITLE_CHARS);
        }
        match self.cwd.rsplit(['/', '\\']).find(|p| !p.is_empty()) {
            Some(folder) => folder.to_string(),
            None => "（无标题）".to_string(),
        }
    }

    /// 项目名 —— 就是工作目录的最后一段，用来出报表。
    pub fn project(&self) -> String {
        self.cwd
            .rsplit(['/', '\\'])
            .find(|p| !p.is_empty())
            .unwrap_or("")
            .to_string()
    }
}

/// 标题最多显示多少个字符。
const TITLE_CHARS: usize = 48;

/// 一份会话文件读出来的东西。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Parsed {
    /// 里面的用量记录
    pub entries: Vec<Entry>,
    /// 这份文件对应的会话概要（一条记录都读不懂时为 `None`）
    pub session: Option<Session>,
}

/// 把一整份 `.jsonl` 读出来。
///
/// `id` 一般是文件名去掉扩展名。**读不懂的行跳过**，不让整份失败。
pub fn parse_file(id: &str, text: &str, flavor: Flavor) -> Parsed {
    let mut entries = Vec::new();
    let mut cwd = String::new();
    let mut title = String::new();
    let mut updated_at = 0i64;
    let mut messages = 0usize;

    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // 写了一半的行（进程正在写、或者上次崩在半道）在这里被挡掉
        let Some(value) = json::parse(line) else {
            continue;
        };
        messages += 1;

        if let Some(at) = timestamp_of(&value, flavor) {
            updated_at = updated_at.max(at);
        }
        if cwd.is_empty() {
            if let Some(found) = cwd_of(&value, flavor) {
                cwd = found;
            }
        }
        if title.is_empty() {
            if let Some(found) = first_user_text(&value, flavor) {
                title = found;
            }
        }
        if let Some(entry) = usage_of(&value, flavor, &cwd) {
            entries.push(entry);
        }
    }

    if messages == 0 {
        return Parsed::default();
    }
    // 用量记录里的项目名要跟着最终的 cwd 走 —— cwd 常常出现在
    // 比第一条用量更晚的行里，先前记的那些是空的
    let project = project_of(&cwd);
    for entry in &mut entries {
        if entry.project.is_empty() {
            entry.project = project.clone();
        }
    }

    Parsed {
        entries,
        session: Some(Session {
            id: id.to_string(),
            cwd,
            title,
            updated_at,
            messages,
        }),
    }
}

fn project_of(cwd: &str) -> String {
    cwd.rsplit(['/', '\\'])
        .find(|p| !p.is_empty())
        .unwrap_or("")
        .to_string()
}

/// 读一行的时间戳。
fn timestamp_of(value: &Json, flavor: Flavor) -> Option<i64> {
    let keys: &[&[&str]] = match flavor {
        Flavor::ClaudeCode => &[&["timestamp"]],
        Flavor::Codex => &[&["timestamp"], &["payload", "timestamp"]],
    };
    for path in keys {
        if let Some(text) = value.path(path).and_then(Json::as_str) {
            if let Some(at) = parse_iso8601(text) {
                return Some(at);
            }
        }
        // 有的版本直接写 Unix 秒
        if let Some(number) = value.path(path).and_then(Json::as_i64) {
            return Some(number);
        }
    }
    None
}

fn cwd_of(value: &Json, flavor: Flavor) -> Option<String> {
    let keys: &[&[&str]] = match flavor {
        Flavor::ClaudeCode => &[&["cwd"]],
        Flavor::Codex => &[&["cwd"], &["payload", "cwd"]],
    };
    for path in keys {
        if let Some(text) = value.path(path).and_then(Json::as_str) {
            if !text.is_empty() {
                return Some(text.to_string());
            }
        }
    }
    None
}

/// 第一条用户消息的文字，当标题。
fn first_user_text(value: &Json, flavor: Flavor) -> Option<String> {
    let role_ok = match flavor {
        Flavor::ClaudeCode => value.get("type").and_then(Json::as_str) == Some("user"),
        Flavor::Codex => {
            value.path(&["payload", "role"]).and_then(Json::as_str) == Some("user")
                || value.get("role").and_then(Json::as_str) == Some("user")
        }
    };
    if !role_ok {
        return None;
    }
    let content = value
        .path(&["message", "content"])
        .or_else(|| value.path(&["payload", "content"]))
        .or_else(|| value.get("content"))?;

    let text = match content {
        Json::Str(text) => text.clone(),
        // 数组形式：取第一个 text 块
        Json::Array(blocks) => blocks
            .iter()
            .find_map(|b| b.get("text").and_then(Json::as_str))
            .unwrap_or("")
            .to_string(),
        _ => return None,
    };
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    // 斜杠命令与系统提醒当不了标题 —— 它们在每个会话里都长一样
    if trimmed.starts_with('/') || trimmed.starts_with("<") {
        return None;
    }
    Some(trimmed.to_string())
}

/// 读一行的用量。
fn usage_of(value: &Json, flavor: Flavor, cwd: &str) -> Option<Entry> {
    let (usage, model) = match flavor {
        Flavor::ClaudeCode => (
            value.path(&["message", "usage"])?,
            value
                .path(&["message", "model"])
                .and_then(Json::as_str)
                .unwrap_or("")
                .to_string(),
        ),
        Flavor::Codex => (
            value
                .path(&["payload", "info", "total_token_usage"])
                .or_else(|| value.path(&["payload", "usage"]))
                .or_else(|| value.get("usage"))?,
            value
                .path(&["payload", "info", "model"])
                .or_else(|| value.path(&["payload", "model"]))
                .and_then(Json::as_str)
                .unwrap_or("")
                .to_string(),
        ),
    };

    let field = |names: &[&str]| -> i64 {
        names
            .iter()
            .find_map(|n| usage.get(n).and_then(Json::as_i64))
            .unwrap_or(0)
    };
    let input = field(&["input_tokens", "prompt_tokens", "input"]);
    let output = field(&["output_tokens", "completion_tokens", "output"]);
    let cache_write = field(&["cache_creation_input_tokens", "cached_write_tokens"]);
    let cache_read = field(&["cache_read_input_tokens", "cached_input_tokens"]);

    // 一条 token 都没有的不算用量记录 —— 否则每条系统消息都会占一行
    if input + output + cache_write + cache_read == 0 {
        return None;
    }
    Some(Entry {
        timestamp: timestamp_of(value, flavor).unwrap_or(0),
        input,
        output,
        cache_write,
        cache_read,
        model_id: model,
        project: project_of(cwd),
    })
}

/// 解析 `2026-08-04T12:34:56.789Z` 这样的时间戳。
///
/// 自己写而不是引 chrono：这个 crate 是零依赖的，而我们只需要认这一种格式。
/// **只认 UTC（`Z` 结尾）与带偏移量的**；认不出返回 `None`，
/// 绝不「就近猜一个」—— 猜错会让用量落到错误的那一天。
pub fn parse_iso8601(text: &str) -> Option<i64> {
    let bytes = text.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    let num = |from: usize, to: usize| -> Option<i64> { text.get(from..to)?.parse().ok() };
    let year = num(0, 4)?;
    let month = num(5, 7)?;
    let day = num(8, 10)?;
    let hour = num(11, 13)?;
    let minute = num(14, 16)?;
    let second = num(17, 19)?;
    if bytes[4] != b'-' || bytes[7] != b'-' || (bytes[10] != b'T' && bytes[10] != b' ') {
        return None;
    }
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    if hour > 23 || minute > 59 || second > 60 {
        return None;
    }

    let days = days_from_civil(year, month, day);
    let mut seconds = days * 86_400 + hour * 3600 + minute * 60 + second;

    // 时区偏移：`Z` 就是 UTC，`+08:00` / `-05:00` 要减回去
    let rest = &text[19..];
    let offset = rest
        .find(['+', '-'])
        .and_then(|at| parse_offset(&rest[at..]));
    if let Some(offset) = offset {
        seconds -= offset;
    }
    Some(seconds)
}

/// `+08:00` / `-0500` → 秒。
fn parse_offset(text: &str) -> Option<i64> {
    let sign = match text.as_bytes().first()? {
        b'+' => 1,
        b'-' => -1,
        _ => return None,
    };
    let digits: String = text[1..].chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.len() < 4 {
        return None;
    }
    let hours: i64 = digits[0..2].parse().ok()?;
    let minutes: i64 = digits[2..4].parse().ok()?;
    Some(sign * (hours * 3600 + minutes * 60))
}

/// 年月日 → 从纪元起的天数（Howard Hinnant 的 days_from_civil）。
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = if month > 2 { month - 3 } else { month + 9 };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// 压成一行并截断。
fn one_line(text: &str, limit: usize) -> String {
    let flat: String = text
        .lines()
        .next()
        .unwrap_or("")
        .chars()
        .take(limit)
        .collect();
    if text.lines().next().unwrap_or("").chars().count() > limit {
        format!("{flat}…")
    } else {
        flat
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CLAUDE_LINE: &str = r#"{"type":"assistant","timestamp":"2026-08-04T12:34:56.789Z","cwd":"/home/me/repo","message":{"model":"claude-opus-5","usage":{"input_tokens":12,"output_tokens":34,"cache_creation_input_tokens":5,"cache_read_input_tokens":6}}}"#;

    #[test]
    fn a_claude_line_yields_all_four_token_counts() {
        let parsed = parse_file("abc", CLAUDE_LINE, Flavor::ClaudeCode);
        assert_eq!(parsed.entries.len(), 1);
        let entry = &parsed.entries[0];
        assert_eq!((entry.input, entry.output), (12, 34));
        assert_eq!((entry.cache_write, entry.cache_read), (5, 6));
        assert_eq!(entry.model_id, "claude-opus-5");
        assert_eq!(entry.project, "repo");
    }

    #[test]
    fn a_half_written_line_is_skipped_instead_of_failing_the_whole_file() {
        // 日志是别人家程序写的，经常有写了一半的行
        let text = format!("{CLAUDE_LINE}\n{{\"type\":\"assis\n{CLAUDE_LINE}\n");
        let parsed = parse_file("abc", &text, Flavor::ClaudeCode);
        assert_eq!(parsed.entries.len(), 2, "坏行跳过，好行照读");
    }

    #[test]
    fn an_empty_file_produces_no_session_at_all() {
        assert_eq!(parse_file("abc", "", Flavor::ClaudeCode), Parsed::default());
        assert_eq!(parse_file("abc", "\n\n  \n", Flavor::ClaudeCode).session, None);
    }

    #[test]
    fn a_line_with_no_tokens_is_not_counted_as_usage() {
        // 否则每条系统消息都会在报表里占一行
        let line = r#"{"type":"assistant","timestamp":"2026-08-04T12:00:00Z","message":{"model":"x","usage":{"input_tokens":0,"output_tokens":0}}}"#;
        assert!(parse_file("a", line, Flavor::ClaudeCode).entries.is_empty());
    }

    #[test]
    fn the_first_user_message_becomes_the_title() {
        let text = format!(
            "{}\n{CLAUDE_LINE}",
            r#"{"type":"user","timestamp":"2026-08-04T12:00:00Z","cwd":"/home/me/repo","message":{"content":"帮我看看这个 bug"}}"#
        );
        let session = parse_file("abc", &text, Flavor::ClaudeCode).session.unwrap();
        assert_eq!(session.display_title(), "帮我看看这个 bug");
    }

    #[test]
    fn a_slash_command_does_not_become_the_title() {
        // 它在每个会话里都长一样，当标题的话列表里全是 /clear
        let text = r#"{"type":"user","timestamp":"2026-08-04T12:00:00Z","cwd":"/home/me/repo","message":{"content":"/clear"}}"#;
        let session = parse_file("abc", text, Flavor::ClaudeCode).session.unwrap();
        assert_eq!(session.display_title(), "repo", "退回目录名");
    }

    #[test]
    fn a_titleless_session_falls_back_to_the_folder_name() {
        // 一行「（无标题）」对用户毫无帮助，目录名至少能认出是哪个活儿
        let session = parse_file("abc", CLAUDE_LINE, Flavor::ClaudeCode)
            .session
            .unwrap();
        assert_eq!(session.display_title(), "repo");
    }

    #[test]
    fn content_blocks_are_understood_as_well_as_plain_strings() {
        let text = r#"{"type":"user","timestamp":"2026-08-04T12:00:00Z","cwd":"/x","message":{"content":[{"type":"text","text":"块形式的内容"}]}}"#;
        let session = parse_file("abc", text, Flavor::ClaudeCode).session.unwrap();
        assert_eq!(session.display_title(), "块形式的内容");
    }

    #[test]
    fn a_long_title_is_shortened_to_one_line() {
        let long = "很".repeat(200);
        let text = format!(
            r#"{{"type":"user","timestamp":"2026-08-04T12:00:00Z","cwd":"/x","message":{{"content":"{long}\n第二行"}}}}"#
        );
        let session = parse_file("abc", &text, Flavor::ClaudeCode).session.unwrap();
        let shown = session.display_title();
        assert!(!shown.contains('\n'));
        assert!(shown.chars().count() <= TITLE_CHARS + 1);
    }

    #[test]
    fn the_project_is_backfilled_when_cwd_shows_up_late() {
        // cwd 常常出现在比第一条用量更晚的行里
        let text = format!(
            "{}\n{}",
            r#"{"type":"assistant","timestamp":"2026-08-04T12:00:00Z","message":{"model":"sonnet","usage":{"input_tokens":9}}}"#,
            CLAUDE_LINE
        );
        let parsed = parse_file("abc", &text, Flavor::ClaudeCode);
        assert!(parsed.entries.iter().all(|e| e.project == "repo"));
    }

    #[test]
    fn a_codex_line_is_read_from_its_own_field_names() {
        let line = r#"{"timestamp":"2026-08-04T12:34:56Z","cwd":"/home/me/x","payload":{"info":{"model":"gpt-5","total_token_usage":{"input_tokens":100,"output_tokens":20,"cached_input_tokens":7}}}}"#;
        let parsed = parse_file("s1", line, Flavor::Codex);
        assert_eq!(parsed.entries.len(), 1);
        assert_eq!(parsed.entries[0].input, 100);
        assert_eq!(parsed.entries[0].cache_read, 7);
        assert_eq!(parsed.entries[0].model_id, "gpt-5");
    }

    #[test]
    fn iso_timestamps_are_parsed_including_the_offset() {
        // 认错时区会让用量落到错误的那一天
        let utc = parse_iso8601("2026-08-04T12:34:56.789Z").unwrap();
        assert_eq!(utc, 1_785_846_896);
        // 东八区的 20:34:56 就是 UTC 的 12:34:56
        let east = parse_iso8601("2026-08-04T20:34:56+08:00").unwrap();
        assert_eq!(east, utc);
        let west = parse_iso8601("2026-08-04T07:34:56-05:00").unwrap();
        assert_eq!(west, utc);
    }

    #[test]
    fn a_timestamp_that_cannot_be_read_is_refused_rather_than_guessed() {
        // 猜一个会让用量落到错误的那一天
        assert!(parse_iso8601("").is_none());
        assert!(parse_iso8601("昨天下午").is_none());
        assert!(parse_iso8601("2026/08/04 12:34:56").is_none());
        assert!(parse_iso8601("2026-13-04T12:34:56Z").is_none(), "13 月");
        assert!(parse_iso8601("2026-08-04T25:00:00Z").is_none(), "25 点");
    }

    #[test]
    fn a_numeric_timestamp_is_accepted_too() {
        let line = r#"{"type":"assistant","timestamp":1785846896,"message":{"model":"sonnet","usage":{"input_tokens":1}}}"#;
        let parsed = parse_file("a", line, Flavor::ClaudeCode);
        assert_eq!(parsed.entries[0].timestamp, 1_785_846_896);
    }

    #[test]
    fn the_session_records_when_it_was_last_touched() {
        let text = format!(
            "{}\n{}",
            CLAUDE_LINE,
            r#"{"type":"assistant","timestamp":"2026-08-05T01:00:00Z","message":{"model":"sonnet","usage":{"input_tokens":1}}}"#
        );
        let session = parse_file("abc", &text, Flavor::ClaudeCode).session.unwrap();
        assert_eq!(session.updated_at, parse_iso8601("2026-08-05T01:00:00Z").unwrap());
        assert_eq!(session.messages, 2);
    }

    #[test]
    fn windows_paths_yield_the_same_project_name_as_unix_ones() {
        let mut session = Session {
            id: "a".into(),
            cwd: r"C:\Users\me\repo".into(),
            title: String::new(),
            updated_at: 0,
            messages: 1,
        };
        assert_eq!(session.project(), "repo");
        session.cwd = "/home/me/repo/".into();
        assert_eq!(session.project(), "repo", "结尾的分隔符不该算成一段");
    }
}
