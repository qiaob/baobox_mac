import SwiftUI
import AppKit

/// 截图设置：自动保存、保存目录、文件名模板。
struct ScreenshotSettingsView: View {
    @AppStorage(ScreenshotSettings.autoSaveKey) private var autoSave = true
    @AppStorage(ScreenshotSettings.saveDirectoryKey) private var saveDirectory = ScreenshotSettings.defaultDirectory
    @AppStorage(ScreenshotSettings.filenameTemplateKey) private var filenameTemplate = ScreenshotSettings.defaultTemplate

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
        }
        .formStyle(.grouped)
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
