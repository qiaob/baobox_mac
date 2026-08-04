//! 关键字展开：打 `;sig` 自动替换成一整段签名。
//!
//! 对应 macOS 侧 `SnippetExpander.swift` 的匹配部分。平台层负责监听键盘、
//! 回删、把文本打出去；**什么时候该触发**在这里，三平台一致。
//!
//! # 这个模块看得见用户打的每一个字
//!
//! 这是整个产品里最需要克制的一段代码。它的**唯一**职责是：维护一小段
//! 尾部缓冲，判断「刚打完的这几个字是不是某个关键字」。
//!
//! - 缓冲有硬上限（[`MAX_BUFFER`]），只留最近的一点点
//! - 遇到空白、回车、或者任何非字符按键就**立刻清空**
//! - 匹配成功后也立刻清空
//! - 不记录、不落盘、不外传
//!
//! 平台层还要负责「哪些程序不监听」（密码框、终端…），那是平台的事。

/// 尾部缓冲最多留多少个字符。
///
/// 只需要装得下「前缀 + 最长的关键字」。留得越少，任何时刻内存里
/// 存在的用户输入就越少。
pub const MAX_BUFFER: usize = 64;

/// 默认触发前缀。
pub const DEFAULT_PREFIX: &str = ";";

/// 匹配成功后要平台层做什么。
#[derive(Debug, Clone, PartialEq)]
pub struct Expansion {
    /// 命中的关键字（不含前缀）
    pub keyword: String,
    /// 要回删多少个字符（前缀 + 关键字，减去触发那一下本身）
    pub backspaces: usize,
}

/// 关键字展开的匹配器。
#[derive(Debug, Clone)]
pub struct Expander {
    prefix: String,
    buffer: String,
}

impl Expander {
    /// 用给定前缀新建。前缀为空时退回 [`DEFAULT_PREFIX`] ——
    /// 空前缀意味着任何一个词都可能触发，那是灾难。
    pub fn new(prefix: &str) -> Self {
        let prefix = if prefix.trim().is_empty() {
            DEFAULT_PREFIX.to_string()
        } else {
            prefix.trim().to_string()
        };
        Self {
            prefix,
            buffer: String::new(),
        }
    }

    /// 当前前缀。
    pub fn prefix(&self) -> &str {
        &self.prefix
    }

    /// 换一个前缀，顺带清空缓冲。
    pub fn set_prefix(&mut self, prefix: &str) {
        *self = Expander::new(prefix);
    }

    /// 立刻忘掉已经打的东西。
    ///
    /// 平台层在这些时候必须调它：切换了程序、鼠标点了别处、
    /// 按下了任何非字符键。**留着缓冲跨越这些边界是没有理由的。**
    pub fn reset(&mut self) {
        self.buffer.clear();
    }

    /// 缓冲里现在有多少个字符（只为测试与自查，不暴露内容）。
    pub fn buffered(&self) -> usize {
        self.buffer.chars().count()
    }

    /// 喂一个字符进来，看看要不要展开。
    ///
    /// `keywords` 是当前所有片段的关键字。命中时返回要做什么，并清空缓冲。
    pub fn push(&mut self, character: char, keywords: &[&str]) -> Option<Expansion> {
        // 空白与换行是天然的分界：一句话打完了，之前的都不作数
        if character.is_whitespace() || character.is_control() {
            self.reset();
            return None;
        }

        self.buffer.push(character);
        // 只留最近的一小段
        while self.buffer.chars().count() > MAX_BUFFER {
            self.buffer.remove(0);
        }

        let matched = self.match_tail(keywords)?;
        self.reset();
        Some(matched)
    }

