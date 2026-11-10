import AppKit
import SwiftUI

/// 桌面宠物工具模块壳：交出通知呈现端、浮窗挂靠点与休息画面主角（框架在启动时接上，docs/notify-core/DESIGN.md §3.3）
/// 并启动宠物（设计见 docs/desktop-pet/DESIGN.md）。
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
        if NotifySettings.quietUntil != nil {
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

    /// 宠物替框架呈现通知：开着 → 气泡；关着（isReady 为假）→ 通知内核走系统通知。
    /// 也当浮窗挂靠点：会议控制条挂在宠物头顶；宠物关着、借给休息画面、出场退场途中挂不上，控制条自己摆。
    /// 也当休息画面的主角：走到屏幕中央变大陪你休息；宠物关着、没就绪、正在换形象时借不到，休息画面走回退画面。
    func presentationRoles() -> PresentationRoles {
        PresentationRoles(notifications: PetController.shared, accessories: PetController.shared,
                          breakCompanion: PetController.shared)
    }

    func activate() {
        // 宠物关着启动：通知会走系统通知，先把权限问好。
        NotifyCenter.shared.prepareSystemFallback(requestPermission: !PetSettings.enabled)
        PetController.shared.start()
    }

    func willTerminate() {
        PetController.shared.stop()
    }
}
