import AppKit

/// 休息画面里主角此刻在做什么（docs/notify-core/DESIGN.md §3.5）。休息画面只说意图；怎么摆姿势、播哪段动画，归主角自己。
enum BreakCompanionCue: Equatable {
    /// 飞到中央 / 飞回原位：侧身走。
    case walking(facingLeft: Bool)
    /// 倒计时开始：先转过来看你一眼（约 1.2 秒），再躺下。`lookAway` = 护眼：侧身看远处，不躺。
    case resting(lookAway: Bool)
    /// 休息好了 / 等你确认本人：站着面向你。
    case attentive
}

/// 借出来的主角（目前是桌面宠物的渲染视图）。休息画面把 `view` 装进自己的舞台窗，按需缩放、飞来飞去，结束时 `giveBack()`。
@MainActor
protocol BreakCompanionLoan: AnyObject {
    var view: NSView { get }
    /// 主角原来在屏幕上的位置与大小：飞出去的起点、飞回来的终点。
    var homeFrame: NSRect { get }
    /// 最多能放大到原尺寸的几倍还清晰；nil = 不限（3D 是实时渲染的）。
    var maxUpscale: CGFloat? { get }
    /// 换个意图：休息画面在阶段切换的那一刻发。借出后、收到第一个意图之前，主角不动。
    func cue(_ cue: BreakCompanionCue)
    /// 被戳了一下（点大宠物 / 点暗处）：做个小动作，做不了就算了。
    func poke()
    /// 还回去，只认第一次调用。调用前休息画面要先摘掉自己的勿扰令牌：否则主角那边还按勿扰睡着，
    /// 还回去会先躺下再爬起来（docs/notify-core/DESIGN.md §5.1）。
    func giveBack()
}

/// 能当休息画面主角的东西（目前是桌面宠物）。模块用 `ToolModule.presentationRoles()` 交出来，框架在启动时装进
/// `PresentationHub`；休息画面经它借，不认识提供者。不在场（关着、没就绪、正在换形象）就返回 nil，休息画面走回退画面。
@MainActor
protocol BreakCompanion: AnyObject {
    func lend() -> BreakCompanionLoan?
}
