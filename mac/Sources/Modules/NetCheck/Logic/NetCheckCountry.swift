import Foundation

/// 国家归成 ISO 3166 两位代码再比（docs/netcheck/COMPARE.md §2「国家按代码比」）：真机上 bash.ws 写 `USA`、
/// ipapi.is 写 `United States`，按名字比会把同一个国家算成两个。只依赖 Foundation，进 BaoboxTests。
///
/// 名字查代码前两边做同样的折叠（`fold`）：小写、去音调符号、撇号统一、`&` → `and`、`st.` → `saint`、去掉开头的 `the`、
/// 压缩空白；括号里的部分先留着查一次（`Congo (Kinshasa)`），查不到再去掉查（`Myanmar (Burma)`）。
/// 还查不到：ISO 的倒装写法（`Korea, Republic of`）倒回来再查；「Republic of X」「Kingdom of X」这类前缀去掉再查。
enum NetCheckCountry {
    /// 系统认得的两位地区代码（大写）。
    static let isoCodes: Set<String> = Set(Locale.Region.isoRegions.map(\.identifier).filter { code in
        code.count == 2 && code.allSatisfy { $0.isASCII && $0.isUppercase }
    })

    /// 常见的另一种写法 → 代码（地区表里的英文名之外的）。键是 `fold` 过的。
    /// 比通用的前缀规则先查：`democratic people's republic of korea` 去掉前缀会变成 `korea`（那是 KR）。
    private static let aliases: [String: String] = [
        "usa": "US", "u.s.": "US", "u.s.a.": "US", "united states of america": "US", "america": "US",
        "uk": "GB", "u.k.": "GB", "great britain": "GB", "britain": "GB", "england": "GB",
        "russia": "RU", "russian federation": "RU",
        "south korea": "KR", "korea": "KR", "republic of korea": "KR",
        "north korea": "KP", "dprk": "KP", "democratic people's republic of korea": "KP",
        "vietnam": "VN", "viet nam": "VN",
        "hong kong": "HK", "hong kong sar": "HK", "hong kong sar china": "HK", "hongkong": "HK",
        "taiwan": "TW", "taiwan, province of china": "TW", "republic of china": "TW",
        "macau": "MO", "macao": "MO", "macao sar": "MO", "macau sar": "MO", "macao sar china": "MO",
        // macOS 的 en_US 地区名是「China mainland」（2026-11 实测），回包里写的是「China」
        "china": "CN", "mainland china": "CN", "people's republic of china": "CN", "prc": "CN",
        "czechia": "CZ", "czech republic": "CZ",
        "uae": "AE", "united arab emirates": "AE",
        "netherlands": "NL", "holland": "NL",
        "turkey": "TR", "turkiye": "TR",
        "iran": "IR",
        "myanmar": "MM", "burma": "MM",
        "congo": "CG", "congo republic": "CG", "republic of the congo": "CG", "congo brazzaville": "CG",
        "dr congo": "CD", "drc": "CD", "democratic republic of the congo": "CD", "congo kinshasa": "CD",
        "congo the": "CG", "democratic republic of congo": "CD", "congo drc": "CD", "congo dr": "CD", "drc congo": "CD",
        "palestine": "PS", "palestinian territory": "PS", "palestinian territories": "PS",
        "brunei": "BN", "brunei darussalam": "BN",
        "cabo verde": "CV", "cape verde": "CV",
        "moldova": "MD",
        "macedonia": "MK", "north macedonia": "MK", "former yugoslav republic of macedonia": "MK",
        "swaziland": "SZ", "eswatini": "SZ",
        "east timor": "TL", "timor-leste": "TL", "timor leste": "TL",
        "laos": "LA", "lao people's democratic republic": "LA", "lao pdr": "LA",
        "syria": "SY", "syrian arab republic": "SY",
        "bolivia": "BO", "venezuela": "VE", "tanzania": "TZ",
        "micronesia": "FM", "federated states of micronesia": "FM",
        "vatican": "VA", "holy see": "VA", "vatican city state": "VA",
        "ivory coast": "CI", "cote d'ivoire": "CI",
    ]

    /// 地区表里的英文名（`en_US`，折叠过）→ 代码，建一次。
    private static let englishNames: [String: String] = {
        var table: [String: String] = [:]
        for (code, name) in englishNameList() {
            table[fold(name)] = code
        }
        return table
    }()

