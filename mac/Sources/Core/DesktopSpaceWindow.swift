import AppKit

/// 建一个从全屏 App 里打开也**不会叠在全屏窗口上**的普通窗口（设置这类要拿焦点、会开很久的窗口）。
///
/// Baobox 是菜单栏 App（LSUIElement，`.accessory`）。这类 App 的普通窗口会被系统放进别的 App 的**全屏空间**当附属窗口：
/// 在全屏的终端里打开设置，设置窗口就叠在全屏窗口上，点回终端也一直盖着（全屏窗口在自己的空间里永远排最底下）。
///
/// 窗口进不进别的 App 的全屏空间，**按它建出来那一刻 App 的身份定**，之后不再变（2026-11-08 LSUIElement 探针实测）：
/// - `.regular` 时建的窗口，之后在 `.accessory` 下显示：系统切到桌面空间显示它，不进全屏空间；关掉再开同一个实例也一样。
/// - `.accessory` 时建的窗口，之后切成 `.regular` 再显示：照样叠进全屏空间。
/// - 窗口级开关改不了：设置窗口标 `.auxiliary` / `.primary` 照样叠进去；反过来 `.regular` 时建的遮罩
///   加 `.canJoinAllApplications`、或做成 `.nonactivatingPanel`，也进不了全屏空间。
///
/// 所以只在**建窗口那一下**临时切成 `.regular`，建完、显示之前就切回。App 不能停在 `.regular`：那期间建的截图遮罩、
/// 浮条、贴图都进不了全屏空间（设置开着时在全屏 App 上截图，遮罩跑到设置所在的桌面）；显示之后再切回 `.accessory`，
/// 系统又会把用户拽回原来的 App。
///
/// 窗口必须在 `build` 里**当场建出来**（`NSWindow(contentViewController:)` 就是；自己 init 的用 `defer: false`），
/// 用完关掉时复用同一个实例（`isReleasedWhenClosed = false`）。浮条、贴图、气泡这类**有意叠在全屏 App 上**的窗口不要用它。
@MainActor
enum DesktopSpaceWindow {
    static func make<W: NSWindow>(_ build: () -> W) -> W {
        let policy = NSApp.activationPolicy()
        guard policy != .regular else { return build() }
        NSApp.setActivationPolicy(.regular)
        let window = build()
        NSApp.setActivationPolicy(policy)
        return window
    }
}
