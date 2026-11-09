import AppKit
import SwiftUI

/// 模型名输入框（docs/ai-service/DESIGN.md §3.4）：NSComboBox —— 下拉选服务商的模型，也能直接输入列表里没有的；
/// 打字时按列表自动补全。
struct ModelComboBox: NSViewRepresentable {
    @Binding var text: String
    let items: [String]
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.usesDataSource = false
        box.completes = true
        box.numberOfVisibleItems = 14
        box.hasVerticalScroller = true
        box.placeholderString = placeholder
        box.addItems(withObjectValues: items)
        box.stringValue = text
        box.delegate = context.coordinator
        box.setContentHuggingPriority(.defaultLow, for: .horizontal)
        box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.text = $text
        if (box.objectValues as? [String]) != items {
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }
        // 正在输入时不回写，免得光标跳动。
        if box.currentEditor() == nil, box.stringValue != text {
            box.stringValue = text
        }
        box.placeholderString = placeholder
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        /// 从列表里选了一项：这时 `stringValue` 还没更新，取选中的那项。
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox, box.indexOfSelectedItem >= 0,
                  let value = box.objectValueOfSelectedItem as? String else { return }
            text.wrappedValue = value
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            text.wrappedValue = box.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            text.wrappedValue = box.stringValue
        }
    }
}
