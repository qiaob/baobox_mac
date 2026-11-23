import Foundation

// 算术表达式（docs/launcher/TECH_DESIGN.md §7 第 5 种句型）：递归下降，先解析成语法树，再求值。
// 先解析后求值，所以「1/0」能被认成算式、再给出「不能除以零」的说明，而不是直接不出结果。
//
//   expression := term (('+' | '-') term)*
//   term       := factor (('*' | '/' | '%' | 'mod') factor)*      % 只在两个操作数之间才是取余
//   factor     := ('-' | '+') factor | power                       -2^2 = -(2^2)
//   power      := postfix ('^' factor)?                           右结合：2^3^2 = 2^9
//   postfix    := primary ('°' | 'deg')?
//   primary    := 数字 | pi | e | 函数 参数 | '(' expression ')' | '√' postfix
//
// 不做隐式乘法（`2pi`、`2(3+4)`、`3x4` 都不认）：`1920x1080`、`3d` 这类不是算式的输入才不会被误算。

indirect enum LauncherCalcExpr: Equatable {
    case number(LauncherCalcValue)
    case constant(LauncherCalcConstant)
    case negate(LauncherCalcExpr)
    case binary(LauncherCalcOperator, LauncherCalcExpr, LauncherCalcExpr)
    case function(LauncherCalcFunction, LauncherCalcExpr)
    case degrees(LauncherCalcExpr)
    /// 输入里写了括号：求值时透明，「理解成了什么」里照样带括号。
    case group(LauncherCalcExpr)
}

enum LauncherCalcConstant: Equatable {
    case pi, e
}

enum LauncherCalcOperator: Equatable {
    case add, subtract, multiply, divide, remainder, power
}

/// 把一段 token 解析成表达式。
struct LauncherCalcExprParser {
    private struct Invalid: Error {}

    /// 括号、一元负号的嵌套上限：再深就不是人打的算式，直接不认（也就不会栈溢出）。
    static let maxDepth = 64

    static let constants: [String: LauncherCalcConstant] = ["pi": .pi, "e": .e]
    static let functions: [String: LauncherCalcFunction] = [
        "sqrt": .sqrt, "cbrt": .cbrt, "sin": .sin, "cos": .cos, "tan": .tan,
        "asin": .asin, "acos": .acos, "atan": .atan, "arcsin": .asin, "arccos": .acos, "arctan": .atan,
        "ln": .ln, "log": .log10, "lg": .log10, "exp": .exp, "abs": .abs,
        "floor": .floor, "ceil": .ceil, "round": .round, "根号": .sqrt,
    ]

    private var cursor: LauncherCalcCursor
    private var depth = 0
    /// 二元运算和函数调用的个数：一个都没有的（裸数字、`(5)`、`-3`、`pi`）不算算式。
    private(set) var operationCount = 0

    private init(_ tokens: [LauncherCalcToken]) {
        cursor = LauncherCalcCursor(tokens)
    }

    /// 整段 token 是一个表达式时返回它和运算个数；没吃完、语法不对返回 nil。
    static func parse(_ tokens: [LauncherCalcToken]) -> (expr: LauncherCalcExpr, operations: Int)? {
        guard !tokens.isEmpty else { return nil }
        var parser = LauncherCalcExprParser(tokens)
        guard let expr = try? parser.expression(), parser.cursor.atEnd else { return nil }
        return (expr, parser.operationCount)
    }

    private mutating func expression() throws -> LauncherCalcExpr {
        var lhs = try term()
        while true {
            if cursor.take(symbol: "+") {
                lhs = .binary(.add, lhs, try term())
            } else if cursor.take(symbol: "-") {
                lhs = .binary(.subtract, lhs, try term())
            } else {
                return lhs
            }
            operationCount += 1
        }
    }

    private mutating func term() throws -> LauncherCalcExpr {
        var lhs = try factor()
        while true {
            let op: LauncherCalcOperator
            if cursor.take(symbol: "*") {
                op = .multiply
            } else if cursor.take(symbol: "/") {
                op = .divide
            } else if cursor.take(word: "mod") {
                op = .remainder
            } else if cursor.current?.isSymbol("%") == true, startsOperand(cursor.peek(1)) {
                cursor.advance()
                op = .remainder
            } else {
                return lhs
            }
            lhs = .binary(op, lhs, try factor())
            operationCount += 1
        }
    }

