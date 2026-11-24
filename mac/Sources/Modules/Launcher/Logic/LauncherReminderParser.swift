import Foundation

// 带时间的句子（docs/launcher/TECH_DESIGN.md §5.4「带时间的句子」、§5.6）：「20 分钟后提醒我取快递」「明天下午三点开会」
// 「in 20 minutes stretch」—— 解析出一个将来的时间点和一段事由，列表最前面出「14:35 提醒我：取快递」。
// 规则解析，不用 AI：句子开头是时间（可以先写「提醒我」/ remind me），后面是事由；英文还认事由在前、`in 20 minutes` 在最后。
// 认的时间：
//   相对    N 分钟后 · N 小时后 · N 个半小时后 · 半小时后 · 一刻钟后 · 过 N 分钟 · in 20 minutes · in an hour · in half an hour
//   绝对    [今天|明天|后天|大后天|今晚|明早|明晚|周五|下周五|星期五|tomorrow|tonight|friday…] [上午|下午|晚上…] [at]
//           三点 · 三点半 · 三点一刻 · 三点十五(分) · 15:30 · 3pm · 3:30 pm（至少要有钟点）
// 已经过去的时间、解析不出来的、没有事由的都不算。「现在」、日历、时区由调用方传入（`LauncherCalcContext`），测试里写死。
// 星期几的写法和「某个锚点是哪一天」用计算引擎的（`LauncherCalcDates`）。纯函数、只依赖 Foundation，进 BaoboxTests。

/// 解析出来的一条提醒（还没设）。
struct LauncherReminderDraft: Equatable, Sendable {
    /// 到点的时刻（钟点写法的秒为 0；「20 分钟后」是从现在起正好 20 分钟）。
    let date: Date
    /// 事由（去掉了时间那部分和「提醒我」）。
    let text: String
}

enum LauncherReminderParser {
    /// 再长就不认（一句提醒不会这么长）。
    static let maxLength = 120
    /// 相对时间最多这么多分钟（一年）：再大就不是在设提醒了。
    static let maxRelativeMinutes = 60 * 24 * 365

