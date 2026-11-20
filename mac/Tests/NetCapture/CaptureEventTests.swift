import Foundation
import XCTest

/// 网络抓包的纯逻辑：引擎事件怎么解、行怎么切、指令怎么编、解密范围怎么从设置得来
/// （docs/packet-capture/TECH_DESIGN.md §4）。事件样本取自真引擎（mitmproxy 12.3.1）的实际输出。
final class CaptureEventTests: XCTestCase {

    private func line(_ json: String) -> Data { Data(("BAOBOX " + json).utf8) }

    // MARK: - 事件解码

    func testRunning() {
        XCTAssertEqual(CaptureEvent.parse(line: line(#"{"event":"running","version":"12.3.1"}"#)),
                       .running(version: "12.3.1"))
    }

    func testRequest() throws {
        let event = CaptureEvent.parse(line: line("""
        {"event":"request","id":"9b80df6e-85cc-4743-9198-58c843904676","client":"127.0.0.1","method":"POST",\
        "scheme":"https","host":"httpbin.org","port":443,"path":"/post","http":"HTTP/2.0",\
        "headers":[["content-type","application/json"],["x-a","1"],["x-a","2"]],"body":"eyJhIjoxfQ==",\
        "truncated":false,"bytes":7,"ts":1795191546.25}
        """))
        guard case .request(let request)? = event else { return XCTFail("not a request: \(String(describing: event))") }
        XCTAssertEqual(request.id, UUID(uuidString: "9B80DF6E-85CC-4743-9198-58C843904676"))
        XCTAssertEqual(request.client, "127.0.0.1")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.host, "httpbin.org")
        XCTAssertEqual(request.port, 443)
        XCTAssertEqual(request.path, "/post")
        XCTAssertEqual(request.httpVersion, "HTTP/2.0")
        // 同名的头保留多条、保留顺序。
        XCTAssertEqual(request.headers, [HTTPHeader(name: "content-type", value: "application/json"),
                                         HTTPHeader(name: "x-a", value: "1"), HTTPHeader(name: "x-a", value: "2")])
        XCTAssertEqual(request.body, Data(#"{"a":1}"#.utf8))
        XCTAssertFalse(request.truncated)
        XCTAssertEqual(request.bytes, 7)
        XCTAssertEqual(request.startedAt.timeIntervalSince1970, 1795191546.25, accuracy: 0.001)
    }

    func testRequestFillsDefaultsForMissingOptionalFields() throws {
        let event = CaptureEvent.parse(line: line(
            #"{"event":"request","id":"9b80df6e-85cc-4743-9198-58c843904676","method":"GET","host":"x.com","scheme":"http","body":null}"#))
        guard case .request(let request)? = event else { return XCTFail("not a request") }
        XCTAssertEqual(request.port, 80)
        XCTAssertEqual(request.path, "/")
        XCTAssertEqual(request.httpVersion, "HTTP/1.1")
        XCTAssertNil(request.client)
        XCTAssertNil(request.body)
        XCTAssertTrue(request.headers.isEmpty)
    }

    func testResponse() throws {
        let event = CaptureEvent.parse(line: line("""
        {"event":"response","id":"9b80df6e-85cc-4743-9198-58c843904676","status":200,"http":"HTTP/2.0",\
        "headers":[["content-type","text/html"]],"body":"aGk=","truncated":false,"encoding":"gzip",\
        "bytes":400,"remote":"104.20.23.154","ts":1795191540.5}
        """))
        guard case .response(let response)? = event else { return XCTFail("not a response") }
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, Data("hi".utf8))
        XCTAssertEqual(response.encoding, "gzip")
        XCTAssertEqual(response.bytes, 400)
        XCTAssertEqual(response.remote, "104.20.23.154")
        XCTAssertNotNil(response.endedAt)
    }

    /// 超过上限、被引擎直接流过去的正文：没有内容，标了截断。
    func testStreamedResponseHasNoBodyAndIsTruncated() throws {
        let event = CaptureEvent.parse(line: line(
            #"{"event":"response","id":"4c99e286-be4b-4e90-ac94-f0a4271d0cc3","status":200,"http":"HTTP/1.1","headers":[],"body":null,"truncated":true,"encoding":null,"bytes":7000000,"remote":"172.66.0.218","ts":1795191558.2}"#))
        guard case .response(let response)? = event else { return XCTFail("not a response") }
        XCTAssertNil(response.body)
        XCTAssertTrue(response.truncated)
        XCTAssertNil(response.encoding)
        XCTAssertEqual(response.bytes, 7_000_000)
    }

    func testTLSDeviceErrorAndWebSocket() {
        XCTAssertEqual(
            CaptureEvent.parse(line: line(#"{"event":"tls","client":"192.168.0.9","host":"www.wikipedia.org","reason":"handshake_failed"}"#)),
            .tls(client: "192.168.0.9", host: "www.wikipedia.org", reason: .handshakeFailed))
        XCTAssertEqual(
            CaptureEvent.parse(line: line(#"{"event":"tls","client":"127.0.0.1","host":"example.com","reason":"out_of_scope"}"#)),
            .tls(client: "127.0.0.1", host: "example.com", reason: .outOfScope))
        XCTAssertEqual(CaptureEvent.parse(line: line(#"{"event":"device","client":"192.168.0.9"}"#)),
                       .device(client: "192.168.0.9"))

        let id = UUID(uuidString: "9B80DF6E-85CC-4743-9198-58C843904676")
        XCTAssertEqual(
            CaptureEvent.parse(line: line(#"{"event":"error","id":"9b80df6e-85cc-4743-9198-58c843904676","message":"connection reset"}"#)),
            id.map { .failure(id: $0, message: "connection reset", at: nil) })

        let text = CaptureEvent.parse(line: line(
            #"{"event":"ws","id":"9b80df6e-85cc-4743-9198-58c843904676","from_client":true,"size":5,"ts":1795191558.0,"text":"hello"}"#))
        guard case .webSocket(let message)? = text else { return XCTFail("not a ws message") }
        XCTAssertTrue(message.fromClient)
        XCTAssertEqual(message.text, "hello")
        XCTAssertEqual(message.size, 5)

        let binary = CaptureEvent.parse(line: line(
            #"{"event":"ws","id":"9b80df6e-85cc-4743-9198-58c843904676","from_client":false,"size":128,"ts":1795191558.0}"#))
        guard case .webSocket(let frame)? = binary else { return XCTFail("not a ws message") }
        XCTAssertNil(frame.text)
        XCTAssertEqual(frame.size, 128)
    }

    /// 解不出来的行一律返回 nil（跳过），不崩。
    func testMalformedLinesAreSkipped() {
        let bad = [
            #"{"event":"running"}"#,                                   // 没有前缀
            "BAOBOX not json",
            "BAOBOX [1,2,3]",
            #"BAOBOX {"event":"nope"}"#,
            #"BAOBOX {"event":"request","id":"not-a-uuid","method":"GET","host":"x.com"}"#,
            #"BAOBOX {"event":"request","id":"9b80df6e-85cc-4743-9198-58c843904676","host":"x.com"}"#,        // 缺 method
            #"BAOBOX {"event":"response","id":"9b80df6e-85cc-4743-9198-58c843904676","status":"200"}"#,       // status 不是数字
            #"BAOBOX {"event":"response","id":"9b80df6e-85cc-4743-9198-58c843904676","status":true}"#,        // Bool 不算数字
            #"BAOBOX {"event":"tls","host":"x.com","reason":"because"}"#,
            #"BAOBOX {"event":"device","client":""}"#,
            "[00:21:39.285] [Errno 48] HTTP(S) proxy failed to listen",  // 引擎自己的日志
            "",
        ]
        for text in bad {
            XCTAssertNil(CaptureEvent.parse(line: Data(text.utf8)), text)
        }
    }

    func testOddHeaderShapesAreDropped() throws {
        let event = CaptureEvent.parse(line: line(
            #"{"event":"request","id":"9b80df6e-85cc-4743-9198-58c843904676","method":"GET","host":"x.com","headers":[["a","1"],["only-name"],"junk",["b",2],["c","3"]]}"#))
        guard case .request(let request)? = event else { return XCTFail("not a request") }
        XCTAssertEqual(request.headers.map(\.name), ["a", "c"])
        XCTAssertEqual(request.headers.value(for: "C"), "3")
    }

    // MARK: - 切行

    func testLineBufferHandlesSplitAndJoinedChunks() {
        var buffer = CaptureLineBuffer()
        XCTAssertEqual(buffer.append(Data("BAOBOX {\"a\"".utf8)), [])
        XCTAssertEqual(buffer.append(Data(":1}\nBAOBOX {}\nBAO".utf8)),
                       [Data("BAOBOX {\"a\":1}".utf8), Data("BAOBOX {}".utf8)])
        XCTAssertEqual(buffer.append(Data()), [])
        XCTAssertEqual(buffer.append(Data("BOX x\n".utf8)), [Data("BAOBOX x".utf8)])
        XCTAssertEqual(buffer.append(Data("\n\n".utf8)), [Data(), Data()])
    }

    /// 一行可以有几 MB（正文是 base64 放在行里的），分很多段到。
    func testLineBufferReassemblesALargeLine() {
        var buffer = CaptureLineBuffer()
        let payload = Data(repeating: 0x41, count: 3 * 1024 * 1024)
        var collected: [Data] = []
        var offset = 0
        while offset < payload.count {
            let end = min(offset + 64 * 1024, payload.count)
            collected += buffer.append(payload.subdata(in: offset..<end))
            offset = end
        }
        XCTAssertTrue(collected.isEmpty)
        collected += buffer.append(Data([0x0A]))
        XCTAssertEqual(collected.count, 1)
        XCTAssertEqual(collected.first?.count, payload.count)
    }

    // MARK: - 指令与解密范围

    private func object(_ command: CaptureCommand) throws -> [String: Any] {
        let data = command.line
        XCTAssertEqual(data.last, 0x0A, "a command is exactly one line")
        XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCommandLines() throws {
        XCTAssertEqual(try object(.shutdown)["cmd"] as? String, "shutdown")

        let scope = try object(.scope(DecryptScope(mode: .allow, domains: ["x.com", "y.org"])))
        XCTAssertEqual(scope["cmd"] as? String, "scope")
        XCTAssertEqual(scope["mode"] as? String, "allow")
        XCTAssertEqual(scope["domains"] as? [String], ["x.com", "y.org"])

        let allow = try object(.allowDevice("192.168.0.9"))
        XCTAssertEqual(allow["cmd"] as? String, "allow_device")
        XCTAssertEqual(allow["client"] as? String, "192.168.0.9")
        XCTAssertEqual(try object(.denyDevice("192.168.0.9"))["cmd"] as? String, "deny_device")
    }

    func testParseDomains() {
        XCTAssertEqual(DecryptScope.parseDomains("x.com\n*.Api.Example.com, https://y.org/path?q=1\n\n z.dev:8443 x.com ."),
                       ["x.com", "api.example.com", "y.org", "z.dev"])
        XCTAssertEqual(DecryptScope.parseDomains("  \n,, "), [])
    }

    func testScopeFromSettings() {
        XCTAssertEqual(DecryptScope.from(setting: "all", allowText: "x.com", denyText: ""), .all)
        XCTAssertEqual(DecryptScope.from(setting: "all", allowText: "x.com", denyText: "bank.com\n"),
                       DecryptScope(mode: .deny, domains: ["bank.com"]))
        XCTAssertEqual(DecryptScope.from(setting: "allowlist", allowText: "x.com", denyText: "bank.com"),
                       DecryptScope(mode: .allow, domains: ["x.com"]))
        // 名单空着的「只解密这些」= 什么都不解密，照字面来，不悄悄改成全部。
        XCTAssertEqual(DecryptScope.from(setting: "allowlist", allowText: "", denyText: ""),
                       DecryptScope(mode: .allow, domains: []))
        // 认不得的值按「全部」。
        XCTAssertEqual(DecryptScope.from(setting: "", allowText: "", denyText: ""), .all)
    }

    func testScopeJSONIsWhatTheBridgeReads() throws {
        let json = DecryptScope(mode: .deny, domains: ["bank.com"]).json
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["mode"] as? String, "deny")
        XCTAssertEqual(object["domains"] as? [String], ["bank.com"])
    }

    // MARK: - 终端的环境变量

    func testShellEnvLines() {
        let lines = CaptureShellEnv.exportLines(port: 9090,
                                                bundlePath: "/Users/me/Library/Application Support/Baobox/NetCapture/ca-bundle.pem",
                                                caPath: "/Users/o'brien/ca.pem")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "export HTTP_PROXY=http://127.0.0.1:9090 HTTPS_PROXY=http://127.0.0.1:9090 "
            + "http_proxy=http://127.0.0.1:9090 https_proxy=http://127.0.0.1:9090")
        // 路径里有空格：必须加引号。
        XCTAssertTrue(lines[1].contains("SSL_CERT_FILE='/Users/me/Library/Application Support/Baobox/NetCapture/ca-bundle.pem'"))
        XCTAssertTrue(lines[1].contains("REQUESTS_CA_BUNDLE='"))
        XCTAssertTrue(lines[1].contains("CURL_CA_BUNDLE='"))
        // 路径里有单引号：转义。
        XCTAssertEqual(lines[2], #"export NODE_EXTRA_CA_CERTS='/Users/o'\''brien/ca.pem'"#)
    }
}
