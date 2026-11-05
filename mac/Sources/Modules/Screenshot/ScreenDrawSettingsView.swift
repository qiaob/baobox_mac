import SwiftUI

/// 屏幕标注设置页：快捷键、画布范围、结束时是否保存预览（选项原在截图设置页里，键名不变）。
struct ScreenDrawSettingsView: View {
    @AppStorage(ScreenshotSettings.drawScreenScopeKey)
    private var drawScope = ScreenshotSettings.DrawScreenScope.current.rawValue
    @AppStorage(ScreenshotSettings.drawSavePreviewKey) private var drawSavePreview = false

    var body: some View {
        Form {
            Section {
                Text("screendraw.hotkey.subtitle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ModuleHotkeyRows(ids: [ScreenDrawTool.hotkeyID])
            }

            Section {
                Picker("screenshot.settings.drawScope", selection: $drawScope) {
                    ForEach(ScreenshotSettings.DrawScreenScope.allCases) { scope in
                        Text(scope.displayName).tag(scope.rawValue)
                    }
                }
                Toggle("screenshot.settings.drawSavePreview", isOn: $drawSavePreview)
                Text("screenshot.settings.drawScopeHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("screenshot.settings.drawSavePreviewHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
