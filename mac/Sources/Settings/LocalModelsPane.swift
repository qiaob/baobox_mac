import SwiftUI

/// 「AI」页的「本机模型」栏（docs/local-models/DESIGN.md §1）：这台 Mac 的内存和磁盘、怎么选、已装的模型、添加模型。
/// 所有本地模型一视同仁：都能下载、启动 / 停止、开机自启、删除。
struct LocalModelsPane: View {
    @ObservedObject private var observer = LocalModelsObserver.shared
    @ObservedObject private var navigation = AISettingsNavigation.shared
    @State private var selected = LocalModels.recommended(totalMemory: MachineInfo.totalMemory)?.id
        ?? LocalModels.defaultEntry(for: .generation).id
    @State private var available: Int64?
    @State private var freeDisk: Int64?
    @State private var footprints: [String: Int64] = [:]
    @State private var pendingStart: LocalModelEntry?
    @State private var pendingDownload: LocalModelEntry?
    @State private var diskShort: LocalModelEntry?
    /// 自定义：粘贴的链接、查询中、出错原因。
    @State private var customLink = ""
    @State private var resolving = false
    @State private var customError: String?

    private let total = MachineInfo.totalMemory
    private let chip = MachineInfo.chipName

    /// 下载前要留的余量。
    private static let diskMargin: Int64 = 512 << 20
    /// 下拉框最后那一项「自定义…」的值。
    private static let customTag = "custom:new"
    /// 「添加模型」那一行（「去下载」滚到这里）。
    private static let addRowID = "localmodel.add"
    /// 推荐说明里「用途」那一列的宽度（放得下「纪要、周报、润色」）。
    private static let guidePurposeWidth: CGFloat = 112

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                machineSection
                guideSection
                installedSection
                addSection
            }
            .formStyle(.grouped)
            .onAppear { applyFocus(proxy) }
            .onChange(of: navigation.focusLocalModel) { _, _ in applyFocus(proxy) }
        }
    }

    // MARK: - 这台 Mac

    private var machineSection: some View {
        Section {
            LabeledContent("localmodel.mac") {
                Text(verbatim: macLine)
            }
            .task { await refreshLoop() }
            .alert(Text("localmodel.confirmStartTitle"), isPresented: presence($pendingStart), presenting: pendingStart) { entry in
                Button("localmodel.startAnyway") { entry.translator.start() }
                Button("localmodel.cancel", role: .cancel) {}
            } message: { entry in
                Text(verbatim: L("localmodel.confirmStartMessage \(MachineInfo.text(available ?? 0)) \(entry.name) \(MachineInfo.text(entry.memoryNeed))"))
            }
            .alert(Text("localmodel.confirmDownloadTitle"), isPresented: presence($pendingDownload),
                   presenting: pendingDownload) { entry in
                Button("localmodel.downloadAnyway") { entry.translator.startDownload() }
                Button("localmodel.cancel", role: .cancel) {}
            } message: { entry in
                Text(verbatim: L("localmodel.confirmDownloadMessage \(entry.name) \(MachineInfo.text(entry.memoryNeed)) \(MachineInfo.text(total))"))
            }
            .alert(Text("localmodel.diskShortTitle"), isPresented: presence($diskShort), presenting: diskShort) { _ in
                Button("localmodel.ok", role: .cancel) {}
            } message: { entry in
                Text(verbatim: L("localmodel.diskShortMessage \(entry.name) \(MachineInfo.text(entry.model.byteSize)) \(MachineInfo.text(freeDisk ?? 0))"))
            }
            LabeledContent("localmodel.available") {
                Text(verbatim: availableLine)
            }
        } header: {
            Text("localmodel.paneIntro")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }

    private var macLine: String {
        let memory = L("localmodel.memory \(MachineInfo.text(total))")
        return [chip, memory].compactMap { $0 }.joined(separator: " · ")
    }

    private var availableLine: String {
        let memory = available.map { L("localmodel.availableMemory \(MachineInfo.text($0))") }
        let disk = freeDisk.map { L("localmodel.freeDisk \(MachineInfo.text($0))") }
        let parts = [memory, disk].compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    // MARK: - 怎么选

    /// 推荐说明（docs/local-models/DESIGN.md §3）：按用途各推荐一个、写明为什么；按这台 Mac 的内存生成。
    private var guideSection: some View {
        let translation = LocalModels.defaultEntry(for: .translation)
        let quick = LocalModels.defaultEntry(for: .generation)
        let best = LocalModels.recommended(totalMemory: total).flatMap { $0.id == quick.id ? nil : $0 }
        let avoid = LocalModels.catalog.filter {
            $0.isRecommendable && LocalModels.fit($0, totalMemory: total) == .tooBig
        }
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                guideRow(L("localmodel.guide.translation"), translation.name,
                         L("localmodel.guide.translationWhy \(MachineInfo.text(translation.memoryNeed))"))
                guideRow(L("localmodel.guide.correction"), quick.name, L("localmodel.guide.correctionWhy"))
                if let best {
                    guideRow(L("localmodel.guide.writing"), best.name,
                             L("localmodel.guide.writingWhy \(quick.name) \(MachineInfo.text(best.memoryNeed))"))
                } else {
                    guideRow(L("localmodel.guide.writing"), quick.name, L("localmodel.guide.writingSmall"))
                }
                if !avoid.isEmpty {
                    guideRow(L("localmodel.guide.avoid"), ListFormatter.localizedString(byJoining: avoid.map(\.name)),
                             L("localmodel.guide.avoidWhy"), warning: true)
                }
                guideRow(L("localmodel.guide.cloud"), L("localmodel.guide.cloudModel"), L("localmodel.guide.cloudWhy"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } header: {
            Text(verbatim: L("localmodel.guide.title \(MachineInfo.text(total))"))
        }
    }

    /// 推荐说明的一行：用途（固定宽度，各行对齐）| 模型名 + 为什么。
    private func guideRow(_ purpose: String, _ model: String, _ why: String, warning: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: purpose)
                .foregroundStyle(.secondary)
                .frame(width: Self.guidePurposeWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model)
                    .foregroundStyle(warning ? Color.orange : Color.primary)
                Text(verbatim: why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 已装的模型

    /// 装了的，以及下载中 / 暂停 / 出错的（切了下拉框也看得到进度）。所有模型规则一样。
    private var listedEntries: [LocalModelEntry] {
        LocalModels.all.filter { entry in
            let translator = entry.translator
            switch translator.modelState {
            case .installed, .downloading, .verifying, .failed: return true
            case .notInstalled: return translator.hasPartialDownload
            }
        }
    }

    private var installedSection: some View {
        Section {
            if listedEntries.isEmpty {
                caption(L("localmodel.listEmpty"))
            }
            ForEach(listedEntries) { entry in
                LocalModelRow(entry: entry, translator: entry.translator, footprint: footprints[entry.id],
                              onStart: { requestStart(entry) }, onDownload: { requestDownload(entry) })
            }
            caption(L("localmodel.autostartHelp"))
        } header: {
            Text("localmodel.listSection")
        }
    }

    // MARK: - 添加模型

    private var addSection: some View {
        Section {
            Picker("localmodel.install", selection: $selected) {
                installOptions
            }
            .id(Self.addRowID)
            if selected == Self.customTag {
                customRows
            } else if let entry = LocalModels.entry(selected) {
                installRow(entry)
            }
        } header: {
            Text("localmodel.addSection")
        }
    }

    /// 按这台 Mac 的内存分组：推荐 / 可以用 / 内存不够；最后一项「自定义…」。
    @ViewBuilder
    private var installOptions: some View {
        let entries = LocalModels.all
        let recommended = entries.filter { LocalModels.fit($0, totalMemory: total) == .recommended }
        let usable = entries.filter {
            let fit = LocalModels.fit($0, totalMemory: total)
            return fit == .ok || fit == .heavy
        }
        let tooBig = entries.filter { LocalModels.fit($0, totalMemory: total) == .tooBig }
        if !recommended.isEmpty {
            Section(L("localmodel.group.recommended")) {
                ForEach(recommended) { Text(verbatim: optionLabel($0)).tag($0.id) }
            }
        }
        if !usable.isEmpty {
            Section(L("localmodel.group.usable")) {
                ForEach(usable) { Text(verbatim: optionLabel($0)).tag($0.id) }
            }
        }
        if !tooBig.isEmpty {
            Section(L("localmodel.group.tooBig")) {
                ForEach(tooBig) { Text(verbatim: optionLabel($0)).tag($0.id) }
            }
        }
        Divider()
        Text("localmodel.customItem").tag(Self.customTag)
    }

    /// 「Qwen3-8B · 通义千问 · 4.68 GB」，装了的后面标「已装」。
    private func optionLabel(_ entry: LocalModelEntry) -> String {
        let label = "\(entry.name) · \(entry.vendor) · \(MachineInfo.text(entry.model.byteSize))"
        return entry.translator.isReady ? L("localmodel.installedLabel \(label)") : label
    }

    @ViewBuilder
    private func installRow(_ entry: LocalModelEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.usage)
                    .font(.caption)
                Text(verbatim: L("localmodel.info \(MachineInfo.text(entry.model.byteSize)) \(MachineInfo.text(entry.memoryNeed))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if LocalModels.fit(entry, totalMemory: total) == .tooBig, !entry.translator.isReady {
                    Text(verbatim: L("localmodel.tooBigNote"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            switch entry.translator.modelState {
            case .installed:
                Text("localmodel.alreadyInstalled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .downloading, .verifying, .failed:
                Text("localmodel.inProgress")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .notInstalled:
                Button(entry.translator.hasPartialDownload ? L("localmodel.resume") : L("localmodel.download")) {
                    requestDownload(entry)
                }
            }
        }
    }

    /// 自定义：粘贴 Hugging Face 上 GGUF 文件的链接 → 查大小和校验值 → 加进清单并开始下载。
    @ViewBuilder
    private var customRows: some View {
        HStack(spacing: 8) {
            TextField("", text: $customLink, prompt: Text(verbatim: "https://huggingface.co/…/resolve/main/….gguf"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { addCustom() }
            Button(resolving ? L("localmodel.custom.resolving") : L("localmodel.custom.add")) {
                addCustom()
            }
            .disabled(resolving || customLink.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        caption(customError ?? L("localmodel.custom.help"), warning: customError != nil)
    }

    private func addCustom() {
        let link = customLink
        resolving = true
        customError = nil
        Task {
            do {
                let model = try await CustomModelImport.resolve(link)
                LocalModels.addCustom(model)
                customLink = ""
                selected = model.id
                if let entry = LocalModels.entry(model.id) { requestDownload(entry) }
            } catch {
                customError = error.localizedDescription
            }
            resolving = false
        }
    }

    // MARK: - 动作

    private func requestDownload(_ entry: LocalModelEntry) {
        if let free = MachineInfo.freeDiskSpace(at: URL(fileURLWithPath: NSHomeDirectory())),
           free < entry.model.byteSize + Self.diskMargin {
            freeDisk = free
            diskShort = entry
            return
        }
        if LocalModels.fit(entry, totalMemory: total) == .tooBig {
            pendingDownload = entry
            return
        }
        entry.translator.startDownload()
    }

    /// 启动前查一次可用内存：不够就先确认（docs/local-models/DESIGN.md §4）。
    private func requestStart(_ entry: LocalModelEntry) {
        let now = MachineInfo.availableMemory()
        available = now
        if let now, now < entry.memoryNeed {
            pendingStart = entry
            return
        }
        entry.translator.start()
    }

    /// 功能栏的「去下载」：把那个模型选进「添加模型」，滚过去。
    private func applyFocus(_ proxy: ScrollViewProxy) {
        guard let id = navigation.focusLocalModel else { return }
        navigation.focusLocalModel = nil
        if LocalModels.entry(id) != nil { selected = id }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(Self.addRowID, anchor: .center) }
        }
    }

    /// 页面开着时每 3 秒刷新可用内存、磁盘、各推理进程的实际占用。
    private func refreshLoop() async {
        while !Task.isCancelled {
            available = MachineInfo.availableMemory()
            freeDisk = MachineInfo.freeDiskSpace(at: URL(fileURLWithPath: NSHomeDirectory()))
            var prints: [String: Int64] = [:]
            for entry in LocalModels.all {
                if let pid = entry.translator.serverPID, let bytes = MachineInfo.footprint(pid: pid) {
                    prints[entry.id] = bytes
                }
            }
            footprints = prints
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func caption(_ text: String, warning: Bool = false) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(warning ? Color.orange : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func presence(_ item: Binding<LocalModelEntry?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// 本地模型列表里的一行：名字、用途和状态；右边是下载 / 暂停，或开机自启、启动 / 停止、删除。
struct LocalModelRow: View {
    let entry: LocalModelEntry
    @ObservedObject var translator: OfflineTranslator
    let footprint: Int64?
    let onStart: () -> Void
    let onDownload: () -> Void

    @State private var autostart: Bool
    @State private var confirmDelete = false

    init(entry: LocalModelEntry, translator: OfflineTranslator, footprint: Int64?,
         onStart: @escaping () -> Void, onDownload: @escaping () -> Void) {
        self.entry = entry
        self.translator = translator
        self.footprint = footprint
        self.onStart = onStart
        self.onDownload = onDownload
        _autostart = State(initialValue: LocalModels.isAutostart(entry.id))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name)
                Text(verbatim: "\(entry.usage) · \(status.text)")
                    .font(.caption)
                    .foregroundStyle(status.warning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            controls
        }
        .alert(Text(verbatim: L("localmodel.confirmDeleteTitle \(entry.name)")), isPresented: $confirmDelete) {
            Button("localmodel.delete", role: .destructive) { delete() }
            Button("localmodel.cancel", role: .cancel) {}
        } message: {
            Text("localmodel.confirmDeleteMessage")
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch translator.modelState {
        case .notInstalled:
            Button(translator.hasPartialDownload ? L("localmodel.resume") : L("localmodel.download")) { onDownload() }
            if translator.hasPartialDownload { trashButton }
        case .downloading(let progress):
            ProgressView(value: progress)
                .frame(width: 110)
            Button(L("localmodel.pause")) { translator.cancelDownload() }
        case .verifying:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Button(L("localmodel.retry")) { onDownload() }
            trashButton
        case .installed:
            Toggle(L("localmodel.autostart"), isOn: Binding(get: { autostart }, set: { on in
                autostart = on
                LocalModels.setAutostart(on, for: entry)
            }))
            .toggleStyle(.checkbox)
            .fixedSize()
            Button(translator.isServerRunning ? L("localmodel.stop") : L("localmodel.start")) {
                if translator.isServerRunning { translator.stop() } else { onStart() }
            }
            .disabled(translator.isStartingServer)
            trashButton
        }
    }

    private var trashButton: some View {
        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help(L("localmodel.delete"))
    }

    private var status: (text: String, warning: Bool) {
        let size = MachineInfo.text(entry.model.byteSize)
        switch translator.modelState {
        case .notInstalled:
            if translator.hasPartialDownload {
                return (L("localmodel.status.paused \(MachineInfo.text(translator.downloadedBytes)) \(size)"), false)
            }
            return (L("localmodel.status.notDownloaded \(size)"), false)
        case .downloading(let progress):
            return (L("localmodel.status.downloading \(Int(progress * 100)) \(size)"), false)
        case .verifying:
            return (L("localmodel.status.verifying"), false)
        case .failed(let message):
            return (L("localmodel.status.failed \(message)"), true)
        case .installed:
            if translator.isStartingServer { return (L("localmodel.status.starting"), false) }
            if translator.isServerRunning {
                if let footprint { return (L("localmodel.status.runningUsing \(MachineInfo.text(footprint))"), false) }
                return (L("localmodel.status.running"), false)
            }
            return (L("localmodel.status.idle"), false)
        }
    }

    private func delete() {
        autostart = false
        LocalModels.setAutostart(false, for: entry)
        translator.deleteModel()
        if entry.isCustom { LocalModels.removeCustom(entry.id) }
    }
}
