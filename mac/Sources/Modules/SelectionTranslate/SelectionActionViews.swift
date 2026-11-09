import AppKit
import SwiftUI

/// 一次取词 = 一个会话（docs/selection-translate/ASSISTANT.md §2.2）：原文、可写信息、浮层形态、各动作结果缓存。
@MainActor
final class SelectionSession: ObservableObject {
    enum Phase: Equatable {
        case bar
        case result(String)
    }

    let text: String
    let source: TranslationLanguage
    let translateTarget: TranslationLanguage
    let route: SelectionTextResult.Route
    let editTarget: SelectionEditTarget?
    let context: String?
    let anchor: CGRect?
    /// 这次显示的动作（打开的，按用户的顺序）。直达快捷键跑了一个关掉的动作时会临时补进来。
    private(set) var actions: [SelectionAction]

    @Published var phase: Phase { didSet { onStateChange?() } }
    /// 键盘唤起的动作条：字母直达、← → 移动、⏎ 执行。
    @Published var keyboardMode: Bool { didSet { onStateChange?() } }
    @Published var optionHeld = false
    /// 键盘模式下高亮的是第几个动作。
    @Published var highlighted = 0
    @Published var tone: SelectionRewriteTone
    /// 当前动作出来的结果（⏎ 主按钮用：改写类替换，其余复制）。
    @Published var primaryText: String? { didSet { onStateChange?() } }
    /// 面板里的一句提示（「选区变了，已复制」）。
    @Published var notice: String?
    /// 翻译里手动改选的目标语言。
    @Published var chosenTarget: TranslationLanguage?

    /// AI 动作的结果缓存：切回来不重跑。键 = 动作 id（改写再加语气）。
    var aiCache: [String: SelectionAIOutcome] = [:]
    var onStateChange: (() -> Void)?

    init(result: SelectionTextResult, text: String, source: TranslationLanguage, translateTarget: TranslationLanguage,
         phase: Phase, keyboardMode: Bool) {
        self.text = text
        self.source = source
        self.translateTarget = translateTarget
        self.route = result.route
        self.editTarget = result.editTarget
        self.context = result.context
        self.anchor = result.anchorRect
        self.actions = SelectionActionStore.visible
        self.phase = phase
        self.keyboardMode = keyboardMode
        self.tone = SelectionActionStore.rewriteTone
        if case .result(let id) = phase {
            ensureAction(id)
            highlighted = actions.firstIndex { $0.id == id } ?? 0
        }
    }

    var isBar: Bool { phase == .bar }

    var currentActionID: String? {
        if case .result(let id) = phase { return id }
        return nil
    }

    var currentAction: SelectionAction? {
        guard let id = currentActionID else { return nil }
        return actions.first { $0.id == id }
    }

    /// 当前结果的主按钮是「替换」（改写类 + 选区可写）。
    var primaryReplaces: Bool {
        (currentAction?.isRewrite ?? false) && editTarget != nil
    }

    /// 关掉的动作被直达快捷键点名：临时补到末尾。
    func ensureAction(_ id: String) {
        guard !actions.contains(where: { $0.id == id }), let action = SelectionActionStore.action(id: id) else { return }
        actions.append(action)
    }
}

/// 一次 AI 动作的结果。
struct SelectionAIOutcome {
    let text: String
    let route: AIRoute
    let usedFallback: Bool
    let seconds: Double
}

// MARK: - 根视图

struct SelectionRootView: View {
    @ObservedObject var session: SelectionSession
    var onSizeChange: (CGSize) -> Void

    var body: some View {
        Group {
            if session.isBar {
                SelectionActionBar(session: session)
                    .fixedSize()
            } else {
                SelectionResultPanel(session: session)
                    .frame(width: SelectionPanelMetrics.width)
                    // 高度取内容的理想高度，不随窗口高度伸缩：窗口跟着内容改，不会反过来把内容压扁。
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: SelectionPanelSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(SelectionPanelSizeKey.self) { size in
            onSizeChange(size)
        }
    }
}

/// 纯提示：没取到词、OCR 没识别到、需要权限、替换没成功等。
struct SelectionNoticeView: View {
    let message: String
    let onClose: () -> Void
    var onSizeChange: (CGSize) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "character.bubble")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            SelectionCloseButton(action: onClose)
        }
        .padding(12)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(SelectionCardBackground(radius: 12))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: SelectionPanelSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(SelectionPanelSizeKey.self) { size in
            onSizeChange(size)
        }
    }
}

struct SelectionCardBackground: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1))
            )
    }
}

struct SelectionCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L("selectiontranslate.panel.close"))
    }
}

// MARK: - 动作条

struct SelectionActionBar: View {
    @ObservedObject var session: SelectionSession

