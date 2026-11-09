//! 截图工具接进 App 框架（Windows）。
//!
//! 与 Linux 的同名文件是**同一个适配层的两种实现**：菜单、快捷键、设置声明
//! 逐字对齐（`baobox_app` 的声明是共享的），只有「动作怎么执行」这一段
//! 换成 GDI / WinRT 那一套。
//!
//! 截图逻辑本身不在这里 —— 抓屏在 `gdi`，覆盖层在 `overlay`，标注在 `editor`，
//! 取字在 `ocr`，录屏在 `record`。

#![cfg(windows)]

use crate::{editor, gdi, ocr, pin, record, store};
use baobox_app::{Field, HotkeySpec, MenuItem, SettingsPage, ToolModule};
use baobox_core::config::Config;
use baobox_core::editor::EditorOutcome;
use baobox_core::geometry::Rect;
use baobox_core::hotkey::KeyCombo;
use baobox_core::selection::Outcome;
use std::path::PathBuf;

/// 工具 id，同时是配置里的节名。**必须与 Linux 侧一致** ——
/// 否则同一份配置在两个系统上读到的是不同的节。
pub const ID: &str = "screenshot";

/// 动作 id。
pub const CAPTURE: &str = "screenshot.capture";
pub const QUICK_CAPTURE: &str = "screenshot.quick";
/// 动作 id。
pub const CAPTURE_FULL: &str = "screenshot.full";
/// 动作 id。
pub const OCR: &str = "screenshot.ocr";
/// 动作 id。
pub const RECORD: &str = "screenshot.record";
/// 动作 id。
pub const HISTORY: &str = "screenshot.history";
pub(crate) const LONG: &str = "screenshot.long";
const CLOSE_PINS: &str = "screenshot.close-pins";
const HISTORY_ENTRY: &str = "screenshot.history-entry.";

/// 截图工具。
pub struct ScreenshotTool {
    settings: Settings,
    /// 有没有 ffmpeg。启动时探一次；菜单构建只读这个布尔，零磁盘 IO
    has_ffmpeg: bool,
    /// 正在进行的录制。有值时菜单里那一项变成「停止录制」
    recording: Option<Recording>,
    history: Vec<baobox_core::history::Entry>,
}

/// 一次正在进行的录制。
struct Recording {
    handle: record::Recording,
    path: PathBuf,
}

/// 从配置读出来的偏好。
struct Settings {
    copy: bool,
    save: bool,
    edit: bool,
    fps: i64,
    save_dir: String,
    history_limit: usize,
    filename: String,
    gif: bool,
    ocr_language: String,
    ocr_copy: bool,
}

impl Settings {
    fn read(config: &Config) -> Self {
        Self {
            copy: config.bool_or(ID, "copy_to_clipboard", true),
            save: config.bool_or(ID, "save_to_disk", true),
            edit: config.bool_or(ID, "annotate_before_saving", true),
            fps: config.usize_or(ID, "record_fps", record::DEFAULT_FPS as usize) as i64,
            save_dir: config.string_or(ID, "save_dir", ""),
            history_limit: config.usize_or(ID, "history_limit", 20).clamp(1, 200),
            filename: config.string_or(ID, "filename_template", crate::DEFAULT_TEMPLATE),
            gif: config.string_or(ID, "record_format", "mp4") == "gif",
            ocr_language: config.string_or(ID, "ocr_language", ""),
            ocr_copy: config.bool_or(ID, "ocr_copy", true),
        }
    }
}

impl Default for ScreenshotTool {
    fn default() -> Self {
        Self::new()
    }
}

impl ScreenshotTool {
    /// 新建。此时还没读配置，`activate` 才读。
    pub fn new() -> Self {
        Self {
            settings: Settings::read(&Config::new()),
            has_ffmpeg: false,
            recording: None,
            history: Vec::new(),
        }
    }

