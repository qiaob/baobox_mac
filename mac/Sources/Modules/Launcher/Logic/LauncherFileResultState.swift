import Foundation

// 快速入口：文件结果什么时候还要（再）搜（docs/launcher/TECH_DESIGN.md §6.4「合并器」，PR 11）。
// 引擎记着手上的文件结果是哪个请求、几个来源回齐了没有；控制器据此决定发不发、停不停。纯逻辑，进 BaoboxTests。
//
// 2026-11-24 独立验证发现：输入 R，内存来源先交了一批（R 的结果不完整）→ 再打一个字成 R'（R 的搜索被顶掉）→ 退格回到 R。
// 原来的规则把「手上有 R 的结果」当成不用再搜，R 的 Spotlight 结果（连同固定行）就再也不来了，`f ` 前缀下一直「正在查找」。
// 现在：结果不完整也算还要搜；正在跑的就是这个请求时不重发（等它回齐）。

/// 引擎手上的文件结果是哪个请求、所有来源回齐了没有。
struct LauncherFileResultState: Equatable, Sendable {
    let request: LauncherFileSearchRequest
    /// 所有来源都回来了。只回来了一部分、或者换表后作废了（`expired`）为 false。
    var complete: Bool

    /// 这次要的请求还要不要搜：要搜（`wanted` 不为 nil）、而且手上没有它的完整结果 —— 没有结果、结果是别的请求、
    /// 或者只回来了一部分来源。返回要搜的请求，不用搜为 nil。
    static func pending(for wanted: LauncherFileSearchRequest?, have: LauncherFileResultState?) -> LauncherFileSearchRequest? {
        guard let wanted else { return nil }
        if let have, have.request == wanted, have.complete { return nil }
        return wanted
    }

    /// 控制器要不要发起：有要搜的、而且正在跑的不是它。正在跑的同一个请求不重发 —— 它回齐了（`complete`）结果就完整了，
    /// `pending` 变成 nil；它被顶掉了（`inFlight` 变了或成了 nil）才会再发。所以同一个请求不会反复重发。
    static func shouldStart(pending: LauncherFileSearchRequest?, inFlight: LauncherFileSearchRequest?) -> Bool {
        guard let pending else { return false }
        return inFlight != pending
    }

    /// 来源的表换了（扫完了、已知文件 / 剪贴板路径重建了）：手上的结果当成不完整，下次查询会重搜（结果先照旧显示）。
    var expired: LauncherFileResultState {
        LauncherFileResultState(request: request, complete: false)
    }
}
