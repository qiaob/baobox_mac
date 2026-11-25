import Foundation

// 快速入口的命令模型（docs/launcher/TECH_DESIGN.md §3.1）：各工具在 `ToolModule.launcherCommands()` 里声明
// 带参数的命令和没有快捷键的动作，快速入口把它们搜出来执行，二期也拿它当「一句话 → 命令」的命令表。
// 只依赖 Foundation，进 BaoboxTests；标题、说明这些文案由模块用 `L()` 取好再传进来。

/// 命令的一个参数。
struct LauncherParameter {
    /// 参数的类型；执行时对应的值见 `LauncherArgument`。
    enum Kind: Equatable, Sendable {
        /// 时长，值是秒数。
        case duration
        case number
        case text
        /// 从给定的候选里选一个（候选是给代码和模型看的取值，不是显示文案）。
        case choice([String])
        /// 剪贴板最新一条：模型只输出占位值 `"@clipboard"`，内容由代码在执行时去取（§8.2）。
        case clipboardRef
        /// 一张图片（输入里挂着的附件、贴进来的图片文件），值见 `LauncherImage`（docs/launcher/TECH_DESIGN.md §5.5）。
        case image
    }

    /// 模型输出里的键，也是 `run` 收到的字典里的键，如 "duration"。
    let name: String
    let kind: Kind
    let required: Bool
    /// 写进提示词的一句说明。
    let hint: String
}

/// 执行命令时一个参数的值，与 `LauncherParameter.Kind` 一一对应。
enum LauncherArgument: Equatable, Sendable {
    /// 秒数。
    case duration(TimeInterval)
    case number(Double)
    case text(String)
    /// 选中的候选（`Kind.choice` 里的一个）。
    case choice(String)
    /// 剪贴板最新一条的引用，不带内容 —— 执行时由代码去取，所以剪贴板里的文字没法冒充指令（§8.2）。
    case clipboardRef
    /// 一张图片：内存里的编码字节或磁盘上的图片文件（`LauncherImage`）。
    case image(LauncherImage)
}

/// 一条命令。`run` 只调模块已有的方法，不新增能力（§3.1）。
struct LauncherCommand {
    /// 稳定标识，如 "caffeinate.start"；和某个快捷键 id 相同时，声明的命令覆盖快捷键自动生成的那条。
    let id: String
    /// 列表里显示的名字。
    let title: String
    /// 额外的搜索词和同义说法（「别睡」「保持唤醒」）。
    var keywords: [String] = []
    /// SF Symbol 名。
    let symbolName: String
    var parameters: [LauncherParameter] = []
    /// true = 有破坏性，要按两次 ⏎。
    var destructive: Bool = false
    /// 作为「对当前输入的建议」时的属性（适用哪几类输入、默认排在哪）。只对文字动作（恰好一个必填 `.text` 参数，
    /// 见 `isTextAction`）和图片动作（恰好一个必填 `.image` 参数，见 `isImageAction`，只看 `priority`）有用，
    /// 其余命令不看它（docs/launcher/TECH_DESIGN.md §5.4、§5.5）。
    /// 例外：模块在 `launcherContextSuggestions()` 里交的情景建议也只看 `priority` —— 空着时按它排（小的在前，§5.6）。
    var suggestion = LauncherSuggestionTraits()
    /// 文字动作对这段文字适不适用（PR 10，docs/launcher/TECH_DESIGN.md §5.4「适用性判断」）：类别（`suggestion.kinds`）
    /// 之外再细一层，比如「是会议链接」「不超过命令行的长度上限」。nil = 适用。类别对得上才调；打字时每次按键都可能调：
    /// 只能看这段文字和内存里的状态，不读盘、不联网、不阻塞。
    var appliesTo: (@MainActor (String) -> Bool)? = nil
    /// 执行。字典的键是 `LauncherParameter.name`；没给的可选参数不在字典里。
    let run: @MainActor ([String: LauncherArgument]) -> Void
}
