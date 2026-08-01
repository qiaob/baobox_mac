import Foundation

/// `curl` 命令的解析/重组（Chrome / Charles「Copy as cURL」为主要目标）。
///
/// 只实现剪贴板场景需要的 shell 子集：`'…'`、`"…"`（带 `\` 转义）、`$'…'`
/// （ANSI-C，Chrome 用它包含引号的 body）、裸 `\` 转义、行尾 `\` 续行。
/// 参数表覆盖常见抓包导出；认不出的参数原样进 `otherArgs`，**不丢**。
struct CurlCommand {
    var method: String?
    var url: String?
    var headers: [(name: String, value: String)] = []
    var cookie: String?
    var user: String?
    var dataParts: [String] = []
    var formParts: [String] = []
    var otherArgs: [String] = []

    /// 展示用方法：显式 `-X` 优先；有 body 时 curl 默认 POST，否则 GET。
    var effectiveMethod: String {
        method ?? ((dataParts.isEmpty && formParts.isEmpty) ? "GET" : "POST")
    }

    // MARK: - 检测 + 解析

    static func parse(_ text: String) -> CurlCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("curl ") else { return nil }
        guard let tokens = tokenize(trimmed), tokens.first == "curl" else { return nil }

        var command = CurlCommand()
        var bareTokens: [String] = []
        var index = 1
        // 取下一个 token 作为当前参数的值；越界返回 nil（残缺命令，值就当没有）。
        func value() -> String? {
            index += 1
            return index < tokens.count ? tokens[index] : nil
        }
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "-X", "--request":
                command.method = value()
            case "-H", "--header":
                if let raw = value() { command.headers.append(Self.splitHeader(raw)) }
            case "-b", "--cookie":
                command.cookie = value()
            case "-u", "--user":
                command.user = value()
            case "-d", "--data", "--data-raw", "--data-binary", "--data-ascii", "--data-urlencode":
                if let raw = value() { command.dataParts.append(raw) }
            case "-F", "--form":
                if let raw = value() { command.formParts.append(raw) }
            case "--url":
                command.url = value()
            default:
                if token.hasPrefix("-X"), token.count > 2 {
                    // curl 允许 -XPOST 连写
                    command.method = String(token.dropFirst(2))
                } else if token.hasPrefix("-") {
                    if Self.valueTakingFlags.contains(token), let raw = value() {
                        command.otherArgs.append("\(token) \(Self.shellQuote(raw))")
                    } else {
                        command.otherArgs.append(token)
                    }
                } else {
                    bareTokens.append(token)
                }
            }
            index += 1
        }
        if command.url == nil {
            // 未知带值参数的值可能混进裸 token，优先挑长得像 URL 的。
            command.url = bareTokens.first(where: { $0.contains("://") }) ?? bareTokens.first
        }
        guard command.url != nil else { return nil }
        return command
    }

    /// 这些参数后面必然跟一个值。漏收的后果是值被当成裸 token、误认成 URL，
    /// 所以宁可列全一点。
    private static let valueTakingFlags: Set<String> = [
        "-o", "--output", "-A", "--user-agent", "-e", "--referer", "-x", "--proxy",
        "-m", "--max-time", "--connect-timeout", "--retry", "-c", "--cookie-jar",
        "--cacert", "--capath", "-E", "--cert", "--key", "--resolve", "--limit-rate",
        "-T", "--upload-file", "--proxy-user", "-r", "--range"
    ]

    private static func splitHeader(_ raw: String) -> (name: String, value: String) {
        guard let colon = raw.firstIndex(of: ":") else { return (raw, "") }
        let name = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (name, value)
    }

    // MARK: - 分词

    /// shell 子集分词。引号不闭合返回 nil（残缺粘贴，不硬猜）。
    static func tokenize(_ text: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        let characters = Array(text)
        var i = 0

        func flush() {
            if hasCurrent { tokens.append(current); current = ""; hasCurrent = false }
        }

        while i < characters.count {
            let c = characters[i]
            switch c {
            case " ", "\t", "\n", "\r":
                flush()
            case "\\":
                // 行尾续行吃掉换行（含 \r\n）；否则转义下一个字符。
                if i + 1 < characters.count {
                    let next = characters[i + 1]
                    if next == "\n" {
                        i += 1
                    } else if next == "\r" {
                        i += 1
                        if i + 1 < characters.count, characters[i + 1] == "\n" { i += 1 }
                    } else {
                        current.append(next); hasCurrent = true; i += 1
                    }
                }
            case "'":
                hasCurrent = true
                i += 1
                while i < characters.count, characters[i] != "'" {
                    current.append(characters[i]); i += 1
                }
                guard i < characters.count else { return nil }
            case "\"":
                hasCurrent = true
                i += 1
                while i < characters.count, characters[i] != "\"" {
                    if characters[i] == "\\", i + 1 < characters.count {
                        i += 1
                    }
                    current.append(characters[i]); i += 1
                }
                guard i < characters.count else { return nil }
            case "$":
                if i + 1 < characters.count, characters[i + 1] == "'" {
                    hasCurrent = true
                    i += 2
                    while i < characters.count, characters[i] != "'" {
                        if characters[i] == "\\", i + 1 < characters.count {
                            i += 1
                            switch characters[i] {
                            case "n": current.append("\n")
                            case "t": current.append("\t")
                            case "r": current.append("\r")
                            default: current.append(characters[i])
                            }
                        } else {
                            current.append(characters[i])
                        }
                        i += 1
                    }
                    guard i < characters.count else { return nil }
                } else {
                    current.append(c); hasCurrent = true
                }
            default:
                current.append(c); hasCurrent = true
            }
            i += 1
        }
        flush()
        return tokens
    }

    // MARK: - 重组

    /// 多行反斜杠格式（每个参数一行），读抓包导出的长命令用。
    /// 输出是**归一化**的（-X/-H/-b/-u/--data-raw/-F），不保证与原文逐字相同。
    func formatted() -> String { lines().joined(separator: " \\\n  ") }

    /// 压缩成一行。
    func minified() -> String { lines().joined(separator: " ") }

    private func lines() -> [String] {
        var result: [String] = []
        var head = "curl"
        if let method { head += " -X \(method)" }
        if let url { head += " \(Self.shellQuote(url))" }
        result.append(head)
        for header in headers { result.append("-H \(Self.shellQuote("\(header.name): \(header.value)"))") }
        if let cookie { result.append("-b \(Self.shellQuote(cookie))") }
        if let user { result.append("-u \(Self.shellQuote(user))") }
        for part in dataParts { result.append("--data-raw \(Self.shellQuote(part))") }
        for part in formParts { result.append("-F \(Self.shellQuote(part))") }
        result.append(contentsOf: otherArgs)
        return result
    }

    /// 单引号包裹；内部单引号用 `'\''` 接续 —— shell 里最稳的引法。
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
