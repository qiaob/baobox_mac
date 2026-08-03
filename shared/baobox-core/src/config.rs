//! 配置文件：分节的 key = value，**保留不认识的东西**。
//!
//! # 为什么不是 JSON / TOML
//!
//! 这个 crate 零依赖，为了一份配置引 serde + toml 不划算。而手写 JSON 又有个
//! 更实际的问题：**改一个键就得整份重写**，用户手写的注释、以及新版本才认识的键，
//! 都会在一次读-改-写之后消失。
//!
//! 这里用行级模型：解析时把每一行按原样记下来，改键只动那一行，
//! 不认识的行原样写回。与 macOS 侧「只动自己的键、保留未知字段」是同一条约定
//! （见 `CLAUDE.md` 约定 4）。
//!
//! ```text
//! # 注释会被保留
//! [screenshot]
//! copy_to_clipboard = true
//! save_to_disk = true
//!
//! [hotkey]
//! screenshot.capture = Ctrl+Shift+S
//! ```

/// 一行配置。解析时保留原样，写回时逐行还原。
#[derive(Debug, Clone, PartialEq)]
enum Line {
    /// 空行或注释，原样保留
    Verbatim(String),
    /// `[section]`
    Section(String),
    /// `key = value`，`raw` 是原始文本（改值时才重新拼）
    Pair { key: String, value: String },
}

/// 一份配置。
#[derive(Debug, Clone, Default)]
pub struct Config {
    lines: Vec<Line>,
}

impl Config {
    /// 空配置。
    pub fn new() -> Self {
        Self::default()
    }

    /// 解析。**任何一行看不懂都当成注释保留**，绝不报错 ——
    /// 配置文件是用户的东西，读不懂的部分只能原样留着，不能丢。
    pub fn parse(text: &str) -> Self {
        let mut lines = Vec::new();
        for raw in text.lines() {
            let trimmed = raw.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with(';') {
                lines.push(Line::Verbatim(raw.to_string()));
                continue;
            }
            if let Some(name) = trimmed
                .strip_prefix('[')
                .and_then(|rest| rest.strip_suffix(']'))
            {
                lines.push(Line::Section(name.trim().to_string()));
                continue;
            }
            match trimmed.split_once('=') {
                Some((key, value)) => lines.push(Line::Pair {
                    key: key.trim().to_string(),
                    value: value.trim().to_string(),
                }),
                // 既不是节、也不是键值 —— 原样留着
                None => lines.push(Line::Verbatim(raw.to_string())),
            }
        }
        Self { lines }
    }

    /// 写回文本。
    pub fn to_text(&self) -> String {
        let mut out = String::new();
        for line in &self.lines {
            match line {
                Line::Verbatim(raw) => out.push_str(raw),
                Line::Section(name) => out.push_str(&format!("[{name}]")),
                Line::Pair { key, value } => out.push_str(&format!("{key} = {value}")),
            }
            out.push('\n');
        }
        out
    }

    /// 读一个值。
    pub fn get(&self, section: &str, key: &str) -> Option<&str> {
        let mut current = "";
        for line in &self.lines {
            match line {
                Line::Section(name) => current = name,
                Line::Pair { key: k, value } if current == section && k == key => {
                    return Some(value)
                }
                _ => {}
            }
        }
        None
    }

    /// 读一个布尔值。认 `true/false`、`yes/no`、`1/0`（大小写不敏感）。
    pub fn bool_or(&self, section: &str, key: &str, fallback: bool) -> bool {
        match self.get(section, key).map(str::trim) {
            Some(value) => match value.to_ascii_lowercase().as_str() {
                "true" | "yes" | "on" | "1" => true,
                "false" | "no" | "off" | "0" => false,
                // 值看不懂时用默认值，而不是当成 false —— 拼错一个字母
                // 就把功能关掉，用户根本查不出来
                _ => fallback,
            },
            None => fallback,
        }
    }

    /// 读一个整数。
    pub fn usize_or(&self, section: &str, key: &str, fallback: usize) -> usize {
        self.get(section, key)
            .and_then(|value| value.trim().parse().ok())
            .unwrap_or(fallback)
    }

    /// 读一个字符串。
    pub fn string_or(&self, section: &str, key: &str, fallback: &str) -> String {
        match self.get(section, key) {
            Some(value) if !value.is_empty() => value.to_string(),
            _ => fallback.to_string(),
        }
    }

    /// 写一个值：已存在就**就地改那一行**，不存在就补在对应节的末尾，
    /// 节也不存在就新建一节。
    ///
    /// 就地改是关键 —— 这样键的顺序、周围的注释都不会被打乱。
    pub fn set(&mut self, section: &str, key: &str, value: &str) {
        let mut current = "";
        let mut section_end: Option<usize> = None;
        for (index, line) in self.lines.iter().enumerate() {
            match line {
                Line::Section(name) => {
                    if current == section {
                        // 刚离开目标节，记下插入点
                        section_end.get_or_insert(index);
                    }
                    current = name;
                }
                Line::Pair { key: k, .. } if current == section && k == key => {
                    self.lines[index] = Line::Pair {
                        key: key.to_string(),
                        value: value.to_string(),
                    };
                    return;
                }
                _ => {}
            }
        }
        if current == section {
            section_end.get_or_insert(self.lines.len());
        }

        let pair = Line::Pair {
            key: key.to_string(),
            value: value.to_string(),
        };
        match section_end {
            Some(at) => self.lines.insert(at, pair),
            None => {
                // 整节都不存在：新起一节
                if !self.lines.is_empty() {
                    self.lines.push(Line::Verbatim(String::new()));
                }
                self.lines.push(Line::Section(section.to_string()));
                self.lines.push(pair);
            }
        }
    }

