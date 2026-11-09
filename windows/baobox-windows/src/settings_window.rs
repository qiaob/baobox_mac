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
//! 侧栏选择页面，内容区独立滚动。
//!
//! # 滚动是自己挪控件，不是 `ScrollWindowEx`
//!
//! 工具一多，设置项就超过一屏了（三个工具已经 700 多像素，而 768 高的
//! 笔记本上扣掉任务栏根本摆不下）。**挂一个滚不动的滚动条比没有更糟**，
//! 所以这里真的实现了 `WM_VSCROLL`。
//!
//! 做法是记下每个控件「设计时的 y」，滚动时按偏移量逐个 `SetWindowPos`。
//! 比 `ScrollWindowEx` 省心：后者滚的是像素，子控件的逻辑位置没变，
//! 点击命中、焦点框、重绘都要另外圆场。控件总共几十个，挪一遍毫无压力。

#![cfg(windows)]

use baobox_app::settings::{FieldKind, SettingsPage};
use baobox_app::Field;
use baobox_core::config::Config;
use baobox_core::hotkey::KeyCombo;
use std::{cell::RefCell, collections::HashSet, sync::OnceLock};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::Graphics::GdiPlus::{
    FillModeAlternate, GdipAddPathArc, GdipClosePathFigure, GdipCreateFromHDC, GdipCreatePath,
    GdipCreateSolidFill, GdipDeleteBrush, GdipDeleteGraphics, GdipDeletePath, GdipFillPath,
    GdipSetSmoothingMode, GdiplusStartup, GdiplusStartupInput, GpGraphics,
    SmoothingModeAntiAlias8x8,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, CLSCTX_INPROC_SERVER,
    COINIT_APARTMENTTHREADED,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Registry::{
    RegDeleteKeyValueW, RegGetValueW, RegSetKeyValueW, HKEY_CURRENT_USER, REG_SZ, RRF_RT_REG_SZ,
};
use windows::Win32::UI::Controls::{
    SetScrollInfo, SetWindowTheme, CDDS_PREPAINT, CDRF_SKIPDEFAULT, DRAWITEMSTRUCT, EM_SETMARGINS,
    HKM_GETHOTKEY, HKM_SETHOTKEY, HOTKEYF_ALT, HOTKEYF_CONTROL, HOTKEYF_SHIFT, NMCUSTOMDRAW,
    NM_CUSTOMDRAW, ODS_FOCUS, ODS_SELECTED, TBM_GETTHUMBRECT, TBM_SETPOS, TBM_SETRANGEMAX,
    TBM_SETRANGEMIN, TBS_NOTICKS,
};
use windows::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
use windows::Win32::UI::WindowsAndMessaging::*;

/// 设置窗口类名。
const CLASS_NAME: PCWSTR = w!("BaoboxSettings");

/// 控件 id 从这里开始编 —— 低位留给系统的标准 id（IDOK 之类）。
const FIRST_CONTROL: i32 = 100;

/// 行距与各段宽度（像素，96 DPI 下的基准）。
const ROW_HEIGHT: i32 = 37;
const HELP_HEIGHT: i32 = 24;
const MARGIN: i32 = 20;
const SIDEBAR: i32 = 200;
const NAV_ID: i32 = 20;
const DOWNLOAD_ID: i32 = 3000;
const DEFAULT_FOLDER_ID: i32 = 4000;
const NUMBER_STEP_ID: i32 = 5000;
const WM_PICK_FOLDER: u32 = WM_APP + 1;
const INPUT: COLORREF = COLORREF(0x383837);
const OPEN_PETS_ID: i32 = 2999;
const TBM_GETPOS: u32 = WM_USER;
const RUN_KEY: PCWSTR = w!("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const RUN_VALUE: PCWSTR = w!("BaoBox");
const BACK: COLORREF = COLORREF(0x282827);
const PANEL: COLORREF = COLORREF(0x2d2d2c);
const SIDEBAR_BACK: COLORREF = COLORREF(0x292823);
const TEXT: COLORREF = COLORREF(0xe8e8e8);
const MUTED: COLORREF = COLORREF(0xaaaaaa);
const BLUE: COLORREF = COLORREF(0xd66a31);
const LABEL_WIDTH: i32 = 322;
const CONTROL_WIDTH: i32 = 245;
// 控件右边要给外框、滚动条和客户区留白。
const WINDOW_WIDTH: i32 = SIDEBAR + MARGIN * 2 + LABEL_WIDTH + CONTROL_WIDTH + 47;

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
    Folder,
    Hotkey,
    Slider,
}

/// 窗口持有的状态。
struct SettingsState {
    controls: Vec<Bound>,
    config: RefCell<Config>,
    on_change: OnChange,
    on_download: Box<dyn Fn(usize)>,
    on_pick_area: Box<dyn Fn()>,
    picking_area: bool,
    font: HFONT,
    /// 页标题专用：消息字体放大加粗，与正文拉开层级。
    title_font: HFONT,
    pages: Vec<PageView>,
    selected: usize,
    panel_brush: HBRUSH,
    input_brush: HBRUSH,
    background_brush: HBRUSH,
    icon_font: HFONT,
    /// 已经往下滚了多少像素
    scroll_y: i32,
    /// 内容总高
    content_height: i32,
}

struct PageView {
    nav: HWND,
    icon: u16,
    children: Vec<(HWND, i32, i32)>,
    groups: Vec<(i32, i32)>,
    height: i32,
}

/// 滚一「行」多少像素。
const SCROLL_STEP: i32 = 30;

/// 打开设置窗口。必须在有消息循环的线程上调用。
pub fn open(
    pages: Vec<SettingsPage>,
    mut config: Config,
    on_download: Box<dyn Fn(usize)>,
    on_pick_area: Box<dyn Fn()>,
    on_change: OnChange,
) -> Result<HWND, String> {
    unsafe {
        let instance: HINSTANCE = GetModuleHandleW(None)
            .map_err(|e| format!("GetModuleHandle 失败：{e}"))?
            .into();
        let class = WNDCLASSW {
            lpfnWndProc: Some(wndproc),
            hInstance: instance,
            lpszClassName: CLASS_NAME,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            ..Default::default()
        };
        RegisterClassW(&class);

        let hwnd = CreateWindowExW(
            Default::default(),
            CLASS_NAME,
            w!("Baobox 设置"),
            // WS_VSCROLL 与 WM_VSCROLL 的处理是配套的 —— 见模块文档
            WS_OVERLAPPEDWINDOW | WS_VSCROLL | WS_CLIPCHILDREN,
            windows::Win32::UI::WindowsAndMessaging::CW_USEDEFAULT,
            windows::Win32::UI::WindowsAndMessaging::CW_USEDEFAULT,
            WINDOW_WIDTH,
            620,
            None,
            None,
            instance,
            None,
        )
        .map_err(|e| format!("创建设置窗口失败：{e}"))?;

        let font = settings_font(-15, FW_NORMAL.0 as i32);
        let title_font = settings_font(-16, FW_SEMIBOLD.0 as i32);
        config.set_bool("general", "autostart", starts_at_login());
        let mut state = Box::new(SettingsState {
            controls: Vec::new(),
            config: RefCell::new(config),
            on_change,
            on_download,
            on_pick_area,
            picking_area: false,
            font,
            title_font,
            pages: Vec::new(),
            selected: 0,
            panel_brush: CreateSolidBrush(PANEL),
            input_brush: CreateSolidBrush(INPUT),
            background_brush: CreateSolidBrush(BACK),
            icon_font: CreateFontW(
                -15,
                0,
                0,
                0,
                400,
                0,
                0,
                0,
                1,
                0,
                0,
                4,
                0,
                w!("Segoe MDL2 Assets"),
            ),
            scroll_y: 0,
            content_height: 0,
        });
        let _ = SetWindowTheme(hwnd, w!("DarkMode_Explorer"), None);
        let dark = 1i32;
        let _ = windows::Win32::Graphics::Dwm::DwmSetWindowAttribute(
            hwnd,
            windows::Win32::Graphics::Dwm::DWMWA_USE_IMMERSIVE_DARK_MODE,
            &dark as *const i32 as _,
            4,
        );

        let mut known = HashSet::new();
        for (index, page) in pages.iter().enumerate() {
            let nav = control(
                hwnd,
                instance,
                w!("BUTTON"),
                &page.title,
                (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | BS_OWNERDRAW as u32,
                10,
                MARGIN + index as i32 * 29,
                SIDEBAR - 20,
                28,
                NAV_ID + index as i32,
                font,
            );
            known.insert(nav.0 as usize);
            let (height, groups) = build(hwnd, instance, page, &mut state);
            let children: Vec<_> = collect_children(hwnd)
                .into_iter()
                .filter(|(child, _, _)| known.insert(child.0 as usize))
                .collect();
            if index != 0 {
                for (child, _, _) in &children {
                    let _ = ShowWindow(*child, SW_HIDE);
                }
            } else {
                state.content_height = height;
            }
            state.pages.push(PageView {
                nav,
                icon: page_icon(&page.section),
                children,
                groups,
                height,
            });
        }
        let raw = Box::into_raw(state);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, raw as isize);
        configure_scrollbar(hwnd, &*raw);

        let _ = ShowWindow(hwnd, SW_SHOW);
        if !IsWindowVisible(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_SHOW);
        }
        Ok(hwnd)
    }
}

