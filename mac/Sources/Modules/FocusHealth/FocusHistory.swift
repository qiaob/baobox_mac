import Foundation

// 专注历史（docs/focus-health/HISTORY.md）：每结束一段专注 / 休息记一条，存在 history.jsonl（一行一条，只追加）。
// 本文件只依赖 Foundation（和同目录的 FocusHealthModels.swift），可脱离 App 单独编译测试；读写文件在 FocusHealthStore。

/// 一段专注或休息（HISTORY.md §2）。时刻取整到秒，秒数是整数 —— 写成 ISO 8601 不丢精度，导出再导入也能按起止去重。
struct FocusHistoryRecord: Equatable {
    enum Kind: String, Codable, CaseIterable {
        case focus, shortBreak, longBreak
    }

    enum Outcome: String, Codable, CaseIterable {
        /// 到点。
        case done
        /// 提前结束 · 算完成。
        case doneEarly
        /// 提前结束 · 不算。
        case discarded
        /// 休息被跳过（提前结束、直接开始下一轮）。
        case skipped
    }

    var kind: Kind
    var start: Date
    var end: Date
    /// 计划秒数。
    var planned: Int
    /// 实际秒数：专注 = 各段相加、去掉暂停；休息 = 从开始到结束。
    var seconds: Int
    var outcome: Outcome

    init(kind: Kind, start: Date, end: Date, planned: Int, seconds: Int, outcome: Outcome) {
        self.kind = kind
        self.start = FocusHistoryCodec.wholeSecond(start)
        self.end = FocusHistoryCodec.wholeSecond(end)
        self.planned = max(planned, 0)
        self.seconds = max(seconds, 0)
        self.outcome = outcome
    }

    /// 算进「今天 / 本周 / 连续天数」：到点或提前结束但算完成的专注。
    var countsAsFocus: Bool {
        kind == .focus && (outcome == .done || outcome == .doneEarly)
    }

    /// 去重用：同一种、起止（秒）都一样就是同一段。
    var identity: String {
        let from = FocusHistoryCodec.safeInt(start.timeIntervalSince1970)
        let to = FocusHistoryCodec.safeInt(end.timeIntervalSince1970)
        return "\(kind.rawValue)|\(from)|\(to)"
    }

    /// 一轮专注结束时的记录（在 session.complete / discard 之前调）。不在专注中返回 nil。
    /// 到点：结束时刻是计划结束的时刻（App 关着期间过点的，不把关着的那段算进去）；暂停中结束：就是现在。
    static func focusEnded(_ session: FocusSession, outcome: Outcome, at now: Date) -> FocusHistoryRecord? {
        guard session.inFocus else { return nil }
        var end = now
        if session.phase == .focusing, let plannedEnd = session.plannedEnd, plannedEnd < now {
            end = plannedEnd
        }
        let seconds = min(session.elapsed(at: end), session.plannedSeconds)
        let start = session.roundStartedAt ?? end.addingTimeInterval(-seconds)
        return FocusHistoryRecord(kind: .focus, start: min(start, end), end: end,
                                  planned: FocusHistoryCodec.safeInt(session.plannedSeconds),
                                  seconds: FocusHistoryCodec.safeInt(seconds), outcome: outcome)
    }

    /// 一段休息结束时的记录（在 session.endBreak 之前调）。不在休息中返回 nil。
    static func breakEnded(_ session: FocusSession, completed: Bool, at now: Date) -> FocusHistoryRecord? {
        guard session.inBreak, let endsAt = session.breakEndsAt else { return nil }
        let start = endsAt.addingTimeInterval(-session.breakSeconds)
        let end = max(start, min(now, endsAt))
        return FocusHistoryRecord(kind: session.phase == .longBreak ? .longBreak : .shortBreak, start: start, end: end,
                                  planned: FocusHistoryCodec.safeInt(session.breakSeconds),
                                  seconds: FocusHistoryCodec.safeInt(end.timeIntervalSince(start)),
                                  outcome: completed ? .done : .skipped)
    }
}

/// 解析全程容错：种类 / 起止 / 结果缺了或不认识的那一行跳过；秒数缺了按起止算。
extension FocusHistoryRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, start, end, planned, seconds, outcome
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        let outcome = try c.decode(Outcome.self, forKey: .outcome)
        guard let start = FocusHistoryCodec.decodeDate(in: c, forKey: .start),
              let end = FocusHistoryCodec.decodeDate(in: c, forKey: .end), end >= start else {
            throw DecodingError.dataCorruptedError(forKey: .end, in: c, debugDescription: "bad start / end")
        }
        let span = FocusHistoryCodec.safeInt(end.timeIntervalSince(start))
        self.init(kind: kind, start: start, end: end,
                  planned: FocusHistoryCodec.decodeSeconds(in: c, forKey: .planned) ?? span,
                  seconds: FocusHistoryCodec.decodeSeconds(in: c, forKey: .seconds) ?? span,
                  outcome: outcome)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(FocusHistoryCodec.dateString(start), forKey: .start)
        try c.encode(FocusHistoryCodec.dateString(end), forKey: .end)
        try c.encode(planned, forKey: .planned)
        try c.encode(seconds, forKey: .seconds)
        try c.encode(outcome, forKey: .outcome)
    }
}

