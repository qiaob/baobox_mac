import Foundation

// 提醒调度（docs/focus-health/TECH_DESIGN.md §2、§4）：纯函数，只依赖 Foundation，可单独编译测试。
// 控制器每秒调一次 advance；到点的项保持到点状态，直到控制器 reset / snooze。

/// 一跳的输入。
struct SchedulerInput {
    var now: Date
    /// 距上一跳的秒数（控制器已封顶，睡眠回来不会一次累加几小时）。
    var dt: TimeInterval
    /// 人在电脑前（键鼠空闲不到 2 分钟，或在看视频）。
    var present: Bool
    var inWorkHours: Bool
    var calendar: Calendar = .current
}

enum ReminderEvent: Equatable {
    /// 休息画面项再过 1 分钟到点（每轮只发一次）。
    case warn(String)
    /// 到点。
    case due(String)
}

enum ReminderScheduler {
    /// 休息画面提前多久预告。
    static let warnLead: TimeInterval = 60
    /// 每天固定时刻：到点后多久之内还补提醒。
    static let dailyGrace: TimeInterval = 4 * 3600

    /// 推进一跳：累加计时，返回预告 / 到点事件。
    static func advance(_ items: [ReminderItem], runtime: inout [String: ReminderRuntime],
                        input: SchedulerInput) -> [ReminderEvent] {
        var events: [ReminderEvent] = []
        for item in items where item.enabled {
            var state = runtime[item.id] ?? ReminderRuntime(anchor: input.now)
            let allowed = !item.workHoursOnly || input.inWorkHours
            if let forced = state.forcedDueAt {
                // 推迟中：以推迟后的时刻为准，期间不累加。
                if allowed, input.now >= forced { events.append(.due(item.id)) }
            } else {
                switch item.schedule {
                case .daily:
                    if allowed, isDailyDue(item, state, now: input.now, calendar: input.calendar) {
                        events.append(.due(item.id))
                    }
                case .interval:
                    if item.clock == .active, input.present, allowed {
                        state.activeSeconds += max(input.dt, 0)
                    }
                    let progress = item.clock == .active
                        ? state.activeSeconds
                        : input.now.timeIntervalSince(state.anchor)
                    if allowed {
                        if progress >= item.intervalSeconds {
                            events.append(.due(item.id))
                        } else if item.style == .rest, !state.warned, item.intervalSeconds > warnLead * 2,
                                  progress >= item.intervalSeconds - warnLead {
                            state.warned = true
                            events.append(.warn(item.id))
                        }
                    }
                }
            }
            runtime[item.id] = state
        }
        return events
    }

    static func isDailyDue(_ item: ReminderItem, _ state: ReminderRuntime, now: Date,
                           calendar: Calendar = .current) -> Bool {
        guard state.lastDailyFire != FocusDay.key(now, calendar: calendar) else { return false }
        let target = FocusDay.date(minute: item.timeOfDay, sameDayAs: now, calendar: calendar)
        let late = now.timeIntervalSince(target)
        return late >= 0 && late < dailyGrace
    }

    /// 这一项提醒过了（发出 / 完成 / 跳过 / 被吞并）：重新计时。
    static func reset(_ id: String, runtime: inout [String: ReminderRuntime], now: Date,
                      calendar: Calendar = .current) {
        var state = runtime[id] ?? ReminderRuntime(anchor: now)
        state.activeSeconds = 0
        state.anchor = now
        state.forcedDueAt = nil
        state.snoozeCount = 0
        state.warned = false
        state.deferredSince = nil
        state.lastDailyFire = FocusDay.key(now, calendar: calendar)
        runtime[id] = state
    }

    /// 提醒发出去了、但不知道用户做没做（轻松档的休息气泡）：重新计时，保留本轮推迟次数 ——
    /// 推迟上限要跨「推迟 → 再提醒 → 再推迟」累计，否则可以无限推迟。
    static func rearm(_ id: String, runtime: inout [String: ReminderRuntime], now: Date,
                      calendar: Calendar = .current) {
        let kept = runtime[id]?.snoozeCount ?? 0
        reset(id, runtime: &runtime, now: now, calendar: calendar)
        runtime[id]?.snoozeCount = kept
    }

    /// 推迟 seconds 秒再提醒；推迟后不再发预告。
    static func snooze(_ id: String, seconds: TimeInterval, runtime: inout [String: ReminderRuntime], now: Date,
                       calendar: Calendar = .current) {
        var state = runtime[id] ?? ReminderRuntime(anchor: now)
        state.forcedDueAt = now.addingTimeInterval(seconds)
        state.snoozeCount += 1
        state.warned = true
        state.deferredSince = nil
        state.lastDailyFire = FocusDay.key(now, calendar: calendar)
        runtime[id] = state
    }

    /// 记下「到点但被挡住」的开始时刻；已记过的保留最早那次（顺延超过 45 分钟要降级）。
    static func markDeferred(_ id: String, runtime: inout [String: ReminderRuntime], now: Date) {
        var state = runtime[id] ?? ReminderRuntime(anchor: now)
        if state.deferredSince == nil { state.deferredSince = now }
        runtime[id] = state
    }