    /// 写一个布尔值。
    pub fn set_bool(&mut self, section: &str, key: &str, value: bool) {
        self.set(section, key, if value { "true" } else { "false" });
    }

    /// 一个节里的全部键（按出现顺序）。
    pub fn keys(&self, section: &str) -> Vec<&str> {
        let mut current = "";
        let mut found = Vec::new();
        for line in &self.lines {
            match line {
                Line::Section(name) => current = name,
                Line::Pair { key, .. } if current == section => found.push(key.as_str()),
                _ => {}
            }
        }
        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "\
# 我的配置
[screenshot]
copy_to_clipboard = true
save_to_disk = false

[hotkey]
screenshot.capture = Ctrl+Shift+S
";

    #[test]
    fn reading_values_of_each_kind() {
        let config = Config::parse(SAMPLE);
        assert_eq!(config.get("screenshot", "copy_to_clipboard"), Some("true"));
        assert!(config.bool_or("screenshot", "copy_to_clipboard", false));
        assert!(!config.bool_or("screenshot", "save_to_disk", true));
        assert_eq!(
            config.string_or("hotkey", "screenshot.capture", ""),
            "Ctrl+Shift+S"
        );
        // 同名键在别的节里不该被读到
        assert_eq!(config.get("hotkey", "copy_to_clipboard"), None);
    }

    #[test]
    fn a_round_trip_changes_nothing() {
        assert_eq!(Config::parse(SAMPLE).to_text(), SAMPLE);
    }

    #[test]
    fn setting_a_value_edits_that_line_and_leaves_everything_else_alone() {
        let mut config = Config::parse(SAMPLE);
        config.set_bool("screenshot", "save_to_disk", true);
        let text = config.to_text();
        assert!(text.contains("save_to_disk = true"));
        // 注释还在，顺序也没乱
        assert!(text.starts_with("# 我的配置"));
        assert!(
            text.find("copy_to_clipboard").unwrap() < text.find("save_to_disk").unwrap(),
            "键的顺序不该被打乱"
        );
    }

    #[test]
    fn unknown_keys_and_comments_survive_a_read_modify_write() {
        // 老版本读到新版本写的配置，改一个自己认识的键，再写回来
        let text = "[screenshot]\n# 这是未来版本的键\nfuture_option = 42\ncopy_to_clipboard = false\n";
        let mut config = Config::parse(text);
        config.set_bool("screenshot", "copy_to_clipboard", true);
        let out = config.to_text();
        assert!(out.contains("future_option = 42"), "不认识的键必须留着");
        assert!(out.contains("# 这是未来版本的键"));
        assert!(out.contains("copy_to_clipboard = true"));
    }

    #[test]
    fn a_new_key_lands_at_the_end_of_its_own_section() {
        let mut config = Config::parse(SAMPLE);
        config.set("screenshot", "format", "png");
        let text = config.to_text();
        // 落在 screenshot 节里，而不是跑到 hotkey 节后面
        assert!(text.find("format = png").unwrap() < text.find("[hotkey]").unwrap());
    }

    #[test]
    fn a_new_section_is_appended() {
        let mut config = Config::parse(SAMPLE);
        config.set("clipboard", "limit", "50");
        let text = config.to_text();
        assert!(text.contains("[clipboard]"));
        assert!(text.contains("limit = 50"));
        assert_eq!(config.get("clipboard", "limit"), Some("50"));
    }

    #[test]
    fn writing_into_an_empty_config_works() {
        let mut config = Config::new();
        config.set("a", "b", "c");
        assert_eq!(config.to_text(), "[a]\nb = c\n");
    }

    #[test]
    fn booleans_accept_the_usual_spellings_and_fall_back_on_nonsense() {
        let config = Config::parse("[s]\na = yes\nb = OFF\nc = 1\nd = 香蕉\n");
        assert!(config.bool_or("s", "a", false));
        assert!(!config.bool_or("s", "b", true));
        assert!(config.bool_or("s", "c", false));
        // 值拼错时用默认值，而不是悄悄当成 false
        assert!(config.bool_or("s", "d", true));
        assert!(!config.bool_or("s", "d", false));
    }

    #[test]
    fn garbage_lines_are_preserved_rather_than_dropped() {
        let text = "[s]\n这一行既不是节也不是键值\nk = v\n";
        let config = Config::parse(text);
        assert_eq!(config.get("s", "k"), Some("v"));
        assert_eq!(config.to_text(), text, "看不懂的行也要原样写回");
    }

    #[test]
    fn values_containing_equals_signs_survive() {
        // Base64、URL 里都可能有 =，只在第一个 = 处切
        let config = Config::parse("[s]\ntoken = a=b=c\n");
        assert_eq!(config.get("s", "token"), Some("a=b=c"));
    }

    #[test]
    fn keys_lists_a_sections_contents_in_order() {
        let config = Config::parse(SAMPLE);
        assert_eq!(
            config.keys("screenshot"),
            vec!["copy_to_clipboard", "save_to_disk"]
        );
        assert!(config.keys("nope").is_empty());
    }
}
