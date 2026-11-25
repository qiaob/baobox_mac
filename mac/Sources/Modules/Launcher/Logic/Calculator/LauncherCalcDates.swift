import Foundation

// 日期句型（docs/launcher/TECH_DESIGN.md §7 第 2 种）：
//   锚点 [± N 天/周/个月/年 …] [是几号 / 是星期几]      今天 + 45 天 · today + 2 weeks · 下周五是几号 · 月底
//   N 天后 / N 周前 · in 3 days · 3 days ago            （锚点是今天）
//   日期 - 日期                                         2026-12-25 - today → 天数（并写出几周几天）
//   [离] 日期 还有几天 · days until 日期 · days since 日期
// 锚点：今天 / 明天 / 昨天 / 后天 / 前天、[下|本|这|上]周X（周一为一周第一天）、月底 / 年底、
//       2026-12-25、2026/12/25、[2026年]12月25日。
// 单独一个锚点只在它本身有意义时出结果（下周五、月底）；「今天」「周五」「2026-11-23」单独不出。
// 用调用方传入的日历（不是公历时换成公历）和时区；输出的日期带星期几。

enum LauncherCalcDates {
    enum Anchor: Equatable {
        case today, tomorrow, yesterday, dayAfterTomorrow, dayBeforeYesterday
        /// week：-1 上周 / 0 本周 / 1 下周；day：1 = 周一 … 7 = 周日；explicit：写了「下 / 本 / 上 / next…」。
        case weekday(week: Int, day: Int, explicit: Bool)
        case endOfMonth, endOfYear
        /// year 为 nil = 今年（「12月25日」）。
        case literal(year: Int?, month: Int, day: Int)
    }

    enum Unit: Equatable {
        case day, week, month, year
    }

    struct Offset: Equatable {
        let amount: Int
        let unit: Unit
    }

    struct Expr: Equatable {
        let anchor: Anchor
        var offsets: [Offset]
    }

    // MARK: - 词表

    private static let simpleAnchors: [String: Anchor] = [
        "今天": .today, "today": .today, "明天": .tomorrow, "tomorrow": .tomorrow,
        "昨天": .yesterday, "yesterday": .yesterday,
        "后天": .dayAfterTomorrow, "day after tomorrow": .dayAfterTomorrow, "the day after tomorrow": .dayAfterTomorrow,
        "前天": .dayBeforeYesterday, "day before yesterday": .dayBeforeYesterday,
        "the day before yesterday": .dayBeforeYesterday,
        "月底": .endOfMonth, "end of month": .endOfMonth, "end of the month": .endOfMonth,
        "年底": .endOfYear, "end of year": .endOfYear, "end of the year": .endOfYear,
    ]

    private static let weekdayAnchors: [String: Anchor] = {
        var table: [String: Anchor] = [:]
        let zhDays: [(String, Int)] = [("一", 1), ("二", 2), ("三", 3), ("四", 4), ("五", 5), ("六", 6), ("日", 7), ("天", 7)]
        let zhPrefixes: [(String, Int)] = [("下", 1), ("下个", 1), ("本", 0), ("这", 0), ("这个", 0), ("上", -1), ("上个", -1)]
        for stem in ["周", "星期", "礼拜"] {
            for (dayText, day) in zhDays {
                table[stem + dayText] = .weekday(week: 0, day: day, explicit: false)
                for (prefix, week) in zhPrefixes {
                    table[prefix + stem + dayText] = .weekday(week: week, day: day, explicit: true)
                }
            }
        }
        let enDays: [(String, Int)] = [
            ("monday", 1), ("mon", 1), ("tuesday", 2), ("tue", 2), ("tues", 2), ("wednesday", 3), ("wed", 3),
            ("thursday", 4), ("thu", 4), ("thur", 4), ("thurs", 4), ("friday", 5), ("fri", 5),
            ("saturday", 6), ("sat", 6), ("sunday", 7), ("sun", 7),
        ]
        for (name, day) in enDays {
            table[name] = .weekday(week: 0, day: day, explicit: false)
            table["next " + name] = .weekday(week: 1, day: day, explicit: true)
            table["this " + name] = .weekday(week: 0, day: day, explicit: true)
            table["last " + name] = .weekday(week: -1, day: day, explicit: true)
        }
        return table
    }()

    private static let anchorWords: [String: Anchor] = simpleAnchors.merging(weekdayAnchors) { first, _ in first }
    private static let anchorPhrases = Set(anchorWords.keys)

