import Foundation

// 时区句型用的地名表（docs/launcher/TECH_DESIGN.md §7「时区」）：常用城市（中文名 + 英文名）→ IANA 时区，
// 另认 IANA 名（`Asia/Tokyo`，不分大小写）、常见缩写（PST / SGT / JST…）和 `UTC+8` 写法。
// 缩写按字面的固定偏移算（PST 永远是 UTC-8，夏天也是）；要跟着夏令时走就写城市名或 IANA 名。
// CST（中国 / 美国中部）、IST 以外的歧义缩写不收；IST 按印度。

struct LauncherCalcPlace {
    let zh: String
    let en: String
    let identifier: String
    /// 其他写法（英文存小写）。
    var aliases: [String] = []
}

/// 解析出来的一个时区：显示名 + TimeZone。
struct LauncherCalcZone {
    let timeZone: TimeZone
    let zh: String
    let en: String

    func name(_ context: LauncherCalcContext) -> String { context.text(zh, en) }
}

enum LauncherCalcPlaces {
    static let cities: [LauncherCalcPlace] = [
        LauncherCalcPlace(zh: "北京", en: "Beijing", identifier: "Asia/Shanghai", aliases: ["peking"]),
        LauncherCalcPlace(zh: "上海", en: "Shanghai", identifier: "Asia/Shanghai"),
        LauncherCalcPlace(zh: "广州", en: "Guangzhou", identifier: "Asia/Shanghai"),
        LauncherCalcPlace(zh: "深圳", en: "Shenzhen", identifier: "Asia/Shanghai"),
        LauncherCalcPlace(zh: "杭州", en: "Hangzhou", identifier: "Asia/Shanghai"),
        LauncherCalcPlace(zh: "成都", en: "Chengdu", identifier: "Asia/Shanghai"),
        LauncherCalcPlace(zh: "中国", en: "China", identifier: "Asia/Shanghai"),
        LauncherCalcPlace(zh: "香港", en: "Hong Kong", identifier: "Asia/Hong_Kong", aliases: ["hongkong"]),
        LauncherCalcPlace(zh: "澳门", en: "Macau", identifier: "Asia/Macau", aliases: ["macao"]),
        LauncherCalcPlace(zh: "台北", en: "Taipei", identifier: "Asia/Taipei"),
        LauncherCalcPlace(zh: "新加坡", en: "Singapore", identifier: "Asia/Singapore"),
        LauncherCalcPlace(zh: "东京", en: "Tokyo", identifier: "Asia/Tokyo"),
        LauncherCalcPlace(zh: "大阪", en: "Osaka", identifier: "Asia/Tokyo"),
        LauncherCalcPlace(zh: "日本", en: "Japan", identifier: "Asia/Tokyo"),
        LauncherCalcPlace(zh: "首尔", en: "Seoul", identifier: "Asia/Seoul"),
        LauncherCalcPlace(zh: "韩国", en: "Korea", identifier: "Asia/Seoul", aliases: ["south korea"]),
        LauncherCalcPlace(zh: "曼谷", en: "Bangkok", identifier: "Asia/Bangkok"),
        LauncherCalcPlace(zh: "泰国", en: "Thailand", identifier: "Asia/Bangkok"),
        LauncherCalcPlace(zh: "河内", en: "Hanoi", identifier: "Asia/Ho_Chi_Minh"),
        LauncherCalcPlace(zh: "胡志明市", en: "Ho Chi Minh City", identifier: "Asia/Ho_Chi_Minh", aliases: ["saigon"]),
        LauncherCalcPlace(zh: "越南", en: "Vietnam", identifier: "Asia/Ho_Chi_Minh"),
        LauncherCalcPlace(zh: "雅加达", en: "Jakarta", identifier: "Asia/Jakarta"),
        LauncherCalcPlace(zh: "吉隆坡", en: "Kuala Lumpur", identifier: "Asia/Kuala_Lumpur"),
        LauncherCalcPlace(zh: "马尼拉", en: "Manila", identifier: "Asia/Manila"),
        LauncherCalcPlace(zh: "新德里", en: "New Delhi", identifier: "Asia/Kolkata", aliases: ["delhi"]),
        LauncherCalcPlace(zh: "孟买", en: "Mumbai", identifier: "Asia/Kolkata"),
        LauncherCalcPlace(zh: "班加罗尔", en: "Bangalore", identifier: "Asia/Kolkata", aliases: ["bengaluru"]),
        LauncherCalcPlace(zh: "印度", en: "India", identifier: "Asia/Kolkata"),
        LauncherCalcPlace(zh: "迪拜", en: "Dubai", identifier: "Asia/Dubai"),
        LauncherCalcPlace(zh: "利雅得", en: "Riyadh", identifier: "Asia/Riyadh"),
        LauncherCalcPlace(zh: "德黑兰", en: "Tehran", identifier: "Asia/Tehran"),
        LauncherCalcPlace(zh: "特拉维夫", en: "Tel Aviv", identifier: "Asia/Jerusalem"),
        LauncherCalcPlace(zh: "伊斯坦布尔", en: "Istanbul", identifier: "Europe/Istanbul"),
        LauncherCalcPlace(zh: "莫斯科", en: "Moscow", identifier: "Europe/Moscow"),
        LauncherCalcPlace(zh: "开罗", en: "Cairo", identifier: "Africa/Cairo"),
        LauncherCalcPlace(zh: "约翰内斯堡", en: "Johannesburg", identifier: "Africa/Johannesburg"),
        LauncherCalcPlace(zh: "内罗毕", en: "Nairobi", identifier: "Africa/Nairobi"),
        LauncherCalcPlace(zh: "拉各斯", en: "Lagos", identifier: "Africa/Lagos"),
        LauncherCalcPlace(zh: "伦敦", en: "London", identifier: "Europe/London"),
        LauncherCalcPlace(zh: "英国", en: "UK", identifier: "Europe/London", aliases: ["united kingdom", "britain"]),
        LauncherCalcPlace(zh: "都柏林", en: "Dublin", identifier: "Europe/Dublin"),
        LauncherCalcPlace(zh: "里斯本", en: "Lisbon", identifier: "Europe/Lisbon"),
        LauncherCalcPlace(zh: "巴黎", en: "Paris", identifier: "Europe/Paris"),
        LauncherCalcPlace(zh: "法国", en: "France", identifier: "Europe/Paris"),
        LauncherCalcPlace(zh: "柏林", en: "Berlin", identifier: "Europe/Berlin"),
        LauncherCalcPlace(zh: "慕尼黑", en: "Munich", identifier: "Europe/Berlin"),
        LauncherCalcPlace(zh: "法兰克福", en: "Frankfurt", identifier: "Europe/Berlin"),
        LauncherCalcPlace(zh: "德国", en: "Germany", identifier: "Europe/Berlin"),
        LauncherCalcPlace(zh: "阿姆斯特丹", en: "Amsterdam", identifier: "Europe/Amsterdam"),
        LauncherCalcPlace(zh: "布鲁塞尔", en: "Brussels", identifier: "Europe/Brussels"),
        LauncherCalcPlace(zh: "苏黎世", en: "Zurich", identifier: "Europe/Zurich"),
        LauncherCalcPlace(zh: "日内瓦", en: "Geneva", identifier: "Europe/Zurich"),
        LauncherCalcPlace(zh: "罗马", en: "Rome", identifier: "Europe/Rome"),
        LauncherCalcPlace(zh: "米兰", en: "Milan", identifier: "Europe/Rome"),
        LauncherCalcPlace(zh: "马德里", en: "Madrid", identifier: "Europe/Madrid"),
        LauncherCalcPlace(zh: "巴塞罗那", en: "Barcelona", identifier: "Europe/Madrid"),
        LauncherCalcPlace(zh: "维也纳", en: "Vienna", identifier: "Europe/Vienna"),
        LauncherCalcPlace(zh: "布拉格", en: "Prague", identifier: "Europe/Prague"),
        LauncherCalcPlace(zh: "华沙", en: "Warsaw", identifier: "Europe/Warsaw"),
        LauncherCalcPlace(zh: "斯德哥尔摩", en: "Stockholm", identifier: "Europe/Stockholm"),
        LauncherCalcPlace(zh: "奥斯陆", en: "Oslo", identifier: "Europe/Oslo"),
        LauncherCalcPlace(zh: "哥本哈根", en: "Copenhagen", identifier: "Europe/Copenhagen"),
        LauncherCalcPlace(zh: "赫尔辛基", en: "Helsinki", identifier: "Europe/Helsinki"),
        LauncherCalcPlace(zh: "雅典", en: "Athens", identifier: "Europe/Athens"),
        LauncherCalcPlace(zh: "纽约", en: "New York", identifier: "America/New_York", aliases: ["nyc"]),
        LauncherCalcPlace(zh: "波士顿", en: "Boston", identifier: "America/New_York"),
        LauncherCalcPlace(zh: "华盛顿", en: "Washington", identifier: "America/New_York", aliases: ["washington dc"]),
        LauncherCalcPlace(zh: "多伦多", en: "Toronto", identifier: "America/Toronto"),
        LauncherCalcPlace(zh: "芝加哥", en: "Chicago", identifier: "America/Chicago"),
        LauncherCalcPlace(zh: "休斯顿", en: "Houston", identifier: "America/Chicago"),
        LauncherCalcPlace(zh: "达拉斯", en: "Dallas", identifier: "America/Chicago"),
        LauncherCalcPlace(zh: "丹佛", en: "Denver", identifier: "America/Denver"),
        LauncherCalcPlace(zh: "凤凰城", en: "Phoenix", identifier: "America/Phoenix"),
        LauncherCalcPlace(zh: "洛杉矶", en: "Los Angeles", identifier: "America/Los_Angeles", aliases: ["la"]),
        LauncherCalcPlace(zh: "旧金山", en: "San Francisco", identifier: "America/Los_Angeles", aliases: ["sf"]),
        LauncherCalcPlace(zh: "硅谷", en: "Silicon Valley", identifier: "America/Los_Angeles"),
        LauncherCalcPlace(zh: "西雅图", en: "Seattle", identifier: "America/Los_Angeles"),
        LauncherCalcPlace(zh: "温哥华", en: "Vancouver", identifier: "America/Vancouver"),
        LauncherCalcPlace(zh: "檀香山", en: "Honolulu", identifier: "Pacific/Honolulu"),
        LauncherCalcPlace(zh: "墨西哥城", en: "Mexico City", identifier: "America/Mexico_City"),
        LauncherCalcPlace(zh: "圣保罗", en: "Sao Paulo", identifier: "America/Sao_Paulo"),
        LauncherCalcPlace(zh: "布宜诺斯艾利斯", en: "Buenos Aires", identifier: "America/Argentina/Buenos_Aires"),
        LauncherCalcPlace(zh: "利马", en: "Lima", identifier: "America/Lima"),
        LauncherCalcPlace(zh: "悉尼", en: "Sydney", identifier: "Australia/Sydney"),
        LauncherCalcPlace(zh: "墨尔本", en: "Melbourne", identifier: "Australia/Melbourne"),
        LauncherCalcPlace(zh: "布里斯班", en: "Brisbane", identifier: "Australia/Brisbane"),
        LauncherCalcPlace(zh: "珀斯", en: "Perth", identifier: "Australia/Perth"),
        LauncherCalcPlace(zh: "奥克兰", en: "Auckland", identifier: "Pacific/Auckland"),
    ]

