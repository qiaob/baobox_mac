import AppKit

enum ResultMode {
    case standard   // 复制到剪贴板，按设置可同时落盘
    case saveOnly   // 仅落盘
}

/// 截图设置的 UserDefaults 访问（统一 screenshot. 前缀）。
enum ScreenshotSettings {
    static let autoSaveKey = "screenshot.autoSave"
    static let saveDirectoryKey = "screenshot.saveDirectory"
    static let filenameTemplateKey = "screenshot.filenameTemplate"
    static let historyLimitKey = "screenshot.historyLimit"

    static let defaultDirectory = "~/Pictures/Baobox"
    /// 按语言取默认模板：英文默认不含单词前缀 —— 模板会被 DateFormatter 直接解析，
    /// "Screenshot" 里的 S/c/r/e… 全是格式符，会产出乱码（中文字符无此问题）。
    static var defaultTemplate: String { L("screenshot.settings.defaultTemplate") }

    static var autoSave: Bool {
        UserDefaults.standard.object(forKey: autoSaveKey) as? Bool ?? true
    }

    static var saveDirectoryURL: URL {
        let path = UserDefaults.standard.string(forKey: saveDirectoryKey) ?? defaultDirectory
        let expanded = ((path.isEmpty ? defaultDirectory : path) as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    static var filenameTemplate: String {
        UserDefaults.standard.string(forKey: filenameTemplateKey) ?? defaultTemplate
    }

    /// 截图历史保留张数，默认 20。
    static var historyLimit: Int {
        let value = UserDefaults.standard.integer(forKey: historyLimitKey)
        return value == 0 ? 20 : value
    }

    /// 录屏是否采集系统声音（选区工具条与设置页共享，默认关）。
    static let recordSystemAudioKey = "screenshot.recordSystemAudio"
    static var recordSystemAudio: Bool {
        get { UserDefaults.standard.bool(forKey: recordSystemAudioKey) }
        set { UserDefaults.standard.set(newValue, forKey: recordSystemAudioKey) }
    }

    /// 录屏是否采集麦克风（第二条音轨；首次开启需系统麦克风授权）。
    static let recordMicrophoneKey = "screenshot.recordMicrophone"
    static var recordMicrophone: Bool {
        get { UserDefaults.standard.bool(forKey: recordMicrophoneKey) }
        set { UserDefaults.standard.set(newValue, forKey: recordMicrophoneKey) }
    }

    /// 录屏输出格式。GIF 无声音、≤10fps、宽度缩到 720px，适合短片段。
    enum RecordFormat: String {
        case mp4, gif
    }
    static let recordFormatKey = "screenshot.recordFormat"
    static var recordFormat: RecordFormat {
        RecordFormat(rawValue: UserDefaults.standard.string(forKey: recordFormatKey) ?? "") ?? .mp4
    }

    /// 系统声音 + 麦克风同录时，完成后把双音轨混为单轨（兼容只播首轨的播放器），默认开。
    static let recordMixAudioKey = "screenshot.recordMixAudio"
    static var recordMixAudio: Bool {
        UserDefaults.standard.object(forKey: recordMixAudioKey) as? Bool ?? true
    }

    /// 按模板生成消毒后的文件基名（不含扩展名）。截图与录屏共用。
    ///
    /// 模板含 "/" 会被 appendingPathComponent 当作子路径；模板写错时
    ///（如 "Screenshot yyyy" 中 S/c/r/e/n/h/o/t 全是 DateFormatter 的格式符）
    /// 还可能产出乱码甚至空串，让文件名退化成隐藏文件 ".png"。
    @MainActor
    static func filenameBase(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateFormat = filenameTemplate
        var base = formatter.string(from: date)
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            formatter.dateFormat = defaultTemplate
            base = formatter.string(from: date)
        }
        return base
    }
}

/// 处理截图结果：复制到剪贴板 / 落盘。
enum ScreenshotResultHandler {
    @MainActor
    static func handle(image: CGImage, mode: ResultMode) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        ScreenshotHistoryStore.shared.record(image: image)

        switch mode {
        case .standard:
            copyToPasteboard(png: png, cgImage: image)
            if ScreenshotSettings.autoSave {
                saveToDisk(png: png)
            }
        case .saveOnly:
            saveToDisk(png: png)
        }
    }

    /// 复制到剪贴板（PNG + TIFF 双格式，覆盖各类粘贴目标）。供历史找回复用。
    @MainActor
    static func copy(image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        copyToPasteboard(png: png, cgImage: image)
    }

    private static func copyToPasteboard(png: Data, cgImage: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        let nsImage = NSImage(cgImage: cgImage, size: .zero)
        if let tiff = nsImage.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    @MainActor
    private static func saveToDisk(png: Data) {
        let dir = ScreenshotSettings.saveDirectoryURL
        let base = ScreenshotSettings.filenameBase(for: Date())

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: uniqueURL(in: dir, base: base, ext: "png"))
        } catch {
            // 原先整条链路都是 try?：目录不可写、保存目录落在 TCC 保护目录（如 ~/Documents）
            // 被拒、磁盘写满，全部静默失败 —— 用户以为存下来了，其实什么都没有。
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("screenshot.error.saveFailed")
            alert.informativeText = "\(dir.path)\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// 文件名模板精确到秒，同一秒内连拍两张时后者会覆盖前者，这里追加序号避让。
    static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        let first = dir.appendingPathComponent(base + "." + ext)
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        for n in 2...999 {
            let candidate = dir.appendingPathComponent("\(base)-\(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent("\(base)-\(UUID().uuidString).\(ext)")
    }
}
