//! 全局界面样式：向 mac 版看齐的 GTK CSS。
//!
//! 以前所有窗口都裸奔系统主题 —— 设置窗是左页签 + 白底平铺，
//! 跟 mac 版（侧边栏 + 分组卡片）不像同一个产品。这里集中一份 CSS：
//! 分组表单的灰底、白卡片、强调蓝选中、圆角输入框。
//!
//! 只此一份，进程内装一次。常驻进程与一次性的面板 / 输入框进程
//! 各自在 GTK 初始化后调用 [`install`]。

use gtk::prelude::*;
use std::sync::Once;

static ONCE: Once = Once::new();

/// 把样式装到默认屏幕上。重复调用无副作用。
pub fn install() {
    ONCE.call_once(|| {
        let provider = gtk::CssProvider::new();
        if let Err(error) = provider.load_from_data(CSS.as_bytes()) {
            // 样式装不上不该挡住功能，退回系统主题即可
            eprintln!("界面样式加载失败，继续用系统主题：{error}");
            return;
        }
        let Some(screen) = gtk::gdk::Screen::default() else {
            return;
        };
        gtk::StyleContext::add_provider_for_screen(
            &screen,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    });
}

/// mac 版设置窗的视觉常量，翻译成 GTK 认的规则：
///
/// - 窗口与详情区底色 #ECECEC（分组表单的经典灰）
/// - 侧边栏 200 宽、浅灰底，选中行是强调蓝圆角胶囊、白字
/// - 字段收进白色圆角卡片（半径 10、发丝边框），行间发丝分隔线
/// - 页标题 20 号粗体；说明文字 11 号灰
/// - 输入框 / 按钮圆角 6，聚焦时强调蓝描边
const CSS: &str = "
window.baobox-settings,
window.baobox-panel {
    background-color: #ececec;
}

.baobox-sidebar {
    background-color: #e4e4e4;
    border-right: 1px solid #d0d0d0;
}
.baobox-sidebar row {
    padding: 6px 10px;
    margin: 1px 8px;
    border-radius: 6px;
}
.baobox-sidebar row:selected {
    background-color: #0a84ff;
    color: #ffffff;
    font-weight: bold;
}
.baobox-sidebar row:hover:not(:selected) {
    background-color: rgba(0, 0, 0, 0.05);
}

.baobox-detail {
    background-color: #ececec;
}
.baobox-page-title {
    font-size: 20px;
    font-weight: bold;
    margin-bottom: 12px;
}

.baobox-card {
    background-color: #ffffff;
    border: 1px solid #d4d4d4;
    border-radius: 10px;
}
.baobox-row {
    padding: 9px 14px;
}
.baobox-card separator {
    background-color: #e6e6e6;
    min-height: 1px;
    margin-left: 14px;
    margin-right: 14px;
}

.baobox-hint {
    color: #7a7a7a;
    font-size: 11px;
}

entry, spinbutton {
    border-radius: 6px;
}
entry:focus, spinbutton:focus {
    border-color: #0a84ff;
    box-shadow: 0 0 0 3px rgba(10, 132, 255, 0.3);
}
button {
    border-radius: 6px;
}

list.baobox-panel-list {
    background-color: #ffffff;
}
list.baobox-panel-list row {
    padding: 8px 10px;
}
list.baobox-panel-list row:selected {
    background-color: #0a84ff;
    color: #ffffff;
}

scrollbar {
    min-width: 10px;
    min-height: 10px;
}
scrollbar slider {
    border-radius: 5px;
    background-color: #c1c1c1;
}
";
