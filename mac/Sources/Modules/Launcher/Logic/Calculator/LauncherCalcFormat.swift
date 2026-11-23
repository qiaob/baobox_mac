import Foundation

// 计算结果的数字格式（docs/launcher/TECH_DESIGN.md §7「精度」）。
// 不经过 NumberFormatter：把数拆成「一串数字 + 小数点位置」，按有效数字四舍五入、去掉尾零，再拼字符串。
// 这样输出不随系统地区变化（千分位永远是逗号、小数点永远是句点），Decimal 和 Double 走同一套规则。
//
// 有效数字：精确值（Decimal）15 位 —— 但 20 位以内的整数原样全显示；近似值（Double）12 位；单位换算 10 位。
// 整数部分超出有效数字、或绝对值小于 1e-6 时用科学计数法（`1.26765060022823e30`、`1.5e-7`）。

enum LauncherCalcFormat {
    enum Precision {
        /// 算术、百分比：精确值 15 位（20 位以内的整数全显示），近似值 12 位。
        case standard
        /// 单位换算：10 位（换算系数本来就是 Double，`72 °F` 换出来是 22.222222222224616）。
        case unit
    }

    struct Number: Equatable {
        /// 带千分位：`1,234.5`
        let display: String
        /// 不带千分位：`1234.5`
        let copy: String
    }

    /// 格式化一个数；不是有限数（NaN、无穷大）返回 nil。
    static func number(_ value: LauncherCalcValue, precision: Precision = .standard) -> Number? {
        guard let digits = decompose(value) else { return nil }
        let significant: Int
        switch (precision, value) {
        case (.unit, _): significant = 10
        case (.standard, .approx): significant = 12
        case (.standard, .exact):
            let isInteger = digits.exponent >= digits.digits.count
            significant = isInteger && digits.exponent <= 20 ? max(digits.exponent, 1) : 15
        }
        let rounded = round(digits, significant: significant)
        return Number(display: render(rounded, capacity: significant, grouping: true),
                      copy: render(rounded, capacity: significant, grouping: false))
    }

    /// 「理解成了什么」里的数字：不带千分位。
    static func plain(_ value: LauncherCalcValue) -> String {
        number(value)?.copy ?? "?"
    }

    /// 整数加千分位（日期差的天数、十进制结果）。
    static func grouped(_ value: Int64) -> String {
        let text = String(value.magnitude)
        return (value < 0 ? "-" : "") + group(text)
    }

    /// 两位补零（钟点、ISO 日期）。
    static func twoDigits(_ value: Int) -> String {
        value >= 0 && value < 10 ? "0\(value)" : "\(value)"
    }

    // MARK: - 拆数字

    /// 数值 = 0.d₁d₂d₃… × 10^exponent；digits 不含首尾的 0，为空表示 0。
    struct Digits: Equatable {
        var negative: Bool
        var digits: [UInt8]
        var exponent: Int
    }

    static func decompose(_ value: LauncherCalcValue) -> Digits? {
        switch value {
        case .exact(let decimal):
            guard !decimal.isNaN else { return nil }
            return parse(decimal.description)
        case .approx(let double):
            guard double.isFinite else { return nil }
            return parse("\(double)")
        }
    }

    /// 解析 `-123.45`、`1.2e-07`、`1e+20` 这样的十进制文本。
    static func parse(_ text: String) -> Digits? {
        var body = Substring(text)
        var negative = false
        if body.first == "-" { negative = true; body = body.dropFirst() }
        var exponentShift = 0
        if let e = body.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let shift = Int(body[body.index(after: e)...].replacingOccurrences(of: "+", with: "")) else { return nil }
            exponentShift = shift
            body = body[..<e]
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let integerPart = parts.first.map(String.init) ?? ""
        let fractionPart = parts.count == 2 ? String(parts[1]) : ""
        var digits: [UInt8] = []
        for character in integerPart + fractionPart {
            guard let digit = character.wholeNumberValue, digit >= 0, digit <= 9 else { return nil }
            digits.append(UInt8(digit))
        }
        var exponent = integerPart.count + exponentShift
        while let first = digits.first, first == 0 { digits.removeFirst(); exponent -= 1 }
        while let last = digits.last, last == 0 { digits.removeLast() }
        if digits.isEmpty { return Digits(negative: false, digits: [], exponent: 0) }
        return Digits(negative: negative, digits: digits, exponent: exponent)
    }

    /// 四舍五入到 `significant` 位有效数字，去掉尾零。
    static func round(_ value: Digits, significant: Int) -> Digits {
        guard significant > 0, value.digits.count > significant else { return value }
        var digits = Array(value.digits.prefix(significant))
        var exponent = value.exponent
        if value.digits[significant] >= 5 {
            var position = digits.count - 1
            while position >= 0 {
                if digits[position] == 9 {
                    digits[position] = 0
                    position -= 1
                } else {
                    digits[position] += 1
                    break
                }
            }
            if position < 0 {
                digits.insert(1, at: 0)
                digits.removeLast()
                exponent += 1
            }
        }
        while let last = digits.last, last == 0 { digits.removeLast() }
        return Digits(negative: value.negative, digits: digits, exponent: exponent)
    }

    // MARK: - 拼字符串

    /// `capacity` 是有效数字位数：整数部分比它还长就改用科学计数法，免得把舍掉的位显示成 0。
    static func render(_ value: Digits, capacity: Int, grouping: Bool) -> String {
        guard !value.digits.isEmpty else { return "0" }
        let sign = value.negative ? "-" : ""
        let digitText = value.digits.map { String($0) }.joined()
        if value.exponent > capacity || value.exponent < -5 {
            let mantissa = value.digits.count > 1
                ? "\(digitText.prefix(1)).\(digitText.dropFirst())"
                : digitText
            return "\(sign)\(mantissa)e\(value.exponent - 1)"
        }
        if value.exponent <= 0 {
            return "\(sign)0.\(String(repeating: "0", count: -value.exponent))\(digitText)"
        }
        let integerCount = value.exponent
        let integerDigits = digitText.count >= integerCount
            ? String(digitText.prefix(integerCount))
            : digitText + String(repeating: "0", count: integerCount - digitText.count)
        let fraction = digitText.count > integerCount ? String(digitText.dropFirst(integerCount)) : ""
        let integerText = grouping ? group(integerDigits) : integerDigits
        return fraction.isEmpty ? "\(sign)\(integerText)" : "\(sign)\(integerText).\(fraction)"
    }

    /// 每三位一个逗号。
    private static func group(_ digits: String) -> String {
        guard digits.count > 3 else { return digits }
        var result = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return result
    }
}
