import Foundation

// 测速与菜单栏实时网速的纯逻辑：速率格式化（菜单栏用的、详情用的）、测速的参数与窗口计算、延迟中位数与抖动、
// 网卡筛选、计数差值与容错、/meta 解析。只依赖 Foundation，进 BaoboxTests。见 docs/netcheck/SPEED.md。

// MARK: - 菜单栏显示方式

/// 菜单栏网速显示什么（设置键 `netcheck.liveSpeed.mode` 的取值）。
enum NetSpeedDisplayMode: String, CaseIterable {
    /// `↓1.2M/s`
    case down
    /// `↓1.2M ↑356K`（省掉 `/s` 免得太宽）
    case both
}

// MARK: - 速率与流量的写法

/// 按字节算，1 M = 1024 K = 1024×1024 字节（SPEED.md §2.2）。数字一律用 `.`，不跟地区设置走（菜单栏要定宽）。
enum NetSpeedFormat {
    static let base: Double = 1024

    /// 紧凑写法拆成数和单位：小于 1 K 是 `0` `K`；1–999 K 整数；1–9.9 M 一位小数；10 M 以上整数；1 G 以上同 M 的规则。
    /// 进位按显示出来的数算：999.5 K 显示出来是 1000 K，所以写成 `1.0` `M`；9.95 M → `10` `M`；1023 M → `1.0` `G`。
    static func compactParts(_ bytesPerSecond: Double) -> (number: String, unit: String) {
        let value = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        let kilo = value / base
        if kilo < 1 { return ("0", "K") }
        if kilo.rounded() < 1000 { return (String(Int(kilo.rounded())), "K") }
        var scaled = kilo / base
        let units = ["M", "G"]
        for (index, unit) in units.enumerated() {
            let tenths = (scaled * 10).rounded() / 10
            if tenths < 10 { return (String(format: "%.1f", tenths), unit) }
            let whole = scaled.rounded()
            if whole < 1000 || index == units.count - 1 { return (String(format: "%.0f", whole), unit) }
            scaled /= base
        }
        return ("0", "K")
    }

    /// 菜单栏上的一个数：`1.2M`。
    static func compact(_ bytesPerSecond: Double) -> String {
        let parts = compactParts(bytesPerSecond)
        return parts.number + parts.unit
    }

    /// 菜单栏上的整段文字：`↓1.2M/s`，或者 `↓1.2M ↑356K`。
    static func menuBarText(down: Double, up: Double, mode: NetSpeedDisplayMode) -> String {
        switch mode {
        case .down: return "↓" + compact(down) + "/s"
        case .both: return "↓" + compact(down) + " ↑" + compact(up)
        }
    }

    /// 一个数在每种单位下最宽的样子（数字是等宽的，所以 8 代表任何数字）：`888K`、`8.8M`、`888M`、`8.8G`、`888G`。
    static let widestNumbers = ["888K", "8.8M", "888M", "8.8G", "888G"]

    /// 这种显示方式下所有可能的最宽形状（定宽的候选）。
    static func widthCandidates(mode: NetSpeedDisplayMode) -> [String] {
        switch mode {
        case .down:
            return widestNumbers.map { "↓" + $0 + "/s" }
        case .both:
            return widestNumbers.flatMap { down in widestNumbers.map { up in "↓" + down + " ↑" + up } }
        }
    }

    /// 定宽用的字符串：候选里量出来最宽的那个（`width` 由界面层用真实字体量）。
    static func widestText(mode: NetSpeedDisplayMode, width: (String) -> Double) -> String {
        let candidates = widthCandidates(mode: mode)
        var best = candidates[0]
        var bestWidth = width(best)
        for candidate in candidates.dropFirst() {
            let w = width(candidate)
            if w > bestWidth {
                best = candidate
                bestWidth = w
            }
        }
        return best
    }

    /// 详情里的速率：`1.2 MB/s`、`356 KB/s`、`0 KB/s`。
    static func rate(_ bytesPerSecond: Double) -> String {
        let parts = compactParts(bytesPerSecond)
        return "\(parts.number) \(parts.unit)B/s"
    }