    private static let units: [String: Unit] = [
        "天": .day, "day": .day, "days": .day,
        "周": .week, "星期": .week, "个星期": .week, "礼拜": .week, "个礼拜": .week, "week": .week, "weeks": .week,
        "个月": .month, "month": .month, "months": .month,
        "年": .year, "year": .year, "years": .year,
    ]
    private static let unitPhrases = Set(units.keys)
    private static let later: Set<String> = ["后", "以后", "之后", "later", "from now"]
    private static let earlier: Set<String> = ["前", "以前", "之前", "ago"]
    private static let querySuffixes: Set<String> = [
        "是几号", "几号", "是星期几", "星期几", "是周几", "周几", "是礼拜几", "礼拜几", "是哪天", "哪天", "是哪一天", "哪一天",
        "是几月几号", "几月几号", "是几月几日", "是什么时候",
    ]
    private static let untilSuffixes: Set<String> = ["还有几天", "还有多少天", "还剩几天", "还剩多少天", "有几天", "有多少天"]
    private static let untilPrefixes: Set<String> = ["离", "距离", "距"]
    private static let englishUntil: Set<String> = ["days until", "days till", "days left until"]
    private static let englishSince: Set<String> = ["days since"]

    static let cjkWords: Set<String> = {
        var words: Set<String> = ["年", "月", "日", "号"]
        let all = Set(anchorWords.keys).union(units.keys).union(later).union(earlier)
            .union(querySuffixes).union(untilSuffixes).union(untilPrefixes)
        for word in all where word.unicodeScalars.contains(where: LauncherCalcLexer.isCJK) { words.insert(word) }
        return words
    }()

    /// 加减的数量上限（天、周、月、年都按这个数）：再大就不是在算日期了。
    private static let maxAmount = 100_000

    // MARK: - 匹配

    static func match(_ tokens: [LauncherCalcToken], _ context: LauncherCalcContext) -> LauncherCalcResult? {
        var cursor = LauncherCalcCursor(tokens)
        let today = Expr(anchor: .today, offsets: [])
        if let phrase = cursor.take(phraseIn: englishUntil.union(englishSince), maxTokens: 3) {
            guard let target = expression(&cursor), cursor.atEnd else { return nil }
            return englishSince.contains(phrase)
                ? difference(today, minus: target, context: context)
                : difference(target, minus: today, context: context)
        }
        let hasUntilPrefix = cursor.take(phraseIn: untilPrefixes, maxTokens: 1) != nil
        guard let first = expression(&cursor) else { return nil }
        if !hasUntilPrefix, cursor.take(symbol: "-") {
            guard let second = expression(&cursor), cursor.atEnd else { return nil }
            return difference(first, minus: second, context: context)
        }
        guard let rest = cursor.takeRest(phraseIn: untilSuffixes.union(querySuffixes).union([""])) else { return nil }
        if untilSuffixes.contains(rest) { return difference(first, minus: today, context: context) }
        guard !hasUntilPrefix else { return nil }
        // 单独一个锚点：只有「下周五」「月底」这种本身就是在问日子的才出结果。
        if rest.isEmpty, first.offsets.isEmpty, !isSelfMeaningful(first.anchor) { return nil }
        return date(first, context: context)
    }

    private static func isSelfMeaningful(_ anchor: Anchor) -> Bool {
        switch anchor {
        case .weekday(_, _, let explicit): return explicit
        case .endOfMonth, .endOfYear: return true
        default: return false
        }
    }

    // MARK: - 解析

    private static func expression(_ cursor: inout LauncherCalcCursor) -> Expr? {
        // in 3 days
        var probe = cursor
        if probe.take(word: "in"), let offset = amountWithUnit(&probe, sign: 1) {
            cursor = probe
            return Expr(anchor: .today, offsets: [offset])
        }
        // 45 天后 · 3 周前 · 3 days ago · 3 days later
        probe = cursor
        if let offset = amountWithUnit(&probe, sign: 1),
           let direction = probe.take(phraseIn: later.union(earlier), maxTokens: 2) {
            cursor = probe
            let signed = earlier.contains(direction) ? Offset(amount: -offset.amount, unit: offset.unit) : offset
            return Expr(anchor: .today, offsets: [signed])
        }
        guard let anchor = anchor(&cursor) else { return nil }
        var expr = Expr(anchor: anchor, offsets: [])
        while true {
            probe = cursor
            let sign: Int
            if probe.take(symbol: "+") {
                sign = 1
            } else if probe.take(symbol: "-") {
                sign = -1
            } else {
                break
            }
            guard let offset = amountWithUnit(&probe, sign: sign) else { break }
            expr.offsets.append(offset)
            cursor = probe
        }
        return expr
    }

    private static func anchor(_ cursor: inout LauncherCalcCursor) -> Anchor? {
        guard let token = cursor.current else { return nil }
        if case .date(let year, let month, let day) = token.kind {
            cursor.advance()
            return .literal(year: year, month: month, day: day)
        }
        if let literal = chineseDate(&cursor) { return literal }
        guard let phrase = cursor.take(phraseIn: anchorPhrases, maxTokens: 4) else { return nil }
        return anchorWords[phrase]
    }

