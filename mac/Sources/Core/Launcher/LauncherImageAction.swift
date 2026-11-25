import Foundation

// 快速入口的「图片动作」（docs/launcher/TECH_DESIGN.md §5.5）：输入里挂着一张图片（贴进来、拖进来、剪贴板历史里的图片按 Tab），
// 或输入是一个图片文件的路径时，列表里出「可以拿这张图做什么」—— 取字、钉在屏幕上、预览、保存成文件……
// 照文字动作（`LauncherTextAction.swift`）的办法：模块在 `launcherCommands()` 里声明恰好一个必填 `.image` 参数的命令，
// 快速入口不认识它们是谁。只依赖 Foundation，进 BaoboxTests；把图解码成 `CGImage` 的在 `Core/LauncherImageLoader.swift`。

/// 交给图片动作的一张图。
///
/// 为什么不传解码好的位图：这里只能 import Foundation；而且附件要在面板开着的整段时间里留着，留编码后的字节比留位图
/// 省得多（2560×1440 的截图 PNG 一两 MB，位图 14 MB）。动作真要用时各自在后台解码一次。
/// 为什么不一律写成临时文件：贴进来的图本来就在内存里，写一份临时文件既多一次磁盘 IO、又多一个要清理的文件；
/// 而访达里的图片文件本来就在磁盘上，直接给路径，不用先读进来。
enum LauncherImage: Equatable, Sendable {
    /// 内存里的编码字节（PNG / TIFF / JPEG……，剪贴板上原样拿来的）。`Data` 写时复制：附件和交给动作的是同一块内存。
    case data(Data)
    /// 磁盘上的一个图片文件。
    case file(URL)
}

extension LauncherCommand {
    /// 图片动作的那个参数的名字（`imageAction(…)` 造的命令都用它）。
    static let imageParameterKey = "image"

    /// 图片动作：`parameters` 恰好是一个必填的 `.image` 参数。它只在「输入里挂着图片 / 输入是图片文件的路径」时
    /// 作为建议出现；不进普通的搜索结果（没有图片可给时执行不了）。
    var isImageAction: Bool {
        guard parameters.count == 1, let parameter = parameters.first else { return false }
        return parameter.kind == .image && parameter.required
    }

    /// 图片动作的参数名；不是图片动作为 nil。
    var imageParameterName: String? {
        isImageAction ? parameters.first?.name : nil
    }

    /// 造一条图片动作：一个必填的图片参数，`run` 直接收到那张图。排在哪看 `suggestion.priority`（档位，小的在前）。
    /// - Parameter hint: 写进提示词的参数说明（二期「一句话 → 命令」用）。
    static func imageAction(id: String, title: String, symbolName: String, keywords: [String] = [],
                            suggestion: LauncherSuggestionTraits = LauncherSuggestionTraits(),
                            hint: String = "要处理的图片",
                            run: @escaping @MainActor (LauncherImage) -> Void) -> LauncherCommand {
        LauncherCommand(id: id, title: title, keywords: keywords, symbolName: symbolName,
                        parameters: [LauncherParameter(name: imageParameterKey, kind: .image, required: true, hint: hint)],
                        suggestion: suggestion) { arguments in
            guard case .image(let image)? = arguments[imageParameterKey] else { return }
            run(image)
        }
    }
}
