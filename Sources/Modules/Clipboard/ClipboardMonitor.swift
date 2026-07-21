import AppKit
import CryptoKit

/// 剪贴板监听：0.3s 轮询 changeCount，识别类型后写入 store。
@MainActor
final class ClipboardMonitor {
    private let store: ClipboardStore
    private var timer: Timer?
    private var lastChangeCount: Int

    /// PasteService 回填时置位，跳过一次自身产生的变更。
    var ignoreNextChange = false

    init(store: ClipboardStore) {
        self.store = store
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if ignoreNextChange {
            ignoreNextChange = false
            return
        }

        // 忽略密码管理器等标记为隐私/临时的内容。
        if let types = pasteboard.types {
            let raw = Set(types.map { $0.rawValue })
            if raw.contains("org.nspasteboard.ConcealedType") || raw.contains("org.nspasteboard.TransientType") {
                return
            }
        }

        readAndStore(pasteboard)
    }

    private func readAndStore(_ pasteboard: NSPasteboard) {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let sourceName = frontApp?.localizedName
        let sourceBundle = frontApp?.bundleIdentifier

        // 忽略名单：NSPasteboard 不暴露写入方，以变更那一刻的前台 App 近似判定来源。
        if let sourceBundle, ClipboardStore.ignoredBundleIDs.contains(sourceBundle) {
            return
        }

        // 1) 文件 URL
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let text = urls.map { $0.path }.joined(separator: "\n")
            store.add(ClipboardItem(id: UUID(), type: .file, text: text, imageFilename: nil,
                                    sourceAppName: sourceName, sourceBundleID: sourceBundle,
                                    createdAt: Date(), isPinned: false))
            return
        }

        // 2) 图片
        //
        // 必须先排除「同时带文本表示」的情况：Word / Excel / PowerPoint / Keynote / Pages /
        // 预览 复制**文字**时，会一并往剪贴板放 public.tiff 或 com.adobe.pdf，
        // `readObjects(forClasses: [NSImage.self])` 对它们会成功返回。若先判图片，
        // 正文就被丢掉了 —— 历史里只剩一个 UUID 文件名，既搜不到也没法用，
        // 还白写一张无用 PNG 到磁盘。这是必现问题，不是边缘情况。
        let hasText = pasteboard.string(forType: .string)?.isEmpty == false
        if !hasText,
           let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first {
            if let filename = saveImage(image) {
                store.add(ClipboardItem(id: UUID(), type: .image, text: nil, imageFilename: filename,
                                        sourceAppName: sourceName, sourceBundleID: sourceBundle,
                                        createdAt: Date(), isPinned: false))
            }
            return
        }

        // 3) 字符串（link / text）
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            let type: ClipboardItemType = isLink(string) ? .link : .text
            store.add(ClipboardItem(id: UUID(), type: type, text: string, imageFilename: nil,
                                    sourceAppName: sourceName, sourceBundleID: sourceBundle,
                                    createdAt: Date(), isPinned: false))
            return
        }
    }

    private func saveImage(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        // 用内容哈希做文件名。原先是 UUID，导致 ClipboardItem.contentSignature
        // （"image:<文件名>"）永远不可能相等 —— 图片去重形同虚设，同一张图反复复制会
        // 持续堆积历史条目和磁盘 PNG。
        let filename = Self.sha256Hex(png) + ".png"
        let dir = ClipboardStore.imagesDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        // 同内容已落盘则直接复用，不重复写。
        if FileManager.default.fileExists(atPath: url.path) { return filename }
        do {
            try png.write(to: url)
            return filename
        } catch {
            return nil
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isLink(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "), trimmed.count < 2048,
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
