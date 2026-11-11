import Foundation

/// 通知内核的账本（纯逻辑，docs/notify-core/DESIGN.md §4 PR 5）：来源开关、去重、记历史、勿扰时攒不攒、勿扰解除后的摘要。
/// 只做判断和记账，不碰窗口、声音、系统通知、定时器、本地化；时间和设置都由调用方传进来（不读 UserDefaults，不调 `Date()`）。
/// `NotifyCenter` 在主线程持有一个：投递时问 `post`，按结论呈现 / 攒着（并开摘要定时器）/ 丢掉；定时器到点问 `flush`，有摘要就呈现。
struct NotifyLedger {
    /// 同来源同去重 key 多久内只呈现一次（秒）。从上一次放行算起，被挡下的不顺延。
    static let dedupeWindow: TimeInterval = 30
    /// 摘要正文最多列几个标题。
    static let digestTitleLimit = 3

    /// 历史里的一条（`history` 新的在前）。
    struct HistoryEntry: Equatable {
        let date: Date
        let source: String
        let level: Notice.Level
        let title: String
        /// 1 + 被去重挡下、并到这一条的次数。
        var mergeCount: Int
    }

    /// 勿扰时攒着的一条。投稿方的回调原样留着、从不调用，出摘要时随这一条一起丢掉（摘要不带按钮）。
    struct Held {
        let notice: Notice
        let onAction: ((String) -> Void)?
    }

    /// 勿扰解除后补的一条摘要：攒了几条、前 3 个标题。标题文案（带条数）由调用方本地化。
    struct Digest: Equatable {
        let count: Int
        let titles: [String]
        /// 摘要正文：前 3 个标题用「、」连起来。
        var body: String { titles.joined(separator: "、") }
    }

    /// 投递一条的结论。
    enum Decision: Equatable {
        /// 现在呈现（宠物气泡还是系统通知，由调用方看呈现端定）。
        case deliver
        /// 勿扰中，攒起来了：调用方确保摘要定时器在跑。
        case hold
        /// 丢掉，什么也不呈现。
        case drop(DropReason)
    }

    enum DropReason: Equatable {
        /// 这个来源在设置里关了。
        case sourceDisabled
        /// 30 秒内同来源同 key 已经放行过一条。
        case duplicate
    }

    /// 摘要定时器到点时的结论。
    enum Flush: Equatable {
        /// 没攒着东西：调用方停掉定时器。
        case nothingHeld
        /// 还在勿扰：定时器接着跑，下次再问。
        case stillSuppressed
        /// 勿扰解除：攒着的已经清空、换成这一条摘要。调用方停掉定时器，呈现摘要。
        case digest(Digest)
    }

    /// 最近的通知，新的在前，最多 `historyLimit` 条（投递时传入）。
    private(set) var history: [HistoryEntry] = []
    /// 勿扰时攒着的，按投递顺序。
    private(set) var held: [Held] = []
    /// 每个「来源|去重 key」上一次放行的时刻。
    private var lastPostAt: [String: Date] = [:]

    /// 投递一条，按顺序判：
    /// 1. 来源关了 → 丢，什么都不记（不进历史，也不开去重窗口）。
    /// 2. 带去重 key、同来源同 key 上一次放行不到 30 秒 → 丢，历史里最近一条同来源同标题的计数 +1（标题不同就找不到、不加）；
    ///    否则记下这次放行的时刻（之后被攒起来也算放行过）。
    /// 3. 记进历史（新的在前），超出 `historyLimit` 的从最旧的裁掉。
    /// 4. 勿扰中、又不是 alert 也不是操作回执 → 攒着；否则现在呈现。
    ///
    /// `isSuppressed` 只在走到第 4 步时问一次（alert、回执也问）：实际是 `NotifyDND.isSuppressed`，要遍历窗口列表查全屏，
    /// 被丢掉的通知不用查。
    mutating func post(_ notice: Notice, onAction: ((String) -> Void)?, at now: Date,
                       sourceEnabled: Bool, historyLimit: Int, isSuppressed: () -> Bool) -> Decision {
        guard sourceEnabled else { return .drop(.sourceDisabled) }

        if let key = notice.dedupeKey {
            let id = notice.source + "|" + key
            if let last = lastPostAt[id], now.timeIntervalSince(last) < Self.dedupeWindow {
                if let index = history.firstIndex(where: { $0.source == notice.source && $0.title == notice.title }) {
                    history[index].mergeCount += 1
                }
                return .drop(.duplicate)
            }
            lastPostAt[id] = now
        }
        record(notice, at: now, limit: historyLimit)

        // 勿扰：alert 照常呈现（宠物路径本身不额外发声，见 NotifyCenter.deliver）；操作回执也照常呈现，录屏中同样 ——
        // 起初录屏时把回执也攒了起来（免得录进视频），结果录屏中暂停专注什么都看不到，录完才跟着摘要一起冒出来
        // （2026-11-08 用户反馈）。环形菜单本身就会被录进去，跟着出一句回执不算多。其余攒着，勿扰解除后合并成摘要。
        let showsAnyway = notice.level == .alert || notice.isUserFeedback
        if isSuppressed(), !showsAnyway {
            held.append(Held(notice: notice, onAction: onAction))
            return .hold
        }
        return .deliver
    }

    /// 摘要定时器到点：没攒着东西 → `.nothingHeld`；还在勿扰 → `.stillSuppressed`；
    /// 否则清空攒着的，换成一条摘要（条数 + 前 3 个标题）。摘要不进历史，也不过来源开关和去重。
    mutating func flush(isSuppressed: Bool) -> Flush {
        guard !held.isEmpty else { return .nothingHeld }
        guard !isSuppressed else { return .stillSuppressed }
        let digest = Digest(count: held.count, titles: held.prefix(Self.digestTitleLimit).map(\.notice.title))
        held.removeAll()
        return .digest(digest)
    }

    private mutating func record(_ notice: Notice, at now: Date, limit: Int) {
        history.insert(
            HistoryEntry(date: now, source: notice.source, level: notice.level, title: notice.title, mergeCount: 1),
            at: 0
        )
        if history.count > limit {
            history.removeLast(history.count - limit)
        }
    }
}