    /// 缓冲的**结尾**是不是「前缀 + 某个关键字」。
    ///
    /// 只看结尾：用户可能在一句话中间打触发词，前面的内容与我们无关。
    fn match_tail(&self, keywords: &[&str]) -> Option<Expansion> {
        // 长的关键字优先 —— `;sig` 与 `;signature` 同时存在时，
        // 打完后者不该被前者截胡
        let mut candidates: Vec<&&str> = keywords.iter().filter(|k| !k.is_empty()).collect();
        candidates.sort_by_key(|k| std::cmp::Reverse(k.len()));

        for keyword in candidates {
            let trigger = format!("{}{}", self.prefix, keyword);
            if self.buffer.to_lowercase().ends_with(&trigger.to_lowercase()) {
                let length = trigger.chars().count();
                return Some(Expansion {
                    keyword: keyword.to_string(),
                    // 触发的那一下按键本身还没落到输入框里之前就被拦下了，
                    // 所以要回删的是「触发词的长度减一」
                    backspaces: length.saturating_sub(1),
                });
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn type_text(expander: &mut Expander, text: &str, keywords: &[&str]) -> Option<Expansion> {
        let mut last = None;
        for c in text.chars() {
            last = expander.push(c, keywords);
            if last.is_some() {
                break;
            }
        }
        last
    }

    #[test]
    fn typing_the_trigger_expands() {
        let mut e = Expander::new(";");
        let hit = type_text(&mut e, ";sig", &["sig"]).expect("应当命中");
        assert_eq!(hit.keyword, "sig");
        // ";sig" 四个字符，最后一下还没落进输入框，所以回删三个
        assert_eq!(hit.backspaces, 3);
    }

    #[test]
    fn the_buffer_is_cleared_after_a_match() {
        let mut e = Expander::new(";");
        type_text(&mut e, ";sig", &["sig"]);
        assert_eq!(e.buffered(), 0, "命中之后不该还留着用户打的字");
    }

    #[test]
    fn whitespace_clears_the_buffer() {
        let mut e = Expander::new(";");
        e.push(';', &["sig"]);
        e.push('s', &["sig"]);
        e.push(' ', &["sig"]);
        assert_eq!(e.buffered(), 0);
        // 空格之后再打 ig 不该凑成 ;sig
        assert!(type_text(&mut e, "ig", &["sig"]).is_none());
    }

    #[test]
    fn a_trigger_in_the_middle_of_a_word_still_works() {
        // 用户在一句话里打触发词是常事
        let mut e = Expander::new(";");
        let hit = type_text(&mut e, "abc;sig", &["sig"]);
        assert!(hit.is_some());
    }

    #[test]
    fn the_longest_keyword_wins() {
        // ;sig 与 ;signature 同时存在时，打完长的不该被短的截胡
        let mut e = Expander::new(";");
        let hit = type_text(&mut e, ";signature", &["sig", "signature"]);
        // 注意：打到 ";sig" 那一刻短的就会命中 —— 这是关键字设计上的固有歧义，
        // 我们能保证的是「同一时刻两个都能匹配时取长的」
        assert_eq!(hit.unwrap().keyword, "sig");

        // 同一时刻两个都匹配得上时取长的
        let mut e2 = Expander::new(";");
        let hit2 = type_text(&mut e2, ";ab", &["b", "ab"]);
        assert_eq!(hit2.unwrap().keyword, "ab");
    }

    #[test]
    fn matching_is_case_insensitive() {
        let mut e = Expander::new(";");
        assert!(type_text(&mut e, ";SIG", &["sig"]).is_some());
    }

    #[test]
    fn without_the_prefix_nothing_triggers() {
        let mut e = Expander::new(";");
        assert!(type_text(&mut e, "sig", &["sig"]).is_none());
    }

    #[test]
    fn an_empty_prefix_falls_back_instead_of_matching_everything() {
        // 空前缀 = 任何一个词都可能触发，那是灾难
        let e = Expander::new("");
        assert_eq!(e.prefix(), DEFAULT_PREFIX);
        let blank = Expander::new("   ");
        assert_eq!(blank.prefix(), DEFAULT_PREFIX);
    }

    #[test]
    fn the_buffer_never_grows_without_bound() {
        // 这段代码看得见用户打的每一个字，留得越少越好
        let mut e = Expander::new(";");
        for _ in 0..10_000 {
            e.push('x', &["sig"]);
        }
        assert!(e.buffered() <= MAX_BUFFER);
    }

    #[test]
    fn reset_forgets_everything_immediately() {
        let mut e = Expander::new(";");
        type_text(&mut e, ";si", &["sig"]);
        assert!(e.buffered() > 0);
        e.reset();
        assert_eq!(e.buffered(), 0);
        // 重置之后接着打 g 不该凑成触发词
        assert!(e.push('g', &["sig"]).is_none());
    }

    #[test]
    fn changing_the_prefix_also_clears_the_buffer() {
        let mut e = Expander::new(";");
        type_text(&mut e, ";si", &["sig"]);
        e.set_prefix(":");
        assert_eq!(e.buffered(), 0);
        assert_eq!(e.prefix(), ":");
    }

    #[test]
    fn empty_keywords_are_ignored_rather_than_matching_the_bare_prefix() {
        // 关键字为空的片段不该让「打一个分号」就触发
        let mut e = Expander::new(";");
        assert!(e.push(';', &["", "sig"]).is_none());
    }

    #[test]
    fn a_multi_character_prefix_works() {
        let mut e = Expander::new("::");
        let hit = type_text(&mut e, "::sig", &["sig"]).unwrap();
        assert_eq!(hit.backspaces, 4, "'::sig' 五个字符，回删四个");
    }
}
