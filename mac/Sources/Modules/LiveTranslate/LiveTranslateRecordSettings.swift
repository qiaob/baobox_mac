import AppKit
import Foundation

/// 实时翻译的本地记录与纪要设置（前缀 `livetranslate.record.`）。见 docs/live-translate/DESIGN.md §6。
enum LiveTranslateRecordSettings {
    static let enabledKey = "livetranslate.record.enabled"
    static let folderKey = "livetranslate.record.folder"
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

    /// 默认：~/Documents/Baobox 实时翻译记录。
    static var defaultFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent(L("livetranslate.record.defaultFolderName"), isDirectory: true)
    }

    static var folder: URL {
        let path = UserDefaults.standard.string(forKey: folderKey) ?? ""
        return path.isEmpty ? defaultFolder : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 设置页「保存位置」、「打开记录文件夹」指向哪：会议库（新记录都由它写，docs/meeting/TECH_DESIGN.md §2.3）；
    /// 会议库没装上时退回上面这个文件夹（那时也不记录，见 `LiveTranslateController.startTranscript`）。
    /// `folder` 设置保留，只用于首次启动把旧记录迁进会议库。
    @MainActor
    static var effectiveFolder: URL {
        LiveTranslateController.recordLibrary?.folderURL ?? folder
    }

    /// 打开记录文件夹（还没有就先建）。建目录放后台：第一次碰「文稿」时系统会弹授权框，别卡住主线程。
    @MainActor
    static func openFolder() {
        let url = effectiveFolder
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
