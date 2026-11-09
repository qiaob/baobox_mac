import AppKit
import CryptoKit
import os

/// 离线英汉词典（docs/selection-translate/ASSISTANT.md §2.6）：ECDICT（MIT）固定提交的 `ecdict.csv`，
/// 在 App 里下载 → 校验 → 后台转成自己的排序索引 → 内存映射 + 二分查词。
@MainActor
final class EnglishDictionary: ObservableObject {
    static let shared = EnglishDictionary()

    enum State: Equatable {
        case notInstalled
        case downloading(progress: Double)
        /// 校验 + 整理索引（一次性，十几秒）。
        case preparing
        case installed
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled
    /// 索引已载入内存，可以查词。
    @Published private(set) var isLoaded = false

    /// ECDICT 固定提交（换版本要同时改大小和 SHA-256）。
    nonisolated static let sourceURL = URL(string:
        "https://raw.githubusercontent.com/skywind3000/ECDICT/39cfb9672c0906b63569e0453c2e6abfb9ab182a/ecdict.csv")
    nonisolated static let byteSize: Int64 = 66_009_548
    nonisolated static let sha256 = "d1ecbdf9ee2b920afb6f430ca6b6bb9f559588cf0dff86e04bd255f9390843cc"

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Self.byteSize, countStyle: .file) }

    private static let log = Logger(subsystem: "com.baobox.app", category: "selectiontranslate")

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Baobox/SelectionTranslate", isDirectory: true)
    }

    nonisolated static var indexURL: URL { directory.appendingPathComponent("ecdict.tsv") }
    nonisolated static var stagingURL: URL { directory.appendingPathComponent("ecdict.csv.part") }

    private var session: URLSession?
    private var index: EnglishDictionaryIndex?
    private var loading = false

    private init() {
        if FileManager.default.fileExists(atPath: Self.indexURL.path) {
            state = .installed
        }
    }

    /// 已安装就在后台载入索引（模块启用时、第一次查词前调用）。
    func loadIfNeeded() {
        guard state == .installed, index == nil, !loading else { return }
        loading = true
        let url = Self.indexURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loaded = EnglishDictionaryIndex(url: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.loading = false
                    if let loaded {
                        self.index = loaded
                        self.isLoaded = true
                    } else {
                        // 文件坏了：当没装，让用户重下。
                        try? FileManager.default.removeItem(at: url)
                        self.state = .notInstalled
                    }
                }
            }
        }
    }

    // MARK: - 下载

    func startDownload() {
        switch state {
        case .downloading, .preparing: return
        default: break
        }
        guard let url = Self.sourceURL else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        state = .downloading(progress: 0)
        let delegate = DictionaryDownloadDelegate(stagingURL: Self.stagingURL)
        delegate.onProgress = { [weak self] written, expected in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.updateProgress(written: written, expected: expected)
                }
            }
        }
        delegate.onComplete = { [weak self] status, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.downloadDidComplete(status: status, error: error)
                }
            }
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: queue)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func cancelDownload() {
        guard case .downloading = state else { return }
        session?.invalidateAndCancel()
        session = nil
        state = .notInstalled
    }

    func delete() {
        cancelDownload()
        index = nil
        isLoaded = false
        try? FileManager.default.removeItem(at: Self.indexURL)
        try? FileManager.default.removeItem(at: Self.stagingURL)
        state = .notInstalled
    }

    private func updateProgress(written: Int64, expected: Int64) {
        guard case .downloading(let old) = state else { return }
        let total = expected > 0 ? expected : Self.byteSize
        let progress = min(1, Double(written) / Double(total))
        if progress - old >= 0.005 || progress >= 1 {
            state = .downloading(progress: progress)
        }
    }

    private func downloadDidComplete(status: Int, error: Error?) {
        session?.finishTasksAndInvalidate()
        session = nil
        guard case .downloading = state else { return } // 用户取消了
        if let error {
            state = .failed(error.localizedDescription)
            return
        }
        guard status == 200 else {
            try? FileManager.default.removeItem(at: Self.stagingURL)
            state = .failed(L("translation.error.httpStatus \(status)"))
            return
        }
        state = .preparing
        let staging = Self.stagingURL
        let output = Self.indexURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var message: String?
            if !Self.verify(staging) {
                message = L("translation.error.checksum")
            } else {
                do {
                    try EnglishDictionaryBuilder.build(csv: staging, output: output)
                } catch {
                    message = error.localizedDescription
                }
            }
            try? FileManager.default.removeItem(at: staging)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let message {
                        Self.log.error("dictionary prepare failed: \(message, privacy: .public)")
                        self.state = .failed(message)
                    } else {
                        self.state = .installed
                        self.loadIfNeeded()
                    }
                }
            }
        }
    }

    nonisolated private static func verify(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        guard size == byteSize, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        var finished = false
        while !finished {
            autoreleasepool {
                let chunk = handle.readData(ofLength: 8 << 20)
                if chunk.isEmpty {
                    finished = true
                } else {
                    hasher.update(data: chunk)
                }
            }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == sha256
    }

    // MARK: - 查词

    /// 查一个英文词 / 短语。没载入、查不到返回 nil。变形词（became）连同原形（become）一起给。
    func lookup(_ raw: String) -> EnglishLookup? {
        guard let index else {
            loadIfNeeded()
            return nil
        }
        let word = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !word.isEmpty, word.count <= 60 else { return nil }
        let candidates = [word] + EnglishLemma.candidates(for: word.lowercased())
        for candidate in candidates {
            guard let entry = index.entry(for: candidate) else { continue }
            var lemmaEntry: EnglishDictionaryEntry?
            if let lemma = entry.lemma, lemma.lowercased() != entry.word.lowercased() {
                lemmaEntry = index.entry(for: lemma)
            }
            return EnglishLookup(query: word, entry: entry, lemmaEntry: lemmaEntry)
        }
        return nil
    }
}

