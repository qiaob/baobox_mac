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
    BST_CHECKED, BST_UNCHECKED, HKM_GETHOTKEY, HKM_SETHOTKEY, HOTKEYF_ALT, HOTKEYF_CONTROL,
    HOTKEYF_SHIFT, UDM_SETPOS32, UDM_SETRANGE32, UDS_SETBUDDYINT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, GetWindowLongPtrW, GetWindowTextLengthW,
    GetWindowTextW, LoadCursorW, RegisterClassW, SendMessageW, SetWindowLongPtrW,
    ShowWindow, SystemParametersInfoW, BM_GETCHECK, BM_SETCHECK, BS_AUTOCHECKBOX, CBN_SELCHANGE,
    CB_ADDSTRING, CB_GETCURSEL, CB_SETCURSEL, CBS_DROPDOWNLIST, EN_CHANGE, ES_AUTOHSCROLL,
    GWLP_USERDATA, IDC_ARROW, NONCLIENTMETRICSW, SPI_GETNONCLIENTMETRICS,
    SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SW_SHOW, WM_COMMAND, WM_DESTROY, WM_SETFONT, WNDCLASSW,
    WS_CHILD, WS_EX_CLIENTEDGE, WS_OVERLAPPEDWINDOW, WS_TABSTOP, WS_VISIBLE, WS_VSCROLL,
};

/// 设置窗口类名。
const CLASS_NAME: PCWSTR = w!("BaoboxSettings");

/// 控件 id 从这里开始编 —— 低位留给系统的标准 id（IDOK 之类）。
const FIRST_CONTROL: i32 = 100;

/// 行距与各段宽度（像素，96 DPI 下的基准）。
const ROW_HEIGHT: i32 = 30;
const HELP_HEIGHT: i32 = 18;
const MARGIN: i32 = 16;
const LABEL_WIDTH: i32 = 220;
const CONTROL_WIDTH: i32 = 200;
const WINDOW_WIDTH: i32 = 520;

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
}

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

        let height = window_height(&pages);
        let hwnd = CreateWindowExW(
            Default::default(),
            CLASS_NAME,
            w!("Baobox 设置"),
            WS_OVERLAPPEDWINDOW | WS_VSCROLL,
            windows::Win32::UI::WindowsAndMessaging::CW_USEDEFAULT,
            windows::Win32::UI::WindowsAndMessaging::CW_USEDEFAULT,
            WINDOW_WIDTH,
            height.min(720),
            None,
            None,
            instance,
            None,
        )
        .map_err(|e| format!("创建设置窗口失败：{e}"))?;

        let font = message_font();
        let mut state = Box::new(SettingsState {
            controls: Vec::new(),
            config: RefCell::new(config),
            on_change,
            font,
        });
        build(hwnd, instance, &pages, &mut state);
        SetWindowLongPtrW(
            hwnd,
            GWLP_USERDATA,
            Box::into_raw(state) as isize,
        );

        let _ = ShowWindow(hwnd, SW_SHOW);
        Ok(hwnd)
    }
}

/// 窗口该多高：所有页的所有行加起来。
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
    pages: &[SettingsPage],
    state: &mut SettingsState,
) {
    let mut y = MARGIN;
    let mut id = FIRST_CONTROL;

    for page in pages {
        // 页标题：一条加粗的分组标签
        static_text(parent, instance, &page.title, MARGIN, y, WINDOW_WIDTH - MARGIN * 2, state.font);
        y += ROW_HEIGHT;

        for field in &page.fields {
            let value = field.value(&state.config.borrow(), &page.section);
            let control_x = MARGIN + LABEL_WIDTH;

            let (hwnd, kind) = match &field.kind {
                FieldKind::Toggle { .. } => {
                    // 复选框自带文字，不再单独放标签
                    let hwnd = control(
                        parent, instance, w!("BUTTON"), &field.label,
                        (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | BS_AUTOCHECKBOX as u32,
                        MARGIN, y, LABEL_WIDTH + CONTROL_WIDTH, 22, id, state.font,
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
                    static_text(parent, instance, &field.label, MARGIN, y + 3, LABEL_WIDTH, state.font);
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
                    static_text(parent, instance, &field.label, MARGIN, y + 3, LABEL_WIDTH, state.font);
                    let edit = control(
                        parent, instance, w!("EDIT"), &value,
                        (WS_CHILD | WS_VISIBLE | WS_TABSTOP).0 | ES_AUTOHSCROLL as u32,
                        control_x, y, 80, 22, id, state.font,
                    );
                    // 配一个上下箭头，省得用户手打数字
                    let spin = control(
                        parent, instance, w!("msctls_updown32"), "",
                        (WS_CHILD | WS_VISIBLE).0 | UDS_SETBUDDYINT as u32,
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
                    static_text(parent, instance, &field.label, MARGIN, y + 3, LABEL_WIDTH, state.font);
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
                    static_text(parent, instance, &field.label, MARGIN, y + 3, LABEL_WIDTH, state.font);
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
                    MARGIN + 2, y - 6, WINDOW_WIDTH - MARGIN * 2, state.font,
                );
                y += HELP_HEIGHT;
            }
        }
        y += MARGIN;
    }
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
unsafe fn message_font() -> HFONT {
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
            handle_command(state, id, code);
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
    fn the_window_grows_with_the_number_of_settings() {
        let one = window_height(&[SettingsPage::new("s", "一项", vec![Field::toggle("a", "开关", true)])]);
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
    fn control_ids_start_above_the_system_reserved_range() {
        // IDOK / IDCANCEL 这些是 1..9，撞上的话会收到莫名其妙的 WM_COMMAND
        assert!(FIRST_CONTROL > 10);
    }
}
