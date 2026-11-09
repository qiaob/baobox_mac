import Foundation

/// AI 润色（需求 §4.4、技术设计 §4）：把口语整理成书面语。用「AI 润色」这个功能选的模型（出厂本地 Qwen3，与实时翻译的纠错同一个；
/// 也可以选云端模型，docs/ai-service/DESIGN.md §5.4）。提示词与结果把关在 `DictationTextProcessor`。最多等 8 秒，超时 / 出错 / 结果不可信都上原文。
@MainActor
enum DictationPolisher {
    /// 这次走哪个模型。
    private static var route: AIRoute { AIService.shared.route(for: .dictationPolish) }

    /// 预热时有没有让本地模型常驻（`coolDown` 只放自己占的那一份，中途改了设置也配得上对）。
    private static var keepsLocalWarm = false

    /// 能润色：走本地 = 模型已下载、推理进程已打包；走云端 = 模型配置完整。
    static var isReady: Bool { AIService.shared.isReady(route, local: .generation) }

    /// 开始听写就预热（加载模型要几秒），结束时 `coolDown` 配对。走云端时不加载本地模型。
    static func warmUp() {
        guard route == .local, !keepsLocalWarm else { return }
        keepsLocalWarm = true
        AIService.shared.beginLocalKeepAlive(.generation)
    }

    static func coolDown() {
        guard keepsLocalWarm else { return }
        keepsLocalWarm = false
        AIService.shared.endLocalKeepAlive(.generation)
    }

    /// 润色结果；nil = 用原文（太短、模型不可用、超时、结果不可信）。
    static func polish(_ text: String, language: DictationTextProcessor.Language,
                       timeout: TimeInterval = 8) async -> String? {
        guard isReady, text.count >= DictationTextProcessor.polishMinimumLength else { return nil }
        let prompt = DictationTextProcessor.polishPrompt(for: text, language: language)
        let maxTokens = min(2048, max(64, text.count * 2 + 32))
        let started = Date()
        let reply: String? = await withCheckedContinuation { continuation in
            let once = DictationOnce(continuation)
            let work = Task { @MainActor in
                let reply = try? await AIService.shared.generate(prompt, maxTokens: maxTokens, sampling: .correction,
                                                                 route: route, timeout: 8).text
                once.resolve(reply)
            }
            // 模型第一次加载、或推理卡住时别让用户干等：到点就上原文（请求本身在后台跑完）。
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                work.cancel()
                once.resolve(nil)
            }
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        guard let reply else {
            DictationLog.general.notice("polish skipped after \(seconds, privacy: .public)s (timeout or error)")
            return nil
        }
        let accepted = DictationTextProcessor.acceptPolished(reply, original: text)
        DictationLog.general.notice(
            "polish \(accepted == nil ? "rejected" : "accepted", privacy: .public) in \(seconds, privacy: .public)s")
        return accepted
    }
}

/// 只收第一个结果的续体（润色结果 / 超时谁先到用谁）。
/// @unchecked Sendable 依据：唯一的可变状态 `continuation` 只在 `lock` 内读写。
final class DictationOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
