//! 设置窗口（Win32 通用控件）。
//!
//! 与 Linux 的 GTK 版是同一件事的两种画法：**「有哪些设置」不在这里**，
//! 全部来自 `baobox_app::SettingsPage`。这个文件只把声明翻译成原生控件，
//! 再把改动写回配置。
//!
//! # 为什么自己摆位置而不是用对话框资源
//!
//! `.rc` 对话框资源要在编译期把每个控件的坐标写死 —— 而我们的控件是
//! **运行期按声明生成**的（工具可以随时多一个选项）。所以这里用
//! `CreateWindowExW` 逐个建控件，按行摆。代价是要自己算 y 坐标，
//! 好处是加一个设置项不用碰这个文件。
//!
//! # 为什么改一下就存一次
//!
//! 没有「确定 / 取消」。改完立刻生效、立刻落盘，与 mac 版、与 Linux 版一致。
//!
//! # 快捷键用系统自带的 `msctls_hotkey32`
//!
//! Win32 有一个专门录快捷键的通用控件，外观与行为都是系统的（包括
//! 「只按修饰键不算数」这类细节）。自己用按钮 + 键盘钩子去实现，
//! 既要处理控件焦点又要处理钩子的生命周期，还做不出一样的手感。
//!
//! 它有一个已知限制：**录不了 Win 键组合** —— 这是控件本身的设计
//! （`HOTKEYF_*` 里根本没有 Win）。Win 键组合基本都被系统占着，实用价值不大；
//! 真要用可以直接在配置文件里写 `Super+…`，注册那一层是支持的。
//!
//! # 字体
//!
//! 不设字体的话 Win32 控件会用上世纪的系统字体（粗糙的 System），
//! 与整个系统格格不入。必须显式取 `SystemParametersInfoW(SPI_GETNONCLIENTMETRICS)`
//! 里的 `lfMessageFont` 并 `WM_SETFONT` 给每个控件。
//!
//! # 按工具分页（与 mac 版对齐）
//!
//! 左边一列工具名，右边只显示选中那个工具的设置项 —— mac 版的设置就是
//! 按工具分 Tab 的，全部工具摞成一长条既难找又得滚半天。切页 = 把别页的
//! 控件 `SW_HIDE`、把本页的挪回设计位置，控件只建一次。
//!
//! # 滚动是自己挪控件，不是 `ScrollWindowEx`
//!
//! 分页之后单页大多一屏放得下，但难保哪个工具的设置项越加越多，
//! 所以 `WM_VSCROLL` 仍然实现着（**挂一个滚不动的滚动条比没有更糟**）。
//!
//! 做法是记下每个控件「设计时的 y」，滚动时按偏移量逐个 `SetWindowPos`。
//! 比 `ScrollWindowEx` 省心：后者滚的是像素，子控件的逻辑位置没变，
//! 点击命中、焦点框、重绘都要另外圆场。控件总共几十个，挪一遍毫无压力。

#![cfg(windows)]

use baobox_app::settings::{FieldKind, SettingsPage};
use baobox_app::Field;
use baobox_core::config::Config;
use baobox_core::hotkey::KeyCombo;
use std::cell::RefCell;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Gdi::{CreateFontIndirectW, DeleteObject, HFONT};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::{
    SetScrollInfo, BST_CHECKED, BST_UNCHECKED, HKM_GETHOTKEY, HKM_SETHOTKEY, HOTKEYF_ALT, HOTKEYF_CONTROL,
    HOTKEYF_SHIFT, UDM_SETPOS32, UDM_SETRANGE32, UDS_AUTOBUDDY, UDS_SETBUDDYINT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, GetWindowLongPtrW, GetWindowTextLengthW,
    GetWindowTextW, LoadCursorW, RegisterClassW, SendMessageW, SetWindowLongPtrW,
    ShowWindow, SystemParametersInfoW, BM_GETCHECK, BM_SETCHECK, BS_AUTOCHECKBOX, CBN_SELCHANGE,
    CB_ADDSTRING, CB_GETCURSEL, CB_SETCURSEL, CBS_DROPDOWNLIST, EN_CHANGE, ES_AUTOHSCROLL,
    EnumChildWindows, GetClientRect, GWLP_USERDATA, IDC_ARROW, LBN_SELCHANGE, LBS_NOTIFY,
    LB_ADDSTRING, LB_GETCURSEL, LB_SETCURSEL, NONCLIENTMETRICSW, SB_BOTTOM,
    SB_LINEDOWN, SB_LINEUP, SB_PAGEDOWN, SB_PAGEUP, SB_THUMBPOSITION, SB_THUMBTRACK, SB_TOP,
    SB_VERT, SCROLLINFO, SIF_PAGE, SIF_POS, SIF_RANGE, SPI_GETNONCLIENTMETRICS,
    SetWindowPos, SWP_NOACTIVATE, SWP_NOSIZE, SWP_NOZORDER,
    SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SW_HIDE, SW_SHOW, WM_COMMAND, WM_DESTROY, WM_MOUSEWHEEL,
    WM_SETFONT, WM_SIZE, WM_VSCROLL, WNDCLASSW, WS_BORDER, WS_CHILD, WS_EX_CLIENTEDGE,
    WS_OVERLAPPEDWINDOW, WS_TABSTOP, WS_VISIBLE, WS_VSCROLL,
};

