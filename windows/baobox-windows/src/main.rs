//! Baobox Windows 截图 CLI。
//!
//! 命令与 Linux 版**完全一致** —— 两边的选区、文件名、拼接逻辑都来自
//! `baobox-core`，差别只在抓屏那一层（这边是 GDI，那边是 X11）。
//!
//! ```text
//! baobox-windows capture                 交互式截图（覆盖层）
//! baobox-windows capture --full
//! baobox-windows capture --region X,Y,W,H
//! baobox-windows capture --window <hwnd>
//! baobox-windows windows
//! baobox-windows info
//! ```

mod gdi;
#[cfg(windows)]
mod overlay;

use baobox_core::filename::{format_template, sanitize, unique, DateParts, Platform};
use baobox_core::geometry::Rect;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// 默认文件名模板。与 Linux 版一致；Windows 的非法字符与保留名由
/// `sanitize(.., Platform::Windows, ..)` 负责挡掉。
const DEFAULT_TEMPLATE: &str = "Screenshot {yyyy}-{MM}-{dd} {HH}.{mm}.{ss}";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match run(&args) {
        Ok(message) => {
            if !message.is_empty() {
                println!("{message}");
            }
            0
        }
        Err(message) => {
            eprintln!("错误：{message}");
            1
        }
    };
    std::process::exit(code);
}

fn run(args: &[String]) -> Result<String, String> {
    match args.first().map(String::as_str) {
        Some("capture") => capture(&args[1..]),
        Some("windows") => list_windows(),
        Some("info") => Ok(info()),
        Some("--help") | Some("-h") | None => Ok(usage()),
        Some(other) => Err(format!("未知命令 {other}\n\n{}", usage())),
    }
}

fn usage() -> String {
    concat!(
        "Baobox Windows —— 截图\n\n",
        "用法：\n",
        "  baobox-windows capture [-o 输出.png]            交互式（悬停选窗口 · 拖拽选区域 · ⏎ 全屏 · esc 取消）\n",
        "  baobox-windows capture --full [-o 输出.png]\n",
        "  baobox-windows capture --region X,Y,W,H [-o 输出.png]\n",
        "  baobox-windows capture --window <hwnd> [-o 输出.png]\n",
        "  baobox-windows windows\n",
        "  baobox-windows info\n\n",
        "不指定 -o 时按模板存到 %USERPROFILE%\\Pictures\\Baobox\\。"
    )
    .to_string()
}

#[cfg(windows)]
fn info() -> String {
    let dpi_ok = gdi::prepare();
    let screen = gdi::virtual_screen();
    format!(
        "DPI 感知：{}\n虚拟屏幕：{}×{} @ ({},{})\n可见窗口：{} 个",
        if dpi_ok { "Per-Monitor V2" } else { "设置失败（可能已由清单指定）" },
        screen.w as i64,
        screen.h as i64,
        screen.x as i64,
        screen.y as i64,
        gdi::windows().len()
    )
}

#[cfg(not(windows))]
fn info() -> String {
    "本程序只能在 Windows 上运行。".to_string()
}

#[cfg(windows)]
fn list_windows() -> Result<String, String> {
    gdi::prepare();
    let found = gdi::windows();
    if found.is_empty() {
        return Ok("没有可见窗口。".to_string());
    }
    Ok(found
        .iter()
        .map(|w| {
            format!(
                "0x{:08x}  {:>5}×{:<5} @ ({},{})  {}",
                w.id, w.frame.w as i64, w.frame.h as i64, w.frame.x as i64, w.frame.y as i64, w.title
            )
        })
        .collect::<Vec<_>>()
        .join("\n"))
}

#[cfg(not(windows))]
fn list_windows() -> Result<String, String> {
    Err("本程序只能在 Windows 上运行。".to_string())
}

#[cfg(windows)]
fn capture(args: &[String]) -> Result<String, String> {
    let options = parse_capture_args(args)?;
    gdi::prepare();

    let target = match (options.full, options.region, options.window) {
        (true, _, _) => gdi::virtual_screen(),
        (_, Some(rect), _) => rect,
        (_, _, Some(id)) => gdi::windows()
            .into_iter()
            .find(|w| w.id == id)
            .ok_or_else(|| format!("找不到窗口 0x{id:08x}，用 `windows` 命令看可用的"))?
            .frame,
        // 什么都没指定 → 交互式覆盖层，这是默认用法
        _ => interactive_target()?,
    };

    let shot = gdi::capture(target)?;
    let path = match options.output {
        Some(path) => path,
        None => default_path()?,
    };
    baobox_image::write_rgba(&path, shot.width, shot.height, &shot.rgba)?;
    Ok(format!("已保存 {}（{}×{}）", path.display(), shot.width, shot.height))
}

#[cfg(not(windows))]
fn capture(args: &[String]) -> Result<String, String> {
    // 非 Windows 上仍解析参数，便于在其他平台上跑参数解析的测试
    let _ = parse_capture_args(args)?;
    Err("本程序只能在 Windows 上运行。".to_string())
}

