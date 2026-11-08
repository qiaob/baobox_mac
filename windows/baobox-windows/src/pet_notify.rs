#![cfg(windows)]

use baobox_core::config::Config;
use std::cell::Cell;
use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{
    COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM,
};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::{DRAWITEMSTRUCT, ODS_SELECTED};
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::WindowsAndMessaging::*;

pub const HISTORY: &str = "desktop-pet.history";
pub const QUIET: &str = "desktop-pet.quiet";
pub const QUIET_TODAY: &str = "desktop-pet.quiet-today";
pub const RESUME: &str = "desktop-pet.resume";
pub const TEST: &str = "desktop-pet.test";
pub const TEST_TOAST: &str = "desktop-pet.test-toast";
pub const TEST_ALERT: &str = "desktop-pet.test-alert";
const MAX_ITEMS: usize = 50;
const CLASS: PCWSTR = w!("BaoboxPetBubble");
pub const SOURCES: [(&str, &str); 7] = [
    ("screenshot", "截图"),
    ("clipboard", "剪贴板"),
    ("caffeinate", "防休眠"),
    ("windowmanager", "窗口管理"),
    ("keyboardnav", "键盘点击"),
    ("claudecode", "Claude Code 助手"),
    ("aitools", "Codex 助手"),
];

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Level {
    Ambient,
    Card,
    Alert,
}

pub struct Notice {
    pub source: String,
    pub title: String,
    pub body: String,
    pub level: Level,
    pub dedupe: Option<String>,
    pub expires: Instant,
    pub actions: Vec<(&'static str, &'static str)>,
    user_feedback: bool,
}

impl Notice {
    pub fn ambient(source: &str, title: &str) -> Self {
        Self {
            source: source.to_owned(),
            title: title.to_owned(),
            body: String::new(),
            level: Level::Ambient,
            dedupe: Some(title.to_owned()),
            expires: Instant::now() + Duration::from_secs(30),
            actions: Vec::new(),
            user_feedback: false,
        }
    }

    pub fn feedback(title: &str) -> Self {
        let mut notice = Self::ambient("desktop-pet", title);
        notice.user_feedback = true;
        notice.dedupe = None;
        notice
    }

    fn digest(mut pending: VecDeque<Self>) -> Self {
        let mut notice = Self::ambient("digest", &format!("{} 条提醒", pending.len()));
        notice.level = Level::Card;
        notice.body = pending
            .drain(..)
            .take(3)
            .map(|n| n.title)
            .collect::<Vec<_>>()
            .join("、");
        notice
    }
}

struct History {
    source: String,
    title: String,
    key: Option<String>,
    count: usize,
}

pub struct Center {
    quiet_until: Option<Instant>,
    history: VecDeque<History>,
    recent: HashMap<(String, String), Instant>,
    pending: VecDeque<Notice>,
    ready: VecDeque<Notice>,
    bubble: Option<Bubble>,
    history_limit: usize,
    muted: Vec<&'static str>,
    sound: bool,
}

impl Default for Center {
    fn default() -> Self {
        Self {
            quiet_until: None,
            history: VecDeque::new(),
            recent: HashMap::new(),
            pending: VecDeque::new(),
            ready: VecDeque::new(),
            bubble: None,
            history_limit: MAX_ITEMS,
            muted: Vec::new(),
            sound: false,
        }
    }
}

impl Center {
    pub fn configure(&mut self, config: &Config) {
        let section = crate::pet::ID;
        self.history_limit = config
            .string_or(section, "history-limit", "50")
            .parse::<usize>()
            .unwrap_or(MAX_ITEMS)
            .clamp(10, 200);
        self.history.truncate(self.history_limit);
        self.sound = config.bool_or(section, "alert-sound", false);
        self.muted = SOURCES
            .iter()
            .map(|(source, _)| *source)
            .filter(|source| !config.bool_or(section, &format!("notify-{source}"), true))
            .collect();
    }
    pub fn quiet(&mut self, duration: Option<Duration>) {
        self.quiet_until = duration.map(|duration| Instant::now() + duration);
    }

