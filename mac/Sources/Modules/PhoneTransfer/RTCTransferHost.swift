import AppKit
import WebKit

/// 公网模式的宿主：一个 1×1 的 `WKWebView` 跑 `host.html` + `rtc.js`（加密信令 + WebRTC），
/// Swift 这边只做文件读写与界面。桥接协议见 docs/phone-transfer/TECH_DESIGN.md §4.7。
///
/// macOS 没有公开的 WebRTC API，借 WebKit 的浏览器级实现；不挂进视图层级的 WebView 可能被挂起，
/// 所以由传输窗口把 `webView` 以 1×1 尺寸放进自己的视图里。
@MainActor
final class RTCTransferHost: NSObject {
    let webView: WKWebView
    /// JS 发来的消息（已在主线程）。
    var onMessage: (([String: Any]) -> Void)?

    private static let messageName = "pt"
    /// 文档 origin 是 https，属于安全上下文，`crypto.subtle` 才可用；页面本身不加载任何外部资源。
    private static let baseURL = URL(string: "https://baobox-host.invalid/")

    override init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        super.init()
        controller.add(WeakScriptHandler(target: self), name: Self.messageName)
    }

    /// 读包内的 host.html，把 rtc.js 内联进占位符后加载。资源缺失返回 false。
    func load() -> Bool {
        guard let root = Bundle.main.url(forResource: "PhoneTransfer", withExtension: nil),
              let html = try? String(contentsOf: root.appendingPathComponent("host.html"), encoding: .utf8),
              let rtc = try? String(contentsOf: root.appendingPathComponent("rtc.js"), encoding: .utf8) else {
            return false
        }
        let page = html.replacingOccurrences(of: "/*__RTC_JS__*/", with: rtc)
        webView.loadHTMLString(page, baseURL: Self.baseURL)
        return true
    }

    fileprivate func receive(_ body: Any) {
        guard let dict = body as? [String: Any] else { return }
        onMessage?(dict)
    }

    /// 调宿主页里的函数。函数体必须 `return` 一个值（返回 undefined 时部分 SDK 的桥接会出问题）。
    @discardableResult
    func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start(sid: String, key: String, since: Int, macName: String) {
        let cfg: [String: Any] = ["sid": sid, "key": key, "since": since, "macName": macName]
        Task { @MainActor in
            _ = try? await self.call("await ptHost.start(cfg); return true;", ["cfg": cfg])
        }
    }

    func approve(_ ok: Bool) {
        Task { @MainActor in
            _ = try? await self.call("await ptHost.approve(ok); return true;", ["ok": ok])
        }
    }

    func sendText(_ text: String) async throws {
        try await call("return ptHost.sendText(text);", ["text": text])
    }

    /// 发一个文件：Swift 每次读 256KB 交给 JS，JS 切成 16KB 走 DataChannel；
    /// `sendChunk` 的 Promise 在发送缓冲回落后才 resolve，天然背压。
    func sendFile(id: String, url: URL, name: String, size: Int64, progress: (Int64) -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try await call("return ptHost.beginFile(id, name, size, mime);",
                       ["id": id, "name": name, "size": NSNumber(value: size), "mime": ""])
        var sent: Int64 = 0
        do {
            while true {
                let data = try handle.read(upToCount: 256 * 1024) ?? Data()
                if data.isEmpty { break }
                try await call("return await ptHost.sendChunk(b64);", ["b64": data.base64EncodedString()])
                sent += Int64(data.count)
                progress(sent)
            }
            try await call("return ptHost.endFile(id);", ["id": id])
        } catch {
            _ = try? await call("return ptHost.cancelFile(id);", ["id": id])
            throw error
        }
    }

    func stop() {
        onMessage = nil
        webView.evaluateJavaScript("window.ptHost && window.ptHost.stop(); true;", completionHandler: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
        webView.stopLoading()
        webView.removeFromSuperview()
    }
}

/// `WKUserContentController.add` 会强引用 handler，用弱代理断开循环引用。
@MainActor
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: RTCTransferHost?

    init(target: RTCTransferHost) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.receive(message.body)
    }
}
