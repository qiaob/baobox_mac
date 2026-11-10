import AppKit
import SwiftUI

/// 专注与健康模块壳（docs/focus-health/）：菜单、快捷键、设置 Tab；逻辑都在 FocusHealthController。
@MainActor
final class FocusHealthTool: ToolModule {
    let id = "focushealth"
    let name = L("focus.name")
    let symbolName = "figure.mind.and.body"

    func submenuItems() -> [NSMenuItem] {
        FocusHealthMenu.items(includeSettings: false)
    }

    /// 出厂不绑键（不占组合键）；桌面宠物的环形菜单经 focushealth.focus 开始 / 暂停专注。
    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "focushealth.focus",
                title: L("focus.hotkey.focus"),
                subtitle: L("focus.hotkey.focusHelp"),
                defaultCombo: nil,
                action: { FocusHealthController.shared.toggleFocus() },
                // 环形菜单的标题跟着 toggleFocus 走：专注中 = 暂停、暂停中 = 继续；空闲 / 休息中 = 开始，用环形菜单自己的「专注」。
                stateTitle: {
                    switch FocusHealthController.shared.session.phase {
                    case .focusing: return L("focus.menu.pause")
                    case .paused: return L("focus.menu.resume")
                    case .idle, .shortBreak, .longBreak: return nil
                    }
                }
            ),
            HotkeyDefinition(
                id: "focushealth.breakNow",
                title: L("focus.hotkey.breakNow"),
                subtitle: nil,
                defaultCombo: nil
            ) {
                FocusHealthController.shared.breakNow()
            },
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(FocusHealthSettingsView())
    }

    func activate() {
        FocusHealthController.shared.start()
    }

    func willTerminate() {
        FocusHealthController.shared.stop()
    }
}

/// 模块二级菜单与菜单栏倒计时项共用的一份菜单（只读内存，零磁盘 IO）。
enum FocusHealthMenu {
    @MainActor
    static func items(includeSettings: Bool) -> [NSMenuItem] {
        let controller = FocusHealthController.shared
        let session = controller.session
        // 状态行下面一行置灰的「今天专注 N 分钟」（docs/focus-health/HISTORY.md §3）：读内存里算好的统计。
        let today = FocusText.focusTotal(controller.historySummary.todaySeconds)
        var items: [NSMenuItem] = [
            NSMenuItem(title: controller.statusLine(), action: nil, keyEquivalent: ""),
            NSMenuItem(title: L("focus.menu.today \(today)"), action: nil, keyEquivalent: ""),
            .separator(),
        ]

        switch session.phase {
        case .idle:
            items.append(ClosureMenuItem(title: L("focus.menu.start \(FocusHealthSettings.defaultFocusMinutes)"),
                                         hotkeyID: "focushealth.focus") {
                controller.startFocus()
            })
            let more = NSMenuItem(title: L("focus.menu.startWith"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for minutes in [25, 50, 90] {
                submenu.addItem(ClosureMenuItem(title: L("focus.menu.minutes \(minutes)")) {
                    controller.startFocus(minutes: minutes)
                })
            }
            more.submenu = submenu
            items.append(more)
        case .focusing, .paused:
            if session.phase == .focusing {
                items.append(ClosureMenuItem(title: L("focus.menu.pause"), hotkeyID: "focushealth.focus") {
                    controller.pauseFocus()
                })
            } else {
                items.append(ClosureMenuItem(title: L("focus.menu.resume"), hotkeyID: "focushealth.focus") {
                    controller.resumeFocus()
                })
            }
            let end = NSMenuItem(title: L("focus.menu.endEarly"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(ClosureMenuItem(title: L("focus.menu.endDone")) {
                controller.endFocusEarly(countAsDone: true)
            })
            submenu.addItem(ClosureMenuItem(title: L("focus.menu.endDiscard")) {
                controller.endFocusEarly(countAsDone: false)
            })
            end.submenu = submenu
            items.append(end)
        case .shortBreak, .longBreak:
            items.append(ClosureMenuItem(title: L("focus.menu.nextRound")) {
                controller.startFocus()
            })
            items.append(ClosureMenuItem(title: L("focus.menu.endBreak")) {
                controller.endCycle()
            })
        }

        items.append(.separator())
        if session.phase == .idle, !controller.stage.isBusy {
            items.append(ClosureMenuItem(title: L("focus.menu.breakNow"), hotkeyID: "focushealth.breakNow") {
                controller.breakNow()
            })
        }
        if FocusHealthSettings.remindersEnabled {
            if controller.remindersPaused {
                items.append(ClosureMenuItem(title: L("focus.menu.resumeReminders")) {
                    controller.resumeReminders()
                })
            } else {
                let pause = NSMenuItem(title: L("focus.menu.pauseReminders"), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.addItem(ClosureMenuItem(title: L("focus.menu.pause1h")) {
                    controller.pauseReminders(for: 3600)
                })
                submenu.addItem(ClosureMenuItem(title: L("focus.menu.pauseToday")) {
                    controller.pauseRemindersForToday()
                })
                pause.submenu = submenu
                items.append(pause)
            }
        }

        // 菜单栏倒计时项是独立入口，自己补一个「设置…」（Baobox 主菜单里框架会自动追加）。
        if includeSettings {
            items.append(.separator())
            items.append(ClosureMenuItem(title: L("focus.menu.settings")) {
                guard let registry = AppDelegate.shared?.registry else { return }
                SettingsWindowController.shared.show(registry: registry, tab: "focushealth")
            })
        }
        return items
    }
}
