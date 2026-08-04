//! AI 助手的用量：定价、分块窗口、报表。
//!
//! 对应 macOS 侧 `ClaudeUsage.swift` 与 `CodexUsage.swift` 里不碰文件系统的
//! 那一半。**Claude Code 与 Codex 用的是同一套算法**，所以这里只有一份 ——
//! 两边的会话日志字段名不同，那部分由各自的读取器负责翻译成 [`Entry`]。
//!
//! # 5 小时窗口不是「最近 5 小时」
//!
//! 这是整个模块最容易想当然的地方。官方的额度窗口是**分块**的：
//! 第一条用量把块的起点定在**那一刻向下取整到整点**，此后 5 小时内的用量
//! 都算这一块；超出 5 小时的第一条用量开**新的一块**。
//!
//! 所以「现在还剩多久」问的是「当前这一块什么时候结束」，而不是
//! 「5 小时前到现在」。按后者算的话，用户看到的剩余时间会一直是 5 小时 ——
//! 永远不动，也就永远没用。
//!
//! 周窗口用的是**同一个分块算法**，只是跨度换成 168 小时；
//! 用户也可以改成「固定锚点」（每周一 0 点重置），那条路是另算的。
//!
//! # 未知模型不猜价钱
//!
//! 定价按 model id 里的关键字匹配。认不出的**不估费用**，并且把整块标成
//! `unpriced` —— 报一个瞎猜的数字，比明说「这部分算不了」更糟。

/// 每百万 token 多少美元。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pricing {
    /// 输入
    pub input: f64,
    /// 输出
    pub output: f64,
    /// 写缓存
    pub cache_write: f64,
    /// 读缓存
    pub cache_read: f64,
}

impl Pricing {
    /// 全零 —— 认不出的模型用它，配合 `unpriced` 标记。
    pub const ZERO: Pricing = Pricing {
        input: 0.0,
        output: 0.0,
        cache_write: 0.0,
        cache_read: 0.0,
    };

    /// 按 model id 里的关键字查价。返回 `(价格, 认不认得)`。
    ///
    /// 与 macOS 侧同一张表：缓存写 = 输入 ×1.25（5 分钟 TTL 口径），
    /// 缓存读 = 输入 ×0.1。
    pub fn for_model(model_id: &str) -> (Pricing, bool) {
        let id = model_id.to_lowercase();
        if id.contains("fable") || id.contains("mythos") {
            return (Pricing::new(10.0, 50.0), true);
        }
        if id.contains("opus") {
            // Opus 4.1 / 4.0 / Claude 3 Opus 是 $15/$75；Opus 4.5 起降到 $5/$25
            if id.contains("opus-4-1")
                || id.contains("opus-4-0")
                || id.contains("opus-4-2025")
                || id.contains("3-opus")
            {
                return (Pricing::new(15.0, 75.0), true);
            }
            return (Pricing::new(5.0, 25.0), true);
        }
        if id.contains("sonnet") {
            return (Pricing::new(3.0, 15.0), true);
        }
        if id.contains("haiku") {
            return (Pricing::new(1.0, 5.0), true);
        }
        // GPT / o 系列（Codex 那边）
        if id.contains("gpt-5") || id.contains("o3") || id.contains("o4") {
            return (Pricing::new(1.25, 10.0), true);
        }
        if id.contains("gpt-4o") {
            return (Pricing::new(2.5, 10.0), true);
        }
        (Pricing::ZERO, false)
    }

    fn new(input: f64, output: f64) -> Pricing {
        Pricing {
            input,
            output,
            cache_write: input * 1.25,
            cache_read: input * 0.1,
        }
    }
}

/// 一段时间里的 token 与估算费用。
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Totals {
    /// 输入 token
    pub input: i64,
    /// 输出 token
    pub output: i64,
    /// 写缓存 token
    pub cache_write: i64,
    /// 读缓存 token
    pub cache_read: i64,
    /// 估算费用（美元）
    pub cost_usd: f64,
    /// 里面有认不出价格的模型 —— 费用是**偏低**的，界面上要标出来
    pub unpriced: bool,
}

impl Totals {
    /// 全部 token 加起来。额度是按这个算的。
    pub fn tokens(&self) -> i64 {
        self.input + self.output + self.cache_write + self.cache_read
    }

