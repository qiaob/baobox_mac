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

    /// 撞车判定：另一项休息更长的休息画面项 window 秒内也要到点（需求 §7）。
    static func longerRestDueSoon(than item: ReminderItem, items: [ReminderItem],
                                  runtime: [String: ReminderRuntime], now: Date,
                                  within window: TimeInterval) -> Bool {
        items.contains { other in
            other.id != item.id && other.enabled && other.style == .rest
                && other.restSeconds > item.restSeconds
                && timeUntilDue(other, runtime[other.id], now: now) <= window
        }
    }
}