    /// PATH 里有没有 ffmpeg。直接跑一次而不是翻 PATH —— 后者要自己处理
    /// PATHEXT 与各种后缀，还不一定和真正执行时的解析一致。
    fn probe_ffmpeg() -> bool {
        std::process::Command::new("ffmpeg")
            .arg("-version")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    }
}

impl ToolModule for ScreenshotTool {
    fn id(&self) -> &str {
        ID
    }

    fn name(&self) -> &str {
        "截图"
    }

    fn menu_items(&self) -> Vec<MenuItem> {
        let record = match (self.has_ffmpeg, self.recording.is_some()) {
            (false, _) => MenuItem::disabled("开始录屏（需 ffmpeg）"),
            (true, false) => MenuItem::action(RECORD, "开始录屏"),
            (true, true) => MenuItem::action(RECORD, "停止录制"),
        };
        let mut history = Vec::new();
        for (index, entry) in self.history.iter().take(10).enumerate() {
            let label = std::path::Path::new(&entry.path)
                .file_name()
                .map_or("截图".into(), |name| name.to_string_lossy());
            history.push(MenuItem::action(&format!("{HISTORY_ENTRY}{index}"), &label));
        }
        if history.is_empty() {
            history.push(MenuItem::disabled("暂无截图"));
        }
        history.push(MenuItem::Separator);
        history.push(MenuItem::action(HISTORY, "打开历史目录"));
        vec![
            MenuItem::action(CAPTURE, "开始截图"),
            MenuItem::action(CAPTURE_FULL, "截整个屏幕"),
            MenuItem::action(LONG, "长截图"),
            record,
            MenuItem::action(OCR, "屏幕取字"),
            MenuItem::Submenu {
                label: "截图历史".into(),
                items: history,
            },
            MenuItem::Submenu {
                label: "贴图管理".into(),
                items: vec![MenuItem::action(CLOSE_PINS, "关闭所有贴图")],
            },
            MenuItem::Separator,
            MenuItem::action("screenshot.settings", "截图设置…"),
        ]
    }
    fn hotkeys(&self) -> Vec<HotkeySpec> {
        vec![
            HotkeySpec::new(CAPTURE, "截图", KeyCombo::parse("Ctrl+Shift+S").ok()),
            // 后面三个容易和别的程序撞，出厂不绑定
            HotkeySpec::new(CAPTURE_FULL, "截整个屏幕", None),
            HotkeySpec::new(OCR, "屏幕取字", None),
            HotkeySpec::new(RECORD, "录屏", None),
        ]
    }

    fn settings_page(&self) -> Option<SettingsPage> {
        Some(SettingsPage::new(
            ID,
            "截图",
            vec![
                Field::toggle("annotate_before_saving", "截完先进标注编辑器", true)
                    .with_help("关掉之后截完直接出图，不再打开编辑器"),
                Field::toggle("copy_to_clipboard", "复制到剪贴板", true),
                Field::toggle("save_to_disk", "同时保存到文件", true)
                    .with_help("两个都关掉的话截图之后什么都不会发生"),
                Field::text("save_dir", "保存到", "", "留空 = 图片\\Baobox"),
                Field::text(
                    "filename_template",
                    "文件名模板",
                    crate::DEFAULT_TEMPLATE,
                    "Screenshot {yyyy}-{MM}-{dd} {HH}.{mm}.{ss}",
                )
                .with_help("支持 {yyyy}、{MM}、{dd}、{HH}、{mm}、{ss}，自动添加扩展名。"),
                Field::choice(
                    "record_format",
                    "输出格式",
                    &[("mp4", "MP4"), ("gif", "GIF")],
                    "mp4",
                ),
                Field::number("record_fps", "录屏帧率", record::DEFAULT_FPS as i64, 1, 60),
                Field::choice(
                    "ocr_language",
                    "识别语言",
                    &[("", "跟随系统"), ("zh-Hans", "简体中文"), ("en-US", "英文")],
                    "",
                ),
                Field::toggle("ocr_copy", "识别后直接复制，不弹结果窗", true)
                    .with_help("由 Windows 在本地识别，所选语言需安装文本识别功能。"),
                Field::number("history_limit", "历史保留张数", 20, 1, 200)
                    .with_help("复制、保存和贴图都会保留一份独立的截图历史。"),
            ],
        ))
    }

