import AppKit
import os

// 挂着图片时的建议行（docs/launcher/TECH_DESIGN.md §5.5）：最前面是识别结果（二维码 / 条码、识别出的文字；还在识别时是一行
// 「正在识别…」），后面是各模块声明的图片动作和「<命令名>图里的文字」，按档位和使用记录排（`LauncherImageSuggestionRanking`）。
// 输入框里打的字是筛选词（按标题匹配）。输入是一个图片文件的路径时（§6.5），路径行后面接同一组动作，但不先取字。
// 快速入口不认识这些动作是谁：标题、图标、所属工具名都来自命令表。规则（排序、筛选、二维码怎么换成行）在 `Logic/LauncherImageSuggestions.swift`。

/// 一次本机取字：后台解码（太大的缩到 4000 万像素以内）+ `TextRecognizer`，跑完回主线程通知等着的人。
/// 挂上附件时建一个、马上开始，只跑这一次；输入是图片文件的路径时，「翻译图里的文字」回车才开始。
/// 附件换了、去了、面板收起了：控制器按对象比较，不是当前附件的就不再刷新列表；但已经在等它的（回车了「翻译图里的文字」）照样拿到结果。
@MainActor
final class LauncherRecognition {
    nonisolated private static let log = Logger(subsystem: "com.baobox.app", category: "launcher")
    private static var nextID = 0

    /// 序号（日志里认是哪一次）。
    let id: Int
    let image: LauncherImage
    private(set) var result: TextRecognizer.Result?
    /// 从开始到结果回到主线程的毫秒数；还没跑完为 nil。
    private(set) var milliseconds: Double?
    private var started = false
    private var waiters: [@MainActor (TextRecognizer.Result) -> Void] = []
    /// 跑完时调（在等着的人之前）：控制器据此刷新列表。
    var onFinish: ((LauncherRecognition) -> Void)?

    init(image: LauncherImage) {
        Self.nextID += 1
        id = Self.nextID
        self.image = image
    }

    var isFinished: Bool { result != nil }

    /// 在后台开始取字（已经开始或跑完了就什么都不做）。取字语言照截图设置里的「识别语言」。
    func start() {
        guard !started else { return }
        started = true
        let image = image
        let languages = TextRecognizer.LanguageOption.preferred.visionLanguages
        let id = id
        let begin = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.global(qos: .userInitiated).async {
            let decoded = LauncherImageLoader.cgImage(image)
            let decodedAt = DispatchTime.now().uptimeNanoseconds
            let result = decoded.map { TextRecognizer.recognize($0, languages: languages) }
                ?? TextRecognizer.Result(text: "", barcodes: [])
            let decodeMs = Double(decodedAt - begin) / 1_000_000
            let recognizeMs = Double(DispatchTime.now().uptimeNanoseconds - decodedAt) / 1_000_000
            Self.log.notice("image #\(id, privacy: .public): decoded \(decoded.map { "\($0.width)×\($0.height)" } ?? "nothing", privacy: .public) in \(decodeMs, format: .fixed(precision: 1), privacy: .public) ms, recognized in \(recognizeMs, format: .fixed(precision: 1), privacy: .public) ms (\(result.text.count, privacy: .public) characters, \(result.barcodes.count, privacy: .public) codes)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finish(result, milliseconds: Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000)
                }
            }
        }
    }

    /// 结果出来后在主线程调 `body`（已经有结果也等到下一个 runloop 再调：调用方往往要先收起面板、还焦点）。还没开始就开始。
    func whenDone(_ body: @escaping @MainActor (TextRecognizer.Result) -> Void) {
        if let result {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { body(result) }
            }
            return
        }
        waiters.append(body)
        start()
    }

    private func finish(_ result: TextRecognizer.Result, milliseconds: Double) {
        self.result = result
        self.milliseconds = milliseconds
        onFinish?(self)
        let waiting = waiters
        waiters = []
        for body in waiting { body(result) }
    }
}

/// 输入里挂着的图片（一次只有一张，再挂一张就换掉）。只留一份：编码后的字节（或文件路径）+ 一张小缩略图；
/// 取字时解出的整图只活在后台那一次取字里。面板收起就丢（不保留 60 秒：图片占内存）。
struct LauncherAttachment {
    let image: LauncherImage
    /// 挂上时就开始的那次取字。
    let recognition: LauncherRecognition
}

/// 一次「挂着图片」查询的建议。
struct LauncherImageSuggestions {
    var rows: [LauncherRow] = []
    /// 复制类的行（识别出的文字、不是网址的二维码内容；「正在识别…」也在这里，⏎ 不做事）。
    var instants: [LauncherInstant] = []
    /// 动作类的行（网址二维码的「打开」、图片动作、「<命令名>图里的文字」）。
    var actions: [LauncherSuggestion] = []
}

@MainActor
enum LauncherImageSuggestionProvider {
    static let recognizingRowID = "image/recognizing"
    static let textRowID = "image/text"

