import Foundation

// 会议的混合音源（麦克风 + 系统声音混成一路）与「我 / 对方」判定的纯逻辑（docs/meeting/TECH_DESIGN.md §2.2）。
// 本文件只依赖 Foundation，可脱离 App 单独编译测试；采集、线程与节拍在 LiveTranslateMixedSource.swift。

/// 一路音频的环形缓冲（16 kHz 单声道 Float32 样本）。放不下时丢最早的。
struct LiveTranslateSampleRing {
    private var storage: [Float]
    /// 最早一个样本的位置。
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = [Float](repeating: 0, count: max(1, capacity))
    }

    var capacity: Int { storage.count }

    /// 追加；放不下时先丢最早的。返回丢了多少个。
    @discardableResult
    mutating func append(_ samples: UnsafeBufferPointer<Float>) -> Int {
        var input = samples
        var dropped = 0
        // 一次给的比整个缓冲还多：只留最后 capacity 个。
        if input.count > storage.count {
            dropped += input.count - storage.count + count
            input = UnsafeBufferPointer(rebasing: input[(input.count - storage.count)...])
            head = 0
            count = 0
        }
        let overflow = count + input.count - storage.count
        if overflow > 0 {
            drop(overflow)
            dropped += overflow
        }
        var tail = (head + count) % storage.count
        for sample in input {
            storage[tail] = sample
            tail += 1
            if tail == storage.count { tail = 0 }
        }
        count += input.count
        return dropped
    }

    @discardableResult
    mutating func append(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// 丢掉最早的 n 个。
    mutating func drop(_ n: Int) {
        let removed = min(max(0, n), count)
        head = (head + removed) % storage.count
        count -= removed
        if count == 0 { head = 0 }
    }

    /// 取出最早的最多 n 个。
    mutating func read(_ n: Int) -> [Float] {
        let taken = min(max(0, n), count)
        var out = [Float](repeating: 0, count: taken)
        for index in 0..<taken {
            out[index] = storage[(head + index) % storage.count]
        }
        drop(taken)
        return out
    }
}

/// 两路（或一路）各自的环形缓冲 → 每 20 ms 一块：各取等长一块（缺的补零）相加、限幅。
///
/// 两路的时钟各走各的：麦克风的 tap 可能一次给 100 ms、系统声音一次 20 ms，还会抖。所以每路先攒够 `prefillFrames`
/// （200 ms：一次给 100 ms 时也还有 100 ms 余量；只是转录，多这点延迟无所谓）再开始出声（抖动缓冲）；积压超过它再加
/// `toleranceFrames`（容忍 ±200 ms）就丢最早的；某一路取空了（生产慢了一拍）就补零并重新攒 —— 宁可插一小段静音，
/// 也不让两路越错越远。
struct LiveTranslateMixer {
    static let sampleRate: Double = 16_000
    /// 20 ms。
    static let blockFrames = 320
    static let blockDuration: TimeInterval = Double(blockFrames) / sampleRate
    /// 抖动缓冲：每路先攒 200 ms 再出声。
    static let prefillFrames = 3_200
    /// 积压超过「抖动缓冲 + 200 ms」就丢最早的。
    static let toleranceFrames = 3_200
    static var maxBacklogFrames: Int { prefillFrames + toleranceFrames }

    struct Block: Equatable {
        /// 混好的一块（`blockFrames` 个样本，限幅在 [-1, 1]）。
        var samples: [Float]
        /// 每路这一块的 RMS（没出声的一路为 0）。下标与 `lanes` 一致：0 = 麦克风，1 = 系统声音。
        var levels: [Float]
    }

    struct Lane {
        var ring: LiveTranslateSampleRing
        /// 攒够了抖动缓冲、正在出声。
        var primed = false
        /// 刚开始（或暂停后刚继续）还没出过声：第一次攒够时把多攒的修掉，免得一开头就带着一大截延迟
        /// （麦克风一次给 100 ms 时，第二次给完就是 200 ms 了）。中途取空后重新攒的不修，那是要送出去的话。
        var fresh = true
        /// 统计（日志 / 测试用）：因积压丢掉的样本数、取空的次数。
        var dropped = 0
        var underruns = 0
    }

    private(set) var lanes: [Lane]

    init(laneCount: Int) {
        // 缓冲留足一秒余量：一次突发多给的也先收下，再按 maxBacklog 修剪。
        let capacity = Self.maxBacklogFrames + Int(Self.sampleRate)
        lanes = (0..<max(1, laneCount)).map { _ in Lane(ring: LiveTranslateSampleRing(capacity: capacity)) }
    }

    func backlog(lane: Int) -> Int {
        lanes.indices.contains(lane) ? lanes[lane].ring.count : 0
    }

    mutating func push(_ samples: UnsafeBufferPointer<Float>, lane: Int) {
        guard lanes.indices.contains(lane), !samples.isEmpty else { return }
        lanes[lane].dropped += lanes[lane].ring.append(samples)
        let excess = lanes[lane].ring.count - Self.maxBacklogFrames
        if excess > 0 {
            lanes[lane].ring.drop(excess)
            lanes[lane].dropped += excess
        }
    }

    mutating func push(_ samples: [Float], lane: Int) {
        samples.withUnsafeBufferPointer { push($0, lane: lane) }
    }

