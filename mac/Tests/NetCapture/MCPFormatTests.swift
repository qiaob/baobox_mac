import Foundation
import XCTest

/// 本地 MCP 的几处整理：Mock 规则脱敏回写、TCP 二进制块预览、TLS 记录识别、设备行。
final class MCPFormatTests: XCTestCase {

    private func h(_ name: String, _ value: String) -> HTTPHeader { HTTPHeader(name: name, value: value) }

    // MARK: - 脱敏回写

    /// AI 把 list_mock_rules 读到的头原样写回：`<redacted>` 换回原值，别的头照写。
    func testRedactedValuesKeepTheRuleValues() {
        let existing = [h("Authorization", "Bearer real"), h("Content-Type", "application/json"), h("Set-Cookie", "a=1"),
                        h("set-cookie", "b=2")]
        let incoming = [h("authorization", "<redacted>"), h("Content-Type", "text/plain"), h("Set-Cookie", "<redacted>"),
                        h("Set-Cookie", "<redacted>"), h("X-New", "1")]
        let result = MCPHeaderRestore.restore(incoming, from: existing)
        XCTAssertEqual(result.headers, [h("authorization", "Bearer real"), h("Content-Type", "text/plain"), h("Set-Cookie", "a=1"),
                                        h("Set-Cookie", "b=2"), h("X-New", "1")])
        XCTAssertEqual(result.unresolved, [])
    }

    /// 原来没有这个头（或同名的不够数）：不写入，名字报出来。
    func testRedactedWithoutAnOriginalIsDropped() {
        let result = MCPHeaderRestore.restore([h("Cookie", "<redacted>"), h("Set-Cookie", "<redacted>"), h("Set-Cookie", "<redacted>")],
                                              from: [h("Set-Cookie", "only=1")])
        XCTAssertEqual(result.headers, [h("Set-Cookie", "only=1")])
        XCTAssertEqual(result.unresolved, ["Cookie", "Set-Cookie"])
        // 新规则（原来什么都没有）。
        XCTAssertEqual(MCPHeaderRestore.restore([h("Authorization", "<redacted>")], from: []).unresolved, ["Authorization"])
        // 只认整个值恰好是 `<redacted>`。
        XCTAssertEqual(MCPHeaderRestore.restore([h("X", "a <redacted> b")], from: []).headers, [h("X", "a <redacted> b")])
    }

    // MARK: - 二进制块

