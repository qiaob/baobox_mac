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

mod app;
mod assistant;
mod assistant_module;
mod terminal;
mod caffeinate;
mod caffeinate_module;
mod windowmanager;
mod windowmanager_module;
mod clipboard;
mod clipboard_module;
mod clipboard_panel;
mod clipboard_read;
mod clipboard_store;
mod paste;
mod editor;
mod hotkeys;
mod ocr;
mod overlay;
mod pin;
mod record;
mod screenshot_module;
mod settings_window;
mod store;
mod text;
mod text_input;
mod tray;
mod x11capture;

use baobox_core::filename::{format_template, sanitize, unique, DateParts, Platform};
use baobox_core::geometry::Rect;
use baobox_core::editor::EditorOutcome;
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
        Some("app") | None => app::run(),
        Some("capture") => capture(&args[1..]),
        Some("ocr") => run_ocr(&args[1..]),
        Some("record") => run_record(&args[1..]),
        Some("history") => history(&args[1..]),
        Some("scroll") => scroll(&args[1..]),
        Some("daemon") => app::run(),
        Some("windows") => list_windows(),
        Some("info") => Ok(info()),
        Some("--help") | Some("-h") => Ok(usage()),
        Some(other) => Err(format!("未知命令 {other}\n\n{}", usage())),
    }
}

