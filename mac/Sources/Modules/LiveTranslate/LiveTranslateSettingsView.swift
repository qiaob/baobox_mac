import AppKit
import SwiftUI

/// 实时翻译（字幕与同传）的全部设置分组，嵌在「会议」设置里（docs/meeting/TECH_DESIGN.md §6）。
/// 开关按钮和快捷键在会议页自己的分组里；独立的设置页已删（#106）。
struct LiveTranslateSettingsSections: View {

    @AppStorage(LiveTranslateSettings.sourceKey) private var source = LiveTranslateSource.system.rawValue
    /// `auto` 或识别 locale（`en-US`、`zh-CN`…）。
    @AppStorage(LiveTranslateSettings.languageKey) private var language = "en-US"
    @AppStorage(LiveTranslateSettings.autoAKey) private var autoA = TranslationLanguage.simplifiedChinese.code
    @AppStorage(LiveTranslateSettings.autoBKey) private var autoB = TranslationLanguage.english.code
    @AppStorage(LiveTranslateSettings.targetKey) private var target = LiveTranslateSettings.target.code
    @AppStorage(LiveTranslateSettings.translateKey) private var translate = true
    @AppStorage(LiveTranslateSettings.onDeviceKey) private var onDevice = true
    @AppStorage(LiveTranslateSettings.aiCorrectionKey) private var aiCorrection = true
    @AppStorage(LiveTranslateSettings.displayKey) private var display = LiveTranslateDisplay.both.rawValue
    @AppStorage(LiveTranslateSettings.fontSizeKey) private var fontSize = LiveTranslateSettings.defaultFontSize
    @AppStorage(LiveTranslateSettings.opacityKey) private var opacity = LiveTranslateSettings.defaultOpacity

    @ObservedObject private var controller = LiveTranslateController.shared

    /// 朗读会读到的语言：只读译文，译文都是「译成」的那种（本来就是这种语言的句子不翻、不读）。
    private var voiceLanguages: [TranslationLanguage] {
        [TranslationLanguage.from(code: target) ?? LiveTranslateSettings.target]
    }

