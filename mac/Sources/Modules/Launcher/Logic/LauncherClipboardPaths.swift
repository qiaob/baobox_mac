import Foundation

// 快速入口：剪贴板历史里出现过的路径（docs/launcher/TECH_DESIGN.md §6.4「来源 D」，PR 11）。
// 2026-11-24 用户的截图里第二行就是那个文件的完整路径（他之前复制过）：复制过路径，之后只打文件名就该找得到它。
// 从剪贴板条目的文字里抽出绝对路径（纯函数），按条目键缓存（文字没变就不重抽）。只在内存里，不写盘、不联网；
// 敏感条目剪贴板本来就不交过来。存不存在由来源在后台查（`LauncherMemoryFileSearch.verifiesExistence`）。
// 只依赖 Foundation，进 BaoboxTests。

/// 交给抽路径的一条文字（剪贴板 / 片段条目的搜索全文：去掉开头空白后的前 200 个字符）。
struct LauncherTextSnapshot: Equatable, Sendable {
    /// 条目键（「来源 id/条目 id」）。
    let key: String
    let text: String
    let date: Date?
}

enum LauncherClipboardPaths {
    /// 一条文字最多抽几个路径。
    static let maxPerText = 8
    /// 路径最长多少个字节（再长的多半不是路径）。
    static let maxPathBytes = 1024

    /// 从一段文字里抽绝对路径：
    /// - 整段（去首尾空白、单行）就是一个路径（同输入框认路径的规则：引号、`file://`、反斜杠转义、`~/`、末尾的 `:行号`）→ 先收它；
    ///   整段没有空白就只有它。有空白时分不清是「带空格的路径」还是「路径 + 一句话」，两种都收，存不存在由来源去查；
    ///   但空白后面又是一个路径的开头（`/a/x.txt then /b/y.txt`）就不当整段收。只有一个 `~`（主目录本身）不收。
    /// - 再找文字里以 `/`、`~/`、`file://` 开头的一段：前面是开头、空白、引号、括号、`=`、`:`、`,`、汉字或全角标点，
    ///   到空白、引号、括号、全角标点或行尾为止；末尾的 `.,;:!?` 去掉，`:行号` 去掉；`//` 开头的（网址的一部分）不要。
    /// 去重，最多 `maxPerText` 个。主目录用来展开 `~`。
    static func extract(from text: String, home: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result: [String] = []
        let characters = Array(trimmed)
        if trimmed != "~", !trimmed.contains(where: \.isNewline), !hasPathAfterWhitespace(characters),
           let whole = LauncherPathInput.parse(trimmed, home: home),
           let path = cleaned(whole.pathWithoutLineSuffix ?? whole.path) {
            result.append(path)
            if !trimmed.contains(where: \.isWhitespace) { return result }
        }
        var index = 0
        while index < characters.count, result.count < maxPerText {
            let startsHere = characters[index] == "/"
                || (characters[index] == "~" && index + 1 < characters.count && characters[index + 1] == "/")
                || startsWithFileURL(characters, at: index)
            guard startsHere, index == 0 || isStartBoundary(characters[index - 1]) else {
                index += 1
                continue
            }
            var end = index
            while end < characters.count, !isTerminator(characters[end]) {
                // 反斜杠转义的空格、括号（终端里拖进来的路径 `My\ File.txt`）算路径的一部分。
                end += characters[end] == "\\" && end + 1 < characters.count ? 2 : 1
            }
            end = min(end, characters.count)
            let token = String(characters[index..<end])
            index = max(end, index + 1)
            guard !token.hasPrefix("//"),
                  let parsed = LauncherPathInput.parse(trimmingTrailingPunctuation(token), home: home),
                  let path = cleaned(parsed.pathWithoutLineSuffix ?? parsed.path),
                  !result.contains(path)
            else { continue }
            result.append(path)
        }
        return result
    }

    /// 合法的路径：末尾的 `/` 去掉；不是根目录；不太长。
    private static func cleaned(_ path: String) -> String? {
        let trimmed = LauncherPathDisplay.trimmingTrailingSlashes(path)
        guard trimmed.hasPrefix("/"), trimmed != "/", !trimmed.hasPrefix("//"), trimmed.utf8.count <= maxPathBytes else { return nil }
        return trimmed
    }

