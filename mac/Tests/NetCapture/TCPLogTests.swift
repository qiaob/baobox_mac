import Foundation
import XCTest

/// 「TCP 包」的数据：事件怎么落进来、协议什么时候认、相邻同方向的段怎么合成块（docs/packet-capture/CONTROL.md §4）。
final class TCPLogTests: XCTestCase {

    private let connectionID = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_795_200_000)

    private func open(port: Int = 25, id: UUID? = nil) -> CaptureEvent {
        .tcpOpen(CaptureEvent.TCPOpen(id: id ?? connectionID, client: "127.0.0.1", host: "10.1.2.3", port: port,
                                      sni: nil, startedAt: t0))
    }

    private func data(_ bytes: [UInt8], client: Bool, size: Int? = nil, at: Double = 0, id: UUID? = nil) -> CaptureEvent {
        .tcpData(CaptureEvent.TCPData(connectionID: id ?? connectionID, fromClient: client, size: size ?? bytes.count,
                                      data: bytes.isEmpty ? nil : Data(bytes), truncated: (size ?? bytes.count) > bytes.count,
                                      at: t0.addingTimeInterval(at)))
    }

    private func text(_ s: String, client: Bool, at: Double = 0) -> CaptureEvent { data(Array(s.utf8), client: client, at: at) }

    func testOpenDataClose() throws {
        var log = TCPLog()
        XCTAssertTrue(log.apply([open(), text("220 mx ESMTP\r\n", client: false), text("EHLO me\r\n", client: true, at: 1),
                                 .tcpClose(id: connectionID, error: nil, at: t0.addingTimeInterval(2))], maxConnections: 10))
        let connection = try XCTUnwrap(log.connections.first)
        XCTAssertEqual(connection.state, .closed)
        XCTAssertEqual(connection.bytesDown, 14)
        XCTAssertEqual(connection.bytesUp, 9)
        XCTAssertEqual(connection.segmentCount, 2)
        XCTAssertEqual(connection.duration, 2)
        XCTAssertEqual(connection.detected, TCPProtocolMatch(name: "SMTP", guessed: false))
        XCTAssertEqual(connection.firstSpeaker, .server)
    }

    func testErrorCloseAndUnknownConnection() {
        var log = TCPLog()
        log.apply([open(), .tcpClose(id: connectionID, error: "reset", at: nil)], maxConnections: 10)
        XCTAssertEqual(log.connections.first?.state, .failed)
        XCTAssertEqual(log.connections.first?.error, "reset")
        // 没见过 open 的连接的数据不落（暂停前没报过的连接）。
        XCTAssertFalse(log.apply([data([1], client: true, id: UUID())], maxConnections: 10))
    }

    /// 在 open 时只有端口，先给端口提示；有了数据再认。
    func testPortHintFirstThenContent() {
        var log = TCPLog()
        log.apply([open(port: 22)], maxConnections: 10)
        XCTAssertEqual(log.connections.first?.detected, TCPProtocolMatch(name: "SSH", guessed: true))
        log.apply([text("SSH-2.0-OpenSSH_9.6\r\n", client: false)], maxConnections: 10)
        XCTAssertEqual(log.connections.first?.detected, TCPProtocolMatch(name: "SSH", guessed: false))
    }

    /// 同一份首包：一整段、拆成 1 字节 + 其余、和后面的数据粘在一起，三种喂法认出来的一样。
    func testDetectionDoesNotDependOnSegmentBoundaries() {
        let greeting = Array("SSH-2.0-OpenSSH_9.6\r\n".utf8)
        let feeds: [[CaptureEvent]] = [
            [data(greeting, client: false)],
            [data(Array(greeting.prefix(1)), client: false), data(Array(greeting.dropFirst()), client: false)],
            [data(greeting + Array(repeating: 0x00, count: 300), client: false)],
        ]
        for events in feeds {
            var log = TCPLog()
            log.apply([open(port: 40000)] + events, maxConnections: 10)
            XCTAssertEqual(log.connections.first?.detected, TCPProtocolMatch(name: "SSH", guessed: false))
        }
        // MQTT 的特征被拆在两段里（第一次只读到 2 个字节）。
        let connect: [UInt8] = [0x10, 0x10, 0x00, 0x04] + Array("MQTT".utf8) + [0x04, 0x02, 0x00, 0x3C, 0x00, 0x04] + Array("abcd".utf8)
        var log = TCPLog()
        log.apply([open(port: 40000), data(Array(connect.prefix(2)), client: true)], maxConnections: 10)
        XCTAssertNil(log.connections.first?.detected)
        log.apply([data(Array(connect.dropFirst(2)), client: true)], maxConnections: 10)
        XCTAssertEqual(log.connections.first?.detected, TCPProtocolMatch(name: "MQTT", guessed: false))
    }

    /// 认出确定的协议后不再变。
    func testConfirmedProtocolSticks() {
        var log = TCPLog()
        log.apply([open(port: 40000), text("SSH-2.0-x\r\n", client: false), text("220 ESMTP\r\n", client: false)], maxConnections: 10)
        XCTAssertEqual(log.connections.first?.detected?.name, "SSH")
    }

    func testSegmentCapKeepsCounting() {
        var log = TCPLog()
        let events = [open()] + (0..<(TCPLog.maxSegments + 5)).map { data([0x41], client: true, at: Double($0)) }
        log.apply(events, maxConnections: 10)
        XCTAssertEqual(log.connections.first?.segments.count, TCPLog.maxSegments)
        XCTAssertEqual(log.connections.first?.segmentCount, TCPLog.maxSegments + 5)
        XCTAssertEqual(log.connections.first?.droppedSegments, 5)
        XCTAssertEqual(log.connections.first?.bytesUp, TCPLog.maxSegments + 5)
    }

    func testConnectionCap() {
        var log = TCPLog()
        let ids = (0..<5).map { _ in UUID() }
        log.apply(ids.map { open(id: $0) }, maxConnections: 3)
        XCTAssertEqual(log.connections.map(\.id), Array(ids.suffix(3)))
        log.removeAll()
        XCTAssertTrue(log.connections.isEmpty)
    }

    // MARK: - 流视图

    private func segment(_ id: Int, _ bytes: [UInt8], client: Bool, size: Int? = nil, at: Double = 0) -> TCPSegment {
        TCPSegment(id: id, fromClient: client, size: size ?? bytes.count, data: bytes.isEmpty ? nil : Data(bytes),
                   at: t0.addingTimeInterval(at))
    }

    /// 相邻同方向的段合成一块；一问一答自然分开；偏移按方向累计。
    func testMergedBlocks() {
        let segments = [segment(1, [1, 2], client: true, at: 0), segment(2, [3], client: true, at: 1),
                        segment(3, [9, 9, 9], client: false, at: 2),
                        segment(4, [4, 5], client: true, at: 3), segment(5, [8], client: false, at: 4)]
        let blocks = TCPStream.blocks(segments, merge: true)
        XCTAssertEqual(blocks.map(\.fromClient), [true, false, true, false])
        XCTAssertEqual(blocks.map(\.offset), [0, 0, 3, 3])
        XCTAssertEqual(blocks.map(\.size), [3, 3, 2, 1])
        XCTAssertEqual(blocks[0].parts, [.data(Data([1, 2, 3]), offset: 0)])
        XCTAssertEqual(blocks[0].segmentCount, 2)
        XCTAssertEqual(blocks[0].startedAt, t0)
        XCTAssertEqual(blocks[0].endedAt, t0.addingTimeInterval(1))
        XCTAssertEqual(blocks[2].parts, [.data(Data([4, 5]), offset: 3)])
    }

    /// 按读到的段：一段一块，偏移照样按方向累计。
    func testUnmergedBlocks() {
        let segments = [segment(1, [1, 2], client: true), segment(2, [3], client: true), segment(3, [7], client: false)]
        let blocks = TCPStream.blocks(segments, merge: false)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.map(\.offset), [0, 2, 0])
        XCTAssertEqual(blocks.map(\.id), [1, 2, 3])
    }

    /// 没保存的部分用占位标出，偏移往前走；相邻的占位并成一个。
    func testMissingBytesKeepOffsets() {
        let segments = [segment(1, [1, 2], client: true, size: 5),     // 只带了前 2 字节
                        segment(2, [], client: true, size: 10),        // 超过上限，没带数据
                        segment(3, [], client: false, size: 4),
                        segment(4, [6], client: true)]
        let merged = TCPStream.blocks(segments, merge: true)
        XCTAssertEqual(merged[0].parts, [.data(Data([1, 2]), offset: 0), .missing(count: 13, offset: 2)])
        XCTAssertEqual(merged[0].size, 15)
        XCTAssertEqual(merged[1].parts, [.missing(count: 4, offset: 0)])
        XCTAssertEqual(merged[2].offset, 15)
        XCTAssertEqual(merged[2].parts, [.data(Data([6]), offset: 15)])
        XCTAssertEqual(merged[0].savedData, Data([1, 2]))
    }
}
