import Foundation

/// 测速的状态：进行中的阶段与这一刻的数、上次结果。只在用户点了才测（docs/netcheck/SPEED.md §1.5），
/// 结果只在内存里：窗口重开还在，退出 Baobox 就没了。同一时刻只跑一次，和 IP 检测不并行。
@MainActor
final class NetSpeedTestSession: ObservableObject {
    static let shared = NetSpeedTestSession()

    @Published private(set) var running = false
    /// 进行中的阶段（没在测时 nil）
    @Published private(set) var phase: NetSpeedPhase?
    /// 这一刻的数：延迟段是秒，下载 / 上传段是字节 / 秒
    @Published private(set) var liveValue: Double?
    /// 这一段的进度（0…1）
    @Published private(set) var phaseFraction: Double = 0
    @Published private(set) var result: NetSpeedResult?

    private var test: NetSpeedTest?
    private var runID = 0

    private init() {}

    /// 整次测速的进度（0…1）：延迟很快，按 1 : 4.5 : 4.5 分。
    var overallFraction: Double {
        guard let phase else { return 0 }
        let weights: [Double] = [0.1, 0.45, 0.45]
        let before = weights.prefix(phase.rawValue).reduce(0, +)
        return min(1, before + weights[phase.rawValue] * min(1, max(0, phaseFraction)))
    }

    /// 开始一次。已经在测、或 IP 检测正在跑时不起（两者不并行）。
    func start() {
        guard !running, !NetCheckSession.shared.running else { return }
        runID += 1
        let id = runID
        running = true
        phase = .latency
        liveValue = nil
        phaseFraction = 0
        let test = NetSpeedTest { [weak self] event in
            self?.handle(event, runID: id)
        }
        self.test = test
        test.start()
    }

    /// 停下（点「停止」、关窗口、退出 App）：这次作废，上次的结果留着。
    func stop() {
        guard running else { return }
        runID += 1
        test?.cancel()
        test = nil
        running = false
        phase = nil
        liveValue = nil
        phaseFraction = 0
    }

    private func handle(_ event: NetSpeedTest.Event, runID id: Int) {
        guard id == runID, running else { return }
        switch event {
        case .phase(let next):
            phase = next
            liveValue = nil
            phaseFraction = 0
        case .progress(let current, let value, let fraction):
            guard current == phase else { return }
            if let value { liveValue = value }
            phaseFraction = fraction
        case .finished(let outcome):
            result = outcome
            test = nil
            running = false
            phase = nil
            liveValue = nil
            phaseFraction = 0
        }
    }
}
