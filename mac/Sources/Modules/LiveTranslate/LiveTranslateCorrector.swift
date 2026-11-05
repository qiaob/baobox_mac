import Foundation

/// AI 纠正识别错字（docs/live-translate/DESIGN.md §3.4）：说完的中文单元交给本地小模型（Qwen3-1.7B），
/// 结合上下文改正同音字 / 近音字（如「时事翻译」→「实时翻译」）。
///
/// 为什么要单独一个通用模型：系统识别器不会按上下文回改；翻译模型 Hy-MT2 只会修「不成词」的错字
/// （「世场」→「市场」），错成了另一个真词的「时事」它原样放过（实测 2026-11-05）。
///
/// 同一时刻只有一个请求在飞，按提交顺序处理；同一单元重复提交只留最新的一次。
@MainActor
final class LiveTranslateCorrector {
    private struct Job {
        /// 与翻译任务同一套编号：句 id × 1000 + 单元序号。
        let key: Int
        let text: String
        let context: String
    }

    /// (任务编号, 原文, 纠正后)。出错或结果不可信时「纠正后」就是原文。
    var onResult: ((Int, String, String) -> Void)?

    private var queue: [Job] = []
    private var running = false
    /// reset 之后在飞的那个结果作废。
    private var generation = 0

    func submit(key: Int, text: String, context: String) {
        queue.removeAll { $0.key == key }
        queue.append(Job(key: key, text: text, context: context))
        pump()
    }

    func reset() {
        queue = []
        generation += 1
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        running = true
        let generation = self.generation
        Task { [weak self] in
            let corrected = await Self.correct(job)
            guard let self else { return }
            self.running = false
            if generation == self.generation {
                self.onResult?(job.key, job.text, corrected)
            }
            self.pump()
        }
    }

    private static func correct(_ job: Job) async -> String {
        let context = job.context.isEmpty ? "（无）" : job.context
        // 末尾的 /no_think 是 Qwen3 关「思考」的软开关；请求里也带了 enable_thinking = false，双保险。
        let prompt = """
        你是语音识别纠错助手。下面「待纠正」是一段中文语音识别结果，可能有同音字、近音字识别错误。
        请结合「上文」判断，只改正明显识别错的字词；不要改写句子，不要增删内容，不要翻译，不要解释。
        只输出改正后的「待纠正」这一句；没有错就原样输出。

        上文：\(context)
        待纠正：\(job.text) /no_think
        """
        do {
            let raw = try await OfflineTranslator.corrector.respond(
                to: prompt, maxTokens: job.text.count * 2 + 24, sampling: .correction)
            return accept(raw, original: job.text)
        } catch {
            LiveTranslateLog.recognition.error("correction failed: \(error.localizedDescription, privacy: .public)")
            return job.text
        }
    }

    /// 只收「像是改了几个字」的结果：取第一行、去掉「待纠正：」之类的前缀和引号；长度差超过三成、
    /// 或改动超过三成（编辑距离 / 长度）就当它在改写，不用。
    nonisolated static func accept(_ raw: String, original: String) -> String {
        var text = OfflinePrompt.clean(raw)
        text = text.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? ""
        for label in ["待纠正：", "待纠正:", "改正后：", "改正后:", "纠正后：", "纠正后:"] where text.hasPrefix(label) {
            text = String(text.dropFirst(label.count))
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t「」“”\"'"))
        guard !text.isEmpty else { return original }
        let source = Array(original)
        let candidate = Array(text)
        let longer = max(source.count, candidate.count)
        guard longer > 0, abs(source.count - candidate.count) * 10 <= longer * 3 else { return original }
        guard editDistance(source, candidate) * 10 <= longer * 3 else { return original }
        return text
    }

    /// 字符级编辑距离（单元很短，几十个字，直接算）。
    nonisolated private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
