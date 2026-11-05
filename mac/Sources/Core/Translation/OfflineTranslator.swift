import CryptoKit
import Foundation

/// 本地模型（llama.cpp GGUF）。见 docs/translation-engine/DESIGN.md §2.1 / §2.4。
struct OfflineModel {
    /// 进程日志 / PID 文件名用的标识。
    let id: String
    let displayName: String
    let fileName: String
    let byteSize: Int64
    let sha256: String
    /// 按顺序尝试：Hugging Face → ModelScope（国内网络更稳）。
    let mirrors: [URL]
    /// llama-server 的上下文长度（token）。
    let contextSize: Int

    /// 「1.08 GB」这类展示用的大小。
    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    /// 离线翻译：腾讯混元 Hy-MT2-1.8B（Q4_K_M）。
    static let translation = OfflineModel(
        id: "translation",
        displayName: "Hy-MT2-1.8B",
        fileName: "Hy-MT2-1.8B-Q4_K_M.gguf",
        byteSize: 1_133_080_448,
        sha256: "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699",
        mirrors: [
            "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/main/Hy-MT2-1.8B-Q4_K_M.gguf",
            "https://modelscope.cn/models/Tencent-Hunyuan/Hy-MT2-1.8B-GGUF/resolve/master/Hy-MT2-1.8B-Q4_K_M.gguf",
        ].compactMap(URL.init(string:)),
        contextSize: 4096
    )

    /// 识别纠错：通义千问 Qwen3-1.7B（官方 Q8_0）。翻译模型只会修「不成词」的错字，
    /// 「实时 → 时事」这种错成了另一个真词的修不了（实测 2026-11-05），要通用模型结合上下文判断。
    static let corrector = OfflineModel(
        id: "corrector",
        displayName: "Qwen3-1.7B",
        fileName: "Qwen3-1.7B-Q8_0.gguf",
        byteSize: 1_834_426_016,
        sha256: "061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a",
        mirrors: [
            "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf",
            "https://modelscope.cn/models/Qwen/Qwen3-1.7B-GGUF/resolve/master/Qwen3-1.7B-Q8_0.gguf",
        ].compactMap(URL.init(string:)),
        // 纠错的请求很短；4096 是给实时翻译停止后整理纪要的（每段记录约 2200 token + 输出），KV 缓存约 0.5 GB。
        contextSize: 4096
    )
}

/// 离线翻译的路径约定：`~/Library/Application Support/Baobox/Translation/`。
enum OfflineTranslationEnv {
    static var supportDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Baobox/Translation", isDirectory: true)
    }

    static var modelsDir: URL { supportDir.appendingPathComponent("models", isDirectory: true) }
    static func modelURL(_ model: OfflineModel) -> URL { modelsDir.appendingPathComponent(model.fileName) }
    /// 下载完、校验前的暂存文件。
    static func stagingURL(_ model: OfflineModel) -> URL { modelsDir.appendingPathComponent(model.fileName + ".part") }
    /// 断点续传数据（暂停 / 网络中断时落盘）。
    static func resumeDataURL(_ model: OfflineModel) -> URL {
        modelsDir.appendingPathComponent(model.fileName + ".resume")
    }
    /// 翻译模型沿用最初的文件名；其他模型带上自己的标识。
    static func serverLogURL(_ model: OfflineModel) -> URL {
        supportDir.appendingPathComponent(model.id == "translation" ? "llama-server.log" : "llama-server-\(model.id).log")
    }
    static func pidFileURL(_ model: OfflineModel) -> URL {
        supportDir.appendingPathComponent(model.id == "translation" ? "llama-server.pid" : "llama-server-\(model.id).pid")
    }

    /// App 包里的推理进程（构建时拷进 `Contents/Helpers/llama/`）；没打包则为 nil。
    static var helperURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama/llama-server")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func ensureDirectories() {
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    }
}

enum OfflineTranslationError: LocalizedError {
    case helperMissing
    case modelMissing
    case serverFailed(String)
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return L("translation.error.helperMissing")
        case .modelMissing:
            return L("translation.error.modelMissing")
        case .serverFailed(let detail):
            let base = L("translation.error.serverFailed")
            return detail.isEmpty ? base : base + "\n" + detail
        case .badResponse(let status):
            return L("translation.error.badResponse \(status)")
        }
    }
}