/// 窗口该多高：所有页的所有行加起来。
#[cfg(test)]
fn window_height(pages: &[SettingsPage]) -> i32 {
    let mut height = MARGIN * 2 + 40;
    for page in pages {
        height += ROW_HEIGHT; // 页标题
        for field in &page.fields {
            height += ROW_HEIGHT;
            if field.help.is_some() {
                height += HELP_HEIGHT;
            }
        }
        height += MARGIN;
    }
    height
}

/// 逐页逐项建控件。
unsafe fn build(
    parent: HWND,
    instance: HINSTANCE,
    page: &SettingsPage,
    state: &mut SettingsState,
) -> (i32, Vec<(i32, i32)>) {
    let mut y = MARGIN;
    let left = SIDEBAR + MARGIN + 10;
    let control_x = left + LABEL_WIDTH;
    let mut groups = Vec::new();
    let mut group_start = y;
    if page.fields.is_empty() {
        let blocks: &[(&str, &str)] = if page.section == "about" {
            &[(
                "BaoBox",
                concat!("Windows 桌面版 · ", env!("CARGO_PKG_VERSION")),
            )]
        } else {
            &[]
        };
        for (title, body) in blocks {
            static_text(
                parent,
                instance,
                title,
                left,
                y,
                LABEL_WIDTH,
                24,
                state.title_font,
            );
            y += 33;
            static_text(
                parent,
                instance,
                body,
                left,
                y + 9,
                LABEL_WIDTH,
                24,
                state.font,
            );
            groups.push((y, y + 39));
            y += 64;
        }
    }
    if page.section == crate::pet::ID {
        static_text(
            parent,
            instance,
            "桌面上的小伙伴。截图反馈和工具通知可由宠物转达。",
            left,
            y + 7,
            LABEL_WIDTH + CONTROL_WIDTH,
            23,
            state.font,
        );
        groups.push((y, y + 37));
        y += 61;
    }
    for (index, field) in page.fields.iter().enumerate() {
        if page.section == crate::pet::ID && field.key == "size" {
            continue;
        }
        let group = match (page.section.as_str(), field.key.as_str(), index) {
            ("desktop-pet", "startup", _) => Some("宠物"),
            ("general", "autostart", _) => Some("启动"),
            ("desktop-pet", "coat", _) => Some("形象"),
            ("desktop-pet", "alert-sound", _) => Some("通知"),
            (_, _, 0) => Some(page.title.as_str()),
            _ => None,
        };
        if page.section == crate::pet::ID && field.key == "alert-sound" {
            control(
                parent,
                instance,
                w!("BUTTON"),
                "打开素材文件夹",
                (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | BS_OWNERDRAW as u32,
                left,
                y,
                124,
                25,
                OPEN_PETS_ID,
                state.font,
            );
            y += ROW_HEIGHT;
            groups.push((group_start, y + 3));
            y += 25;
            static_text(
                parent,
                instance,
                "更多形象",
                left,
                y,
                LABEL_WIDTH,
                24,
                state.title_font,
            );
            y += 32;
            group_start = y;
            y += 7;
            for (index, entry) in crate::pet_download::catalog().iter().enumerate() {
                static_text(
                    parent,
                    instance,
                    &entry.name,
                    left,
                    y,
                    LABEL_WIDTH,
                    20,
                    state.font,
                );
                static_text(
                    parent,
                    instance,
                    &entry.credit,
                    left,
                    y + 21,
                    LABEL_WIDTH,
                    18,
                    state.font,
                );
                let installed = crate::pet_download::installed(&entry.id);
                let button = control(
                    parent,
                    instance,
                    w!("BUTTON"),
                    if installed { "已安装" } else { "下载" },
                    (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | BS_OWNERDRAW as u32,
                    control_x + CONTROL_WIDTH - 66,
                    y + 7,
                    66,
                    25,
                    DOWNLOAD_ID + index as i32,
                    state.font,
                );
                if installed {
                    let _ =
                        windows::Win32::UI::Input::KeyboardAndMouse::EnableWindow(button, false);
                }
                y += 48;
            }
        }
        if let Some(title) = group {
            if index != 0 {
                groups.push((group_start, y + 3));
                y += 25;
            }
            static_text(
                parent,
                instance,
                title,
                left,
                y,
                LABEL_WIDTH,
                24,
                state.title_font,
            );
            y += 32;
            group_start = y;
            y += 7;
        }
        let id = FIRST_CONTROL + state.controls.len() as i32;
        let value = field.value(&state.config.borrow(), &page.section);
        let (hwnd, kind) = match &field.kind {
            FieldKind::Number { min, max, .. }
                if page.section == crate::pet::ID && field.key == "custom-size" =>
            {
                static_text(
                    parent,
                    instance,
                    "大小",
                    left,
                    y + 3,
                    LABEL_WIDTH,
                    24,
                    state.font,
                );
                let slider = control(
                    parent,
                    instance,
                    w!("msctls_trackbar32"),
                    "大小",
                    (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | TBS_NOTICKS,
                    control_x,
                    y,
                    CONTROL_WIDTH,
                    26,
                    id,
                    state.font,
                );
                let size = crate::pet::configured_size(&state.config.borrow());
                SendMessageW(slider, TBM_SETRANGEMIN, WPARAM(0), LPARAM(*min as isize));
                SendMessageW(slider, TBM_SETRANGEMAX, WPARAM(0), LPARAM(*max as isize));
                SendMessageW(slider, TBM_SETPOS, WPARAM(1), LPARAM(size as isize));
                (slider, Kind::Slider)
            }
            FieldKind::Toggle { .. } => {
                static_text(
                    parent,
                    instance,
                    &field.label,
                    left,
                    y + 3,
                    LABEL_WIDTH,
                    24,
                    state.font,
                );
                let hwnd = control(
                    parent,
                    instance,
                    w!("BUTTON"),
                    &field.label,
                    (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | BS_OWNERDRAW as u32,
                    control_x + CONTROL_WIDTH - 26,
                    y,
                    26,
                    24,
                    id,
                    state.font,
                );
                (hwnd, Kind::Check)
            }
            FieldKind::Choice { options, .. } => {
                static_text(
                    parent,
                    instance,
                    &field.label,
                    left,
                    y + 3,
                    LABEL_WIDTH,
                    24,
                    state.font,
                );
                let hwnd = control(
                    parent,
                    instance,
                    w!("COMBOBOX"),
                    "",
                    (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0
                        | (CBS_DROPDOWNLIST | CBS_OWNERDRAWFIXED | CBS_HASSTRINGS) as u32,
                    control_x,
                    y,
                    CONTROL_WIDTH,
                    200,
                    id,
                    state.font,
                );
                style_combo(hwnd);
                for (index, (stored, title)) in options.iter().enumerate() {
                    let text = wide(title);
                    SendMessageW(
                        hwnd,
                        CB_ADDSTRING,
                        WPARAM(0),
                        LPARAM(text.as_ptr() as isize),
                    );
                    if *stored == value {
                        SendMessageW(hwnd, CB_SETCURSEL, WPARAM(index), LPARAM(0));
                    }
                }
                (hwnd, Kind::Combo)
            }
            FieldKind::Number { .. } => {
                static_text(
                    parent,
                    instance,
                    &field.label,
                    left,
                    y + 3,
                    LABEL_WIDTH,
                    24,
                    state.font,
                );
                let x = control_x + CONTROL_WIDTH - 121;
                let edit = control(
                    parent,
                    instance,
                    w!("EDIT"),
                    &value,
                    (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0
                        | (ES_CENTER | ES_NUMBER | ES_AUTOHSCROLL) as u32,
                    x + 30,
                    y + 3,
                    61,
                    24,
                    id,
                    state.font,
                );
                for (index, (symbol, x)) in [("−", x), ("+", x + 95)].into_iter().enumerate() {
                    control(
                        parent,
                        instance,
                        w!("BUTTON"),
                        symbol,
                        (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | BS_OWNERDRAW as u32,
                        x,
                        y,
                        26,
                        28,
                        NUMBER_STEP_ID + (id - FIRST_CONTROL) * 2 + index as i32,
                        state.font,
                    );
                }
                style_input(edit);
                (edit, Kind::Number)
            }
            FieldKind::Hotkey { .. } => {
                static_text(
                    parent,
                    instance,
                    &field.label,
                    left,
                    y + 3,
                    LABEL_WIDTH,
                    24,
                    state.font,
                );
                let hwnd = control_ex(
                    parent,
                    instance,
                    Default::default(),
                    w!("msctls_hotkey32"),
                    "",
                    (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0,
                    control_x,
                    y,
                    CONTROL_WIDTH,
                    22,
                    id,
                    state.font,
                );
                let (key, modifiers) = to_hotkey_control(&value);
                SendMessageW(
                    hwnd,
                    HKM_SETHOTKEY,
                    WPARAM((key as usize) | ((modifiers as usize) << 8)),
                    LPARAM(0),
                );
                let style = GetWindowLongPtrW(hwnd, GWL_STYLE);
                SetWindowLongPtrW(hwnd, GWL_STYLE, style & !(WS_BORDER.0 as isize));
                let extended_style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
                SetWindowLongPtrW(
                    hwnd,
                    GWL_EXSTYLE,
                    extended_style & !(WS_EX_CLIENTEDGE.0 as isize),
                );
                let _ = SetWindowSubclass(hwnd, Some(hotkey_proc), 1, 0);
                let _ = SetWindowPos(
                    hwnd,
                    None,
                    0,
                    0,
                    0,
                    0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED,
                );
                (hwnd, Kind::Hotkey)
            }
            FieldKind::Text { .. }
                if page.section == crate::screenshot_module::ID && field.key == "save_dir" =>
            {
                static_text(
                    parent,
                    instance,
                    &field.label,
                    left,
                    y + 3,
                    LABEL_WIDTH,
                    24,
                    state.font,
                );
                let button = control(
                    parent,
                    instance,
                    w!("BUTTON"),
                    folder_label(&value),
                    (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | BS_OWNERDRAW as u32,
                    control_x,
                    y,
                    CONTROL_WIDTH - 82,
                    28,
                    id,
                    state.font,
                );
                control(
                    parent,
                    instance,
                    w!("BUTTON"),
                    "恢复默认",
                    (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | BS_OWNERDRAW as u32,
                    control_x + CONTROL_WIDTH - 76,
                    y,
                    76,
                    28,
                    DEFAULT_FOLDER_ID,
                    state.font,
                );
                (button, Kind::Folder)
            }
            FieldKind::Text { .. } => {
                static_text(
                    parent,
                    instance,
                    &field.label,
                    left,
                    y + 3,
                    LABEL_WIDTH,
                    24,
                    state.font,
                );
                let hwnd = control_ex(
                    parent,
                    instance,
                    Default::default(),
                    w!("EDIT"),
                    &value,
                    (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | ES_AUTOHSCROLL as u32,
                    control_x,
                    y,
                    CONTROL_WIDTH,
                    22,
                    id,
                    state.font,
                );
                style_input(hwnd);
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

        y += ROW_HEIGHT;

        if let Some(help) = field.help.as_ref().filter(|_| kind != Kind::Slider) {
            static_text(
                parent,
                instance,
                help,
                left,
                y - 6,
                LABEL_WIDTH + CONTROL_WIDTH,
                20,
                state.font,
            );
            y += HELP_HEIGHT;
        }
    }
    if !page.fields.is_empty() {
        groups.push((group_start, y + 3));
    }
    if page.section == "general" {
        y += 28;
        static_text(
            parent,
            instance,
            "语言",
            left,
            y,
            LABEL_WIDTH,
            24,
            state.title_font,
        );
        y += 33;
        static_text(
            parent,
            instance,
            "界面语言",
            left,
            y + 9,
            LABEL_WIDTH,
            24,
            state.font,
        );
        static_text(
            parent,
            instance,
            "简体中文",
            control_x + CONTROL_WIDTH - 62,
            y + 9,
            62,
            24,
            state.font,
        );
        groups.push((y, y + 39));
        y += 39;
    }
    (y + MARGIN, groups)
}

unsafe fn static_text(
    parent: HWND,
    instance: HINSTANCE,
    text: &str,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    font: HFONT,
) {
    control(
        parent,
        instance,
        w!("STATIC"),
        text,
        (WS_CHILD | WS_VISIBLE).0,
        x,
        y,
        width,
        height,
        0,
        font,
    );
}

/// `SS_ETCHEDHORZ` 的原始值 —— windows crate 没导出这个静态控件样式常量。
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
    control_ex(
        parent,
        instance,
        Default::default(),
        class,
        text,
        style,
        x,
        y,
        width,
        height,
        id,
        font,
    )
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

unsafe extern "system" fn collect_one(
    child: HWND,
    lparam: LPARAM,
) -> windows::Win32::Foundation::BOOL {
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
    let Some(page) = state.pages.get(state.selected) else {
        return;
    };
    for (child, design_x, design_y) in &page.children {
        let _ = SetWindowPos(
            *child,
            None,
            *design_x,
            design_y - state.scroll_y,
            0,
            0,
            SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOREDRAW,
        );
    }
    configure_scrollbar(hwnd, state);
    let _ = RedrawWindow(hwnd, None, None, RDW_INVALIDATE | RDW_ALLCHILDREN);
}

pub(crate) fn page_icon(section: &str) -> u16 {
    match section {
        "hotkey" => 0xe765,
        "about" => 0xe946,
        "claudecode" => 0xe756,
        "aitools" => 0xe943,
        "screenshot" => 0xe722,
        "clipboard" => 0xe77f,
        "caffeinate" => 0xec32,
        "windowmanager" => 0xe737,
        "keyboardnav" => 0xe765,
        "desktop-pet" => 0xed54,
        _ => 0xe713,
    }
}

unsafe fn select_page(hwnd: HWND, state: &mut SettingsState, index: usize) {
    if index == state.selected || index >= state.pages.len() {
        return;
    }
    let old = &state.pages[state.selected];
    for (child, _, _) in &old.children {
        let _ = ShowWindow(*child, SW_HIDE);
    }
    let _ = InvalidateRect(old.nav, None, false);
    state.selected = index;
    state.scroll_y = 0;
    let page = &state.pages[index];
    state.content_height = page.height;
    for (child, x, y) in &page.children {
        let _ = SetWindowPos(
            *child,
            None,
            *x,
            *y,
            0,
            0,
            SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW,
        );
    }
    let _ = InvalidateRect(page.nav, None, false);
    let _ = InvalidateRect(hwnd, None, false);
    configure_scrollbar(hwnd, state);
}

fn rect(left: i32, top: i32, right: i32, bottom: i32) -> RECT {
    RECT {
        left,
        top,
        right,
        bottom,
    }
}

unsafe fn fill(dc: HDC, rect: RECT, color: COLORREF) {
    let brush = CreateSolidBrush(color);
    FillRect(dc, &rect, brush);
    let _ = DeleteObject(brush);
}

unsafe fn smooth_fill(graphics: *mut GpGraphics, rect: RECT, diameter: i32, color: COLORREF) {
    let width = rect.right - rect.left;
    let height = rect.bottom - rect.top;
    let diameter = diameter.min(width).min(height) as f32;
    if diameter <= 0.0 {
        return;
    }
    let mut path = std::ptr::null_mut();
    if GdipCreatePath(FillModeAlternate, &mut path).0 != 0 {
        return;
    }
    let x = rect.left as f32;
    let y = rect.top as f32;
    let right = rect.right as f32 - diameter;
    let bottom = rect.bottom as f32 - diameter;
    for (x, y, angle) in [
        (x, y, 180.0),
        (right, y, 270.0),
        (right, bottom, 0.0),
        (x, bottom, 90.0),
    ] {
        GdipAddPathArc(path, x, y, diameter, diameter, angle, 90.0);
    }
    GdipClosePathFigure(path);
    let rgb = color.0;
    let argb = 0xff00_0000 | (rgb & 0xff) << 16 | rgb & 0xff00 | (rgb >> 16 & 0xff);
    let mut brush = std::ptr::null_mut();
    if GdipCreateSolidFill(argb, &mut brush).0 == 0 {
        GdipFillPath(graphics, brush.cast(), path);
        GdipDeleteBrush(brush.cast());
    }
    GdipDeletePath(path);
}
unsafe fn rounded(dc: HDC, bounds: RECT, radius: i32, color: COLORREF, border: COLORREF) {
    static GDI_PLUS: OnceLock<usize> = OnceLock::new();
    let token = GDI_PLUS.get_or_init(|| {
        let mut token = 0;
        let input = GdiplusStartupInput {
            GdiplusVersion: 1,
            ..Default::default()
        };
        if GdiplusStartup(&mut token, &input, std::ptr::null_mut()).0 == 0 {
            token
        } else {
            0
        }
    });
    let mut graphics = std::ptr::null_mut();
    if *token != 0 && GdipCreateFromHDC(dc, &mut graphics).0 == 0 {
        GdipSetSmoothingMode(graphics, SmoothingModeAntiAlias8x8);
        if border == color {
            smooth_fill(graphics, bounds, radius, color);
        } else {
            smooth_fill(graphics, bounds, radius, border);
            let inner = rect(
                bounds.left + 1,
                bounds.top + 1,
                bounds.right - 1,
                bounds.bottom - 1,
            );
            smooth_fill(graphics, inner, radius - 2, color);
        }
        GdipDeleteGraphics(graphics);
        return;
    }
    let rect = bounds;
    let brush = CreateSolidBrush(color);
    let pen = CreatePen(PS_SOLID, 1, border);
    let previous_brush = SelectObject(dc, brush);
    let previous_pen = SelectObject(dc, pen);
    let _ = RoundRect(
        dc,
        rect.left,
        rect.top,
        rect.right,
        rect.bottom,
        radius,
        radius,
    );
    SelectObject(dc, previous_brush);
    SelectObject(dc, previous_pen);
    let _ = DeleteObject(brush);
    let _ = DeleteObject(pen);
}

unsafe fn paint_settings(hwnd: HWND, state: &SettingsState) {
    let mut paint = PAINTSTRUCT::default();
    let dc = BeginPaint(hwnd, &mut paint);
    let mut client = RECT::default();
    let _ = GetClientRect(hwnd, &mut client);
    fill(dc, client, BACK);
    fill(dc, rect(0, 0, SIDEBAR, client.bottom), SIDEBAR_BACK);
    fill(
        dc,
        rect(SIDEBAR - 1, 0, SIDEBAR, client.bottom),
        COLORREF(0x3f3f3e),
    );
    if let Some(page) = state.pages.get(state.selected) {
        for &(top, bottom) in &page.groups {
            rounded(
                dc,
                rect(
                    SIDEBAR + MARGIN,
                    top - state.scroll_y,
                    client.right - MARGIN,
                    bottom - state.scroll_y,
                ),
                10,
                PANEL,
                COLORREF(0x444443),
            );
        }
    }
    let _ = EndPaint(hwnd, &paint);
}

unsafe fn draw_nav(item: &DRAWITEMSTRUCT, state: &SettingsState) {
    let index = (item.CtlID as i32 - NAV_ID) as usize;
    let Some(page) = state.pages.get(index) else {
        return;
    };
    let dc = item.hDC;
    let bounds = item.rcItem;
    let selected = state.selected == index;
    let focused = item.itemState.0 & (ODS_FOCUS.0 | ODS_SELECTED.0) != 0;
    fill(dc, bounds, SIDEBAR_BACK);
    if selected || focused {
        let color = if selected { BLUE } else { COLORREF(0x403c35) };
        rounded(dc, bounds, 9, color, color);
    }
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, if selected { TEXT } else { COLORREF(0xf89926) });
    let old = SelectObject(dc, state.icon_font);
    DrawTextW(
        dc,
        &mut [page.icon],
        &mut rect(8, 0, 30, bounds.bottom),
        DT_SINGLELINE | DT_VCENTER,
    );
    SelectObject(dc, state.font);
    SetTextColor(dc, if selected { TEXT } else { COLORREF(0xd6d6d6) });
    let mut text = [0u16; 128];
    let len = GetWindowTextW(item.hwndItem, &mut text).max(0) as usize;
    DrawTextW(
        dc,
        &mut text[..len],
        &mut rect(33, 0, bounds.right - 8, bounds.bottom),
        DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS,
    );
    SelectObject(dc, old);
}

unsafe fn style_input(hwnd: HWND) {
    let _ = SetWindowTheme(hwnd, w!("DarkMode_Explorer"), None);
    let mut bounds = RECT::default();
    if GetWindowRect(hwnd, &mut bounds).is_ok() {
        let region = CreateRoundRectRgn(
            0,
            0,
            bounds.right - bounds.left + 1,
            bounds.bottom - bounds.top + 1,
            8,
            8,
        );
        if !region.is_invalid() && SetWindowRgn(hwnd, region, true) == 0 {
            let _ = DeleteObject(region);
        }
    }
    SendMessageW(
        hwnd,
        EM_SETMARGINS,
        WPARAM((EC_LEFTMARGIN | EC_RIGHTMARGIN) as usize),
        LPARAM(6 | 6 << 16),
    );
}

unsafe fn settings_font(height: i32, weight: i32) -> HFONT {
    CreateFontW(
        height,
        0,
        0,
        0,
        weight,
        0,
        0,
        0,
        DEFAULT_CHARSET.0.into(),
        0,
        0,
        CLEARTYPE_NATURAL_QUALITY,
        0,
        w!("Microsoft YaHei UI"),
    )
}

unsafe fn style_combo(hwnd: HWND) {
    let _ = SetWindowTheme(hwnd, w!("DarkMode_Explorer"), None);
    SendMessageW(hwnd, CB_SETITEMHEIGHT, WPARAM(usize::MAX), LPARAM(22));
    SendMessageW(hwnd, CB_SETITEMHEIGHT, WPARAM(0), LPARAM(28));
    let _ = SetWindowSubclass(hwnd, Some(combo_proc), 1, 0);
}

unsafe fn combo_text(hwnd: HWND, index: usize) -> Vec<u16> {
    let len = SendMessageW(hwnd, CB_GETLBTEXTLEN, WPARAM(index), LPARAM(0)).0;
    if len < 0 {
        return Vec::new();
    }
    let mut text = vec![0; len as usize + 1];
    SendMessageW(
        hwnd,
        CB_GETLBTEXT,
        WPARAM(index),
        LPARAM(text.as_mut_ptr() as isize),
    );
    text.truncate(len as usize);
    text
}

unsafe fn draw_combo_text(dc: HDC, font: HFONT, mut text: Vec<u16>, mut bounds: RECT) {
    bounds.left += 10;
    bounds.right -= 8;
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, TEXT);
    let old = SelectObject(dc, font);
    DrawTextW(
        dc,
        &mut text,
        &mut bounds,
        DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS,
    );
    SelectObject(dc, old);
}

unsafe fn draw_combo_item(item: &DRAWITEMSTRUCT, font: HFONT) {
    let bounds = item.rcItem;
    let selected = item.itemState.0 & ODS_SELECTED.0 != 0;
    fill(item.hDC, bounds, PANEL);
    if selected {
        rounded(
            item.hDC,
            rect(
                bounds.left + 3,
                bounds.top + 1,
                bounds.right - 3,
                bounds.bottom - 1,
            ),
            8,
            BLUE,
            BLUE,
        );
    }
    draw_combo_text(
        item.hDC,
        font,
        combo_text(item.hwndItem, item.itemID as usize),
        bounds,
    );
}

unsafe extern "system" fn combo_proc(
    hwnd: HWND,
    message: u32,
    wp: WPARAM,
    lp: LPARAM,
    id: usize,
    _: usize,
) -> LRESULT {
    if message == WM_NCDESTROY {
        let _ = RemoveWindowSubclass(hwnd, Some(combo_proc), id);
    }
    if message != WM_PAINT {
        let result = DefSubclassProc(hwnd, message, wp, lp);
        if matches!(
            message,
            CB_SETCURSEL | CB_SHOWDROPDOWN | WM_SETFOCUS | WM_KILLFOCUS | WM_KEYDOWN | WM_LBUTTONUP
        ) {
            let _ = InvalidateRect(hwnd, None, false);
        }
        return result;
    }
    let mut paint = PAINTSTRUCT::default();
    let dc = BeginPaint(hwnd, &mut paint);
    let mut bounds = RECT::default();
    let _ = GetClientRect(hwnd, &mut bounds);
    let focused = windows::Win32::UI::Input::KeyboardAndMouse::GetFocus() == hwnd;
    fill(dc, bounds, PANEL);
    rounded(
        dc,
        bounds,
        9,
        COLORREF(0x383837),
        if focused { BLUE } else { COLORREF(0x4a4a49) },
    );
    let font = HFONT(SendMessageW(hwnd, WM_GETFONT, WPARAM(0), LPARAM(0)).0 as _);
    let index = SendMessageW(hwnd, CB_GETCURSEL, WPARAM(0), LPARAM(0)).0 as usize;
    draw_combo_text(
        dc,
        font,
        combo_text(hwnd, index),
        rect(0, 0, bounds.right - 22, bounds.bottom),
    );

    let x = bounds.right - 14;
    let y = bounds.bottom / 2;
    let pen = CreatePen(PS_SOLID, 2, MUTED);
    let old = SelectObject(dc, pen);
    let _ = MoveToEx(dc, x - 4, y - 2, None);
    let _ = LineTo(dc, x, y + 2);
    let _ = LineTo(dc, x + 5, y - 3);
    SelectObject(dc, old);
    let _ = DeleteObject(pen);
    let _ = EndPaint(hwnd, &paint);
    LRESULT(0)
}

unsafe extern "system" fn hotkey_proc(
    hwnd: HWND,
    message: u32,
    wp: WPARAM,
    lp: LPARAM,
    id: usize,
    _: usize,
) -> LRESULT {
    if message == WM_NCDESTROY {
        let _ = RemoveWindowSubclass(hwnd, Some(hotkey_proc), id);
    }
    if message == WM_NCPAINT {
        return LRESULT(0);
    }
    if message != WM_PAINT {
        let result = DefSubclassProc(hwnd, message, wp, lp);
        if matches!(
            message,
            HKM_SETHOTKEY
                | WM_KEYDOWN
                | WM_KEYUP
                | WM_SYSKEYDOWN
                | WM_SYSKEYUP
                | WM_SETFOCUS
                | WM_KILLFOCUS
        ) {
            let _ = InvalidateRect(hwnd, None, false);
        }
        return result;
    }
    let mut paint = PAINTSTRUCT::default();
    let dc = BeginPaint(hwnd, &mut paint);
    let mut bounds = RECT::default();
    let _ = GetClientRect(hwnd, &mut bounds);
    let focused = windows::Win32::UI::Input::KeyboardAndMouse::GetFocus() == hwnd;
    fill(dc, bounds, PANEL);
    rounded(
        dc,
        bounds,
        8,
        INPUT,
        if focused { BLUE } else { COLORREF(0x4a4a49) },
    );
    let packed = SendMessageW(hwnd, HKM_GETHOTKEY, WPARAM(0), LPARAM(0)).0 as u16;
    let combo = from_hotkey_control(packed as u8, (packed >> 8) as u8);
    let label = if combo.is_empty() {
        if focused {
            "请按下快捷键"
        } else {
            "未设置"
        }
    } else {
        &combo
    };
    let font = HFONT(SendMessageW(hwnd, WM_GETFONT, WPARAM(0), LPARAM(0)).0 as _);
    draw_combo_text(dc, font, label.encode_utf16().collect(), bounds);
    let _ = EndPaint(hwnd, &paint);
    LRESULT(0)
}

unsafe fn draw_action(item: &DRAWITEMSTRUCT, font: HFONT) {
    let dc = item.hDC;
    let mut bounds = item.rcItem;
    let pressed = item.itemState.0 & ODS_SELECTED.0 != 0;
    let disabled = item.itemState.0 & windows::Win32::UI::Controls::ODS_DISABLED.0 != 0;
    fill(dc, bounds, PANEL);
    rounded(
        dc,
        bounds,
        8,
        COLORREF(if pressed { 0x5b5b59 } else { 0x414140 }),
        COLORREF(0x575756),
    );
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, if disabled { MUTED } else { TEXT });
    let old = SelectObject(dc, font);
    let mut label: Vec<u16> = window_text(item.hwndItem).encode_utf16().collect();
    DrawTextW(
        dc,
        &mut label,
        &mut bounds,
        DT_CENTER | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS,
    );
    SelectObject(dc, old);
}
unsafe fn draw_switch(item: &DRAWITEMSTRUCT, checked: bool) {
    let dc = item.hDC;
    fill(dc, item.rcItem, PANEL);
    let color = if checked { BLUE } else { COLORREF(0x555554) };
    let focused = item.itemState.0 & ODS_FOCUS.0 != 0;
    rounded(
        dc,
        rect(0, 4, 26, 20),
        16,
        color,
        if focused { MUTED } else { color },
    );
    let x = if checked { 12 } else { 2 };
    rounded(dc, rect(x, 6, x + 12, 18), 12, TEXT, TEXT);
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
    if message == WM_PICK_FOLDER {
        let initial = (*pointer)
            .controls
            .iter()
            .find(|bound| bound.kind == Kind::Folder)
            .map(|bound| {
                bound
                    .field
                    .value(&(*pointer).config.borrow(), &bound.section)
            })
            .unwrap_or_default();
        match choose_folder(hwnd, &initial) {
            Ok(Some(path)) if GetWindowLongPtrW(hwnd, GWLP_USERDATA) == pointer as isize => {
                update_folder(&mut *pointer, &path);
            }
            Ok(_) => {}
            Err(error) => {
                let message = wide(&format!("无法打开目录选择器：{error}"));
                let _ = MessageBoxW(
                    hwnd,
                    PCWSTR(message.as_ptr()),
                    w!("BaoBox"),
                    MB_OK | MB_ICONWARNING,
                );
            }
        }
        return LRESULT(0);
    }
    let state = &mut *pointer;

    match message {
        WM_COMMAND => {
            let id = (wparam.0 & 0xFFFF) as i32;
            let code = ((wparam.0 >> 16) & 0xFFFF) as u32;
            if id == OPEN_PETS_ID {
                if let Some(directory) = crate::pet_pack::directory() {
                    if std::fs::create_dir_all(&directory).is_ok() {
                        let folder = wide(&directory.to_string_lossy());
                        let _ = windows::Win32::UI::Shell::ShellExecuteW(
                            hwnd,
                            w!("open"),
                            PCWSTR(folder.as_ptr()),
                            None,
                            None,
                            SW_SHOWNORMAL,
                        );
                    }
                }
                return LRESULT(0);
            }
            if id >= NUMBER_STEP_ID {
                let step = id - NUMBER_STEP_ID;
                if code == BN_CLICKED {
                    step_number(
                        state,
                        FIRST_CONTROL + step / 2,
                        if step % 2 == 0 { -1 } else { 1 },
                    );
                }
                return LRESULT(0);
            }
            if id == DEFAULT_FOLDER_ID {
                update_folder(state, "");
                return LRESULT(0);
            }
            if id >= DOWNLOAD_ID {
                (state.on_download)((id - DOWNLOAD_ID) as usize);
                return LRESULT(0);
            }
            if let Some(index) = id
                .checked_sub(NAV_ID)
                .filter(|id| (0..FIRST_CONTROL - NAV_ID).contains(id))
            {
                select_page(hwnd, state, index as usize);
            } else {
                handle_command(state, id, code);
            }
            LRESULT(0)
        }
        WM_PAINT => {
            paint_settings(hwnd, state);
            LRESULT(0)
        }
        WM_DRAWITEM => {
            let item = &*(lparam.0 as *const DRAWITEMSTRUCT);
            if (NAV_ID..FIRST_CONTROL).contains(&(wparam.0 as i32)) {
                draw_nav(item, state);
            } else if item.CtlType == windows::Win32::UI::Controls::ODT_COMBOBOX {
                draw_combo_item(item, state.font);
            } else if item.CtlID >= OPEN_PETS_ID as u32 {
                draw_action(item, state.font);
            } else if let Some(bound) = state
                .controls
                .iter()
                .find(|bound| bound.id == item.CtlID as i32)
            {
                if bound.kind == Kind::Folder {
                    draw_action(item, state.font);
                    return LRESULT(1);
                }
                if bound.kind != Kind::Check {
                    return LRESULT(0);
                }
                let checked = bound.field.value(&state.config.borrow(), &bound.section) == "true";
                draw_switch(item, checked);
            }
            LRESULT(1)
        }
        WM_CTLCOLORSTATIC | WM_CTLCOLOREDIT | WM_CTLCOLORLISTBOX | WM_CTLCOLORBTN => {
            let dc = HDC(wparam.0 as _);
            SetTextColor(dc, TEXT);
            if message == WM_CTLCOLORSTATIC
                && SendMessageW(HWND(lparam.0 as _), WM_GETFONT, WPARAM(0), LPARAM(0)).0
                    == state.title_font.0 as isize
            {
                SetBkColor(dc, BACK);
                return LRESULT(state.background_brush.0 as isize);
            }
            if message == WM_CTLCOLOREDIT {
                SetBkColor(dc, INPUT);
                return LRESULT(state.input_brush.0 as isize);
            }
            SetBkColor(dc, PANEL);
            LRESULT(state.panel_brush.0 as isize)
        }
        WM_NOTIFY => {
            let header = &*(lparam.0 as *const windows::Win32::UI::Controls::NMHDR);
            if header.code == NM_CUSTOMDRAW
                && state
                    .controls
                    .iter()
                    .any(|bound| bound.hwnd == header.hwndFrom && bound.kind == Kind::Slider)
            {
                let draw = &*(lparam.0 as *const NMCUSTOMDRAW);
                if draw.dwDrawStage == CDDS_PREPAINT {
                    let mut thumb = RECT::default();
                    SendMessageW(
                        header.hwndFrom,
                        TBM_GETTHUMBRECT,
                        WPARAM(0),
                        LPARAM(&mut thumb as *mut RECT as isize),
                    );
                    let mut client = RECT::default();
                    let _ = GetClientRect(header.hwndFrom, &mut client);
                    let width = client.right;
                    let y = client.bottom / 2;
                    let x = (thumb.left + thumb.right) / 2;
                    fill(draw.hdc, client, PANEL);
                    rounded(
                        draw.hdc,
                        rect(8, y - 2, width - 8, y + 2),
                        4,
                        COLORREF(0x494948),
                        COLORREF(0x494948),
                    );
                    if x > 8 {
                        rounded(draw.hdc, rect(8, y - 2, x, y + 2), 4, BLUE, BLUE);
                    }
                    rounded(draw.hdc, rect(x - 9, y - 9, x + 9, y + 9), 18, TEXT, TEXT);
                    return LRESULT(CDRF_SKIPDEFAULT as isize);
                }
            }
            DefWindowProcW(hwnd, message, wparam, lparam)
        }
        WM_HSCROLL if lparam.0 != 0 => {
            let slider = HWND(lparam.0 as _);
            if let Some(bound) = state
                .controls
                .iter()
                .find(|bound| bound.hwnd == slider && bound.kind == Kind::Slider)
            {
                let value = SendMessageW(slider, TBM_GETPOS, WPARAM(0), LPARAM(0))
                    .0
                    .to_string();
                let mut config = state.config.borrow_mut();
                if config.get(&bound.section, "size") != Some("custom")
                    || config.get(&bound.section, "custom-size") != Some(value.as_str())
                {
                    config.set(&bound.section, "size", "custom");
                    bound.field.store(&mut config, &bound.section, &value);
                    (state.on_change)(&config);
                }
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
            // 而且可能要把已经滚过头的位置收回来
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
            if !state.title_font.is_invalid() {
                let _ = DeleteObject(state.title_font);
            }
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            let _ = DeleteObject(state.panel_brush);
            let _ = DeleteObject(state.input_brush);
            let _ = DeleteObject(state.background_brush);
            let _ = DeleteObject(state.icon_font);
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

    let pet_range = bound.section == crate::pet::ID && bound.field.key == "range";
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
            if code != BN_CLICKED {
                return;
            }
            (bound.field.value(&state.config.borrow(), &bound.section) != "true").to_string()
        }
        Kind::Combo => {
            let dropped = SendMessageW(hwnd, CB_GETDROPPEDSTATE, WPARAM(0), LPARAM(0)).0 != 0;
            if !(code == CBN_SELCHANGE && (!pet_range || !dropped)
                || pet_range && code == CBN_SELENDOK)
            {
                return;
            }
            let index = SendMessageW(hwnd, CB_GETCURSEL, WPARAM(0), LPARAM(0)).0;
            match &bound.field.kind {
                FieldKind::Choice { options, default } => options
                    .get(index as usize)
                    .map(|(stored, _)| stored.clone())
                    .unwrap_or_else(|| default.clone()),
                _ => return,
            }
        }
        Kind::Folder => {
            if code == BN_CLICKED {
                if let Ok(parent) = GetParent(hwnd) {
                    let _ = PostMessageW(parent, WM_PICK_FOLDER, WPARAM(0), LPARAM(0));
                }
            }
            return;
        }
        Kind::Number => {
            if code == EN_KILLFOCUS {
                update_number(state, index, &window_text(hwnd));
            }
            return;
        }
        Kind::Slider => return,
        Kind::Edit => {
            if code != EN_CHANGE {
                return;
            }
            window_text(hwnd)
        }
    };

    if pet_range && value == "custom" {
        if !state.picking_area {
            state.picking_area = true;
            (state.on_pick_area)();
        }
        return;
    }
    if bound.section == "general" && bound.field.key == "autostart" {
        if let Err(error) = set_starts_at_login(value == "true") {
            let message = wide(&format!("无法修改开机启动：{error}"));
            let _ = MessageBoxW(
                GetParent(hwnd).unwrap_or_default(),
                PCWSTR(message.as_ptr()),
                w!("BaoBox"),
                MB_OK | MB_ICONWARNING,
            );
            return;
        }
        bound
            .field
            .store(&mut state.config.borrow_mut(), &bound.section, &value);
        let _ = InvalidateRect(hwnd, None, false);
        return;
    }
    {
        let mut config = state.config.borrow_mut();
        if pet_range && value == bound.field.value(&config, &bound.section) {
            return;
        }
        bound.field.store(&mut config, &bound.section, &value);
    }
    let _ = InvalidateRect(hwnd, None, false);
    (state.on_change)(&state.config.borrow());
}

fn folder_label(path: &str) -> &str {
    if path.is_empty() {
        "图片\\Baobox · 更改…"
    } else {
        path
    }
}

unsafe fn choose_folder(owner: HWND, initial: &str) -> windows::core::Result<Option<String>> {
    use windows::Win32::UI::Shell::{
        FileOpenDialog, IFileOpenDialog, IShellItem, SHCreateItemFromParsingName,
        FOS_FORCEFILESYSTEM, FOS_PATHMUSTEXIST, FOS_PICKFOLDERS, SIGDN_FILESYSPATH,
    };
    CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok()?;
    struct Com;
    impl Drop for Com {
        fn drop(&mut self) {
            unsafe {
                CoUninitialize();
            }
        }
    }
    let _com = Com;
    let dialog: IFileOpenDialog = CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER)?;
    dialog.SetTitle(w!("选择截图保存文件夹"))?;
    dialog.SetOptions(
        dialog.GetOptions()? | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST,
    )?;
    if initial.is_empty() {
        use windows::Win32::UI::Shell::{FOLDERID_Pictures, SHGetKnownFolderItem, KF_FLAG_DEFAULT};
        if let Ok(folder) =
            SHGetKnownFolderItem::<_, IShellItem>(&FOLDERID_Pictures, KF_FLAG_DEFAULT, None)
        {
            let _ = dialog.SetDefaultFolder(&folder);
        }
    } else {
        let initial = wide(initial);
        if let Ok(folder) =
            SHCreateItemFromParsingName::<_, _, IShellItem>(PCWSTR(initial.as_ptr()), None)
        {
            let _ = dialog.SetFolder(&folder);
        }
    }
    if let Err(error) = dialog.Show(owner) {
        if error.code() == windows::core::HRESULT::from_win32(1223) {
            return Ok(None);
        }
        return Err(error);
    }
    let path = dialog.GetResult()?.GetDisplayName(SIGDN_FILESYSPATH)?;
    let result = path.to_string();
    CoTaskMemFree(Some(path.0.cast()));
    Ok(Some(result?))
}

unsafe fn update_folder(state: &mut SettingsState, path: &str) {
    let Some(bound) = state
        .controls
        .iter()
        .find(|bound| bound.kind == Kind::Folder)
    else {
        return;
    };
    let mut config = state.config.borrow_mut();
    if bound.field.value(&config, &bound.section) == path {
        return;
    }
    bound.field.store(&mut config, &bound.section, path);
    let label = wide(folder_label(path));
    let _ = SetWindowTextW(bound.hwnd, PCWSTR(label.as_ptr()));
    let _ = InvalidateRect(bound.hwnd, None, false);
    (state.on_change)(&config);
}

unsafe fn step_number(state: &mut SettingsState, id: i32, delta: i64) {
    let Some(index) = state
        .controls
        .iter()
        .position(|bound| bound.id == id && bound.kind == Kind::Number)
    else {
        return;
    };
    let bound = &state.controls[index];
    let stored = bound.field.value(&state.config.borrow(), &bound.section);
    if let Ok(value) = stored.parse::<i64>() {
        update_number(state, index, &value.saturating_add(delta).to_string());
    }
}

unsafe fn update_number(state: &mut SettingsState, index: usize, input: &str) {
    let bound = &state.controls[index];
    let mut config = state.config.borrow_mut();
    let previous = bound.field.value(&config, &bound.section);
    if input.trim().parse::<i64>().is_ok() {
        bound.field.store(&mut config, &bound.section, input);
    }
    let current = bound.field.value(&config, &bound.section);
    if current != window_text(bound.hwnd) {
        let text = wide(&current);
        let _ = SetWindowTextW(bound.hwnd, PCWSTR(text.as_ptr()));
    }
    if current != previous {
        (state.on_change)(&config);
    }
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
unsafe fn starts_at_login() -> bool {
    let mut length = 0;
    RegGetValueW(
        HKEY_CURRENT_USER,
        RUN_KEY,
        RUN_VALUE,
        RRF_RT_REG_SZ,
        None,
        None,
        Some(&mut length),
    )
    .is_ok()
}

unsafe fn set_starts_at_login(enabled: bool) -> Result<(), String> {
    if enabled {
        let exe = std::env::current_exe().map_err(|error| error.to_string())?;
        let command = wide(&format!("\"{}\"", exe.display()));
        RegSetKeyValueW(
            HKEY_CURRENT_USER,
            RUN_KEY,
            RUN_VALUE,
            REG_SZ.0,
            Some(command.as_ptr().cast()),
            (command.len() * 2) as u32,
        )
        .ok()
        .map_err(|error| error.to_string())
    } else {
        let result = RegDeleteKeyValueW(HKEY_CURRENT_USER, RUN_KEY, RUN_VALUE);
        if result == windows::Win32::Foundation::ERROR_FILE_NOT_FOUND {
            return Ok(());
        }
        result.ok().map_err(|error| error.to_string())
    }
}

pub unsafe fn route_input(hwnd: HWND, message: &MSG) -> bool {
    if message.message == WM_MOUSEWHEEL && GetAncestor(message.hwnd, GA_ROOT) == hwnd {
        SendMessageW(hwnd, WM_MOUSEWHEEL, message.wParam, message.lParam);
        return true;
    }
    if message.message == WM_KEYDOWN
        && message.wParam.0 == 0x0d
        && GetParent(message.hwnd).ok() == Some(hwnd)
    {
        let mut class = [0u16; 8];
        let len = GetClassNameW(message.hwnd, &mut class).max(0) as usize;
        if class[..len] == *w!("Edit").as_wide() {
            let id = GetDlgCtrlID(message.hwnd) as usize;
            SendMessageW(
                hwnd,
                WM_COMMAND,
                WPARAM(id | (EN_KILLFOCUS as usize) << 16),
                LPARAM(message.hwnd.0 as isize),
            );
            return true;
        }
    }
    IsDialogMessageW(hwnd, message).as_bool()
}
pub fn refresh_pet(hwnd: HWND, config: &Config) {
    sync_pet_settings(hwnd, config, false);
}

pub fn finish_area_pick(hwnd: HWND, config: &Config) {
    sync_pet_settings(hwnd, config, true);
}
fn sync_pet_settings(hwnd: HWND, config: &Config, finished_pick: bool) {
    unsafe {
        let mut class = [0u16; 32];
        let len = GetClassNameW(hwnd, &mut class).max(0) as usize;
        if class[..len] != *CLASS_NAME.as_wide() {
            return;
        }
        let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut SettingsState;
        let Some(state) = pointer.as_mut() else {
            return;
        };
        if finished_pick {
            state.picking_area = false;
        }
        if !state.picking_area {
            if let Some(bound) = state
                .controls
                .iter()
                .find(|bound| bound.section == crate::pet::ID && bound.field.key == "range")
            {
                if let FieldKind::Choice { options, .. } = &bound.field.kind {
                    let value = bound.field.value(config, &bound.section);
                    if let Some(index) = options.iter().position(|(key, _)| *key == value) {
                        if SendMessageW(bound.hwnd, CB_GETCURSEL, WPARAM(0), LPARAM(0)).0
                            != index as isize
                        {
                            SendMessageW(bound.hwnd, CB_SETCURSEL, WPARAM(index), LPARAM(0));
                        }
                    }
                }
            }
        }
        let mut catalog_changed = false;
        for (index, entry) in crate::pet_download::catalog().iter().enumerate() {
            let Ok(button) = GetDlgItem(hwnd, DOWNLOAD_ID + index as i32) else {
                continue;
            };
            let installed = crate::pet_download::installed(&entry.id);
            let enabled =
                windows::Win32::UI::Input::KeyboardAndMouse::IsWindowEnabled(button).as_bool();
            if installed == enabled {
                catalog_changed = true;
                let _ = SetWindowTextW(
                    button,
                    if installed {
                        w!("已安装")
                    } else {
                        w!("下载")
                    },
                );
                let _ =
                    windows::Win32::UI::Input::KeyboardAndMouse::EnableWindow(button, !installed);
            }
        }
        let section = crate::pet::ID;
        let old_character = state
            .config
            .borrow()
            .string_or(section, "character", "plush-cat");
        let character = config.string_or(section, "character", "plush-cat");
        if catalog_changed || old_character != character {
            if let Some(bound) = state
                .controls
                .iter_mut()
                .find(|bound| bound.section == section && bound.field.key == "character")
            {
                if let FieldKind::Choice { options, .. } = &mut bound.field.kind {
                    *options = std::iter::once((String::new(), "内置像素猫".into()))
                        .chain(
                            crate::pet_pack::list()
                                .into_iter()
                                .map(|entry| (entry.id, entry.name)),
                        )
                        .collect();
                    SendMessageW(bound.hwnd, CB_RESETCONTENT, WPARAM(0), LPARAM(0));
                    for (index, (id, label)) in options.iter().enumerate() {
                        let label = wide(label);
                        SendMessageW(
                            bound.hwnd,
                            CB_ADDSTRING,
                            WPARAM(0),
                            LPARAM(label.as_ptr() as isize),
                        );
                        if *id == character {
                            SendMessageW(bound.hwnd, CB_SETCURSEL, WPARAM(index), LPARAM(0));
                        }
                    }
                }
            }
        }
        let mut config = config.clone();
        config.set_bool("general", "autostart", starts_at_login());
        state.config.replace(config);
    }
}

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
        for text in [
            "Ctrl+Shift+S",
            "Alt+F4",
            "Ctrl+Alt+P",
            "Ctrl+Space",
            "PrintScreen",
        ] {
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
        assert_eq!(
            modifiers, 0,
            "Win 键不该被映射成 Ctrl/Alt/Shift 里的任何一个"
        );
    }

    #[test]
    fn the_window_grows_with_the_number_of_settings() {
        let one = window_height(&[SettingsPage::new(
            "s",
            "一项",
            vec![Field::toggle("a", "开关", true)],
        )]);
        let many = window_height(&[page()]);
        assert!(many > one, "多几项就该高一些，否则控件会被挤到窗口外");
        // 带说明的那一项要多留一行
        let without_help = window_height(&[SettingsPage::new(
            "s",
            "测试",
            vec![Field::toggle("a", "开关", true)],
        )]);
        let with_help = window_height(&[SettingsPage::new(
            "s",
            "测试",
            vec![Field::toggle("a", "开关", true).with_help("说明")],
        )]);
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
    fn three_tools_worth_of_settings_no_longer_fit_in_one_screen() {
        // 这条测试记的是「为什么会有滚动条」：三个工具已经超过 640，
        // 而 768 高的笔记本扣掉任务栏就摆不下更高的窗口了
        let many: Vec<SettingsPage> = (0..3)
            .map(|n| {
                SettingsPage::new(
                    "s",
                    "页",
                    (0..4)
                        .map(|m| Field::toggle(&format!("k{n}{m}"), "开关", true).with_help("说明"))
                        .collect(),
                )
            })
            .collect();
        assert!(window_height(&many) > 640, "超过一屏就必须能滚");
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
