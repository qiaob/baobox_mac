import Foundation

// 会议库的磁盘布局、索引重建与旧记录迁移（docs/meeting/TECH_DESIGN.md §4）。
// 本文件只依赖 Foundation（FileManager），可脱离 App 单独编译测试；主线程模型与写盘队列在 MeetingStore.swift。
//
//   Meetings/
//     index.json                         摘要数组（缓存；缺失 / 损坏就扫目录重建）
//     2026/2026-11-06 14-05 设计评审/
//       meta.json                        元信息与行动项（真相源）
//       meeting.md                       纪要 + 速记 + 转录
//     weekly/2026-W45.md                 周报（第二段）

enum MeetingLibraryLayout {
    static let metaFileName = "meta.json"
    static let markdownFileName = "meeting.md"
    static let indexFileName = "index.json"
    static let weeklyFolderName = "weekly"

    /// 目录名：「2026-11-06 14-05 设计评审」（本地时间；标题去掉文件系统不认的字符，过长截断）。
    static func folderName(start: Date, title: String) -> String {
        let stamp = format(start, "yyyy-MM-dd HH-mm")
        let clean = sanitizedTitle(title)
        return clean.isEmpty ? stamp : stamp + " " + clean
    }

    static func yearFolder(for start: Date) -> String {
        format(start, "yyyy")
    }

