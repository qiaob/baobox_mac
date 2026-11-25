import AppKit
import os

// 快速入口的一次性提醒（docs/launcher/TECH_DESIGN.md §5.4「一次性提醒」，第 10 步）：输入「20 分钟后提醒我取快递」，最前面一行「14:35 提醒我：取快递」，
// ⏎ 设好；到点经通知内核发一条 alert（宠物开着是宠物气泡，否则系统通知）。输入「提醒」/「reminders」列出还没到点的，⏎ 两次取消。
// - 存储：`~/Library/Application Support/Baobox/Launcher/reminders.json`（格式与解码容错在 `Logic/LauncherReminders.swift`）。
//   启动时在后台读回；读回前设的、取消的先记着，读完按顺序补上（不会被盘上的盖掉，也不会用空表盖盘）。每次改动在后台原子写；
//   写盘失败走 `StorageWriteFailure.report`（约定 8）。
// - 计时：一个到最近一条为止的计时器；过了点没响的（关机、睡眠中、计时器晚了）补响一次，标明晚了多久。系统睡眠唤醒、
//   改了系统时间后重新对表。
// 打字时只读内存里的 `pending`；读写盘、计时都不在打字路径上。日志只记条数和秒数，不记事由。

@MainActor
final class LauncherReminderCenter {
    static let shared = LauncherReminderCenter()
    nonisolated private static let log = Logger(subsystem: "com.baobox.app", category: "launcher")
    /// 计时器允许晚多久（省电）：提醒精确到分钟就够了。
    static let timerTolerance: TimeInterval = 1

    /// 还没到点的提醒，按到点时刻排。
    private(set) var pending: [LauncherReminder] = []

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.baobox.app.launcher.reminders", qos: .utility)
    private var loadRequested = false
    /// 读盘完成之前不写、不响：免得用还没读进来的空表盖掉磁盘上的。
    private var loaded = false
    /// 读盘完成前的改动（设好、取消），读完按顺序补上。
    private var pendingChanges: [([LauncherReminder]) -> [LauncherReminder]] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(directory: URL = LauncherUsageStore.defaultDirectory) {
        fileURL = directory.appendingPathComponent("reminders.json")
    }

