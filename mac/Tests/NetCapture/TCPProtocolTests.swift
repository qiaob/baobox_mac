import Foundation
import XCTest

/// 原始 TCP 的协议识别（docs/packet-capture/CONTROL.md §4.3）。每种协议至少一条认得出的样本、一条相近但不该认的样本。
final class TCPProtocolTests: XCTestCase {

    private func id(port: Int = 40000, client: [UInt8] = [], server: [UInt8] = [], clientTotal: Int? = nil,
                    first: TCPProtocol.Input.Side? = nil, sni: String? = nil) -> TCPProtocolMatch? {
        let speaker = first ?? (client.isEmpty ? (server.isEmpty ? nil : .server) : .client)
        return TCPProtocol.identify(TCPProtocol.Input(
            port: port, sni: sni, client: Data(client), server: Data(server),
            clientTotal: clientTotal ?? client.count, firstSpeaker: speaker))
    }

    private func name(port: Int = 40000, client: [UInt8] = [], server: [UInt8] = [], clientTotal: Int? = nil,
                      first: TCPProtocol.Input.Side? = nil, sni: String? = nil) -> String? {
        guard let match = id(port: port, client: client, server: server, clientTotal: clientTotal, first: first, sni: sni),
              !match.guessed else { return nil }
        return match.name
    }

    private func b(_ text: String) -> [UInt8] { Array(text.utf8) }

    func testSSH() {
        XCTAssertEqual(name(server: b("SSH-2.0-OpenSSH_9.6\r\n")), "SSH")
        XCTAssertEqual(name(client: b("SSH-2.0-libssh\r\n")), "SSH")
        XCTAssertNil(name(client: b("SSH-it is a secret")))
    }

    func testMQTT() {
        // CONNECT，剩余长度 16，协议名 MQTT，级别 4。
        let connect: [UInt8] = [0x10, 0x10, 0x00, 0x04] + b("MQTT") + [0x04, 0x02, 0x00, 0x3C, 0x00, 0x04] + b("abcd")
        XCTAssertEqual(name(client: connect), "MQTT")
        let v31: [UInt8] = [0x10, 0x14, 0x00, 0x06] + b("MQIsdp") + [0x03, 0x02, 0x00, 0x3C, 0x00, 0x06] + b("client")
        XCTAssertEqual(name(client: v31), "MQTT")
        XCTAssertNil(name(client: [0x10, 0x10, 0x00, 0x04] + b("MQTX") + [0x04, 0x02]))
    }

    func testAMQP() {
        XCTAssertEqual(name(client: b("AMQP") + [0x00, 0x00, 0x09, 0x01]), "AMQP")
        XCTAssertNil(name(client: b("AMQPS stream")))
    }

    func testMySQL() {
        let version = b("8.0.33") + [0x00]
        let payloadLength = 74
        let greeting: [UInt8] = [UInt8(payloadLength), 0x00, 0x00, 0x00, 0x0A] + version + [0x08, 0x00, 0x00, 0x00] + Array(repeating: 0x41, count: 20)
        XCTAssertEqual(name(server: greeting), "MySQL")
        let maria: [UInt8] = [0x5B, 0x00, 0x00, 0x00, 0x0A] + b("5.5.5-10.11.6-MariaDB-0+deb12u1") + [0x00, 0x01]
        XCTAssertEqual(name(server: maria), "MySQL")
        // 序号不是 0、版本串不以数字开头，都不算。
        XCTAssertNil(name(server: [UInt8(payloadLength), 0x00, 0x00, 0x01, 0x0A] + version))
        XCTAssertNil(name(server: [UInt8(payloadLength), 0x00, 0x00, 0x00, 0x0A] + b("hello") + [0x00]))
    }

