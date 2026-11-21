import Foundation

// 网络抓包的纯逻辑（只依赖 Foundation，进 BaoboxTests）：只为展示用的 JSON 解析（docs/packet-capture/TOOLS.md §2）。
//
// 不用 JSONSerialization：它解出来的字典没有顺序（树和文本会对不上），数字也会被转成 Double 丢精度
// （`12345678901234567890`、`0.1000`）。这里保持键的原文顺序，数字保留原文。

/// 对象里的一项（保持原文顺序）。
struct JSONMember: Equatable, Sendable {
    let key: String
    let value: JSONNode
}

/// 树里一个节点的一个子项：对象的键，或数组的下标。
struct JSONChild: Equatable, Sendable {
    let label: String
    let node: JSONNode
}

enum JSONNode: Equatable, Sendable {
    case object([JSONMember])
    case array([JSONNode])
    case string(String)
    /// 原文，不转换（不丢精度、不改写法）。
    case number(String)
    case bool(Bool)
    case null

    /// 超过这么大的正文不建树，界面直接显示文本。
    static let maxTreeBytes = 2 * 1024 * 1024
    /// 树里每层最多显示这么多子项，其余收成一行「还有 N 项」。
    static let childLimit = 200
    /// 嵌套超过这么深当作解不开（防止病态输入把栈用完）。
    static let maxDepth = 512

    // MARK: - 解析

    /// 解一段 JSON。不是合法 JSON、超过 `maxTreeBytes`、嵌套太深都返回 nil（界面退回文本）。
    static func parse(_ data: Data) -> JSONNode? {
        guard data.count <= maxTreeBytes else { return nil }
        var parser = Parser(bytes: [UInt8](data))
        return parser.parseDocument()
    }

    /// 正文值得试着按 JSON 建树吗：Content-Type 写着 json，或第一个非空白字符是 `{` / `[`。
    static func looksLikeJSON(_ data: Data, contentType: String?) -> Bool {
        if contentType?.lowercased().contains("json") == true { return true }
        for byte in data {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF: continue   // 空白与 UTF-8 BOM
            case UInt8(ascii: "{"), UInt8(ascii: "["): return true
            default: return false
            }
        }
        return false
    }

    // MARK: - 树

    var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }

    var childCount: Int {
        switch self {
        case .object(let members): return members.count
        case .array(let items): return items.count
        default: return 0
        }
    }

    /// 前 `limit` 个子项，以及没显示的还有几个。
    func children(limit: Int = JSONNode.childLimit) -> (items: [JSONChild], remaining: Int) {
        switch self {
        case .object(let members):
            let shown = members.prefix(limit).map { JSONChild(label: $0.key, node: $0.value) }
            return (shown, members.count - shown.count)
        case .array(let items):
            let shown = items.prefix(limit).enumerated().map { JSONChild(label: String($0.offset), node: $0.element) }
            return (shown, items.count - shown.count)
        default:
            return ([], 0)
        }
    }

    /// 容器收起时的摘要：`{3}`、`[10]`。标量返回它的文本。
    var summary: String {
        switch self {
        case .object(let members): return "{\(members.count)}"
        case .array(let items): return "[\(items.count)]"
        default: return scalarText
        }
    }

    /// 标量写成 JSON 的样子（字符串带引号并转义）。容器返回空串。
    var scalarText: String {
        switch self {
        case .string(let text): return Self.quoted(text)
        case .number(let raw): return raw
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .object, .array: return ""
        }
    }

    // MARK: - 文本

    /// 缩进两格的文本，键序与数字写法都和原文一致（「树 / 文本」切换的文本那一面）。
    func prettyText() -> String {
        var out = ""
        write(into: &out, indent: 0)
        return out
    }

    private func write(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (index, member) in members.enumerated() {
                out += inner + Self.quoted(member.key) + ": "
                member.value.write(into: &out, indent: indent + 1)
                out += index == members.count - 1 ? "\n" : ",\n"
            }
            out += pad + "}"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += inner
                item.write(into: &out, indent: indent + 1)
                out += index == items.count - 1 ? "\n" : ",\n"
            }
            out += pad + "]"
        default:
            out += scalarText
        }
    }

    /// JSON 字符串字面量：引号、反斜杠、控制字符转义；`/` 和非 ASCII 原样。
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - 解析器

/// RFC 8259 的严格子集：不认注释、尾逗号、单引号；字符串里不许有没转义的控制字符。
private struct Parser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        // 跳过 UTF-8 BOM。
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }
    }

    mutating func parseDocument() -> JSONNode? {
        skipWhitespace()
        guard let value = parseValue(depth: 0) else { return nil }
        skipWhitespace()
        return index == bytes.count ? value : nil
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func parseValue(depth: Int) -> JSONNode? {
        guard depth < JSONNode.maxDepth, index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "{"): return parseObject(depth: depth)
        case UInt8(ascii: "["): return parseArray(depth: depth)
        case UInt8(ascii: "\""): return parseString().map(JSONNode.string)
        case UInt8(ascii: "t"): return literal("true", .bool(true))
        case UInt8(ascii: "f"): return literal("false", .bool(false))
        case UInt8(ascii: "n"): return literal("null", .null)
        default: return parseNumber()
        }
    }

    private mutating func literal(_ word: String, _ value: JSONNode) -> JSONNode? {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<index + expected.count]) == expected else { return nil }
        index += expected.count
        return value
    }

    private mutating func parseObject(depth: Int) -> JSONNode? {
        index += 1   // {
        var members: [JSONMember] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = parseString() else { return nil }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
            skipWhitespace()
            guard let value = parseValue(depth: depth + 1) else { return nil }
            members.append(JSONMember(key: key, value: value))
            skipWhitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            return nil
        }
    }

    private mutating func parseArray(depth: Int) -> JSONNode? {
        index += 1   // [
        var items: [JSONNode] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            guard let value = parseValue(depth: depth + 1) else { return nil }
            items.append(value)
            skipWhitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            return nil
        }
    }

    /// 当前在开引号上。返回解码后的字符串，指针停在闭引号之后。
    private mutating func parseString() -> String? {
        index += 1   // "
        var out: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { return nil }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard let scalar = parseUnicodeEscape() else { return nil }
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    return nil
                }
            default:
                guard byte >= 0x20 else { return nil }   // 没转义的控制字符
                out.append(byte)
                index += 1
            }
        }
        return nil   // 没有闭引号
    }

    /// `\u` 之后的四位十六进制；高位代理后面跟着 `\uDC00…` 时合成一个字符。落单的代理换成 U+FFFD。
    private mutating func parseUnicodeEscape() -> Unicode.Scalar? {
        guard let first = hex4() else { return nil }
        if (0xD800...0xDBFF).contains(first) {
            if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                let save = index
                index += 2
                if let second = hex4(), (0xDC00...0xDFFF).contains(second) {
                    let value = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    return Unicode.Scalar(value) ?? "\u{FFFD}"
                }
                index = save
            }
            return "\u{FFFD}"
        }
        return Unicode.Scalar(first) ?? "\u{FFFD}"
    }

    private mutating func hex4() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for byte in bytes[index..<index + 4] {
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: return nil
            }
            value = value * 16 + digit
        }
        index += 4
        return value
    }

    /// `-? (0 | [1-9][0-9]*) (\.[0-9]+)? ([eE][+-]?[0-9]+)?`，原文返回。
    private mutating func parseNumber() -> JSONNode? {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count, isDigit(bytes[index]) else { return nil }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else {
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else { return nil }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, isDigit(bytes[index]) else { return nil }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        return .number(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}
