import AppKit

// 路径行的动作（docs/launcher/TECH_DESIGN.md §6.5「路径行的动作」，第 10 步）：输入是一个完整存在的路径时，路径行后面、文件夹内容之前
// 接最多 3 行 —— 文件夹「在终端里打开」「复制路径」；文件「复制路径」+ 各模块声明的文件动作（「发到手机」）。出哪几行的规则在
// `Logic/LauncherPathActions.swift`；这里换成行。都不记使用（同路径行），也不读盘：路径是不是文件夹，路径那一行查过了。

/// 一次路径输入的动作行。
struct LauncherPathActionRows {
    var rows: [LauncherRow] = []
    /// 复制类的（复制路径：⏎ 复制、⌘⏎ 插入原来的 App，同计算结果）。
    var instants: [LauncherInstant] = []
    /// 动作类的（在终端里打开、模块声明的文件动作）。
    var actions: [LauncherSuggestion] = []
}

@MainActor
enum LauncherPathActionProvider {
    /// `fileActions`：模块声明的文件动作（设置里关掉的已经去掉）；`features`：「在终端里打开」「复制路径」的开关（第 13 步）。
    static func rows(for target: LauncherPathTarget, fileActions: [LauncherCatalogCommand],
                     features: LauncherFeatureSet = .allEnabled) -> LauncherPathActionRows {
        let declared = fileActions.filter { $0.command.isFileAction }
        var output = LauncherPathActionRows()
        let plan = LauncherPathActionPlan.actions(for: target, declaredPriorities: declared.map(\.command.suggestion.priority),
                                                  features: features)
        for action in plan {
            switch action {
            case .copyPath:
                let row = LauncherRow(id: "pathaction/copy", title: L("launcher.path.copyPath"), source: L("launcher.name"),
                                      icon: .symbol("doc.on.doc"))
                output.rows.append(row)
                output.instants.append(LauncherInstant(row: row, copyText: target.path))
            case .openInTerminal:
                let row = LauncherRow(id: "pathaction/terminal", title: L("launcher.path.openInTerminal"),
                                      source: L("launcher.suggest.source.terminal"), icon: .symbol("terminal"))
                let path = target.path
                output.rows.append(row)
                output.actions.append(LauncherSuggestion(row: row, usageKey: nil, action: .run {
                    TerminalLauncher.run(command: LauncherShellHandoff.interactiveShell, in: path)
                }))
            case .declared(let index):
                guard declared.indices.contains(index), let parameter = declared[index].command.fileParameterName else { continue }
                let entry = declared[index]
                let command = entry.command
                let url = URL(fileURLWithPath: target.path)
                let row = LauncherRow(id: "fileaction/\(command.id)", title: command.title, source: entry.toolName,
                                      icon: .symbol(command.symbolName))
                output.rows.append(row)
                output.actions.append(LauncherSuggestion(row: row, usageKey: nil,
                                                         action: .run { command.run([parameter: .file(url)]) }))
            }
        }
        return output
    }
}
