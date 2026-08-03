import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// 全局快捷键中心（Carbon RegisterEventHotKey）。
///
/// 关键约束：Carbon 的 C 事件回调不能捕获 Swift 上下文，因此回调里只取出 hotkey id，
/// 再经单例 `HotkeyCenter.shared` 转发到主线程执行对应 action。
final class HotkeyCenter: ObservableObject {
    static let shared = HotkeyCenter()

    /// 注册失败/冲突的定义 id 集合，供设置页标红。
    @Published private(set) var conflictedIDs: Set<String> = []

    private struct Registration {
        let def: HotkeyDefinition
        var hotKeyRef: EventHotKeyRef?
        var carbonID: UInt32
        /// nil = 未绑定键位（无默认且用户未设置）。
        var combo: KeyCombo?
    }

    private var registrations: [String: Registration] = [:]   // definition.id -> 注册信息
    private var idByCarbonID: [UInt32: String] = [:]          // carbonID -> definition.id
    private var nextCarbonID: UInt32 = 1
    private var handlerInstalled = false
    private var suspended = false
    private let signature: OSType = 0x544D484B // 'TMHK'

    /// 系统保留组合缓存，见 `systemReservedCombos()`。
    private lazy var systemReserved: Set<UInt64> = Self.systemReservedCombos()

    /// 触发任一热键 action 之前的回调（主线程执行）。用于在执行动作前收起可能正打开的状态栏菜单，
    /// 否则菜单会与动作弹出的窗口（如截图选区浮层）同时在场、抢占鼠标事件。由 AppDelegate 装配。
    var onWillFireAction: (@MainActor () -> Void)?

    /// 仅经 CGEventTap（状态栏菜单打开期）触发时，在收起菜单**之前**回调。用于截图先抓「含菜单整屏」
    /// 快照，实现「菜单打开时截图也能截到菜单」。由 AppDelegate 装配。
    var onBeforeFire: (@MainActor () -> Void)?

    private init() {}

