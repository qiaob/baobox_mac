//! 键盘点击（Linux）：AT-SPI 枚举可点元素，XTEST 点它。
//!
//! 标签怎么发、打字之后怎么反应在 `baobox_core::hints`（三平台共用），
//! 这里只回答两个问题：**屏幕上有哪些可点的东西**、**怎么点**。
//!
//! # 只有 AT-SPI 这一条路
//!
//! X11 本身只知道「窗口」，不知道窗口里有哪些按钮 —— 那些是各个工具包
//! 自己画的。AT-SPI（无障碍总线）是唯一的通用问法：GTK、Qt、Electron、
//! Firefox、Chrome 都实现了它，因为屏幕阅读器要靠它。
//!
//! # 它默认可能是关着的
//!
//! 无障碍总线要 `org.a11y.Bus` 这个服务在跑，而且应用要在启动时
//! 打开了无障碍支持（GTK 看 `GTK_MODULES` / `gtk-enable-accessibility`，
//! Qt 看 `QT_ACCESSIBILITY`）。**没开的时候一个元素都扫不到** ——
//! 这时必须明说，而不是显示「这个窗口里没有可点的东西」让用户以为是自己的错。
//!
//! # 只扫**活动窗口**那一棵树
//!
//! 一开始这里遍历了所有程序的整棵树 —— 那既慢（每下一层都是一轮 DBus
//! 往返，几十个程序加起来要好几秒），又会给用户**根本看不见的窗口**
//! 打上标签。改成先按 AT-SPI 的 `ACTIVE` 状态找出活动窗口，只下探它。
//!
//! # 为什么不用 `AtspiAction` 去「按」它
//!
//! AT-SPI 有 `Action` 接口能直接触发按钮。但很多程序只实现了「报告」
//! 没实现「执行」，调了毫无反应且不报错。合成一次真实的鼠标点击对谁都成立。

use baobox_core::hints::Target;
use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::OwnedObjectPath;

/// 最多标多少个。与 Windows 侧同一个数。
pub const MAX_TARGETS: usize = 200;

/// 元素小于这个尺寸就不标 —— 多半是分隔线或者看不见的占位。
pub const MIN_SIZE: i32 = 6;

/// 递归下探的层数上限。
///
/// 界面树能很深（Electron 尤其），而每下一层都是一轮 DBus 往返 ——
/// 不设上限的话，一个复杂网页能让这次扫描跑上十几秒。
pub const MAX_DEPTH: usize = 12;

/// 视为「可点」的 AT-SPI role。
///
/// 数字是 AT-SPI 规范里的 role id。与 macOS 的 role 表、Windows 的
/// 控件类型表一一对应；同样**不收 text 与 panel** —— 收了的话
/// 一个网页能标出上千个标签，那时用键盘比用鼠标还慢。
pub const CLICKABLE_ROLES: [u32; 10] = [
    43, // push button
    44, // radio button
    22, // check box
    30, // link
    35, // menu item
    41, // page tab
    27, // list item
    62, // tree item
    24, // combo box
    71, // entry
];

/// 扫一遍当前活动窗口里可点的东西。
pub fn scan() -> Result<Vec<Target>, String> {
    let conn = accessibility_bus()?;
    let registry = Proxy::new(
        &conn,
        "org.a11y.atspi.Registry",
        "/org/a11y/atspi/accessible/root",
        "org.a11y.atspi.Accessible",
    )
    .map_err(|e| format!("连不上无障碍注册表：{e}"))?;

    let apps: Vec<(String, OwnedObjectPath)> = registry
        .call("GetChildren", &())
        .map_err(|e| format!("列不出正在运行的程序：{e}"))?;
    if apps.is_empty() {
        return Err(NOT_ENABLED.to_string());
    }

    // 只找活动窗口那一棵。遍历所有程序既慢（几十个程序 × 几十层
    // DBus 往返）又会给用户看不见的窗口打标签
    let Some((bus, path)) = active_window(&conn, &apps) else {
        return Err("没找到活动窗口（焦点可能在桌面上）".to_string());
    };
    let mut targets = Vec::new();
    collect(&conn, &bus, &path, 0, &mut targets);
    if targets.is_empty() {
        return Err(NOT_ENABLED.to_string());
    }
    Ok(targets)
}

