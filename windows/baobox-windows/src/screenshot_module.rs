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
/// 动作 id。
pub const CAPTURE_FULL: &str = "screenshot.full";
/// 动作 id。
pub const OCR: &str = "screenshot.ocr";
/// 动作 id。
pub const RECORD: &str = "screenshot.record";
/// 动作 id。
pub const HISTORY: &str = "screenshot.history";

/// 截图工具。
pub struct ScreenshotTool {
    settings: Settings,
    /// 有没有 ffmpeg。启动时探一次；菜单构建只读这个布尔，零磁盘 IO
    has_ffmpeg: bool,
    /// 正在进行的录制。有值时菜单里那一项变成「停止录制」
    recording: Option<Recording>,
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
}

impl Settings {
    fn read(config: &Config) -> Self {
        Self {
            copy: config.bool_or(ID, "copy_to_clipboard", true),
            save: config.bool_or(ID, "save_to_disk", true),
            edit: config.bool_or(ID, "annotate_before_saving", true),
            fps: config.usize_or(ID, "record_fps", record::DEFAULT_FPS as usize) as i64,
            save_dir: config.string_or(ID, "save_dir", ""),
            history_limit: config.usize_or(ID, "history_limit", 20),
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
        let mut items = vec![
            MenuItem::action(CAPTURE, "截图…"),
            MenuItem::action(CAPTURE_FULL, "截整个屏幕"),
            MenuItem::Separator,
            // 取字用系统自带的引擎，不需要探测外部程序 —— 这是 Windows
            // 相对 Linux 唯一「白拿」的一块
            MenuItem::action(OCR, "屏幕取字…"),
        ];
        items.push(match (self.has_ffmpeg, self.recording.is_some()) {
            (false, _) => MenuItem::disabled("录屏（未检测到 ffmpeg）"),
            (true, false) => MenuItem::action(RECORD, "录屏…"),
            (true, true) => MenuItem::action(RECORD, "停止录制"),
        });
        items.push(MenuItem::Separator);
        items.push(MenuItem::action(HISTORY, "打开历史目录"));
        items
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
                Field::number("record_fps", "录屏帧率", record::DEFAULT_FPS as i64, 1, 60),
                Field::number("history_limit", "历史保留张数", 20, 1, 200),
            ],
        ))
    }

    fn activate(&mut self, config: &Config) {
        self.settings = Settings::read(config);
        self.has_ffmpeg = Self::probe_ffmpeg();
    }

    fn config_changed(&mut self, config: &Config) {
        self.settings = Settings::read(config);
    }

    fn will_terminate(&mut self) {
        // 退出前把录制收干净：直接被杀的话 mp4 没有 moov box，播放器打不开
        if let Some(current) = self.recording.take() {
            let _ = current.handle.stop();
        }
    }

    fn perform(&mut self, action: &str) -> Result<String, String> {
        match action {
            CAPTURE => self.capture(None),
            CAPTURE_FULL => self.capture(Some(gdi::virtual_screen())),
            OCR => self.ocr(),
            RECORD => self.record(),
            HISTORY => self.open_history(),
            other => Err(format!("截图工具不认识动作 {other}")),
        }
    }
}

impl ScreenshotTool {
    fn capture(&mut self, region: Option<Rect>) -> Result<String, String> {
        gdi::prepare();
        let (target, toolbar_click) = match region {
            Some(rect) => (rect, None),
            None => interactive_target(crate::overlay::Mode::Capture)?,
        };
        let shot = gdi::capture(target)?;

        // 覆盖层工具栏上点过按钮的，交给编辑器的同一套点击逻辑去解释
        //（出口类按钮不会真的开窗）；只有纯回车确认才尊重「不进编辑器」的设置
        if !self.settings.edit && toolbar_click.is_none() {
            return self.deliver(&shot, self.settings.copy, self.settings.save);
        }

        let result = editor::run(gdi::virtual_screen(), target, shot.rgba, toolbar_click)?;
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
                // 贴图会占住这个线程直到用户关掉，所以先落盘
                let note = self.deliver(&edited, false, true)?;
                pin::show(
                    (target.x as i32, target.y as i32),
                    &edited.rgba,
                    edited.width,
                    edited.height,
                )?;
                Ok(note)
            }
        }
    }

    fn deliver(&self, shot: &gdi::Capture, copy: bool, save: bool) -> Result<String, String> {
        let mut notes = Vec::new();
        if save {
            let path = crate::default_path(&self.settings.save_dir)?;
            baobox_image::write_rgba(&path, shot.width, shot.height, &shot.rgba)?;
            store::remember(
                &path,
                shot.width,
                shot.height,
                crate::now_seconds(),
                Some(self.settings.history_limit),
            );
            notes.push(format!("已保存 {}", path.display()));
        }
        if copy {
            crate::clipboard::copy_rgba(shot.width, shot.height, &shot.rgba)?;
            notes.push("已复制到剪贴板".to_string());
        }
        if notes.is_empty() {
            return Err("「复制到剪贴板」与「保存到文件」都关着，截图无处可去".to_string());
        }
        Ok(notes.join("，"))
    }

    fn ocr(&mut self) -> Result<String, String> {
        gdi::prepare();
        let (target, _) = interactive_target(crate::overlay::Mode::Pick)?;
        let shot = gdi::capture(target)?;
        let text = ocr::recognize(&shot.rgba, shot.width, shot.height)?;
        if text.trim().is_empty() {
            return Err("这块区域里没识别出文字".to_string());
        }
        let preview: String = text.chars().take(40).collect();
        crate::clipboard::copy_text(&text)?;
        Ok(format!("已取字并复制：{preview}…"))
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
        let (target, _) = interactive_target(crate::overlay::Mode::Pick)?;
        let path = crate::default_path(&self.settings.save_dir)?.with_extension("mp4");
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

/// 铺覆盖层让用户选，返回要抓的矩形和（截图模式下）工具栏上的那一下点击。
fn interactive_target(
    mode: crate::overlay::Mode,
) -> Result<(Rect, Option<(f64, f64)>), String> {
    let screen = gdi::virtual_screen();
    let window_rects: Vec<Rect> = gdi::windows().into_iter().map(|w| w.frame).collect();
    let result = crate::overlay::run(screen, window_rects, mode)?;
    let rect = match result.outcome {
        Outcome::Region(rect) => rect,
        Outcome::Window(index) => result
            .windows
            .get(index)
            .copied()
            .ok_or_else(|| "选中的窗口已消失".to_string())?,
        Outcome::FullScreen => screen,
        Outcome::Cancelled => return Err("已取消".to_string()),
    };
    Ok((rect, result.toolbar_click))
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
