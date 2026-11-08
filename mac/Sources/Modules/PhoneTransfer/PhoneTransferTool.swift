import AppKit
import SwiftUI

/// 手机互传模块壳：菜单入口、快捷键、设置 Tab。会话随窗口开关，不常驻后台服务。
/// 见 docs/phone-transfer/。
@MainActor
final class PhoneTransferTool: ToolModule {
    let id = "phonetransfer"
    let name = L("phonetransfer.name")
    let symbolName = "iphone.and.arrow.forward"

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let session = PhoneTransferSession.shared
        if session.isRunning, !session.devices.isEmpty {
            items.append(NSMenuItem(title: L("phonetransfer.menu.connected \(session.devices.count)"),
                                    action: nil, keyEquivalent: ""))
            items.append(.separator())
        }
        items.append(ClosureMenuItem(title: L("phonetransfer.menu.open"), hotkeyID: "phonetransfer.open") {
            PhoneTransferWindowController.shared.show()
        })
        items.append(ClosureMenuItem(title: L("phonetransfer.menu.openFolder")) {
            let dir = PhoneTransferSettings.receiveDir
            if PhoneTransferSettings.ensureDirectory(dir) { NSWorkspace.shared.open(dir) }
        })
        return items
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "phonetransfer.open",
                title: L("phonetransfer.hotkey.open"),
                subtitle: nil,
                defaultCombo: nil
            ) {
                PhoneTransferWindowController.shared.show()
            }
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(PhoneTransferSettingsView())
    }

    func activate() {
        // 无后台服务：会话在打开窗口时才启动。
    }

    func willTerminate() {
        PhoneTransferSession.shared.stop()
    }
}
