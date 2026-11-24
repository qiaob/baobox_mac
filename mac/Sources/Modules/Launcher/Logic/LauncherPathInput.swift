import Foundation

// 快速入口「输入是路径」（docs/launcher/TECH_DESIGN.md §6.5）：认出贴进来的路径、展开成绝对路径，
// 以及显示和补全要用的几个小函数。这里不碰文件系统（存不存在、是文件还是文件夹由 App 侧在后台查），
// 主目录由调用方传入。只依赖 Foundation，进 BaoboxTests。

/// 认出来的一个路径输入。
struct LauncherPathInput: Equatable, Sendable {
    /// 展开后的绝对路径：`~` 换成主目录，两边的引号、`file://`、反斜杠转义都已去掉。末尾的 `/` 保留。
    let path: String
    /// 末尾带行号（`:12`、`:12:3`）时去掉后缀的路径：带后缀的不存在、去掉后存在时按它算。没有后缀为 nil。
    let pathWithoutLineSuffix: String?
    /// 用户写的是 `~` 开头：补全时保持 `~/…` 的写法。
    let usesTilde: Bool

    /// 认路径。规则：
    /// - 去首尾空白；有换行的不算（一次贴了好几行）。
    /// - 两边成对的引号（`"…"`、`'…'`）去掉；`file://`（可带 `localhost`）开头的按 URL 解码；
    ///   不在引号里、也不是 URL 时，反斜杠转义（`My\ File.txt`、`\(1\)`）去掉反斜杠。
    /// - 之后必须以 `/` 或 `~` 开头：`~`、`~/…` 展开成主目录；`~别人` 不认；只有 `/`（一个或几个）不认。
    ///   所以 `1/2`、`24/7` 这类算式不会进来。
    /// - 末尾是 `:数字` 或 `:数字:数字` 时另给一个去掉后缀的路径。
    static func parse(_ input: String, home: String) -> LauncherPathInput? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isNewline) else { return nil }

        var quoted = false
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            quoted = true
        }

        if text.lowercased().hasPrefix("file://") {
            var rest = String(text.dropFirst("file://".count))
            if rest.lowercased().hasPrefix("localhost/") { rest = String(rest.dropFirst("localhost".count)) }
            guard rest.hasPrefix("/") else { return nil }
            text = rest.removingPercentEncoding ?? rest
        } else if !quoted {
            text = unescapingBackslashes(text)
        }

        let home = LauncherPathDisplay.trimmingTrailingSlashes(home)
        let path: String
        let usesTilde: Bool
        if text == "~" {
            path = home
            usesTilde = true
        } else if text.hasPrefix("~/") {
            path = (home == "/" ? "" : home) + text.dropFirst()
            usesTilde = true
        } else if text.hasPrefix("/") {
            guard text.contains(where: { $0 != "/" }) else { return nil }
            path = text
            usesTilde = false
        } else {
            return nil
        }
        return LauncherPathInput(path: path, pathWithoutLineSuffix: strippingLineSuffix(path), usesTilde: usesTilde)
    }

    /// 输入从 `previous` 改成了这个，还是在同一处打字（同一个上一级目录里改最后一段、往深里打、往回删）：
    /// 这个路径的结果回来之前，可以先顶着上一次的行，列表不会每打一个字就收起再长出来。
    /// 换成了别处的路径就不顶 —— 免得显示另一个目录的内容、这时按回车打开错的。
    func continues(_ previous: LauncherPathInput) -> Bool {
        if path.hasPrefix(previous.path) || previous.path.hasPrefix(path) { return true }
        return LauncherPathDisplay.split(path).parent == LauncherPathDisplay.split(previous.path).parent
    }

    /// `\X` → `X`（X 不是字母数字时）：终端里拖进来、shell 补全出来的路径会这样转义空格和括号。
    /// 字母数字前的反斜杠留着（那可能就是名字的一部分），末尾单独一个反斜杠也留着。
    static func unescapingBackslashes(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let next = iterator.next() else {
                result.append(character)
                break
            }
            if !(next.isLetter || next.isNumber) {
                result.append(next)
            } else {
                result.append(character)
                result.append(next)
            }
        }
        return result
    }

    /// 末尾的 `:12` / `:12:3`（编辑器、编译器报错里常见的「文件:行:列」）去掉后的路径；没有这种后缀为 nil。
    static func strippingLineSuffix(_ path: String) -> String? {
        var rest = Substring(path)
        for _ in 0..<2 {
            guard let colon = rest.lastIndex(of: ":") else { break }
            let digits = rest[rest.index(after: colon)...]
            guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { break }
            rest = rest[..<colon]
        }
        guard rest.count < path.count, rest.contains(where: { $0 != "/" }) else { return nil }
        return String(rest)
    }
}

