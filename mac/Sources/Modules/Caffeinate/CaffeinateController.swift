import AppKit
import IOKit.pwr_mgt

/// 防休眠相关的 UserDefaults 键与默认值。
enum CaffeinateSettings {
    static let defaultDurationKey = "caffeinate.defaultDuration"
    static let preventDisplaySleepKey = "caffeinate.preventDisplaySleep"

    /// -1 表无限期；单位秒。
    static let infiniteSentinel: Double = -1

    /// 默认时长；未设置时视为无限期（nil）。
    static var defaultDuration: TimeInterval? {
        guard let value = UserDefaults.standard.object(forKey: defaultDurationKey) as? Double else {
            return nil
        }
        return value == infiniteSentinel ? nil : value
    }

    static var preventDisplaySleep: Bool {
        UserDefaults.standard.object(forKey: preventDisplaySleepKey) as? Bool ?? false
    }
}

/// 防休眠断言管理：封装 IOKit 电源管理断言的创建与释放。
@MainActor
final class CaffeinateController: ObservableObject {
    static let shared = CaffeinateController()

    @Published private(set) var isActive = false
    /// 到期时间；nil 表示无限期（仅在 isActive 时有意义）。
    @Published private(set) var until: Date?

    /// 本次开启时所选的原始时长（nil 表无限期），用于菜单勾选当前生效项。
    private(set) var requestedDuration: TimeInterval?

    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?

    private init() {}

    // MARK: - 开关

    func start(duration: TimeInterval?) {
        stop() // 清旧断言

        let assertionType: String = CaffeinateSettings.preventDisplaySleep
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep

        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            assertionType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            L("caffeinate.assertionName") as CFString,
            &id
        )

        guard result == kIOReturnSuccess else {
            // LSUIElement 应用从状态栏菜单触发时并非活跃 App（菜单跟踪不激活应用）。
            // 不先激活的话警告窗会排在其他 App 窗口之后，而主线程已进入模态循环 ——
            // 用户看不到弹窗、没有 Dock 图标可点、菜单也不响应，只能强杀。
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("caffeinate.error.title")
            alert.informativeText = L("caffeinate.error.message \(Int(result))")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("common.ok"))
            alert.runModal()
            return
        }

        assertionID = id
        isActive = true
        requestedDuration = duration

        if let duration {
            until = Date().addingTimeInterval(duration)
            let t = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stop()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            until = nil
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        isActive = false
        until = nil
        requestedDuration = nil
    }

    /// 设置变更（如“同时防显示器休眠”）时若正在生效，用新断言类型重建，尽量保留剩余时长。
    func rebuildIfActive() {
        guard isActive else { return }
        // start() 会把 requestedDuration 覆盖成传入值，而这里传的是「剩余秒数」
        //（如 893.7）。不还原的话，菜单按预设值（900 / 3600 / 7200）做的勾选比较
        // 就永远不相等 —— 用户改完「同时防止显示器休眠」回到菜单，会看到四个预设
        // 一个勾都没有，像是设置把防休眠关掉了。
        let saved = requestedDuration
        if let until {
            start(duration: max(1, until.timeIntervalSinceNow))
        } else {
            start(duration: nil)
        }
        requestedDuration = saved
    }

    // MARK: - 展示辅助

    /// 剩余分钟数（向上取整）；无限期或未激活返回 nil。
    var remainingMinutes: Int? {
        guard isActive, let until else { return nil }
        let seconds = max(0, until.timeIntervalSinceNow)
        return Int(ceil(seconds / 60))
    }
}
