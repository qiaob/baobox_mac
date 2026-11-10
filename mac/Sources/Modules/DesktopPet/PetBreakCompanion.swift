import AppKit

// MARK: - 休息画面的主角（BreakCompanion，docs/notify-core/DESIGN.md §3.5）

/// 宠物替框架当休息画面的主角：借出渲染视图（`lendRenderView`），交给 `PetBreakLoan` 按意图摆姿势。
/// 宠物关着、没就绪、正在换形象时借不到（返回 nil），休息画面走回退画面。
extension PetController: BreakCompanion {
    func lend() -> BreakCompanionLoan? {
        lendRenderView().map { PetBreakLoan($0, owner: self) }
    }
}

/// 借给休息画面的宠物：把休息画面给的意图换成每一帧的 `PetPose`，每秒推 30 次（2D 帧动画靠它走）。
/// 姿态逐行照搬原来 BreakStage 的 `pushPose`：那边按「休息画面在哪个阶段」算，这里按「最近收到的意图」算 ——
/// 休息画面在阶段切换的那一刻发意图，两者一一对应（docs/notify-core/DESIGN.md §3.5 的表）。
@MainActor
final class PetBreakLoan: BreakCompanionLoan {
    let view: NSView
    let homeFrame: NSRect
    let maxUpscale: CGFloat?

    private let owner: PetController
    /// 新借出的自带一份新姿态，等于原来飞出去时的那次重置（`pose = PetPose()`）；飞回来不重置，接着上一帧的 time / walkPhase。
    private var pose = PetPose()
    /// 最近收到的意图；nil = 借出后还没收到，不推（同原来等待出场的阶段）。
    private var current: BreakCompanionCue?
    /// 收到「休息」的那一刻（原来是 BreakStage 的 restingSince，同一时刻）：前 1.2 秒先转过来看你。
    private var restingSince = Date()
    private var timer: Timer?
    private var returned = false

    init(_ loan: PetController.Loan, owner: PetController) {
        view = loan.view
        homeFrame = loan.frame
        // 3D 形象实时渲染，放大照样清晰；2D 帧图只有几十像素，超过原尺寸 3 倍就糊。
        maxUpscale = loan.is3D ? nil : 3
        self.owner = owner
        // 节奏同原来 BreakStage 的 poseTimer：1/30 秒、.common 模式（菜单开着也走），借出时开、归还时停。
        // 不复用宠物引擎的帧定时器：引擎会随系统睡眠 suspend（PetEngine.suspend），复用的话行为会变。
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.pushPose()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cue(_ cue: BreakCompanionCue) {
        guard !returned else { return }
        current = cue
        switch cue {
        case .walking(let facingLeft):
            // 飞到中央（原 flyIn）/ 飞回原位（原 finish）：侧身走，朝着要去的方向。
            pose.state = .wander
            pose.facingLeft = facingLeft
        case .resting:
            restingSince = Date()
        case .attentive:
            break
        }
    }

    func poke() {
        guard !returned else { return }
        owner.performLent("poke")
    }

    func giveBack() {
        guard !returned else { return }
        returned = true
        timer?.invalidate()
        timer = nil
        view.removeFromSuperview()
        owner.returnRenderView()
    }

    // MARK: - 姿态（30fps 推送；2D 帧动画靠它走）

    private func pushPose() {
        let now = Date()
        pose.time = now.timeIntervalSinceReferenceDate
        switch current {
        case .walking?:
            pose.state = .wander
            pose.walkPhase += 9.0 / 30.0
            pose.attentive = false
            pose.lying = false
            pose.eyesClosed = false
            pose.bob = 0
        case .resting(let lookAway)?:
            if now.timeIntervalSince(restingSince) < 1.2 {
                // 先转过来看你一眼。
                pose.state = .idle
                pose.attentive = true
            } else if lookAway {
                // 护眼：侧过身去看远处。
                pose.state = .idle
                pose.attentive = false
                pose.facingLeft = false
            } else {
                pose.state = .sleep
            }
            pose.lying = pose.state == .sleep
            pose.eyesClosed = pose.state == .sleep
            pose.bob = pose.state == .idle ? CGFloat(sin(pose.time * 1.7)) * 1.4 : 0
        case .attentive?:
            // 休息好了 / 等你确认：站着面向你。
            pose.state = .idle
            pose.attentive = true
            pose.lying = false
            pose.eyesClosed = false
            pose.bob = CGFloat(sin(pose.time * 1.7)) * 1.4
        case nil:
            return
        }
        owner.setLentPose(pose)
    }
}
