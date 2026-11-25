import Foundation

// 快速入口的排序（docs/launcher/TECH_DESIGN.md §5.2）：最终分 = 匹配分 × 来源权重 + 使用分；
// 查询完全等于别名的那一行排第一，其次是「这个输入上次选了谁」，隐藏的行不出现。只依赖 Foundation，进 BaoboxTests。
// 输入是纯值的候选（条目键 + 来源 id + 预先算好的搜索键），不碰带 @MainActor 闭包的 `LauncherEntry` / `LauncherCommand`，
// 整个排序可以挪到后台队列。计算结果、文本识别不经过这里：它们只在高置信时出现，由引擎固定放在最前。

/// 参与排序的一个候选。
struct LauncherCandidate: Equatable, Sendable {
    /// 条目键 = 「来源 id/条目 id」，也是使用记录、别名、隐藏用的键。
    let key: String
    let sourceID: String
    /// 参与匹配的文本，取最高分。第一个是标题：同分时按它的长度排。
    let searchKeys: [LauncherSearchKey]
    /// 条目的时间（剪贴板的复制时间、片段的创建时间）：同分时新的在前。App、命令没有（nil）。
    let date: Date?

    init(sourceID: String, entryID: String, searchKeys: [LauncherSearchKey], date: Date? = nil) {
        self.key = Self.key(sourceID: sourceID, entryID: entryID)
        self.sourceID = sourceID
        self.searchKeys = searchKeys
        self.date = date
    }

    static func key(sourceID: String, entryID: String) -> String {
        "\(sourceID)/\(entryID)"
    }
}

/// 来源权重表（§5.2）：匹配分乘上它。
struct LauncherSourceWeights: Equatable, Sendable {
    /// 来源 id → 权重。
    var bySource: [String: Double]
    /// 表里没有的来源。
    var other: Double

    /// 出厂：命令和 App 1.0、片段 0.9、剪贴板 0.7，其余 0.8。
    static let standard = LauncherSourceWeights(
        bySource: ["commands": 1.0, "apps": 1.0, "snippets": 0.9, "clipboard": 0.7],
        other: 0.8
    )

    func weight(for sourceID: String) -> Double {
        bySource[sourceID] ?? other
    }
}

/// 排好序的一行。
struct LauncherRankedItem: Equatable, Sendable {
    let key: String
    let sourceID: String
    /// 匹配分（`LauncherMatch`；别名命中时记 1000）。
    let matchScore: Int
    let usageScore: Double
    /// 最终分 = 匹配分 × 来源权重 + 使用分。
    let score: Double
    /// 查询完全等于它的别名：不论来源权重和分数排第一（在「上次选了谁」之前）。
    let isAliasMatch: Bool
    /// 这个输入上次选的就是它：不论分数排在别名命中之后、其余所有行之前。
    let isRemembered: Bool
}

/// 一次排序的结果。
struct LauncherRankingResult: Equatable, Sendable {
    /// 前 N 行。
    let items: [LauncherRankedItem]
    /// 所有命中的候选（不只前 N 行）里最高的匹配分；一个都没中为 nil。给「让 AI 来办」提不提前用。
    let bestMatchScore: Int?

    var keys: [String] { items.map(\.key) }
}

enum LauncherRanking {
    /// 默认取前多少行。
    static let defaultLimit = 50
    /// 其余结果的最高匹配分低于它（没有开头或词首匹配）……
    static let aiPromotionScoreThreshold = LauncherMatch.substringScore
    /// ……且输入至少这么多个字符（「超过 6 个」）时，「让 AI 来办」提到第一行。
    static let aiPromotionMinimumLength = 7
    /// 出厂的按来源最低匹配分：剪贴板要「包含这段字」（连续子串及以上），不认按顺序跳字 ——
    /// 剪贴板是几百字的长文本，跳字几乎什么都能凑上（`72 f to c` 能在一段 JSON 里跳出来）。片段、App、命令照旧可以跳字。
    static let defaultMinimumMatchScores = ["clipboard": LauncherMatch.substringMinimumScore]

