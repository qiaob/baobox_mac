import Foundation

// 专注与健康的数据模型（docs/focus-health/TECH_DESIGN.md §1）。
// 本文件只依赖 Foundation，可脱离 App 单独编译测试；显示文案在 FocusHealthText.swift。

/// 休息强度（需求 §5）：轻松 = 只发宠物提醒（可推迟）；标准 = 宠物走到屏幕中央变大，变暗 + 拦截键鼠，
/// 不可推迟，长按 3 秒才能跳过；严格 = 在标准基础上把背景模糊掉。
enum BreakStrength: String, Codable, CaseIterable {
    case relaxed, standard, strict
}

/// 一条健康提醒（需求 §2）。解析全程容错：字段缺失或值不认识就用默认值，
/// 外部改坏的 JSON 决不让 App 崩溃。
struct ReminderItem: Codable, Identifiable, Equatable {
    enum Schedule: String, Codable, CaseIterable {
        case interval   // 每隔 X 分钟
        case daily      // 每天固定时刻
    }

    enum Clock: String, Codable, CaseIterable {
        case active     // 按用电脑的时间（离开不计）
        case wall       // 按实际时间
    }

    enum Style: String, Codable, CaseIterable {
        case bubble     // 宠物提醒：气泡 + 按钮
        case rest       // 休息画面（强提醒）
        /// 轻提醒：宠物做个动作 + 一个几秒后自己消失的小气泡，没有按钮、不盖屏（护眼 20-20-20 这类一下就做完的事）。
        case nudge
    }

    var id: String
    /// 预置项标识（water / stand / eye / break）；自建项为 nil。决定默认名称与宠物动作。
    var preset: String?
    /// 自定义名称；空 = 用预置名（随界面语言）。
    var name: String
    var enabled: Bool
    var schedule: Schedule
    var intervalMinutes: Int
    var clock: Clock
    /// 每天固定时刻：距 0 点的分钟数。
    var timeOfDay: Int
    var style: Style
    /// 休息画面时长（秒）。
    var restSeconds: Int
    var workHoursOnly: Bool
    /// 离开电脑够久算完成（自然休息）。
    var awayCounts: Bool

    init(id: String = UUID().uuidString, preset: String? = nil, name: String = "", enabled: Bool = true,
         schedule: Schedule = .interval, intervalMinutes: Int = 30, clock: Clock = .active,
         timeOfDay: Int = 9 * 60, style: Style = .bubble, restSeconds: Int = 60,
         workHoursOnly: Bool = false, awayCounts: Bool = false) {
        self.id = id
        self.preset = preset
        self.name = name
        self.enabled = enabled
        self.schedule = schedule
        self.intervalMinutes = intervalMinutes
        self.clock = clock
        self.timeOfDay = timeOfDay
        self.style = style
        self.restSeconds = restSeconds
        self.workHoursOnly = workHoursOnly
        self.awayCounts = awayCounts
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case id, preset, name, enabled, schedule, intervalMinutes, clock, timeOfDay, style, restSeconds,
             workHoursOnly, awayCounts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        let fallback = ReminderItem(id: "")
        self.init(
            id: get(.id, String.self).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
            preset: get(.preset, String.self),
            name: get(.name, String.self) ?? "",
            enabled: get(.enabled, Bool.self) ?? true,
            schedule: get(.schedule, Schedule.self) ?? fallback.schedule,
            intervalMinutes: get(.intervalMinutes, Int.self) ?? fallback.intervalMinutes,
            clock: get(.clock, Clock.self) ?? fallback.clock,
            timeOfDay: get(.timeOfDay, Int.self) ?? fallback.timeOfDay,
            style: get(.style, Style.self) ?? fallback.style,
            restSeconds: get(.restSeconds, Int.self) ?? fallback.restSeconds,
            workHoursOnly: get(.workHoursOnly, Bool.self) ?? false,
            awayCounts: get(.awayCounts, Bool.self) ?? false
        )
    }

    /// 把越界的数值收回合理范围（手改 JSON、旧版本数据）。
    mutating func normalize() {
        intervalMinutes = min(max(intervalMinutes, 1), 24 * 60)
        timeOfDay = min(max(timeOfDay, 0), 24 * 60 - 1)
        restSeconds = min(max(restSeconds, 10), 3600)
    }

    var intervalSeconds: TimeInterval { TimeInterval(intervalMinutes * 60) }

    /// 统一节拍里的级别（docs/focus-health/REQUIREMENTS.md §7）：3 = 大休息（休息画面 ≥ 2 分钟），
    /// 2 = 起身（宠物提醒：站立、喝水、自定义），1 = 小歇（轻提醒、很短的休息画面）。大的包含小的。
    var tier: Int {
        switch style {
        case .rest: return restSeconds >= 120 ? 3 : 1
        case .bubble: return 2
        case .nudge: return 1
        }
    }

    /// 离开多久算这一项做过了（需求 §3）：休息画面项、轻提醒项 = max(休息时长, 2 分钟)，宠物提醒项 = 5 分钟。
    var awayThreshold: TimeInterval {
        style == .bubble ? 300 : TimeInterval(max(restSeconds, 120))
    }
}