    pub fn manually_quiet(&self) -> bool {
        self.quiet_until.is_some_and(|end| end > Instant::now())
    }

    pub fn quiet_today(&mut self) {
        let time = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
        let elapsed =
            u64::from(time.wHour) * 3600 + u64::from(time.wMinute) * 60 + u64::from(time.wSecond);
        self.quiet(Some(Duration::from_secs(86_400 - elapsed)));
    }

    pub fn history(&self) -> String {
        if self.history.is_empty() {
            return "暂无通知".to_owned();
        }
        self.history
            .iter()
            .map(|item| {
                if item.count > 1 {
                    format!("{} · {}（{} 次）", item.source, item.title, item.count)
                } else {
                    format!("{} · {}", item.source, item.title)
                }
            })
            .collect::<Vec<_>>()
            .join("\r\n")
    }

    pub fn post(&mut self, notice: Notice) {
        let now = Instant::now();
        if notice.expires <= now || self.muted.contains(&notice.source.as_str()) {
            return;
        }
        self.recent
            .retain(|_, time| now.duration_since(*time) < Duration::from_secs(30));
        if let Some(key) = &notice.dedupe {
            let id = (notice.source.clone(), key.clone());
            if self.recent.contains_key(&id) {
                if let Some(entry) = self
                    .history
                    .iter_mut()
                    .find(|item| item.source == notice.source && item.key.as_ref() == Some(key))
                {
                    entry.count += 1;
                }
                return;
            }
            if self.recent.len() >= MAX_ITEMS {
                if let Some(oldest) = self
                    .recent
                    .iter()
                    .min_by_key(|(_, time)| *time)
                    .map(|(key, _)| key.clone())
                {
                    self.recent.remove(&oldest);
                }
            }
            self.recent.insert(id, now);
        }
        self.history.push_front(History {
            source: notice.source.clone(),
            title: notice.title.clone(),
            key: notice.dedupe.clone(),
            count: 1,
        });
        self.history.truncate(self.history_limit);
        if self.suppressed() && notice.level != Level::Alert && !notice.user_feedback {
            if notice.level == Level::Card {
                Self::enqueue(&mut self.pending, notice);
            }
        } else {
            Self::enqueue(&mut self.ready, notice);
        }
    }

    fn enqueue(queue: &mut VecDeque<Notice>, notice: Notice) {
        if queue.len() == MAX_ITEMS {
            queue.pop_front();
        }
        queue.push_back(notice);
    }

    pub fn suppressed(&self) -> bool {
        self.manually_quiet() || unsafe { fullscreen() }
    }

    pub fn tick(
        &mut self,
        pet: Option<HWND>,
        fallback: impl FnOnce(&str, &str),
    ) -> Option<&'static str> {
        let now = Instant::now();
        self.ready.retain(|notice| notice.expires > now);
        self.pending.retain(|notice| notice.expires > now);
        let suppressed = self.suppressed();
        if !suppressed && !self.pending.is_empty() {
            Self::enqueue(
                &mut self.ready,
                Notice::digest(std::mem::take(&mut self.pending)),
            );
        }

        if let Some(bubble) = &self.bubble {
            if pet.is_some_and(|hwnd| bubble.update(hwnd, suppressed)) {
                return None;
            }
            let action = bubble.input.selected.get();
            self.bubble = None;
            if action.is_some() {
                return action;
            }
        }
        while let Some(notice) = self.ready.pop_front() {
            if suppressed && notice.level != Level::Alert && !notice.user_feedback {
                if notice.level == Level::Card {
                    Self::enqueue(&mut self.pending, notice);
                }
                continue;
            }
            if self.sound && notice.level == Level::Alert && !suppressed {
                unsafe {
                    let _ =
                        windows::Win32::System::Diagnostics::Debug::MessageBeep(MB_ICONINFORMATION);
                }
            }
            if let Some(pet) = pet {
                if let Ok(bubble) = Bubble::open(pet, &notice) {
                    if !notice.user_feedback {
                        crate::pet::notify_reaction(pet);
                    }
                    self.bubble = Some(bubble);
                    return None;
                }
            }
            fallback(&notice.title, &notice.body);
            return None;
        }
        None
    }
}

