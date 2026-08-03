//! 剪贴板面板（Windows）：搜一下、选一条、回车粘出去。
//!
//! 与 Linux 的 GTK 版是同一件事的两种画法，**交互规则逐条对齐**：
//!
//! - 面板一出来焦点就在搜索框，直接打字就是搜
//! - ↑↓ 选，⏎ 粘贴，Esc 关掉
//! - Ctrl+1–9 直接选中对应的那条；Ctrl+P 收藏，Ctrl+D 删除
//!
//! # 两层：条目 → 文本工具
//!
//! Ctrl+T 把列表切成第二层：这段文字被认成了什么（JSON / JWT / 时间戳 / URL…）、
//! 能拿它做什么（格式化、解码、转大小写…）。选中一个动作按 ⏎，
//! 就把**转换后的结果**粘出去。再按 Esc 退回第一层。
//!
//! macOS 版那块预览区能自由排版（徽章一行、表格一块、按钮一排），
//! 这里只有一个列表控件，所以压成一张平表 —— 压平的规则在
//! `baobox_core::textformat::action_list`，两个平台共用一份。
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
use baobox_core::textformat;

/// 列表里一条最多显示多少个字符。
const PREVIEW_CHARS: usize = 120;

/// 用户在面板里选了什么。
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// 粘贴这一条
    Paste(String),
    /// 把这一条转换之后再粘贴（条目 id，动作 id）
    Transform(String, String),
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

/// 这一条能进文本工具那一层吗；能的话给出该显示的内容。
///
/// 图片没有文字可分析；**打码的内容一律不进** —— 那一层会把内容拆开摆出来，
/// 正是打码要防的事。规则与 Linux 侧逐条相同。
pub fn tools_for(item: &Item) -> Option<Vec<textformat::Entry>> {
    if item.concealed || item.kind == Kind::Image || item.text.trim().is_empty() {
        return None;
    }
    let entries = textformat::action_list(&item.text);
    if entries.is_empty() {
        return None;
    }
    Some(entries)
}

/// 文本工具那一层里，一条显示成什么样。
///
/// 说明行前面加一个点号，动作行不加 —— 只有一个列表控件、没有字重可用时，
/// 这是让用户一眼看出「哪些能按」的最省事的办法。
pub fn tool_row_label(entry: &textformat::Entry) -> String {
    if entry.action.is_empty() {
        let mark = if entry.warning { "!" } else { "·" };
        format!("   {mark} {}", entry.label)
    } else {
        format!("→ {}", entry.label)
    }
}

#[cfg(windows)]
pub use imp::open;

