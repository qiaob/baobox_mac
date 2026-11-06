import Foundation

// 会议检测的纯逻辑（docs/meeting/TECH_DESIGN.md §5，规则 2）：只依赖 Foundation，可脱离 App 单独编译测试；
// 采样（运行中的进程、谁在用麦克风）在 MeetingMicrophoneUsage.swift / MeetingDetector.swift，发气泡在 MeetingDetector.swift。
//
// 每个会议 App 单独判断「是不是正在开会」，信号两种：
// - 会议进程：会议 App 开会时才起的进程开着（如钉钉的 Tblive）—— 入会就静音也算，看到 2 秒就问；
// - 麦克风：按进程查出来是这个 App（含它包里的辅助进程）在录音 —— 专门开会的 App 连续 2 秒、聊天 App 连续 10 秒才问
//   （浏览器在录音、窗口标题又是会议网站 —— Google Meet、Teams 网页版等 —— 算这个网站在开会，同专门开会的 App；
//   这一轮录音里认出过一次就一直算，见 `MeetingWebLatch`）
//   （微信语音消息、Slack 试麦这类短占用不算）。说不清是谁在录（WebKit 网页通话、系统不支持按进程查）时只算到前台的会议 App。
// 麦克风一被占用就采样、在用期间每秒采样（MeetingDetector，借鉴 Notion），所以进会两三秒就能问到。
// 同一场只问一次（同时有几个 App 在开会也只弹一个）：信号断开不超过一段时间还算同一场（会议进程 15 秒；麦克风 3 分钟 —— 有的软件静音时会松开麦克风）。
// Baobox 自己在记录会议时，正在开的会都算问过（结束记录后同一场不再来问）；Baobox 在用麦克风做别的（听写、字幕、自检）
// 或在录屏时先不问，结束后再问。
//
// 2026-11-06 真机：钉钉开会起的是包里的 Tblive.app，入会后麦克风只用了 6 秒就松开（静音），
// 原来「会议 App 在跑 + 默认麦克风被占用满 10 秒」的规则问不到；而 Slack、微信常驻时，浏览器开会又会被算到它们头上。

enum MeetingDetectionApps {
    /// 专门开会的 App：麦克风被它用着多半就是在开会。
    static let dedicated = [
        "us.zoom.xos",
        "com.tencent.meeting",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark",
        "com.apple.FaceTime",
    ]
    /// 平时一直开着、偶尔用来开会的聊天 App：排在后面，前台是谁就先问谁。
    static let chat = [
        "com.alibaba.DingTalkMac",
        "com.electron.lark",
        "com.bytedance.feishu",
        "com.bytedance.macos.feishu",
        "com.tencent.xinWeChat",
        "com.tinyspeck.slackmacgap",
    ]
    /// 会议 App 开会时才起的进程（bundle id）→ 所属 App。它开着就是在开会，静音也算。
    static let meetingProcesses: [String: String] = [
        "5ZSL2CJU2T.com.dingtalk.mac.tblive": "com.alibaba.DingTalkMac",
        "5ZSL2CJU2T.com.dingtalk.meeting": "com.alibaba.DingTalkMac",
    ]

    /// 先问谁的顺序：专门开会的 App、浏览器里的会议网站、聊天 App。
    static var all: [String] { dedicated + MeetingWebSites.keys + chat }

    /// 会议 App 或浏览器里的会议网站（`MeetingWebSites` 的 key）。
    static func isMeetingApp(_ bundleID: String) -> Bool {
        all.contains(bundleID)
    }

    /// 用麦克风 2 秒就问的（专门开会的 App、会议网站）；其余（聊天 App）要 10 秒。
    static func isDedicated(_ bundleID: String) -> Bool {
        dedicated.contains(bundleID) || MeetingWebSites.keys.contains(bundleID)
    }

    /// 按「先问谁」排（只留会议 App）：前台那个、专门开会的、聊天 App。
    static func ordered(_ apps: Set<String>, frontmost: String?) -> [String] {
        var ordered: [String] = []
        if let frontmost, apps.contains(frontmost), isMeetingApp(frontmost) {
            ordered.append(frontmost)
        }
        for bundleID in all where apps.contains(bundleID) && !ordered.contains(bundleID) {
            ordered.append(bundleID)
        }
        return ordered
    }

