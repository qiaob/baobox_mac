import Foundation

/// 拼 shell 命令、跑小命令的两件小事（#164，docs/codex-assistant/DEDUPE-P2.md §2.4 类 4、类 5）。
///
/// 单引号转义原先有五份逐字相同的副本（Claude Code、Codex 各两处，剪贴板 curl、实时翻译各一处），都改成调这里；
/// 暂缓、不参与编译的网络抓包那份没动（D3）。只 import Foundation：进 BaoboxTests。
enum Shell {

    /// 单引号包裹，内部单引号写成 `'\''`（sh / zsh / bash 通用）：里面的 `$`、反引号、`\`、换行都原样，不展开。
    /// 拼进 shell 命令的路径、会话 id、curl 参数都用它。
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 直接起一个可执行文件（不经过 shell），先读完 stdout 再等退出（免得管道写满把子进程卡住）。
    /// 起不来返回 nil；不看退出码；stderr 丢弃；stdout 不是 UTF-8 也返回 nil。同步等子进程：后台线程调用。
    static func output(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
