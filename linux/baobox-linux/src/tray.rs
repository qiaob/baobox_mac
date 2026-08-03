//! Linux 托盘图标：StatusNotifierItem + dbusmenu。
//!
//! # 为什么是这两个协议
//!
//! Linux 没有「系统托盘 API」。现在的桌面认的是 **StatusNotifierItem**（KDE 起草，
//! 后来成了事实标准）：我们在会话总线上导出一个对象，向 `StatusNotifierWatcher`
//! 报到，桌面那边负责把图标画在面板上。菜单不走 SNI 本身，而是另一个协议
//! **com.canonical.dbusmenu** —— 菜单结构由我们提供，**由桌面渲染**，
//! 所以外观是原生的。
//!
//! 老的 XEmbed systray 已经被 GNOME 移除，没有退路，这条路是唯一的。
//!
//! # 桌面支持情况（会影响用户看不看得到图标）
//!
//! - KDE / XFCE / Cinnamon / Budgie：开箱可用
//! - **GNOME：默认不显示**，需要用户装 AppIndicator 扩展。这是 GNOME 自己的决定，
//!   任何 App 都绕不过去，所以 [`Tray::start`] 在报到失败时会明确告诉用户这件事，
//!   而不是留下一个「程序像是没启动」的假象
//!
//! # 菜单 id
//!
//! dbusmenu 用**整数** id，根节点固定是 0。我们在建菜单时顺次编号，
//! 同时记下「整数 → 动作字符串」的映射，点击事件回来时反查。
//! 菜单每次重建都会换一批 id，所以重建后必须发 `LayoutUpdated` 让桌面重新拉取。

use baobox_app::{MenuItem, MenuModel};
use baobox_render::Canvas;
use baobox_core::annotation::Color;
use baobox_core::geometry::Rect;
use std::collections::HashMap;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use zbus::blocking::Connection;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedValue, Value};
use zbus::{fdo, interface};

/// SNI 对象路径（约定俗成，多数实现都用这个）。
const ITEM_PATH: &str = "/StatusNotifierItem";

/// dbusmenu 对象路径。
const MENU_PATH: &str = "/MenuBar";

/// 托盘图标边长。面板通常会缩放，22 是传统的托盘尺寸。
const ICON_SIZE: usize = 22;

/// 托盘要告诉外面发生了什么。
pub enum TrayEvent {
    /// 用户点了某个动作
    Action(String),
}

/// 菜单的共享状态：一份树 + 一份 id 映射。
///
/// 托盘线程与主线程都要碰它（主线程重建菜单，托盘线程响应桌面的拉取），
/// 所以上锁。锁里只有内存操作，不会持锁做 IO。
#[derive(Default)]
struct MenuState {
    /// 整数 id → 动作字符串
    actions: HashMap<i32, String>,
    /// 整数 id → 这一项的属性
    props: HashMap<i32, ItemProps>,
    /// 整数 id → 子项 id
    children: HashMap<i32, Vec<i32>>,
    /// 每次重建 +1，桌面用它判断要不要重新拉取
    revision: u32,
}

/// dbusmenu 里一项的属性。
#[derive(Clone, Default)]
struct ItemProps {
    label: String,
    enabled: bool,
    separator: bool,
    submenu: bool,
}

impl MenuState {
    /// 把菜单模型摊平成 dbusmenu 的整数编号结构。
    fn rebuild(&mut self, model: &MenuModel) {
        self.actions.clear();
        self.props.clear();
        self.children.clear();
        self.revision = self.revision.wrapping_add(1);

        // 根节点固定是 0
        self.props.insert(0, ItemProps::default());
        let mut next = 1;
        let roots = self.flatten(&model.items, &mut next);
        self.children.insert(0, roots);
    }

