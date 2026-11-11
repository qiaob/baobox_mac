import Foundation

// 从日历事件里找会议链接（docs/meeting/TECH_DESIGN.md §5）。纯函数，只依赖 Foundation，可脱离 App 单独编译测试。
//
// 依次看事件的 URL、地点、备注，返回第一个认得的会议链接：Zoom、腾讯会议、钉钉、Google Meet、Teams、飞书、Webex。
// 备注可能是纯文本也可能是 HTML（Exchange / Outlook 的邀请），链接常被尖括号、括号、中文标点包着，
// 还可能套着 Outlook 安全链接（safelinks）或 Google 跳转 —— 都先剥掉再认。

/// 会议软件。
enum MeetingLinkProvider: String, CaseIterable, Equatable {
    case zoom
    case tencent
    case dingtalk
    case googleMeet
    case teams
    case feishu
    case webex
}

/// 认出来的一个会议链接。
struct MeetingLink: Equatable {
    var provider: MeetingLinkProvider
    var url: URL
}

enum MeetingLinkParser {
    /// 依次看事件的 URL、地点、备注，返回第一个认得的会议链接；都没有为 nil。
    static func find(url: String?, location: String?, notes: String?) -> MeetingLink? {
        for text in [url, location, notes] {
            guard let text, !text.isEmpty else { continue }
            if let link = links(in: text).first { return link }
        }
        return nil
    }

    /// 一段文字里所有认得的会议链接（按出现顺序，同一个只算一次）。
    static func links(in text: String) -> [MeetingLink] {
        guard let candidate = candidatePattern else { return [] }
        // HTML 备注：`&amp;` 还原成 `&`，免得查询参数断掉。
        let source = text.replacingOccurrences(of: "&amp;", with: "&")
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var seen = Set<String>()
        var found: [MeetingLink] = []
        for match in candidate.matches(in: source, options: [], range: range) {
            guard let matched = Range(match.range, in: source) else { continue }
            let raw = cleaned(String(source[matched]))
            guard let url = makeURL(raw), let link = classify(url), seen.insert(link.url.absoluteString).inserted else {
                continue
            }
            found.append(link)
        }
        return found
    }

    /// 一个 URL 是哪家的会议链接（会先剥掉安全链接 / 跳转）；不是会议链接为 nil。
    static func classify(_ url: URL) -> MeetingLink? {
        if let inner = unwrapped(url) {
            return classify(inner)
        }
        guard let provider = provider(of: url) else { return nil }
        return MeetingLink(provider: provider, url: url)
    }

    // MARK: - 候选

