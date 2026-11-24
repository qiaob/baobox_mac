import Foundation

// 快速入口的输入分类（docs/launcher/TECH_DESIGN.md §5.4）：输入是网址、邮箱、颜色、英文单词、一大段文字还是别的 ——
// 决定排在最前的「对应建议」（打开网址、写邮件、颜色换算、字数）和兜底建议里哪些动作适用、哪些提前。
// 只看这段文字本身：纯函数、不碰磁盘不联网，每次按键跑一次。只依赖 Foundation，进 BaoboxTests。

/// 一次输入的分类结果。
struct LauncherInputClassification: Equatable, Sendable {
    /// 去首尾空白后的输入。
    let text: String
    /// 属于哪一类（目前最多一类，见 `LauncherTextKind`）；空 = 不出任何建议（空输入、路径）。
    let kinds: Set<LauncherTextKind>
    /// 以 `/` 或 `~` 开头：路径的事归路径那一路（文件 / 路径行），这里不出任何建议。
    var isPath = false
    /// 是网址时，打开用的地址（没写 scheme 的已补上：域名补 `https://`，localhost 和 IP 补 `http://`）。
    var url: URL?
    /// 是邮箱时，地址本身（`mailto:` 已去掉）。
    var email: String?
    /// 是颜色时，解析出的颜色。
    var color: LauncherColor?
}

enum LauncherInputClassifier {
    /// 不少于这么多个字符算「一大段文字」。输入框是单行的，粘进来的换行会被换成空格（探针实测），所以只能按长度认。
    static let longTextLength = 80
    /// 单词 / 短语最多几个词、最多几个字符（同划词助手「学习」出词典卡的门槛 `LearnText.isWordLike`）。
    static let maxWordCount = 3
    static let maxWordLength = 40

    /// 分类。优先级：路径（不出建议）> 网址 > 邮箱 > 颜色 > 英文单词 / 短语 > 一大段文字 > 其余。
    static func classify(_ input: String) -> LauncherInputClassification {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return LauncherInputClassification(text: "", kinds: []) }
        if text.hasPrefix("/") || text.hasPrefix("~") {
            return LauncherInputClassification(text: text, kinds: [], isPath: true)
        }
        if let url = LauncherURLDetector.url(from: text) {
            return LauncherInputClassification(text: text, kinds: [.url], url: url)
        }
        if let email = LauncherURLDetector.email(from: text) {
            return LauncherInputClassification(text: text, kinds: [.email], email: email)
        }
        if let color = LauncherColor.parse(text) {
            return LauncherInputClassification(text: text, kinds: [.color], color: color)
        }
        if isWordLike(text) {
            return LauncherInputClassification(text: text, kinds: [.word])
        }
        if isLong(text) {
            return LauncherInputClassification(text: text, kinds: [.longText])
        }
        return LauncherInputClassification(text: text, kinds: [.plainText])
    }

    /// 1–3 个英文词：每个词以英文字母开头，只含英文字母、连字符、撇号（' 或 ’），词之间是空格；最多 40 个字符。
    static func isWordLike(_ text: String) -> Bool {
        guard text.utf8.count <= maxWordLength * 3, text.unicodeScalars.count <= maxWordLength else { return false }
        let words = text.split(separator: " ")
        guard (1...maxWordCount).contains(words.count) else { return false }
        return words.allSatisfy { word in
            guard let first = word.unicodeScalars.first, isASCIILetter(first) else { return false }
            return word.unicodeScalars.allSatisfy { isASCIILetter($0) || $0 == "'" || $0 == "’" || $0 == "-" }
        }
    }

    /// 不少于 80 个字符，或者带换行（别的路子交来的原文）。数到第 80 个就停，几 MB 的粘贴也不用整段数。
    static func isLong(_ text: String) -> Bool {
        text.index(text.startIndex, offsetBy: longTextLength, limitedBy: text.endIndex) != nil
            || text.contains(where: \.isNewline)
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }
}

/// 认网址和邮箱。不带 scheme 的域名判断保守：顶级域名在常见表里才算，免得把 `TECH_DESIGN.md`、`file.txt`、`v2.0` 当成网址。
enum LauncherURLDetector {
    static let maxURLLength = 2048

    /// 不写 scheme 时认的顶级域名（小写）。只收常见的；和常见文件扩展名撞车的国家域名（md、sh、py、rs、pl、mo、ar、in…）
    /// 不收 —— 宁可让 `foo.md` 不出「打开」，也不把文件名当网址。
    static let knownTopLevelDomains: Set<String> = [
        // 通用
        "com", "net", "org", "edu", "gov", "mil", "int", "info", "biz", "name", "pro",
        "io", "dev", "app", "ai", "co", "me", "cc", "tv", "xyz", "top", "site", "online", "tech", "store", "shop",
        "blog", "cloud", "wiki", "news", "live", "link", "page", "fun", "club", "vip", "work", "art", "design",
        "one", "so", "ly", "gg", "fm", "im", "to",
        // 国家和地区
        "cn", "hk", "tw", "sg", "jp", "kr", "us", "uk", "ca", "au", "nz", "de", "fr", "it", "es", "nl", "se", "no",
        "fi", "dk", "ch", "at", "be", "ru", "ua", "br", "mx", "eu", "asia", "my", "th", "vn", "ph", "id",
    ]