/// 一次查词的结果。
struct EnglishLookup {
    let query: String
    let entry: EnglishDictionaryEntry
    /// 查到的是变形词时，原形的条目。
    let lemmaEntry: EnglishDictionaryEntry?

    /// 「became 是 become 的过去式」。
    var lemmaNote: String? {
        guard let lemma = entry.lemma, let kinds = entry.exchange["1"] else { return nil }
        let names = kinds.compactMap { EnglishDictionaryEntry.formName($0) }
        guard !names.isEmpty else { return nil }
        return L("selectiontranslate.dict.lemmaNote \(entry.word) \(lemma) \(names.joined(separator: " / "))")
    }
}

/// 词典里的一条。
struct EnglishDictionaryEntry {
    let word: String
    let phonetic: String
    /// 释义，一行一条（如「adj. 无所不在的」）。
    let definitions: [String]
    /// 变形：键是 ECDICT 的类型码（p / d / i / 3 / r / t / s / 0 / 1）。
    let exchange: [String: String]

    var lemma: String? { exchange["0"] }

    /// 卡片上显示的释义：最多 5 条；有正经释义时去掉「[网络]」那条。
    var displayDefinitions: [String] {
        let normal = definitions.filter { !$0.hasPrefix("[网络]") }
        return Array((normal.isEmpty ? definitions : normal).prefix(5))
    }

    /// 变形列表（「过去式 became」…），原形自己的条目才有意义。
    var forms: [(name: String, value: String)] {
        let order = ["p", "d", "i", "3", "r", "t", "s"]
        return order.compactMap { code in
            guard let value = exchange[code], !value.isEmpty, let name = Self.formName(Character(code)) else {
                return nil
            }
            return (name, value)
        }
    }

    static func formName(_ code: Character) -> String? {
        switch code {
        case "p": return L("selectiontranslate.dict.form.past")
        case "d": return L("selectiontranslate.dict.form.pastParticiple")
        case "i": return L("selectiontranslate.dict.form.presentParticiple")
        case "3": return L("selectiontranslate.dict.form.thirdPerson")
        case "r": return L("selectiontranslate.dict.form.comparative")
        case "t": return L("selectiontranslate.dict.form.superlative")
        case "s": return L("selectiontranslate.dict.form.plural")
        default: return nil
        }
    }

