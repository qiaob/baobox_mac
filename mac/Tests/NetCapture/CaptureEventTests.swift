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
            .tls(client: "192.168.0.9", wireguard: nil, host: "www.wikipedia.org", reason: .handshakeFailed))
        XCTAssertEqual(
            CaptureEvent.parse(line: line(#"{"event":"tls","client":"127.0.0.1","host":"example.com","reason":"out_of_scope"}"#)),
            .tls(client: "127.0.0.1", wireguard: nil, host: "example.com", reason: .outOfScope))
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

    /// 头里没声明的压缩由桥脚本认出来解开，事件里带上压缩方式的名字；没有这回事时是 nil。
    func testSniffedCompressionName() throws {
        let request = CaptureEvent.parse(line: line(
            #"{"event":"request","id":"9b80df6e-85cc-4743-9198-58c843904676","method":"POST","host":"x.com","body":"e30=","sniffed":"gzip"}"#))
        guard case .request(let sniffed)? = request else { return XCTFail("not a request") }
        XCTAssertEqual(sniffed.sniffed, "gzip")
        XCTAssertEqual(sniffed.body, Data("{}".utf8))

        let response = CaptureEvent.parse(line: line(
            #"{"event":"response","id":"9b80df6e-85cc-4743-9198-58c843904676","status":200,"sniffed":null,"encoding":"br"}"#))
        guard case .response(let plain)? = response else { return XCTFail("not a response") }
        XCTAssertNil(plain.sniffed)
        XCTAssertEqual(plain.encoding, "br")
    }

    // MARK: - 重发 / Mock / 解码（docs/packet-capture/TOOLS.md §6）

    func testReplayedRequestWithDecodedBody() throws {
        let event = CaptureEvent.parse(line: line("""
        {"event":"request","id":"5f0c1a52-3b55-4a5e-9d1f-0e8b7f1c2a33","client":"127.0.0.1","replay":true,\
        "decoded":{"view":"Protobuf","text":"1: 150  # !sint: 75\\n2: testing\\n"},"method":"POST","scheme":"http",\
        "host":"127.0.0.1","port":19620,"path":"/proto","http":"HTTP/1.1",\
        "headers":[["content-type","application/x-protobuf"]],"body":"CJYBEgd0ZXN0aW5n","truncated":false,\
        "sniffed":null,"bytes":11,"ts":1795200000.5}
        """))
        guard case .request(let request)? = event else { return XCTFail("not a request") }
        XCTAssertTrue(request.isReplay)
        // 文本取自真引擎（mitmproxy 12.3.1）对同一段 protobuf 的输出：只有字段编号，带它自己的 `# !sint` 注释。
        XCTAssertEqual(request.decoded, DecodedBody(view: "Protobuf", text: "1: 150  # !sint: 75\n2: testing\n"))
        XCTAssertEqual(request.body?.count, 12)
    }

    func testMockedResponseWithDecodedBody() throws {
        let event = CaptureEvent.parse(line: line("""
        {"event":"response","id":"5f0c1a52-3b55-4a5e-9d1f-0e8b7f1c2a33","status":418,\
        "mock":"0c6f4a0e-1d0e-4f8a-9b3c-5a6b7c8d9e0f","decoded":{"view":"MsgPack","text":"a: 1\\nb: x\\n"},\
        "http":"HTTP/1.1","headers":[["x-mock","yes"]],"body":"aGk=","truncated":false,"sniffed":null,\
        "encoding":null,"bytes":2,"remote":null,"ts":1795200001.0}
        """))
        guard case .response(let response)? = event else { return XCTFail("not a response") }
        XCTAssertEqual(response.status, 418)
        XCTAssertEqual(response.mockRuleID, "0c6f4a0e-1d0e-4f8a-9b3c-5a6b7c8d9e0f")
        XCTAssertEqual(response.decoded?.view, "MsgPack")
        XCTAssertEqual(response.decoded?.text, "a: 1\nb: x\n")
        XCTAssertNil(response.remote)
    }

    /// 新字段缺失、是 null 或形状不对：一律按「没有」，整条事件照常解出来。
    func testNewFieldsDefaultToAbsent() throws {
        let requests = [
            #"{"event":"request","id":"5f0c1a52-3b55-4a5e-9d1f-0e8b7f1c2a33","method":"GET","host":"x.com"}"#,
            #"{"event":"request","id":"5f0c1a52-3b55-4a5e-9d1f-0e8b7f1c2a33","method":"GET","host":"x.com","replay":null,"decoded":null}"#,
            #"{"event":"request","id":"5f0c1a52-3b55-4a5e-9d1f-0e8b7f1c2a33","method":"GET","host":"x.com","replay":"yes","decoded":"1: 2"}"#,
            #"{"event":"request","id":"5f0c1a52-3b55-4a5e-9d1f-0e8b7f1c2a33","method":"GET","host":"x.com","decoded":{"view":"Protobuf","text":""}}"#,
        ]
        for text in requests {
            guard case .request(let request)? = CaptureEvent.parse(line: line(text)) else { return XCTFail(text) }
            XCTAssertFalse(request.isReplay, text)
            XCTAssertNil(request.decoded, text)
        }
        let responses = [
            #"{"event":"response","id":"5f0c1a52-3b55-4a5e-9d1f-0e8b7f1c2a33","status":200}"#,
            #"{"event":"response","id":"5f0c1a52-3b55-4a5e-9d1f-0e8b7f1c2a33","status":200,"mock":null,"decoded":null}"#,
            #"{"event":"response","id":"5f0c1a52-3b55-4a5e-9d1f-0e8b7f1c2a33","status":200,"mock":"","decoded":[1]}"#,
            #"{"event":"response","id":"5f0c1a52-3b55-4a5e-9d1f-0e8b7f1c2a33","status":200,"mock":7}"#,
        ]
        for text in responses {
            guard case .response(let response)? = CaptureEvent.parse(line: line(text)) else { return XCTFail(text) }
            XCTAssertNil(response.mockRuleID, text)
            XCTAssertNil(response.decoded, text)
        }
        // 只有文本没有视图名：照样算解码了。
        guard case .response(let unnamed)? = CaptureEvent.parse(line: line(
            #"{"event":"response","id":"5f0c1a52-3b55-4a5e-9d1f-0e8b7f1c2a33","status":200,"decoded":{"text":"1: 2"}}"#))
        else { return XCTFail("not a response") }
        XCTAssertEqual(unnamed.decoded, DecodedBody(view: "", text: "1: 2"))
    }

    func testReplayFailed() {
        XCTAssertEqual(
            CaptureEvent.parse(line: line(#"{"event":"replay_failed","id":"5f0c1a52-3b55-4a5e-9d1f-0e8b7f1c2a33","message":"Invalid URL"}"#)),
            .replayFailed(id: UUID(uuidString: "5F0C1A52-3B55-4A5E-9D1F-0E8B7F1C2A33"), message: "Invalid URL"))
        // 指令里没给 id 时引擎回 null：事件照样解出来，好让界面说明原因。
        XCTAssertEqual(CaptureEvent.parse(line: line(#"{"event":"replay_failed","id":null,"message":"'url'"}"#)),
                       .replayFailed(id: nil, message: "'url'"))
        XCTAssertEqual(CaptureEvent.parse(line: line(#"{"event":"replay_failed"}"#)),
                       .replayFailed(id: nil, message: ""))
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

    func testReplayCommand() throws {
        let id = try XCTUnwrap(UUID(uuidString: "5F0C1A52-3B55-4A5E-9D1F-0E8B7F1C2A33"))
        let replay = try object(.replay(ReplayRequest(
            id: id, method: "POST", url: "https://api.x.com/v1/login?debug=1",
            headers: [HTTPHeader(name: "content-type", value: "application/json"),
                      HTTPHeader(name: "x-a", value: "1"), HTTPHeader(name: "x-a", value: "2")],
            body: Data(#"{"email":"a@x.com"}"#.utf8))))
        XCTAssertEqual(replay["cmd"] as? String, "replay")
        // 小写：引擎拿它当 flow id，事件里原样回来，`UUID(uuidString:)` 不分大小写都认。
        XCTAssertEqual(replay["id"] as? String, "5f0c1a52-3b55-4a5e-9d1f-0e8b7f1c2a33")
        XCTAssertEqual(replay["method"] as? String, "POST")
        XCTAssertEqual(replay["url"] as? String, "https://api.x.com/v1/login?debug=1")
        XCTAssertEqual(replay["headers"] as? [[String]],
                       [["content-type", "application/json"], ["x-a", "1"], ["x-a", "2"]])
        let body = try XCTUnwrap(replay["body"] as? String)
        XCTAssertEqual(Data(base64Encoded: body), Data(#"{"email":"a@x.com"}"#.utf8))

        // 没有正文：body 是 null（桥脚本按「没有」处理）。
        let empty = try object(.replay(ReplayRequest(id: id, method: "GET", url: "http://x.com/", headers: [], body: nil)))
        XCTAssertTrue(empty["body"] is NSNull)
        XCTAssertEqual(empty["headers"] as? [[String]], [])
        let zeroLength = try object(.replay(ReplayRequest(id: id, method: "GET", url: "http://x.com/", headers: [], body: Data())))
        XCTAssertTrue(zeroLength["body"] is NSNull)
    }

    func testRulesCommand() throws {
        let rules = [
            MockRule(id: "r1", enabled: true, method: "GET", host: "api.x.com", path: "/v1/user/*", status: 418,
                     headers: [HTTPHeader(name: "content-type", value: "application/json")],
                     body: Data(#"{"id":1}"#.utf8)),
            MockRule(id: "r2", enabled: false, method: "*", host: "cdn.x.com", path: "/", status: 204),
        ]
        let command = try object(.rules(rules))
        XCTAssertEqual(command["cmd"] as? String, "rules")
        let items = try XCTUnwrap(command["rules"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2, "停用的规则也发，引擎自己跳过")
        XCTAssertEqual(items[0]["id"] as? String, "r1")
        XCTAssertEqual(items[0]["enabled"] as? Bool, true)
        XCTAssertEqual(items[0]["method"] as? String, "GET")
        XCTAssertEqual(items[0]["host"] as? String, "api.x.com")
        XCTAssertEqual(items[0]["path"] as? String, "/v1/user/*")
        XCTAssertEqual(items[0]["status"] as? Int, 418)
        XCTAssertEqual(items[0]["headers"] as? [[String]], [["content-type", "application/json"]])
        XCTAssertEqual((items[0]["body"] as? String).flatMap { Data(base64Encoded: $0) }, Data(#"{"id":1}"#.utf8))
        XCTAssertEqual(items[1]["enabled"] as? Bool, false)
        XCTAssertEqual(items[1]["method"] as? String, "*")
        XCTAssertEqual(items[1]["body"] as? String, "")
        // 空表也要发：引擎据此清掉旧规则、恢复走真实服务器。
        XCTAssertEqual((try object(.rules([])))["rules"] as? [String], [])
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

    // MARK: - 引擎日志

    func testBusyPortFromEngineError() {
        let real = "[00:21:39.285] [Errno 48] HTTP(S) proxy failed to listen on 127.0.0.1:19412 with [Errno 48] error while attempting to bind on address ('127.0.0.1', 19412): [errno 48] address already in use"
        XCTAssertEqual(CaptureEngineLog.busyPort(in: real), 19412)
        XCTAssertEqual(CaptureEngineLog.busyPort(in: "SOCKS v5 proxy failed to listen on 127.0.0.1:9092 with [Errno 48]"), 9092)
        XCTAssertEqual(CaptureEngineLog.busyPort(in: "proxy failed to listen on *:9090 with …"), 9090)
        XCTAssertNil(CaptureEngineLog.busyPort(in: "Error logged during startup, exiting..."))
        XCTAssertNil(CaptureEngineLog.busyPort(in: "failed to listen on somewhere"))
        XCTAssertNil(CaptureEngineLog.busyPort(in: "failed to listen on 127.0.0.1:notaport"))
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

/// 「配置 / HTTP / TCP」一批加的事件与指令（docs/packet-capture/CONTROL.md §2、§4、§5）。
/// 事件样本取自真引擎（mitmproxy 12.3.1）经 SOCKS 转发原始 TCP 时桥的实际输出。
final class CaptureControlEventTests: XCTestCase {

    private func line(_ json: String) -> Data { Data(("BAOBOX " + json).utf8) }
    private let id = "be704a7c-d720-4793-9f07-39bd4f54a61f"

    func testTCPOpen() {
        let event = CaptureEvent.parse(line: line(
            #"{"event":"tcp_open","id":"\#(id)","client":"127.0.0.1","host":"127.0.0.1","port":19660,"sni":null,"ts":1795191546.5}"#))
        XCTAssertEqual(event, .tcpOpen(CaptureEvent.TCPOpen(
            id: UUID(uuidString: id) ?? UUID(), client: "127.0.0.1", host: "127.0.0.1", port: 19660, sni: nil,
            startedAt: Date(timeIntervalSince1970: 1795191546.5))))
    }

    func testTCPOpenEmptySNIIsNil() {
        guard case .tcpOpen(let open)? = CaptureEvent.parse(line: line(
            #"{"event":"tcp_open","id":"\#(id)","host":"10.1.2.3","port":5222,"sni":""}"#)) else { return XCTFail() }
        XCTAssertNil(open.sni)
        XCTAssertNil(open.client)
    }

    func testTCPData() {
        guard case .tcpData(let data)? = CaptureEvent.parse(line: line(
            #"{"event":"tcp_data","id":"\#(id)","from_client":false,"size":28,"data":"MjIwIHJlYWR5DQo=","truncated":false,"ts":1795191547}"#))
        else { return XCTFail() }
        XCTAssertFalse(data.fromClient)
        XCTAssertEqual(data.size, 28)
        XCTAssertEqual(data.data, Data("220 ready\r\n".utf8))
        XCTAssertFalse(data.truncated)
    }

    /// 超过正文上限后只有大小、没有数据。
    func testTCPDataSizeOnly() {
        guard case .tcpData(let data)? = CaptureEvent.parse(line: line(
            #"{"event":"tcp_data","id":"\#(id)","from_client":true,"size":70000,"truncated":false}"#))
        else { return XCTFail() }
        XCTAssertNil(data.data)
        XCTAssertEqual(data.size, 70000)
    }

    func testTCPDataNeedsDirection() {
        XCTAssertNil(CaptureEvent.parse(line: line(#"{"event":"tcp_data","id":"\#(id)","size":3}"#)))
    }

    func testTCPClose() {
        XCTAssertEqual(CaptureEvent.parse(line: line(#"{"event":"tcp_close","id":"\#(id)","error":null,"ts":1795191550}"#)),
                       .tcpClose(id: UUID(uuidString: id) ?? UUID(), error: nil, at: Date(timeIntervalSince1970: 1795191550)))
        guard case .tcpClose(_, let error, _)? = CaptureEvent.parse(line: line(
            #"{"event":"tcp_close","id":"\#(id)","error":"Connection reset by peer"}"#)) else { return XCTFail() }
        XCTAssertEqual(error, "Connection reset by peer")
    }

    func testDecryptOffReason() {
        XCTAssertEqual(CaptureEvent.parse(line: line(#"{"event":"tls","client":"10.0.0.1","host":"x.com","reason":"decrypt_off"}"#)),
                       .tls(client: "10.0.0.1", wireguard: nil, host: "x.com", reason: .decryptOff))
    }

    func testNewCommands() {
        func text(_ command: CaptureCommand) -> String { String(decoding: command.line, as: UTF8.self) }
        XCTAssertEqual(text(.record(false)), "{\"cmd\":\"record\",\"on\":false}\n")
        XCTAssertEqual(text(.lanProxy(true)), "{\"cmd\":\"lan_proxy\",\"on\":true}\n")
        XCTAssertEqual(text(.macTCP(true)), "{\"cmd\":\"mac_tcp\",\"on\":true}\n")
        XCTAssertEqual(text(.pagePort(9091)), "{\"cmd\":\"page_port\",\"port\":9091}\n")
        XCTAssertEqual(text(.scope(.off)), "{\"cmd\":\"scope\",\"domains\":[],\"mode\":\"none\"}\n")
        XCTAssertEqual(DecryptScope.off.json, #"{"domains":[],"mode":"none"}"#)
    }
}

/// WireGuard 多台设备：桥在经隧道来的事件上多带一个 `"wg": "<设备 id>"`（docs/packet-capture/WIREGUARD-DEVICES.md §4）。
final class WireGuardDeviceEventTests: XCTestCase {

    private func line(_ json: String) -> Data { Data(("BAOBOX " + json).utf8) }
    private let wg = "6f1c2a9e-0b7d-4c55-9a3e-2f8d1e4b7c60"
    private let id = "be704a7c-d720-4793-9f07-39bd4f54a61f"

    func testRequestTLSAndTCPOpenCarryTheDevice() throws {
        guard case .request(let request)? = CaptureEvent.parse(line: line(
            #"{"event":"request","id":"\#(id)","client":"10.0.0.1","wg":"\#(wg)","method":"GET","host":"example.com"}"#))
        else { return XCTFail("not a request") }
        XCTAssertEqual(request.client, "10.0.0.1")
        XCTAssertEqual(request.wireguard, wg)

        XCTAssertEqual(CaptureEvent.parse(line: line(
            #"{"event":"tls","client":"10.0.0.1","wg":"\#(wg)","host":"x.com","reason":"handshake_failed"}"#)),
                       .tls(client: "10.0.0.1", wireguard: wg, host: "x.com", reason: .handshakeFailed))

        guard case .tcpOpen(let open)? = CaptureEvent.parse(line: line(
            #"{"event":"tcp_open","id":"\#(id)","client":"10.0.0.1","wg":"\#(wg)","host":"139.95.11.88","port":5222}"#))
        else { return XCTFail("not a tcp_open") }
        XCTAssertEqual(open.wireguard, wg)
    }

    /// 不是隧道来的不带 `wg`；带了个不像设备 id 的（不是小写 UUID）当作没有。
    func testMissingOrOddDeviceIsNil() throws {
        guard case .request(let plain)? = CaptureEvent.parse(line: line(
            #"{"event":"request","id":"\#(id)","client":"192.168.0.23","method":"GET","host":"example.com"}"#))
        else { return XCTFail() }
        XCTAssertNil(plain.wireguard)
        for odd in [#""../../etc""#, #""6F1C2A9E-0B7D-4C55-9A3E-2F8D1E4B7C60""#, "42", "null", #""""#] {
            guard case .tcpOpen(let open)? = CaptureEvent.parse(line: line(
                #"{"event":"tcp_open","id":"\#(id)","wg":\#(odd),"host":"1.2.3.4","port":1}"#))
            else { return XCTFail(odd) }
            XCTAssertNil(open.wireguard, odd)
        }
    }
}