    fn activate(&mut self, config: &Config) {
        self.settings = Settings::read(config);
        self.history = store::load(self.settings.history_limit).entries().to_vec();
        self.has_ffmpeg = Self::probe_ffmpeg();
    }

    fn config_changed(&mut self, config: &Config) {
        self.settings = Settings::read(config);
        self.history = store::load(self.settings.history_limit).entries().to_vec();
    }

    fn will_terminate(&mut self) {
        // 退出前把录制收干净：直接被杀的话 mp4 没有 moov box，播放器打不开
        if let Some(current) = self.recording.take() {
            let _ = current.handle.stop();
        }
    }

    fn perform(&mut self, action: &str) -> Result<String, String> {
        match action {
            CAPTURE => self.capture(None, self.settings.edit),
            QUICK_CAPTURE => self.capture(None, false),
            CAPTURE_FULL => self.capture(Some(gdi::virtual_screen()), self.settings.edit),
            OCR => self.ocr(),
            LONG => self.long_capture(None),
            CLOSE_PINS => {
                pin::close_all();
                Ok(String::new())
            }
            action if action.starts_with(HISTORY_ENTRY) => {
                let index = action[HISTORY_ENTRY.len()..]
                    .parse::<usize>()
                    .map_err(|_| "无效的历史条目")?;
                let entry = self.history.get(index).ok_or("截图历史不存在")?;
                open_screenshot(&entry.path)?;
                Ok(String::new())
            }
            RECORD => self.record(),
            HISTORY => self.open_history(),
            other => Err(format!("截图工具不认识动作 {other}")),
        }
    }
}

impl ScreenshotTool {
    fn capture(&mut self, region: Option<Rect>, edit: bool) -> Result<String, String> {
        gdi::prepare();
        let (target, shot) = match region {
            Some(rect) => (rect, gdi::capture(rect)?),
            None => {
                let screen = gdi::virtual_screen();
                let windows = gdi::windows()
                    .into_iter()
                    .map(|window| window.frame)
                    .collect();
                let result = if edit {
                    crate::overlay::run_editor(screen, windows)?
                } else {
                    crate::overlay::run_capture(screen, windows)?
                };
                if let Some((target, edited)) = result.edited {
                    return self.finish_edit(target, edited);
                }
                result.captured.ok_or("已取消")?
            }
        };

        if !edit {
            return self.deliver(&shot, self.settings.copy, self.settings.save);
        }

        let result = editor::run(gdi::virtual_screen(), target, shot.rgba)?;
        self.finish_edit(target, result)
    }

    fn finish_edit(
        &mut self,
        target: Rect,
        result: editor::EditorResult,
    ) -> Result<String, String> {
        if let Some(action) = result.extra {
            return match action {
                editor::ExtraAction::Scroll => self.long_capture(Some(target)),
                editor::ExtraAction::Ocr => self.recognize(&gdi::Capture {
                    width: result.width,
                    height: result.height,
                    rgba: result.rgba,
                }),
            };
        }
        let edited = gdi::Capture {
            width: result.width,
            height: result.height,
            rgba: result.rgba,
        };
        match result.outcome {
            EditorOutcome::Cancel => Err("已取消".to_string()),
            EditorOutcome::Copy => self.deliver(&edited, true, false),
            EditorOutcome::Save => self.deliver(&edited, false, true),
            EditorOutcome::Pin => {
                // 贴图由窗口自己持有，托盘继续处理其他操作。
                pin::open(
                    (target.x as i32, target.y as i32),
                    &edited.rgba,
                    edited.width,
                    edited.height,
                )?;
                self.deliver(&edited, false, self.settings.save)
            }
        }
    }

