#![cfg(windows)]

use crate::pet_pack::{self, Pack};
use baobox_app::{Field, HotkeySpec, MenuItem, SettingsPage, ToolModule};
use baobox_core::config::Config;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{Duration, Instant};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{
    COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM,
};
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, SelectObject, HDC,
};
use windows::Win32::Graphics::Gdi::{
    CreateSolidBrush, DeleteObject, FillRect, GetDC, GetMonitorInfoW, MonitorFromRect,
    MonitorFromWindow, ReleaseDC, MONITORINFO, MONITOR_DEFAULTTONEAREST,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, GetLastInputInfo, ReleaseCapture, SetCapture, LASTINPUTINFO, VK_LBUTTON,
    VK_RBUTTON,
};
use windows::Win32::UI::WindowsAndMessaging::*;

pub const ID: &str = "desktop-pet";
const TOGGLE: &str = "desktop-pet.toggle";
pub(crate) const DOWNLOAD: &str = "desktop-pet.download.";
const REMOVE: &str = "desktop-pet.remove.";
const SELECT: &str = "desktop-pet.select.";
const PICK_AREA: &str = "desktop-pet.pick-area";
pub const WM_PET_MENU: u32 = WM_APP + 3;
const WM_PET_REACT: u32 = WM_APP + 4;
const INTERACTIONS: [(&str, &str, &str); 7] = [
    ("desktop-pet.pet", "pet", "摸摸"),
    ("desktop-pet.feed", "feed", "喂食"),
    ("desktop-pet.play", "play", "陪玩"),
    ("desktop-pet.nod", "nod", "点头"),
    ("desktop-pet.shake", "shake", "摇头"),
    ("desktop-pet.laugh", "laugh", "笑"),
    ("desktop-pet.cry", "cry", "哭"),
];
const SIT: &str = "desktop-pet.sit";
const PEEK: &str = "desktop-pet.peek";
const UNPERCH: &str = "desktop-pet.unperch";
pub const NEXT_CHARACTER: &str = "desktop-pet.next-character";
const CLASS: PCWSTR = w!("BaoboxDesktopPet");
const KEY: COLORREF = COLORREF(0xff00ff);
thread_local! {
    static PREVIEW: Cell<bool> = const { Cell::new(false) };
    static PREVIEW_ACTIONS: Cell<bool> = const { Cell::new(false) };
    static FRAME_TRACE: RefCell<Vec<(Instant, f64, i32, i32)>> = const { RefCell::new(Vec::new()) };
    static TRACE_OUTPUT: RefCell<Option<(std::path::PathBuf, Instant)>> = const { RefCell::new(None) };
    static ANCHOR: Cell<Option<HWND>> = const { Cell::new(None) };
    static QUIET: Cell<bool> = const { Cell::new(false) };
    static MENU_OPEN: Cell<bool> = const { Cell::new(false) };
    static CAPTURING: Cell<bool> = const { Cell::new(false) };
}

pub struct CaptureVisibility(Option<HWND>);

impl CaptureVisibility {
    pub fn hide() -> Self {
        CAPTURING.set(true);
        let visible = anchor().filter(|&hwnd| unsafe { IsWindowVisible(hwnd).as_bool() });
        if let Some(hwnd) = visible {
            unsafe {
                let _ = ShowWindow(hwnd, SW_HIDE);
            }
        }
        Self(visible)
    }
}

impl Drop for CaptureVisibility {
    fn drop(&mut self) {
        CAPTURING.set(false);
        if let Some(hwnd) = self.0 {
            unsafe {
                let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            }
        }
    }
}

pub fn trace_desktop() {
    if let Some(path) = std::env::var_os("BAOBOX_PET_TRACE") {
        TRACE_OUTPUT.replace(Some((
            path.into(),
            Instant::now() + Duration::from_secs(20),
        )));
    }
}

fn write_trace(path: &std::path::Path) -> std::io::Result<()> {
    let csv = FRAME_TRACE.with(|trace| {
        let mut csv = String::from("interval_ms,submit_ms,x,y\n");
        for frames in trace.borrow().windows(2) {
            use std::fmt::Write;
            let (_, cost, x, y) = frames[1];
            let interval = frames[1].0.duration_since(frames[0].0).as_secs_f64() * 1000.0;
            let _ = writeln!(csv, "{interval:.3},{cost:.3},{x},{y}");
        }
        csv
    });
    std::fs::write(path, csv)
}

pub fn is_preview() -> bool {
    PREVIEW.get()
}