    /// 累加一条。
    pub fn add(&mut self, entry: &Entry) {
        self.input += entry.input;
        self.output += entry.output;
        self.cache_write += entry.cache_write;
        self.cache_read += entry.cache_read;
        let (price, known) = Pricing::for_model(&entry.model_id);
        if known {
            self.cost_usd += entry.input as f64 / 1e6 * price.input
                + entry.output as f64 / 1e6 * price.output
                + entry.cache_write as f64 / 1e6 * price.cache_write
                + entry.cache_read as f64 / 1e6 * price.cache_read;
        } else if entry.tokens() > 0 {
            // 有 token 却查不到价 —— 费用一定是偏低的，说清楚
            self.unpriced = true;
        }
    }
}

/// 会话日志里的一条用量记录。
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    /// Unix 秒
    pub timestamp: i64,
    /// 输入 token
    pub input: i64,
    /// 输出 token
    pub output: i64,
    /// 写缓存
    pub cache_write: i64,
    /// 读缓存
    pub cache_read: i64,
    /// 模型 id，用来查价
    pub model_id: String,
    /// 属于哪个项目（用来出报表）
    pub project: String,
}

impl Entry {
    /// 这条一共多少 token。
    pub fn tokens(&self) -> i64 {
        self.input + self.output + self.cache_write + self.cache_read
    }
}

/// 一个额度窗口。
#[derive(Debug, Clone, PartialEq)]
pub struct Window {
    /// 起点（Unix 秒）
    pub start: i64,
    /// 终点（Unix 秒）
    pub end: i64,
    /// 这一块里的用量
    pub totals: Totals,
}

impl Window {
    /// 还剩多少秒重置。已经过去的返回 0。
    pub fn seconds_until_reset(&self, now: i64) -> i64 {
        (self.end - now).max(0)
    }

    /// 用掉了额度的百分之多少。`budget` 为 0（没设）时返回 `None`。
    pub fn percent_of(&self, budget: i64) -> Option<f64> {
        if budget <= 0 {
            return None;
        }
        Some(self.totals.tokens() as f64 / budget as f64 * 100.0)
    }
}

/// 5 小时窗口的跨度。
pub const FIVE_HOUR: i64 = 5 * 3600;

/// 周窗口的跨度。
pub const ONE_WEEK: i64 = 168 * 3600;

/// 向下取整到整点。块的起点用它 —— 与官方口径一致。
pub fn floor_to_hour(timestamp: i64) -> i64 {
    timestamp.div_euclid(3600) * 3600
}

/// 按跨度分块，返回**当前还活着**的那一块。
///
/// 分块规则：第一条用量把起点定在「那一刻向下取整到整点」；
/// 某条用量的时间超过 `块起点 + span` 时，从它开始开新的一块。
/// 最后一块只有在 `now <= 它的终点` 时才算活着 —— 否则额度早就重置了，
/// 报一个已经过期的窗口只会误导。
pub fn last_active_block(entries: &[Entry], span: i64, now: i64) -> Option<Window> {
    if entries.is_empty() {
        return None;
    }
    let mut sorted: Vec<&Entry> = entries.iter().collect();
    sorted.sort_by_key(|e| e.timestamp);

    let mut start: Option<i64> = None;
    let mut totals = Totals::default();
    let mut last: Option<Window> = None;

    for entry in sorted {
        match start {
            Some(current) if entry.timestamp > current + span => {
                last = Some(Window {
                    start: current,
                    end: current + span,
                    totals,
                });
                start = Some(floor_to_hour(entry.timestamp));
                totals = Totals::default();
            }
            None => {
                start = Some(floor_to_hour(entry.timestamp));
                totals = Totals::default();
            }
            _ => {}
        }
        totals.add(entry);
    }
    if let Some(current) = start {
        last = Some(Window {
            start: current,
            end: current + span,
            totals,
        });
    }

    let window = last?;
    // 已经过期的块不算「当前窗口」—— 额度早重置了
    if now > window.end {
        return None;
    }
    Some(window)
}

/// 固定锚点的周窗口：`[start, start + 7 天)` 之间的用量。
///
/// 与滚动块不同，**即使一条用量都没有也返回一个窗口** —— 它有明确的起止
/// 与倒计时可以显示，而「这周还没用过」本身就是有用的信息。
pub fn fixed_week_window(entries: &[Entry], start: i64) -> Window {
    let end = start + ONE_WEEK;
    let mut totals = Totals::default();
    for entry in entries {
        if entry.timestamp >= start && entry.timestamp < end {
            totals.add(entry);
        }
    }
    Window { start, end, totals }
}

