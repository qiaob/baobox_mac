import Foundation

/// 设置页顶部那一行与菜单里「今天专注 N 分钟」用的数（docs/focus-health/HISTORY.md §3）。
struct FocusHistorySummary: Equatable {
    var todaySeconds: Int = 0
    var weekSeconds: Int = 0
    /// 到今天（今天还没有就到昨天）为止，连续几天每天至少一轮算完成的专注。
    var streakDays: Int = 0
    /// 有没有过一轮算完成的专注（没有就显示一句引导，不显示一排 0）。
    var hasCompletedFocus = false
}

/// 专注统计（纯函数，可单测）。只算结果为 done / doneEarly 的专注；一轮算在它结束的那天。
enum FocusHistoryStats {
    static func summary(_ records: [FocusHistoryRecord], now: Date, calendar: Calendar = .current) -> FocusHistorySummary {
        let counted = records.filter(\.countsAsFocus)
        guard !counted.isEmpty else { return FocusHistorySummary() }

        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        // 周从系统设定的每周第一天算起（Calendar.current 的 firstWeekday 跟着系统设置走）。
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today

        var summary = FocusHistorySummary(hasCompletedFocus: true)
        var days = Set<String>()
        for record in counted {
            days.insert(FocusDay.key(record.end, calendar: calendar))
            guard record.end < tomorrow else { continue }
            if record.end >= today { summary.todaySeconds += record.seconds }
            if record.end >= weekStart { summary.weekSeconds += record.seconds }
        }
        summary.streakDays = streak(days: days, today: today, calendar: calendar)
        return summary
    }

    /// 从今天往回数连续有专注的天数；今天还没有就从昨天数起（今天还有机会，不算断）。
    static func streak(days: Set<String>, today: Date, calendar: Calendar = .current) -> Int {
        var day = today
        if !days.contains(FocusDay.key(day, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        // 上限只为防御（日历算不出前一天时别死循环）；400 天的历史也到不了。
        while count < 10_000, days.contains(FocusDay.key(day, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}
