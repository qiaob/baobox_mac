import Foundation
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// 翻译节流队列。见 docs/live-translate/DESIGN.md §3.2。
///
/// - `finals`：已定稿的段，全部要翻，按顺序；
/// - `latest`：最新的 partial，只留最后一个。
///
/// 同一时刻只有一个翻译在飞，翻完再取下一条 —— 识别 partial 再密也不会堆积。
@MainActor
final class LiveTranslateTranslator {
    private struct Job {
        let id: Int
        let text: String
    }

    var onResult: ((Int, String) -> Void)?
    var onError: (() -> Void)?

    private var finals: [Job] = []
    private var latest: Job?
    private var wake: AsyncStream<Void>.Continuation?

    func submit(id: Int, text: String, isFinal: Bool) {
        if isFinal {
            finals.removeAll { $0.id == id }
            finals.append(Job(id: id, text: text))
            if latest?.id == id { latest = nil }
        } else {
            latest = Job(id: id, text: text)
        }
        wake?.yield(())
    }

    func reset() {
        finals = []
        latest = nil
    }

    private func next() -> Job? {
        if !finals.isEmpty { return finals.removeFirst() }
        let job = latest
        latest = nil
        return job
    }

    #if canImport(Translation)
    /// 由字幕条视图上的 `.translationTask` 调用；session 只在本函数（即该闭包）生命周期内使用。
    /// 视图消失 / 配置变化时任务被取消，循环随之结束。
    @available(macOS 15.0, *)
    func serve(_ session: TranslationSession) async {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake?.finish()
        wake = continuation
        // 会话就绪前已排队的内容。
        continuation.yield(())
        for await _ in stream {
            while let job = next() {
                if Task.isCancelled { return }
                do {
                    let response = try await session.translate(job.text)
                    onResult?(job.id, response.targetText)
                } catch {
                    if Task.isCancelled { return }
                    onError?()
                }
            }
        }
    }
    #endif
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct LiveTranslateTaskModifier: ViewModifier {
    let translator: LiveTranslateTranslator
    @State private var configuration: TranslationSession.Configuration?

    init(translator: LiveTranslateTranslator, source: String, target: String) {
        self.translator = translator
        _configuration = State(initialValue: TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)))
    }

    func body(content: Content) -> some View {
        content.translationTask(configuration) { session in
            await translator.serve(session)
        }
    }
}

extension View {
    /// 挂翻译会话；pair 为 nil 或系统低于 macOS 15 时原样返回。
    @ViewBuilder
    func liveTranslateTask(_ pair: (source: String, target: String)?,
                           translator: LiveTranslateTranslator) -> some View {
        if #available(macOS 15.0, *) {
            if let pair {
                self.modifier(LiveTranslateTaskModifier(translator: translator,
                                                        source: pair.source, target: pair.target))
            } else {
                self
            }
        } else {
            self
        }
    }
}
#else
extension View {
    func liveTranslateTask(_ pair: (source: String, target: String)?,
                           translator: LiveTranslateTranslator) -> some View {
        self
    }
}
#endif
