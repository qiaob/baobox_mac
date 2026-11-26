import AppKit
import SwiftUI

/// 网络工具组合模块壳：将「网络检测（IP 检测 / 测速 / 诊断 / 端口）」与「网络抓包」收拢为一个一级菜单与设置 Tab。
/// 保留各自独立窗口与底层模块边界；所有既有设置键（`netcheck.*`、`netcapture.*`）、快捷键 id 与快速入口命令 id 不变。
@MainActor
final class NetworkToolsModule: ToolModule {
    let id = "network"
    let name = L("network.tools.name")
    let symbolName = "network"

    private let netCheck = NetCheckTool()
    private let netCapture = NetCaptureTool()

    func submenuItems() -> [NSMenuItem] {
        var items = netCheck.submenuItems()
        let captureItems = netCapture.submenuItems()
        if !captureItems.isEmpty {
            items.append(.separator())
            items.append(contentsOf: captureItems)
        }
        return items
    }

    func hotkeys() -> [HotkeyDefinition] {
        netCheck.hotkeys() + netCapture.hotkeys()
    }

    func settingsTab() -> AnyView {
        AnyView(NetworkToolsSettingsView())
    }

    func activate() {
        netCheck.activate()
        netCapture.activate()
    }

    func willTerminate() {
        netCheck.willTerminate()
        netCapture.willTerminate()
    }

    func statusMenuHeaderItems() -> [NSMenuItem] {
        netCheck.statusMenuHeaderItems() + netCapture.statusMenuHeaderItems()
    }

    func aiFeatures() -> [AIFeatureDefinition] {
        netCheck.aiFeatures() + netCapture.aiFeatures()
    }

    func launcherCommands() -> [LauncherCommand] {
        netCheck.launcherCommands() + netCapture.launcherCommands()
    }

    func launcherSources() -> [any LauncherSearchable] {
        netCheck.launcherSources() + netCapture.launcherSources()
    }

    func launcherFileRoots() -> [String] {
        netCheck.launcherFileRoots() + netCapture.launcherFileRoots()
    }

    func launcherKnownFiles() -> [LauncherKnownFile] {
        netCheck.launcherKnownFiles() + netCapture.launcherKnownFiles()
    }

    func launcherContextSuggestions() -> [LauncherCommand] {
        netCheck.launcherContextSuggestions() + netCapture.launcherContextSuggestions()
    }
}

/// 网络工具设置页：顶部分段切换「网络检测」与「网络抓包」。
struct NetworkToolsSettingsView: View {
    private enum Pane: Hashable {
        case check, capture
    }

    @State private var pane: Pane = .check

    var body: some View {
        VStack(spacing: 0) {
            Picker(selection: $pane) {
                Text("netcheck.name").tag(Pane.check)
                Text("netcapture.name").tag(Pane.capture)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 12)
            .padding(.bottom, 6)

            Divider()

            switch pane {
            case .check:
                NetCheckSettingsView()
            case .capture:
                NetCaptureSettingsView()
            }
        }
    }
}
