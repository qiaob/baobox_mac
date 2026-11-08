#![cfg(windows)]

use baobox_core::config::Config;
use std::cell::Cell;
use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    GetMonitorInfoW, MonitorFromWindow, HBRUSH, MONITORINFO, MONITOR_DEFAULTTONEAREST,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
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

struct BubbleInput {
    selected: Cell<Option<&'static str>>,
    actions: Vec<(&'static str, &'static str)>,
}

impl Bubble {
    fn open(pet: HWND, notice: &Notice) -> Result<Self, windows::core::Error> {
        unsafe {
            let instance: HINSTANCE = GetModuleHandleW(None)?.into();
            RegisterClassW(&WNDCLASSW {
                lpfnWndProc: Some(bubble_proc),
                hInstance: instance,
                hbrBackground: HBRUSH(6 as _), // COLOR_WINDOW + 1
                lpszClassName: CLASS,
                ..Default::default()
            });
            let width = 300;
            let base_height = if notice.body.is_empty() { 56 } else { 108 };
            let height = base_height + if notice.actions.is_empty() { 0 } else { 35 };
            let window = CreateWindowExW(
                WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
                CLASS,
                w!("BaoBox 通知"),
                WS_POPUP | WS_BORDER,
                0,
                0,
                width,
                height,
                pet,
                None,
                instance,
                None,
            )?;
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
                input: Box::new(BubbleInput {
                    selected: Cell::new(None),
                    actions: notice.actions.clone(),
                }),
            };
            let title = wide(&notice.title);
            CreateWindowExW(
                Default::default(),
                w!("STATIC"),
                PCWSTR(title.as_ptr()),
                WS_CHILD | WS_VISIBLE,
                12,
                12,
                width - 58,
                31,
                window,
                None,
                instance,
                None,
            )?;
            if !notice.body.is_empty() {
                let body = wide(&notice.body);
                CreateWindowExW(
                    Default::default(),
                    w!("STATIC"),
                    PCWSTR(body.as_ptr()),
                    WS_CHILD | WS_VISIBLE,
                    12,
                    48,
                    width - 24,
                    base_height - 54,
                    window,
                    None,
                    instance,
                    None,
                )?;
            }
            CreateWindowExW(
                Default::default(),
                w!("BUTTON"),
                w!("×"),
                WS_CHILD | WS_VISIBLE,
                width - 40,
                8,
                26,
                24,
                window,
                HMENU(1 as _),
                instance,
                None,
            )?;
            for (index, (_, label)) in bubble.input.actions.iter().take(3).enumerate() {
                let label = wide(label);
                CreateWindowExW(
                    Default::default(),
                    w!("BUTTON"),
                    PCWSTR(label.as_ptr()),
                    WS_CHILD | WS_VISIBLE,
                    12 + 94 * index as i32,
                    base_height,
                    89,
                    26,
                    window,
                    HMENU((index + 2) as _),
                    instance,
                    None,
                )?;
            }
            SetWindowLongPtrW(
                window,
                GWLP_USERDATA,
                &*bubble.input as *const BubbleInput as isize,
            );
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
        let area = info.rcWork;
        let x = ((rect.left + rect.right - self.width) / 2)
            .clamp(area.left, (area.right - self.width).max(area.left));
        let y = if rect.top - self.height - 8 >= area.top {
            rect.top - self.height - 8
        } else {
            (rect.bottom + 8).min((area.bottom - self.height).max(area.top))
        };
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

unsafe extern "system" fn bubble_proc(hwnd: HWND, message: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match message {
        WM_COMMAND if (1..=4).contains(&wp.0) => {
            let input = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const BubbleInput;
            if let Some(input) = input.as_ref() {
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