unsafe fn monitor_info(hwnd: HWND) -> Option<MONITORINFO> {
    let mut info = MONITORINFO {
        cbSize: std::mem::size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mut info)
        .as_bool()
        .then_some(info)
}

unsafe fn fullscreen() -> bool {
    let window = GetForegroundWindow();
    if window.is_invalid() || window == GetDesktopWindow() || window == GetShellWindow() {
        return false;
    }
    let Some(info) = monitor_info(window) else {
        return false;
    };
    let mut rect = RECT::default();
    GetWindowRect(window, &mut rect).is_ok()
        && rect.left <= info.rcMonitor.left
        && rect.top <= info.rcMonitor.top
        && rect.right >= info.rcMonitor.right
        && rect.bottom >= info.rcMonitor.bottom
        && (!IsZoomed(window).as_bool() || info.rcWork == info.rcMonitor)
}

struct Bubble {
    window: HWND,
    level: Level,
    close_at: Cell<Instant>,
    checked: Cell<Instant>,
    expires: Instant,
    width: i32,
    height: i32,
    input: Box<BubbleInput>,
    user_feedback: bool,
}

const KEY: COLORREF = COLORREF(0xff00ff);
const SURFACE: COLORREF = COLORREF(0xffffff);
const LINE: COLORREF = COLORREF(0xe2e4dd);
const INK: COLORREF = COLORREF(0x24221c);
const MUTED: COLORREF = COLORREF(0x686b5d);
const ACCENT: COLORREF = COLORREF(0x74_7c_0e);
const TINT: COLORREF = COLORREF(0xf0f7de);

struct BubbleInput {
    selected: Cell<Option<&'static str>>,
    actions: Vec<(&'static str, &'static str)>,
    source: &'static str,
    icon: u16,
    title: Vec<u16>,
    body: Vec<u16>,
    ambient: bool,
    dpi: i32,
    fonts: [HFONT; 3],
    title_height: i32,
    body_height: i32,
    tail: Cell<(i32, bool)>,
}

impl BubbleInput {
    fn px(&self, value: i32) -> i32 {
        (value * self.dpi + 48) / 96
    }
}

impl Drop for BubbleInput {
    fn drop(&mut self) {
        for font in self.fonts {
            unsafe {
                let _ = DeleteObject(font);
            }
        }
    }
}

