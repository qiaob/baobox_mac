import AppKit
import Foundation

/// 勿扰判定（设计 §4）：手动安静、外部抑制令牌（会议 #42 / 专注 #43 后续接入）、
/// 前台全屏应用。勿扰信号统一收敛到这里，各模块不要各写一份。
@MainActor
final class NotifyDND {
    static let shared = NotifyDND()
    private init() {}

    private var tokens: Set<String> = []

    /// 其他模块的抑制开关：如会议开始时 setSuppressed(true, token: "meeting")。
    func setSuppressed(_ on: Bool, token: String) {
        if on { tokens.insert(token) } else { tokens.remove(token) }
    }

    var isSuppressed: Bool {
        if !tokens.isEmpty { return true }
        if let until = PetSettings.quietUntil, until > Date() { return true }
        return frontmostAppIsFullscreen
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
