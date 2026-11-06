import SwiftUI

/// 桌面宠物设置：宠物本体（启用 / 漫游 / 大小）、形象（选择 + 下载更多）、通知（提示音 / 逐来源开关）。
struct PetSettingsView: View {
    @AppStorage(PetSettings.enabledKey) private var enabled = true
    @AppStorage(PetSettings.roamKey) private var roam = true
    @AppStorage(PetSettings.sizeKey) private var size = 1.0
    @AppStorage(PetSettings.soundKey) private var sound = false
    @AppStorage("notify.source.claudecode") private var sourceClaude = true
    @AppStorage("notify.source.codex") private var sourceCodex = true
    @AppStorage("notify.source.livetranslate") private var sourceLive = true
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
                Toggle("pet.settings.roam", isOn: $roam)
                Slider(value: $size, in: 0.7...1.6) {
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