    func testBinaryBlockPreview() {
        let data = Data([0x17, 0x03, 0x03, 0x12, 0x00] + Array(repeating: 0xAB, count: 4600 - 5))
        let text = MCPBlockText.render(data, offset: 0x200, format: "auto")
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "(TLS record: application data, encrypted)")
        XCTAssertEqual(lines.count, 1 + 16 + 1)          // 标注 + 256 字节 = 16 行十六进制 + 剩余
        XCTAssertTrue(lines[1].hasPrefix("00000200  17 03 03 12 00"))
        XCTAssertEqual(lines.last, "[… 4344 more bytes (binary; use format: hex to get all of it)]")
        XCTAssertLessThan(text.count, 1600)               // 原来整块转 hex 约 18 KB
    }

    func testShortBinaryHasNoTail() {
        let text = MCPBlockText.render(Data([0x00, 0x01, 0x02, 0xff]), offset: 0, format: "auto")
        XCTAssertEqual(text, "00000000  00 01 02 ff                                       |....|")
    }

    func testTextAndExplicitFormats() {
        let hello = Data("220 smtp ready\r\n".utf8)
        XCTAssertEqual(MCPBlockText.render(hello, offset: 0, format: "auto"), "220 smtp ready\n")
        let big = Data(repeating: 0x00, count: 1000)
        // format: hex 照旧给全（调用方另有每块 8 KB 上限）。
        XCTAssertEqual(MCPBlockText.render(big, offset: 0, format: "hex").components(separatedBy: "\n").count, 63)
        XCTAssertEqual(MCPBlockText.render(hello, offset: 0, format: "text"), "220 smtp ready\n")
    }

    func testTLSRecord() {
        XCTAssertEqual(MCPBlockText.tlsRecord(Data([0x16, 0x03, 0x01, 0x02, 0x00])), "handshake")
        XCTAssertEqual(MCPBlockText.tlsRecord(Data([0x17, 0x03, 0x03])), "application data, encrypted")
        XCTAssertNil(MCPBlockText.tlsRecord(Data([0x15, 0x03, 0x03])))
        XCTAssertNil(MCPBlockText.tlsRecord(Data([0x16, 0x03, 0x05])))
        XCTAssertNil(MCPBlockText.tlsRecord(Data([0x16, 0xf1, 0x04])))     // mmtls
        XCTAssertNil(MCPBlockText.tlsRecord(Data([0x16, 0x03])))
    }

    // MARK: - 设备行

    func testDeviceLine() {
        XCTAssertEqual(MCPDeviceLine.format(key: "192.168.0.9", kind: .lan, name: nil, count: 1, last: "T"),
                       "192.168.0.9 · LAN · 1 flow · T")
        XCTAssertEqual(MCPDeviceLine.format(key: "192.168.0.9", kind: .lan, name: "192.168.0.9", count: 3, last: "T"),
                       "192.168.0.9 · LAN · 3 flows · T")
        XCTAssertEqual(MCPDeviceLine.format(key: "127.0.0.1", kind: .thisMac, name: nil, count: 2, last: "T"),
                       "127.0.0.1 · This Mac · 2 flows · T")
        XCTAssertEqual(MCPDeviceLine.format(key: "wg:abc", kind: .wireguard, name: "vivo", count: 5, last: "T"),
                       "wg:abc · WireGuard · vivo · 5 flows · T")
        XCTAssertEqual(MCPDeviceLine.format(key: "192.168.0.23", kind: .lan, name: "测试机", count: 2, last: "T"),
                       "192.168.0.23 · LAN · 测试机 · 2 flows · T")
    }

    // MARK: - 只给本机的 AI 工具用

    private func gate(_ headers: [String: String], method: String = "POST") -> MCPRequestGate.Rejection? {
        MCPRequestGate.check(method: method, headers: headers, port: 9191)
    }

    func testRequestGate() {
        let ok = ["host": "127.0.0.1:9191", "content-type": "application/json"]
        XCTAssertNil(gate(ok))
        XCTAssertNil(gate(["host": "localhost:9191", "content-type": "application/json; charset=utf-8"]))
        XCTAssertNil(gate(["host": "LOCALHOST:9191", "content-type": "Application/JSON"]))
        // 网页发的：带 Origin（哪怕其余都对）。
        XCTAssertEqual(gate(ok.merging(["origin": "https://evil.example"]) { $1 })?.status, "403 Forbidden")
        XCTAssertEqual(gate(ok.merging(["origin": "null"]) { $1 })?.status, "403 Forbidden")
        // DNS 重绑定：Host 是别的名字；端口不对；没有 Host。
        XCTAssertEqual(gate(["host": "evil.example:9191", "content-type": "application/json"])?.status, "403 Forbidden")
        XCTAssertEqual(gate(["host": "127.0.0.1:9192", "content-type": "application/json"])?.status, "403 Forbidden")
        XCTAssertEqual(gate(["content-type": "application/json"])?.status, "403 Forbidden")
        // no-cors 的简单请求：text/plain、表单。
        XCTAssertEqual(gate(["host": "127.0.0.1:9191", "content-type": "text/plain"])?.status, "415 Unsupported Media Type")
        XCTAssertEqual(gate(["host": "127.0.0.1:9191"])?.status, "415 Unsupported Media Type")
        // 预检和别的方法。
        XCTAssertEqual(gate(["host": "127.0.0.1:9191"], method: "OPTIONS")?.status, "405 Method Not Allowed")
        XCTAssertEqual(gate(ok, method: "GET")?.status, "405 Method Not Allowed")
    }
}
