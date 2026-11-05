import SwiftUI

/// 桌面宠物设置：宠物本体（启用 / 漫游 / 大小）与通知（提示音 / 逐来源开关）。
struct PetSettingsView: View {
    @AppStorage(PetSettings.enabledKey) private var enabled = true
    @AppStorage(PetSettings.roamKey) private var roam = true
    @AppStorage(PetSettings.sizeKey) private var size = 1.0
    @AppStorage(PetSettings.soundKey) private var sound = false
    @AppStorage("notify.source.claudecode") private var sourceClaude = true
    @AppStorage("notify.source.codex") private var sourceCodex = true
    @AppStorage("notify.source.livetranslate") private var sourceLive = true

    var body: some View {
        Form {
            Section {
                Text("pet.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("pet.settings.petSection") {
                Toggle("pet.settings.enabled", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in
                        PetController.shared.applyVisibility()
                    }
                Toggle("pet.settings.roam", isOn: $roam)
                Slider(value: $size, in: 0.7...1.6) {
                    Text("pet.settings.size")
                }
                .onChange(of: size) { _, _ in
                    PetController.shared.applySize()
                }
                Text("pet.settings.rendererNote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("pet.settings.notifySection") {
                Toggle("pet.settings.sound", isOn: $sound)
                Toggle("pet.settings.sourceClaude", isOn: $sourceClaude)
                Toggle("pet.settings.sourceCodex", isOn: $sourceCodex)
                Toggle("pet.settings.sourceLive", isOn: $sourceLive)
            }
        }
        .formStyle(.grouped)
    }
}