    /// 解析；不是一句带时间的话为 nil。
    static func parse(_ input: String, context: LauncherCalcContext) -> LauncherReminderDraft? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxLength * 4, trimmed.count <= maxLength,
              !trimmed.contains(where: \.isNewline) else { return nil }
        let text = ReminderText(trimmed)
        let cal = context.gregorian
        var start = 0
        text.skipSpaces(&start)
        text.skipFillers(&start)
        if text.take("在", at: &start) { text.skipSpaces(&start) }
        if let (date, end) = relative(text, at: start, now: context.now, cal: cal)
            ?? absolute(text, at: start, now: context.now, cal: cal) {
            return draft(date: date, event: text.event(from: end, to: text.count))
        }
        // 英文：事由在前，`in 20 minutes` 在最后（remind me to call mom in 20 minutes）。
        if let (date, timeStart) = trailingRelative(text, from: start, now: context.now, cal: cal) {
            return draft(date: date, event: text.event(from: start, to: timeStart))
        }
        return nil
    }

    private static func draft(date: Date, event: String) -> LauncherReminderDraft? {
        event.isEmpty ? nil : LauncherReminderDraft(date: date, text: event)
    }

    // MARK: - 相对时间

    /// `N 分钟后`、`半小时后`、`一刻钟后`、`过 N 分钟`、`in 20 minutes`：从 `index` 开始，返回时刻和时间那部分的结尾。
    private static func relative(_ text: ReminderText, at index: Int, now: Date, cal: Calendar) -> (Date, Int)? {
        if let (minutes, end) = chineseRelative(text, at: index) ?? englishRelative(text, at: index) {
            guard minutes > 0, minutes <= Double(maxRelativeMinutes) else { return nil }
            return (now.addingTimeInterval(minutes * 60), end)
        }
        return nil
    }

    private static func chineseRelative(_ text: ReminderText, at index: Int) -> (Double, Int)? {
        var j = index
        let pass = text.take("过", at: &j)
        text.skipSpaces(&j)
        var minutes: Double
        if text.takeAny(["半个小时", "半小时", "半个钟头", "半钟头"], at: &j) != nil {
            minutes = 30
        } else if text.takeAny(["一刻钟", "一刻"], at: &j) != nil {
            minutes = 15
        } else if text.takeAny(["三刻钟"], at: &j) != nil {
            minutes = 45
        } else if let amount = text.decimal(at: &j) {
            text.skipSpaces(&j)
            _ = text.take("个", at: &j)
            let half = text.take("半", at: &j)
            text.skipSpaces(&j)
            if text.take("分钟", at: &j) {
                guard !half else { return nil }
                minutes = amount
            } else if text.takeAny(["小时", "钟头"], at: &j) != nil {
                minutes = amount * 60 + (half ? 30 : 0)
            } else {
                return nil
            }
        } else {
            return nil
        }
        text.skipSpaces(&j)
        let later = text.takeAny(["以后", "之后", "后"], at: &j) != nil
        guard later || pass else { return nil }
        return (minutes, j)
    }

    private static let englishMinuteUnits = ["minutes", "minute", "mins", "min", "m"]
    private static let englishHourUnits = ["hours", "hour", "hrs", "hr", "h"]

    private static func englishRelative(_ text: ReminderText, at index: Int) -> (Double, Int)? {
        var j = index
        guard text.take("in ", at: &j) else { return nil }
        text.skipSpaces(&j)
        if text.takeWord(["half an hour", "half a hour"], at: &j) != nil { return (30, j) }
        if text.takeWord(["an hour", "a hour"], at: &j) != nil { return (60, j) }
        if text.takeWord(["a minute"], at: &j) != nil { return (1, j) }
        guard let amount = text.decimal(at: &j) else { return nil }
        text.skipSpaces(&j)
        if text.takeWord(englishMinuteUnits, at: &j) != nil { return (amount, j) }
        if text.takeWord(englishHourUnits, at: &j) != nil { return (amount * 60, j) }
        return nil
    }

    /// 英文事由在前、`in N minutes` 在句末：找最后一个 ` in `，从它开始正好吃到句末才算。返回时刻和 `in` 的位置。
    private static func trailingRelative(_ text: ReminderText, from start: Int, now: Date,
                                         cal: Calendar) -> (Date, Int)? {
        guard let position = text.lastIndex(of: " in ", from: start) else { return nil }
        let timeStart = position + 1
        guard let (date, end) = relative(text, at: timeStart, now: now, cal: cal) else { return nil }
        var tail = end
        text.skipSpacesAndPunctuation(&tail)
        return tail == text.count ? (date, timeStart) : nil
    }

    // MARK: - 绝对时间

    /// 哪一天。
    private enum Day {
        case offset(Int)
        /// 星期几（计算引擎的锚点）；explicit = 写了「下 / 本 / 上 / next…」。没写的：这一天已经过去就是下一周的。
        case weekday(LauncherCalcDates.Anchor, explicit: Bool)
    }

    /// 上午、下午……：决定钟点怎么换成 24 小时。
    private enum Period {
        case earlyMorning, morning, noon, afternoon, evening
    }

    private static let dayWords: [(String, Day, Period?)] = {
        var words: [(String, Day, Period?)] = [
            ("今天", .offset(0), nil), ("明天", .offset(1), nil), ("后天", .offset(2), nil), ("大后天", .offset(3), nil),
            ("今晚", .offset(0), .evening), ("明晚", .offset(1), .evening), ("今早", .offset(0), .morning),
            ("明早", .offset(1), .morning), ("today", .offset(0), nil), ("tomorrow", .offset(1), nil),
            ("tonight", .offset(0), .evening),
        ]
        for (phrase, anchor) in LauncherCalcDates.weekdayAnchors {
            guard case .weekday(_, _, let explicit) = anchor else { continue }
            words.append((phrase, .weekday(anchor, explicit: explicit), nil))
        }
        return words.sorted { $0.0.count > $1.0.count }
    }()

    private static let periodWords: [(String, Period)] = [
        ("凌晨", .earlyMorning), ("早上", .morning), ("早晨", .morning), ("上午", .morning), ("中午", .noon),
        ("下午", .afternoon), ("傍晚", .afternoon), ("晚上", .evening), ("夜里", .evening),
    ]

    private static func absolute(_ text: ReminderText, at index: Int, now: Date, cal: Calendar) -> (Date, Int)? {
        var j = index
        var day = Day.offset(0)
        var period: Period?
        if let (word, matchedDay, matchedPeriod) = dayWords.first(where: { text.hasWord($0.0, at: j) }) {
            j += word.count
            day = matchedDay
            period = matchedPeriod
        }
        text.skipSpaces(&j)
        if period == nil, let (word, matched) = periodWords.first(where: { text.has($0.0, at: j) }) {
            j += word.count
            period = matched
            text.skipSpaces(&j)
        }
        let sawAt = text.takeWord(["at"], at: &j) != nil
        text.skipSpaces(&j)
        guard let clock = clockTime(text, at: &j, bareHourAllowed: sawAt),
              let hours = candidateHours(clock, period: period),
              let dayStart = dayStart(day, now: now, cal: cal) else { return nil }
        for hour in hours {
            if let date = time(hour: hour, minute: clock.minute, on: dayStart, cal: cal), date > now { return (date, j) }
        }
        // 没写「下 / 本」的星期几已经过去（今天周三说「周一」、或今天说「周三上午九点」而已经十点了）：下一周的同一天。
        if case .weekday(_, explicit: false) = day, let hour = hours.first,
           let nextWeek = cal.date(byAdding: .day, value: 7, to: dayStart),
           let date = time(hour: hour, minute: clock.minute, on: nextWeek, cal: cal), date > now {
            return (date, j)
        }
        return nil
    }

    private static func dayStart(_ day: Day, now: Date, cal: Calendar) -> Date? {
        switch day {
        case .offset(let days):
            return cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: now))
        case .weekday(let anchor, _):
            return LauncherCalcDates.day(of: anchor, calendar: cal, now: now)
        }
    }

    /// 当天的 `hour:minute`（`hour` 可以是 24 = 第二天 0 点）。
    private static func time(hour: Int, minute: Int, on dayStart: Date, cal: Calendar) -> Date? {
        guard (0...24).contains(hour), (0...59).contains(minute) else { return nil }
        if hour == 24 {
            guard minute == 0, let next = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            return next
        }
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: dayStart)
    }

    /// 读出来的钟点。
    private struct Clock {
        let hour: Int
        let minute: Int
        /// `am` / `pm`：nil = 没写。
        var meridiem: Bool?
        /// 写成 `15:30` 的（按 24 小时算，不猜上午下午）。
        var colon = false
    }

    /// 钟点：`15:30`、`3:30 pm`、`3pm`、`三点`、`三点半`、`三点一刻`、`三点十五(分)`、`3 点 05`；`bareHourAllowed`（前面写了 at）时
    /// 单独一个数也算（`at 3`）。「三点五」这种分说不清的不认。
    private static func clockTime(_ text: ReminderText, at j: inout Int, bareHourAllowed: Bool) -> Clock? {
        var k = j
        guard let hour = text.integer(at: &k, maxDigits: 2) else { return nil }
        // 15:30 / 3:30 pm
        var colonEnd = k
        if text.take(":", at: &colonEnd), let minute = text.integer(at: &colonEnd, exactDigits: 2) {
            var after = colonEnd
            text.skipSpaces(&after)
            if let meridiem = meridiem(text, at: &after) {
                j = after
                return Clock(hour: hour, minute: minute, meridiem: meridiem)
            }
            j = colonEnd
            return Clock(hour: hour, minute: minute, colon: true)
        }
        var afterNumber = k
        text.skipSpaces(&afterNumber)
        // 3pm / 3 pm
        if let meridiem = meridiem(text, at: &afterNumber) {
            j = afterNumber
            return Clock(hour: hour, minute: 0, meridiem: meridiem)
        }
        // 三点…
        if text.take("点", at: &afterNumber) {
            _ = text.take("钟", at: &afterNumber)
            var m = afterNumber
            text.skipSpaces(&m)
            if text.take("半", at: &m) {
                j = m
                return Clock(hour: hour, minute: 30)
            }
            if text.take("一刻", at: &m) {
                j = m
                return Clock(hour: hour, minute: 15)
            }
            if text.take("三刻", at: &m) {
                j = m
                return Clock(hour: hour, minute: 45)
            }
            let leadingZero = text.has("零", at: m) || text.has("〇", at: m) || text.has("0", at: m)
            var digitsEnd = m
            if let minute = text.integer(at: &digitsEnd, maxDigits: 2) {
                let digitCount = digitsEnd - m
                var end = digitsEnd
                text.skipSpaces(&end)
                let unit = text.take("分", at: &end)
                // 「三点十五」「3 点 05」「三点零五」「三点五分」认；「三点五」（是 3:05 还是 3:50？）不认。
                guard unit || leadingZero || minute >= 10 || digitCount >= 2 else { return nil }
                j = unit ? end : digitsEnd
                return Clock(hour: hour, minute: minute)
            }
            j = afterNumber
            return Clock(hour: hour, minute: 0)
        }
        if bareHourAllowed {
            j = k
            return Clock(hour: hour, minute: 0)
        }
        return nil
    }

    /// `am` / `pm` / `a.m.` / `p.m.`：true = 下午。
    private static func meridiem(_ text: ReminderText, at j: inout Int) -> Bool? {
        if text.takeWord(["a.m.", "am"], at: &j) != nil { return false }
        if text.takeWord(["p.m.", "pm"], at: &j) != nil { return true }
        return nil
    }

    /// 钟点换成 24 小时（几个候选按顺序试，第一个在将来的算）：
    /// - 写了 am / pm：12 小时制。
    /// - 写了上午 / 下午……：下午、傍晚、晚上的 1–11 点加 12；中午的 1–3 点加 12；晚上 12 点是第二天 0 点。
    /// - 写成 `15:30`：就是这个钟点。
    /// - 都没写：13 点以后、0 点、12 点照写的；1–6 点当成下午（很少有人设凌晨的提醒）；7–11 点先当上午，已经过了再当晚上。
    private static func candidateHours(_ clock: Clock, period: Period?) -> [Int]? {
        let h = clock.hour
        if let pm = clock.meridiem {
            guard (1...12).contains(h) else { return nil }
            return [h % 12 + (pm ? 12 : 0)]
        }
        if let period {
            switch period {
            case .earlyMorning:
                return (0...6).contains(h) ? [h] : (h == 12 ? [0] : nil)
            case .morning:
                return (0...12).contains(h) ? [h] : nil
            case .noon:
                if h == 11 || h == 12 { return [h] }
                return (1...3).contains(h) ? [h + 12] : nil
            case .afternoon:
                if (1...11).contains(h) { return [h + 12] }
                return (12...23).contains(h) ? [h] : nil
            case .evening:
                if (1...11).contains(h) { return [h + 12] }
                if h == 12 { return [24] }
                return (13...23).contains(h) ? [h] : nil
            }
        }
        guard (0...24).contains(h) else { return nil }
        if clock.colon { return h == 24 ? nil : [h] }
        switch h {
        case 1...6: return [h + 12]
        case 7...11: return [h, h + 12]
        default: return [h]
        }
    }
}

