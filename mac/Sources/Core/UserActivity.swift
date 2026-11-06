import AppKit
import IOKit.pwr_mgt

/// 用户活动信号：键鼠空闲秒数、此刻是否正在操作、别的进程是否在阻止屏幕休眠（看视频 / 放幻灯片）。
/// 桌面宠物（长空闲睡觉）与专注与健康（在不在电脑前、自然休息）共用这一份。
enum UserActivity {
    /// 距最近一次键鼠输入的秒数（取多类事件的最小值，即最近的活动）。
    static func secondsSinceInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? 0
    }

    /// 正按着鼠标，或 1.5 秒内敲过键：休息画面等这一下结束再出来（拖拽到一半被盖住最恼人）。
    static func isBusyWithInput() -> Bool {
        if CGEventSource.buttonState(.hidSystemState, button: .left) { return true }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < 1.5
    }

    /// 别的进程持有「阻止屏幕休眠」断言：播放器播视频、浏览器放网课、演示软件放映都会这样。
    /// 此时键鼠长时间不动也算人在电脑前（不是离开）。跨进程问 powerd，调用方自己控制频率。
    static func otherProcessPreventsDisplaySleep() -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dict = unmanaged?.takeRetainedValue() as NSDictionary? else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let typeKey = kIOPMAssertionTypeKey as String
        let wanted = kIOPMAssertionTypePreventUserIdleDisplaySleep as String
        for (key, value) in dict {
            // 自己的（防休眠模块的断言）不算：那是用户让 Mac 别睡，不代表人在看屏幕。
            guard let pid = (key as? NSNumber)?.int32Value, pid != me,
                  let assertions = value as? [NSDictionary] else { continue }
            for assertion in assertions {
                guard let type = assertion[typeKey] as? String else { continue }
                // 旧名 NoDisplaySleepAssertion 仍有老 App 在用。
                if type == wanted || type == "NoDisplaySleepAssertion" { return true }
            }
        }
        return false
    }
}