impl Bubble {
    fn open(pet: HWND, notice: &Notice) -> Result<Self, windows::core::Error> {
        unsafe {
            let instance: HINSTANCE = GetModuleHandleW(None)?.into();
            RegisterClassW(&WNDCLASSW {
                lpfnWndProc: Some(bubble_proc),
                hInstance: instance,
                lpszClassName: CLASS,
                ..Default::default()
            });
            let window = CreateWindowExW(
                WS_EX_LAYERED
                    | WS_EX_TOPMOST
                    | WS_EX_NOACTIVATE
                    | if crate::pet::is_preview() {
                        WS_EX_APPWINDOW
                    } else {
                        WS_EX_TOOLWINDOW
                    },
                CLASS,
                w!("BaoBox 通知"),
                WS_POPUP,
                0,
                0,
                0,
                0,
                pet,
                None,
                instance,
                None,
            )?;
            let dpi = match GetDpiForWindow(pet) {
                0 => 96,
                dpi => dpi as i32,
            };
            let (source, icon) = match notice.source.as_str() {
                "screenshot" | "capture-result" => ("截图", 0xe722),
                "clipboard" => ("剪贴板", 0xe77f),
                "claudecode" => ("Claude Code", 0xe734),
                "aitools" | "codex" => ("Codex", 0xe943),
                "digest" => ("消息摘要", 0xe8b7),
                crate::pet::ID => ("桌面宠物", 0xed54),
                other => (
                    SOURCES
                        .iter()
                        .find(|(id, _)| *id == other)
                        .map_or("BaoBox", |(_, name)| *name),
                    0xea8f,
                ),
            };
            let mut input = Box::new(BubbleInput {
                selected: Cell::new(None),
                actions: notice.actions.clone(),
                source,
                icon,
                title: notice.title.encode_utf16().collect(),
                body: notice.body.encode_utf16().collect(),
                ambient: notice.level == Level::Ambient && notice.actions.is_empty(),
                dpi,
                fonts: [(14, 600), (13, 400), (11, 400)].map(|(size, weight)| {
                    let face = if size == 11 {
                        w!("Segoe MDL2 Assets")
                    } else {
                        w!("Microsoft YaHei UI")
                    };
                    CreateFontW(
                        -(size * dpi + 48) / 96,
                        0,
                        0,
                        0,
                        weight,
                        0,
                        0,
                        0,
                        1,
                        0,
                        0,
                        4,
                        0,
                        face,
                    )
                }),
                title_height: 0,
                body_height: 0,
                tail: Cell::new((0, false)),
            });
            let dc = GetDC(window);
            let width = input.px(300);
            let text_width = width - input.px(if input.ambient { 58 } else { 28 });
            input.title_height =
                measure(dc, input.fonts[0], &input.title, text_width, input.px(36));
            input.body_height = measure(
                dc,
                input.fonts[1],
                &input.body,
                text_width,
                input.px(if input.ambient { 18 } else { 64 }),
            );
            let content = input.title_height
                + input.body_height
                + if input.body_height > 0 {
                    input.px(4)
                } else {
                    0
                };
            let actions_y = input.px(47) + content;
            let height = if input.ambient {
                input.px(34) + content.max(input.px(22))
            } else if input.actions.is_empty() {
                input.px(54) + content
            } else {
                actions_y + input.px(43)
            };
            let button_widths: Vec<_> = input
                .actions
                .iter()
                .take(3)
                .map(|(_, label)| {
                    let label: Vec<u16> = label.encode_utf16().collect();
                    let old = SelectObject(dc, input.fonts[1]);
                    let mut size = SIZE::default();
                    let _ = GetTextExtentPoint32W(dc, &label, &mut size);
                    SelectObject(dc, old);
                    (size.cx + input.px(24)).clamp(
                        input.px(48),
                        input.px(if input.actions.len() == 1 { 272 } else { 86 }),
                    )
                })
                .collect();
            ReleaseDC(window, dc);
            let bubble = Self {
                window,
                level: notice.level,
                user_feedback: notice.user_feedback,
                close_at: Cell::new(
                    Instant::now()
                        + Duration::from_secs(if notice.level == Level::Ambient { 3 } else { 8 }),
                ),
                checked: Cell::new(Instant::now()),
                expires: notice.expires,
                width,
                height,
                input,
            };
            SetWindowLongPtrW(
                window,
                GWLP_USERDATA,
                &*bubble.input as *const BubbleInput as isize,
            );
            SetLayeredWindowAttributes(window, KEY, 255, LWA_COLORKEY)?;
            SetWindowPos(
                window,
                None,
                0,
                0,
                width,
                height,
                SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE,
            )?;
            let px = |n| bubble.input.px(n);
            let button = |id, label: PCWSTR, x, y, width, height| {
                CreateWindowExW(
                    Default::default(),
                    w!("BUTTON"),
                    label,
                    WS_CHILD | WS_VISIBLE | WINDOW_STYLE(BS_OWNERDRAW as u32),
                    x,
                    y,
                    width,
                    height,
                    window,
                    HMENU(id as _),
                    instance,
                    None,
                )
            };
            if !bubble.input.ambient {
                button(1, w!("关闭"), width - px(35), px(18), px(20), px(20))?;
                let mut x = px(14);
                for (index, ((_, label), button_width)) in
                    bubble.input.actions.iter().zip(button_widths).enumerate()
                {
                    let label = wide(label);
                    button(
                        index + 2,
                        PCWSTR(label.as_ptr()),
                        x,
                        actions_y,
                        button_width,
                        px(26),
                    )?;
                    x += button_width + px(6);
                }
            }
            bubble.position(pet);
            let _ = ShowWindow(window, SW_SHOWNOACTIVATE);
            Ok(bubble)
        }
    }
    unsafe fn position(&self, pet: HWND) {
        let mut rect = RECT::default();
        if GetWindowRect(pet, &mut rect).is_err() {
            return;
        }
        let Some(info) = monitor_info(pet) else {
            return;
        };
        let rect = crate::pet::body_bounds(pet, rect);
        let area = info.rcWork;
        let x = ((rect.left + rect.right - self.width) / 2)
            .clamp(area.left, (area.right - self.width).max(area.left));
        let gap = self.input.px(4);
        let below = rect.top - self.height - gap < area.top;
        let y = if below {
            (rect.bottom + gap).min((area.bottom - self.height).max(area.top))
        } else {
            rect.top - self.height - gap
        };
        let inset = self.input.px(22);
        let tail = (
            ((rect.left + rect.right) / 2 - x).clamp(inset, self.width - inset),
            below,
        );
        if self.input.tail.replace(tail) != tail {
            let _ = InvalidateRect(self.window, None, false);
        }
        let _ = SetWindowPos(
            self.window,
            None,
            x,
            y,
            0,
            0,
            SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOZORDER,
        );
    }

