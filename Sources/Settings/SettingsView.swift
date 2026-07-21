import SwiftUI

/// 设置窗口当前选中的 Tab（供菜单栏点击"〈工具〉设置…"时定位）。
@MainActor
final class SettingsTabSelection: ObservableObject {
    static let shared = SettingsTabSelection()
    @Published var selectedTab: String = "general"
    private init() {}
}

/// 设置窗容器：通用 / 快捷键 / 每个工具一个 Tab / 关于。
struct SettingsView: View {
    @ObservedObject var registry: ToolRegistry
    @ObservedObject private var tabSelection = SettingsTabSelection.shared

    var body: some View {
        TabView(selection: $tabSelection.selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("settings.tab.general", systemImage: "gearshape") }
                .tag("general")

            HotkeySettingsView(registry: registry)
                .tabItem { Label("settings.tab.hotkeys", systemImage: "command") }
                .tag("hotkeys")

            // 遍历注册的工具，各生成一个设置 Tab。用 indices 避免对存在类型取 keyPath。
            ForEach(registry.tools.indices, id: \.self) { index in
                let tool = registry.tools[index]
                tool.settingsTab()
                    .tabItem { Label(tool.name, systemImage: tool.symbolName) }
                    .tag(tool.id)
            }

            AboutView()
                .tabItem { Label("settings.tab.about", systemImage: "info.circle") }
                .tag("about")
        }
        .frame(width: 640, height: 480)
    }
}