/// 预置四项（需求 §2）。id 固定，便于「恢复预置」只补缺的。
enum ReminderPreset {
    static let water = "water"
    static let stand = "stand"
    static let eye = "eye"
    static let rest = "break"

    /// 2026-11-07 统一节拍（REQUIREMENTS.md §7）：喝水跟站立同一个节奏（按用电脑的时间每 60 分钟、离开也算做过），
    /// 两项总是一起到点、合成一条「起来走走，喝口水」；护眼改成轻提醒，不盖屏。
    static func defaults() -> [ReminderItem] {
        [
            ReminderItem(id: "preset.water", preset: water, intervalMinutes: 60, clock: .active,
                         style: .bubble, awayCounts: true),
            ReminderItem(id: "preset.stand", preset: stand, intervalMinutes: 60, clock: .active,
                         style: .bubble, awayCounts: true),
            ReminderItem(id: "preset.eye", preset: eye, intervalMinutes: 20, clock: .active,
                         style: .nudge, restSeconds: 20, awayCounts: true),
            ReminderItem(id: "preset.break", preset: rest, intervalMinutes: 50, clock: .active,
                         style: .rest, restSeconds: 300, awayCounts: true),
        ]
    }

    /// 旧版本存下的预置项：用户没改过（还是旧默认值）的换成新默认值；改过的原样保留。
    static func migrated(_ items: [ReminderItem]) -> [ReminderItem] {
        let fresh = Dictionary(uniqueKeysWithValues: defaults().map { ($0.id, $0) })
        return items.map { item in
            guard let replacement = fresh[item.id], item.name.isEmpty, !item.workHoursOnly,
                  item.schedule == .interval else { return item }
            let oldWater = item.preset == water && item.intervalMinutes == 45 && item.clock == .wall
                && item.style == .bubble && !item.awayCounts
            let oldEye = item.preset == eye && item.intervalMinutes == 20 && item.clock == .active
                && item.style == .rest && item.restSeconds == 20 && item.awayCounts
            guard oldWater || oldEye else { return item }
            var updated = replacement
            updated.enabled = item.enabled
            return updated
        }
    }
}

/// 一项提醒的计时进度（持久化在 state.json）。
struct ReminderRuntime: Codable, Equatable {
    /// 按用电脑的时间累计的秒数（clock == .active）。
    var activeSeconds: Double = 0
    /// 按实际时间计时的起点（clock == .wall）。
    var anchor: Date
    /// 推迟后的到点时刻；非 nil 时以它为准。
    var forcedDueAt: Date?
    /// 本轮推迟了几次（休息画面的推迟上限用）。
    var snoozeCount: Int = 0
    /// 每天固定时刻：最近一次提醒是哪天（yyyy-MM-dd）。
    var lastDailyFire: String?
    /// 休息预告已发（每轮只发一次）。
    var warned: Bool = false
    /// 到点后被挡住（专注 / 避让）的开始时刻。
    var deferredSince: Date?

    init(anchor: Date) {
        self.anchor = anchor
    }

    private enum CodingKeys: String, CodingKey {
        case activeSeconds, anchor, forcedDueAt, snoozeCount, lastDailyFire, warned, deferredSince
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        anchor = get(.anchor, Date.self) ?? Date()
        activeSeconds = max(get(.activeSeconds, Double.self) ?? 0, 0)
        forcedDueAt = get(.forcedDueAt, Date.self)
        snoozeCount = max(get(.snoozeCount, Int.self) ?? 0, 0)
        lastDailyFire = get(.lastDailyFire, String.self)
        warned = get(.warned, Bool.self) ?? false
        deferredSince = get(.deferredSince, Date.self)
    }
}

/// 专注后接哪种休息。
enum BreakKind: String, Codable {
    case short, long
}

/// 专注—休息循环（技术设计 §3）。
struct FocusSession: Codable, Equatable {
    enum Phase: String, Codable {
        case idle, focusing, paused, shortBreak, longBreak
    }

    /// 计划时长达到这么久算「长专注」，结束后直接接休息画面。
    static let longFocusSeconds: Double = 50 * 60

    var phase: Phase = .idle
    var plannedSeconds: Double = 0
    /// 当前这段（未暂停）专注的开始时刻。
    var segmentStart: Date?
    /// 之前几段累计的专注秒数（暂停过）。
    var elapsedBefore: Double = 0
    var breakSeconds: Double = 0
    var breakEndsAt: Date?
    var roundsToday: Int = 0
    /// roundsToday 记的是哪天（yyyy-MM-dd），翻日清零。
    var roundsDay: String = ""

    init() {}

    var inFocus: Bool { phase == .focusing || phase == .paused }
    var inBreak: Bool { phase == .shortBreak || phase == .longBreak }

    func elapsed(at now: Date) -> Double {
        guard phase == .focusing || phase == .paused else { return elapsedBefore }
        let running = phase == .focusing ? max(0, now.timeIntervalSince(segmentStart ?? now)) : 0
        return elapsedBefore + running
    }

