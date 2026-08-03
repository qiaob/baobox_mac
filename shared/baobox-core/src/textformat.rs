//! 预览区文本工具：认出剪贴板里这段文字是什么，能对它做什么。
//!
//! 对应 macOS 侧 `Modules/Clipboard/TextTools/`。识别器**必须是纯函数**，
//! 不得有副作用 —— 它们在每次选中条目时都会跑一遍。
//!
//! # 认出来 ≠ 替换预览
//!
//! [`Match::rendered`] **只有在原文根本没法读、且没有等价的显式动作时才给**
//! （当前只有 JWT 的分段视图）。其余一律留空：转换是用户的显式动作，
//! 不能因为「认出来了」就把预览换掉 —— 否则预览显示的和粘贴出去的不是一个东西。
//! （Base64 曾经自动渲染成解码结果，后来撤销了。）
//!
//! # 为什么动作是 id 而不是闭包
//!
//! mac 侧的 `FormatAction` 带一个闭包。放到这里不行：动作要跨过平台层的
//! 菜单 / 按钮，闭包既不好存也不好传。改成「动作只有 id 和标题，
//! 执行走 [`apply`]」—— 平台层拿到 id 原样交回来即可，也更好测。

use std::fmt::Write as _;

/// 表格里的一行（时间转换表、URL query、JWT 声明）。
#[derive(Debug, Clone, PartialEq)]
pub struct Row {
    /// 左边的名字
    pub label: String,
    /// 右边的值
    pub value: String,
    /// 要标出来提醒的行（比如已过期的 exp）
    pub warning: bool,
}

impl Row {
    fn new(label: &str, value: impl Into<String>) -> Row {
        Row {
            label: label.to_string(),
            value: value.into(),
            warning: false,
        }
    }

    fn warn(mut self) -> Row {
        self.warning = true;
        self
    }
}

/// 一个可执行的动作。
#[derive(Debug, Clone, PartialEq)]
pub struct Action {
    /// 交给 [`apply`] 的 id
    pub id: &'static str,
    /// 按钮上的字
    pub title: String,
}

impl Action {
    fn new(id: &'static str, title: &str) -> Action {
        Action {
            id,
            title: title.to_string(),
        }
    }
}

/// 一次识别的结果。
#[derive(Debug, Clone, PartialEq)]
pub struct Match {
    /// 与识别器同名
    pub id: &'static str,
    /// 徽章文案
    pub badge: String,
    /// 覆盖预览正文的渲染结果；空 = 照常显示原文
    pub rendered: Option<String>,
    /// 表格区
    pub rows: Vec<Row>,
    /// 动作区
    pub actions: Vec<Action>,
}

/// 超过这个长度就不做识别了。
///
/// 识别器要扫全文，而剪贴板里出现几 MB 的日志是常事 ——
/// 每选中一次就卡一下，比不给这个功能更糟。
pub const MAX_LENGTH: usize = 256 * 1024;

/// 认一认这段文字是什么。返回的顺序就是界面上徽章的顺序。
pub fn detect(text: &str) -> Vec<Match> {
    if text.len() > MAX_LENGTH {
        return Vec::new();
    }
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    let mut found = Vec::new();
    // 顺序有讲究：JWT 在 Base64 之前 —— JWT 本身就是几段 Base64，
    // 反过来的话每个 JWT 都会先被认成 Base64
    if let Some(m) = detect_jwt(trimmed) {
        found.push(m);
    }
    if let Some(m) = detect_json(trimmed) {
        found.push(m);
    }
    if let Some(m) = detect_xml(trimmed) {
        found.push(m);
    }
    if let Some(m) = detect_url(trimmed) {
        found.push(m);
    }
    if let Some(m) = detect_timestamp(trimmed) {
        found.push(m);
    }
    if found.is_empty() {
        if let Some(m) = detect_base64(trimmed) {
            found.push(m);
        }
    }
    // 通用动作永远给：大小写、去空白、编码解码这些跟格式无关
    found.push(common_actions(trimmed));
    found
}

