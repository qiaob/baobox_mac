import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let registry = ToolRegistry()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        registry.register(ScreenshotTool())
        registry.register(ClipboardTool())
        registry.register(ColorPickerTool())
        registry.register(QRCodeTool())
        registry.register(CaffeinateTool())
        registry.register(WindowManagerTool())
        registry.register(ClaudeCodeTool())
        registry.register(AIToolsTool())
        registry.register(KeyboardNavTool())
        // 0.0.2 暂不发布抓包工具（NetCapture 尚在完善）：模块代码保留在仓库，仅此版本不注册/不激活，
        // 后续完善后取消下一行注释即可恢复。
        // registry.register(NetCaptureTool())
        registry.activateAll()

        statusItemController = StatusItemController(registry: registry)
        // 全局热键触发前先收起状态栏菜单：修复「菜单打开时按快捷键，动作被推迟/与菜单并存」。
        HotkeyCenter.shared.onWillFireAction = { [weak self] in
            self?.statusItemController?.dismissMenu()
        }
        // 菜单打开期（经 CGEventTap）触发时，收起菜单**之前**先抓「含菜单整屏」快照，供截图冻结模式用
        // ——这样菜单打开时按截图快捷键，能截到菜单本身。
        HotkeyCenter.shared.onBeforeFire = {
            ScreenMenuSnapshot.captureAllScreens()
        }

        OnboardingController.shared.showIfNeeded()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// 退出前让各模块收尾：刷新未落盘数据、释放电源管理断言等。
    /// 框架不认识具体工具，统一走 `ToolModule.willTerminate()`。
    func applicationWillTerminate(_ notification: Notification) {
        for tool in registry.tools {
            tool.willTerminate()
        }
    }

    /// 构建最小主菜单。
    ///
    /// LSUIElement 应用默认没有主菜单，而 ⌘X/⌘C/⌘V/⌘A/⌘Z 这些标准编辑命令依赖主菜单
    /// Edit 项的 key equivalent —— 不建的话，设置页的文件名模板输入框、剪贴板面板的搜索框
    /// 都无法复制粘贴。菜单本身在 LSUIElement 下不可见，只作为 key equivalent 的挂载点。
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("app.menu.quit"),
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L("app.editMenu.title"))
        // undo:/redo: 由 NSUndoManager 在响应者链上提供，Swift 侧没有可见声明，
        // 只能用字符串 selector；其余四项限定到 NSText 以消除与 NSObject.copy() 的歧义。
        editMenu.addItem(withTitle: L("app.editMenu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("app.editMenu.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("app.editMenu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("app.editMenu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("app.editMenu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("app.editMenu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
