import AppKit
import SwiftUI

/// 宠物 AI 对话（#55，docs/desktop-pet/CHAT.md）：对话上下文、发请求、流式显示、朗读。只打字，不做语音输入（用户定）。
/// 界面（`PetChatPanel` / `PetChatView`）与摆位由 `PetController` 负责。
@MainActor
final class PetChatController: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id = UUID()
        let role: PetChatTurn.Role
        var text: String
        var isError = false
    }

    @Published private(set) var lines: [Line] = []
    @Published var input = ""
    @Published private(set) var replying = false
    @Published var hint: String?
    @Published private(set) var name = ""

    /// 回复的情绪（happy / sad …；nil = 复原）。控制器据此给 VRM 换表情。
    var onMood: ((String?) -> Void)?
    /// 点了关闭 / 按了 Esc。
    var onClose: (() -> Void)?

    let voice = PetVoice()

    private var persona: PetPersona?
    /// 发给 AI 的上下文：一问一答成对存，最近 10 轮。
    private var turns: [PetChatTurn] = []
    private var task: Task<Void, Never>?
    private var sentTimes: [Date] = []
    private var moodShown = false

    static let maxTurns = 20

    init() {
        voice.onSpeakingChanged = { [weak self] speaking in
            guard let self, !speaking, !self.replying, self.moodShown else { return }
            self.moodShown = false
            self.onMood?(nil)
        }
    }

    // MARK: - 角色与历史

    /// 换成某个角色的对话（打开聊天、换形象时）：读它的人设与本机对话记录。
    func load(_ package: PetPackage) {
        let persona = PetPersona.resolve(for: package)
        guard persona.characterID != self.persona?.characterID || persona.persona != self.persona?.persona
                || persona.pitch != self.persona?.pitch || persona.rate != self.persona?.rate
                || persona.zhVoice != self.persona?.zhVoice || persona.enVoice != self.persona?.enVoice else { return }
        let switched = persona.characterID != self.persona?.characterID
        self.persona = persona
        name = persona.name
        guard switched else { return }
        cancel()
        turns = Self.loadHistory(persona.characterID)
        rebuildLines()
    }

    private func rebuildLines() {
        lines = turns.map { Line(role: $0.role, text: $0.text) }
        if lines.isEmpty, let persona {
            lines = [Line(role: .assistant, text: persona.greeting)]
        }
    }

    /// 打开聊天框时：没聊过就把开场白读出来。
    func opened() {
        hint = nil
        guard turns.isEmpty, let persona, shouldSpeak else { return }
        voice.speak(persona.greeting, persona: persona)
    }

    func clear() {
        cancel()
        turns = []
        if let id = persona?.characterID { Self.saveHistory([], for: id) }
        rebuildLines()
        hint = nil
    }

    /// 停掉正在进行的一切（关聊天框、换形象、宠物被关掉）。
    func cancel() {
        task?.cancel()
        task = nil
        replying = false
        voice.stop()
        if moodShown {
            moodShown = false
            onMood?(nil)
        }
    }

    func close() {
        onClose?()
    }

    // MARK: - 发送

    /// 开会、录屏、勿扰、安静一下、正在录音时不出声（设置里可以改）。
    private var shouldSpeak: Bool {
        guard PetAISettings.speak else { return false }
        if PetAISettings.speakWhenBusy { return true }
        let quiet = PetSettings.quietUntil.map { $0 > Date() } ?? false
        return !(quiet || NotifyDND.shared.isSuppressed || AudioCaptureCoordinator.shared.current != nil)
    }

    func sendInput() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        send(text)
    }

    func send(_ text: String) {
        guard let persona, !replying else { return }
        hint = nil
        // 每分钟次数上限（免得误刷费用）。
        let now = Date()
        sentTimes.removeAll { now.timeIntervalSince($0) > 60 }
        guard sentTimes.count < PetAISettings.perMinute else {
            hint = L("pet.chat.error.localLimit \(persona.name)")
            return
        }
        sentTimes.append(now)
        voice.stop()
        // 没聊过时那句开场白只是显示用的，不进上下文。
        if turns.isEmpty { lines = [] }
        lines.append(Line(role: .user, text: text))
        lines.append(Line(role: .assistant, text: ""))
        let replyIndex = lines.count - 1
        replying = true

        let provider = PetAISettings.provider
        let request = PetAIClient.Request(
            provider: provider, model: PetAISettings.model, baseURL: PetAISettings.openaiBaseURL,
            apiKey: PetAIKeychain.key(for: provider), system: persona.systemPrompt,
            turns: Array(turns.suffix(Self.maxTurns)) + [PetChatTurn(role: .user, text: text)],
            maxTokens: PetAISettings.maxTokens
        )
        let speak = shouldSpeak
        task = Task { [weak self] in
            var raw = ""
            var spoken = 0
            var visible = ""
            do {
                try await PetAIClient.stream(request) { chunk in
                    guard let self, !Task.isCancelled else { return }
                    raw += chunk
                    let parsed = Self.parse(raw)
                    visible = parsed.visible
                    if let mood = parsed.mood, !self.moodShown, mood != "neutral" {
                        self.moodShown = true
                        self.onMood?(mood)
                    }
                    if replyIndex < self.lines.count { self.lines[replyIndex].text = visible }
                    // 说完整的一句就读出来，不等整段。
                    if speak, let end = Self.lastSentenceEnd(in: visible, from: spoken) {
                        self.speakSlice(visible, from: spoken, to: end, persona: persona)
                        spoken = end
                    }
                }
                guard let self, !Task.isCancelled else { return }
                let finished = visible.trimmingCharacters(in: .whitespacesAndNewlines)
                if speak, spoken < visible.count { self.speakSlice(visible, from: spoken, to: visible.count, persona: persona) }
                self.finish(user: text, reply: finished, replyIndex: replyIndex)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.fail(error, replyIndex: replyIndex, persona: persona)
            }
        }
    }

    private func speakSlice(_ text: String, from: Int, to: Int, persona: PetPersona) {
        let start = text.index(text.startIndex, offsetBy: min(from, text.count))
        let end = text.index(text.startIndex, offsetBy: min(to, text.count))
        guard start < end else { return }
        voice.speak(String(text[start..<end]), persona: persona)
    }

    private func finish(user: String, reply: String, replyIndex: Int) {
        replying = false
        task = nil
        guard !reply.isEmpty, let id = persona?.characterID else { return }
        turns.append(PetChatTurn(role: .user, text: user))
        turns.append(PetChatTurn(role: .assistant, text: reply))
        if turns.count > Self.maxTurns { turns.removeFirst(turns.count - Self.maxTurns) }
        Self.saveHistory(turns, for: id)
        if !voice.isSpeaking, moodShown {
            moodShown = false
            onMood?(nil)
        }
    }

    /// 出错：用角色的口吻说一句（那一问不进上下文，下次重发即可）。
    private func fail(_ error: Error, replyIndex: Int, persona: PetPersona) {
        replying = false
        task = nil
        let message = Self.describe(error, name: persona.name)
        if replyIndex < lines.count {
            lines[replyIndex].text = message
            lines[replyIndex].isError = true
        }
        if moodShown {
            moodShown = false
            onMood?(nil)
        }
    }

    /// 出错时角色说的那句话（设置页「测试连接」也用）。
    static func describe(_ error: Error, name: String) -> String {
        switch error as? PetAIError {
        case .noKey?: return L("pet.chat.error.noKey \(name)")
        case .unauthorized?: return L("pet.chat.error.unauthorized \(name)")
        case .rateLimited?: return L("pet.chat.error.rateLimited \(name)")
        case .overloaded?: return L("pet.chat.error.overloaded \(name)")
        case .timeout?: return L("pet.chat.error.timeout \(name)")
        case .offline?: return L("pet.chat.error.offline \(name)")
        case .refused?: return L("pet.chat.error.refused \(name)")
        case .server(let code, let detail)?:
            let info = detail.isEmpty ? "HTTP \(code)" : (code > 0 ? "HTTP \(code): \(detail)" : detail)
            return L("pet.chat.error.server \(name) \(info)")
        case .malformed?, nil: return L("pet.chat.error.malformed \(name)")
        }
    }

    /// 回复开头的 `[happy]` 这类情绪标签：认出来就藏起来；还没收全（`[ha`）先什么都不显示。
    static func parse(_ raw: String) -> (mood: String?, visible: String) {
        let trimmed = raw.drop { $0 == " " || $0 == "\n" }
        guard trimmed.first == "[" else { return (nil, raw) }
        if let close = trimmed.firstIndex(of: "]"), trimmed.distance(from: trimmed.startIndex, to: close) <= 14 {
            let tag = trimmed[trimmed.index(after: trimmed.startIndex)..<close].lowercased()
            let rest = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return PetPersona.moods.contains(tag) ? (tag, rest) : (nil, raw)
        }
        return trimmed.count <= 14 ? (nil, "") : (nil, raw)
    }

    /// `from` 之后最后一个句末标点的位置（含标点）；没有返回 nil。
    static func lastSentenceEnd(in text: String, from: Int) -> Int? {
        let enders: Set<Character> = ["。", "！", "？", "!", "?", ".", "\n", "…", "~", "～"]
        var result: Int?
        for (offset, character) in text.enumerated() where offset >= from && enders.contains(character) {
            result = offset + 1
        }
        return result
    }

    // MARK: - 本机对话记录：~/Library/Application Support/Baobox/Pets/<角色>/chat.json

    private static func historyURL(_ id: String) -> URL {
        PetPackageLoader.userPetsDirectory.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("chat.json")
    }

    /// 读失败 / 格式不对就当没有记录（不报错）。文件很小（最多 20 条），打开聊天框时读一次。
    private static func loadHistory(_ id: String) -> [PetChatTurn] {
        guard let data = try? Data(contentsOf: historyURL(id)),
              let turns = try? JSONDecoder().decode([PetChatTurn].self, from: data) else { return [] }
        // 只留成对的一问一答（Claude 要求 user / assistant 交替、从 user 开始）。
        var paired: [PetChatTurn] = []
        var index = 0
        while index + 1 < turns.count {
            if turns[index].role == .user, turns[index + 1].role == .assistant {
                paired += [turns[index], turns[index + 1]]
                index += 2
            } else {
                index += 1
            }
        }
        return Array(paired.suffix(maxTurns))
    }

    private static func saveHistory(_ turns: [PetChatTurn], for id: String) {
        let url = historyURL(id)
        DispatchQueue.global(qos: .utility).async {
            if turns.isEmpty {
                try? FileManager.default.removeItem(at: url)
                return
            }
            guard let data = try? JSONEncoder().encode(turns) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - 窗口与界面

/// 聊天框：无边框、不激活 App 的面板（能打字，但原来的 App 仍是前台）。Esc 关闭。
final class PetChatPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

struct PetChatView: View {
    @ObservedObject var controller: PetChatController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(.tint)
                Text(verbatim: controller.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    controller.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L("pet.chat.clear"))
                Button {
                    controller.close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help(L("pet.chat.close"))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(controller.lines) { line in
                            lineView(line).id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: controller.lines) { _, lines in
                    if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onAppear {
                    if let last = controller.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            if let hint = controller.hint {
                Text(verbatim: hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                TextField(L("pet.chat.placeholder"), text: $controller.input)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { controller.sendInput() }
                Button {
                    controller.sendInput()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(controller.replying || controller.input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: PetChatView.width, height: PetChatView.height)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        .onAppear { focused = true }
        .onExitCommand { controller.close() }
    }

    static let width: CGFloat = 300
    static let height: CGFloat = 320

    @ViewBuilder
    private func lineView(_ line: PetChatController.Line) -> some View {
        let mine = line.role == .user
        HStack {
            if mine { Spacer(minLength: 30) }
            Group {
                if line.text.isEmpty, line.role == .assistant {
                    ProgressView().controlSize(.small)
                } else {
                    Text(verbatim: line.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            .foregroundStyle(line.isError ? Color.orange : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(mine ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
            if !mine { Spacer(minLength: 30) }
        }
    }
}