    fn flatten(&mut self, items: &[MenuItem], next: &mut i32) -> Vec<i32> {
        let mut ids = Vec::with_capacity(items.len());
        for item in items {
            let id = *next;
            *next += 1;
            ids.push(id);
            match item {
                MenuItem::Separator => {
                    self.props.insert(
                        id,
                        ItemProps {
                            separator: true,
                            enabled: false,
                            ..Default::default()
                        },
                    );
                }
                MenuItem::Action {
                    id: action,
                    label,
                    enabled,
                    hint,
                } => {
                    // 快捷键直接缀在标签后面。dbusmenu 有个 `shortcut` 属性，
                    // 但各桌面对它的渲染差别很大，有的干脆不显示 ——
                    // 缀在标签里丑一点，但保证用户看得见
                    let text = match hint {
                        Some(hint) => format!("{label}\t{hint}"),
                        None => label.clone(),
                    };
                    self.props.insert(
                        id,
                        ItemProps {
                            label: text,
                            enabled: *enabled,
                            ..Default::default()
                        },
                    );
                    if *enabled && !action.is_empty() {
                        self.actions.insert(id, action.clone());
                    }
                }
                MenuItem::Submenu { label, items } => {
                    self.props.insert(
                        id,
                        ItemProps {
                            label: label.clone(),
                            enabled: true,
                            submenu: true,
                            ..Default::default()
                        },
                    );
                    let kids = self.flatten(items, next);
                    self.children.insert(id, kids);
                }
            }
        }
        ids
    }

    /// 一项的 dbusmenu 属性字典。
    fn properties(&self, id: i32) -> HashMap<String, OwnedValue> {
        let mut map = HashMap::new();
        let Some(props) = self.props.get(&id) else {
            return map;
        };
        if props.separator {
            insert(&mut map, "type", Value::from("separator"));
            return map;
        }
        if id != 0 {
            insert(&mut map, "label", Value::from(props.label.as_str()));
            insert(&mut map, "enabled", Value::from(props.enabled));
            insert(&mut map, "visible", Value::from(true));
        }
        if props.submenu || id == 0 {
            insert(&mut map, "children-display", Value::from("submenu"));
        }
        map
    }

    /// 递归建出 dbusmenu 的布局结构 `(i, a{sv}, av)`。
    fn layout(&self, id: i32, depth: i32) -> OwnedValue {
        let children: Vec<OwnedValue> = if depth == 0 {
            Vec::new()
        } else {
            self.children
                .get(&id)
                .map(|kids| {
                    kids.iter()
                        .map(|kid| self.layout(*kid, depth - 1))
                        .collect()
                })
                .unwrap_or_default()
        };
        let structure = Value::from((id, self.properties(id), children));
        OwnedValue::try_from(structure).unwrap_or_else(|_| {
            // 理论上不会失败；真失败了给一个空项，总好过让整个菜单拉取报错
            OwnedValue::try_from(Value::from((id, HashMap::<String, OwnedValue>::new(), Vec::<OwnedValue>::new())))
                .expect("空的布局项一定构造得出来")
        })
    }
}

fn insert(map: &mut HashMap<String, OwnedValue>, key: &str, value: Value<'_>) {
    if let Ok(owned) = OwnedValue::try_from(value) {
        map.insert(key.to_string(), owned);
    }
}

/// `org.kde.StatusNotifierItem` 的实现。
struct StatusNotifierItem {
    events: Sender<TrayEvent>,
}

#[interface(name = "org.kde.StatusNotifierItem")]
impl StatusNotifierItem {
    /// 左键点击。我们把菜单交给桌面渲染，所以这里请桌面弹菜单。
    fn activate(&self, _x: i32, _y: i32) {
        // 有些桌面（KDE）左键会直接调这里而不是弹菜单。
        // 我们的托盘只有菜单这一种交互，所以把它当成「请弹菜单」，
        // 但协议里没有「请弹菜单」的回调 —— ItemIsMenu = true 就是干这个的，
        // 声明之后桌面会自己弹，这里只剩兜底
        let _ = &self.events;
    }

    /// 中键点击。没有第二动作，留空。
    fn secondary_activate(&self, _x: i32, _y: i32) {}