    /// 标题 → 能放进文件名的一段：路径分隔符、冒号、控制字符换成空格，连续空白并成一个，去掉开头的点，最多 60 个字符。
    static func sanitizedTitle(_ title: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let replaced = String(String.UnicodeScalarView(title.unicodeScalars.map { banned.contains($0) ? " " : $0 }))
        var clean = replaced.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while clean.hasPrefix(".") { clean.removeFirst() }
        clean = clean.trimmingCharacters(in: .whitespaces)
        if clean.count > 60 {
            clean = String(clean.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        return clean
    }

    /// 从目录名开头的「yyyy-MM-dd HH-mm」读出开始时间（meta.json 缺了开始时间时用）。
    static func date(fromFolderName name: String) -> Date? {
        guard name.count >= 16 else { return nil }
        return parse(String(name.prefix(16)), "yyyy-MM-dd HH-mm")
    }

    /// 目录名里日期后面的标题部分。
    static func title(fromFolderName name: String) -> String {
        guard date(fromFolderName: name) != nil else { return name }
        return String(name.dropFirst(16)).trimmingCharacters(in: .whitespaces)
    }

    /// 旧版实时翻译记录的文件名「yyyy-MM-dd HH-mm-ss.md」→ 开始时间。
    static func date(fromLegacyFileName name: String) -> Date? {
        let base = (name as NSString).deletingPathExtension
        guard base.count >= 19 else { return nil }
        return parse(String(base.prefix(19)), "yyyy-MM-dd HH-mm-ss")
    }

    /// `base` 已被占用时加「 (2)」「 (3)」…
    static func unique(_ base: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(base) else { return base }
        var index = 2
        while isTaken("\(base) (\(index))") { index += 1 }
        return "\(base) (\(index))"
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func parse(_ text: String, _ pattern: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = pattern
        return formatter.date(from: text)
    }
}

/// 扫目录：重建索引、与磁盘对账、读单个会议目录。
enum MeetingLibraryScanner {
    /// 会议库里所有会议目录（相对路径「yyyy/目录名」）：根目录下四位数字的年份文件夹里、带 meta.json 或 meeting.md 的子目录。
    static func directories(root: URL, fileManager: FileManager = .default) -> [String] {
        guard let years = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var result: [String] = []
        for year in years.sorted() where year.count == 4 && year.allSatisfy(\.isNumber) {
            let yearURL = root.appendingPathComponent(year, isDirectory: true)
            guard let names = try? fileManager.contentsOfDirectory(atPath: yearURL.path) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let folder = yearURL.appendingPathComponent(name, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }
                let hasMeta = fileManager.fileExists(atPath: folder.appendingPathComponent(MeetingLibraryLayout.metaFileName).path)
                let hasMarkdown = fileManager.fileExists(
                    atPath: folder.appendingPathComponent(MeetingLibraryLayout.markdownFileName).path)
                if hasMeta || hasMarkdown {
                    result.append(year + "/" + name)
                }
            }
        }
        return result
    }

    /// 读一个会议目录。meta.json 缺 id / 开始时间时按目录补（id 用目录路径，稳定不变）；meta.json 没有或读不出
    /// JSON 对象、但有 meeting.md 时，按目录名补一条「仅转录」的记录（写盘中途崩溃留下的）。都没有返回 nil。
    static func record(root: URL, dir: String, fileManager: FileManager = .default) -> MeetingRecord? {
        let folder = root.appendingPathComponent(dir, isDirectory: true)
        let name = (dir as NSString).lastPathComponent
        let folderDate = MeetingLibraryLayout.date(fromFolderName: name)
        if let data = fileManager.contents(atPath: folder.appendingPathComponent(MeetingLibraryLayout.metaFileName).path),
           var meta = MeetingMeta.decode(data) {
            if meta.id.isEmpty { meta.id = dir }
            if meta.start == .distantPast {
                meta.start = folderDate ?? modificationDate(of: folder, fileManager: fileManager) ?? Date()
            }
            if meta.title.isEmpty { meta.title = MeetingLibraryLayout.title(fromFolderName: name) }
            return MeetingRecord(dir: dir, meta: meta)
        }
        let markdown = folder.appendingPathComponent(MeetingLibraryLayout.markdownFileName)
        guard fileManager.fileExists(atPath: markdown.path) else { return nil }
        let start = folderDate ?? modificationDate(of: markdown, fileManager: fileManager) ?? Date()
        let meta = MeetingMeta(id: dir, type: .free, title: MeetingLibraryLayout.title(fromFolderName: name),
                               start: start, status: .transcribed, template: "content")
        return MeetingRecord(dir: dir, meta: meta)
    }

    /// 扫目录重建索引（index.json 缺失 / 损坏时），按开始时间倒序。
    static func rebuild(root: URL, fileManager: FileManager = .default) -> [MeetingRecord] {
        sorted(directories(root: root, fileManager: fileManager).compactMap {
            record(root: root, dir: $0, fileManager: fileManager)
        })
    }

    /// 索引与磁盘对账：目录没了的去掉；磁盘上有、索引里没有的读进来（写盘写到一半退出、用户在 Finder 里删了目录）。
    static func reconcile(_ records: [MeetingRecord], root: URL,
                          fileManager: FileManager = .default) -> (records: [MeetingRecord], changed: Bool) {
        let onDisk = Set(directories(root: root, fileManager: fileManager))
        var kept = records.filter { onDisk.contains($0.dir) }
        var changed = kept.count != records.count
        let known = Set(kept.map(\.dir))
        var ids = Set(kept.map(\.id))
        for dir in onDisk.subtracting(known).sorted() {
            guard let record = record(root: root, dir: dir, fileManager: fileManager), !ids.contains(record.id) else {
                continue
            }
            ids.insert(record.id)
            kept.append(record)
            changed = true
        }
        return (sorted(kept), changed)
    }

    /// 解析 index.json：不是数组、或有元素解不出来（多半是写坏了）→ nil，调用方扫目录重建。
    static func decodeIndex(_ data: Data) -> [MeetingRecord]? {
        guard let elements = try? JSONDecoder().decode([MeetingLenient.Element<MeetingRecord>].self, from: data) else {
            return nil
        }
        let records = elements.compactMap(\.value)
        guard records.count == elements.count else { return nil }
        return records
    }

    static func encodeIndex(_ records: [MeetingRecord]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(records)
    }

    /// 开始时间倒序（新的在前）；同一时刻按目录名，顺序稳定。
    static func sorted(_ records: [MeetingRecord]) -> [MeetingRecord] {
        records.sorted { lhs, rhs in
            lhs.meta.start != rhs.meta.start ? lhs.meta.start > rhs.meta.start : lhs.dir > rhs.dir
        }
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// 首次启动把旧版实时翻译记录（`livetranslate.record.folder`，默认 ~/Documents/Baobox 实时翻译记录）按引用导入会议库：
/// 每个 .md 一条自由听译，`legacyPath` 指向原文件，文件原地不动。
enum MeetingLegacyImporter {
    struct Item: Equatable {
        /// 原文件的绝对路径。
        let path: String
        let start: Date
        let end: Date?
        /// 记录里已经有整理好的纪要。
        let summarized: Bool
    }

    /// 旧记录文件夹顶层的 .md：文件名推开始时间（推不出用修改时间），读文件头推结束时间与有没有纪要。
    static func scan(folder: URL, fileManager: FileManager = .default) -> [Item] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted().compactMap { name -> Item? in
            guard !name.hasPrefix("."), (name as NSString).pathExtension.lowercased() == "md" else { return nil }
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return nil
            }
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            guard let start = MeetingLibraryLayout.date(fromLegacyFileName: name)
                    ?? attributes?[.creationDate] as? Date ?? attributes?[.modificationDate] as? Date else { return nil }
            let content = fileManager.contents(atPath: url.path).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let parsed = parse(content: content)
            return Item(path: url.path, start: start, end: parsed.end, summarized: parsed.summarized)
        }
    }

    /// 旧记录的文件头：「- 开始：yyyy-MM-dd HH:mm:ss」「- 结束：yyyy-MM-dd HH:mm:ss（…）」（中英文都一样是这种时间格式），
    /// 第二个时间就是结束；纪要整理好了会有「### 要点」/「### Key points」。
    static func parse(content: String) -> (end: Date?, summarized: Bool) {
        var stamps: [Date] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let pattern = try? NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#)
        for line in content.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") { break }
            guard line.hasPrefix("- "), let pattern else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = pattern.firstMatch(in: line, range: range), let found = Range(match.range, in: line),
               let date = formatter.date(from: String(line[found])) {
                stamps.append(date)
            }
        }
        let summarized = content.contains("### 要点") || content.contains("### Key points")
        return (stamps.count >= 2 ? stamps[1] : nil, summarized)
    }
}
