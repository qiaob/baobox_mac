//! Baobox Linux 截图 CLI。
//!
//! 当前阶段提供命令行入口（GUI 覆盖层是下一步）。抓屏走 X11，
//! 选区 / 文件名 / 历史 / 拼接等逻辑一律来自 `baobox-core`，
//! 因此行为与 macOS 版一致。
//!
//! ```text
//! baobox-linux capture                   交互式截图（覆盖层：悬停选窗口 / 拖拽选区域）
//! baobox-linux capture --full            截整个屏幕
//! baobox-linux capture --region X,Y,W,H  截一块区域
//! baobox-linux capture --window <id>     截某个窗口
//! baobox-linux scroll --region X,Y,W,H   长截屏（滚动拼接）
//! baobox-linux daemon [--hotkey 组合]    常驻，按快捷键唤起截图（默认 Ctrl+Shift+S）
//! baobox-linux windows                   列出可截的窗口
//! baobox-linux info                      打印环境诊断
//! ```

mod daemon;
mod overlay;
mod x11capture;

use baobox_core::filename::{format_template, sanitize, unique, DateParts, Platform};
use baobox_core::geometry::Rect;
use baobox_core::hotkey::KeyCombo;
use baobox_core::selection::Outcome;
use baobox_core::stitch::{compose_rgba, Frame, Stitcher};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use x11capture::X11Session;

/// 默认文件名模板。占位符集合见 `baobox_core::filename::format_template`。
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
        Some("scroll") => scroll(&args[1..]),
        Some("daemon") => run_daemon(&args[1..]),
        Some("windows") => list_windows(),
        Some("info") => Ok(info()),
        Some("--help") | Some("-h") | None => Ok(usage()),
        Some(other) => Err(format!("未知命令 {other}\n\n{}", usage())),
    }
}

fn usage() -> String {
    concat!(
        "Baobox Linux —— 截图\n\n",
        "用法：\n",
        "  baobox-linux capture [-o 输出.png]              交互式（悬停选窗口 · 拖拽选区域 · ⏎ 全屏 · esc 取消）\n",
        "  baobox-linux capture --full [-o 输出.png]\n",
        "  baobox-linux capture --region X,Y,W,H [-o 输出.png]\n",
        "  baobox-linux capture --window <id> [-o 输出.png]\n",
        "  baobox-linux scroll --region X,Y,W,H [--frames N] [--interval MS] [-o 输出.png]\n",
        "  baobox-linux daemon [--hotkey Ctrl+Shift+S]\n",
        "  baobox-linux windows\n",
        "  baobox-linux info\n\n",
        "不指定 -o 时按模板存到 ~/Pictures/Baobox/。"
    )
    .to_string()
}

fn info() -> String {
    let mut lines = vec![format!(
        "会话类型：{}",
        std::env::var("XDG_SESSION_TYPE").unwrap_or_else(|_| "未知".into())
    )];
    lines.push(format!(
        "DISPLAY：{}",
        std::env::var("DISPLAY").unwrap_or_else(|_| "未设置".into())
    ));
    if x11capture::is_wayland_session() {
        lines.push(
            "⚠️ 检测到 Wayland 会话。X11 抓屏只能拿到 XWayland 的内容，\
             原生 Wayland 窗口会是黑的 —— 需要走 xdg-desktop-portal，尚未实现。"
                .to_string(),
        );
    }
    match X11Session::open() {
        Ok(session) => {
            let r = session.screen_rect();
            lines.push(format!("屏幕：{}×{}", r.w as i64, r.h as i64));
            match session.windows() {
                Ok(windows) => lines.push(format!("可见窗口：{} 个", windows.len())),
                Err(e) => lines.push(format!("窗口枚举失败：{e}")),
            }
        }
        Err(e) => lines.push(format!("X11 连接失败：{e}")),
    }
    lines.join("\n")
}

fn list_windows() -> Result<String, String> {
    let session = X11Session::open()?;
    let windows = session.windows()?;
    if windows.is_empty() {
        return Ok("没有可见窗口。".to_string());
    }
    let mut lines = Vec::with_capacity(windows.len());
    for w in windows {
        lines.push(format!(
            "0x{:08x}  {:>5}×{:<5} @ ({},{})  {}",
            w.id,
            w.frame.w as i64,
            w.frame.h as i64,
            w.frame.x as i64,
            w.frame.y as i64,
            w.title
        ));
    }
    Ok(lines.join("\n"))
}