/// 从 `now` 往回找最近一次「周几的几点」。
///
/// `weekday` 用 0 = 周日 … 6 = 周六（与 `civil` 里的算法一致）。
pub fn week_anchor_before(now: i64, weekday: i64, hour: i64) -> i64 {
    let hour = hour.clamp(0, 23);
    let weekday = weekday.rem_euclid(7);
    // 1970-01-01 是周四（4）
    let days = now.div_euclid(86_400);
    let today = (days + 4).rem_euclid(7);
    let seconds_today = now.rem_euclid(86_400);

    let mut back = (today - weekday).rem_euclid(7);
    // 今天就是那一天，但还没到点 —— 那锚点在上周
    if back == 0 && seconds_today < hour * 3600 {
        back = 7;
    }
    (days - back) * 86_400 + hour * 3600
}

/// 报表里的一格。
#[derive(Debug, Clone, PartialEq)]
pub struct Bucket {
    /// 分组的名字（日期 / 项目 / 模型）
    pub label: String,
    /// 这一格的用量
    pub totals: Totals,
}

/// 按什么分组。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupBy {
    /// 按天（UTC）
    Day,
    /// 按项目
    Project,
    /// 按模型
    Model,
}

/// 出一张报表，**用量从多到少**排。
///
/// 按用量排而不是按名字：用户看报表是想知道「钱花在哪了」，
/// 按字母序排的话最大的那一项可能在第七行。
pub fn report(entries: &[Entry], group: GroupBy) -> Vec<Bucket> {
    let mut buckets: Vec<Bucket> = Vec::new();
    for entry in entries {
        let label = match group {
            GroupBy::Day => day_label(entry.timestamp),
            GroupBy::Project => {
                if entry.project.is_empty() {
                    "（未知项目）".to_string()
                } else {
                    entry.project.clone()
                }
            }
            GroupBy::Model => {
                if entry.model_id.is_empty() {
                    "（未知模型）".to_string()
                } else {
                    entry.model_id.clone()
                }
            }
        };
        match buckets.iter_mut().find(|b| b.label == label) {
            Some(bucket) => bucket.totals.add(entry),
            None => {
                let mut totals = Totals::default();
                totals.add(entry);
                buckets.push(Bucket { label, totals });
            }
        }
    }
    buckets.sort_by(|a, b| {
        b.totals
            .tokens()
            .cmp(&a.totals.tokens())
            .then(a.label.cmp(&b.label))
    });
    buckets
}

/// `2026-08-04` 这样的一天（UTC）。
fn day_label(timestamp: i64) -> String {
    let parts = crate::filename::DateParts::from_unix(timestamp);
    format!("{:04}-{:02}-{:02}", parts.year, parts.month, parts.day)
}

/// 把一个 token 数写成人能读的样子（`1.2M` / `340k`）。
///
/// 菜单里一行装不下 `1234567 tokens`，而用户要的本来也只是个量级。
pub fn short_tokens(count: i64) -> String {
    if count >= 1_000_000 {
        format!("{:.1}M", count as f64 / 1_000_000.0)
    } else if count >= 1_000 {
        format!("{:.0}k", count as f64 / 1_000.0)
    } else {
        count.to_string()
    }
}

