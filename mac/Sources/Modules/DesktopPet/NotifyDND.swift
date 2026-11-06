import AppKit
import CoreAudio
import Foundation

/// 勿扰判定（设计 §4）：手动安静、外部抑制令牌（录屏 / 会议 #42 / 专注与休息 #43）、
/// 前台全屏应用。勿扰信号统一收敛到这里，各模块不要各写一份。
@MainActor
final class NotifyDND {
    static let shared = NotifyDND()
    private init() {}

    /// 为什么勿扰（docs/focus-health/TECH_DESIGN.md §6）。调用方按需挑自己在意的原因。
    enum Reason: Hashable {
        case quiet              // 宠物「安静一下」
        case token(String)      // 其他模块挂的勿扰：recording / meeting / focus / break …
        case fullscreen         // 前台 App 全屏（演示 / 视频 / 游戏）
        case microphone         // 默认输入设备正被使用（开会的近似信号）
    }

    private var tokens: Set<String> = []
    /// 麦克风占用的缓存值（后台刷新，见 refreshMicrophoneState）。
    private(set) var microphoneInUse = false
    private var microphoneRefreshing = false

    /// 其他模块的抑制开关：如会议开始时 setSuppressed(true, token: "meeting")。
    func setSuppressed(_ on: Bool, token: String) {
        if on { tokens.insert(token) } else { tokens.remove(token) }
    }

    /// 某个令牌挂着没有（会议检测看「录屏中」用；不像 `reasons()` 那样要遍历窗口列表查全屏）。
    func hasToken(_ token: String) -> Bool {
        tokens.contains(token)
    }

    /// 宠物与通知内核用：令牌、手动安静、前台全屏。麦克风占用不算在内 —— Baobox 自己的
    /// 实时翻译也会占用麦克风，分不清是谁在用，不能因此让宠物睡着、把别的通知攒起来。
    var isSuppressed: Bool {
        if !tokens.isEmpty { return true }
        if let until = PetSettings.quietUntil, until > Date() { return true }
        return frontmostAppIsFullscreen
    }

    /// 全部勿扰原因（含麦克风占用）。`ignoringTokens`：调用方自己挂的令牌不算（专注模块判避让时
    /// 不能被自己的 focus / break 令牌挡住）。
    func reasons(ignoringTokens ignored: Set<String> = []) -> [Reason] {
        var result: [Reason] = tokens.subtracting(ignored).sorted().map { .token($0) }
        if let until = PetSettings.quietUntil, until > Date() { result.append(.quiet) }
        if microphoneInUse { result.append(.microphone) }
        if frontmostAppIsFullscreen { result.append(.fullscreen) }
        return result
    }

    /// 在后台读一次「默认输入设备是否正被使用」，结果回主线程写缓存。
    /// 不在主线程直接调 CoreAudio HAL：coreaudiod 忙的时候属性读取也可能卡住。
    func refreshMicrophoneState() {
        guard !microphoneRefreshing else { return }
        microphoneRefreshing = true
        DispatchQueue.global(qos: .utility).async {
            let running = NotifyDND.defaultInputIsRunning()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NotifyDND.shared.microphoneInUse = running
                    NotifyDND.shared.microphoneRefreshing = false
                }
            }
        }
    }

    private nonisolated static func defaultInputIsRunning() -> Bool {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &deviceID) == noErr,
              deviceID != AudioObjectID(kAudioObjectUnknown) else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// 启发式：最前台 App 有一个铺满某块屏幕的窗口，视作全屏（演示 / 视频 / 游戏）。
    /// CGWindowList 与 NSScreen 的 y 轴方向相反，这里只比尺寸，不比位置。
    private var frontmostAppIsFullscreen: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let frontName = front.localizedName else { return false }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }
        let screenSizes = NSScreen.screens.map { $0.frame.size }
        for info in infos {
            guard let owner = info[kCGWindowOwnerName as String] as? String, owner == frontName,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            if screenSizes.contains(where: { abs($0.width - bounds.width) < 2 && abs($0.height - bounds.height) < 2 }) {
                return true
            }
        }
        return false
    }
}
