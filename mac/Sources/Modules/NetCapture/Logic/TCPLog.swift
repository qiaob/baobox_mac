import Foundation

// 网络抓包的纯逻辑（只依赖 Foundation，进 BaoboxTests）：「TCP 包」页的数据。
// 见 docs/packet-capture/CONTROL.md §4。
//
// 引擎报上来的每条 `tcp_data` 只是「这一次读到的那一段」，边界是任意的：一条应用层消息可能被拆成几段，
// 几条也可能粘在一段里。这里按段存（`TCPSegment`），显示时默认把相邻、同方向的段合成一块（`TCPStream`）。

/// 读到的一段。
struct TCPSegment: Identifiable, Equatable, Sendable {
    /// 连接内从 1 起的序号。
    let id: Int
    let fromClient: Bool
    /// 这一段实际的字节数。
    let size: Int
    /// 带过来的内容；超过上限的为 nil，或比 `size` 短（只带了前 16 KB）。
    let data: Data?
    let at: Date

    /// 没保存下来的字节数。
    var missing: Int { max(0, size - (data?.count ?? 0)) }
}

/// 一条原始 TCP 连接。
struct TCPConnection: Identifiable, Equatable, Sendable {
    enum State: String, Sendable {
        case open, closed, failed
    }

    let id: UUID
    var client: String?
    /// 经 WireGuard 来的：是哪台设备（设备 id）。
    var wireguardID: String?
    var host: String
    var port: Int
    var sni: String?
    var startedAt: Date
    var endedAt: Date?
    var state: State = .open
    var error: String?
    /// 客户端 → 服务器、服务器 → 客户端的字节数（含没保存的）。
    var bytesUp = 0
    var bytesDown = 0
    /// 一共读到多少段（含没留下的）。
    var segmentCount = 0
    /// 留下来的段：只留前 `TCPLog.maxSegments` 段，后面的只计数、计字节。
    var segments: [TCPSegment] = []
    /// 认出来的协议；nil = 未知。
    var detected: TCPProtocolMatch?
    /// XMPP STARTTLS 接管过的连接：解开了没有、分隔线在哪（docs/packet-capture/STARTTLS.md §3.3）。别的连接为 nil。
    var tls: TCPTLSMark?

    /// 两个方向各自累计的前若干字节，认协议用（`TCPProtocol.prefixLimit`）。
    var clientPrefix = Data()
    var serverPrefix = Data()
    var firstSpeaker: TCPProtocol.Input.Side?

    init(id: UUID, client: String?, wireguardID: String? = nil, host: String, port: Int, sni: String?, startedAt: Date) {
        self.id = id
        self.client = client
        self.wireguardID = wireguardID
        self.host = host
        self.port = port
        self.sni = sni
        self.startedAt = startedAt
        detected = TCPProtocol.identify(input)
    }

    /// 列表里「目标」那一格：有 SNI 写域名，否则 IP。
    var target: String { sni ?? host }

    var droppedSegments: Int { segmentCount - segments.count }

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }

    var input: TCPProtocol.Input {
        TCPProtocol.Input(port: port, sni: sni, client: clientPrefix, server: serverPrefix,
                          clientTotal: bytesUp, firstSpeaker: firstSpeaker)
    }

    /// 收到一段：计数、计字节、留段、攒前缀；前缀变长了（或 RTMP 要看的客户端字节数刚够）就重新认一次，认出确定的就不再认。
    mutating func receive(_ data: CaptureEvent.TCPData, keepSegment: Bool) {
        segmentCount += 1
        let clientBefore = bytesUp
        if data.fromClient { bytesUp += data.size } else { bytesDown += data.size }
        if keepSegment {
            segments.append(TCPSegment(id: segmentCount, fromClient: data.fromClient, size: data.size,
                                       data: data.data, at: data.at))
        }
        if firstSpeaker == nil, data.size > 0 { firstSpeaker = data.fromClient ? .client : .server }

        guard detected?.guessed ?? true else { return }
        var grew = false
        // 只接在连续的字节后面：这一段前面有没保存的，前缀就不再长。
        if let bytes = data.data, !bytes.isEmpty {
            if data.fromClient, clientPrefix.count < TCPProtocol.prefixLimit, clientPrefix.count == clientBefore {
                clientPrefix.append(bytes.prefix(TCPProtocol.prefixLimit - clientPrefix.count))
                grew = true
            } else if !data.fromClient, serverPrefix.count < TCPProtocol.prefixLimit,
                      serverPrefix.count == bytesDown - data.size {
                serverPrefix.append(bytes.prefix(TCPProtocol.prefixLimit - serverPrefix.count))
                grew = true
            }
        }
        let rtmpThreshold = clientBefore < 1537 && bytesUp >= 1537
        if grew || rtmpThreshold { detected = TCPProtocol.identify(input) }
    }
}

