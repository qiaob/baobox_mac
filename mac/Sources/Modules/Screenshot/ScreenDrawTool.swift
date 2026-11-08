import AppKit
import SwiftUI

/// 屏幕标注模块壳：菜单栏一级入口（2026-11-05 起从截图子菜单移出，见 docs/screen-draw/DESIGN.md）。
/// 代码仍放在 Screenshot 目录 —— 与截图共用同一套标注引擎（`Annotation` / 工具条）。
@MainActor
final class ScreenDrawTool: ToolModule {
    let id = "screendraw"
    let name = L("screendraw.name")
    let symbolName = "scribble.variable"

    func submenuItems() -> [NSMenuItem] {
        let title = ScreenDrawController.shared.isRunning ? L("screendraw.menu.stop") : L("screendraw.menu.begin")
        return [ClosureMenuItem(title: title, hotkeyID: Self.hotkeyID) { ScreenDrawController.shared.toggle() }]
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: Self.hotkeyID,
                title: L("screendraw.hotkey.title"),
                subtitle: L("screendraw.hotkey.subtitle"),
                // 出厂不绑定（易冲突组合的一贯做法），用户在快捷键页或本模块设置页自行设置。
                defaultCombo: nil,
                action: { ScreenDrawController.shared.toggle() },
                // 穿透态下宠物点得到：环形菜单开着时写「关闭画笔」。
                stateTitle: { ScreenDrawController.shared.isRunning ? L("screendraw.action.stop") : nil }
            )
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(ScreenDrawSettingsView())
    }

    func activate() {
        // 无常驻服务；快捷键由框架统一注册。
    }

    /// 沿用在截图模块时的 id：它是快捷键的持久化键，改了用户已设的键位会丢。
    static let hotkeyID = "screenshot.draw"
}
