import Foundation

/// 为什么拒收一个文件（#99）。
enum PhoneTransferRefusal: Equatable {
    /// 超过单个文件上限。
    case tooBig
    /// 这次会话收满了，或收完磁盘剩不到预留量。`room` = 现在最多还能收多少字节。
    case noRoom(room: Int64)

    /// 告诉手机网页的原因码与数字（网页按它显示「超过单个文件上限 10 GB」「电脑这次最多还能收 1.2 GB」）。
    var phoneReason: (why: String, limit: Int64) {
        switch self {
        case .tooBig: return ("size", PhoneTransferLimits.maxFileBytes)
        case .noRoom(let room): return ("room", room)
        }
    }

    /// Mac 传输列表里那一行的说明。
    var note: String {
        switch self {
        case .tooBig:
            return L("phonetransfer.refused.tooBig \(Self.bytes(PhoneTransferLimits.maxFileBytes))")
        case .noRoom(let room):
            return L("phonetransfer.refused.noRoom \(Self.bytes(room))")
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// 手机发来的东西收多少（#99）：防一台已经允许的设备把磁盘塞满。两种模式共用。
/// 纯函数 + 常量，局域网服务的后台队列也会调用。
enum PhoneTransferLimits {
    /// 单个文件。手机拍的 4K 视频十来分钟就有几个 GB，给 10 GB。
    static let maxFileBytes: Int64 = 10 << 30
    /// 一次会话（一个二维码）合计，文字也算进来。
    static let maxSessionBytes: Int64 = 20 << 30
    /// 收完之后磁盘至少还要剩这么多。
    static let diskReserveBytes: Int64 = 2 << 30

    /// 这次会话现在最多还能收多少：会话余量与磁盘余量（扣掉预留）取小。磁盘读不到时只看会话余量。
    static func room(received: Int64, freeSpace: Int64?) -> Int64 {
        var room = maxSessionBytes - received
        if let freeSpace { room = min(room, freeSpace - diskReserveBytes) }
        return max(0, room)
    }

    /// 收一个 `size` 字节的文件行不行；`received` 是这次会话已经收下（含正在收）的字节。
    static func check(size: Int64, received: Int64, freeSpace: Int64?) -> PhoneTransferRefusal? {
        if size > maxFileBytes { return .tooBig }
        let room = room(received: received, freeSpace: freeSpace)
        if size > room { return .noRoom(room: room) }
        return nil
    }

    /// 收件目录所在磁盘的可用空间；读不到（目录还没建等）为 nil。
    static func freeSpace(at dir: URL) -> Int64? {
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