    /// 滚轮。截图工具没有可滚的东西。
    fn scroll(&self, _delta: i32, _orientation: &str) {}

    /// 右键。同 `activate`。
    fn context_menu(&self, _x: i32, _y: i32) {}

    /// 分类：我们是个应用状态图标。
    #[zbus(property)]
    fn category(&self) -> &str {
        "ApplicationStatus"
    }

    /// 唯一标识。
    #[zbus(property)]
    fn id(&self) -> &str {
        "baobox"
    }

    /// 悬停时的标题。
    #[zbus(property)]
    fn title(&self) -> &str {
        "Baobox"
    }

    /// 一直显示。
    #[zbus(property)]
    fn status(&self) -> &str {
        "Active"
    }

    /// 图标名。给一个主题里可能有的名字作为后备；真正用的是下面的像素。
    #[zbus(property)]
    fn icon_name(&self) -> &str {
        ""
    }

    /// 自带像素的图标。
    ///
    /// **不依赖图标主题**：给图标名的话，主题里没有就会显示成一个问号或干脆空白。
    /// 这里直接给 ARGB32 像素，画的是我们自己的标志。
    #[zbus(property)]
    fn icon_pixmap(&self) -> Vec<(i32, i32, Vec<u8>)> {
        vec![(ICON_SIZE as i32, ICON_SIZE as i32, icon_argb())]
    }

    /// 菜单对象的路径。
    #[zbus(property)]
    fn menu(&self) -> zbus::zvariant::ObjectPath<'_> {
        zbus::zvariant::ObjectPath::from_static_str(MENU_PATH)
            .expect("MENU_PATH 是编译期常量，一定是合法路径")
    }

    /// 告诉桌面「点我就是弹菜单」，于是左键也弹菜单，不必自己处理坐标。
    #[zbus(property)]
    fn item_is_menu(&self) -> bool {
        true
    }
}

/// `com.canonical.dbusmenu` 的实现。
struct DBusMenu {
    state: Arc<Mutex<MenuState>>,
    events: Sender<TrayEvent>,
}

#[interface(name = "com.canonical.dbusmenu")]
impl DBusMenu {
    /// 桌面拉取菜单结构。`depth` 为 -1 表示要整棵树。
    fn get_layout(
        &self,
        parent_id: i32,
        recursion_depth: i32,
        _property_names: Vec<String>,
    ) -> fdo::Result<(u32, OwnedValue)> {
        let state = self.state.lock().map_err(|_| poisoned())?;
        // -1 = 全部；这里给一个足够深的值，菜单只有两层
        let depth = if recursion_depth < 0 { 8 } else { recursion_depth };
        Ok((state.revision, state.layout(parent_id, depth)))
    }

    /// 批量取属性。
    fn get_group_properties(
        &self,
        ids: Vec<i32>,
        _property_names: Vec<String>,
    ) -> fdo::Result<Vec<(i32, HashMap<String, OwnedValue>)>> {
        let state = self.state.lock().map_err(|_| poisoned())?;
        Ok(ids.into_iter().map(|id| (id, state.properties(id))).collect())
    }

    /// 取单个属性。
    fn get_property(&self, id: i32, name: String) -> fdo::Result<OwnedValue> {
        let state = self.state.lock().map_err(|_| poisoned())?;
        state
            .properties(id)
            .remove(&name)
            .ok_or_else(|| fdo::Error::InvalidArgs(format!("菜单项 {id} 没有属性 {name}")))
    }

    /// 用户点了某一项。
    ///
    /// **事件必须立刻返回**：这是同步的 DBus 调用，在这里干活会把桌面的面板卡住。
    /// 所以只把动作 id 丢进队列，真正的执行在别的线程。
    fn event(&self, id: i32, event_id: String, _data: Value<'_>, _timestamp: u32) {
        if event_id != "clicked" {
            return;
        }
        let action = self
            .state
            .lock()
            .ok()
            .and_then(|state| state.actions.get(&id).cloned());
        if let Some(action) = action {
            let _ = self.events.send(TrayEvent::Action(action));
        }
    }

