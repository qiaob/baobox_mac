import AppKit
import os

/// 把一个菜单栏图标挪到另一个图标的左边 / 右边 —— **图标在屏幕外也行**（docs/menubar-manager/TECH_DESIGN.md §8c）。
///
/// 在屏上发普通的合成事件只能挪看得见的图标；要碰隐藏区里的，第一版只能把占位项缩短、让一串图标一起回到屏上，
/// 用户看到「还是都出来了」（2026-11-08）。这里按 Ice 的思路（只看了原理，代码自己写）：
/// 1. 按下（带 ⌘）放在所有屏幕之外 (20000, 20000)，窗口字段指向要挪的图标；抬起放在目标图标的边上，窗口字段指向目标。
///    两个事件的目标进程都是要挪的图标所属的 App，不发拖动事件。
/// 2. 每个事件「转一手」：先给那个 App 发一个空事件；挂在那个 App 上的拦截（`tapCreateForPid`）收到空事件后把真事件
///    发进会话事件流；会话流上只听不改的拦截看到真事件后，再把它直接发给那个 App —— 系统和那个 App 都收到。
///    （单发会话流、单发给那个 App，2026-11-08 探针里都不起作用。）
/// 3. 每一步等图标的位置真的变了（最多约 80 毫秒），再等位置稳住（系统可能播放滑动动画）才核对；
///    没落到位就先「叫醒」它（在它中心按住 ⌘ 按一下）再重试，最多 5 次。
/// 全程隐藏鼠标指针，做完放回原处。需要辅助功能权限。
@MainActor
final class MenuBarItemMover {
    static let shared = MenuBarItemMover()
    private static let log = Logger(subsystem: "com.baobox.app", category: "menubar")
    /// 自定义的窗口号字段（Ice 用的 0x33）：AppKit 据它把事件派给那个窗口。
    private static let windowNumberField = CGEventField(rawValue: 0x33)

    enum Side {
        case leftOf
        case rightOf
    }

    struct Window {
        let pid: pid_t
        let windowID: CGWindowID
    }

    private init() {}

    /// 把 item 挪到 target 的左边 / 右边。挪完按位置核对：item 紧挨在目标那一侧（菜单栏图标窗口一个挨一个、没有空隙），返回 true。
    /// 只看「在那一侧」不够：本来就在远处那一侧的（隐藏区里的图标在 Baobox 左边几千像素）没挪也会算成功（2026-11-08）。
    func move(_ item: Window, _ side: Side, of target: Window) async -> Bool {
        guard let startFrame = Self.windowFrame(item.windowID) else {
            Self.log.notice("relay move: no frame for item window \(item.windowID) (pid \(item.pid))")
            return false
        }
        guard Self.windowFrame(target.windowID) != nil else {
            Self.log.notice("relay move: no frame for target window \(target.windowID)")
            return false
        }
        permitAllEvents()
        let savedCursor = CGEvent(source: nil)?.location
        _ = CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if let savedCursor {
                _ = CGWarpMouseCursorPosition(savedCursor)
                _ = CGAssociateMouseAndMouseCursorPosition(1)
            }
            _ = CGDisplayShowCursor(CGMainDisplayID())
        }

