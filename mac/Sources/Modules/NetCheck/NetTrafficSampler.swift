import Foundation

/// 菜单栏实时网速的数据源：每秒读一次各网卡的累计收发字节，和上一秒相减（docs/netcheck/SPEED.md §2.1）。
/// 读数在后台队列的定时器里做（1 秒一次、容差 100 ms），结果回主线程交给 `onUpdate`（约定 1）。不要权限、不抓包、不联网。
/// 开关关着时定时器不存在。
@MainActor
final class NetTrafficSampler {
    static let shared = NetTrafficSampler()

    /// 最近一次的速度与累计（只在主线程读写）。
    private(set) var latest: NetTrafficRate?
    /// 每次有新的速度时调（主线程）。
    var onUpdate: ((NetTrafficRate) -> Void)?

    private let queue = DispatchQueue(label: "com.baobox.netcheck.traffic", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// 上一次读数：只在 `queue` 上读写。
    private let state = NetTrafficSamplerState()

    private init() {}

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let state = state
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        source.setEventHandler {
            guard let rate = state.sample() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // 关掉之后还在路上的那一次不要了
                    guard NetTrafficSampler.shared.timer != nil else { return }
                    NetTrafficSampler.shared.latest = rate
                    NetTrafficSampler.shared.onUpdate?(rate)
                }
            }
        }
        timer = source
        source.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        latest = nil
        let state = state
        queue.async { state.reset() }
    }
}

/// 采样器在后台队列上的状态（上一次读数）。只在采样器的队列上用。
final class NetTrafficSamplerState: @unchecked Sendable {
    private var previous: NetTrafficSnapshot?

    func reset() {
        previous = nil
    }

    /// 读一次，和上一次相减。第一次、读不到、间隔不对（睡眠醒来）时 nil。
    func sample() -> NetTrafficRate? {
        guard let current = NetTrafficReader.read() else { return nil }
        defer { previous = current }
        guard let previous else { return nil }
        return NetTrafficMath.rate(from: previous, to: current)
    }
}

/// 读系统的网卡统计。优先 `sysctl` 的 `NET_RT_IFLIST2`（64 位计数），不行再退到 `getifaddrs` 的 `if_data`（32 位，按回绕处理）。
/// 只留 `NetTrafficMath.counts` 认的物理网卡。
enum NetTrafficReader {
    /// 一块网卡的原始读数（筛选之前）。
    struct Interface: Equatable {
        let name: String
        let isUp: Bool
        let received: UInt64
        let sent: UInt64
    }

    static func read() -> NetTrafficSnapshot? {
        let time = monotonicSeconds()
        if let interfaces = routeTableInterfaces() {
            return snapshot(interfaces, time: time, is32Bit: false)
        }
        if let interfaces = ifaddrsInterfaces() {
            return snapshot(interfaces, time: time, is32Bit: true)
        }
        return nil
    }

    private static func snapshot(_ interfaces: [Interface], time: TimeInterval, is32Bit: Bool) -> NetTrafficSnapshot {
        var counters: [String: NetTrafficCounter] = [:]
        for interface in interfaces where NetTrafficMath.counts(name: interface.name, isUp: interface.isUp) {
            counters[interface.name] = NetTrafficCounter(received: interface.received, sent: interface.sent)
        }
        return NetTrafficSnapshot(time: time, counters: counters, is32Bit: is32Bit)
    }

    /// 含睡眠时间的单调时钟（秒）：睡眠醒来后两次读数的间隔才看得出变长。
    static func monotonicSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// `sysctl {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0}`：一串 `if_msghdr2`（RTM_IFINFO2），后面跟着带网卡名的 `sockaddr_dl`。
    static func routeTableInterfaces() -> [Interface]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        // 两次调用之间网卡可能变多，留点余量
        length += 4096
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        let headerSize = MemoryLayout<if_msghdr>.size
        let message2Size = MemoryLayout<if_msghdr2>.stride
        var interfaces: [Interface] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, messageLength >= message2Size {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if let name = linkName(raw, from: offset + message2Size, to: offset + messageLength) {
                        interfaces.append(Interface(name: name, isUp: message.ifm_flags & IFF_UP != 0,
                                                    received: message.ifm_data.ifi_ibytes,
                                                    sent: message.ifm_data.ifi_obytes))
                    }
                }
                offset += messageLength
            }
        }
        return interfaces
    }

    /// 紧跟在 `if_msghdr2` 后面的 `sockaddr_dl` 里的网卡名（`sdl_nlen` 个字节，从 `sdl_data` 开始）。越界、不是 AF_LINK 时 nil。
    private static func linkName(_ raw: UnsafeRawBufferPointer, from start: Int, to end: Int) -> String? {
        let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) ?? 8
        guard start + dataOffset <= end else { return nil }
        let address = raw.loadUnaligned(fromByteOffset: start, as: sockaddr_dl.self)
        guard Int32(address.sdl_family) == AF_LINK else { return nil }
        let nameLength = Int(address.sdl_nlen)
        guard nameLength > 0, start + dataOffset + nameLength <= end else { return nil }
        let bytes = raw[(start + dataOffset)..<(start + dataOffset + nameLength)]
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 退路：`getifaddrs` 里 AF_LINK 那一条的 `if_data`（计数是 32 位的）。
    static func ifaddrsInterfaces() -> [Interface]? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var interfaces: [Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let item = entry.pointee
            cursor = item.ifa_next
            guard let address = item.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK,
                  let data = item.ifa_data else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            interfaces.append(Interface(name: String(cString: item.ifa_name), isUp: Int32(item.ifa_flags) & IFF_UP != 0,
                                        received: UInt64(stats.ifi_ibytes), sent: UInt64(stats.ifi_obytes)))
        }
        return interfaces
    }
}
