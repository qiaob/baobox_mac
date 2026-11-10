import SwiftUI

/// 桌面宠物设置：宠物本体（启用 / 漫游 / 大小）、形象（选择 + 下载更多）、通知（提示音 / 逐来源开关）。
struct PetSettingsView: View {
    @AppStorage(PetSettings.enabledKey) private var enabled = true
    @AppStorage(PetSettings.activityKey) private var activity = PetSettings.activity.rawValue
    @AppStorage(PetSettings.avoidKey) private var avoid = true
    @AppStorage(PetSettings.contentAwareKey) private var contentAware = true
    @AppStorage(PetSettings.entranceKey) private var entrance = true
    @AppStorage(PetSettings.sizeKey) private var size = 1.0
    @AppStorage(PetSettings.rangeKey) private var range = PetRange.bottom.rawValue
    @AppStorage(NotifySettings.soundKey) private var sound = false
    @AppStorage("notify.source.claudecode") private var sourceClaude = true
    @AppStorage("notify.source.codex") private var sourceCodex = true
    @AppStorage("notify.source.livetranslate") private var sourceLive = true
    @AppStorage("notify.source.focus") private var sourceFocus = true
    @ObservedObject private var pet = PetController.shared
    @ObservedObject private var store = PetPackStore.shared

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
                Picker("pet.settings.activity", selection: $activity) {
                    Text("pet.activity.still").tag(PetActivity.still.rawValue)
                    Text("pet.activity.calm").tag(PetActivity.calm.rawValue)
                    Text("pet.activity.normal").tag(PetActivity.normal.rawValue)
                    Text("pet.activity.lively").tag(PetActivity.lively.rawValue)
                }
                .onChange(of: activity) { _, _ in
                    PetController.shared.applyActivity()
                }
                Toggle("pet.settings.avoid", isOn: $avoid)
                    .onChange(of: avoid) { _, _ in
                        PetController.shared.applyActivity()
                    }
                if avoid {
                    Toggle("pet.settings.contentAware", isOn: $contentAware)
                        .onChange(of: contentAware) { _, _ in
                            PetController.shared.applyActivity()
                        }
                }
                Text("pet.settings.activityHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("pet.settings.entrance", isOn: $entrance)
                Picker("pet.settings.range", selection: $range) {
                    Text("pet.range.bottom").tag(PetRange.bottom.rawValue)
                    Text("pet.range.windows").tag(PetRange.windows.rawValue)
                    Text("pet.range.custom").tag(PetRange.custom.rawValue)
                    Text("pet.range.screen").tag(PetRange.screen.rawValue)
                }
                .onChange(of: range) { _, newValue in
                    // 第一次选「自定义区域」还没框过：直接进框选。
                    if newValue == PetRange.custom.rawValue, PetSettings.rangeRect == nil {
                        PetController.shared.pickRegion()
                    } else {
                        PetController.shared.applyRange()
                    }
                }
                if range == PetRange.custom.rawValue {
                    HStack {
                        Button("pet.settings.pickRegion") {
                            PetController.shared.pickRegion()
                        }
                        Spacer()
                    }
                }
                Text("pet.settings.rangeHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $size, in: 0.6...3.5) {
                    Text("pet.settings.size")
                }
                .onChange(of: size) { _, _ in
                    PetController.shared.applySize()
                }
            }

            Section("pet.settings.characterSection") {
                if pet.packages.isEmpty {
                    Text("pet.settings.noCharacter")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("pet.settings.character", selection: characterSelection) {
                        ForEach(pet.packages, id: \.id) { item in
                            Text(verbatim: item.name).tag(item.id)
                        }
                    }
                    if let credit = PetCatalog.info(for: pet.currentCharacterID)?.credit {
                        Text(L("pet.settings.credit \(credit)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("pet.settings.openFolder") {
                        PetController.shared.openPetsFolder()
                    }
                    Spacer()
                }
                Text("pet.settings.customHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !PetCatalog.downloadable.isEmpty {
                Section("pet.settings.moreSection") {
                    ForEach(PetCatalog.downloadable, id: \.id) { pack in
                        PetPackRow(pack: pack, store: store)
                    }
                }
            }

            Section("pet.settings.notifySection") {
                Toggle("pet.settings.sound", isOn: $sound)
                Toggle("pet.settings.sourceClaude", isOn: $sourceClaude)
                Toggle("pet.settings.sourceCodex", isOn: $sourceCodex)
                Toggle("pet.settings.sourceLive", isOn: $sourceLive)
                Toggle("pet.settings.sourceFocus", isOn: $sourceFocus)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // 用户可能刚往素材文件夹里放了自制形象 / 手动删了下载的形象：每次打开都按磁盘现状刷新。
            PetController.shared.reloadCharacter()
            store.refresh()
        }
    }

    private var characterSelection: Binding<String> {
        Binding(
            get: { pet.currentCharacterID },
            set: { PetController.shared.selectCharacter($0) }
        )
    }
}

/// 一个可下载形象：名字、署名与大小；下载 / 删除 / 重试，下载中显示进度。样式照离线模型那一行（OfflineModelRow）。
struct PetPackRow: View {
    let pack: PetPackInfo
    @ObservedObject var store: PetPackStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: pack.name)
                    Text(verbatim: "\(pack.credit) · \(pack.sizeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }
            status
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch store.state(of: pack) {
        case .notInstalled:
            Button(L("pet.settings.download")) {
                store.download(pack)
            }
        case .downloading:
            ProgressView().controlSize(.small)
        case .installed:
            Button(L("pet.settings.delete"), role: .destructive) {
                store.delete(pack)
            }
        case .failed:
            Button(L("pet.settings.retry")) {
                store.download(pack)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch store.state(of: pack) {
        case .downloading(let progress):
            ProgressView(value: progress)
        case .failed(let message):
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .notInstalled, .installed:
            EmptyView()
        }
    }
}
