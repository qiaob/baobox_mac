//! AI 助手工具接进 App 框架。
//!
//! **住在共享层**：两个 Rust 平台的这份适配层曾经是两份逐字相同的拷贝，
//! review 时收掉了 —— 它与平台唯一的接触面是「开哪个终端」，
//! 那一个函数由平台层在构造时传进来（[`AssistantTool::new`]）。
//!
//! **一份代码带出两个工具**：Claude Code 与 Codex 的日志形状一样、
//! 用量算法一样、菜单一样，只有「读哪个目录、用什么命令续接」不同。
//! 所以这里是一个带 [`Flavor`] 的结构体，注册两次。
//!
//! # 扫描在后台，菜单只读快照
//!
//! `~/.claude/projects/` 底下几百份日志。每次弹菜单都扫一遍会卡住界面
//! （根 `CLAUDE.md` 约定 2）。所以：`activate` 起一次后台扫描，
//! 之后每隔一段时间再扫一次，菜单永远只读内存里那份快照。
//!
//! # 「续接会话」是把命令交给终端，不是自己跑
//!
//! `claude --resume <id>` 要一个交互式终端 —— 我们自己 `spawn` 它，
//! 用户既看不到界面也没法打字。正确做法是**开一个终端窗口**并把命令交给它。
//! 用哪个终端由用户在设置里选（与 macOS 侧 `TerminalAppPreference` 同一个思路）。

use crate::assistant;
use crate::{Field, HotkeySpec, MenuItem, SettingsPage, ToolModule};
use baobox_core::aisession::Flavor;
use baobox_core::aiusage::{self, Window};
use baobox_core::config::Config;
use std::sync::mpsc::{channel, Receiver};

/// Claude Code 助手的工具 id。
pub const CLAUDE_ID: &str = "claudecode";
/// Codex 助手的工具 id。
pub const CODEX_ID: &str = "aitools";

/// 动作：把用量报表打到标准输出。
const REPORT: &str = "report";
/// 动作：立刻重扫一遍。
const REFRESH: &str = "refresh";
/// 动作前缀：续接某个会话，后面接会话 id。
const RESUME: &str = "resume.";

/// 当前 Unix 秒。
///
/// 平台层各有一份同名函数，但为了让这个模块自足，这里直接问系统。
fn now_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 这个工具的 id。
fn id_of(flavor: Flavor) -> &'static str {
    match flavor {
        Flavor::ClaudeCode => CLAUDE_ID,
        Flavor::Codex => CODEX_ID,
    }
}

/// 某个动作的完整 id。
fn action(flavor: Flavor, suffix: &str) -> String {
    format!("{}.{suffix}", id_of(flavor))
}

/// 多久重扫一次。
///
/// 用量是给人看个大概的，不必实时；而扫描要读几十 MB，
/// 太频繁会让磁盘一直转。
const RESCAN_SECONDS: i64 = 60;

/// 从配置读出来的偏好。
struct Settings {
    five_hour_budget: i64,
    weekly_budget: i64,
    weekly_fixed: bool,
    weekly_weekday: i64,
    weekly_hour: i64,
    terminal: String,
}

impl Settings {
    fn read(config: &Config, id: &str) -> Self {
        Self {
            five_hour_budget: config.usize_or(id, "five_hour_budget", 0) as i64,
            weekly_budget: config.usize_or(id, "weekly_budget", 0) as i64,
            weekly_fixed: config.bool_or(id, "weekly_reset_fixed", false),
            weekly_weekday: config.usize_or(id, "weekly_reset_weekday", 1) as i64,
            weekly_hour: config.usize_or(id, "weekly_reset_hour", 0) as i64,
            terminal: config.string_or(id, "terminal", ""),
        }
    }
}

/// 「开一个终端，在这个目录里跑这条命令」。
///
/// 这是这个工具与平台**唯一**的接触面 —— Linux 要挨个试一张候选表，
/// Windows 用 `wt.exe` / `cmd /K`。用函数指针而不是 trait：
/// 只有一个方法、没有状态，为它造一个 trait 是白添一层。
pub type OpenTerminal = fn(preferred: &str, cwd: &str, command: &str) -> Result<(), String>;