    /// 进程可执行文件所在的最外层 .app：辅助进程算进宿主 App
    /// （…/DingTalk.app/Contents/Frameworks/Tblive.app/Contents/MacOS/Tblive → …/DingTalk.app）。
    /// 系统目录里的（WebKit 的 GPU 进程等，说不清是替谁录的）返回 nil。
    static func hostAppPath(forExecutable path: String) -> String? {
        guard !path.hasPrefix("/System/"), !path.hasPrefix("/usr/") else { return nil }
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// 这一次采样里各会议 App 的信号（已去掉忽略名单）。
    /// - Parameters:
    ///   - runningBundleIDs: 在跑的进程的 bundle id（找会议进程）。
    ///   - microphoneApps: 在录音的进程所属 App 的 bundle id（不含 Baobox 自己）。
    ///   - unattributedMicrophone: 有进程在录音但说不清是谁（只算到前台的会议 App 头上）。
    ///   - webMeetings: 在用麦克风的浏览器窗口标题认出来的会议网站（`MeetingWebSites` 的 key）。
    static func signals(runningBundleIDs: [String], microphoneApps: Set<String>, unattributedMicrophone: Bool,
                        webMeetings: Set<String> = [], frontmost: String?, ignored: Set<String>) -> [String: MeetingSignal] {
        var result: [String: MeetingSignal] = [:]
        for bundleID in runningBundleIDs {
            if let owner = meetingProcesses[bundleID] { result[owner] = .meetingProcess }
        }
        for app in microphoneApps where isMeetingApp(app) && result[app] == nil {
            result[app] = .microphone
        }
        for site in webMeetings where MeetingWebSites.keys.contains(site) {
            result[site] = .microphone
        }
        if unattributedMicrophone, let frontmost, isMeetingApp(frontmost), result[frontmost] == nil {
            result[frontmost] = .microphone
        }
        for app in ignored {
            result[app] = nil
        }
        return result
    }
}

/// 浏览器里开的会（2026-11-06 真机：Google Meet 在 Chrome 里开，录音的是 Chrome 的音频辅助进程）。
/// 浏览器用麦克风不一定是开会（网页录音、语音输入），所以还要窗口标题是会议网站 —— 标题就是当前标签页的标题。
enum MeetingWebSites {
    /// 浏览器（bundle id）。
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "company.thebrowser.Browser", "com.brave.Browser", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
    ]

    /// 会议网站的 key（当作「会议 App」的 id 用：检测记录、忽略名单都按它）。
    static let meet = "web.meet"
    static let teams = "web.teams"
    static let zoom = "web.zoom"
    static let tencent = "web.tencentmeeting"
    static let feishu = "web.feishu"
    static let webex = "web.webex"
    static let jitsi = "web.jitsi"
    static let keys = [meet, teams, zoom, tencent, feishu, webex, jitsi]

    /// 从窗口标题认会议网站。浏览器会在标题后面加「 - Google Chrome」「 - 用户名」之类，所以前缀按第一段判断。
    static func site(forTitle title: String) -> String? {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var head = text
        for separator in [" - ", " – ", " — ", " | "] {
            if let range = head.range(of: separator) { head = String(head[..<range.lowerBound]) }
        }
        // Google Meet 会议中的标签页标题：「Meet - abc-defg-hij」「Meet – 会议名」；落地页「Google Meet」。
        if text.contains("Google Meet") || head == "Meet" || text.hasPrefix("Meet - ") || text.hasPrefix("Meet – ")
            || text.hasPrefix("Meet — ") {
            return meet
        }
        if text.contains("Microsoft Teams") { return teams }
        let zoomHeads = ["Zoom", "Zoom Meeting", "Zoom Meetings", "Zoom Webinar", "Zoom Workplace", "Zoom 会议"]
        if zoomHeads.contains(head) { return zoom }
        if text.contains("腾讯会议") || text.contains("VooV Meeting") || text.contains("Tencent Meeting") { return tencent }
        if text.contains("飞书会议") || text.contains("Feishu Meetings") || text.contains("Lark Meetings")
            || text.contains("Lark Meeting") { return feishu }
        if text.contains("Webex") { return webex }
        if text.contains("Jitsi Meet") { return jitsi }
        return nil
    }

    /// 这些窗口标题里认出来的会议网站。
    static func sites(inTitles titles: [String]) -> Set<String> {
        Set(titles.compactMap(site(forTitle:)))
    }
}

/// 浏览器里认出过的会议网站，在这个浏览器这一轮用麦克风期间一直算数；浏览器松开麦克风就忘掉，下一轮重新认。
/// 2026-11-06 真机：Chrome 入会那一下标题认出了 Google Meet，5 秒后同一个窗口的标题就认不出了（切了标签页或标题变了），
/// 连续计时被打断，一直没问。说不清是谁在录（Safari 由 WebKit 的 GPU 进程录音）时认在前台浏览器头上，说不清的录音停了才忘。
struct MeetingWebLatch: Equatable {
    private struct Entry: Equatable {
        var sites: Set<String>
        /// 是按「说不清是谁在录 + 前台是这个浏览器」认上的。
        var unattributed: Bool
    }

    private var entries: [String: Entry] = [:]

    init() {}