fn capture(args: &[String]) -> Result<String, String> {
    let mut region: Option<Rect> = None;
    let mut window: Option<u32> = None;
    let mut full = false;
    let mut output: Option<PathBuf> = None;

    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--full" => full = true,
            "--region" => {
                index += 1;
                let value = args.get(index).ok_or("--region 缺少参数 X,Y,W,H")?;
                region = Some(parse_region(value)?);
            }
            "--window" => {
                index += 1;
                let value = args.get(index).ok_or("--window 缺少窗口 id")?;
                window = Some(parse_window_id(value)?);
            }
            "-o" | "--output" => {
                index += 1;
                output = Some(PathBuf::from(args.get(index).ok_or("-o 缺少路径")?));
            }
            other => return Err(format!("未知参数 {other}")),
        }
        index += 1;
    }

    let session = X11Session::open()?;
    if x11capture::is_wayland_session() {
        eprintln!("提示：Wayland 会话下只能抓到 XWayland 内容，原生 Wayland 窗口会是黑的。");
    }

    // --full 直接走 capture_screen；其余先解析出目标区域再抓
    if full {
        let shot = session.capture_screen()?;
        let path = match output {
            Some(path) => path,
            None => default_path()?,
        };
        baobox_image::write_rgba(&path, shot.width, shot.height, &shot.rgba)?;
        return Ok(format!("已保存 {}（{}×{}）", path.display(), shot.width, shot.height));
    }

    let target = match (region, window) {
        (Some(rect), _) => rect,
        (_, Some(id)) => session
            .windows()?
            .into_iter()
            .find(|w| w.id == id)
            .ok_or_else(|| format!("找不到窗口 0x{id:08x}，用 `windows` 命令看可用的"))?
            .frame,
        // 什么都没指定 → 交互式覆盖层，这是默认的用法
        _ => interactive_target(&session)?,
    };

    let shot = session.capture(target)?;
    let path = match output {
        Some(path) => path,
        None => default_path()?,
    };
    baobox_image::write_rgba(&path, shot.width, shot.height, &shot.rgba)?;
    Ok(format!(
        "已保存 {}（{}×{}）",
        path.display(),
        shot.width,
        shot.height
    ))
}


/// 长截屏：定时抓同一块区域，按重叠自动对齐拼成长图。
///
/// 与 macOS 版同一套算法（`baobox_core::stitch`），所以两个平台拼出来的结果一致。
/// 命令跑起来之后**你自己滚动页面**，抓够 `--frames` 帧就结束。
fn scroll(args: &[String]) -> Result<String, String> {
    let mut region: Option<Rect> = None;
    let mut frames = 20usize;
    let mut interval_ms = 400u64;
    let mut output: Option<PathBuf> = None;

    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--region" => {
                index += 1;
                region = Some(parse_region(args.get(index).ok_or("--region 缺少参数")?)?);
            }
            "--frames" => {
                index += 1;
                frames = args
                    .get(index)
                    .ok_or("--frames 缺少参数")?
                    .parse()
                    .map_err(|_| "--frames 需要一个整数".to_string())?;
            }
            "--interval" => {
                index += 1;
                interval_ms = args
                    .get(index)
                    .ok_or("--interval 缺少参数")?
                    .parse()
                    .map_err(|_| "--interval 需要毫秒数".to_string())?;
            }
            "-o" | "--output" => {
                index += 1;
                output = Some(PathBuf::from(args.get(index).ok_or("-o 缺少路径")?));
            }
            other => return Err(format!("未知参数 {other}")),
        }
        index += 1;
    }

    let region = region.ok_or("长截屏需要 --region X,Y,W,H 指定可滚动区域")?;
    if frames < 2 {
        return Err("--frames 至少为 2".to_string());
    }

    let session = X11Session::open()?;
    let mut stitcher = Stitcher::new();
    let mut kept: Vec<Vec<u8>> = Vec::new();
    let mut frame_height = 0usize;

    eprintln!("开始长截屏：现在滚动页面，将抓取 {frames} 帧（间隔 {interval_ms}ms）…");
    for _ in 0..frames {
        let shot = session.capture(region)?;
        frame_height = shot.height as usize;
        let gray = baobox_image::to_gray(&shot.rgba);
        let Some(frame) = Frame::from_gray(shot.width as usize, shot.height as usize, &gray) else {
            continue;
        };
        if stitcher.push(frame) {
            kept.push(shot.rgba);
        }
        std::thread::sleep(std::time::Duration::from_millis(interval_ms));
    }

    if kept.len() < 2 {
        return Err(
            "没有拼接到任何内容。请确认框选的是可滚动区域，并在命令运行期间滚动页面。".to_string(),
        );
    }

    let refs: Vec<&[u8]> = kept.iter().map(|f| f.as_slice()).collect();
    let canvas = compose_rgba(
        &refs,
        frame_height,
        stitcher.placements(),
        stitcher.width(),
        stitcher.total_height(),
    )
    .ok_or("拼接失败：帧尺寸不一致")?;

    let path = match output {
        Some(path) => path,
        None => default_path()?,
    };
    baobox_image::write_rgba(
        &path,
        stitcher.width() as u32,
        stitcher.total_height() as u32,
        &canvas,
    )?;
    Ok(format!(
        "已保存 {}（{}×{}，由 {} 帧拼成）",
        path.display(),
        stitcher.width(),
        stitcher.total_height(),
        kept.len()
    ))
}

