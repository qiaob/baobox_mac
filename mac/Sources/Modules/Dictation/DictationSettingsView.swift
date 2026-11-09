import AppKit
import AVFoundation
import Speech
import SwiftUI
import UniformTypeIdentifiers

/// 语音听写设置（需求 §7）：唤起方式、识别、文本处理、AI 润色、插入、录音条、历史、术语表、权限。
struct DictationSettingsView: View {
    @AppStorage(DictationSettings.languageKey) private var language = DictationLanguageSetting.auto.rawValue
    @AppStorage(DictationSettings.pauseKey) private var pauseSeconds = DictationSettings.defaultPauseSeconds
    @AppStorage(DictationSettings.onDeviceKey) private var onDevice = true
    @AppStorage(DictationSettings.voiceCommandsKey) private var voiceCommands = true
    @AppStorage(DictationSettings.fillerFilterKey) private var fillerFilter = true
    @AppStorage(DictationSettings.polishModeKey) private var polishMode = DictationPolishMode.off.rawValue
    @AppStorage(DictationSettings.polishAppsKey) private var polishApps = ""
    @AppStorage(DictationSettings.insertModeKey) private var insertMode = DictationInsertMode.auto.rawValue
    @AppStorage(DictationSettings.barPositionKey) private var barPosition = DictationBarPosition.caret.rawValue
    @AppStorage(DictationSettings.soundsKey) private var sounds = false
    @AppStorage(DictationSettings.historyEnabledKey) private var historyEnabled = true
    @AppStorage(DictationSettings.historyLimitKey) private var historyLimit = DictationHistoryCodec.defaultLimit
    @AppStorage(LiveTranslateSettings.vocabularyKey) private var vocabulary = ""
    @ObservedObject private var history = DictationController.shared.history
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section {
                Text("dictation.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    modeLine("hand.tap", "dictation.settings.modeHold")
                    modeLine("repeat", "dictation.settings.modeToggle")
                    modeLine("text.append", "dictation.settings.modeLong")
                }
                .font(.callout)
                // id 与 DictationTool.hotkeys() 一致。
                ModuleHotkeyRows(ids: [DictationTool.holdHotkeyID, DictationTool.toggleHotkeyID, DictationTool.longHotkeyID])
                Text("dictation.settings.hotkeyHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("dictation.settings.recognitionSection") {
                Picker("dictation.settings.language", selection: $language) {
                    Text("dictation.language.auto").tag(DictationLanguageSetting.auto.rawValue)
                    Text(verbatim: followTitle).tag(DictationLanguageSetting.follow.rawValue)
                    Text("dictation.language.chinese").tag(DictationLanguageSetting.chinese.rawValue)
                    Text("dictation.language.english").tag(DictationLanguageSetting.english.rawValue)
                }
                Text("dictation.settings.languageHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("dictation.settings.pause", selection: $pauseSeconds) {
                    ForEach(DictationSettings.pauseOptions, id: \.self) { seconds in
                        if seconds == 0 {
                            Text("dictation.pause.off").tag(seconds)
                        } else {
                            Text(verbatim: L("dictation.pause.seconds \(seconds)")).tag(seconds)
                        }
                    }
                }
                Text("dictation.settings.pauseHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("dictation.settings.onDevice", isOn: $onDevice)
                ForEach(routeLines, id: \.self) { line in
                    Text(verbatim: line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("dictation.settings.textSection") {
                Toggle("dictation.settings.voiceCommands", isOn: $voiceCommands)
                Text("dictation.settings.voiceCommandsHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("dictation.settings.fillerFilter", isOn: $fillerFilter)
                Text("dictation.settings.fillerFilterHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("dictation.settings.polishSection") {
                Picker("dictation.settings.polish", selection: $polishMode) {
                    Text("dictation.polish.off").tag(DictationPolishMode.off.rawValue)
                    Text("dictation.polish.all").tag(DictationPolishMode.all.rawValue)
                    Text("dictation.polish.apps").tag(DictationPolishMode.apps.rawValue)
                }
                Text("dictation.settings.polishHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if polishMode == DictationPolishMode.apps.rawValue {
                    DictationAppList(raw: $polishApps)
                }
                if polishMode != DictationPolishMode.off.rawValue {
                    AIFeatureRow(definition: .dictationPolish, showsManage: true)
                    OfflineModelRow(translator: .corrector,
                                    title: "dictation.polish.modelTitle",
                                    notInstalledHelp: "dictation.polish.notInstalledHelp",
                                    installedHelp: "dictation.polish.installedHelp")
                }
            }

            Section("dictation.settings.insertSection") {
                Picker("dictation.settings.insertMode", selection: $insertMode) {
                    Text("dictation.insert.auto").tag(DictationInsertMode.auto.rawValue)
                    Text("dictation.insert.paste").tag(DictationInsertMode.paste.rawValue)
                }
                Text("dictation.settings.insertHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("dictation.settings.barSection") {
                Picker("dictation.settings.barPosition", selection: $barPosition) {
                    Text("dictation.bar.position.caret").tag(DictationBarPosition.caret.rawValue)
                    Text("dictation.bar.position.bottom").tag(DictationBarPosition.bottom.rawValue)
                }
                Toggle("dictation.settings.sounds", isOn: $sounds)
            }

            Section("dictation.settings.historySection") {
                Toggle("dictation.settings.historyEnabled", isOn: $historyEnabled)
                Stepper(value: $historyLimit, in: DictationHistoryCodec.limitRange, step: 10) {
                    Text(verbatim: L("dictation.settings.historyLimit \(historyLimit)"))
                }
                .disabled(!historyEnabled)
                .onChange(of: historyLimit) { _, limit in
                    history.trim(to: limit)
                }
                HStack {
                    Button("dictation.settings.openHistory") {
                        DictationController.shared.openHistory()
                    }
                    Button("dictation.settings.clearHistory") {
                        confirmingClear = true
                    }
                    .disabled(history.records.isEmpty)
                    Spacer()
                    Text(verbatim: L("dictation.settings.historyCount \(history.records.count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("dictation.settings.historyHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("dictation.settings.glossarySection") {
                HStack {
                    Text(verbatim: L("dictation.settings.glossaryCount \(TranslationGlossary.parse(vocabulary).count)"))
                    Spacer()
                    Button("dictation.settings.editGlossary") {
                        SettingsTabSelection.shared.selectedTab = "livetranslate"
                    }
                }
                Text("dictation.settings.glossaryHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("dictation.settings.permissionsSection") {
                DictationPermissionRow(title: "dictation.permission.microphone", granted: microphoneGranted,
                                       pane: "Privacy_Microphone")
                DictationPermissionRow(title: "dictation.permission.speech", granted: speechGranted,
                                       pane: "Privacy_SpeechRecognition")
                DictationPermissionRow(title: "dictation.permission.accessibility", granted: Permissions.hasAccessibility,
                                       pane: nil)
                Text("dictation.settings.permissionsHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(L("dictation.history.clearConfirm"), isPresented: $confirmingClear) {
            Button("dictation.history.clear", role: .destructive) { history.clear() }
            Button("common.cancel", role: .cancel) {}
        }
    }

    private func modeLine(_ symbol: String, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(key)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 「跟随实时翻译（当前：简体中文）」。
    private var followTitle: String {
        let current = DictationSettings.speechLanguages(for: .follow)
        let names = current.count > 1
            ? L("dictation.language.autoPair \(current[0].endonym) \(current[1].endonym)")
            : (current.first?.endonym ?? "")
        return L("dictation.language.follow \(names)")
    }

    /// 每种会用到的语言此刻走本机还是 Apple 服务器。
    private var routeLines: [String] {
        let setting = DictationLanguageSetting(rawValue: language) ?? .follow
        return DictationSettings.speechLanguages(for: setting).map { item in
            if !onDevice { return L("dictation.route.server \(item.endonym)") }
            return DictationRecognizer.supportsOnDevice(item)
                ? L("dictation.route.onDevice \(item.endonym)")
                : L("dictation.route.noModel \(item.endonym)")
        }
    }

    private var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private var speechGranted: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }
}

/// 一项权限：已授权 / 未授权 + 去设置。首次使用时才会弹系统授权，这里不预先申请（需求 §8）。
private struct DictationPermissionRow: View {
    let title: LocalizedStringKey
    let granted: Bool
    /// 系统设置「隐私与安全性」里的锚点；nil = 辅助功能（走 Permissions 的引导）。
    let pane: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if granted {
                Text("dictation.permission.granted")
                    .foregroundStyle(.secondary)
            } else {
                Text("dictation.permission.missing")
                    .foregroundStyle(.orange)
                Button("dictation.permission.open") {
                    if let pane {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                            NSWorkspace.shared.open(url)
                        }
                    } else {
                        Permissions.promptAccessibility()
                        Permissions.openSystemSettings(pane: .accessibility)
                    }
                }
            }
        }
    }
}

/// 「仅这些 App」的名单：图标 + 名称 + 移除；从「应用程序」里挑 App 加进来。存成 bundle id，一行一个。
private struct DictationAppList: View {
    @Binding var raw: String

    private var bundleIDs: [String] { DictationSettings.parseApps(raw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if bundleIDs.isEmpty {
                Text("dictation.polish.appsEmpty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(bundleIDs, id: \.self) { bundleID in
                HStack(spacing: 8) {
                    if let icon = Self.icon(for: bundleID) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    Text(verbatim: Self.name(for: bundleID))
                    Text(verbatim: bundleID)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        raw = bundleIDs.filter { $0 != bundleID }.joined(separator: "\n")
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L("dictation.polish.removeApp"))
                }
            }
            Button("dictation.polish.addApp") { addApp() }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        var ids = bundleIDs
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !ids.contains(id) else { continue }
            ids.append(id)
        }
        raw = ids.joined(separator: "\n")
    }

    private static func appURL(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private static func name(for bundleID: String) -> String {
        guard let url = appURL(for: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func icon(for bundleID: String) -> NSImage? {
        appURL(for: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}
