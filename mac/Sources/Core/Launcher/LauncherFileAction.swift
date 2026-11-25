import Foundation

// 快速入口的「文件动作」（docs/launcher/TECH_DESIGN.md §6.5「路径行的动作」，第 10 步）：输入是一个存在的文件的路径时，
// 路径那一行后面接「可以拿这个文件做什么」—— 快速入口自己的「复制路径」，再加各模块声明的（手机互传的「发到手机」）。
// 照图片动作（`LauncherImageAction.swift`）的办法：模块在 `launcherCommands()` 里声明恰好一个必填 `.file` 参数的命令，
// 快速入口不认识它们是谁。只用在文件上（不是文件夹、不是 `.app` 这类包）；文件搜索结果里的文件行不接。
// 只依赖 Foundation，进 BaoboxTests。

extension LauncherCommand {
    /// 文件动作的那个参数的名字（`fileAction(…)` 造的命令都用它）。
    static let fileParameterKey = "file"

    /// 文件动作：`parameters` 恰好是一个必填的 `.file` 参数。只在输入是一个存在的文件的路径时，作为路径行后面的动作出现；
    /// 不进普通的搜索结果（没有文件可给时执行不了）。
    var isFileAction: Bool {
        guard parameters.count == 1, let parameter = parameters.first else { return false }
        return parameter.kind == .file && parameter.required
    }

    /// 文件动作的参数名；不是文件动作为 nil。
    var fileParameterName: String? {
        isFileAction ? parameters.first?.name : nil
    }

    /// 造一条文件动作：一个必填的文件参数，`run` 直接收到那个文件的网址（`file://`，文件存在，不是文件夹）。
    /// 排在哪看 `suggestion.priority`（档位，小的在前；快速入口自己的「复制路径」总在最前）。
    static func fileAction(id: String, title: String, symbolName: String,
                           suggestion: LauncherSuggestionTraits = LauncherSuggestionTraits(),
                           hint: String = "要处理的文件",
                           run: @escaping @MainActor (URL) -> Void) -> LauncherCommand {
        LauncherCommand(id: id, title: title, symbolName: symbolName,
                        parameters: [LauncherParameter(name: fileParameterKey, kind: .file, required: true, hint: hint)],
                        suggestion: suggestion) { arguments in
            guard case .file(let url)? = arguments[fileParameterKey] else { return }
            run(url)
        }
    }
}
