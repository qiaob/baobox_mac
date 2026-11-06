import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 会议的普通窗口（docs/meeting/TECH_DESIGN.md §6）：会议库（含行动项视图、系列时间线）与会前简报。
/// 同设置窗口的做法：自持 NSWindow + NSHostingController，关闭后复用，打开时 `NSApp.activate`（这是普通窗口，要拿焦点）。
@MainActor
final class MeetingWindowController {
    static let shared = MeetingWindowController()
    private init() {}

    private var libraryWindow: NSWindow?
    private var briefWindow: NSWindow?
    let briefModel = MeetingBriefModel()

    /// 打开会议库；`select` = 选中这场（通知里的「打开」、简报里的「打开上次纪要」）。
    func showLibrary(select id: String? = nil, detail: MeetingLibraryModel.Detail = .minutes) {
        let model = MeetingLibraryModel.shared
        model.mode = .meetings
        if let id {
            model.query = ""
            model.typeFilter = .all
            model.selectedID = id
            model.detail = detail
        } else if model.selectedID == nil {
            model.selectedID = MeetingStore.shared.records.first?.id
        }
        present(library())
    }

    /// 打开会议库的「行动项」视图（跨会议）。
    func showActionItems() {
        MeetingLibraryModel.shared.mode = .actionItems
        present(library())
    }

    /// 会前简报（菜单「会前简报」、提醒气泡的「看简报」）。
    func showBrief(for event: MeetingCalendarEvent) {
        briefModel.show(event)
        present(brief())
    }

    func closeBrief() {
        briefWindow?.close()
    }

