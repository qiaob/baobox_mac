import Foundation

/// 用量统计的共用算法：5 小时额度窗口、周窗口（滚动块 / 固定锚点）、今日累计、按天 / 项目 / 模型的报表。
///
/// 对定价表 `Table` 泛型，Claude 与 Codex 各传各的。用到「现在」和日历的地方都是参数
/// （默认 `Date()` / `Calendar.current`），测试据此固定时间与时区。纯函数，可在后台线程调用。
enum CLIUsageCalculator<Table: CLIUsagePricingTable> {
    typealias Totals = CLIUsageTotals<Table>
    typealias Window = CLIUsageWindow<Table>
    typealias Bucket = CLIUsageBucket<Table>
    typealias Report = CLIUsageReport<Table>

    /// 5 小时额度窗口的跨度。
    static var fiveHourSpan: TimeInterval { 5 * 3_600 }
    /// 周窗口的跨度（168h）。
    static var weekSpan: TimeInterval { 168 * 3_600 }

    // MARK: - 5 小时窗口

    /// 5h 窗口算法（对齐 ccusage）：升序，blockStart 向下取整到小时；超 5h 开新块。
    /// 若 `now <= 末块.start + 5h` 则末块为活跃窗口，否则无活跃窗口。
    static func activeWindow(from entries: [CLIUsageEntry], now: Date = Date()) -> Window? {
        lastActiveBlock(from: entries, span: fiveHourSpan, now: now)
    }

    /// 通用「末个活跃分块」算法（跨度参数化）：升序，blockStart 向下取整到小时；
    /// 条目时间 > `blockStart + span` 时开新块。末块满足 `now <= blockStart + span` 即为活跃窗口，否则返回 nil。
    /// span=5h 为 5 小时窗口，span=168h 为周窗口（滚动块口径），两者行为一致。
    static func lastActiveBlock(from entries: [CLIUsageEntry], span: TimeInterval, now: Date = Date()) -> Window? {
        guard !entries.isEmpty else { return nil }
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }

        var blocks: [Window] = []
        var start: Date?
        var totals = Totals.zero

        for entry in sorted {
            if let currentStart = start {
                if entry.timestamp > currentStart.addingTimeInterval(span) {
                    blocks.append(Window(start: currentStart, end: currentStart.addingTimeInterval(span), totals: totals))
                    start = floorToHour(entry.timestamp)
                    totals = .zero
                }
            } else {
                start = floorToHour(entry.timestamp)
                totals = .zero
            }
            totals.add(entry)
        }
        if let currentStart = start {
            blocks.append(Window(start: currentStart, end: currentStart.addingTimeInterval(span), totals: totals))
        }

        guard let last = blocks.last, now <= last.end else { return nil }
        return last
    }

    // MARK: - 周窗口

    /// 周窗口：滚动块（默认）复用分块算法、跨度换 168h；固定锚点聚合 [anchorStart, anchorStart+7d) 内条目。
    /// 滚动块无条目返回 nil；固定锚点即使 totals 为 0 也返回一个 window（有明确起止与倒计时可展示），
    /// 取不到锚点则回退滚动块口径（此时无条目才返回 nil）。
    static func weeklyWindow(
        from entries: [CLIUsageEntry],
        anchor: CLIUsageWeeklyAnchor,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Window? {
        if !anchor.fixed {
            guard !entries.isEmpty else { return nil }
            return lastActiveBlock(from: entries, span: weekSpan, now: now)
        }
        guard let start = weekAnchorStart(before: now, weekday: anchor.weekday, hour: anchor.hour, calendar: calendar) else {
            guard !entries.isEmpty else { return nil }
            return lastActiveBlock(from: entries, span: weekSpan, now: now)
        }
        let end = start.addingTimeInterval(weekSpan)
        var totals = Totals.zero
        for entry in entries where entry.timestamp >= start && entry.timestamp < end {
            totals.add(entry)
        }
        return Window(start: start, end: end, totals: totals)
    }

    /// `date` 之前最近一个「指定星期几的指定小时:00:00」。取不到返回 nil（调用方回退滚动块）。
    static func weekAnchorStart(before date: Date, weekday: Int, hour: Int, calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0
        components.second = 0
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            direction: .backward
        )
    }

    // MARK: - 今日

    /// 今日（`calendar` 的时区，默认本地）累计；今天没有用量返回 nil。
    static func todayTotals(from entries: [CLIUsageEntry], now: Date = Date(), calendar: Calendar = .current) -> Totals? {
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        var totals = Totals.zero
        var any = false
        for entry in entries where entry.timestamp >= dayStart && entry.timestamp < dayEnd {
            any = true
            totals.add(entry)
        }
        return any ? totals : nil
    }

    // MARK: - 报表

    /// 三维度报表：按天（新的在前）、按项目、按模型（后两张按 `order` 从大到小）。
    /// - Parameters:
    ///   - locale: 「按天」日期文字（yyyy-MM-dd）的 locale，App 里传跟随应用语言的那个。
    ///   - calendar: 按天分组用的日历（时区同时用于日期文字），默认本地。
    ///   - projectBucket: 项目路径 → 这一行的 id 与显示名（各模块各有取项目名的办法）。
    ///     模型 id 为空的用量归到 "unknown"。
    static func buildReport(
        from entries: [CLIUsageEntry],
        order: CLIUsageReportOrder,
        locale: Locale,
        calendar: Calendar = .current,
        projectBucket: (String) -> (id: String, label: String)
    ) -> Report {
        var report = Report()

        var byDay: [Date: Totals] = [:]
        var byProject: [String: Totals] = [:]
        var byModel: [String: Totals] = [:]

        let dayFormatter = DateFormatter()
        dayFormatter.locale = locale
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"

        for entry in entries {
            let dayKey = calendar.startOfDay(for: entry.timestamp)
            var day = byDay[dayKey] ?? .zero
            day.add(entry)
            byDay[dayKey] = day

            var proj = byProject[entry.projectPath] ?? .zero
            proj.add(entry)
            byProject[entry.projectPath] = proj

            let modelLabel = entry.modelID.isEmpty ? "unknown" : entry.modelID
            var model = byModel[modelLabel] ?? .zero
            model.add(entry)
            byModel[modelLabel] = model
        }

        report.byDay = byDay.map { key, value in
            Bucket(id: dayFormatter.string(from: key), label: dayFormatter.string(from: key), totals: value, date: key)
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        report.byProject = byProject.map { key, value in
            let row = projectBucket(key)
            return Bucket(id: row.id, label: row.label, totals: value, date: nil)
        }.sorted { ranksHigher($0, $1, order: order) }

        report.byModel = byModel.map { key, value in
            Bucket(id: key, label: key, totals: value, date: nil)
        }.sorted { ranksHigher($0, $1, order: order) }

        return report
    }

    /// 报表排序比较：`a` 是否应排在 `b` 前面（从大到小）。
    private static func ranksHigher(_ a: Bucket, _ b: Bucket, order: CLIUsageReportOrder) -> Bool {
        switch order {
        case .byCost: return a.totals.costUSD > b.totals.costUSD
        case .byTokens: return a.totals.totalTokens > b.totals.totalTokens
        }
    }

    // MARK: - 辅助

    /// 时间戳向下取整到整点（对齐 UTC 小时，稳定不随时区漂移）。
    static func floorToHour(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        let floored = (seconds / 3_600).rounded(.down) * 3_600
        return Date(timeIntervalSinceReferenceDate: floored)
    }
}