    fn deliver(&mut self, shot: &gdi::Capture, copy: bool, save: bool) -> Result<String, String> {
        let mut errors = Vec::new();
        let mut notes = Vec::new();
        let history_result = (|| {
            let dir = store::dir().ok_or("找不到截图历史目录")?;
            let path = crate::capture_path(&dir, &self.settings.filename, "png");
            baobox_image::write_rgba(&path, shot.width, shot.height, &shot.rgba)?;
            store::remember(
                &path,
                shot.width,
                shot.height,
                crate::now_seconds(),
                Some(self.settings.history_limit),
            );
            self.history = store::load(self.settings.history_limit).entries().to_vec();
            Ok::<_, String>(())
        })();
        if let Err(error) = history_result {
            errors.push(format!("截图历史写入失败：{error}"));
        }
        if save {
            match self.save_shot(shot) {
                Ok(path) => notes.push(format!("已保存 {}", path.display())),
                Err(error) => errors.push(error),
            }
        }
        if copy {
            match crate::clipboard::copy_rgba(shot.width, shot.height, &shot.rgba) {
                Ok(()) => notes.push("已复制到剪贴板".to_owned()),
                Err(error) => errors.push(error),
            }
        }
        if !errors.is_empty() {
            notes.extend(errors);
            return Err(notes.join("。"));
        }
        if notes.is_empty() {
            notes.push("已存入截图历史".into());
        }
        Ok(notes.join("，"))
    }

    fn save_shot(&self, shot: &gdi::Capture) -> Result<std::path::PathBuf, String> {
        let path = crate::configured_capture_path(
            &self.settings.save_dir,
            &self.settings.filename,
            "png",
        )?;
        baobox_image::write_rgba(&path, shot.width, shot.height, &shot.rgba)?;
        Ok(path)
    }

    fn ocr(&self) -> Result<String, String> {
        gdi::prepare();
        let screen = gdi::virtual_screen();
        let windows = gdi::windows()
            .into_iter()
            .map(|window| window.frame)
            .collect();
        let (_, shot) = crate::overlay::run_capture(screen, windows)?
            .captured
            .ok_or("已取消")?;
        self.recognize(&shot)
    }

    fn recognize(&self, shot: &gdi::Capture) -> Result<String, String> {
        self.recognize_from(shot, windows::Win32::Foundation::HWND::default())
    }

    fn recognize_from(
        &self,
        shot: &gdi::Capture,
        owner: windows::Win32::Foundation::HWND,
    ) -> Result<String, String> {
        let text = ocr::recognize_language(
            &shot.rgba,
            shot.width,
            shot.height,
            &self.settings.ocr_language,
        )?;
        if text.trim().is_empty() {
            return Err("这块区域里没识别出文字".into());
        }
        if !self.settings.ocr_copy {
            use windows::core::{w, PCWSTR};
            use windows::Win32::UI::WindowsAndMessaging::{MessageBoxW, IDOK, MB_OKCANCEL};
            let prompt: Vec<u16> = format!("{text}\n\n确定复制，取消关闭。")
                .encode_utf16()
                .chain(Some(0))
                .collect();
            if unsafe {
                MessageBoxW(owner, PCWSTR(prompt.as_ptr()), w!("屏幕取字"), MB_OKCANCEL)
            } != IDOK
            {
                return Ok(String::new());
            }
        }
        crate::clipboard::copy_text(&text)?;
        Ok("已取字并复制到剪贴板".into())
    }

