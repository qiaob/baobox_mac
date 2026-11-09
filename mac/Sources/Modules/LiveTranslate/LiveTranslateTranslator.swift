import Foundation
import NaturalLanguage
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// 翻译节流队列。见 docs/live-translate/DESIGN.md §3.2。
///
/// - `finals`：已定稿的段，全部要翻，按顺序；
/// - `latest`：每个翻译方向（目标语言）只留最新的一条 partial。
///
/// 每个「服务方」同一时刻只有一个翻译在飞，翻完再取下一条 —— 识别 partial 再密也不会堆积。
/// 服务方：系统翻译每个方向一个会话（只取自己方向的活），离线模型 / 云端服务一个循环（什么方向都接）。
/// 云端时草稿（partial）降频：两次之间至少隔 `cloudPartialInterval`，定稿照常逐句翻（docs/ai-service/DESIGN.md §5.3）。
@MainActor
final class LiveTranslateTranslator {
    private struct Job {
        let id: Int
        let text: String
        /// 目标语言代码。
        let target: String
    }

    /// (任务 id, 原文, 目标语言代码, 译文)。带上原文和方向：调用方据此丢掉已经过时的结果
    /// （那一截原文后来又改了，或这句改判了语言）。
    var onResult: ((Int, String, String, String) -> Void)?
    var onError: (() -> Void)?
    /// 要的是云端、这一句改用了本地（断网、超时、限流等）。
    var onFallback: (() -> Void)?

    /// 云端草稿的最小间隔：草稿更新很密，全走云端费钱、也容易撞限流。
    private static let cloudPartialInterval: TimeInterval = 2
    /// 云端请求超时：超时的那一句改用本地译文，不卡住后面的句子。
    private static let cloudFinalTimeout: TimeInterval = 4
    private static let cloudPartialTimeout: TimeInterval = 3
    private var lastCloudPartial = Date.distantPast

    private var finals: [Job] = []
    private var latest: [String: Job] = [:]
    private var wakes: [Int: AsyncStream<Void>.Continuation] = [:]
    private var nextWakeID = 0

    func submit(id: Int, text: String, isFinal: Bool, target: String) {
        if isFinal {
            finals.removeAll { $0.id == id }
            finals.append(Job(id: id, text: text, target: target))
            for (key, job) in latest where job.id == id {
                latest[key] = nil
            }
        } else {
            // 这一句改判了语言：旧方向上排着的 partial 作废。
            for (key, job) in latest where job.id == id && key != target {
                latest[key] = nil
            }
            latest[target] = Job(id: id, text: text, target: target)
        }
        for continuation in wakes.values {
            continuation.yield(())
        }
    }

    func reset() {
        finals = []
        latest = [:]
        lastCloudPartial = .distantPast
    }

    /// 取下一条活：先定稿再 partial。`target` 为 nil = 不挑方向。
    private func next(for target: String?) -> Job? {
        if let index = finals.firstIndex(where: { target == nil || $0.target == target }) {
            return finals.remove(at: index)
        }
        if let target {
            let job = latest[target]
            latest[target] = nil
            return job
        }
        guard let newest = latest.max(by: { $0.value.id < $1.value.id }) else { return nil }
        latest[newest.key] = nil
        return newest.value
    }

    /// 登记一个服务方的唤醒流；先唤醒一次，处理就绪前已排队的内容。
    private func registerWake() -> (stream: AsyncStream<Void>, id: Int) {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        nextWakeID += 1
        wakes[nextWakeID] = continuation
        continuation.yield(())
        return (stream, nextWakeID)
    }

    private func unregisterWake(_ id: Int) {
        wakes[id]?.finish()
        wakes[id] = nil
    }