    /// 累计流量：小于 1 K 写字节数；K 整数；M / G / T 小于 100 时一位小数（`12.3 GB`），否则整数（`356 MB`）。
    static func amount(_ bytes: Double) -> String {
        let value = bytes.isFinite ? max(0, bytes) : 0
        if value < base { return "\(Int(value)) B" }
        var scaled = value / base
        if scaled.rounded() < 1000 { return "\(Int(scaled.rounded())) KB" }
        let units = ["MB", "GB", "TB"]
        for (index, unit) in units.enumerated() {
            scaled /= base
            let tenths = (scaled * 10).rounded() / 10
            if tenths < 100 { return String(format: "%.1f %@", tenths, unit) }
            let whole = scaled.rounded()
            if whole < 1000 || index == units.count - 1 { return String(format: "%.0f %@", whole, unit) }
        }
        return "\(Int(value)) B"
    }

    /// 测速结果的 Mbps（十进制兆比特，测速网站的通行写法）：10 以上整数，1–10 一位小数，1 以下两位小数。
    static func mbps(_ bytesPerSecond: Double) -> String {
        let value = (bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0) * 8 / 1_000_000
        if value >= 9.95 { return String(format: "%.0f", value) }
        if value >= 0.995 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    /// 毫秒数（不带单位）：10 ms 以上整数，以下一位小数。
    static func milliseconds(_ seconds: Double) -> String {
        let value = (seconds.isFinite ? max(0, seconds) : 0) * 1000
        if value >= 9.95 { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }
}

// MARK: - 测速的参数（SPEED.md §1.2）

enum NetSpeedPlan {
    static let host = "speed.cloudflare.com"
    static let metaURL = "https://speed.cloudflare.com/meta"
    /// `/meta` 不带 Referer 返回 403（2026-11-25 实测），所有请求都带上它。
    static let referer = "https://speed.cloudflare.com/"
    static let uploadURL = "https://speed.cloudflare.com/__up"
    static func downloadURL(bytes: Int) -> String { "https://speed.cloudflare.com/__down?bytes=\(bytes)" }

    /// 延迟：先 1 个热连接（不计），再连续 10 个 `bytes=0`。整段最多 10 秒，单个请求最多 5 秒。
    static let pingCount = 10
    static let latencyDeadline: TimeInterval = 10
    static let pingTimeout: TimeInterval = 5

    /// 下一个延迟请求的超时：5 秒和这一段剩下的时间取小的；剩下不到 0.1 秒就不再发（nil）。
    static func pingTimeout(elapsed: TimeInterval) -> TimeInterval? {
        let remaining = latencyDeadline - elapsed
        guard remaining >= 0.1 else { return nil }
        return min(pingTimeout, remaining)
    }
    /// 下载、上传各 4 条并行的流。
    static let streams = 4
    /// 每段 6 秒，前 1.5 秒算起速不计、后 4.5 秒计（2026-11-25 从 8 秒减下来：一次 300–600 MB 偏多）。
    static let phaseDuration: TimeInterval = 6
    static let warmup: TimeInterval = 1.5
    /// 每段的流量上限，先到先停。
    static let downloadCap: Int64 = 500 << 20
    static let uploadCap: Int64 = 300 << 20
    /// 单条下载请求的字节数：服务端上限是 99,999,999（2026-11-25 实测，100,000,000 起返回 403），留一半余量；不够就续下一条。
    static let downloadChunk = 50_000_000
    /// 上传的请求体：一块 1 MB 随机字节（不要全零：代理可能压缩）重复 25 次；发完续下一条。
    static let uploadBlock = 1 << 20
    static let uploadBlocksPerRequest = 25
    /// 界面刷新（也是窗口计算的采样）间隔。
    static let tick: TimeInterval = 0.25
    /// 「这一刻的速度」看最近多长时间。
    static let liveWindow: TimeInterval = 1
    /// 起速段之后至少要有这么长的数据，才用「后 4.5 秒」的算法；不到（流量上限先到）就用全程平均。
    static let minimumWindow: TimeInterval = 0.5
}

// MARK: - 测速窗口计算

/// 一段（下载或上传）的计量：累计字节、起速段结束那一刻的快照、最近一秒的采样。时间都是同一个单调时钟的秒数。
struct NetSpeedMeter {
    let start: TimeInterval
    let cap: Int64
    let duration: TimeInterval
    let warmup: TimeInterval
    private(set) var total: Int64 = 0
    /// 起速段结束后的第一次采样：之后的字节才算数。
    private(set) var baseline: (time: TimeInterval, bytes: Int64)?
    private var samples: [(time: TimeInterval, bytes: Int64)] = []

    init(start: TimeInterval, cap: Int64, duration: TimeInterval = NetSpeedPlan.phaseDuration,
         warmup: TimeInterval = NetSpeedPlan.warmup) {
        self.start = start
        self.cap = cap
        self.duration = duration
        self.warmup = warmup
    }

    mutating func add(_ bytes: Int64) {
        guard bytes > 0 else { return }
        total += bytes
    }

    /// 定时器每 0.25 秒调一次。
    mutating func tick(at now: TimeInterval) {
        if baseline == nil, now - start >= warmup {
            baseline = (now, total)
        }
        samples.append((now, total))
        // 留最近一秒，外加一个更早的点当起点
        while samples.count > 2, now - samples[1].time >= NetSpeedPlan.liveWindow {
            samples.removeFirst()
        }
    }

    /// 时间到了，或者流量上限到了。
    func isFinished(at now: TimeInterval) -> Bool {
        now - start >= duration || total >= cap
    }

    /// 这一段的进度（0…1）：时间和流量哪个走得快按哪个。
    func progress(at now: TimeInterval) -> Double {
        let byTime = duration > 0 ? (now - start) / duration : 1
        let byBytes = cap > 0 ? Double(total) / Double(cap) : 1
        return min(1, max(0, max(byTime, byBytes)))
    }

    /// 这一刻的速度（字节 / 秒）：最近一秒的采样；采样不够两个时用从开始到现在的平均。还没有数据时 nil。
    func currentRate(at now: TimeInterval) -> Double? {
        if let first = samples.first, let last = samples.last, last.time - first.time > 0 {
            return Double(last.bytes - first.bytes) / (last.time - first.time)
        }
        let elapsed = now - start
        guard elapsed > 0, total > 0 else { return nil }
        return Double(total) / elapsed
    }

    /// 这一段的结果（字节 / 秒），nil = 没测出来：**所有流都失败了才结束的**（`streamsAlive == 0`），不管什么时候，都不给数
    /// （独立验证用假服务实测过：每条流传 1 MB 就断，0.09 秒结束却显示 393.9 Mbps）。时间到或流量上限到、还有流活着时才给数。
    func outcome(at now: TimeInterval, streamsAlive: Int) -> Double? {
        guard streamsAlive > 0 else { return nil }
        return result(at: now)
    }

    /// 结果（字节 / 秒）：起速段之后收到的字节 ÷ 之后的时间。起速段还没过完、或之后不到 0.5 秒就停了（流量上限先到），
    /// 用全程平均。一个字节都没有时 nil。
    func result(at now: TimeInterval) -> Double? {
        guard total > 0 else { return nil }
        if let baseline, now - baseline.time >= NetSpeedPlan.minimumWindow, total > baseline.bytes {
            return Double(total - baseline.bytes) / (now - baseline.time)
        }
        let elapsed = now - start
        guard elapsed > 0 else { return nil }
        return Double(total) / elapsed
    }
}

// MARK: - 延迟

enum NetSpeedLatency {
    /// 中位数（偶数个取中间两个的平均）。空 = nil。
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// 抖动：相邻两次之差的绝对值的平均。不到两个 = nil（没有相邻的两次）。
    static func jitter(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        var sum = 0.0
        for index in 1..<values.count {
            sum += abs(values[index] - values[index - 1])
        }
        return sum / Double(values.count - 1)
    }

    /// `Server-Timing` 头里服务端自己花的时间（秒）：各项 `dur=` 毫秒数之和。
    /// speed.cloudflare.com 回的是 `cfSpeedEdge;dur=4, cfSpeedWorker;dur=30, cfL4;desc="?proto=TCP&rtt=…"`
    /// （2026-11-25 实测：服务端要花 15–40 ms，比往返本身还长，不扣掉延迟会偏高好几倍）。没有 = 0。
    static func serverTime(_ header: String?) -> Double {
        guard let header, !header.isEmpty else { return 0 }
        var milliseconds = 0.0
        for entry in header.split(separator: ",") {
            for parameter in entry.split(separator: ";") {
                let text = parameter.trimmingCharacters(in: .whitespaces)
                guard text.lowercased().hasPrefix("dur=") else { continue }
                let value = text.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                if let number = Double(value), number.isFinite, number > 0 { milliseconds += number }
            }
        }
        return milliseconds / 1000
    }

    /// 一次的延迟：「发出请求 → 收到响应头」减去服务端自己花的时间；扣完不是正数（服务端的数不对）就不扣。
    static func sample(measured: TimeInterval, serverTiming: String?) -> TimeInterval {
        let server = serverTime(serverTiming)
        let net = measured - server
        return net > 0 ? net : measured
    }
}

// MARK: - 测速结果

enum NetSpeedPhase: Int, CaseIterable, Equatable {
    case latency, download, upload
}

/// 一项没测出来的原因（已经是给人看的文字）。
struct NetSpeedFailure: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

struct NetSpeedLatencyResult: Equatable {
    /// 秒
    let median: TimeInterval
    let jitter: TimeInterval?
}

/// 测速服务器与出口：`/meta` 给的。
struct NetSpeedServer: Equatable {
    /// 机房三字码，如 `FRA`
    var colo: String = ""
    var coloCity: String = ""
    var asn: Int?
    /// 出口运营商 / 机房名
    var organization: String = ""

    /// 「Frankfurt (FRA)」；什么都没有时 nil。
    var node: String? {
        switch (coloCity.isEmpty, colo.isEmpty) {
        case (false, false): return "\(coloCity) (\(colo))"
        case (false, true): return coloCity
        case (true, false): return colo
        case (true, true): return nil
        }
    }

    /// 「Example Broadband (AS64500)」；什么都没有时 nil。
    var exit: String? {
        let asText = asn.map { "AS\($0)" }
        switch (organization.isEmpty, asText) {
        case (false, let asText?): return "\(organization) (\(asText))"
        case (false, nil): return organization
        case (true, let asText?): return asText
        case (true, nil): return nil
        }
    }
}

struct NetSpeedResult: Equatable {
    let at: Date
    let latency: Result<NetSpeedLatencyResult, NetSpeedFailure>
    /// 字节 / 秒
    let download: Result<Double, NetSpeedFailure>
    let upload: Result<Double, NetSpeedFailure>
    let server: NetSpeedServer?
    /// 这次一共收发了多少字节（含起速段与热连接）
    let bytesUsed: Int64
}

// MARK: - /meta

enum NetSpeedMeta {
    /// 解析 `https://speed.cloudflare.com/meta`（2026-11-25 实测）：
    /// `{"asn":64500,"asOrganization":"Example Broadband","country":"DE","city":"Frankfurt",
    ///   "colo":{"iata":"FRA","city":"Frankfurt",…},…}`（值是假的）。`colo` 是字符串也认，`asn` 是 `"AS64500"` 也认。
    /// 不是 JSON 对象、或者一样有用的都没有时 nil。
    static func parse(_ text: String) -> NetSpeedServer? {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var server = NetSpeedServer()
        if let colo = root["colo"] as? [String: Any] {
            server.colo = string(colo["iata"])
            server.coloCity = string(colo["city"])
        } else {
            server.colo = string(root["colo"])
        }
        server.asn = asn(root["asn"])
        server.organization = string(root["asOrganization"])
        guard server.node != nil || server.exit != nil else { return nil }
        return server
    }

    private static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func asn(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let asn = number.intValue
            return asn > 0 ? asn : nil
        }
        guard var text = (value as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.uppercased().hasPrefix("AS") { text.removeFirst(2) }
        guard let asn = Int(text), asn > 0 else { return nil }
        return asn
    }
}

// MARK: - 网卡

/// 一块网卡此刻的累计收发字节。
struct NetTrafficCounter: Equatable {
    var received: UInt64
    var sent: UInt64
}

/// 一次读数：网卡名 → 计数（只含计入的网卡），读的时刻（单调时钟，含睡眠）、计数是不是 32 位的。
struct NetTrafficSnapshot: Equatable {
    var time: TimeInterval
    var counters: [String: NetTrafficCounter]
    /// 退路给的 32 位计数：变小按回绕算，累计不可信；IFMIB 的 64 位计数变小 = 网卡重置
    var is32Bit: Bool = false

    var totalReceived: UInt64 { counters.values.reduce(0) { $0 &+ $1.received } }
    var totalSent: UInt64 { counters.values.reduce(0) { $0 &+ $1.sent } }
}

/// 此刻的速度与开机以来的累计。
struct NetTrafficRate: Equatable {
    /// 字节 / 秒
    var down: Double
    var up: Double
    /// 开机以来的累计；32 位计数（每 4 GiB 回绕）时 nil，不显示
    var totalDown: UInt64?
    var totalUp: UInt64?
}

enum NetTrafficMath {
    /// 两次读数间隔超过这么久（刚从睡眠醒来）那一次丢掉，不显示尖峰。
    static let maxGap: TimeInterval = 3

    /// 只算物理网卡：`en<数字>`（Wi-Fi、有线、USB / 雷雳网卡、iPhone USB 共享）和 `pdp_ip<数字>`（蜂窝），并且是启用状态。
    /// 不算 lo、utun / ipsec（VPN 隧道：同一份流量既过隧道又过物理网卡，加起来会翻倍）、awdl、llw、bridge、ap、gif、stf、
    /// anpi、vmnet / vmenet。
    static func counts(name: String, isUp: Bool) -> Bool {
        guard isUp else { return false }
        for prefix in ["en", "pdp_ip"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            return !rest.isEmpty && rest.allSatisfy { $0.isASCII && $0.isNumber }
        }
        return false
    }

    /// 一个计数的增量：没变小就相减；变小时 32 位计数按回绕算，64 位计数（网卡重置）按 0。
    static func delta(from old: UInt64, to new: UInt64, is32Bit: Bool) -> UInt64 {
        if new >= old { return new - old }
        guard is32Bit, old <= UInt64(UInt32.max), new <= UInt64(UInt32.max) else { return 0 }
        return (UInt64(UInt32.max) - old) + new + 1
    }

    /// 两次读数之间的速度。间隔不是正数、或超过 3 秒时 nil（丢掉这一次）；两次的位宽不一样（一次 32 位、一次 64 位）时也丢掉
    /// （不然差值就是高 32 位，一秒几十 GB）。两次都有的网卡才算（新出现的网卡这一秒不算）。
    static func rate(from old: NetTrafficSnapshot, to new: NetTrafficSnapshot) -> NetTrafficRate? {
        let interval = new.time - old.time
        guard interval > 0, interval <= maxGap, old.is32Bit == new.is32Bit else { return nil }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, counter) in new.counters {
            guard let previous = old.counters[name] else { continue }
            received &+= delta(from: previous.received, to: counter.received, is32Bit: new.is32Bit)
            sent &+= delta(from: previous.sent, to: counter.sent, is32Bit: new.is32Bit)
        }
        return NetTrafficRate(down: Double(received) / interval, up: Double(sent) / interval,
                              totalDown: new.is32Bit ? nil : new.totalReceived,
                              totalUp: new.is32Bit ? nil : new.totalSent)
    }
}

// MARK: - 相对时间

enum NetCheckTime {
    /// 「刚刚」：不到 5 秒，或者时间在将来（时钟差一点）——不会出现「0 秒后」这种写法。
    static func isJustNow(_ date: Date, now: Date) -> Bool {
        now.timeIntervalSince(date) < 5
    }
}