    func testPostgreSQL() {
        XCTAssertEqual(name(client: [0x00, 0x00, 0x00, 0x08, 0x04, 0xD2, 0x16, 0x2F]), "PostgreSQL")
        let startup: [UInt8] = [0x00, 0x00, 0x00, 0x29, 0x00, 0x03, 0x00, 0x00] + b("user") + [0x00] + b("postgres") + [0x00]
        XCTAssertEqual(name(client: startup), "PostgreSQL")
        // SSLRequest 的长度必须是 8；协议号 2.0 不认。
        XCTAssertNil(name(client: [0x00, 0x00, 0x00, 0x10, 0x04, 0xD2, 0x16, 0x2F]))
        XCTAssertNil(name(client: [0x00, 0x00, 0x00, 0x29, 0x00, 0x02, 0x00, 0x00]))
    }

    func testRedis() {
        XCTAssertEqual(name(client: b("*2\r\n$4\r\nAUTH\r\n$6\r\nsecret\r\n")), "Redis")
        XCTAssertEqual(name(client: b("PING\r\n")), "Redis")
        XCTAssertEqual(name(client: b("AUTH hunter2\r\n"), first: .client), "Redis")
        // 只凭首字节是 `*` 不算；IMAP 的服务器招呼 `* OK` 不是 Redis。
        XCTAssertNil(name(client: b("*hello world")))
        XCTAssertNotEqual(name(server: b("* OK IMAP4rev1 ready\r\n")), "Redis")
    }

