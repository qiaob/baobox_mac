import Foundation

// 快速入口的前缀解析（docs/launcher/TECH_DESIGN.md §5；需求见 REQUIREMENTS.md §3.2「只搜一类」）：
// 输入开头打一个来源前缀再空格，只搜那一类。只依赖 Foundation，进 BaoboxTests。

/// 一次输入拆成的「只搜哪一类 + 查询词」。
struct LauncherQuery: Equatable, Sendable {
    /// 只搜这个来源（来源 id）；nil = 没有前缀，搜全部。
    let sourceID: String?
    /// 查询词：去掉前缀和首尾空白。
    let text: String

    /// 出厂前缀：键是来源 id、值是前缀（与设置键 `launcher.prefix.<来源 id>` 同一方向，TECH_DESIGN.md §11）。
    static let defaultPrefixBySource: [String: String] = [
        "apps": "a",
        "clipboard": "c",
        "files": "f",
        "sessions": "s",
        "meetings": "m",
        "windows": "w",
    ]

    /// 拆前缀。规则：
    /// - 输入**开头**是某个前缀（不分大小写），后面紧跟一个空白字符（空格；全角空格也算）才算。
    ///   只有前缀没有空格（"a"）、前缀后面紧跟别的字（"app"）、前缀前面先有空白（" a x"）都不算，整段当查询词。
    /// - 前缀为空（设置里关掉了这个来源的前缀）不参与。
    /// - 两个来源的前缀相同（不分大小写）时按来源 id 排序取第一个，结果稳定、不随字典顺序变。
    /// - 查询词去掉首尾空白；"a " 得到「只搜 App、查询词为空」。
    static func parse(_ input: String,
                      prefixBySource: [String: String] = defaultPrefixBySource) -> LauncherQuery {
        for (sourceID, rawPrefix) in prefixBySource.sorted(by: { $0.key < $1.key }) {
            let prefix = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prefix.isEmpty, let rest = remainder(of: input, afterPrefix: prefix) else { continue }
            return LauncherQuery(sourceID: sourceID, text: trimmed(rest))
        }
        return LauncherQuery(sourceID: nil, text: trimmed(input))
    }

    /// `input` 以「`prefix`（不分大小写）+ 一个空白字符」开头时，返回那个空白之后的部分；否则 nil。
    /// 按字符（Character）比，不先整串 lowercased —— 有的字符变小写后长度会变，下标就对不上了。
    private static func remainder(of input: String, afterPrefix prefix: String) -> Substring? {
        guard let separator = input.index(input.startIndex, offsetBy: prefix.count, limitedBy: input.endIndex),
              separator < input.endIndex,
              input[separator].isWhitespace,
              input[..<separator].lowercased() == prefix.lowercased()
        else { return nil }
        return input[input.index(after: separator)...]
    }

    private static func trimmed<S: StringProtocol>(_ text: S) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
