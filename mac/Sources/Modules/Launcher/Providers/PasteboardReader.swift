import AppKit

// 读剪贴板（或拖进来的东西）给快速入口用（docs/launcher/TECH_DESIGN.md §5.5）：只在按 ⌘V / 放下的那一下读，不在打字路径上。
// 读出来的纯数据交给 `LauncherPasteClassifier` 判断是文件、图片还是文字；是图片时再取图片的编码字节。
// 剪贴板由调用方传进来（控制器传 `.general`、拖放传拖动的那块，探针传自己建的具名剪贴板）—— 这里只读、从不写。

enum LauncherPasteboardReader {
    /// 有哪些类型、纯文字、文件网址（只收 `file://`）。
    static func snapshot(_ pasteboard: NSPasteboard) -> LauncherPasteboardSnapshot {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        let string = pasteboard.string(forType: .string)
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return LauncherPasteboardSnapshot(types: types, string: string, fileURLs: files)
    }

    /// 同一张图有几种格式时按这个顺序取第一种：压缩的在前（PNG、JPEG 比 TIFF 小一个量级，附件留的就是这份字节）。
    static let preferredImageTypes: [NSPasteboard.PasteboardType] = [
        .png, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("com.compuserve.gif"), NSPasteboard.PasteboardType("org.webmproject.webp"), .tiff,
    ]

    /// 图片的编码字节（原样，不转码）；上面几种都没有、但能读成 `NSImage`（老格式）时，转一份 TIFF。没有图片为 nil。
    static func imageData(_ pasteboard: NSPasteboard) -> Data? {
        let available = Set(pasteboard.types ?? [])
        for type in preferredImageTypes where available.contains(type) {
            if let data = pasteboard.data(forType: type), !data.isEmpty { return data }
        }
        guard let image = (pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first,
              let tiff = image.tiffRepresentation, !tiff.isEmpty else { return nil }
        return tiff
    }
}
