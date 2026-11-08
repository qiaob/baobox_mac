import Foundation
import Security

/// 手机互传的设置键与几个纯函数工具（接收目录、文件名去重、随机令牌）。
/// 读 UserDefaults 线程安全，局域网服务的后台队列也会调用这里。
enum PhoneTransferSettings {
    static let receiveDirKey = "phonetransfer.receiveDir"
    static let autoCopyTextKey = "phonetransfer.autoCopyText"
    static let pageURLKey = "phonetransfer.pageURL"
    static let lanInterfaceKey = "phonetransfer.lanInterface"

    /// 局域网模式在哪块网卡上监听：`""` = 自动（默认路由那块），`"*"` = 所有网卡，其他 = BSD 名（如 `en0`）。
    /// 存网卡名而不是 IP：换网络后 IP 会变，网卡名不变。
    static var lanInterface: String {
        get { UserDefaults.standard.string(forKey: lanInterfaceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: lanInterfaceKey) }
    }

    /// 公网模式的手机页面（本仓库 GitHub Pages 发布的 `mac/Sources/Resources/PhoneTransfer/`）。
    static let defaultPageURL = "https://qiaob.github.io/baobox_mac/transfer/"

    static var defaultReceiveDir: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        return downloads.appendingPathComponent("Baobox", isDirectory: true)
    }

    static var receiveDir: URL {
        let path = (UserDefaults.standard.string(forKey: receiveDirKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? defaultReceiveDir : URL(fileURLWithPath: path, isDirectory: true)
    }

    static var autoCopyText: Bool { UserDefaults.standard.bool(forKey: autoCopyTextKey) }

    /// 只接受 https 地址（手机页面必须在安全上下文里才能用 WebCrypto），否则回退默认值。
    static var pageURL: String {
        var text = (UserDefaults.standard.string(forKey: pageURLKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
        guard text.lowercased().hasPrefix("https://"), URL(string: text) != nil else { return defaultPageURL }
        return text
    }

    /// 本机显示名：取主机名去掉 `.local`，连字符换空格（`Host.current()` 可能做 DNS 查询而卡住，不用它）。
    static var macName: String {
        var name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { name = String(name.dropLast(6)) }
        name = name.replacingOccurrences(of: "-", with: " ")
        return name.isEmpty ? "Mac" : name
    }

    /// 确保目录存在。失败返回 false。
    static func ensureDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) { return isDir.boolValue }
        return (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil
    }

    /// 把手机传来的文件名清理成安全的单段文件名：去掉路径分隔符、控制字符、开头的点。
    static func sanitize(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        name = String(name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 200 { name = String(name.suffix(200)) }
        return name.isEmpty ? "file" : name
    }

    /// 目录里不重名的目标路径：`a.jpg` → `a 2.jpg` → `a 3.jpg` …
    static func uniqueURL(in dir: URL, name: String) -> URL {
        let clean = sanitize(name)
        var candidate = dir.appendingPathComponent(clean)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (clean as NSString).pathExtension
        let base = (clean as NSString).deletingPathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path), n < 10_000 {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = dir.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }

    /// 安全随机字节的 base64url（无填充）。
    static func randomToken(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for i in 0..<count { bytes[i] = UInt8.random(in: 0...255) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 文件大小（字节）；取不到返回 nil。目录也返回 nil。
    static func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
              values.isDirectory != true else { return nil }
        return Int64(values.fileSize ?? 0)
    }
}
