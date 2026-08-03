import AppKit
import SwiftUI

/// 全局快捷键定义：由工具模块声明，快捷键中心统一注册与持久化。
struct HotkeyDefinition {
    /// 稳定标识，用作 UserDefaults 持久化键，如 "screenshot.capture"
    let id: String
    let title: String
    /// 设置页里显示的行为说明小字
    let subtitle: String?
    /// nil = 出厂不绑定（易冲突的组合出厂留空，由用户在快捷键页自行设置）。
    let defaultCombo: KeyCombo?
    let action: @MainActor () -> Void
}

/// 工具模块协议：新增工具只需实现本协议并在 AppDelegate 中注册，
/// 菜单栏一行入口、二级菜单、设置 Tab、快捷键均由框架自动生成。
@MainActor
protocol ToolModule: AnyObject {
    var id: String { get }
    var name: String { get }
    /// SF Symbol 名，用于菜单栏与设置侧栏图标
    var symbolName: String { get }

    /// 二级菜单内容（不含"设置…"，框架自动追加）。
    ///
    /// 需要在菜单项右侧展示快捷键的，用 `ClosureMenuItem(title:hotkeyID:)` 声明关联的
    /// 快捷键 id 即可，框架会在构建菜单时填入当前键位。注意快捷键**不能**挂在工具主行上：
    /// AppKit 对带 submenu 的菜单项既不渲染 keyEquivalent、也不发送 action。
    func submenuItems() -> [NSMenuItem]
    func hotkeys() -> [HotkeyDefinition]
    func settingsTab() -> AnyView
    /// App 启动时调用：启动后台服务、注册快捷键等
    func activate()
    /// App 退出前调用：刷新未落盘数据、释放系统资源等
    func willTerminate()
}

extension ToolModule {
    func willTerminate() {}
}
