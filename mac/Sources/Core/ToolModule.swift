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
    /// 二级菜单最后那项「<工具>设置…」点了做什么。nil（默认）= 打开设置窗口里这个工具的那一页；
    /// 有自己窗口、设置都在窗口里的工具（网络抓包）给一个动作，打开自己的窗口（docs/packet-capture/CONFIG-LAYOUT.md §3）。
    var settingsAction: (@MainActor () -> Void)? { get }
    /// 这个模块替框架承担的呈现角色，默认没有（目前只有桌面宠物交出通知呈现端、浮窗挂靠点与休息画面主角）。框架在调任何模块的 `activate()` 之前
    /// 收集一次、装进 `PresentationHub`，与注册顺序无关，之后不再收集。见 docs/notify-core/DESIGN.md §3.3。
    func presentationRoles() -> PresentationRoles
    /// 快速入口里能搜到、能执行的命令，默认没有：带参数的命令和没有快捷键的动作（有快捷键的动作快速入口自动收，
    /// 不用在这里重复；id 相同时这里的覆盖自动生成的那条）。见 docs/launcher/TECH_DESIGN.md §3.1。每次现建（文案跟着当前语言）。
    func launcherCommands() -> [LauncherCommand]
    /// 交给快速入口搜索的数据来源，默认没有（剪贴板历史、文本片段、会议、会话）。见 docs/launcher/TECH_DESIGN.md §3.2。
    func launcherSources() -> [any LauncherSearchable]
    /// 快速入口要自己扫的目录（Spotlight 不建索引的地方，绝对路径），默认没有。快速入口在后台遍历、只记文件名和路径在内存里；
    /// 不存在的目录由它在后台跳过，这里不用先查（零磁盘 IO）。见 docs/launcher/TECH_DESIGN.md §6.4「来源 B」。
    func launcherFileRoots() -> [String]
    /// 交给快速入口按名字搜的已知文件，默认没有（Claude Code 会话写过的文件）。只读内存；面板呼出时取一次。
    /// 见 docs/launcher/TECH_DESIGN.md §6.4「来源 C」。
    func launcherKnownFiles() -> [LauncherKnownFile]
    /// 快速入口空着的时候（呼出后还没打字）此刻值得提一句的动作，默认没有：正在专注 →「暂停专注」，防休眠开着 →「关闭防休眠」。
    /// 每次呼出调一次；只读内存、零磁盘 IO、不阻塞。命令 id 也是使用记录的键（`commands/<id>`），和对应的命令用同一个 id。
    /// 开关类快捷键动作可以直接用 `HotkeyDefinition.launcherStateCommand(symbolName:)`。见 docs/launcher/TECH_DESIGN.md §5.6。
    func launcherContextSuggestions() -> [LauncherCommand]
}

extension ToolModule {
    func willTerminate() {}
    func statusMenuHeaderItems() -> [NSMenuItem] { [] }
    func aiFeatures() -> [AIFeatureDefinition] { [] }
    func presentationRoles() -> PresentationRoles { PresentationRoles() }
    func launcherCommands() -> [LauncherCommand] { [] }
    func launcherSources() -> [any LauncherSearchable] { [] }
    func launcherFileRoots() -> [String] { [] }
    func launcherKnownFiles() -> [LauncherKnownFile] { [] }
    func launcherContextSuggestions() -> [LauncherCommand] { [] }
    var settingsAction: (@MainActor () -> Void)? { nil }
}
