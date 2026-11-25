import Foundation

// 快速入口认颜色值（docs/launcher/TECH_DESIGN.md §5.4）：`#RGB`、`#RRGGBB`、`#RRGGBBAA`、`rgb(…)` / `rgba(…)`、`hsl(…)` / `hsla(…)`，
// 解析成分量，再写成 HEX / RGB / HSL 三种写法（行首画一个这个颜色的色块，⏎ 复制该写法）。
// 宁可不认也不误认：数值超出范围、个数不对、多出别的字都不算颜色。纯逻辑、只依赖 Foundation，进 BaoboxTests。

/// 一个颜色（sRGB），分量都在 0…1。
struct LauncherColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamped(red)
        self.green = Self.clamped(green)
        self.blue = Self.clamped(blue)
        self.alpha = Self.clamped(alpha)
    }

    // MARK: - 解析

    /// 认不出为 nil。不分大小写，括号里的空白随意；去首尾空白由调用方做。
    static func parse(_ text: String) -> LauncherColor? {
        guard !text.isEmpty, text.utf8.count <= 64 else { return nil }
        if text.hasPrefix("#") { return parseHex(text.dropFirst()) }
        return parseFunction(text.lowercased())
    }

    /// `#` 后面的 3 / 6 / 8 位十六进制（#RGB、#RRGGBB、#RRGGBBAA）。
    private static func parseHex(_ digits: Substring) -> LauncherColor? {
        guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded = digits.count == 3 ? String(digits.flatMap { [$0, $0] }) : String(digits)
        var bytes: [Double] = []
        var index = expanded.startIndex
        while index < expanded.endIndex {
            let next = expanded.index(index, offsetBy: 2)
            guard let byte = UInt8(expanded[index..<next], radix: 16) else { return nil }
            bytes.append(Double(byte) / 255)
            index = next
        }
        guard bytes.count >= 3 else { return nil }
        return LauncherColor(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes.count > 3 ? bytes[3] : 1)
    }

    /// `rgb(…)` / `rgba(…)` / `hsl(…)` / `hsla(…)`，两种写法：逗号分隔（`rgb(23, 163, 152)`、`rgba(23,163,152,0.5)`），
    /// 或空格分隔、透明度跟在 `/` 后面（`rgb(23 163 152 / 50%)`）。
    private static func parseFunction(_ text: String) -> LauncherColor? {
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return nil }
        let name = text[..<open].trimmingCharacters(in: .whitespaces)
        let body = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard !body.contains("("), !body.contains(")"), let parts = components(body) else { return nil }
        switch name {
        case "rgb", "rgba":
            guard let red = channel(parts.values[0]), let green = channel(parts.values[1]),
                  let blue = channel(parts.values[2]), let alpha = alphaValue(parts.alpha) else { return nil }
            return LauncherColor(red: red, green: green, blue: blue, alpha: alpha)
        case "hsl", "hsla":
            guard let hue = hueValue(parts.values[0]), let saturation = percentage(parts.values[1]),
                  let lightness = percentage(parts.values[2]), let alpha = alphaValue(parts.alpha) else { return nil }
            return fromHSL(hue: hue, saturation: saturation, lightness: lightness, alpha: alpha)
        default:
            return nil
        }
    }

    /// 括号里的内容 → 三个分量 + 可选的透明度。个数不对、空的分量、两种分隔混用都为 nil。
    private static func components(_ body: Substring) -> (values: [Substring], alpha: Substring?)? {
        if body.contains(",") {
            guard !body.contains("/") else { return nil }
            let tokens = body.split(separator: ",", omittingEmptySubsequences: false)
                .map { Substring($0.trimmingCharacters(in: .whitespaces)) }
            guard tokens.count == 3 || tokens.count == 4,
                  tokens.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }) else { return nil }
            return (Array(tokens.prefix(3)), tokens.count == 4 ? tokens[3] : nil)
        }
        let halves = body.split(separator: "/", omittingEmptySubsequences: false)
        guard halves.count <= 2 else { return nil }
        let values = halves[0].split(whereSeparator: \.isWhitespace)
        guard values.count == 3 else { return nil }
        guard halves.count == 2 else { return (values, nil) }
        let alpha = halves[1].split(whereSeparator: \.isWhitespace)
        guard alpha.count == 1 else { return nil }
        return (values, alpha[0])
    }

    /// RGB 的一个分量：0–255 或 0%–100%。
    private static func channel(_ token: Substring) -> Double? {
        if token.hasSuffix("%") {
            guard let value = number(token.dropLast()), value <= 100 else { return nil }
            return value / 100
        }
        guard let value = number(token), value <= 255 else { return nil }
        return value / 255
    }

    /// 透明度：0–1 或 0%–100%；没写为 1。
    private static func alphaValue(_ token: Substring?) -> Double? {
        guard let token else { return 1 }
        if token.hasSuffix("%") {
            guard let value = number(token.dropLast()), value <= 100 else { return nil }
            return value / 100
        }
        guard let value = number(token), value <= 1 else { return nil }
        return value
    }

    /// 色相：度数（可带 `deg`、可为负、可超过 360），折回 0..<360。
    private static func hueValue(_ token: Substring) -> Double? {
        let digits = token.hasSuffix("deg") ? token.dropLast(3) : token
        guard let value = number(digits, allowsNegative: true) else { return nil }
        let wrapped = value.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// 饱和度、亮度：0–100，`%` 可写可不写。
    private static func percentage(_ token: Substring) -> Double? {
        let digits = token.hasSuffix("%") ? token.dropLast() : token
        guard let value = number(digits), value <= 100 else { return nil }
        return value / 100
    }

    /// 只认 `12`、`12.5`、`.5` 这样的十进制数（不认 `inf`、`nan`、`1e3`、`+1`）；`allowsNegative` 时可带一个负号。
    private static func number(_ token: Substring, allowsNegative: Bool = false) -> Double? {
        var digits = token
        if allowsNegative, digits.first == "-" { digits = digits.dropFirst() }
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard !digits.isEmpty, parts.count <= 2,
              parts.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } }),
              parts.contains(where: { !$0.isEmpty }),
              parts.count == 1 || !parts[1].isEmpty else { return nil }
        return Double(token)
    }

    // MARK: - HSL

    static func fromHSL(hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) -> LauncherColor {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case ..<1: (r, g, b) = (chroma, second, 0)
        case ..<2: (r, g, b) = (second, chroma, 0)
        case ..<3: (r, g, b) = (0, chroma, second)
        case ..<4: (r, g, b) = (0, second, chroma)
        case ..<5: (r, g, b) = (second, 0, chroma)
        default: (r, g, b) = (chroma, 0, second)
        }
        let offset = lightness - chroma / 2
        return LauncherColor(red: r + offset, green: g + offset, blue: b + offset, alpha: alpha)
    }

    /// 色相（度，0..<360）、饱和度、亮度（0…1）。
    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        guard delta > 1e-9 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        if maximum == red {
            hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            hue = 60 * ((blue - red) / delta + 2)
        } else {
            hue = 60 * ((red - green) / delta + 4)
        }
        if hue < 0 { hue += 360 }
        return (hue, min(1, saturation), lightness)
    }

    // MARK: - 三种写法

    /// 0–255 的三个整数。
    var rgb255: (red: Int, green: Int, blue: Int) {
        (Self.byte(red), Self.byte(green), Self.byte(blue))
    }

    /// 带不带透明度：按两位十六进制取整后不到 FF 才算有。
    var hasAlpha: Bool { Self.byte(alpha) < 255 }

    /// `#17A398`；有透明度时 `#17A39880`。大写。
    var hexString: String {
        let (r, g, b) = rgb255
        let base = String(format: "#%02X%02X%02X", r, g, b)
        return hasAlpha ? base + String(format: "%02X", Self.byte(alpha)) : base
    }

    /// `rgb(23, 163, 152)`；有透明度时 `rgba(23, 163, 152, 0.5)`。
    var rgbString: String {
        let (r, g, b) = rgb255
        return hasAlpha ? "rgba(\(r), \(g), \(b), \(Self.alphaText(alpha)))" : "rgb(\(r), \(g), \(b))"
    }

    /// `hsl(175, 75%, 36%)`；有透明度时 `hsla(175, 75%, 36%, 0.5)`。都取整。
    var hslString: String {
        let (hue, saturation, lightness) = hsl
        var h = Int(hue.rounded())
        if h >= 360 { h -= 360 }
        let s = Int((saturation * 100).rounded())
        let l = Int((lightness * 100).rounded())
        return hasAlpha ? "hsla(\(h), \(s)%, \(l)%, \(Self.alphaText(alpha)))" : "hsl(\(h), \(s)%, \(l)%)"
    }

    private static func byte(_ value: Double) -> Int {
        Int((clamped(value) * 255).rounded())
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    /// 透明度最多两位小数，去掉末尾的 0：`0.5`、`0.25`、`1`、`0`。
    static func alphaText(_ alpha: Double) -> String {
        var text = String(format: "%.2f", (clamped(alpha) * 100).rounded() / 100)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