    /// 排序。
    ///
    /// 次序：查询完全等于别名的那一行排第一；上次为这个输入选的那一行（且这次也命中、没隐藏）其次
    /// （两者是同一行时只出现一次）；其余按最终分从高到低，
    /// 同分先看使用分（高的在前），再看时间（有时间的新的在前；没有时间的 —— App、命令 —— 排在有时间的前面），
    /// 再看标题长度（短的在前），最后按条目键的字典序 —— 结果与候选的先后无关。
    /// 查询为空时所有候选都算命中（匹配分 0），等于按使用分排。
    /// - Parameters:
    ///   - query: 查询词（`LauncherQuery.text`，前缀已拆掉）。
    ///   - now: 当前时间，算使用分的衰减用。
    ///   - sourceLimits: 某些来源最多出几行（没打前缀时剪贴板最多 5 行，免得把 App 和命令挤下去）；
    ///     超出的跳过、由后面的行补上，`limit` 仍是总行数。
    ///   - minimumMatchScores: 某些来源的最低匹配分，低于它的候选不出、也不算进最高匹配分（出厂：剪贴板不认跳字）。
    ///     别名命中、「这个输入上次选了它」不受门槛限制；查询为空时不看门槛。
    static func rank(_ candidates: [LauncherCandidate], query: String, records: LauncherUsageRecords, now: Date,
                     weights: LauncherSourceWeights = .standard, limit: Int = LauncherRanking.defaultLimit,
                     sourceLimits: [String: Int] = [:],
                     minimumMatchScores: [String: Int] = LauncherRanking.defaultMinimumMatchScores) -> LauncherRankingResult {
        let matchQuery = LauncherMatchQuery(query)
        let aliasKey = records.key(forAlias: query)
        let rememberedKey = records.rememberedKey(forInput: query)
        let checksHidden = !records.hidden.isEmpty

        var scored: [Scored] = []
        var best: Int?
        for candidate in candidates {
            let match: Int
            let isAliasMatch = candidate.key == aliasKey
            if isAliasMatch {
                match = LauncherMatch.exactScore
            } else if let score = LauncherMatch.score(matchQuery, in: candidate.searchKeys) {
                match = score
            } else {
                continue
            }
            let isRemembered = candidate.key == rememberedKey
            if !isAliasMatch, !isRemembered, !matchQuery.isEmpty,
               let minimum = minimumMatchScores[candidate.sourceID], match < minimum {
                continue
            }
            if checksHidden && records.isHidden(candidate.key) { continue }
            let usage = records.usageScore(for: candidate.key, now: now)
            let item = LauncherRankedItem(
                key: candidate.key,
                sourceID: candidate.sourceID,
                matchScore: match,
                usageScore: usage,
                score: Double(match) * weights.weight(for: candidate.sourceID) + usage,
                isAliasMatch: isAliasMatch,
                isRemembered: isRemembered
            )
            scored.append(Scored(item: item, titleLength: candidate.searchKeys.first?.length ?? 0,
                                 date: candidate.date ?? .distantFuture))
            best = max(best ?? match, match)
        }

        scored.sort(by: precedes)
        return LauncherRankingResult(items: top(scored, limit: limit, sourceLimits: sourceLimits), bestMatchScore: best)
    }

    /// 排好序的前 `limit` 行，每个来源不超过 `sourceLimits` 里给的行数。
    private static func top(_ scored: [Scored], limit: Int, sourceLimits: [String: Int]) -> [LauncherRankedItem] {
        let limit = max(0, limit)
        guard !sourceLimits.isEmpty else { return scored.prefix(limit).map(\.item) }
        var items: [LauncherRankedItem] = []
        items.reserveCapacity(min(limit, scored.count))
        var used: [String: Int] = [:]
        for entry in scored {
            guard items.count < limit else { break }
            let sourceID = entry.item.sourceID
            if let sourceLimit = sourceLimits[sourceID] {
                let count = used[sourceID, default: 0]
                guard count < sourceLimit else { continue }
                used[sourceID] = count + 1
            }
            items.append(entry.item)
        }
        return items
    }

    /// 「让 AI 来办」要不要提到第一行：其余结果的最高匹配分低于 400 且输入超过 6 个字符（§5.2）。
    /// 查询等于某一行的别名、或上次为这个输入选过某一行时不提 —— 用户已经表明过要什么。
    static func shouldPromoteAIRow(query: String, result: LauncherRankingResult) -> Bool {
        if result.items.contains(where: { $0.isAliasMatch || $0.isRemembered }) { return false }
        return shouldPromoteAIRow(query: query, bestMatchScore: result.bestMatchScore)
    }

    /// 同上，只看最高匹配分（nil = 一个都没中）。字符按用户看到的字数算（去首尾空白）。
    static func shouldPromoteAIRow(query: String, bestMatchScore: Int?) -> Bool {
        let length = query.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard length >= aiPromotionMinimumLength else { return false }
        return (bestMatchScore ?? 0) < aiPromotionScoreThreshold
    }

    private struct Scored {
        let item: LauncherRankedItem
        let titleLength: Int
        /// 没有时间的记成 distantFuture：同分时排在有时间的前面（一个全序，排序结果确定）。
        let date: Date
    }

    private static func precedes(_ a: Scored, _ b: Scored) -> Bool {
        if a.item.isAliasMatch != b.item.isAliasMatch { return a.item.isAliasMatch }
        if a.item.isRemembered != b.item.isRemembered { return a.item.isRemembered }
        if a.item.score != b.item.score { return a.item.score > b.item.score }
        if a.item.usageScore != b.item.usageScore { return a.item.usageScore > b.item.usageScore }
        if a.date != b.date { return a.date > b.date }
        if a.titleLength != b.titleLength { return a.titleLength < b.titleLength }
        return a.item.key < b.item.key
    }
}
