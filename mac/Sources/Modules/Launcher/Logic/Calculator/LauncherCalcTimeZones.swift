import Foundation

// 时区句型（docs/launcher/TECH_DESIGN.md §7 第 2 种）：
//   某地现在几点：东京现在几点 · 现在东京几点 · 北京时间 · time in tokyo · tokyo time · now in UTC+8
//   换算：[甲地] 时刻 [甲地] [to | in | 是 | 换成] [乙地] [几点]
//         下午 3 点 新加坡 北京（新加坡的下午 3 点是北京几点）· 15:00 SGT in PST · 3pm in tokyo
//   只写一个地方时，另一边是本地（调用方传入的时区）：写在连接词后面的是目标，否则是出发地。
// 时刻：15:00、3pm、3:30 pm、下午3点、下午3点半、上午10点20分、15点。日期按出发地的「今天」。
// 地名、缩写、UTC 偏移、IANA 名见 LauncherCalcPlaces。

enum LauncherCalcTimeZones {
    private enum Period {
        case morning, earlyMorning, noon, afternoon, evening
    }

    private static let periods: [String: Period] = [
        "上午": .morning, "早上": .morning, "早晨": .morning, "凌晨": .earlyMorning, "中午": .noon,
        "下午": .afternoon, "傍晚": .afternoon, "晚上": .evening, "夜里": .evening,
    ]
    private static let nowLeading: Set<String> = [
        "time in", "current time in", "what time is it in", "what time in", "now in", "local time in", "time now in", "现在",
    ]
    private static let nowTrailing: Set<String> = [
        "", "time", "now", "local time", "current time", "time now",
        "几点", "几点了", "几点钟", "现在几点", "现在几点了", "现在几点钟", "是几点", "现在是几点", "现在是几点了",
        "时间", "现在时间", "的时间", "现在的时间", "什么时间", "现在什么时间", "当地时间", "现在", "现在是",
    ]
    private static let connectors: Set<String> = ["to", "in", "into", "转", "换成", "转换成", "是", "在", "等于", "对应"]
    private static let conversionTrailing: Set<String> = [
        "", "几点", "几点了", "几点钟", "是几点", "是几点钟", "时间", "的时间", "什么时间", "是什么时间", "time",
    ]

    static let cjkWords: Set<String> = {
        var words: Set<String> = ["点", "点钟", "时", "分", "半"]
        words.formUnion(periods.keys)
        words.formUnion(LauncherCalcPlaces.cjkNames)
        for word in nowLeading.union(nowTrailing).union(connectors).union(conversionTrailing)
            where word.unicodeScalars.contains(where: LauncherCalcLexer.isCJK) {
            words.insert(word)
        }
        return words
    }()

    static func match(_ tokens: [LauncherCalcToken], _ context: LauncherCalcContext) -> LauncherCalcResult? {
        nowQuery(tokens, context) ?? conversion(tokens, context)
    }

    // MARK: - 某地现在几点

    private static func nowQuery(_ tokens: [LauncherCalcToken], _ context: LauncherCalcContext) -> LauncherCalcResult? {
        var cursor = LauncherCalcCursor(tokens)
        let lead = cursor.take(phraseIn: nowLeading, maxTokens: 5)
        guard let zone = LauncherCalcPlaces.zone(&cursor),
              let trail = cursor.takeRest(phraseIn: nowTrailing),
              lead != nil || !trail.isEmpty else { return nil }
        let offset = LauncherCalcPlaces.offsetLabel(zone.timeZone.secondsFromGMT(for: context.now))
        let interpretation: String
        // 名字是英文（缩写、IANA 名）时和「现在」之间空一格；名字本身就是 UTC 偏移时不再重复写偏移。
        let zhName = zone.zh.unicodeScalars.last?.isASCII == true ? "\(zone.zh) " : zone.zh
        if zone.zh.hasPrefix("UTC") {
            interpretation = context.text("\(zhName)现在", "Now in \(zone.en)")
        } else {
            interpretation = context.text("\(zhName)现在（\(offset)）", "Now in \(zone.en) (\(offset))")
        }
        var localCal = context.gregorian
        localCal.timeZone = context.timeZone
        let reference = localCal.dateComponents([.year, .month, .day], from: context.now)
        return output(context.now, in: zone, referenceDay: reference, interpretation: interpretation, context: context)
    }

    // MARK: - 换算

    private static func conversion(_ tokens: [LauncherCalcToken], _ context: LauncherCalcContext) -> LauncherCalcResult? {
        var cursor = LauncherCalcCursor(tokens)
        var source = LauncherCalcPlaces.zone(&cursor)
        guard let (hour, minute) = time(&cursor) else { return nil }
        if source == nil { source = LauncherCalcPlaces.zone(&cursor) }
        if !cursor.take(symbol: "=") { _ = cursor.take(phraseIn: connectors, maxTokens: 2) }
        let target = LauncherCalcPlaces.zone(&cursor)
        guard source != nil || target != nil, cursor.takeRest(phraseIn: conversionTrailing) != nil else { return nil }

        let local = LauncherCalcZone(timeZone: context.timeZone, zh: "本地", en: "Local")
        let from = source ?? local
        let to = target ?? local
        var fromCal = context.gregorian
        fromCal.timeZone = from.timeZone
        let day = fromCal.dateComponents([.year, .month, .day], from: context.now)
        var wanted = day
        wanted.hour = hour
        wanted.minute = minute
        wanted.second = 0
        guard let instant = fromCal.date(from: wanted) else { return nil }
        let clock = "\(LauncherCalcFormat.twoDigits(hour)):\(LauncherCalcFormat.twoDigits(minute))"
        let interpretation = "\(clock) \(label(from, at: instant, context)) → \(label(to, at: instant, context))"
        return output(instant, in: to, referenceDay: day, interpretation: interpretation, context: context)
    }

