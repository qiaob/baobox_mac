import Foundation

/// 一次测速（docs/netcheck/SPEED.md §1.2）：延迟 → 下载 → 上传，依次跑，对着 speed.cloudflare.com。
///
/// - 走系统的网络设置（`URLSessionConfiguration.ephemeral`，同 `NetCheckEngine`）：开着代理 / VPN 时测的就是 App 实际走的那条路。
/// - 下载、上传各 4 条流，**每条流一个 URLSession**：同一个会话里的请求会被 HTTP/2 并进同一条连接，四条流就成了一条。
/// - 所有状态只在 `queue` 上读写，URLSession 的回调也在这个队列上（delegateQueue 的 underlyingQueue）；
///   进度与结果经 `onEvent` 回主线程。`cancel()` 之后不再回调，所有请求立即停。
final class NetSpeedTest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event {
        /// 进到某一段。
        case phase(NetSpeedPhase)
        /// 这一刻的数：延迟段是最近一次的延迟（秒），下载 / 上传段是速度（字节 / 秒）；`fraction` 是这一段的进度（0…1）。
        case progress(NetSpeedPhase, value: Double?, fraction: Double)
        case finished(NetSpeedResult)
    }

    private enum Kind {
        case meta
        /// 0 = 热连接（不计）
        case ping(Int)
        case stream(Int)
    }

    private final class TaskInfo {
        let kind: Kind
        let generation: Int
        let started: TimeInterval
        var status: Int?
        var serverTiming: String?
        var responded: TimeInterval?
        /// URLSessionTaskMetrics 给的「发出请求 → 收到响应头」
        var measured: TimeInterval?
        /// 只有 /meta 收正文
        var body = Data()

        init(kind: Kind, generation: Int, started: TimeInterval) {
            self.kind = kind
            self.generation = generation
            self.started = started
        }
    }

    private let queue = DispatchQueue(label: "com.baobox.netcheck.speedtest", qos: .userInitiated)
    private let delegateQueue = OperationQueue()
    private let onEvent: @MainActor (Event) -> Void
    /// `cancel()` 一调就置上（任何线程都读得到）：已经排进主线程、还没送出的回调据此丢掉。
    private let cancelLock = NSLock()
    private var cancelRequested = false

    // 以下只在 queue 上读写
    private var done = false
    private var cancelled = false
    private var generation = 0
    private var sessions: [URLSession] = []
    private var metaSession: URLSession?
    private var latencySession: URLSession?
    private var streamSessions: [URLSession] = []
    private var tasks: [ObjectIdentifier: TaskInfo] = [:]
    private var live: [ObjectIdentifier: URLSessionTask] = [:]

    private var server: NetSpeedServer?
    private var bytesUsed: Int64 = 0

    private var latencyStarted: TimeInterval = 0
    private var pingIndex = 0
    private var pings: [TimeInterval] = []
    private var latencyFailure: NetSpeedFailure?
    private var latency: Result<NetSpeedLatencyResult, NetSpeedFailure>?

    private var phase: NetSpeedPhase = .latency
    private var meter: NetSpeedMeter?
    private var ticker: DispatchSourceTimer?
    private var aliveStreams = 0
    private var phaseFailure: NetSpeedFailure?
    private var uploadBody: Data?
    private var download: Result<Double, NetSpeedFailure>?
    private var upload: Result<Double, NetSpeedFailure>?

    init(onEvent: @escaping @MainActor (Event) -> Void) {
        self.onEvent = onEvent
        super.init()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
    }

    func start() {
        queue.async { [self] in
            guard !done else { return }
            metaSession = makeSession()
            latencySession = makeSession()
            streamSessions = (0..<NetSpeedPlan.streams).map { _ in makeSession() }
            fetchMeta()
            startLatency()
        }
    }

    /// 停下：所有请求立即取消，不再回调（已经排进主线程的那一两个也丢掉）。
    func cancel() {
        cancelLock.lock()
        cancelRequested = true
        cancelLock.unlock()
        queue.async { [self] in
            guard !done else { return }
            cancelled = true
            finishSessions()
        }
    }

    // MARK: - 基础

    private static func now() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// 同 NetCheckEngine：走系统代理设置，不缓存、不带 cookie。
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        sessions.append(session)
        return session
    }

    private func request(_ urlString: String, method: String = "GET", timeout: TimeInterval = 10) -> URLRequest? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Baobox-NetCheck", forHTTPHeaderField: "User-Agent")
        request.setValue(NetSpeedPlan.referer, forHTTPHeaderField: "Referer")
        return request
    }

    private func track(_ task: URLSessionTask, _ kind: Kind) {
        let id = ObjectIdentifier(task)
        tasks[id] = TaskInfo(kind: kind, generation: generation, started: Self.now())
        live[id] = task
        task.resume()
    }

    private var isCancelRequested: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelRequested
    }

    private func emit(_ event: Event) {
        guard !cancelled else { return }
        let onEvent = onEvent
        DispatchQueue.main.async { [self] in
            guard !isCancelRequested else { return }
            MainActor.assumeIsolated { onEvent(event) }
        }
    }

    private func failure(_ error: Error?, status: Int?) -> NetSpeedFailure {
        if let status, !(200..<300).contains(status) {
            return NetSpeedFailure(L("netcheck.error.status \(NetSpeedPlan.host) \(status)"))
        }
        if let error {
            return NetSpeedFailure(L("netcheck.error.unreachable \(NetSpeedPlan.host) \(error.localizedDescription)"))
        }
        return NetSpeedFailure(L("netcheck.speed.error.noData"))
    }

    // MARK: - /meta（节点与出口，拿不到就不显示那一行）

    private func fetchMeta() {
        guard let session = metaSession, let request = request(NetSpeedPlan.metaURL) else { return }
        track(session.dataTask(with: request), .meta)
    }

    // MARK: - 延迟

    private func startLatency() {
        phase = .latency
        latencyStarted = Self.now()
        emit(.phase(.latency))
        pingIndex = 0
        sendPing()
    }

    private func sendPing() {
        guard let session = latencySession,
              let request = request(NetSpeedPlan.downloadURL(bytes: 0), timeout: 5) else {
            finishLatency()
            return
        }
        track(session.dataTask(with: request), .ping(pingIndex))
    }

    private func pingCompleted(_ info: TaskInfo, index: Int, error: Error?) {
        if error == nil, info.status == 200 {
            if index > 0 {
                let measured = info.measured ?? ((info.responded ?? Self.now()) - info.started)
                let sample = NetSpeedLatency.sample(measured: measured, serverTiming: info.serverTiming)
                pings.append(sample)
                emit(.progress(.latency, value: sample, fraction: Double(index) / Double(NetSpeedPlan.pingCount)))
            }
        } else if latencyFailure == nil {
            latencyFailure = failure(error, status: info.status)
        }
        if index < NetSpeedPlan.pingCount, Self.now() - latencyStarted < NetSpeedPlan.latencyDeadline {
            pingIndex = index + 1
            sendPing()
        } else {
            finishLatency()
        }
    }

    private func finishLatency() {
        if let median = NetSpeedLatency.median(pings) {
            latency = .success(NetSpeedLatencyResult(median: median, jitter: NetSpeedLatency.jitter(pings), count: pings.count))
        } else {
            latency = .failure(latencyFailure ?? NetSpeedFailure(L("netcheck.speed.error.noData")))
        }
        startBandwidth(.download)
    }

    // MARK: - 下载 / 上传

    private func startBandwidth(_ next: NetSpeedPhase) {
        generation += 1
        phase = next
        let cap = next == .download ? NetSpeedPlan.downloadCap : NetSpeedPlan.uploadCap
        meter = NetSpeedMeter(start: Self.now(), cap: cap)
        phaseFailure = nil
        if next == .upload, uploadBody == nil { uploadBody = Self.makeUploadBody() }
        emit(.phase(next))
        aliveStreams = streamSessions.count
        for index in streamSessions.indices { startStream(index) }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + NetSpeedPlan.tick, repeating: NetSpeedPlan.tick, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        ticker = timer
        timer.resume()
    }

    /// 1 MB 随机字节（不要全零：代理可能压缩）重复 25 次。
    private static func makeUploadBody() -> Data {
        var generator = SystemRandomNumberGenerator()
        var block = Data(count: NetSpeedPlan.uploadBlock)
        block.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for index in words.indices { words[index] = generator.next() }
        }
        var body = Data(capacity: NetSpeedPlan.uploadBlock * NetSpeedPlan.uploadBlocksPerRequest)
        for _ in 0..<NetSpeedPlan.uploadBlocksPerRequest { body.append(block) }
        return body
    }

    private func startStream(_ index: Int) {
        guard streamSessions.indices.contains(index) else { return }
        let session = streamSessions[index]
        switch phase {
        case .download:
            guard let request = request(NetSpeedPlan.downloadURL(bytes: NetSpeedPlan.downloadChunk)) else { return }
            track(session.dataTask(with: request), .stream(index))
        case .upload:
            guard var request = request(NetSpeedPlan.uploadURL, method: "POST"), let body = uploadBody else { return }
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            track(session.uploadTask(with: request, from: body), .stream(index))
        case .latency:
            return
        }
    }

    private func streamCompleted(_ info: TaskInfo, index: Int, error: Error?) {
        if error == nil, info.status == 200 {
            // 这一条传完了：续下一条
            startStream(index)
            return
        }
        if phaseFailure == nil { phaseFailure = failure(error, status: info.status) }
        aliveStreams -= 1
        if aliveStreams <= 0 { finishBandwidth() }
    }

    private func tick() {
        guard !done, phase != .latency, var current = meter else { return }
        let now = Self.now()
        current.tick(at: now)
        meter = current
        emit(.progress(phase, value: current.currentRate(at: now), fraction: current.progress(at: now)))
        if current.isFinished(at: now) { finishBandwidth() }
    }

    private func finishBandwidth() {
        guard phase != .latency, let current = meter else { return }
        ticker?.cancel()
        ticker = nil
        let outcome: Result<Double, NetSpeedFailure>
        if let rate = current.result(at: Self.now()) {
            outcome = .success(rate)
        } else {
            outcome = .failure(phaseFailure ?? NetSpeedFailure(L("netcheck.speed.error.noData")))
        }
        // 这一段的请求都停掉；它们迟到的回调按 generation 丢掉
        let ended = generation
        generation += 1
        for (id, info) in tasks where info.generation == ended {
            if case .stream = info.kind { live[id]?.cancel() }
        }
        meter = nil
        if phase == .download {
            download = outcome
            startBandwidth(.upload)
        } else {
            upload = outcome
            uploadBody = nil
            finish()
        }
    }

    private func finish() {
        let result = NetSpeedResult(at: Date(),
                                    latency: latency ?? .failure(NetSpeedFailure(L("netcheck.speed.error.noData"))),
                                    download: download ?? .failure(NetSpeedFailure(L("netcheck.speed.error.noData"))),
                                    upload: upload ?? .failure(NetSpeedFailure(L("netcheck.speed.error.noData"))),
                                    server: server,
                                    bytesUsed: bytesUsed)
        emit(.finished(result))
        finishSessions()
    }

    /// 收尾：停定时器、取消所有请求、放掉会话（URLSession 强引用 delegate，不放会连同自己一起漏掉）。
    private func finishSessions() {
        done = true
        ticker?.cancel()
        ticker = nil
        sessions.forEach { $0.invalidateAndCancel() }
        sessions = []
        streamSessions = []
        metaSession = nil
        latencySession = nil
        tasks = [:]
        live = [:]
        uploadBody = nil
    }

    // MARK: - URLSession 回调（都在 queue 上）

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !done, let info = tasks[ObjectIdentifier(dataTask)] else {
            completionHandler(.cancel)
            return
        }
        let http = response as? HTTPURLResponse
        info.status = http?.statusCode
        info.serverTiming = http?.value(forHTTPHeaderField: "Server-Timing")
        info.responded = Self.now()
        completionHandler(info.status == 200 ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !done, let info = tasks[ObjectIdentifier(dataTask)] else { return }
        switch info.kind {
        case .meta:
            // /meta 只有几百字节；防一个异常回包撑爆内存
            if info.body.count < 64 * 1024 { info.body.append(data) }
        case .stream:
            guard info.generation == generation, phase == .download else { return }
            meter?.add(Int64(data.count))
            bytesUsed += Int64(data.count)
        case .ping:
            break
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard !done, let info = tasks[ObjectIdentifier(task)], case .stream = info.kind,
              info.generation == generation, phase == .upload else { return }
        meter?.add(bytesSent)
        bytesUsed += max(0, bytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard !done, let info = tasks[ObjectIdentifier(task)], case .ping = info.kind else { return }
        if let transaction = metrics.transactionMetrics.last(where: { $0.requestStartDate != nil && $0.responseStartDate != nil }),
           let sent = transaction.requestStartDate, let received = transaction.responseStartDate {
            let measured = received.timeIntervalSince(sent)
            if measured > 0 { info.measured = measured }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = ObjectIdentifier(task)
        live[id] = nil
        guard !done, let info = tasks.removeValue(forKey: id) else { return }
        switch info.kind {
        case .meta:
            if error == nil, info.status == 200 {
                server = NetSpeedMeta.parse(String(decoding: info.body, as: UTF8.self))
            }
        case .ping(let index):
            guard phase == .latency else { return }
            pingCompleted(info, index: index, error: error)
        case .stream(let index):
            guard info.generation == generation, phase != .latency else { return }
            streamCompleted(info, index: index, error: error)
        }
    }
}
