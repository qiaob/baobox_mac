import Foundation
import XCTest

/// XMPP STARTTLS：`tcp_tls` 事件怎么解、`TCPLog` 把分隔线放在哪、合块不跨过分隔线（docs/packet-capture/STARTTLS.md §3）。
final class StartTLSTests: XCTestCase {

    private func line(_ json: String) -> Data { Data(("BAOBOX " + json).utf8) }
    private let id = UUID(uuidString: "4c1d2e3f-0a1b-4c2d-8e3f-405162738495") ?? UUID()
    private let t0 = Date(timeIntervalSince1970: 1_795_200_000)

    // MARK: - 事件

    func testDecryptedEvent() {
        XCTAssertEqual(CaptureEvent.parse(line: line(
            #"{"event":"tcp_tls","id":"\#(id.uuidString.lowercased())","state":"decrypted","sni":"chat.coffeemeetsbagel.com","version":"TLSv1.3"}"#)),
                       .tcpTLS(CaptureEvent.TCPTLS(connectionID: id, state: .decrypted, sni: "chat.coffeemeetsbagel.com",
                                                   version: "TLSv1.3", reason: nil)))
    }

    func testFailedEventReasons() {
        for (raw, reason) in [("handshake_failed", CaptureEvent.TCPTLS.Reason.handshakeFailed), ("decrypt_off", .decryptOff),
                              ("out_of_scope", .outOfScope), ("server_handshake_failed", .serverHandshakeFailed)] {
            guard case .tcpTLS(let tls)? = CaptureEvent.parse(line: line(
                #"{"event":"tcp_tls","id":"\#(id.uuidString)","state":"failed","sni":"x.test","reason":"\#(raw)"}"#))
            else { return XCTFail(raw) }
            XCTAssertEqual(tls.state, .failed)
            XCTAssertEqual(tls.reason, reason)
            XCTAssertNil(tls.version)
        }
    }

    /// 缺 id、缺或认不出 state 的行跳过；认不出的原因当作没有。
    func testMalformed() {
        XCTAssertNil(CaptureEvent.parse(line: line(#"{"event":"tcp_tls","state":"decrypted"}"#)))
        XCTAssertNil(CaptureEvent.parse(line: line(#"{"event":"tcp_tls","id":"\#(id.uuidString)"}"#)))
        XCTAssertNil(CaptureEvent.parse(line: line(#"{"event":"tcp_tls","id":"\#(id.uuidString)","state":"maybe"}"#)))
        guard case .tcpTLS(let tls)? = CaptureEvent.parse(line: line(
            #"{"event":"tcp_tls","id":"\#(id.uuidString)","state":"failed","reason":"cosmic_rays","sni":""}"#))
        else { return XCTFail() }
        XCTAssertNil(tls.reason)
        XCTAssertNil(tls.sni)
    }

    // MARK: - TCPLog

    private func open() -> CaptureEvent {
        .tcpOpen(CaptureEvent.TCPOpen(id: id, client: "10.0.0.1", wireguard: "6f1c2a9e-0b7d-4c55-9a3e-2f8d1e4b7c60",
                                      host: "139.95.11.88", port: 5222, sni: nil, startedAt: t0))
    }

    private func text(_ s: String, client: Bool, at: Double) -> CaptureEvent {
        .tcpData(CaptureEvent.TCPData(connectionID: id, fromClient: client, size: s.utf8.count, data: Data(s.utf8),
                                      truncated: false, at: t0.addingTimeInterval(at)))
    }

    private func tls(_ state: CaptureEvent.TCPTLS.State, reason: CaptureEvent.TCPTLS.Reason? = nil) -> CaptureEvent {
        .tcpTLS(CaptureEvent.TCPTLS(connectionID: id, state: state, sni: "chat.coffeemeetsbagel.com",
                                    version: state == .decrypted ? "TLSv1.3" : nil, reason: reason))
    }

    /// 明文 4 段 → `<proceed/>` 之后接管成功 → 解密后的 3 段：一条连接一行，分隔线在第 4 段后面，XMPP 照样认得出。
    func testDecryptedConnectionIsOneRowWithTheLineAfterProceed() throws {
        var log = TCPLog()
        log.apply([open(),
                   text("<?xml version='1.0'?><stream:stream to='chat.coffeemeetsbagel.com' xmlns='jabber:client'>", client: true, at: 0.1),
                   text("<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/></stream:features>", client: false, at: 0.2),
                   text("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>", client: true, at: 0.3),
                   text("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>", client: false, at: 0.4),
                   tls(.decrypted),
                   text("<stream:stream to='chat.coffeemeetsbagel.com' xmlns='jabber:client'>", client: true, at: 0.6),
                   text("<auth mechanism='PLAIN'>AGV4AA==</auth>", client: true, at: 0.7),
                   text("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>", client: false, at: 0.8),
                   .tcpClose(id: id, error: nil, at: t0.addingTimeInterval(1))], maxConnections: 10)
        XCTAssertEqual(log.connections.count, 1)
        let connection = try XCTUnwrap(log.connections.first)
        let mark = try XCTUnwrap(connection.tls)
        XCTAssertTrue(mark.decrypted)
        XCTAssertEqual(mark.afterSegment, 4)
        XCTAssertEqual(mark.versionLabel, "TLS 1.3")
        XCTAssertEqual(mark.detail, "chat.coffeemeetsbagel.com · TLS 1.3")
        XCTAssertEqual(connection.detected, TCPProtocolMatch(name: "XMPP", guessed: false))
        XCTAssertEqual(connection.wireguardID, "6f1c2a9e-0b7d-4c55-9a3e-2f8d1e4b7c60")
        XCTAssertEqual(connection.segmentCount, 7)

        // 合块：分隔线后的两段客户端数据合成一块，但不会和线前面的块合在一起；线插在第 5 块前面。
        let blocks = TCPStream.blocks(connection.segments, merge: true, breakAfter: mark.afterSegment)
        XCTAssertEqual(blocks.map(\.id), [1, 2, 3, 4, 5, 7])
        XCTAssertEqual(mark.boundaryIndex(in: blocks), 4)
        XCTAssertEqual(blocks[4].segmentCount, 2)
    }

    /// 线前线后同一个方向的段也不合并（没接管时，`<proceed/>` 之后客户端先说话的密文和之前客户端的明文之间也可能同向）。
    func testBlocksDoNotMergeAcrossTheLine() {
        let segments = [
            TCPSegment(id: 1, fromClient: true, size: 3, data: Data("abc".utf8), at: t0),
            TCPSegment(id: 2, fromClient: true, size: 3, data: Data("def".utf8), at: t0),
            TCPSegment(id: 3, fromClient: true, size: 3, data: Data([0x16, 0x03, 0x01]), at: t0),
            TCPSegment(id: 4, fromClient: true, size: 2, data: Data([0x00, 0x01]), at: t0),
        ]
        let blocks = TCPStream.blocks(segments, merge: true, breakAfter: 2)
        XCTAssertEqual(blocks.map(\.id), [1, 3])
        XCTAssertEqual(blocks.map(\.size), [6, 5])
        // 偏移照样按方向累计：线后的第一块从 6 开始。
        XCTAssertEqual(blocks[1].offset, 6)
        XCTAssertEqual(TCPStream.blocks(segments, merge: true).count, 1)
        XCTAssertEqual(TCPStream.blocks(segments, merge: false, breakAfter: 2).count, 4)
    }

    /// 没接管（之前握手失败过）：线在 `<proceed/>` 后面，之后的密文照样记字节；失败状态和原因在。
    func testPassedThroughKeepsTheCiphertext() throws {
        var log = TCPLog()
        log.apply([open(),
                   text("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>", client: true, at: 0.1),
                   text("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>", client: false, at: 0.2),
                   tls(.failed, reason: .handshakeFailed),
                   .tcpData(CaptureEvent.TCPData(connectionID: id, fromClient: true, size: 517,
                                                 data: Data([0x16, 0x03, 0x01, 0x02, 0x00, 0x01]), truncated: true,
                                                 at: t0.addingTimeInterval(0.3)))], maxConnections: 10)
        let connection = try XCTUnwrap(log.connections.first)
        let mark = try XCTUnwrap(connection.tls)
        XCTAssertFalse(mark.decrypted)
        XCTAssertEqual(mark.tls.reason, .handshakeFailed)
        XCTAssertEqual(mark.afterSegment, 2)
        XCTAssertEqual(connection.bytesUp, 51 + 517)
        let blocks = TCPStream.blocks(connection.segments, merge: true, breakAfter: mark.afterSegment)
        XCTAssertEqual(mark.boundaryIndex(in: blocks), 2)
    }

    /// 接管时手机拒绝了证书：线后面没有数据，线放在最后；连接以出错结束。
    func testRefusedCertificateLineAtTheEnd() throws {
        var log = TCPLog()
        log.apply([open(), text("<proceed/>", client: false, at: 0.1), tls(.failed, reason: .handshakeFailed),
                   .tcpClose(id: id, error: "TLS handshake failed", at: t0.addingTimeInterval(0.2))], maxConnections: 10)
        let connection = try XCTUnwrap(log.connections.first)
        let blocks = TCPStream.blocks(connection.segments, merge: true, breakAfter: connection.tls?.afterSegment)
        XCTAssertEqual(connection.tls?.boundaryIndex(in: blocks), blocks.count)
        XCTAssertEqual(connection.state, .failed)
    }

    /// 别的连接没有 TLS 标记；没见过 open 的连接的 tcp_tls 不落。
    func testOnlySTARTTLSConnectionsAreMarked() {
        var log = TCPLog()
        log.apply([open()], maxConnections: 10)
        XCTAssertNil(log.connections.first?.tls)
        XCTAssertFalse(log.apply([.tcpTLS(CaptureEvent.TCPTLS(connectionID: UUID(), state: .decrypted, sni: nil, version: nil,
                                                               reason: nil))], maxConnections: 10))
    }

    func testVersionLabel() {
        func mark(_ version: String?) -> TCPTLSMark {
            TCPTLSMark(tls: CaptureEvent.TCPTLS(connectionID: id, state: .decrypted, sni: nil, version: version, reason: nil),
                       afterSegment: 0)
        }
        XCTAssertEqual(mark("TLSv1.2").versionLabel, "TLS 1.2")
        XCTAssertEqual(mark("SSLv3").versionLabel, "SSLv3")
        XCTAssertNil(mark(nil).versionLabel)
        XCTAssertEqual(mark(nil).detail, "")
    }
}