    /// 系统地区表里每个两位代码和它的英文名（测试用它做全量自检）。
    static func englishNameList() -> [(code: String, name: String)] {
        let english = Locale(identifier: "en_US")
        return isoCodes.sorted().compactMap { code in
            english.localizedString(forRegionCode: code).map { (code, $0) }
        }
    }

    /// 折叠：小写、去音调符号、撇号统一、`&` → `and`、`st.` / `st` → `saint`、括号（`keepParenthesized` 时只去括号本身，
    /// 否则连里面的字一起去掉）、去掉开头的 `the`、压缩空白。
    static func fold(_ text: String, keepParenthesized: Bool = false) -> String {
        var value = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX")).lowercased()
        for apostrophe in ["’", "‘", "`", "´", "ʼ"] {
            value = value.replacingOccurrences(of: apostrophe, with: "'")
        }
        value = value.replacingOccurrences(of: "&", with: " and ")
        if keepParenthesized {
            value = value.replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ")
        } else {
            value = value.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        }
        var words = value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        words = words.map { $0 == "st." || $0 == "st" ? "saint" : $0 }
        if words.first == "the" { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// 小写、去首尾空白、中间连续空白并成一个（认不出代码时的比较键）。
    static func normalize(_ text: String) -> String {
        fold(text, keepParenthesized: true)
    }

    /// 两位代码（大写）：回包给的代码认得就用它；否则用名字查（名字本身是两位代码也认）。认不出 nil。
    static func code(_ given: String?, name: String) -> String? {
        if let given = validCode(given) { return given }
        let kept = fold(name, keepParenthesized: true)
        guard !kept.isEmpty else { return nil }
        if let code = validCode(kept) { return code }
        for candidate in variants(of: name) {
            if let code = aliases[candidate] ?? englishNames[candidate] { return code }
        }
        return nil
    }

    /// 去括号、去前缀之后只剩这几个词时不认：它们各对应两个国家（`Korea (North)`、`Democratic Republic of Congo`
    /// 去掉修饰后只剩 `korea` / `congo`，会被认成 KR / CG）。原文本身就是这个词时照常认（`Congo` → CG）。
    private static let ambiguousRoots: Set<String> = ["congo", "korea"]

    /// 依次要查的写法：留括号 → 括号里的倒到前面（`Korea (the Democratic People's Republic of)`）→ 去括号 →
    /// ISO 倒装倒回来 → 去掉「Republic of」这类前缀。
    private static func variants(of name: String) -> [String] {
        var list: [String] = []
        let kept = fold(name, keepParenthesized: true)
        func add(_ text: String) {
            guard !text.isEmpty, !list.contains(text) else { return }
            if text != kept, ambiguousRoots.contains(text) { return }
            list.append(text)
        }
        let stripped = fold(name)
        add(kept)
        // `X (Y)` → `Y X`：ISO 现行短名把修饰放在括号里（`Congo (the Democratic Republic of the)`）
        if let open = name.firstIndex(of: "("), let close = name.lastIndex(of: ")"), open < close {
            let outer = String(name[..<open]) + String(name[name.index(after: close)...])
            let inner = String(name[name.index(after: open)..<close])
            add(fold(inner + " " + outer))
        }
        add(stripped)
        // `Korea, Republic of` → `Republic of Korea`；`Congo, The Democratic Republic of the` → `Democratic Republic of the Congo`
        for base in [kept, stripped] {
            let parts = base.components(separatedBy: ", ")
            if parts.count == 2 { add(fold(parts[1] + " " + parts[0])) }
        }
        // `Republic of Lithuania`、`Hashemite Kingdom of Jordan`、`Islamic Republic of Iran` → 去掉前缀
        for base in list {
            if let range = base.range(of: #"^(?:[a-z' ]+ )?(?:republic|kingdom|state|states|commonwealth|federation|principality|sultanate|emirate|grand duchy|union) of "#,
                                      options: .regularExpression) {
                add(fold(String(base[range.upperBound...])))
            }
        }
        return list
    }

    /// 比较用的键：有代码用代码，没有用名字（折叠过）；两样都没有 nil（不参加比较）。
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
