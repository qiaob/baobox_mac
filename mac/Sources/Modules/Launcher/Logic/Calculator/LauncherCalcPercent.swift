import Foundation

// 百分比句型（docs/launcher/TECH_DESIGN.md §7 第 4 种）：
//   A 的 B%          · B% of A          → A × B%
//   A + B% / A - B%                     → A × (1 ± B%)       A * B% → A × B%
//   A 是 B 的百分之几 · A 占 B 的百分比   → A ÷ B，显示成百分数
//   A is what percent of B · what percent of B is A
// A、B 可以是算术表达式（`(100 + 100) 的 15%`）；百分数本身只认「数字 + %」「数字 percent」「百分之 + 数字」。
// 全用 Decimal 算。

enum LauncherCalcPercent {
    private static let ratioWords: Set<String> = ["百分之几", "百分之多少", "百分比", "多少百分比"]
    static let cjkWords: Set<String> = Set(["的", "是", "占", "百分之"]).union(ratioWords)

    private enum Shape {
        case of(base: LauncherCalcExpr, percent: Decimal)
        case adjust(base: LauncherCalcExpr, op: LauncherCalcOperator, percent: Decimal)
        case ratio(part: LauncherCalcExpr, whole: LauncherCalcExpr)
    }

    static func match(_ tokens: [LauncherCalcToken], _ context: LauncherCalcContext) -> LauncherCalcResult? {
        guard let shape = shape(of: tokens) else { return nil }
        let interpretation = render(shape)
        do {
            switch shape {
            case .of(let base, let percent):
                let value = try LauncherCalcMath.multiply(try LauncherCalcArithmetic.evaluate(base), fraction(percent))
                return result(value, suffix: "", interpretation: interpretation, context: context)
            case .adjust(let base, let op, let percent):
                let a = try LauncherCalcArithmetic.evaluate(base)
                let factor: LauncherCalcValue
                switch op {
                case .add: factor = try LauncherCalcMath.add(.exact(1), fraction(percent))
                case .subtract: factor = try LauncherCalcMath.subtract(.exact(1), fraction(percent))
                default: factor = fraction(percent)
                }
                return result(try LauncherCalcMath.multiply(a, factor), suffix: "",
                              interpretation: interpretation, context: context)
            case .ratio(let part, let whole):
                let quotient = try LauncherCalcMath.divide(try LauncherCalcArithmetic.evaluate(part),
                                                           try LauncherCalcArithmetic.evaluate(whole))
                return result(try LauncherCalcMath.multiply(quotient, .exact(100)), suffix: "%",
                              interpretation: interpretation, context: context)
            }
        } catch let failure as LauncherCalcFailure {
            return .failed(.percentage, failure, interpretation: interpretation, context: context)
        } catch {
            return nil
        }
    }

    // MARK: - 认句型

    private static func shape(of tokens: [LauncherCalcToken]) -> Shape? {
        // A is what percent of B
        if let isIndex = topLevelIndex(of: "is", in: tokens), isIndex > 0,
           let afterWhat = whatPercentOf(tokens, from: isIndex + 1),
           let part = operand(tokens[..<isIndex]), let whole = operand(tokens[afterWhat...]) {
            return .ratio(part: part, whole: whole)
        }
        // what percent of B is A
        if let afterWhat = whatPercentOf(tokens, from: 0), let isIndex = topLevelIndex(of: "is", in: tokens),
           isIndex > afterWhat, let whole = operand(tokens[afterWhat..<isIndex]),
           let part = operand(tokens[(isIndex + 1)...]) {
            return .ratio(part: part, whole: whole)
        }
        // A 是 / 占 B [的] 百分之几
        if let last = tokens.last, last.isWord(in: ratioWords),
           let verb = topLevelIndex(in: tokens, where: { $0.isWord("是") || $0.isWord("占") }), verb > 0 {
            var wholeEnd = tokens.count - 1
            if wholeEnd > verb + 1, tokens[wholeEnd - 1].isWord("的") { wholeEnd -= 1 }
            if let part = operand(tokens[..<verb]), let whole = operand(tokens[(verb + 1)..<wholeEnd]) {
                return .ratio(part: part, whole: whole)
            }
        }
        // A 的 B%
        if let of = topLevelIndex(of: "的", in: tokens), of > 0,
           let percent = percentLiteral(tokens[(of + 1)...]), let base = operand(tokens[..<of]) {
            return .of(base: base, percent: percent)
        }
        // B% of A
        if let of = topLevelIndex(of: "of", in: tokens), let percent = percentLiteral(tokens[..<of]),
           let base = operand(tokens[(of + 1)...]) {
            return .of(base: base, percent: percent)
        }
        // A + B% · A - B% · A * B%
        guard tokens.count >= 4 else { return nil }
        let percentStart = tokens.count - 2
        guard let percent = percentLiteral(tokens[percentStart...]),
              case .symbol(let symbol) = tokens[percentStart - 1].kind,
              let base = operand(tokens[..<(percentStart - 1)]) else { return nil }
        switch symbol {
        case "+": return .adjust(base: base, op: .add, percent: percent)
        case "-": return .adjust(base: base, op: .subtract, percent: percent)
        case "*": return .adjust(base: base, op: .multiply, percent: percent)
        default: return nil
        }
    }