// MARK: - 扫描

/// 一段输入，按字符扫描。全角数字、冒号、空格换成半角（`original`，事由从这里取，大小写不变）；匹配用 `lower`（英文字母变小写）。
private struct ReminderText {
    let original: [Character]
    let lower: [Character]

    init(_ text: String) {
        var original: [Character] = []
        var lower: [Character] = []
        for character in text {
            let normalized = Self.halfWidth(character)
            original.append(normalized)
            lower.append(normalized.isASCII ? Character(normalized.lowercased()) : normalized)
        }
        self.original = original
        self.lower = lower
    }

    private static func halfWidth(_ character: Character) -> Character {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return character }
        switch scalar.value {
        case 0xFF10...0xFF19:
            return Character(Unicode.Scalar(scalar.value - 0xFF10 + 0x30) ?? scalar)
        case 0xFF1A: return ":"
        case 0x3000: return " "
        default: return character
        }
    }

    var count: Int { lower.count }

    func has(_ word: String, at index: Int) -> Bool {
        var i = index
        for character in word {
            guard i < lower.count, lower[i] == character else { return false }
            i += 1
        }
        return true
    }

    /// 同 `has`，但以英文字母结尾的词后面不能紧跟英文字母（`mon` 不吃 `monitor` 的开头）。
    func hasWord(_ word: String, at index: Int) -> Bool {
        guard has(word, at: index) else { return false }
        guard let last = word.last, last.isASCII, last.isLetter else { return true }
        let after = index + word.count
        return after >= lower.count || !(lower[after].isASCII && lower[after].isLetter)
    }

    func take(_ word: String, at index: inout Int) -> Bool {
        guard has(word, at: index) else { return false }
        index += word.count
        return true
    }

    func takeAny(_ words: [String], at index: inout Int) -> String? {
        guard let word = words.first(where: { has($0, at: index) }) else { return nil }
        index += word.count
        return word
    }

    func takeWord(_ words: [String], at index: inout Int) -> String? {
        guard let word = words.first(where: { hasWord($0, at: index) }) else { return nil }
        index += word.count
        return word
    }

    func skipSpaces(_ index: inout Int) {
        while index < lower.count, lower[index] == " " || lower[index] == "\t" { index += 1 }
    }

    static let punctuation: Set<Character> = ["，", ",", "、", "。", ".", "！", "!", "？", "?", "：", ":", "；", ";", "~", "～", "-", "—"]

    func skipSpacesAndPunctuation(_ index: inout Int) {
        while index < lower.count, lower[index] == " " || lower[index] == "\t" || Self.punctuation.contains(lower[index]) {
            index += 1
        }
    }

    /// 开头 / 时间后面的「提醒我」「叫我」「remind me to」「to」，可以连着几个。
    func skipFillers(_ index: inout Int) {
        while true {
            skipSpacesAndPunctuation(&index)
            if takeAny(["提醒我", "提醒一下我", "提醒", "叫我", "通知我"], at: &index) != nil { continue }
            if takeWord(["remind me to", "remind me", "to"], at: &index) != nil { continue }
            return
        }
    }

    /// 最后一个 `needle`（小写）的位置，不早于 `start`。
    func lastIndex(of needle: String, from start: Int) -> Int? {
        let length = needle.count
        guard length > 0, lower.count - length >= start else { return nil }
        for position in stride(from: lower.count - length, through: start, by: -1) where has(needle, at: position) {
            return position
        }
        return nil
    }

    /// `[from, to)` 之间的事由：去掉开头的「提醒我」这类和标点，去首尾空白和标点。
    func event(from start: Int, to end: Int) -> String {
        var i = start
        skipFillers(&i)
        guard i < end else { return "" }
        let slice = String(original[i..<end])
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "，,、。.！!？?：:；;~～—"))
        return slice.trimmingCharacters(in: trim)
    }

    // MARK: 数

    /// 阿拉伯数字（可带小数：`1.5`）或中文数字（零一二两三…十，到九十九）。
    func decimal(at index: inout Int) -> Double? {
        var i = index
        var digits = ""
        while i < lower.count, lower[i].isASCII, lower[i].isNumber {
            digits.append(lower[i])
            i += 1
        }
        if !digits.isEmpty {
            if i + 1 < lower.count, lower[i] == ".", lower[i + 1].isASCII, lower[i + 1].isNumber {
                digits.append(".")
                i += 1
                while i < lower.count, lower[i].isASCII, lower[i].isNumber {
                    digits.append(lower[i])
                    i += 1
                }
            }
            guard digits.count <= 8, let value = Double(digits) else { return nil }
            index = i
            return value
        }
        guard let value = chineseNumber(at: &i) else { return nil }
        index = i
        return Double(value)
    }

    /// 整数：阿拉伯数字（最多 `maxDigits` 位，或正好 `exactDigits` 位）或中文数字。
    func integer(at index: inout Int, maxDigits: Int = 4, exactDigits: Int? = nil) -> Int? {
        var i = index
        var digits = ""
        while i < lower.count, lower[i].isASCII, lower[i].isNumber {
            digits.append(lower[i])
            i += 1
        }
        if !digits.isEmpty {
            if let exactDigits {
                guard digits.count == exactDigits else { return nil }
            } else if digits.count > maxDigits {
                return nil
            }
            // 「1.5」这种带小数的不是钟点。
            if i + 1 < lower.count, lower[i] == ".", lower[i + 1].isASCII, lower[i + 1].isNumber { return nil }
            guard let value = Int(digits) else { return nil }
            index = i
            return value
        }
        guard exactDigits == nil, let value = chineseNumber(at: &i) else { return nil }
        index = i
        return value
    }

    private static let chineseDigits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]

    /// 中文数字 0–99：「三」「十」「十五」「二十」「二十五」「零五」「两」。读不成一个数时不动 `index`。
    func chineseNumber(at index: inout Int) -> Int? {
        var i = index
        var run: [Character] = []
        while i < lower.count, run.count < 4, Self.chineseDigits[lower[i]] != nil || lower[i] == "十" {
            run.append(lower[i])
            i += 1
        }
        guard !run.isEmpty, let value = Self.chineseValue(run) else { return nil }
        index = i
        return value
    }

    private static func chineseValue(_ run: [Character]) -> Int? {
        if let ten = run.firstIndex(of: "十") {
            let before = run[..<ten]
            let after = run[run.index(after: ten)...]
            guard before.count <= 1, after.count <= 1, !after.contains("十") else { return nil }
            let tens = before.first.map { chineseDigits[$0] ?? -1 } ?? 1
            let ones = after.first.map { chineseDigits[$0] ?? -1 } ?? 0
            guard (1...9).contains(tens), (0...9).contains(ones) else { return nil }
            return tens * 10 + ones
        }
        switch run.count {
        case 1:
            return chineseDigits[run[0]]
        case 2 where run[0] == "零" || run[0] == "〇":
            return chineseDigits[run[1]]
        default:
            return nil
        }
    }
}
