import SwiftUI

/// 设置窗口当前选中的 Tab（供菜单栏点击"〈工具〉设置…"时定位）。
@MainActor
final class SettingsTabSelection: ObservableObject {
    static let shared = SettingsTabSelection()
    @Published var selectedTab: String = "general"
    private init() {}
}

/// 设置窗容器:左侧边栏(通用 / 快捷键 / 各工具 / 关于) + 右详情。
/// 原横向 TabView 在工具增多后放不下,侧边栏可随工具数量线性扩展。
struct SettingsView: View {
    @ObservedObject var registry: ToolRegistry
    @ObservedObject private var tabSelection = SettingsTabSelection.shared

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let symbol: String
    }

    private var entries: [Entry] {
        var list = [
            Entry(id: "general", title: L("settings.tab.general"), symbol: "gearshape"),
            Entry(id: "hotkeys", title: L("settings.tab.hotkeys"), symbol: "command"),
        ]
        list += registry.tools.map { Entry(id: $0.id, title: $0.name, symbol: $0.symbolName) }
        list.append(Entry(id: "about", title: L("settings.tab.about"), symbol: "info.circle"))
        return list
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $tabSelection.selectedTab) {
                ForEach(entries) { entry in
                    Label {
                        Text(verbatim: entry.title)
                    } icon: {
                        Image(systemName: entry.symbol)
                    }
                    .tag(entry.id)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 860, height: 560)
    }

    @ViewBuilder
    private var detail: some View {
        switch tabSelection.selectedTab {
        case "general":
            GeneralSettingsView()
        case "hotkeys":
            HotkeySettingsView(registry: registry)
        case "about":
            AboutView()
        default:
            // 工具设置页。切换时用 id 强制重建,避免不同工具的 @State 串台。
            if let index = registry.tools.indices.first(where: { registry.tools[$0].id == tabSelection.selectedTab }) {
                registry.tools[index].settingsTab()
                    .id(tabSelection.selectedTab)
            } else {
                GeneralSettingsView()
            }
        }
    }
}