    /// 离线模型 / 云端服务的翻译循环：由控制器在开始时起一个 Task，停止时取消。
    func serveModel(route: AIService.Route) async {
        let wake = registerWake()
        defer { unregisterWake(wake.id) }
        for await _ in wake.stream {
            while !finals.isEmpty || !latest.isEmpty {
                if Task.isCancelled { return }
                let isFinal = !finals.isEmpty
                if route == .cloud, !isFinal,
                   Date().timeIntervalSince(lastCloudPartial) < Self.cloudPartialInterval {
                    // 草稿还没到点：小睡一下再看（期间来了定稿就先翻定稿，草稿被更新的替换掉也正好）。
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                guard let job = next(for: nil) else { break }
                guard let target = TranslationLanguage.from(code: job.target) else { continue }
                if route == .cloud, !isFinal { lastCloudPartial = Date() }
                do {
                    // 专有名词表每句现读：设置里改完，下一句翻译就用上。
                    let reply = try await AIService.shared.translate(
                        job.text, to: target, glossary: LiveTranslateSettings.glossary, route: route,
                        timeout: isFinal ? Self.cloudFinalTimeout : Self.cloudPartialTimeout)
                    if Task.isCancelled { return }
                    if reply.usedFallback { onFallback?() }
                    onResult?(job.id, job.text, job.target, reply.text)
                } catch {
                    if Task.isCancelled { return }
                    onError?()
                }
            }
        }
    }

    #if canImport(Translation)
    /// 由字幕条视图上的 `.translationTask` 调用；session 只在本函数（即该闭包）生命周期内使用。
    /// 视图消失 / 配置变化时任务被取消，循环随之结束。
    @available(macOS 15.0, *)
    func serve(_ session: TranslationSession, target: String) async {
        let wake = registerWake()
        defer { unregisterWake(wake.id) }
        for await _ in wake.stream {
            while let job = next(for: target) {
                if Task.isCancelled { return }
                do {
                    let response = try await session.translate(job.text)
                    onResult?(job.id, job.text, job.target, response.targetText)
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
    let target: String
    @State private var configuration: TranslationSession.Configuration?

    init(translator: LiveTranslateTranslator, source: TranslationLanguage, target: TranslationLanguage) {
        self.translator = translator
        // 队列按我们自己的语言代码分方向；会话配置用系统的语言标识（两者只在葡萄牙语上不同）。
        self.target = target.code
        _configuration = State(initialValue: TranslationSession.Configuration(
            source: Locale.Language(identifier: source.appleCode),
            target: Locale.Language(identifier: target.appleCode)))
    }

    func body(content: Content) -> some View {
        content.translationTask(configuration) { session in
            await translator.serve(session, target: target)
        }
    }
}

extension View {
    /// 挂一个方向的翻译会话；pair 为 nil 或系统低于 macOS 15 时原样返回。
    @ViewBuilder
    func liveTranslateTask(_ pair: (source: TranslationLanguage, target: TranslationLanguage)?,
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
    func liveTranslateTask(_ pair: (source: TranslationLanguage, target: TranslationLanguage)?,
                           translator: LiveTranslateTranslator) -> some View {
        self
    }
}
#endif

/// 把一句（可能很长、还在说）的识别文字切成翻译单元，让长段落边说边翻（docs/live-translate/DESIGN.md §3.2）：
/// 已经说完的单元各翻一次、缓存住；只有最后那截还在说的反复重翻 —— 每次翻译都很短，跟得上语速。
///
/// 切法：句末标点（。！？；… ! ? ;）切；英文句点只在「后面空格 + 大写开头」时算句末，缩写（U.S.、Mr.、e.g.）
/// 和小数不拆；一截已经够长（中文 24 字、英文 80 字符）就在逗号处切；还没标点又太长（中文 48 字、英文 160 字符）
/// 才硬切 —— 中文按分词切在词边界上（`NLTokenizer`），英文切在空格处，保证延迟有上限又不把词拆开。
enum LiveTranslateUnits {
    private static let terminators: Set<Character> = ["。", "！", "？", "；", "…", "!", "?", ";"]
    private static let commas: Set<Character> = ["，", "、", ","]
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "inc", "ltd", "co", "jr", "sr", "no", "fig",
    ]

    static func split(_ text: String, cjk: Bool) -> [String] {
        let soft = cjk ? 24 : 80
        let hard = cjk ? 48 : 160
        let characters = Array(text)
        var units: [String] = []
        var current = ""
        func emit(_ piece: String) {
            let unit = piece.trimmingCharacters(in: .whitespaces)
            if !unit.isEmpty { units.append(unit) }
        }
        for (index, character) in characters.enumerated() {
            current.append(character)
            if terminators.contains(character)
                || (character == "." && endsSentence(characters, at: index))
                || (commas.contains(character) && current.count >= soft) {
                emit(current)
                current = ""
            } else if current.count >= hard {
                if !cjk {
                    guard character == " " else { continue }
                    emit(current)
                    current = ""
                } else {
                    let cut = lastWordBoundary(in: current)
                    emit(String(current[..<cut]))
                    current = String(current[cut...])
                }
            }
        }
        emit(current)
        return units
    }

    /// 英文句点是不是句末：后面没字了，或「空格 + 大写 / 非字母」开头；前面的词是缩写或单个字母（U.S.）就不算。
    private static func endsSentence(_ characters: [Character], at index: Int) -> Bool {
        guard index + 1 < characters.count else { return true }
        guard characters[index + 1] == " " else { return false }
        var start = index
        while start > 0, characters[start - 1] != " " { start -= 1 }
        let word = String(characters[start..<index])
        if word.count <= 1 || word.contains(".") || abbreviations.contains(word.lowercased()) { return false }
        guard index + 2 < characters.count else { return true }
        let following = characters[index + 2]
        return following.isUppercase || !following.isLetter
    }

    /// 中文长句硬切时切在最后一个完整的词后面（最后那个词可能还没说完，留给下一截）；分不出词就整段切。
    private static func lastWordBoundary(in text: String) -> String.Index {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var boundary = text.endIndex
        var last: Range<String.Index>?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if let previous = last { boundary = previous.upperBound }
            last = range
            return true
        }
        return boundary
    }
}
