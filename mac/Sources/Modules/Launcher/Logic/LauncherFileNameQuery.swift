import Foundation

// 快速入口：输入像不像一个文件名（docs/launcher/TECH_DESIGN.md §6.4「像文件名」，PR 11）。
// 2026-11-24 用户实测：输入 `add-approval-hook.py`，列表前两行是剪贴板，接着是翻译、解释……
// 「我如果输入一个文件，第一优先级应该是打开文件吧。」—— 所以输入像文件名时，名字完全等于它的文件固定排第一，⏎ 就是打开。
// 只看这段文字：纯函数，每次按键跑一次。只依赖 Foundation，进 BaoboxTests。

enum LauncherFileNameQuery {
    /// 扩展名最多几个字符：10 个（PR 11 独立验证后从 8 放宽，`Localizable.xcstrings`、`x.properties` 要能拿到固定行；
    /// 同「目录/文件名」片段的规则）。
    static let maxExtensionLength = 10
    /// 文件名最长 255 个字节。
    static let maxNameBytes = 255

    /// 输入（已去掉前缀和首尾空白）像一个文件名时返回它，否则 nil。规则：
    /// - 形如「名字.扩展名」：最后一个点不在开头也不在末尾，扩展名 1–10 个 ASCII 字母数字、至少一个字母
    ///   （`v2.0`、`3.14`、`1.5` 这类数字不算；`.zshrc` 没有名字，不算）；
    /// - 空白只能是普通空格（`报告 final.pdf`）：有制表符、换行的不算；不含 `/`（那是片段或路径，各有各的路）；
    /// - 不是带 scheme 的网址（不含 `:`：`https://x.com/a.md`、`mailto:a@b.com`；访达里的名字也不会有 `:`）。
    /// 和「网址」不互斥：`claude.ai`、`Safari.app`、`main.cc`、`github.com` 既像域名又像文件名，这里照样认 ——
    /// 找到了名字正好是它的文件才多出一行固定行，找不到什么都不多出；网址那边的规则不变。
    static func fileName(in text: String) -> String? {
        guard !text.isEmpty, text.utf8.count <= maxNameBytes,
              !text.hasPrefix(" "), !text.hasSuffix(" "),
              !text.contains("/"), !text.contains(":"),
              !text.unicodeScalars.contains(where: { $0 != " " && CharacterSet.whitespacesAndNewlines.contains($0) }),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let dot = text.lastIndex(of: "."), dot != text.startIndex
        else { return nil }
        let name = text[..<dot]
        let ext = text[text.index(after: dot)...]
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              (1...maxExtensionLength).contains(ext.count),
              ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              ext.contains(where: \.isLetter)
        else { return nil }
        return text
    }
}