/// 一个 AI 助手工具。
pub struct AssistantTool {
    flavor: Flavor,
    open_terminal: OpenTerminal,
    settings: Settings,
    snapshot: assistant::Snapshot,
    /// 后台扫描的结果从这里回来
    inbox: Option<Receiver<assistant::Snapshot>>,
    /// 上次开扫是什么时候
    scanned_at: i64,
    /// 有没有扫描正在跑 —— 不看这个的话会每个 tick 起一条线程
    scanning: bool,
    installed: bool,
}

impl AssistantTool {
    /// 造一个。`open_terminal` 由平台层给。
    pub fn new(flavor: Flavor, open_terminal: OpenTerminal) -> Self {
        Self {
            flavor,
            open_terminal,
            settings: Settings::read(&Config::new(), id_of(flavor)),
            snapshot: assistant::Snapshot::default(),
            inbox: None,
            scanned_at: 0,
            scanning: false,
            installed: false,
        }
    }

    /// 起一次后台扫描。已经在扫就不重复起。
    fn start_scan(&mut self) {
        if self.scanning {
            return;
        }
        self.scanning = true;
        self.scanned_at = now_seconds();
        let (tx, rx) = channel();
        self.inbox = Some(rx);
        let flavor = self.flavor;
        let now = self.scanned_at;
        std::thread::spawn(move || {
            let _ = tx.send(assistant::scan(flavor, now));
        });
    }

    /// 当前的 5 小时窗口。
    fn five_hour(&self) -> Option<Window> {
        aiusage::last_active_block(
            &self.snapshot.entries,
            aiusage::FIVE_HOUR,
            now_seconds(),
        )
    }

    /// 当前的周窗口。固定锚点与滚动块是两条路。
    fn weekly(&self) -> Option<Window> {
        let now = now_seconds();
        if self.settings.weekly_fixed {
            let start = aiusage::week_anchor_before(
                now,
                self.settings.weekly_weekday,
                self.settings.weekly_hour,
            );
            return Some(aiusage::fixed_week_window(&self.snapshot.entries, start));
        }
        aiusage::last_active_block(&self.snapshot.entries, aiusage::ONE_WEEK, now)
    }

    /// 一个窗口在菜单里显示成一行。
    fn window_line(&self, label: &str, window: Option<&Window>, budget: i64) -> String {
        let now = now_seconds();
        let Some(window) = window else {
            return format!("{label}：这段时间还没用过");
        };
        let tokens = aiusage::short_tokens(window.totals.tokens());
        let left = aiusage::short_duration(window.seconds_until_reset(now));
        let percent = match window.percent_of(budget) {
            Some(p) => format!(" · {p:.0}%"),
            None => String::new(),
        };
        // 有认不出价格的模型时说清楚，别让用户以为费用就这么点
        let cost = if window.totals.unpriced {
            format!(" · ${:.2}+", window.totals.cost_usd)
        } else {
            format!(" · ${:.2}", window.totals.cost_usd)
        };
        format!("{label}：{tokens}{percent}{cost} · {left}后重置")
    }

    /// 续接一个会话：开一个终端，把命令交给它。
    fn resume(&self, session_id: &str) -> Result<String, String> {
        let session = self
            .snapshot
            .sessions
            .iter()
            .find(|s| s.id == session_id)
            .ok_or("这个会话已经不在了（可能刚被清掉）")?;
        let command = match self.flavor {
            Flavor::ClaudeCode => format!("claude --resume {}", shell_quote(&session.id)),
            Flavor::Codex => format!("codex resume {}", shell_quote(&session.id)),
        };
        (self.open_terminal)(&self.settings.terminal, &session.cwd, &command)?;
        Ok(format!("已在终端里续接「{}」", session.display_title()))
    }
}

