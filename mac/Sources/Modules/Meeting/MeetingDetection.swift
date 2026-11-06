import Foundation

// 会议检测的纯逻辑（docs/meeting/TECH_DESIGN.md §5，规则 2）：会议 App 在运行 + 麦克风被别人占用 ≥ 10 秒 → 问一次。
// 只依赖 Foundation，可脱离 App 单独编译测试；采样（运行中的 App、麦克风占用）与发气泡在 MeetingDetector.swift。
//
// 麦克风占用只知道「默认输入设备在被用」，不知道是谁在用；所以「同一段占用只问一次」：问的时候在跑的会议 App 都算问过，
// 麦克风空下来 30 秒以上才算这段占用结束。Baobox 自己在录（会议、自由听译、自检）的那段也算问过 ——
// 刚结束记录、会议软件还开着麦克风时不会马上又来问。

enum MeetingDetectionApps {
    /// 专门开会的 App：麦克风被占用时多半就是它在用。
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

    static var all: [String] { dedicated + chat }

    static func isMeetingApp(_ bundleID: String) -> Bool {
        all.contains(bundleID)
    }

    /// 在跑的会议 App（去掉忽略名单里的），按「先问谁」排：前台那个、专门开会的、聊天 App。
    static func candidates(running: [String], frontmost: String?, ignored: Set<String>) -> [String] {
        let present = Set(running).subtracting(ignored)
        var ordered: [String] = []
        if let frontmost, present.contains(frontmost), isMeetingApp(frontmost) {
            ordered.append(frontmost)
        }
        for bundleID in all where present.contains(bundleID) && !ordered.contains(bundleID) {
            ordered.append(bundleID)
        }
        return ordered
    }
}

/// 检测的状态机：每次采样（5 秒）推一步，该问时返回问哪个 App。
struct MeetingDetectionMachine: Equatable {
    /// 麦克风被占用（且有会议 App 在跑）持续这么久才问。
    static let sustain: TimeInterval = 10
    /// 麦克风空了这么久，这一段占用才算结束（会议软件换设备、重开音频时会短暂松开）。
    static let occupancyGap: TimeInterval = 30

    /// 这一段连续占用从什么时候开始（中间断一下就重新计）。
    private(set) var busySince: Date?
    /// 最后一次看到被占用。
    private(set) var lastBusy: Date?
    /// 这一段占用里已经问过（或 Baobox 自己在录）时在跑的 App。
    private(set) var covered: Set<String> = []
    /// 这一段连续占用里，每个 App 是什么时候出现的（中途才打开的 App 要自己满 10 秒）。
    private(set) var appSeen: [String: Date] = [:]

    init() {}

    /// - Parameters:
    ///   - micBusy: 默认输入设备正被使用。
    ///   - baoboxCapturing: Baobox 自己在用麦克风 / 在记录会议（这时分不清是谁在用，不问；这段占用算问过）。
    ///   - candidates: 在跑的会议 App（已去掉忽略名单），按优先级排。
    /// - Returns: 该问的 App（bundle id）；不问为 nil。
    mutating func step(now: Date, micBusy: Bool, baoboxCapturing: Bool, candidates: [String]) -> String? {
        if baoboxCapturing {
            lastBusy = now
            busySince = nil
            appSeen = [:]
            covered.formUnion(candidates)
            return nil
        }
        guard micBusy, !candidates.isEmpty else {
            busySince = nil
            appSeen = [:]
            if let last = lastBusy, now.timeIntervalSince(last) >= Self.occupancyGap {
                lastBusy = nil
                covered = []
            }
            return nil
        }
        if let last = lastBusy, now.timeIntervalSince(last) >= Self.occupancyGap {
            // 上一段占用早就结束了（采样中断过，比如睡眠）：重新算。
            covered = []
        }
        let since = busySince ?? now
        busySince = since
        lastBusy = now
        for app in candidates where appSeen[app] == nil {
            appSeen[app] = now
        }
        let eligible = candidates.first { app in
            guard !covered.contains(app) else { return false }
            let start = max(since, appSeen[app] ?? now)
            return now.timeIntervalSince(start) >= Self.sustain
        }
        guard let pick = eligible else { return nil }
        covered.formUnion(candidates)
        return pick
    }
}
