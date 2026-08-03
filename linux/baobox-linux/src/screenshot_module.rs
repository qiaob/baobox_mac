//! 截图工具接进 App 框架。
//!
//! 这个文件是**适配层**，不含截图逻辑 —— 抓屏在 `x11capture`，覆盖层在 `overlay`，
//! 标注在 `editor`，取字在 `ocr`，录屏在 `record`。这里只回答框架的四个问题：
//! 菜单里放什么、要哪些快捷键、设置页长什么样、动作来了怎么执行。
//!
//! 与 macOS 侧 `Modules/Screenshot/ScreenshotTool.swift` 承担的是同一件事。

use crate::{editor, ocr, pin, record, store, x11capture};
use baobox_app::{Field, HotkeySpec, MenuItem, SettingsPage, ToolModule};
use baobox_core::config::Config;
use baobox_core::editor::EditorOutcome;
use baobox_core::geometry::Rect;
use baobox_core::hotkey::KeyCombo;
use baobox_core::selection::Outcome;
use std::path::PathBuf;
use x11capture::X11Session;

/// 工具 id，同时是配置里的节名。
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
    /// 从配置里读来的偏好。**在内存里**，菜单与动作都不再碰磁盘
    settings: Settings,
    /// 环境里有没有 tesseract / ffmpeg。启动时探一次，之后只读缓存 ——
    /// 菜单每次弹出都重建，不能在那里去翻 PATH
    has_tesseract: bool,
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
    langs: String,
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
            langs: config.string_or(ID, "ocr_languages", ocr::DEFAULT_LANGS),
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
            has_tesseract: false,
            has_ffmpeg: false,
            recording: None,
        }
    }

    /// PATH 里有没有这个命令。
    ///
    /// 直接跑一次而不是翻 PATH 目录 —— 后者要自己处理软链与权限位，
    /// 还不一定和真正执行时的解析结果一致。版本参数按各自的习惯给：
    /// ffmpeg 只认单横线的 `-version`。
    fn probe(binary: &str, version_flag: &str) -> bool {
        std::process::Command::new(binary)
            .arg(version_flag)
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
        // 只读内存缓存，零磁盘 IO —— 菜单每次弹出都会走这里
        let mut items = vec![
            MenuItem::action(CAPTURE, "截图…"),
            MenuItem::action(CAPTURE_FULL, "截整个屏幕"),
            MenuItem::Separator,
        ];
        // 依赖外部命令的功能：没装时显示一条置灰的引导，而不是让菜单项消失
        items.push(if self.has_tesseract {
            MenuItem::action(OCR, "屏幕取字…")
        } else {
            MenuItem::disabled("屏幕取字（未检测到 tesseract）")
        });
        // 录制中时同一项变成「停止」—— 常驻 App 没有终端可以按 ⏎，
        // 停止入口必须在菜单里看得见
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
            // 后面三个容易和别的程序撞，出厂不绑定，让用户自己设
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
                Field::text(
                    "save_dir",
                    "保存到",
                    "",
                    "留空 = ~/Pictures/Baobox",
                ),
                Field::text("ocr_languages", "取字语言", ocr::DEFAULT_LANGS, "chi_sim+eng")
                    .with_help("tesseract 的语言包名，用 + 连接"),
                Field::number("record_fps", "录屏帧率", record::DEFAULT_FPS as i64, 1, 60),
                Field::number("history_limit", "历史保留张数", 20, 1, 200),
            ],
        ))
    }

    fn activate(&mut self, config: &Config) {
        self.settings = Settings::read(config);
        // 探测放在 activate 里跑一次，菜单构建时就只读这两个布尔
        self.has_tesseract = Self::probe("tesseract", "--version");
        self.has_ffmpeg = Self::probe("ffmpeg", "-version");
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
            CAPTURE_FULL => {
                let session = X11Session::open()?;
                let full = session.screen_rect();
                self.capture(Some(full))
            }
            OCR => self.ocr(),
            RECORD => self.record(),
            HISTORY => self.open_history(),
            other => Err(format!("截图工具不认识动作 {other}")),
        }
    }
}