/// 路径的显示、拆分与补全文字。
enum LauncherPathDisplay {
    /// 副标题（所在目录）最多这么多个字符，超了中间截断。
    static let maxDirectoryLabelLength = 60

    /// 去掉末尾的 `/`（根目录 `/` 本身保留）。
    static func trimmingTrailingSlashes(_ path: String) -> String {
        var result = Substring(path)
        while result.count > 1, result.hasSuffix("/") { result = result.dropLast() }
        return String(result)
    }

    /// 主目录缩写成 `~`（`/Users/me` → `~`，`/Users/me/Downloads` → `~/Downloads`），别的原样。
    static func abbreviated(_ path: String, home: String) -> String {
        let home = trimmingTrailingSlashes(home)
        guard home != "/", !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// 拆成上一级目录和最后一段（末尾的 `/` 先去掉）：`/a/b/c` → (`/a/b`, `c`)，`/c` → (`/`, `c`)，`/` → (`/`, ``)。
    static func split(_ path: String) -> (parent: String, name: String) {
        let trimmed = trimmingTrailingSlashes(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return ("", trimmed) }
        let name = String(trimmed[trimmed.index(after: slash)...])
        let parent = trimmingTrailingSlashes(String(trimmed[..<slash]))
        return (parent.isEmpty ? "/" : parent, name)
    }

    /// 目录 + 名字。
    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// 所在目录的显示：主目录缩写成 `~`；太长时先把 UUID、十六进制哈希这类长串缩成前 8 位 + 「…」（PR 11：
    /// `/private/tmp/claude-501/-Users-qiao-cmb/e0c00de7-…/scratchpad` 原来截成 `/private/…/<整串 UUID>/scratchpad`，
    /// 看不出是哪个项目），还长就中间截断成「开头几级/…/末尾两级」，
    /// 开头留得越多越好（`~/cmb/worktrees/某个副本/…/docs/launcher` 能看出是哪个副本），末尾两级总留着。
    static func directoryLabel(_ directory: String, home: String, maxLength: Int = maxDirectoryLabelLength) -> String {
        var label = abbreviated(trimmingTrailingSlashes(directory), home: home)
        guard label.count > maxLength else { return label }
        label = shorteningIdentifiers(label)
        guard label.count > maxLength else { return label }
        let absolute = label.hasPrefix("/")
        let parts = label.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 3 else { return label }
        let tail = parts.suffix(2).joined(separator: "/")
        var head: [String] = []
        for part in parts.dropLast(2) {
            let candidate = (absolute ? "/" : "") + (head + [part]).joined(separator: "/") + "/…/" + tail
            guard candidate.count <= maxLength else { break }
            head.append(part)
        }
        if head.isEmpty { return "…/" + tail }
        return (absolute ? "/" : "") + head.joined(separator: "/") + "/…/" + tail
    }

    /// 路径里每一段像标识符的（20 个字符起、去掉连字符后是 16 位以上的十六进制、带数字：UUID、git 哈希）缩成前 8 位 + 「…」。
    static func shorteningIdentifiers(_ label: String) -> String {
        label.split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
            guard part.count >= 20 else { return String(part) }
            let hex = part.filter { $0 != "-" }
            guard hex.count >= 16, hex.allSatisfy(\.isHexDigit), hex.contains(where: \.isNumber) else { return String(part) }
            return part.prefix(8) + "…"
        }.joined(separator: "/")
    }

    /// Tab 补全换进输入框的文字：完整路径，文件夹末尾带 `/`（于是立刻列出它里面的内容）；
    /// 用户写的是 `~` 开头就保持 `~/…`，否则写完整路径 —— 跟着用户自己的写法走。
    static func completionText(path: String, isDirectory: Bool, usesTilde: Bool, home: String) -> String {
        let base = usesTilde ? abbreviated(trimmingTrailingSlashes(path), home: home) : trimmingTrailingSlashes(path)
        guard isDirectory, !base.hasSuffix("/") else { return base }
        return base + "/"
    }
}
