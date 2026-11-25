import Foundation

// 快速入口的文本识别行（docs/launcher/TECH_DESIGN.md §6.3）：输入像时间戳、JWT、Base64、JSON、URL 时直接给出转换结果。
// 识别器是剪贴板文本工具那一套（`Core/TextTools/`，同一组开关）；取优先级最高的那个识别结果，
// 换成最多 3 行（规则在 `Logic/LauncherInstantResults.swift` 的 `LauncherConversions`）。⏎ 复制，不记使用。

@MainActor
enum LauncherTextFormatProvider {
    /// 这次输入的识别结果行（计算结果之后、普通结果之前）；认不出为空。
    static func instants(for text: String) -> [LauncherInstant] {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = TextFormatRegistry.detectAll(input).first else { return [] }
        let table = match.rows.map {
            LauncherConversionTableRow(label: $0.label, value: $0.value, copyValue: $0.copyValue)
        }
        let conversions = LauncherConversions.rows(input: input, badge: match.badge, table: table,
                                                   transforms: transforms(match.actions))
        return conversions.enumerated().map { index, conversion in
            LauncherInstant(row: LauncherRow(id: "textformat/\(match.id)/\(index)", title: conversion.title,
                                             source: conversion.detail, icon: .symbol("arrow.left.arrow.right")),
                            copyText: conversion.copyText)
        }
    }

    /// 识别器第一次跑要建一串 DateFormatter（时间识别）：预热时先跑一次。
    static func warmUp() {
        _ = TextFormatRegistry.detectAll("2026-11-24 10:00:00")
    }

    /// 识别器的动作里能用的文字转换，按出现的顺序（下拉里的子项展开）。置灰的、出图片的、自己收尾的都不要。
    private static func transforms(_ actions: [FormatAction]) -> [LauncherConversionTransform] {
        actions.flatMap { action -> [LauncherConversionTransform] in
            guard action.isEnabled else { return [] }
            switch action.kind {
            case .transform(let run):
                return [LauncherConversionTransform(title: action.title, run: run)]
            case .menu(let children):
                return transforms(children)
            case .imagePreview, .terminal:
                return []
            }
        }
    }
}
