import Foundation

/// 额度提醒（用到预算 80%）的防重状态：同一个窗口只提醒一次；之前提醒过的窗口过去了、换成了新窗口，
/// 报一次「窗口已切换」（Claude 据此可选发「额度已恢复」，Codex 不发）。
///
/// 只判断该不该提醒，不读设置也不发通知 —— 预算从哪读、通知怎么发留给各模块。5h 与周窗口各用一个实例，互不干扰。
struct CLIUsageBudgetReminder {
    /// 一次检查的结论。
    struct Outcome: Equatable {
        /// 之前提醒过的窗口已经过去（防重记录随之清空）。
        var windowChanged = false
        /// 这次刚用到提醒线：用量占预算的百分比（四舍五入）；nil = 这次不提醒。
        var reachedPercent: Int?
    }

    /// 提醒线：用到预算的 80%。
    static let threshold = 0.8

    /// 已提醒过的窗口起点。
    private(set) var remindedStarts: Set<Date> = []

    /// 拿一个窗口的最新用量检查一次。`budget <= 0`（未设预算）时什么都不做。
    mutating func check(windowStart: Date, totalTokens: Int, budget: Int) -> Outcome {
        var outcome = Outcome()
        guard budget > 0 else { return outcome }
        // 清掉非当前窗口的旧记录，顺带识别「窗口切换」。
        if !remindedStarts.contains(windowStart), remindedStarts.contains(where: { $0 != windowStart }) {
            outcome.windowChanged = true
            remindedStarts = []
        }
        let ratio = Double(totalTokens) / Double(budget)
        if ratio >= Self.threshold, !remindedStarts.contains(windowStart) {
            remindedStarts.insert(windowStart)
            outcome.reachedPercent = Int((ratio * 100).rounded())
        }
        return outcome
    }
}