#[cfg(windows)]
mod imp {
    use super::*;
    use baobox_core::clipboard::Store;
    use windows::core::{w, PCWSTR};
    use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
    use windows::Win32::Graphics::Gdi::HFONT;
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetKeyState, SetFocus, VK_CONTROL};
    use windows::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetMessageW,
        GetSystemMetrics, GetWindowLongPtrW, GetWindowTextLengthW, GetWindowTextW, LoadCursorW,
        PostQuitMessage, RegisterClassW, SendMessageW, SetForegroundWindow,
        SetWindowLongPtrW, ShowWindow, TranslateMessage, UnregisterClassW, EN_CHANGE,
        ES_AUTOHSCROLL, GWLP_USERDATA, IDC_ARROW, LBN_DBLCLK, LBS_NOTIFY, LB_ADDSTRING,
        LB_GETCURSEL, LB_RESETCONTENT, LB_SETCURSEL, MSG, SM_CXSCREEN, SM_CYSCREEN, SW_SHOW,
        WM_COMMAND, WM_DESTROY, WM_KEYDOWN, WM_SETFONT, WNDCLASSW, WS_BORDER, WS_CAPTION, WS_CHILD,
        WS_EX_TOPMOST, WS_POPUP, WS_SYSMENU, WS_TABSTOP, WS_VISIBLE, WS_VSCROLL,
    };

    /// 面板窗口类名。
    const CLASS_NAME: PCWSTR = w!("BaoboxClipboardPanel");

    /// 控件 id。低位留给系统的标准 id。
    const ID_SEARCH: i32 = 100;
    const ID_LIST: i32 = 101;

    /// 尺寸（96 DPI 下的基准）。
    const WIDTH: i32 = 560;
    const HEIGHT: i32 = 460;
    const MARGIN: i32 = 10;
    const SEARCH_HEIGHT: i32 = 24;
    const HINT_HEIGHT: i32 = 18;

    /// 虚拟键码。`VIRTUAL_KEY` 里有常量，但这里要和 `WPARAM` 里的原始值比，
    /// 写成 u32 更直白。
    const VK_ESCAPE: u32 = 0x1B;
    const VK_RETURN: u32 = 0x0D;
    const VK_UP: u32 = 0x26;
    const VK_DOWN: u32 = 0x28;
    const VK_P: u32 = 0x50;
    const VK_D: u32 = 0x44;
    const VK_T: u32 = 0x54;
    const VK_1: u32 = 0x31;
    const VK_9: u32 = 0x39;

    /// 底下那行提示。
    const HINT_BROWSE: &str =
        "↑↓ 选择 · ⏎ 粘贴 · Esc 关闭 · Ctrl+1–9 直接选 · Ctrl+T 文本工具 · Ctrl+P 收藏 · Ctrl+D 删除";
    const HINT_TOOLS: &str = "↑↓ 选择 · ⏎ 转换后粘贴 · Esc 返回";

    /// 列表现在显示的是哪一层。
    enum Mode {
        /// 历史条目
        Browse,
        /// 某一条的文本工具
        Tools {
            item: String,
            entries: Vec<textformat::Entry>,
        },
    }

    /// 面板持有的状态。
    struct PanelState {
        /// 打开面板那一刻的历史快照。面板开着的时候不跟着变 ——
        /// 列表在用户眼皮底下重排是件很讨厌的事
        snapshot: Vec<Item>,
        /// 当前列表里显示的是哪些条目的 id
        visible: Vec<String>,
        search: HWND,
        list: HWND,
        hint: HWND,
        /// 列表现在显示的是哪一层
        mode: Mode,
        outcome: Outcome,
        /// 用户选完了，消息循环该退出了
        done: bool,
    }

    impl PanelState {
        /// 按关键词重建列表。
        ///
        /// `visible` 里放的东西随层而变：第一层是条目 id，第二层是动作 id
        /// （说明行放空串）。
        unsafe fn refill(&mut self, needle: &str) {
            SendMessageW(self.list, LB_RESETCONTENT, WPARAM(0), LPARAM(0));
            self.visible.clear();
            let mut rows: Vec<(String, String)> = Vec::new();
            match &self.mode {
                Mode::Browse => {
                    let needle = needle.trim().to_lowercase();
                    for item in &self.snapshot {
                        if !matches(item, &needle) {
                            continue;
                        }
                        rows.push((item.id.clone(), row_label(item, rows.len())));
                    }
                }
                // 第二层不参与搜索：那一层就十来行，搜反而碍事
                Mode::Tools { entries, .. } => {
                    for entry in entries {
                        rows.push((entry.action.to_string(), tool_row_label(entry)));
                    }
                }
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
            // 重建之后总是选中第一条，⏎ 才有东西可粘
            SendMessageW(self.list, LB_SETCURSEL, WPARAM(0), LPARAM(0));
        }

        /// Ctrl+T：进 / 出文本工具那一层。
        unsafe fn toggle_tools(&mut self) {
            let next = match &self.mode {
                Mode::Tools { .. } => Mode::Browse,
                Mode::Browse => {
                    let Some(id) = self.selected() else { return };
                    let Some(item) = self.snapshot.iter().find(|e| e.id == id) else {
                        return;
                    };
                    // 图片、打码的内容、认不出任何动作的：留在第一层
                    let Some(entries) = tools_for(item) else { return };
                    Mode::Tools { item: id, entries }
                }
            };
            let browsing = matches!(next, Mode::Browse);
            self.mode = next;
            let hint = wide(if browsing { HINT_BROWSE } else { HINT_TOOLS });
            let _ = windows::Win32::UI::WindowsAndMessaging::SetWindowTextW(
                self.hint,
                PCWSTR(hint.as_ptr()),
            );
            let needle = window_text(self.search);
            self.refill(&needle);
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
            self.outcome = match &self.mode {
                Mode::Browse => make(id),
                Mode::Tools { item, .. } => {
                    // 说明行选中了也不做事；收藏 / 删除是针对条目的，第二层不给
                    if id.is_empty() {
                        return;
                    }
                    Outcome::Transform(item.clone(), id)
                }
            };
            self.done = true;
        }

        /// ↑↓ 换一行。列表不在焦点上（焦点在搜索框），所以要自己算。
        unsafe fn move_selection(&self, down: bool) {
            let current = SendMessageW(self.list, LB_GETCURSEL, WPARAM(0), LPARAM(0)).0;
            let next = if down { current + 1 } else { current - 1 };
            if next < 0 || next as usize >= self.visible.len() {
                return;
            }
            SendMessageW(self.list, LB_SETCURSEL, WPARAM(next as usize), LPARAM(0));
        }
    }

    /// 打开面板，阻塞到用户选完或关掉。
    ///
    /// 必须在有消息循环的那条线程上调用（App 只有一条线程，见 `app.rs`）。
    pub fn open(store: &Store) -> Outcome {
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
                hbrBackground: windows::Win32::Graphics::Gdi::HBRUSH(
                    // COLOR_BTNFACE + 1：对话框的标准底色
                    (windows::Win32::Graphics::Gdi::COLOR_BTNFACE.0 + 1) as isize as *mut _,
                ),
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
                WS_POPUP | WS_CAPTION | WS_SYSMENU | WS_VISIBLE,
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

            let font = crate::settings_window::message_font();
            let inner_width = WIDTH - MARGIN * 2 - 16;
            let search = child(
                hwnd,
                instance,
                w!("EDIT"),
                "",
                (WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_BORDER).0 | ES_AUTOHSCROLL as u32,
                MARGIN,
                MARGIN,
                inner_width,
                SEARCH_HEIGHT,
                ID_SEARCH,
                font,
            );
            let list_height = (HEIGHT - MARGIN * 3 - SEARCH_HEIGHT - HINT_HEIGHT - 40).max(80);
            let list = child(
                hwnd,
                instance,
                w!("LISTBOX"),
                "",
                (WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_BORDER | WS_VSCROLL).0
                    | LBS_NOTIFY as u32,
                MARGIN,
                MARGIN * 2 + SEARCH_HEIGHT,
                inner_width,
                list_height,
                ID_LIST,
                font,
            );
            let hint = child(
                hwnd,
                instance,
                w!("STATIC"),
                HINT_BROWSE,
                (WS_CHILD | WS_VISIBLE).0,
                MARGIN,
                MARGIN * 2 + SEARCH_HEIGHT + list_height + 6,
                inner_width,
                HINT_HEIGHT,
                0,
                font,
            );

            let mut state = Box::new(PanelState {
                snapshot: store.items().to_vec(),
                visible: Vec::new(),
                search,
                list,
                hint,
                mode: Mode::Browse,
                outcome: Outcome::Cancelled,
                done: false,
            });
            state.refill("");
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, state.as_mut() as *mut PanelState as isize);

            let _ = ShowWindow(hwnd, SW_SHOW);
            // 面板是快捷键唤起的，不抢前台的话它会开在别人后面
            let _ = SetForegroundWindow(hwnd);
            let _ = SetFocus(search);

            let mut message = MSG::default();
            while GetMessageW(&mut message, None, 0, 0).as_bool() {
                // 焦点在搜索框上，↑↓ / ⏎ / Esc 本来会被它自己吃掉，
                // 所以在派发之前先看一眼
                if message.message == WM_KEYDOWN && handle_key(&mut state, message.wParam.0 as u32)
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
            // 窗口销毁是异步的：把队列里剩下的消息跑完，
            // 免得面板的残影还在，合成的 Ctrl+V 就已经发出去了
            drain_pending();
            std::mem::replace(&mut state.outcome, Outcome::Cancelled)
        }
    }

    /// 拦下来一个按键。返回 `true` 表示已经处理，不要再派发下去。
    unsafe fn handle_key(state: &mut PanelState, key: u32) -> bool {
        let ctrl = GetKeyState(VK_CONTROL.0 as i32) < 0;
        match key {
            VK_ESCAPE => {
                // 第二层的 Esc 是「退回上一层」，不是「关掉面板」
                if matches!(state.mode, Mode::Tools { .. }) {
                    state.toggle_tools();
                    return true;
                }
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
            VK_T if ctrl => {
                state.toggle_tools();
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
            // Ctrl+1–9 直接选中第 n 条。要带 Ctrl，否则用户打不了数字
            digit if ctrl && (VK_1..=VK_9).contains(&digit) => {
                let index = (digit - VK_1) as usize;
                if index < state.visible.len() {
                    SendMessageW(state.list, LB_SETCURSEL, WPARAM(index), LPARAM(0));
                    state.finish(Outcome::Paste);
                }
                true
            }
            _ => false,
        }
    }

    /// 把队列里剩下的消息跑完。
    unsafe fn drain_pending() {
        use windows::Win32::UI::WindowsAndMessaging::{PeekMessageW, PM_REMOVE};
        let mut message = MSG::default();
        while PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool() {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }

    unsafe extern "system" fn wndproc(
        hwnd: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut PanelState;
        if pointer.is_null() {
            return DefWindowProcW(hwnd, message, wparam, lparam);
        }
        let state = &mut *pointer;

        match message {
            WM_COMMAND => {
                let id = (wparam.0 & 0xFFFF) as i32;
                let code = ((wparam.0 >> 16) & 0xFFFF) as u32;
                if id == ID_SEARCH && code == EN_CHANGE {
                    let needle = window_text(state.search);
                    state.refill(&needle);
                } else if id == ID_LIST && code == LBN_DBLCLK {
                    state.finish(Outcome::Paste);
                }
                LRESULT(0)
            }
            WM_DESTROY => {
                // 用户点了标题栏上的关闭按钮：什么都没选
                state.done = true;
                PostQuitMessage(0);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, message, wparam, lparam),
        }
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
        assert!(tools_for(&secret).is_none());
    }

    #[test]
    fn the_text_tools_refuse_to_open_on_images_and_empty_entries() {
        let mut image = item("");
        image.kind = Kind::Image;
        image.image_file = "a.png".into();
        assert!(tools_for(&image).is_none());
        assert!(tools_for(&item("   ")).is_none());
    }

    #[test]
    fn the_text_tools_open_on_ordinary_text_and_recognise_json() {
        let entries = tools_for(&item(r#"{"a":1}"#)).unwrap();
        assert!(entries.iter().any(|e| e.action == "json.pretty"));
        // 说明行不是动作，选中了不该做事
        assert!(entries.iter().any(|e| e.action.is_empty()));
    }

    #[test]
    fn action_rows_look_different_from_explanatory_ones() {
        // 只有一个列表控件、没有字重可用，全靠行首那个记号区分
        let entries = tools_for(&item("1785760496")).unwrap();
        let action = entries.iter().find(|e| !e.action.is_empty()).unwrap();
        let info = entries.iter().find(|e| e.action.is_empty()).unwrap();
        assert_ne!(
            tool_row_label(action).trim_start().chars().next(),
            tool_row_label(info).trim_start().chars().next()
        );
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
