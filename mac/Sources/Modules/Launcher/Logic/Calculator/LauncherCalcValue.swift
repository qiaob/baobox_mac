import Foundation

// 计算引擎的数值与运算（docs/launcher/TECH_DESIGN.md §7「精度」）。
// 加减乘除、取余、整数次幂用 Decimal（`0.1 + 0.2 = 0.3`）；开方、三角、对数、非整数次幂转 Double。
// Decimal 算溢出（得 NaN）时退到 Double 再算一次；Double 也溢出才算「数字太大」。不会 trap。

enum LauncherCalcValue: Equatable, Sendable {
    /// 精确值（Decimal，38 位有效数字）。
    case exact(Decimal)
    /// 近似值（Double），显示时按 12 位有效数字取整。
    case approx(Double)

    var doubleValue: Double {
        switch self {
        case .exact(let value): return NSDecimalNumber(decimal: value).doubleValue
        case .approx(let value): return value
        }
    }

    var isZero: Bool {
        switch self {
        case .exact(let value): return value.isZero
        case .approx(let value): return value == 0
        }
    }
}

/// 可以作用在一个数上的函数。
enum LauncherCalcFunction: String, Sendable {
    case sqrt, cbrt, sin, cos, tan, asin, acos, atan, ln, log10, log2, exp, abs, floor, ceil, round
}

enum LauncherCalcMath {
    /// 整数次幂走精确路径的指数上限；更大的指数直接用 Double（结果反正要么溢出、要么只能近似）。
    private static let maxExactExponent = 1_000

    // MARK: - 四则、取余、乘方

    static func add(_ lhs: LauncherCalcValue, _ rhs: LauncherCalcValue) throws -> LauncherCalcValue {
        if case .exact(let a) = lhs, case .exact(let b) = rhs {
            let result = a + b
            if !result.isNaN { return .exact(result) }
        }
        return try finite(lhs.doubleValue + rhs.doubleValue)
    }

    static func subtract(_ lhs: LauncherCalcValue, _ rhs: LauncherCalcValue) throws -> LauncherCalcValue {
        try add(lhs, negate(rhs))
    }

    static func multiply(_ lhs: LauncherCalcValue, _ rhs: LauncherCalcValue) throws -> LauncherCalcValue {
        if case .exact(let a) = lhs, case .exact(let b) = rhs {
            let result = a * b
            if !result.isNaN { return .exact(result) }
        }
        return try finite(lhs.doubleValue * rhs.doubleValue)
    }

    static func divide(_ lhs: LauncherCalcValue, _ rhs: LauncherCalcValue) throws -> LauncherCalcValue {
        guard !rhs.isZero else { throw LauncherCalcFailure.divisionByZero }
        if case .exact(let a) = lhs, case .exact(let b) = rhs {
            let result = a / b
            if !result.isNaN { return .exact(result) }
        }
        return try finite(lhs.doubleValue / rhs.doubleValue)
    }

    /// 取余：结果和被除数同号（`-7 % 3 = -1`），同大多数编程语言。
    static func remainder(_ lhs: LauncherCalcValue, _ rhs: LauncherCalcValue) throws -> LauncherCalcValue {
        guard !rhs.isZero else { throw LauncherCalcFailure.divisionByZero }
        if case .exact(let a) = lhs, case .exact(let b) = rhs {
            let quotient = a / b
            let result = a - truncated(quotient) * b
            if !quotient.isNaN, !result.isNaN { return .exact(result) }
        }
        return try finite(fmod(lhs.doubleValue, rhs.doubleValue))
    }

