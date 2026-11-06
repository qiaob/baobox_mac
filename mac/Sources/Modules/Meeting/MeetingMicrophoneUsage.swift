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
    /// 在录音的浏览器开着的会议网站（`MeetingWebSites` 的 key）。
    var webMeetings: Set<String> = []
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
            usage.webMeetings.formUnion(MeetingWebSites.sites(inTitles: windowTitles(ofBundleID: browser)))
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
