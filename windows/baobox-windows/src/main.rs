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
//! baobox-windows daemon [--hotkey 组合]   常驻，按快捷键唤起截图（默认 Ctrl+Shift+S）
//! baobox-windows scroll --region X,Y,W,H  长截屏（滚动拼接）
//! baobox-windows windows
//! baobox-windows info
//! ```

// GUI 子系统：常驻运行（托盘）时不再弹出一个黑色控制台窗口。
// 命令行用法靠 main() 里的 AttachConsole 接回父控制台，输出照常可见。
#![cfg_attr(windows, windows_subsystem = "windows")]

mod gdi;
#[cfg(windows)]
mod app;
#[cfg(windows)]
mod clipboard;
#[cfg(windows)]
mod terminal;
#[cfg(windows)]
mod caffeinate;
#[cfg(windows)]
mod caffeinate_module;
#[cfg(windows)]
mod clipboard_module;
mod clipboard_panel;
#[cfg(windows)]
mod clipboard_read;
mod clipboard_store;
#[cfg(windows)]
mod editor;
#[cfg(windows)]
mod hotkeys;
mod ocr;
#[cfg(windows)]
mod overlay;
#[cfg(windows)]
mod paste;
#[cfg(windows)]
mod pin;
#[cfg(windows)]
mod screenshot_module;
#[cfg(windows)]
mod settings_window;
#[cfg(windows)]
mod hint_overlay;
#[cfg(windows)]
mod keyboardnav;
#[cfg(windows)]
mod keyboardnav_module;
#[cfg(windows)]
mod windowmanager;
#[cfg(windows)]
mod windowmanager_module;
#[cfg(windows)]
mod tray;
mod record;
mod store;

use baobox_core::filename::{format_template, sanitize, unique, DateParts, Platform};
use baobox_core::geometry::Rect;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// 默认文件名模板。与 Linux 版一致；Windows 的非法字符与保留名由
/// `sanitize(.., Platform::Windows, ..)` 负责挡掉。
const DEFAULT_TEMPLATE: &str = "Screenshot {yyyy}-{MM}-{dd} {HH}.{mm}.{ss}";

