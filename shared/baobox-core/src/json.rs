//! 一个够用就好的 JSON 解析器。
//!
//! `baobox-core` 是零依赖的，不能引 serde；而剪贴板的文本工具要判断
//! 「这段是不是合法 JSON」并重新排版，AI 助手要读 `.jsonl` 会话日志 ——
//! 两处都需要解析，所以放在这里共用一份。
//!
//! # 三条刻意的取舍
//!
//! 1. **数字原样保留字符串形式**。转成 `f64` 再转回来，`1e400` 会变成 `inf`、
//!    `1.0` 会变成 `1`，而这两样都是在改用户的内容。要数值时调用方自己
//!    [`Json::as_f64`]。
//! 2. **有深度上限**（[`MAX_DEPTH`]）。一串 `[[[[…` 能把递归下降解析器
//!    送进栈溢出，而剪贴板与磁盘上的日志都是完全不可信的输入。
//! 3. **对象保留顺序、允许重复键**。重新排版时要一字不差地还原，
//!    用 map 会打乱顺序、吞掉重复键。

/// 极简 JSON 值。只为「验证是不是合法 JSON」与「重新排版」而存在，
/// 不追求完整的数值语义（数字原样保留字符串形式，避免浮点往返丢精度）。
#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    /// `null`
    Null,
    /// `true` / `false`
    Bool(bool),
    /// 原样保留文本形式：`1e400` 与 `1.0` 重新输出时不该被改写
    Number(String),
    /// 字符串（转义已经还原）
    Str(String),
    /// 数组
    Array(Vec<Json>),
    /// 对象。**保留顺序、允许重复键** —— 重新排版要一字不差
    Object(Vec<(String, Json)>),
}

/// 解析一段 JSON。**整段必须是一个值** —— 后面还跟着别的东西就算不合法。
///
/// 解析不了返回 `None`，不区分「哪里错了」：调用方拿到细节也做不了什么，
/// 而剪贴板与日志里出现非 JSON 是家常便饭，不值得为它造一套错误类型。
pub fn parse(text: &str) -> Option<Json> {
    let bytes: Vec<char> = text.chars().collect();
    let mut at = 0usize;
    let value = parse_value(&bytes, &mut at, 0)?;
    skip_space(&bytes, &mut at);
    if at != bytes.len() {
        return None;
    }
    Some(value)
}

/// 嵌套层数上限。没有它的话，一串 `[[[[…` 能把解析器递归到爆栈 ——
/// 而剪贴板内容是完全不可信的输入。
/// 嵌套层数上限。
pub const MAX_DEPTH: usize = 128;

pub(crate) fn parse_value(chars: &[char], at: &mut usize, depth: usize) -> Option<Json> {
    if depth > MAX_DEPTH {
        return None;
    }
    skip_space(chars, at);
    match chars.get(*at)? {
        '{' => parse_object(chars, at, depth),
        '[' => parse_array(chars, at, depth),
        '"' => parse_string(chars, at).map(Json::Str),
        't' => literal(chars, at, "true").map(|_| Json::Bool(true)),
        'f' => literal(chars, at, "false").map(|_| Json::Bool(false)),
        'n' => literal(chars, at, "null").map(|_| Json::Null),
        _ => parse_number(chars, at),
    }
}

pub(crate) fn parse_object(chars: &[char], at: &mut usize, depth: usize) -> Option<Json> {
    *at += 1; // {
    let mut entries = Vec::new();
    skip_space(chars, at);
    if chars.get(*at) == Some(&'}') {
        *at += 1;
        return Some(Json::Object(entries));
    }
    loop {
        skip_space(chars, at);
        let key = parse_string(chars, at)?;
        skip_space(chars, at);
        if chars.get(*at) != Some(&':') {
            return None;
        }
        *at += 1;
        let value = parse_value(chars, at, depth + 1)?;
        entries.push((key, value));
        skip_space(chars, at);
        match chars.get(*at)? {
            ',' => *at += 1,
            '}' => {
                *at += 1;
                return Some(Json::Object(entries));
            }
            _ => return None,
        }
    }
}

pub(crate) fn parse_array(chars: &[char], at: &mut usize, depth: usize) -> Option<Json> {
    *at += 1; // [
    let mut items = Vec::new();
    skip_space(chars, at);
    if chars.get(*at) == Some(&']') {
        *at += 1;
        return Some(Json::Array(items));
    }
    loop {
        items.push(parse_value(chars, at, depth + 1)?);
        skip_space(chars, at);
        match chars.get(*at)? {
            ',' => *at += 1,
            ']' => {
                *at += 1;
                return Some(Json::Array(items));
            }
            _ => return None,
        }
    }
}

pub(crate) fn parse_string(chars: &[char], at: &mut usize) -> Option<String> {
    if chars.get(*at) != Some(&'"') {
        return None;
    }
    *at += 1;
    let mut out = String::new();
    loop {
        let c = *chars.get(*at)?;
        *at += 1;
        match c {
            '"' => return Some(out),
            '\\' => {
                let escaped = *chars.get(*at)?;
                *at += 1;
                match escaped {
                    'n' => out.push('\n'),
                    't' => out.push('\t'),
                    'r' => out.push('\r'),
                    'b' => out.push('\u{8}'),
                    'f' => out.push('\u{c}'),
                    'u' => {
                        let mut code = 0u32;
                        for _ in 0..4 {
                            code = code * 16 + (*chars.get(*at)?).to_digit(16)?;
                            *at += 1;
                        }
                        out.push(char::from_u32(code).unwrap_or('\u{fffd}'));
                    }
                    other => out.push(other),
                }
            }
            other => out.push(other),
        }
    }
}

