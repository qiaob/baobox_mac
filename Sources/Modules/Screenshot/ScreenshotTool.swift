import AppKit
import SwiftUI

/// 截图工具模块壳。
@MainActor
final class ScreenshotTool: ToolModule {
    let id = "screenshot"
    let name = L("screenshot.name")
    let symbolName = "viewfinder"

    private let captureController = CaptureController()

    func submenuItems() -> [NSMenuItem] {
        let start = ClosureMenuItem(title: L("screenshot.menu.start"), hotkeyID: "screenshot.capture") { [weak self] in
            self?.captureController.begin()
        }
        // M2 占位（action 为 nil → 自动置灰）
        let history = NSMenuItem(title: L("screenshot.menu.history"), action: nil, keyEquivalent: "")
        history.toolTip = "M2"
        let pin = NSMenuItem(title: L("screenshot.menu.pins"), action: nil, keyEquivalent: "")
        pin.toolTip = "M2"
        return [start, history, pin]
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "screenshot.capture",
                title: L("screenshot.hotkey.title"),
                subtitle: L("screenshot.hotkey.subtitle"),
                defaultCombo: KeyCombo(keyCode: 0x13, carbonModifiers: KeyCombo.cmd | KeyCombo.shift) // ⌘⇧2
            ) { [weak self] in
                self?.captureController.begin()
            }
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(ScreenshotSettingsView())
    }

    func activate() {
        // 截图无需常驻后台服务；快捷键由框架统一注册。
    }
}
