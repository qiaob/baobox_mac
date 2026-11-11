import Foundation

// 会话索引共用层的「形状」（#109，docs/codex-assistant/DEDUPE.md §4.1）：摘要、会话文件、缓存记录，
// 以及每种 CLI 各实现一份的「格式」。Claude Code 助手是 `ClaudeSessionFormat`，Codex 助手是 `CodexSessionFormat`。
// 摘要与记录在后台扫出来、回主线程发布，所以都要求 Sendable（各模块的结构体字段全是值类型，声明遵循即可）。

/// 会话摘要：共用层只用到这几项（删除、导出、排序）；界面另外读各模块自己的字段。
protocol CLISessionSummary: Identifiable, Sendable where ID == String {
    var id: String { get }
    var fileURL: URL { get }
    var projectPath: String { get }
    var projectName: String { get }
    var title: String { get }
    var lastActivity: Date { get }
}

/// 一个会话文件：列目录时顺手取到的修改时间与大小（取不到时是 1970-01-01 与 0）。
struct CLISessionFile: Equatable, Sendable {
    let url: URL
    let modified: Date
    let size: Int64
}

/// 缓存记录：扫描时文件的修改时间（timeIntervalSince1970）与大小，两样都没变就复用、不再读文件。
/// 要落盘的记录靠 Codable 编码，字段名就是缓存文件里的键 —— 改字段名等于让旧缓存失效。
protocol CLISessionRecord: Codable, Sendable {
    var modified: Double { get }
    var size: Int64 { get }
}

/// 一种 CLI 会话日志的「格式」：会话文件在哪、怎么快扫一个文件、怎么导出、缓存放哪。
/// 全是静态成员、不碰主线程状态，在后台线程调用。
protocol CLISessionFormat: Sendable {
    associatedtype Summary: CLISessionSummary
    associatedtype Record: CLISessionRecord

    /// 列出全部会话文件；顺序就是同一时间戳时的先后（排序前的原始顺序）。
    static func sessionFiles() -> [CLISessionFile]
    /// 快扫一个文件；nil = 打不开 / 读失败，这次跳过（不进缓存，下次再试）。
    static func scan(_ file: CLISessionFile) -> Record?
    /// 由缓存记录得到摘要（复用的与新扫的都走这里）。
    static func summary(of record: Record, fileURL: URL) -> Summary
    /// 磁盘缓存文件；nil = 只在内存里缓存，不读也不写。
    static var cacheFileURL: URL? { get }
    /// 清理旧会话时递归查找 .jsonl 的根目录。
    static var logRoot: URL { get }
    /// 整份会话导出成 Markdown；nil = 读失败。
    static func markdown(fileURL: URL, title: String) -> String?
}