pub(crate) fn parse_number(chars: &[char], at: &mut usize) -> Option<Json> {
    let start = *at;
    if chars.get(*at) == Some(&'-') {
        *at += 1;
    }
    let digits = *at;
    while matches!(chars.get(*at), Some(c) if c.is_ascii_digit()) {
        *at += 1;
    }
    if *at == digits {
        return None;
    }
    if chars.get(*at) == Some(&'.') {
        *at += 1;
        while matches!(chars.get(*at), Some(c) if c.is_ascii_digit()) {
            *at += 1;
        }
    }
    if matches!(chars.get(*at), Some('e') | Some('E')) {
        *at += 1;
        if matches!(chars.get(*at), Some('+') | Some('-')) {
            *at += 1;
        }
        while matches!(chars.get(*at), Some(c) if c.is_ascii_digit()) {
            *at += 1;
        }
    }
    Some(Json::Number(chars[start..*at].iter().collect()))
}

pub(crate) fn literal(chars: &[char], at: &mut usize, word: &str) -> Option<()> {
    for expected in word.chars() {
        if chars.get(*at) != Some(&expected) {
            return None;
        }
        *at += 1;
    }
    Some(())
}

pub(crate) fn skip_space(chars: &[char], at: &mut usize) {
    while matches!(chars.get(*at), Some(c) if c.is_whitespace()) {
        *at += 1;
    }
}

impl Json {
    /// 取对象里的一个字段。不是对象、或者没这个键都返回 `None`。
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(entries) => entries.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    /// 顺着一串键往下取。读日志时一层层判空太啰嗦。
    pub fn path(&self, keys: &[&str]) -> Option<&Json> {
        let mut current = self;
        for key in keys {
            current = current.get(key)?;
        }
        Some(current)
    }

    /// 当成字符串取。
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(text) => Some(text),
            _ => None,
        }
    }

    /// 当成数字取。
    ///
    /// 解析时数字是原样留着的字符串，到这一步才转 —— 转不动就返回 `None`，
    /// 不要悄悄给个 0（那会让「字段缺失」和「值就是 0」分不开）。
    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Number(text) => text.parse().ok(),
            _ => None,
        }
    }

    /// 当成整数取。超出范围或带小数点的按 `None`。
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Json::Number(text) => text.parse().ok(),
            _ => None,
        }
    }

    /// 当成数组取。
    pub fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(items) => Some(items),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_nested_field_can_be_read_without_a_pile_of_ifs() {
        let value = parse(r#"{"message":{"usage":{"input_tokens":12}}}"#).unwrap();
        assert_eq!(
            value.path(&["message", "usage", "input_tokens"]).and_then(Json::as_i64),
            Some(12)
        );
        assert!(value.path(&["message", "nope"]).is_none());
        assert!(value.path(&["message", "usage", "input_tokens", "更深"]).is_none());
    }

    #[test]
    fn numbers_keep_their_text_form_until_someone_asks_for_a_value() {
        // 解析时就转 f64 的话，1e400 会变成 inf、1.0 会变成 1
        let value = parse(r#"{"big":1e400,"round":1.0}"#).unwrap();
        assert_eq!(value.get("big"), Some(&Json::Number("1e400".to_string())));
        assert_eq!(value.get("round"), Some(&Json::Number("1.0".to_string())));
        assert!(value.get("big").unwrap().as_f64().unwrap().is_infinite());
    }

    #[test]
    fn a_missing_field_is_none_rather_than_zero() {
        // 悄悄给 0 的话，「字段缺失」和「值就是 0」就分不开了
        let value = parse(r#"{"a":0}"#).unwrap();
        assert_eq!(value.get("a").and_then(Json::as_i64), Some(0));
        assert_eq!(value.get("b").and_then(Json::as_i64), None);
    }

    #[test]
    fn deeply_nested_input_is_refused_rather_than_blowing_the_stack() {
        let bomb = "[".repeat(MAX_DEPTH + 10);
        assert!(parse(&bomb).is_none());
    }

    #[test]
    fn rubbish_is_refused() {
        assert!(parse("").is_none());
        assert!(parse("{").is_none());
        assert!(parse("{\"a\":}").is_none());
        // 后面还有东西的不算合法
        assert!(parse("{} 多出来的").is_none());
    }

    #[test]
    fn duplicate_keys_are_kept_because_reformatting_must_be_faithful() {
        // 用 map 存的话会吞掉一个，重新排版就不是原文了
        let value = parse(r#"{"a":1,"a":2}"#).unwrap();
        assert_eq!(value.as_array(), None);
        match value {
            Json::Object(entries) => assert_eq!(entries.len(), 2),
            _ => panic!("该是个对象"),
        }
    }
}