pub fn preview(trace_path: Option<&std::path::Path>, mode: Option<&str>) -> Result<String, String> {
    crate::gdi::prepare();
    PREVIEW.set(true);
    PREVIEW_ACTIONS.set(mode == Some("--actions"));
    if mode == Some("--front") {
        set_menu_open(true);
    }
    let mut config = crate::store::load_config();
    config.set_bool(ID, "startup", true);
    config.set_bool(ID, "roam", true);
    config.set(ID, "range", "bottom");
    let mut tool = PetTool::new(HWND::default());
    tool.activate(&config);
    tool.show()?;
    unsafe {
        let hwnd = tool.window.as_ref().ok_or("验收窗口未创建")?.hwnd;
        let _ring = if mode == Some("--ring") {
            set_menu_open(true);
            Some(
                crate::pet_ring::Ring::open(
                    hwnd,
                    hwnd,
                    &crate::pet_ring::ITEMS,
                    &[
                        ("desktop-pet.nod", "点头"),
                        ("desktop-pet.shake", "摇头"),
                        ("desktop-pet.laugh", "笑"),
                        ("desktop-pet.cry", "哭"),
                    ],
                )
                .map_err(|e| e.to_string())?,
            )
        } else {
            None
        };
        let mut notices = crate::pet_notify::Center::default();
        if matches!(mode, Some("--card" | "--toast" | "--focus-card")) {
            use crate::pet_notify::{Level, Notice, HISTORY};
            set_menu_open(true);
            let mut notice = Notice::ambient("capture-result", "截图完成");
            notice.expires = Instant::now() + Duration::from_secs(20);
            if mode == Some("--card") {
                notice.level = Level::Alert;
                notice.body = "截图已复制到剪贴板，可以直接粘贴到聊天输入框。".into();
                notice.actions.push((HISTORY, "通知历史"));
            }
            if mode == Some("--focus-card") {
                notice = Notice::ambient("focus", "专注已暂停 · 还剩 24:53");
                notice.level = Level::Card;
                notice.actions = vec![(HISTORY, "继续"), (crate::pet_notify::QUIET, "结束这一轮")];
            }
            notices.post(notice);
            notices.tick(Some(hwnd), |_, _| {});
        }
        if SetTimer(hwnd, 2, 20_000, None) == 0 {
            return Err("无法启动验收计时器".into());
        }
        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    if let Some(path) = trace_path {
        write_trace(path).map_err(|e| e.to_string())?;
    }
    Ok(String::new())
}

pub fn anchor() -> Option<HWND> {
    ANCHOR.get()
}

pub fn body_bounds(hwnd: HWND, window: RECT) -> RECT {
    unsafe {
        let state = (GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const State).as_ref();
        if let Some((left, top, right, bottom)) = state.and_then(|state| {
            state
                .pack
                .borrow()
                .as_ref()
                .and_then(|pack| pack.body_bounds())
        }) {
            RECT {
                left: window.left + left,
                top: window.top + top,
                right: window.left + right,
                bottom: window.top + bottom,
            }
        } else {
            window
        }
    }
}

pub fn set_quiet(value: bool) {
    QUIET.set(value);
}

pub fn set_menu_open(value: bool) {
    MENU_OPEN.set(value);
}

pub fn notify_reaction(hwnd: HWND) {
    unsafe {
        let _ = PostMessageW(hwnd, WM_PET_REACT, WPARAM(0), LPARAM(0));
    }
}
const CAT: [&[u8; 12]; 12] = [
    b"  ##    ##  ",
    b"  #+#  #+#  ",
    b"  #++##++#  ",
    b"  #++++++#  ",
    b" #++++++++# ",
    b" #+o++++o+# ",
    b" #++....++# ",
    b"  #..oo..#  ",
    b"   #....### ",
    b"   #++++#+# ",
    b"   ##++###  ",
    b"    #  #    ",
];

#[derive(Clone, Copy, PartialEq, Eq)]
struct Appearance {
    scale: i32,
    custom_size: Option<i32>,
    gait: usize,
    coat: u32,
    roam: bool,
    range: Range,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Range {
    Bottom,
    Free,
    Custom(RECT),
    Windows,
}

impl Appearance {
    fn read(config: &Config) -> Self {
        let size = config.string_or(ID, "size", "medium");
        Self {
            gait: match config.string_or(ID, "gait", "calm").as_str() {
                "happy" => 1,
                "playful" => 2,
                _ => 0,
            },
            scale: match size.as_str() {
                "small" => 5,
                "large" => 11,
                _ => 8,
            },
            custom_size: (size == "custom").then(|| {
                config
                    .string_or(ID, "custom-size", "320")
                    .parse::<i32>()
                    .unwrap_or(320)
                    .clamp(48, 640)
            }),
            coat: if config.string_or(ID, "coat", "orange") == "gray" {
                0xa89387
            } else {
                0x4da8ed
            },
            roam: config.bool_or(ID, "roam", true),
            range: match config.string_or(ID, "range", "bottom").as_str() {
                "free" => Range::Free,
                "windows" => Range::Windows,
                "custom" => parse_area(&config.string_or(ID, "area", ""))
                    .map_or(Range::Bottom, Range::Custom),
                _ => Range::Bottom,
            },
        }
    }

    fn size(self, humanoid: bool) -> i32 {
        self.custom_size
            .unwrap_or(self.scale * 13 * if humanoid { 3 } else { 1 })
    }
}

pub fn configured_size(config: &Config) -> i32 {
    let appearance = Appearance::read(config);
    let humanoid = anchor().is_some_and(|hwnd| unsafe {
        (GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const State)
            .as_ref()
            .is_some_and(|state| state.pack.borrow().as_ref().is_some_and(|pack| pack.is_humanoid()))
    });
    appearance.size(humanoid)
}

fn parse_area(value: &str) -> Option<RECT> {
    let values: Vec<i32> = value
        .split(',')
        .map(|value| value.trim().parse())
        .collect::<Result<_, _>>()
        .ok()?;
    let &[x, y, width, height] = values.as_slice() else {
        return None;
    };
    if width <= 0 || height <= 0 {
        return None;
    }
    Some(RECT {
        left: x,
        top: y,
        right: x.checked_add(width)?,
        bottom: y.checked_add(height)?,
    })
}

pub struct PetTool {
    owner: HWND,
    window: Option<PetWindow>,
    appearance: Appearance,
    startup: bool,
    character: String,
    pack: Option<Rc<Pack>>,
    catalog: Vec<(&'static crate::pet_download::CatalogEntry, bool, bool)>,
    download: Option<Receiver<Result<String, String>>>,
    download_status: Option<String>,
}

impl PetTool {
    pub fn new(owner: HWND) -> Self {
        Self {
            owner,
            window: None,
            appearance: Appearance::read(&Config::new()),
            startup: false,
            character: String::new(),
            pack: None,
            catalog: Self::catalog(),
            download: None,
            download_status: None,
        }
    }

    fn catalog() -> Vec<(&'static crate::pet_download::CatalogEntry, bool, bool)> {
        crate::pet_download::catalog()
            .iter()
            .map(|entry| {
                (
                    entry,
                    crate::pet_download::installed(&entry.id),
                    crate::pet_download::managed(&entry.id),
                )
            })
            .collect()
    }

    fn select(&mut self, id: &str) -> Result<(), String> {
        let mut config = crate::store::load_config();
        config.set(ID, "character", id);
        crate::store::save_config(&config)?;
        self.config_changed(&config);
        unsafe {
            let _ = PostMessageW(
                self.owner,
                crate::app::WM_RELOAD_CONFIG,
                WPARAM(0),
                LPARAM(0),
            );
        }
        Ok(())
    }

    fn show(&mut self) -> Result<(), String> {
        if self.window.is_none() {
            self.window = Some(PetWindow::open(
                self.owner,
                self.appearance,
                self.pack.clone(),
            )?);
        }
        Ok(())
    }
}

impl ToolModule for PetTool {
    fn id(&self) -> &str {
        ID
    }
    fn name(&self) -> &str {
        "桌面宠物"
    }

    fn menu_items(&self) -> Vec<MenuItem> {
        let label = if self.window.is_some() {
            "隐藏宠物"
        } else {
            "显示宠物"
        };
        let mut items = vec![
            MenuItem::action(TOGGLE, label),
            MenuItem::action(PICK_AREA, "框选活动区域"),
            MenuItem::action(crate::pet_notify::QUIET, "安静一小时"),
            MenuItem::action(crate::pet_notify::QUIET_TODAY, "今天保持安静"),
            MenuItem::action(crate::pet_notify::RESUME, "结束勿扰"),
            MenuItem::action(crate::pet_notify::HISTORY, "通知历史"),
            MenuItem::Submenu {
                label: "发送测试提醒".into(),
                items: vec![
                    MenuItem::action(crate::pet_notify::TEST_TOAST, "轻提示"),
                    MenuItem::action(crate::pet_notify::TEST, "卡片"),
                    MenuItem::action(crate::pet_notify::TEST_ALERT, "常驻提醒"),
                ],
            },
        ];
        if self.window.is_some() {
            items.extend(INTERACTIONS.iter().filter_map(|&(action, kind, label)| {
                (kind == "pet"
                    || self
                        .pack
                        .as_ref()
                        .is_some_and(|p| p.interaction_seconds(kind).is_some()))
                .then(|| MenuItem::action(action, label))
            }));
        }
        if self.window.is_some() && self.pack.as_ref().is_some_and(|pack| pack.is_humanoid()) {
            items.push(MenuItem::Submenu {
                label: "窗口互动".into(),
                items: vec![
                    MenuItem::action(SIT, "坐在窗口上沿"),
                    MenuItem::action(PEEK, "从窗口后探头"),
                    MenuItem::action(UNPERCH, "恢复自由活动"),
                ],
            });
        }
        let mut packs = Vec::new();
        if let Some(status) = &self.download_status {
            packs.push(MenuItem::disabled(status));
        }
        for (entry, installed, managed) in &self.catalog {
            let label = format!("{} · {}", entry.name, entry.credit);
            if *installed {
                let mut choices = vec![MenuItem::action(
                    &format!("{SELECT}{}", entry.id),
                    "使用形象",
                )];
                if *managed {
                    choices.push(MenuItem::action(
                        &format!("{REMOVE}{}", entry.id),
                        "移除下载",
                    ));
                }
                packs.push(MenuItem::Submenu {
                    label,
                    items: choices,
                });
            } else if self.download.is_none() {
                packs.push(MenuItem::action(&format!("{DOWNLOAD}{}", entry.id), &label));
            }
        }
        items.push(MenuItem::Submenu {
            label: "更多形象".into(),
            items: packs,
        });
        items
    }

    fn hotkeys(&self) -> Vec<HotkeySpec> {
        vec![HotkeySpec::new(TOGGLE, "显示或隐藏桌面宠物", None)]
    }

    fn settings_page(&self) -> Option<SettingsPage> {
        let entries = pet_pack::list();
        let mut characters = vec![("", "内置像素猫")];
        characters.extend(
            entries
                .iter()
                .map(|entry| (entry.id.as_str(), entry.name.as_str())),
        );
        let mut fields = vec![
            Field::toggle("startup", "启动时显示宠物", true),
            Field::toggle("roam", "自动散步", true),
            Field::choice(
                "gait",
                "人形走路风格",
                &[("calm", "轻盈"), ("happy", "开心"), ("playful", "孩子气")],
                "calm",
            ),
            Field::choice(
                "range",
                "活动范围",
                &[
                    ("bottom", "屏幕底边"),
                    ("free", "自由放置"),
                    ("custom", "自定义区域"),
                    ("windows", "窗口顶部"),
                ],
                "bottom",
            ),
            Field::text("area", "自定义区域", "", "X,Y,宽,高"),
            Field::choice(
                "size",
                "大小",
                &[
                    ("small", "小"),
                    ("medium", "中"),
                    ("large", "大"),
                    ("custom", "自定义"),
                ],
                "medium",
            ),
            Field::number("custom-size", "自定义大小（像素）", 320, 48, 640)
                .with_help("将「大小」设为「自定义」后生效。"),
            Field::choice(
                "coat",
                "内置像素猫毛色",
                &[("orange", "橘猫"), ("gray", "灰猫")],
                "orange",
            ),
            Field::choice("character", "形象包", &characters, "plush-cat")
                .with_help("自制形象目录：%APPDATA%\\Baobox\\Pets。"),
            Field::toggle("alert-sound", "常驻提醒播放提示音", false),
            Field::number("history-limit", "通知历史条数", 50, 10, 200),
        ];
        fields.extend(crate::pet_notify::SOURCES.iter().map(|(source, label)| {
            Field::toggle(
                &format!("notify-{source}"),
                &format!("接收{label}通知"),
                true,
            )
        }));
        Some(SettingsPage::new(ID, "桌面宠物", fields))
    }

    fn activate(&mut self, config: &Config) {
        self.config_changed(config);
    }

    fn config_changed(&mut self, config: &Config) {
        self.appearance = Appearance::read(config);
        let character = config.string_or(ID, "character", "plush-cat");
        if character != self.character || (!character.is_empty() && self.pack.is_none()) {
            self.character = character;
            self.pack = pet_pack::list()
                .into_iter()
                .find(|entry| entry.id == self.character)
                .and_then(|entry| {
                    let name = entry.name.clone();
                    match entry.load() {
                        Ok(pack) => Some(Rc::new(pack)),
                        Err(error) => {
                            eprintln!("无法读取宠物形象 {name}：{error}");
                            None
                        }
                    }
                });
        }
        if let Some(pack) = &self.pack {
            pack.set_gait(self.appearance.gait);
        }
        let startup = config.bool_or(ID, "startup", true);
        if startup != self.startup {
            self.startup = startup;
            if startup {
                if let Err(error) = self.show() {
                    eprintln!("{error}");
                }
            } else {
                self.window = None;
            }
        }
        if let Some(window) = &self.window {
            window.update(self.appearance, self.pack.clone());
        }
    }

    fn perform(&mut self, action: &str) -> Result<String, String> {
        if action == NEXT_CHARACTER {
            let entries = pet_pack::list();
            let next = entries
                .iter()
                .position(|entry| entry.id == self.character)
                .map_or(0, |index| (index + 1) % entries.len());
            let entry = &entries[next];
            self.select(&entry.id)?;
            return Ok(format!("已换成{}", entry.name));
        }
        if action == PICK_AREA {
            let screen = crate::gdi::virtual_screen();
            let selected = crate::overlay::run(screen, Vec::new())?;
            if let baobox_core::selection::Outcome::Region(area) = selected.outcome {
                let mut config = crate::store::load_config();
                config.set(ID, "range", "custom");
                config.set(
                    ID,
                    "area",
                    &format!(
                        "{},{},{},{}",
                        area.x as i32, area.y as i32, area.w as i32, area.h as i32
                    ),
                );
                crate::store::save_config(&config)?;
                self.config_changed(&config);
                unsafe {
                    let _ = PostMessageW(
                        self.owner,
                        crate::app::WM_RELOAD_CONFIG,
                        WPARAM(0),
                        LPARAM(0),
                    );
                }
            }
            return Ok(String::new());
        }
        if let Some(id) = action.strip_prefix(DOWNLOAD) {
            if self.download.is_some() {
                return Err("已有宠物形象正在下载".into());
            }
            let entry = crate::pet_download::catalog()
                .iter()
                .find(|entry| entry.id == id)
                .ok_or("未知的宠物形象")?;
            let (send, receive) = mpsc::channel();
            std::thread::spawn(move || {
                let _ = send.send(crate::pet_download::download(entry).map(|()| entry.id.clone()));
            });
            self.download = Some(receive);
            self.download_status = Some(format!("正在下载 {}…", entry.name));
            return Ok(String::new());
        }
        if let Some(id) = action.strip_prefix(SELECT) {
            self.select(id)?;
            return Ok(String::new());
        }
        if let Some(id) = action.strip_prefix(REMOVE) {
            let entry = crate::pet_download::catalog()
                .iter()
                .find(|entry| entry.id == id)
                .ok_or("未知的宠物形象")?;
            crate::pet_download::remove(entry)?;
            self.catalog = Self::catalog();
            if self.character == id {
                self.select("plush-cat")?;
            }
            return Ok(format!("已移除 {}", entry.name));
        }
        if matches!(action, SIT | PEEK | UNPERCH) {
            let window = self.window.as_ref().ok_or("宠物尚未显示")?;
            if action == UNPERCH {
                window.state.perched.set(None);
                unsafe {
                    let _ = ShowWindow(window.hwnd, SW_SHOWNOACTIVATE);
                }
                return Ok(String::new());
            }
            let target = window
                .state
                .last_window
                .get()
                .filter(|&hwnd| unsafe { IsWindow(hwnd).as_bool() })
                .ok_or("请先激活资源管理器或其他要互动的窗口")?;
            window
                .state
                .perched
                .set(Some((target, if action == SIT { "sit" } else { "peek" })));
            return Ok(String::new());
        }
        if let Some(&(_, kind, _)) = INTERACTIONS.iter().find(|&&(id, _, _)| id == action) {
            if let Some(window) = &self.window {
                window.state.react(kind);
            }
            return Ok(String::new());
        }
        if action != TOGGLE {
            return Err(format!("桌面宠物不认识动作 {action}"));
        }
        if self.window.is_some() {
            self.window = None;
        } else {
            self.show()?;
        }
        Ok(String::new())
    }

    fn will_terminate(&mut self) {
        self.window = None;
    }

    fn tick(&mut self) -> bool {
        let result = match self.download.as_ref().map(Receiver::try_recv) {
            Some(Ok(result)) => result,
            Some(Err(TryRecvError::Disconnected)) => Err("下载线程意外退出".into()),
            _ => return false,
        };
        self.download = None;
        self.catalog = Self::catalog();
        self.download_status = match result.and_then(|id| self.select(&id)) {
            Ok(()) => Some("下载完成，已切换形象".into()),
            Err(error) => Some(error),
        };
        true
    }
}

#[derive(Clone, Copy)]
struct Drag {
    cursor: POINT,
    origin: RECT,
    moved: bool,
}

struct State {
    owner: HWND,
    appearance: Cell<Appearance>,
    since: Cell<Instant>,
    reaction: Cell<Option<Reaction>>,
    drag: Cell<Option<Drag>>,
    direction: Cell<i32>,
    pack: RefCell<Option<Rc<Pack>>>,
    animation: Cell<(&'static str, Instant)>,
    idle_check: Cell<(Instant, bool)>,
    walk_tick: Cell<(Instant, f32)>,
    walk_seconds: Cell<f64>,
    frame_pending: Arc<AtomicBool>,
    last_window: Cell<Option<HWND>>,
    perched: Cell<Option<(HWND, &'static str)>>,
    window_scan: RefCell<Option<(Instant, Vec<(HWND, baobox_core::geometry::Rect)>)>>,
}

#[derive(Clone, Copy)]
struct Reaction {
    name: &'static str,
    start: Instant,
    duration: Duration,
}

struct PetWindow {
    hwnd: HWND,
    state: Box<State>,
    stop_clock: Arc<AtomicBool>,
    clock: Option<std::thread::JoinHandle<()>>,
}

const WM_PET_FRAME: u32 = WM_APP + 6;

fn start_frame_clock(
    hwnd: HWND,
    pending: Arc<AtomicBool>,
    stopped: Arc<AtomicBool>,
) -> std::io::Result<std::thread::JoinHandle<()>> {
    let handle = hwnd.0 as isize;
    std::thread::Builder::new()
        .name("baobox-pet-clock".into())
        .spawn(move || {
            let interval = Duration::from_millis(30);
            let mut next = Instant::now() + interval;
            while !stopped.load(Ordering::Acquire) {
                std::thread::sleep(next.saturating_duration_since(Instant::now()));
                if stopped.load(Ordering::Acquire) {
                    break;
                }
                if !pending.swap(true, Ordering::AcqRel) {
                    let hwnd = HWND(handle as _);
                    if unsafe { PostMessageW(hwnd, WM_PET_FRAME, WPARAM(0), LPARAM(0)) }.is_err() {
                        pending.store(false, Ordering::Release);
                        break;
                    }
                }
                next += interval;
                if next <= Instant::now() {
                    next = Instant::now() + interval;
                }
            }
        })
}

fn position_file() -> Option<std::path::PathBuf> {
    Some(
        crate::store::config_path()?
            .parent()?
            .join("pet-position.txt"),
    )
}

fn saved_position() -> Option<(i32, i32)> {
    let text = std::fs::read_to_string(position_file()?).ok()?;
    let (x, y) = text.trim().split_once(',')?;
    let x = x.parse::<i32>().ok()?;
    let y = y.parse::<i32>().ok()?;
    let screen = crate::gdi::virtual_screen();
    (f64::from(x) >= screen.x
        && f64::from(x) < screen.x + screen.w
        && f64::from(y) >= screen.y
        && f64::from(y) < screen.y + screen.h)
        .then_some((x, y))
}

impl PetWindow {
    fn open(owner: HWND, appearance: Appearance, pack: Option<Rc<Pack>>) -> Result<Self, String> {
        unsafe {
            let instance: HINSTANCE = GetModuleHandleW(None).map_err(|e| e.to_string())?.into();
            RegisterClassW(&WNDCLASSW {
                style: CS_DBLCLKS,
                lpfnWndProc: Some(wndproc),
                hInstance: instance,
                hCursor: LoadCursorW(None, IDC_HAND).unwrap_or_default(),
                lpszClassName: CLASS,
                ..Default::default()
            });
            let saved = saved_position();
            let (x, y) = saved.unwrap_or((0, 0));
            let hwnd = CreateWindowExW(
                WS_EX_LAYERED
                    | WS_EX_TOPMOST
                    | if PREVIEW.get() {
                        WS_EX_APPWINDOW
                    } else {
                        WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
                    },
                CLASS,
                if PREVIEW.get() {
                    w!("BaoBox 步态验收")
                } else {
                    w!("Baobox 桌面宠物")
                },
                WS_POPUP,
                x,
                y,
                1,
                1,
                None,
                None,
                instance,
                None,
            )
            .map_err(|e| format!("创建宠物窗口失败：{e}"))?;
            let mut window = Self {
                hwnd,
                stop_clock: Arc::new(AtomicBool::new(false)),
                clock: None,
                state: Box::new(State {
                    owner,
                    appearance: Cell::new(appearance),
                    since: Cell::new(Instant::now()),
                    reaction: Cell::new(None),
                    drag: Cell::new(None),
                    direction: Cell::new(-1),
                    pack: RefCell::new(pack),
                    animation: Cell::new(("idle", Instant::now())),
                    idle_check: Cell::new((Instant::now(), false)),
                    walk_tick: Cell::new((Instant::now(), 0.0)),
                    walk_seconds: Cell::new(0.0),
                    frame_pending: Arc::new(AtomicBool::new(false)),
                    last_window: Cell::new(None),
                    perched: Cell::new(None),
                    window_scan: RefCell::new(None),
                }),
            };
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, &*window.state as *const State as isize);
            let area = work_area(hwnd);
            let size = window.state.size();
            let (x, y) = saved.unwrap_or((area.right - size - 24, area.bottom - size));
            place(
                hwnd,
                x.clamp(area.left, (area.right - size).max(area.left)),
                y.clamp(area.top, (area.bottom - size).max(area.top)),
                size,
            );
            window
                .state
                .present(hwnd, None)
                .map_err(|e| format!("绘制宠物窗口失败：{e}"))?;
            window.clock = Some(
                start_frame_clock(
                    hwnd,
                    window.state.frame_pending.clone(),
                    window.stop_clock.clone(),
                )
                .map_err(|error| format!("无法启动宠物动画：{error}"))?,
            );
            let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            ANCHOR.set(Some(hwnd));
            Ok(window)
        }
    }

    fn update(&self, appearance: Appearance, pack: Option<Rc<Pack>>) {
        let previous_size = self.state.size();
        self.state.pack.replace(pack);
        self.state.animation.set(("idle", Instant::now()));
        self.state.appearance.set(appearance);
        let size = self.state.size();
        if previous_size != size {
            unsafe {
                let mut rect = RECT::default();
                if GetWindowRect(self.hwnd, &mut rect).is_ok() {
                    let area = work_area(self.hwnd);
                    let x = rect.left + (previous_size - size) / 2;
                    place(
                        self.hwnd,
                        x.clamp(area.left, (area.right - size).max(area.left)),
                        (rect.bottom - size).clamp(area.top, (area.bottom - size).max(area.top)),
                        size,
                    );
                }
            }
        }
        unsafe {
            let _ = self.state.present(self.hwnd, None);
        }
    }
}

impl Drop for PetWindow {
    fn drop(&mut self) {
        if ANCHOR.get() == Some(self.hwnd) {
            ANCHOR.set(None);
        }
        unsafe {
            self.stop_clock.store(true, Ordering::Release);
            if let Some(clock) = self.clock.take() {
                let _ = clock.join();
            }
            SetWindowLongPtrW(self.hwnd, GWLP_USERDATA, 0);
            let _ = DestroyWindow(self.hwnd);
        }
    }
}

unsafe fn work_area(hwnd: HWND) -> RECT {
    let mut info = MONITORINFO {
        cbSize: std::mem::size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    if GetMonitorInfoW(monitor, &mut info).as_bool() {
        info.rcWork
    } else {
        RECT {
            right: GetSystemMetrics(SM_CXSCREEN),
            bottom: GetSystemMetrics(SM_CYSCREEN),
            ..Default::default()
        }
    }
}

fn intersect_area(a: RECT, b: RECT) -> Option<RECT> {
    let area = RECT {
        left: a.left.max(b.left),
        right: a.right.min(b.right),
        top: a.top.max(b.top),
        bottom: a.bottom.min(b.bottom),
    };
    (area.left < area.right && area.top < area.bottom).then_some(area)
}

fn ledge_segments(
    frame: baobox_core::geometry::Rect,
    in_front: &[(HWND, baobox_core::geometry::Rect)],
) -> Vec<(i32, i32)> {
    let top = frame.y as i32;
    let mut segments = vec![(frame.x as i32, (frame.x + frame.w) as i32)];
    for &(_, cover) in in_front {
        if cover.y > f64::from(top + 2) || cover.y + cover.h < f64::from(top - 40) {
            continue;
        }
        let cut = (cover.x as i32, (cover.x + cover.w) as i32);
        segments = segments
            .into_iter()
            .flat_map(|(left, right)| [(left, right.min(cut.0)), (left.max(cut.1), right)])
            .filter(|(left, right)| right - left >= 50)
            .collect();
    }
    segments
}

unsafe fn place(hwnd: HWND, x: i32, y: i32, size: i32) {
    let _ = SetWindowPos(hwnd, None, x, y, size, size, SWP_NOACTIVATE | SWP_NOZORDER);
}

impl State {
    fn ledge(&self, monitor: RECT, origin: POINT, size: i32, target: Option<HWND>) -> Option<RECT> {
        let mut cache = self.window_scan.borrow_mut();
        if cache
            .as_ref()
            .is_none_or(|(time, _)| time.elapsed() >= Duration::from_millis(100))
        {
            *cache = Some((Instant::now(), crate::gdi::pet_windows()));
        }
        let windows = &cache.as_ref()?.1;
        let half_body = (size / 5).max(25);
        windows
            .iter()
            .enumerate()
            .filter(|(_, (hwnd, frame))| {
                target.map_or(
                    frame.w >= 160.0
                        && frame.h >= 100.0
                        && frame.y >= f64::from(monitor.top + size * 3 / 4),
                    |wanted| *hwnd == wanted,
                )
            })
            .flat_map(|(index, (_, frame))| {
                let bottom = frame.y as i32;
                ledge_segments(*frame, &windows[..index])
                    .into_iter()
                    .filter_map(move |(left, right)| {
                        let left = left.max(monitor.left) + half_body;
                        let right = right.min(monitor.right) - half_body;
                        (right >= left && bottom > monitor.top && bottom <= monitor.bottom)
                            .then_some(RECT {
                                left: left - size / 2,
                                right: right - size / 2 + size,
                                top: monitor.top - size / 4,
                                bottom,
                            })
                    })
            })
            .min_by_key(|area| {
                (origin.x - origin.x.clamp(area.left, area.right - size)).abs()
                    + (origin.y - (area.bottom - size)).abs()
            })
    }
    fn size(&self) -> i32 {
        self.appearance.get().size(
            self.pack
                .borrow()
                .as_ref()
                .is_some_and(|pack| pack.is_humanoid()),
        )
    }
    fn reacting(&self) -> bool {
        self.active_reaction().is_some()
    }

    fn active_reaction(&self) -> Option<Reaction> {
        self.reaction
            .get()
            .filter(|reaction| reaction.start.elapsed() < reaction.duration)
    }

    fn react(&self, kind: &'static str) {
        let seconds = self
            .pack
            .borrow()
            .as_ref()
            .and_then(|pack| pack.interaction_seconds(kind));
        self.reaction.set(Some(Reaction {
            name: if seconds.is_some() { kind } else { "happy" },
            start: Instant::now(),
            duration: Duration::from_secs_f32(seconds.unwrap_or(0.75).clamp(0.1, 30.0)),
        }));
    }

    fn phase(&self) -> u64 {
        self.since.get().elapsed().as_secs() % 30
    }

    fn walking(&self) -> bool {
        if self.perched.get().is_some() {
            return false;
        }
        if PREVIEW.get() {
            return !PREVIEW_ACTIONS.get() && !MENU_OPEN.get() && self.drag.get().is_none();
        }
        !self.asleep()
            && !MENU_OPEN.get()
            && self.appearance.get().roam
            && (4..22).contains(&self.phase())
            && self.drag.get().is_none()
    }

    fn asleep(&self) -> bool {
        QUIET.get() || self.idle_check.get().1
    }

    unsafe fn update_idle(&self) {
        if self.idle_check.get().0.elapsed() < Duration::from_secs(1) {
            return;
        }
        let mut input = LASTINPUTINFO {
            cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32,
            dwTime: 0,
        };
        let idle = GetLastInputInfo(&mut input).as_bool()
            && windows::Win32::System::SystemInformation::GetTickCount().wrapping_sub(input.dwTime)
                >= 300_000;
        self.idle_check.set((Instant::now(), idle));
    }

    unsafe fn animate(&self, hwnd: HWND) {
        if CAPTURING.get() {
            return;
        }
        let active = GetForegroundWindow();
        let mut process = 0;
        GetWindowThreadProcessId(active, Some(&mut process));
        if process != 0
            && process != std::process::id()
            && active != GetShellWindow()
            && active != GetDesktopWindow()
        {
            self.last_window.set(Some(active));
        }
        if let Some((target, pose)) = self.perched.get() {
            if IsWindow(target).as_bool() {
                if IsIconic(target).as_bool() || !IsWindowVisible(target).as_bool() {
                    let _ = ShowWindow(hwnd, SW_HIDE);
                    return;
                }
                if let Some(frame) = crate::gdi::visible_frame(target) {
                    let area = work_area(target);
                    let size = self.size();
                    let origin = POINT {
                        x: frame.x as i32 + frame.w as i32 * 3 / 4 - size / 2,
                        y: frame.y as i32 - size,
                    };
                    let Some(ledge) = self.ledge(area, origin, size, Some(target)) else {
                        let _ = ShowWindow(hwnd, SW_HIDE);
                        return;
                    };
                    let anchor = if pose == "peek" {
                        crate::pet_model::PEEK_LINE
                    } else {
                        crate::pet_model::SEAT_LINE
                    };
                    let x = origin.x.clamp(ledge.left, ledge.right - size);
                    let y = ledge.bottom - (size as f32 * anchor).round() as i32;
                    let _ = self.present(hwnd, Some(&POINT { x, y }));
                    if !IsWindowVisible(hwnd).as_bool() {
                        let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
                    }
                    return;
                }
            }
            self.perched.set(None);
            let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        }
        let mut destination = None;
        let now = Instant::now();
        let (previous_tick, remainder) = self.walk_tick.replace((now, 0.0));
        self.update_idle();
        let walking = self.walking() && !self.reacting();
        let elapsed = now.duration_since(previous_tick).as_secs_f64().min(0.09);
        if walking {
            self.walk_seconds.set(self.walk_seconds.get() + elapsed);
        } else {
            self.walk_seconds.set(0.0);
        }
        if self.drag.get().is_some() {
            // 非激活窗口的捕获范围有限，鼠标移出窗口时也要能继续拖动。
            let button = if GetSystemMetrics(SM_SWAPBUTTON) != 0 {
                VK_RBUTTON
            } else {
                VK_LBUTTON
            };
            if GetAsyncKeyState(i32::from(button.0)) < 0 {
                self.move_drag(hwnd);
            } else {
                self.end_drag(hwnd);
            }
        }
        if self.drag.get().is_none() {
            let mut rect = RECT::default();
            if GetWindowRect(hwnd, &mut rect).is_ok() {
                let monitor = work_area(hwnd);
                let appearance = self.appearance.get();
                let size = self.size();
                let area = match appearance.range {
                    Range::Custom(custom) => {
                        let mut info = MONITORINFO {
                            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                            ..Default::default()
                        };
                        if GetMonitorInfoW(
                            MonitorFromRect(&custom, MONITOR_DEFAULTTONEAREST),
                            &mut info,
                        )
                        .as_bool()
                        {
                            intersect_area(info.rcWork, custom).unwrap_or(monitor)
                        } else {
                            monitor
                        }
                    }
                    Range::Windows if self.walking() => self
                        .ledge(
                            monitor,
                            POINT {
                                x: rect.left,
                                y: rect.top,
                            },
                            size,
                            None,
                        )
                        .unwrap_or(monitor),
                    _ => monitor,
                };
                let right = (area.right - size).max(area.left);
                let bottom = (area.bottom - size).max(area.top);
                let mut x = rect.left.clamp(area.left, right);
                let mut y = rect.top.clamp(area.top, bottom);
                if walking {
                    if x == area.left {
                        self.direction.set(1);
                    } else if x == right {
                        self.direction.set(-1);
                    }
                    let rate = self
                        .pack
                        .borrow()
                        .as_ref()
                        .and_then(|pack| pack.walk_rate());
                    let speed = rate.map_or(50.0, |rate| size as f32 * rate);
                    let distance = remainder + speed * elapsed as f32;
                    self.walk_tick.set((now, distance.fract()));
                    let stride = distance as i32;
                    x = (x + self.direction.get() * stride).clamp(area.left, right);
                    if appearance.range != Range::Free {
                        y += (bottom - y).clamp(-12, 12);
                    }
                }
                if (x, y) != (rect.left, rect.top) {
                    destination = Some(POINT { x, y });
                }
            }
        }
        let (state, start) = self.animation.get();
        if !self.asleep()
            || state != "sleep"
            || start.elapsed() < Duration::from_secs(3)
            || self.reacting()
            || destination.is_some()
        {
            let _ = self.present(hwnd, destination.as_ref());
        }
    }

    unsafe fn move_drag(&self, hwnd: HWND) {
        let Some(mut drag) = self.drag.get() else {
            return;
        };
        let mut cursor = POINT::default();
        if GetCursorPos(&mut cursor).is_ok() {
            let dx = cursor.x - drag.cursor.x;
            let dy = cursor.y - drag.cursor.y;
            if drag.moved || dx.abs().max(dy.abs()) >= 4 {
                drag.moved = true;
                self.drag.set(Some(drag));
                place(
                    hwnd,
                    drag.origin.left + dx,
                    drag.origin.top + dy,
                    self.size(),
                );
            }
        }
    }

    unsafe fn end_drag(&self, hwnd: HWND) {
        if let Some(drag) = self.drag.take() {
            let _ = ReleaseCapture();
            let was_asleep = self.asleep();
            self.since.set(Instant::now());
            if drag.moved {
                let mut rect = RECT::default();
                if GetWindowRect(hwnd, &mut rect).is_ok() {
                    if let Some(path) = position_file() {
                        let _ = std::fs::write(path, format!("{},{}", rect.left, rect.top));
                    }
                }
            } else {
                self.react(if was_asleep { "wake" } else { "poke" });
            }
        }
    }

    unsafe fn present(&self, hwnd: HWND, destination: Option<&POINT>) -> windows::core::Result<()> {
        let started = Instant::now();
        let dc = GetDC(None);
        let size = self.size();
        let mut result = Err(windows::core::Error::from_win32());
        let buffer = CreateCompatibleDC(dc);
        if !buffer.is_invalid() {
            let bitmap = CreateCompatibleBitmap(dc, size, size);
            if !bitmap.is_invalid() {
                let previous = SelectObject(buffer, bitmap);
                if !previous.is_invalid() {
                    self.paint_frame(buffer, size);
                    result = UpdateLayeredWindow(
                        hwnd,
                        dc,
                        destination.map(|point| point as *const POINT),
                        Some(&SIZE { cx: size, cy: size }),
                        buffer,
                        Some(&POINT::default()),
                        KEY,
                        None,
                        ULW_COLORKEY,
                    );
                    SelectObject(buffer, previous);
                }
                let _ = DeleteObject(bitmap);
            }
            let _ = DeleteDC(buffer);
        }
        ReleaseDC(None, dc);
        let tracing = TRACE_OUTPUT.with_borrow(|output| output.is_some());
        if (PREVIEW.get() || tracing) && result.is_ok() {
            let mut bounds = RECT::default();
            if GetWindowRect(hwnd, &mut bounds).is_ok() {
                FRAME_TRACE.with_borrow_mut(|trace| {
                    trace.push((
                        Instant::now(),
                        started.elapsed().as_secs_f64() * 1000.0,
                        bounds.left,
                        bounds.top,
                    ))
                });
            }
        }
        if tracing {
            let expired = TRACE_OUTPUT.with_borrow(|output| {
                output
                    .as_ref()
                    .is_some_and(|(_, end)| Instant::now() >= *end)
            });
            if expired {
                if let Some((path, _)) = TRACE_OUTPUT.take() {
                    if let Err(error) = write_trace(&path) {
                        eprintln!("无法写入桌宠帧记录：{error}");
                    }
                    FRAME_TRACE.with_borrow_mut(Vec::clear);
                }
            }
        }
        result
    }

    unsafe fn paint_frame(&self, dc: HDC, size: i32) {
        let appearance = self.appearance.get();
        let background = CreateSolidBrush(KEY);
        FillRect(
            dc,
            &RECT {
                left: 0,
                top: 0,
                right: size,
                bottom: size,
            },
            background,
        );
        let _ = DeleteObject(background);
        let sleeping = self.asleep() && !self.reacting() && self.drag.get().is_none();
        if let Some(pack) = self.pack.borrow().as_ref() {
            let reaction = self.active_reaction();
            let preview_pose = PREVIEW_ACTIONS.get().then(|| {
                let states = [
                    "sit", "peek", "nod", "shake", "laugh", "cry", "pet", "feed", "play",
                ];
                let elapsed = self.since.get().elapsed().as_secs_f64();
                (
                    states[(elapsed / 2.0) as usize % states.len()],
                    elapsed % 2.0,
                )
            });
            let state = if let Some((pose, _)) = preview_pose {
                pose
            } else if let Some((_, pose)) = self.perched.get() {
                pose
            } else if self.drag.get().is_some() {
                "drag"
            } else if let Some(reaction) = reaction {
                reaction.name
            } else if sleeping {
                "sleep"
            } else if self.walking() {
                "walk"
            } else if self.phase() >= 22 && pack.interaction_seconds("fidget").is_some() {
                "fidget"
            } else {
                "idle"
            };
            let (last, mut started) = self.animation.get();
            if last != state {
                started = reaction.map_or_else(Instant::now, |reaction| reaction.start);
                self.animation.set((state, started));
            }
            pack.draw(
                dc,
                size,
                state,
                if let Some((_, seconds)) = preview_pose {
                    seconds
                } else if state == "walk" && pack.walk_rate().is_some() {
                    self.walk_seconds.get()
                } else {
                    started.elapsed().as_secs_f64()
                },
                self.direction.get() < 0,
            );
            return;
        }
        let brushes =
            [0x36252a, appearance.coat, 0xd3eaff].map(|color| CreateSolidBrush(COLORREF(color)));
        let step = self.since.get().elapsed().as_millis() / 150 % 2;
        let bounce = self.reacting() || (self.walking() && step == 0);
        for (y, row) in CAT.iter().enumerate() {
            for (x, pixel) in row.iter().enumerate() {
                let brush = match pixel {
                    b'#' | b'o' => brushes[0],
                    b'+' => brushes[1],
                    b'.' => brushes[2],
                    _ => continue,
                };
                let column = if self.direction.get() > 0 { 11 - x } else { x } as i32;
                let row = y as i32 + i32::from(!bounce);
                let left = (column + 1) * size / 13 - size / 26;
                let right = (column + 2) * size / 13 - size / 26;
                let top = row * size / 13;
                let bottom = if sleeping && y == 5 && *pixel == b'o' {
                    top + size / 39
                } else {
                    (row + 1) * size / 13
                };
                FillRect(
                    dc,
                    &RECT {
                        left,
                        top,
                        right,
                        bottom,
                    },
                    brush,
                );
            }
        }
        for brush in brushes {
            let _ = DeleteObject(brush);
        }
    }
}

unsafe extern "system" fn wndproc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let state = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const State;
    let Some(state) = state.as_ref() else {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    };
    match message {
        WM_CLOSE if PREVIEW.get() => PostQuitMessage(0),
        WM_TIMER if PREVIEW.get() && wparam.0 == 2 => PostQuitMessage(0),
        WM_KEYDOWN if PREVIEW.get() && wparam.0 == 0x1b => PostQuitMessage(0),
        WM_PET_FRAME => {
            state.animate(hwnd);
            state.frame_pending.store(false, Ordering::Release);
        }
        WM_LBUTTONDOWN => {
            let mut cursor = POINT::default();
            let mut origin = RECT::default();
            if GetCursorPos(&mut cursor).is_ok() && GetWindowRect(hwnd, &mut origin).is_ok() {
                state.drag.set(Some(Drag {
                    cursor,
                    origin,
                    moved: false,
                }));
                SetCapture(hwnd);
            }
        }
        WM_MOUSEMOVE => state.move_drag(hwnd),
        WM_LBUTTONUP => state.end_drag(hwnd),
        WM_LBUTTONDBLCLK => state.react("highFive"),
        WM_PET_REACT => state.react("happy"),
        WM_CAPTURECHANGED | WM_CANCELMODE => {
            if state.drag.take().is_some() && message == WM_CANCELMODE {
                let _ = ReleaseCapture();
            }
        }
        WM_RBUTTONUP => {
            let _ = PostMessageW(state.owner, WM_PET_MENU, WPARAM(0), LPARAM(0));
        }
        WM_CLOSE => {}
        _ => return DefWindowProcW(hwnd, message, wparam, lparam),
    }
    LRESULT(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn window_ledges_exclude_occlusion_near_the_top_edge() {
        use baobox_core::geometry::Rect;
        let window = Rect::new(10.0, 200.0, 700.0, 450.0);
        let fronts = [
            (HWND::default(), Rect::new(190.0, 150.0, 150.0, 90.0)),
            (HWND::default(), Rect::new(480.0, 250.0, 90.0, 60.0)),
        ];
        assert_eq!(ledge_segments(window, &fronts), vec![(10, 190), (340, 710)]);
    }

    #[test]
    fn toggle_creates_and_destroys_the_native_pet_window() {
        let mut tool = PetTool::new(HWND::default());
        let mut config = Config::new();
        config.set_bool(ID, "startup", false);
        tool.activate(&config);
        assert!(tool.window.is_none());

        tool.perform(TOGGLE).unwrap();
        let hwnd = tool.window.as_ref().unwrap().hwnd;
        unsafe {
            assert!(IsWindowVisible(hwnd).as_bool());
            let mut rect = RECT::default();
            GetWindowRect(hwnd, &mut rect).unwrap();
            assert_eq!(rect.right - rect.left, tool.appearance.size(false));
            let state = &tool.window.as_ref().unwrap().state;
            let destination = POINT {
                x: rect.left - 8,
                y: rect.top - 5,
            };
            state.present(hwnd, Some(&destination)).unwrap();
            GetWindowRect(hwnd, &mut rect).unwrap();
            assert_eq!((rect.left, rect.top), (destination.x, destination.y));
            let mut cursor = POINT::default();
            GetCursorPos(&mut cursor).unwrap();
            state.drag.set(Some(Drag {
                cursor: POINT {
                    x: cursor.x + 25,
                    y: cursor.y + 12,
                },
                origin: rect,
                moved: false,
            }));
            state.move_drag(hwnd);
            let mut moved = RECT::default();
            GetWindowRect(hwnd, &mut moved).unwrap();
            assert_eq!((moved.left, moved.top), (rect.left - 25, rect.top - 12));
            state.drag.set(None);
        }

        tool.perform(TOGGLE).unwrap();
        assert!(!unsafe { IsWindow(hwnd) }.as_bool());
    }
}
