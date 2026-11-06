import AppKit
import SwiftUI

/// 桌面宠物工具模块壳：注册通知呈现端并启动宠物（设计见 docs/desktop-pet/DESIGN.md)。
@MainActor
final class DesktopPetTool: ToolModule {
    let id = "desktop-pet"
    let name = L("pet.name")
    let symbolName = "pawprint"

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        items.append(NSMenuItem(title: PetSettings.enabled ? L("pet.menu.statusOn") : L("pet.menu.statusOff"),
                                action: nil, keyEquivalent: ""))
        items.append(.separator())
        if PetSettings.enabled {
            items.append(ClosureMenuItem(title: L("pet.menu.hide")) {
                PetController.shared.setEnabled(false)
            })
        } else {
            items.append(ClosureMenuItem(title: L("pet.menu.show")) {
                PetController.shared.setEnabled(true)
            })
        }
        let quietItem = NSMenuItem(title: L("pet.menu.quiet"), action: nil, keyEquivalent: "")
        let quietMenu = NSMenu()
        quietMenu.addItem(ClosureMenuItem(title: L("pet.menu.quiet1h")) {
            PetController.shared.quietForOneHour()
        })
        quietMenu.addItem(ClosureMenuItem(title: L("pet.menu.quietToday")) {
            PetController.shared.quietForToday()
        })
        if PetSettings.quietUntil != nil {
            quietMenu.addItem(ClosureMenuItem(title: L("pet.menu.quietOff")) {
                PetController.shared.clearQuiet()
            })
        }
        quietItem.submenu = quietMenu
        items.append(quietItem)
        let testItem = NSMenuItem(title: L("pet.menu.test"), action: nil, keyEquivalent: "")
        let testMenu = NSMenu()
        testMenu.addItem(ClosureMenuItem(title: L("pet.menu.testToast")) { PetController.shared.sendTestNotification(.toast) })
        testMenu.addItem(ClosureMenuItem(title: L("pet.menu.testCard")) { PetController.shared.sendTestNotification(.card) })
        testMenu.addItem(ClosureMenuItem(title: L("pet.menu.testSticky")) { PetController.shared.sendTestNotification(.sticky) })
        testItem.submenu = testMenu
        items.append(testItem)
        return items
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "pet.toggle",
                title: L("pet.hotkey.toggle"),
                subtitle: nil,
                defaultCombo: nil
            ) {
                PetController.shared.toggleEnabled()
            }
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(PetSettingsView())
    }

    func activate() {
        NotifyCenter.shared.presenter = PetController.shared
        PetController.shared.start()
    }

    func willTerminate() {
        PetController.shared.stop()
    }
}