/// 把一段文字包成 shell 里安全的单个参数。
///
/// 会话 id 是从**文件名**来的，而文件名是别人家程序起的 —— 虽然目前都是
/// UUID，但把它直接拼进命令行是一条不该留的路。
pub fn shell_quote(text: &str) -> String {
    if !text.is_empty()
        && text
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/'))
    {
        return text.to_string();
    }
    // 单引号里只有单引号本身需要处理
    format!("'{}'", text.replace('\'', r"'\''"))
}

impl ToolModule for AssistantTool {
    fn id(&self) -> &str {
        id_of(self.flavor)
    }

    fn name(&self) -> &str {
        match self.flavor {
            Flavor::ClaudeCode => "Claude Code",
            Flavor::Codex => "Codex",
        }
    }

    fn menu_items(&self) -> Vec<MenuItem> {
        // 只读内存里的快照，零磁盘 IO
        if !self.installed {
            return vec![MenuItem::disabled(&assistant::not_installed_hint(self.flavor))];
        }
        let mut items = vec![
            MenuItem::disabled(&self.window_line(
                "5 小时",
                self.five_hour().as_ref(),
                self.settings.five_hour_budget,
            )),
            MenuItem::disabled(&self.window_line(
                "本周",
                self.weekly().as_ref(),
                self.settings.weekly_budget,
            )),
            MenuItem::Separator,
        ];

        if self.snapshot.sessions.is_empty() {
            items.push(MenuItem::disabled("最近还没有会话"));
        } else {
            for session in self.snapshot.sessions.iter().take(assistant::MENU_SESSIONS) {
                items.push(MenuItem::action(
                    &action(self.flavor, &format!("{RESUME}{}", session.id)),
                    &session.display_title(),
                ));
            }
        }
        items.push(MenuItem::Separator);
        items.push(MenuItem::action(&action(self.flavor, REPORT), "用量报表…"));
        items.push(MenuItem::action(&action(self.flavor, REFRESH), "立刻刷新"));
        items
    }

    fn hotkeys(&self) -> Vec<HotkeySpec> {
        // 纯菜单操作
        Vec::new()
    }

    fn settings_page(&self) -> Option<SettingsPage> {
        let title = match self.flavor {
            Flavor::ClaudeCode => "Claude Code",
            Flavor::Codex => "Codex",
        };
        Some(SettingsPage::new(
            id_of(self.flavor),
            title,
            vec![
                Field::number("five_hour_budget", "5 小时额度（千 token）", 0, 0, 100_000)
                    .with_help("填了才会显示百分比；0 = 不显示"),
                Field::number("weekly_budget", "每周额度（千 token）", 0, 0, 1_000_000)
                    .with_help("同上"),
                Field::toggle("weekly_reset_fixed", "周额度按固定时间重置", false)
                    .with_help("关掉的话按「最后一次用量往后 7 天」滚动计算"),
                Field::number("weekly_reset_weekday", "周几重置（0=周日）", 1, 0, 6),
                Field::number("weekly_reset_hour", "几点重置", 0, 0, 23),
                Field::text("terminal", "用哪个终端", "", "留空自动挑")
                    .with_help("续接会话时开哪个终端；留空自动挑一个装了的"),
            ],
        ))
    }

    fn activate(&mut self, config: &Config) {
        self.settings = Settings::read(config, id_of(self.flavor));
        self.installed = assistant::installed(self.flavor);
        // 没装就不起后台任务（约定 7）
        if self.installed {
            self.start_scan();
        }
    }

    fn config_changed(&mut self, config: &Config) {
        self.settings = Settings::read(config, id_of(self.flavor));
    }

    fn tick(&mut self) -> bool {
        let mut changed = false;
        // 后台扫完了就收下
        if let Some(inbox) = &self.inbox {
            if let Ok(snapshot) = inbox.try_recv() {
                self.snapshot = snapshot;
                self.scanning = false;
                self.inbox = None;
                changed = true;
            }
        }
        // 到点了再扫一遍
        if self.installed
            && !self.scanning
            && now_seconds() - self.scanned_at >= RESCAN_SECONDS
        {
            self.start_scan();
        }
        changed
    }