    static func power(_ base: LauncherCalcValue, _ exponent: LauncherCalcValue) throws -> LauncherCalcValue {
        if case .exact(let b) = base, case .exact(let e) = exponent, isInteger(e),
           let n = Int(e.description), Swift.abs(n) <= maxExactExponent {
            if n >= 0 {
                let result = Foundation.pow(b, n)
                if !result.isNaN { return .exact(result) }
            } else {
                guard !b.isZero else { throw LauncherCalcFailure.divisionByZero }
                let denominator = Foundation.pow(b, -n)
                if !denominator.isNaN, !denominator.isZero {
                    let result = 1 / denominator
                    if !result.isNaN { return .exact(result) }
                }
            }
        }
        let result = Foundation.pow(base.doubleValue, exponent.doubleValue)
        if result.isNaN { throw LauncherCalcFailure.notReal }
        if result.isInfinite {
            throw base.isZero ? LauncherCalcFailure.divisionByZero : LauncherCalcFailure.overflow
        }
        return .approx(result)
    }

    static func negate(_ value: LauncherCalcValue) -> LauncherCalcValue {
        switch value {
        case .exact(let a): return .exact(-a)
        case .approx(let a): return .approx(-a)
        }
    }

    /// 角度换成弧度（`sin(30°)`）。
    static func radians(fromDegrees value: LauncherCalcValue) throws -> LauncherCalcValue {
        try finite(value.doubleValue * Double.pi / 180)
    }

    // MARK: - 函数

    static func apply(_ function: LauncherCalcFunction, _ value: LauncherCalcValue) throws -> LauncherCalcValue {
        // 取绝对值、取整在 Decimal 上做，保持精确。
        if case .exact(let a) = value {
            switch function {
            case .abs: return .exact(a.magnitude)
            case .floor: return .exact(rounded(a, .down))
            case .ceil: return .exact(rounded(a, .up))
            case .round: return .exact(rounded(a, .plain))
            default: break
            }
        }
        let x = value.doubleValue
        let result: Double
        switch function {
        case .sqrt: result = x < 0 ? .nan : x.squareRoot()
        case .cbrt: result = Foundation.cbrt(x)
        case .sin: result = cleaned(Foundation.sin(x))
        case .cos: result = cleaned(Foundation.cos(x))
        case .tan: result = cleaned(Foundation.tan(x))
        case .asin: result = Foundation.asin(x)
        case .acos: result = Foundation.acos(x)
        case .atan: result = Foundation.atan(x)
        case .ln: result = x == 0 ? -.infinity : Foundation.log(x)
        case .log10: result = x == 0 ? -.infinity : Foundation.log10(x)
        case .log2: result = x == 0 ? -.infinity : Foundation.log2(x)
        case .exp:
            result = Foundation.exp(x)
            if result.isInfinite { throw LauncherCalcFailure.overflow }
        case .abs: result = Swift.abs(x)
        case .floor: result = Foundation.floor(x)
        case .ceil: result = Foundation.ceil(x)
        case .round: result = Foundation.round(x)
        }
        if result.isNaN { throw LauncherCalcFailure.notReal }
        if result.isInfinite { throw LauncherCalcFailure.infinite }
        return .approx(result)
    }

    // MARK: - Decimal 小工具

    static func isInteger(_ value: Decimal) -> Bool {
        guard !value.isNaN else { return false }
        return rounded(value, .plain) == value
    }

    /// 向零取整：`7.9 → 7`、`-7.9 → -7`（NSDecimalRound 的 .down 是向负无穷取整，所以先取绝对值）。
    static func truncated(_ value: Decimal) -> Decimal {
        let magnitude = rounded(value.magnitude, .down)
        return value < 0 ? -magnitude : magnitude
    }

    /// 取整到个位：.down = 向负无穷，.up = 向正无穷，.plain = 四舍五入（.5 远离零）。
    static func rounded(_ value: Decimal, _ mode: NSDecimalNumber.RoundingMode) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 0, mode)
        return result
    }

    // MARK: - Double 小工具

    private static func finite(_ value: Double) throws -> LauncherCalcValue {
        if value.isNaN { throw LauncherCalcFailure.notReal }
        if value.isInfinite { throw LauncherCalcFailure.overflow }
        return .approx(value)
    }

    /// 三角函数在 π 的整数倍处得到 1e-16 这样的误差，当成 0（`sin(pi)` 显示 0 而不是 1.22e-16）。
    private static func cleaned(_ value: Double) -> Double {
        Swift.abs(value) < 1e-15 ? 0 : value
    }
}