/// 设置窗口类名。
const CLASS_NAME: PCWSTR = w!("BaoboxSettings");

/// 控件 id 从这里开始编 —— 低位留给系统的标准 id（IDOK 之类）。
const FIRST_CONTROL: i32 = 100;

/// 左侧工具列表的控件 id（在系统保留区之上、普通控件之下）。
const ID_SIDEBAR: i32 = 90;

/// 行距与各段宽度（像素，96 DPI 下的基准）。
const ROW_HEIGHT: i32 = 30;
const HELP_HEIGHT: i32 = 18;
const MARGIN: i32 = 16;
const LABEL_WIDTH: i32 = 220;
const CONTROL_WIDTH: i32 = 200;
/// 左侧工具列表的宽度。
const SIDEBAR_WIDTH: i32 = 130;
/// 设置项区域的起点（工具列表右侧）。
const PAGE_X: i32 = MARGIN + SIDEBAR_WIDTH + MARGIN;
const WINDOW_WIDTH: i32 = 520 + SIDEBAR_WIDTH + MARGIN;

/// 配置被改动时的回调。
pub type OnChange = Box<dyn Fn(&Config)>;

/// 一个已经建出来的控件，连着它对应的那项声明。
struct Bound {
    id: i32,
    field: Field,
    section: String,
    hwnd: HWND,
    kind: Kind,
}

/// 控件种类 —— 决定怎么把值读出来。
#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Check,
    Combo,
    Edit,
    Number,
    Hotkey,
}

/// 窗口持有的状态。
struct SettingsState {
    controls: Vec<Bound>,
    config: RefCell<Config>,
    on_change: OnChange,
    font: HFONT,
    /// 每一页的子控件与它们**设计时**的 (x, y)。切页时别页隐藏、本页摆回；
    /// 滚动就是照着这个（减去偏移）重新摆一遍。
    ///
    /// x 也要记：`SetWindowPos` 即便带 `SWP_NOSIZE`，位置也是两个坐标
    /// **一起**生效的 —— 只算 y、x 随手传 0 的话，一滚动所有控件会齐刷刷
    /// 贴到窗口左边
    page_children: Vec<Vec<(HWND, i32, i32)>>,
    /// 每一页的内容总高
    page_heights: Vec<i32>,
    /// 现在显示第几页
    current: usize,
    /// 左侧工具列表
    sidebar: HWND,
    /// 已经往下滚了多少像素（只作用于当前页）
    scroll_y: i32,
    /// 当前页的内容总高
    content_height: i32,
}

/// 滚一「行」多少像素。
const SCROLL_STEP: i32 = 30;