    private mutating func factor() throws -> LauncherCalcExpr {
        try descend()
        defer { depth -= 1 }
        if cursor.take(symbol: "-") { return .negate(try factor()) }
        if cursor.take(symbol: "+") { return try factor() }
        let base = try postfix()
        if cursor.take(symbol: "^") {
            operationCount += 1
            return .binary(.power, base, try factor())
        }
        return base
    }

    private mutating func postfix() throws -> LauncherCalcExpr {
        let operand = try primary()
        if cursor.take(symbol: "°") || cursor.take(word: "deg") || cursor.take(word: "degrees") {
            return .degrees(operand)
        }
        return operand
    }

    private mutating func primary() throws -> LauncherCalcExpr {
        try descend()
        defer { depth -= 1 }
        guard let token = cursor.current else { throw Invalid() }
        if let value = token.number {
            cursor.advance()
            return .number(value)
        }
        if token.isSymbol("(") {
            cursor.advance()
            let inner = try expression()
            guard cursor.take(symbol: ")") else { throw Invalid() }
            return .group(inner)
        }
        if token.isSymbol("√") {
            cursor.advance()
            operationCount += 1
            return .function(.sqrt, try postfix())
        }
        guard let word = token.word else { throw Invalid() }
        if let constant = Self.constants[word] {
            cursor.advance()
            return .constant(constant)
        }
        // log2(8)、log10(100)：词法把「log」和紧跟的「2」「10」切开了，这里拼回去。
        if word == "log", let base = cursor.peek(1), !base.spaceBefore, cursor.peek(2)?.isSymbol("(") == true,
           let baseValue = base.decimalInteger, baseValue == 2 || baseValue == 10 {
            cursor.advance(2)
            operationCount += 1
            return .function(baseValue == 2 ? .log2 : .log10, try argument())
        }
        if let function = Self.functions[word] {
            cursor.advance()
            operationCount += 1
            // 英文函数名不带括号时参数要隔一个空格（`sqrt 2`）：`log12`、`sin1` 更像文件名，不当算式。
            let needsSpace = token.raw.unicodeScalars.first?.isASCII == true
            return .function(function, try argument(spaceRequired: needsSpace))
        }
        throw Invalid()
    }

    /// 函数的参数：括号里的表达式，或一个操作数（`sqrt 2`、`根号2`、`sin 30°`）。
    private mutating func argument(spaceRequired: Bool = false) throws -> LauncherCalcExpr {
        if cursor.take(symbol: "(") {
            let inner = try expression()
            guard cursor.take(symbol: ")") else { throw Invalid() }
            return inner
        }
        if spaceRequired, cursor.current?.spaceBefore != true { throw Invalid() }
        return try postfix()
    }

    private mutating func descend() throws {
        depth += 1
        if depth > Self.maxDepth { throw Invalid() }
    }

    /// 这个 token 能开始一个操作数（用来判断 `%` 是取余还是百分号）。
    private func startsOperand(_ token: LauncherCalcToken?) -> Bool {
        guard let token else { return false }
        if token.number != nil { return true }
        if token.isSymbol("(") || token.isSymbol("√") || token.isSymbol("-") || token.isSymbol("+") { return true }
        guard let word = token.word else { return false }
        return Self.constants[word] != nil || Self.functions[word] != nil || word == "log"
    }
}

enum LauncherCalcArithmetic {
    static let cjkWords: Set<String> = ["根号"]

    static func match(_ tokens: [LauncherCalcToken], _ context: LauncherCalcContext) -> LauncherCalcResult? {
        guard !looksLikeCode(tokens),
              let (expr, operations) = LauncherCalcExprParser.parse(tokens), operations > 0 else { return nil }
        let interpretation = render(expr)
        do {
            let value = try evaluate(expr)
            guard let number = LauncherCalcFormat.number(value) else {
                return .failed(.arithmetic, .overflow, interpretation: interpretation, context: context)
            }
            return .value(.arithmetic, display: number.display, copy: number.copy, interpretation: interpretation)
        } catch let failure as LauncherCalcFailure {
            return .failed(.arithmetic, failure, interpretation: interpretation, context: context)
        } catch {
            return nil
        }
    }

    // MARK: - 求值