    fn long_capture(&mut self, target: Option<Rect>) -> Result<String, String> {
        let target = match target {
            Some(rect) => rect,
            None => interactive_target()?,
        };
        let shot = capture_long(target)?;
        let mut result = self.deliver(&shot, false, self.settings.save);
        use crate::screenshot_preview::Action;
        crate::screenshot_preview::run(&shot, |owner, action| {
            let action_result = match action {
                Action::Save => self
                    .save_shot(&shot)
                    .map(|path| format!("已保存 {}", path.display())),
                Action::Ocr => self.recognize_from(&shot, owner),
                Action::Pin => pin::open(
                    (target.x as i32, target.y as i32),
                    &shot.rgba,
                    shot.width,
                    shot.height,
                )
                .map(|_| "已钉在屏幕".into()),
                Action::Copy => crate::clipboard::copy_rgba(shot.width, shot.height, &shot.rgba)
                    .map(|_| "已复制长截图".into()),
            };
            if matches!(action, Action::Save | Action::Ocr) {
                let (Ok(message) | Err(message)) = &action_result;
                if !message.is_empty() {
                    use windows::core::{w, PCWSTR};
                    use windows::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_OK};
                    let text: Vec<u16> = message.encode_utf16().chain(Some(0)).collect();
                    unsafe {
                        MessageBoxW(owner, PCWSTR(text.as_ptr()), w!("长截图"), MB_OK);
                    }
                }
            } else if result.is_ok() {
                result = action_result;
            }
        })?;
        result
    }
    /// 录屏是**开关**：没在录就开始，正在录就停下。
    ///
    /// 常驻 App 里没有终端可以「按 ⏎ 停止」，所以停止入口必须是同一个动作。
    fn record(&mut self) -> Result<String, String> {
        if let Some(current) = self.recording.take() {
            let path = current.path;
            current.handle.stop()?;
            return Ok(format!("录制结束，已保存 {}", path.display()));
        }

        gdi::prepare();
        let target = interactive_target()?;
        let extension = if self.settings.gif { "gif" } else { "mp4" };
        let path = crate::configured_capture_path(
            &self.settings.save_dir,
            &self.settings.filename,
            extension,
        )?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("创建目录失败：{e}"))?;
        }
        let handle = record::start(target, self.settings.fps.max(1) as u32, &path)?;
        self.recording = Some(Recording {
            handle,
            path: path.clone(),
        });
        Ok(format!(
            "正在录制 {}×{} → {}。再点一次「停止录制」结束。",
            target.w as i64,
            target.h as i64,
            path.display()
        ))
    }

    fn open_history(&self) -> Result<String, String> {
        let dir = store::dir().ok_or("找不到数据目录")?;
        std::fs::create_dir_all(&dir).map_err(|e| format!("创建历史目录失败：{e}"))?;
        std::process::Command::new("explorer")
            .arg(&dir)
            .spawn()
            .map_err(|e| format!("打不开历史目录（{e}）。目录在 {}", dir.display()))?;
        Ok(format!("已打开 {}", dir.display()))
    }
}

fn open_screenshot(path: &str) -> Result<(), String> {
    use windows::core::{w, PCWSTR};
    use windows::Win32::UI::{Shell::ShellExecuteW, WindowsAndMessaging::SW_SHOWNORMAL};
    let path: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
    let result = unsafe {
        ShellExecuteW(
            None,
            w!("open"),
            PCWSTR(path.as_ptr()),
            None,
            None,
            SW_SHOWNORMAL,
        )
    };
    if result.0 as isize <= 32 {
        Err("无法打开截图预览，图片可从截图历史打开".into())
    } else {
        Ok(())
    }
}

