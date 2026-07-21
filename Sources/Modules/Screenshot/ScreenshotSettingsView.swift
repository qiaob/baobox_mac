import SwiftUI
import AppKit

/// 截图设置：自动保存、保存目录、文件名模板。
struct ScreenshotSettingsView: View {
    @AppStorage(ScreenshotSettings.autoSaveKey) private var autoSave = true
    @AppStorage(ScreenshotSettings.saveDirectoryKey) private var saveDirectory = ScreenshotSettings.defaultDirectory
    @AppStorage(ScreenshotSettings.filenameTemplateKey) private var filenameTemplate = ScreenshotSettings.defaultTemplate
    @AppStorage(ScreenshotSettings.historyLimitKey) private var historyLimit = 20
    @AppStorage(ScreenshotSettings.recordSystemAudioKey) private var recordSystemAudio = false
    @AppStorage(ScreenshotSettings.recordMicrophoneKey) private var recordMicrophone = false
    @AppStorage(ScreenshotSettings.recordFormatKey) private var recordFormat = ScreenshotSettings.RecordFormat.mp4.rawValue
    @AppStorage(ScreenshotSettings.recordMixAudioKey) private var recordMixAudio = true

    var body: some View {
        Form {
            Section("screenshot.settings.saveSection") {
                Toggle("screenshot.settings.autoSave", isOn: $autoSave)

                HStack {
                    Text("screenshot.settings.location")
                    Spacer()
                    Text(displayPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("screenshot.settings.choose") { chooseDirectory() }
                }
                .disabled(!autoSave)
            }

            Section("screenshot.settings.filenameSection") {
                TextField("screenshot.settings.template", text: $filenameTemplate)
                Text("common.example \(exampleName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("screenshot.settings.templateHelp")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("screenshot.settings.recordSection") {
                Picker("screenshot.settings.format", selection: $recordFormat) {
                    Text(verbatim: "MP4").tag(ScreenshotSettings.RecordFormat.mp4.rawValue)
                    Text(verbatim: "GIF").tag(ScreenshotSettings.RecordFormat.gif.rawValue)
                }
                .pickerStyle(.segmented)

                Toggle("screenshot.settings.recordAudio", isOn: $recordSystemAudio)
                    .disabled(isGIF)
                Toggle("screenshot.settings.recordMic", isOn: $recordMicrophone)
                    .disabled(isGIF)
                Toggle("screenshot.settings.mixAudio", isOn: $recordMixAudio)
                    .disabled(isGIF || !(recordSystemAudio && recordMicrophone))
                Text("screenshot.settings.recordAudioHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("screenshot.settings.mixAudioHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("screenshot.settings.historySection") {
                Stepper("screenshot.settings.historyLimit \(historyLimit)", value: $historyLimit, in: 5...100, step: 5)
                Text("screenshot.settings.historyLimitHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: historyLimit) { _, _ in
            ScreenshotHistoryStore.shared.trimToLimit()
        }
    }

    private var isGIF: Bool {
        recordFormat == ScreenshotSettings.RecordFormat.gif.rawValue
    }

    private var displayPath: String {
        (saveDirectory.isEmpty ? ScreenshotSettings.defaultDirectory : saveDirectory)
    }

    private var exampleName: String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateFormat = filenameTemplate
        return formatter.string(from: Date()) + ".png"
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("screenshot.settings.choosePrompt")
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url.path
        }
    }
}
