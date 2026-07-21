import AppKit
import SwiftUI

/// 二维码生成工具模块壳。纯本地生成（CIQRCodeGenerator），无需任何权限。
@MainActor
final class QRCodeTool: ToolModule {
    let id = "qrcode"
    let name = L("qrcode.name")
    let symbolName = "qrcode"

    private let panelController = QRCodePanelController()

    func submenuItems() -> [NSMenuItem] {
        [
            ClosureMenuItem(title: L("qrcode.menu.generate"), hotkeyID: "qrcode.generate") { [weak self] in
                self?.panelController.show()
            }
        ]
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "qrcode.generate",
                title: L("qrcode.menu.generate"),
                subtitle: L("qrcode.hotkey.subtitle"),
                defaultCombo: KeyCombo(keyCode: 0x0C, carbonModifiers: KeyCombo.control | KeyCombo.shift) // ⌃⇧Q
            ) { [weak self] in
                self?.panelController.show()
            }
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(QRCodeSettingsView())
    }

    func activate() {
        // 无后台服务；快捷键由框架统一注册。
    }
}

/// 二维码设置：目前仅用法说明（无可配置项）。
struct QRCodeSettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("qrcode.settings.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
