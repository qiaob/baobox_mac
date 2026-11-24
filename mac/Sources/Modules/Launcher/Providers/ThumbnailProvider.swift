import AppKit

// 图片条目行首的缩略图（docs/launcher/TECH_DESIGN.md §3.2、§5.5）：来源交出来的只是「怎么取图片字节」（`LauncherEntryImage`），
// 行要显示时才在后台串行队列取一次、解成长边 64 像素的小图，按来源给的键缓存（`NSCache`，最多 60 张、几百 KB）；
// 取到一批就通知面板重画。打字路径上不碰：列表只在画出某一行时才问它要。

@MainActor
final class LauncherThumbnailProvider {
    /// 缩略图最长边（像素）：行首图标 26pt，Retina 上两倍多一点。
    nonisolated static let maxPixelSize = 64

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        return cache
    }()
    private let queue = DispatchQueue(label: "com.baobox.app.launcher.thumbnails", qos: .utility)
    /// 正在取的（别重复交）。
    private var loading: Set<String> = []
    /// 取过但读不出来的（别每次重画都再试）。
    private var failed: Set<String> = []

    /// 取到了一张：面板重画。
    var onLoaded: (() -> Void)?

    /// 缓存里有就给；没有就交给后台去取、先返回 nil（取到后 `onLoaded`）。
    func thumbnail(for image: LauncherEntryImage) -> NSImage? {
        let key = image.cacheKey
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard !failed.contains(key), loading.insert(key).inserted else { return nil }
        let load = image.loadData
        queue.async {
            let thumbnail = load().flatMap { LauncherImageLoader.thumbnail(.data($0), maxPixelSize: Self.maxPixelSize) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.loading.remove(key)
                    guard let thumbnail else {
                        self.failed.insert(key)
                        return
                    }
                    self.cache.setObject(NSImage(cgImage: thumbnail, size: .zero), forKey: key as NSString)
                    self.onLoaded?()
                }
            }
        }
        return nil
    }
}
