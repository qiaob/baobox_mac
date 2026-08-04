//! 敏感内容识别：这段东西该不该进剪贴板历史。
//!
//! 剪贴板历史是个**长期留存**的东西 —— 密码、私钥、银行卡号进去之后，
//! 会一直躺在那儿等着被别人看到。所以宁可漏过一些普通内容，
//! 也不能把明显是机密的东西默默记下来。
//!
//! # 两道关
//!
//! 1. **来源标记**：密码管理器复制密码时会打标记（macOS 是
//!    `org.nspasteboard.ConcealedType`）。这一道由平台层判断并传进来。
//! 2. **内容特征**：这里做的。看起来像私钥、银行卡号、长随机令牌的，
//!    一律当敏感。
//!
//! # 宁可少认，不可错认
//!
//! 每条规则都往「保守」的方向调过：
//!
//! - 银行卡号要过 Luhn 校验 —— 否则一串 16 位订单号就会被当成卡号
//! - 令牌要够长且熵够高 —— 否则一个 commit sha 也会被拦下来
//!
//! 错认的代价是用户发现「我复制的东西没进历史」，而且**根本查不出为什么**。

/// 判定为敏感的原因。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    /// 来源程序打了标记（密码管理器）
    Marked,
    /// 看起来是私钥 / 证书
    PrivateKey,
    /// 过了 Luhn 校验的银行卡号
    CardNumber,
    /// 长且高熵的令牌
    Token,
}

impl Reason {
    /// 给用户看的说法。
    pub fn describe(&self) -> &'static str {
        match self {
            Reason::Marked => "来源程序标记为敏感",
            Reason::PrivateKey => "看起来是私钥",
            Reason::CardNumber => "看起来是银行卡号",
            Reason::Token => "看起来是密钥或令牌",
        }
    }
}

/// 私钥 / 证书的块首。覆盖 OpenSSH、OpenSSL、PGP 的常见写法。
const KEY_HEADERS: [&str; 6] = [
    "-----BEGIN PRIVATE KEY",
    "-----BEGIN RSA PRIVATE KEY",
    "-----BEGIN OPENSSH PRIVATE KEY",
    "-----BEGIN EC PRIVATE KEY",
    "-----BEGIN DSA PRIVATE KEY",
    "-----BEGIN PGP PRIVATE KEY",
];

/// 一望即知是密钥的前缀。这些是各家自己定的、不会撞上普通文本的招牌。
const TOKEN_PREFIXES: [&str; 8] = [
    "ghp_",     // GitHub personal access token
    "gho_",     // GitHub OAuth
    "github_pat_",
    "sk-",      // OpenAI
    "sk_live_", // Stripe
    "xoxb-",    // Slack bot
    "xoxp-",    // Slack user
    "AKIA",     // AWS access key id
];

/// 被当成「长随机令牌」的最短长度。
///
/// 40 是刻意压高的：git 的 commit sha 正好 40 个十六进制字符，
/// 而那玩意儿天天在剪贴板里过，绝不能被拦。所以纯十六进制的另有判断。
const TOKEN_MIN_LENGTH: usize = 40;

/// 这段文字敏感吗。
///
/// `marked` 是平台层给的「来源标记为敏感」。
pub fn classify(text: &str, marked: bool) -> Option<Reason> {
    if marked {
        return Some(Reason::Marked);
    }
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    if KEY_HEADERS.iter().any(|header| trimmed.contains(header)) {
        return Some(Reason::PrivateKey);
    }
    if TOKEN_PREFIXES
        .iter()
        .any(|prefix| trimmed.starts_with(prefix))
    {
        return Some(Reason::Token);
    }
    if looks_like_card_number(trimmed) {
        return Some(Reason::CardNumber);
    }
    if looks_like_token(trimmed) {
        return Some(Reason::Token);
    }
    None
}

/// 是不是一串过了 Luhn 校验的卡号。
///
/// **必须过 Luhn** —— 16 位数字在订单号、流水号里太常见了，
/// 光按位数拦会把一大堆正常内容误伤。
pub fn looks_like_card_number(text: &str) -> bool {
    // 卡号常写成 4 位一组，允许空格与短横
    let digits: Vec<u32> = text
        .chars()
        .filter(|c| !matches!(c, ' ' | '-'))
        .map(|c| c.to_digit(10))
        .collect::<Option<Vec<u32>>>()
        .unwrap_or_default();
    if !(13..=19).contains(&digits.len()) {
        return false;
    }
    luhn(&digits)
}

/// Luhn 校验。
fn luhn(digits: &[u32]) -> bool {
    let sum: u32 = digits
        .iter()
        .rev()
        .enumerate()
        .map(|(index, digit)| {
            if index % 2 == 1 {
                let doubled = digit * 2;
                if doubled > 9 {
                    doubled - 9
                } else {
                    doubled
                }
            } else {
                *digit
            }
        })
        .sum();
    sum % 10 == 0
}