    /// 索引里的一行：`小写键\t原词\t音标\t释义\t变形`。
    init?(line: String) {
        let fields = line.components(separatedBy: "\t")
        guard fields.count >= 5 else { return nil }
        word = fields[1]
        phonetic = fields[2]
        definitions = fields[3].components(separatedBy: "\\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var exchange: [String: String] = [:]
        for item in fields[4].split(separator: "/") {
            let parts = item.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            exchange[String(parts[0])] = String(parts[1])
        }
        self.exchange = exchange
    }
}

/// 查不到时猜原形：去掉常见词尾（ECDICT 的变形表覆盖了大多数，这里只兜底）。
enum EnglishLemma {
    static func candidates(for word: String) -> [String] {
        guard word.count > 3, !word.contains(" ") else { return [] }
        var result: [String] = []
        func add(_ value: String) {
            if value.count >= 2, value != word, !result.contains(value) { result.append(value) }
        }
        if word.hasSuffix("ies") { add(String(word.dropLast(3)) + "y") }
        if word.hasSuffix("es") { add(String(word.dropLast(2))) }
        if word.hasSuffix("s") { add(String(word.dropLast())) }
        if word.hasSuffix("ied") { add(String(word.dropLast(3)) + "y") }
        if word.hasSuffix("ed") {
            add(String(word.dropLast(2)))
            add(String(word.dropLast()))
        }
        if word.hasSuffix("ing") {
            add(String(word.dropLast(3)))
            add(String(word.dropLast(3)) + "e")
        }
        if word.hasSuffix("ly") { add(String(word.dropLast(2))) }
        return result
    }
}

// MARK: - 索引（只读，建好后不再改，可跨线程）

final class EnglishDictionaryIndex: @unchecked Sendable {
    private let data: Data
    /// 每行的起始偏移。
    private let offsets: [Int]

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), !data.isEmpty else { return nil }
        var offsets: [Int] = [0]
        offsets.reserveCapacity(800_000)
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let count = buffer.count
            for i in 0..<count where buffer[i] == 0x0A && i + 1 < count {
                offsets.append(i + 1)
            }
        }
        self.data = data
        self.offsets = offsets
    }

    /// 同一个小写键可能有好几条（Polish / polish）：优先大小写完全一致的。
    func entry(for word: String) -> EnglishDictionaryEntry? {
        let key = Array(word.lowercased().utf8)
        let lines = self.lines(forKey: key)
        guard !lines.isEmpty else { return nil }
        let entries = lines.compactMap { EnglishDictionaryEntry(line: $0) }
        return entries.first { $0.word == word } ?? entries.first { $0.word == word.lowercased() } ?? entries.first
    }

    private func lines(forKey key: [UInt8]) -> [String] {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [String] in
            func keyBytes(at lineIndex: Int) -> ArraySlice<UInt8> {
                let start = offsets[lineIndex]
                var end = start
                while end < buffer.count, buffer[end] != 0x09, buffer[end] != 0x0A { end += 1 }
                return ArraySlice(buffer[start..<end])
            }
            // 下界二分：第一个键 >= key 的行。
            var low = 0
            var high = offsets.count
            while low < high {
                let mid = (low + high) / 2
                if keyBytes(at: mid).lexicographicallyPrecedes(key) {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            var result: [String] = []
            var index = low
            while index < offsets.count, Array(keyBytes(at: index)) == key, result.count < 8 {
                let start = offsets[index]
                var end = start
                while end < buffer.count, buffer[end] != 0x0A { end += 1 }
                result.append(String(decoding: UnsafeRawBufferPointer(rebasing: buffer[start..<end]), as: UTF8.self))
                index += 1
            }
            return result
        }
    }
}

// MARK: - 从 ECDICT CSV 建索引（后台线程）

enum EnglishDictionaryBuilder {
    enum BuildError: LocalizedError {
        case unreadable
        case empty

        var errorDescription: String? { L("selectiontranslate.dict.buildFailed") }
    }

