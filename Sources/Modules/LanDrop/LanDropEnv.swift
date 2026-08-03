import Foundation

/// 局域网传输 —— 环境与共享基础层：UserDefaults 键与默认值、保存目录、文件名消毒与去重。
///
/// 并发说明：有意**不**标 `@MainActor` —— 文件名消毒与去重要在连接队列（后台）上直接调用，
/// 设置读取则是纯 UserDefaults 访问，两边都线程安全。本文件不含用户可见文案。
enum LanDropEnv {

    // MARK: - UserDefaults 键

    enum Keys {
        static let port = "landrop.port"
        static let saveDirectory = "landrop.saveDirectory"
        static let idleTimeout = "landrop.idleTimeout"
        static let stopWhenDone = "landrop.stopWhenDone"
        static let maxFileSize = "landrop.maxFileSize"
        static let notifyStart = "landrop.notifyStart"
        static let notifyDone = "landrop.notifyDone"
        static let notifySound = "landrop.notifySound"
    }

    /// 默认保存目录（展示用的原始串，含 `~`）。
    static let defaultDirectory = "~/Downloads/Baobox"

    static let defaultPort: UInt16 = 8787

    /// 单文件默认上限 4 GB。
    static let defaultMaxFileSize: Int = 4 * 1024 * 1024 * 1024

    /// 空闲自动关闭默认 10 分钟。
    static let defaultIdleTimeout: Double = 600

    // MARK: - 设置读取

    /// 监听端口。落在合法范围外时回退默认值（端口 0 由服务端专门表示「系统自动分配」，
    /// 但那是回退逻辑内部的事，不作为用户可设的值）。
    static var port: UInt16 {
        let raw = UserDefaults.standard.integer(forKey: Keys.port)
        guard raw > 0, raw <= 65535 else { return defaultPort }
        return UInt16(raw)
    }

    /// 保存目录。空串或未设时回落默认目录。
    static var saveDirectoryURL: URL {
        let path = UserDefaults.standard.string(forKey: Keys.saveDirectory) ?? defaultDirectory
        let expanded = ((path.isEmpty ? defaultDirectory : path) as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    /// 空闲自动关闭秒数。0 = 不自动关。
    static var idleTimeout: Double {
        guard let value = UserDefaults.standard.object(forKey: Keys.idleTimeout) as? Double else {
            return defaultIdleTimeout
        }
        return max(0, value)
    }

    /// 全部传输完成后立即关闭（默认关）。
    static var stopWhenDone: Bool {
        UserDefaults.standard.bool(forKey: Keys.stopWhenDone)
    }

    /// 单文件上限字节数。0 = 不限。
    static var maxFileSize: Int {
        guard let value = UserDefaults.standard.object(forKey: Keys.maxFileSize) as? Int else {
            return defaultMaxFileSize
        }
        return max(0, value)
    }

    static var notifyStart: Bool {
        UserDefaults.standard.object(forKey: Keys.notifyStart) as? Bool ?? true
    }

    static var notifyDone: Bool {
        UserDefaults.standard.object(forKey: Keys.notifyDone) as? Bool ?? true
    }

    static var notifySound: Bool {
        UserDefaults.standard.object(forKey: Keys.notifySound) as? Bool ?? true
    }

    // MARK: - 目录准备

    /// 确保当前设置的保存目录存在。返回目录 URL；创建失败返回 nil（调用方据此回错误，不静默吞掉）。
    static func ensureSaveDirectory() -> URL? {
        ensureDirectory(saveDirectoryURL)
    }

    /// 确保指定目录存在且可写。会话用注入的目录调这个，避免上传中途读到被改掉的设置。
    static func ensureDirectory(_ dir: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        // 建出来了也可能不可写（比如指到了只读卷）。
        guard FileManager.default.isWritableFile(atPath: dir.path) else { return nil }
        return dir
    }

    // MARK: - 文件名消毒

    /// 上限：文件名保留的最大 UTF-8 字节数（HFS+/APFS 单个组件上限 255，留出去重后缀余量）。
    private static let maxNameBytes = 200

    /// 把手机端传来的文件名消毒成安全的单个路径组件。
    ///
    /// 步骤（见 TECH_DESIGN §9）：去分隔符 → 去控制字符 → 去首尾空白与前导点 → 截断 → 兜底名。
    /// 去掉分隔符之后不可能再出现 `..` 作为路径成分；单独的 `..` 会在去前导点时被削成空串，
    /// 落到兜底名，故目录穿越在此彻底关死。
    static func sanitize(filename raw: String) -> String {
        var name = raw
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: ":", with: "")   // HFS 遗留分隔符，访达里显示为 "/"
        name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = truncate(name, toBytes: maxNameBytes)
        if name.isEmpty { name = "file-" + timestamp() }
        return name
    }

    /// 按 UTF-8 字节数截断，尽量保留扩展名。
    private static func truncate(_ name: String, toBytes limit: Int) -> String {
        guard name.utf8.count > limit else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : "." + String(ext.prefix(20))
        var base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        // 逐字符削，避免从 UTF-8 中间截断产生乱码。
        while base.utf8.count + suffix.utf8.count > limit, !base.isEmpty {
            base.removeLast()
        }
        return base + suffix
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - 去重

    /// 目标目录内不重名的 URL：已存在则追加 `-2`、`-3`…（照 `ScreenshotResultHandler.uniqueURL` 的思路）。
    static func uniqueURL(in dir: URL, filename: String) -> URL {
        let first = dir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: first.path) else { return first }

        let ext = (filename as NSString).pathExtension
        let base = ext.isEmpty ? filename : String(filename.dropLast(ext.count + 1))
        let suffix = ext.isEmpty ? "" : "." + ext
        for n in 2...999 {
            let candidate = dir.appendingPathComponent("\(base)-\(n)\(suffix)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent("\(base)-\(UUID().uuidString)\(suffix)")
    }

    // MARK: - 随机串

    /// URL-safe 随机串。访问码与分享句柄共用一套字母表（去掉了 l/I/1、O/0 这类易混字符）。
    static func randomID(length: Int) -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in
            alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))]
        })
    }

    // MARK: - 展示辅助

    /// 人类可读的字节数（菜单 / 通知 / 网页都用同一套，避免两处不一致）。
    static func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