/// 打开设置窗口。必须在有消息循环的线程上调用。
pub fn open(pages: Vec<SettingsPage>, config: Config, on_change: OnChange) -> Result<HWND, String> {
    unsafe {
        let instance: HINSTANCE = GetModuleHandleW(None)
            .map_err(|e| format!("GetModuleHandle 失败：{e}"))?
            .into();
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

        let page_heights: Vec<i32> = pages.iter().map(page_height).collect();
        // 窗口取最高的那一页，但不超过 640 —— 再高的话 768 的笔记本上
        // 扣掉任务栏就摆不下了。单页超出的部分交给滚动条
        let height = page_heights.iter().copied().max().unwrap_or(200).min(640);
        let hwnd = CreateWindowExW(
            Default::default(),
            CLASS_NAME,
            w!("Baobox 设置"),
            // WS_VSCROLL 与 WM_VSCROLL 的处理是配套的 —— 见模块文档
            WS_OVERLAPPEDWINDOW | WS_VSCROLL,
            windows::Win32::UI::WindowsAndMessaging::CW_USEDEFAULT,
            windows::Win32::UI::WindowsAndMessaging::CW_USEDEFAULT,
            WINDOW_WIDTH,
            height,
            None,
            None,
            instance,
            None,
        )
        .map_err(|e| format!("创建设置窗口失败：{e}"))?;

        let font = message_font();
        // 左侧工具列表（先建，好在收集各页控件时把它排除在外）
        let sidebar = control(
            hwnd, instance, w!("LISTBOX"), "",
            (WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_BORDER).0 | LBS_NOTIFY as u32,
            MARGIN, MARGIN, SIDEBAR_WIDTH, client_height(hwnd).max(200) - MARGIN * 2,
            ID_SIDEBAR, font,
        );
        for page in &pages {
            let title = wide(&page.title);
            SendMessageW(sidebar, LB_ADDSTRING, WPARAM(0), LPARAM(title.as_ptr() as isize));
        }
        SendMessageW(sidebar, LB_SETCURSEL, WPARAM(0), LPARAM(0));

        let mut state = Box::new(SettingsState {
            controls: Vec::new(),
            config: RefCell::new(config),
            on_change,
            font,
            page_children: Vec::new(),
            page_heights,
            current: 0,
            sidebar,
            scroll_y: 0,
            content_height: 0,
        });

        // 一页一页建；每建完一页收一遍子窗口，新出现的就是这一页的。
        // 这样建控件的那些辅助函数不必都串一个「记到哪一页」的参数
        let mut seen: std::collections::HashSet<isize> =
            collect_children(hwnd).iter().map(|(h, _, _)| h.0 as isize).collect();
        let mut id = FIRST_CONTROL;
        for page in &pages {
            id = build_page(hwnd, instance, page, &mut state, id);
            let mut mine = Vec::new();
            for (child, x, y) in collect_children(hwnd) {
                if seen.insert(child.0 as isize) {
                    mine.push((child, x, y));
                }
            }
            state.page_children.push(mine);
        }

        let raw = Box::into_raw(state);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, raw as isize);
        show_page(hwnd, &mut *raw, 0);

        let _ = ShowWindow(hwnd, SW_SHOW);
        Ok(hwnd)
    }
}

/// 一页该多高：标题 + 各行 + 说明行。
fn page_height(page: &SettingsPage) -> i32 {
    let mut height = MARGIN * 2 + 40 + ROW_HEIGHT; // 边距 + 页标题
    for field in &page.fields {
        height += ROW_HEIGHT;
        if field.help.is_some() {
            height += HELP_HEIGHT;
        }
    }
    height
}

/// 切到第 `index` 页：别页的控件藏起来，本页的摆回设计位置。
unsafe fn show_page(hwnd: HWND, state: &mut SettingsState, index: usize) {
    let index = index.min(state.page_children.len().saturating_sub(1));
    state.current = index;
    state.scroll_y = 0;
    state.content_height = state.page_heights.get(index).copied().unwrap_or(0);
    for (page, children) in state.page_children.iter().enumerate() {
        for (child, x, y) in children {
            if page == index {
                let _ = SetWindowPos(
                    *child, None, *x, *y, 0, 0,
                    SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
                );
                let _ = ShowWindow(*child, SW_SHOW);
            } else {
                let _ = ShowWindow(*child, SW_HIDE);
            }
        }
    }
    configure_scrollbar(hwnd, state);
}