    /// 菜单即将弹出。我们的菜单在重建时就是最新的，不需要临时刷新。
    fn about_to_show(&self, _id: i32) -> bool {
        false
    }

    /// 协议版本。
    #[zbus(property)]
    fn version(&self) -> u32 {
        3
    }

    /// 菜单整体状态。
    #[zbus(property)]
    fn status(&self) -> &str {
        "normal"
    }

    /// 文字方向。
    #[zbus(property)]
    fn text_direction(&self) -> &str {
        "ltr"
    }

    /// 图标主题路径。我们不用主题图标。
    #[zbus(property)]
    fn icon_theme_path(&self) -> Vec<String> {
        Vec::new()
    }

    /// 菜单结构变了。桌面收到之后会重新 `GetLayout`。
    #[zbus(signal)]
    async fn layout_updated(
        emitter: &SignalEmitter<'_>,
        revision: u32,
        parent: i32,
    ) -> zbus::Result<()>;
}

fn poisoned() -> fdo::Error {
    fdo::Error::Failed("菜单状态被另一个线程的 panic 弄脏了".to_string())
}

/// 活着的托盘图标。析构时连接关闭，图标自动消失。
pub struct Tray {
    connection: Connection,
    state: Arc<Mutex<MenuState>>,
}

impl Tray {
    /// 把图标放上托盘。
    ///
    /// 报到失败通常意味着桌面根本没有 `StatusNotifierWatcher`（最常见的是 GNOME），
    /// 这时返回的错误里会写清楚要装什么 —— 不能让用户面对一个「启动了但什么都没有」
    /// 的程序。
    pub fn start(model: &MenuModel, events: Sender<TrayEvent>) -> Result<Self, String> {
        let mut state = MenuState::default();
        state.rebuild(model);
        let state = Arc::new(Mutex::new(state));

        let name = format!("org.kde.StatusNotifierItem-{}-1", std::process::id());
        let connection = zbus::blocking::connection::Builder::session()
            .map_err(|e| format!("连不上会话总线：{e}"))?
            .name(name.as_str())
            .map_err(|e| format!("申请总线名失败：{e}"))?
            .serve_at(
                ITEM_PATH,
                StatusNotifierItem {
                    events: events.clone(),
                },
            )
            .map_err(|e| format!("导出托盘对象失败：{e}"))?
            .serve_at(
                MENU_PATH,
                DBusMenu {
                    state: Arc::clone(&state),
                    events,
                },
            )
            .map_err(|e| format!("导出菜单对象失败：{e}"))?
            .build()
            .map_err(|e| format!("建立总线连接失败：{e}"))?;

        register(&connection, &name)?;
        Ok(Self { connection, state })
    }

    /// 菜单内容变了（比如开始录制之后那一项变成「停止录制」）。
    pub fn refresh(&self, model: &MenuModel) {
        let revision = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.rebuild(model);
            state.revision
        };
        // 通知桌面重新拉 —— 不发的话面板会一直显示旧菜单
        if let Ok(iface) = self
            .connection
            .object_server()
            .interface::<_, DBusMenu>(MENU_PATH)
        {
            let emitter = iface.signal_emitter().clone();
            let _ = zbus::block_on(DBusMenu::layout_updated(&emitter, revision, 0));
        }
    }
}

/// 向 `StatusNotifierWatcher` 报到。
fn register(connection: &Connection, name: &str) -> Result<(), String> {
    let proxy = zbus::blocking::Proxy::new(
        connection,
        "org.kde.StatusNotifierWatcher",
        "/StatusNotifierWatcher",
        "org.kde.StatusNotifierWatcher",
    )
    .map_err(|e| format!("找不到托盘服务：{e}"))?;

    proxy
        .call::<_, _, ()>("RegisterStatusNotifierItem", &(name))
        .map_err(|_| no_watcher())?;
    Ok(())
}

