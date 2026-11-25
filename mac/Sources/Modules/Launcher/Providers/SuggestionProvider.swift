import AppKit

// 快速入口的建议行（docs/launcher/TECH_DESIGN.md §5.4）：把 `LauncherSuggestionPolicy` 定下的计划换成面板的行 ——
// 对应建议固定在最前（计算结果之后、文本识别之前），兜底建议接在普通结果之后。
// 文字动作来自各模块的 `launcherCommands()`（只收一个文字参数的命令），快速入口不认识它们是谁：
// 标题 =「命令名「引用」」，右侧小字是所属工具名；执行时把输入框里上屏的文字（去首尾空白）作为那个文字参数交过去 ——
// 粘贴进来、还没改动过的多行文字交原文（带换行，`LauncherPastedText`）。
// 打字时只做这些内存里的计算：不调模型、不联网、不读盘；选中一行回车才真的执行。

/// 建议行 ⏎ 做什么。
enum LauncherSuggestionAction {
    /// 收起面板，下一个 runloop 执行（同命令：很多动作要等面板让开）。
    case run(@MainActor () -> Void)
    /// 把输入框换成这段文字，面板不收（「搜文件名含…」= 改成 `f <文字>`）。
    case replaceInput(String)
    /// 「<命令名>图里的文字」（§5.5）：收起面板，等这次取字有了结果，把认出的文字交给动作；没认出字就回执一句。
    case runOnImageText(LauncherRecognition, @MainActor (String) -> Void)
}

/// 一条动作类的建议行。颜色、字数这类 ⏎ 复制的行走 `LauncherInstant`（同计算结果：⏎ 复制、⌘⏎ 插入前台 App）。
struct LauncherSuggestion {
    let row: LauncherRow
    /// 执行时记一次使用的键（兜底建议：`textaction/<id>`）；nil = 不记（对应建议固定在最前，不用排）。
    let usageKey: String?
    let action: LauncherSuggestionAction
    /// 要按两次 ⏎（「在终端里运行」、取消一条提醒，PR 10）：第一次只换标题；nil = 按一次就执行。
    var confirmation: LauncherConfirmation? = nil
}

/// 一次输入的全部建议。
struct LauncherSuggestions {
    /// 固定在最前的一行：动作（打开网址、写邮件）或复制（颜色、字数）。
    enum Leading {
        case action(LauncherSuggestion)
        case instant(LauncherInstant)

        var row: LauncherRow {
            switch self {
            case .action(let suggestion): return suggestion.row
            case .instant(let instant): return instant.row
            }
        }
    }

    var leading: [Leading] = []
    /// 排在普通结果之后的兜底建议。
    var trailing: [LauncherSuggestion] = []

    var leadingRows: [LauncherRow] { leading.map(\.row) }

    /// 复制类的行（引擎并进计算结果、识别结果那一张表）。
    var instants: [LauncherInstant] {
        leading.compactMap { entry in
            if case .instant(let instant) = entry { return instant }
            return nil
        }
    }

    /// 动作类的行（对应建议 + 兜底建议）。
    var actions: [LauncherSuggestion] {
        leading.compactMap { entry in
            if case .action(let suggestion) = entry { return suggestion }
            return nil
        } + trailing
    }
}

@MainActor
enum LauncherSuggestionProvider {

    /// 这次输入的建议。`textActions`：各模块声明的文字动作（呼出时收一次）；`placed`：放进来的原文（控制器核对过，输入框还是它）。
    static func suggestions(for query: LauncherQuery, textActions: [LauncherCatalogCommand],
                            hasCalculation: Bool, hasRecognition: Bool, placed: LauncherPlacedText? = nil,
                            records: LauncherUsageRecords, now: Date) -> LauncherSuggestions {
        let plan = LauncherSuggestionPolicy.plan(for: query, hasCalculation: hasCalculation, hasRecognition: hasRecognition,
                                                 placed: placed)
        var suggestions = LauncherSuggestions()
        suggestions.leading = plan.leading.flatMap { leadingRows($0, text: plan.text) }
        if let kinds = plan.fallbackKinds {
            // 对这段文字适用的文字动作：类别对得上，模块的 `appliesTo` 也说行（PR 10）。先看类别 —— `appliesTo` 可能要跑一遍正则。
            let actions = textActions.filter { entry in
                entry.command.isTextAction && !entry.command.suggestion.kinds.isDisjoint(with: kinds)
                    && entry.command.applies(to: plan.text)
            }
            // 标了 `leading` 的（会议链接的「入会并开始会议记录」）紧跟在对应建议后面，不进兜底建议。
            suggestions.leading += leadingActionRows(text: plan.text, kinds: kinds, textActions: actions)
            // 有歧义的网址的「打开」排在兜底建议最前面（翻译前面），占一个名额。
            let first = plan.fallbackLeading.flatMap { leadingRows($0, text: plan.text, inFallback: true) }
                .compactMap { entry -> LauncherSuggestion? in
                    if case .action(let suggestion) = entry { return suggestion }
                    return nil
                }
            suggestions.trailing = first + fallbackRows(text: plan.text, kinds: kinds, textActions: actions,
                                                        records: records, now: now, limit: plan.rankedFallbackLimit)
        }
        return suggestions
    }