    /// `[2026年]12月25日` / `12月25号`。
    private static func chineseDate(_ cursor: inout LauncherCalcCursor) -> Anchor? {
        var probe = cursor
        var year: Int?
        if let value = probe.current?.decimalInteger, probe.peek(1)?.isWord("年") == true,
           let number = Int(value.description) {
            year = number
            probe.advance(2)
        }
        guard let monthValue = probe.current?.decimalInteger, probe.peek(1)?.isWord("月") == true,
              let dayValue = probe.peek(2)?.decimalInteger,
              probe.peek(3)?.isWord("日") == true || probe.peek(3)?.isWord("号") == true,
              let month = Int(monthValue.description), let day = Int(dayValue.description) else { return nil }
        probe.advance(4)
        cursor = probe
        return .literal(year: year, month: month, day: day)
    }

    private static func amountWithUnit(_ cursor: inout LauncherCalcCursor, sign: Int) -> Offset? {
        guard let value = cursor.current?.decimalInteger, let amount = Int(value.description),
              amount <= maxAmount else { return nil }
        var probe = cursor
        probe.advance()
        guard let phrase = probe.take(phraseIn: unitPhrases, maxTokens: 2), let unit = units[phrase] else { return nil }
        cursor = probe
        return Offset(amount: sign * amount, unit: unit)
    }

    // MARK: - 求值

    private struct Invalid: Error {}

    /// 解析出的表达式落到哪一天（当天 0 点）。日子不存在（2026-02-30）抛 Invalid；超出 1…9999 年抛 outOfRange。
    private static func resolve(_ expr: Expr, _ cal: Calendar, now: Date) throws -> Date {
        let today = cal.startOfDay(for: now)
        var date: Date
        switch expr.anchor {
        case .today: date = today
        case .tomorrow: date = try add(1, .day, to: today, cal)
        case .yesterday: date = try add(-1, .day, to: today, cal)
        case .dayAfterTomorrow: date = try add(2, .day, to: today, cal)
        case .dayBeforeYesterday: date = try add(-2, .day, to: today, cal)
        case .weekday(let week, let day, _):
            // 周一为一周第一天：Calendar 的 weekday 是 1 = 周日 … 7 = 周六。
            let todayIndex = (cal.component(.weekday, from: today) + 5) % 7 + 1
            date = try add(week * 7 + day - todayIndex, .day, to: today, cal)
        case .endOfMonth:
            guard let days = cal.range(of: .day, in: .month, for: today) else { throw Invalid() }
            var parts = cal.dateComponents([.year, .month], from: today)
            parts.day = days.count
            guard let end = cal.date(from: parts) else { throw Invalid() }
            date = end
        case .endOfYear:
            var parts = cal.dateComponents([.year], from: today)
            parts.month = 12
            parts.day = 31
            guard let end = cal.date(from: parts) else { throw Invalid() }
            date = end
        case .literal(let year, let month, let day):
            let resolvedYear = year ?? cal.component(.year, from: today)
            date = try literal(year: resolvedYear, month: month, day: day, cal)
        }
        for offset in expr.offsets {
            date = try add(offset.amount, offset.unit, to: date, cal)
        }
        return date
    }

    private static func literal(year: Int, month: Int, day: Int, _ cal: Calendar) throws -> Date {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { throw Invalid() }
        let wanted = DateComponents(year: year, month: month, day: day)
        guard let date = cal.date(from: wanted) else { throw Invalid() }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { throw Invalid() }
        return date
    }

    private static func add(_ amount: Int, _ unit: Unit, to date: Date, _ cal: Calendar) throws -> Date {
        let component: Calendar.Component
        var value = amount
        switch unit {
        case .day: component = .day
        case .week: component = .day; value = amount * 7
        case .month: component = .month
        case .year: component = .year
        }
        guard let result = cal.date(byAdding: component, value: value, to: date),
              (1...9999).contains(cal.component(.year, from: result)) else { throw LauncherCalcFailure.outOfRange }
        return result
    }

    // MARK: - 输出

