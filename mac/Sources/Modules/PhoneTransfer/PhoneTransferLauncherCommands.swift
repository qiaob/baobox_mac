import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 手机互传给快速入口的动作「发到手机」（docs/launcher/TECH_DESIGN.md §5.4、§6.5，PR 10）：文字动作（输入框里的文字）、
/// 图片动作（挂着的图片）、文件动作（输入是一个存在的文件的路径，接在路径行后面）。
/// - 有手机连着（`PhoneTransferSession.canSend`：窗口开着、局域网有设备 / 公网已连上）：直接发，回执一句。
/// - 没有：打开手机互传的窗口（会话随窗口开），回执「连上手机后再发一次」—— 现有代码没有「连上后自动发」。
/// - 档位 50，和「存为片段」并列（图片动作里排在「保存成文件」40 之后）。
/// 挂着的图片是内存里的字节时，先在后台写成临时文件（`临时目录/Baobox-PhoneTransfer/`，扩展名按图片本来的格式）再发：
/// 手机互传只认文件（局域网模式是手机来取，文件要留着）。写在扩展里，不动 `PhoneTransferTool.swift`。
extension PhoneTransferTool {
    func launcherCommands() -> [LauncherCommand] {
        [
            .textAction(id: "phonetransfer.text.send", title: L("phonetransfer.launcher.send"),
                        symbolName: "iphone.and.arrow.forward", suggestion: LauncherSuggestionTraits(priority: 50),
                        hint: "发到手机的文字") { text in
                PhoneTransferLauncherActions.send(text: text)
            },
            // 图片文件的路径行后面不出（`skipsImageFiles`）：那里已经有下面这条文件动作「发到手机」。
            .imageAction(id: "phonetransfer.image.send", title: L("phonetransfer.launcher.sendImage"),
                         symbolName: "iphone.and.arrow.forward",
                         suggestion: LauncherSuggestionTraits(priority: 50, skipsImageFiles: true),
                         hint: "发到手机的图片") { image in
                PhoneTransferLauncherActions.send(image: image)
            },
            .fileAction(id: "phonetransfer.file.send", title: L("phonetransfer.launcher.send"),
                        symbolName: "iphone.and.arrow.forward", suggestion: LauncherSuggestionTraits(priority: 50),
                        hint: "发到手机的文件") { url in
                PhoneTransferLauncherActions.send(file: url)
            },
        ]
    }
}

/// 快速入口交来的东西怎么发到手机。
@MainActor
enum PhoneTransferLauncherActions {
    static func send(text: String) {
        guard isConnected() else { return }
        PhoneTransferSession.shared.send(text: text)
        toast(L("phonetransfer.launcher.toast.sentText"))
    }

    static func send(file url: URL) {
        guard isConnected() else { return }
        guard PhoneTransferSettings.fileSize(url) != nil else {
            toast(L("phonetransfer.launcher.toast.unreadable \(url.lastPathComponent)"))
            return
        }
        PhoneTransferSession.shared.send(files: [url])
        toast(L("phonetransfer.launcher.toast.sentFile \(url.lastPathComponent)"))
    }

    static func send(image: LauncherImage) {
        guard isConnected() else { return }
        switch image {
        case .file(let url):
            send(file: url)
        case .data(let data):
            DispatchQueue.global(qos: .userInitiated).async {
                let url = writeTemporaryImage(data)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let url else {
                            toast(L("phonetransfer.launcher.toast.imageFailed"))
                            return
                        }
                        send(file: url)
                    }
                }
            }
        }
    }

    /// 有手机连着就是 true；没有就打开手机互传的窗口（扫码连上）、回执一句，返回 false。
    private static func isConnected() -> Bool {
        guard PhoneTransferSession.shared.canSend else {
            PhoneTransferWindowController.shared.show()
            toast(L("phonetransfer.launcher.toast.connectFirst"))
            return false
        }
        return true
    }

    /// 图片字节写成临时文件（后台调）：文件名「Baobox 2026-11-25 14.35.12.png」，扩展名按字节本来的格式（认不出按 png）。
    nonisolated private static func writeTemporaryImage(_ data: Data) -> URL? {
        let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }
        let ext = type.flatMap { UTType($0)?.preferredFilenameExtension } ?? "png"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Baobox-PhoneTransfer", isDirectory: true)
        var url = directory.appendingPathComponent("Baobox \(formatter.string(from: Date())).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("Baobox \(formatter.string(from: Date())) \(index).\(ext)")
            index += 1
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// 回执（同防休眠：是用户刚点的操作的回执，勿扰时也照常显示）。
    private static func toast(_ text: String) {
        NotifyCenter.shared.post(Notice(source: "phonetransfer", level: .ambient, title: text,
                                        icon: "iphone.and.arrow.forward", isUserFeedback: true))
    }
}