/// 桌面上没有托盘服务时的说明。
///
/// 这是 Linux 上最常见的一种「装了但看不到」，值得把话说全。
fn no_watcher() -> String {
    no_watcher_for(&std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default())
}

/// 同上，桌面名作为参数 —— 测试不必去改进程级的环境变量
/// （那会和并行跑的别的测试互相踩）。
fn no_watcher_for(desktop: &str) -> String {
    let hint = if desktop.to_ascii_lowercase().contains("gnome") {
        "检测到 GNOME：它默认不显示托盘图标，需要装一个扩展 —— \
         在 https://extensions.gnome.org 搜索 AppIndicator and KStatusNotifierItem Support 并启用。"
    } else {
        "当前桌面没有提供 StatusNotifierWatcher 服务。KDE / XFCE / Cinnamon 自带；\
         其他桌面可以装 snixembed 之类的桥接程序。"
    };
    format!("托盘图标放不上去。{hint}\n（程序仍在运行，全局快捷键照常可用。）")
}

/// 画一个托盘图标：圆角方块里一个 B。
///
/// 自己画而不是带一个 PNG 资源：托盘图标要跟着面板高度换尺寸，
/// 而我们本来就有一套绘制栈，随手就能按尺寸画出来。
fn icon_argb() -> Vec<u8> {
    let mut pixels = vec![0u8; ICON_SIZE * ICON_SIZE * 4];
    let Some(mut canvas) = Canvas::new(ICON_SIZE, ICON_SIZE, &mut pixels) else {
        return pixels;
    };
    let accent = Color::rgb(0x17, 0xA3, 0x98);
    let size = ICON_SIZE as f64;
    baobox_render::fill_rect(&mut canvas, &Rect::new(1.0, 1.0, size - 2.0, size - 2.0), accent);

    // 一个粗略的 B：一竖两半圆
    let ink = Color::rgb(0xFF, 0xFF, 0xFF);
    baobox_render::line(&mut canvas, (7.0, 5.0), (7.0, 17.0), 2.0, ink);
    baobox_render::stroke_ellipse_in(&mut canvas, &Rect::new(7.0, 5.0, 8.0, 6.0), 2.0, ink);
    baobox_render::stroke_ellipse_in(&mut canvas, &Rect::new(7.0, 11.0, 9.0, 6.0), 2.0, ink);

    // SNI 的像素是 **ARGB32 大端**，而我们的画布是 RGBA
    let mut argb = Vec::with_capacity(pixels.len());
    for pixel in pixels.chunks_exact(4) {
        argb.extend_from_slice(&[pixel[3], pixel[0], pixel[1], pixel[2]]);
    }
    argb
}

#[cfg(test)]
mod tests {
    use super::*;
    use baobox_app::menu::{ACTION_QUIT, ACTION_SETTINGS};

    pub(super) fn model() -> MenuModel {
        MenuModel {
            items: vec![
                MenuItem::Submenu {
                    label: "截图".into(),
                    items: vec![
                        MenuItem::action("screenshot.capture", "截图…").with_hint("Ctrl+Shift+S"),
                        MenuItem::disabled("录屏（未检测到 ffmpeg）"),
                    ],
                },
                MenuItem::Separator,
                MenuItem::action(ACTION_SETTINGS, "设置…"),
                MenuItem::action(ACTION_QUIT, "退出"),
            ],
        }
    }

    #[test]
    fn every_clickable_item_gets_an_id_and_disabled_ones_do_not() {
        let mut state = MenuState::default();
        state.rebuild(&model());
        let actions: Vec<&String> = state.actions.values().collect();
        assert_eq!(actions.len(), 3, "两个内建项 + 一个截图动作");
        assert!(state.actions.values().any(|a| a == "screenshot.capture"));
        assert!(
            !state.actions.values().any(|a| a.is_empty()),
            "置灰项不该拿到可点 id"
        );
    }