/// 面板里那张「这段文字是什么、能拿它做什么」的扁平列表。
///
/// macOS 版的预览区是一块能自由排版的面板：徽章一行、表格一块、按钮一排。
/// Linux 的 GTK ListBox 与 Windows 的 `LISTBOX` 都只认「一行一个字符串」，
/// 所以这里把三段压成一张平表 —— **压平这件事是共用的**，
/// 两个平台不该各写一遍（各写一遍必然慢慢长歪）。
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    /// 交给 [`apply`] 的动作 id。**空串表示这是一条只读的说明**，
    /// 选中了也不做事
    pub action: &'static str,
    /// 列表里显示的那一行
    pub label: String,
    /// 值得提醒的说明（比如已经过期的 exp）
    pub warning: bool,
}

/// 把 [`detect`] 的结果压成列表。
pub fn action_list(text: &str) -> Vec<Entry> {
    let mut entries = Vec::new();
    for found in detect(text) {
        // 先说明「这是什么」，再给「能做什么」—— 反过来的话用户得先猜
        for row in &found.rows {
            entries.push(Entry {
                action: "",
                label: format!("{} · {}：{}", found.badge, row.label, row.value),
                warning: row.warning,
            });
        }
        for action in &found.actions {
            entries.push(Entry {
                action: action.id,
                label: format!("[{}] {}", found.badge, action.title),
                warning: false,
            });
        }
    }
    entries
}

/// 执行一个动作。认不出的 id 返回 `None`。
pub fn apply(action: &str, text: &str) -> Option<String> {
    match action {
        "json.pretty" => pretty_json(text),
        "json.minify" => minify_json(text),
        "jwt.payload" => jwt_part(text, 1),
        "jwt.header" => jwt_part(text, 0),
        "base64.decode" => base64_decode(text).and_then(|b| String::from_utf8(b).ok()),
        "base64.encode" => Some(base64_encode(text.as_bytes())),
        "url.decode" => Some(percent_decode(text)),
        "url.encode" => Some(percent_encode(text)),
        "time.iso" => timestamp_of(text).map(|s| format_utc(s)),
        "time.epoch" => timestamp_of(text).map(|s| s.to_string()),
        "case.upper" => Some(text.to_uppercase()),
        "case.lower" => Some(text.to_lowercase()),
        "text.trim" => Some(trim_lines(text)),
        "text.collapse" => Some(collapse_whitespace(text)),
        "text.unescape" => Some(unescape(text)),
        _ => None,
    }
}

// ---------------------------------------------------------------- JSON

fn detect_json(text: &str) -> Option<Match> {
    let first = text.chars().next()?;
    if first != '{' && first != '[' {
        return None;
    }
    let value = parse_json(text)?;
    let (objects, arrays, depth) = json_shape(&value, 1);
    Some(Match {
        id: "json",
        badge: "JSON".to_string(),
        rendered: None,
        rows: vec![
            Row::new("对象", objects.to_string()),
            Row::new("数组", arrays.to_string()),
            Row::new("最大层深", depth.to_string()),
        ],
        actions: vec![
            Action::new("json.pretty", "格式化"),
            Action::new("json.minify", "压缩"),
        ],
    })
}