fn main() {
    // 必须在第一次 print 之前调用，否则 Rust 会缓存住无效的标准输出句柄
    attach_parent_console();
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

/// GUI 子系统的进程默认没有控制台。从 cmd / PowerShell 启动时把父进程的
/// 控制台接回来，`capture` / `info` 这些子命令的输出才看得见；
/// 从资源管理器 / 开始菜单启动时没有父控制台，失败是常态，忽略即可。
#[cfg(windows)]
fn attach_parent_console() {
    use windows::Win32::System::Console::{AttachConsole, ATTACH_PARENT_PROCESS};
    unsafe {
        let _ = AttachConsole(ATTACH_PARENT_PROCESS);
    }
}

#[cfg(not(windows))]
fn attach_parent_console() {}

fn run(args: &[String]) -> Result<String, String> {
    match args.first().map(String::as_str) {
        Some("app") | None => run_app(),
        Some("capture") => capture(&args[1..]),
        Some("ocr") => run_ocr(&args[1..]),
        Some("record") => run_record(&args[1..]),
        Some("history") => history(&args[1..]),
        Some("daemon") => run_app(),
        Some("scroll") => scroll(&args[1..]),
        Some("windows") => list_windows(),
        Some("info") => Ok(info()),
        Some("--help") | Some("-h") => Ok(usage()),
        Some(other) => Err(format!("未知命令 {other}\n\n{}", usage())),
    }
}

fn usage() -> String {
    concat!(
        "Baobox Windows —— 截图\n\n",
        "用法：\n",
        "  baobox-windows                                 常驻运行：托盘图标 + 全局快捷键 + 设置窗口\n",
        "  baobox-windows capture [-o 输出.png]            交互式（悬停选窗口 · 拖拽选区域 · ⏎ 全屏 · esc 取消）\n",
        "      截完自动进标注编辑器：画框 / 箭头 / 打码 / 写字，再按工具条上的按钮决定去向\n",
        "      --no-edit 跳过编辑，截完直接出图\n",
        "  baobox-windows capture --full [-o 输出.png]\n",
        "  baobox-windows capture --region X,Y,W,H [-o 输出.png]\n",
        "  baobox-windows capture --window <hwnd> [-o 输出.png]\n",
        "      默认复制到剪贴板并保存；--no-copy / --no-save 可分别关掉\n",
        "  baobox-windows ocr [--region X,Y,W,H]                          屏幕取字（用系统自带的识别引擎）\n",
        "  baobox-windows record [--region X,Y,W,H] [--fps 15] [-o 输出.mp4]  录屏（需要 ffmpeg，⏎ 停止）\n",
        "  baobox-windows history [--clear]                               最近的截图\n",
        "  baobox-windows scroll --region X,Y,W,H [--frames N] [--interval MS]\n",
        "  baobox-windows daemon                          与不带参数一样（老名字，保留兼容）\n",
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

    let (target, action) = match (options.full, options.region, options.window) {
        (true, _, _) => (gdi::virtual_screen(), overlay::PostAction::Annotate),
        (_, Some(rect), _) => (rect, overlay::PostAction::Annotate),
        (_, _, Some(id)) => (
            gdi::windows()
                .into_iter()
                .find(|w| w.id == id)
                .ok_or_else(|| format!("找不到窗口 0x{id:08x}，用 `windows` 命令看可用的"))?
                .frame,
            overlay::PostAction::Annotate,
        ),
        // 什么都没指定 → 交互式覆盖层，这是默认用法
        _ => interactive_target(overlay::Mode::Capture)?,
    };

    let shot = gdi::capture(target)?;
    // 按钮条上直接选了去向的，跳过编辑器
    match action {
        overlay::PostAction::Copy => finish(target, shot, options.output, true, false, false),
        overlay::PostAction::Save => finish(target, shot, options.output, false, true, false),
        overlay::PostAction::Pin => {
            let note = deliver(&shot, options.output, false, true)?;
            println!("{note}，已钉在屏幕上（拖动可挪位置，任意键 / 右键 / 双击关闭）");
            pin::show(
                (target.x as i32, target.y as i32),
                &shot.rgba,
                shot.width,
                shot.height,
            )?;
            Ok(String::new())
        }
        overlay::PostAction::Annotate => finish(
            target,
            shot,
            options.output,
            options.copy,
            options.save,
            options.edit,
        ),
    }
}

/// 截完图之后的去向：先（可选地）进标注编辑器，再按结果收尾。
///
/// **开着编辑器时出口由用户按的按钮决定**，`--no-copy` / `--no-save` 不再生效；
/// `-o` 仍然管用 —— 它说的是「存到哪」，不是「要不要存」。与 Linux 版规则一致。
#[cfg(windows)]
fn finish(
    at: Rect,
    shot: gdi::Capture,
    output: Option<PathBuf>,
    copy: bool,
    save: bool,
    edit: bool,
) -> Result<String, String> {
    if !edit {
        return deliver(&shot, output, copy, save);
    }

    let result = editor::run(gdi::virtual_screen(), at, shot.rgba)?;
    let edited = gdi::Capture {
        width: result.width,
        height: result.height,
        rgba: result.rgba,
    };
    match result.outcome {
        baobox_core::editor::EditorOutcome::Cancel => Err("已取消".to_string()),
        baobox_core::editor::EditorOutcome::Copy => deliver(&edited, output, true, false),
        baobox_core::editor::EditorOutcome::Save => deliver(&edited, output, false, true),
        baobox_core::editor::EditorOutcome::Pin => {
            // 贴图会占住这个进程直到用户关掉，所以先落盘 —— 否则关掉贴图图就没了
            let note = deliver(&edited, output, false, true)?;
            println!("{note}，已钉在屏幕上（拖动可挪位置，任意键 / 右键 / 双击关闭）");
            pin::show(
                (at.x as i32, at.y as i32),
                &edited.rgba,
                edited.width,
                edited.height,
            )?;
            Ok(String::new())
        }
    }
}

/// 截图的收尾：按需复制到剪贴板、按需落盘。
///
/// Windows 的剪贴板由系统托管，交出去之后本进程可以直接退出 ——
/// 与 X11 必须常驻服务是完全不同的模型。
#[cfg(windows)]
fn deliver(
    shot: &gdi::Capture,
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
        clipboard::copy_rgba(shot.width, shot.height, &shot.rgba)?;
        notes.push("已复制到剪贴板".to_string());
    }
    if notes.is_empty() {
        return Err("--no-copy 与 --no-save 同时给了，什么都不会发生".to_string());
    }
    Ok(format!("{}（{}×{}）", notes.join("，"), shot.width, shot.height))
}

/// 屏幕取字：框一块区域，把里面的文字识别出来。
///
/// 结果同时打印到标准输出并放进剪贴板 —— 取字十有八九是为了粘贴。
#[cfg(windows)]
fn run_ocr(args: &[String]) -> Result<String, String> {
    let mut region: Option<Rect> = None;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--region" => {
                index += 1;
                region = Some(parse_region(args.get(index).ok_or("--region 缺少参数")?)?);
            }
            other => return Err(format!("未知参数 {other}")),
        }
        index += 1;
    }

    gdi::prepare();
    let target = match region {
        Some(rect) => rect,
        None => interactive_target(overlay::Mode::Pick)?.0,
    };
    let shot = gdi::capture(target)?;
    let text = ocr::recognize(&shot.rgba, shot.width, shot.height)?;
    if text.trim().is_empty() {
        return Err("这块区域里没识别出文字。".to_string());
    }
    println!("{text}");
    clipboard::copy_text(&text)?;
    Ok("（已复制到剪贴板）".to_string())
}

#[cfg(not(windows))]
fn run_ocr(_args: &[String]) -> Result<String, String> {
    Err("本程序只能在 Windows 上运行。".to_string())
}

