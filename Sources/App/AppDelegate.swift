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
        registry.activateAll()

        statusItemController = StatusItemController(registry: registry)

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
