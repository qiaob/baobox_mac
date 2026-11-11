import AppKit
import SwiftUI

/// 防休眠工具模块壳。主要是菜单操作；「开关防休眠」快捷键出厂不绑，桌面宠物的环形菜单也经它开关。
@MainActor
final class CaffeinateTool: ToolModule {
    let id = "caffeinate"
    let name = L("caffeinate.name")
    let symbolName = "cup.and.saucer"

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
        // 那个显眼的「默认时长」Picker 改了 100% 没有任何效果。本模块的快捷键出厂又不绑，
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
        // 出厂不绑键（不占组合键）；桌面宠物的环形菜单也经它开关防休眠。这两处都看不到二级菜单的状态行：
        // 开关后让宠物说一声，环形菜单开着时写「关闭防休眠」（2026-11-08 用户反馈点了没反应、标题也不变）。
        [
            HotkeyDefinition(
                id: "caffeinate.toggle",
                title: L("caffeinate.hotkey.toggle"),
                subtitle: nil,
                defaultCombo: nil,
                action: { [weak self] in self?.toggle(announce: true) },
                stateTitle: { CaffeinateController.shared.isActive ? L("caffeinate.action.stop") : nil }
            )
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(CaffeinateSettingsView())
    }

    func activate() {
        // 无需后台服务；断言按需创建。
    }

    // MARK: - 动作

    /// 按默认时长开 / 关：菜单「按默认时长开启」、快捷键、桌面宠物的环形菜单（设置页写的就是「菜单点击或快捷开启时的时长」；
    /// 快捷键以前一律无限期开）。`announce`：快捷键与环形菜单看不到状态行，开关后让宠物说一声。
    private func toggle(announce: Bool = false) {
        if controller.isActive {
            controller.stop()
            if announce { Self.toast(L("caffeinate.toast.off")) }
            return
        }
        let duration = CaffeinateSettings.defaultDuration
        controller.start(duration: duration)
        // 断言没建成：start 已经弹了错误框，不再说「已开启」。
        guard announce, controller.isActive else { return }
        if let duration {
            Self.toast(L("caffeinate.toast.onFor \(max(1, Int((duration / 60).rounded())))"))
        } else {
            Self.toast(L("caffeinate.toast.on"))
        }
    }

    /// 宠物说一句。是用户刚点的操作的回执：专注 / 安静这些勿扰时也照常显示。
    private static func toast(_ text: String) {
        NotifyCenter.shared.post(Notice(source: "caffeinate", level: .ambient, title: text,
                                        icon: "cup.and.saucer.fill", isUserFeedback: true))
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
