import AppKit
import SwiftUI

/// 防休眠工具模块壳。纯菜单操作，无全局快捷键。
@MainActor
final class CaffeinateTool: ToolModule {
    let id = "caffeinate"
    let name = L("caffeinate.name")
    let symbolName = "cup.and.saucer"
    /// 无快捷键。

    private var controller: CaffeinateController { CaffeinateController.shared }

    /// 预设时长（秒）。
    private static let presets: [(title: String, duration: TimeInterval?)] = [
        (L("caffeinate.preset.15m"), 15 * 60),
        (L("caffeinate.preset.1h"), 60 * 60),
        (L("caffeinate.preset.2h"), 2 * 60 * 60),
        (L("caffeinate.preset.infinite"), nil)
    ]

    /// 退出时释放电源管理断言，避免系统被 Baobox 永久保持唤醒。
    func willTerminate() {
        controller.stop()
    }

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        // 状态行（disabled，action 为 nil 即自动置灰）。
        items.append(NSMenuItem(title: statusText(), action: nil, keyEquivalent: ""))
        items.append(.separator())

        // 「默认时长」的唯一可达入口。此前它只挂在 performDefaultAction 上，而 AppKit
        // 对带 submenu 的菜单主行从不发送 action —— 该方法全项目零调用点，导致设置页
        // 那个显眼的「默认时长」Picker 改了 100% 没有任何效果。本模块又没有快捷键，
        // 所以必须在菜单里给出入口。
        if !controller.isActive {
            items.append(ClosureMenuItem(title: L("caffeinate.menu.startDefault")) { [weak self] in
                self?.toggle()
            })
            items.append(.separator())
        }

        for preset in Self.presets {
            let item = ClosureMenuItem(title: preset.title) { [weak self] in
                self?.controller.start(duration: preset.duration)
            }
            item.state = isCurrentSelection(preset.duration) ? .on : .off
            items.append(item)
        }

        items.append(.separator())

        if controller.isActive {
            items.append(ClosureMenuItem(title: L("caffeinate.menu.stop")) { [weak self] in
                self?.controller.stop()
            })
        } else {
            // 未激活 → 置灰。
            items.append(NSMenuItem(title: L("caffeinate.menu.stop"), action: nil, keyEquivalent: ""))
        }

        return items
    }

    func hotkeys() -> [HotkeyDefinition] {
        [] // 纯菜单操作，不占用组合键。
    }

    func settingsTab() -> AnyView {
        AnyView(CaffeinateSettingsView())
    }

    func activate() {
        // 无需后台服务；断言按需创建。
    }

    // MARK: - 动作

    private func toggle() {
        if controller.isActive {
            controller.stop()
        } else {
            controller.start(duration: CaffeinateSettings.defaultDuration)
        }
    }

    // MARK: - 展示

    private func statusText() -> String {
        guard controller.isActive else { return L("caffeinate.status.off") }
        if controller.until == nil {
            return L("caffeinate.status.infinite")
        }
        let minutes = controller.remainingMinutes ?? 0
        return L("caffeinate.status.remaining \(minutes)")
    }

    /// 判断某预设是否为当前生效项（用于菜单勾选）。
    private func isCurrentSelection(_ duration: TimeInterval?) -> Bool {
        guard controller.isActive else { return false }
        switch (duration, controller.requestedDuration) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs == rhs
        default:
            return false
        }
    }
}