    /// CSV 列：word, phonetic, definition, translation, pos, collins, oxford, tag, bnc, frq, exchange, detail, audio。
    /// 只留有中文释义、≤ 3 个词的条目；按小写键的 UTF-8 字节序排序后写成一行一条的 TSV。
    static func build(csv: URL, output: URL) throws {
        guard let data = try? Data(contentsOf: csv, options: .alwaysMapped) else { throw BuildError.unreadable }
        var rows: [(key: [UInt8], line: [UInt8])] = []
        rows.reserveCapacity(760_000)
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var lineStart = 0
            var isHeader = true
            let count = buffer.count
            var position = 0
            while position <= count {
                if position == count || buffer[position] == 0x0A {
                    if position > lineStart {
                        if isHeader {
                            isHeader = false
                        } else if let row = parse(UnsafeRawBufferPointer(rebasing: buffer[lineStart..<position])) {
                            rows.append(row)
                        }
                    }
                    lineStart = position + 1
                }
                position += 1
            }
        }
        guard !rows.isEmpty else { throw BuildError.empty }
        rows.sort { lhs, rhs in
            if lhs.key != rhs.key { return lhs.key.lexicographicallyPrecedes(rhs.key) }
            return lhs.line.lexicographicallyPrecedes(rhs.line)
        }
        var out = Data()
        out.reserveCapacity(rows.reduce(0) { $0 + $1.line.count + 1 })
        for row in rows {
            out.append(contentsOf: row.line)
            out.append(0x0A)
        }
        let temporary = output.appendingPathExtension("tmp")
        try out.write(to: temporary, options: .atomic)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: temporary, to: output)
    }

    /// 解析一行 CSV（ECDICT 的换行已转义成字面 `\n`，一条记录就是一行）。不合格的行返回 nil。
    private static func parse(_ line: UnsafeRawBufferPointer) -> (key: [UInt8], line: [UInt8])? {
        var fields: [[UInt8]] = []
        fields.reserveCapacity(13)
        var current: [UInt8] = []
        var quoted = false
        var index = 0
        let count = line.count
        var atFieldStart = true
        while index < count {
            let byte = line[index]
            if quoted {
                if byte == 0x22 {
                    if index + 1 < count, line[index + 1] == 0x22 {
                        current.append(0x22)
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    current.append(byte)
                }
            } else if byte == 0x22, atFieldStart {
                quoted = true
                atFieldStart = false
            } else if byte == 0x2C {
                fields.append(current)
                current = []
                atFieldStart = true
            } else if byte != 0x0D {
                current.append(byte)
                atFieldStart = false
            }
            index += 1
        }
        fields.append(current)
        guard fields.count >= 11 else { return nil }
        let word = clean(fields[0])
        let translation = clean(fields[3])
        guard !word.isEmpty, !translation.isEmpty else { return nil }
        guard word.split(separator: 0x20).count <= 3 else { return nil }
        let wordText = String(decoding: word, as: UTF8.self)
        let key = Array(wordText.lowercased().utf8)
        let phonetic = Array(normalizedPhonetic(String(decoding: clean(fields[1]), as: UTF8.self)).utf8)
        var out: [UInt8] = key
        for field in [word, phonetic, translation, clean(fields[10])] {
            out.append(0x09)
            out.append(contentsOf: field)
        }
        return (key, out)
    }

    /// 去掉制表符 / 换行（索引的分隔符）和首尾空白。
    private static func clean(_ bytes: [UInt8]) -> [UInt8] {
        var result = bytes.map { $0 == 0x09 || $0 == 0x0A || $0 == 0x0D ? 0x20 : $0 }
        while let first = result.first, first == 0x20 { result.removeFirst() }
        while let last = result.last, last == 0x20 { result.removeLast() }
        return result
    }

    /// ECDICT 的音标是老写法：`'` 重音、`,` 次重音、`:` 长音、西里尔字母 ә。换成常见的 IPA 写法。
    static func normalizedPhonetic(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        return raw
            .replacingOccurrences(of: "'", with: "ˈ")
            .replacingOccurrences(of: ",", with: "ˌ")
            .replacingOccurrences(of: ":", with: "ː")
            .replacingOccurrences(of: "\u{04D9}", with: "ə")
    }
}

/// 下载回调（跑在专用串行队列上，结果抛回主线程）。
private final class DictionaryDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Int64, Int64) -> Void)?
    var onComplete: ((Int, Error?) -> Void)?

    private let stagingURL: URL
    private var stagedStatus: Int?
    private var stageError: Error?

    init(stagingURL: URL) {
        self.stagingURL = stagingURL
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // 系统给的临时文件在本回调返回后就会被删，必须现在挪走。
        let fm = FileManager.default
        try? fm.removeItem(at: stagingURL)
        do {
            try fm.moveItem(at: location, to: stagingURL)
            stagedStatus = status
        } catch {
            stageError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error == nil, let stagedStatus {
            onComplete?(stagedStatus, nil)
            return
        }
        onComplete?(0, error ?? stageError ?? URLError(.unknown))
    }
}
