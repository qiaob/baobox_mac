import Foundation

/// 本地模型推理进程（llama-server）的 PID 文件（#187）：每个模型一个，`Application Support/Baobox/Translation/` 下的
/// `llama-server.pid`（离线翻译）与 `llama-server-<模型 id>.pid`（纠错和「AI」页装的模型）。拉起进程后写下 PID，
/// 进程正常结束时删掉；App 崩溃或被强杀时它留在盘上，下次启动据此找到遗留的进程并结束。
///
/// 只依赖 Foundation，进 BaoboxTests。读写、结束进程由 `OfflineTranslator` 做。
enum OfflineServerPID {

    /// 文件里记的 PID：去掉首尾空白后是大于 1 的整数才算（0、1、负数、非数字、超出 Int32 都是 nil）。
    static func parse(_ text: String) -> Int32? {
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        return pid
    }

    /// 读 PID 文件；没有文件、读不了或内容不对都是 nil。
    static func read(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// 是不是 PID 文件的文件名：`llama-server.pid` 或 `llama-server-<模型 id>.pid`。
    static func isPIDFileName(_ name: String) -> Bool {
        name == "llama-server.pid" || (name.hasPrefix("llama-server-") && name.hasSuffix(".pid") && name.count > "llama-server-.pid".count)
    }

    /// `directory` 下所有 PID 文件（按文件名排序；只看这一层，目录不算）。目录不存在时为空。
    /// 按文件名找，这次运行没建过实例的模型（「AI」页装的那些）也能覆盖到。
    static func files(in directory: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { isPIDFileName($0.lastPathComponent) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `ps -p <pid> -o comm=` 的输出是不是推理进程（核对进程名，PID 被别的进程占用时不误杀；口径同 #187 之前）。
    static func isServerCommand(_ command: String) -> Bool {
        command.hasSuffix("llama-server")
    }
}
