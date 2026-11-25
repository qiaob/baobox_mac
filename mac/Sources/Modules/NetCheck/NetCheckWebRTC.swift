import AppKit
import WebKit

/// WebRTC 探测：一个 1×1 的 `WKWebView` 里建 `RTCPeerConnection`，经 STUN 收集 ICE 候选原文。
///
/// macOS 没有公开的 WebRTC API，借 WebKit 的浏览器实现 —— 要测的也正是「网页能看到什么」。
/// 做法照搬手机互传的 `RTCTransferHost`：不挂进视图层级的 WebView 可能被挂起，
/// 所以由检测窗口把 `webView` 以 1×1 放进自己的视图里。见 docs/netcheck/DESIGN.md §4.2。
@MainActor
final class NetCheckWebRTC: NSObject {
    let webView: WKWebView

    /// 文档 origin 是 https，属于安全上下文；页面本身不加载任何外部资源。
    private static let baseURL = URL(string: "https://baobox-netcheck.invalid/")
    /// 浏览器里等收集完成的上限（毫秒）。
    private static let gatherTimeoutMs = 5000

    private var loaded = false
    /// `WKWebView.navigationDelegate` 是弱引用，自己留着。
    private var loadWatcher: NetCheckLoadWatcher?
    private var waitingForLoad: [CheckedContinuation<Void, Never>] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        super.init()
        let watcher = NetCheckLoadWatcher(target: self)
        loadWatcher = watcher
        webView.navigationDelegate = watcher
        // 兜底：加载回调万一没来，别让检测一直等下去（之后的脚本调用会自己报错）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.markLoaded() }
        }
        webView.loadHTMLString("<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>",
                               baseURL: Self.baseURL)
    }

    fileprivate func markLoaded() {
        loaded = true
        let waiting = waitingForLoad
        waitingForLoad = []
        waiting.forEach { $0.resume() }
    }

    private func waitUntilLoaded() async {
        if loaded { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waitingForLoad.append(continuation)
        }
    }

    /// 页面里跑的收集脚本：收集完成（null 候选 / gathering complete）或超时就返回。
    private static let script = """
    return await new Promise((resolve) => {
      const lines = [];
      let pc = null;
      let finished = false;
      const finish = (error) => {
        if (finished) { return; }
        finished = true;
        try { if (pc) { pc.close(); } } catch (e) {}
        resolve(error ? { ok: false, error: String(error) } : { ok: true, lines: lines });
      };
      if (typeof RTCPeerConnection === "undefined") { finish("RTCPeerConnection unavailable"); return; }
      try {
        pc = new RTCPeerConnection({ iceServers: [{ urls: stun }] });
      } catch (e) { finish(e); return; }
      pc.onicecandidate = (event) => {
        if (!event.candidate) { finish(); return; }
        if (event.candidate.candidate) { lines.push(event.candidate.candidate); }
      };
      pc.onicegatheringstatechange = () => { if (pc.iceGatheringState === "complete") { finish(); } };
      pc.createDataChannel("netcheck");
      pc.createOffer().then((offer) => pc.setLocalDescription(offer)).catch((e) => finish(e));
      setTimeout(() => finish(), timeoutMs);
    });
    """

    /// 收集一次 ICE 候选。浏览器里出错返回 `.failure`；一条都没有是 `.success([])`（UDP 被挡住，不会漏）。
    func gather(stun: String) async -> Result<[String], NetCheckFailure> {
        await waitUntilLoaded()
        let arguments: [String: Any] = ["stun": stun, "timeoutMs": NSNumber(value: Self.gatherTimeoutMs)]
        let value: Any?
        do {
            value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
                webView.callAsyncJavaScript(Self.script, arguments: arguments, in: nil, in: .page) { result in
                    switch result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            return .failure(NetCheckFailure(L("netcheck.error.webrtc \(error.localizedDescription)")))
        }
        guard let dict = value as? [String: Any] else {
            return .failure(NetCheckFailure(L("netcheck.error.webrtc \("no result")")))
        }
        if let ok = dict["ok"] as? Bool, ok {
            let lines = (dict["lines"] as? [Any] ?? []).compactMap { $0 as? String }
            return .success(lines)
        }
        let why = dict["error"] as? String ?? "unknown"
        return .failure(NetCheckFailure(L("netcheck.error.webrtc \(why)")))
    }

    func stop() {
        webView.stopLoading()
        webView.removeFromSuperview()
    }
}

/// 页面加载完成的回调（弱引用目标，照 `RTCTransferHost` 的 `WeakScriptHandler`）。
@MainActor
private final class NetCheckLoadWatcher: NSObject, WKNavigationDelegate {
    weak var target: NetCheckWebRTC?

    init(target: NetCheckWebRTC) {
        self.target = target
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        target?.markLoaded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        target?.markLoaded()
    }
}