    /// 读一个时刻，返回 24 小时制的时和分；读不到不前进。
    private static func time(_ cursor: inout LauncherCalcCursor) -> (Int, Int)? {
        var probe = cursor
        let period = probe.current?.word.flatMap { periods[$0] }
        if period != nil { probe.advance() }
        var hour: Int
        var minute = 0
        if case .clock(let h, let m)? = probe.current?.kind {
            hour = h
            minute = m
            probe.advance()
        } else if let value = probe.current?.decimalInteger, let h = Int(value.description) {
            hour = h
            probe.advance()
            if probe.take(word: "点") || probe.take(word: "点钟") || probe.take(word: "时") {
                if probe.take(word: "半") {
                    minute = 30
                } else if let minuteValue = probe.current?.decimalInteger, let m = Int(minuteValue.description) {
                    probe.advance()
                    _ = probe.take(word: "分")
                    minute = m
                }
            } else if period != nil || !(probe.current?.isWord("am") == true || probe.current?.isWord("pm") == true) {
                return nil
            }
        } else {
            return nil
        }
        var meridiem: String?
        if period == nil, let word = probe.current?.word, word == "am" || word == "pm" {
            meridiem = word
            probe.advance()
        }
        guard (0...59).contains(minute), let resolved = resolveHour(hour, period: period, meridiem: meridiem) else {
            return nil
        }
        cursor = probe
        return (resolved, minute)
    }

    private static func resolveHour(_ hour: Int, period: Period?, meridiem: String?) -> Int? {
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            return meridiem == "am" ? hour % 12 : hour % 12 + 12
        }
        guard let period else { return (0...23).contains(hour) ? hour : nil }
        switch period {
        case .morning:
            return (0...12).contains(hour) ? hour : nil
        case .earlyMorning:
            return (0...12).contains(hour) ? hour % 12 : nil
        case .noon:
            guard (1...12).contains(hour) else { return nil }
            return hour < 11 ? hour + 12 : hour
        case .afternoon:
            if (13...23).contains(hour) { return hour }
            return (1...12).contains(hour) ? hour % 12 + 12 : nil
        case .evening:
            if (13...23).contains(hour) { return hour }
            guard (1...12).contains(hour) else { return nil }
            if hour == 12 { return 0 }
            return hour >= 6 ? hour + 12 : hour
        }
    }

    // MARK: - 输出

    /// `东京（UTC+9）`；名字本身就是 UTC 偏移时不重复写。
    private static func label(_ zone: LauncherCalcZone, at instant: Date, _ context: LauncherCalcContext) -> String {
        let name = zone.name(context)
        if name.hasPrefix("UTC") { return name }
        let offset = LauncherCalcPlaces.offsetLabel(zone.timeZone.secondsFromGMT(for: instant))
        return context.text("\(name)（\(offset)）", "\(name) (\(offset))")
    }

    /// `11:00 · 11月23日 周一`、`23:00 · 11月22日 周日（前一天）` / `23:00 · Sun, Nov 22 (previous day)`。
    private static func output(_ instant: Date, in zone: LauncherCalcZone, referenceDay: DateComponents,
                               interpretation: String, context: LauncherCalcContext) -> LauncherCalcResult? {
        var cal = context.gregorian
        cal.timeZone = zone.timeZone
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: instant)
        guard let year = parts.year, let month = parts.month, let day = parts.day, let hour = parts.hour,
              let minute = parts.minute, let weekday = parts.weekday else { return nil }
        let clock = "\(LauncherCalcFormat.twoDigits(hour)):\(LauncherCalcFormat.twoDigits(minute))"
        let shift = dayShift(from: referenceDay, to: DateComponents(year: year, month: month, day: day))
        let display: String
        if context.prefersChinese {
            display = "\(clock) · \(month)月\(day)日 \(LauncherCalcCalendarText.weekdayZhShort(weekday))\(shiftText(shift, context))"
        } else {
            display = "\(clock) · \(LauncherCalcCalendarText.weekdayEn(weekday)), "
                + "\(LauncherCalcCalendarText.monthEn(month)) \(day)\(shiftText(shift, context))"
        }
        return .value(.timeZone, display: display, copy: clock, interpretation: interpretation)
    }

    /// 两个日子差几天（按 UTC 公历算日序，与时区无关）。
    private static func dayShift(from start: DateComponents, to end: DateComponents) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? utc.timeZone
        guard let a = utc.date(from: DateComponents(year: start.year, month: start.month, day: start.day)),
              let b = utc.date(from: DateComponents(year: end.year, month: end.month, day: end.day)) else { return 0 }
        return utc.dateComponents([.day], from: a, to: b).day ?? 0
    }

    private static func shiftText(_ shift: Int, _ context: LauncherCalcContext) -> String {
        switch shift {
        case 0: return ""
        case 1: return context.text("（后一天）", " (next day)")
        case -1: return context.text("（前一天）", " (previous day)")
        default:
            let signed = shift > 0 ? "+\(shift)" : "\(shift)"
            return context.text("（\(signed) 天）", " (\(signed) days)")
        }
    }
}