/// AT-SPI 状态位：`ACTIVE`。
///
/// 状态集是一个 64 位位图，拆成两个 u32 传过来；`ACTIVE` 是第 1 位。
const STATE_ACTIVE: u32 = 1;

/// 在所有程序里找出那个**活动**窗口。
///
/// 逐个程序问它的顶层窗口，谁带 `ACTIVE` 就是它。找不到返回 `None` ——
/// 焦点在桌面上时确实没有活动窗口，那时该明说而不是随便挑一个。
fn active_window(
    conn: &Connection,
    apps: &[(String, OwnedObjectPath)],
) -> Option<(String, String)> {
    for (bus, path) in apps {
        let Ok(app) = Proxy::new(conn, bus.as_str(), path.as_str(), "org.a11y.atspi.Accessible") else {
            continue;
        };
        let Ok(windows) = app.call::<_, _, Vec<(String, OwnedObjectPath)>>("GetChildren", &())
        else {
            continue;
        };
        for (window_bus, window_path) in windows {
            let Ok(window) =
                Proxy::new(conn, window_bus.as_str(), window_path.as_str(), "org.a11y.atspi.Accessible")
            else {
                continue;
            };
            let Ok(states) = window.call::<_, _, Vec<u32>>("GetState", &()) else {
                continue;
            };
            if is_active(&states) {
                return Some((window_bus.clone(), window_path.as_str().to_string()));
            }
        }
    }
    None
}

/// 状态集里带 `ACTIVE` 吗。
///
/// 低 32 位在 `states[0]`。数组短了就是没有 —— 不能索引越界。
pub fn is_active(states: &[u32]) -> bool {
    states.first().map(|low| low & (1 << STATE_ACTIVE) != 0).unwrap_or(false)
}

/// 无障碍没开时说什么。
///
/// 必须明说，而不是显示「这个窗口里没有可点的东西」—— 后者会让用户
/// 以为是自己找错了地方，然后反复按快捷键。
pub const NOT_ENABLED: &str = "读不到界面元素。多半是无障碍支持没开：\
    试试 `gsettings set org.gnome.desktop.interface toolkit-accessibility true`，\
    或在环境里设 `GTK_MODULES=gail:atk-bridge` 与 `QT_ACCESSIBILITY=1` 之后重启目标程序。";

/// 连无障碍总线。
///
/// 它是一根**独立**的总线，地址要先向会话总线要。
fn accessibility_bus() -> Result<Connection, String> {
    let session = Connection::session().map_err(|e| format!("连不上会话总线：{e}"))?;
    let bus = Proxy::new(
        &session,
        "org.a11y.Bus",
        "/org/a11y/bus",
        "org.a11y.Bus",
    )
    .map_err(|e| format!("找不到无障碍总线服务：{e}"))?;
    let address: String = bus
        .call("GetAddress", &())
        .map_err(|_| NOT_ENABLED.to_string())?;
    zbus::blocking::connection::Builder::address(address.as_str())
        .and_then(|builder| builder.build())
        .map_err(|e| format!("连不上无障碍总线：{e}"))
}

/// 递归收一棵子树。
///
/// **读不到的分支直接跳过**：界面树是别人家程序在维护的，
/// 一个程序卡住不该让整次扫描失败。
fn collect(conn: &Connection, bus: &str, path: &str, depth: usize, out: &mut Vec<Target>) {
    if depth > MAX_DEPTH || out.len() >= MAX_TARGETS {
        return;
    }
    let Ok(node) = Proxy::new(conn, bus, path, "org.a11y.atspi.Accessible") else {
        return;
    };
    // 看不见的整棵子树都不用下探 —— 那是最省时间的一刀
    if let Some(role) = node.call::<_, _, u32>("GetRole", &()).ok() {
        if CLICKABLE_ROLES.contains(&role) {
            if let Some(target) = target_of(conn, bus, path) {
                out.push(target);
            }
        }
    }
    let Ok(children) = node.call::<_, _, Vec<(String, OwnedObjectPath)>>("GetChildren", &()) else {
        return;
    };
    for (child_bus, child_path) in children {
        if out.len() >= MAX_TARGETS {
            return;
        }
        collect(conn, &child_bus, child_path.as_str(), depth + 1, out);
    }
}

