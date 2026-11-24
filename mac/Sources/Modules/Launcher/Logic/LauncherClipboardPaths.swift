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
    /// 一条文字最多抽几个路径（含下面的变体）。
    static let maxPerText = 12
    /// 一段最多出几个变体（原样 + 在 `,` `;` `=` 处截断的至多 2 个 + 去掉末尾汉字 / 全角字符的至多 2 个）。
    static let maxVariantsPerToken = 5
    /// 一条文字最多看几处路径开头（`=/=/=/…` 这种一处都抽不出来的，不至于每一处都从头扫到尾）。
    static let maxStartsPerText = 24
    /// 已知的顶层目录名（PR 11 复查后定）：汉字 / 全角字符后面的 `/` 只有跟着它们才算路径开头；路径里「非 ASCII 字符后面紧跟
    /// `/<它们>` 或 `~/`」就是下一个路径开始了（`…最终版.pdf和/Users/qiao/b.md`）。
    static let knownTopLevelNames: Set<String> = [
        "Users", "private", "tmp", "var", "Applications", "opt", "usr", "Volumes", "Library", "System", "etc", "bin", "sbin",
        "cores", "Network",
    ]
    /// 比较时不分大小写（APFS 默认不区分大小写，`/users/qiao/…` 也是同一个地方）。
    private static let knownTopLevelNamesLowercased = Set(knownTopLevelNames.map { $0.lowercased() })
    /// 路径最长多少个字节（再长的多半不是路径）。
    static let maxPathBytes = 1024

    /// 从一段文字里抽绝对路径：
    /// - 整段（去首尾空白、单行）就是一个路径（同输入框认路径的规则：引号、`file://`、反斜杠转义、`~/`、末尾的 `:行号`）→ 先收它；
    ///   整段没有空白就只有它。有空白时分不清是「带空格的路径」还是「路径 + 一句话」，两种都收，存不存在由来源去查；
    ///   但空白后面又是一个路径的开头（`/a/x.txt then /b/y.txt`）就不当整段收。只有一个 `~`（主目录本身）不收。
    /// - 再找文字里以 `/`、`~/`、`file://` 开头的一段：前面是开头、空白、引号、括号、`=`、`:`、`,`、汉字或全角标点，
    ///   到空白、引号、括号、全角标点或行尾为止；末尾的 `.,;:!?` 去掉，`:行号` 去掉；`//` 开头的（网址的一部分）不要。
    ///   这一段再出几个变体（`variants`，PR 11 独立验证后加）：`文件在/Users/qiao/文档/报告.pdf里` 末尾多带了「里」、
    ///   `cmd=/usr/local/bin/foo,arg=/etc/hosts` 被当成一整段、`path:/var/log/system.log;next` 带上了 `;next` ——
    ///   分不清哪个对，都给出来，由来源在后台 `stat` 决定哪个存在。一段之后从它的下一个字接着找（`arg=/etc/hosts` 里的第二个路径）。
    /// - 中文里夹着路径（PR 11 复查后定）：前面是汉字 / 全角字符的 `/` 只有后面跟着已知的顶层目录名（`knownTopLevelNames`）才算
    ///   路径开头（`~/` 照旧算）—— 不然 `/Users/qiao/文档/项目/…` 里每个「汉字 + /」都抽出一个垃圾候选占名额；一段路径在
    ///   「非 ASCII 字符后面紧跟一个新的绝对路径开头」处结束（`最终版.pdf和/Users/qiao/b.md` 是两个路径）。断开时不断开的那一段
    ///   也作为一个候选留着（`~/文档/bin/x` 这种中文目录下正好有个 `bin` 的，断开反而错了），哪个存在由 `stat` 决定。
    ///   第一级目录名里一个字母数字都没有的（`/=/=`）不收。
    /// 去重，最多 `maxPerText` 个。主目录用来展开 `~`。
    static func extract(from text: String, home: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result: [String] = []
        let characters = Array(trimmed)
        // 整段是路径：开头得是 `/`、`~`、引号或 `file:`，别的不用试（省掉一次整段的解析）。
        if let first = characters.first, "/~\"'fF".contains(first),
           trimmed != "~", !trimmed.contains(where: \.isNewline), !hasPathAfterWhitespace(characters),
           let whole = LauncherPathInput.parse(trimmed, home: home),
           let path = cleaned(whole.pathWithoutLineSuffix ?? whole.path) {
            result.append(path)
            if !trimmed.contains(where: \.isWhitespace) { return result }
        }
        var index = 0
        var starts = 0
        while index < characters.count, result.count < maxPerText, starts < maxStartsPerText {
            let startsHere = characters[index] == "/"
                || (characters[index] == "~" && index + 1 < characters.count && characters[index + 1] == "/")
                || startsWithFileURL(characters, at: index)
            guard startsHere, index == 0 || startsAfter(characters[index - 1], characters: characters, at: index) else {
                index += 1
                continue
            }
            starts += 1
            var end = index
            var split: Int?
            while end < characters.count, !isTerminator(characters[end]) {
                // 非 ASCII 字符后面紧跟一个新的绝对路径开头：这一段到这里为止（不断开的那一段也留作一个候选）。
                if split == nil, end > index, !characters[end].isASCII, end + 1 < characters.count,
                   startsKnownAbsolutePath(characters, at: end + 1) {
                    split = end
                }
                // 反斜杠转义的空格、括号（终端里拖进来的路径 `My\ File.txt`）算路径的一部分。
                end += characters[end] == "\\" && end + 1 < characters.count ? 2 : 1
            }
            end = min(end, characters.count)
            let token = String(characters[index..<(split ?? end)])
            // 从下一个字接着找：这一段里可能还有别的路径开头（`foo,arg=/etc/hosts`）；路径中间的 `/` 前面是字母数字，不算开头。
            index += 1
            guard !token.hasPrefix("//") else { continue }
            var candidates = variants(of: trimmingTrailingPunctuation(token))
            if split != nil {
                // 不断开的那一段（连同它的变体）也留作候选。
                candidates += variants(of: trimmingTrailingPunctuation(String(characters[(index - 1)..<end])))
            }
            for variant in candidates where result.count < maxPerText {
                guard let path = tokenPath(trimmingTrailingPunctuation(variant), home: home).flatMap(cleaned),
                      !result.contains(path)
                else { continue }
                result.append(path)
            }
        }
        return result
    }

    /// 一段的几种可能：原样；在 `,` `;` `=` 处截断的（前两处）；去掉末尾一个汉字 / 全角字符的、去掉末尾所有汉字 / 全角字符的
    /// （`报告里` → `报告`；`报告.pdf里面` → `报告.pdf`）。去重，最多 `maxVariantsPerToken` 个，原样的在最前。
    static func variants(of token: String) -> [String] {
        var result = [token]
        func add(_ candidate: Substring) {
            let text = String(candidate)
            if !text.isEmpty, !result.contains(text), result.count < maxVariantsPerToken { result.append(text) }
        }
        var cuts = 0
        for index in token.indices where index != token.startIndex && ",;=".contains(token[index]) {
            add(token[..<index])
            cuts += 1
            if cuts == 2 { break }
        }
        if let last = token.last, isWide(last) {
            add(token.dropLast())
            var stripped = Substring(token)
            while let tail = stripped.last, isWide(tail) { stripped = stripped.dropLast() }
            add(stripped)
        }
        return result
    }

    /// 汉字、全角字符（全角 ASCII、全角标点）：中文句子里紧跟在路径后面的字。
    private static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar.properties.isIdeographic || (0xFF00...0xFFEF).contains(scalar.value) || (0x3000...0x303F).contains(scalar.value)
    }

    /// 合法的路径：末尾的 `/` 去掉；不是根目录；不太长；第一级目录名里至少有一个字母或数字（`/=/=/=` 不收）。
    private static func cleaned(_ path: String) -> String? {
        let trimmed = LauncherPathDisplay.trimmingTrailingSlashes(path)
        guard trimmed.hasPrefix("/"), trimmed != "/", !trimmed.hasPrefix("//"), trimmed.utf8.count <= maxPathBytes,
              trimmed.dropFirst().prefix(while: { $0 != "/" }).contains(where: { $0.isLetter || $0.isNumber })
        else { return nil }
        return trimmed
    }

    /// 前一个字是 `previous` 时，这里（`/`、`~/`、`file://`）能不能算路径开头：前面是空白、引号、括号、`=` `:` `,` 这些照旧算；
    /// 前面是汉字 / 全角字符时，`~/`、`file://` 算，`/` 只有后面跟着已知的顶层目录名才算。
    private static func startsAfter(_ previous: Character, characters: [Character], at index: Int) -> Bool {
        guard isStartBoundary(previous) else { return false }
        guard isWide(previous) else { return true }
        return characters[index] != "/" || startsKnownAbsolutePath(characters, at: index)
    }

    /// 这里是不是一个新的绝对路径的开头：`~/`，或 `/` 后面是已知的顶层目录名（后面接 `/` 或到头）。
    private static func startsKnownAbsolutePath(_ characters: [Character], at index: Int) -> Bool {
        guard index < characters.count else { return false }
        if characters[index] == "~" { return index + 1 < characters.count && characters[index + 1] == "/" }
        guard characters[index] == "/" else { return false }
        var name = ""
        var next = index + 1
        while next < characters.count, characters[next] != "/", name.count < 13 {
            let character = characters[next]
            guard character.isASCII, character.isLetter else { return false }
            name.append(character)
            next += 1
        }
        return knownTopLevelNamesLowercased.contains(name.lowercased()) && (next == characters.count || characters[next] == "/")
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

    /// 文字里的一段 → 绝对路径（同输入框认路径的规则，但这里的一段不会带引号、空格）：`file://` 交给 `LauncherPathInput`
    /// 解码；`~/` 展开；反斜杠转义去掉；末尾的 `:行号` 去掉。不以 `/`、`~/`、`file://` 开头为 nil。
    private static func tokenPath(_ token: String, home: String) -> String? {
        if token.first == "f" || token.first == "F" {
            return LauncherPathInput.parse(token, home: home).map { $0.pathWithoutLineSuffix ?? $0.path }
        }
        var text = token.contains("\\") ? LauncherPathInput.unescapingBackslashes(token) : token
        if text.hasPrefix("~/") {
            let home = LauncherPathDisplay.trimmingTrailingSlashes(home)
            text = (home == "/" ? "" : home) + text.dropFirst()
        } else if !text.hasPrefix("/") {
            return nil
        }
        return LauncherPathInput.strippingLineSuffix(text) ?? text
    }

    private static let fileURLPrefix = Array("file://")

    private static func startsWithFileURL(_ characters: [Character], at index: Int) -> Bool {
        guard characters[index] == "f" || characters[index] == "F", index + fileURLPrefix.count <= characters.count else { return false }
        return zip(characters[index..<(index + fileURLPrefix.count)], fileURLPrefix).allSatisfy { $0.lowercased() == $1.lowercased() }
    }

    /// 路径前面可以是这些（不然 `and/or`、`1/2`、网址中间的 `/path` 都会被当成路径）；另外空白和汉字也可以。
    /// ASCII 的查表、别的按码点查（逐字判断，比按 `Character` 哈希快得多：2000 条中文偏多的文字第一次抽从 220 ms 降下来）。
    /// ASCII 的空白全在表里（空格、Tab、换行 `\n` `\r`、`\u{0B}`、`\u{0C}`；`"\r\n"` 是一个 `Character`，`asciiValue` 是 `\n`）——
    /// 原来按 `isWhitespace` 判断，改成查表时漏了换行，「Created:\n/路径」这种多行文字里的路径认不出（复查发现）。
    private static let asciiStartBoundaries = asciiTable("\"'`([{<=:,;|" + asciiWhitespace)
    private static let wideStartBoundaries = scalarSet("“”‘’（【《「『，。；：、")
    /// 路径到这些为止（另外空白也是）。逗号、分号不算（名字里可能有），末尾的由 `trimmingTrailingPunctuation` 去掉。
    private static let asciiTerminators = asciiTable("\"'`()[]{}<>|" + asciiWhitespace)
    private static let asciiWhitespace = " \t\n\r\u{0B}\u{0C}"
    private static let wideTerminators = scalarSet("“”‘’（）【】《》「」『』，。；：、！？")

    private static func asciiTable(_ characters: String) -> [Bool] {
        var table = [Bool](repeating: false, count: 128)
        for scalar in characters.unicodeScalars where scalar.value < 128 { table[Int(scalar.value)] = true }
        return table
    }

    private static func scalarSet(_ characters: String) -> Set<UInt32> {
        Set(characters.unicodeScalars.map(\.value))
    }

    private static func isStartBoundary(_ character: Character) -> Bool {
        if let ascii = character.asciiValue { return asciiStartBoundaries[Int(ascii)] }
        guard let scalar = character.unicodeScalars.first else { return false }
        return wideStartBoundaries.contains(scalar.value) || scalar.properties.isIdeographic || character.isWhitespace
    }

    private static func isTerminator(_ character: Character) -> Bool {
        if let ascii = character.asciiValue { return asciiTerminators[Int(ascii)] }
        guard let scalar = character.unicodeScalars.first else { return false }
        return wideTerminators.contains(scalar.value) || character.isWhitespace
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
