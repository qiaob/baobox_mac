import AppKit
import UserNotifications

/// 局域网传输 —— 系统通知。
///
/// 模式照 `AIToolsNotify`：授权失败、未签名 dev 包发不出通知都不影响传输本身，全部判空不 crash。
///
/// 用户可见文案（L key）：
///   - landrop.notify.start %@        zh:「开始接收 %@」          en:「Receiving %@」
///   - landrop.notify.done.title      zh:「文件已接收」            en:「File received」
///   - landrop.notify.done.body %@    zh:「%@」                    en:「%@」
///   - landrop.notify.failed.title    zh:「接收失败」              en:「Transfer failed」
@MainActor
enum LanDropNotify {

    /// 首次开启服务时请求一次授权。用户拒绝也不再打扰。
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 开始接收（每个文件一条，可在设置里关）。
    static func postStart(name: String) {
        guard LanDropEnv.notifyStart else { return }
        post(title: L("landrop.notify.start \(name)"), body: nil)
    }

    /// 接收完成：标题固定，正文给「文件名 · 大小」。
    static func postDone(name: String, bytes: Int) {
        guard LanDropEnv.notifyDone else { return }
        let detail = "\(name) · \(LanDropEnv.formatBytes(bytes))"
        post(title: L("landrop.notify.done.title"), body: L("landrop.notify.done.body \(detail)"))
    }

    /// 接收失败。失败通知不受「完成通知」开关控制——出错必须让用户知道。
    static func postFailed(name: String, reason: String) {
        post(title: L("landrop.notify.failed.title"), body: "\(name) · \(reason)")
    }

    private static func post(title: String, body: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body, !body.isEmpty { content.body = body }
        if LanDropEnv.notifySound { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
