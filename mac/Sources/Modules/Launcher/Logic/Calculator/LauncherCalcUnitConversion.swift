import Foundation

// 单位换算句型（docs/launcher/TECH_DESIGN.md §7 第 3 种）：
//   <数量> [to | in | = | 换成 | 是多少 …] <单位>
//   数量 = 数字 单位 [数字 单位 …]（复合量：`3 小时 20 分`、`5 ft 11 in`，各段量纲相同）
// 两边量纲必须一致才出结果（`5 km to kg` 不出）；有歧义的写法（`m` = 米 / 分钟）按两边能对上的量纲定。
// 换算本身交给 Foundation 的 Measurement，结果按 10 位有效数字显示。

enum LauncherCalcUnitConversion {
    private static let connectors: Set<String> = [
        "to", "in", "into", "as", "换成", "换算成", "转", "转成", "转换成", "转为", "等于", "等于多少", "是多少",
        "合", "合多少", "折合", "折合多少", "多少",
    ]
    static let cjkWords: Set<String> = connectors.filter { $0.unicodeScalars.contains(where: LauncherCalcLexer.isCJK) }

    /// 一个单位写法最多跨几个 token（`kilometers per hour`、`m ^ 2` 连写、`公里 / 小时`）。
    private static let maxUnitTokens = 4

    private struct Part {
        let value: LauncherCalcValue
        let candidates: [LauncherCalcUnit]
    }

    static func match(_ tokens: [LauncherCalcToken], _ context: LauncherCalcContext) -> LauncherCalcResult? {
        var cursor = LauncherCalcCursor(tokens)
        let negative = cursor.take(symbol: "-")
        var parts: [Part] = []
        while let value = cursor.current?.number {
            var probe = cursor
            probe.advance()
            guard let candidates = unit(at: &probe) else { break }
            parts.append(Part(value: parts.isEmpty && negative ? LauncherCalcMath.negate(value) : value,
                              candidates: candidates))
            cursor = probe
        }
        guard !parts.isEmpty else { return nil }
        if !cursor.take(symbol: "=") { _ = cursor.take(phraseIn: connectors, maxTokens: 2) }
        guard let targets = unit(at: &cursor), cursor.atEnd,
              let (sources, target) = resolve(parts, targets) else { return nil }
        // 温度不是线性叠加的量，复合写法（`20 °C 5 °F`）没有意义。
        if target.dimension == .temperature, sources.count > 1 { return nil }

        var total = 0.0
        for (part, source) in zip(parts, sources) {
            let measurement = Measurement<Dimension>(value: part.value.doubleValue, unit: source.unit)
            total += measurement.converted(to: target.unit).value
        }
        let quantity = zip(parts, sources).map { "\(LauncherCalcFormat.plain($0.value)) \($1.name(context))" }
        let interpretation = "\(quantity.joined(separator: " ")) → \(target.name(context))"
        guard total.isFinite, let number = LauncherCalcFormat.number(.approx(total), precision: .unit) else {
            return .failed(.unit, .overflow, interpretation: interpretation, context: context)
        }
        return .value(.unit, display: "\(number.display) \(target.name(context))", copy: number.copy,
                      interpretation: interpretation)
    }

    /// 从游标处读一个单位写法（最长优先）；读到就前进，返回候选单位。
    private static func unit(at cursor: inout LauncherCalcCursor) -> [LauncherCalcUnit]? {
        let longest = min(maxUnitTokens, cursor.remainingCount)
        guard longest > 0 else { return nil }
        for count in stride(from: longest, through: 1, by: -1) {
            guard let key = key(cursor, count: count) else { continue }
            let units = LauncherCalcUnitTable.lookup(key)
            if !units.isEmpty {
                cursor.advance(count)
                return units
            }
        }
        return nil
    }

    /// 几个 token 拼成的单位写法：连着写的直接拼（`km/h`、`m2`、`°c`），中间有空格的补一个空格（`sq ft`）。
    /// 只拼词、`/`、`^`、`°` 和紧跟的数字 2 / 3。
    private static func key(_ cursor: LauncherCalcCursor, count: Int) -> String? {
        var text = ""
        for offset in 0..<count {
            guard let token = cursor.peek(offset) else { return nil }
            switch token.kind {
            case .word: break
            case .symbol(let symbol) where symbol == "/" || symbol == "^" || symbol == "°": break
            case .number where offset > 0 && !token.spaceBefore && (token.raw == "2" || token.raw == "3"): break
            default: return nil
            }
            if offset > 0, token.spaceBefore { text += " " }
            text += token.raw
        }
        return text
    }

    /// 选一个各段和目标都有的量纲，返回各段和目标的具体单位。
    private static func resolve(_ parts: [Part],
                                _ targets: [LauncherCalcUnit]) -> ([LauncherCalcUnit], LauncherCalcUnit)? {
        guard let first = parts.first else { return nil }
        for dimension in first.candidates.map(\.dimension) {
            guard let target = targets.first(where: { $0.dimension == dimension }) else { continue }
            let sources = parts.compactMap { part in part.candidates.first { $0.dimension == dimension } }
            if sources.count == parts.count { return (sources, target) }
        }
        return nil
    }
}