pub fn capture_long(region: Rect) -> Result<gdi::Capture, String> {
    use windows::core::w;
    use windows::Win32::Foundation::{
        COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM,
    };
    use windows::Win32::Graphics::Gdi::{
        CreateRoundRectRgn, DeleteObject, FillRect, GetStockObject, SetBkColor, SetDCBrushColor,
        SetTextColor, SetWindowRgn, DC_BRUSH, HBRUSH, HDC,
    };
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::Input::KeyboardAndMouse::EnableWindow;
    use windows::Win32::UI::WindowsAndMessaging::*;
    const CLASS: windows::core::PCWSTR = w!("BaoboxScrollControls");
    const PANEL: COLORREF = COLORREF(0x242222);

    unsafe extern "system" fn controls(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
        match msg {
            WM_DRAWITEM if matches!(wp.0, 1 | 2) => {
                crate::screenshot_preview::draw_button(lp, wp.0 == 1, PANEL)
            }
            WM_COMMAND if matches!(wp.0, 1 | 2) => {
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, wp.0 as isize);
                LRESULT(0)
            }
            WM_CLOSE => {
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, 2);
                LRESULT(0)
            }
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_ERASEBKGND => {
                let dc = HDC(wp.0 as _);
                let mut rect = RECT::default();
                let _ = GetClientRect(hwnd, &mut rect);
                SetDCBrushColor(dc, PANEL);
                FillRect(dc, &rect, HBRUSH(GetStockObject(DC_BRUSH).0));
                LRESULT(1)
            }
            WM_CTLCOLORSTATIC => {
                let dc = HDC(wp.0 as _);
                SetTextColor(dc, COLORREF(0xeeeeee));
                SetBkColor(dc, PANEL);
                SetDCBrushColor(dc, PANEL);
                LRESULT(GetStockObject(DC_BRUSH).0 as isize)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }

    let screen = gdi::virtual_screen();
    let region = region.clamped_to(&screen);
    if region.w < 40.0 || region.h < 60.0 {
        return Err("请框选至少 40 × 60 像素的可滚动内容，再开始长截图。".into());
    }
    let (width, height) = (438.0, 66.0);
    let x = (region.right() - width).clamp(screen.x, (screen.right() - width).max(screen.x));
    let y = region
        .y
        .clamp(screen.y, (screen.bottom() - height).max(screen.y));
    let (x, y) = if region.bottom() + height + 8.0 <= screen.bottom() {
        (x, region.bottom() + 8.0)
    } else if region.y - height - 8.0 >= screen.y {
        (x, region.y - height - 8.0)
    } else if region.right() + width + 8.0 <= screen.right() {
        (region.right() + 8.0, y)
    } else if region.x - width - 8.0 >= screen.x {
        (region.x - width - 8.0, y)
    } else {
        return Err("请缩小长截图选区，给完成按钮留出空间".into());
    };

    unsafe {
        // The selection overlay took focus. Give it back to the content under
        // the selection so wheel input works even with inactive scrolling off.
        let content = WindowFromPoint(POINT {
            x: (region.x + region.w / 2.0) as i32,
            y: (region.y + region.h / 2.0) as i32,
        });
        let target = GetAncestor(content, GA_ROOT);
        if !target.is_invalid() {
            let _ = SetForegroundWindow(target);
        }
        let instance: HINSTANCE = GetModuleHandleW(None)
            .map_err(|error| error.to_string())?
            .into();
        RegisterClassW(&WNDCLASSW {
            lpfnWndProc: Some(controls),
            hInstance: instance,
            lpszClassName: CLASS,
            ..Default::default()
        });
        let hwnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            CLASS,
            w!("长截图"),
            WS_POPUP,
            x as i32,
            y as i32,
            width as i32,
            height as i32,
            None,
            None,
            instance,
            None,
        )
        .map_err(|error| error.to_string())?;
        let shape = CreateRoundRectRgn(0, 0, width as i32, height as i32, 18, 18);
        if !shape.is_invalid() && SetWindowRgn(hwnd, shape, false) == 0 {
            let _ = DeleteObject(shape);
        }
        let result = (|| {
            let _outline = ScrollOutline::open(region)?;
            let font = crate::settings_window::settings_font(-14, 400);
            let set_font = |control| {
                SendMessageW(control, WM_SETFONT, WPARAM(font.0 as usize), LPARAM(1));
            };
            let font_result = (|| {
                let hint = CreateWindowExW(
                    Default::default(),
                    w!("STATIC"),
                    w!("鼠标放在框内，慢慢滚动页面"),
                    WS_CHILD | WS_VISIBLE,
                    14,
                    11,
                    225,
                    22,
                    hwnd,
                    None,
                    instance,
                    None,
                )
                .map_err(|error| error.to_string())?;
                set_font(hint);
                let label = CreateWindowExW(
                    Default::default(),
                    w!("STATIC"),
                    w!("等待页面滚动…"),
                    WS_CHILD | WS_VISIBLE,
                    14,
                    36,
                    232,
                    22,
                    hwnd,
                    None,
                    instance,
                    None,
                )
                .map_err(|error| error.to_string())?;
                set_font(label);
                let mut finish = HWND::default();
                for (id, x, button_width, title) in
                    [(1, 248, 106, w!("完成并预览")), (2, 362, 62, w!("取消"))]
                {
                    let button = CreateWindowExW(
                        Default::default(),
                        w!("BUTTON"),
                        title,
                        WS_CHILD | WS_VISIBLE | WINDOW_STYLE(BS_OWNERDRAW as u32),
                        x,
                        16,
                        button_width,
                        34,
                        hwnd,
                        HMENU(id as _),
                        instance,
                        None,
                    )
                    .map_err(|error| error.to_string())?;
                    set_font(button);
                    crate::screenshot_preview::style_button(button);
                    if id == 1 {
                        finish = button;
                        let _ = EnableWindow(button, false);
                    }
                }
                let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
                let mut last = usize::MAX;
                crate::capture_scroll(
                    region,
                    720,
                    std::time::Duration::from_millis(250),
                    |count, height| {
                        let mut message = MSG::default();
                        while PeekMessageW(&mut message, hwnd, 0, 0, PM_REMOVE).as_bool() {
                            if message.message == WM_QUIT {
                                PostQuitMessage(message.wParam.0 as i32);
                                return Err("已取消".into());
                            }
                            let _ = TranslateMessage(&message);
                            DispatchMessageW(&message);
                        }
                        if count != last {
                            let can_finish = count >= 2;
                            let _ = EnableWindow(finish, can_finish);
                            let status = if can_finish {
                                format!("已拼接 {height} 像素 · 可继续滚动")
                            } else {
                                "等待滚动 · 拼接到新内容后可完成".into()
                            };
                            let label_text: Vec<u16> =
                                status.encode_utf16().chain(Some(0)).collect();
                            let _ =
                                SetWindowTextW(label, windows::core::PCWSTR(label_text.as_ptr()));
                            last = count;
                        }
                        match GetWindowLongPtrW(hwnd, GWLP_USERDATA) {
                            1 if count >= 2 => Ok(true),
                            2 => Err("已取消".into()),
                            _ => Ok(false),
                        }
                    },
                )
                .map(|(shot, _)| shot)
            })();
            let _ = DestroyWindow(hwnd);
            let _ = windows::Win32::Graphics::Gdi::DeleteObject(font);
            font_result
        })();
        if IsWindow(hwnd).as_bool() {
            let _ = DestroyWindow(hwnd);
        }
        let _ = UnregisterClassW(CLASS, instance);
        result
    }
}