/// 默认全局快捷键。带修饰键，避免抢占普通按键。
const DEFAULT_HOTKEY: &str = "Ctrl+Shift+S";

/// 常驻：注册全局快捷键，按下即唤起覆盖层截图。
///
/// 前台运行（`Ctrl+C` 退出）—— 交给用户自己的 systemd user unit / 桌面自启项去托管，
/// 比自己 fork 成后台进程更符合 Linux 的习惯，也更好排查。
fn run_daemon(args: &[String]) -> Result<String, String> {
    let mut hotkey_text = DEFAULT_HOTKEY.to_string();
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--hotkey" => {
                index += 1;
                hotkey_text = args.get(index).ok_or("--hotkey 缺少参数")?.clone();
            }
            other => return Err(format!("未知参数 {other}")),
        }
        index += 1;
    }

    let combo = KeyCombo::parse(&hotkey_text)?;
    if !combo.is_safe_global() {
        return Err(format!(
            "{combo} 没有修饰键，注册成全局快捷键会把这个键从所有 App 手里抢走。请加上 Ctrl / Alt / Super。"
        ));
    }

    let session = X11Session::open()?;
    let root = session.screen().root;
    daemon::grab(session.connection(), root, &combo)?;

    println!("Baobox 已常驻：按 {combo} 截图，Ctrl+C 退出。");
    if x11capture::is_wayland_session() {
        eprintln!("提示：Wayland 会话下全局快捷键与抓屏都只对 XWayland 有效。");
    }

    loop {
        if !daemon::wait_for_trigger(session.connection()) {
            daemon::ungrab(session.connection(), root, &combo);
            return Err("与 X 服务器的连接已断开".to_string());
        }
        match capture_interactively(&session) {
            Ok(message) => println!("{message}"),
            // 单次失败（含用户取消）不该让常驻进程退出
            Err(message) => eprintln!("{message}"),
        }
    }
}

/// 走一次「覆盖层选择 → 抓屏 → 落盘」。
fn capture_interactively(session: &X11Session) -> Result<String, String> {
    let target = interactive_target(session)?;
    let shot = session.capture(target)?;
    let path = default_path()?;
    baobox_image::write_rgba(&path, shot.width, shot.height, &shot.rgba)?;
    Ok(format!(
        "已保存 {}（{}×{}）",
        path.display(),
        shot.width,
        shot.height
    ))
}

