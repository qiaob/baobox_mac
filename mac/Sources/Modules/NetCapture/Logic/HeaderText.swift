import Foundation

// 网络抓包的纯逻辑（只依赖 Foundation，进 BaoboxTests）：请求头 / 响应头和多行文本互转。
// 「编辑后重发」和 Mock 面板里的头都是一个文本框，每行一个「名: 值」（docs/packet-capture/TOOLS.md §3、§4）。

enum HeaderText {
    /// 描述正文线上形态的头。正文换了（编辑后重发、Mock 应答）它们就不对了，桥脚本会丢掉重算，所以文本框里不显示。
    static let wireHeaders: Set<String> = ["content-length", "content-encoding", "transfer-encoding"]

    /// 头 → 文本，每行 `名: 值`。默认不写 `wireHeaders`。
    static func text(_ headers: [HTTPHeader], omittingWireHeaders: Bool = true) -> String {
        headers
            .filter { !omittingWireHeaders || !wireHeaders.contains($0.name.lowercased()) }
            .map { "\($0.name): \($0.value)" }
            .joined(separator: "\n")
    }

    /// 文本 → 头：按第一个 `:` 切，名和值都去掉两头的空白；空行、没有 `:` 的行、名字是空的行跳过；同名的保留多条、保留顺序。
    static func headers(_ text: String) -> [HTTPHeader] {
        text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .compactMap { line -> HTTPHeader? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : HTTPHeader(name: name, value: value)
            }
    }
}

/// 正文算不算「文本」：能不能放进文本框编辑、按文本显示。
enum BodyText {
    /// 是 UTF-8、并且除了换行 / 回车 / 制表 / 换页之外没有控制字符，才返回文本。
    /// Protobuf / gRPC 这类二进制常常碰巧是合法 UTF-8（`00 00 00 00 02 08 2A` 就是），只看编码会把它当成文本，
    /// 放进文本框再发出去就变了；所以带控制字符的一律当二进制。
    static func text(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let allowed: Set<Unicode.Scalar> = ["\n", "\r", "\t", "\u{0C}"]
        let hasControl = text.unicodeScalars.contains { scalar in
            (scalar.value < 0x20 || scalar.value == 0x7F) && !allowed.contains(scalar)
        }
        return hasControl ? nil : text
    }
}