/// 全部连接（旧 → 新）和怎么把引擎事件落进来。`TCPStore` 包着它。
struct TCPLog: Sendable {
    /// 一条连接最多留多少段；之后的只计数、计字节。
    static let maxSegments = 2000

    private(set) var connections: [TCPConnection] = []

    /// 落一批事件，返回有没有变化。超过 `maxConnections` 条丢最旧的。与 TCP 无关的事件忽略。
    @discardableResult
    mutating func apply(_ events: [CaptureEvent], maxConnections: Int) -> Bool {
        var changed = false
        for event in events {
            switch event {
            case .tcpOpen(let open):
                let connection = TCPConnection(id: open.id, client: open.client, wireguardID: open.wireguard,
                                               host: open.host, port: open.port, sni: open.sni, startedAt: open.startedAt)
                if let index = index(of: open.id) { connections[index] = connection } else { connections.append(connection) }
                changed = true
            case .tcpData(let data):
                guard let index = index(of: data.connectionID) else { continue }
                let keep = connections[index].segments.count < Self.maxSegments
                connections[index].receive(data, keepSegment: keep)
                changed = true
            case .tcpClose(let id, let error, let at):
                guard let index = index(of: id) else { continue }
                connections[index].endedAt = at ?? Date()
                connections[index].state = error == nil ? .closed : .failed
                connections[index].error = error
                changed = true
            case .tcpTLS(let tls):
                guard let index = index(of: tls.connectionID) else { continue }
                // 分隔线放在此刻已经读到的段后面：桥在 `<proceed/>` 转发之后、TLS 之前发这条。
                connections[index].tls = TCPTLSMark(tls: tls, afterSegment: connections[index].segmentCount)
                changed = true
            default:
                continue
            }
        }
        if connections.count > maxConnections {
            connections.removeFirst(connections.count - maxConnections)
        }
        return changed
    }

    mutating func removeAll() {
        connections.removeAll()
    }

    /// 删掉符合条件的连接，返回有没有删掉。
    @discardableResult
    mutating func removeAll(where shouldRemove: (TCPConnection) -> Bool) -> Bool {
        let before = connections.count
        connections.removeAll(where: shouldRemove)
        return connections.count != before
    }

    /// 数据几乎总是落在最近的几条上，从尾部找。
    private func index(of id: UUID) -> Int? {
        connections.lastIndex { $0.id == id }
    }
}

/// STARTTLS 接管过的连接上的 TLS 标记：结果 + 分隔线的位置（序号 ≤ `afterSegment` 的段在线上面，是 TLS 之前的明文）。
struct TCPTLSMark: Equatable, Sendable {
    var tls: CaptureEvent.TCPTLS
    var afterSegment: Int

    var decrypted: Bool { tls.state == .decrypted }

    /// `TLSv1.3` → `TLS 1.3`；认不出的原样。
    var versionLabel: String? {
        guard let raw = tls.version else { return nil }
        if raw.hasPrefix("TLSv") { return "TLS " + raw.dropFirst(4) }
        return raw
    }

    /// 分隔线上「· 域名 · TLS 1.3」那一截（没有的项不写）。
    var detail: String {
        [tls.sni, versionLabel].compactMap { $0 }.joined(separator: " · ")
    }

