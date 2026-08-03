//! 设置的**声明**：有哪些选项、叫什么、默认值是什么。
//!
//! 界面由平台层用各自的原生控件画（Windows 用 Win32 通用控件，Linux 用 GTK），
//! 但「设置有哪些」只有这一份定义。于是两个平台的设置项**不会走散**，
//! 加一个选项也只要改一处。
//!
//! # 值一律以字符串进出配置
//!
//! 配置文件本来就是文本。让 [`Field`] 自己负责「字符串 ↔ 类型」的换算，
//! 平台层就只需要处理「原生控件 ↔ 字符串」这一件事，不必按类型分叉。

use baobox_core::config::Config;

/// 一项设置的类型与取值范围。
#[derive(Debug, Clone, PartialEq)]
pub enum FieldKind {
    /// 开关
    Toggle {
        /// 默认值
        default: bool,
    },
    /// 若干互斥选项。`(存进配置的值, 显示的名字)`
    Choice {
        /// 可选项
        options: Vec<(String, String)>,
        /// 默认值（存进配置的那个）
        default: String,
    },
    /// 一行文本
    Text {
        /// 默认值
        default: String,
        /// 空着时控件里显示的灰字
        placeholder: String,
    },
    /// 整数，带上下界
    Number {
        /// 默认值
        default: i64,
        /// 下界（含）
        min: i64,
        /// 上界（含）
        max: i64,
    },
    /// 全局快捷键。值是 `baobox_core::hotkey::KeyCombo` 的文本形式，
    /// 空串表示用户主动解绑
    Hotkey {
        /// 出厂默认；`None` 表示出厂不绑定
        default: Option<String>,
    },
}

/// 一项设置。
#[derive(Debug, Clone, PartialEq)]
pub struct Field {
    /// 配置里的键名
    pub key: String,
    /// 控件旁边的标题
    pub label: String,
    /// 标题下面的一行小字。说清楚这个开关**到底会发生什么**，
    /// 而不是把标题换个说法重复一遍
    pub help: Option<String>,
    /// 类型与取值
    pub kind: FieldKind,
}

impl Field {
    /// 一个开关。
    pub fn toggle(key: &str, label: &str, default: bool) -> Self {
        Self {
            key: key.to_string(),
            label: label.to_string(),
            help: None,
            kind: FieldKind::Toggle { default },
        }
    }

    /// 若干互斥选项。
    pub fn choice(key: &str, label: &str, options: &[(&str, &str)], default: &str) -> Self {
        Self {
            key: key.to_string(),
            label: label.to_string(),
            help: None,
            kind: FieldKind::Choice {
                options: options
                    .iter()
                    .map(|(value, title)| (value.to_string(), title.to_string()))
                    .collect(),
                default: default.to_string(),
            },
        }
    }

    /// 一行文本。
    pub fn text(key: &str, label: &str, default: &str, placeholder: &str) -> Self {
        Self {
            key: key.to_string(),
            label: label.to_string(),
            help: None,
            kind: FieldKind::Text {
                default: default.to_string(),
                placeholder: placeholder.to_string(),
            },
        }
    }

    /// 一个整数。
    pub fn number(key: &str, label: &str, default: i64, min: i64, max: i64) -> Self {
        Self {
            key: key.to_string(),
            label: label.to_string(),
            help: None,
            kind: FieldKind::Number { default, min, max },
        }
    }

    /// 一个快捷键。
    pub fn hotkey(key: &str, label: &str, default: Option<&str>) -> Self {
        Self {
            key: key.to_string(),
            label: label.to_string(),
            help: None,
            kind: FieldKind::Hotkey {
                default: default.map(str::to_string),
            },
        }
    }

    /// 补一行说明。
    pub fn with_help(mut self, help: &str) -> Self {
        self.help = Some(help.to_string());
        self
    }

    /// 从配置里读出当前值的**字符串形式**（控件直接用）。
    pub fn value(&self, config: &Config, section: &str) -> String {
        let stored = config.get(section, &self.key);
        match &self.kind {
            FieldKind::Toggle { default } => {
                let on = config.bool_or(section, &self.key, *default);
                if on { "true" } else { "false" }.to_string()
            }
            FieldKind::Choice { options, default } => match stored {
                // 配置里存着一个已经不存在的选项（降级、改名）→ 退回默认值，
                // 而不是让控件显示一个空白项
                Some(value) if options.iter().any(|(candidate, _)| candidate == value) => {
                    value.to_string()
                }
                _ => default.clone(),
            },
            FieldKind::Text { default, .. } => {
                stored.map(str::to_string).unwrap_or_else(|| default.clone())
            }
            FieldKind::Number { default, min, max } => {
                let value = stored
                    .and_then(|text| text.trim().parse::<i64>().ok())
                    .unwrap_or(*default);
                value.clamp(*min, *max).to_string()
            }
            FieldKind::Hotkey { default } => stored
                .map(str::to_string)
                .unwrap_or_else(|| default.clone().unwrap_or_default()),
        }
    }

