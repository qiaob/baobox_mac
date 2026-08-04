//! 文件名：模板格式化、按平台消毒、重名去重。
//!
//! 三平台的非法字符集与保留名**并不一样**，这是移植时最容易被忽略的坑之一：
//! macOS 上完全合法的 `CON.png` 在 Windows 上根本写不出来。
//! 所以消毒规则按目标平台分开，而不是取一个「最严的交集」——
//! 那样 Linux/macOS 用户会莫名其妙地看到文件名被改。

/// 目标平台的文件名规则。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    /// macOS：只有 `/` 非法；`:` 在访达里会显示成 `/`，一并替换
    MacOS,
    /// Linux：只有 `/` 与 NUL 非法
    Linux,
    /// Windows：非法字符最多，另有一批保留设备名
    Windows,
}

/// Windows 保留设备名（不区分大小写，**带扩展名也一样不行**：`CON.txt` 同样非法）。
const WINDOWS_RESERVED: &[&str] = &[
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
    "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
];

/// 文件名保留的最大 UTF-8 字节数（各平台单个组件上限 255，留出去重后缀余量）。
pub const MAX_NAME_BYTES: usize = 200;

/// 把外来文件名消毒成目标平台上安全的**单个路径组件**。
///
/// 步骤：去分隔符与非法字符 → 去控制字符 → 去首尾空白与前导点 →
/// （Windows）躲开保留名、去尾部点与空格 → 截断 → 兜底名。
///
/// 去掉分隔符之后不可能再出现 `..` 作为路径成分；单独的 `..` 会在去前导点时被削成空串，
/// 落到兜底名，因此目录穿越在此彻底关死。
pub fn sanitize(raw: &str, platform: Platform, fallback: &str) -> String {
    let illegal: &[char] = match platform {
        Platform::MacOS => &['/', '\\', ':'],
        Platform::Linux => &['/', '\\'],
        Platform::Windows => &['/', '\\', ':', '<', '>', '"', '|', '?', '*'],
    };

    let mut name: String = raw
        .chars()
        .filter(|c| !illegal.contains(c) && !c.is_control())
        .collect();

    name = name.trim().to_string();
    while name.starts_with('.') {
        name.remove(0);
    }
    name = name.trim().to_string();

    if platform == Platform::Windows {
        // 尾部的点和空格会被系统悄悄吃掉，导致「写出来的名字和以为的不一样」
        name = name.trim_end_matches([' ', '.']).to_string();
        if is_windows_reserved(&name) {
            name = format!("_{name}");
        }
    }

    name = truncate_utf8(&name, MAX_NAME_BYTES);
    if name.is_empty() {
        fallback.to_string()
    } else {
        name
    }
}

/// 是否命中 Windows 保留设备名（比较的是第一个点之前的部分）。
pub fn is_windows_reserved(name: &str) -> bool {
    let stem = name.split('.').next().unwrap_or("");
    WINDOWS_RESERVED
        .iter()
        .any(|reserved| stem.eq_ignore_ascii_case(reserved))
}

/// 按 UTF-8 字节数截断，尽量保留扩展名，且不从字符中间切断。
fn truncate_utf8(name: &str, limit: usize) -> String {
    if name.len() <= limit {
        return name.to_string();
    }
    let (stem, ext) = split_extension(name);
    let suffix: String = if ext.is_empty() {
        String::new()
    } else {
        format!(".{}", ext.chars().take(20).collect::<String>())
    };
    let budget = limit.saturating_sub(suffix.len());
    let mut out = String::new();
    for ch in stem.chars() {
        if out.len() + ch.len_utf8() > budget {
            break;
        }
        out.push(ch);
    }
    out.push_str(&suffix);
    out
}

/// 拆成（主名, 扩展名）。没有扩展名时扩展名为空串。
pub fn split_extension(name: &str) -> (String, String) {
    match name.rfind('.') {
        Some(index) if index > 0 && index < name.len() - 1 => (
            name[..index].to_string(),
            name[index + 1..].to_string(),
        ),
        _ => (name.to_string(), String::new()),
    }
}

/// 在已有名字集合里取一个不重名的名字：已存在则追加 `-2`、`-3`…
///
/// 与 macOS 侧 `ScreenshotResultHandler.uniqueURL` 同一规则，
/// 这样同一个人在两台机器上看到的命名习惯是一致的。
pub fn unique(name: &str, exists: &dyn Fn(&str) -> bool) -> String {
    if !exists(name) {
        return name.to_string();
    }
    let (stem, ext) = split_extension(name);
    let suffix = if ext.is_empty() {
        String::new()
    } else {
        format!(".{ext}")
    };
    for n in 2..1000 {
        let candidate = format!("{stem}-{n}{suffix}");
        if !exists(&candidate) {
            return candidate;
        }
    }
    format!("{stem}-{}{suffix}", uniquish_tail())
}