/// 建一页的控件，返回下一个可用的控件 id。
unsafe fn build_page(
    parent: HWND,
    instance: HINSTANCE,
    page: &SettingsPage,
    state: &mut SettingsState,
    first_id: i32,
) -> i32 {
    let mut y = MARGIN;
    let mut id = first_id;
    let page_width = WINDOW_WIDTH - PAGE_X - MARGIN;

    {
        // 页标题
        static_text(parent, instance, &page.title, PAGE_X, y, page_width, state.font);
        y += ROW_HEIGHT;

        for field in &page.fields {
            let value = field.value(&state.config.borrow(), &page.section);
            let control_x = PAGE_X + LABEL_WIDTH;

            let (hwnd, kind) = match &field.kind {
                FieldKind::Toggle { .. } => {
                    // 复选框自带文字，不再单独放标签
                    let hwnd = control(
                        parent, instance, w!("BUTTON"), &field.label,
                        (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | BS_AUTOCHECKBOX as u32,
                        PAGE_X, y, LABEL_WIDTH + CONTROL_WIDTH, 22, id, state.font,
                    );
                    SendMessageW(
                        hwnd,
                        BM_SETCHECK,
                        WPARAM(if value == "true" { BST_CHECKED.0 } else { BST_UNCHECKED.0 } as usize),
                        LPARAM(0),
                    );
                    (hwnd, Kind::Check)
                }
                FieldKind::Choice { options, .. } => {
                    static_text(parent, instance, &field.label, PAGE_X, y + 3, LABEL_WIDTH, state.font);
                    let hwnd = control(
                        parent, instance, w!("COMBOBOX"), "",
                        (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | CBS_DROPDOWNLIST as u32,
                        control_x, y, CONTROL_WIDTH, 200, id, state.font,
                    );
                    for (index, (stored, title)) in options.iter().enumerate() {
                        let text = wide(title);
                        SendMessageW(hwnd, CB_ADDSTRING, WPARAM(0), LPARAM(text.as_ptr() as isize));
                        if *stored == value {
                            SendMessageW(hwnd, CB_SETCURSEL, WPARAM(index), LPARAM(0));
                        }
                    }
                    (hwnd, Kind::Combo)
                }
                FieldKind::Number { min, max, .. } => {
                    static_text(parent, instance, &field.label, PAGE_X, y + 3, LABEL_WIDTH, state.font);
                    let edit = control(
                        parent, instance, w!("EDIT"), &value,
                        (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | ES_AUTOHSCROLL as u32,
                        control_x, y, 80, 22, id, state.font,
                    );
                    // 配一个上下箭头，省得用户手打数字。
                    // UDS_AUTOBUDDY 把 Z 序上前一个窗口（就是上面那个编辑框）
                    // 认作 buddy —— 不绑 buddy 的话箭头点了只改内部计数，
                    // 编辑框纹丝不动，设置永远不会变
                    let spin = control(
                        parent, instance, w!("msctls_updown32"), "",
                        (WS_CHILD | WS_VISIBLE).0
                            | (UDS_SETBUDDYINT | UDS_AUTOBUDDY) as u32,
                        control_x + 80, y, 18, 22, id + 1000, state.font,
                    );
                    SendMessageW(spin, UDM_SETRANGE32, WPARAM(*min as usize), LPARAM(*max as isize));
                    SendMessageW(
                        spin,
                        UDM_SETPOS32,
                        WPARAM(0),
                        LPARAM(value.parse::<i32>().unwrap_or(*min as i32) as isize),
                    );
                    (edit, Kind::Number)
                }
                FieldKind::Hotkey { .. } => {
                    static_text(parent, instance, &field.label, PAGE_X, y + 3, LABEL_WIDTH, state.font);
                    let hwnd = control_ex(
                        parent, instance, WS_EX_CLIENTEDGE, w!("msctls_hotkey32"), "",
                        (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0,
                        control_x, y, CONTROL_WIDTH, 22, id, state.font,
                    );
                    let (key, modifiers) = to_hotkey_control(&value);
                    SendMessageW(
                        hwnd,
                        HKM_SETHOTKEY,
                        WPARAM((key as usize) | ((modifiers as usize) << 8)),
                        LPARAM(0),
                    );
                    (hwnd, Kind::Hotkey)
                }
                FieldKind::Text { .. } => {
                    static_text(parent, instance, &field.label, PAGE_X, y + 3, LABEL_WIDTH, state.font);
                    let hwnd = control_ex(
                        parent, instance, WS_EX_CLIENTEDGE, w!("EDIT"), &value,
                        (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | ES_AUTOHSCROLL as u32,
                        control_x, y, CONTROL_WIDTH, 22, id, state.font,
                    );
                    (hwnd, Kind::Edit)
                }
            };

            state.controls.push(Bound {
                id,
                field: field.clone(),
                section: page.section.clone(),
                hwnd,
                kind,
            });
            id += 1;
            y += ROW_HEIGHT;

            if let Some(help) = &field.help {
                static_text(
                    parent, instance, help,
                    PAGE_X + 2, y - 6, page_width, state.font,
                );
                y += HELP_HEIGHT;
            }
        }
    }
    id
}

unsafe fn static_text(
    parent: HWND,
    instance: HINSTANCE,
    text: &str,
    x: i32,
    y: i32,
    width: i32,
    font: HFONT,
) {
    control(
        parent, instance, w!("STATIC"), text,
        (WS_CHILD | WS_VISIBLE).0,
        x, y, width, 18, 0, font,
    );
}

#[allow(clippy::too_many_arguments)]
unsafe fn control(
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
    control_ex(parent, instance, Default::default(), class, text, style, x, y, width, height, id, font)
}

#[allow(clippy::too_many_arguments)]
unsafe fn control_ex(
    parent: HWND,
    instance: HINSTANCE,
    ex_style: windows::Win32::UI::WindowsAndMessaging::WINDOW_EX_STYLE,
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
        ex_style,
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
    // 不设字体的话会用上世纪的 System 字体，与系统格格不入
    SendMessageW(hwnd, WM_SETFONT, WPARAM(font.0 as usize), LPARAM(1));
    hwnd
}

/// 系统的界面字体。
///
/// 剪贴板面板也用它 —— 两个窗口该长得像同一个程序里出来的。
pub unsafe fn message_font() -> HFONT {
    let mut metrics = NONCLIENTMETRICSW {
        cbSize: std::mem::size_of::<NONCLIENTMETRICSW>() as u32,
        ..Default::default()
    };
    let ok = SystemParametersInfoW(
        SPI_GETNONCLIENTMETRICS,
        metrics.cbSize,
        Some(&mut metrics as *mut _ as *mut _),
        SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
    )
    .is_ok();
    if ok {
        CreateFontIndirectW(&metrics.lfMessageFont)
    } else {
        HFONT::default()
    }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

/// `KeyCombo` 的文本形式 → `msctls_hotkey32` 认的 `(虚拟键, 修饰键位)`。
///
/// 解析不出来（包括空串，也就是「用户解绑了」）时返回 `(0, 0)`，
/// 控件会显示成「无」。
pub fn to_hotkey_control(text: &str) -> (u8, u8) {
    let Ok(combo) = KeyCombo::parse(text) else {
        return (0, 0);
    };
    let Some(key) = crate::hotkeys::virtual_key_for(combo.key) else {
        return (0, 0);
    };
    let mut modifiers = 0u8;
    if combo.shift {
        modifiers |= HOTKEYF_SHIFT as u8;
    }
    if combo.ctrl {
        modifiers |= HOTKEYF_CONTROL as u8;
    }
    if combo.alt {
        modifiers |= HOTKEYF_ALT as u8;
    }
    // Win 键：控件不支持，这里也就无从设置（见模块文档）
    (key as u8, modifiers)
}

/// `msctls_hotkey32` 的 `(虚拟键, 修饰键位)` → `KeyCombo` 的文本形式。
///
/// 虚拟键为 0 表示用户清空了控件 —— 返回空串，也就是「主动解绑」，
/// 与「配置里没这个键」是两回事（见 `baobox_app::HotkeySpec::resolve`）。
pub fn from_hotkey_control(key: u8, modifiers: u8) -> String {
    if key == 0 {
        return String::new();
    }
    let Some(name) = key_name(key) else {
        return String::new();
    };
    let mut parts = Vec::new();
    if modifiers & HOTKEYF_CONTROL as u8 != 0 {
        parts.push("Ctrl".to_string());
    }
    if modifiers & HOTKEYF_ALT as u8 != 0 {
        parts.push("Alt".to_string());
    }
    if modifiers & HOTKEYF_SHIFT as u8 != 0 {
        parts.push("Shift".to_string());
    }
    // 没带修饰键的组合会把这个键从所有 App 手里抢走，不接受
    // （PrintScreen 例外，它本来就是系统级功能键）
    if parts.is_empty() && name != "PrintScreen" {
        return String::new();
    }
    parts.push(name);
    parts.join("+")
}

/// 虚拟键码 → `KeyCombo` 认得的主键名。
fn key_name(key: u8) -> Option<String> {
    match key {
        // VK 里字母是大写 ASCII，数字是 '0'–'9'
        b'A'..=b'Z' | b'0'..=b'9' => Some((key as char).to_string()),
        0x70..=0x87 => Some(format!("F{}", key - 0x70 + 1)),
        0x20 => Some("Space".to_string()),
        0x0D => Some("Enter".to_string()),
        0x2C => Some("PrintScreen".to_string()),
        _ => None,
    }
}

/// 收一遍子窗口，记下每个的**设计时 y**（客户区坐标）。
///
/// 滚动时照着它重新摆。之所以建完再收、而不是在每个 `control()` 里顺手记下来：
/// 那要给六七个建控件的辅助函数都串一个参数，而这件事只做一次。
unsafe fn collect_children(parent: HWND) -> Vec<(HWND, i32, i32)> {
    let mut found: Vec<(HWND, i32, i32)> = Vec::new();
    let _ = EnumChildWindows(
        parent,
        Some(collect_one),
        LPARAM(&mut found as *mut Vec<(HWND, i32, i32)> as isize),
    );
    found
}

unsafe extern "system" fn collect_one(child: HWND, lparam: LPARAM) -> windows::Win32::Foundation::BOOL {
    use windows::Win32::Foundation::{POINT, RECT, TRUE};
    use windows::Win32::Graphics::Gdi::ScreenToClient;
    use windows::Win32::UI::WindowsAndMessaging::{GetParent, GetWindowRect};

    let found = &mut *(lparam.0 as *mut Vec<(HWND, i32, i32)>);
    let mut rect = RECT::default();
    if GetWindowRect(child, &mut rect).is_ok() {
        let mut point = POINT {
            x: rect.left,
            y: rect.top,
        };
        if let Ok(parent) = GetParent(child) {
            let _ = ScreenToClient(parent, &mut point);
        }
        found.push((child, point.x, point.y));
    }
    TRUE
}

/// 客户区有多高。
unsafe fn client_height(hwnd: HWND) -> i32 {
    use windows::Win32::Foundation::RECT;
    let mut rect = RECT::default();
    if GetClientRect(hwnd, &mut rect).is_ok() {
        rect.bottom - rect.top
    } else {
        0
    }
}

/// 按当前内容高与客户区高设好滚动条。
///
/// `nPage` 给的是「一屏能看到多少」——**必须设**，否则滑块会是一条细线，
/// 而且 `SB_PAGEDOWN` 一次翻整个范围。
unsafe fn configure_scrollbar(hwnd: HWND, state: &SettingsState) {
    let page = client_height(hwnd).max(1);
    let info = SCROLLINFO {
        cbSize: std::mem::size_of::<SCROLLINFO>() as u32,
        fMask: SIF_RANGE | SIF_PAGE | SIF_POS,
        nMin: 0,
        nMax: state.content_height.max(0),
        nPage: page as u32,
        nPos: state.scroll_y,
        nTrackPos: 0,
    };
    SetScrollInfo(hwnd, SB_VERT, &info, true);
}

/// 滚到某个位置（会被夹进合法范围），然后把控件挪过去。
unsafe fn scroll_to(hwnd: HWND, state: &mut SettingsState, target: i32) {
    let max = (state.content_height - client_height(hwnd)).max(0);
    let clamped = target.clamp(0, max);
    if clamped == state.scroll_y {
        return;
    }
    state.scroll_y = clamped;
    let Some(children) = state.page_children.get(state.current) else {
        return;
    };
    for (child, design_x, design_y) in children {
        let _ = SetWindowPos(
            *child,
            None,
            *design_x,
            design_y - state.scroll_y,
            0,
            0,
            SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
        );
    }
    configure_scrollbar(hwnd, state);
}

unsafe extern "system" fn wndproc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut SettingsState;
    if pointer.is_null() {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    let state = &mut *pointer;

    match message {
        WM_COMMAND => {
            let id = (wparam.0 & 0xFFFF) as i32;
            let code = ((wparam.0 >> 16) & 0xFFFF) as u32;
            if id == ID_SIDEBAR && code == LBN_SELCHANGE {
                // 列表点当前行也会发 LBN_SELCHANGE —— 不挡掉的话，
                // 随手一点就把用户滚到一半的位置弹回顶部
                let index = SendMessageW(state.sidebar, LB_GETCURSEL, WPARAM(0), LPARAM(0)).0;
                if index >= 0 && index as usize != state.current {
                    show_page(hwnd, state, index as usize);
                }
            } else {
                handle_command(state, id, code);
            }
            LRESULT(0)
        }
        WM_VSCROLL => {
            let request = (wparam.0 & 0xFFFF) as i32;
            let page = client_height(hwnd).max(1);
            let target = match request {
                r if r == SB_LINEUP.0 => state.scroll_y - SCROLL_STEP,
                r if r == SB_LINEDOWN.0 => state.scroll_y + SCROLL_STEP,
                r if r == SB_PAGEUP.0 => state.scroll_y - page,
                r if r == SB_PAGEDOWN.0 => state.scroll_y + page,
                r if r == SB_TOP.0 => 0,
                r if r == SB_BOTTOM.0 => state.content_height,
                // 拖滑块：位置在 wParam 的高 16 位。用它而不是 GetScrollInfo，
                // 少一次往返；设置窗口不可能高到超过 65535 像素
                r if r == SB_THUMBTRACK.0 || r == SB_THUMBPOSITION.0 => {
                    ((wparam.0 >> 16) & 0xFFFF) as i32
                }
                _ => state.scroll_y,
            };
            scroll_to(hwnd, state, target);
            LRESULT(0)
        }
        WM_MOUSEWHEEL => {
            // 高 16 位是有符号的滚动量，一「格」是 120
            let delta = ((wparam.0 >> 16) & 0xFFFF) as u16 as i16;
            let lines = -(delta as i32) / 120;
            scroll_to(hwnd, state, state.scroll_y + lines * SCROLL_STEP);
            LRESULT(0)
        }
        WM_SIZE => {
            // 窗口被拉高了：能看到的更多，滚动范围就该变小，
            // 而且可能要把已经滚过头的位置收回来；工具列表也跟着拉高
            let _ = SetWindowPos(
                state.sidebar,
                None,
                MARGIN,
                MARGIN,
                SIDEBAR_WIDTH,
                (client_height(hwnd) - MARGIN * 2).max(60),
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
            configure_scrollbar(hwnd, state);
            scroll_to(hwnd, state, state.scroll_y);
            LRESULT(0)
        }
        WM_DESTROY => {
            // 窗口关掉不等于退出 App —— 这是常驻程序，托盘图标还在。
            // 只把这个窗口自己的资源还回去
            if !state.font.is_invalid() {
                let _ = DeleteObject(state.font);
            }
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            drop(Box::from_raw(pointer));
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

/// 某个控件变了。
unsafe fn handle_command(state: &mut SettingsState, id: i32, code: u32) {
    let Some(index) = state.controls.iter().position(|c| c.id == id) else {
        return;
    };
    let bound = &state.controls[index];
    let kind = bound.kind;
    let hwnd = bound.hwnd;

    let value = match kind {
        Kind::Hotkey => {
            // 控件自己负责录制；它变了会像编辑框一样发 EN_CHANGE
            if code != EN_CHANGE {
                return;
            }
            let packed = SendMessageW(hwnd, HKM_GETHOTKEY, WPARAM(0), LPARAM(0)).0 as u32;
            from_hotkey_control((packed & 0xFF) as u8, ((packed >> 8) & 0xFF) as u8)
        }
        Kind::Check => {
            let checked = SendMessageW(hwnd, BM_GETCHECK, WPARAM(0), LPARAM(0)).0 as u32;
            if checked == BST_CHECKED.0 { "true" } else { "false" }.to_string()
        }
        Kind::Combo => {
            if code != CBN_SELCHANGE {
                return;
            }
            let index = SendMessageW(hwnd, CB_GETCURSEL, WPARAM(0), LPARAM(0)).0;
            match &state.controls[index_of(state, id)].field.kind {
                FieldKind::Choice { options, default } => options
                    .get(index as usize)
                    .map(|(stored, _)| stored.clone())
                    .unwrap_or_else(|| default.clone()),
                _ => return,
            }
        }
        Kind::Edit | Kind::Number => {
            if code != EN_CHANGE {
                return;
            }
            window_text(hwnd)
        }
    };

    let bound = &state.controls[index];
    {
        let mut config = state.config.borrow_mut();
        bound.field.store(&mut config, &bound.section, &value);
    }
    (state.on_change)(&state.config.borrow());
}

fn index_of(state: &SettingsState, id: i32) -> usize {
    state
        .controls
        .iter()
        .position(|c| c.id == id)
        .unwrap_or_default()
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

/// 关掉设置窗口。
pub fn close(hwnd: HWND) {
    unsafe {
        let _ = DestroyWindow(hwnd);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use baobox_app::settings::Field;

    fn page() -> SettingsPage {
        SettingsPage::new(
            "s",
            "测试",
            vec![
                Field::toggle("a", "开关", true).with_help("一行说明"),
                Field::number("b", "数字", 5, 1, 10),
                Field::hotkey("c", "快捷键", Some("Ctrl+Shift+S")),
            ],
        )
    }

    #[test]
    fn hotkeys_survive_a_round_trip_through_the_native_control() {
        for text in ["Ctrl+Shift+S", "Alt+F4", "Ctrl+Alt+P", "Ctrl+Space", "PrintScreen"] {
            let (key, modifiers) = to_hotkey_control(text);
            let back = from_hotkey_control(key, modifiers);
            assert_eq!(
                KeyCombo::parse(&back).unwrap().to_string(),
                KeyCombo::parse(text).unwrap().to_string(),
                "{text} 转进控件再转回来就变了"
            );
        }
    }

    #[test]
    fn clearing_the_control_means_unbound_not_default() {
        // 虚拟键为 0 = 用户清空了控件；写回空串才表示「主动解绑」
        assert_eq!(from_hotkey_control(0, 0), "");
        assert_eq!(to_hotkey_control(""), (0, 0));
        assert_eq!(to_hotkey_control("这不是快捷键"), (0, 0));
    }

    #[test]
    fn a_combination_without_modifiers_is_rejected() {
        // 光一个 S 会把这个键从所有 App 手里抢走
        assert_eq!(from_hotkey_control(b'S', 0), "");
        // PrintScreen 例外，它本来就是系统级功能键
        assert_eq!(from_hotkey_control(0x2C, 0), "PrintScreen");
    }

    #[test]
    fn the_win_key_is_dropped_rather_than_silently_mismapped() {
        // 控件里没有 Win 位；转进去时丢掉，不能错当成别的修饰键
        let (_, modifiers) = to_hotkey_control("Super+S");
        assert_eq!(modifiers, 0, "Win 键不该被映射成 Ctrl/Alt/Shift 里的任何一个");
    }

    #[test]
    fn the_page_grows_with_the_number_of_settings() {
        let one = page_height(&SettingsPage::new("s", "一项", vec![Field::toggle("a", "开关", true)]));
        let many = page_height(&page());
        assert!(many > one, "多几项就该高一些，否则控件会被挤到窗口外");
        // 带说明的那一项要多留一行
        let without_help = page_height(&SettingsPage::new(
            "s",
            "测试",
            vec![Field::toggle("a", "开关", true)],
        ));
        let with_help = page_height(&SettingsPage::new(
            "s",
            "测试",
            vec![Field::toggle("a", "开关", true).with_help("说明")],
        ));
        assert_eq!(with_help - without_help, HELP_HEIGHT);
    }

    #[test]
    fn wide_strings_are_null_terminated() {
        // 少了结尾的 NUL，Win32 会一直读到内存里下一个 0 为止
        let encoded = wide("ab");
        assert_eq!(encoded, vec![b'a' as u16, b'b' as u16, 0]);
        assert_eq!(wide(""), vec![0]);
        // 中文按 UTF-16 编，不是按字节
        assert_eq!(wide("中").len(), 2);
    }

    #[test]
    fn pages_are_sized_per_tool_but_scrolling_still_backs_up_a_huge_page() {
        // 设置按工具分页（与 mac 版对齐）：普通工具的一页一屏放得下……
        let typical = SettingsPage::new(
            "s",
            "页",
            (0..6)
                .map(|m| Field::toggle(&format!("k{m}"), "开关", true).with_help("说明"))
                .collect(),
        );
        assert!(page_height(&typical) < 640, "普通工具的设置页不该出滚动条");
        // ……但哪个工具的设置项越加越多时，滚动条仍要兜得住
        let huge = SettingsPage::new(
            "s",
            "页",
            (0..20)
                .map(|m| Field::toggle(&format!("k{m}"), "开关", true).with_help("说明"))
                .collect(),
        );
        assert!(page_height(&huge) > 640, "单页超高时必须能滚");
    }

    #[test]
    fn the_sidebar_id_stays_clear_of_both_system_and_field_ids() {
        // 撞上系统 id 会收到莫名其妙的 WM_COMMAND，撞上字段 id 会把
        // 切页当成改设置
        assert!(ID_SIDEBAR > 10);
        assert!(ID_SIDEBAR < FIRST_CONTROL);
    }

    #[test]
    fn scrolling_one_step_is_about_one_row() {
        // 一格滚半行会看着像卡住，滚三行会晕
        assert!(SCROLL_STEP > 0);
        assert!(SCROLL_STEP <= ROW_HEIGHT);
    }

    #[test]
    fn control_ids_start_above_the_system_reserved_range() {
        // IDOK / IDCANCEL 这些是 1..9，撞上的话会收到莫名其妙的 WM_COMMAND
        assert!(FIRST_CONTROL > 10);
    }
}
