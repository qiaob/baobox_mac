import Foundation

/// 一个功能建议用的模型（docs/ai-service/DESIGN.md §6.3）：推荐跟着功能走，按功能要什么（`AIModelAdvice`）、
/// 这台 Mac 的内存和系统版本算。功能栏每行的第三列据此写「✓ 建议的模型」，或「建议 X：理由」加「改用」。
struct AIRecommendation {
    /// 「改用」存进去的选择。
    let choice: AIEngineChoice
    /// 显示的模型名（「Qwen3-8B」「系统翻译」）。
    let name: String
    /// 跟在名字后面的几个字。不跟现在用的比较（现在用的可能是云端模型），只说它本身好在哪。
    let reason: String
    /// 鼠标停上去看到的完整理由。
    let detail: String

    /// 现在的选择用的就是它。没有系统翻译的 Mac 上，「自动」实际就是本机翻译模型，选哪个都算。
    func isUsed(by current: AIEngineChoice) -> Bool {
        if current == choice { return true }
        return choice == .auto && current == .local && !TranslationSettings.systemAvailable
    }
}

extension AIFeatureDefinition {
    /// 这个功能在这台 Mac 上建议用什么：
    /// - 翻译类：「自动」（macOS 15 起是系统翻译，否则是本机翻译专用模型 Hy-MT2）；
    /// - `.fastest`：通用模型里最快的 Qwen3-1.7B（字幕纠错、听写润色：边说边出，或有人等着）；
    /// - `.best`：跑得动的最大的 Qwen3（纪要、周报：会后才用，慢几秒没关系）。
    @MainActor
    var recommendation: AIRecommendation {
        if feature.kind == .translation {
            let translator = LocalModels.defaultEntry(for: .translation)
            if TranslationSettings.systemAvailable {
                return AIRecommendation(choice: .auto, name: L("ai.advice.system"), reason: L("ai.advice.systemReason"),
                                        detail: L("ai.advice.systemDetail \(translator.name)"))
            }
            return AIRecommendation(choice: .auto, name: translator.name, reason: L("ai.advice.translatorReason"),
                                    detail: L("ai.advice.translatorDetail \(MachineInfo.text(translator.memoryNeed))"))
        }
        let quick = LocalModels.defaultEntry(for: .generation)
        switch advice {
        case .fastest:
            return AIRecommendation(choice: .local, name: quick.name, reason: L("ai.advice.fastestReason"),
                                    detail: L("ai.advice.fastestDetail"))
        case .best:
            guard let best = LocalModels.bestFitting(totalMemory: MachineInfo.totalMemory), best.id != quick.id else {
                return AIRecommendation(choice: .local, name: quick.name, reason: L("ai.advice.onlyFitsReason"),
                                        detail: L("ai.advice.onlyFitsDetail"))
            }
            return AIRecommendation(choice: .localModel(best.id), name: best.name, reason: L("ai.advice.bestReason"),
                                    detail: L("ai.advice.bestDetail \(quick.name) \(MachineInfo.text(best.memoryNeed))"))
        }
    }
}