    fn update(&self, pet: HWND, suppressed: bool) -> bool {
        let now = Instant::now();
        let interval = now.duration_since(self.checked.replace(now));
        if self.level == Level::Card {
            unsafe {
                let mut cursor = POINT::default();
                let mut rect = RECT::default();
                if GetCursorPos(&mut cursor).is_ok()
                    && GetWindowRect(self.window, &mut rect).is_ok()
                    && cursor.x >= rect.left
                    && cursor.x < rect.right
                    && cursor.y >= rect.top
                    && cursor.y < rect.bottom
                {
                    self.close_at.set(self.close_at.get() + interval);
                }
            }
        }
        if now >= self.expires
            || (self.level != Level::Alert
                && (now >= self.close_at.get() || suppressed && !self.user_feedback))
        {
            return false;
        }
        unsafe {
            if !IsWindowVisible(self.window).as_bool() {
                return false;
            }
            self.position(pet);
        }
        true
    }
}

impl Drop for Bubble {
    fn drop(&mut self) {
        unsafe {
            let _ = DestroyWindow(self.window);
        }
    }
}

const WRAP: DRAW_TEXT_FORMAT = DRAW_TEXT_FORMAT(DT_WORDBREAK.0 | DT_NOPREFIX.0 | DT_EDITCONTROL.0);
const ONE_LINE: DRAW_TEXT_FORMAT =
    DRAW_TEXT_FORMAT(DT_SINGLELINE.0 | DT_VCENTER.0 | DT_END_ELLIPSIS.0 | DT_NOPREFIX.0);

fn bounds(left: i32, top: i32, right: i32, bottom: i32) -> RECT {
    RECT {
        left,
        top,
        right,
        bottom,
    }
}

unsafe fn measure(dc: HDC, font: HFONT, text: &[u16], width: i32, limit: i32) -> i32 {
    if text.is_empty() {
        return 0;
    }
    let old = SelectObject(dc, font);
    let mut rect = bounds(0, 0, width, 0);
    DrawTextW(dc, &mut text.to_vec(), &mut rect, WRAP | DT_CALCRECT);
    SelectObject(dc, old);
    rect.bottom.min(limit)
}

unsafe fn fill(dc: HDC, rect: RECT, color: COLORREF) {
    let brush = CreateSolidBrush(color);
    FillRect(dc, &rect, brush);
    let _ = DeleteObject(brush);
}

