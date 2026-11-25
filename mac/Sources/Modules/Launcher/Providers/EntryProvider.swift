import Foundation
import os

// 快速入口里别的模块交来的条目（docs/launcher/TECH_DESIGN.md §3.2）：各工具 `launcherSources()` 的来源（剪贴板历史、文本片段……）。
// 面板呼出时向各来源取一次条目（只读内存），缓存到收起；搜索键按「条目键 + 文字」缓存（`Logic/LauncherEntryKeys.swift`），
// 只给新出现的补建 —— 缺得多时只同步建最新的 200 条，其余在后台建，建完通知控制器刷新一次列表。
// 不呼出时也预热：`activate()` 后几秒一次、每次收起后空闲时一次，让下次呼出基本不用现建。

@MainActor
final class LauncherEntryProvider {
    /// 呼出那一下最多同步建多少条的键（其余交给后台）。
    static let syncKeyBudget = 200
    /// 收起后多久补一次键（「空闲时」：用户刚执行完一行，别和那一行抢主线程）。
    static let idlePrewarmDelay: TimeInterval = 2

    nonisolated private static let log = Logger(subsystem: "com.baobox.app", category: "launcher")

    /// 呼出时这一步的统计（记进 `panel shown in … ms` 那条日志）。
    struct Report {
        /// 各来源交来的条目数。
        let entries: Int
        /// 现建了几个条目的键。
        let built: Int
        /// 交给后台、这次先搜不到的条目数。
        let pending: Int
    }

    private struct SourceEntries {
        let sourceID: String
        let sourceName: String
        let entries: [LauncherEntry]
        let specs: [LauncherEntryKeySpec]
    }

    private weak var registry: ToolRegistry?
    private var cache = LauncherEntryKeyCache()
    private let queue = DispatchQueue(label: "com.baobox.app.launcher.entrykeys", qos: .utility)
    /// 已经交给后台、还没建完的条目键（别重复交）。
    private var building: Set<String> = []
    /// 这次面板会话的条目（呼出时取一次，收起时放掉，连同条目带的闭包）。
    private var session: [SourceEntries]?
    private var idleWork: DispatchWorkItem?

    /// 后台建好了一批键、面板还开着：控制器重新装一次条目、刷新列表。
    var onKeysAdded: (() -> Void)?

    init(registry: ToolRegistry?) {
        self.registry = registry
    }

    /// 这次会话里有的来源 id（它们的前缀才生效）。
    var sessionSourceIDs: Set<String> {
        Set((session ?? []).map(\.sourceID))
    }

    /// 面板呼出：取一次条目，补建缺的键（最新的至多 200 条现在建，其余交给后台）。
    func beginSession() -> Report {
        idleWork?.cancel()
        idleWork = nil
        let sources = collect()
        session = sources
        let specs = sources.flatMap(\.specs)
        cache.retain(Set(specs.map(\.key)))
        let missing = cache.missing(specs)
        let (now, later) = LauncherEntryKeyCache.split(missing, budget: Self.syncKeyBudget)
        cache.build(now)
        buildInBackground(later.filter { !building.contains($0.key) })
        return Report(entries: specs.count, built: now.count, pending: later.count)
    }

    /// 这次会话里键已经建好的条目（后台建好一批后再调一次，就能搜到新的）。
    func sessionItems() -> [LauncherItem] {
        guard let session else { return [] }
        var items: [LauncherItem] = []
        items.reserveCapacity(session.reduce(0) { $0 + $1.entries.count })
        for source in session {
            for (entry, spec) in zip(source.entries, source.specs) {
                guard let keys = cache.keys(for: spec) else { continue }
                let candidate = LauncherCandidate(sourceID: source.sourceID, entryID: entry.id, searchKeys: keys,
                                                  date: entry.date)
                // 图片条目（§5.5）：行首是缩略图（行要显示时才在后台取），副标题是相对时间 —— 标题都差不多（「图片 · 微信」），
                // 靠它分得清是哪一张。文字条目照旧不写副标题。
                let icon: LauncherRowIcon = entry.image == nil ? .symbol(entry.symbolName)
                    : .thumbnail(placeholderSymbol: entry.symbolName)
                let row = LauncherRow(id: candidate.key, title: entry.title, source: source.sourceName, icon: icon,
                                      subtitle: entry.image == nil ? nil : entry.subtitle)
                items.append(LauncherItem(candidate: candidate, row: row, run: entry.primary,
                                          image: entry.image, onlyWithPrefix: entry.onlyWithPrefix))
            }
        }
        return items
    }

