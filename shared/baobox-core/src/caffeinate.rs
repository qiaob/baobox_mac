//! 防休眠：时长预设、到期判定、状态文案。
//!
//! 对应 macOS 侧 `CaffeinateController.swift` 里不碰 IOKit 的那一半。
//! **「什么时候该到期、菜单上写什么」在这里**，三个平台不会各写各的；
//! 「怎么让系统别睡」是平台的事（IOPMAssertion / DBus inhibit /
//! `SetThreadExecutionState`）。
//!
//! # 为什么「无限期」不用一个很大的数字表示
//!
//! 用 `i64::MAX` 之类当哨兵，加法会溢出、比较会在时区/时钟调整时出怪事，
//! 而且每处判断都得记得「这个数是特殊的」。这里用 `Option<i64>`：
//! `None` 就是无限期，编译器会逼着每个分支都想清楚。

/// 一档时长预设。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Preset {
    /// 菜单上的字
    pub title: &'static str,
    /// 持续多少秒；`None` = 无限期
    pub seconds: Option<i64>,
}

/// 菜单里的预设，顺序就是显示顺序。与 macOS 版一致。
pub const PRESETS: [Preset; 4] = [
    Preset {
        title: "15 分钟",
        seconds: Some(15 * 60),
    },
    Preset {
        title: "1 小时",
        seconds: Some(60 * 60),
    },
    Preset {
        title: "2 小时",
        seconds: Some(2 * 60 * 60),
    },
    Preset {
        title: "一直开着",
        seconds: None,
    },
];

/// 配置里「默认时长」用的值，与 [`PRESETS`] 一一对应。
///
/// 存的是秒数的字符串；`0` 表示无限期 —— 配置文件是给人看也给人编的，
/// 一个负数哨兵（mac 侧用的 -1）在 INI 里比 `0` 难认。
pub const DEFAULT_DURATION_CHOICES: [(&str, &str); 4] = [
    ("900", "15 分钟"),
    ("3600", "1 小时"),
    ("7200", "2 小时"),
    ("0", "一直开着"),
];

/// 把配置里的那个字符串读成秒数。认不出的当无限期。
pub fn duration_from_config(value: &str) -> Option<i64> {
    match value.trim().parse::<i64>() {
        Ok(seconds) if seconds > 0 => Some(seconds),
        _ => None,
    }
}

/// 一次正在生效的防休眠。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Session {
    /// 什么时候到期（Unix 秒）；`None` = 无限期
    pub until: Option<i64>,
    /// 用户当初选的是哪一档（秒），用来在菜单里打勾。
    ///
    /// **不能用「剩余时间」反推**：开了 15 分钟之后过一会儿再看菜单，
    /// 剩余是 893 秒，跟任何一档预设都不相等，四个预设会一个勾都没有 ——
    /// 看着像是防休眠被关掉了。mac 侧踩过这个坑，注释还在。
    pub requested: Option<i64>,
}

impl Session {
    /// 从「现在」和「要多久」造一次会话。
    pub fn start(now: i64, duration: Option<i64>) -> Session {
        Session {
            until: duration.map(|seconds| now + seconds),
            requested: duration,
        }
    }

    /// 到点了吗。无限期的永远没到。
    pub fn is_expired(&self, now: i64) -> bool {
        match self.until {
            Some(until) => now >= until,
            None => false,
        }
    }

    /// 还剩几分钟（向上取整）。无限期返回 `None`。
    ///
    /// 向上取整而不是四舍五入：剩 30 秒时显示「还有 1 分钟」比「还有 0 分钟」
    /// 诚实 —— 后者会让用户以为已经失效了。
    pub fn remaining_minutes(&self, now: i64) -> Option<i64> {
        let until = self.until?;
        let seconds = (until - now).max(0);
        Some((seconds + 59) / 60)
    }

    /// 这一档预设是不是当前生效的那个（菜单打勾用）。
    pub fn matches(&self, preset: Option<i64>) -> bool {
        self.requested == preset
    }
}