/// 录屏：框一块区域，录到用户按下 ⏎ 为止。
#[cfg(windows)]
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

    gdi::prepare();
    let target = match region {
        Some(rect) => rect,
        None => interactive_target(overlay::Mode::Pick)?.0,
    };
    let path = match output {
        Some(path) => path,
        None => default_path("")?.with_extension("mp4"),
    };
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("创建目录失败：{e}"))?;
    }

    let recording = record::start(target, fps, &path)?;
    println!(
        "正在录制 {}×{} → {}，按 ⏎ 停止。",
        target.w as i64,
        target.h as i64,
        path.display()
    );
    let mut line = String::new();
    let _ = std::io::stdin().read_line(&mut line);
    recording.stop()?;
    Ok(format!("已保存 {}", path.display()))
}

#[cfg(not(windows))]
fn run_record(_args: &[String]) -> Result<String, String> {
    Err("本程序只能在 Windows 上运行。".to_string())
}

/// 最近的截图。与 Linux 版同一套索引格式。
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
/// 与 Linux / macOS 同一套算法（`baobox_core::stitch`），三边拼出来的结果一致。
#[cfg(windows)]
fn scroll(args: &[String]) -> Result<String, String> {
    use baobox_core::stitch::{compose_rgba, Frame, Stitcher};

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

    gdi::prepare();
    let mut stitcher = Stitcher::new();
    let mut kept: Vec<Vec<u8>> = Vec::new();
    let mut frame_height = 0usize;

    eprintln!("开始长截屏：现在滚动页面，将抓取 {frames} 帧（间隔 {interval_ms}ms）…");
    for _ in 0..frames {
        let shot = gdi::capture(region)?;
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

#[cfg(not(windows))]
fn scroll(_args: &[String]) -> Result<String, String> {
    Err("本程序只能在 Windows 上运行。".to_string())
}

#[cfg(not(windows))]
fn capture(args: &[String]) -> Result<String, String> {
    // 非 Windows 上仍解析参数，便于在其他平台上跑参数解析的测试
    let _ = parse_capture_args(args)?;
    Err("本程序只能在 Windows 上运行。".to_string())
}

/// 铺覆盖层让用户选，返回要抓的矩形和（截图模式下）按钮条上选的去向。
///
/// 覆盖层返回前已销毁自身，所以接下来的抓屏不会把它自己截进去。
#[cfg(windows)]
fn interactive_target(mode: overlay::Mode) -> Result<(Rect, overlay::PostAction), String> {
    let screen = gdi::virtual_screen();
    let window_rects: Vec<Rect> = gdi::windows().into_iter().map(|w| w.frame).collect();
    let result = overlay::run(screen, window_rects, mode)?;
    let rect = match result.outcome {
        baobox_core::selection::Outcome::Region(rect) => rect,
        baobox_core::selection::Outcome::Window(index) => result
            .windows
            .get(index)
            .copied()
            .ok_or_else(|| "选中的窗口已消失".to_string())?,
        baobox_core::selection::Outcome::FullScreen => screen,
        baobox_core::selection::Outcome::Cancelled => return Err("已取消".to_string()),
    };
    Ok((rect, result.action))
}

/// 常驻：托盘图标 + 全局快捷键 + 设置窗口。
#[cfg(windows)]
fn run_app() -> Result<String, String> {
    app::run()
}

#[cfg(not(windows))]
fn run_app() -> Result<String, String> {
    Err("本程序只能在 Windows 上运行。".to_string())
}

/// `capture` 的命令行参数。
struct CaptureOptions {
    full: bool,
    region: Option<Rect>,
    window: Option<isize>,
    output: Option<PathBuf>,
    /// 与 macOS 版默认一致：复制到剪贴板 + 同时落盘
    copy: bool,
    save: bool,
    /// 截完先进标注编辑器
    edit: bool,
}

fn parse_capture_args(args: &[String]) -> Result<CaptureOptions, String> {
    let mut options = CaptureOptions {
        full: false,
        region: None,
        window: None,
        output: None,
        copy: true,
        save: true,
        edit: true,
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
            "--no-copy" => options.copy = false,
            "--no-save" => options.save = false,
            "--no-edit" => options.edit = false,
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
///
/// `save_dir` 非空时改存到那里 —— 设置里的「保存到」就是靠它生效的。
pub fn default_path(save_dir: &str) -> Result<PathBuf, String> {
    let home = std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .map_err(|_| "%USERPROFILE% 未设置".to_string())?;
    let dir = match save_dir.trim() {
        "" => Path::new(&home).join("Pictures").join("Baobox"),
        custom => PathBuf::from(custom),
    };
    let stem = format_template(DEFAULT_TEMPLATE, now_parts());
    // 走 Windows 规则：非法字符更多，另有 CON/PRN/NUL 等保留名
    let safe = sanitize(&stem, Platform::Windows, "screenshot");
    let name = unique(&format!("{safe}.png"), &|candidate: &str| {
        dir.join(candidate).exists()
    });
    Ok(dir.join(name))
}

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