/// 本地模型：下载 / 校验、推理进程（llama-server）生命周期、请求。每个模型一个实例、一个进程：
/// `shared` 是离线翻译（Hy-MT2），`corrector` 是识别纠错（Qwen3-1.7B）。
///
/// 推理进程第一次用时才启动，空闲 10 分钟退出；实时翻译运行期间用 keep-alive 保持常驻。
@MainActor
final class OfflineTranslator: ObservableObject {
    static let shared = OfflineTranslator(model: .translation)
    static let corrector = OfflineTranslator(model: .corrector)

    /// 采样参数。
    struct Sampling {
        var temperature: Double
        var topP: Double
        var topK: Int
        var repeatPenalty: Double
        /// 关掉 Qwen3 这类混合推理模型的「思考」（模板参数；别的模型忽略）。
        var disablesThinking = false

        /// Hy-MT2 模型卡推荐值。
        static let translation = Sampling(temperature: 0.7, topP: 0.6, topK: 20, repeatPenalty: 1.05)
        /// 纠错要稳：低温度，不思考。
        static let correction = Sampling(temperature: 0.2, topP: 0.8, topK: 20, repeatPenalty: 1.0,
                                         disablesThinking: true)
        /// 实时翻译停止后整理纪要：偏稳，略防复读，不思考。
        static let summary = Sampling(temperature: 0.3, topP: 0.8, topK: 20, repeatPenalty: 1.05,
                                      disablesThinking: true)
    }

    let model: OfflineModel

    enum ModelState: Equatable {
        case notInstalled
        case downloading(progress: Double)
        case verifying
        case installed
        case failed(String)
    }

    @Published private(set) var modelState: ModelState = .notInstalled
    @Published private(set) var downloadedBytes: Int64 = 0
    /// 有上次没下完的进度可以接着下。
    @Published private(set) var hasPartialDownload = false
    @Published private(set) var isStartingServer = false

    /// 构建时有没有把推理进程打进 App 包。
    let isHelperBundled: Bool
    var isReady: Bool { isHelperBundled && modelState == .installed }

    // 下载
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var mirrorIndex = 0
    private var receivedAnyBytes = false
    private var userCancelled = false

    // 推理进程
    private var process: Process?
    private var serverBase: URL?
    private var apiKey = ""
    private var launchTask: Task<URL, Error>?
    private var idleTimer: Timer?
    private var lastUse = Date()
    private var keepAliveCount = 0
    private var inFlight = 0

    private static let idleTimeout: TimeInterval = 600

