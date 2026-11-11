import Foundation

/// 事件触发的用量刷新的节流：距上次放行满 `interval` 秒才再放行一次；被拦下的请求不顺延，也不补刷。
///
/// Claude Code 助手收到 hook 事件（回合结束 / 等你确认）时用它（#109 B1，docs/codex-assistant/DEDUPE.md §5.1）。
/// Codex 助手的 `CodexUsageStore.refreshThrottledFromEvent` 是同一条规则，还没换过来 —— 留给两个用量 Store 外壳合并的那一步（同上 §5.3）。
/// 只判断该不该刷，不碰定时器与磁盘；调用方在主线程持有一个实例。
struct CLIUsageRefreshThrottle {
    /// 两次放行之间至少隔多久（秒）。
    let interval: TimeInterval
    /// 上次放行的时刻；还没放行过是 distantPast（第一次一定放行）。
    private(set) var lastAllowed: Date = .distantPast

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// 现在刷不刷：距上次放行 ≥ `interval` 才放行，放行即记下 `now`。
    mutating func allow(at now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(lastAllowed) >= interval else { return false }
        lastAllowed = now
        return true
    }
}
