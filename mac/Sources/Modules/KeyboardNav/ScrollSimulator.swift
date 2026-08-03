import CoreGraphics

/// 发滚轮事件。macOS 按**光标位置**路由滚轮 —— 进入滚动态时已把光标移到滚动区中心，
/// 这里只管发事件，不依赖目标 App 暴露任何 AX 滚动角色（Chrome 的网页滚动条就不暴露，
/// 这正是滚动模式存在的原因）。
enum ScrollSimulator {
    /// pixels > 0 向上（露出更早内容），< 0 向下 —— 与滚轮方向语义一致。
    static func scroll(pixels: Int32) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                                  wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }
}