unsafe fn rounded(dc: HDC, rect: RECT, radius: i32, color: COLORREF, outline: COLORREF) {
    let brush = CreateSolidBrush(color);
    let pen = CreatePen(PS_SOLID, 1, outline);
    let old_brush = SelectObject(dc, brush);
    let old_pen = SelectObject(dc, pen);
    let _ = RoundRect(
        dc,
        rect.left,
        rect.top,
        rect.right,
        rect.bottom,
        radius,
        radius,
    );
    SelectObject(dc, old_pen);
    SelectObject(dc, old_brush);
    let _ = DeleteObject(pen);
    let _ = DeleteObject(brush);
}

unsafe fn draw_label(
    dc: HDC,
    font: HFONT,
    text: &[u16],
    mut rect: RECT,
    color: COLORREF,
    format: DRAW_TEXT_FORMAT,
) {
    let old = SelectObject(dc, font);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, color);
    DrawTextW(dc, &mut text.to_vec(), &mut rect, format);
    SelectObject(dc, old);
}

unsafe fn paint_bubble(hwnd: HWND, input: &BubbleInput) {
    let mut paint = PAINTSTRUCT::default();
    let dc = BeginPaint(hwnd, &mut paint);
    let mut rect = RECT::default();
    let _ = GetClientRect(hwnd, &mut rect);
    let px = |n| input.px(n);
    let width = rect.right;
    let height = rect.bottom;
    let (tail, below) = input.tail.get();
    fill(dc, rect, KEY);
    rounded(
        dc,
        bounds(0, px(7), width, height - px(7)),
        px(28),
        SURFACE,
        LINE,
    );

    let edge = if below { px(7) } else { height - px(7) - 1 };
    let tip = if below { 0 } else { height - 1 };
    let seam = if below { edge + 1 } else { edge - 1 };
    let brush = CreateSolidBrush(SURFACE);
    let pen = CreatePen(PS_SOLID, 1, LINE);
    let old_brush = SelectObject(dc, brush);
    let old_pen = SelectObject(dc, pen);
    let _ = Polygon(
        dc,
        &[
            POINT {
                x: tail - px(7),
                y: seam,
            },
            POINT { x: tail, y: tip },
            POINT {
                x: tail + px(7),
                y: seam,
            },
        ],
    );
    SelectObject(dc, old_pen);
    SelectObject(dc, old_brush);
    let _ = DeleteObject(pen);
    let _ = DeleteObject(brush);
    fill(
        dc,
        bounds(tail - px(6), seam, tail + px(6) + 1, seam + 1),
        SURFACE,
    );

    let icon_y = if input.ambient {
        (height - px(22)) / 2
    } else {
        px(17)
    };
    let icon_rect = bounds(px(14), icon_y, px(36), icon_y + px(22));
    rounded(dc, icon_rect, px(22), TINT, TINT);
    draw_label(
        dc,
        input.fonts[2],
        &[input.icon],
        icon_rect,
        ACCENT,
        ONE_LINE | DT_CENTER,
    );
    if !input.ambient {
        let source: Vec<u16> = input.source.encode_utf16().collect();
        draw_label(
            dc,
            input.fonts[1],
            &source,
            bounds(px(43), px(17), width - px(42), px(39)),
            MUTED,
            ONE_LINE,
        );
    }

    let x = px(if input.ambient { 44 } else { 14 });
    let y = if input.ambient {
        (height
            - input.title_height
            - input.body_height
            - if input.body_height > 0 { px(4) } else { 0 })
            / 2
    } else {
        px(42)
    };
    draw_label(
        dc,
        input.fonts[0],
        &input.title,
        bounds(x, y, width - px(14), y + input.title_height),
        INK,
        WRAP | DT_END_ELLIPSIS,
    );
    if input.body_height > 0 {
        let y = y + input.title_height + px(4);
        draw_label(
            dc,
            input.fonts[1],
            &input.body,
            bounds(x, y, width - px(14), y + input.body_height),
            MUTED,
            WRAP | DT_END_ELLIPSIS,
        );
    }
    let _ = EndPaint(hwnd, &paint);
}