    /// 模块 activate：后台读盘；监听睡眠唤醒、系统时间变化（重新对表）。
    func activate() {
        guard !loadRequested else { return }
        loadRequested = true
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck(reason: "wake") }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck(reason: "clock changed") }
        })
        let url = fileURL
        queue.async {
            let disk = Self.read(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishLoading(disk) }
            }
        }
    }

    /// 模块 willTerminate：等还在写的那次写完（提醒每次改动都马上写，不防抖，没有攒着的）。
    func flush() {
        timer?.invalidate()
        timer = nil
        queue.sync {}
    }

    /// 设一条提醒（⏎ 了最前面那一行）。返回设好的那条。
    @discardableResult
    func add(_ draft: LauncherReminderDraft, now: Date = Date()) -> LauncherReminder {
        let reminder = LauncherReminder(id: UUID().uuidString, date: draft.date,
                                        text: String(draft.text.prefix(LauncherReminderBook.maxTextLength)), created: now)
        change { LauncherReminderBook.inserting(reminder, into: $0) }
        Self.log.notice("reminder set, due in \(Int(reminder.date.timeIntervalSince(now)), privacy: .public) s; \(self.pending.count, privacy: .public) pending")
        return reminder
    }

    /// 取消一条还没到点的提醒。false = 已经没有这一条了（刚响过、别处取消了）。
    @discardableResult
    func cancel(id: String) -> Bool {
        guard pending.contains(where: { $0.id == id }) else { return false }
        change { list in list.filter { $0.id != id } }
        Self.log.notice("reminder cancelled; \(self.pending.count, privacy: .public) pending")
        return true
    }

    // MARK: - 内部

    private func change(_ apply: @escaping ([LauncherReminder]) -> [LauncherReminder]) {
        pending = apply(pending)
        guard loaded else {
            pendingChanges.append(apply)
            return
        }
        save()
        reschedule()
    }

    private func finishLoading(_ disk: [LauncherReminder]) {
        var merged = disk
        for apply in pendingChanges { merged = apply(merged) }
        let hadChanges = !pendingChanges.isEmpty
        pendingChanges = []
        pending = merged
        loaded = true
        Self.log.notice("reminders loaded: \(disk.count, privacy: .public) on disk, \(merged.count, privacy: .public) after merging")
        // 过了点没响的（关机、App 没开着）现在补响；`fireDue` 有响的就会写盘。
        if !fireDue(now: Date()), hadChanges { save() }
        reschedule()
    }

    /// 唤醒、改了系统时间：过了点的补响，计时器按新的时间重排。
    private func recheck(reason: String) {
        guard loaded else { return }
        Self.log.notice("reminders recheck (\(reason, privacy: .public)), \(self.pending.count, privacy: .public) pending")
        fireDue(now: Date())
        reschedule()
    }

    /// 响掉所有到点了的（晚了一分钟以上的标明晚了多久），从表里去掉并写盘。返回有没有响的。
    @discardableResult
    private func fireDue(now: Date) -> Bool {
        let (due, rest) = LauncherReminderBook.split(pending, now: now)
        guard !due.isEmpty else { return false }
        pending = rest
        save()
        for reminder in due {
            post(reminder, late: LauncherReminderBook.lateness(of: reminder, now: now), now: now)
        }
        return true
    }

    private func post(_ reminder: LauncherReminder, late: TimeInterval?, now: Date) {
        let body: String
        if let late {
            body = L("launcher.reminder.alert.late \(LauncherReminderText.lateness(late)) \(LauncherReminderText.when(reminder.date, now: now))")
        } else {
            body = ""
        }
        Self.log.notice("reminder fired\(late == nil ? "" : " late", privacy: .public) (\(Int(late ?? 0), privacy: .public) s)")
        NotifyCenter.shared.post(Notice(source: "launcher", level: .alert,
                                        title: L("launcher.reminder.alert.title \(reminder.text)"), body: body,
                                        dedupeKey: "launcher.reminder." + reminder.id, icon: "alarm"))
    }

    /// 计时器定到最近一条；没有就停掉。到点的那一下：响掉到点的、再定下一条。
    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard loaded, let next = pending.first?.date else { return }
        let timer = Timer(fire: max(next, Date()), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fireDue(now: Date())
                self?.reschedule()
            }
        }
        timer.tolerance = Self.timerTolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func save() {
        guard loaded else { return }
        let snapshot = pending
        let url = fileURL
        queue.async {
            guard let data = LauncherReminderBook.encode(snapshot) else {
                StorageWriteFailure.report(L("storage.what.launcherReminders"), reason: "encoding failed")
                return
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                StorageWriteFailure.report(L("storage.what.launcherReminders"), reason: error.localizedDescription)
            }
        }
    }

    /// 读盘（后台）：文件不存在 → 空表；不是合法 JSON → 改名留底（`reminders.json.bad`）、当空表（同使用记录）。
    /// 单条坏了由 `LauncherReminderBook.decode` 跳过。
    nonisolated private static func read(_ url: URL) -> [LauncherReminder] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            let bad = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: url, to: bad)
            return []
        }
        return LauncherReminderBook.decode(data)
    }
}

/// 提醒的「什么时候」怎么写：今天只写时刻（14:35），明天 / 后天写「明天 14:35」，再往后写日期（11月28日 14:35），跨年带年份。
/// 时刻一律 24 小时制（同设计稿）。语言跟界面（`L10n.locale`），日历、时区跟系统。
@MainActor
enum LauncherReminderText {
    private static let timeFormatter = formatter("Hm")
    private static let dateFormatter = formatter("MMMd")
    private static let yearDateFormatter = formatter("yMMMd")

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    /// `alwaysDay`：今天也写「今天」（回执：「已设好：今天 14:35 …」）。
    static func when(_ date: Date, now: Date, alwaysDay: Bool = false) -> String {
        let time = timeFormatter.string(from: date)
        switch LauncherReminderDay.of(date, now: now, calendar: .current) {
        case .today: return alwaysDay ? L("launcher.reminder.day.today \(time)") : time
        case .tomorrow: return L("launcher.reminder.day.tomorrow \(time)")
        case .dayAfterTomorrow: return L("launcher.reminder.day.dayAfterTomorrow \(time)")
        case .date(let sameYear):
            let day = (sameYear ? dateFormatter : yearDateFormatter).string(from: date)
            return L("launcher.reminder.day.date \(day) \(time)")
        }
    }

    /// 晚了多久：「12 分钟」「3 小时」「2 天」。
    static func lateness(_ seconds: TimeInterval) -> String {
        switch LauncherReminderLateness(seconds: seconds) {
        case .minutes(let n): return L("launcher.reminder.late.minutes \(n)")
        case .hours(let n): return L("launcher.reminder.late.hours \(n)")
        case .days(let n): return L("launcher.reminder.late.days \(n)")
        }
    }
}