/// 是不是一串长而随机的令牌。
///
/// 要同时满足：够长、没有空白、字符集像是随机生成的、并且**不是纯十六进制**
/// （commit sha、MD5、文件校验和天天在剪贴板里过，拦它们纯属骚扰）。
pub fn looks_like_token(text: &str) -> bool {
    if text.len() < TOKEN_MIN_LENGTH {
        return false;
    }
    if text.contains(char::is_whitespace) {
        return false;
    }
    if !text
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | '+' | '/' | '='))
    {
        return false;
    }
    if text.chars().all(|c| c.is_ascii_hexdigit()) {
        return false;
    }
    // 随机令牌里大小写与数字都会出现；只有小写字母的多半是一句英文或一个路径
    let has_upper = text.chars().any(|c| c.is_ascii_uppercase());
    let has_lower = text.chars().any(|c| c.is_ascii_lowercase());
    let has_digit = text.chars().any(|c| c.is_ascii_digit());
    has_upper && has_lower && has_digit
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_source_marked_item_is_always_sensitive() {
        assert_eq!(classify("随便什么", true), Some(Reason::Marked));
        // 空内容也一样 —— 标记是来源给的，比我们的猜测可信
        assert_eq!(classify("", true), Some(Reason::Marked));
    }

    #[test]
    fn private_key_blocks_are_caught() {
        let key = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNz...\n-----END";
        assert_eq!(classify(key, false), Some(Reason::PrivateKey));
        assert_eq!(
            classify("-----BEGIN RSA PRIVATE KEY-----", false),
            Some(Reason::PrivateKey)
        );
        // 公钥不是秘密
        assert_eq!(classify("ssh-rsa AAAAB3Nza...", false), None);
    }

    #[test]
    fn well_known_token_prefixes_are_caught() {
        for token in [
            "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
            "sk-proj-abcdefghijklmnop",
            "xoxb-123-456-abcdef",
            "AKIAIOSFODNN7EXAMPLE",
        ] {
            assert_eq!(classify(token, false), Some(Reason::Token), "{token}");
        }
    }

    #[test]
    fn card_numbers_must_pass_luhn_so_order_ids_are_not_caught() {
        // 这是 Visa 的公开测试卡号，过 Luhn
        assert_eq!(classify("4111111111111111", false), Some(Reason::CardNumber));
        assert_eq!(
            classify("4111 1111 1111 1111", false),
            Some(Reason::CardNumber),
            "四位一组的写法也要认"
        );
        assert_eq!(classify("4111-1111-1111-1111", false), Some(Reason::CardNumber));

        // 位数够但过不了 Luhn = 多半是订单号，不该拦
        assert_eq!(classify("1234567890123456", false), None);
        // 位数不够
        assert_eq!(classify("411111111111", false), None);
    }

    #[test]
    fn a_commit_sha_is_not_treated_as_a_secret() {
        // 40 位十六进制天天在剪贴板里过，拦它纯属骚扰
        let sha = "e408947bfd200af42db322daf0fadfe7e26d3bd1";
        assert_eq!(sha.len(), 40);
        assert_eq!(classify(sha, false), None);
        // MD5 / SHA256 同理
        assert_eq!(classify(&"a".repeat(64), false), None);
    }

    #[test]
    fn long_mixed_case_random_strings_are_treated_as_tokens() {
        let token = "Zm9vYmFyMTIzNDU2Nzg5MEFCQ0RFRkdISUpLTE1OT1A";
        assert!(token.len() >= TOKEN_MIN_LENGTH);
        assert_eq!(classify(token, false), Some(Reason::Token));
    }

    #[test]
    fn ordinary_long_text_is_not_a_token() {
        // 一句长英文、一条路径、一个 URL 都不该被当成密钥
        for ordinary in [
            "the quick brown fox jumps over the lazy dog again and again",
            "/usr/local/share/some/rather/long/path/to/a/file.txt",
            "https://example.com/a/very/long/path/that/goes/on/for/a/while",
            "这是一段足够长的中文文本，里面并没有任何机密的内容在其中出现过",
        ] {
            assert_eq!(classify(ordinary, false), None, "{ordinary}");
        }
    }

    #[test]
    fn a_lowercase_only_slug_is_not_a_token() {
        // 只有小写字母的长串多半是个 slug 或一句话，不是随机令牌
        assert_eq!(classify(&"abcdefghij".repeat(5), false), None);
    }

    #[test]
    fn every_reason_can_explain_itself() {
        for reason in [
            Reason::Marked,
            Reason::PrivateKey,
            Reason::CardNumber,
            Reason::Token,
        ] {
            assert!(!reason.describe().is_empty());
        }
    }

    #[test]
    fn luhn_matches_the_textbook_examples() {
        assert!(luhn(&[4, 5, 3, 9, 1, 4, 8, 8, 0, 3, 4, 3, 6, 4, 6, 7]));
        assert!(!luhn(&[4, 5, 3, 9, 1, 4, 8, 8, 0, 3, 4, 3, 6, 4, 6, 8]));
    }
}