fn usage() -> String {
    concat!(
        "Baobox Linux —— 截图\n\n",
        "用法：\n",
        "  baobox-linux                                   常驻运行：托盘图标 + 全局快捷键 + 设置窗口\n",
        "  baobox-linux capture [-o 输出.png]              交互式（悬停选窗口 · 拖拽选区域 · ⏎ 全屏 · esc 取消）\n",
        "      截完自动进标注编辑器：画框 / 箭头 / 打码 / 写字，再按工具条上的按钮决定去向\n",
        "      --no-edit 跳过编辑，截完直接出图\n",
        "  baobox-linux capture --full [-o 输出.png]\n",
        "  baobox-linux capture --region X,Y,W,H [-o 输出.png]\n",
        "  baobox-linux capture --window <id> [-o 输出.png]\n",
        "      默认复制到剪贴板并保存；--no-copy / --no-save 可分别关掉\n",
        "  baobox-linux ocr [--region X,Y,W,H] [--lang chi_sim+eng]      屏幕取字（需要 tesseract）\n",
        "  baobox-linux record [--region X,Y,W,H] [--fps 15] [-o 输出.mp4]  录屏（需要 ffmpeg，⏎ 停止）\n",
        "  baobox-linux history [--clear]                                 最近的截图\n",
        "  baobox-linux scroll --region X,Y,W,H [--frames N] [--interval MS] [-o 输出.png]\n",
        "  baobox-linux daemon                            与不带参数一样（老名字，保留兼容）\n",
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
    // 与 macOS 版默认一致：复制到剪贴板 + 同时落盘
    let mut copy = true;
    let mut save = true;
    let mut edit = true;

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
            "--no-copy" => copy = false,
            "--no-save" => save = false,
            "--no-edit" => edit = false,
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
        let at = session.screen_rect();
        return finish(&session, at, shot, output, copy, save, edit);
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
    finish(&session, target, shot, output, copy, save, edit)
}

/// 截完图之后的去向：先（可选地）进标注编辑器，再按结果收尾。
///
/// **开着编辑器时，出口由用户按的那个按钮决定**，`--no-copy` / `--no-save` 不再生效 ——
/// 都已经点了「保存」还要被命令行参数否掉，那才叫莫名其妙。`-o` 仍然管用，
/// 它指定的是「保存到哪」而不是「要不要保存」。
fn finish(
    session: &X11Session,
    at: Rect,
    shot: x11capture::Capture,
    output: Option<PathBuf>,
    copy: bool,
    save: bool,
    edit: bool,
) -> Result<String, String> {
    if !edit {
        return deliver(session, &shot, output, copy, save);
    }

    let result = editor::run(
        session.connection(),
        session.screen(),
        session.screen_rect(),
        at,
        shot.rgba,
    )?;
    let edited = x11capture::Capture {
        width: result.width,
        height: result.height,
        rgba: result.rgba,
    };
    match result.outcome {
        EditorOutcome::Cancel => Err("已取消".to_string()),
        EditorOutcome::Copy => deliver(session, &edited, output, true, false),
        EditorOutcome::Save => deliver(session, &edited, output, false, true),
        EditorOutcome::Pin => {
            // 贴图会一直占着这个进程，所以先把图落盘再钉上去 ——
            // 否则用户关掉贴图窗口时图就没了
            let note = deliver(session, &edited, output, false, true)?;
            println!("{note}，已钉在屏幕上（拖动可挪位置，任意键 / 右键关闭）");
            pin::show(
                session.connection(),
                session.screen(),
                at,
                &edited.rgba,
                edited.width,
                edited.height,
            )?;
            Ok(String::new())
        }
    }
}

/// 截图的收尾：按需复制到剪贴板、按需落盘，返回给用户看的一行话。
///
/// 复制放在保存之后 —— X11 的剪贴板要靠本进程持续服务，一进去就阻塞了，
/// 落盘必须先做完。
fn deliver(
    session: &X11Session,
    shot: &x11capture::Capture,
    output: Option<PathBuf>,
    copy: bool,
    save: bool,
) -> Result<String, String> {
    let mut notes: Vec<String> = Vec::new();

    if save || output.is_some() {
        let path = match output {
            Some(path) => path,
            None => default_path("")?,
        };
        baobox_image::write_rgba(&path, shot.width, shot.height, &shot.rgba)?;
        store::remember(&path, shot.width, shot.height, now_seconds(), None);
        notes.push(format!("已保存 {}", path.display()));
    }

    if copy {
        let png = baobox_image::encode_rgba(shot.width, shot.height, &shot.rgba)?;
        let owner = session.create_owner_window()?;
        notes.push(format!(
            "已复制到剪贴板（持有 {} 秒，期间可粘贴）",
            clipboard::DEFAULT_SERVE.as_secs()
        ));
        println!("{}（{}×{}）", notes.join("，"), shot.width, shot.height);
        // X11 剪贴板必须由本进程持续服务，所以这一步会阻塞
        clipboard::serve(
            session.connection(),
            owner,
            &clipboard::Payload::Png(png),
            Some(clipboard::DEFAULT_SERVE),
        )?;
        return Ok(String::new());
    }

    if notes.is_empty() {
        return Err("--no-copy 与 --no-save 同时给了，什么都不会发生".to_string());
    }
    Ok(format!(
        "{}（{}×{}）",
        notes.join("，"),
        shot.width,
        shot.height
    ))
}


/// 屏幕取字：框一块区域，把里面的文字识别出来。
///
/// 结果同时**打印到标准输出**和**放进剪贴板** —— 取字的目的十有八九是拿去粘贴。
fn run_ocr(args: &[String]) -> Result<String, String> {
    let mut region: Option<Rect> = None;
    let mut langs = ocr::DEFAULT_LANGS.to_string();
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--region" => {
                index += 1;
                region = Some(parse_region(args.get(index).ok_or("--region 缺少参数")?)?);
            }
            "--lang" => {
                index += 1;
                langs = args.get(index).ok_or("--lang 缺少参数")?.clone();
            }
            other => return Err(format!("未知参数 {other}")),
        }
        index += 1;
    }

    let session = X11Session::open()?;
    let target = match region {
        Some(rect) => rect,
        None => interactive_target(&session)?,
    };
    let shot = session.capture(target)?;

    // tesseract 只认文件，所以先落一个临时 PNG，用完就删
    let temp = std::env::temp_dir().join(format!("baobox-ocr-{}.png", std::process::id()));
    baobox_image::write_rgba(&temp, shot.width, shot.height, &shot.rgba)?;
    let result = ocr::recognize(&temp, &langs);
    let _ = std::fs::remove_file(&temp);
    let text = result?;

    if text.trim().is_empty() {
        return Err("这块区域里没识别出文字。".to_string());
    }
    println!("{text}");
    let owner = session.create_owner_window()?;
    println!(
        "（已复制到剪贴板，持有 {} 秒）",
        clipboard::DEFAULT_SERVE.as_secs()
    );
    clipboard::serve(
        session.connection(),
        owner,
        &clipboard::Payload::Text(text),
        Some(clipboard::DEFAULT_SERVE),
    )?;
    Ok(String::new())
}

