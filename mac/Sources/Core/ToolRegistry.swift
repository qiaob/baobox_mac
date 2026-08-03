import Foundation

@MainActor
final class ToolRegistry: ObservableObject {
    @Published private(set) var tools: [any ToolModule] = []

    func register(_ tool: any ToolModule) {
        guard !tools.contains(where: { $0.id == tool.id }) else { return }
        tools.append(tool)
    }

    func activateAll() {
        for tool in tools {
            for def in tool.hotkeys() {
                HotkeyCenter.shared.register(def)
            }
            tool.activate()
        }
    }

    func allHotkeys() -> [(tool: any ToolModule, defs: [HotkeyDefinition])] {
        tools.map { ($0, $0.hotkeys()) }
    }
}
