import Foundation

/// 事件触发的用量刷新的节流：距上次放行满 `interval` 秒才马上放行；窗口里来的请求不丢，在窗口结束时补刷一次（只补一次，不叠加）。
///
/// 用量 Store 基类 `CLIUsageStore.refreshThrottledFromEvent` 用它：Claude Code 助手收到 hook 事件（回合结束 / 等你确认）时
/// （#109 B1，docs/codex-assistant/DEDUPE.md §5.1），Codex 助手收到回合完成的 notify 事件时（#164 PR4 起，之前是只节流不补刷，
/// 60 秒内的第二回合直接丢，DEDUPE-P2.md §7 D6）。回合中途刚因等确认刷过、几十秒后回合结束，那次的用量也能在窗口结束时刷到。
/// 只做判断，不碰定时器与磁盘：补刷的定时器由调用方按 `.trailing(at:)` 排、到点调 `fireTrailing`。调用方在主线程持有一个实例。
struct CLIUsageRefreshThrottle {
    /// 一次请求的结论。
    enum Decision: Equatable {
        /// 现在就刷（已记作放行）。
        case now
        /// 窗口里被拦下了：到这个时刻补刷一次。调用方排一个定时器（延迟不超过 `interval`），到点调 `fireTrailing`。
        case trailing(at: Date)
        /// 这个窗口已经排了补刷：什么也不用做。
        case alreadyScheduled
    }

    /// 两次放行之间至少隔多久（秒）。
    let interval: TimeInterval
    /// 上次放行（马上刷或补刷）的时刻；还没放行过是 distantPast（第一次一定马上放行）。
    private(set) var lastAllowed: Date = .distantPast
    /// 有一次补刷排着、还没到点。
    private(set) var trailingPending = false

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// 来了一次刷新请求：距上次放行 ≥ `interval` 就马上放行（顺带取消排着的补刷）；否则在窗口结束时补一次，已经排了就不再排。
    mutating func request(at now: Date = Date()) -> Decision {
        if now.timeIntervalSince(lastAllowed) >= interval {
            lastAllowed = now
            trailingPending = false
            return .now
        }
        if trailingPending { return .alreadyScheduled }
        trailingPending = true
        return .trailing(at: lastAllowed.addingTimeInterval(interval))
    }

    /// 补刷的定时器到点：有排着的补刷就放行（记作一次放行，下一个窗口从现在算），返回 true；已经被马上放行取代了返回 false。
    mutating func fireTrailing(at now: Date = Date()) -> Bool {
        guard trailingPending else { return false }
        trailingPending = false
        lastAllowed = now
        return true
    }
}
