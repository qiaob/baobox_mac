import Foundation

@MainActor
final class ToolRegistry: ObservableObject {
    @Published private(set) var tools: [any ToolModule] = []

    func register(_ tool: any ToolModule) {
        guard !tools.contains(where: { $0.id == tool.id }) else { return }
        tools.append(tool)
    }

    func activateAll() {
        // 启动期间投递的通知先攒着，全部 activate() 跑完再按顺序发：呈现端（宠物）下一行就装好，
        // 但要等它自己的 activate() 里 start() 之后才就绪（docs/notify-core/DESIGN.md §3.3）。
        NotifyCenter.shared.holdDuringLaunch()
        // 呈现角色在任何模块 activate() 之前装一次，之后只读，与注册顺序无关。
        PresentationHub.shared.install(from: tools)
        for tool in tools {
            for def in tool.hotkeys() {
                HotkeyCenter.shared.register(def)
            }
            tool.activate()
        }
        NotifyCenter.shared.releaseAfterLaunch()
    }

    func allHotkeys() -> [(tool: any ToolModule, defs: [HotkeyDefinition])] {
        tools.map { ($0, $0.hotkeys()) }
    }
}