    /// 把控件里的值写回配置。越界的数字会被夹回范围内。
    pub fn store(&self, config: &mut Config, section: &str, value: &str) {
        let normalized = match &self.kind {
            FieldKind::Number { min, max, default } => value
                .trim()
                .parse::<i64>()
                .unwrap_or(*default)
                .clamp(*min, *max)
                .to_string(),
            _ => value.to_string(),
        };
        config.set(section, &self.key, &normalized);
    }
}

/// 设置窗口里的一页 —— 一个工具一页。
#[derive(Debug, Clone, PartialEq)]
pub struct SettingsPage {
    /// 所属工具的 id，同时是配置里的节名
    pub section: String,
    /// 侧栏里显示的标题
    pub title: String,
    /// 这一页的设置项
    pub fields: Vec<Field>,
}

impl SettingsPage {
    /// 造一页。
    pub fn new(section: &str, title: &str, fields: Vec<Field>) -> Self {
        Self {
            section: section.to_string(),
            title: title.to_string(),
            fields,
        }
    }

    /// 把这一页的所有默认值写进配置（首次启动时生成一份带注释的完整配置用）。
    ///
    /// **已经有值的键不动** —— 这个函数会在每次启动时跑，覆盖用户的设置是灾难。
    pub fn fill_defaults(&self, config: &mut Config) {
        for field in &self.fields {
            if config.get(&self.section, &field.key).is_none() {
                let default = field.value(config, &self.section);
                config.set(&self.section, &field.key, &default);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page() -> SettingsPage {
        SettingsPage::new(
            "screenshot",
            "截图",
            vec![
                Field::toggle("copy_to_clipboard", "复制到剪贴板", true),
                Field::choice(
                    "format",
                    "格式",
                    &[("png", "PNG"), ("jpg", "JPEG")],
                    "png",
                ),
                Field::number("history_limit", "历史保留", 20, 1, 200),
                Field::text("save_dir", "保存到", "", "~/Pictures/Baobox"),
            ],
        )
    }

    #[test]
    fn defaults_come_out_when_the_config_is_empty() {
        let config = Config::new();
        let page = page();
        assert_eq!(page.fields[0].value(&config, "screenshot"), "true");
        assert_eq!(page.fields[1].value(&config, "screenshot"), "png");
        assert_eq!(page.fields[2].value(&config, "screenshot"), "20");
        assert_eq!(page.fields[3].value(&config, "screenshot"), "");
    }

    #[test]
    fn stored_values_win_over_defaults() {
        let mut config = Config::new();
        config.set("screenshot", "copy_to_clipboard", "false");
        config.set("screenshot", "format", "jpg");
        let page = page();
        assert_eq!(page.fields[0].value(&config, "screenshot"), "false");
        assert_eq!(page.fields[1].value(&config, "screenshot"), "jpg");
    }

    #[test]
    fn an_option_that_no_longer_exists_falls_back_to_the_default() {
        // 降级或改名之后配置里可能留着一个已经没有的选项
        let mut config = Config::new();
        config.set("screenshot", "format", "webp");
        assert_eq!(
            page().fields[1].value(&config, "screenshot"),
            "png",
            "控件不该显示一个空白项"
        );
    }

    #[test]
    fn numbers_are_clamped_both_when_read_and_when_written() {
        let mut config = Config::new();
        config.set("screenshot", "history_limit", "9999");
        let page = page();
        assert_eq!(page.fields[2].value(&config, "screenshot"), "200");

        page.fields[2].store(&mut config, "screenshot", "-5");
        assert_eq!(config.get("screenshot", "history_limit"), Some("1"));
    }

    #[test]
    fn a_non_numeric_value_falls_back_to_the_default() {
        let mut config = Config::new();
        config.set("screenshot", "history_limit", "很多");
        assert_eq!(page().fields[2].value(&config, "screenshot"), "20");
    }

    #[test]
    fn filling_defaults_never_overwrites_what_the_user_set() {
        let mut config = Config::new();
        config.set("screenshot", "copy_to_clipboard", "false");
        page().fill_defaults(&mut config);
        assert_eq!(
            config.get("screenshot", "copy_to_clipboard"),
            Some("false"),
            "每次启动都跑一遍，覆盖用户设置就是灾难"
        );
        // 没设过的键补上默认值
        assert_eq!(config.get("screenshot", "format"), Some("png"));
    }

    #[test]
    fn an_unbound_hotkey_reads_as_an_empty_string() {
        let field = Field::hotkey("capture", "截图", Some("Ctrl+Shift+S"));
        let mut config = Config::new();
        assert_eq!(field.value(&config, "hotkey"), "Ctrl+Shift+S");
        config.set("hotkey", "capture", "");
        assert_eq!(field.value(&config, "hotkey"), "");

        // 出厂就不绑定的，空配置下也是空串
        let unbound = Field::hotkey("other", "别的", None);
        assert_eq!(unbound.value(&Config::new(), "hotkey"), "");
    }

    #[test]
    fn help_text_is_optional_and_attaches_fluently() {
        let field = Field::toggle("x", "开关", true).with_help("说清楚会发生什么");
        assert_eq!(field.help.as_deref(), Some("说清楚会发生什么"));
        assert!(Field::toggle("y", "另一个", true).help.is_none());
    }
}