    /// 离开电脑 span 秒后回来：达到阈值的「离开算完成」项重新计时（自然休息）。返回被重置的 id。
    @discardableResult
    static func applyAway(span: TimeInterval, items: [ReminderItem], runtime: inout [String: ReminderRuntime],
                          now: Date) -> [String] {
        var resetIDs: [String] = []
        for item in items where item.enabled && item.awayCounts && item.schedule == .interval
            && span >= item.awayThreshold {
            reset(item.id, runtime: &runtime, now: now)
            resetIDs.append(item.id)
        }
        return resetIDs
    }

    /// 休息做完了：全部「离开算完成」项重新计时（不会刚休息完又被要求休息）。
    static func resetAwayItems(_ items: [ReminderItem], runtime: inout [String: ReminderRuntime], now: Date) {
        for item in items where item.awayCounts && item.schedule == .interval {
            reset(item.id, runtime: &runtime, now: now)
        }
    }

    /// 距离到点还有多久（菜单「下一个提醒」用；按用电脑的时间计的项按人一直在电脑前估算）。
    static func timeUntilDue(_ item: ReminderItem, _ state: ReminderRuntime?, now: Date,
                             calendar: Calendar = .current) -> TimeInterval {
        let state = state ?? ReminderRuntime(anchor: now)
        if let forced = state.forcedDueAt { return max(0, forced.timeIntervalSince(now)) }
        switch item.schedule {
        case .interval:
            let progress = item.clock == .active ? state.activeSeconds : now.timeIntervalSince(state.anchor)
            return max(0, item.intervalSeconds - progress)
        case .daily:
            var target = FocusDay.date(minute: item.timeOfDay, sameDayAs: now, calendar: calendar)
            let firedToday = state.lastDailyFire == FocusDay.key(now, calendar: calendar)
            if firedToday || now.timeIntervalSince(target) >= dailyGrace {
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86400)
                target = FocusDay.date(minute: item.timeOfDay, sameDayAs: tomorrow, calendar: calendar)
            }
            return max(0, target.timeIntervalSince(now))
        }
    }

}

/// 一次提醒的安排：一起提醒哪几项（第一个是主项，决定用什么形式提醒），顺带算完成哪几项。
struct ReminderPlan: Equatable {
    var items: [String]
    var covered: [String]
}

/// 统一节拍（docs/focus-health/REQUIREMENTS.md §7、TECH_DESIGN.md §4.1）：各项照旧各自计时，
/// 但什么时候真的打扰、一次说几件事由这里统一定，不再各自弹：
/// 1. 最小间隔：离上一次提醒不到 `minSpacing`，有间隔的项先等着（每天固定时刻的项不等）；
/// 2. 等大的：比到点项高一级的项 10 分钟内就到，先不打扰，等它来了一起说；
/// 3. 顺手合并：同级或更低级的项在自己间隔的 30%（最多 15 分钟）之内也要到点的，提前一起说；
/// 4. 大的包含小的：这次的级别比谁高，谁就算做过了（大休息 ⊃ 起身 ⊃ 小歇）。
enum ReminderCoordinator {
    static let mergeCap: TimeInterval = 15 * 60
    static let mergeFraction = 0.3
    static let waitForBigger: TimeInterval = 10 * 60

    /// 这一跳到点的项怎么提醒；nil = 这一跳先不提醒（离上次太近 / 在等更大的那项）。
    static func plan(due: [ReminderItem], items: [ReminderItem], runtime: [String: ReminderRuntime], now: Date,
                     lastPromptAt: Date?, minSpacing: TimeInterval) -> ReminderPlan? {
        guard let topTier = due.map(\.tier).max() else { return nil }
        let hasDaily = due.contains { $0.schedule == .daily }
        if !hasDaily, let last = lastPromptAt, now.timeIntervalSince(last) < minSpacing { return nil }
        let dueIDs = Set(due.map(\.id))
        let intervalItems = items.filter { $0.enabled && $0.schedule == .interval && !dueIDs.contains($0.id) }
        func untilDue(_ item: ReminderItem) -> TimeInterval {
            ReminderScheduler.timeUntilDue(item, runtime[item.id], now: now)
        }
        if !hasDaily, intervalItems.contains(where: { $0.tier > topTier && untilDue($0) <= waitForBigger }) {
            return nil
        }
        var members = due
        for other in intervalItems where other.tier <= topTier {
            if untilDue(other) <= min(mergeCap, other.intervalSeconds * mergeFraction) { members.append(other) }
        }
        // 主项：级别最高的，其次休息最长的，再按原来的顺序。
        let order = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        members.sort {
            if $0.tier != $1.tier { return $0.tier > $1.tier }
            if $0.restSeconds != $1.restSeconds { return $0.restSeconds > $1.restSeconds }
            return (order[$0.id] ?? 0) < (order[$1.id] ?? 0)
        }
        let memberIDs = Set(members.map(\.id))
        let tier = members.first?.tier ?? topTier
        let covered = intervalItems.filter { $0.tier < tier && !memberIDs.contains($0.id) }.map(\.id)
        return ReminderPlan(items: members.map(\.id), covered: covered)
    }
}