/// 铺覆盖层让用户选，返回要抓的矩形。
///
/// 覆盖层返回前已销毁自身，所以接下来的抓屏不会把它自己截进去。
#[cfg(windows)]
fn interactive_target() -> Result<Rect, String> {
    let screen = gdi::virtual_screen();
    let window_rects: Vec<Rect> = gdi::windows().into_iter().map(|w| w.frame).collect();
    let result = overlay::run(screen, window_rects)?;
    match result.outcome {
        baobox_core::selection::Outcome::Region(rect) => Ok(rect),
        baobox_core::selection::Outcome::Window(index) => result
            .windows
            .get(index)
            .copied()
            .ok_or_else(|| "选中的窗口已消失".to_string()),
        baobox_core::selection::Outcome::FullScreen => Ok(screen),
        baobox_core::selection::Outcome::Cancelled => Err("已取消".to_string()),
    }
}

/// `capture` 的命令行参数。
struct CaptureOptions {
    full: bool,
    region: Option<Rect>,
    window: Option<isize>,
    output: Option<PathBuf>,
}

fn parse_capture_args(args: &[String]) -> Result<CaptureOptions, String> {
    let mut options = CaptureOptions {
        full: false,
        region: None,
        window: None,
        output: None,
    };
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--full" => options.full = true,
            "--region" => {
                index += 1;
                options.region = Some(parse_region(args.get(index).ok_or("--region 缺少参数 X,Y,W,H")?)?);
            }
            "--window" => {
                index += 1;
                options.window = Some(parse_window_id(args.get(index).ok_or("--window 缺少句柄")?)?);
            }
            "-o" | "--output" => {
                index += 1;
                options.output = Some(PathBuf::from(args.get(index).ok_or("-o 缺少路径")?));
            }
            other => return Err(format!("未知参数 {other}")),
        }
        index += 1;
    }
    Ok(options)
}

fn parse_region(value: &str) -> Result<Rect, String> {
    let parts: Vec<&str> = value.split(',').map(str::trim).collect();
    if parts.len() != 4 {
        return Err(format!("区域格式应为 X,Y,W,H，收到 {value}"));
    }
    let mut numbers = [0f64; 4];
    for (index, part) in parts.iter().enumerate() {
        numbers[index] = part
            .parse::<f64>()
            .map_err(|_| format!("区域里的 {part} 不是数字"))?;
    }
    if numbers[2] <= 0.0 || numbers[3] <= 0.0 {
        return Err("区域的宽高必须为正".to_string());
    }
    Ok(Rect::new(numbers[0], numbers[1], numbers[2], numbers[3]))
}

fn parse_window_id(value: &str) -> Result<isize, String> {
    let trimmed = value.trim();
    let parsed = if let Some(hex) = trimmed.strip_prefix("0x").or(trimmed.strip_prefix("0X")) {
        isize::from_str_radix(hex, 16)
    } else {
        trimmed.parse::<isize>()
    };
    parsed.map_err(|_| format!("窗口句柄无法解析：{value}"))
}

/// 默认保存位置：`%USERPROFILE%\Pictures\Baobox\<模板>.png`。
fn default_path() -> Result<PathBuf, String> {
    let home = std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .map_err(|_| "%USERPROFILE% 未设置".to_string())?;
    let dir = Path::new(&home).join("Pictures").join("Baobox");
    let stem = format_template(DEFAULT_TEMPLATE, now_parts());
    // 走 Windows 规则：非法字符更多，另有 CON/PRN/NUL 等保留名
    let safe = sanitize(&stem, Platform::Windows, "screenshot");
    let name = unique(&format!("{safe}.png"), &|candidate: &str| {
        dir.join(candidate).exists()
    });
    Ok(dir.join(name))
}

fn now_parts() -> DateParts {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    civil_from_unix(secs)
}

/// Unix 秒 → 年月日时分秒（UTC）。与 Linux 版同一实现，保证两边文件名一致。
fn civil_from_unix(secs: i64) -> DateParts {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
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
    DateParts {
        year: year as u32,
        month: m as u32,
        day: d as u32,
        hour: (rem / 3600) as u32,
        minute: ((rem % 3600) / 60) as u32,
        second: (rem % 60) as u32,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn region_parsing_matches_the_linux_build() {
        assert_eq!(parse_region("10,20,30,40").unwrap(), Rect::new(10.0, 20.0, 30.0, 40.0));
        assert!(parse_region("10,20,30").is_err());
        assert!(parse_region("10,20,0,40").is_err());
    }

    #[test]
    fn window_handles_accept_hex_and_decimal() {
        assert_eq!(parse_window_id("0x1a2b").unwrap(), 0x1a2b);
        assert_eq!(parse_window_id("4242").unwrap(), 4242);
        assert!(parse_window_id("nope").is_err());
    }

    #[test]
    fn unix_to_civil_matches_the_linux_build() {
        let d = civil_from_unix(1_785_760_496);
        assert_eq!((d.year, d.month, d.day), (2026, 8, 3));
        assert_eq!((d.hour, d.minute, d.second), (12, 34, 56));
    }

    #[test]
    fn default_name_avoids_windows_reserved_words() {
        // 模板若被改成 CON 之类，必须被躲开
        let safe = sanitize("CON", Platform::Windows, "screenshot");
        assert_eq!(safe, "_CON");
    }
}
