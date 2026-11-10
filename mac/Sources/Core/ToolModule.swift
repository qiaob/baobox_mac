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
    /// 按下时调用（每按一次只调一次）。
    let action: @MainActor () -> Void
    /// 松开时调用；nil = 不关心松开（绝大多数快捷键）。「按住说话」= `action` 开始 + `onRelease` 结束，
    /// 见 docs/dictation/TECH_DESIGN.md §1。
    var onRelease: (@MainActor () -> Void)? = nil
    /// 开关类动作此刻按下去会做什么（「关闭防休眠」「暂停专注」）。桌面宠物的环形菜单拿它当按钮标题 ——
    /// 那里看不到二级菜单里随状态变的那一行。要短（按钮下的小标签）；nil / 返回 nil = 用环形菜单自己的标题。
    var stateTitle: (@MainActor () -> String?)? = nil
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
    /// 放在 Baobox 主菜单最上面的行（工具列表之前，框架另接一条分隔线），默认没有。
    /// 菜单栏管理用它放「被隐藏 / 被挤掉的图标」那一行（docs/menubar-manager/）。和 submenuItems 一样只读内存缓存。
    func statusMenuHeaderItems() -> [NSMenuItem]
    /// 用到模型的功能，默认没有。设置的「AI」页按工具分组列出、每个功能选一个模型（同 `hotkeys()` 之于快捷键页），
    /// 见 docs/ai-service/DESIGN.md §3.3。每次现建（文案跟着当前语言）。
    func aiFeatures() -> [AIFeatureDefinition]
    /// 这个模块替框架承担的呈现角色，默认没有（目前只有桌面宠物交出通知呈现端）。框架在调任何模块的 `activate()` 之前
    /// 收集一次、装进 `PresentationHub`，与注册顺序无关，之后不再收集。见 docs/notify-core/DESIGN.md §3.3。
    func presentationRoles() -> PresentationRoles
}

extension ToolModule {
    func willTerminate() {}
    func statusMenuHeaderItems() -> [NSMenuItem] { [] }
    func aiFeatures() -> [AIFeatureDefinition] { [] }
    func presentationRoles() -> PresentationRoles { PresentationRoles() }
}