    /// 空白后面紧跟着一个路径的开头（`/`、`~/`）：这段文字里不止一个路径，不能当整段收。
    private static func hasPathAfterWhitespace(_ characters: [Character]) -> Bool {
        for index in characters.indices.dropLast() where characters[index].isWhitespace {
            let next = characters[index + 1]
            if next == "/" { return true }
            if next == "~", index + 2 < characters.count, characters[index + 2] == "/" { return true }
        }
        return false
    }

    private static func startsWithFileURL(_ characters: [Character], at index: Int) -> Bool {
        let prefix = Array("file://")
        guard index + prefix.count <= characters.count else { return false }
        return zip(characters[index..<(index + prefix.count)], prefix).allSatisfy { $0.lowercased() == $1.lowercased() }
    }

    /// 路径前面可以是什么（不然 `and/or`、`1/2`、网址中间的 `/path` 都会被当成路径）。
    private static func isStartBoundary(_ character: Character) -> Bool {
        if character.isWhitespace { return true }
        if "\"'`([{<=:,;|“”‘’（【《「『，。；：、".contains(character) { return true }
        return character.unicodeScalars.first?.properties.isIdeographic == true
    }

    /// 路径到哪里为止。逗号、分号不算（名字里可能有），末尾的由 `trimmingTrailingPunctuation` 去掉。
    private static func isTerminator(_ character: Character) -> Bool {
        character.isWhitespace || "\"'`()[]{}<>|“”‘’（）【】《》「」『』，。；：、！？".contains(character)
    }

    /// 末尾的句读和多出来的右括号去掉（`/a/b.py.`、`/a/b.py,`、`(see /a/b.py)` 已经在括号处断开）。
    private static func trimmingTrailingPunctuation(_ token: String) -> String {
        var result = Substring(token)
        while let last = result.last, ".,;:!?".contains(last), result.count > 1 { result = result.dropLast() }
        return String(result)
    }
}

/// 剪贴板路径的缓存：按条目键记「文字 → 抽出的路径」，文字没变就不重抽；这次没出现的条目从缓存删掉。
/// 不是线程安全的值类型：由一个串行后台队列独占（`LauncherFileSources`）。
struct LauncherClipboardPathIndex {
    /// 一共最多留多少个路径（新的在前）。
    static let maxPaths = 2000

    private var cache: [String: (text: String, paths: [String])] = [:]

    var cachedEntries: Int { cache.count }

    /// 换成这一批条目，返回建表用的路径：按条目时间新的在前，同一个路径（按规范路径）只留最新的那次，最多 `maxPaths` 个；
    /// 路径的「最近使用」= 复制它的时间。`extracted` 是这次现抽了几条（其余用缓存）。
    mutating func update(_ snapshots: [LauncherTextSnapshot], home: String)
        -> (files: [LauncherFileCatalog.File], extracted: Int) {
        var next: [String: (text: String, paths: [String])] = [:]
        next.reserveCapacity(snapshots.count)
        var extracted = 0
        var found: [(path: String, date: Date?, order: Int)] = []
        for snapshot in snapshots {
            let paths: [String]
            if let cached = cache[snapshot.key], cached.text == snapshot.text {
                paths = cached.paths
            } else {
                paths = LauncherClipboardPaths.extract(from: snapshot.text, home: home)
                extracted += 1
            }
            next[snapshot.key] = (snapshot.text, paths)
            for path in paths { found.append((path, snapshot.date, found.count)) }
        }
        cache = next
        found.sort { a, b in
            let aDate = a.date ?? .distantPast
            let bDate = b.date ?? .distantPast
            return aDate != bDate ? aDate > bDate : a.order < b.order
        }
        var seen = Set<String>()
        var files: [LauncherFileCatalog.File] = []
        for item in found where files.count < Self.maxPaths {
            guard seen.insert(LauncherFileMerge.key(for: item.path)).inserted else { continue }
            files.append(LauncherFileCatalog.File(path: item.path, lastUsed: item.date))
        }
        return (files, extracted)
    }
}
