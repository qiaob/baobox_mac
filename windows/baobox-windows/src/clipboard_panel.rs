//! 剪贴板面板（Windows）：搜一下、选一条、回车粘出去。
//!
//! 与 Linux 的 GTK 版是同一件事的两种画法，**交互规则逐条对齐**：
//!
//! - 面板一出来焦点就在搜索框，直接打字就是搜
//! - ↑↓ 选，⏎ 粘贴，Esc 关掉
//! - Ctrl+1–9 直接选中对应的那条；Ctrl+P 收藏，Ctrl+D 删除
//!
//! 选中条目后，文本工具显示在右侧预览下方。转换先更新预览，确认后才粘贴。
//!
//! # 面板必须先关掉再粘贴
//!
//! 面板开着的时候焦点在我们这儿，合成的 Ctrl+V 会打到自己身上。
//! 所以选中之后的顺序是：关窗口 → 等焦点回位 → 放剪贴板 → 合成按键。
//! 这个顺序由调用方（`clipboard_module`）负责，面板只管把「选了哪一条」交出去。
//!
//! # 敏感内容
//!
//! 列表里一律打码显示，**也进不了文本工具那一层** —— 那一层会把内容拆开摆出来，
//! 正是打码要防的事。面板是会被人从背后看到的东西，
//! 而「我只是想找上一条」不该顺带把密码亮出来。
//!
//! # 键盘消息在消息循环里拦，不做子类化
//!
//! 焦点在搜索框上，↑↓ / ⏎ / Esc 本来会被编辑框自己吃掉。常规做法是子类化
//! 那个编辑框，但那要管一份额外的窗口过程与它的生命周期。这里改成在
//! **本窗口自己的消息循环**里先看一眼 `WM_KEYDOWN` —— 与对话框的
//! `IsDialogMessage` 是同一个套路，少一整块代码。
//!
//! # 这个模块只有 `open` 带门
//!
//! 预览、搜索匹配、行文本这些是纯逻辑，不加 `cfg(windows)` 它们的测试
//! 在开发机上也能跑 —— 而「敏感内容不能被搜出来」这类规则正是最该被测到的。

use baobox_core::clipboard::{Item, Kind};

/// 列表里一条最多显示多少个字符。
const PREVIEW_CHARS: usize = 120;

/// 用户在面板里选了什么。
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// 粘贴这一条
    Paste(String),
    /// 粘贴已经在面板里预览过的转换结果。
    PasteText(String),
    /// 收藏 / 取消收藏
    TogglePin(String),
    /// 删掉这一条
    Delete(String),
    /// 什么都没选
    Cancelled,
}

/// 这一条过不过搜索。空关键词全过。
pub fn matches(item: &Item, needle: &str) -> bool {
    if needle.is_empty() {
        return true;
    }
    // 敏感内容不参与内容搜索 —— 否则可以用搜索把打码的密码试出来
    if item.concealed {
        return item.title.to_lowercase().contains(needle);
    }
    item.text.to_lowercase().contains(needle) || item.title.to_lowercase().contains(needle)
}

/// 一条在列表里显示成什么样。
///
/// 多行内容压成一行 —— 列表里一条占三行的话，一屏就看不到几条了。
pub fn preview(item: &Item) -> String {
    let title = item.display_title();
    let flat: String = title.chars().take(PREVIEW_CHARS).collect();
    if title.chars().count() > PREVIEW_CHARS {
        format!("{flat}…")
    } else {
        flat
    }
}

/// 整行的文本：序号 + 内容 + 标签。
///
/// Win32 的列表框一行只能放一个字符串（不做自绘的话），所以三段拼在一起。
/// 前九条给个序号，配 Ctrl+数字直接选。
pub fn row_label(item: &Item, index: usize) -> String {
    let badge = if index < 9 {
        format!("{}. ", index + 1)
    } else {
        "   ".to_string()
    };
    let mut tags = Vec::new();
    if item.is_snippet() {
        tags.push("片段");
    } else if item.pinned {
        tags.push("收藏");
    }
    if item.concealed {
        tags.push("敏感");
    }
    let suffix = if tags.is_empty() {
        String::new()
    } else {
        format!("    [{}]", tags.join(" · "))
    };
    format!("{badge}{}{suffix}", preview(item))
}

fn tools_available(item: &Item) -> bool {
    !item.concealed && item.kind != Kind::Image && !item.text.trim().is_empty()
}

#[cfg(windows)]
pub use imp::open;

