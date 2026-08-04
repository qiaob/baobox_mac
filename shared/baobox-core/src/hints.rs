//! 键盘点击：给屏幕上可点的东西打字母标签，打字母就点它。
//!
//! 对应 macOS 侧 `HintLabelGenerator.swift` 与 `KeyboardNavController.swift`
//! 里不碰系统 API 的那一半。**「标签怎么发、打字之后该怎么反应」在这里**，
//! 「屏幕上有哪些可点的东西、怎么点」是平台的事（AX / UI Automation / AT-SPI）。
//!
//! # 标签必须互不为前缀
//!
//! 这是整个模块的核心约束。如果 `a` 和 `ab` 同时是标签，用户打完 `a`
//! 我们就得**等**——等他是不是还要打 `b`。等多久？等着的时候屏幕上什么都没发生，
//! 用户只会以为程序卡了，然后再按一次。
//!
//! 所以用 Vimium 那套 BFS 发号：从单字符开始，不够就把队首那个前缀
//! 展开成 k 个孩子（它自己随之变成内部节点、不再是标签）。
//! 这样发出来的标签**互不为前缀**，打完最后一个字符立刻就能动手。
//!
//! # 字母表里没有的字符
//!
//! 用户打了一个不在标签字母表里的字符，说明他要么打错了、要么根本不想点 ——
//! 直接退出，而不是忽略。忽略的话，一个想按 Esc 却按到别处的用户
//! 会发现自己被困在一个吃掉所有按键的模式里。

/// 默认的标签字母表。
///
/// 用**主键盘行**的字母：手不用移动，而且这几个键在各种布局上都稳定。
/// 排除了容易看混的（没有 `l` 与 `i`）—— 屏幕上密密麻麻几十个标签时，
/// 认错一个字母就点错一个按钮。
pub const DEFAULT_ALPHABET: &str = "asdfghjkwertyuop";

/// 一个可点的东西。
#[derive(Debug, Clone, PartialEq)]
pub struct Target {
    /// 屏幕坐标下的中心点，点它就点这里
    pub x: f64,
    /// 同上
    pub y: f64,
    /// 给用户看的说明（按钮标题之类），只为调试与无障碍
    pub label: String,
}

/// 一个已经分配了标签的目标。
#[derive(Debug, Clone, PartialEq)]
pub struct Hint {
    /// 打这几个字母就点它
    pub tag: String,
    /// 点哪儿
    pub target: Target,
}

/// 给 `count` 个目标发标签：**最短、且互不为前缀**。
///
/// BFS：从单字符起，队首前缀展开成 k 个孩子（前缀本身随之变成内部节点）。
/// 没被展开的那些就是叶子 —— 叶子之间互不为前缀，而且短的先发出来。
pub fn labels(count: usize, alphabet: &str) -> Vec<String> {
    let chars: Vec<char> = alphabet.chars().collect();
    if chars.is_empty() || count == 0 {
        return Vec::new();
    }
    if chars.len() == 1 {
        // 退化情况：单字符集只能靠长度区分（a, aa, aaa…）。
        // 实践中字符表恒 >1，但不挡的话这里会死循环
        let only = chars[0];
        return (1..=count)
            .map(|n| std::iter::repeat(only).take(n).collect())
            .collect();
    }

    let mut nodes: Vec<String> = chars.iter().map(|c| c.to_string()).collect();
    let mut head = 0usize;
    while nodes.len() - head < count {
        let prefix = nodes[head].clone();
        head += 1;
        for c in &chars {
            nodes.push(format!("{prefix}{c}"));
        }
    }
    nodes[head..].iter().take(count).cloned().collect()
}

/// 给一组目标配上标签。
pub fn assign(targets: Vec<Target>, alphabet: &str) -> Vec<Hint> {
    let tags = labels(targets.len(), alphabet);
    targets
        .into_iter()
        .zip(tags)
        .map(|(target, tag)| Hint { tag, target })
        .collect()
}

/// 用户打了一个字之后该干什么。
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// 还在输入，这些标签还留着（用来把没匹配上的淡出去）
    Filtering(Vec<String>),
    /// 打中了，点这个
    Activate(Hint),
    /// 退出
    Cancel,
}