    /// 本机回环请求专用：不走系统代理（抓包模块开着系统代理时也不受影响）。
    private let localSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 180
        return URLSession(configuration: configuration)
    }()

    private init(model: OfflineModel) {
        self.model = model
        isHelperBundled = OfflineTranslationEnv.helperURL != nil
        refreshModelState()
    }

    private var modelURL: URL { OfflineTranslationEnv.modelURL(model) }
    private var stagingURL: URL { OfflineTranslationEnv.stagingURL(model) }
    private var resumeDataURL: URL { OfflineTranslationEnv.resumeDataURL(model) }
    private var serverLogURL: URL { OfflineTranslationEnv.serverLogURL(model) }
    private var pidFileURL: URL { OfflineTranslationEnv.pidFileURL(model) }

    // MARK: - 模型状态

    private func refreshModelState() {
        let fm = FileManager.default
        // 校验中途退出留下的暂存文件：直接丢掉，下次重新下载。
        try? fm.removeItem(at: stagingURL)
        let size = (try? fm.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?
            .int64Value ?? -1
        modelState = size == model.byteSize ? .installed : .notInstalled
        hasPartialDownload = fm.fileExists(atPath: resumeDataURL.path)
    }

    // MARK: - 下载

    func startDownload() {
        switch modelState {
        case .downloading, .verifying, .installed:
            return
        case .notInstalled, .failed:
            break
        }
        OfflineTranslationEnv.ensureDirectories()
        mirrorIndex = 0
        userCancelled = false
        modelState = .downloading(progress: 0)
        beginDownload(useResumeData: true)
    }

    /// 暂停：保留已下载的部分，下次「继续下载」接着下。
    func cancelDownload() {
        guard case .downloading = modelState, let task = downloadTask else { return }
        userCancelled = true
        task.cancel(byProducingResumeData: { [weak self] data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.saveResumeData(data)
                }
            }
        })
        modelState = .notInstalled
    }

    func deleteModel() {
        cancelDownload()
        stopServer()
        let fm = FileManager.default
        try? fm.removeItem(at: modelURL)
        try? fm.removeItem(at: stagingURL)
        try? fm.removeItem(at: resumeDataURL)
        refreshModelState()
    }

    private func beginDownload(useResumeData: Bool) {
        let delegate = ModelDownloadDelegate(stagingURL: stagingURL)
        delegate.onProgress = { [weak self] written, expected in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.updateProgress(written: written, expected: expected)
                }
            }
        }
        delegate.onComplete = { [weak self] outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.downloadDidComplete(outcome)
                }
            }
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: queue)
        self.session = session
        receivedAnyBytes = false

        let task: URLSessionDownloadTask
        if useResumeData, let data = try? Data(contentsOf: resumeDataURL) {
            try? FileManager.default.removeItem(at: resumeDataURL)
            task = session.downloadTask(withResumeData: data)
        } else if mirrorIndex < model.mirrors.count {
            task = session.downloadTask(with: model.mirrors[mirrorIndex])
        } else {
            modelState = .failed(L("translation.error.downloadFailed"))
            return
        }
        downloadTask = task
        task.resume()
    }

    private func updateProgress(written: Int64, expected: Int64) {
        guard case .downloading(let old) = modelState else { return }
        if written > 0 { receivedAnyBytes = true }
        let total = expected > 0 ? expected : model.byteSize
        let progress = min(1, Double(written) / Double(total))
        downloadedBytes = written
        // 每 0.2% 刷一次界面，免得 SwiftUI 被几万次回调淹没。
        if progress - old >= 0.002 || progress >= 1 {
            modelState = .downloading(progress: progress)
        }
    }

    private func saveResumeData(_ data: Data?) {
        guard let data else { return }
        OfflineTranslationEnv.ensureDirectories()
        try? data.write(to: resumeDataURL)
        hasPartialDownload = true
    }

    private func downloadDidComplete(_ outcome: ModelDownloadDelegate.Outcome) {
        session?.finishTasksAndInvalidate()
        session = nil
        downloadTask = nil

        switch outcome {
        case .staged(let status):
            guard status == 200 || status == 206 else {
                try? FileManager.default.removeItem(at: stagingURL)
                tryNextMirrorOrFail(L("translation.error.httpStatus \(status)"))
                return
            }
            modelState = .verifying
            // 后台线程只用这几个值，不碰本对象（主线程隔离）的属性。
            let staging = stagingURL
            let destination = modelURL
            let size = model.byteSize
            let sha256 = model.sha256
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let ok = Self.verify(staging, size: size, sha256: sha256)
                if ok {
                    let fm = FileManager.default
                    try? fm.removeItem(at: destination)
                    try? fm.moveItem(at: staging, to: destination)
                } else {
                    try? FileManager.default.removeItem(at: staging)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.verificationDidFinish(ok: ok)
                    }
                }
            }
        case .failed(let error, let resumeData):
            if userCancelled {
                userCancelled = false
                saveResumeData(resumeData)
                return
            }
            saveResumeData(resumeData)
            tryNextMirrorOrFail(error.localizedDescription)
        }
    }

    private func verificationDidFinish(ok: Bool) {
        hasPartialDownload = FileManager.default.fileExists(atPath: resumeDataURL.path)
        if ok {
            refreshModelState()
        } else {
            tryNextMirrorOrFail(L("translation.error.checksum"))
        }
    }

    /// 这个源一个字节都没下到（多半是被墙 / 不通）→ 换下一个源；否则报错，保留进度等用户重试。
    private func tryNextMirrorOrFail(_ message: String) {
        if !receivedAnyBytes, mirrorIndex + 1 < model.mirrors.count {
            mirrorIndex += 1
            // 续传数据绑在上一个源的 URL 上，换源就作废。
            try? FileManager.default.removeItem(at: resumeDataURL)
            hasPartialDownload = false
            modelState = .downloading(progress: 0)
            beginDownload(useResumeData: false)
            return
        }
        modelState = .failed(message)
    }

    /// 大小 + SHA-256 双重校验（后台线程调用，1 GB 约几秒）。
    nonisolated private static func verify(_ url: URL, size expected: Int64, sha256: String) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        guard size == expected, let handle = try? FileHandle(forReadingFrom: url) else { return false }
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

    // MARK: - 翻译

    /// 把 `text` 译成 `target`。`source` 已知时传入（决定用中文还是英文提示词模板）。
    /// `glossary`：专有名词表，每块原文里出现了的词条按官方「术语」模板给出参考译法。
    func translate(_ text: String, to target: TranslationLanguage,
                   from source: TranslationLanguage? = nil,
                   glossary: [GlossaryEntry] = []) async throws -> String {
        guard isHelperBundled else { throw OfflineTranslationError.helperMissing }
        guard modelState == .installed else { throw OfflineTranslationError.modelMissing }
        inFlight += 1
        defer {
            inFlight -= 1
            lastUse = Date()
        }
        let base = try await ensureServer()
        let joinWithoutSpace = target.isChinese || target.code == "ja"
        var output = ""
        for chunk in OfflineTextChunker.chunks(of: text) {
            try Task.checkCancellation()
            let references = TranslationGlossary.references(for: chunk.text, target: target, entries: glossary)
            let prompt = OfflinePrompt.make(text: chunk.text, target: target, source: source,
                                            references: references)
            let translated = try await complete(base: base, prompt: prompt,
                                                maxTokens: OfflinePrompt.maxTokens(for: chunk.text),
                                                sampling: .translation)
            output += translated
            switch chunk.joiner {
            case .newline: output += "\n"
            case .space: output += joinWithoutSpace ? "" : " "
            case .none: break
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 通用的一问一答（识别纠错等）：按需拉起推理进程。
    func respond(to prompt: String, maxTokens: Int, sampling: Sampling) async throws -> String {
        guard isHelperBundled else { throw OfflineTranslationError.helperMissing }
        guard modelState == .installed else { throw OfflineTranslationError.modelMissing }
        inFlight += 1
        defer {
            inFlight -= 1
            lastUse = Date()
        }
        let base = try await ensureServer()
        return try await complete(base: base, prompt: prompt, maxTokens: maxTokens, sampling: sampling)
    }

    /// 提前把模型加载起来（实时翻译开始时调用，第一句不用等加载）。
    func prewarm() {
        guard isReady, process == nil, launchTask == nil else { return }
        Task { _ = try? await self.ensureServer() }
    }

    func beginKeepAlive() {
        keepAliveCount += 1
        prewarm()
    }

    func endKeepAlive() {
        keepAliveCount = max(0, keepAliveCount - 1)
        lastUse = Date()
    }

    /// App 退出时调用。
    func shutdown() {
        stopServer()
    }

    // MARK: - 推理进程

    private func ensureServer() async throws -> URL {
        if let process, process.isRunning, let serverBase { return serverBase }
        if let launchTask { return try await launchTask.value }
        let task = Task { try await self.launchServer() }
        launchTask = task
        isStartingServer = true
        defer {
            launchTask = nil
            isStartingServer = false
        }
        return try await task.value
    }

    private func launchServer() async throws -> URL {
        guard let helper = OfflineTranslationEnv.helperURL else { throw OfflineTranslationError.helperMissing }
        await Self.terminateStaleServer(pidURL: pidFileURL)
        guard let port = Self.findFreePort(), let base = URL(string: "http://127.0.0.1:\(port)") else {
            throw OfflineTranslationError.serverFailed("")
        }
        let key = UUID().uuidString
        let process = Process()
        process.executableURL = helper
        process.currentDirectoryURL = OfflineTranslationEnv.supportDir
        process.arguments = [
            "-m", modelURL.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--api-key", key,
            "--jinja",
            "-ngl", "99",
            "-c", String(model.contextSize),
            "-np", "1",
        ]
        let logURL = serverLogURL
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let pid = finished.processIdentifier
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.serverDidExit(pid: pid)
                }
            }
        }
        do {
            try process.run()
        } catch {
            try? log?.close()
            throw OfflineTranslationError.serverFailed(error.localizedDescription)
        }
        try? log?.close()
        try? String(process.processIdentifier).write(to: pidFileURL,
                                                     atomically: true, encoding: .utf8)
        self.process = process
        apiKey = key

        // 首次加载要把 1～2 GB 模型读进内存并编译 Metal 着色器，给足时间。
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            guard process.isRunning else {
                self.process = nil
                throw OfflineTranslationError.serverFailed(Self.logTail(serverLogURL))
            }
            if await isHealthy(base: base, apiKey: key) {
                serverBase = base
                startIdleTimer()
                return base
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        stopServer()
        throw OfflineTranslationError.serverFailed(Self.logTail(serverLogURL))
    }

    private func isHealthy(base: URL, apiKey: String) async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("health"))
        request.timeoutInterval = 2
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let result = try? await localSession.data(for: request) else { return false }
        return (result.1 as? HTTPURLResponse)?.statusCode == 200
    }

    private func complete(base: URL, prompt: String, maxTokens: Int, sampling: Sampling) async throws -> String {
        var request = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "messages": [["role": "user", "content": prompt]],
            "temperature": sampling.temperature,
            "top_p": sampling.topP,
            "top_k": sampling.topK,
            "repeat_penalty": sampling.repeatPenalty,
            "max_tokens": maxTokens,
            "stream": false,
        ]
        if sampling.disablesThinking {
            body["chat_template_kwargs"] = ["enable_thinking": false]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await localSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OfflineTranslationError.badResponse(status) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OfflineTranslationError.badResponse(status)
        }
        return OfflinePrompt.clean(content)
    }

    private func stopServer() {
        idleTimer?.invalidate()
        idleTimer = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        serverBase = nil
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private func serverDidExit(pid: Int32) {
        guard let process, process.processIdentifier == pid else { return }
        self.process = nil
        serverBase = nil
        idleTimer?.invalidate()
        idleTimer = nil
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkIdle()
            }
        }
    }

    private func checkIdle() {
        guard process != nil, keepAliveCount == 0, inFlight == 0, launchTask == nil else { return }
        if Date().timeIntervalSince(lastUse) > Self.idleTimeout {
            stopServer()
        }
    }

    /// 上次 App 崩溃 / 被强杀留下的推理进程：按 PID 文件找到、核对进程名后再结束，绝不误杀别的进程。
    private static func terminateStaleServer(pidURL: URL) async {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        let command: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: processName(pid: pid))
            }
        }
        if command.hasSuffix("llama-server") {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidURL)
    }

    /// `ps -p <pid> -o comm=`（后台线程调用，同步等待）。
    nonisolated private static func processName(pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 在 127.0.0.1 上找一个空闲端口（绑定端口 0 让系统分配，再释放）。
    nonisolated private static func findFreePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        let port = Int(UInt16(bigEndian: address.sin_port))
        return port > 0 ? port : nil
    }

    /// 推理进程日志的最后几行（启动失败时带进错误提示，方便排查）。
    nonisolated private static func logTail(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        let tail = data.suffix(800)
        let text = String(decoding: tail, as: UTF8.self)
        return text.split(separator: "\n").suffix(3).joined(separator: "\n")
    }
}