    fn perform(&mut self, action_id: &str) -> Result<String, String> {
        let prefix = format!("{}.", id_of(self.flavor));
        let suffix = action_id
            .strip_prefix(&prefix)
            .ok_or_else(|| format!("助手工具不认识动作 {action_id}"))?;

        match suffix {
            REFRESH => {
                if !self.installed {
                    return Err(assistant::not_installed_hint(self.flavor));
                }
                // 强制重扫：把上次时间抹掉，`start_scan` 才不会被 60 秒的节流挡住
                self.scanned_at = 0;
                self.start_scan();
                Ok("正在重新统计…".to_string())
            }
            REPORT => {
                if self.snapshot.entries.is_empty() {
                    return Err("最近还没有用量可以统计".to_string());
                }
                println!("{}", self.report_text());
                Ok("报表已打印到标准输出".to_string())
            }
            other => match other.strip_prefix(RESUME) {
                Some(session_id) => self.resume(session_id),
                None => Err(format!("助手工具不认识动作 {action_id}")),
            },
        }
    }
}

impl AssistantTool {
    /// 报表的文本形式。
    fn report_text(&self) -> String {
        let mut out = String::new();
        for (title, group) in [
            ("按天", aiusage::GroupBy::Day),
            ("按项目", aiusage::GroupBy::Project),
            ("按模型", aiusage::GroupBy::Model),
        ] {
            out.push_str(&format!("\n{title}\n"));
            for bucket in aiusage::report(&self.snapshot.entries, group).iter().take(10) {
                out.push_str(&format!(
                    "  {:<28} {:>8}  ${:.2}{}\n",
                    bucket.label,
                    aiusage::short_tokens(bucket.totals.tokens()),
                    bucket.totals.cost_usd,
                    if bucket.totals.unpriced { "+" } else { "" }
                ));
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use baobox_core::aiusage::Entry;

    /// 测试用的假终端：什么都不做，只说「成功了」。
    fn fake_terminal(_: &str, _: &str, _: &str) -> Result<(), String> {
        Ok(())
    }

    fn tool(flavor: Flavor) -> AssistantTool {
        AssistantTool::new(flavor, fake_terminal)
    }

    #[test]
    fn the_two_flavours_have_different_tool_ids_and_never_collide() {
        assert_ne!(CLAUDE_ID, CODEX_ID);
        assert_eq!(tool(Flavor::ClaudeCode).id(), CLAUDE_ID);
        assert_eq!(tool(Flavor::Codex).id(), CODEX_ID);
    }

    #[test]
    fn every_menu_action_is_dispatchable_to_the_right_flavour() {
        for flavor in [Flavor::ClaudeCode, Flavor::Codex] {
            let mut t = tool(flavor);
            t.installed = true;
            for item in t.menu_items() {
                if let MenuItem::Action { id, enabled, .. } = item {
                    if enabled {
                        assert!(
                            id.starts_with(&format!("{}.", id_of(flavor))),
                            "{id} 会派发到别的工具头上"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn an_unknown_action_is_refused() {
        let mut t = tool(Flavor::ClaudeCode);
        assert!(t.perform("claudecode.nope").unwrap_err().contains("不认识"));
        // 另一个工具的动作也不该被认领
        assert!(t.perform("aitools.refresh").unwrap_err().contains("不认识"));
    }

    #[test]
    fn every_declared_setting_is_actually_read_somewhere() {
        let page = tool(Flavor::ClaudeCode).settings_page().unwrap();
        let source = include_str!("assistant_tool.rs");
        for key in crate::settings::declared_keys(&page) {
            let mentions = source.matches(&format!("\"{key}\"")).count();
            assert!(
                mentions >= 2,
                "{key} 在设置里声明了却没人读它（源码里只出现 {mentions} 次）"
            );
        }
    }

    #[test]
    fn the_settings_section_matches_the_tool_id() {
        for flavor in [Flavor::ClaudeCode, Flavor::Codex] {
            let t = tool(flavor);
            assert_eq!(t.settings_page().unwrap().section, t.id());
        }
    }

    #[test]
    fn a_tool_that_is_not_installed_shows_one_greyed_hint_and_nothing_else() {
        // 菜单项消失的话用户会以为程序坏了；报错更糟 —— 没装是常态
        let t = tool(Flavor::ClaudeCode);
        let items = t.menu_items();
        assert_eq!(items.len(), 1);
        assert!(matches!(&items[0], MenuItem::Action { enabled: false, .. }));
    }

    #[test]
    fn refreshing_a_tool_that_is_not_installed_explains_instead_of_pretending() {
        let mut t = tool(Flavor::ClaudeCode);
        assert!(t.perform("claudecode.refresh").unwrap_err().contains(".claude"));
    }

    #[test]
    fn a_window_line_reports_tokens_cost_and_the_countdown() {
        let mut t = tool(Flavor::ClaudeCode);
        let now = now_seconds();
        t.snapshot.entries = vec![Entry {
            timestamp: now,
            input: 1_000_000,
            output: 0,
            cache_write: 0,
            cache_read: 0,
            model_id: "claude-sonnet-4".into(),
            project: "p".into(),
        }];
        let line = t.window_line("5 小时", t.five_hour().as_ref(), 0);
        assert!(line.contains("1.0M"), "{line}");
        assert!(line.contains("$3.00"), "{line}");
        assert!(line.contains("重置"), "{line}");
        assert!(!line.contains('%'), "没设额度就不该显示百分比：{line}");
    }

    #[test]
    fn an_unpriced_model_makes_the_cost_show_a_plus_sign() {
        // 不标的话用户会以为费用就这么点
        let mut t = tool(Flavor::ClaudeCode);
        let now = now_seconds();
        t.snapshot.entries = vec![Entry {
            timestamp: now,
            input: 1_000_000,
            output: 0,
            cache_write: 0,
            cache_read: 0,
            model_id: "还没发布的模型".into(),
            project: "p".into(),
        }];
        assert!(t.window_line("5 小时", t.five_hour().as_ref(), 0).contains("+"));
    }

    #[test]
    fn a_window_with_no_usage_says_so_rather_than_showing_zeroes() {
        let t = tool(Flavor::ClaudeCode);
        assert!(t.window_line("5 小时", None, 0).contains("还没用过"));
    }

    #[test]
    fn a_budget_turns_on_the_percentage() {
        let mut t = tool(Flavor::ClaudeCode);
        let now = now_seconds();
        t.snapshot.entries = vec![Entry {
            timestamp: now,
            input: 500,
            output: 0,
            cache_write: 0,
            cache_read: 0,
            model_id: "sonnet".into(),
            project: "p".into(),
        }];
        let line = t.window_line("5 小时", t.five_hour().as_ref(), 1000);
        assert!(line.contains("50%"), "{line}");
    }

    #[test]
    fn a_session_id_is_quoted_before_it_reaches_a_shell() {
        // 会话 id 是从别人家程序起的文件名来的，直接拼进命令行是不该留的路
        assert_eq!(shell_quote("abc-123"), "abc-123");
        assert_eq!(shell_quote("a b"), "'a b'");
        assert_eq!(shell_quote("x;rm -rf /"), "'x;rm -rf /'");
        assert_eq!(shell_quote("it's"), r"'it'\''s'");
        assert_eq!(shell_quote(""), "''");
    }

    #[test]
    fn resuming_a_session_that_is_gone_says_so() {
        let mut t = tool(Flavor::ClaudeCode);
        assert!(t
            .perform("claudecode.resume.不存在")
            .unwrap_err()
            .contains("已经不在了"));
    }

    #[test]
    fn the_rescan_interval_is_slow_enough_not_to_keep_the_disk_spinning() {
        assert!(RESCAN_SECONDS >= 30);
        assert!(RESCAN_SECONDS <= 600);
    }
}
