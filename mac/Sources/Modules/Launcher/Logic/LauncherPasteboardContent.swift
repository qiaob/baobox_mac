import Foundation

// 快速入口按 ⌘V（或拖进来）时，剪贴板里的东西归哪一类（docs/launcher/TECH_DESIGN.md §5.5）：
// 文件（访达里复制的）→ 输入框换成它的路径；图片 → 挂成输入里的附件；其余 → 照旧按文字粘贴。
// 输入是从剪贴板读出来的纯数据（有哪些类型、文字是什么、有哪些文件），读剪贴板在 App 侧（只在按 ⌘V / 放下的那一下读）。
// 纯函数、只依赖 Foundation，进 BaoboxTests。

/// 剪贴板（或拖进来的东西）此刻有什么。
struct LauncherPasteboardSnapshot: Equatable, Sendable {
    /// 剪贴板上的类型标识（UTI，如 `public.png`），按剪贴板给的顺序。
    var types: [String]
    /// 纯文字；没有为 nil。
    var string: String?
    /// 文件网址（只收 `file://` 的），按剪贴板给的顺序；没有为空。
    var fileURLs: [URL]

    init(types: [String] = [], string: String? = nil, fileURLs: [URL] = []) {
        self.types = types
        self.string = string
        self.fileURLs = fileURLs
    }
}

/// 这次粘贴归哪一类。
enum LauncherPasteKind: Equatable, Sendable {
    /// 文件：输入框换成第一个文件的路径（一次复制了好几个时这一期只取第一个）。
    case file(URL)
    /// 图片：挂成输入里的附件。
    case image
    /// 文字：照旧粘进输入框。
    case text
    /// 什么都没有（交给输入框，它自己什么都不做）。
    case nothing
}

enum LauncherPasteClassifier {
    /// 算作图片数据的类型（剪贴板上常见的位图格式；PDF 不算 —— 这一期不给 PDF 专门的建议）。
    static let imageTypes: Set<String> = [
        "public.png", "public.tiff", "public.jpeg", "public.heic", "public.heif", "com.compuserve.gif",
        "org.webmproject.webp", "com.microsoft.bmp",
        // 老程序用的旧名字。
        "Apple PNG pasteboard type", "NeXT TIFF v4.0 pasteboard type",
    ]
    /// 带格式的文字：和图片一起出现时，多半是从文档、表格里复制了一段（表格软件会顺带放一张这段内容的截图）。
    static let richTextTypes: Set<String> = [
        "public.rtf", "public.html", "public.rtfd", "com.apple.flat-rtfd", "com.apple.webarchive",
        "Apple HTML pasteboard type", "NeXT Rich Text Format v1.0 pasteboard type", "NeXT RTFD pasteboard type",
    ]
    /// 和图片一起的文字不超过这么多个字符（单行）时，当成这张图的说明（文件名、替代文字），按图片算。
    static let shortTextLimit = 20
    /// 图片文件的扩展名：和图片一起的文字是一个这种结尾的名字时，按图片算。
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp"]

    /// 规则（按顺序，第一条成立的生效）：
    /// 1. 有文件网址 → 文件（取第一个）。访达复制文件时还会带文件名文字和图标图片，都不看。
    /// 2. 有图片数据：
    ///    - 没有文字（或全是空白）→ 图片；
    ///    - 文字是这张图的地址（单行的 `http(s)://`、`file://`、`data:image/`）或一个图片文件名（`IMG_1234.png`）→ 图片；
    ///    - 同时有带格式的文字（RTF / HTML，从文档、表格里复制的一段，表格软件会顺带放一张截图）→ 文字；
    ///    - 文字很短（单行、不超过 20 个字符）→ 图片（多半是替代文字）；
    ///    - 其余 → 文字（文字是用户要的，图片是顺带的）。
    /// 3. 有文字 → 文字。
    /// 4. 都没有 → 什么都没有。
    static func classify(_ snapshot: LauncherPasteboardSnapshot) -> LauncherPasteKind {
        if let file = snapshot.fileURLs.first(where: \.isFileURL) {
            return .file(file)
        }
        let types = Set(snapshot.types)
        let hasText = !(snapshot.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !types.isDisjoint(with: imageTypes) else {
            return hasText ? .text : (snapshot.string == nil ? .nothing : .text)
        }
        guard hasText, let string = snapshot.string else { return .image }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if isImageAddress(trimmed) || isImageFileName(trimmed) { return .image }
        if !types.isDisjoint(with: richTextTypes) { return .text }
        if !trimmed.contains(where: \.isNewline), trimmed.count <= shortTextLimit { return .image }
        return .text
    }

    /// 单行、没有空白的 `http(s)://…`、`file://…`、`data:image/…`（浏览器「拷贝图像」时一起放的那张图的地址）。
    static func isImageAddress(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        let lower = text.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://")
            || lower.hasPrefix("data:image/")
    }

    /// 单行、不太长、以图片扩展名结尾的名字（`IMG_1234.png`、`Screenshot 2026-11-24 at 10.12.33.png`）。
    static func isImageFileName(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 255, !text.contains(where: \.isNewline),
              let dot = text.lastIndex(of: "."), dot != text.startIndex else { return false }
        let ext = text[text.index(after: dot)...].lowercased()
        return imageExtensions.contains(ext)
    }
}

/// 贴进来（拖进来）一个文件时换进输入框的文字。
enum LauncherPastedFile {
    /// 文件的路径：主目录下的写成 `~/…`（输入框里短一截，和路径行副标题的写法一样）；
    /// 文件夹末尾带 `/`（网址自己带着「是文件夹」：访达给的文件夹网址以 `/` 结尾），于是立刻列出它里面的内容。
    /// 不读磁盘。不是 `file://` 的网址为 nil。
    static func fieldText(for url: URL, home: String) -> String? {
        guard url.isFileURL else { return nil }
        // 不用 `standardizedFileURL`：它会查磁盘、把 `/private/tmp` 改写成 `/tmp`。访达给的网址本来就是干净的绝对路径。
        let path = url.path
        guard !path.isEmpty else { return nil }
        let shown = LauncherPathDisplay.abbreviated(LauncherPathDisplay.trimmingTrailingSlashes(path), home: home)
        guard url.hasDirectoryPath, !shown.hasSuffix("/") else { return shown }
        return shown + "/"
    }
}
