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

    /// 新记录实际写到哪：会议模块装上了就是会议库（docs/meeting/TECH_DESIGN.md §2.3），否则是上面这个文件夹。
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

/// 会议库（Meeting 模块）接管自由听译的新记录（docs/meeting/TECH_DESIGN.md §2.3）。
@MainActor
protocol LiveTranslateRecordLibrary: AnyObject {
    /// 会议库根目录（设置页「保存位置」、字幕条「打开记录文件夹」）。
    var folderURL: URL { get }
    /// 新开一份自由听译记录写到哪（会议库里新的一条；记下第一句时才登记进索引）。
    func freeListeningDestination(start: Date) -> LiveTranslateTranscript.Destination
}
