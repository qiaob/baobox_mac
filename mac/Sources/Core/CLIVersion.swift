import Foundation

/// Claude Code / Codex 两个助手共用的版本检查（#164，docs/codex-assistant/DEDUPE-P2.md §2.4 类 9）：
/// 本机 CLI 的 `--version`（设置页状态卡、维护节）与 npm 上的最新版（维护节「检查最新版」）。
///
/// 两边原来各有一份逐行相同的子进程与请求，只差二进制与包名 —— 现在由模块传进来。
/// 只 import Foundation：进 BaoboxTests（npm 那半在测试里用 `URLProtocol` 桩，不真去打网络）。
enum CLIVersion {

    /// `<binary> --version` 的输出（去首尾空白，空 = nil）。经 `/bin/zsh -lc` 跑：登录 shell 保证 PATH 完整
    /// （binary 可能只是 "claude"）。起不来、输出不是 UTF-8 也是 nil；不看退出码；stderr 丢弃。
    /// 同步等子进程（没有超时）：后台线程调用。
    static func local(binary: String) -> String? {
        guard let output = Shell.output("/bin/zsh", localArguments(binary: binary)) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `local` 交给 `/bin/zsh` 的参数：`-lc`，`'<binary>' --version`（binary 单引号转义）。
    static func localArguments(binary: String) -> [String] {
        ["-lc", "\(Shell.quote(binary)) --version"]
    }

    /// npm registry 上 `package` 的最新版本号：请求 `https://registry.npmjs.org/<package>/latest`（超时 10 秒），
    /// 取响应的 `version`。网络失败、解析不出都是 nil（不看 HTTP 状态码）。回调在主线程。
    static func latestOnNPM(package: String, completion: @escaping @Sendable (String?) -> Void) {
        guard let url = npmLatestURL(package: package) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let version = data.flatMap { parseNPMLatest($0) }
            DispatchQueue.main.async { completion(version) }
        }.resume()
    }

    /// `latestOnNPM` 请求的地址（包名原样拼进路径，如 `@openai/codex`）。
    static func npmLatestURL(package: String) -> URL? {
        URL(string: "https://registry.npmjs.org/\(package)/latest")
    }

    /// `…/latest` 响应的解析：顶层对象的 `version` 字符串，原样返回；坏 JSON、不是对象、没有或不是字符串都是 nil。
    static func parseNPMLatest(_ data: Data) -> String? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any],
              let version = object["version"] as? String else { return nil }
        return version
    }
}