    /// 地名 → 城市（英文名、别名存小写）。
    private static let byName: [String: LauncherCalcPlace] = {
        var table: [String: LauncherCalcPlace] = [:]
        for city in cities {
            for name in [city.zh, city.en.lowercased()] + city.aliases where table[name] == nil {
                table[name] = city
            }
        }
        return table
    }()

    static let cityNames = Set(byName.keys)

    /// 缩写 → 相对 UTC 的固定秒数。
    private static let abbreviations: [String: Int] = [
        "utc": 0, "gmt": 0, "wet": 0, "bst": 3_600, "cet": 3_600, "cest": 7_200, "eet": 7_200, "eest": 10_800,
        "msk": 10_800, "ist": 19_800, "ict": 25_200, "wib": 25_200,
        "sgt": 28_800, "hkt": 28_800, "pht": 28_800, "awst": 28_800, "bjt": 28_800,
        "jst": 32_400, "kst": 32_400, "aest": 36_000, "aedt": 39_600, "nzst": 43_200, "nzdt": 46_800,
        "hst": -36_000, "akst": -32_400, "akdt": -28_800, "pst": -28_800, "pdt": -25_200,
        "mst": -25_200, "mdt": -21_600, "est": -18_000, "edt": -14_400,
    ]

    /// 不带标准 / 夏令之分的笼统叫法：跟着夏令时走。
    private static let genericAbbreviations: [String: String] = [
        "pt": "America/Los_Angeles", "et": "America/New_York",
    ]