/// 铺覆盖层让用户选，返回要抓的矩形。
///
/// 覆盖层在返回前已经销毁并 sync 过，所以接下来的抓屏不会把它自己截进去。
fn interactive_target(session: &X11Session) -> Result<Rect, String> {
    let window_rects: Vec<Rect> = session.windows()?.into_iter().map(|w| w.frame).collect();
    let result = overlay::run(
        session.connection(),
        session.screen(),
        session.screen_rect(),
        window_rects,
    )?;
    match result.outcome {
        Outcome::Region(rect) => Ok(rect),
        Outcome::Window(index) => result
            .windows
            .get(index)
            .copied()
            .ok_or_else(|| "选中的窗口已消失".to_string()),
        Outcome::FullScreen => Ok(session.screen_rect()),
        Outcome::Cancelled => Err("已取消".to_string()),
    }
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

fn parse_window_id(value: &str) -> Result<u32, String> {
    let trimmed = value.trim();
    let parsed = if let Some(hex) = trimmed.strip_prefix("0x").or(trimmed.strip_prefix("0X")) {
        u32::from_str_radix(hex, 16)
    } else {
        trimmed.parse::<u32>()
    };
    parsed.map_err(|_| format!("窗口 id 无法解析：{value}"))
}

/// 默认保存位置：`~/Pictures/Baobox/<模板>.png`，重名自动加序号。
fn default_path() -> Result<PathBuf, String> {
    let home = std::env::var("HOME").map_err(|_| "$HOME 未设置".to_string())?;
    let dir = Path::new(&home).join("Pictures").join("Baobox");
    let stem = format_template(DEFAULT_TEMPLATE, now_parts());
    let safe = sanitize(&stem, Platform::Linux, "screenshot");
    let name = unique(&format!("{safe}.png"), &|candidate: &str| {
        dir.join(candidate).exists()
    });
    Ok(dir.join(name))
}

/// 当前本地时间。
///
/// 不引 chrono：这里只需要「把 Unix 秒拆成年月日时分秒」，而多一个依赖
/// 就多一份供应链与体积。时区取 `TZ` 之外的系统偏移暂不处理，用 UTC，
/// 并在文档里写明 —— 含糊的本地时间比明确的 UTC 更糟。
fn now_parts() -> DateParts {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    civil_from_unix(secs)
}

/// Unix 秒 → 年月日时分秒（UTC）。用 Howard Hinnant 的 civil_from_days 算法。
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
    fn region_parsing_accepts_valid_and_rejects_garbage() {
        assert_eq!(
            parse_region("10,20,30,40").unwrap(),
            Rect::new(10.0, 20.0, 30.0, 40.0)
        );
        assert_eq!(
            parse_region(" 10 , 20 , 30 , 40 ").unwrap(),
            Rect::new(10.0, 20.0, 30.0, 40.0)
        );
        assert!(parse_region("10,20,30").is_err());
        assert!(parse_region("10,20,0,40").is_err(), "零宽应被拒绝");
        assert!(parse_region("a,b,c,d").is_err());
    }

    #[test]
    fn window_id_accepts_hex_and_decimal() {
        assert_eq!(parse_window_id("0x1a2b3c").unwrap(), 0x1a2b3c);
        assert_eq!(parse_window_id("12345").unwrap(), 12345);
        assert!(parse_window_id("zzz").is_err());
    }

    #[test]
    fn unix_to_civil_matches_known_dates() {
        // 1970-01-01 00:00:00
        let epoch = civil_from_unix(0);
        assert_eq!((epoch.year, epoch.month, epoch.day), (1970, 1, 1));
        // 2026-08-03 12:34:56 UTC = 1785760496
        let d = civil_from_unix(1_785_760_496);
        assert_eq!((d.year, d.month, d.day), (2026, 8, 3));
        assert_eq!((d.hour, d.minute, d.second), (12, 34, 56));
        // 闰日
        let leap = civil_from_unix(1_709_164_800); // 2024-02-29 00:00:00
        assert_eq!((leap.year, leap.month, leap.day), (2024, 2, 29));
    }

    #[test]
    fn unknown_command_reports_usage() {
        let err = run(&["nope".to_string()]).unwrap_err();
        assert!(err.contains("未知命令"));
        assert!(err.contains("用法"));
    }

    #[test]
    fn help_is_available_without_a_display() {
        assert!(run(&["--help".to_string()]).unwrap().contains("用法"));
    }
}
