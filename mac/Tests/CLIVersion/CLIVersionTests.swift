import Foundation
import XCTest

/// `CLIVersion`（Claude Code / Codex 助手共用的版本检查），docs/codex-assistant/DEDUPE-P2.md §2.4 类 9。
/// 本机 `--version` 用临时目录里的假 CLI 脚本真跑一遍（经 `/bin/zsh -lc`，与线上同一条路）；
/// npm 那半用 `URLProtocol` 桩替 `URLSession.shared` 回答，不真去打网络。回调回主线程：测试类标 `@MainActor`、转主 RunLoop 等。
@MainActor
final class CLIVersionTests: XCTestCase {

    // MARK: - npm 响应的解析

    func testParseNPMLatestReadsTheVersion() {
        XCTAssertEqual(CLIVersion.parseNPMLatest(Data(#"{"name":"@openai/codex","version":"0.58.0","dist":{}}"#.utf8)),
                       "0.58.0")
    }

    func testParseNPMLatestKeepsTheVersionVerbatim() {
        XCTAssertEqual(CLIVersion.parseNPMLatest(Data(#"{"version":" 1.0 "}"#.utf8)), " 1.0 ", "不去空白")
        XCTAssertEqual(CLIVersion.parseNPMLatest(Data(#"{"version":""}"#.utf8)), "", "空串也原样")
    }

    func testParseNPMLatestIsNilWithoutAStringVersion() {
        XCTAssertNil(CLIVersion.parseNPMLatest(Data(#"{"name":"x"}"#.utf8)))
        XCTAssertNil(CLIVersion.parseNPMLatest(Data(#"{"version":2}"#.utf8)))
        XCTAssertNil(CLIVersion.parseNPMLatest(Data(#"{"version":null}"#.utf8)))
        XCTAssertNil(CLIVersion.parseNPMLatest(Data(#"{"error":"Not found"}"#.utf8)))
    }

    func testParseNPMLatestIsNilForBadJSONAndNonObjects() {
        XCTAssertNil(CLIVersion.parseNPMLatest(Data()))
        XCTAssertNil(CLIVersion.parseNPMLatest(Data("<html>502 Bad Gateway</html>".utf8)))
        XCTAssertNil(CLIVersion.parseNPMLatest(Data(#"{"version":"1.0""#.utf8)), "截断的 JSON")
        XCTAssertNil(CLIVersion.parseNPMLatest(Data(#"["1.0"]"#.utf8)))
        XCTAssertNil(CLIVersion.parseNPMLatest(Data(#""1.0""#.utf8)), "顶层不是对象")
    }

    func testNPMLatestURLPutsThePackageNameInThePath() {
        XCTAssertEqual(CLIVersion.npmLatestURL(package: "@anthropic-ai/claude-code")?.absoluteString,
                       "https://registry.npmjs.org/@anthropic-ai/claude-code/latest")
        XCTAssertEqual(CLIVersion.npmLatestURL(package: "@openai/codex")?.absoluteString,
                       "https://registry.npmjs.org/@openai/codex/latest")
    }

    // MARK: - 本机 --version

    func testLocalArgumentsRunTheQuotedBinaryWithVersionInALoginShell() {
        XCTAssertEqual(CLIVersion.localArguments(binary: "/opt/homebrew/bin/claude"),
                       ["-lc", "'/opt/homebrew/bin/claude' --version"])
        XCTAssertEqual(CLIVersion.localArguments(binary: "/Users/o'neil/bin/codex"),
                       ["-lc", "'/Users/o'\\''neil/bin/codex' --version"])
        XCTAssertEqual(CLIVersion.localArguments(binary: "claude"), ["-lc", "'claude' --version"])
    }

    func testLocalReturnsTheTrimmedOutputOfVersion() throws {
        // 路径带空格和单引号：转义后照样跑得起来；脚本把收到的参数打回来，看 --version 传到了。
        let cli = try makeFakeCLI(#"printf '\n  %s (Fake CLI)  \n\n' "$@""#, directoryName: "o'neil dir")
        XCTAssertEqual(CLIVersion.local(binary: cli), "--version (Fake CLI)")
    }

    func testLocalIgnoresTheExitCodeAndStderr() throws {
        let cli = try makeFakeCLI("echo 'warning: something' >&2\necho 2.0.31\nexit 3")
        XCTAssertEqual(CLIVersion.local(binary: cli), "2.0.31")
    }

    /// stderr 丢弃（不再接一个没人读的管道）：写满 1 MB 也不会把子进程卡住（§3 第 11 条）。
    func testLocalDoesNotStallOnALotOfStderr() throws {
        let cli = try makeFakeCLI("head -c 1048576 /dev/zero >&2\necho 9.9.9")
        let result = Callback()
        DispatchQueue.global(qos: .utility).async {
            let version = CLIVersion.local(binary: cli)
            DispatchQueue.main.async { result.finish(version) }
        }
        spinMainRunLoop(timeout: 30) { result.called }
        XCTAssertEqual(result.value, "9.9.9")
    }

    func testLocalIsNilForWhitespaceOnlyOrNonUTF8Output() throws {
        XCTAssertNil(CLIVersion.local(binary: try makeFakeCLI(#"printf '  \n\t\n'"#)))
        XCTAssertNil(CLIVersion.local(binary: try makeFakeCLI(#"printf '\377\376'"#)))
        XCTAssertNil(CLIVersion.local(binary: try makeFakeCLI("exit 0")))
    }

    func testLocalIsNilWhenTheBinaryDoesNotExist() {
        XCTAssertNil(CLIVersion.local(binary: "/nonexistent-\(UUID().uuidString)/claude"))
    }

    // MARK: - npm 最新版（桩）

    func testLatestOnNPMAsksTheRegistryAndCallsBackOnTheMainThread() {
        let registry = FakeNPMRegistry.install(reply: .body(200, #"{"name":"@openai/codex","version":"0.58.0"}"#))
        addTeardownBlock { FakeNPMRegistry.uninstall() }

        let result = Callback()
        CLIVersion.latestOnNPM(package: "@openai/codex") { version in result.finish(version) }
        spinMainRunLoop { result.called }

        XCTAssertEqual(result.value, "0.58.0")
        XCTAssertEqual(result.onMainThread, true)
        let request = registry.requests.first
        XCTAssertEqual(registry.requests.count, 1)
        XCTAssertEqual(request?.url?.absoluteString, "https://registry.npmjs.org/@openai/codex/latest")
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.timeoutInterval, 10)
    }

    func testLatestOnNPMIsNilWhenTheRequestFailsOrTheBodyIsNotAVersion() {
        let replies: [FakeNPMRegistry.Reply] = [
            .failure(.notConnectedToInternet),
            .failure(.timedOut),
            .body(404, #"{"error":"Not found"}"#),
            .body(200, "<html>captive portal</html>")
        ]
        for reply in replies {
            FakeNPMRegistry.install(reply: reply)
            let result = Callback()
            CLIVersion.latestOnNPM(package: "@anthropic-ai/claude-code") { version in result.finish(version) }
            spinMainRunLoop { result.called }
            XCTAssertNil(result.value, "\(reply)")
            XCTAssertEqual(result.onMainThread, true, "\(reply)")
            FakeNPMRegistry.uninstall()
        }
    }

    /// 不看 HTTP 状态码（同原来）：响应体里有 version 就用。
    func testLatestOnNPMReadsTheBodyWhateverTheStatusCode() {
        FakeNPMRegistry.install(reply: .body(500, #"{"version":"1.2.3"}"#))
        addTeardownBlock { FakeNPMRegistry.uninstall() }
        let result = Callback()
        CLIVersion.latestOnNPM(package: "@openai/codex") { version in result.finish(version) }
        spinMainRunLoop { result.called }
        XCTAssertEqual(result.value, "1.2.3")
    }

    // MARK: - 辅助

    /// 在临时目录里写一个可执行的假 CLI（`#!/bin/sh` + body），返回它的路径。
    private func makeFakeCLI(_ body: String, directoryName: String = "bin") throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BaoboxCLIVersionTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = directory.appendingPathComponent("fake-cli")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }
}

/// 回调记下的结果。回调是 `@Sendable`：只在主线程写、主线程读（`finish` 由主线程调）。
private final class Callback: @unchecked Sendable {
    private(set) var called = false
    private(set) var value: String?
    private(set) var onMainThread: Bool?

    func finish(_ value: String?) {
        onMainThread = Thread.isMainThread
        self.value = value
        called = true
    }
}

/// 替 `URLSession.shared` 回答 registry.npmjs.org 的请求（测试期间注册），记下收到的请求。别的主机不接。
private final class FakeNPMRegistry: URLProtocol {
    enum Reply: CustomStringConvertible {
        case body(Int, String)
        case failure(URLError.Code)

        var description: String {
            switch self {
            case .body(let status, let text): return "HTTP \(status) \(text)"
            case .failure(let code): return "URLError \(code.rawValue)"
            }
        }
    }

    /// 读写都在锁里：注册在主线程，`startLoading` 在 URL 加载线程。
    private static let lock = NSLock()
    private static var reply: Reply = .failure(.notConnectedToInternet)
    private static var received: [URLRequest] = []

    /// 注册并设好这次的回答，清空记下的请求。
    @discardableResult
    static func install(reply: Reply) -> FakeNPMRegistry.Type {
        lock.lock()
        self.reply = reply
        received = []
        lock.unlock()
        URLProtocol.registerClass(FakeNPMRegistry.self)
        return self
    }

    static func uninstall() {
        URLProtocol.unregisterClass(FakeNPMRegistry.self)
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "registry.npmjs.org"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.received.append(request)
        let reply = Self.reply
        Self.lock.unlock()

        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .body(let status, let text):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
