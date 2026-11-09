import Foundation

/// AI 润色（需求 §4.4、技术设计 §4）：本地 Qwen3（经 `AIService` 的本地通用生成，与实时翻译的纠错同一个模型）
/// 把口语整理成书面语。提示词与结果把关在 `DictationTextProcessor`。最多等 8 秒，超时 / 出错 / 结果不可信都上原文。
@MainActor
enum DictationPolisher {
    /// 模型已下载、推理进程已打包。
    static var isReady: Bool { AIService.shared.isLocalReady(.generation) }

    /// 开始听写就预热（加载模型要几秒），结束时 `coolDown` 配对。
    static func warmUp() {
        AIService.shared.beginLocalKeepAlive(.generation)
    }

    static func coolDown() {
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
                // P0 只走本地（docs/ai-service/DESIGN.md §5.5）。
                let reply = try? await AIService.shared.generate(prompt, maxTokens: maxTokens, sampling: .correction,
                                                                 route: .local).text
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
