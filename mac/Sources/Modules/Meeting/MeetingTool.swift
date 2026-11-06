import AppKit
import SwiftUI

/// 会议模块壳（docs/meeting/）：菜单、快捷键、设置 Tab；会话在 MeetingSessionController，会议库在 MeetingStore。
/// 注册在实时翻译前面（菜单顺序 = 注册顺序），启动时先装好会议库，自由听译的新记录才写得进去。
@MainActor
final class MeetingTool: ToolModule {
    let id = "meeting"
    let name = L("meeting.name")
    let symbolName = "person.2.wave.2"

    func submenuItems() -> [NSMenuItem] {
        MeetingMenu.items(includeSettings: false)
    }

    /// 全部出厂不绑定（仓库惯例），在快捷键页或会议设置里自设。「开始自由听译」沿用实时翻译的 `livetranslate.toggle`。
    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(id: "meeting.startOnline", title: L("meeting.hotkey.startOnline"),
                             subtitle: L("meeting.hotkey.startOnlineHelp"), defaultCombo: nil) {
                MeetingMenu.toggleOnline()
            },
            HotkeyDefinition(id: "meeting.startOffline", title: L("meeting.hotkey.startOffline"),
                             subtitle: nil, defaultCombo: nil) {
                MeetingSessionController.shared.start(type: .offline)
            },
            HotkeyDefinition(id: "meeting.mark", title: L("meeting.hotkey.mark"),
                             subtitle: L("meeting.hotkey.markHelp"), defaultCombo: nil) {
                MeetingSessionController.shared.mark()
            },
            HotkeyDefinition(id: "meeting.notes", title: L("meeting.hotkey.notes"),
                             subtitle: nil, defaultCombo: nil) {
                MeetingSessionController.shared.toggleNotes()
            },
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(MeetingSettingsView())
    }

    func activate() {
        MeetingStore.shared.load()
        LiveTranslateController.recordLibrary = MeetingStore.shared
    }

    func willTerminate() {
        MeetingSessionController.shared.terminate()
    }
}

/// 会议菜单：Baobox 主菜单「会议」与记录中的菜单栏录音指示共用一份（只读内存，零磁盘 IO）。
enum MeetingMenu {
    @MainActor
    static func items(includeSettings: Bool) -> [NSMenuItem] {
        let session = MeetingSessionController.shared
        let engine = LiveTranslateController.shared
        var items: [NSMenuItem] = [
            NSMenuItem(title: session.statusLine(), action: nil, keyEquivalent: ""),
            .separator(),
        ]

        // 开始线上会议记录 / 结束并生成纪要（同一个位置，同一个快捷键）。
        switch session.phase {
        case .idle:
            items.append(ClosureMenuItem(title: L("meeting.menu.startOnline"), hotkeyID: "meeting.startOnline") {
                session.start(type: .online)
            })
            items.append(ClosureMenuItem(title: L("meeting.menu.startOffline"), hotkeyID: "meeting.startOffline") {
                session.start(type: .offline)
            })
        case .starting, .recording, .paused:
            items.append(ClosureMenuItem(title: L("meeting.menu.finish"), hotkeyID: "meeting.startOnline") {
                session.finish()
            })
            items.append(NSMenuItem(title: L("meeting.menu.startOffline"), action: nil, keyEquivalent: ""))
        case .finishing:
            items.append(NSMenuItem(title: L("meeting.statusLine.finishing"), action: nil, keyEquivalent: ""))
            items.append(NSMenuItem(title: L("meeting.menu.startOffline"), action: nil, keyEquivalent: ""))
        }

        // 开始自由听译（记录中 = 打开 / 收起字幕）。
        let freeTitle: String
        if session.isActive {
            freeTitle = session.subtitlesOn ? L("meeting.menu.subtitlesOff") : L("meeting.menu.subtitlesOn")
        } else {
            freeTitle = engine.isRunning ? L("meeting.menu.stopFree") : L("meeting.menu.startFree")
        }
        if session.phase == .finishing {
            items.append(NSMenuItem(title: freeTitle, action: nil, keyEquivalent: ""))
        } else {
            items.append(ClosureMenuItem(title: freeTitle, hotkeyID: "livetranslate.toggle") {
                session.startFreeListening()
            })
        }

        items.append(.separator())
        // 第一段的临时入口；第二段换成会议库窗口。
        items.append(ClosureMenuItem(title: L("meeting.menu.openLibrary")) {
            MeetingStore.shared.openInFinder()
        })

        // 录音指示的菜单是独立入口，自己补一个「设置…」（Baobox 主菜单里框架会自动追加）。
        if includeSettings {
            items.append(.separator())
            items.append(ClosureMenuItem(title: L("meeting.menu.settings")) {
                guard let registry = AppDelegate.shared?.registry else { return }
                SettingsWindowController.shared.show(registry: registry, tab: "meeting")
            })
        }
        return items
    }

    /// 「开始线上会议记录」快捷键：空闲时开始，记录中按一下结束并生成纪要。
    @MainActor
    static func toggleOnline() {
        let session = MeetingSessionController.shared
        if session.isActive {
            session.finish()
        } else {
            session.start(type: .online)
        }
    }
}
