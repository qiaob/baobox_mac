import Foundation

/// JSON 识别与格式化。
///
/// **格式化不走 `JSONSerialization` 往返**（`.prettyPrinted`），因为那条路有三个真实缺陷：
/// ① 解析成 `NSDictionary` 即丢失 key 原始顺序（`.sortedKeys` 只是换成字典序）；
/// ② 大整数/高精度小数会过一遍 `Double`，19 位雪花 ID 会被静默改写 —— 这是数据损坏，
///    比不支持这个功能更糟；③ 大文档要在内存里建一整棵对象树。
/// 所以：**合法性校验用 `JSONSerialization`，格式化/压缩用下面的保序扫描器。**
struct JSONRecognizer: TextFormatRecognizer {
    let id = "json"
    let priority = 20

    func detect(_ text: String) -> FormatMatch? {
        guard JSONFormatter.isValid(text) else { return nil }
        return FormatMatch(
            id: id,
            badge: "JSON",
            // 原文本身可读，格式化是显式动作 —— 不因为「选中了」就把预览换掉。
            rendered: nil,
            rows: [],
            actions: [
                // 转换是可以串起来的（格式化 → 转义 → …），所以每次都要重新校验入参：
                // 对着「转义后的字符串字面量」再点格式化，扫描器不校验的话会吐出一堆
                // 乱缩进。返回 nil = 静默不动。
                FormatAction(id: "json.pretty", title: L("clipboard.tools.action.format"),
                             kind: .transform { JSONFormatter.isValid($0) ? JSONFormatter.rewrite($0, pretty: true) : nil }),
                FormatAction(id: "json.minify", title: L("clipboard.tools.action.minify"),
                             kind: .transform { JSONFormatter.isValid($0) ? JSONFormatter.rewrite($0, pretty: false) : nil }),
                FormatAction(id: "json.escape", title: L("clipboard.tools.action.escape"),
                             kind: .transform { JSONFormatter.escaped($0) }),
                FormatAction(id: "json.unescape", title: L("clipboard.tools.action.unescape"),
                             kind: .transform { JSONFormatter.unescaped($0) })
            ]
        )
    }
}

// MARK: - 保序扫描器

enum JSONFormatter {
    /// 合法性校验。不开 `.fragmentsAllowed`，所以 `123` / `"abc"` 不会被认成 JSON。
    static func isValid(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return false }
        guard let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) != nil
    }

    /// 词法级单遍重排（O(n)、无递归、不建对象树）。
    ///
    /// - 字符串内的一切原样透传（含转义），只靠 `escaped` 标志判断引号是否闭合；
    /// - 数字与 `true/false/null` 逐字符透传 → **精度天然无损**；
    /// - key 顺序天然保持，因为压根没解析成字典。
    ///
    /// `pretty == false` 即压缩：同一套扫描逻辑，只是不输出缩进/换行/`:` 后的空格。
    static func rewrite(_ text: String, pretty: Bool, indent: Int = 2) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count + text.utf8.count / 3)

        var depth = 0
        var inString = false
        var escaped = false
        // 刚输出了 `{` 或 `[`，还没决定要不要换行 —— 用它避免向前看：
        // 下一个有效字符若是配对的闭合符，就原地写成 `{}` / `[]`，不跨两行。
        var pendingOpen = false

        for character in text {
            if inString {
                out.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                continue
            }

            if pendingOpen {
                pendingOpen = false
                if character == "}" || character == "]" {
                    out.append(character) // 空容器
                    continue
                }
                depth += 1
                if pretty {
                    out.append("\n")
                    out.append(Self.indentation(depth, unit: indent))
                }
            }

            switch character {
            case "\"":
                out.append(character)
                inString = true
            case "{", "[":
                out.append(character)
                pendingOpen = true
            case "}", "]":
                depth = max(0, depth - 1)
                if pretty {
                    out.append("\n")
                    out.append(Self.indentation(depth, unit: indent))
                }
                out.append(character)
            case ",":
                out.append(character)
                if pretty {
                    out.append("\n")
                    out.append(Self.indentation(depth, unit: indent))
                }
            case ":":
                out.append(character)
                if pretty { out.append(" ") }
            default:
                out.append(character)
            }
        }
        return out
    }

    private static func indentation(_ depth: Int, unit: Int) -> String {
        String(repeating: " ", count: max(0, depth) * unit)
    }

    // MARK: 转义

    /// 包成可直接嵌进代码的字符串字面量。
    static func escaped(_ text: String) -> String {
        var out = "\""
        for character in text {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if let ascii = character.asciiValue, ascii < 0x20 {
                    out += String(format: "\\u%04x", Int(ascii))
                } else {
                    out.append(character)
                }
            }
        }
        return out + "\""
    }

    /// 递归剥掉转义层。日志里嵌两层很常见（`"{\"data\":\"{\\\"id\\\":1}\"}"`），
    /// 三层封顶防炸。剥完若是合法 JSON 则顺手格式化。返回 nil = 压根没转义可剥。
    static func unescaped(_ text: String) -> String? {
        var current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var peeled = false

        for _ in 0..<3 {
            guard current.hasPrefix("\""), current.hasSuffix("\""), current.count >= 2,
                  let data = current.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let inner = object as? String else { break }
            current = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            peeled = true
        }

        guard peeled else { return nil }
        return isValid(current) ? rewrite(current, pretty: true) : current
    }
}