/// 菜单里那行状态。`None` = 没开着。
pub fn status_text(session: Option<&Session>, now: i64) -> String {
    match session {
        None => "未开启（系统按自己的设置休眠）".to_string(),
        Some(session) => match session.remaining_minutes(now) {
            None => "已开启 · 一直开着".to_string(),
            Some(minutes) => format!("已开启 · 还有 {minutes} 分钟"),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_785_760_000;

    #[test]
    fn a_finite_session_expires_exactly_when_it_should() {
        let session = Session::start(NOW, Some(900));
        assert!(!session.is_expired(NOW));
        assert!(!session.is_expired(NOW + 899));
        assert!(session.is_expired(NOW + 900), "到点就该算过期");
        assert!(session.is_expired(NOW + 10_000));
    }

    #[test]
    fn an_infinite_session_never_expires() {
        let session = Session::start(NOW, None);
        assert!(!session.is_expired(NOW + 10_000_000));
        assert_eq!(session.remaining_minutes(NOW), None);
    }

    #[test]
    fn remaining_minutes_round_up_so_the_last_seconds_are_not_shown_as_zero() {
        let session = Session::start(NOW, Some(900));
        assert_eq!(session.remaining_minutes(NOW), Some(15));
        // 过了 1 秒还剩 899 秒 —— 向上取整成 15 分钟
        assert_eq!(session.remaining_minutes(NOW + 1), Some(15));
        // 剩 30 秒时显示「还有 1 分钟」比「0 分钟」诚实
        assert_eq!(session.remaining_minutes(NOW + 870), Some(1));
        assert_eq!(session.remaining_minutes(NOW + 900), Some(0));
    }

    #[test]
    fn a_clock_that_jumped_forward_does_not_produce_negative_time() {
        // 系统时钟被调过、或者机器睡了一觉醒来，都会让 now 冲到 until 之后
        let session = Session::start(NOW, Some(900));
        assert_eq!(session.remaining_minutes(NOW + 100_000), Some(0));
    }

    #[test]
    fn the_ticked_preset_follows_what_the_user_picked_not_what_is_left() {
        // 开了 15 分钟之后过一会儿再看菜单，剩余是 893 秒 —— 拿它去比
        // 四个预设会一个勾都没有，看着像是防休眠被关掉了
        let session = Session::start(NOW, Some(900));
        assert!(session.matches(Some(900)), "选的那一档要一直打着勾");
        assert!(!session.matches(Some(3600)));
        assert!(!session.matches(None));

        let forever = Session::start(NOW, None);
        assert!(forever.matches(None));
        assert!(!forever.matches(Some(900)));
    }

    #[test]
    fn the_status_line_says_what_is_going_on_in_all_three_states() {
        assert!(status_text(None, NOW).contains("未开启"));

        let forever = Session::start(NOW, None);
        assert!(status_text(Some(&forever), NOW).contains("一直"));

        let timed = Session::start(NOW, Some(3600));
        let text = status_text(Some(&timed), NOW);
        assert!(text.contains("60"), "要报出还剩多久：{text}");
    }

    #[test]
    fn the_config_value_is_read_leniently_and_zero_means_forever() {
        assert_eq!(duration_from_config("900"), Some(900));
        assert_eq!(duration_from_config("  3600  "), Some(3600));
        // 0 = 一直开着；配置文件是给人编的，0 比 -1 好认
        assert_eq!(duration_from_config("0"), None);
        assert_eq!(duration_from_config("-1"), None);
        // 认不出的按「一直开着」，而不是让功能整个失效
        assert_eq!(duration_from_config("香蕉"), None);
        assert_eq!(duration_from_config(""), None);
    }

    #[test]
    fn every_preset_has_a_matching_config_choice() {
        // 两张表对不齐的话，用户在设置里选的默认时长会跟菜单里的预设对不上
        assert_eq!(PRESETS.len(), DEFAULT_DURATION_CHOICES.len());
        for (preset, (stored, title)) in PRESETS.iter().zip(DEFAULT_DURATION_CHOICES.iter()) {
            assert_eq!(&preset.title, title);
            assert_eq!(preset.seconds, duration_from_config(stored));
        }
    }

    #[test]
    fn presets_are_listed_from_short_to_long_with_forever_last() {
        let finite: Vec<i64> = PRESETS.iter().filter_map(|p| p.seconds).collect();
        let mut sorted = finite.clone();
        sorted.sort_unstable();
        assert_eq!(finite, sorted, "预设该从短到长排");
        assert_eq!(PRESETS.last().unwrap().seconds, None, "「一直开着」排最后");
    }
}
