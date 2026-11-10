import Foundation

/// 听写的「人声」门槛（docs/dictation/TECH_DESIGN.md §3）：固定 -40 dBFS，环境底噪更高时跟着抬。
///
/// 只用固定门槛时，环境稍吵（空调、风扇、键盘、外放）底噪就一直过线，程序以为一直在说话：
/// 连续听写等不到停顿、一句也不上屏，安静自动结束也不触发。
///
/// 底噪 = 最近约 2 秒里最安静的那块缓冲区：每 0.5 秒一格记一个最小 RMS，留 4 格取最小。
/// 说话时字与字之间总会落回底噪附近，取最小值不会被人声抬上去；底噪变大要整 2 秒都吵才跟上，变小下一格就跟上。
/// 纯逻辑（只依赖 Foundation），不加锁：调用方（`DictationAudioPipe`）持锁调用。
struct DictationVoiceFloor {
    /// 约 -40 dBFS：安静房间的底噪在它之下，正常说话在它之上（同实时翻译）。
    static let baseRMS: Float = 0.01
    static let windowSeconds: Double = 0.5
    static let windowCount = 4
    /// 比底噪高出这么多倍（约 8 dB）才算人声。
    static let margin: Float = 2.5

    private var windows: [Float] = []
    private var windowMin = Float.greatestFiniteMagnitude
    private var windowFrames: Double = 0

    /// 现在的底噪估计（RMS）；还没攒够一格为 0。
    var floor: Float { windows.min() ?? 0 }

    /// 「人声」门槛：RMS 高过它就算有人在说话。
    var threshold: Float { max(Self.baseRMS, floor * Self.margin) }

    /// 记一块缓冲区：它的 RMS、帧数和采样率。
    mutating func add(rms: Float, frames: Int, sampleRate: Double) {
        guard rms.isFinite, frames > 0, sampleRate > 0 else { return }
        windowMin = min(windowMin, rms)
        windowFrames += Double(frames)
        guard windowFrames >= Self.windowSeconds * sampleRate else { return }
        windows.append(windowMin)
        if windows.count > Self.windowCount { windows.removeFirst() }
        windowMin = .greatestFiniteMagnitude
        windowFrames = 0
    }
}