    /// 下一块（20 ms）。
    mutating func nextBlock() -> Block {
        var mix = [Float](repeating: 0, count: Self.blockFrames)
        var levels = [Float](repeating: 0, count: lanes.count)
        for index in lanes.indices {
            if !lanes[index].primed, lanes[index].ring.count >= Self.prefillFrames {
                lanes[index].primed = true
                if lanes[index].fresh {
                    lanes[index].fresh = false
                    let excess = lanes[index].ring.count - Self.prefillFrames
                    lanes[index].ring.drop(excess)
                    lanes[index].dropped += excess
                }
            }
            guard lanes[index].primed else { continue }
            let taken = lanes[index].ring.read(Self.blockFrames)
            if taken.count < Self.blockFrames {
                // 取空了：这块缺的补零，重新攒抖动缓冲。
                lanes[index].primed = false
                lanes[index].underruns += 1
            }
            levels[index] = Self.add(taken, into: &mix)
        }
        Self.clamp(&mix)
        return Block(samples: mix, levels: levels)
    }

    /// 收尾：不管攒没攒够，把各路剩下的都混出来（停止时最后那点声音也送进识别器）。
    mutating func drain() -> [Block] {
        var blocks: [Block] = []
        while lanes.contains(where: { $0.ring.count > 0 }) {
            var mix = [Float](repeating: 0, count: Self.blockFrames)
            var levels = [Float](repeating: 0, count: lanes.count)
            for index in lanes.indices {
                levels[index] = Self.add(lanes[index].ring.read(Self.blockFrames), into: &mix)
            }
            Self.clamp(&mix)
            blocks.append(Block(samples: mix, levels: levels))
        }
        for index in lanes.indices { lanes[index].primed = false }
        return blocks
    }

    /// 清空（暂停后继续：不把暂停期间攒下的旧声音送出去）。
    mutating func reset() {
        for index in lanes.indices {
            lanes[index].ring.drop(lanes[index].ring.count)
            lanes[index].primed = false
            lanes[index].fresh = true
        }
    }

    /// 加进 mix，返回这一路在整块（`blockFrames`，缺的算零）上的 RMS。
    private static func add(_ samples: [Float], into mix: inout [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for (index, sample) in samples.enumerated() where index < mix.count {
            mix[index] += sample
            sum += sample * sample
        }
        return (sum / Float(blockFrames)).squareRoot()
    }

    private static func clamp(_ mix: inout [Float]) {
        for index in mix.indices {
            mix[index] = min(1, max(-1, mix[index]))
        }
    }
}

/// 混音节拍的时钟：按实际过去的时间算该发几块（定时器晚了就一次补几块，落后太多只补最近的），
/// 输出的总时长始终跟真实时间对得上。
struct LiveTranslateMixClock {
    let start: TimeInterval
    private(set) var emittedBlocks = 0
    /// 一次最多补这么多块（200 ms）；再落后就跳过，免得一下子灌一大段。
    static let maxCatchUp = 10

    init(start: TimeInterval) {
        self.start = start
    }

    /// 到 `now`（与 `start` 同一时基的秒数）为止还该发几块。
    mutating func blocksDue(at now: TimeInterval) -> Int {
        guard now > start else { return 0 }
        // 加一点余量：浮点误差别让「刚好 20 ms」少算一块。
        let due = Int(((now - start) / LiveTranslateMixer.blockDuration + 1e-6).rounded(.down))
        var pending = due - emittedBlocks
        if pending > Self.maxCatchUp {
            emittedBlocks = due - Self.maxCatchUp
            pending = Self.maxCatchUp
        }
        guard pending > 0 else { return 0 }
        emittedBlocks += pending
        return pending
    }
}

/// 两路有人声的累计时长（秒）：每个 20 ms 块里 RMS 过阈值的那一路记上这一块的时长。
/// 混音线程一直往上累计；判一句的说话人时取这句开始到定稿之间的差（`-`）。
struct LiveTranslateLaneStats: Equatable {
    var microphoneVoiced: TimeInterval = 0
    var systemVoiced: TimeInterval = 0

    /// 约 -40 dBFS，与音频路由判「有人在说话」的阈值一致。
    static let voiceThreshold: Float = 0.01

    /// 记一块：`levels` 下标 0 = 麦克风，1 = 系统声音（没有这一路就不记）。
    mutating func add(levels: [Float], duration: TimeInterval = LiveTranslateMixer.blockDuration) {
        if let microphone = levels.first, microphone > Self.voiceThreshold {
            microphoneVoiced += duration
        }
        if levels.count > 1, levels[1] > Self.voiceThreshold {
            systemVoiced += duration
        }
    }

    static func - (lhs: LiveTranslateLaneStats, rhs: LiveTranslateLaneStats) -> LiveTranslateLaneStats {
        LiveTranslateLaneStats(microphoneVoiced: max(0, lhs.microphoneVoiced - rhs.microphoneVoiced),
                               systemVoiced: max(0, lhs.systemVoiced - rhs.systemVoiced))
    }
}

/// 一句定稿时判「我 / 对方」（近似，见 docs/meeting/REQUIREMENTS.md §9）。
///
/// 系统声音显著 →「对方」；否则麦克风显著 →「我」；都弱 → 不标。外放时麦克风会收进对方的声音（回声），
/// 所以「系统声音显著」优先判对方。「显著」= 有人声累计至少 0.3 秒；系统声音还要有麦克风的 35% 那么长 ——
/// 我说了好几秒、对方插一声「嗯」时不至于整句算成对方。
enum LiveTranslateSpeakerJudge {
    static let significant: TimeInterval = 0.3
    static let systemShare: Double = 0.35

    static func decide(_ stats: LiveTranslateLaneStats) -> MeetingSpeaker? {
        if stats.systemVoiced >= significant, stats.systemVoiced >= systemShare * stats.microphoneVoiced {
            return .them
        }
        if stats.microphoneVoiced >= significant {
            return .me
        }
        return nil
    }
}