        for attempt in 1...5 {
            guard let targetFrame = Self.windowFrame(target.windowID) else {
                Self.log.notice("relay move: target window \(target.windowID) vanished")
                return false
            }
            let edgeX = side == .leftOf ? targetFrame.minX : targetFrame.maxX
            let down = Self.makeEvent(.leftMouseDown, at: CGPoint(x: 20_000, y: 20_000), pid: item.pid,
                                      windowID: item.windowID, command: true)
            let up = Self.makeEvent(.leftMouseUp, at: CGPoint(x: edgeX, y: targetFrame.midY), pid: item.pid,
                                    windowID: target.windowID, command: false)
            guard let down, let up else {
                Self.log.notice("relay move: could not create events")
                return false
            }

            // 按下后图标可能先动一下（被「拿起来」），也可能要等抬起才动：两步都等一下，最后只看落没落到位。
            let before = Self.windowFrame(item.windowID) ?? startFrame
            var ok = await relay(down, to: item.pid)
            if ok {
                _ = await waitForFrameChange(item.windowID, from: before)
                let afterDown = Self.windowFrame(item.windowID) ?? before
                ok = await relay(up, to: item.pid)
                if ok {
                    _ = await waitForFrameChange(item.windowID, from: afterDown)
                    await waitForSettle([item.windowID, target.windowID])
                }
            }
            if ok, let frame = Self.windowFrame(item.windowID), let targetNow = Self.windowFrame(target.windowID) {
                let landed = side == .leftOf ? abs(frame.maxX - targetNow.minX) <= 3 : abs(frame.minX - targetNow.maxX) <= 3
                if landed {
                    Self.log.notice("relay move ok after \(attempt) attempt(s): \(NSStringFromRect(startFrame), privacy: .public) → \(NSStringFromRect(frame), privacy: .public), target \(NSStringFromRect(targetNow), privacy: .public), cursor \(String(describing: savedCursor), privacy: .public)")
                    return true
                }
            }
            Self.log.notice("relay move attempt \(attempt) missed: relayed \(ok), item at \(NSStringFromRect(Self.windowFrame(item.windowID) ?? .zero), privacy: .public), target was \(NSStringFromRect(targetFrame), privacy: .public) now \(NSStringFromRect(Self.windowFrame(target.windowID) ?? .zero), privacy: .public), cursor \(String(describing: savedCursor), privacy: .public)")
            // 没挪成：补一个抬起结束可能挂着的拖动，再叫醒它（在它中心按住 ⌘ 按一下，不会打开它的菜单）。
            if let frame = Self.windowFrame(item.windowID) {
                let center = CGPoint(x: frame.midX, y: frame.midY)
                if let release = Self.makeEvent(.leftMouseUp, at: center, pid: item.pid, windowID: item.windowID, command: false) {
                    _ = await relay(release, to: item.pid)
                }
                if let wakeDown = Self.makeEvent(.leftMouseDown, at: center, pid: item.pid, windowID: item.windowID, command: true),
                   let wakeUp = Self.makeEvent(.leftMouseUp, at: center, pid: item.pid, windowID: item.windowID, command: false) {
                    _ = await relay(wakeDown, to: item.pid)
                    _ = await relay(wakeUp, to: item.pid)
                }
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        Self.log.notice("relay move failed after 5 attempts (window \(item.windowID))")
        return false
    }

    // MARK: - 事件

    private static var nextTag: Int64 = 0x0BA0_B0C5_0000

    private static func makeEvent(_ type: CGEventType, at point: CGPoint, pid: pid_t, windowID: CGWindowID,
                                  command: Bool) -> CGEvent? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: .left) else { return nil }
        nextTag += 1
        event.flags = command ? .maskCommand : []
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.setIntegerValueField(.eventSourceUserData, value: nextTag)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        if let field = windowNumberField {
            event.setIntegerValueField(field, value: Int64(windowID))
        }
        return event
    }

    /// 期间别让系统把我们的合成事件当成「远程拖动」压掉。
    private func permitAllEvents() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let permit: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source.setLocalEventsFilterDuringSuppressionState(permit, state: .eventSuppressionStateRemoteMouseDrag)
        source.setLocalEventsFilterDuringSuppressionState(permit, state: .eventSuppressionStateSuppressionInterval)
        source.localEventsSuppressionInterval = 0
    }

    // MARK: - 转一手

    /// 一次转发的上下文。C 回调不能捕获 Swift 上下文，经 userInfo 指针拿回来。
    private final class Relay {
        let pid: pid_t
        let real: CGEvent
        let nullTag: Int64
        var pidTap: CFMachPort?
        var sessionTap: CFMachPort?
        var nullSeen = false
        var realSeen = false
        var continuation: CheckedContinuation<Bool, Never>?

        init(pid: pid_t, real: CGEvent, nullTag: Int64) {
            self.pid = pid
            self.real = real
            self.nullTag = nullTag
        }

        func finish(_ ok: Bool) {
            if let pidTap { CGEvent.tapEnable(tap: pidTap, enable: false) }
            if let sessionTap { CGEvent.tapEnable(tap: sessionTap, enable: false) }
            continuation?.resume(returning: ok)
            continuation = nil
        }

        func matches(_ event: CGEvent) -> Bool {
            let fields: [CGEventField] = [.eventSourceUserData, .mouseEventWindowUnderMousePointer,
                                          .mouseEventWindowUnderMousePointerThatCanHandleThisEvent]
            return fields.allSatisfy { event.getIntegerValueField($0) == real.getIntegerValueField($0) }
        }
    }

    private func relay(_ event: CGEvent, to pid: pid_t) async -> Bool {
        guard let null = CGEvent(source: nil) else { return false }
        Self.nextTag += 1
        let nullTag = Self.nextTag
        null.setIntegerValueField(.eventSourceUserData, value: nullTag)
        let context = Relay(pid: pid, real: event, nullTag: nullTag)
        let pointer = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged<Relay>.fromOpaque(pointer).release() }

        // 拦截 1：挂在那个 App 上，只看空事件；收到我们的空事件就丢掉它，把真事件发进会话事件流。
        let pidCallback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let relay = Unmanaged<Relay>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = relay.pidTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard event.getIntegerValueField(.eventSourceUserData) == relay.nullTag else {
                return Unmanaged.passUnretained(event)
            }
            if let tap = relay.pidTap { CGEvent.tapEnable(tap: tap, enable: false) }
            relay.nullSeen = true
            relay.real.post(tap: .cgSessionEventTap)
            return nil
        }
        // 拦截 2：会话事件流上只听；看到真事件就再直接发给那个 App，然后收工。
        let sessionCallback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let relay = Unmanaged<Relay>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = relay.sessionTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard relay.matches(event) else { return Unmanaged.passUnretained(event) }
            relay.realSeen = true
            relay.real.postToPid(relay.pid)
            relay.finish(true)
            return Unmanaged.passUnretained(event)
        }

        guard let pidTap = CGEvent.tapCreateForPid(pid: pid, place: .tailAppendEventTap, options: .defaultTap,
                                                   eventsOfInterest: CGEventMask(1) << CGEventType.null.rawValue,
                                                   callback: pidCallback, userInfo: pointer),
              let sessionTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                                 eventsOfInterest: CGEventMask(1) << event.type.rawValue,
                                                 callback: sessionCallback, userInfo: pointer) else {
            Self.log.notice("relay: could not create event taps")
            return false
        }
        context.pidTap = pidTap
        context.sessionTap = sessionTap
        let pidSource = CFMachPortCreateRunLoopSource(nil, pidTap, 0)
        let sessionSource = CFMachPortCreateRunLoopSource(nil, sessionTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), pidSource, .commonModes)
        CFRunLoopAddSource(CFRunLoopGetMain(), sessionSource, .commonModes)
        defer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), pidSource, .commonModes)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), sessionSource, .commonModes)
            CFMachPortInvalidate(pidTap)
            CFMachPortInvalidate(sessionTap)
        }

        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            context.continuation = continuation
            CGEvent.tapEnable(tap: pidTap, enable: true)
            CGEvent.tapEnable(tap: sessionTap, enable: true)
            null.postToPid(pid)
            // 200 毫秒没转到就算失败（Ice 给 50 毫秒，这里放宽一点）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                context.finish(false)
            }
        }
        if !ok {
            Self.log.notice("relay type \(event.type.rawValue) to pid \(pid): null seen \(context.nullSeen), real seen \(context.realSeen)")
        }
        return ok
    }

    // MARK: - 位置

    /// 按窗口号取位置，屏外的窗口也要取得到（隐藏的图标都在屏外）。
    /// `CGWindowListCopyWindowInfo(.optionIncludingWindow, id)` 对屏外的窗口返回空（2026-11-08 自测：隐藏的 Tailscale 取不到）；
    /// `CGWindowListCreateDescriptionFromArray` 不管在不在屏上，数组里放的是窗口号本身（不是 CFNumber）。取不到再遍历全部窗口。
    static func windowFrame(_ id: CGWindowID) -> CGRect? {
        var value = UnsafeRawPointer(bitPattern: UInt(id))
        if let array = CFArrayCreate(nil, &value, 1, nil),
           let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]],
           let info = list.first, let bounds = info[kCGWindowBounds as String] as? NSDictionary,
           let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
            return frame
        }
        let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        for info in all {
            guard (info[kCGWindowNumber as String] as? Int).map({ CGWindowID($0) }) == id,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else { continue }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }
        return nil
    }

    /// 等这几个窗口的位置连续 3 次（约 45 毫秒）不变，最多 0.6 秒：滑动动画中途读到的位置不算数。
    private func waitForSettle(_ ids: [CGWindowID]) async {
        var last = ids.map { Self.windowFrame($0) }
        var stable = 0
        let started = Date()
        while stable < 3, Date().timeIntervalSince(started) < 0.6 {
            try? await Task.sleep(nanoseconds: 15_000_000)
            let now = ids.map { Self.windowFrame($0) }
            stable = now == last ? stable + 1 : 0
            last = now
        }
    }

    private func waitForFrameChange(_ id: CGWindowID, from start: CGRect) async -> Bool {
        let started = Date()
        while Date().timeIntervalSince(started) < 0.08 {
            if let now = Self.windowFrame(id), now != start { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}
