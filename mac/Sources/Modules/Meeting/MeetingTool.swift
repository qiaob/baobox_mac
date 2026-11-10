import AppKit
import SwiftUI

extension AIFeature {
    /// 会议纪要（会后自动生成、会议库里重新生成）用哪个模型；出厂本地（docs/ai-service/DESIGN.md §3.3、§5.4）。
    static let meetingMinutes = AIFeature(id: "meeting.minutes", kind: .generation)
    /// 周报概述用哪个模型；出厂本地。
    static let meetingWeekly = AIFeature(id: "meeting.weekly", kind: .generation)
}

extension AIFeatureDefinition {
    static var meetingMinutes: AIFeatureDefinition {
        // 会后才写，慢几秒没关系：建议跑得动的最大的。
        AIFeatureDefinition(feature: .meetingMinutes, title: L("meeting.ai.minutes"), sends: L("meeting.ai.minutesSends"),
                            advice: .best, shortTitle: L("meeting.ai.minutesShort"))
    }

    static var meetingWeekly: AIFeatureDefinition {
        AIFeatureDefinition(feature: .meetingWeekly, title: L("meeting.ai.weekly"), sends: L("meeting.ai.weeklySends"),
                            advice: .best, shortTitle: L("meeting.ai.weeklyShort"))
    }
}

/// 会议模块壳（docs/meeting/）：菜单、快捷键、设置 Tab；会话在 MeetingSessionController，会议库在 MeetingStore，
/// 日历 / 提醒 / 检测在 MeetingCalendar / MeetingReminder / MeetingDetector，窗口在 MeetingWindowController。
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
            HotkeyDefinition(id: "meeting.join", title: L("meeting.hotkey.join"),
                             subtitle: L("meeting.hotkey.joinHelp"), defaultCombo: nil) {
                MeetingActions.joinNext()
            },
            HotkeyDefinition(id: "meeting.startOnline", title: L("meeting.hotkey.startOnline"),
                             subtitle: L("meeting.hotkey.startOnlineHelp"), defaultCombo: nil,
                             action: { MeetingMenu.toggleOnline() },
                             // 环形菜单的标题跟着开关走：记录中 = 结束；正在收尾时再点也没用，写明在结束。
                             stateTitle: {
                                 switch MeetingSessionController.shared.phase {
                                 case .idle: return nil
                                 case .starting, .recording, .paused: return L("meeting.action.finish")
                                 case .finishing: return L("meeting.statusLine.finishing")
                                 }
                             }),
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
            // 字幕与同传的开关：独立入口删掉以后（#106）由会议声明，id 不变，已绑的键照常生效；环形菜单的「翻译」也认它。
            HotkeyDefinition(
                id: "livetranslate.toggle",
                title: L("livetranslate.hotkey.toggle"),
                subtitle: L("livetranslate.hotkey.toggle.subtitle"),
                // 易冲突组合出厂不绑定（仓库惯例），在快捷键页自设。
                defaultCombo: nil,
                action: { LiveTranslateController.shared.toggle() },
                // 环形菜单的标题跟着开关走（与二级菜单同一套判断）；没开着时用环形菜单自己的「翻译」。
                stateTitle: {
                    let controller = LiveTranslateController.shared
                    if controller.isHostedSession {
                        return controller.barVisible ? L("meeting.menu.subtitlesOff") : L("meeting.menu.subtitlesOn")
                    }
                    return controller.isRunning ? L("livetranslate.action.stop") : nil
                }
            ),
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(MeetingSettingsView())
    }

    /// 字幕与同传的翻译和纠错也由会议声明：字幕与同传的设置区块嵌在会议页里，下个版本那个入口就并进会议（docs/ai-service/DESIGN.md §3.3）。
    func aiFeatures() -> [AIFeatureDefinition] {
        [.liveTranslate, .liveCorrection, .meetingMinutes, .meetingWeekly]
    }

    func activate() {
        MeetingStore.shared.load()
        LiveTranslateController.recordLibrary = MeetingStore.shared
        // 日历只在设置里打开过才读（没打开不碰 EventKit、不弹权限框）；提醒、检测只读内存里的缓存与系统状态。
        MeetingCalendar.shared.start()
        MeetingReminder.shared.start()
        MeetingDetector.shared.start()
    }

    func willTerminate() {
        MeetingDetector.shared.stop()
        MeetingReminder.shared.stop()
        MeetingCalendar.shared.stop()
        MeetingDeviceTest.shared.cancel()
        MeetingSessionController.shared.terminate()
        // 不在会议里的自由听译也要收尾（停音源、写完记录）：以前由独立的「字幕与同传」入口做（#106）。
        // 会议进行中上面已经调过一次，再调是空操作。推理进程由 AppDelegate 的 OfflineTranslator.shutdownAll() 统一结束。
        LiveTranslateController.shared.terminate()
    }
}

