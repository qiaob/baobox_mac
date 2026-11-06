import AVFoundation
import Foundation

/// pet.json 里的声音（#55）：`{ "pitch": 1.3, "rate": 0.5, "zh": "<系统声音 id>", "en": "<系统声音 id>" }`，都可省略。
/// 写错了（比如写成字符串）只当没写，不让整个 pet.json 读不出来。
struct PetVoiceSpec: Decodable {
    var pitch: Double?
    var rate: Double?
    var zh: String?
    var en: String?

    private enum CodingKeys: String, CodingKey { case pitch, rate, zh, en }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        pitch = try? container.decodeIfPresent(Double.self, forKey: .pitch)
        rate = try? container.decodeIfPresent(Double.self, forKey: .rate)
        zh = try? container.decodeIfPresent(String.self, forKey: .zh)
        en = try? container.decodeIfPresent(String.self, forKey: .en)
    }
}

/// 一个角色怎么说话：人设（系统提示词）、开场白、声音。来源优先级：设置里改过的 > pet.json > 内置默认。
struct PetPersona {
    let characterID: String
    let name: String
    let persona: String
    let greeting: String
    /// 音调（0.5–2，1 = 原声）与语速（AVSpeechUtterance 的 0–1，0.5 = 正常）。
    let pitch: Double
    let rate: Double
    /// 中文 / 英文用哪个系统声音（identifier）；nil = 该语言的默认声音。
    let zhVoice: String?
    let enVoice: String?

    /// 内置角色的大类：决定默认人设与声音。
    private enum Kind: String {
        case cat, dog, bunny, toka, alchemist, robot, generic
    }

    private static func kind(of id: String) -> Kind {
        switch id {
        case "plush-cat", "cube-cat", "cat-blob": return .cat
        case "plush-dog", "shiba", "husky", "pug", "cube-dog": return .dog
        case "plush-bunny", "rabbit", "cube-bunny": return .bunny
        case "vroid-toka": return .toka
        case "vroid-alchemist": return .alchemist
        case "robot": return .robot
        default: return .generic
        }
    }

    private static func defaultPersona(_ kind: Kind, name: String) -> String {
        switch kind {
        case .cat: return L("pet.persona.cat \(name)")
        case .dog: return L("pet.persona.dog \(name)")
        case .bunny: return L("pet.persona.bunny \(name)")
        case .toka: return L("pet.persona.toka \(name)")
        case .alchemist: return L("pet.persona.alchemist \(name)")
        case .robot: return L("pet.persona.robot \(name)")
        case .generic: return L("pet.persona.generic \(name)")
        }
    }

    private static func defaultVoice(_ kind: Kind) -> (pitch: Double, rate: Double) {
        switch kind {
        case .cat: return (1.35, 0.52)
        case .dog: return (1.1, 0.55)
        case .bunny: return (1.45, 0.5)
        case .toka: return (1.2, 0.5)
        case .alchemist: return (1.05, 0.48)
        case .robot: return (0.8, 0.5)
        case .generic: return (1.2, 0.5)
        }
    }

    /// 内置默认人设（设置页「恢复默认」与占位提示用）。
    static func defaultPersona(for package: PetPackage) -> String {
        if let custom = package.persona?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty { return custom }
        return defaultPersona(kind(of: package.id), name: package.name)
    }

    static func resolve(for package: PetPackage) -> PetPersona {
        let kind = kind(of: package.id)
        let base = defaultVoice(kind)
        let spec = package.voice
        let defaults = UserDefaults.standard
        let prefix = "pet.ai.voice.\(package.id)."
        let greeting = package.greeting?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PetPersona(
            characterID: package.id,
            name: package.name,
            persona: PetAISettings.persona(for: package.id) ?? defaultPersona(for: package),
            greeting: (greeting?.isEmpty == false ? greeting : nil) ?? L("pet.chat.greeting \(package.name)"),
            pitch: min(max(defaults.object(forKey: prefix + "pitch") as? Double ?? spec?.pitch ?? base.pitch, 0.5), 2),
            rate: min(max(defaults.object(forKey: prefix + "rate") as? Double ?? spec?.rate ?? base.rate, 0.1), 0.9),
            zhVoice: nonEmpty(defaults.string(forKey: prefix + "zh")) ?? nonEmpty(spec?.zh),
            enVoice: nonEmpty(defaults.string(forKey: prefix + "en")) ?? nonEmpty(spec?.en)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// 发给 AI 的系统提示词：角色人设 + 桌宠的说话规矩（简短、口语、跟着用户的语言、开头标情绪）。
    /// 规矩是给模型看的，不进界面，所以不走本地化。
    var systemPrompt: String {
        """
        \(persona)

        You are \(name), a small desktop pet living on the user's Mac screen inside the Baobox app. \
        Stay in character. Your reply is shown in a small speech bubble and read aloud, so:
        - Keep it short: one to three sentences, conversational, no Markdown, no lists, no code blocks.
        - Reply in the language the user writes in.
        - Begin every reply with exactly one mood tag: [happy], [sad], [surprised], [angry], [relaxed] or [neutral]. \
        The tag is hidden from the user and not read aloud.
        - You cannot see the screen, the clipboard or files, and you cannot operate the computer. \
        If asked to, say so in character.
        """
    }

    /// 回复开头的情绪标签。
    static let moods: Set<String> = ["happy", "sad", "surprised", "angry", "relaxed", "neutral"]

    /// 中文回复用中文声音，否则英文声音。
    static func isChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let chinese = Self.isChinese(text)
        if let id = chinese ? zhVoice : enVoice, let voice = AVSpeechSynthesisVoice(identifier: id) { return voice }
        return AVSpeechSynthesisVoice(language: chinese ? "zh-CN" : "en-US")
    }

    /// 系统里某种语言的全部声音（设置页的选择列表）。
    static func voices(chinese: Bool) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { chinese ? $0.language.hasPrefix("zh") : $0.language.hasPrefix("en") }
            .sorted { $0.name < $1.name }
    }
}
