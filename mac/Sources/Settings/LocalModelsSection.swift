import SwiftUI

/// 「AI」页最上面的本地模型（docs/local-models/DESIGN.md §1）：这台 Mac 的内存和磁盘、建议装哪个、下拉框选模型下载；
/// 下面列出已装的模型（内置的两个一直在），每个能启动 / 停止、开机自启、删除。
struct LocalModelsSection: View {
    @ObservedObject private var observer = LocalModelsObserver.shared
    @State private var selected = LocalModels.recommended(totalMemory: MachineInfo.totalMemory)?.id
        ?? LocalModels.optional[0].id
    @State private var available: Int64?
    @State private var freeDisk: Int64?
    @State private var footprints: [String: Int64] = [:]
    @State private var pendingStart: LocalModelEntry?
    @State private var pendingDownload: LocalModelEntry?
    @State private var diskShort: LocalModelEntry?

    private let total = MachineInfo.totalMemory
    private let chip = MachineInfo.chipName

    /// 下载前要留的余量：校验时还会写一份暂存文件的元数据，留 0.5 GB 免得把磁盘写满。
    private static let diskMargin: Int64 = 512 << 20

    var body: some View {
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
            caption(recommendationLine)
            Picker("localmodel.install", selection: $selected) {
                ForEach(LocalModels.optional) { entry in
                    Text(verbatim: "\(entry.name)（\(fitText(entry))）").tag(entry.id)
                }
            }
            if let entry = LocalModels.entry(selected) {
                installRow(entry)
            }
        } header: {
            Text("localmodel.section")
        }


        Section {
            ForEach(listedEntries) { entry in
                LocalModelRow(entry: entry, translator: entry.translator, footprint: footprints[entry.id],
                              onStart: { requestStart(entry) }, onDownload: { requestDownload(entry) })
            }
            caption(L("localmodel.autostartHelp"))
        } header: {
            Text("localmodel.listSection")
        }
    }

    // MARK: - 文案

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

    private var recommendationLine: String {
        guard let best = LocalModels.recommended(totalMemory: total) else { return L("localmodel.recommendNone") }
        return L("localmodel.recommend \(best.name)")
    }

    private func fitText(_ entry: LocalModelEntry) -> String {
        switch LocalModels.fit(entry, totalMemory: total) {
        case .recommended: return L("localmodel.fit.recommended")
        case .ok: return L("localmodel.fit.ok")
        case .heavy: return L("localmodel.fit.heavy")
        case .tooBig: return L("localmodel.fit.tooBig")
        }
    }

    /// 已装的（内置的两个一直列出，没下载的在这里下），以及下载中 / 暂停 / 出错的大模型（切了下拉框也看得到进度）。
    private var listedEntries: [LocalModelEntry] {
        LocalModels.builtIn + LocalModels.optional.filter { entry in
            let translator = entry.translator
            switch translator.modelState {
            case .installed, .downloading, .verifying, .failed: return true
            case .notInstalled: return translator.hasPartialDownload
            }
        }
    }

    @ViewBuilder
    private func installRow(_ entry: LocalModelEntry) -> some View {
        caption(L("localmodel.info \(MachineInfo.text(entry.model.byteSize)) \(MachineInfo.text(entry.memoryNeed)) \(entry.usage)"))
        switch entry.translator.modelState {
        case .installed:
            caption(L("localmodel.alreadyInstalled"))
        case .downloading, .verifying, .failed:
            caption(L("localmodel.inProgress"))
        case .notInstalled:
            HStack {
                if LocalModels.fit(entry, totalMemory: total) == .tooBig {
                    Text(verbatim: L("localmodel.tooBigNote"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(entry.translator.hasPartialDownload ? L("localmodel.resume") : L("localmodel.download")) {
                    requestDownload(entry)
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
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
                HStack(spacing: 6) {
                    Text(verbatim: entry.name)
                    if entry.builtIn {
                        Text("localmodel.builtIn")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
    }
}