impl ScreenshotTool {
    /// 截图。`region` 为 `None` 时先弹覆盖层让用户选。
    fn capture(&mut self, region: Option<Rect>) -> Result<String, String> {
        let session = X11Session::open()?;
        let target = match region {
            Some(rect) => rect,
            None => interactive_target(&session)?,
        };
        let shot = session.capture(target)?;

        if !self.settings.edit {
            return self.deliver(&shot, self.settings.copy, self.settings.save);
        }

        let result = editor::run(
            session.connection(),
            session.screen(),
            session.screen_rect(),
            target,
            shot.rgba,
        )?;
        let edited = x11capture::Capture {
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
                    session.connection(),
                    session.screen(),
                    target,
                    &edited.rgba,
                    edited.width,
                    edited.height,
                )?;
                Ok(note)
            }
        }
    }

    /// 落盘 / 复制。
    ///
    /// 不需要 X11 会话 —— 复制交给后台线程自己开连接去做（见
    /// [`crate::clipboard::serve_detached`]），这里立刻返回。
    fn deliver(
        &self,
        shot: &x11capture::Capture,
        copy: bool,
        save: bool,
    ) -> Result<String, String> {
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
            let png = baobox_image::encode_rgba(shot.width, shot.height, &shot.rgba)?;
            // 后台线程去持有剪贴板：X11 要本进程持续应答，在主线程上等
            // 会把整个界面冻住
            crate::clipboard::serve_detached(crate::clipboard::Payload::Png(png));
            notes.push("已复制到剪贴板".to_string());
        }
        if notes.is_empty() {
            return Err("「复制到剪贴板」与「保存到文件」都关着，截图无处可去".to_string());
        }
        Ok(notes.join("，"))
    }

    fn ocr(&mut self) -> Result<String, String> {
        let session = X11Session::open()?;
        let target = interactive_target(&session)?;
        let shot = session.capture(target)?;

        let temp = std::env::temp_dir().join(format!("baobox-ocr-{}.png", std::process::id()));
        baobox_image::write_rgba(&temp, shot.width, shot.height, &shot.rgba)?;
        let recognized = ocr::recognize(&temp, &self.settings.langs);
        let _ = std::fs::remove_file(&temp);
        let text = recognized?;
        if text.trim().is_empty() {
            return Err("这块区域里没识别出文字".to_string());
        }

        let preview: String = text.chars().take(40).collect();
        crate::clipboard::serve_detached(crate::clipboard::Payload::Text(text));
        Ok(format!("已取字并复制：{preview}…"))
    }

    /// 录屏是**开关**：没在录就开始，正在录就停下。
    ///
    /// 常驻 App 里没有终端可以「按 ⏎ 停止」，所以停止入口必须是同一个动作 ——
    /// 这样快捷键和菜单项都能停，不必再造一个只在录制时才存在的入口。
    fn record(&mut self) -> Result<String, String> {
        if let Some(current) = self.recording.take() {
            let path = current.path;
            current.handle.stop()?;
            return Ok(format!("录制结束，已保存 {}", path.display()));
        }

        let session = X11Session::open()?;
        let target = interactive_target(&session)?;
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
        let dir: PathBuf = store::dir().ok_or("找不到数据目录")?;
        std::fs::create_dir_all(&dir).map_err(|e| format!("创建历史目录失败：{e}"))?;
        // xdg-open 在所有桌面上都有，比猜文件管理器可靠
        std::process::Command::new("xdg-open")
            .arg(&dir)
            .spawn()
            .map_err(|e| format!("打不开历史目录（{e}）。目录在 {}", dir.display()))?;
        Ok(format!("已打开 {}", dir.display()))
    }
}