    #[test]
    fn the_root_has_the_top_level_items_as_children() {
        let mut state = MenuState::default();
        state.rebuild(&model());
        assert_eq!(state.children[&0].len(), 4);
    }

    #[test]
    fn a_submenu_is_marked_so_the_desktop_knows_to_nest_it() {
        let mut state = MenuState::default();
        state.rebuild(&model());
        // 第一个顶层项是二级菜单
        let first = state.children[&0][0];
        let props = state.properties(first);
        assert!(props.contains_key("children-display"));
        assert_eq!(state.children[&first].len(), 2);
    }

    #[test]
    fn separators_are_typed_and_carry_no_label() {
        let mut state = MenuState::default();
        state.rebuild(&model());
        let separator = state.children[&0][1];
        let props = state.properties(separator);
        assert!(props.contains_key("type"));
        assert!(!props.contains_key("label"));
    }

    #[test]
    fn the_shortcut_hint_ends_up_visible_in_the_label() {
        let mut state = MenuState::default();
        state.rebuild(&model());
        let submenu = state.children[&0][0];
        let first_child = state.children[&submenu][0];
        assert!(state.props[&first_child].label.contains("Ctrl+Shift+S"));
    }

    #[test]
    fn rebuilding_bumps_the_revision_so_the_desktop_refetches() {
        let mut state = MenuState::default();
        state.rebuild(&model());
        let first = state.revision;
        state.rebuild(&model());
        assert_ne!(state.revision, first, "不 +1 的话面板会一直显示旧菜单");
    }

    #[test]
    fn rebuilding_does_not_leak_ids_from_the_previous_menu() {
        let mut state = MenuState::default();
        state.rebuild(&model());
        let before = state.actions.len();
        state.rebuild(&model());
        assert_eq!(state.actions.len(), before, "旧 id 必须被清掉");
    }

    #[test]
    fn the_icon_is_argb_and_fully_sized() {
        let icon = icon_argb();
        assert_eq!(icon.len(), ICON_SIZE * ICON_SIZE * 4);
        // 中心应当是不透明的（画了底色）
        let center = ((ICON_SIZE / 2) * ICON_SIZE + ICON_SIZE / 2) * 4;
        assert_eq!(icon[center], 0xFF, "第一个字节是 alpha，必须不透明");
    }

    #[test]
    fn the_gnome_case_is_called_out_by_name() {
        // GNOME 上「装了但看不到图标」是最常见的一种困惑，必须说清楚
        let message = no_watcher_for("ubuntu:GNOME");
        assert!(message.contains("GNOME"));
        assert!(message.contains("扩展"));
        assert!(message.contains("快捷键照常可用"), "要说清楚程序还在跑");

        // 别的桌面给的是另一套建议，但同样要声明程序还在跑
        let other = no_watcher_for("KDE");
        assert!(!other.contains("扩展"));
        assert!(other.contains("快捷键照常可用"));
    }
}

/// 对着一个**假的** `StatusNotifierWatcher` 跑一遍完整协议。
///
/// 上面那些测试验的是菜单模型；这里验的是**真正走 DBus 的那一段** ——
/// `(i, a{sv}, av)` 这个递归结构的编码最容易写错，而写错的表现是
/// 「面板上图标在，菜单是空的」，光看代码看不出来。
///
/// 没有会话总线时（CI 的默认环境）整组测试跳过，不算失败。
#[cfg(test)]
mod protocol_tests {
    use super::*;
    use std::sync::mpsc::channel;
    use zbus::zvariant::OwnedObjectPath;

    /// 假的托盘服务：只记下谁报到了。
    struct FakeWatcher {
        registered: Arc<Mutex<Vec<String>>>,
    }

    #[interface(name = "org.kde.StatusNotifierWatcher")]
    impl FakeWatcher {
        fn register_status_notifier_item(&self, service: String) {
            if let Ok(mut list) = self.registered.lock() {
                list.push(service);
            }
        }