    func remaining(at now: Date) -> Double {
        max(0, plannedSeconds - elapsed(at: now))
    }

    func breakRemaining(at now: Date) -> Double {
        max(0, (breakEndsAt ?? now).timeIntervalSince(now))
    }

    /// 专注中按计划该在什么时候结束（判断 App 关着期间过点多久用）。
    var plannedEnd: Date? {
        guard phase == .focusing, let start = segmentStart else { return nil }
        return start.addingTimeInterval(plannedSeconds - elapsedBefore)
    }

    mutating func start(seconds: Double, at now: Date) {
        phase = .focusing
        plannedSeconds = max(60, seconds)
        segmentStart = now
        elapsedBefore = 0
        breakSeconds = 0
        breakEndsAt = nil
    }

    mutating func pause(at now: Date) {
        guard phase == .focusing else { return }
        elapsedBefore = elapsed(at: now)
        segmentStart = nil
        phase = .paused
    }

    mutating func resume(at now: Date) {
        guard phase == .paused else { return }
        segmentStart = now
        phase = .focusing
    }

    mutating func rollDay(_ day: String) {
        if roundsDay != day {
            roundsDay = day
            roundsToday = 0
        }
    }

    /// 记为完成：轮次 +1，返回要接的休息。长专注或满 N 轮接长休息（休息画面）。
    @discardableResult
    mutating func complete(day: String, longEvery: Int) -> BreakKind {
        rollDay(day)
        roundsToday += 1
        let planned = plannedSeconds
        phase = .idle
        segmentStart = nil
        elapsedBefore = 0
        let every = max(longEvery, 1)
        return (planned >= Self.longFocusSeconds || roundsToday % every == 0) ? .long : .short
    }

    mutating func discard() {
        phase = .idle
        segmentStart = nil
        elapsedBefore = 0
        plannedSeconds = 0
    }

    mutating func startBreak(_ kind: BreakKind, seconds: Double, at now: Date) {
        phase = kind == .long ? .longBreak : .shortBreak
        breakSeconds = max(seconds, 1)
        breakEndsAt = now.addingTimeInterval(breakSeconds)
    }

    mutating func endBreak() {
        if inBreak { phase = .idle }
        breakSeconds = 0
        breakEndsAt = nil
    }

    private enum CodingKeys: String, CodingKey {
        case phase, plannedSeconds, segmentStart, elapsedBefore, breakSeconds, breakEndsAt, roundsToday, roundsDay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        phase = get(.phase, Phase.self) ?? .idle
        plannedSeconds = max(get(.plannedSeconds, Double.self) ?? 0, 0)
        segmentStart = get(.segmentStart, Date.self)
        elapsedBefore = max(get(.elapsedBefore, Double.self) ?? 0, 0)
        breakSeconds = max(get(.breakSeconds, Double.self) ?? 0, 0)
        breakEndsAt = get(.breakEndsAt, Date.self)
        roundsToday = max(get(.roundsToday, Int.self) ?? 0, 0)
        roundsDay = get(.roundsDay, String.self) ?? ""
        // 数据不自洽（专注中却没有开始时刻、休息中却没有结束时刻）就当空闲，别卡在半截状态里。
        if phase == .focusing, segmentStart == nil { phase = .idle }
        if inBreak, breakEndsAt == nil { phase = .idle }
    }
}

/// 工作时间（需求 §2「仅工作时间」）。跨午夜的时段（如 22:00–06:00）也支持。
struct WorkHours: Equatable {
    var startMinute: Int = 9 * 60
    var endMinute: Int = 18 * 60
    var workdaysOnly: Bool = true

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        if workdaysOnly, calendar.isDateInWeekend(date) { return false }
        let minute = FocusDay.minuteOfDay(date, calendar: calendar)
        if startMinute == endMinute { return true }
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }
}

/// 本地日期工具：翻日判断、固定时刻换算。
enum FocusDay {
    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// 与 date 同一天、0 点起第 minute 分钟的时刻（夏令时切换日也按钟面时间算）。
    static func date(minute: Int, sameDayAs date: Date, calendar: Calendar = .current) -> Date {
        let clamped = min(max(minute, 0), 24 * 60 - 1)
        return calendar.date(bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: date)
            ?? calendar.startOfDay(for: date).addingTimeInterval(TimeInterval(clamped * 60))
    }
}

/// 持久化的运行状态（state.json）。
struct FocusHealthState: Codable {
    var session = FocusSession()
    var runtime: [String: ReminderRuntime] = [:]
    var pausedUntil: Date?
    /// 「今天关闭」是哪天（yyyy-MM-dd）。
    var offDay: String?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case session, runtime, pausedUntil, offDay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = ((try? c.decodeIfPresent(FocusSession.self, forKey: .session)) ?? nil) ?? FocusSession()
        runtime = ((try? c.decodeIfPresent([String: ReminderRuntime].self, forKey: .runtime)) ?? nil) ?? [:]
        pausedUntil = (try? c.decodeIfPresent(Date.self, forKey: .pausedUntil)) ?? nil
        offDay = (try? c.decodeIfPresent(String.self, forKey: .offDay)) ?? nil
    }
}