/// A click-through outline whose pixels sit entirely outside the capture rectangle.
struct ScrollOutline(windows::Win32::Foundation::HWND);

impl ScrollOutline {
    fn open(rect: Rect) -> Result<Self, String> {
        use windows::core::w;
        use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, WPARAM};
        use windows::Win32::Graphics::Gdi::{
            BeginPaint, CombineRgn, CreateRectRgn, CreateSolidBrush, DeleteObject, EndPaint,
            FillRect, SetWindowRgn, UpdateWindow, PAINTSTRUCT, RGN_DIFF,
        };
        use windows::Win32::System::LibraryLoader::GetModuleHandleW;
        use windows::Win32::UI::WindowsAndMessaging::*;
        const CLASS: windows::core::PCWSTR = w!("BaoboxScrollOutline");
        unsafe extern "system" fn paint(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
            if msg != WM_PAINT {
                return DefWindowProcW(hwnd, msg, wp, lp);
            }
            let mut ps = PAINTSTRUCT::default();
            let dc = BeginPaint(hwnd, &mut ps);
            let brush = CreateSolidBrush(COLORREF(0xb8c42b));
            FillRect(dc, &ps.rcPaint, brush);
            let _ = DeleteObject(brush);
            let _ = EndPaint(hwnd, &ps);
            LRESULT(0)
        }
        let (width, height) = (rect.w as i32, rect.h as i32);
        unsafe {
            let instance = GetModuleHandleW(None)
                .map_err(|error| error.to_string())?
                .into();
            RegisterClassW(&WNDCLASSW {
                lpfnWndProc: Some(paint),
                hInstance: instance,
                lpszClassName: CLASS,
                ..Default::default()
            });
            let hwnd = CreateWindowExW(
                WS_EX_TOPMOST
                    | WS_EX_TOOLWINDOW
                    | WS_EX_NOACTIVATE
                    | WS_EX_LAYERED
                    | WS_EX_TRANSPARENT,
                CLASS,
                w!("长截图范围"),
                WS_POPUP,
                rect.x as i32 - 2,
                rect.y as i32 - 2,
                width + 4,
                height + 4,
                None,
                None,
                instance,
                None,
            )
            .map_err(|error| format!("无法显示长截图范围：{error}"))?;
            let outline = Self(hwnd);
            let outer = CreateRectRgn(0, 0, width + 4, height + 4);
            let inner = CreateRectRgn(2, 2, width + 2, height + 2);
            let combined = !outer.is_invalid()
                && !inner.is_invalid()
                && CombineRgn(outer, outer, inner, RGN_DIFF).0 != 0;
            let _ = DeleteObject(inner);
            if !combined || SetWindowRgn(hwnd, outer, true) == 0 {
                let _ = DeleteObject(outer);
                return Err("无法显示长截图范围".into());
            }
            SetLayeredWindowAttributes(hwnd, COLORREF(0), 220, LWA_ALPHA)
                .map_err(|error| format!("无法显示长截图范围：{error}"))?;
            let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            let _ = UpdateWindow(hwnd);
            Ok(outline)
        }
    }
}