    /// 这次会话里这几个来源的文字条目（条目键、搜索全文、时间）：文件搜索从里面抽剪贴板里出现过的路径（§6.4，PR 11）。图片条目不算。
    func sessionTexts(sourceIDs: Set<String>) -> [LauncherTextSnapshot] {
        guard let session else { return [] }
        return session.filter { sourceIDs.contains($0.sourceID) }.flatMap { source in
            source.entries.compactMap { entry in
                entry.image == nil
                    ? LauncherTextSnapshot(key: LauncherCandidate.key(sourceID: source.sourceID, entryID: entry.id),
                                           text: entry.searchText, date: entry.date)
                    : nil
            }
        }
    }

    /// 这次会话里这个来源最新的条目（按时间；没有时间的不算）：「刚复制的」从剪贴板历史里取（§8.4）。
    func latestEntry(sourceID: String) -> LauncherEntry? {
        var latest: LauncherEntry?
        for source in session ?? [] where source.sourceID == sourceID {
            for entry in source.entries {
                guard let date = entry.date else { continue }
                if let current = latest?.date, current >= date { continue }
                latest = entry
            }
        }
        return latest
    }

    /// 面板收起：放掉这次的条目，空闲时再补一次键（会话中新复制的、来源里新加的）。
    func endSession() {
        session = nil
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.idleWork = nil
                self?.prewarm()
            }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idlePrewarmDelay, execute: work)
    }

    /// 预热：取一次条目（只读内存），把缺的键全交给后台建；来源里已经没有的从缓存里删掉。
    func prewarm() {
        let specs = collect().flatMap(\.specs)
        if session == nil {
            cache.retain(Set(specs.map(\.key)))
        }
        buildInBackground(cache.missing(specs).filter { !building.contains($0.key) })
    }

    // MARK: - 内部

    /// 向各工具的来源取条目。标题转不转拼音按来源定（剪贴板不转）。
    private func collect() -> [SourceEntries] {
        guard let registry else { return [] }
        var result: [SourceEntries] = []
        for tool in registry.tools {
            for source in tool.launcherSources() {
                let sourceID = source.launcherSourceID
                let pinyin = !LauncherEntryKeySpec.titlePinyinOffSourceIDs.contains(sourceID)
                let entries = source.launcherEntries()
                let specs = entries.map {
                    LauncherEntryKeySpec(sourceID: sourceID, entryID: $0.id, title: $0.title, searchText: $0.searchText,
                                         pinyin: pinyin, date: $0.date)
                }
                result.append(SourceEntries(sourceID: sourceID, sourceName: source.launcherSourceName,
                                            entries: entries, specs: specs))
            }
        }
        return result
    }

    /// 在后台串行队列建键，建完回主线程记进缓存（约定 1）。
    private func buildInBackground(_ specs: [LauncherEntryKeySpec]) {
        guard !specs.isEmpty else { return }
        building.formUnion(specs.map(\.key))
        queue.async {
            let start = DispatchTime.now().uptimeNanoseconds
            let built = LauncherEntryKeyCache.makeKeys(specs)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishBackground(built, milliseconds: milliseconds)
                }
            }
        }
    }

    private func finishBackground(_ built: [(spec: LauncherEntryKeySpec, keys: [LauncherSearchKey])],
                                  milliseconds: Double) {
        for entry in built {
            building.remove(entry.spec.key)
            cache.insert(entry.spec, keys: entry.keys)
        }
        Self.log.notice("entry keys: \(built.count, privacy: .public) built in background in \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms, \(self.cache.count, privacy: .public) cached")
        if session != nil { onKeysAdded?() }
    }
}