    /// 不当网址打开的 scheme（会执行脚本或带内联数据）。
    private static let blockedSchemes: Set<String> = ["javascript", "data", "vbscript"]

    /// 是网址就给出打开用的地址，否则 nil。输入已去首尾空白。
    /// - `scheme://…`（scheme 是字母开头的字母数字 `+-.`）：原样（`http` / `https` 要有主机部分）。
    /// - 不带 scheme：`主机[:端口][/路径][?查询][#片段]`，主机是 `localhost`、IPv4 或「几段 + 常见顶级域名」的域名。
    static func url(from text: String) -> URL? {
        guard !text.isEmpty, text.utf8.count <= maxURLLength, !text.contains(where: \.isWhitespace) else { return nil }
        if let separator = text.range(of: "://") {
            let scheme = text[..<separator.lowerBound]
            let rest = text[separator.upperBound...]
            guard isScheme(scheme), !blockedSchemes.contains(scheme.lowercased()), let first = rest.first else { return nil }
            if ["http", "https"].contains(scheme.lowercased()), "/?#".contains(first) { return nil }
            return URL(string: text)
        }
        guard let scheme = schemeForBareHost(text) else { return nil }
        return URL(string: scheme + "://" + text)
    }

    /// 邮箱（可带 `mailto:`）：本地部分是字母数字和 `._%+-`（不以点开头或结尾、不连着两个点），
    /// 域名至少两段、每段字母数字和连字符、顶级域名是两个以上的字母。返回去掉 `mailto:` 的地址。
    static func email(from text: String) -> String? {
        var address = Substring(text)
        guard address.utf8.count <= 254 + 7 else { return nil }
        if address.prefix(7).lowercased() == "mailto:" { address = address.dropFirst(7) }
        guard address.utf8.count <= 254, !address.contains(where: \.isWhitespace) else { return nil }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let local = parts[0]
        guard (1...64).contains(local.count), local.first != ".", local.last != ".", !local.contains(".."),
              local.unicodeScalars.allSatisfy({ isASCIIAlphanumeric($0) || "._%+-".unicodeScalars.contains($0) })
        else { return nil }
        let labels = parts[1].lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(isHostLabel), let tld = labels.last, tld.count >= 2,
              tld.unicodeScalars.allSatisfy(isASCIILetter) else { return nil }
        return String(address)
    }

    /// 不带 scheme 时该补哪个：域名 `https`，localhost 和 IPv4 `http`；不是网址为 nil。
    private static func schemeForBareHost(_ text: String) -> String? {
        let hostEnd = text.firstIndex(where: { "/?#".contains($0) }) ?? text.endIndex
        let hostAndPort = text[..<hostEnd]
        guard !hostAndPort.isEmpty, !hostAndPort.contains("@") else { return nil }
        var host = hostAndPort
        if let colon = hostAndPort.firstIndex(of: ":") {
            let port = hostAndPort[hostAndPort.index(after: colon)...]
            guard (1...5).contains(port.count), port.allSatisfy({ ("0"..."9").contains($0) }),
                  let number = Int(port), (1...65_535).contains(number) else { return nil }
            host = hostAndPort[..<colon]
        }
        let lower = host.lowercased()
        if lower == "localhost" { return "http" }
        if isIPv4(lower) { return "http" }
        return isKnownDomain(lower) ? "https" : nil
    }

    /// 四段 0–255 的数字（`192.168.1.1`）。
    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            (1...3).contains(part.count) && part.allSatisfy { ("0"..."9").contains($0) } && (Int(part) ?? 256) <= 255
        }
    }

    /// 至少两段，每段合法，最后一段在常见顶级域名表里。
    private static func isKnownDomain(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(isHostLabel), let tld = labels.last else { return false }
        return knownTopLevelDomains.contains(String(tld))
    }

    /// 域名的一段：1–63 个小写字母、数字、连字符，不以连字符开头或结尾。
    private static func isHostLabel(_ label: Substring) -> Bool {
        guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
        return label.unicodeScalars.allSatisfy { isASCIIAlphanumeric($0) || $0 == "-" }
    }

    /// scheme：字母开头，之后是字母、数字、`+`、`-`、`.`，至少两个字符（`c://` 不算）。
    private static func isScheme(_ scheme: Substring) -> Bool {
        guard scheme.count >= 2, let first = scheme.unicodeScalars.first, isASCIILetter(first) else { return false }
        return scheme.unicodeScalars.allSatisfy { isASCIIAlphanumeric($0) || "+-.".unicodeScalars.contains($0) }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || ("0"..."9").contains(scalar)
    }
}
