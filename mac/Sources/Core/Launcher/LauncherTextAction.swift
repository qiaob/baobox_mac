import Foundation

// 快速入口的「文字动作」（docs/launcher/TECH_DESIGN.md §5.4）：输入框里放进任何文字，列表里都有「可以拿它做什么」的建议。
// 输入先被归成一类（`LauncherTextKind`，规则在 `Modules/Launcher/Logic/LauncherInputClassifier.swift`），
// 各模块声明的文字动作按自己适用哪几类决定出不出、排在哪。只依赖 Foundation，进 BaoboxTests。

/// 输入的类别。基本类别一段输入只属于其中一类（优先级：网址 > 邮箱 > 颜色 > 英文单词 > 一大段文字 > 其余）；
/// 「像命令」「带时间的句子」是额外的标记，和普通文字 / 一大段文字同时成立（PR 10）。用集合表示，动作声明「适用哪几类」。
enum LauncherTextKind: String, CaseIterable, Sendable {
    /// 网址、域名（`https://…`、`example.com/path`、`localhost:8080`、`192.168.1.1:3000`）。
    case url
    /// 邮箱地址（`name@example.com`）。
    case email
    /// 颜色值（`#17A398`、`rgb(…)`、`hsl(…)`）。
    case color
    /// 一个英文单词或 2–3 个词的短语（只有英文字母，可带连字符、撇号）。
    case word
    /// 一大段文字（80 个字符及以上）。
    case longText
    /// 其余的文字。
    case plainText
    /// 像一条终端命令（`git status`、`$ npm run build`）。和普通文字同时成立（像命令时不再算英文单词、一大段文字）。
    case command
    /// 带时间的句子（「20 分钟后提醒我取快递」「明天下午三点开会」）。和普通文字 / 一大段文字同时成立。
    case reminder
}

/// 一条文字动作作为建议时的属性：对哪些输入适用、默认排在哪。不是文字动作的命令用不到它。
///
/// 优先级是档位，小的在前；快速入口自己的两条是「上网搜」30、「搜文件名」40。现在各模块用的档位：
/// 10 翻译 / 学习，20 解释 / 总结，50 存为片段 / 钉成贴卡 / 二维码，60 润色（PR 10 起的见 docs/launcher/TECH_DESIGN.md §5.4 的表）。
/// 同一档里用得多的在前，用得很多（7 次以上）的能往前挪三档；输入属于 `boostedKinds` 时直接排到所有档位前面。
struct LauncherSuggestionTraits: Equatable, Sendable {
    /// 对这几类输入适用（默认：任何文字）。
    var kinds: Set<LauncherTextKind> = Set(LauncherTextKind.allCases)
    /// 默认优先级（档位），小的在前。
    var priority: Int = 50
    /// 输入属于这几类时提到最前（单词 → 学习；一大段文字 → 总结、润色；网址 → 二维码）。
    var boostedKinds: Set<LauncherTextKind> = []
    /// 文字动作也用在图片里认出的文字上：输入里挂着图片（或输入是一个图片文件的路径）时，出一行「<命令名>图里的文字」，
    /// 和图片动作排在一起，值是那时的档位（同图片动作的 `priority`）；执行时先本机取字、再把认出的文字交给它
    /// （docs/launcher/TECH_DESIGN.md §5.5）。nil（默认）= 不出。图片动作不看它。
    var imageTextPriority: Int?
    /// 只对情景建议有用（`ToolModule.launcherContextSuggestions()`，docs/launcher/TECH_DESIGN.md §5.6）：执行时记不记使用记录。
    /// 默认记（和对应的命令同一个键）；每一行都只出现一次、以后用不上的（Claude Code 在等的会话，id 带会话）设 false ——
    /// 不然每执行一次就多一个永远用不上的键，还把会话 id 写进使用记录文件。文字 / 图片动作不看它。
    var recordsUsage: Bool
    /// 文字动作：适用时不进兜底建议，排在最前的对应建议后面（网址的「打开」后面紧接着），不看使用记录、只按档位排 ——
    /// 只给很确定的输入用（「是会议链接」→「入会并开始会议记录」，配合 `LauncherCommand.appliesTo`）。PR 10。
    var leading = false
    /// 图片动作：只用在挂着的图片上，图片文件的路径行后面不出 —— 那里已经有做同一件事的文件动作
    /// （「把图片发到手机」↔ 路径行的「发到手机」，docs/launcher/TECH_DESIGN.md §6.5）。PR 10。
    var skipsImageFiles = false

    init(kinds: Set<LauncherTextKind> = Set(LauncherTextKind.allCases), priority: Int = 50,
         boostedKinds: Set<LauncherTextKind> = [], imageTextPriority: Int? = nil, recordsUsage: Bool = true,
         leading: Bool = false, skipsImageFiles: Bool = false) {
        self.kinds = kinds
        self.priority = priority
        self.boostedKinds = boostedKinds
        self.imageTextPriority = imageTextPriority
        self.recordsUsage = recordsUsage
        self.leading = leading
        self.skipsImageFiles = skipsImageFiles
    }
}

extension LauncherCommand {
    /// 文字动作的那个参数的名字（`textAction(…)` 造的命令都用它）。
    static let textParameterKey = "text"

    /// 文字动作：`parameters` 恰好是一个必填的 `.text` 参数。它只作为「对当前输入的建议」出现在列表最后，
    /// 执行时输入框里的文字就是这个参数；不进普通的搜索结果（没有文字可给时执行不了）。
    var isTextAction: Bool {
        guard parameters.count == 1, let parameter = parameters.first else { return false }
        return parameter.kind == .text && parameter.required
    }

    /// 文字动作的参数名；不是文字动作为 nil。
    var textParameterName: String? {
        isTextAction ? parameters.first?.name : nil
    }

    /// 这条文字动作对 `text` 适不适用：没写 `appliesTo` 就适用（类别由调用方先看）。
    @MainActor
    func applies(to text: String) -> Bool {
        appliesTo?(text) ?? true
    }

    /// 造一条文字动作：一个必填的文字参数，`run` 直接收到那段文字。
    /// - Parameters:
    ///   - hint: 写进提示词的参数说明（二期「一句话 → 命令」用）。
    ///   - appliesTo: 对这段文字适不适用（类别之外再细一层，见 `LauncherCommand.appliesTo`）；nil = 适用。
    static func textAction(id: String, title: String, symbolName: String,
                           suggestion: LauncherSuggestionTraits = LauncherSuggestionTraits(),
                           hint: String = "要处理的文字",
                           appliesTo: (@MainActor (String) -> Bool)? = nil,
                           run: @escaping @MainActor (String) -> Void) -> LauncherCommand {
        LauncherCommand(id: id, title: title, symbolName: symbolName,
                        parameters: [LauncherParameter(name: textParameterKey, kind: .text, required: true, hint: hint)],
                        suggestion: suggestion, appliesTo: appliesTo) { arguments in
            guard case .text(let text)? = arguments[textParameterKey] else { return }
            run(text)
        }
    }
}