/// history.jsonl 的编解码、去重合并与 400 天裁剪（纯逻辑，可单测）。
enum FocusHistoryCodec {
    /// 只留最近这么多天（HISTORY.md §2）。
    static let keepDays = 400

    /// 一行：JSON + 换行。
    static func line(_ record: FocusHistoryRecord) -> Data? {
        guard var data = try? encoder.encode(record) else { return nil }
        data.append(0x0A)
        return data
    }

    /// 整份文件（重写用）。`keeping`：看不懂的行原样接在后面（见 `Decoded.unknownLines`）。
    static func encodeLines(_ records: [FocusHistoryRecord], keeping unknown: [Data] = []) -> Data {
        var data = Data()
        for record in records {
            if let line = line(record) { data.append(line) }
        }
        for line in unknown {
            data.append(line)
            data.append(0x0A)
        }
        return data
    }

    struct Decoded: Equatable {
        var records: [FocusHistoryRecord] = []
        /// 看不懂的完整行（坏行，或更新版本的 Baobox 写的新种类 / 新结果）：读的时候跳过，重写时原样留着 ——
        /// 装回旧版本（别的分支的构建）启动时不会把新版本记下的东西删掉。
        var unknownLines: [Data] = []
        /// 最后一行没写完（没有换行、也解不出来 = 崩在半截）：这一行丢掉，启动时整份重写一次。
        var truncatedTail = false
    }

    /// 读整份文件。空行跳过。
    static func decodeLines(_ data: Data) -> Decoded {
        let decoder = JSONDecoder()
        var result = Decoded()
        let slices = data.split(separator: 0x0A)
        let endsWithNewline = data.last == 0x0A
        for (index, slice) in slices.enumerated() {
            let line = Data(slice)
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
            if let record = try? decoder.decode(FocusHistoryRecord.self, from: line) {
                result.records.append(record)
            } else if index == slices.count - 1, !endsWithNewline {
                result.truncatedTail = true
            } else {
                result.unknownLines.append(line)
            }
        }
        return result
    }

    /// 结束时刻早于 400 天前（按本地日期算）的去掉。
    static func pruned(_ records: [FocusHistoryRecord], now: Date, calendar: Calendar = .current) -> [FocusHistoryRecord] {
        let cutoff = cutoffDate(now: now, calendar: calendar)
        return records.filter { $0.end >= cutoff }
    }

    static func cutoffDate(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -keepDays, to: today)
            ?? today.addingTimeInterval(-Double(keepDays) * 86_400)
    }

    /// 合并两份：按「种类 + 起止」去重（先出现的留下），按开始时间排好，裁掉 400 天前的。
    static func merged(_ base: [FocusHistoryRecord], _ extra: [FocusHistoryRecord], now: Date,
                       calendar: Calendar = .current) -> [FocusHistoryRecord] {
        var seen = Set<String>()
        let unique = (base + extra).filter { seen.insert($0.identity).inserted }
        let sorted = unique.enumerated().sorted { lhs, rhs in
            lhs.element.start != rhs.element.start ? lhs.element.start < rhs.element.start : lhs.offset < rhs.offset
        }.map(\.element)
        return pruned(sorted, now: now, calendar: calendar)
    }

    static func wholeSecond(_ date: Date) -> Date {
        let t = date.timeIntervalSince1970
        return t.isFinite ? Date(timeIntervalSince1970: t.rounded()) : date
    }

    /// Double → Int：NaN / 无穷 / 大得离谱的值（手改过的文件）不崩，收进 ±1e11（几千年的秒数）。
    static func safeInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value.rounded(), -1e11), 1e11))
    }

    // MARK: - 日期：ISO 8601（UTC，到秒）；也认带小数秒的、以及秒数（1970 起）

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private static let plainFormatter = ISO8601DateFormatter()
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func dateString(_ date: Date) -> String {
        plainFormatter.string(from: date)
    }

    static func decodeDate<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, forKey key: Key) -> Date? {
        if let string = try? container.decode(String.self, forKey: key) {
            return plainFormatter.date(from: string) ?? fractionalFormatter.date(from: string)
        }
        // 秒数只认公元 1970 前后几千年内的，免得离谱的数字算出离谱的日期。
        if let seconds = try? container.decode(Double.self, forKey: key), seconds.isFinite, abs(seconds) < 1e11 {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    static func decodeSeconds<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, forKey key: Key) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) { return max(value, 0) }
        if let value = try? container.decode(Double.self, forKey: key), value.isFinite {
            return max(safeInt(value), 0)
        }
        return nil
    }
}
