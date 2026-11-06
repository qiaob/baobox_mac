import CoreAudio
import Foundation

/// 谁在用麦克风（会议检测用，docs/meeting/TECH_DESIGN.md §5）。
///
/// 按进程查：macOS 14 的 CoreAudio 进程对象（`kAudioHardwarePropertyProcessObjectList` +
/// `kAudioProcessPropertyIsRunningInput`），任何输入设备都算，不只默认麦克风。进程按可执行文件路径归到它所在的
/// 最外层 .app（钉钉开会的 Tblive 在 DingTalk.app 里）。系统目录里的进程（WebKit 的 GPU 进程替网页录音）说不清是谁的，
/// 记为 `unattributed`。系统不支持按进程查时退回「默认输入设备在被用」，同样只知道在用、不知道是谁。
struct MeetingMicrophoneUsage: Equatable {
    /// 在录音的 App（bundle id），不含 Baobox 自己。
    var apps: Set<String> = []
    /// 有进程在录音但说不清是谁。
    var unattributed = false
}

enum MeetingMicrophoneProbe {
    /// 读一次。会调 CoreAudio HAL，**不要在主线程调**（coreaudiod 忙时属性读取会卡住）。
    nonisolated static func sample() -> MeetingMicrophoneUsage {
        guard let objects = processObjects() else {
            return MeetingMicrophoneUsage(apps: [], unattributed: NotifyDND.defaultInputIsRunning())
        }
        let ownPID = getpid()
        var usage = MeetingMicrophoneUsage()
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
        return usage
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