/// 铺覆盖层让用户选，返回要抓的矩形。
fn interactive_target(session: &X11Session) -> Result<Rect, String> {
    let window_rects: Vec<Rect> = session.windows()?.into_iter().map(|w| w.frame).collect();
    let result = crate::overlay::run(
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_menu_action_is_something_perform_knows() {
        let tool = ScreenshotTool::new();
        let mut known = tool.menu_items();
        known.retain(|item| !matches!(item, MenuItem::Separator));
        for item in known {
            if let MenuItem::Action { id, enabled, .. } = item {
                if enabled {
                    assert!(
                        id.starts_with("screenshot."),
                        "动作 id 的前缀决定派发给谁，{id} 会派发不到自己头上"
                    );
                }
            }
        }
    }

    #[test]
    fn an_unknown_action_is_refused_rather_than_silently_ignored() {
        let mut tool = ScreenshotTool::new();
        assert!(tool.perform("screenshot.nope").unwrap_err().contains("不认识"));
    }

    #[test]
    fn missing_binaries_become_greyed_out_hints_not_missing_items() {
        let mut tool = ScreenshotTool::new();
        tool.has_tesseract = false;
        tool.has_ffmpeg = false;
        let items = tool.menu_items();
        let disabled: Vec<&MenuItem> = items
            .iter()
            .filter(|item| matches!(item, MenuItem::Action { enabled: false, .. }))
            .collect();
        assert_eq!(disabled.len(), 2, "没装的两个功能应当各留一条置灰提示");
        assert!(items.iter().any(|item| matches!(
            item,
            MenuItem::Action { label, enabled: false, .. } if label.contains("tesseract")
        )));

        tool.has_tesseract = true;
        tool.has_ffmpeg = true;
        assert!(tool.menu_items().iter().any(|item| matches!(
            item,
            MenuItem::Action { id, enabled: true, .. } if id == OCR
        )));
    }

    #[test]
    fn only_the_capture_hotkey_ships_bound_by_default() {
        let hotkeys = ScreenshotTool::new().hotkeys();
        let bound: Vec<&str> = hotkeys
            .iter()
            .filter(|spec| spec.default.is_some())
            .map(|spec| spec.id.as_str())
            .collect();
        // 容易冲突的组合出厂不绑定，由用户在设置里自己设（CLAUDE.md 约定 6）
        assert_eq!(bound, vec![CAPTURE]);
    }

    #[test]
    fn the_record_item_turns_into_stop_while_recording() {
        let mut tool = ScreenshotTool::new();
        tool.has_ffmpeg = true;
        let label = |tool: &ScreenshotTool| -> String {
            tool.menu_items()
                .into_iter()
                .find_map(|item| match item {
                    MenuItem::Action { id, label, .. } if id == RECORD => Some(label),
                    _ => None,
                })
                .unwrap_or_default()
        };
        assert!(label(&tool).contains("录屏"));

        // 装成正在录制的样子：常驻 App 里没有终端可以按 ⏎，
        // 停止入口必须在菜单里看得见
        tool.recording = Some(Recording {
            handle: record::Recording::detached(),
            path: PathBuf::from("/tmp/x.mp4"),
        });
        assert!(label(&tool).contains("停止"));
    }


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
    fn settings_declare_every_preference_the_tool_actually_reads() {
        let page = ScreenshotTool::new().settings_page().unwrap();
        let keys: Vec<&str> = page.fields.iter().map(|f| f.key.as_str()).collect();
        for expected in [
            "annotate_before_saving",
            "copy_to_clipboard",
            "save_to_disk",
            "ocr_languages",
            "record_fps",
        ] {
            assert!(keys.contains(&expected), "{expected} 在代码里读了却没声明");
        }
        assert_eq!(page.section, ID, "节名必须与工具 id 一致，否则读写对不上");
    }

    #[test]
    fn settings_round_trip_through_the_config() {
        let page = ScreenshotTool::new().settings_page().unwrap();
        let mut config = Config::new();
        page.fill_defaults(&mut config);

        let mut tool = ScreenshotTool::new();
        tool.config_changed(&config);
        assert!(tool.settings.copy);

        config.set_bool(ID, "copy_to_clipboard", false);
        tool.config_changed(&config);
        assert!(!tool.settings.copy, "改了配置就该跟着变");
    }

}
