import Foundation

// 路径行的动作（docs/launcher/TECH_DESIGN.md §6.5「路径行的动作」，第 10 步）：输入是一个完整存在的路径（不是半截补全）时，
// 路径那一行（文件夹是它本身那一行）后面、文件夹内容之前，接最多 3 行：
// - 文件夹：在终端里打开、复制路径；
// - 文件：复制路径，再加各模块声明的文件动作（发到手机），按档位排；
// - 包（`.app` 这类，路径行当成一个文件、不进去）：只有复制路径 —— 模块的文件动作只收真正的文件。
// 这里是出哪几行的规则（纯值，进 BaoboxTests）；换成行（文案、图标、执行）在 App 侧 `Providers/PathActionProvider.swift`。

/// 一个完整存在的路径：路径行带着它，引擎据此在后面接动作行。
struct LauncherPathTarget: Equatable, Sendable {
    /// 绝对路径（已展开 `~`、去掉末尾的 `/`）。
    let path: String
    let isDirectory: Bool
    /// 文件夹形式的包（`.app`）：当成一个文件。
    var isPackage = false
}

/// 路径行后面的一行动作。
enum LauncherPathAction: Equatable, Sendable {
    /// 在偏好终端里打开这个文件夹（只开、不跑命令）。
    case openInTerminal
    /// 复制完整路径（⏎ 复制，⌘⏎ 插入原来的 App）。
    case copyPath
    /// 模块声明的第 N 条文件动作（下标是传进来的顺序）。
    case declared(Int)
}

enum LauncherPathActionPlan {
    /// 最多几行（设计：路径行和文件夹内容之间不要隔太多）。
    static let maxRows = 3

    /// 这个路径后面出哪几行。`declaredPriorities`：模块声明的文件动作的档位（按声明的顺序）；按档位排、同档按声明顺序。
    static func actions(for target: LauncherPathTarget, declaredPriorities: [Int]) -> [LauncherPathAction] {
        if target.isDirectory && !target.isPackage {
            return Array([LauncherPathAction.openInTerminal, .copyPath].prefix(maxRows))
        }
        var actions: [LauncherPathAction] = [.copyPath]
        if !target.isPackage {
            let order = declaredPriorities.indices.sorted { a, b in
                declaredPriorities[a] != declaredPriorities[b] ? declaredPriorities[a] < declaredPriorities[b] : a < b
            }
            actions += order.map { LauncherPathAction.declared($0) }
        }
        return Array(actions.prefix(maxRows))
    }
}
