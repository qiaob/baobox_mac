import Foundation

/// CLI 会话日志（JSONL：一行一个 JSON）逐行解析的小工具，Claude Code 助手与 Codex 助手共用（#109）。
/// 两个 ISO8601 formatter 建成静态常量复用。纯函数，任意线程可调。
enum CLIJSONL {

    /// 带毫秒的 ISO8601（首选）。
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 不带毫秒的 ISO8601（回退）。
    private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 解析 ISO8601 时间戳，先试带毫秒再退无毫秒。失败返回 nil。
    static func parseDate(_ string: String) -> Date? {
        if let date = iso8601Fractional.date(from: string) { return date }
        return iso8601Plain.date(from: string)
    }

    /// 把一行 JSON 数据解析为字典；坏 JSON、或顶层不是对象（数组、字符串、数字）返回 nil。
    static func parseObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// 会话里项目路径的展示用小工具。
enum CLISessionPaths {

    /// 从路径取展示名（末段）；末段为空时返回原路径。
    static func projectName(fromPath path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}