        #[zbus(property)]
        fn is_status_notifier_host_registered(&self) -> bool {
            true
        }

        #[zbus(property)]
        fn registered_status_notifier_items(&self) -> Vec<String> {
            self.registered
                .lock()
                .map(|list| list.clone())
                .unwrap_or_default()
        }

        #[zbus(property)]
        fn protocol_version(&self) -> i32 {
            0
        }
    }

    /// 有没有会话总线可用。
    fn has_session_bus() -> bool {
        zbus::blocking::Connection::session().is_ok()
    }

    #[test]
    fn the_menu_survives_a_real_dbus_round_trip() {
        if !has_session_bus() {
            eprintln!("跳过：没有会话总线（CI 环境常态）");
            return;
        }

        let registered = Arc::new(Mutex::new(Vec::new()));
        let _watcher = zbus::blocking::connection::Builder::session()
            .expect("已经确认有会话总线")
            .name("org.kde.StatusNotifierWatcher")
            .expect("总线名应当申请得到")
            .serve_at(
                "/StatusNotifierWatcher",
                FakeWatcher {
                    registered: Arc::clone(&registered),
                },
            )
            .expect("导出假 watcher")
            .build()
            .expect("建立连接");

        let model = super::tests::model();
        let (tx, rx) = channel();
        let tray = Tray::start(&model, tx).expect("有 watcher 在，报到应当成功");

        // 报到了吗
        let names = registered.lock().unwrap().clone();
        assert_eq!(names.len(), 1, "应当恰好报到一次");
        assert!(names[0].contains("StatusNotifierItem"));

        // 桌面视角：把菜单整棵拉下来
        let client = zbus::blocking::Connection::session().unwrap();
        let menu = zbus::blocking::Proxy::new(
            &client,
            names[0].as_str(),
            MENU_PATH,
            "com.canonical.dbusmenu",
        )
        .expect("连上菜单对象");

        let (revision, layout): (u32, OwnedValue) = menu
            .call("GetLayout", &(0i32, -1i32, Vec::<String>::new()))
            .expect("GetLayout 应当返回一棵树");
        assert!(revision >= 1);

        // 结构应当是 (i, a{sv}, av)，根节点有 4 个孩子
        let text = format!("{layout:?}");
        assert!(text.contains("截图"), "二级菜单的标题应当在树里：{text}");
        assert!(
            text.contains("Ctrl+Shift+S"),
            "快捷键提示应当跟着标签一起过来：{text}"
        );
        assert!(text.contains("separator"), "分隔线应当带类型：{text}");

        // SNI 那边的属性也该读得到
        let item = zbus::blocking::Proxy::new(
            &client,
            names[0].as_str(),
            ITEM_PATH,
            "org.kde.StatusNotifierItem",
        )
        .expect("连上托盘对象");
        let menu_path: OwnedObjectPath = item.get_property("Menu").expect("Menu 属性");
        assert_eq!(menu_path.as_str(), MENU_PATH);
        let pixmaps: Vec<(i32, i32, Vec<u8>)> =
            item.get_property("IconPixmap").expect("IconPixmap 属性");
        assert_eq!(pixmaps[0].0, ICON_SIZE as i32);
        assert_eq!(pixmaps[0].2.len(), ICON_SIZE * ICON_SIZE * 4);

        // 点一下第一个可点项，应当能收到动作
        let clickable = {
            let state = tray.state.lock().unwrap();
            *state
                .actions
                .iter()
                .find(|(_, action)| action.as_str() == "screenshot.capture")
                .expect("截图动作应当有 id")
                .0
        };
        menu.call::<_, _, ()>(
            "Event",
            &(clickable, "clicked", zbus::zvariant::Value::from(0i32), 0u32),
        )
        .expect("Event 调用");
        let received = rx
            .recv_timeout(std::time::Duration::from_secs(3))
            .expect("点击应当变成一个动作");
        let TrayEvent::Action(action) = received;
        assert_eq!(action, "screenshot.capture");
    }
}
