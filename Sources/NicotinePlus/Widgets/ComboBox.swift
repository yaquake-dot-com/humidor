// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Text entry with a drop-down list of items and completion, backed by `NSComboBox`.
struct ComboBox: NSViewRepresentable {

    let placeholder: String
    @Binding var text: String
    var items: [String] = []
    var tooltip: String?
    /// Changes of this value move keyboard focus to the entry
    var focusRequest = 0
    var isError = false
    /// Called when Return is pressed
    var onSubmit: (@MainActor () -> Void)?
    /// Called when an item is chosen from the drop-down list
    var onSelectItem: (@MainActor () -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.completes = true
        comboBox.usesDataSource = false
        comboBox.numberOfVisibleItems = 15
        comboBox.delegate = context.coordinator
        comboBox.target = context.coordinator
        comboBox.action = #selector(Coordinator.onAction(_:))
        comboBox.lineBreakMode = .byTruncatingTail
        comboBox.cell?.isScrollable = true
        comboBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        comboBox.placeholderString = placeholder
        comboBox.toolTip = tooltip

        let visibleItems = items.filter { !$0.isEmpty }

        if coordinator.items != visibleItems {
            coordinator.items = visibleItems
            comboBox.removeAllItems()
            comboBox.addItems(withObjectValues: visibleItems)
        }

        // Typed text is synced to the binding right away, so only external changes are applied here
        if comboBox.stringValue != text {
            comboBox.stringValue = text
        }

        comboBox.textColor = isError ? .systemRed : .controlTextColor

        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest

            DispatchQueue.main.async {
                comboBox.window?.makeFirstResponder(comboBox)

                // Place cursor at the end without selecting the text
                if let editor = comboBox.currentEditor() {
                    editor.selectedRange = NSRange(location: (comboBox.stringValue as NSString).length, length: 0)
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ComboBox
        var items: [String] = []
        var focusRequest: Int

        init(_ parent: ComboBox) {
            self.parent = parent
            self.focusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else {
                return
            }
            parent.text = comboBox.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox,
                  comboBox.indexOfSelectedItem >= 0, comboBox.indexOfSelectedItem < items.count else {
                return
            }

            let item = items[comboBox.indexOfSelectedItem]
            comboBox.stringValue = item
            parent.text = item

            // Only react to items chosen from the drop-down list, not completions
            guard NSApp.currentEvent?.type != .keyDown || comboBox.currentEditor() == nil else {
                return
            }

            DispatchQueue.main.async { [parent] in
                parent.onSelectItem?()
            }
        }

        @objc func onAction(_ sender: NSComboBox) {
            parent.text = sender.stringValue

            if NSApp.currentEvent?.type == .keyDown {
                parent.onSubmit?()
            }
        }
    }
}