    /// 这张图的建议。
    /// - Parameters:
    ///   - recognition: 挂着的附件的那次取字（出识别结果的行）；nil = 输入是图片文件的路径（不出识别结果，图片动作照出）。
    ///   - filter: 输入框里打的字（去首尾空白后为空 = 不筛）。
    ///   - showsRecognition: false = 设置里关掉了「识别图里的文字和二维码」（第 13 步）：不出识别结果的几行（「正在识别…」、
    ///     二维码、识别出的文字）；取字照样在后台跑 ——「<命令名>图里的文字」要用它。
    static func suggestions(image: LauncherImage, recognition: LauncherRecognition?, filter: String,
                            imageActions: [LauncherCatalogCommand], textActions: [LauncherCatalogCommand],
                            showsRecognition: Bool = true,
                            records: LauncherUsageRecords, now: Date) -> LauncherImageSuggestions {
        var output = LauncherImageSuggestions()
        let filtering = !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        func keeps(_ row: LauncherRow) -> Bool {
            LauncherImageSuggestionFilter.keeps(title: row.title, filter: filter)
        }

        // 识别结果。
        if let recognition, showsRecognition {
            if let result = recognition.result {
                for (index, code) in LauncherRecognizedContent.codes(result.barcodes).enumerated() {
                    let source = L("launcher.image.source.code")
                    if let url = LauncherRecognizedContent.webURL(in: code) {
                        let title = L("launcher.suggest.openURL \(LauncherSuggestionText.quote(code, maxLength: LauncherSuggestionText.leadingQuoteLength))")
                        let row = LauncherRow(id: "image/code/\(index)", title: title, source: source, icon: .symbol("qrcode"))
                        guard keeps(row) else { continue }
                        output.rows.append(row)
                        output.actions.append(LauncherSuggestion(row: row, usageKey: nil,
                                                                 action: .run { NSWorkspace.shared.open(url) }))
                    } else {
                        let row = LauncherRow(id: "image/code/\(index)", title: LauncherSuggestionText.quote(code, maxLength: 300),
                                              source: source, icon: .symbol("qrcode"))
                        guard keeps(row) else { continue }
                        output.rows.append(row)
                        output.instants.append(LauncherInstant(row: row, copyText: code))
                    }
                }
                if let text = LauncherRecognizedContent.text(result.text) {
                    let count = LauncherCalcFormat.grouped(Int64(LauncherRecognizedContent.wordCount(text)))
                    let row = LauncherRow(id: textRowID, title: LauncherRecognizedContent.textTitle(text),
                                          source: L("launcher.image.source.text \(count)"), icon: .symbol("text.viewfinder"))
                    if keeps(row) {
                        output.rows.append(row)
                        output.instants.append(LauncherInstant(row: row, copyText: text))
                    }
                }
            } else if !filtering {
                let row = LauncherRow(id: recognizingRowID, title: L("launcher.image.recognizing"),
                                      source: L("launcher.image.source.recognizing"), icon: .symbol("text.viewfinder"))
                output.rows.append(row)
                output.instants.append(LauncherInstant(row: row, copyText: nil))
            }
        }

        // 图片动作 + 「<命令名>图里的文字」。认出来确定没有字时，后一种不出。
        let actions = imageActions.filter { $0.command.isImageAction }
        let noText = recognition?.result.map { LauncherRecognizedContent.text($0.text) == nil } ?? false
        let onText = noText ? [] : textActions.filter { $0.command.isTextAction && $0.command.suggestion.imageTextPriority != nil }
        let candidates = actions.map { LauncherSuggestionCandidate(id: $0.command.id, traits: $0.command.suggestion) }
            + onText.map { LauncherSuggestionCandidate(id: $0.command.id,
                                                       traits: LauncherSuggestionTraits(priority: $0.command.suggestion.imageTextPriority ?? 50)) }
        // 「图里的文字」交给哪次取字：挂着的附件就用它那次（多半已经跑完）；图片文件的路径到回车时才取。
        let textRecognition = recognition ?? LauncherRecognition(image: image)
        for index in LauncherImageSuggestionRanking.order(candidates, records: records, now: now) {
            let key = LauncherImageSuggestionRanking.usageKey(for: candidates[index].id)
            let suggestion: LauncherSuggestion
            if actions.indices.contains(index) {
                let entry = actions[index]
                let command = entry.command
                guard let parameter = command.imageParameterName else { continue }
                let row = LauncherRow(id: key, title: command.title, source: entry.toolName, icon: .symbol(command.symbolName))
                suggestion = LauncherSuggestion(row: row, usageKey: key, action: .run { command.run([parameter: .image(image)]) })
            } else {
                let entry = onText[index - actions.count]
                let command = entry.command
                guard let parameter = command.textParameterName else { continue }
                let row = LauncherRow(id: key, title: L("launcher.image.textAction \(command.title)"), source: entry.toolName,
                                      icon: .symbol(command.symbolName))
                suggestion = LauncherSuggestion(row: row, usageKey: key,
                                                action: .runOnImageText(textRecognition) { text in command.run([parameter: .text(text)]) })
            }
            guard keeps(suggestion.row) else { continue }
            output.rows.append(suggestion.row)
            output.actions.append(suggestion)
        }
        return output
    }
}