    // MARK: - 事件处理器安装

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // C 函数指针：不捕获任何局部上下文，只引用全局单例与全局常量。
        let callback: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
            guard let eventRef else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(eventRef,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hkID)
            if status == noErr {
                let carbonID = hkID.id
                // Carbon 应用级事件回调本就在主线程执行，这里直接同步派发到 handle，不经任何队列/RunLoop。
                // 状态栏 NSMenu 打开时主 runloop 进入事件跟踪模式，DispatchQueue.main.async / RunLoop.perform
                // 入队的 block 在该模式不被服务、要等菜单关闭才执行 —— 表现为「菜单开着时按快捷键无反应，
                // 关掉菜单才触发」。同步执行则在回调栈内立即处理（含收起菜单 + 弹出截图浮层）。
                MainActor.assumeIsolated {
                    HotkeyCenter.shared.handle(carbonID: carbonID)
                }
            }
            return noErr
        }
        // 安装失败时所有热键都会「注册成功」却永远收不到回调，必须显式检查，
        // 否则是最难定位的一类静默失效。
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, nil)
        guard status == noErr else {
            NSLog("[HotkeyCenter] InstallEventHandler 失败(status=\(status))，全局快捷键将全部无响应")
            return
        }
        handlerInstalled = true
    }

    @MainActor
    private func handle(carbonID: UInt32) {
        guard let id = idByCarbonID[carbonID], let reg = registrations[id] else { return }
        // 先收起可能正打开的状态栏菜单，再执行动作，避免菜单与动作窗口并存、抢占事件。
        onWillFireAction?()
        reg.def.action()
    }

    // MARK: - 菜单跟踪期热键补捉（CGEventTap）
    //
    // 状态栏 NSMenu 打开时进入独立的事件跟踪循环、独占事件，Carbon 全局热键此时**收不到**
    // （表现为「菜单开着按快捷键无反应」）。这里在菜单打开期间临时启用一个 CGEventTap，在 HID
    // 层补捉键盘事件；命中已注册组合就收起菜单并触发对应动作。需辅助功能权限，无权限则静默不启用。

    private var menuEventTap: CFMachPort?
    private var menuTapSource: CFRunLoopSource?

    /// 状态栏菜单即将打开：启用补捉 tap（幂等）。
    func beginMenuTrackingCapture() {
        guard menuEventTap == nil else { return }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let callback: CGEventTapCallBack = { _, _, event, _ in
            if HotkeyCenter.shared.handleTapKeyDown(event) {
                return nil // 命中：吞掉该按键，避免再被菜单当作导航键处理
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: nil) else {
            return // 无辅助功能权限等 → 静默不启用，不影响其它功能
        }
        menuEventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        menuTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// 状态栏菜单已关闭：停用并释放 tap。
    func endMenuTrackingCapture() {
        if let tap = menuEventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = menuTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        menuEventTap = nil
        menuTapSource = nil
    }

    /// tap 回调：把 keyDown 转 keyCode + 修饰键，匹配已注册热键。命中则收起菜单 + 触发，返回是否命中。
    /// tap source 挂在主 run loop，回调在主线程执行。
    fileprivate func handleTapKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        var carbon: UInt32 = 0
        if flags.contains(.maskCommand) { carbon |= KeyCombo.cmd }
        if flags.contains(.maskShift) { carbon |= KeyCombo.shift }
        if flags.contains(.maskAlternate) { carbon |= KeyCombo.option }
        if flags.contains(.maskControl) { carbon |= KeyCombo.control }
        return MainActor.assumeIsolated {
            for (_, reg) in registrations {
                guard let combo = reg.combo,
                      combo.keyCode == keyCode, combo.carbonModifiers == carbon else { continue }
                onBeforeFire?()      // 收菜单前：截图先抓含菜单整屏快照
                onWillFireAction?()  // 收起菜单
                reg.def.action()
                return true
            }
            return false
        }
    }

    // MARK: - 注册 API

    func register(_ def: HotkeyDefinition) {
        installHandlerIfNeeded()
        guard let combo = effectiveCombo(for: def) else {
            // 未绑定：登记定义供设置页展示/后续绑定，不注册 Carbon 热键。
            let carbonID = nextCarbonID
            nextCarbonID += 1
            registrations[def.id] = Registration(def: def, hotKeyRef: nil, carbonID: carbonID, combo: nil)
            return
        }
        _ = performRegister(def: def, combo: combo)
    }

    @discardableResult
    func update(id: String, to combo: KeyCombo) -> Bool {
        // 用户可能刚在系统设置里改过键位，重新读一次系统保留表再判定。
        systemReserved = Self.systemReservedCombos()
        return reregister(id: id, to: combo, persist: true)
    }

    func resetToDefault(id: String) {
        guard let existing = registrations[id] else { return }
        guard let defaultCombo = existing.def.defaultCombo else {
            // 默认即"未绑定"：注销现有热键并清掉持久化。
            if let ref = existing.hotKeyRef {
                UnregisterEventHotKey(ref)
                idByCarbonID[existing.carbonID] = nil
            }
            registrations[id]?.hotKeyRef = nil
            registrations[id]?.combo = nil
            conflictedIDs.remove(id)
            removePersisted(for: id)
            return
        }
        // 必须先确认默认组合注册成功再清除持久化：否则注册失败回滚后，用户的自定义
        // 键位本次仍在生效，但持久化已被删掉，重启后会无声变回默认。
        if reregister(id: id, to: defaultCombo, persist: false) {
            removePersisted(for: id)
        }
    }

    // MARK: - 录制期间挂起

    /// 录制新键位前调用：临时注销全部热键。
    ///
    /// Carbon 热键由 HIToolbox 在常规按键分发**之前**派发，对注册方自己的窗口同样生效。
    /// 不挂起就会出现：在设置里按 ⇧⌘2 想录入，结果直接触发截图盖住设置窗，
    /// 录制框根本收不到 keyDown —— 凡是本 App 已占用的组合都无法录入。
    func suspendAll() {
        guard !suspended else { return }
        suspended = true
        for (id, reg) in registrations {
            guard let ref = reg.hotKeyRef else { continue }
            UnregisterEventHotKey(ref)
            idByCarbonID[reg.carbonID] = nil
            registrations[id]?.hotKeyRef = nil
        }
    }

    /// 录制结束后调用：按各自当前键位重新注册。
    func resumeAll() {
        guard suspended else { return }
        suspended = false
        for (id, reg) in registrations where reg.hotKeyRef == nil {
            guard let combo = reg.combo, !isSystemReserved(combo) else { continue }
            let carbonID = nextCarbonID
            nextCarbonID += 1
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: signature, id: carbonID)
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hkID,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registrations[id]?.hotKeyRef = ref
                registrations[id]?.carbonID = carbonID
                idByCarbonID[carbonID] = id
                conflictedIDs.remove(id)
            } else {
                conflictedIDs.insert(id)
            }
        }
    }

    // MARK: - 系统保留组合

    /// 组合的可比较键（keyCode 高 32 位 + 修饰键低 32 位）。
    private static func comboKey(keyCode: UInt32, carbonModifiers: UInt32) -> UInt64 {
        (UInt64(keyCode) << 32) | UInt64(carbonModifiers)
    }

    /// 被系统占用的组合（Spotlight ⌘Space、截屏、输入法切换等）。
    ///
    /// `RegisterEventHotKey` 对这类组合**仍然返回 noErr 并给出有效 ref**，但热键永远
    /// 收不到回调，仅靠返回值判断冲突会漏掉全部系统级冲突，必须单独比对。
    private static func systemReservedCombos() -> Set<UInt64> {
        var out: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&out) == noErr,
              let list = out?.takeRetainedValue() as? [[String: Any]] else { return [] }

        var result: Set<UInt64> = []
        for entry in list {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let mods = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value
            else { continue }
            result.insert(comboKey(keyCode: code, carbonModifiers: mods))
        }
        return result
    }

    private func isSystemReserved(_ combo: KeyCombo) -> Bool {
        systemReserved.contains(Self.comboKey(keyCode: combo.keyCode,
                                              carbonModifiers: combo.carbonModifiers))
    }

    func combo(for id: String) -> KeyCombo? {
        registrations[id]?.combo ?? nil
    }

    func effectiveCombo(for def: HotkeyDefinition) -> KeyCombo? {
        loadPersisted(for: def.id) ?? def.defaultCombo
    }

    // MARK: - 内部注册实现

    @discardableResult
    private func performRegister(def: HotkeyDefinition, combo: KeyCombo) -> Bool {
        let carbonID = nextCarbonID
        nextCarbonID += 1
        // 系统保留组合注册会「成功」却永不回调，需在此拦截才能给出冲突提示。
        if isSystemReserved(combo) {
            registrations[def.id] = Registration(def: def, hotKeyRef: nil, carbonID: carbonID, combo: combo)
            conflictedIDs.insert(def.id)
            return false
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: carbonID)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            registrations[def.id] = Registration(def: def, hotKeyRef: ref, carbonID: carbonID, combo: combo)
            idByCarbonID[carbonID] = def.id
            conflictedIDs.remove(def.id)
            return true
        } else {
            // 冲突/失败：保留定义信息以便设置页展示与后续更新，但不建立 carbonID 映射。
            registrations[def.id] = Registration(def: def, hotKeyRef: nil, carbonID: carbonID, combo: combo)
            conflictedIDs.insert(def.id)
            return false
        }
    }

    @discardableResult
    private func reregister(id: String, to combo: KeyCombo, persist: Bool) -> Bool {
        guard let existing = registrations[id] else { return false }
        // 系统保留组合直接拒绝，且不动原注册 —— 原键位继续可用。
        guard !isSystemReserved(combo) else { return false }
        // 注销旧的
        if let ref = existing.hotKeyRef {
            UnregisterEventHotKey(ref)
            idByCarbonID[existing.carbonID] = nil
        }
        // 注册新的
        let carbonID = nextCarbonID
        nextCarbonID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: carbonID)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            registrations[id] = Registration(def: existing.def, hotKeyRef: ref, carbonID: carbonID, combo: combo)
            idByCarbonID[carbonID] = id
            conflictedIDs.remove(id)
            if persist { self.persist(combo, for: id) }
            return true
        } else {
            // 回滚：重新注册旧组合（原本未绑定则保持未绑定）。
            let oldCarbonID = nextCarbonID
            nextCarbonID += 1
            guard let oldCombo = existing.combo else {
                registrations[id] = Registration(def: existing.def, hotKeyRef: nil, carbonID: oldCarbonID, combo: nil)
                return false
            }
            var oldRef: EventHotKeyRef?
            let oldHKID = EventHotKeyID(signature: signature, id: oldCarbonID)
            let st = RegisterEventHotKey(oldCombo.keyCode, oldCombo.carbonModifiers, oldHKID,
                                         GetApplicationEventTarget(), 0, &oldRef)
            if st == noErr, let oldRef {
                registrations[id] = Registration(def: existing.def, hotKeyRef: oldRef, carbonID: oldCarbonID, combo: oldCombo)
                idByCarbonID[oldCarbonID] = id
            } else {
                registrations[id] = Registration(def: existing.def, hotKeyRef: nil, carbonID: oldCarbonID, combo: oldCombo)
                conflictedIDs.insert(id)
            }
            return false
        }
    }

    // MARK: - 持久化

    private func persistKey(for id: String) -> String { "hotkey.\(id)" }

    private func persist(_ combo: KeyCombo, for id: String) {
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: persistKey(for: id))
        }
    }

    private func loadPersisted(for id: String) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: persistKey(for: id)) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    private func removePersisted(for id: String) {
        UserDefaults.standard.removeObject(forKey: persistKey(for: id))
    }
}
