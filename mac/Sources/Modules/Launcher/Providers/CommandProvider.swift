import Foundation

// 快速入口的命令来源（docs/launcher/TECH_DESIGN.md §3.1）：每次呼出现建命令表 ——
// `ToolRegistry.allHotkeys()` 里的每个快捷键动作自动成为一条无参数命令，再合上各模块 `launcherCommands()` 声明的；
// 合并规则在 `Logic/LauncherCommandCatalog.swift`。搜索键按「id + 文字」缓存，只给新出现或标题变了的补建。

@MainActor
final class LauncherCommandProvider {
    static let sourceID = "commands"

    private weak var registry: ToolRegistry?
    private var keyCache = LauncherCommandKeyCache()

    init(registry: ToolRegistry?) {
        self.registry = registry
    }

    /// 此刻的命令条目（呼出时调一次）。
    func items() -> [LauncherItem] {
        guard let registry else { return [] }
        return items(from: Self.catalog(from: registry))
    }

    /// 命令表：快捷键动作 + 模块声明的，排除快速入口自己的呼出键和「按住 + 松开」类的动作，这一期只收无参数的
    /// （文字动作另走 `textActions()`）。
    static func catalog(from registry: ToolRegistry) -> [LauncherCatalogCommand] {
        var automatic: [LauncherCatalogCommand] = []
        for (tool, definitions) in registry.allHotkeys() {
            // 带 onRelease 的（按住说话）靠「按下 + 松开」才完整，单次执行没有意义。
            for definition in definitions where definition.onRelease == nil {
                automatic.append(LauncherCatalogCommand(command: command(from: definition, symbolName: tool.symbolName),
                                                        toolID: tool.id, toolName: tool.name))
            }
        }
        var declared: [LauncherCatalogCommand] = []
        for tool in registry.tools {
            for command in tool.launcherCommands() {
                declared.append(LauncherCatalogCommand(command: command, toolID: tool.id, toolName: tool.name))
            }
        }
        return LauncherCommandCatalog.merge(automatic: automatic, declared: declared,
                                            excludedIDs: [LauncherTool.toggleHotkeyID])
    }

    /// 此刻各模块声明的文字动作（呼出时调一次）：只作为「对当前输入的建议」出现（§5.4），不进普通的搜索结果。
    func textActions() -> [LauncherCatalogCommand] {
        guard let registry else { return [] }
        let declared = registry.tools.flatMap { tool in
            tool.launcherCommands().map { LauncherCatalogCommand(command: $0, toolID: tool.id, toolName: tool.name) }
        }
        return LauncherCommandCatalog.textActions(declared: declared, excludedIDs: [LauncherTool.toggleHotkeyID])
    }

    /// 此刻各模块声明的图片动作（呼出时调一次）：只在输入里挂着图片、或输入是图片文件的路径时作为建议出现（§5.5）。
    func imageActions() -> [LauncherCatalogCommand] {
        guard let registry else { return [] }
        let declared = registry.tools.flatMap { tool in
            tool.launcherCommands().map { LauncherCatalogCommand(command: $0, toolID: tool.id, toolName: tool.name) }
        }
        return LauncherCommandCatalog.imageActions(declared: declared, excludedIDs: [LauncherTool.toggleHotkeyID])
    }

    /// 此刻各模块声明的文件动作（呼出时调一次）：只在输入是一个存在的文件的路径时接在路径行后面（§6.5，PR 10）。
    func fileActions() -> [LauncherCatalogCommand] {
        guard let registry else { return [] }
        let declared = registry.tools.flatMap { tool in
            tool.launcherCommands().map { LauncherCatalogCommand(command: $0, toolID: tool.id, toolName: tool.name) }
        }
        return LauncherCommandCatalog.fileActions(declared: declared, excludedIDs: [LauncherTool.toggleHotkeyID])
    }

    /// 快捷键动作 → 无参数命令。开关类动作此刻有 `stateTitle` 就用它当标题（「关闭防休眠」）。
    static func command(from definition: HotkeyDefinition, symbolName: String) -> LauncherCommand {
        var title = definition.title
        if let stateTitle = definition.stateTitle?(), !stateTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            title = stateTitle
        }
        let action = definition.action
        return LauncherCommand(id: definition.id, title: title, symbolName: symbolName) { _ in action() }
    }

    /// 命令表 → 面板条目；搜索键走缓存。有破坏性的命令（`destructive`）要按两次 ⏎：第一次标题换成「再按一次回车：<命令名>」。
    func items(from catalog: [LauncherCatalogCommand]) -> [LauncherItem] {
        let keys = keyCache.keys(for: catalog)
        return zip(catalog, keys).map { entry, searchKeys in
            let command = entry.command
            let candidate = LauncherCandidate(sourceID: Self.sourceID, entryID: command.id, searchKeys: searchKeys)
            var item = LauncherItem(candidate: candidate,
                                    row: LauncherRow(id: candidate.key, title: command.title, source: entry.toolName,
                                                     icon: .symbol(command.symbolName)),
                                    run: { command.run([:]) })
            if command.destructive {
                item.confirmation = LauncherConfirmation(verb: nil, object: command.title)
            }
            return item
        }
    }
}