    static func evaluate(_ expr: LauncherCalcExpr) throws -> LauncherCalcValue {
        switch expr {
        case .number(let value): return value
        case .constant(.pi): return .approx(Double.pi)
        case .constant(.e): return .approx(M_E)
        case .group(let inner): return try evaluate(inner)
        case .negate(let inner): return LauncherCalcMath.negate(try evaluate(inner))
        case .degrees(let inner): return try LauncherCalcMath.radians(fromDegrees: try evaluate(inner))
        case .function(let function, let argument):
            return try LauncherCalcMath.apply(function, try evaluate(argument))
        case .binary(let op, let lhs, let rhs):
            let a = try evaluate(lhs)
            let b = try evaluate(rhs)
            switch op {
            case .add: return try LauncherCalcMath.add(a, b)
            case .subtract: return try LauncherCalcMath.subtract(a, b)
            case .multiply: return try LauncherCalcMath.multiply(a, b)
            case .divide: return try LauncherCalcMath.divide(a, b)
            case .remainder: return try LauncherCalcMath.remainder(a, b)
            case .power: return try LauncherCalcMath.power(a, b)
            }
        }
    }

    // MARK: - 「理解成了什么」

    /// 标准写法：数字不带千分位（进制、科学计数、「3万」都换成十进制），× ÷ 用数学符号，% 写成 mod。
    static func render(_ expr: LauncherCalcExpr) -> String {
        switch expr {
        case .number(let value): return LauncherCalcFormat.plain(value)
        case .constant(.pi): return "π"
        case .constant(.e): return "e"
        case .group(let inner): return "(\(render(inner)))"
        case .negate(let inner): return "-\(render(inner))"
        case .degrees(let inner): return "\(render(inner))°"
        case .function(let function, let argument):
            if case .group(let inner) = argument { return "\(function.rawValue)(\(render(inner)))" }
            return "\(function.rawValue)(\(render(argument)))"
        case .binary(let op, let lhs, let rhs):
            switch op {
            case .add: return "\(render(lhs)) + \(render(rhs))"
            case .subtract: return "\(render(lhs)) - \(render(rhs))"
            case .multiply: return "\(render(lhs)) × \(render(rhs))"
            case .divide: return "\(render(lhs)) ÷ \(render(rhs))"
            case .remainder: return "\(render(lhs)) mod \(render(rhs))"
            case .power: return "\(render(lhs))^\(render(rhs))"
            }
        }
    }

    /// 作为更大式子的一个操作数时：不是单个数、括号、函数的，外面加括号（百分比句型用）。
    static func renderOperand(_ expr: LauncherCalcExpr) -> String {
        switch expr {
        case .number, .constant, .group, .function: return render(expr)
        default: return "(\(render(expr)))"
        }
    }

    // MARK: - 像编号、日期的数字串

    /// 中间没有空格、用同一种 `-` / `/` 把数字连起来的串，像电话号码、日期、编号时不当算式：
    /// - 任何地方出现连续两个以上的分隔符：`138-1234-5678`、`11/23/2026`、`2026-12-251`、`1-2-3`
    ///   （真要连减连除，加上空格：`100 - 20 - 30`）；
    /// - 只有一个分隔符、但有前导零（`010-1234`）或是「年-月」（`2026-11`、`2026/11`）。
    /// `5-3`、`100/4` 这样的照常算。
    static func looksLikeCode(_ tokens: [LauncherCalcToken]) -> Bool {
        var index = 0
        while index < tokens.count {
            guard tokens[index].number != nil else { index += 1; continue }
            var numbers = [tokens[index]]
            var separator: Character?
            var next = index + 1
            while next + 1 < tokens.count, case .symbol(let symbol) = tokens[next].kind, symbol == "-" || symbol == "/",
                  separator == nil || separator == symbol, !tokens[next].spaceBefore,
                  tokens[next + 1].number != nil, !tokens[next + 1].spaceBefore {
                separator = symbol
                numbers.append(tokens[next + 1])
                next += 2
            }
            if numbers.count >= 3 { return true }
            if numbers.count == 2, numbers.allSatisfy({ $0.raw.allSatisfy { $0.isASCII && $0.isNumber } }) {
                if numbers.contains(where: { $0.raw.count > 1 && $0.raw.hasPrefix("0") }) { return true }
                let first = numbers[0].raw
                let second = numbers[1].raw
                if first.count == 4, first.hasPrefix("19") || first.hasPrefix("20"),
                   second.count <= 2, let month = Int(second), (1...12).contains(month) {
                    return true
                }
            }
            index = max(next, index + 1)
        }
        return false
    }
}
