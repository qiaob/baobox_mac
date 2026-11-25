import Foundation

// 设置页「快速入口」的功能清单（docs/launcher/TECH_DESIGN.md §11「功能开关」，第 13 步）：快速入口能做的全部事情，每一项一个开关。
// 框架不认识具体工具：来源从各模块的 `launcherSources()` 收（名字 = `launcherSourceName`、图标 = 所属工具的图标、
// 右侧 = 所属工具名），动作从各模块的 `launcherCommands()` 里的文字 / 图片 / 文件动作收（名字 = 命令标题、图标 = 命令自己的、
// 右侧 = 所属工具名）；快速入口自己的功能是一张静态表（`LauncherBuiltInFeature`，名字和说明在这里取本地化文案）。
// 设置页出现时收集一次（主线程、只读内存 —— 和每次呼出时做的是同一件事）。没装 Claude Code 时它不声明「交给 Claude Code」，
// 这一行自然就没有；被关掉、这次没人声明的 id 仍留在设置里（`LauncherFeatureSettings` 不清理）。分组与次序在 `LauncherFeatureLayout`。

@MainActor
enum LauncherFeatureCatalog {
    /// 此刻的全部行（还没分组）。模块的在前、快速入口自己的在后 —— 同一档位时模块的动作排在前面，和面板里兜底建议的次序一致。
    static func rows(registry: ToolRegistry?) -> [LauncherFeatureRow] {
        var rows: [LauncherFeatureRow] = []
        if let registry {
            for tool in registry.tools {
                for source in tool.launcherSources() {
                    rows.append(LauncherFeatureLayout.sourceRow(sourceID: source.launcherSourceID, name: source.launcherSourceName,
                                                                toolName: tool.name, symbolName: tool.symbolName))
                }
            }
            // 不设开关的实例：收全部动作（面板里用的那个会按开关过滤）。
            let commands = LauncherCommandProvider(registry: registry)
            rows += LauncherFeatureLayout.actionRows(text: commands.textActions(), image: commands.imageActions(),
                                                     file: commands.fileActions())
        }
        rows += LauncherBuiltInFeature.allCases.map { feature in
            LauncherFeatureRow(id: feature.id, group: feature.group, title: feature.title, detail: feature.detail,
                               symbolName: feature.symbolName, order: feature.order)
        }
        return rows
    }
}

extension LauncherBuiltInFeature {
    /// 设置页里的名字。
    var title: String {
        switch self {
        case .apps: return L("launcher.feature.apps")
        case .commands: return L("launcher.feature.commands")
        case .files: return L("launcher.feature.files")
        case .path: return L("launcher.feature.path")
        case .calculator: return L("launcher.feature.calculator")
        case .textFormat: return L("launcher.feature.textFormat")
        case .url: return L("launcher.feature.url")
        case .email: return L("launcher.feature.email")
        case .color: return L("launcher.feature.color")
        case .wordCount: return L("launcher.feature.wordCount")
        case .reminder: return L("launcher.feature.reminder")
        case .runInTerminal: return L("launcher.feature.runInTerminal")
        case .webSearch: return L("launcher.feature.webSearch")
        case .fileName: return L("launcher.feature.fileName")
        case .imageRecognition: return L("launcher.feature.imageRecognition")
        case .openInTerminal: return L("launcher.path.openInTerminal")
        case .copyPath: return L("launcher.path.copyPath")
        case .selection: return L("launcher.feature.selection")
        case .clipboard: return L("launcher.feature.clipboard")
        case .situational: return L("launcher.feature.situational")
        case .frequent: return L("launcher.feature.frequent")
        }
    }

    /// 名字下面一行小字（一句）；nil = 不用说明。
    var detail: String? {
        switch self {
        case .commands: return L("launcher.feature.commands.detail")
        case .files: return L("launcher.feature.files.detail")
        case .path: return L("launcher.feature.path.detail")
        case .calculator: return L("launcher.feature.calculator.detail")
        case .textFormat: return L("launcher.feature.textFormat.detail")
        case .reminder: return L("launcher.feature.reminder.detail")
        case .runInTerminal: return L("launcher.feature.runInTerminal.detail")
        case .fileName: return L("launcher.feature.fileName.detail")
        case .openInTerminal: return L("launcher.feature.openInTerminal.detail")
        case .clipboard: return L("launcher.feature.clipboard.detail")
        case .situational: return L("launcher.feature.situational.detail")
        case .apps, .url, .email, .color, .wordCount, .webSearch, .imageRecognition, .copyPath, .selection, .frequent:
            return nil
        }
    }
}

extension LauncherFeatureGroup {
    /// 小节标题。
    var title: String {
        switch self {
        case .search: return L("launcher.settings.group.search")
        case .instant: return L("launcher.settings.group.instant")
        case .text: return L("launcher.settings.group.text")
        case .image: return L("launcher.settings.group.image")
        case .file: return L("launcher.settings.group.file")
        case .emptyState: return L("launcher.settings.group.emptyState")
        }
    }

    /// 标题后面同一行的小字：这一组管什么时候；nil = 标题已经说清楚了。
    var explanation: String? {
        switch self {
        case .search: return L("launcher.settings.group.search.detail")
        case .instant: return L("launcher.settings.group.instant.detail")
        case .text: return L("launcher.settings.group.text.detail")
        case .image: return L("launcher.settings.group.image.detail")
        case .file: return L("launcher.settings.group.file.detail")
        case .emptyState: return nil
        }
    }
}
