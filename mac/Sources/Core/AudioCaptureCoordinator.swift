import Foundation

/// 语音采集占用登记（docs/meeting/TECH_DESIGN.md §1、docs/dictation/TECH_DESIGN.md §2）。
/// 设备端语音识别同一时间只能跑一个请求，新请求会把旧的掐掉，所以实时翻译（自由听译）、
/// 会议记录、语音听写互斥：开始前 claim，结束时 release。会议检测还据此排除 Baobox 自己占用的麦克风。
@MainActor
final class AudioCaptureCoordinator {
    static let shared = AudioCaptureCoordinator()
    private init() {}

    struct Claim: Equatable {
        /// 占用者标识：`livetranslate` / `meeting` / `dictation`。
        let owner: String
        /// 给用户看的名字（「实时翻译」「会议记录」「听写」），用在「正在 XX」的提示里。
        let label: String
        let usesMicrophone: Bool
    }

    private(set) var current: Claim?

    /// Baobox 自己正在用麦克风（会议检测看到麦克风被占用时据此排除自己）。
    var isBaoboxUsingMicrophone: Bool { current?.usesMicrophone == true }

    /// 申请占用：已被别的占用者占着返回 false。同一占用者重复申请视为更新（如改了音源后重启）。
    @discardableResult
    func claim(owner: String, label: String, microphone: Bool) -> Bool {
        if let current, current.owner != owner { return false }
        current = Claim(owner: owner, label: label, usesMicrophone: microphone)
        return true
    }

    /// 只有占用者本人能释放，别人释放是空操作。
    func release(owner: String) {
        if current?.owner == owner { current = nil }
    }

    /// 被占时给用户的一句话，如「正在实时翻译，先停止再开始」。
    func busyMessage() -> String? {
        guard let current else { return nil }
        return L("capture.busy \(current.label)")
    }
}
