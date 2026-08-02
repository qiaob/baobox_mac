import Foundation

/// `/etc/hosts` 的读取与「只动自己那一段」的合成。
///
/// 核心约定：本 App 生成的内容一律包在块标记里，**标记之外的内容原样保留**——
/// 系统自带的 localhost 映射、用户手写的条目、别的工具写的东西都不许碰
/// （CLAUDE.md 约定 4：改用户文件只动自己的键）。
enum HostsFile {

    static let beginMarker = "# >>> Baobox begin >>>"
    static let endMarker = "# <<< Baobox end <<<"

    /// 读系统 hosts。文件是全局可读的，不需要提权；读失败返回空串（不 crash、不阻断流程）。
    static func readSystem() -> String {
        (try? String(contentsOfFile: HostsEnv.systemHostsPath, encoding: .utf8)) ?? ""
    }

    static func isManaged(_ content: String) -> Bool {
        content.contains(beginMarker)
    }

    /// 摘掉 Baobox 块，返回「用户自己的那部分」。
    ///
    /// 容错：缺 `endMarker`（用户手工编辑坏了）时，从 `beginMarker` 一直丢到文件末尾——
    /// 宁可少留我们自己的内容，也不能把半截块留在文件里越滚越长。
    static func stripBlock(_ content: String) -> String {
        guard content.contains(beginMarker) else { return content }
        var out: [String] = []
        var inBlock = false
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(beginMarker) {
                inBlock = true
                continue
            }
            if inBlock {
                if trimmed.hasPrefix(endMarker) { inBlock = false }
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// 把已启用方案拼成块正文（不含块标记本身）。每套前加一行注释，方便用户在文件里看出来源。
    static func blockText(from schemes: [HostsScheme]) -> String {
        var parts: [String] = []
        for scheme in schemes {
            let body = scheme.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            parts.append("# --- \(scheme.name) ---\n\(body)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// 用户内容 + Baobox 块 → 完整的新 hosts 文本。块为空时只留用户内容（等于「取消接管」）。
    static func compose(userContent: String, block: String) -> String {
        var base = userContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return base.isEmpty ? "" : base + "\n" }
        if !base.isEmpty { base += "\n\n" }
        return base + beginMarker + "\n"
            + "# 本段由 Baobox 管理，会被整段覆盖；要手工加条目请写在这段之外。\n"
            + body + "\n"
            + endMarker + "\n"
    }
}