/// 录屏：框一块区域，录到用户按下 ⏎ 为止。
fn run_record(args: &[String]) -> Result<String, String> {
    let mut region: Option<Rect> = None;
    let mut fps = record::DEFAULT_FPS;
    let mut output: Option<PathBuf> = None;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--region" => {
                index += 1;
                region = Some(parse_region(args.get(index).ok_or("--region 缺少参数")?)?);
            }
            "--fps" => {
                index += 1;
                fps = args
                    .get(index)
                    .ok_or("--fps 缺少参数")?
                    .parse()
                    .map_err(|_| "--fps 需要一个整数".to_string())?;
            }
            "-o" | "--output" => {
                index += 1;
                output = Some(PathBuf::from(args.get(index).ok_or("-o 缺少路径")?));
            }
            other => return Err(format!("未知参数 {other}")),
        }
        index += 1;
    }

    let target = match region {
        Some(rect) => rect,
        None => {
            let session = X11Session::open()?;
            interactive_target(&session)?
        }
    };
    let path = match output {
        Some(path) => path,
        None => default_path("")?.with_extension("mp4"),
    };
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("创建目录失败：{e}"))?;
    }

    let recording = record::start(target, fps, &path)?;
    println!("正在录制 {}×{} → {}，按 ⏎ 停止。", target.w as i64, target.h as i64, path.display());
    let mut line = String::new();
    let _ = std::io::stdin().read_line(&mut line);
    recording.stop()?;
    Ok(format!("已保存 {}", path.display()))
}

/// 最近的截图。
fn history(args: &[String]) -> Result<String, String> {
    let mut clear = false;
    for arg in args {
        match arg.as_str() {
            "--clear" => clear = true,
            other => return Err(format!("未知参数 {other}")),
        }
    }
    let mut history = store::load(baobox_core::history::History::DEFAULT_LIMIT);
    if clear {
        let dropped = history.clear();
        // 只删历史目录里的副本；用户自己 -o 指定的文件不动
        if let Some(dir) = store::dir() {
            for entry in &dropped {
                let path = Path::new(&entry.path);
                if path.starts_with(&dir) {
                    let _ = std::fs::remove_file(path);
                }
            }
        }
        store::save(&history)?;
        return Ok(format!("已清空 {} 条历史。", dropped.len()));
    }
    Ok(store::describe(&history))
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
        None => default_path("")?,
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
///
/// `save_dir` 非空时改存到那里 —— 设置里的「保存到」就是靠它生效的。
/// 以 `~` 开头会展开成家目录：用户在输入框里手打路径时几乎一定会那么写。
pub fn default_path(save_dir: &str) -> Result<PathBuf, String> {
    let home = std::env::var("HOME").map_err(|_| "$HOME 未设置".to_string())?;
    let dir = match save_dir.trim() {
        "" => Path::new(&home).join("Pictures").join("Baobox"),
        custom => match custom.strip_prefix("~/") {
            Some(rest) => Path::new(&home).join(rest),
            None => PathBuf::from(custom),
        },
    };
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
    civil_from_unix(now_seconds())
}

/// 当前 Unix 秒。
pub fn now_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Unix 秒 → 年月日时分秒（UTC）。
///
/// 实现在 `baobox_core::filename` —— 两个平台以前各抄了一份，
/// 而「同一时刻在两个系统上算出不同的文件名」是这个仓库最不该出的错。
fn civil_from_unix(secs: i64) -> DateParts {
    DateParts::from_unix(secs)
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