    private static func date(_ expr: Expr, context: LauncherCalcContext) -> LauncherCalcResult? {
        let cal = context.gregorian
        let interpretation = render(expr, cal, context)
        do {
            let date = try resolve(expr, cal, now: context.now)
            let parts = cal.dateComponents([.year, .month, .day, .weekday], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day,
                  let weekday = parts.weekday else { return nil }
            let display = context.prefersChinese
                ? "\(year)年\(month)月\(day)日 \(LauncherCalcCalendarText.weekdayZh(weekday))"
                : "\(LauncherCalcCalendarText.weekdayEn(weekday)), \(LauncherCalcCalendarText.monthEn(month)) \(day), \(year)"
            return .value(.date, display: display, copy: iso(year, month, day), interpretation: interpretation)
        } catch let failure as LauncherCalcFailure {
            return .failed(.date, failure, interpretation: interpretation, context: context)
        } catch {
            return nil
        }
    }

    private static func difference(_ lhs: Expr, minus rhs: Expr, context: LauncherCalcContext) -> LauncherCalcResult? {
        let cal = context.gregorian
        let interpretation = "\(render(lhs, cal, context)) - \(render(rhs, cal, context))"
        do {
            let end = try resolve(lhs, cal, now: context.now)
            let start = try resolve(rhs, cal, now: context.now)
            guard let days = cal.dateComponents([.day], from: start, to: end).day else { return nil }
            return .value(.date, display: daysText(days, context), copy: String(days), interpretation: interpretation)
        } catch let failure as LauncherCalcFailure {
            return .failed(.date, failure, interpretation: interpretation, context: context)
        } catch {
            return nil
        }
    }

    /// `32 天（4 周 4 天）` / `32 days (4 weeks 4 days)`：不满一周不写括号。
    private static func daysText(_ days: Int, _ context: LauncherCalcContext) -> String {
        let total = LauncherCalcFormat.grouped(Int64(days))
        let weeks = Swift.abs(days) / 7
        let rest = Swift.abs(days) % 7
        if context.prefersChinese {
            guard weeks > 0 else { return "\(total) 天" }
            return "\(total) 天（\(weeks) 周" + (rest > 0 ? " \(rest) 天" : "") + "）"
        }
        let head = "\(total) \(Swift.abs(days) == 1 ? "day" : "days")"
        guard weeks > 0 else { return head }
        let restText = rest > 0 ? " \(rest) \(rest == 1 ? "day" : "days")" : ""
        return "\(head) (\(weeks) \(weeks == 1 ? "week" : "weeks")\(restText))"
    }

    private static func iso(_ year: Int, _ month: Int, _ day: Int) -> String {
        let yearText = String(year)
        let padded = String(repeating: "0", count: max(0, 4 - yearText.count)) + yearText
        return "\(padded)-\(LauncherCalcFormat.twoDigits(month))-\(LauncherCalcFormat.twoDigits(day))"
    }

    /// 「理解成了什么」：锚点用标准叫法，加减写成 `+ 45 天`。
    private static func render(_ expr: Expr, _ cal: Calendar, _ context: LauncherCalcContext) -> String {
        var text = renderAnchor(expr.anchor, cal, context)
        for offset in expr.offsets {
            let sign = offset.amount < 0 ? "-" : "+"
            text += " \(sign) \(renderAmount(Swift.abs(offset.amount), offset.unit, context))"
        }
        return text
    }

    private static func renderAnchor(_ anchor: Anchor, _ cal: Calendar, _ context: LauncherCalcContext) -> String {
        switch anchor {
        case .today: return context.text("今天", "today")
        case .tomorrow: return context.text("明天", "tomorrow")
        case .yesterday: return context.text("昨天", "yesterday")
        case .dayAfterTomorrow: return context.text("后天", "the day after tomorrow")
        case .dayBeforeYesterday: return context.text("前天", "the day before yesterday")
        case .endOfMonth: return context.text("月底", "end of month")
        case .endOfYear: return context.text("年底", "end of year")
        case .weekday(let week, let day, let explicit):
            if context.prefersChinese {
                let prefix = !explicit ? "周" : (week > 0 ? "下周" : (week < 0 ? "上周" : "本周"))
                return prefix + LauncherCalcCalendarText.weekdayZhShortSuffix(day)
            }
            let name = LauncherCalcCalendarText.weekdayEnFull(day)
            guard explicit else { return name }
            return (week > 0 ? "next " : (week < 0 ? "last " : "this ")) + name
        case .literal(let year, let month, let day):
            return iso(year ?? cal.component(.year, from: context.now), month, day)
        }
    }

    private static func renderAmount(_ amount: Int, _ unit: Unit, _ context: LauncherCalcContext) -> String {
        if context.prefersChinese {
            switch unit {
            case .day: return "\(amount) 天"
            case .week: return "\(amount) 周"
            case .month: return "\(amount) 个月"
            case .year: return "\(amount) 年"
            }
        }
        let name: String
        switch unit {
        case .day: name = "day"
        case .week: name = "week"
        case .month: name = "month"
        case .year: name = "year"
        }
        return "\(amount) \(name)\(amount == 1 ? "" : "s")"
    }
}
