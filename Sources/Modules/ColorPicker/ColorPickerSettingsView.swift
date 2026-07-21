import SwiftUI

/// 取色器设置：输出格式、Hex 大写、取色后自动复制。
struct ColorPickerSettingsView: View {
    @AppStorage(ColorPickerSettings.formatKey) private var format: ColorFormat = .hex
    @AppStorage(ColorPickerSettings.hexUppercaseKey) private var hexUppercase = true
    @AppStorage(ColorPickerSettings.autoCopyKey) private var autoCopy = true

    /// 用于示例展示的固定品牌色。
    private static let sampleHex = "#1AB3A6"

    var body: some View {
        Form {
            Section("colorpicker.settings.formatSection") {
                Picker("colorpicker.settings.format", selection: $format) {
                    ForEach(ColorFormat.allCases) { fmt in
                        Text(verbatim: fmt.displayName).tag(fmt)
                    }
                }
                Text("common.example \(exampleText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Toggle("colorpicker.settings.hexUppercase", isOn: $hexUppercase)
                    .disabled(format != .hex)
            }

            Section("colorpicker.settings.behaviorSection") {
                Toggle("colorpicker.settings.autoCopy", isOn: $autoCopy)
                Text("colorpicker.settings.help \(ColorHistoryStore.maxEntries)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var exampleText: String {
        ColorFormatter.display(hex: Self.sampleHex, format: format, hexUppercase: hexUppercase)
    }
}