/// 兜底后缀：不引入随机数依赖，用一个足够长的固定串加计数没有意义，
/// 这里直接返回一个明显可辨认的标记，交由调用方处理（1000 个同名文件本身就是异常）。
fn uniquish_tail() -> &'static str {
    "overflow"
}

/// 截图文件名模板里支持的占位符。
///
/// 只实现一个**明确的小集合**，而不是照搬 macOS 的 `DateFormatter` ——
/// 跨平台一致比功能齐全重要，而且 DateFormatter 的隐式格式符正是
/// macOS 侧踩过的坑（`Screenshot` 里的字母会被当成格式符）。
///
/// | 占位符 | 含义 |
/// |---|---|
/// | `{yyyy}` | 四位年 |
/// | `{MM}` | 两位月 |
/// | `{dd}` | 两位日 |
/// | `{HH}` | 两位时（24 小时制） |
/// | `{mm}` | 两位分 |
/// | `{ss}` | 两位秒 |
///
/// 花括号之外的文字**原样保留**，所以 `Screenshot {yyyy}-{MM}-{dd}` 就是字面意思。
#[derive(Debug, Clone, Copy)]
pub struct DateParts {
    /// 年
    pub year: u32,
    /// 月 1-12
    pub month: u32,
    /// 日 1-31
    pub day: u32,
    /// 时 0-23
    pub hour: u32,
    /// 分 0-59
    pub minute: u32,
    /// 秒 0-59
    pub second: u32,
}
impl DateParts {
    /// Unix 秒 → 年月日时分秒（UTC）。
    ///
    /// 用的是 Howard Hinnant 那套 civil_from_days 算法：纯整数运算，
    /// 没有查表也没有闰年特判，负数（1970 以前）一样成立。
    ///
    /// 放在这里而不是各平台的 `main.rs` 里 —— 之前两个平台各抄了一份，
    /// 而「同一时刻在两个系统上算出不同的文件名」是这个仓库最不该出的错。
    pub fn from_unix(seconds: i64) -> DateParts {
        let days = seconds.div_euclid(86_400);
        let rem = seconds.rem_euclid(86_400);
        // 把纪元挪到 0000-03-01，闰年规则在这个起点上是周期的
        let z = days + 719_468;
        let era = z.div_euclid(146_097);
        let doe = z.rem_euclid(146_097);
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        let y = yoe + era * 400;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = doy - (153 * mp + 2) / 5 + 1;
        let m = if mp < 10 { mp + 3 } else { mp - 9 };
        DateParts {
            year: (if m <= 2 { y + 1 } else { y }) as u32,
            month: m as u32,
            day: d as u32,
            hour: (rem / 3600) as u32,
            minute: ((rem % 3600) / 60) as u32,
            second: (rem % 60) as u32,
        }
    }
}