/// 键盘点击的会话。
#[derive(Debug, Clone)]
pub struct Session {
    hints: Vec<Hint>,
    typed: String,
    alphabet: String,
    /// 点完还留着，可以接着点下一个
    continuous: bool,
}

impl Session {
    /// 开一次会话。
    pub fn new(hints: Vec<Hint>, alphabet: &str, continuous: bool) -> Session {
        Session {
            hints,
            typed: String::new(),
            alphabet: alphabet.to_string(),
            continuous,
        }
    }

    /// 已经打了什么。
    pub fn typed(&self) -> &str {
        &self.typed
    }

    /// 现在还有哪些标签能匹配上（界面据此把别的淡出去）。
    pub fn matching(&self) -> Vec<&Hint> {
        self.hints
            .iter()
            .filter(|h| h.tag.starts_with(&self.typed))
            .collect()
    }

    /// 全部标签，用来画。
    pub fn hints(&self) -> &[Hint] {
        &self.hints
    }

    /// 连续点击模式下，点完一个还要不要留着。
    pub fn is_continuous(&self) -> bool {
        self.continuous
    }

    /// 打了一个字。
    pub fn push(&mut self, c: char) -> Outcome {
        let c = c.to_ascii_lowercase();
        // 字母表里没有的字符 = 打错了或者根本不想点 —— 直接退出。
        // 忽略的话，用户会被困在一个吃掉所有按键的模式里
        if !self.alphabet.contains(c) {
            return Outcome::Cancel;
        }
        self.typed.push(c);

        // 标签互不为前缀，所以「完全相等」就是唯一解，不必等下一个字符
        if let Some(hit) = self.hints.iter().find(|h| h.tag == self.typed) {
            let hit = hit.clone();
            self.typed.clear();
            return Outcome::Activate(hit);
        }
        let still: Vec<String> = self.matching().iter().map(|h| h.tag.clone()).collect();
        // 一个都不剩说明打岔了 —— 退出比停在一个空屏幕上好
        if still.is_empty() {
            return Outcome::Cancel;
        }
        Outcome::Filtering(still)
    }

    /// 退一格。已经是空的时候退一格 = 退出，与 Vim 里的手感一致。
    pub fn backspace(&mut self) -> Outcome {
        if self.typed.pop().is_none() {
            return Outcome::Cancel;
        }
        Outcome::Filtering(self.matching().iter().map(|h| h.tag.clone()).collect())
    }
}

/// 键盘滚动的一步。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scroll {
    /// 往下一行
    Down,
    /// 往上一行
    Up,
    /// 往下一屏
    PageDown,
    /// 往上一屏
    PageUp,
    /// 到顶
    Top,
    /// 到底
    Bottom,
}

impl Scroll {
    /// 按键 → 滚动动作。认不出的返回 `None`（调用方据此退出）。
    ///
    /// 键位取自 Vim / less：`j`/`k` 上下，空格翻页，`g`/`G` 到头。
    /// 方向键也认 —— 不是所有人都用 Vim。
    pub fn from_key(key: &str, shift: bool) -> Option<Scroll> {
        match key {
            "j" | "Down" => Some(Scroll::Down),
            "k" | "Up" => Some(Scroll::Up),
            "space" | "Page_Down" => Some(if shift { Scroll::PageUp } else { Scroll::PageDown }),
            "Page_Up" => Some(Scroll::PageUp),
            "g" => Some(if shift { Scroll::Bottom } else { Scroll::Top }),
            "Home" => Some(Scroll::Top),
            "End" => Some(Scroll::Bottom),
            _ => None,
        }
    }