// MARK: - 下载回调

/// URLSession 回调对象（跑在下载专用的串行队列上，结果抛回主线程）。
private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    enum Outcome {
        case staged(status: Int)
        case failed(Error, resumeData: Data?)
    }

    var onProgress: ((Int64, Int64) -> Void)?
    var onComplete: ((Outcome) -> Void)?

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
            onComplete?(.staged(status: stagedStatus))
            return
        }
        let failure = error ?? stageError ?? URLError(.unknown)
        let resumeData = (failure as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        onComplete?(.failed(failure, resumeData: resumeData))
    }
}

// MARK: - 提示词与切块

/// Hy-MT 官方提示词模板（涉及中文用中文模板，其余用英文模板）。
enum OfflinePrompt {
    /// 模型卡的官方模板：涉及中文用中文模板，否则用英文模板。有参考译法时用「术语」模板
    /// （参考译法列在前面；中文版参考与指令之间不空行，英文版空一行 —— 照模型卡原样）。
    static func make(text: String, target: TranslationLanguage, source: TranslationLanguage?,
                     references: [(source: String, target: String)] = []) -> String {
        let sourceIsChinese = source?.isChinese
            ?? text.unicodeScalars.contains { TranslationScript.han.contains($0) }
        if target.isChinese || sourceIsChinese {
            let instruction = "将以下文本翻译为\(target.chineseName)，注意只需要输出翻译后的结果，不要额外解释：\n\n\(text)"
            guard !references.isEmpty else { return instruction }
            let lines = references.map { "\($0.source) 翻译成 \($0.target)" }.joined(separator: "\n")
            return "参考下面的翻译：\n\(lines)\n\(instruction)"
        }
        guard !references.isEmpty else {
            return "Translate the following segment into \(target.englishName), without additional explanation.\n\n\(text)"
        }
        let lines = references.map { "\($0.source) translates to \($0.target)" }.joined(separator: "\n")
        return "Reference the following translations:\n\(lines)\n\n"
            + "Translate the following text into \(target.englishName). Note that you must ONLY output "
            + "the translated result without any additional explanation:\n\n\(text)"
    }