    func testMongoDB() {
        func header(length: Int, responseTo: Int, opCode: Int) -> [UInt8] {
            func le(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
            return le(length) + le(7) + le(responseTo) + le(opCode) + [0, 0, 0, 0]
        }
        XCTAssertEqual(name(client: header(length: 120, responseTo: 0, opCode: 2013)), "MongoDB")
        XCTAssertEqual(name(client: header(length: 200, responseTo: 0, opCode: 2004)), "MongoDB")
        XCTAssertNil(name(client: header(length: 120, responseTo: 0, opCode: 2012)))
        XCTAssertNil(name(client: header(length: 120, responseTo: 5, opCode: 2013)))
    }

    func testServerGreetings() {
        XCTAssertEqual(name(server: b("220 mx.example.com ESMTP Postfix\r\n")), "SMTP")
        XCTAssertEqual(name(server: b("220 (vsFTPd 3.0.5)\r\n")), "FTP")
        XCTAssertEqual(name(server: b("* OK [CAPABILITY IMAP4rev1] ready\r\n")), "IMAP")
        XCTAssertEqual(name(server: b("+OK POP3 server ready\r\n"), first: .server), "POP3")
        // 220 但既不是 SMTP 也不是 FTP；`+OK` 但客户端先说话（Redis 的回答）。
        XCTAssertNil(name(server: b("220 welcome\r\n")))
        XCTAssertNotEqual(name(client: b("SET a 1\r\n"), server: b("+OK\r\n"), first: .client), "POP3")
    }

    /// 客户端先发 AUTH、服务器回 +OK 是 Redis；服务器先打招呼 +OK、客户端再 AUTH 是 POP3。
    func testRedisAndPOP3AreToldApartByWhoSpokeFirst() {
        XCTAssertEqual(name(client: b("AUTH pw\r\n"), server: b("+OK\r\n"), first: .client), "Redis")
        XCTAssertEqual(name(client: b("AUTH PLAIN\r\n"), server: b("+OK ready\r\n"), first: .server), "POP3")
    }

    func testXMPP() {
        XCTAssertEqual(name(client: b("<?xml version='1.0'?><stream:stream to='example.com'")), "XMPP")
        XCTAssertEqual(name(client: b("<stream:stream xmlns='jabber:client'")), "XMPP")
        XCTAssertNil(name(client: b("<?xml version=\"1.0\"?><soap:Envelope>")))
    }

    func testBitTorrent() {
        XCTAssertEqual(name(client: [0x13] + b("BitTorrent protocol") + Array(repeating: 0, count: 8)), "BitTorrent")
        XCTAssertNil(name(client: [0x12] + b("BitTorrent protocol")))
    }

    /// 2026-11-21 在用户手机上实际看到的微信首包 `16f10400…`。
    func testMMTLS() {
        XCTAssertEqual(name(client: [0x16, 0xF1, 0x04, 0x00, 0xB7, 0x01, 0x03, 0xF1]), "mmtls")
        XCTAssertNotEqual(name(client: [0x16, 0xF1, 0x03, 0x00]), "mmtls")
    }

    func testTLS() {
        XCTAssertEqual(name(client: [0x16, 0x03, 0x01, 0x02, 0x00, 0x01, 0x00, 0x01, 0xFC]), "TLS")
        // 记录头对、但不是 ClientHello。
        XCTAssertNil(name(client: [0x16, 0x03, 0x01, 0x02, 0x00, 0x02]))
        XCTAssertNil(name(client: [0x16, 0x03, 0x07, 0x02, 0x00, 0x01]))
    }

    func testRTMP() {
        let c0c1: [UInt8] = [0x03] + Array(repeating: 0, count: 63)
        XCTAssertEqual(name(client: c0c1, clientTotal: 1537), "RTMP")
        XCTAssertEqual(name(client: c0c1, server: [0x03, 0x00], clientTotal: 1537), "RTMP")
        // 不够 1537 字节；服务器回的首字节不是 0x03。
        XCTAssertNil(name(client: c0c1, clientTotal: 64))
        XCTAssertNil(name(client: c0c1, server: [0x05], clientTotal: 1537))
    }

    func testDNSOverTCP() {
        let query: [UInt8] = [0x00, 0x1D, 0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0] + b("\u{07}example\u{03}com") + [0, 0, 1, 0, 1]
        XCTAssertEqual(name(port: 53, client: query), "DNS")
        // 别的端口不认；整条消息还没到齐也不认。
        XCTAssertNil(name(port: 5353, client: query))
        XCTAssertNil(name(port: 53, client: Array(query.prefix(14))))
    }

    func testFCMBySNI() {
        XCTAssertEqual(name(port: 5228, client: [0x29, 0x02], sni: "mtalk.google.com"), "FCM")
        XCTAssertNil(name(port: 5228, client: [0x29, 0x02], sni: "talk.google.com"))
    }

    func testPortGuesses() {
        let cases: [(Int, String)] = [(22, "SSH"), (25, "SMTP"), (465, "SMTP"), (587, "SMTP"), (110, "POP3"), (995, "POP3"),
                                      (143, "IMAP"), (993, "IMAP"), (1883, "MQTT"), (8883, "MQTT"), (3306, "MySQL"),
                                      (5432, "PostgreSQL"), (6379, "Redis"), (27017, "MongoDB"), (5222, "XMPP"), (5223, "XMPP"),
                                      (5228, "FCM"), (5229, "FCM"), (5230, "FCM"), (5671, "AMQP"), (5672, "AMQP"), (1935, "RTMP")]
        for (port, expected) in cases {
            XCTAssertEqual(id(port: port), TCPProtocolMatch(name: expected, guessed: true), "port \(port)")
        }
        XCTAssertEqual(id(port: 22)?.label, "SSH?")
        XCTAssertNil(id(port: 443))
        XCTAssertNil(id(port: 8080, client: b("hello")))
    }

    /// 内容认得出时按内容，不按端口：6379 上跑的其实是 SSH。
    func testContentWinsOverPort() {
        XCTAssertEqual(id(port: 6379, server: b("SSH-2.0-dropbear\r\n")), TCPProtocolMatch(name: "SSH", guessed: false))
    }

    func testTextPreference() {
        XCTAssertTrue(TCPProtocolMatch(name: "SMTP", guessed: false).prefersText)
        XCTAssertTrue(TCPProtocolMatch(name: "SSH", guessed: true).prefersText)
        XCTAssertFalse(TCPProtocolMatch(name: "MQTT", guessed: false).prefersText)
    }
}