    /// 百分数：`15%`、`15 percent`、`百分之15`。只认非负的普通十进制数。
    private static func percentLiteral(_ tokens: ArraySlice<LauncherCalcToken>) -> Decimal? {
        guard tokens.count == 2, let first = tokens.first, let last = tokens.last else { return nil }
        if first.radix == 10, case .number(.exact(let value)) = first.kind, value >= 0,
           last.isSymbol("%") || last.isWord("percent") {
            return value
        }
        if first.isWord("百分之"), last.radix == 10, case .number(.exact(let value)) = last.kind, value >= 0 {
            return value
        }
        return nil
    }

    /// `what percent of` / `what % of` 从 `start` 起出现时，返回它后面的位置。
    private static func whatPercentOf(_ tokens: [LauncherCalcToken], from start: Int) -> Int? {
        guard start + 2 < tokens.count, tokens[start].isWord("what"),
              tokens[start + 1].isWord("percent") || tokens[start + 1].isSymbol("%"),
              tokens[start + 2].isWord("of") else { return nil }
        return start + 3
    }

    /// 一个操作数：能解析成算术表达式就行（可以是裸数字，不要求有运算）。
    private static func operand(_ tokens: ArraySlice<LauncherCalcToken>) -> LauncherCalcExpr? {
        guard !tokens.isEmpty else { return nil }
        return LauncherCalcExprParser.parse(Array(tokens))?.expr
    }

    private static func topLevelIndex(of word: String, in tokens: [LauncherCalcToken]) -> Int? {
        topLevelIndex(in: tokens) { $0.isWord(word) }
    }

    /// 括号外第一个满足条件的 token。
    private static func topLevelIndex(in tokens: [LauncherCalcToken],
                                      where predicate: (LauncherCalcToken) -> Bool) -> Int? {
        var depth = 0
        for (index, token) in tokens.enumerated() {
            if token.isSymbol("(") { depth += 1 }
            if token.isSymbol(")") { depth -= 1 }
            if depth == 0, predicate(token) { return index }
        }
        return nil
    }

    // MARK: - 输出

    private static func fraction(_ percent: Decimal) -> LauncherCalcValue {
        .exact(percent / 100)
    }

    private static func result(_ value: LauncherCalcValue, suffix: String, interpretation: String,
                               context: LauncherCalcContext) -> LauncherCalcResult {
        guard let number = LauncherCalcFormat.number(value) else {
            return .failed(.percentage, .overflow, interpretation: interpretation, context: context)
        }
        return .value(.percentage, display: number.display + suffix, copy: number.copy + suffix,
                      interpretation: interpretation)
    }

    private static func render(_ shape: Shape) -> String {
        switch shape {
        case .of(let base, let percent):
            return "\(LauncherCalcArithmetic.renderOperand(base)) × \(percentText(percent))"
        case .adjust(let base, let op, let percent):
            let a = LauncherCalcArithmetic.renderOperand(base)
            switch op {
            case .add: return "\(a) × (1 + \(percentText(percent)))"
            case .subtract: return "\(a) × (1 - \(percentText(percent)))"
            default: return "\(a) × \(percentText(percent))"
            }
        case .ratio(let part, let whole):
            return "\(LauncherCalcArithmetic.renderOperand(part)) ÷ \(LauncherCalcArithmetic.renderOperand(whole))"
        }
    }

    private static func percentText(_ percent: Decimal) -> String {
        LauncherCalcFormat.plain(.exact(percent)) + "%"
    }
}
