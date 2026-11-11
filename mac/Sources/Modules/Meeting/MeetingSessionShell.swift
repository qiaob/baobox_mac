import AppKit

/// 会话的 App 外壳（docs/meeting/ENGINE.md §5.2）：`MeetingSessionController`（纯逻辑，Meeting/Logic/）碰到的 App 侧的东西都在这里 ——
/// 控制条、菜单栏录音指示、0.25 秒的心跳 Timer、`meeting` 勿扰、宠物通知、合规对话框、日历候选、会议设置与文案。
/// 会话按原来内联的顺序调这些端口；这里只把每个调用落到对应的 App 对象上，不做决定。
///
/// `init` 里不能碰 `MeetingSessionController.shared`：它在 `shared` 的初始化过程中建出来，碰了会递归。
/// 其余方法读会话状态时用 `shared`（App 里只有这一个会话）。
@MainActor
final class MeetingSessionShell: MeetingSessionEnvironment {
    static let shared = MeetingSessionShell()

    private let bar = MeetingControlBarController()
    private let statusItem = MeetingStatusItem()
    private var timer: Timer?

    private init() {}

    func now() -> Date {
        Date()
    }

    // MARK: - 开始前

    func captureBusyMessage() -> String? {
        AudioCaptureCoordinator.shared.busyMessage()
    }

    func confirmConsent() -> Bool {
        MeetingSettings.consentAcknowledged || askConsent()
    }

    func calendarBindingCandidate() -> MeetingEventInfo? {
        MeetingCalendar.shared.bindingCandidate()?.info
    }

    var defaultType: MeetingType { MeetingSettings.defaultType }

    var minutesStyle: MeetingMinutesStyle { MeetingSettings.template }

    var captureLabel: String { L("meeting.captureLabel") }

    func typeName(_ type: MeetingType) -> String {
        MeetingText.typeName(type)
    }

    /// 合规说明：告知参会人是用户自己的事，这里只提醒、不代为通知（需求 §3）。确认一次后不再问；返回是否确认。
    ///
    /// 用模态对话框、不走通知：这是点了「开始」之后必须先回答的一步。宠物关着时通知会退成系统横幅，
    /// 按钮藏在「选项」里、一闪就没，看起来就像点了没反应（2026-11-06 真机）。
    private func askConsent() -> Bool {
        let previous = NSWorkspace.shared.frontmostApplication
        // LSUIElement 应用不先激活，对话框会排在别的 App 窗口后面，主线程却已进了模态循环（见 CaffeinateController）。
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("meeting.consent.title")
        alert.informativeText = L("meeting.consent.body")
        alert.addButton(withTitle: L("meeting.consent.ack"))
        alert.addButton(withTitle: L("meeting.consent.cancel"))
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        // 焦点还给原来的 App（多半是会议软件）。
        if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           !previous.isTerminated {
            previous.activate()
        }
        if confirmed { MeetingSettings.consentAcknowledged = true }
        return confirmed
    }

    // MARK: - 会中 / 会后

    func setDoNotDisturb(_ on: Bool) {
        NotifyDND.shared.setSuppressed(on, token: MeetingSessionController.dndToken)
    }

