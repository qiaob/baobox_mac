import Foundation

/// Mock 规则表（docs/packet-capture/TOOLS.md §4）：增删改、开关、排序，存盘，并且每次变化都把**全量**规则发给引擎。
///
/// 存在 `~/Library/Application Support/Baobox/NetCapture/mock-rules.json`，不放 UserDefaults（正文可能几百 KB）。
/// 读不出来就当空表，坏文件改名留着不删；写失败报 `StorageWriteFailure`。
/// 引擎每次就绪（`running` 事件）由 `NetCaptureEngine` 叫 `pushToEngine()` 再发一遍。
@MainActor
final class MockRuleStore: ObservableObject {
    static let shared = MockRuleStore()

    /// 列表顺序 = 匹配顺序：多条都能命中时靠上的生效。
    @Published private(set) var rules: [MockRule] = []

    private var loadStarted = false
    /// 读写都在这一条串行队列上，保证存盘顺序和改动顺序一致。
    private let ioQueue = DispatchQueue(label: "com.baobox.netcapture.mock-rules", qos: .utility)

    static var fileURL: URL { NetCaptureEnv.supportDir.appendingPathComponent("mock-rules.json") }

    private init() {}

    /// 启用中的规则数（工具条上写成「Mock 2」）。
    var enabledCount: Int { rules.filter(\.enabled).count }

    /// 在后台读一次存盘的规则（模块 `activate()` 时调；重复调用无效）。读完发给引擎（引擎没在跑就丢掉）。
    func load() {
        guard !loadStarted else { return }
        loadStarted = true
        let url = Self.fileURL
        ioQueue.async {
            let loaded = Self.read(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // 读盘期间用户已经加了规则（几乎不会）：两边合起来，存盘那份在前。
                    let added = self.rules.filter { rule in !loaded.contains { $0.id == rule.id } }
                    self.rules = loaded + added
                    if !added.isEmpty { self.persist() }
                    self.pushToEngine()
                }
            }
        }
    }

    // MARK: - 改动

    /// 新建或更新（按 id）。新规则放在最后。
    func save(_ rule: MockRule) {
        let clean = rule.normalized()
        if let index = rules.firstIndex(where: { $0.id == clean.id }) {
            rules[index] = clean
        } else {
            rules.append(clean)
        }
        commit()
    }

    func remove(id: String) {
        rules.removeAll { $0.id == id }
        commit()
    }

    func setEnabled(id: String, _ enabled: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }), rules[index].enabled != enabled else { return }
        rules[index].enabled = enabled
        commit()
    }

    /// 拖动排序（列表的 `onMove`）。
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        commit()
    }

    /// 把全量规则发给引擎（停用的也带上，引擎自己跳过）。引擎没在跑时 `send` 什么也不做。
    func pushToEngine() {
        NetCaptureEngine.shared.send(.rules(rules))
    }

    private func commit() {
        pushToEngine()
        persist()
    }

    // MARK: - 存盘

    private func persist() {
        let snapshot = rules
        let url = Self.fileURL
        ioQueue.async {
            guard let data = MockRuleFile.encode(snapshot) else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                StorageWriteFailure.report(L("netcapture.mock.storageName"), reason: error.localizedDescription)
            }
        }
    }

    /// 没有文件 = 空表。文件坏了：改名成 `mock-rules.broken-<时间>.json` 留着，当空表。
    private nonisolated static func read(_ url: URL) -> [MockRule] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let rules = MockRuleFile.decode(data) { return rules }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let broken = url.deletingLastPathComponent()
            .appendingPathComponent("mock-rules.broken-\(formatter.string(from: Date())).json")
        try? FileManager.default.moveItem(at: url, to: broken)
        return []
    }
}
