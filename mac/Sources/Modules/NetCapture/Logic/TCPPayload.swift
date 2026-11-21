import Foundation

// 网络抓包的纯逻辑（只依赖 Foundation，进 BaoboxTests）：「TCP 包」页的数据怎么排成十六进制、怎么当文本看。
// 见 docs/packet-capture/CONTROL.md §4.2。

enum TCPPayload {
    /// 每行 16 字节：`偏移(8 位十六进制)  16 个字节（8 个一组）  |可打印的 ASCII|`。
    /// `startOffset` 是这一块在它那个方向上的累计偏移（流视图里偏移连续编号，不是每块从 0 开始）。
    static func hexDump(_ data: Data, startOffset: Int = 0) -> String {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return "" }
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / 16 + 1)
        var index = 0
        while index < bytes.count {
            let row = bytes[index..<min(index + 16, bytes.count)]
            var hex = ""
            for (column, byte) in row.enumerated() {
                if column == 8 { hex += " " }
                hex += hexByte(byte) + " "
            }
            // 不满 16 字节的最后一行补空格，让右边的 ASCII 对齐。
            let missing = 16 - row.count
            if missing > 0 { hex += String(repeating: "   ", count: missing) + (row.count <= 8 ? " " : "") }
            let ascii = String(row.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(offsetText(startOffset + index) + "  " + hex + " |" + ascii + "|")
            index += 16
        }
        return lines.joined(separator: "\n")
    }

    /// 八位十六进制的偏移。
    static func offsetText(_ offset: Int) -> String {
        let text = String(offset, radix: 16)
        return String(repeating: "0", count: max(0, 8 - text.count)) + text
    }

    /// 像不像文本：按 UTF-8 解得开（末尾被截断的半个字符不算错），控制字符（除了换行、回车、制表）不超过 5%。
    static func looksLikeText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        var bytes = [UInt8](data)
        // 一段数据可能正好切在一个多字节字符中间：去掉末尾最多 3 个不完整的字节再判断。
        bytes = dropIncompleteTail(bytes)
        guard let text = String(bytes: bytes, encoding: .utf8) else { return false }
        let scalars = text.unicodeScalars
        let control = scalars.filter { isControl($0) }.count
        return control * 20 <= scalars.count
    }

    /// 当文本显示：按 UTF-8 解，换行、回车换行、制表照留；别的控制字符和解不开的字节都显示成 `·`
    /// （SSH 的版本行之后是密文，按文本看时就是一串点，不是满屏的替换符）。
    static func text(_ data: Data) -> String {
        let decoded = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var result = String.UnicodeScalarView()
        for scalar in decoded.unicodeScalars {
            if scalar == "\r" {
                result.append("\n")
            } else if isControl(scalar) || scalar == "\u{FFFD}" {
                result.append("·")
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\r" || scalar == "\t" { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    /// 末尾不完整的 UTF-8 序列（最多 3 个字节）去掉。
    private static func dropIncompleteTail(_ bytes: [UInt8]) -> [UInt8] {
        let count = bytes.count
        for back in 1...min(3, count) {
            let byte = bytes[count - back]
            if byte & 0xC0 == 0x80 { continue }                 // 续字节，往前找起始字节
            let needed: Int
            if byte & 0xE0 == 0xC0 { needed = 2 } else if byte & 0xF0 == 0xE0 { needed = 3 } else if byte & 0xF8 == 0xF0 { needed = 4 } else { return bytes }
            return back < needed ? Array(bytes[..<(count - back)]) : bytes
        }
        return bytes
    }

    private static let digits = Array("0123456789abcdef")

    private static func hexByte(_ byte: UInt8) -> String {
        String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }
}