    /// 用这次采样更新，返回现在算在开会的会议网站（`MeetingWebSites` 的 key）。
    /// - Parameters:
    ///   - recordingBrowsers: 按进程查出来在录音的浏览器。
    ///   - unattributed: 有说不清是谁的进程在录音。
    ///   - matches: 这次各浏览器窗口标题认出来的会议网站（含说不清时的前台浏览器）。
    mutating func update(recordingBrowsers: Set<String>, unattributed: Bool,
                         matches: [String: Set<String>]) -> Set<String> {
        entries = entries.filter { browser, entry in
            recordingBrowsers.contains(browser) || (entry.unattributed && unattributed)
        }
        for (browser, found) in matches where !found.isEmpty {
            var entry = entries[browser] ?? Entry(sites: [], unattributed: false)
            entry.sites.formUnion(found)
            entry.unattributed = !recordingBrowsers.contains(browser)
            entries[browser] = entry
        }
        return entries.values.reduce(into: Set<String>()) { $0.formUnion($1.sites) }
    }
}

/// 一个会议 App「正在开会」的依据。
enum MeetingSignal: Equatable {
    /// 会议 App 开会时才起的进程开着。
    case meetingProcess
    /// 这个 App 在用麦克风。
    case microphone
}

/// 检测的状态机：每次采样推一步（有人在用麦克风时每秒一次，平时 5 秒），该问时返回问哪个 App。每个 App 一条记录（一场会）。
struct MeetingDetectionMachine: Equatable {
    /// 会议进程开着这么久就问。
    static let processSustain: TimeInterval = 2
    /// 专门开会的 App（含会议网站）连续用麦克风这么久才问：短到进会就问，又能滤掉一闪而过的试麦。
    static let dedicatedMicrophoneSustain: TimeInterval = 2
    /// 聊天 App 连续用麦克风这么久才问（语音消息、试麦不算）。
    static let chatMicrophoneSustain: TimeInterval = 10
    /// 会议进程退出这么久，这一场才算结束（下一场接着开也能问到）。
    static let processGap: TimeInterval = 15
    /// 麦克风松开这么久，这一场才算结束（静音时有的软件会松开麦克风，解除静音不该再问一遍）。
    static let microphoneGap: TimeInterval = 180

    struct Track: Equatable {
        /// 这一次连续出现信号从什么时候开始；最近一次采样没有信号为 nil。
        var runSince: Date?
        /// 最后一次看到信号。
        var lastSeen: Date
        /// 最后一次看到的信号。
        var signal: MeetingSignal
        /// 这一场问过了（或 Baobox 记录过）。
        var asked: Bool
    }

    /// 正在开（或刚结束、还在宽限期里）的会，按 App。
    private(set) var tracks: [String: Track] = [:]

    init() {}

    static func sustain(_ signal: MeetingSignal, app: String) -> TimeInterval {
        switch signal {
        case .meetingProcess: return processSustain
        case .microphone: return MeetingDetectionApps.isDedicated(app) ? dedicatedMicrophoneSustain : chatMicrophoneSustain
        }
    }

    static func gap(_ signal: MeetingSignal) -> TimeInterval {
        switch signal {
        case .meetingProcess: return processGap
        case .microphone: return microphoneGap
        }
    }

    /// - Parameters:
    ///   - signals: 这次采样里各会议 App 的信号（`MeetingDetectionApps.signals`）。
    ///   - frontmost: 前台 App（先问它）。
    ///   - recordingMeeting: Baobox 正在记录会议：正在开的会都算问过，不问。
    ///   - holdOff: Baobox 在用麦克风做别的（听写、字幕、自检）或在录屏：先不问，之后再问。
    /// - Returns: 该问的 App（bundle id）；不问为 nil。
    mutating func step(now: Date, signals: [String: MeetingSignal], frontmost: String?,
                       recordingMeeting: Bool, holdOff: Bool) -> String? {
        for (app, track) in tracks where signals[app] == nil {
            var track = track
            track.runSince = nil
            tracks[app] = track
        }
        for (app, signal) in signals {
            if var track = tracks[app], now.timeIntervalSince(track.lastSeen) < Self.gap(track.signal) {
                if track.runSince == nil { track.runSince = now }
                track.lastSeen = now
                track.signal = signal
                tracks[app] = track
            } else {
                tracks[app] = Track(runSince: now, lastSeen: now, signal: signal, asked: false)
            }
        }
        tracks = tracks.filter { now.timeIntervalSince($0.value.lastSeen) < Self.gap($0.value.signal) }

        if recordingMeeting {
            for app in tracks.keys { tracks[app]?.asked = true }
            return nil
        }
        guard !holdOff else { return nil }
        for app in MeetingDetectionApps.ordered(Set(signals.keys), frontmost: frontmost) {
            guard let track = tracks[app], !track.asked, let since = track.runSince,
                  now.timeIntervalSince(since) >= Self.sustain(track.signal, app: app) else { continue }
            // 一次只问一个：这会儿同时在开的也算问过（不接着弹第二个气泡）；之后才开的会照样问。
            for active in signals.keys { tracks[active]?.asked = true }
            return app
        }
        return nil
    }
}
