import SwiftUI

/// 模块设置页的翻译区块（docs/ai-service/DESIGN.md §6.2）：这个翻译功能用哪个模型（与「AI」页的功能表是同一行、同一份设置）
/// + 引擎说明 + 离线模型下载。划词助手、字幕与同传的设置页各嵌一块。字幕与同传运行中改了，按 `AIFeatureSettings.didChange` 重启。
struct TranslationEngineSection: View {
    let definition: AIFeatureDefinition

    var body: some View {
        Section {
            AIFeatureRow(definition: definition, showsManage: true)
            Text(TranslationSettings.systemAvailable
                 ? L("translation.settings.engineHelp")
                 : L("translation.settings.engineHelpNoSystem"))
                .font(.caption)
                .foregroundStyle(.secondary)
            OfflineModelRow()
        } header: {
            Text("translation.settings.section")
        }
    }
}

/// 本地模型的状态与操作（下载 / 暂停 / 删除）。默认是离线翻译模型；识别纠错模型传自己的实例和文案。
/// `compact` = 划词浮层里的精简样式。
struct OfflineModelRow: View {
    @ObservedObject private var offline: OfflineTranslator
    private let title: LocalizedStringKey
    private let notInstalledHelp: LocalizedStringKey
    private let installedHelp: LocalizedStringKey
    let compact: Bool

    /// `translator` 不给 = 翻译模型（默认参数里不能直接写 `.shared`：默认值在非隔离上下文里求值）。
    @MainActor
    init(translator: OfflineTranslator? = nil,
         title: LocalizedStringKey = "translation.model.title",
         notInstalledHelp: LocalizedStringKey = "translation.model.notInstalledHelp",
         installedHelp: LocalizedStringKey = "translation.model.installed",
         compact: Bool = false) {
        _offline = ObservedObject(wrappedValue: translator ?? .shared)
        self.title = title
        self.notInstalledHelp = notInstalledHelp
        self.installedHelp = installedHelp
        self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !compact {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(verbatim: "\(offline.model.displayName) · \(offline.model.sizeText) · \(L("translation.model.local"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    actions
                }
            } else {
                HStack(spacing: 8) {
                    actions
                    Spacer(minLength: 0)
                }
            }
            status
            if !offline.isHelperBundled {
                Text("translation.model.helperMissing")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch offline.modelState {
        case .notInstalled:
            Button(offline.hasPartialDownload
                   ? L("translation.model.resume")
                   : L("translation.model.download \(offline.model.sizeText)")) {
                offline.startDownload()
            }
            .disabled(!offline.isHelperBundled)
        case .downloading:
            Button(L("translation.model.pause")) {
                offline.cancelDownload()
            }
        case .verifying:
            ProgressView().controlSize(.small)
        case .installed:
            if !compact {
                Button(L("translation.model.delete"), role: .destructive) {
                    offline.deleteModel()
                }
            }
        case .failed:
            Button(L("translation.model.retry")) {
                offline.startDownload()
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch offline.modelState {
        case .notInstalled:
            if !compact {
                Text(notInstalledHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .downloading(let progress):
            ProgressView(value: progress)
            Text(verbatim: "\(ByteCountFormatter.string(fromByteCount: offline.downloadedBytes, countStyle: .file)) / \(offline.model.sizeText)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .verifying:
            Text("translation.model.verifying")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .installed:
            Text(installedHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
