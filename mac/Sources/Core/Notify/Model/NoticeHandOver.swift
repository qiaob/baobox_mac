import Foundation

extension Notice {
    /// 呈现端没了（关掉宠物）时，这条还挂着 / 还在排队的通知要不要转成系统通知（#144）。`shown` = 已经在气泡里露过面。
    /// - 操作回执不转：只在当下有意义，事后冒出来按钮也早过期了（同它从不攒进勿扰摘要）。
    /// - 常驻、带按钮的转：还等着用户处理（推迟、进入会议……），丢了就点不了了。
    /// - 没露过面的转，轻提示除外：用户还没看到过；轻提示几秒就消失，本来就可有可无。
    /// - 露过面的普通卡片不转：用户已经看过，再来一条系统通知是重复。
    func handsOver(shown: Bool) -> Bool {
        guard !isUserFeedback else { return false }
        if resolvedStyle == .sticky || !actions.isEmpty { return true }
        return !shown && level != .ambient
    }
}