/// 会议菜单（需求 §5）：Baobox 主菜单「会议」与菜单栏的录音指示 / 倒计时共用一份（只读内存，零磁盘 IO）。
enum MeetingMenu {
    @MainActor
    static func items(includeSettings: Bool) -> [NSMenuItem] {
        let session = MeetingSessionController.shared
        let engine = LiveTranslateController.shared
        let next = MeetingCalendar.shared.next()
        var items: [NSMenuItem] = [
            NSMenuItem(title: session.statusLine(), action: nil, keyEquivalent: ""),
            .separator(),
        ]

        // 加入下一场会议（没有链接置灰）。
        if let next, next.link != nil {
            items.append(ClosureMenuItem(title: L("meeting.menu.joinNext"), hotkeyID: "meeting.join") {
                MeetingActions.join(next)
            })
        } else {
            items.append(NSMenuItem(title: L("meeting.menu.joinNext"), action: nil, keyEquivalent: ""))
        }

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

        // 开始自由听译（记录中 = 打开 / 收起字幕），显示 `livetranslate.toggle` 的键位。
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
        // 会前简报（下一场没有简报置灰）。
        if let next, !MeetingActions.briefing(for: next).isEmpty {
            items.append(ClosureMenuItem(title: L("meeting.menu.brief")) {
                MeetingWindowController.shared.showBrief(for: next)
            })
        } else {
            items.append(NSMenuItem(title: L("meeting.menu.brief"), action: nil, keyEquivalent: ""))
        }
        items.append(ClosureMenuItem(title: L("meeting.menu.library")) {
            MeetingWindowController.shared.showLibrary()
        })
        let open = MeetingStore.shared.openActionItemCount
        items.append(ClosureMenuItem(title: open > 0 ? L("meeting.menu.actionItemsCount \(open)")
                                                     : L("meeting.menu.actionItems")) {
            MeetingWindowController.shared.showActionItems()
        })
        items.append(ClosureMenuItem(title: L("meeting.menu.weekly")) {
            MeetingWeeklyReporter.shared.generate()
        })
        items.append(pauseItem())

        // 菜单栏项（录音指示 / 倒计时）的菜单是独立入口，自己补一个「设置…」（Baobox 主菜单里框架会自动追加）。
        if includeSettings {
            items.append(.separator())
            items.append(ClosureMenuItem(title: L("meeting.menu.settings")) {
                guard let registry = AppDelegate.shared?.registry else { return }
                SettingsWindowController.shared.show(registry: registry, tab: "meeting")
            })
        }
        return items
    }

    /// 暂停会议提醒 ▸ 1 小时 / 今天 / 直到明天；暂停中换成「恢复会议提醒（暂停到 …）」。
    @MainActor
    private static func pauseItem() -> NSMenuItem {
        let reminder = MeetingReminder.shared
        if reminder.isPaused(), let until = reminder.pausedUntil {
            return ClosureMenuItem(title: L("meeting.menu.resumeReminders \(MeetingText.untilTime(until))")) {
                reminder.resume()
            }
        }
        let item = NSMenuItem(title: L("meeting.menu.pauseReminders"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = true
        let choices: [(MeetingSchedule.Pause, String, String)] = [
            (.hour, L("meeting.menu.pauseHour"), L("meeting.menu.pauseHourHelp")),
            (.today, L("meeting.menu.pauseToday"), L("meeting.menu.pauseTodayHelp")),
            (.untilTomorrow, L("meeting.menu.pauseTomorrow"), L("meeting.menu.pauseTomorrowHelp")),
        ]
        for (pause, title, help) in choices {
            let choice = ClosureMenuItem(title: title) {
                reminder.pause(pause)
            }
            choice.toolTip = help
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
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

/// 日历会议上的动作：菜单、提醒 / 检测气泡、会前简报共用。
@MainActor
enum MeetingActions {
    /// 会前简报的内容（同系列上一场 + 该系列未完成行动项）；正在记录的那场不算「上一场」。
    static func briefing(for event: MeetingCalendarEvent) -> MeetingBriefing {
        MeetingBriefing.make(seriesKey: event.info.seriesKey, title: event.info.title, start: event.info.start,
                             records: MeetingStore.shared.records, excluding: MeetingSessionController.shared.meetingID)
    }

    /// 提醒 / 检测气泡上的按钮。
    static func handle(_ action: String, event: MeetingCalendarEvent) {
        switch action {
        case "joinRecord": joinAndRecord(event)
        case "join": join(event)
        case "record": record(event)
        case "brief": MeetingWindowController.shared.showBrief(for: event)
        case "ignore": MeetingPromptBook.shared.markIgnored(event)
        default: break
        }
    }

    /// 菜单「加入下一场会议」、快捷键：打开下一场的会议链接。
    static func joinNext() {
        let calendar = MeetingCalendar.shared
        guard calendar.isActive else {
            toast(L("meeting.toast.calendarOff"))
            return
        }
        guard let next = calendar.next() else {
            toast(L("meeting.toast.noNextMeeting"))
            return
        }
        guard next.link != nil else {
            toast(L("meeting.toast.noLink \(next.info.title)"))
            return
        }
        join(next)
    }

    /// 打开会议链接（Zoom / 腾讯会议…的 App，或浏览器）。
    static func join(_ event: MeetingCalendarEvent) {
        guard let url = event.link?.url else {
            toast(L("meeting.toast.noLink \(event.info.title)"))
            return
        }
        if !NSWorkspace.shared.open(url) {
            toast(L("meeting.toast.cannotOpenLink"))
        }
    }

    /// [加入并记录]：打开链接，开始线上会议记录（绑这一场）。已经在记这一场就只入会。
    static func joinAndRecord(_ event: MeetingCalendarEvent) {
        join(event)
        let session = MeetingSessionController.shared
        if session.isActive, let current = session.event, current.eventID == event.info.eventID,
           current.start == event.info.start {
            return
        }
        session.start(type: .online, event: event.info)
    }

    /// [开始记录]：有链接按线上会议，否则按设置里的默认类型（会议室里开的多半是线下）。
    static func record(_ event: MeetingCalendarEvent) {
        let session = MeetingSessionController.shared
        if event.link != nil {
            session.start(type: .online, event: event.info)
        } else {
            session.startDefault(event: event.info)
        }
    }

    private static func toast(_ text: String) {
        NotifyCenter.shared.post(PetNotification(source: MeetingSessionController.source, level: .ambient, title: text,
                                                 icon: "calendar"))
    }
}
