import AppKit
import Foundation

/// 实时翻译的本地记录与纪要设置（前缀 `livetranslate.record.`）。见 docs/live-translate/DESIGN.md §6。
/// 记录写进会议库，保存位置就是会议库目录（跟着会话配置来，docs/meeting/ENGINE.md §4.6），这里没有保存位置的设置；
/// 旧版的 `livetranslate.record.folder` 只剩会议库首次启动迁移旧记录时读（键在会议那边）。
enum LiveTranslateRecordSettings {
    static let enabledKey = "livetranslate.record.enabled"
    static let summaryKey = "livetranslate.record.summary"

    /// 保存记录（默认关，2026-11-05 用户要求）：设置页或字幕条「记录」菜单里手动开，开了以后每次开始都记。
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 停止后用本地 AI 整理纪要（默认开；没下载模型时只存原文和译文）。
    static var summary: Bool {
        UserDefaults.standard.object(forKey: summaryKey) as? Bool ?? true
    }

    /// 打开记录文件夹（会议库目录；还没有就先建）。建目录放后台，别让磁盘 IO 卡住主线程。
    @MainActor
    static func openFolder(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
