import SwiftUI

/// 实时翻译设置：音源、语言、翻译开关、字幕样式。
struct LiveTranslateSettingsView: View {
    @AppStorage(LiveTranslateSettings.sourceKey) private var source = LiveTranslateSource.system.rawValue
    @AppStorage(LiveTranslateSettings.languageKey) private var language = LiveTranslateLanguage.english.rawValue
    @AppStorage(LiveTranslateSettings.translateKey) private var translate = true
    @AppStorage(LiveTranslateSettings.onDeviceKey) private var onDevice = true
    @AppStorage(LiveTranslateSettings.displayKey) private var display = LiveTranslateDisplay.both.rawValue
    @AppStorage(LiveTranslateSettings.fontSizeKey) private var fontSize = LiveTranslateSettings.defaultFontSize
    @AppStorage(LiveTranslateSettings.opacityKey) private var opacity = LiveTranslateSettings.defaultOpacity

    @ObservedObject private var controller = LiveTranslateController.shared

    var body: some View {
        Form {
            Section {
                Text("livetranslate.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(controller.isRunning ? L("livetranslate.menu.stop") : L("livetranslate.menu.start")) {
                    controller.toggle()
                }
            }

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
                    ForEach(LiveTranslateLanguage.allCases) { item in
                        Text(item.displayName).tag(item.rawValue)
                    }
                }
                .onChange(of: language) { _, _ in controller.restartIfRunning() }

                Toggle("livetranslate.settings.onDevice", isOn: $onDevice)
                    .onChange(of: onDevice) { _, _ in controller.restartIfRunning() }
                Text("livetranslate.settings.onDeviceHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("livetranslate.settings.translateSection") {
                Toggle("livetranslate.settings.translate", isOn: $translate)
                    .onChange(of: translate) { _, _ in controller.restartIfRunning() }
                Text("livetranslate.settings.translateHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !LiveTranslateSettings.translationSupported {
                    Text("livetranslate.notice.needsMacOS15")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

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
        .formStyle(.grouped)
    }
}