/// 极简 JSON 值。只为「验证是不是合法 JSON」与「重新排版」而存在，
/// 不追求完整的数值语义（数字原样保留字符串形式，避免浮点往返丢精度）。
#[derive(Debug, Clone, PartialEq)]
enum Json {
    Null,
    Bool(bool),
    /// 原样保留文本形式：`1e400` 与 `1.0` 重新输出时不该被改写
    Number(String),
    Str(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

fn parse_json(text: &str) -> Option<Json> {
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
const MAX_DEPTH: usize = 128;

fn parse_value(chars: &[char], at: &mut usize, depth: usize) -> Option<Json> {
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

fn parse_object(chars: &[char], at: &mut usize, depth: usize) -> Option<Json> {
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

fn parse_array(chars: &[char], at: &mut usize, depth: usize) -> Option<Json> {
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

fn parse_string(chars: &[char], at: &mut usize) -> Option<String> {
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

fn parse_number(chars: &[char], at: &mut usize) -> Option<Json> {
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

fn literal(chars: &[char], at: &mut usize, word: &str) -> Option<()> {
    for expected in word.chars() {
        if chars.get(*at) != Some(&expected) {
            return None;
        }
        *at += 1;
    }
    Some(())
}

fn skip_space(chars: &[char], at: &mut usize) {
    while matches!(chars.get(*at), Some(c) if c.is_whitespace()) {
        *at += 1;
    }
}

fn json_shape(value: &Json, depth: usize) -> (usize, usize, usize) {
    match value {
        Json::Object(entries) => {
            let mut objects = 1;
            let mut arrays = 0;
            let mut deepest = depth;
            for (_, child) in entries {
                let (o, a, d) = json_shape(child, depth + 1);
                objects += o;
                arrays += a;
                deepest = deepest.max(d);
            }
            (objects, arrays, deepest)
        }
        Json::Array(items) => {
            let mut objects = 0;
            let mut arrays = 1;
            let mut deepest = depth;
            for child in items {
                let (o, a, d) = json_shape(child, depth + 1);
                objects += o;
                arrays += a;
                deepest = deepest.max(d);
            }
            (objects, arrays, deepest)
        }
        _ => (0, 0, depth),
    }
}

fn pretty_json(text: &str) -> Option<String> {
    let value = parse_json(text.trim())?;
    let mut out = String::new();
    write_json(&value, 0, true, &mut out);
    Some(out)
}

fn minify_json(text: &str) -> Option<String> {
    let value = parse_json(text.trim())?;
    let mut out = String::new();
    write_json(&value, 0, false, &mut out);
    Some(out)
}

fn write_json(value: &Json, indent: usize, pretty: bool, out: &mut String) {
    let pad = |n: usize| "  ".repeat(n);
    match value {
        Json::Null => out.push_str("null"),
        Json::Bool(true) => out.push_str("true"),
        Json::Bool(false) => out.push_str("false"),
        Json::Number(raw) => out.push_str(raw),
        Json::Str(s) => {
            out.push('"');
            out.push_str(&escape_json(s));
            out.push('"');
        }
        Json::Array(items) if items.is_empty() => out.push_str("[]"),
        Json::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                if pretty {
                    let _ = write!(out, "\n{}", pad(indent + 1));
                }
                write_json(item, indent + 1, pretty, out);
            }
            if pretty {
                let _ = write!(out, "\n{}", pad(indent));
            }
            out.push(']');
        }
        Json::Object(entries) if entries.is_empty() => out.push_str("{}"),
        Json::Object(entries) => {
            out.push('{');
            for (index, (key, child)) in entries.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                if pretty {
                    let _ = write!(out, "\n{}", pad(indent + 1));
                }
                let _ = write!(out, "\"{}\":", escape_json(key));
                if pretty {
                    out.push(' ');
                }
                write_json(child, indent + 1, pretty, out);
            }
            if pretty {
                let _ = write!(out, "\n{}", pad(indent));
            }
            out.push('}');
        }
    }
}

fn escape_json(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out
}

// ---------------------------------------------------------------- JWT

fn detect_jwt(text: &str) -> Option<Match> {
    let parts: Vec<&str> = text.split('.').collect();
    if parts.len() != 3 || parts.iter().any(|p| p.is_empty()) {
        return None;
    }
    let header = decode_jwt_part(parts[0])?;
    let payload = decode_jwt_part(parts[1])?;
    // 头部必须是带 alg 的 JSON —— 光「三段 base64」会把很多别的东西认成 JWT
    let header_json = parse_json(&header)?;
    let Json::Object(fields) = &header_json else {
        return None;
    };
    if !fields.iter().any(|(k, _)| k == "alg") {
        return None;
    }

    let mut rows = Vec::new();
    if let Some(Json::Str(alg)) = fields.iter().find(|(k, _)| k == "alg").map(|(_, v)| v) {
        rows.push(Row::new("算法", alg.clone()));
    }
    if let Ok(payload_json) = parse_json(&payload).ok_or(()) {
        if let Json::Object(claims) = payload_json {
            for (key, value) in &claims {
                let text = json_scalar(value);
                match key.as_str() {
                    // 三个时间类声明额外翻成人看得懂的时刻
                    "exp" | "iat" | "nbf" => {
                        let seconds = text.parse::<i64>().unwrap_or(0);
                        let readable = format!("{text}（{}）", format_utc(seconds));
                        let row = Row::new(key, readable);
                        rows.push(if key == "exp" && seconds > 0 {
                            // 过期与否交给调用方比对当前时间；这里只标出它是时间
                            row
                        } else {
                            row
                        });
                    }
                    _ => rows.push(Row::new(key, text)),
                }
            }
        }
    }

    // JWT 的原文人根本读不了，这是**唯一**一个替换预览的场合
    let rendered = format!("{header}\n---\n{payload}");
    Some(Match {
        id: "jwt",
        badge: "JWT".to_string(),
        rendered: Some(rendered),
        rows,
        actions: vec![
            Action::new("jwt.payload", "复制载荷"),
            Action::new("jwt.header", "复制头部"),
        ],
    })
}

fn decode_jwt_part(part: &str) -> Option<String> {
    String::from_utf8(base64url_decode(part)?).ok()
}

fn jwt_part(text: &str, index: usize) -> Option<String> {
    let parts: Vec<&str> = text.trim().split('.').collect();
    if parts.len() != 3 {
        return None;
    }
    let decoded = decode_jwt_part(parts.get(index)?)?;
    pretty_json(&decoded).or(Some(decoded))
}

fn json_scalar(value: &Json) -> String {
    match value {
        Json::Str(s) => s.clone(),
        Json::Number(n) => n.clone(),
        Json::Bool(b) => b.to_string(),
        Json::Null => "null".to_string(),
        other => {
            let mut out = String::new();
            write_json(other, 0, false, &mut out);
            out
        }
    }
}

// ---------------------------------------------------------------- XML

fn detect_xml(text: &str) -> Option<Match> {
    if !text.starts_with('<') || !text.ends_with('>') {
        return None;
    }
    // 至少要有一对标签，否则 `<不是标签>` 这种也会被认上
    let tags = text.matches('<').count();
    if tags < 2 {
        return None;
    }
    let is_html = text.to_lowercase().starts_with("<!doctype html")
        || text.to_lowercase().starts_with("<html");
    Some(Match {
        id: "xml",
        badge: if is_html { "HTML" } else { "XML" }.to_string(),
        rendered: None,
        rows: vec![Row::new("标签数", tags.to_string())],
        actions: Vec::new(),
    })
}

// ---------------------------------------------------------------- URL

fn detect_url(text: &str) -> Option<Match> {
    if text.contains(char::is_whitespace) {
        return None;
    }
    let (scheme, rest) = text.split_once("://")?;
    if scheme.is_empty() || !scheme.chars().all(|c| c.is_ascii_alphanumeric() || c == '+') {
        return None;
    }
    let (authority, path_and_query) = match rest.find('/') {
        Some(at) => (&rest[..at], &rest[at..]),
        None => (rest, ""),
    };
    let mut rows = vec![
        Row::new("协议", scheme.to_string()),
        Row::new("主机", authority.to_string()),
    ];
    if let Some((path, query)) = path_and_query.split_once('?') {
        if !path.is_empty() {
            rows.push(Row::new("路径", path.to_string()));
        }
        for pair in query.split('&').filter(|p| !p.is_empty()) {
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            rows.push(Row::new(key, percent_decode(value)));
        }
    } else if !path_and_query.is_empty() {
        rows.push(Row::new("路径", path_and_query.to_string()));
    }
    Some(Match {
        id: "url",
        badge: "URL".to_string(),
        rendered: None,
        rows,
        actions: vec![
            Action::new("url.decode", "解码"),
            Action::new("url.encode", "编码"),
        ],
    })
}

// ---------------------------------------------------------------- 时间戳

/// 认得出的秒级时间戳范围：2001-09-09 到 2286-11-20。
///
/// 下界压在十位数上：再小的整数（订单号、端口、年份）远比时间戳常见，
/// 把它们都认成时间是骚扰。
const EPOCH_MIN: i64 = 1_000_000_000;
const EPOCH_MAX: i64 = 9_999_999_999;

fn timestamp_of(text: &str) -> Option<i64> {
    let raw = text.trim();
    let digits: i64 = raw.parse().ok()?;
    match raw.len() {
        10 if (EPOCH_MIN..=EPOCH_MAX).contains(&digits) => Some(digits),
        // 毫秒
        13 => Some(digits / 1000),
        _ => None,
    }
}

fn detect_timestamp(text: &str) -> Option<Match> {
    let seconds = timestamp_of(text)?;
    let unit = if text.trim().len() == 13 { "毫秒" } else { "秒" };
    Some(Match {
        id: "timestamp",
        badge: "时间戳".to_string(),
        rendered: None,
        rows: vec![
            Row::new("单位", unit),
            Row::new("UTC", format_utc(seconds)),
            Row::new("Unix 秒", seconds.to_string()),
        ],
        actions: vec![
            Action::new("time.iso", "转成时间"),
            Action::new("time.epoch", "转成秒"),
        ],
    })
}

/// Unix 秒 → `YYYY-MM-DD HH:MM:SS UTC`。
///
/// 用 UTC 而不是本地时间：这个 crate 拿不到时区库，
/// **含糊的本地时间比明确的 UTC 更糟**。
pub fn format_utc(seconds: i64) -> String {
    let days = seconds.div_euclid(86_400);
    let rem = seconds.rem_euclid(86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };
    format!(
        "{year:04}-{m:02}-{d:02} {:02}:{:02}:{:02} UTC",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

// ---------------------------------------------------------------- Base64

fn detect_base64(text: &str) -> Option<Match> {
    // 太短的「Base64」几乎都是误认：四个字符的普通单词一抓一大把
    if text.len() < 16 || text.len() % 4 != 0 {
        return None;
    }
    if !text
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '/' || c == '=')
    {
        return None;
    }
    let decoded = base64_decode(text)?;
    let as_text = String::from_utf8(decoded.clone()).ok();
    let mut rows = vec![Row::new("解码后长度", format!("{} 字节", decoded.len()))];
    if as_text.is_none() {
        rows.push(Row::new("内容", "二进制（不是文本）").warn());
    }
    Some(Match {
        id: "base64",
        badge: "Base64".to_string(),
        // 刻意不填 rendered：解码是显式动作，不能因为认出来就把预览换掉，
        // 否则预览显示的和粘出去的不是一个东西
        rendered: None,
        rows,
        actions: vec![Action::new("base64.decode", "解码")],
    })
}

const BASE64_ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// 标准 Base64 编码。
pub fn base64_encode(data: &[u8]) -> String {
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let packed = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(BASE64_ALPHABET[(packed >> 18) as usize & 63] as char);
        out.push(BASE64_ALPHABET[(packed >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            BASE64_ALPHABET[(packed >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            BASE64_ALPHABET[packed as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

/// 标准 Base64 解码。含非法字符时返回 `None`。
pub fn base64_decode(text: &str) -> Option<Vec<u8>> {
    decode_base64_with(text, false)
}

/// URL-safe Base64 解码（JWT 用的那种：`-_` 代替 `+/`，可以没有 `=` 补齐）。
pub fn base64url_decode(text: &str) -> Option<Vec<u8>> {
    decode_base64_with(text, true)
}

fn decode_base64_with(text: &str, url_safe: bool) -> Option<Vec<u8>> {
    let mut bits = 0u32;
    let mut count = 0u32;
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    for c in text.chars() {
        if c == '=' {
            break;
        }
        let value = match c {
            'A'..='Z' => c as u32 - 'A' as u32,
            'a'..='z' => c as u32 - 'a' as u32 + 26,
            '0'..='9' => c as u32 - '0' as u32 + 52,
            '+' if !url_safe => 62,
            '/' if !url_safe => 63,
            '-' if url_safe => 62,
            '_' if url_safe => 63,
            // 换行在贴过来的 Base64 里很常见，忽略而不是判定为非法
            '\n' | '\r' => continue,
            _ => return None,
        };
        bits = (bits << 6) | value;
        count += 6;
        if count >= 8 {
            count -= 8;
            out.push((bits >> count) as u8);
        }
    }
    Some(out)
}

// ---------------------------------------------------------------- 百分号编码

/// 百分号解码，顺带把 `+` 还原成空格（query 里的惯例）。
pub fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'%' if index + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok();
                match hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                    Some(byte) => {
                        out.push(byte);
                        index += 3;
                    }
                    // 不是合法的十六进制就原样留着 —— 一个孤零零的 % 很常见
                    None => {
                        out.push(b'%');
                        index += 1;
                    }
                }
            }
            b'+' => {
                out.push(b' ');
                index += 1;
            }
            other => {
                out.push(other);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).to_string()
}

/// 百分号编码。保留 RFC 3986 的非保留字符。
pub fn percent_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            other => {
                let _ = write!(out, "%{other:02X}");
            }
        }
    }
    out
}

// ---------------------------------------------------------------- 通用动作

fn common_actions(text: &str) -> Match {
    let lines = text.lines().count();
    let chars = text.chars().count();
    Match {
        id: "common",
        badge: "文本".to_string(),
        rendered: None,
        rows: vec![
            Row::new("字符数", chars.to_string()),
            Row::new("行数", lines.to_string()),
        ],
        actions: vec![
            Action::new("case.upper", "转大写"),
            Action::new("case.lower", "转小写"),
            Action::new("text.trim", "去每行首尾空白"),
            Action::new("text.collapse", "压成一行"),
            Action::new("text.unescape", "反转义"),
            Action::new("base64.encode", "Base64 编码"),
            Action::new("url.encode", "URL 编码"),
        ],
    }
}

fn trim_lines(text: &str) -> String {
    text.lines()
        .map(str::trim)
        .collect::<Vec<_>>()
        .join("\n")
}

fn collapse_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// 把 `\n` `\t` `\"` 这类转义序列还原成真正的字符。
///
/// 从日志里抠出来的 JSON 字符串常常整段带着转义，人根本读不了。
fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            Some('"') => out.push('"'),
            Some('\\') => out.push('\\'),
            Some('u') => {
                let hex: String = chars.by_ref().take(4).collect();
                match u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32) {
                    Some(decoded) => out.push(decoded),
                    // 认不出的转义原样留着，别把内容改坏
                    None => {
                        out.push_str("\\u");
                        out.push_str(&hex);
                    }
                }
            }
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn badges(text: &str) -> Vec<String> {
        detect(text).into_iter().map(|m| m.badge).collect()
    }

    #[test]
    fn plain_text_still_gets_the_generic_actions() {
        let matches = detect("就是一句话");
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].id, "common");
        assert!(matches[0].actions.iter().any(|a| a.id == "case.upper"));
    }

    #[test]
    fn json_is_recognised_and_reformatted_both_ways() {
        let text = r#"{"b":1,"a":[1,2,{"c":null}]}"#;
        assert!(badges(text).contains(&"JSON".to_string()));

        let pretty = apply("json.pretty", text).unwrap();
        assert!(pretty.contains('\n'));
        // 键的顺序不变 —— 重排会让 diff 面目全非
        assert!(pretty.find("\"b\"").unwrap() < pretty.find("\"a\"").unwrap());

        let minified = apply("json.minify", &pretty).unwrap();
        assert_eq!(minified, text);
    }

    #[test]
    fn malformed_json_is_not_recognised() {
        for bad in [r#"{"a":}"#, "{", "[1,2", r#"{"a" 1}"#, r#"{"a":1}x"#] {
            assert!(
                !badges(bad).contains(&"JSON".to_string()),
                "{bad} 不该被认成 JSON"
            );
        }
    }

    #[test]
    fn json_numbers_survive_a_round_trip_without_being_rewritten() {
        // 用浮点解析再输出的话，1e400 会变成 inf、1.0 会变成 1
        let text = r#"{"big":1e400,"exact":1.0,"neg":-0.5}"#;
        assert_eq!(apply("json.minify", text).unwrap(), text);
    }

    #[test]
    fn deeply_nested_json_is_refused_rather_than_blowing_the_stack() {
        // 剪贴板内容完全不可信，一串 [[[[ 不能把我们递归到爆栈
        let bomb = "[".repeat(10_000);
        assert!(!badges(&bomb).contains(&"JSON".to_string()));
    }

    #[test]
    fn jwt_beats_base64_because_it_is_checked_first() {
        // header {"alg":"HS256","typ":"JWT"} / payload {"sub":"1","exp":1700000000}
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIiwiZXhwIjoxNzAwMDAwMDAwfQ.abc";
        let ids: Vec<&str> = detect(jwt).into_iter().map(|m| m.id).collect();
        assert!(ids.contains(&"jwt"), "应当认成 JWT，实得 {ids:?}");
        assert!(!ids.contains(&"base64"), "认成 JWT 之后不该再认一次 Base64");
    }

    #[test]
    fn jwt_shows_its_claims_and_turns_epochs_into_readable_times() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIiwiZXhwIjoxNzAwMDAwMDAwfQ.abc";
        let m = detect(jwt).into_iter().find(|m| m.id == "jwt").unwrap();
        assert!(m.rows.iter().any(|r| r.label == "算法" && r.value == "HS256"));
        let exp = m.rows.iter().find(|r| r.label == "exp").unwrap();
        assert!(exp.value.contains("2023-11-14"), "exp 应当同时给出可读时刻：{}", exp.value);
        // JWT 是唯一一个替换预览的场合 —— 原文人根本读不了
        assert!(m.rendered.is_some());
    }

    #[test]
    fn three_base64_segments_without_an_alg_are_not_a_jwt() {
        // 光看「三段用点分隔的 base64」会把很多东西误认成 JWT
        let fake = "aGVsbG8.d29ybGQ.YWdhaW4";
        assert!(!detect(fake).iter().any(|m| m.id == "jwt"));
    }

    #[test]
    fn base64_does_not_replace_the_preview() {
        // 曾经自动渲染成解码结果，导致预览显示的和粘出去的不是一个东西
        let text = base64_encode(b"hello world, this is long enough");
        let m = detect(&text).into_iter().find(|m| m.id == "base64").unwrap();
        assert!(m.rendered.is_none(), "解码是显式动作，不能自动替换预览");
        assert_eq!(
            apply("base64.decode", &text).unwrap(),
            "hello world, this is long enough"
        );
    }

    #[test]
    fn short_strings_are_not_guessed_to_be_base64() {
        // 四个字母的普通单词一抓一大把
        for text in ["test", "abcd", "Zm9v"] {
            assert!(!detect(text).iter().any(|m| m.id == "base64"), "{text}");
        }
    }

    #[test]
    fn base64_survives_a_round_trip_including_padding_edges() {
        for original in ["a", "ab", "abc", "abcd", "", "中文也行"] {
            let encoded = base64_encode(original.as_bytes());
            let decoded = base64_decode(&encoded).unwrap();
            assert_eq!(String::from_utf8(decoded).unwrap(), original);
        }
    }

    #[test]
    fn base64_ignores_line_breaks_but_rejects_real_garbage() {
        let wrapped = "aGVsbG8g\nd29ybGQ=";
        assert_eq!(
            String::from_utf8(base64_decode(wrapped).unwrap()).unwrap(),
            "hello world"
        );
        assert!(base64_decode("这不是 base64").is_none());
    }

    #[test]
    fn urls_are_broken_into_parts_with_decoded_query_values() {
        let m = detect("https://example.com/a/b?q=%E4%B8%AD%E6%96%87&n=1")
            .into_iter()
            .find(|m| m.id == "url")
            .unwrap();
        assert!(m.rows.iter().any(|r| r.label == "主机" && r.value == "example.com"));
        assert!(m.rows.iter().any(|r| r.label == "路径" && r.value == "/a/b"));
        assert!(
            m.rows.iter().any(|r| r.label == "q" && r.value == "中文"),
            "query 的值应当解码后显示"
        );
    }

    #[test]
    fn percent_coding_round_trips_and_tolerates_stray_signs() {
        let original = "中文 & 空格/斜杠";
        assert_eq!(percent_decode(&percent_encode(original)), original);
        // query 里 + 是空格
        assert_eq!(percent_decode("a+b"), "a b");
        // 孤零零的 % 原样留着，别把内容改坏
        assert_eq!(percent_decode("100% sure"), "100% sure");
        assert_eq!(percent_decode("%zz"), "%zz");
    }

    #[test]
    fn timestamps_are_recognised_only_in_a_plausible_range() {
        assert!(badges("1700000000").contains(&"时间戳".to_string()));
        assert!(badges("1700000000000").contains(&"时间戳".to_string()));
        // 订单号、端口、年份远比时间戳常见，不该被骚扰
        for not_time in ["42", "8080", "2026", "123456"] {
            assert!(
                !badges(not_time).contains(&"时间戳".to_string()),
                "{not_time} 不该被认成时间戳"
            );
        }
    }

    #[test]
    fn timestamp_conversion_matches_known_instants() {
        assert_eq!(apply("time.iso", "0").as_deref(), None, "0 不在识别范围内");
        assert_eq!(
            apply("time.iso", "1700000000").unwrap(),
            "2023-11-14 22:13:20 UTC"
        );
        // 毫秒的转成秒
        assert_eq!(apply("time.epoch", "1700000000123").unwrap(), "1700000000");
    }

    #[test]
    fn xml_and_html_get_different_badges() {
        assert!(badges("<a><b>1</b></a>").contains(&"XML".to_string()));
        assert!(badges("<html><body>x</body></html>").contains(&"HTML".to_string()));
        // 只有一个尖括号的普通文本不该被认上
        assert!(!badges("<不是标签>").contains(&"XML".to_string()));
    }

    #[test]
    fn generic_text_transforms_do_what_they_say() {
        assert_eq!(apply("case.upper", "aBc").unwrap(), "ABC");
        assert_eq!(apply("case.lower", "aBc").unwrap(), "abc");
        assert_eq!(apply("text.trim", "  a  \n  b  ").unwrap(), "a\nb");
        assert_eq!(apply("text.collapse", "a\n\n  b\tc").unwrap(), "a b c");
    }

    #[test]
    fn unescaping_restores_real_characters_and_leaves_unknown_escapes_alone() {
        assert_eq!(apply("text.unescape", r"a\nb\tc").unwrap(), "a\nb\tc");
        assert_eq!(apply("text.unescape", r#"say \"hi\""#).unwrap(), "say \"hi\"");
        assert_eq!(apply("text.unescape", r"中文").unwrap(), "中文");
        // 认不出的转义原样留着，别把内容改坏
        assert_eq!(apply("text.unescape", r"\q").unwrap(), r"\q");
        assert_eq!(apply("text.unescape", r"\uZZZZ").unwrap(), r"\uZZZZ");
    }

    #[test]
    fn an_unknown_action_returns_nothing_rather_than_mangling_the_text() {
        assert_eq!(apply("不存在的动作", "abc"), None);
    }

    #[test]
    fn oversized_input_is_skipped_instead_of_scanned() {
        // 剪贴板里出现几 MB 的日志是常事，每选中一次就卡一下比不给这功能更糟
        let huge = "x".repeat(MAX_LENGTH + 1);
        assert!(detect(&huge).is_empty());
    }

    #[test]
    fn empty_and_whitespace_input_produces_nothing() {
        assert!(detect("").is_empty());
        assert!(detect("   \n  ").is_empty());
    }

    #[test]
    fn the_flat_list_puts_what_it_is_before_what_you_can_do() {
        // 反过来的话用户得先猜这段东西被认成了什么
        let entries = action_list(r#"{"a":1}"#);
        let first_action = entries.iter().position(|e| !e.action.is_empty()).unwrap();
        let json_rows = entries
            .iter()
            .take(first_action)
            .filter(|e| e.label.starts_with("JSON"))
            .count();
        assert!(json_rows > 0, "JSON 的说明该排在它的动作前面");
        assert!(entries.iter().any(|e| e.action == "json.pretty"));
    }

    #[test]
    fn every_listed_action_can_actually_be_applied() {
        // 列出来点不动的动作比不列更糟
        for sample in [
            r#"{"a":[1,2]}"#,
            "https://example.com/x?y=1",
            "1785760496",
            "<a><b/></a>",
            "aGVsbG8gd29ybGQ=",
            "随便一段中文",
        ] {
            for entry in action_list(sample) {
                if entry.action.is_empty() {
                    continue;
                }
                assert!(
                    apply(entry.action, sample).is_some(),
                    "{} 列了 {} 却执行不了",
                    sample,
                    entry.action
                );
            }
        }
    }

    #[test]
    fn informational_rows_are_not_actions() {
        let entries = action_list("1785760496");
        let info: Vec<&Entry> = entries.iter().filter(|e| e.action.is_empty()).collect();
        assert!(!info.is_empty(), "时间戳该给出它读成了几号");
        assert!(info.iter().all(|e| e.action.is_empty()));
    }

    #[test]
    fn plain_text_still_offers_the_generic_actions() {
        // 认不出格式不等于什么都不能做：大小写、去空白这些跟格式无关
        let entries = action_list("随便一段中文");
        assert!(entries.iter().any(|e| e.action == "case.upper"));
    }

    #[test]
    fn oversized_input_produces_an_empty_list_rather_than_hanging() {
        assert!(action_list(&"x".repeat(MAX_LENGTH + 1)).is_empty());
    }
}
