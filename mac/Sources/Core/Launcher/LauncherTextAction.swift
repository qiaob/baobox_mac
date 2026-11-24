import Foundation

// 快速入口的「文字动作」（docs/launcher/TECH_DESIGN.md §5.4）：输入框里放进任何文字，列表里都有「可以拿它做什么」的建议。
// 输入先被归成一类（`LauncherTextKind`，规则在 `Modules/Launcher/Logic/LauncherInputClassifier.swift`），
// 各模块声明的文字动作按自己适用哪几类决定出不出、排在哪。只依赖 Foundation，进 BaoboxTests。

/// 输入的类别。按目前的规则一段输入只属于其中一类（优先级：网址 > 邮箱 > 颜色 > 英文单词 > 一大段文字 > 其余），
/// 用集合表示是为了动作声明「适用哪几类」。
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
}
