import Foundation

// 快速入口的命令表（docs/launcher/TECH_DESIGN.md §3.1）：快捷键动作自动生成的命令 + 模块在 `launcherCommands()` 里声明的命令，
// 合成一张表；每条命令的搜索键按「id + 标题 + 关键词 + 工具名」缓存，面板每次呼出只给新出现或文字变了的补建。
// 只依赖 Foundation（`LauncherCommand` 在 Core/Launcher），进 BaoboxTests；从 `ToolRegistry` 收集命令在 App 侧
// （`Providers/CommandProvider.swift`），这里只管合并规则和搜索键。

/// 命令表里的一条：命令 + 它属于哪个工具（列表右边写工具名；工具名也参与搜索）。
struct LauncherCatalogCommand {
    let command: LauncherCommand
    let toolID: String
    /// 所属工具的名字（已本地化）。
    let toolName: String
}

enum LauncherCommandCatalog {

    /// 合并两组命令（普通的搜索结果用）。规则：
    /// 1. 先过滤：id 为空、id 在 `excludedIDs` 里的不要；文字动作（恰好一个必填文字参数，`LauncherCommand.isTextAction`）
    ///    一律不要 —— 它们只作为「对当前输入的建议」出现（`textActions`），没有文字可给时执行不了；
    ///    `includesParameterized` 为 false 时其余带参数的（`parameters` 非空）也不要 —— 一期面板只能执行无参数命令。
    /// 2. 同一组里 id 重复的只留第一条。
    /// 3. 自动的在前、保持传入顺序；声明的和某条自动的 id 相同时，在那条的位置上替换它；
    ///    声明的里其余的接在后面、保持传入顺序。
    ///
    /// 先过滤再合并：声明了一条同 id 的带参数命令、而这次不收带参数的时，自动那条照样留着（快捷键动作本来就能无参数执行）。
    static func merge(automatic: [LauncherCatalogCommand], declared: [LauncherCatalogCommand],
                      excludedIDs: Set<String> = [], includesParameterized: Bool = false) -> [LauncherCatalogCommand] {
        func keeps(_ entry: LauncherCatalogCommand) -> Bool {
            let id = entry.command.id
            guard !id.isEmpty, !excludedIDs.contains(id), !entry.command.isTextAction else { return false }
            return includesParameterized || entry.command.parameters.isEmpty
        }
        let automatic = firstOfEachID(automatic.filter(keeps))
        let declared = firstOfEachID(declared.filter(keeps))

        let declaredByID = Dictionary(uniqueKeysWithValues: declared.map { ($0.command.id, $0) })
        var merged: [LauncherCatalogCommand] = []
        merged.reserveCapacity(automatic.count + declared.count)
        var placed: Set<String> = []
        for entry in automatic {
            let id = entry.command.id
            merged.append(declaredByID[id] ?? entry)
            placed.insert(id)
        }
        for entry in declared where !placed.contains(entry.command.id) {
            merged.append(entry)
        }
        return merged
    }

    /// 文字动作（docs/launcher/TECH_DESIGN.md §5.4）：模块声明的命令里恰好一个必填文字参数的那些，
    /// 作为「对当前输入的建议」排在列表最后。id 为空、在 `excludedIDs` 里的不要；id 重复只留第一条；保持传入顺序
    /// （同一档里没用过的按这个顺序排）。快捷键自动生成的命令都没有参数，不会是文字动作，所以只看声明的。
    static func textActions(declared: [LauncherCatalogCommand], excludedIDs: Set<String> = []) -> [LauncherCatalogCommand] {
        firstOfEachID(declared.filter { entry in
            !entry.command.id.isEmpty && !excludedIDs.contains(entry.command.id) && entry.command.isTextAction
        })
    }

    /// 参与匹配的文字：标题（第一个，排序同分时按它的长度）、关键词、「工具名 标题」。
    /// 工具名和标题拼成一段而不是单独一个键：单独的工具名会让这个工具的每条命令在输入工具名时都「完全相等」，
    /// 拼起来以后输入工具名是开头匹配、按标题长短排，`截图 区域` 这样连着写也能中。空白的去掉，完全相同的只留一个。
    static func searchTexts(for entry: LauncherCatalogCommand) -> [String] {
        let title = entry.command.title
        var texts = [title]
        texts.append(contentsOf: entry.command.keywords)
        let toolName = entry.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !toolName.isEmpty {
            texts.append(toolName + " " + title)
        }
        var seen: Set<String> = []
        return texts.filter { text in
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert(text).inserted
        }
    }

    private static func firstOfEachID(_ entries: [LauncherCatalogCommand]) -> [LauncherCatalogCommand] {
        var seen: Set<String> = []
        return entries.filter { seen.insert($0.command.id).inserted }
    }
}

/// 命令的搜索键缓存：按命令 id 记「搜索文字 → 搜索键」，文字没变就复用，变了（「开启防休眠」↔「关闭防休眠」）才重建。
/// 面板呼出时调一次 `keys(for:)`，打字时不碰。
struct LauncherCommandKeyCache {
    private var entries: [String: (texts: [String], keys: [LauncherSearchKey])] = [:]
    /// 一共建过几次（单元测试看缓存有没有生效）。
    private(set) var buildCount = 0

    init() {}

    /// 每条命令的搜索键，顺序同 `commands`。这次没出现的 id 从缓存里删掉。
    mutating func keys(for commands: [LauncherCatalogCommand]) -> [[LauncherSearchKey]] {
        var next: [String: (texts: [String], keys: [LauncherSearchKey])] = [:]
        next.reserveCapacity(commands.count)
        let result = commands.map { entry -> [LauncherSearchKey] in
            let id = entry.command.id
            let texts = LauncherCommandCatalog.searchTexts(for: entry)
            if let cached = next[id] ?? entries[id], cached.texts == texts {
                next[id] = cached
                return cached.keys
            }
            let keys = texts.map { LauncherSearchKey($0) }
            buildCount += 1
            next[id] = (texts, keys)
            return keys
        }
        entries = next
        return result
    }
}