    private static let ianaByLowercase: [String: String] = {
        var table: [String: String] = [:]
        for identifier in TimeZone.knownTimeZoneIdentifiers { table[identifier.lowercased()] = identifier }
        return table
    }()

    static let cjkNames: Set<String> = Set(cities.map(\.zh))

    // MARK: - 解析

    /// 从游标处读一个时区：UTC±偏移、IANA 名、城市名（最多 4 个词）、缩写。读到就前进。
    static func zone(_ cursor: inout LauncherCalcCursor) -> LauncherCalcZone? {
        if let offset = utcOffset(&cursor) { return offset }
        if let iana = ianaName(&cursor) { return iana }
        if let phrase = cursor.take(phraseIn: cityNames, maxTokens: 4), let city = byName[phrase],
           let timeZone = TimeZone(identifier: city.identifier) {
            return LauncherCalcZone(timeZone: timeZone, zh: city.zh, en: city.en)
        }
        guard let token = cursor.current, let word = token.word else { return nil }
        if let seconds = abbreviations[word], let timeZone = TimeZone(secondsFromGMT: seconds) {
            cursor.advance()
            return LauncherCalcZone(timeZone: timeZone, zh: word.uppercased(), en: word.uppercased())
        }
        if let identifier = genericAbbreviations[word], let timeZone = TimeZone(identifier: identifier) {
            cursor.advance()
            return LauncherCalcZone(timeZone: timeZone, zh: word.uppercased(), en: word.uppercased())
        }
        return nil
    }