    private var controller: SelectionTranslateController { .shared }

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(session.actions.enumerated()), id: \.element.id) { index, action in
                barItem(action, index: index)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 3)
            Button {
                controller.openSettings()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("selectiontranslate.bar.settings"))
        }
        .padding(3)
        .modifier(SelectionCardBackground(radius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(session.keyboardMode ? 0.5 : 0), lineWidth: 2)
        )
    }

    @ViewBuilder
    private func barItem(_ action: SelectionAction, index: Int) -> some View {
        let highlighted = session.keyboardMode && session.highlighted == index
        if action.builtin == .rewrite {
            Menu {
                ForEach(SelectionRewriteTone.allCases) { tone in
                    Button(tone.title) {
                        session.tone = tone
                        SelectionActionStore.rewriteTone = tone
                        controller.run(action.id)
                    }
                }
            } label: {
                itemLabel(action, index: index, highlighted: highlighted)
            } primaryAction: {
                controller.run(action.id)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .padding(.trailing, 4)
            .help(helpText(action, index: index))
        } else {
            Button {
                controller.run(action.id)
            } label: {
                itemLabel(action, index: index, highlighted: highlighted)
            }
            .buttonStyle(.plain)
            .help(helpText(action, index: index))
        }
    }

    private func itemLabel(_ action: SelectionAction, index: Int, highlighted: Bool) -> some View {
        HStack(spacing: 4) {
            if let badge = badge(for: action, index: index) {
                Text(verbatim: badge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(highlighted ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                    .frame(minWidth: 13, minHeight: 14)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(highlighted ? Color.white : Color.primary.opacity(0.85))
                    )
            } else {
                Image(systemName: action.symbolName)
                    .font(.system(size: 11))
            }
            Text(action.title)
                .font(.system(size: 12))
        }
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// 按住 ⌥ 显示数字；键盘模式显示字母（自定义动作显示数字）。
    private func badge(for action: SelectionAction, index: Int) -> String? {
        if session.keyboardMode {
            if let builtin = action.builtin { return builtin.letter }
            return index < 9 ? String(index + 1) : nil
        }
        if session.optionHeld, SelectionAssistantSettings.optionDigits, index < 9 {
            return String(index + 1)
        }
        return nil
    }

    private func helpText(_ action: SelectionAction, index: Int) -> String {
        let base = action.builtin?.help ?? action.title
        guard SelectionAssistantSettings.optionDigits, index < 9 else { return base }
        return "\(base)  ⌥\(index + 1)"
    }
}

// MARK: - 结果面板

struct SelectionResultPanel: View {
    @ObservedObject var session: SelectionSession

    private var controller: SelectionTranslateController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            tabs
            Divider()
            if let action = session.currentAction {
                content(for: action)
                    .id(action.id)
            }
            if let notice = session.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .modifier(SelectionCardBackground(radius: 12))
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(session.actions.enumerated()), id: \.element.id) { index, action in
                        tab(action, index: index)
                    }
                }
            }
            .frame(height: 24)
            SelectionCloseButton { controller.hidePanel() }
        }
    }

    private func tab(_ action: SelectionAction, index: Int) -> some View {
        let selected = session.currentActionID == action.id
        return Button {
            controller.run(action.id)
        } label: {
            HStack(spacing: 3) {
                if session.optionHeld, SelectionAssistantSettings.optionDigits, index < 9 {
                    Text(verbatim: String(index + 1))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(minWidth: 12, minHeight: 13)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.85)))
                }
                Text(action.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func content(for action: SelectionAction) -> some View {
        switch action.builtin {
        case .translate:
            SelectionTranslateBody(session: session)
        case .learn:
            SelectionLearnView(session: session)
        default:
            SelectionAIActionArea(session: session, action: action)
        }
    }
}

// MARK: - 翻译

/// 「翻译」：方向行（目标语言可改）+ 原文 + 译文 + 朗读 / 复制（沿用原来的划词翻译）。
struct SelectionTranslateBody: View {
    @ObservedObject var session: SelectionSession
    @State private var translatedText: String?
    @State private var copied = false

    private var controller: SelectionTranslateController { .shared }
    private var target: TranslationLanguage { session.chosenTarget ?? session.translateTarget }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(session.source.endonym)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                Menu {
                    ForEach(TranslationLanguage.all) { language in
                        Button(language.endonym) {
                            guard language != target else { return }
                            translatedText = nil
                            copied = false
                            session.primaryText = nil
                            session.chosenTarget = language
                        }
                    }
                } label: {
                    Text(target.endonym)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("selectiontranslate.panel.changeTarget"))
                Spacer()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

