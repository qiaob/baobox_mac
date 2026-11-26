import Foundation

/// 菜单栏实时网速的数据源：每秒读一次各网卡的累计收发字节，和上一秒相减（docs/netcheck/SPEED.md §2.1）。
/// 读数在后台队列的定时器里做（1 秒一次、容差 100 ms），结果回主线程交给 `onUpdate`（约定 1）。不要权限、不抓包、不联网。
/// 开关关着时定时器不存在。
@MainActor
final class NetTrafficSampler {
    static let shared = NetTrafficSampler()

    /// 最近一次的速度与累计（只在主线程读写）。
    private(set) var latest: NetTrafficRate?
    /// 最近一次读到的主局域网网卡与 IPv4（后台每 5 秒刷新，菜单构建只读内存）。
    private(set) var latestLAN: NetCheckLAN?
    /// 每次有新的速度时调（主线程）。
    var onUpdate: ((NetTrafficRate) -> Void)?

    private let queue = DispatchQueue(label: "com.baobox.netcheck.traffic", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// 上一次读数：只在 `queue` 上读写。
    private let state = NetTrafficSamplerState()

    private init() {}

    func start() {
        guard timer == nil else { return }
        let state = state
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        source.setEventHandler {
            let (rate, lan) = state.sample()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // 关掉之后还在路上的那一次不要了
                    guard NetTrafficSampler.shared.timer != nil else { return }
                    NetTrafficSampler.shared.latestLAN = lan
                    if let rate {
                        NetTrafficSampler.shared.latest = rate
                        NetTrafficSampler.shared.onUpdate?(rate)
                    }
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
        latestLAN = nil
        let state = state
        queue.async { state.reset() }
    }
}

/// 采样器在后台队列上的状态（上一次读数）。只在采样器的队列上用。
final class NetTrafficSamplerState: @unchecked Sendable {
    private var previous: NetTrafficSnapshot?
    private var lanTick = 0
    private var cachedLAN: NetCheckLAN?

    func reset() {
        previous = nil
        lanTick = 0
        cachedLAN = nil
    }

    /// 读一次，和上一次相减；顺手每 5 秒刷一次主局域网 IP。第一次、读不到、间隔不对（睡眠醒来）时速率为 nil。
    func sample() -> (NetTrafficRate?, NetCheckLAN?) {
        if lanTick % 5 == 0 {
            cachedLAN = NetCheckEnvironmentReader.primaryLAN()
        }
        lanTick &+= 1
        guard let current = NetTrafficReader.read() else { return (nil, cachedLAN) }
        defer { previous = current }
        guard let previous else { return (nil, cachedLAN) }
        return (NetTrafficMath.rate(from: previous, to: current), cachedLAN)
    }
}

/// 读系统的网卡统计（docs/netcheck/SPEED.md §2.1）。
///
/// - 网卡名单与启用状态：`sysctl` 的 `NET_RT_IFLIST2`（读不到退到 `getifaddrs`）。
/// - 字节计数：对计入的那几块各调一次 `sysctl {CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, <ifindex>, IFDATA_GENERAL}`，
///   取 `ifmibdata.ifmd_data`，完整 64 位、不要权限。`NET_RT_IFLIST2` 的 `if_data64` 虽然字段是 64 位的，给普通进程时
///   高 32 位全是 0（2026-11-25 实测：同一块 en0 和 `netstat -ibn` 对照，高位只有 IFMIB 对得上），`getifaddrs` 的 `if_data`
///   本来就是 32 位。这条路拿不到时退回名单里的计数，当 32 位、变小按回绕算，「开机以来」不显示。
/// 只留 `NetTrafficMath.counts` 认的物理网卡。
enum NetTrafficReader {
    /// 一块网卡（筛选之前）：名单里的读数，计数只有低 32 位可信。
    struct Interface: Equatable {
        let name: String
        let index: UInt32
        let isUp: Bool
        let received: UInt64
        let sent: UInt64
    }

    static func read() -> NetTrafficSnapshot? {
        let time = monotonicSeconds()
        guard let interfaces = routeTableInterfaces() ?? ifaddrsInterfaces() else { return nil }
        let counted = interfaces.filter { NetTrafficMath.counts(name: $0.name, isUp: $0.isUp) }
        // 64 位计数：计入的每一块都要拿到，缺一块就整次退回 32 位（同一次读数里不混用位宽）
        var wide: [String: NetTrafficCounter] = [:]
        for interface in counted {
            guard let counter = fullCounter(index: interface.index) else {
                wide = [:]
                break
            }
            wide[interface.name] = counter
        }
        if wide.count == counted.count {
            return NetTrafficSnapshot(time: time, counters: wide, is32Bit: false)
        }
        var narrow: [String: NetTrafficCounter] = [:]
        for interface in counted {
            narrow[interface.name] = NetTrafficCounter(received: interface.received & 0xFFFF_FFFF,
                                                       sent: interface.sent & 0xFFFF_FFFF)
        }
        return NetTrafficSnapshot(time: time, counters: narrow, is32Bit: true)
    }

    /// 一块网卡的完整 64 位计数（IFMIB）。拿不到 nil。
    static func fullCounter(index: UInt32) -> NetTrafficCounter? {
        guard index > 0, index <= UInt32(Int32.max) else { return nil }
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(index), IFDATA_GENERAL]
        var data = ifmibdata()
        var length = MemoryLayout<ifmibdata>.size
        guard sysctl(&mib, UInt32(mib.count), &data, &length, nil, 0) == 0,
              length == MemoryLayout<ifmibdata>.size else { return nil }
        return NetTrafficCounter(received: data.ifmd_data.ifi_ibytes, sent: data.ifmd_data.ifi_obytes)
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
                        interfaces.append(Interface(name: name, index: UInt32(message.ifm_index),
                                                    isUp: message.ifm_flags & IFF_UP != 0,
                                                    received: message.ifm_data.ifi_ibytes,
                                                    sent: message.ifm_data.ifi_obytes))
                    }
                }
                offset += messageLength
            }
        }
        return interfaces
    }

    /// 紧跟在 `if_msghdr2` 后面的 `sockaddr_dl` 里的网卡名（`sdl_nlen` 个字节，从 `sdl_data` 开始）。
    /// 按 `sdl_len` 和这条消息剩下的长度两头查边界；越界、不是 AF_LINK 时 nil。
    private static func linkName(_ raw: UnsafeRawBufferPointer, from start: Int, to end: Int) -> String? {
        let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) ?? 8
        // 先确认头几个字节（sdl_len … sdl_slen）都在这条消息里，才去读它们
        guard start >= 0, start + dataOffset <= end, end <= raw.count else { return nil }
        let addressLength = Int(raw[start])
        let family = Int32(raw[start + 1])
        let nameLength = Int(raw[start + 5])
        guard family == AF_LINK, nameLength > 0,
              dataOffset + nameLength <= addressLength,
              start + addressLength <= end else { return nil }
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
            let name = String(cString: item.ifa_name)
            interfaces.append(Interface(name: name, index: if_nametoindex(name),
                                        isUp: Int32(item.ifa_flags) & IFF_UP != 0,
                                        received: UInt64(stats.ifi_ibytes), sent: UInt64(stats.ifi_obytes)))
        }
        return interfaces
    }
}