/// 按模板生成文件名主体（不含扩展名）。
pub fn format_template(template: &str, date: DateParts) -> String {
    let mut out = String::with_capacity(template.len() + 8);
    let mut rest = template;
    while let Some(start) = rest.find('{') {
        out.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        match after.find('}') {
            Some(end) => {
                let token = &after[..end];
                match token {
                    "yyyy" => out.push_str(&format!("{:04}", date.year)),
                    "MM" => out.push_str(&format!("{:02}", date.month)),
                    "dd" => out.push_str(&format!("{:02}", date.day)),
                    "HH" => out.push_str(&format!("{:02}", date.hour)),
                    "mm" => out.push_str(&format!("{:02}", date.minute)),
                    "ss" => out.push_str(&format!("{:02}", date.second)),
                    // 未知占位符原样保留，便于用户看出自己拼错了
                    other => {
                        out.push('{');
                        out.push_str(other);
                        out.push('}');
                    }
                }
                rest = &after[end + 1..];
            }
            None => {
                // 没有闭合花括号，剩下的全当字面量
                out.push('{');
                out.push_str(after);
                rest = "";
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unix_seconds_become_the_right_calendar_date() {
        let d = DateParts::from_unix(1_785_760_496);
        assert_eq!((d.year, d.month, d.day), (2026, 8, 3));
        assert_eq!((d.hour, d.minute, d.second), (12, 34, 56));
        // 纪元本身
        let epoch = DateParts::from_unix(0);
        assert_eq!((epoch.year, epoch.month, epoch.day), (1970, 1, 1));
    }

    #[test]
    fn leap_days_and_century_rules_come_out_right() {
        // 2000 是闰年（能被 400 整除），1900 不是
        let leap = DateParts::from_unix(951_782_400); // 2000-02-29
        assert_eq!((leap.year, leap.month, leap.day), (2000, 2, 29));
        let after = DateParts::from_unix(951_782_400 + 86_400);
        assert_eq!((after.year, after.month, after.day), (2000, 3, 1));
    }

    #[test]
    fn dates_before_the_epoch_do_not_go_haywire() {
        // 系统时钟被调到 1970 以前是会发生的事，不能算出负的月份
        let d = DateParts::from_unix(-86_400);
        assert_eq!((d.year, d.month, d.day), (1969, 12, 31));
    }


    #[test]
    fn path_traversal_is_impossible_on_every_platform() {
        for platform in [Platform::MacOS, Platform::Linux, Platform::Windows] {
            let out = sanitize("../../../../etc/passwd", platform, "file");
            assert!(!out.contains('/'), "{platform:?} 结果里不应有分隔符：{out}");
            assert!(!out.contains(".."), "{platform:?} 结果里不应有 ..：{out}");
            assert_eq!(out, "etcpasswd");
        }
        // 纯 ".." 会被削空 → 落到兜底名
        assert_eq!(sanitize("..", Platform::Linux, "file"), "file");
    }

    #[test]
    fn windows_illegal_characters_are_stripped_only_on_windows() {
        let raw = "report<1>:\"x\"|y?.png";
        let win = sanitize(raw, Platform::Windows, "file");
        assert_eq!(win, "report1xy.png");
        // Linux 上这些字符是合法的，不该被动
        let linux = sanitize(raw, Platform::Linux, "file");
        assert!(linux.contains('<') && linux.contains('?'));
    }

    #[test]
    fn windows_reserved_device_names_are_escaped() {
        assert!(is_windows_reserved("CON"));
        assert!(is_windows_reserved("con.txt"), "带扩展名也仍是保留名");
        assert!(is_windows_reserved("COM1.png"));
        assert!(!is_windows_reserved("CONSOLE.txt"));

        assert_eq!(sanitize("CON.png", Platform::Windows, "file"), "_CON.png");
        // 其他平台不需要躲
        assert_eq!(sanitize("CON.png", Platform::Linux, "file"), "CON.png");
    }

    #[test]
    fn windows_strips_trailing_dots_and_spaces() {
        assert_eq!(sanitize("report. . ", Platform::Windows, "file"), "report");
        // macOS / Linux 上尾部空格是合法的，仅 trim 首尾空白
        assert_eq!(sanitize("report .", Platform::Linux, "file"), "report .");
    }

    #[test]
    fn truncation_keeps_the_extension_and_valid_utf8() {
        let long = "中".repeat(300); // 每个 3 字节
        let out = sanitize(&format!("{long}.png"), Platform::Linux, "file");
        assert!(out.len() <= MAX_NAME_BYTES);
        assert!(out.ends_with(".png"));
        // 没有从字符中间截断（能正常解析成字符）
        assert!(out.chars().all(|c| c == '中' || ".png".contains(c)));
    }

    #[test]
    fn unique_appends_incrementing_suffixes() {
        let taken = ["a.png".to_string(), "a-2.png".to_string()];
        let exists = |name: &str| taken.iter().any(|t| t == name);
        assert_eq!(unique("b.png", &exists), "b.png");
        assert_eq!(unique("a.png", &exists), "a-3.png");
    }

    #[test]
    fn unique_handles_names_without_extension() {
        let taken = ["notes".to_string()];
        let exists = |name: &str| taken.iter().any(|t| t == name);
        assert_eq!(unique("notes", &exists), "notes-2");
    }

    #[test]
    fn template_placeholders_expand_and_literals_survive() {
        let date = DateParts {
            year: 2026,
            month: 8,
            day: 3,
            hour: 14,
            minute: 5,
            second: 9,
        };
        assert_eq!(
            format_template("Screenshot {yyyy}-{MM}-{dd} {HH}.{mm}.{ss}", date),
            "Screenshot 2026-08-03 14.05.09"
        );
        // 这正是 macOS DateFormatter 会出乱码的场景：字面量必须原样保留
        assert_eq!(format_template("Screenshot", date), "Screenshot");
        // 拼错的占位符原样留着，让用户看得见
        assert_eq!(format_template("{yyy}", date), "{yyy}");
        assert_eq!(format_template("{unclosed", date), "{unclosed");
    }
}
