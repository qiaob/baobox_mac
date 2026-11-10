import AppKit
import SwiftUI

// 划词助手浮层里的按钮（#95）：浮层为了不抢焦点永远不是当前窗口（`SelectionPanel.canBecomeKey == false`），
// 系统按「非当前窗口」画里面的 AppKit 控件：`.borderedProminent` 不上强调色、`Menu` 的标签和分段控件都变暗，
// 看起来像点不了。`.environment(\.controlActiveState, .key)` 改不了这些控件（试过）。
// 这里的样式背景和文字都由 SwiftUI 自己画，不看窗口状态。

/// 主按钮：强调色底、白字（「替换」「复制」「用云端试一次」）。
struct SelectionPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .contentShape(Rectangle())
    }
}

/// 次要按钮：淡灰底、正常字色（「复制」「重试」「AI 设置…」、刷新 / 朗读图标）。
struct SelectionSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 8)
            .frame(minWidth: 22, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .contentShape(Rectangle())
    }
}

/// 开关按钮（「慢速」）：开着是主按钮的样子，关着是次要按钮的样子。
struct SelectionToggleButtonStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: isOn ? .medium : .regular))
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1)
                               : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .contentShape(Rectangle())
    }
}

/// 菜单里的一项。
struct SelectionMenuItem {
    let title: String
    var checked = false
    let action: () -> Void
}

/// 点了弹出 NSMenu 的按钮：标签自己画（代替 SwiftUI `Menu`，后者在非当前窗口里变暗）。菜单出在按钮正下方。
struct SelectionMenuButton<Label: View>: View {
    let items: () -> [SelectionMenuItem]
    @ViewBuilder let label: () -> Label

    @State private var anchor = SelectionMenuAnchor()

    var body: some View {
        Button {
            anchor.popUp(items())
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .background(SelectionMenuAnchorView(anchor: anchor))
    }
}

/// 记住按钮底下那块 NSView，弹菜单时用它定位。
@MainActor
final class SelectionMenuAnchor {
    weak var view: NSView?

    /// 视图的 `@State` 初始值在非隔离上下文里建，构造器本身不碰任何状态。
    nonisolated init() {}

    func popUp(_ items: [SelectionMenuItem]) {
        guard let view, !items.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            let menuItem = ClosureMenuItem(title: item.title, handler: item.action)
            menuItem.state = item.checked ? .on : .off
            menu.addItem(menuItem)
        }
        // 视图坐标原点在左下：菜单左上角放在按钮左下角再往下一点。
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 2 : -2), in: view)
    }
}

private struct SelectionMenuAnchorView: NSViewRepresentable {
    let anchor: SelectionMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
