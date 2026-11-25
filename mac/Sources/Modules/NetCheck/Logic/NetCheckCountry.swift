import Foundation

/// 国家归成 ISO 3166 两位代码再比（docs/netcheck/COMPARE.md §2「国家按代码比」）：真机上 bash.ws 写 `USA`、
/// ipapi.is 写 `United States`，按名字比会把同一个国家算成两个。只依赖 Foundation，进 BaoboxTests。
enum NetCheckCountry {
    /// 系统认得的两位地区代码（大写）。
    static let isoCodes: Set<String> = Set(Locale.Region.isoRegions.map(\.identifier).filter { code in
        code.count == 2 && code.allSatisfy { $0.isASCII && $0.isUppercase }
    })

    /// 常见的另一种写法 → 代码（地区表里的英文名之外的）。键已经是 `normalize` 过的。
    private static let aliases: [String: String] = [
        "usa": "US", "u.s.": "US", "u.s.a.": "US", "united states of america": "US", "america": "US",
        "uk": "GB", "u.k.": "GB", "great britain": "GB", "britain": "GB", "england": "GB",
        "russia": "RU", "russian federation": "RU",
        "south korea": "KR", "korea": "KR", "republic of korea": "KR", "korea, republic of": "KR",
        "north korea": "KP",
        "vietnam": "VN", "viet nam": "VN",
        "hong kong": "HK", "hong kong sar": "HK", "hong kong sar china": "HK", "hongkong": "HK",
        "taiwan": "TW", "taiwan, province of china": "TW",
        "macau": "MO", "macao": "MO", "macao sar": "MO", "macau sar": "MO", "macao sar china": "MO",
        "czechia": "CZ", "czech republic": "CZ",
        "uae": "AE", "united arab emirates": "AE",
        "the netherlands": "NL", "holland": "NL",
        "turkey": "TR", "türkiye": "TR", "turkiye": "TR",
        "iran": "IR", "iran, islamic republic of": "IR",
        "laos": "LA", "syria": "SY", "moldova": "MD", "bolivia": "BO", "venezuela": "VE", "tanzania": "TZ",
        "ivory coast": "CI", "côte d’ivoire": "CI", "cote d'ivoire": "CI",
        // macOS 的 en_US 地区名是「China mainland」（2026-11 实测），回包里写的是「China」
        "china": "CN", "mainland china": "CN", "people's republic of china": "CN", "prc": "CN",
    ]

    /// 地区表里的英文名（`en_US`）→ 代码，建一次。
    private static let englishNames: [String: String] = {
        let english = Locale(identifier: "en_US")
        var table: [String: String] = [:]
        for code in isoCodes {
            guard let name = english.localizedString(forRegionCode: code) else { continue }
            table[normalize(name)] = code
        }
        return table
    }()

    /// 小写、去首尾空白、中间连续空白并成一个。
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 两位代码（大写）：回包给的代码认得就用它；否则用名字查（名字本身是两位代码也认）。认不出 nil。
    static func code(_ given: String?, name: String) -> String? {
        if let given = validCode(given) { return given }
        let key = normalize(name)
        guard !key.isEmpty else { return nil }
        if let code = validCode(key) { return code }
        return aliases[key] ?? englishNames[key]
    }

    /// 比较用的键：有代码用代码，没有用名字（小写、去空白）；两样都没有 nil（不参加比较）。
    static func key(code given: String?, name: String) -> String? {
        if let code = code(given, name: name) { return code }
        let key = normalize(name)
        return key.isEmpty ? nil : "name:" + key
    }

    private static func validCode(_ text: String?) -> String? {
        guard let text else { return nil }
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return code.count == 2 && isoCodes.contains(code) ? code : nil
    }
}