    private func library() -> NSWindow {
        if let libraryWindow { return libraryWindow }
        let hosting = NSHostingController(rootView: MeetingLibraryView())
        let window = NSWindow(contentViewController: hosting)
        window.title = L("meeting.library.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 980, height: 640))
        window.isReleasedWhenClosed = false
        window.center()
        libraryWindow = window
        return window
    }

    private func brief() -> NSWindow {
        if let briefWindow { return briefWindow }
        let hosting = NSHostingController(rootView: MeetingBriefView(model: briefModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = L("meeting.brief.title")
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        briefWindow = window
        return window
    }

    private func present(_ window: NSWindow) {
        // LSUIElement 应用默认不激活，不主动激活则窗口会出现在其他 App 之后（同 SettingsWindowController）。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// 会议库窗口的状态（主线程）：视图、搜索、筛选、选中、纪要全文缓存（后台读）、底部的一行提示。
@MainActor
final class MeetingLibraryModel: ObservableObject {
    static let shared = MeetingLibraryModel()
    private init() {}

    enum Mode: String, CaseIterable {
        case meetings
        case actionItems
    }

    enum Detail: String, CaseIterable {
        case minutes
        case transcript
        case series
    }

    enum TypeFilter: String, CaseIterable {
        case all
        case online
        case offline
        case free
    }

    @Published var mode: Mode = .meetings
    /// 搜索（标题 / 参会人 / 纪要全文）。有字时把全部会议的 Markdown 在后台读进缓存。
    @Published var query = "" {
        didSet {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty { loadAll() }
        }
    }
    @Published var typeFilter: TypeFilter = .all
    @Published var selectedID: String?
    @Published var detail: Detail = .minutes
    /// 会议 id → meeting.md 全文。
    @Published private(set) var texts: [String: String] = [:]
    /// 底部一行提示（「已复制」「纪要已重新生成」…），2.5 秒后消失。
    @Published private(set) var banner: String?
    /// 等用户确认删除的那场。
    @Published var pendingDelete: String?

    /// 读进缓存时那场的状态（状态变了 = 文件变了，要重读）。
    private var versions: [String: String] = [:]
    private var loading: Set<String> = []
    private var bannerGeneration = 0

    // MARK: - 列表

    func filtered(_ records: [MeetingRecord]) -> [MeetingRecord] {
        let byType = records.filter { record in
            switch typeFilter {
            case .all: return true
            case .online: return record.meta.type == .online
            case .offline: return record.meta.type == .offline
            case .free: return record.meta.type == .free
            }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return byType }
        return byType.filter { record in
            Self.contains(record.meta.title, needle) || record.meta.attendees.contains { Self.contains($0, needle) }
                || (texts[record.id].map { Self.contains($0, needle) } ?? false)
        }
    }

    private static func contains(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    // MARK: - 全文缓存

    private static func version(_ record: MeetingRecord) -> String {
        "\(record.meta.status.rawValue)|\(record.meta.end?.timeIntervalSince1970 ?? 0)"
    }

    /// 这场的全文（可能是旧的，`load` 会换成新的）。
    func text(for id: String) -> String? {
        texts[id]
    }

    /// 读一场（没读过、或之后状态变了）。
    func load(_ record: MeetingRecord) {
        load([record])
    }

    func loadAll() {
        load(MeetingStore.shared.records)
    }

    private func load(_ records: [MeetingRecord]) {
        let stale = records.filter { versions[$0.id] != Self.version($0) && !loading.contains($0.id) }
        guard !stale.isEmpty else { return }
        let stamps = Dictionary(stale.map { ($0.id, Self.version($0)) }, uniquingKeysWith: { first, _ in first })
        loading.formUnion(stamps.keys)
        MeetingStore.shared.loadMarkdowns(Array(stamps.keys)) { texts in
            MeetingLibraryModel.shared.loaded(texts, stamps: stamps)
        }
    }

    private func loaded(_ loaded: [String: String], stamps: [String: String]) {
        loading.subtract(stamps.keys)
        var merged = texts
        for (id, stamp) in stamps {
            versions[id] = stamp
            merged[id] = loaded[id]
        }
        texts = merged
    }

    /// 重新生成纪要写好了：直接换上新的全文。
    func setText(_ id: String, _ text: String) {
        texts[id] = text
        if let record = MeetingStore.shared.record(id) {
            versions[id] = Self.version(record)
        }
    }

    // MARK: - 操作

    /// 切到会议列表并选中这场。
    func reveal(_ id: String, detail: Detail = .minutes) {
        mode = .meetings
        if !filtered(MeetingStore.shared.records).contains(where: { $0.id == id }) {
            query = ""
            typeFilter = .all
        }
        selectedID = id
        self.detail = detail
    }

    func minutes(of id: String) -> String? {
        texts[id].flatMap { MeetingMarkdown.sections($0).minutes }
    }

    func copyMinutes(_ id: String) {
        guard let record = MeetingStore.shared.record(id) else { return }
        if let minutes = minutes(of: id) {
            Self.copy("# " + record.meta.title + "\n\n" + minutes)
            flash(L("meeting.library.copied"))
            return
        }
        // 还没读进来：读完再复制。
        MeetingStore.shared.loadMarkdown(id) { text in
            let model = MeetingLibraryModel.shared
            guard let text, let minutes = MeetingMarkdown.sections(text).minutes else {
                model.flash(L("meeting.library.noMinutes"))
                return
            }
            model.setText(id, text)
            Self.copy("# " + record.meta.title + "\n\n" + minutes)
            model.flash(L("meeting.library.copied"))
        }
    }

    /// 导出整份 meeting.md（NSSavePanel）。
    func export(_ id: String) {
        guard let record = MeetingStore.shared.record(id) else { return }
        let name = MeetingLibraryLayout.folderName(start: record.meta.start, title: record.meta.title) + ".md"
        guard let destination = Self.chooseDestination(name: name) else { return }
        MeetingStore.shared.loadMarkdown(id) { text in
            guard let text else {
                MeetingLibraryModel.shared.flash(L("meeting.library.exportFailed"))
                return
            }
            MeetingLibraryModel.shared.write(text, to: destination)
        }
    }

    /// 写到用户选的位置（后台），写完提示一句。
    func write(_ text: String, to url: URL) {
        let data = Data(text.utf8)
        DispatchQueue.global(qos: .utility).async {
            let succeeded = (try? data.write(to: url, options: .atomic)) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MeetingLibraryModel.shared.flash(succeeded ? L("meeting.library.exported") : L("meeting.library.exportFailed"))
                }
            }
        }
    }

    static func chooseDestination(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    func confirmDelete(_ id: String) {
        pendingDelete = id
    }

    /// 记录中、整理纪要中（含重新生成）的不能删：转录 / 纪要写完时会把目录又建回来。
    static func canDelete(_ record: MeetingRecord) -> Bool {
        record.meta.status != .recording && record.meta.status != .summarizing
            && !MeetingMinutesRegenerator.shared.running.contains(record.id)
    }

    /// 删除：移到废纸篓（迁移来的旧记录连原文件）。
    func delete(_ id: String) {
        pendingDelete = nil
        guard let record = MeetingStore.shared.record(id), Self.canDelete(record) else { return }
        if selectedID == id {
            let records = filtered(MeetingStore.shared.records)
            let index = records.firstIndex(where: { $0.id == id })
            let neighbor = index.flatMap { records.indices.contains($0 + 1) ? records[$0 + 1] : ($0 > 0 ? records[$0 - 1] : nil) }
            selectedID = neighbor?.id
        }
        texts[id] = nil
        versions[id] = nil
        MeetingStore.shared.delete(id) { succeeded in
            MeetingLibraryModel.shared.flash(succeeded ? L("meeting.library.deleted") : L("meeting.library.deleteFailed"))
        }
    }

    func flash(_ message: String) {
        bannerGeneration += 1
        let generation = bannerGeneration
        banner = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated {
                let model = MeetingLibraryModel.shared
                if model.bannerGeneration == generation { model.banner = nil }
            }
        }
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - 行动项（跨会议）

    struct ActionRow: Identifiable, Equatable {
        var meetingID: String
        var meetingTitle: String
        var meetingStart: Date
        var item: MeetingActionItem
        var id: String { meetingID + "|" + item.id }
    }

    /// 所有会议的行动项，新会议的在前。
    static func actionRows(_ records: [MeetingRecord]) -> [ActionRow] {
        records.flatMap { record in
            record.meta.actionItems.map {
                ActionRow(meetingID: record.id, meetingTitle: record.meta.title, meetingStart: record.meta.start, item: $0)
            }
        }
    }

    /// 行动项导出 / 复制的 Markdown：`- [ ] 负责人：事项（截止：…）— 会议（日期）`。
    static func markdown(_ rows: [ActionRow]) -> String {
        rows.map { row in
            var line = row.item.done ? "- [x] " : "- [ ] "
            if let owner = row.item.owner { line += owner + "：" }
            line += row.item.text
            if let due = row.item.due { line += L("meeting.actions.due \(due)") }
            return line + " — " + row.meetingTitle + "（" + MeetingText.shortDay(row.meetingStart) + "）"
        }
        .joined(separator: "\n")
    }

    func copyOpenItems() {
        let open = Self.actionRows(MeetingStore.shared.records).filter { !$0.item.done }
        guard !open.isEmpty else {
            flash(L("meeting.actions.noneOpen"))
            return
        }
        Self.copy(Self.markdown(open))
        flash(L("meeting.library.copied"))
    }

    func exportActionItems() {
        let rows = Self.actionRows(MeetingStore.shared.records)
        let open = rows.filter { !$0.item.done }
        let done = rows.filter(\.item.done)
        var text = "# " + L("meeting.actions.title") + "\n\n"
        text += "## " + L("meeting.actions.open \(open.count)") + "\n\n" + (open.isEmpty ? L("meeting.weekly.none") : Self.markdown(open)) + "\n\n"
        text += "## " + L("meeting.actions.done \(done.count)") + "\n\n" + (done.isEmpty ? L("meeting.weekly.none") : Self.markdown(done)) + "\n"
        guard let destination = Self.chooseDestination(name: L("meeting.actions.fileName") + ".md") else { return }
        write(text, to: destination)
    }
}

/// 会前简报窗口的状态：哪一场、上一场的纪要（后台读）。简报本身每次按会议库现算（勾了行动项马上反映）。
@MainActor
final class MeetingBriefModel: ObservableObject {
    @Published private(set) var event: MeetingCalendarEvent?
    /// 上一场的纪要（读好了才有）。
    @Published private(set) var previousMinutes: String?
    @Published private(set) var previousLoaded = false
    private var loadingID: String?

    func show(_ event: MeetingCalendarEvent) {
        self.event = event
        previousMinutes = nil
        previousLoaded = false
        loadPrevious()
    }

    func loadPrevious() {
        guard let event, let previous = MeetingActions.briefing(for: event).previous else {
            previousLoaded = true
            return
        }
        loadingID = previous.id
        MeetingStore.shared.loadMarkdown(previous.id) { text in
            let model = MeetingWindowController.shared.briefModel
            guard model.loadingID == previous.id else { return }
            model.previousMinutes = text.flatMap { MeetingMarkdown.sections($0).minutes }
            model.previousLoaded = true
        }
    }
}
