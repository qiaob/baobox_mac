import AppKit
import CoreAudio

/// 谁在用麦克风（会议检测用，docs/meeting/TECH_DESIGN.md §5）。
///
/// 按进程查：macOS 14 的 CoreAudio 进程对象（`kAudioHardwarePropertyProcessObjectList` +
/// `kAudioProcessPropertyIsRunningInput`），任何输入设备都算，不只默认麦克风。进程按可执行文件路径归到它所在的
/// 最外层 .app（钉钉开会的 Tblive 在 DingTalk.app 里）。系统目录里的进程（WebKit 的 GPU 进程替网页录音）说不清是谁的，
/// 记为 `unattributed`。系统不支持按进程查时退回「默认输入设备在被用」，同样只知道在用、不知道是谁。
///
/// 在录音的是浏览器（说不清是谁时看前台是不是浏览器 —— Safari 由 WebKit 的 GPU 进程录音）就再读它的窗口标题，
/// 认会议网站（`MeetingWebSites`）。标题优先从 WindowServer 读（要屏幕录制权限，截图已经要了），读不到再用辅助功能。
struct MeetingMicrophoneUsage: Equatable {
    /// 在录音的 App（bundle id），不含 Baobox 自己。
    var apps: Set<String> = []
    /// 有进程在录音但说不清是谁。
    var unattributed = false
    /// 在录音的浏览器这次从窗口标题认出来的会议网站（`MeetingWebSites` 的 key），按浏览器分；`MeetingWebLatch` 据此记住。
    var sitesByBrowser: [String: Set<String>] = [:]
    /// 在录音的浏览器各读到几个窗口标题（诊断用：0 = 标题读不到，屏幕录制 / 辅助功能权限有问题）。
    var browserTitleCounts: [String: Int] = [:]
}

enum MeetingMicrophoneProbe {
    /// 读一次。会调 CoreAudio HAL，**不要在主线程调**（coreaudiod 忙时属性读取会卡住）。
    /// `frontmost`：前台 App 的 bundle id（主线程取好传进来）—— 说不清是谁在录音时，看它是不是浏览器。
    nonisolated static func sample(frontmost: String?) -> MeetingMicrophoneUsage {
        var usage = MeetingMicrophoneUsage()
        if let objects = processObjects() {
            let ownPID = getpid()
            for object in objects where isRunningInput(object) {
                guard let pid = processID(of: object), pid != ownPID else { continue }
                if let path = executablePath(of: pid),
                   let host = MeetingDetectionApps.hostAppPath(forExecutable: path),
                   let bundleID = Bundle(path: host)?.bundleIdentifier {
                    usage.apps.insert(bundleID)
                } else {
                    usage.unattributed = true
                }
            }
        } else {
            usage.unattributed = NotifyDND.defaultInputIsRunning()
        }
        var browsers = usage.apps.intersection(MeetingWebSites.browsers)
        if usage.unattributed, let frontmost, MeetingWebSites.browsers.contains(frontmost) {
            browsers.insert(frontmost)
        }
        for browser in browsers {
            let titles = windowTitles(ofBundleID: browser)
            usage.browserTitleCounts[browser] = titles.count
            let sites = MeetingWebSites.sites(inTitles: titles)
            if !sites.isEmpty { usage.sitesByBrowser[browser] = sites }
        }
        return usage
    }

    /// 某个 App 的窗口标题（浏览器 = 各窗口当前标签页的标题）。
    private nonisolated static func windowTitles(ofBundleID bundleID: String) -> [String] {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        guard !pids.isEmpty else { return [] }
        var titles: [String] = []
        var sawWindow = false
        if let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for info in list {
                guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                      (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
                sawWindow = true
                if let name = info[kCGWindowName as String] as? String, !name.isEmpty {
                    titles.append(name)
                }
            }
        }
        // 没有屏幕录制权限时 WindowServer 不给别人窗口的标题：改用辅助功能读。
        if titles.isEmpty, sawWindow {
            titles = accessibilityWindowTitles(pids)
        }
        return titles
    }

    private nonisolated static func accessibilityWindowTitles(_ pids: Set<pid_t>) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        var titles: [String] = []
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            // 浏览器卡住时别把检测也拖住。
            AXUIElementSetMessagingTimeout(app, 0.5)
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let windows = windowsValue as? [AXUIElement] else { continue }
            for window in windows {
                var titleValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                   let title = titleValue as? String, !title.isEmpty {
                    titles.append(title)
                }
            }
        }
        return titles
    }

    private nonisolated static func processObjects() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var objects = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return nil }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private nonisolated static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    private nonisolated static func processID(of object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr, pid > 0 else { return nil }
        return pid
    }

    private nonisolated static func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// 麦克风开始 / 停止被用就马上叫一声（docs/meeting/TECH_DESIGN.md §10）。借鉴 Notion：在默认输入设备上挂
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` 的监听（任何进程开始 / 停止用它都会变），一被占用就去查是谁，
/// 不等下一次定时采样；默认输入设备换了跟着换。只盯默认设备 —— 用别的输入设备开会的，靠定时采样兜底。
/// HAL 调用都在自己的串行队列上（coreaudiod 忙时属性读写会卡住，别卡主线程），回调也在这个队列上，由调用方转回主线程。
final class MeetingMicListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.baobox.meeting.mic-listener")
    private let onChange: @Sendable () -> Void
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.async { self.install() }
    }

    func stop() {
        queue.async { self.uninstall() }
    }

    private func install() {
        guard defaultDeviceListener == nil else { return }
        var address = Self.defaultInputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebind()
            self?.onChange()
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr {
            defaultDeviceListener = listener
        }
        rebind()
    }

    /// 换到当前的默认输入设备上盯。
    private func rebind() {
        let current = Self.defaultInputDevice()
        guard current != device else { return }
        removeDeviceListener()
        guard current != AudioObjectID(kAudioObjectUnknown) else { return }
        var address = Self.runningAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange() }
        if AudioObjectAddPropertyListenerBlock(current, &address, queue, listener) == noErr {
            device = current
            deviceListener = listener
        }
    }

    private func removeDeviceListener() {
        if device != AudioObjectID(kAudioObjectUnknown), let deviceListener {
            var address = Self.runningAddress
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, deviceListener)
        }
        device = AudioObjectID(kAudioObjectUnknown)
        deviceListener = nil
    }

    private func uninstall() {
        removeDeviceListener()
        if let defaultDeviceListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue,
                                                   defaultDeviceListener)
        }
        defaultDeviceListener = nil
    }

    private static var runningAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultInputDevice() -> AudioObjectID {
        var address = defaultInputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return AudioObjectID(kAudioObjectUnknown) }
        return device
    }
}