    /// 译文长度上限：中文 → 英文 token 数会涨，给原文字数的 3 倍，封顶 2048。
    static func maxTokens(for text: String) -> Int {
        min(2048, max(128, text.count * 3))
    }

    /// 去掉首尾空白；万一模型带了思考块也一并剥掉。
    static func clean(_ raw: String) -> String {
        var text = raw
        if let end = text.range(of: "</think>") {
            text = String(text[end.upperBound...])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 长文切块：按行聚合（每块 ≤ maxLength 字符），超长的单行再按句末标点切。
enum OfflineTextChunker {
    enum Joiner {
        case newline
        case space
        case none
    }

    struct Chunk {
        let text: String
        /// 这一块的译文后面接什么（按原文的切分位置还原）。
        let joiner: Joiner
    }

    static let maxLength = 1200

    static func chunks(of text: String) -> [Chunk] {
        guard text.count > maxLength else { return [Chunk(text: text, joiner: .none)] }
        var result: [Chunk] = []
        var buffer: [String] = []
        var bufferLength = 0

        func flush(joiner: Joiner) {
            guard !buffer.isEmpty else { return }
            result.append(Chunk(text: buffer.joined(separator: "\n"), joiner: joiner))
            buffer = []
            bufferLength = 0
        }

        for line in text.components(separatedBy: "\n") {
            if line.count > maxLength {
                flush(joiner: .newline)
                let pieces = sentencePieces(of: line)
                for (index, piece) in pieces.enumerated() {
                    result.append(Chunk(text: piece, joiner: index == pieces.count - 1 ? .newline : .space))
                }
                continue
            }
            if bufferLength + line.count + 1 > maxLength {
                flush(joiner: .newline)
            }
            buffer.append(line)
            bufferLength += line.count + 1
        }
        flush(joiner: .none)
        if let last = result.last, last.joiner != .none {
            result[result.count - 1] = Chunk(text: last.text, joiner: .none)
        }
        return result.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 单行太长：在句末标点后断开，每段 ≤ maxLength；没有标点就硬切。
    private static func sentencePieces(of line: String) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", ".", "!", "?", "；", ";"]
        var pieces: [String] = []
        var current = ""
        for character in line {
            current.append(character)
            if current.count >= maxLength || (terminators.contains(character) && current.count >= maxLength / 2) {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