    /// `UTC+8`、`GMT-3`、`UTC+5:30`、`UTC + 08:00`。只有 `UTC` / `GMT` 没有偏移时交给缩写表。
    private static func utcOffset(_ cursor: inout LauncherCalcCursor) -> LauncherCalcZone? {
        guard let head = cursor.current?.word, head == "utc" || head == "gmt",
              let signToken = cursor.peek(1), signToken.isSymbol("+") || signToken.isSymbol("-"),
              let amount = cursor.peek(2) else { return nil }
        var hours = 0
        var minutes = 0
        if case .clock(let h, let m) = amount.kind {
            hours = h
            minutes = m
        } else if let value = amount.decimalInteger, let h = Int(value.description) {
            hours = h
        } else {
            return nil
        }
        guard hours <= 14, minutes < 60, hours * 60 + minutes <= 14 * 60 else { return nil }
        let sign = signToken.isSymbol("-") ? -1 : 1
        guard let timeZone = TimeZone(secondsFromGMT: sign * (hours * 3_600 + minutes * 60)) else { return nil }
        cursor.advance(3)
        let label = offsetLabel(sign * (hours * 3_600 + minutes * 60))
        return LauncherCalcZone(timeZone: timeZone, zh: label, en: label)
    }

    /// `Asia/Tokyo`、`America/Argentina/Buenos_Aires`：词和斜杠紧挨着写。
    private static func ianaName(_ cursor: inout LauncherCalcCursor) -> LauncherCalcZone? {
        guard let first = cursor.current, first.word != nil else { return nil }
        var parts = [first.raw]
        var count = 1
        while let slash = cursor.peek(count), slash.isSymbol("/"), !slash.spaceBefore,
              let next = cursor.peek(count + 1), next.word != nil, !next.spaceBefore, parts.count < 3 {
            parts.append(next.raw)
            count += 2
        }
        guard parts.count >= 2, let identifier = ianaByLowercase[parts.joined(separator: "/").lowercased()],
              let timeZone = TimeZone(identifier: identifier) else { return nil }
        cursor.advance(count)
        return LauncherCalcZone(timeZone: timeZone, zh: identifier, en: identifier)
    }

    /// `UTC+8`、`UTC-3:30`、`UTC+0`。
    static func offsetLabel(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let total = Swift.abs(seconds) / 60
        let hours = total / 60
        let minutes = total % 60
        return minutes == 0 ? "UTC\(sign)\(hours)" : "UTC\(sign)\(hours):\(LauncherCalcFormat.twoDigits(minutes))"
    }
}