    /// 排在对应建议后面的文字动作（`traits.leading`）：标题就是命令名（输入已经在上一行写着了），右侧是所属工具名；不记使用。
    private static func leadingActionRows(text: String, kinds: Set<LauncherTextKind>,
                                          textActions: [LauncherCatalogCommand]) -> [LauncherSuggestions.Leading] {
        let candidates = textActions.map { LauncherSuggestionCandidate(id: $0.command.id, traits: $0.command.suggestion) }
        return LauncherSuggestionRanking.leadingOrder(candidates, kinds: kinds).compactMap { index in
            let entry = textActions[index]
            let command = entry.command
            guard let parameter = command.textParameterName else { return nil }
            let row = LauncherRow(id: "suggest/leading/\(command.id)", title: command.title, source: entry.toolName,
                                  icon: .symbol(command.symbolName))
            return .action(LauncherSuggestion(row: row, usageKey: nil, action: .run { command.run([parameter: .text(text)]) }))
        }
    }

    // MARK: - 对应建议

    /// `inFallback`：放在兜底建议最前面的（有歧义的网址）—— 标题写补好 scheme 的完整地址（「打开 https://claude.ai」），
    /// 一眼看出说的是网站，不是那个文件名。
    private static func leadingRows(_ suggestion: LauncherLeadingSuggestion, text: String,
                                    inFallback: Bool = false) -> [LauncherSuggestions.Leading] {
        let quote = LauncherSuggestionText.quote(text, maxLength: LauncherSuggestionText.leadingQuoteLength)
        switch suggestion {
        case .openURL(let url):
            let shown = inFallback
                ? LauncherSuggestionText.quote(url.absoluteString, maxLength: LauncherSuggestionText.leadingQuoteLength)
                : quote
            let row = LauncherRow(id: "suggest/url", title: L("launcher.suggest.openURL \(shown)"),
                                  source: L("launcher.suggest.source.url"), icon: .symbol("globe"))
            return [.action(LauncherSuggestion(row: row, usageKey: nil, action: .run { NSWorkspace.shared.open(url) }))]
        case .email(let address):
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = address
            guard let url = components.url else { return [] }
            let row = LauncherRow(id: "suggest/email",
                                  title: L("launcher.suggest.email \(LauncherSuggestionText.quote(address, maxLength: LauncherSuggestionText.leadingQuoteLength))"),
                                  source: L("launcher.suggest.source.email"), icon: .symbol("envelope"))
            return [.action(LauncherSuggestion(row: row, usageKey: nil, action: .run { NSWorkspace.shared.open(url) }))]
        case .color(let color):
            let formats = [("hex", "HEX", color.hexString), ("rgb", "RGB", color.rgbString), ("hsl", "HSL", color.hslString)]
            return formats.map { id, label, value in
                .instant(LauncherInstant(row: LauncherRow(id: "suggest/color/\(id)", title: value,
                                                          source: L("launcher.suggest.source.color \(label)"),
                                                          icon: .swatch(color)),
                                         copyText: value))
            }
        case .wordCount(let stats):
            let words = LauncherCalcFormat.grouped(Int64(stats.words))
            let characters = LauncherCalcFormat.grouped(Int64(stats.characters))
            let row = LauncherRow(id: "suggest/wordcount", title: L("launcher.suggest.wordCount \(words) \(characters)"),
                                  source: L("launcher.suggest.source.wordCount"), icon: .symbol("number"))
            return [.instant(LauncherInstant(row: row, copyText: String(stats.words)))]
        case .runInTerminal, .reminder:
            return []
        }
    }

    // MARK: - 兜底建议

    /// `textActions`：已经筛过的（文字动作、对这段文字适用）。
    private static func fallbackRows(text: String, kinds: Set<LauncherTextKind>, textActions actions: [LauncherCatalogCommand],
                                     records: LauncherUsageRecords, now: Date, limit: Int) -> [LauncherSuggestion] {
        let candidates = actions.map { LauncherSuggestionCandidate(id: $0.command.id, traits: $0.command.suggestion) }
            + [LauncherSuggestionRanking.webSearch, LauncherSuggestionRanking.findFiles]
        let quote = LauncherSuggestionText.quote(text)
        let order = LauncherSuggestionRanking.order(candidates, kinds: kinds, records: records, now: now, limit: limit)
        return order.compactMap { index in
            let id = candidates[index].id
            let key = LauncherSuggestionRanking.usageKey(for: id)
            if actions.indices.contains(index) {
                let entry = actions[index]
                let command = entry.command
                guard let parameter = command.textParameterName else { return nil }
                let row = LauncherRow(id: key, title: L("launcher.suggest.action \(command.title) \(quote)"),
                                      source: entry.toolName, icon: .symbol(command.symbolName))
                return LauncherSuggestion(row: row, usageKey: key, action: .run { command.run([parameter: .text(text)]) })
            }
            switch id {
            case LauncherSuggestionRanking.webSearch.id:
                guard let url = LauncherWebSearch.defaultEngine.url(for: text) else { return nil }
                let row = LauncherRow(id: key, title: L("launcher.suggest.webSearch \(quote)"),
                                      source: L("launcher.suggest.source.web"), icon: .symbol("magnifyingglass"))
                return LauncherSuggestion(row: row, usageKey: key, action: .run { NSWorkspace.shared.open(url) })
            case LauncherSuggestionRanking.findFiles.id:
                // 改成 `f <文字>`：只搜文件（Spotlight，§6.4），面板不收。
                let prefix = LauncherQuery.defaultPrefixBySource["files"] ?? "f"
                let row = LauncherRow(id: key, title: L("launcher.suggest.findFiles \(quote)"),
                                      source: L("launcher.suggest.source.files"), icon: .symbol("doc.text.magnifyingglass"))
                return LauncherSuggestion(row: row, usageKey: key, action: .replaceInput(prefix + " " + text))
            default:
                return nil
            }
        }
    }
}