/// 一个元素标在哪。
fn target_of(conn: &Connection, bus: &str, path: &str) -> Option<Target> {
    let component = Proxy::new(conn, bus, path, "org.a11y.atspi.Component").ok()?;
    // 坐标类型 0 = 屏幕坐标；1 = 窗口坐标。要的是前者
    let extents: (i32, i32, i32, i32) = component.call("GetExtents", &(0u32)).ok()?;
    let (x, y, w, h) = extents;
    if w < MIN_SIZE || h < MIN_SIZE {
        return None;
    }
    let name = Proxy::new(conn, bus, path, "org.freedesktop.DBus.Properties")
        .ok()
        .and_then(|p| {
            p.call::<_, _, zbus::zvariant::OwnedValue>(
                "Get",
                &("org.a11y.atspi.Accessible", "Name"),
            )
            .ok()
        })
        .and_then(|v| String::try_from(v).ok())
        .unwrap_or_default();
    Some(Target {
        x: x as f64 + w as f64 / 2.0,
        y: y as f64 + h as f64 / 2.0,
        label: name,
    })
}

/// 在某个点上点一下（XTEST）。
///
/// 用合成的鼠标事件而不是 AT-SPI 的 `Action` 接口：很多程序只实现了
/// 「报告」没实现「执行」，调了毫无反应且不报错。
pub fn click(conn: &x11rb::rust_connection::RustConnection, root: u32, x: f64, y: f64) -> Result<(), String> {
    use x11rb::connection::Connection as _;
    use x11rb::protocol::xproto::ConnectionExt as _;
    use x11rb::protocol::xtest::ConnectionExt as _;

    conn.warp_pointer(x11rb::NONE, root, 0, 0, 0, 0, x.round() as i16, y.round() as i16)
        .map_err(|e| format!("挪不动指针：{e}"))?;
    // 4 = ButtonPress，5 = ButtonRelease；按钮 1 是左键
    conn.xtest_fake_input(4, 1, 0, x11rb::NONE, 0, 0, 0)
        .map_err(|e| format!("合成点击失败（XTEST 可用吗？）：{e}"))?;
    conn.xtest_fake_input(5, 1, 0, x11rb::NONE, 0, 0, 0)
        .map_err(|e| format!("合成点击失败：{e}"))?;
    conn.flush().map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_text_and_panels_are_not_clickable() {
        // 收了的话一个网页能标出上千个标签，那时用键盘比用鼠标还慢
        const TEXT: u32 = 60;
        const PANEL: u32 = 39;
        assert!(!CLICKABLE_ROLES.contains(&TEXT));
        assert!(!CLICKABLE_ROLES.contains(&PANEL));
        assert!(CLICKABLE_ROLES.contains(&43), "按钮必须算");
        assert!(CLICKABLE_ROLES.contains(&30), "链接必须算");
    }

    #[test]
    fn the_hint_tells_the_user_exactly_what_to_run() {
        // 「这个窗口里没有可点的东西」会让用户以为是自己找错了地方
        assert!(NOT_ENABLED.contains("无障碍"));
        assert!(NOT_ENABLED.contains("toolkit-accessibility"), "要给能照做的命令");
        assert!(NOT_ENABLED.contains("QT_ACCESSIBILITY"), "Qt 程序也要覆盖到");
    }

    #[test]
    fn the_active_state_bit_is_read_from_the_low_word() {
        // 状态集是 64 位拆成两个 u32；读错一半的话永远找不到活动窗口
        assert!(is_active(&[1 << STATE_ACTIVE, 0]));
        assert!(!is_active(&[0, 1 << STATE_ACTIVE]), "高位那半不是 ACTIVE");
        assert!(!is_active(&[0, 0]));
        // 数组短了就是没有，不能索引越界
        assert!(!is_active(&[]));
    }

    #[test]
    fn the_depth_limit_keeps_a_deep_tree_from_taking_forever() {
        // 每下一层都是一轮 DBus 往返，Electron 的树能有几十层
        assert!(MAX_DEPTH >= 8);
        assert!(MAX_DEPTH <= 20);
    }

}