/// 把剩余秒数写成 `2 小时 15 分`。
pub fn short_duration(seconds: i64) -> String {
    let seconds = seconds.max(0);
    let hours = seconds / 3600;
    let minutes = (seconds % 3600) / 60;
    if hours > 0 {
        format!("{hours} 小时 {minutes} 分")
    } else if minutes > 0 {
        format!("{minutes} 分")
    } else {
        "不到 1 分钟".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 2026-08-04 12:34:56 UTC
    const NOON: i64 = 1_785_846_896;

    fn entry(at: i64, tokens: i64, model: &str) -> Entry {
        Entry {
            timestamp: at,
            input: tokens,
            output: 0,
            cache_write: 0,
            cache_read: 0,
            model_id: model.to_string(),
            project: "proj".to_string(),
        }
    }

    #[test]
    fn a_block_starts_at_the_hour_not_at_the_first_message() {
        // 官方口径是向下取整到整点；不取整的话，同一段对话算出来的
        // 「还剩多久」会跟 claude 自己报的差几十分钟
        let at = floor_to_hour(NOON) + 1800; // 半点
        let window = last_active_block(&[entry(at, 100, "sonnet")], FIVE_HOUR, at).unwrap();
        assert_eq!(window.start, floor_to_hour(at));
        assert_eq!(window.start % 3600, 0);
        assert_eq!(window.end, window.start + FIVE_HOUR);
    }

    #[test]
    fn usage_beyond_five_hours_opens_a_new_block() {
        let first = floor_to_hour(NOON);
        let later = first + FIVE_HOUR + 60;
        let entries = vec![entry(first, 100, "sonnet"), entry(later, 7, "sonnet")];
        let window = last_active_block(&entries, FIVE_HOUR, later).unwrap();
        // 当前这一块只该有第二条
        assert_eq!(window.totals.input, 7);
        assert_eq!(window.start, floor_to_hour(later));
    }

    #[test]
    fn usage_inside_the_same_block_accumulates() {
        let first = floor_to_hour(NOON);
        let entries = vec![
            entry(first, 100, "sonnet"),
            entry(first + 3600, 30, "sonnet"),
            entry(first + FIVE_HOUR - 1, 5, "sonnet"),
        ];
        let window = last_active_block(&entries, FIVE_HOUR, first + FIVE_HOUR - 1).unwrap();
        assert_eq!(window.totals.input, 135);
    }

    #[test]
    fn an_expired_block_is_not_reported_as_the_current_window() {
        // 报一个早就重置了的窗口只会误导
        let long_ago = floor_to_hour(NOON) - 10 * FIVE_HOUR;
        let entries = vec![entry(long_ago, 100, "sonnet")];
        assert!(last_active_block(&entries, FIVE_HOUR, NOON).is_none());
    }

    #[test]
    fn entries_are_sorted_so_out_of_order_logs_still_block_correctly() {
        // 会话日志是按文件读的，跨文件时间戳一定不是有序的
        let base = floor_to_hour(NOON);
        let entries = vec![
            entry(base + FIVE_HOUR + 60, 7, "sonnet"),
            entry(base, 100, "sonnet"),
        ];
        let window = last_active_block(&entries, FIVE_HOUR, base + FIVE_HOUR + 60).unwrap();
        assert_eq!(window.totals.input, 7, "乱序也要分对块");
    }

    #[test]
    fn the_remaining_time_counts_down_instead_of_staying_at_five_hours() {
        // 按「最近 5 小时」算的话剩余会永远是 5 小时 —— 永远不动也就永远没用
        let start = floor_to_hour(NOON);
        let window = last_active_block(&[entry(start, 1, "sonnet")], FIVE_HOUR, start).unwrap();
        assert_eq!(window.seconds_until_reset(start), FIVE_HOUR);
        assert_eq!(window.seconds_until_reset(start + 3600), FIVE_HOUR - 3600);
        assert_eq!(window.seconds_until_reset(start + FIVE_HOUR + 999), 0);
    }

    #[test]
    fn an_unknown_model_is_flagged_rather_than_priced_by_guesswork() {
        let mut totals = Totals::default();
        totals.add(&entry(NOON, 1_000_000, "某个还没发布的模型"));
        assert_eq!(totals.cost_usd, 0.0);
        assert!(totals.unpriced, "算不了就要说算不了，不能报个瞎猜的数");

        let mut known = Totals::default();
        known.add(&entry(NOON, 1_000_000, "claude-sonnet-4"));
        assert_eq!(known.cost_usd, 3.0);
        assert!(!known.unpriced);
    }

    #[test]
    fn a_zero_token_entry_of_an_unknown_model_does_not_raise_the_flag() {
        // 没有 token 就没有费用，标出来只会让用户白担心
        let mut totals = Totals::default();
        totals.add(&entry(NOON, 0, "未知"));
        assert!(!totals.unpriced);
    }

    #[test]
    fn opus_pricing_distinguishes_the_generations() {
        // 4.5 起降价了，一张表算到底会把老会话的费用报低三倍
        let (old, _) = Pricing::for_model("claude-opus-4-1-20250805");
        let (new, _) = Pricing::for_model("claude-opus-5");
        assert_eq!((old.input, old.output), (15.0, 75.0));
        assert_eq!((new.input, new.output), (5.0, 25.0));
    }

    #[test]
    fn cache_pricing_follows_the_published_ratios() {
        let (p, _) = Pricing::for_model("sonnet");
        assert_eq!(p.cache_write, p.input * 1.25);
        assert_eq!(p.cache_read, p.input * 0.1);
    }

    #[test]
    fn the_fixed_week_window_exists_even_with_no_usage_at_all() {
        // 它有明确的起止与倒计时可以显示，而「这周还没用过」本身就是信息
        let start = floor_to_hour(NOON);
        let window = fixed_week_window(&[], start);
        assert_eq!(window.totals.tokens(), 0);
        assert_eq!(window.end - window.start, ONE_WEEK);
    }

    #[test]
    fn the_fixed_week_window_ignores_usage_outside_it() {
        let start = floor_to_hour(NOON);
        let entries = vec![
            entry(start - 10, 5, "sonnet"),
            entry(start, 100, "sonnet"),
            entry(start + ONE_WEEK, 7, "sonnet"),
        ];
        assert_eq!(fixed_week_window(&entries, start).totals.input, 100);
    }

    #[test]
    fn the_week_anchor_lands_on_the_requested_weekday_and_hour() {
        // 1970-01-01 是周四
        let thursday_noon = 12 * 3600;
        // 要「周四 0 点」——就是今天
        let anchor = week_anchor_before(thursday_noon, 4, 0);
        assert_eq!(anchor, 0);
        // 要「周四 18 点」——今天还没到，所以是上周四
        let earlier = week_anchor_before(thursday_noon, 4, 18);
        assert_eq!(earlier, -7 * 86_400 + 18 * 3600);
    }

    #[test]
    fn the_week_anchor_never_lands_in_the_future() {
        for weekday in 0..7 {
            for hour in [0, 9, 23] {
                let anchor = week_anchor_before(NOON, weekday, hour);
                assert!(anchor <= NOON, "周{weekday} {hour} 点算出来跑到未来去了");
                assert!(NOON - anchor < 8 * 86_400, "也不该退到八天以前");
            }
        }
    }

    #[test]
    fn a_report_is_sorted_by_usage_not_by_name() {
        // 用户看报表是想知道钱花在哪了，按字母排的话最大那项可能在第七行
        let entries = vec![
            Entry {
                project: "zzz".into(),
                ..entry(NOON, 1000, "sonnet")
            },
            Entry {
                project: "aaa".into(),
                ..entry(NOON, 10, "sonnet")
            },
        ];
        let buckets = report(&entries, GroupBy::Project);
        assert_eq!(buckets[0].label, "zzz");
        assert_eq!(buckets[0].totals.input, 1000);
    }

    #[test]
    fn grouping_by_day_uses_the_calendar_not_a_rolling_24h() {
        let entries = vec![entry(NOON, 5, "sonnet"), entry(NOON + 86_400, 5, "sonnet")];
        let buckets = report(&entries, GroupBy::Day);
        assert_eq!(buckets.len(), 2);
        assert!(buckets[0].label.starts_with("2026-08-0"));
    }

    #[test]
    fn empty_labels_get_a_readable_placeholder_instead_of_a_blank_row() {
        let blank = Entry {
            project: String::new(),
            model_id: String::new(),
            ..entry(NOON, 5, "")
        };
        assert!(report(&[blank.clone()], GroupBy::Project)[0]
            .label
            .contains("未知"));
        assert!(report(&[blank], GroupBy::Model)[0].label.contains("未知"));
    }

    #[test]
    fn a_budget_of_zero_means_no_percentage_rather_than_a_division_by_zero() {
        let window = Window {
            start: 0,
            end: FIVE_HOUR,
            totals: Totals {
                input: 500,
                ..Default::default()
            },
        };
        assert_eq!(window.percent_of(0), None);
        assert_eq!(window.percent_of(-1), None);
        assert_eq!(window.percent_of(1000), Some(50.0));
    }

    #[test]
    fn big_numbers_are_shortened_so_the_menu_line_fits() {
        assert_eq!(short_tokens(999), "999");
        assert_eq!(short_tokens(1_500), "2k");
        assert_eq!(short_tokens(1_234_567), "1.2M");
        assert_eq!(short_tokens(0), "0");
    }

    #[test]
    fn a_countdown_reads_naturally_at_every_magnitude() {
        assert_eq!(short_duration(2 * 3600 + 15 * 60), "2 小时 15 分");
        assert_eq!(short_duration(15 * 60), "15 分");
        assert_eq!(short_duration(30), "不到 1 分钟");
        assert_eq!(short_duration(-5), "不到 1 分钟");
    }
}