    /// 分隔线插在第几块前面：第一块起始段序号大于 `afterSegment` 的那块；都在线上面就放在最后。
    func boundaryIndex(in blocks: [TCPBlock]) -> Int {
        blocks.firstIndex { $0.id > afterSegment } ?? blocks.count
    }
}

/// 详情里「数据」怎么排：默认把相邻、同方向的段合成一块（一问一答自然分开），也能按读到的段一段一段看。
/// 偏移量按**这个方向的累计偏移**连续编号；没保存的部分用占位标出，偏移照样往前走，后面的偏移对得上。
struct TCPBlock: Identifiable, Equatable, Sendable {
    enum Part: Equatable, Sendable {
        /// 保存下来的字节，从 `offset` 起（这个方向的累计偏移）。
        case data(Data, offset: Int)
        /// 没保存的 `count` 字节，从 `offset` 起。
        case missing(count: Int, offset: Int)
    }

    /// 第一段的序号。
    let id: Int
    let fromClient: Bool
    /// 这一块在它那个方向上的起始偏移。
    let offset: Int
    /// 这一块的总字节数（含没保存的）。
    var size: Int
    var parts: [Part]
    let startedAt: Date
    var endedAt: Date
    var segmentCount: Int

    /// 保存下来的字节拼在一起（复制、判断像不像文本用）。
    var savedData: Data {
        parts.reduce(into: Data()) { result, part in
            if case .data(let bytes, _) = part { result.append(bytes) }
        }
    }
}

enum TCPStream {
    /// `merge` = 相邻同方向的段合成一块；false = 一段一块（看读取时序用）。
    /// `breakAfter`：序号大于它的段不和前面的合并（STARTTLS 的分隔线两边分开）。
    static func blocks(_ segments: [TCPSegment], merge: Bool, breakAfter: Int? = nil) -> [TCPBlock] {
        var blocks: [TCPBlock] = []
        var upOffset = 0
        var downOffset = 0
        for segment in segments {
            let offset = segment.fromClient ? upOffset : downOffset
            var parts: [TCPBlock.Part] = []
            let saved = segment.data ?? Data()
            if !saved.isEmpty { parts.append(.data(saved, offset: offset)) }
            if segment.missing > 0 { parts.append(.missing(count: segment.missing, offset: offset + saved.count)) }
            if segment.fromClient { upOffset += segment.size } else { downOffset += segment.size }

            var crossesBoundary = false
            if let breakAfter, let last = blocks.last { crossesBoundary = last.id <= breakAfter && segment.id > breakAfter }
            if merge, blocks.last?.fromClient == segment.fromClient, !crossesBoundary {
                // 先取下来再改再放回：这一块的数据只有一个引用，接上新的字节时就地追加，不整块复制。
                var last = blocks.removeLast()
                for part in parts { append(part, to: &last.parts) }
                last.size += segment.size
                last.endedAt = segment.at
                last.segmentCount += 1
                blocks.append(last)
            } else {
                blocks.append(TCPBlock(id: segment.id, fromClient: segment.fromClient, offset: offset, size: segment.size,
                                       parts: parts, startedAt: segment.at, endedAt: segment.at, segmentCount: 1))
            }
        }
        return blocks
    }

    /// 接一个部分：和前一个同类就并起来（数据接上，占位的字节数相加）。
    private static func append(_ part: TCPBlock.Part, to parts: inout [TCPBlock.Part]) {
        guard let last = parts.indices.last else {
            parts.append(part)
            return
        }
        switch (parts[last], part) {
        case (.data(_, let offset), .data(let bytes, _)):
            // 先从数组里取出来、把那一格换掉，取出来的这份就是唯一的引用，追加是就地的
            // （不然每接一段都把前面攒下的整份复制一遍）。
            guard case .data(var previous, _) = parts[last] else { return }
            parts[last] = .missing(count: 0, offset: offset)
            previous.append(bytes)
            parts[last] = .data(previous, offset: offset)
        case (.missing(let previous, let offset), .missing(let count, _)):
            parts[last] = .missing(count: previous + count, offset: offset)
        default:
            parts.append(part)
        }
    }
}