    var body: some View {
        Section("livetranslate.settings.audioSection") {
            Picker("livetranslate.settings.source", selection: $source) {
                ForEach(LiveTranslateSource.allCases) { item in
                    Text(item.title).tag(item.rawValue)
                }
            }
            .onChange(of: source) { _, _ in controller.restartIfRunning() }
            Text("livetranslate.settings.sourceHelp")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("livetranslate.settings.language", selection: $language) {
                Text(LiveTranslateSpeech.auto(LiveTranslateSettings.autoA, LiveTranslateSettings.autoB).title)
                    .tag(LiveTranslateSettings.autoValue)
                ForEach(LiveTranslateSettings.speechLanguages) { item in
                    Text(item.endonym).tag(item.speechLocale ?? item.code)
                }
            }
            .onChange(of: language) { _, _ in controller.restartIfRunning() }

            if language == LiveTranslateSettings.autoValue {
                Picker("livetranslate.settings.autoA", selection: $autoA) {
                    ForEach(LiveTranslateSettings.speechLanguages) { item in
                        Text(item.endonym).tag(item.code)
                    }
                }
                .onChange(of: autoA) { _, _ in controller.restartIfRunning() }
                Picker("livetranslate.settings.autoB", selection: $autoB) {
                    ForEach(LiveTranslateSettings.speechLanguages) { item in
                        Text(item.endonym).tag(item.code)
                    }
                }
                .onChange(of: autoB) { _, _ in controller.restartIfRunning() }
                Text("livetranslate.settings.autoHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if LiveTranslateSettings.analyzerSupported {
                Text("livetranslate.settings.engineAnalyzer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("livetranslate.settings.onDevice", isOn: $onDevice)
                    .onChange(of: onDevice) { _, _ in controller.restartIfRunning() }
                Text("livetranslate.settings.onDeviceHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LiveTranslateRouteStatus(speech: LiveTranslateSettings.speech, preferOnDevice: onDevice)
            }
        }

        Section("livetranslate.settings.vocabularySection") {
            LiveTranslateGlossaryEditor()
            Text("livetranslate.settings.vocabularyHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("livetranslate.settings.translateSection") {
            Toggle("livetranslate.settings.translate", isOn: $translate)
                .onChange(of: translate) { _, _ in controller.restartIfRunning() }
            Text("livetranslate.settings.translateHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("livetranslate.settings.target", selection: $target) {
                ForEach(TranslationLanguage.all) { item in
                    Text(item.endonym).tag(item.code)
                }
            }
            .onChange(of: target) { _, _ in controller.restartIfRunning() }
            Text("livetranslate.settings.targetHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        TranslationEngineSection(definition: .liveTranslate)

        Section("livetranslate.settings.correctionSection") {
            Toggle("livetranslate.settings.aiCorrection", isOn: $aiCorrection)
                .onChange(of: aiCorrection) { _, _ in controller.restartIfRunning() }
            Text("livetranslate.settings.aiCorrectionHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
            AIFeatureRow(definition: .liveCorrection, showsManage: true)
            OfflineModelRow(translator: .corrector,
                            title: "livetranslate.correction.modelTitle",
                            notInstalledHelp: "livetranslate.correction.notInstalledHelp",
                            installedHelp: "livetranslate.correction.installedHelp")
        }

        LiveTranslateVoiceSection(languages: voiceLanguages) {
            controller.restartIfRunning()
        }

        LiveTranslateRecordSection()

        Section("livetranslate.settings.barSection") {
            Picker("livetranslate.settings.display", selection: $display) {
                Text("livetranslate.display.both").tag(LiveTranslateDisplay.both.rawValue)
                Text("livetranslate.display.translation").tag(LiveTranslateDisplay.translation.rawValue)
                Text("livetranslate.display.original").tag(LiveTranslateDisplay.original.rawValue)
            }
            HStack {
                Text("livetranslate.settings.fontSize")
                Slider(value: $fontSize, in: 16...40, step: 1)
                Text(verbatim: "\(Int(fontSize))")
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
            }
            HStack {
                Text("livetranslate.settings.opacity")
                Slider(value: $opacity, in: 0.3...1.0)
                Text(verbatim: "\(Int(opacity * 100))%")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            Text("livetranslate.settings.barHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 「优先本地识别」下的当前状态：每种在听的语言此刻走本机还是 Apple 服务器、为什么。
/// 单独成一个视图、结果存在 @State 里：设置页跟着字幕刷新会频繁重算 body，不能每次都去问识别器。
private struct LiveTranslateRouteStatus: View {
    let speech: LiveTranslateSpeech
    let preferOnDevice: Bool
    @State private var routes: [LiveTranslateRecognitionRoute] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("livetranslate.settings.routeHeader")
                .foregroundStyle(.secondary)
            ForEach(routes) { route in
                Label {
                    Text(Self.describe(route))
                } icon: {
                    Image(systemName: route.kind == .onDevice ? "laptopcomputer" : "icloud")
                        .foregroundStyle(route.kind == .onDevice ? Color.accentColor : Color.secondary)
                }
            }
            if routes.contains(where: { $0.kind == .switching }) {
                Text("livetranslate.settings.route.switchingHelp")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 只在某种语言没有本机模型时给入口（去听写里加上它就有了）。轮流识别时不再引导去删英文听写：删不掉，
            // 删了系统也会自动装回来（2026-11-05）。
            if routes.contains(where: { $0.kind == .noModel }) {
                Button("livetranslate.settings.route.addLanguage") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
        }
        .font(.caption)
        .onAppear(perform: refresh)
        .onChange(of: speech) { _, _ in refresh() }
        .onChange(of: preferOnDevice) { _, _ in refresh() }
        // 从系统设置加完听写语言回来、窗口重新激活时刷新（模型可能已经装好）。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        routes = LiveTranslateSettings.recognitionRoutes(for: speech)
    }

    private static func describe(_ route: LiveTranslateRecognitionRoute) -> String {
        let name = route.language.endonym
        switch route.kind {
        case .onDevice: return L("livetranslate.settings.route.onDevice \(name)")
        case .noModel: return L("livetranslate.settings.route.noModel \(name)")
        case .switching: return L("livetranslate.settings.route.switching \(name)")
        }
    }
}

/// 「记录与纪要」：自动保存记录、保存位置、停止后用本地 AI 整理纪要（docs/live-translate/DESIGN.md §6）。
/// 改了从下一次开始生效，不用重开。
private struct LiveTranslateRecordSection: View {
    @AppStorage(LiveTranslateRecordSettings.enabledKey) private var enabled = false
    @AppStorage(LiveTranslateRecordSettings.folderKey) private var folder = ""
    @AppStorage(LiveTranslateRecordSettings.summaryKey) private var summary = true
    @ObservedObject private var corrector = OfflineTranslator.corrector

    var body: some View {
        Section("livetranslate.record.section") {
            Toggle("livetranslate.record.enabled", isOn: $enabled)
                .onChange(of: enabled) { _, value in
                    // 正在实时翻译：立刻开始 / 停止记这一次（和字幕条「记录」菜单里的开关一样）。
                    LiveTranslateController.shared.setRecording(value)
                }
            Text("livetranslate.record.help")
                .font(.caption)
                .foregroundStyle(.secondary)
            if enabled {
                HStack {
                    Text("livetranslate.record.folder")
                    Spacer()
                    Text(verbatim: displayPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // 新记录写进会议库（docs/meeting/TECH_DESIGN.md §2.3），原来的文件夹设置只用于迁移，这里不再能改。
                    if !writesToLibrary {
                        Button("livetranslate.record.choose") { chooseFolder() }
                    }
                    Button("livetranslate.record.openFolder") { LiveTranslateRecordSettings.openFolder() }
                }
                if writesToLibrary {
                    Text("livetranslate.record.libraryHelp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("livetranslate.record.summary", isOn: $summary)
                Group {
                    // 和结束时决定整不整理纪要的判断是同一条（LiveTranslateTranscript.finish）：看「会议纪要」选的模型，
                    // 不只是内置的 Qwen3-1.7B。`corrector` 仍然观察着，它下载完这一行会跟着变。
                    if AIService.shared.isReady(AIService.shared.route(for: .meetingMinutes), local: .generation) {
                        Text("livetranslate.record.summaryHelp")
                    } else {
                        Text("livetranslate.record.summaryNeedsModel")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var writesToLibrary: Bool { LiveTranslateController.recordLibrary != nil }

    private var displayPath: String {
        if writesToLibrary {
            return (LiveTranslateRecordSettings.effectiveFolder.path as NSString).abbreviatingWithTildeInPath
        }
        let path = folder.isEmpty ? LiveTranslateRecordSettings.defaultFolder.path : folder
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("livetranslate.record.choosePrompt")
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
        }
    }
}