#[cfg(windows)]
mod imp {
    use super::*;
    use crate::clipboard_text_tools as tools;
    use baobox_core::clipboard::Store;
    use windows::core::{w, PCWSTR};
    use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
    use windows::Win32::Graphics::Gdi::*;
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::Controls::{DRAWITEMSTRUCT, ODS_SELECTED};
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        GetFocus, GetKeyState, SetFocus, VK_CONTROL,
    };
    use windows::Win32::UI::WindowsAndMessaging::*;

    /// 面板窗口类名。
    const CLASS_NAME: PCWSTR = w!("BaoboxClipboardPanel");

    /// 控件 id。低位留给系统的标准 id。
    const ID_SEARCH: i32 = 100;
    const ID_LIST: i32 = 101;
    const FIRST_FILTER: i32 = 110;
    const FIRST_TOOL: i32 = 130;
    const ID_REVERT: i32 = 136;
    const ID_BADGE: i32 = 137;
    const ACTION_Y: i32 = HEIGHT - 112;
    const PREVIEW_TOP: i32 = CONTENT_Y + 31;
    const PREVIEW_HEIGHT: i32 = ACTION_Y + 24 - PREVIEW_TOP;
    const FILTERS: [&str; 6] = ["全部", "收藏", "文本", "图片", "链接", "文件"];
    const PANEL: COLORREF = COLORREF(0x302c28);
    const FIELD: COLORREF = COLORREF(0x3a3530);
    const TEXT: COLORREF = COLORREF(0xf2eee9);
    const MUTED: COLORREF = COLORREF(0xc5b9ae);
    const BLUE: COLORREF = COLORREF(0xe47a12);
    const PREVIEW_X: i32 = 374;
    const CONTENT_Y: i32 = 58;

    /// 尺寸（96 DPI 下的基准）。
    const WIDTH: i32 = 810;
    const HEIGHT: i32 = 510;
    const MARGIN: i32 = 10;
    const SEARCH_HEIGHT: i32 = 28;
    const HINT_HEIGHT: i32 = 18;

    /// 虚拟键码。`VIRTUAL_KEY` 里有常量，但这里要和 `WPARAM` 里的原始值比，
    /// 写成 u32 更直白。
    const VK_ESCAPE: u32 = 0x1B;
    const VK_RETURN: u32 = 0x0D;
    const VK_UP: u32 = 0x26;
    const VK_DOWN: u32 = 0x28;
    const VK_P: u32 = 0x50;
    const VK_D: u32 = 0x44;
    const VK_1: u32 = 0x31;
    const VK_9: u32 = 0x39;

    /// 底下那行提示。
    const HINT_BROWSE: &str =
        "↑↓ 选择 · ⏎ 粘贴 · Esc 关闭 · Ctrl+1–9 文本操作 · Ctrl+P 收藏 · Ctrl+D 删除";

    /// 面板持有的状态。
    struct PanelState {
        /// 打开面板那一刻的历史快照。面板开着的时候不跟着变 ——
        /// 列表在用户眼皮底下重排是件很讨厌的事
        snapshot: Vec<Item>,
        /// 当前列表里显示的是哪些条目的 id
        visible: Vec<String>,
        search: HWND,
        list: HWND,
        detail: HWND,
        preview: HWND,
        metadata: HWND,
        font: HFONT,
        brush: HBRUSH,
        panel_brush: HBRUSH,
        filter: usize,
        text_tools: bool,
        image: Option<(u32, u32, Vec<u8>)>,
        buttons: [HWND; 6],
        badge: HWND,
        revert: HWND,
        selected_id: Option<String>,
        formats: Vec<baobox_core::textformat::Match>,
        active_format: usize,
        transformed: Option<(&'static str, String)>,
        qr_visible: bool,
        outcome: Outcome,
        /// 用户选完了，消息循环该退出了
        done: bool,
    }

    impl PanelState {
        /// 按关键词重建列表。
        ///
        unsafe fn refill(&mut self, needle: &str) {
            let selected = self.selected();
            SendMessageW(self.list, WM_SETREDRAW, WPARAM(0), LPARAM(0));
            SendMessageW(self.list, LB_RESETCONTENT, WPARAM(0), LPARAM(0));
            self.visible.clear();
            let mut rows: Vec<(String, String)> = Vec::new();
            let needle = needle.trim().to_lowercase();
            for item in &self.snapshot {
                let included = match self.filter {
                    1 => item.pinned || item.is_snippet(),
                    2 => item.kind == Kind::Text,
                    3 => item.kind == Kind::Image,
                    4 => item.kind == Kind::Link,
                    5 => item.kind == Kind::File,
                    _ => true,
                };
                if !included || !matches(item, &needle) {
                    continue;
                }
                let kind = match item.kind {
                    Kind::Text => "文本",
                    Kind::Link => "链接",
                    Kind::Image => "图片",
                    Kind::File => "文件",
                };
                let source = if item.source.is_empty() {
                    kind.to_owned()
                } else {
                    format!("{kind} · {}", item.source)
                };
                rows.push((
                    item.id.clone(),
                    format!("{}\n{source}", row_label(item, rows.len())),
                ));
            }
            for (id, label) in rows {
                let text = wide(&label);
                SendMessageW(
                    self.list,
                    LB_ADDSTRING,
                    WPARAM(0),
                    LPARAM(text.as_ptr() as isize),
                );
                self.visible.push(id);
            }
            let index = selected
                .and_then(|id| self.visible.iter().position(|value| *value == id))
                .unwrap_or(0);
            SendMessageW(self.list, LB_SETCURSEL, WPARAM(index), LPARAM(0));
            SendMessageW(self.list, WM_SETREDRAW, WPARAM(1), LPARAM(0));
            let _ = InvalidateRect(self.list, None, true);
            self.update_preview();
        }

        unsafe fn update_preview(&mut self) {
            let selected = self.selected();
            let item = selected
                .as_ref()
                .and_then(|id| self.snapshot.iter().find(|item| &item.id == id));
            let has_tools = self.text_tools && item.is_some_and(tools_available);
            if self.selected_id != selected {
                self.transformed = None;
                self.active_format = 0;
                self.qr_visible = false;
                self.formats = if has_tools {
                    tools::detect(&item.unwrap().text)
                } else {
                    Vec::new()
                };
                self.selected_id = selected;
            }
            self.image = None;
            let active = self.formats.get(self.active_format);
            let (title, content) = match item {
                Some(item) if item.concealed => {
                    ("预览 · 敏感内容".to_owned(), "••••••••".to_owned())
                }
                Some(item) if item.kind == Kind::Image => {
                    self.image = crate::clipboard_store::image_dir()
                        .and_then(|dir| std::fs::read(dir.join(&item.image_file)).ok())
                        .and_then(|bytes| baobox_image::decode_rgba(&bytes).ok());
                    if let Some((_, _, rgba)) = &mut self.image {
                        for pixel in rgba.chunks_exact_mut(4) {
                            pixel.swap(0, 2);
                        }
                    }
                    (
                        "预览 · 图片".to_owned(),
                        if self.image.is_none() {
                            "图片不可用".into()
                        } else {
                            String::new()
                        },
                    )
                }
                Some(item) => {
                    let kind = match item.kind {
                        Kind::Link => "链接",
                        Kind::File => "文件",
                        _ => "文本",
                    };
                    let text = self
                        .transformed
                        .as_ref()
                        .map(|(_, text)| text.as_str())
                        .or_else(|| active.and_then(|format| format.rendered.as_deref()))
                        .unwrap_or(&item.text);
                    let mut content = text.to_owned();
                    if let Some(format) = active.filter(|format| !format.rows.is_empty()) {
                        content.push_str("\n\n────────────\n");
                        for row in &format.rows {
                            use std::fmt::Write;
                            let _ = writeln!(
                                content,
                                "{}{}  {}",
                                if row.warning { "! " } else { "" },
                                row.label,
                                row.value
                            );
                        }
                    }
                    let title = self.transformed.as_ref().map_or_else(
                        || format!("预览 · {kind}"),
                        |(label, _)| format!("已转换 · {label}"),
                    );
                    (title, content.replace("\r\n", "\n").replace('\n', "\r\n"))
                }
                None => ("预览".into(), "没有匹配的剪贴板条目。".into()),
            };
            if self.qr_visible {
                if let Some(item) = item.filter(|_| has_tools) {
                    self.image = tools::qr(
                        self.transformed
                            .as_ref()
                            .map_or(item.text.as_str(), |(_, value)| value)
                            .trim(),
                    );
                }
            }
            let buttons = if has_tools {
                self.action_buttons()
            } else {
                Vec::new()
            };
            let mut x = PREVIEW_X;
            for (index, button) in self.buttons.into_iter().enumerate() {
                if let Some((label, width, _)) = buttons.get(index) {
                    let _ = SetWindowTextW(button, PCWSTR(wide(label).as_ptr()));
                    let _ = MoveWindow(button, x, ACTION_Y, *width, 26, true);
                    let _ = ShowWindow(button, SW_SHOW);
                    x += width + 5;
                } else {
                    let _ = ShowWindow(button, SW_HIDE);
                }
            }
            if let Some(format) = active {
                let label = if self.formats.len() > 1 {
                    format!("{} ▾", format.badge)
                } else {
                    format.badge.clone()
                };
                let _ = SetWindowTextW(self.badge, PCWSTR(wide(&label).as_ptr()));
            }
            let _ = ShowWindow(self.badge, if active.is_some() { SW_SHOW } else { SW_HIDE });
            let _ = ShowWindow(
                self.revert,
                if self.transformed.is_some() {
                    SW_SHOW
                } else {
                    SW_HIDE
                },
            );
            let _ = MoveWindow(
                self.preview,
                PREVIEW_X,
                PREVIEW_TOP,
                WIDTH - PREVIEW_X - 22,
                if has_tools {
                    ACTION_Y - CONTENT_Y - 39
                } else {
                    PREVIEW_HEIGHT
                },
                true,
            );
            let _ = SetWindowTextW(self.detail, PCWSTR(wide(&title).as_ptr()));
            let _ = SetWindowTextW(self.preview, PCWSTR(wide(&content).as_ptr()));
            let metadata = item.map_or_else(String::new, |item| {
                let source = if item.source.is_empty() {
                    "未知"
                } else {
                    &item.source
                };
                if item.concealed || item.kind == Kind::Image {
                    format!("来源  {source}")
                } else {
                    format!("来源  {source}    ·    {} 字符", item.text.chars().count())
                }
            });
            let _ = SetWindowTextW(self.metadata, PCWSTR(wide(&metadata).as_ptr()));
            let _ = ShowWindow(
                self.preview,
                if self.image.is_some() {
                    SW_HIDE
                } else {
                    SW_SHOW
                },
            );
            if let Ok(parent) = GetParent(self.detail) {
                let bounds = RECT {
                    left: PREVIEW_X,
                    top: PREVIEW_TOP,
                    right: WIDTH - 22,
                    bottom: HEIGHT - 72,
                };
                let _ = InvalidateRect(parent, Some(&bounds), false);
                for index in 0..FILTERS.len() {
                    if let Ok(button) = GetDlgItem(parent, FIRST_FILTER + index as i32) {
                        let _ = InvalidateRect(button, None, false);
                    }
                }
            }
        }

        fn format_actions(&self) -> &'static [tools::Action] {
            self.formats
                .get(self.active_format)
                .map_or(&[], tools::format_actions)
        }

        fn action_buttons(&self) -> Vec<(String, i32, &'static [tools::Action])> {
            let mut buttons = Vec::new();
            if let Some(format) = self.formats.get(self.active_format) {
                let actions = self.format_actions();
                if matches!(format.badge.as_str(), "JSON" | "URL" | "cURL") {
                    buttons.push((format!("{} ▾", format.badge), 67, actions));
                } else {
                    for action in actions {
                        buttons.push((
                            action.title.to_owned(),
                            if format.id == "jwt" { 83 } else { 55 },
                            std::slice::from_ref(action),
                        ));
                    }
                }
            }
            buttons.push(("编码/解码 ▾".into(), 83, tools::ENCODING));
            for (action, width) in tools::COMMON.iter().zip([54, 43, 43]) {
                buttons.push((action.title.to_owned(), width, std::slice::from_ref(action)));
            }
            buttons
        }

        fn keyboard_action(&self, index: usize) -> Option<tools::Action> {
            if !self.text_tools
                || !self.selected_id.as_ref().is_some_and(|id| {
                    self.snapshot
                        .iter()
                        .any(|item| &item.id == id && tools_available(item))
                })
            {
                return None;
            }
            self.format_actions()
                .iter()
                .chain(tools::ENCODING)
                .chain(tools::COMMON)
                .nth(index)
                .copied()
        }

        unsafe fn run_tool(&mut self, action: tools::Action) {
            let Some(item) = self
                .selected_id
                .as_ref()
                .and_then(|id| self.snapshot.iter().find(|item| &item.id == id))
                .filter(|item| self.text_tools && tools_available(item))
            else {
                return;
            };
            let text = self
                .transformed
                .as_ref()
                .map_or(item.text.as_str(), |(_, value)| value)
                .trim();
            match action.id {
                "qr" => {
                    if !self.qr_visible && tools::qr(text).is_none() {
                        MessageBoxW(
                            GetParent(self.list).unwrap_or_default(),
                            w!("文本太长，无法生成二维码。"),
                            w!("二维码"),
                            MB_OK,
                        );
                        return;
                    }
                    self.qr_visible = !self.qr_visible;
                }
                "pin" | "edit" => {
                    let result = if action.id == "pin" {
                        crate::clipboard_text_window::pin(text)
                    } else {
                        crate::clipboard_text_window::edit(text)
                    };
                    match result {
                        Ok(()) if action.id == "edit" => self.done = true,
                        Ok(()) => {}
                        Err(error) => {
                            MessageBoxW(
                                GetParent(self.list).unwrap_or_default(),
                                PCWSTR(wide(&error).as_ptr()),
                                w!("剪贴板"),
                                MB_OK,
                            );
                        }
                    }
                    return;
                }
                _ => {
                    let Some(result) = tools::transform(action.id, text) else {
                        return;
                    };
                    self.transformed = Some((action.title, result));
                    self.qr_visible = false;
                }
            }
            self.update_preview();
            let _ = SetFocus(self.search);
        }

        unsafe fn tool_button(&mut self, index: usize) {
            let buttons = self.action_buttons();
            let Some((_, _, actions)) = buttons.get(index) else {
                return;
            };
            if let [action] = *actions {
                self.run_tool(*action);
                return;
            }
            let offset: usize = buttons[..index]
                .iter()
                .map(|(_, _, actions)| actions.len())
                .sum();
            let labels = actions
                .iter()
                .enumerate()
                .map(|(i, action)| {
                    (
                        action.title.to_owned(),
                        (i + offset < 9).then(|| format!("Ctrl+{}", i + offset + 1)),
                    )
                })
                .collect::<Vec<_>>();
            if let Some(choice) = popup_choice(self.buttons[index], &labels) {
                self.run_tool(actions[choice]);
            }
        }

        unsafe fn copy_preview(&self) -> bool {
            use windows::Win32::UI::Controls::EM_GETSEL;
            let focus = GetFocus();
            if focus == self.preview || focus == self.search {
                let mut start = 0u32;
                let mut end = 0u32;
                SendMessageW(
                    focus,
                    EM_GETSEL,
                    WPARAM(&mut start as *mut u32 as usize),
                    LPARAM(&mut end as *mut u32 as isize),
                );
                if start != end {
                    return false;
                }
            }
            let Some(item) = self
                .selected_id
                .as_ref()
                .and_then(|id| self.snapshot.iter().find(|item| &item.id == id))
                .filter(|item| tools_available(item))
            else {
                return false;
            };
            let text = self
                .transformed
                .as_ref()
                .map(|(_, value)| value.as_str())
                .or_else(|| {
                    self.formats
                        .get(self.active_format)
                        .and_then(|format| format.rendered.as_deref())
                })
                .unwrap_or(&item.text);
            let _ = crate::clipboard_module::copy_preview_text(text);
            true
        }

        /// 当前选中的是哪一条。
        unsafe fn selected(&self) -> Option<String> {
            let index = SendMessageW(self.list, LB_GETCURSEL, WPARAM(0), LPARAM(0)).0;
            if index < 0 {
                return None;
            }
            self.visible.get(index as usize).cloned()
        }

        /// 定下结果并让消息循环退出。
        unsafe fn finish(&mut self, make: fn(String) -> Outcome) {
            let Some(id) = self.selected() else { return };
            self.outcome = match (make(id), &self.transformed) {
                (Outcome::Paste(_), Some((_, text))) => Outcome::PasteText(text.clone()),
                (outcome, _) => outcome,
            };
            self.done = true;
        }

        /// ↑↓ 换一行。列表不在焦点上（焦点在搜索框），所以要自己算。
        unsafe fn move_selection(&mut self, down: bool) {
            let current = SendMessageW(self.list, LB_GETCURSEL, WPARAM(0), LPARAM(0)).0;
            let next = if down { current + 1 } else { current - 1 };
            if next < 0 || next as usize >= self.visible.len() {
                return;
            }
            SendMessageW(self.list, LB_SETCURSEL, WPARAM(next as usize), LPARAM(0));
            self.update_preview();
        }
    }

    /// 打开面板，阻塞到用户选完或关掉。
    ///
    /// 必须在有消息循环的那条线程上调用（App 只有一条线程，见 `app.rs`）。
    pub fn open(store: &Store, text_tools: bool) -> Outcome {
        unsafe {
            let Ok(module) = GetModuleHandleW(None) else {
                return Outcome::Cancelled;
            };
            let instance: HINSTANCE = module.into();
            let class = WNDCLASSW {
                lpfnWndProc: Some(wndproc),
                hInstance: instance,
                lpszClassName: CLASS_NAME,
                hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
                ..Default::default()
            };
            RegisterClassW(&class);

            // 摆在主屏中央 —— 用户按下快捷键时眼睛在哪并不好猜，居中最不容易找不着
            let x = (GetSystemMetrics(SM_CXSCREEN) - WIDTH) / 2;
            let y = (GetSystemMetrics(SM_CYSCREEN) - HEIGHT) / 2;
            let Ok(hwnd) = CreateWindowExW(
                WS_EX_TOPMOST,
                CLASS_NAME,
                w!("剪贴板"),
                WS_POPUP | WS_CAPTION | WS_SYSMENU | WS_CLIPCHILDREN,
                x.max(0),
                y.max(0),
                WIDTH,
                HEIGHT,
                None,
                None,
                instance,
                None,
            ) else {
                let _ = UnregisterClassW(CLASS_NAME, instance);
                return Outcome::Cancelled;
            };

            let dark = 1i32;
            use windows::Win32::Graphics::Dwm::{
                DwmSetWindowAttribute, DWMWA_USE_IMMERSIVE_DARK_MODE,
            };
            let _ = DwmSetWindowAttribute(
                hwnd,
                DWMWA_USE_IMMERSIVE_DARK_MODE,
                (&dark as *const i32).cast(),
                4,
            );
            let font = crate::settings_window::settings_font(-15, 400);
            let metadata_font = crate::settings_window::settings_font(-12, 400);
            let brush = CreateSolidBrush(FIELD);
            let panel_brush = CreateSolidBrush(PANEL);
            let search = child(
                hwnd,
                instance,
                w!("EDIT"),
                "",
                (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | ES_AUTOHSCROLL as u32,
                36,
                12,
                292,
                SEARCH_HEIGHT,
                ID_SEARCH,
                font,
            );
            child(
                hwnd,
                instance,
                w!("STATIC"),
                "⌕",
                (WS_CHILD | WS_VISIBLE).0,
                MARGIN,
                12,
                25,
                SEARCH_HEIGHT,
                0,
                font,
            );
            use windows::Win32::UI::Controls::{SetWindowTheme, EM_SETCUEBANNER};
            SendMessageW(
                search,
                EM_SETCUEBANNER,
                WPARAM(1),
                LPARAM(w!("搜索历史").0 as isize),
            );
            for (index, label) in FILTERS.iter().enumerate() {
                child(
                    hwnd,
                    instance,
                    w!("BUTTON"),
                    label,
                    (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | BS_OWNERDRAW as u32,
                    355 + index as i32 * 71,
                    12,
                    65,
                    SEARCH_HEIGHT,
                    FIRST_FILTER + index as i32,
                    font,
                );
            }
            let list = child(
                hwnd,
                instance,
                w!("LISTBOX"),
                "",
                (WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_VSCROLL).0
                    | (LBS_NOTIFY | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | LBS_NOINTEGRALHEIGHT)
                        as u32,
                MARGIN,
                CONTENT_Y,
                PREVIEW_X - 25,
                HEIGHT - 132,
                ID_LIST,
                font,
            );
            SendMessageW(list, LB_SETITEMHEIGHT, WPARAM(0), LPARAM(44));
            let detail = child(
                hwnd,
                instance,
                w!("STATIC"),
                "预览",
                (WS_CHILD | WS_VISIBLE).0,
                PREVIEW_X,
                CONTENT_Y,
                WIDTH - PREVIEW_X - 22,
                25,
                0,
                font,
            );
            let preview = child(
                hwnd,
                instance,
                w!("EDIT"),
                "",
                (WS_CHILD | WS_VISIBLE | WS_VSCROLL).0
                    | (ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL) as u32,
                PREVIEW_X,
                PREVIEW_TOP,
                WIDTH - PREVIEW_X - 22,
                PREVIEW_HEIGHT,
                0,
                font,
            );
            let _ = SetWindowTheme(list, w!("DarkMode_Explorer"), None);
            let _ = SetWindowTheme(preview, w!("DarkMode_Explorer"), None);
            use windows::Win32::UI::Controls::EM_SETMARGINS;
            SendMessageW(
                preview,
                EM_SETMARGINS,
                WPARAM((EC_LEFTMARGIN | EC_RIGHTMARGIN) as usize),
                LPARAM(10 | (10 << 16)),
            );
            let metadata = child(
                hwnd,
                instance,
                w!("STATIC"),
                "",
                (WS_CHILD | WS_VISIBLE).0,
                PREVIEW_X,
                ACTION_Y + 30,
                WIDTH - PREVIEW_X - 22,
                16,
                0,
                metadata_font,
            );
            child(
                hwnd,
                instance,
                w!("STATIC"),
                HINT_BROWSE,
                (WS_CHILD | WS_VISIBLE).0,
                MARGIN,
                HEIGHT - 61,
                WIDTH - 32,
                HINT_HEIGHT,
                0,
                font,
            );
            let tool_button = |label, x, y, width, id| {
                let button = child(
                    hwnd,
                    instance,
                    w!("BUTTON"),
                    label,
                    (WS_CHILD | WS_TABSTOP).0 | BS_OWNERDRAW as u32,
                    x,
                    y,
                    width,
                    26,
                    id,
                    font,
                );
                crate::screenshot_preview::style_button(button);
                button
            };
            let buttons = [
                tool_button("格式 ▾", PREVIEW_X, ACTION_Y, 73, FIRST_TOOL),
                tool_button("编码/解码 ▾", PREVIEW_X + 79, ACTION_Y, 101, FIRST_TOOL + 1),
                tool_button("二维码", PREVIEW_X + 186, ACTION_Y, 64, FIRST_TOOL + 2),
                tool_button("钉住", PREVIEW_X + 256, ACTION_Y, 61, FIRST_TOOL + 3),
                tool_button("编辑", PREVIEW_X + 323, ACTION_Y, 61, FIRST_TOOL + 4),
                tool_button("", PREVIEW_X, ACTION_Y, 61, FIRST_TOOL + 5),
            ];
            let badge = tool_button("", PREVIEW_X + 153, CONTENT_Y - 2, 82, ID_BADGE);
            let revert = tool_button("恢复原文", WIDTH - 108, CONTENT_Y - 2, 82, ID_REVERT);
            let mut state = Box::new(PanelState {
                snapshot: store.items().to_vec(),
                visible: Vec::new(),
                search,
                list,
                detail,
                preview,
                metadata,
                font,
                brush,
                panel_brush,
                filter: 0,
                text_tools,
                image: None,
                buttons,
                badge,
                revert,
                selected_id: None,
                formats: Vec::new(),
                active_format: 0,
                transformed: None,
                qr_visible: false,
                outcome: Outcome::Cancelled,
                done: false,
            });
            state.refill("");
            SetWindowLongPtrW(
                hwnd,
                GWLP_USERDATA,
                state.as_mut() as *mut PanelState as isize,
            );

            let _ = SetWindowPos(
                hwnd,
                HWND_TOPMOST,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW,
            );
            // 面板是快捷键唤起的，不抢前台的话它会开在别人后面
            let _ = SetForegroundWindow(hwnd);
            let _ = SetFocus(search);

            let mut message = MSG::default();
            while GetMessageW(&mut message, None, 0, 0).as_bool() {
                // 焦点在搜索框上，↑↓ / ⏎ / Esc 本来会被它自己吃掉，
                // 所以在派发之前先看一眼
                if message.message == WM_KEYDOWN
                    && (message.hwnd == hwnd || IsChild(hwnd, message.hwnd).as_bool())
                    && handle_key(&mut state, message.wParam.0 as u32)
                {
                    if state.done {
                        break;
                    }
                    continue;
                }
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
                if state.done {
                    break;
                }
            }

            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            let _ = DestroyWindow(hwnd);
            if !font.is_invalid() {
                let _ = windows::Win32::Graphics::Gdi::DeleteObject(font);
            }
            let _ = UnregisterClassW(CLASS_NAME, instance);
            let _ = DeleteObject(brush);
            let _ = DeleteObject(panel_brush);
            let _ = DeleteObject(metadata_font);
            std::mem::replace(&mut state.outcome, Outcome::Cancelled)
        }
    }

    /// 拦下来一个按键。返回 `true` 表示已经处理，不要再派发下去。
    unsafe fn handle_key(state: &mut PanelState, key: u32) -> bool {
        let ctrl = GetKeyState(VK_CONTROL.0 as i32) < 0;
        match key {
            VK_ESCAPE => {
                state.outcome = Outcome::Cancelled;
                state.done = true;
                true
            }
            VK_RETURN => {
                state.finish(Outcome::Paste);
                true
            }
            VK_UP => {
                state.move_selection(false);
                true
            }
            VK_DOWN => {
                state.move_selection(true);
                true
            }
            VK_P if ctrl => {
                state.finish(Outcome::TogglePin);
                true
            }
            VK_D if ctrl => {
                state.finish(Outcome::Delete);
                true
            }
            0x43 if ctrl => state.copy_preview(),
            digit if ctrl && (VK_1..=VK_9).contains(&digit) => {
                let index = (digit - VK_1) as usize;
                if let Some(action) = state.keyboard_action(index) {
                    state.run_tool(action);
                } else if !state.text_tools && index < state.visible.len() {
                    SendMessageW(state.list, LB_SETCURSEL, WPARAM(index), LPARAM(0));
                    state.update_preview();
                    state.finish(Outcome::Paste);
                }
                true
            }
            _ => false,
        }
    }

    unsafe extern "system" fn wndproc(
        hwnd: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        if let Some(result) = crate::tray::paint_menu(message, lparam) {
            return result;
        }
        let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut PanelState;
        if pointer.is_null() {
            return DefWindowProcW(hwnd, message, wparam, lparam);
        }
        let state = &mut *pointer;

        match message {
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let mut paint = PAINTSTRUCT::default();
                let dc = BeginPaint(hwnd, &mut paint);
                paint_panel(dc, state, paint.rcPaint);
                let _ = EndPaint(hwnd, &paint);
                LRESULT(0)
            }
            WM_CTLCOLORSTATIC | WM_CTLCOLOREDIT | WM_CTLCOLORLISTBOX => {
                let dc = HDC(wparam.0 as _);
                let control = HWND(lparam.0 as _);
                if message == WM_CTLCOLORSTATIC && control != state.preview {
                    SetTextColor(dc, MUTED);
                    SetBkColor(dc, PANEL);
                    LRESULT(state.panel_brush.0 as isize)
                } else {
                    SetTextColor(dc, TEXT);
                    SetBkColor(dc, FIELD);
                    LRESULT(state.brush.0 as isize)
                }
            }
            WM_DRAWITEM => {
                let item = &*(lparam.0 as *const DRAWITEMSTRUCT);
                draw_item(item, state);
                LRESULT(1)
            }
            WM_COMMAND => {
                let id = (wparam.0 & 0xFFFF) as i32;
                let code = ((wparam.0 >> 16) & 0xFFFF) as u32;
                if id == ID_SEARCH && code == EN_CHANGE {
                    let needle = window_text(state.search);
                    state.refill(&needle);
                } else if (FIRST_FILTER..FIRST_FILTER + FILTERS.len() as i32).contains(&id)
                    && code == BN_CLICKED
                {
                    state.filter = (id - FIRST_FILTER) as usize;
                    state.refill(&window_text(state.search));
                    let _ = SetFocus(state.search);
                } else if id == ID_LIST && code == LBN_SELCHANGE {
                    state.update_preview();
                } else if id == ID_LIST && code == LBN_DBLCLK {
                    state.finish(Outcome::Paste);
                } else if (FIRST_TOOL..FIRST_TOOL + 6).contains(&id)
                    && matches!(code, BN_CLICKED | BN_DOUBLECLICKED)
                {
                    state.tool_button((id - FIRST_TOOL) as usize);
                } else if id == ID_REVERT && code == BN_CLICKED {
                    state.transformed = None;
                    state.qr_visible = false;
                    state.update_preview();
                    let _ = SetFocus(state.search);
                } else if id == ID_BADGE && code == BN_CLICKED && state.formats.len() > 1 {
                    let labels = state
                        .formats
                        .iter()
                        .map(|format| (format.badge.clone(), None))
                        .collect::<Vec<_>>();
                    if let Some(index) = popup_choice(state.badge, &labels) {
                        state.active_format = index;
                        state.update_preview();
                    }
                }
                LRESULT(0)
            }
            WM_CLOSE => {
                // 用户点了标题栏上的关闭按钮：什么都没选
                state.done = true;

                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, message, wparam, lparam),
        }
    }

    unsafe fn popup_choice(anchor: HWND, labels: &[(String, Option<String>)]) -> Option<usize> {
        let mut bounds = RECT::default();
        let _ = GetWindowRect(anchor, &mut bounds);
        let owner = GetParent(anchor).ok().unwrap_or(anchor);
        crate::tray::popup_text_actions(owner, bounds.left, bounds.bottom + 3, labels)
    }

    unsafe fn paint_panel(dc: HDC, state: &PanelState, paint: RECT) {
        let background = CreateSolidBrush(PANEL);
        FillRect(dc, &paint, background);
        let _ = DeleteObject(background);
        let divider = CreateSolidBrush(COLORREF(0x534b45));
        for bounds in [
            RECT {
                left: 0,
                top: 48,
                right: WIDTH,
                bottom: 49,
            },
            RECT {
                left: PREVIEW_X - 8,
                top: 49,
                right: PREVIEW_X - 7,
                bottom: HEIGHT - 71,
            },
            RECT {
                left: 0,
                top: HEIGHT - 71,
                right: WIDTH,
                bottom: HEIGHT - 70,
            },
        ] {
            FillRect(dc, &bounds, divider);
        }
        let _ = DeleteObject(divider);
        if let Some((width, height, pixels)) = &state.image {
            let area_w = WIDTH - PREVIEW_X - 22;
            let area_h = if state.qr_visible {
                ACTION_Y - CONTENT_Y - 39
            } else {
                PREVIEW_HEIGHT
            };
            let scale = (area_w as f64 / *width as f64)
                .min(area_h as f64 / *height as f64)
                .min(1.0);
            let w = (*width as f64 * scale).round() as i32;
            let h = (*height as f64 * scale).round() as i32;
            let info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: *width as i32,
                    biHeight: -(*height as i32),
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            SetStretchBltMode(dc, HALFTONE);
            StretchDIBits(
                dc,
                PREVIEW_X + (area_w - w) / 2,
                PREVIEW_TOP + (area_h - h) / 2,
                w,
                h,
                0,
                0,
                *width as i32,
                *height as i32,
                Some(pixels.as_ptr().cast()),
                &info,
                DIB_RGB_COLORS,
                SRCCOPY,
            );
        }
    }

    unsafe fn draw_item(item: &DRAWITEMSTRUCT, state: &PanelState) {
        if (FIRST_TOOL as u32..=ID_BADGE as u32).contains(&item.CtlID) {
            crate::screenshot_preview::draw_button(
                LPARAM(item as *const DRAWITEMSTRUCT as isize),
                item.CtlID == ID_BADGE as u32,
                PANEL,
            );
            return;
        }
        let mut bounds = item.rcItem;
        let dc = item.hDC;
        FillRect(dc, &bounds, state.brush);
        let old = SelectObject(dc, state.font);
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, TEXT);
        let flags = DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX;
        if item.CtlID == ID_LIST as u32 {
            if item.itemID != u32::MAX {
                if item.itemState.0 & ODS_SELECTED.0 != 0 {
                    crate::settings_window::rounded(dc, bounds, 10, BLUE, BLUE);
                }
                let len = SendMessageW(
                    item.hwndItem,
                    LB_GETTEXTLEN,
                    WPARAM(item.itemID as usize),
                    LPARAM(0),
                )
                .0;
                if len >= 0 {
                    let mut text = vec![0; len as usize + 1];
                    SendMessageW(
                        item.hwndItem,
                        LB_GETTEXT,
                        WPARAM(item.itemID as usize),
                        LPARAM(text.as_mut_ptr() as isize),
                    );
                    let separator = text[..len as usize]
                        .iter()
                        .position(|ch| *ch == 10)
                        .unwrap_or(len as usize);
                    bounds.left += 11;
                    bounds.right -= 9;
                    let mut title = RECT {
                        bottom: bounds.top + 24,
                        ..bounds
                    };
                    DrawTextW(dc, &mut text[..separator], &mut title, flags);
                    if separator < len as usize {
                        bounds.top += 22;
                        SetTextColor(
                            dc,
                            if item.itemState.0 & ODS_SELECTED.0 != 0 {
                                TEXT
                            } else {
                                MUTED
                            },
                        );
                        DrawTextW(
                            dc,
                            &mut text[separator + 1..len as usize],
                            &mut bounds,
                            flags,
                        );
                    }
                }
            }
        } else if let Some(index) = item
            .CtlID
            .checked_sub(FIRST_FILTER as u32)
            .map(|id| id as usize)
            .filter(|id| *id < FILTERS.len())
        {
            let color = if state.filter == index { BLUE } else { FIELD };
            crate::settings_window::rounded(dc, bounds, 25, color, color);
            let mut label: Vec<u16> = FILTERS[index].encode_utf16().collect();
            DrawTextW(dc, &mut label, &mut bounds, flags | DT_CENTER);
        }
        SelectObject(dc, old);
    }
    #[allow(clippy::too_many_arguments)]
    unsafe fn child(
        parent: HWND,
        instance: HINSTANCE,
        class: PCWSTR,
        text: &str,
        style: u32,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        id: i32,
        font: HFONT,
    ) -> HWND {
        let label = wide(text);
        let hwnd = CreateWindowExW(
            Default::default(),
            class,
            PCWSTR(label.as_ptr()),
            windows::Win32::UI::WindowsAndMessaging::WINDOW_STYLE(style),
            x,
            y,
            width,
            height,
            parent,
            windows::Win32::UI::WindowsAndMessaging::HMENU(id as isize as *mut _),
            instance,
            None,
        )
        .unwrap_or_default();
        // 不设字体的话控件会用上世纪的 System 字体，与整个系统格格不入
        SendMessageW(hwnd, WM_SETFONT, WPARAM(font.0 as usize), LPARAM(1));
        hwnd
    }

    unsafe fn window_text(hwnd: HWND) -> String {
        let length = GetWindowTextLengthW(hwnd);
        if length <= 0 {
            return String::new();
        }
        let mut buffer = vec![0u16; length as usize + 1];
        let copied = GetWindowTextW(hwnd, &mut buffer);
        String::from_utf16_lossy(&buffer[..copied.max(0) as usize])
    }

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(std::iter::once(0)).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(text: &str) -> Item {
        Item::text("id", text, 0)
    }

    #[test]
    fn long_content_is_truncated_for_the_list() {
        let long = "x".repeat(PREVIEW_CHARS * 2);
        let shown = preview(&item(&long));
        assert!(shown.chars().count() <= PREVIEW_CHARS + 1);
        assert!(shown.ends_with('…'));
    }

    #[test]
    fn multiline_content_collapses_to_its_first_line() {
        // 列表里一条占三行的话，一屏就看不到几条了
        let shown = preview(&item("第一行\n第二行\n第三行"));
        assert!(!shown.contains('\n'));
        assert_eq!(shown, "第一行");
    }

    #[test]
    fn concealed_items_never_show_their_content() {
        let mut secret = item("hunter2");
        secret.concealed = true;
        assert!(!preview(&secret).contains("hunter"));
        assert!(!row_label(&secret, 0).contains("hunter"));
    }

    #[test]
    fn search_cannot_be_used_to_fish_out_concealed_content() {
        let mut secret = item("hunter2");
        secret.concealed = true;
        secret.title = "密码".into();
        assert!(!matches(&secret, "hunter"), "打码的内容不能被搜出来");
        assert!(matches(&secret, "密码"), "标题仍可搜");
        assert!(matches(&secret, ""), "空关键词照样列出来");
    }

    #[test]
    fn ordinary_items_are_searchable_by_content() {
        assert!(matches(&item("Hello World"), "hello"));
        assert!(!matches(&item("Hello World"), "nope"));
    }

    #[test]
    fn the_first_nine_rows_are_numbered_for_the_ctrl_digit_shortcut() {
        assert!(row_label(&item("x"), 0).starts_with("1."));
        assert!(row_label(&item("x"), 8).starts_with("9."));
        // 第十条之后没有对应的快捷键，也就不该编号
        assert!(!row_label(&item("x"), 9).starts_with("10"));
    }

    #[test]
    fn the_text_tools_refuse_to_open_on_concealed_content() {
        // 那一层会把内容拆开摆出来，正是打码要防的事
        let mut secret = item(r#"{"password":"hunter2"}"#);
        secret.concealed = true;
        assert!(!tools_available(&secret));
    }

    #[test]
    fn the_text_tools_refuse_to_open_on_images_and_empty_entries() {
        let mut image = item("");
        image.kind = Kind::Image;
        image.image_file = "a.png".into();
        assert!(!tools_available(&image));
        assert!(!tools_available(&item("   ")));
    }

    #[test]
    fn the_text_tools_open_on_ordinary_text_and_recognise_json() {
        let item = item(r#"{"a":1}"#);
        assert!(tools_available(&item));
        let formats = crate::clipboard_text_tools::detect(&item.text);
        assert!(crate::clipboard_text_tools::format_actions(&formats[0])
            .iter()
            .any(|action| action.id == "json.pretty"));
    }

    #[test]
    fn pinned_and_snippet_rows_are_labelled_the_same_way_as_on_linux() {
        let mut pinned = item("x");
        pinned.pinned = true;
        assert!(row_label(&pinned, 0).contains("收藏"));

        let mut secret = item("x");
        secret.concealed = true;
        assert!(row_label(&secret, 0).contains("敏感"));
    }
}