unsafe fn paint_button(item: &DRAWITEMSTRUCT, input: &BubbleInput) {
    let dc = item.hDC;
    let rect = item.rcItem;
    let pressed = item.itemState.0 & ODS_SELECTED.0 != 0;
    fill(dc, rect, SURFACE);
    let (label, background, color, font) = match item.CtlID {
        1 => (
            vec![0x00d7],
            COLORREF(if pressed { 0xd9e1de } else { 0xecf0ee }),
            MUTED,
            input.fonts[0],
        ),
        2 => (
            input.actions[0].1.encode_utf16().collect(),
            if pressed { COLORREF(0x615d0a) } else { ACCENT },
            SURFACE,
            input.fonts[1],
        ),
        id => (
            input.actions[(id - 2) as usize].1.encode_utf16().collect(),
            if pressed { COLORREF(0xd5e9ba) } else { TINT },
            ACCENT,
            input.fonts[1],
        ),
    };
    let rect = bounds(rect.left, rect.top, rect.right - 1, rect.bottom - 1);
    rounded(dc, rect, rect.bottom - rect.top, background, background);
    draw_label(dc, font, &label, rect, color, ONE_LINE | DT_CENTER);
}
unsafe extern "system" fn bubble_proc(hwnd: HWND, message: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let input = (GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const BubbleInput).as_ref();
    match message {
        WM_PAINT if input.is_some() => {
            paint_bubble(hwnd, input.unwrap());
            LRESULT(0)
        }
        WM_DRAWITEM if input.is_some() && (1..=4).contains(&wp.0) => {
            paint_button(&*(lp.0 as *const DRAWITEMSTRUCT), input.unwrap());
            LRESULT(1)
        }
        WM_COMMAND if (1..=4).contains(&wp.0) => {
            if let Some(input) = input {
                input.selected.set(
                    wp.0.checked_sub(2)
                        .and_then(|index| input.actions.get(index))
                        .map(|(id, _)| *id),
                );
            }
            let _ = ShowWindow(hwnd, SW_HIDE);
            LRESULT(0)
        }
        WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
        _ => DefWindowProcW(hwnd, message, wp, lp),
    }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn card_button_returns_action_through_native_window() {
        let mut center = Center::default();
        let mut notice = Notice::ambient("test", "测试");
        notice.level = Level::Alert;
        notice.actions.push((HISTORY, "通知历史"));
        center.post(notice);
        unsafe {
            let instance: HINSTANCE = GetModuleHandleW(None).unwrap().into();
            let owner = CreateWindowExW(
                WS_EX_TOOLWINDOW,
                w!("STATIC"),
                w!("BaoBox test"),
                WS_POPUP,
                100,
                150,
                80,
                80,
                None,
                None,
                instance,
                None,
            )
            .unwrap();
            assert_eq!(
                center.tick(Some(owner), |_, _| panic!("unexpected fallback")),
                None
            );
            let bubble = center.bubble.as_ref().expect("notification bubble");
            assert!(IsWindowVisible(bubble.window).as_bool());
            let button = GetDlgItem(bubble.window, 2).unwrap();
            SendMessageW(button, BM_CLICK, WPARAM(0), LPARAM(0));
            assert_eq!(
                center.tick(Some(owner), |_, _| panic!("unexpected fallback")),
                Some(HISTORY)
            );
            DestroyWindow(owner).unwrap();
        }
    }

    #[test]
    fn quiet_mode_merges_duplicate_history_and_queues_cards() {
        let mut center = Center::default();
        center.quiet(Some(Duration::from_secs(60)));
        for _ in 0..2 {
            let mut notice = Notice::ambient("test", "重复消息");
            notice.level = Level::Card;
            center.post(notice);
        }
        assert_eq!(center.pending.len(), 1);
        assert!(center.history().contains("2 次"));
        center.quiet(None);
        if !center.suppressed() {
            let mut delivered = String::new();
            center.tick(None, |title, _| delivered = title.into());
            assert_eq!(delivered, "1 条提醒");
        }
    }
}