    func setHeartbeat(_ running: Bool) {
        timer?.invalidate()
        timer = nil
        guard running else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingSessionController.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func controlBar(_ change: MeetingControlBarChange) {
        switch change {
        case .show: bar.show()
        case .hide: bar.hide()
        case .refreshSize: bar.refreshSize()
        case .notesExpanded(let expanded): bar.setNotesExpanded(expanded)
        }
    }

    /// 菜单栏「● 32:15」。
    func refreshIndicators() {
        let session = MeetingSessionController.shared
        switch session.phase {
        case .recording, .paused, .finishing:
            statusItem.menuItems = { MeetingMenu.items(includeSettings: true) }
            statusItem.update(text: MeetingText.clock(session.elapsed()), paused: session.phase == .paused)
        case .starting:
            statusItem.menuItems = { MeetingMenu.items(includeSettings: true) }
            statusItem.update(text: "…", paused: false)
        case .idle:
            statusItem.update(text: nil, paused: false)
        }
    }

    /// 菜单栏的下一场倒计时（MeetingReminder 每 15 秒给一次；nil = 不显示）。记录中录音指示优先。
    func setCountdown(_ text: String?) {
        statusItem.menuItems = { MeetingMenu.items(includeSettings: true) }
        statusItem.setCountdown(text)
    }

    func toast(_ toast: MeetingSessionToast) {
        switch toast {
        case .alreadyRecording:
            postToast(L("meeting.toast.alreadyRecording"))
        case .busy(let message):
            postToast(message)
        case .overtime:
            postToast(L("meeting.toast.overtime"))
        case .nothingRecorded:
            // 结束时转录收尾在撤勿扰之前：晚一拍再发，免得被会议自己的勿扰攒起来。
            let text = L("meeting.toast.nothingRecorded")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MeetingSessionShell.shared.postToast(text)
                }
            }
        }
    }

    /// 一行轻提示。记录中挂着会议自己的勿扰，普通提示会被攒起来，所以用 alert 级、toast 样式（宠物不会出声）。
    private func postToast(_ text: String) {
        NotifyCenter.shared.post(PetNotification(source: MeetingSessionController.source, level: .alert, title: text,
                                                 style: .toast, icon: "waveform"))
    }

    /// 纪要好了 / 没整理成 / 只存了转录：宠物通知，[打开] 打开这场的记录。
    func notifySaved(_ record: MeetingRecord, outcome: MeetingMinutesOutcome) {
        let id = record.id
        let title: String
        switch outcome {
        case .done: title = L("meeting.notify.minutesReady")
        case .failed: title = L("meeting.notify.minutesFailed")
        case .generating, .interrupted: return
        case .off, .noModel, .tooShort: title = L("meeting.notify.transcriptOnly")
        }
        var body = record.meta.title
        if let duration = record.meta.duration {
            body += " · " + MeetingText.duration(duration)
        }
        if outcome == .noModel {
            body += "\n" + L("meeting.notify.noModelHint")
        }
        var summarized = false
        if case .done = outcome { summarized = true }
        let notification = PetNotification(
            source: MeetingSessionController.source, level: .bubble, title: title, body: body,
            actions: [.init(id: "open", label: L("meeting.notify.open"), role: .primary)],
            dedupeKey: "saved.\(id)", icon: summarized ? "doc.text" : "waveform")
        // 结束时转录收尾在撤勿扰之前：晚一拍再发，免得被会议自己的勿扰攒起来。
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NotifyCenter.shared.post(notification) { action in
                    guard action == "open" else { return }
                    MeetingWindowController.shared.showLibrary(select: id)
                }
            }
        }
    }
}

// MARK: - App 里的那一个会话

extension MeetingSessionController {
    /// 装配：引擎（`AppDelegate.meetingEngine`，会议库已作为构造参数交给它）、会议库、App 外壳。第一次用到时建好、之后不变
    /// （docs/meeting/ENGINE.md §4.6）。
    static let shared = MeetingSessionController(engine: AppDelegate.meetingEngine, library: MeetingStore.shared,
                                                 environment: MeetingSessionShell.shared)

    /// 菜单栏的下一场倒计时（MeetingReminder 每 15 秒给一次；nil = 不显示）。记录中录音指示优先。
    func setCountdown(_ text: String?) {
        MeetingSessionShell.shared.setCountdown(text)
    }

    // MARK: 菜单状态行

    /// 「● 记录中 32:15 · 线上会议」「正在开始记录…」；空闲时「下一场：设计评审 · 25 分钟后」（读着日历、接下来有会时）。
    func statusLine() -> String {
        let kind = type.map(MeetingText.typeName) ?? ""
        switch phase {
        case .starting: return L("meeting.statusLine.starting")
        case .recording: return L("meeting.statusLine.recording \(MeetingText.clock(elapsed())) \(kind)")
        case .paused: return L("meeting.statusLine.paused \(MeetingText.clock(elapsed())) \(kind)")
        case .finishing: return L("meeting.statusLine.finishing")
        case .idle:
            if engine.activity == .freeListening {
                return L("meeting.statusLine.freeListening")
            }
            let now = Date()
            if let next = MeetingCalendar.shared.next(at: now) {
                return L("meeting.statusLine.next \(next.info.title) \(MeetingText.relative(next.info.start, now: now))")
            }
            if let summarizing = MeetingStore.shared.records.first(where: { $0.meta.status == .summarizing }) {
                return L("meeting.statusLine.summarizing \(summarizing.meta.title)")
            }
            return L("meeting.statusLine.idle")
        }
    }
}