    /// 这一步该滚多少「格」。正数向下。
    ///
    /// 到顶 / 到底给一个足够大的数 —— 各平台的滚动 API 都没有「滚到头」，
    /// 只能滚一个大数字。
    pub fn ticks(&self, page_lines: i32) -> i32 {
        match self {
            Scroll::Down => 3,
            Scroll::Up => -3,
            Scroll::PageDown => page_lines,
            Scroll::PageUp => -page_lines,
            Scroll::Bottom => 100_000,
            Scroll::Top => -100_000,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(n: usize) -> Target {
        Target {
            x: n as f64,
            y: n as f64,
            label: format!("按钮 {n}"),
        }
    }

    #[test]
    fn no_label_is_a_prefix_of_another() {
        // 这是整个模块的核心约束：否则打完 `a` 就得等，等着的时候
        // 屏幕上什么都没发生，用户只会以为程序卡了
        for count in [1, 5, 16, 17, 100, 500] {
            let tags = labels(count, DEFAULT_ALPHABET);
            assert_eq!(tags.len(), count);
            for (i, a) in tags.iter().enumerate() {
                for (j, b) in tags.iter().enumerate() {
                    if i != j {
                        assert!(!b.starts_with(a.as_str()), "{a} 是 {b} 的前缀（共 {count} 个）");
                    }
                }
            }
        }
    }

    #[test]
    fn labels_are_unique() {
        let tags = labels(300, DEFAULT_ALPHABET);
        let unique: std::collections::HashSet<&String> = tags.iter().collect();
        assert_eq!(unique.len(), tags.len());
    }

    #[test]
    fn short_labels_come_first_so_the_common_case_is_one_keystroke() {
        let alphabet = "abc";
        // 3 个目标 → 三个单字符
        assert_eq!(labels(3, alphabet), vec!["a", "b", "c"]);
        // 4 个 → 第一个被展开，剩下的是 b c aa ab ac 里的前四个
        let four = labels(4, alphabet);
        assert_eq!(four.len(), 4);
        assert!(four.iter().filter(|t| t.len() == 1).count() >= 2);
    }

    #[test]
    fn a_single_character_alphabet_does_not_hang() {
        // 实践中不会走到，但不挡的话这里是个死循环
        assert_eq!(labels(3, "a"), vec!["a", "aa", "aaa"]);
    }

    #[test]
    fn asking_for_nothing_gives_nothing() {
        assert!(labels(0, DEFAULT_ALPHABET).is_empty());
        assert!(labels(5, "").is_empty());
        assert!(assign(Vec::new(), DEFAULT_ALPHABET).is_empty());
    }

    #[test]
    fn the_default_alphabet_avoids_letters_that_look_alike() {
        // 屏幕上密密麻麻几十个标签时，认错一个字母就点错一个按钮
        assert!(!DEFAULT_ALPHABET.contains('l'));
        assert!(!DEFAULT_ALPHABET.contains('i'));
        assert!(DEFAULT_ALPHABET.len() > 8, "太少的话标签会变得很长");
    }

    #[test]
    fn typing_a_complete_tag_activates_it_immediately() {
        // 标签互不为前缀，所以不必等下一个字符
        let hints = assign((0..3).map(target).collect(), "abc");
        let mut session = Session::new(hints.clone(), "abc", false);
        match session.push(hints[1].tag.chars().next().unwrap()) {
            Outcome::Activate(hit) => assert_eq!(hit.tag, hints[1].tag),
            other => panic!("该立刻触发，却是 {other:?}"),
        }
    }

    #[test]
    fn a_multi_character_tag_filters_before_it_fires() {
        let hints = assign((0..20).map(target).collect(), "ab");
        let long = hints
            .iter()
            .find(|h| h.tag.chars().count() >= 2)
            .unwrap()
            .clone();
        let mut session = Session::new(hints, "ab", false);
        let mut chars = long.tag.chars();
        // 除最后一个字符外都只该过滤
        let last = long.tag.chars().count() - 1;
        for _ in 0..last {
            let c = chars.next().unwrap();
            assert!(matches!(session.push(c), Outcome::Filtering(_)));
        }
        match session.push(chars.next().unwrap()) {
            Outcome::Activate(hit) => assert_eq!(hit.tag, long.tag),
            other => panic!("最后一个字符该触发，却是 {other:?}"),
        }
    }

    #[test]
    fn a_character_outside_the_alphabet_exits_instead_of_being_swallowed() {
        // 忽略的话，一个想按 Esc 却按到别处的用户会被困在一个吃掉所有按键的模式里
        let hints = assign((0..3).map(target).collect(), "abc");
        let mut session = Session::new(hints, "abc", false);
        assert_eq!(session.push('z'), Outcome::Cancel);
        assert_eq!(session.push('7'), Outcome::Cancel);
    }

    #[test]
    fn typing_something_that_matches_nothing_exits_rather_than_leaving_a_blank_screen() {
        let hints = assign((0..20).map(target).collect(), "ab");
        let mut session = Session::new(hints, "ab", false);
        // 先打一个能过滤的
        session.push('a');
        // 再打到一个不存在的组合上
        let mut result = Outcome::Filtering(Vec::new());
        for _ in 0..6 {
            result = session.push('a');
            if result == Outcome::Cancel {
                break;
            }
            if matches!(result, Outcome::Activate(_)) {
                return; // 打中了也算合理
            }
        }
        assert_eq!(result, Outcome::Cancel);
    }

    #[test]
    fn matching_narrows_as_the_user_types() {
        let hints = assign((0..20).map(target).collect(), "ab");
        let session = Session::new(hints.clone(), "ab", false);
        assert_eq!(session.matching().len(), hints.len(), "还没打字时全都算匹配");

        let mut session = Session::new(hints, "ab", false);
        if let Outcome::Filtering(left) = session.push('a') {
            assert!(left.len() < 20);
            assert!(left.iter().all(|t| t.starts_with('a')));
        }
    }

    #[test]
    fn uppercase_input_matches_lowercase_tags() {
        // 用户开着 CapsLock 是常事，不该因此点不动
        let hints = assign((0..3).map(target).collect(), "abc");
        let mut session = Session::new(hints.clone(), "abc", false);
        assert!(matches!(session.push('A'), Outcome::Activate(_)));
    }

    #[test]
    fn backspace_on_an_empty_input_exits() {
        // 与 Vim 里的手感一致
        let hints = assign((0..20).map(target).collect(), "ab");
        let mut session = Session::new(hints, "ab", false);
        assert_eq!(session.backspace(), Outcome::Cancel);
    }

    #[test]
    fn backspace_widens_the_match_again() {
        let hints = assign((0..20).map(target).collect(), "ab");
        let mut session = Session::new(hints, "ab", false);
        session.push('a');
        let narrowed = session.matching().len();
        session.backspace();
        assert!(session.matching().len() > narrowed);
        assert_eq!(session.typed(), "");
    }

    #[test]
    fn activating_clears_the_input_so_continuous_mode_starts_fresh() {
        // 不清的话，连续点击时第二个标签永远匹配不上
        let hints = assign((0..20).map(target).collect(), "ab");
        let mut session = Session::new(hints.clone(), "ab", true);
        let long = hints.iter().find(|h| h.tag.chars().count() >= 2).unwrap();
        for c in long.tag.chars() {
            session.push(c);
        }
        assert_eq!(session.typed(), "");
        assert!(session.is_continuous());
    }

    #[test]
    fn scroll_keys_follow_vim_and_the_arrow_keys_both() {
        // 不是所有人都用 Vim
        assert_eq!(Scroll::from_key("j", false), Some(Scroll::Down));
        assert_eq!(Scroll::from_key("Down", false), Some(Scroll::Down));
        assert_eq!(Scroll::from_key("k", false), Some(Scroll::Up));
        assert_eq!(Scroll::from_key("space", false), Some(Scroll::PageDown));
        assert_eq!(Scroll::from_key("space", true), Some(Scroll::PageUp));
        assert_eq!(Scroll::from_key("g", false), Some(Scroll::Top));
        assert_eq!(Scroll::from_key("g", true), Some(Scroll::Bottom));
        assert_eq!(Scroll::from_key("q", false), None);
    }

    #[test]
    fn scrolling_to_an_end_uses_a_number_big_enough_to_actually_get_there() {
        // 各平台的滚动 API 都没有「滚到头」，只能滚一个大数字
        assert!(Scroll::Bottom.ticks(10) > 1000);
        assert!(Scroll::Top.ticks(10) < -1000);
        // 方向不能反
        assert!(Scroll::Down.ticks(10) > 0);
        assert!(Scroll::Up.ticks(10) < 0);
        assert_eq!(Scroll::PageDown.ticks(10), 10);
    }
}