impl Drop for ScrollOutline {
    fn drop(&mut self) {
        unsafe {
            let _ = windows::Win32::UI::WindowsAndMessaging::DestroyWindow(self.0);
        }
    }
}

/// 铺覆盖层让用户选，返回要抓的矩形。
fn interactive_target() -> Result<Rect, String> {
    let screen = gdi::virtual_screen();
    let window_rects: Vec<Rect> = gdi::windows().into_iter().map(|w| w.frame).collect();
    let result = crate::overlay::run(screen, window_rects)?;
    match result.outcome {
        Outcome::Region(rect) => Ok(rect),
        Outcome::Window(index) => result
            .windows
            .get(index)
            .copied()
            .ok_or_else(|| "选中的窗口已消失".to_string()),
        Outcome::FullScreen => Ok(screen),
        Outcome::Cancelled => Err("已取消".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_declared_setting_is_actually_read_somewhere() {
        // 声明了却没人读 = 用户在设置里改了却什么都不会发生，
        // 那比干脆不给这个选项更糟。这条测试盯着两者不走散。
        let page = ScreenshotTool::new().settings_page().unwrap();
        let source = include_str!("screenshot_module.rs");
        for key in baobox_app::settings::declared_keys(&page) {
            // 声明处出现一次，读取处再出现一次 —— 少于两次就说明只声明没读。
            // 不去匹配具体的调用形状（`config.string_or(ID, "k", …)` 之类），
            // 那种模式换个写法就失效，反而变成一条空转的测试
            let mentions = source.matches(&format!("\"{key}\"")).count();
            assert!(
                mentions >= 2,
                "{key} 在设置里声明了却没人读它（源码里只出现 {mentions} 次）—— \
                 用户改了会什么都不发生，比不给这个选项更糟"
            );
        }
    }

    #[test]
    fn the_settings_section_matches_the_tool_id() {
        // 节名与工具 id 不一致的话，写进去的设置读不出来
        assert_eq!(ScreenshotTool::new().settings_page().unwrap().section, ID);
    }
}