    /// 带 scheme 的链接，或者没写 scheme、但域名是会议软件的（地点里常写「meet.google.com/abc-defg-hij」）。
    /// 链接里不会出现的字符（空白、尖括号、引号、中文标点）当边界。
    private static let candidatePattern: NSRegularExpression? = {
        let schemes = "https?|zoommtg|zoomus|wemeet|dingtalk|msteams|webex"
        let hosts = [
            #"zoom\.us"#, #"zoom\.com\.cn"#, #"zoomgov\.com"#, #"meeting\.tencent\.com"#, #"voovmeeting\.com"#,
            #"dingtalk\.com"#, #"meet\.google\.com"#, #"teams\.microsoft\.com"#, #"teams\.live\.com"#,
            #"feishu\.cn"#, #"larksuite\.com"#, #"webex\.com"#,
        ].joined(separator: "|")
        let body = #"[^\s<>"'`{}|\\^\[\]（）【】「」『』《》〈〉，。；！？、“”‘’]+"#
        let pattern = #"(?:\b(?:"# + schemes + #")://|\b(?:[a-z0-9-]+\.)*(?:"# + hosts + #")/)"# + body
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// 去掉粘在链接末尾的标点（句号、逗号、右括号、星号…）；右括号只在不配对时才去掉。
    static func cleaned(_ raw: String) -> String {
        var text = raw
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", "]", "}", ">", "'", "\"", "*", "`", "…"]
        while let last = text.last {
            if trailing.contains(last) {
                text.removeLast()
            } else if last == ")" {
                let opens = text.filter { $0 == "(" }.count
                let closes = text.filter { $0 == ")" }.count
                guard closes > opens else { break }
                text.removeLast()
            } else {
                break
            }
        }
        return text
    }

    private static func makeURL(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        let text = raw.contains("://") ? raw : "https://" + raw
        if let url = URL(string: text), url.scheme != nil { return url }
        // 带中文等非 ASCII 字符：先编码再认。
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#%")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: encoded), url.scheme != nil else { return nil }
        return url
    }

    // MARK: - 剥壳

    /// Outlook 安全链接 `…safelinks.protection.outlook.com/?url=<编码后的原链接>`、
    /// Google 跳转 `google.com/url?q=<原链接>`：取出里面的原链接；不是这两种为 nil。
    private static func unwrapped(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let name: String
        if host.hasSuffix("safelinks.protection.outlook.com") {
            name = "url"
        } else if (host == "www.google.com" || host == "google.com") && url.path == "/url" {
            name = "q"
        } else {
            return nil
        }
        guard let value = components.queryItems?.first(where: { $0.name.lowercased() == name })?.value,
              let inner = URL(string: value), inner.scheme != nil, inner.host?.lowercased() != host else { return nil }
        return inner
    }

    // MARK: - 认是哪家

    private static func provider(of url: URL) -> MeetingLinkProvider? {
        let scheme = url.scheme?.lowercased() ?? ""
        let whole = url.absoluteString.lowercased()
        switch scheme {
        case "zoommtg", "zoomus": return .zoom
        case "wemeet": return .tencent
        case "dingtalk": return .dingtalk
        case "msteams": return whole.contains("meetup-join") ? .teams : nil
        case "webex": return .webex
        case "http", "https": break
        default: return nil
        }
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()

        if matches(host, "zoom.us") || matches(host, "zoom.com.cn") || matches(host, "zoomgov.com") {
            // /j/ 会议号、/my/ 个人会议室、/w/ 网络研讨会、/s/ 发起、/wc/ 网页版入会；/u/（当地拨号号码）等不算。
            let prefixes = ["/j/", "/my/", "/w/", "/s/", "/wc/"]
            return prefixes.contains(where: { path.hasPrefix($0) }) ? .zoom : nil
        }
        if matches(host, "meeting.tencent.com") || matches(host, "voovmeeting.com") {
            return path.hasPrefix("/dm/") || path.hasPrefix("/p/") ? .tencent : nil
        }
        if matches(host, "dingtalk.com") {
            // meeting.dingtalk.com/j/…、…/videoconf/…；钉钉别的页面（文档、审批）不算。
            return host.contains("meeting") || path.contains("meeting") || path.contains("conf") ? .dingtalk : nil
        }
        if host == "meet.google.com" {
            return path.count > 1 ? .googleMeet : nil
        }
        if matches(host, "teams.microsoft.com") {
            return path.contains("/l/meetup-join") || path.hasPrefix("/meet/") ? .teams : nil
        }
        if matches(host, "teams.live.com") {
            return path.hasPrefix("/meet/") ? .teams : nil
        }
        if host == "vc.feishu.cn" || host == "vc.larksuite.com" {
            return path.hasPrefix("/j/") ? .feishu : nil
        }
        if matches(host, "meetings.feishu.cn") || matches(host, "meetings.larksuite.com") {
            return path.count > 1 ? .feishu : nil
        }
        if matches(host, "webex.com") {
            // 邀请末尾常带帮助页（help.webex.com）：官网与帮助页不算。
            let excluded = ["webex.com", "www.webex.com", "help.webex.com", "blog.webex.com"]
            return !excluded.contains(host) && path.count > 1 ? .webex : nil
        }
        return nil
    }

    /// host 就是 domain，或是它的子域名。
    private static func matches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}