            AdaptiveText(text: session.text, size: 13, weight: .regular,
                         maxHeight: SelectionPanelMetrics.originalMaxHeight)

            Divider()

            // 换目标语言 = 重建翻译区（新会话 / 新请求）。
            SelectionTranslationArea(text: session.text, source: session.source, target: target) { value in
                translatedText = value
                session.primaryText = value
                controller.translationReady(value, language: target)
            }
            .id(target.code)

            HStack(spacing: 8) {
                Button {
                    controller.speak(session.text, language: session.source)
                } label: {
                    Label(L("selectiontranslate.panel.speakOriginal"), systemImage: "speaker.wave.2")
                }
                if let translatedText {
                    Button {
                        controller.speak(translatedText, language: target)
                    } label: {
                        Label(L("selectiontranslate.panel.speakTranslation"), systemImage: "speaker.wave.2.fill")
                    }
                    Button {
                        controller.copy(translatedText)
                        copied = true
                    } label: {
                        Label(copied ? L("selectiontranslate.panel.copied") : L("selectiontranslate.panel.copy"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                Spacer()
            }
            .controlSize(.small)
        }
        .onAppear {
            if let translatedText { session.primaryText = translatedText }
        }
    }
}

// MARK: - AI 动作

/// 润色 / 改写 / 地道英文 / 解释 / 总结 / 自定义：走 AI 服务层（docs/selection-translate/ASSISTANT.md §1.6 / §2.5）。
struct SelectionAIActionArea: View {
    @ObservedObject var session: SelectionSession
    let action: SelectionAction

    @ObservedObject private var local = OfflineTranslator.corrector
    @ObservedObject private var store = AIModelStore.shared
    /// 本机大模型下载好 / 删掉时刷新。
    @ObservedObject private var localModels = LocalModelsObserver.shared
    @State private var outcome: SelectionAIOutcome?
    @State private var failure: String?
    /// 「这次用云端」。
    @State private var routeOverride: AIRoute?
    /// 「重新生成」+1，强制重跑。
    @State private var runCount = 0
    @State private var copied = false
    /// 出现时常驻的本地推理进程（消失时配对结束）。
    @State private var keptBackend: OfflineTranslator?

    private var controller: SelectionTranslateController { .shared }

    private enum Blocker {
        case needsModel
        case tooLong
    }

    private var cacheKey: String {
        action.builtin == .rewrite ? "\(action.id).\(session.tone.rawValue)" : action.id
    }

    /// 这次走哪：「AI」页给这个功能选的模型（云端没配好 / 本机大模型没下载时服务层已退回内置本地模型）。
    private var effectiveRoute: AIRoute {
        routeOverride ?? AIService.shared.route(for: .selectionActions)
    }

    private var isLocal: Bool { effectiveRoute.modelID == nil }

    /// 第一个配置完整的云端模型（「这次用云端」用）。
    private var firstCloudModelID: String? {
        store.models.first { store.isConfigured($0.id) }?.id
    }

    private var blocker: Blocker? {
        guard isLocal else { return nil }
        if !AIService.shared.isReady(effectiveRoute, local: .generation) { return .needsModel }
        if !SelectionTextBudget.fitsLocal(session.text, rewrite: action.isRewrite) { return .tooLong }
        return nil
    }

    private var routeKey: String {
        switch effectiveRoute {
        case .local: return "local"
        case .localModel(let id): return "localmodel:" + id
        case .cloud(let id): return "cloud:" + id
        }
    }

    private var taskKey: String {
        "\(cacheKey)#\(runCount)#\(routeKey)#\(blocker == nil)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if action.builtin == .rewrite {
                Picker("", selection: Binding(
                    get: { session.tone },
                    set: { tone in
                        session.tone = tone
                        SelectionActionStore.rewriteTone = tone
                    })) {
                    ForEach(SelectionRewriteTone.allCases) { tone in
                        Text(tone.title).tag(tone)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }

            AdaptiveText(text: session.text, size: 12, weight: .regular, maxHeight: 80, color: .secondary)

            resultArea

            if outcome != nil {
                footer
            }
        }
        .task(id: taskKey) {
            await run()
        }
        .onAppear {
            // 只对实际要用、已下载的那个本地进程常驻（常驻会顺带把模型加载起来）。
            if blocker == nil, let backend = AIService.shared.localBackend(for: effectiveRoute, local: .generation) {
                backend.beginKeepAlive()
                keptBackend = backend
            }
        }
        .onDisappear {
            keptBackend?.endKeepAlive()
            keptBackend = nil
        }
    }

    @ViewBuilder
    private var resultArea: some View {
        if let outcome {
            VStack(alignment: .leading, spacing: 4) {
                AdaptiveText(text: outcome.text, size: 13, weight: .medium,
                             maxHeight: SelectionPanelMetrics.translationMaxHeight)
                if outcome.usedFallback {
                    Text(L("ai.notice.cloudFallback"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        } else if let failure {
            VStack(alignment: .leading, spacing: 6) {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("selectiontranslate.result.retry")) {
                    self.failure = nil
                    runCount += 1
                }
                .controlSize(.small)
            }
        } else if let blocker {
            blockerView(blocker)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(AIService.shared.localBackend(for: effectiveRoute, local: .generation)?.isStartingServer == true
                     ? L("selectiontranslate.panel.startingModel")
                     : L("selectiontranslate.result.generating"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func blockerView(_ blocker: Blocker) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch blocker {
            case .needsModel:
                Text(L("selectiontranslate.result.needsModel"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if effectiveRoute == .local {
                    OfflineModelRow(translator: .corrector, compact: true)
                        .controlSize(.small)
                }
                HStack(spacing: 8) {
                    if let id = firstCloudModelID {
                        Button(L("selectiontranslate.result.useCloudOnce")) {
                            routeOverride = .cloud(id)
                        }
                    }
                    Button(L("selectiontranslate.result.aiSettings")) {
                        controller.openSettings(tab: AISettingsView.tabID)
                    }
                }
                .controlSize(.small)
            case .tooLong:
                Text(L("selectiontranslate.result.tooLong \(session.text.count) \(SelectionTextBudget.localCharacterLimit(for: session.text, rewrite: action.isRewrite))"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let id = firstCloudModelID {
                    Button(L("selectiontranslate.result.useCloudOnce")) {
                        routeOverride = .cloud(id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button(L("selectiontranslate.result.aiSettings")) {
                        controller.openSettings(tab: AISettingsView.tabID)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let outcome {
                Text(L("selectiontranslate.result.meta \(Self.modelName(outcome.route)) \(Self.format(outcome.seconds))"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                outcome = nil
                session.primaryText = nil
                session.aiCache[cacheKey] = nil
                runCount += 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(L("selectiontranslate.result.regenerate"))
            Button {
                if let text = outcome?.text {
                    controller.speak(text, language: LanguageDetector.detect(text, preferred: [session.source]))
                }
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .help(L("selectiontranslate.panel.speakTranslation"))
            if action.isRewrite, session.editTarget != nil {
                Button {
                    if let text = outcome?.text { controller.copy(text) }
                    copied = true
                } label: {
                    Text(copied ? L("selectiontranslate.panel.copied") : L("selectiontranslate.result.copy"))
                }
                Button {
                    if let text = outcome?.text { controller.replace(text, session: session) }
                } label: {
                    Text(L("selectiontranslate.result.replace"))
                }
                .buttonStyle(.borderedProminent)
                .help(L("selectiontranslate.result.replaceHelp"))
            } else {
                Button {
                    if let text = outcome?.text { controller.copy(text) }
                    copied = true
                } label: {
                    Text(copied ? L("selectiontranslate.panel.copied") : L("selectiontranslate.result.copy"))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
    }

    /// 页脚的模型名：内置本地 = Qwen3-1.7B，本机大模型 / 云端用各自的名字。
    private static func modelName(_ route: AIRoute) -> String {
        switch route {
        case .local:
            return OfflineTranslator.corrector.model.displayName
        case .localModel(let id):
            return LocalModels.entry(id)?.name ?? id
        case .cloud(let id):
            return AIModelStore.shared.model(id)?.displayName ?? L("selectiontranslate.result.cloud")
        }
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.1f", seconds)
    }

    private func run() async {
        copied = false
        if runCount == 0, let cached = session.aiCache[cacheKey] {
            outcome = cached
            session.primaryText = cached.text
            return
        }
        outcome = nil
        failure = nil
        session.primaryText = nil
        guard blocker == nil,
              let request = SelectionPrompts.request(for: action, text: session.text, tone: session.tone) else {
            if action.isCustom, action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failure = L("selectiontranslate.result.emptyPrompt")
            }
            return
        }
        let started = Date()
        do {
            let reply = try await AIService.shared.generate(request.prompt, maxTokens: request.maxTokens,
                                                            sampling: request.sampling, route: effectiveRoute)
            guard !Task.isCancelled else { return }
            let text = SelectionPrompts.clean(reply.text)
            guard !text.isEmpty else {
                failure = L("selectiontranslate.result.empty")
                return
            }
            let result = SelectionAIOutcome(text: text, route: reply.route, usedFallback: reply.usedFallback,
                                            seconds: Date().timeIntervalSince(started))
            session.aiCache[cacheKey] = result
            outcome = result
            session.primaryText = text
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }
}
