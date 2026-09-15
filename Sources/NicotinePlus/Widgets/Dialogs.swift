// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// A message dialog with custom buttons, presented as a sheet on the main window.
///
/// Buttons are identified by response IDs. The callback is not called for the
/// "cancel" response.
@MainActor
class MessageDialog {

    struct Button {
        let response: String
        let label: String

        init(_ response: String, _ label: String) {
            self.response = response
            self.label = label
        }
    }

    let alert = NSAlert()
    let container = NSStackView()

    private let buttons: [Button]
    private let callback: (@MainActor (MessageDialog, String) -> Void)?

    private static var activeDialogs: [MessageDialog] = []

    init(title: String, message: String, longMessage: String? = nil, buttons: [Button]? = nil,
         destructiveResponse: String? = nil, callback: (@MainActor (MessageDialog, String) -> Void)? = nil) {

        self.buttons = buttons ?? [Button("cancel", String(localized: "Close"))]
        self.callback = callback

        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational

        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 12

        // The first non-cancel button is the default button, cancel buttons come last
        let orderedButtons = self.buttons.filter { $0.response != "cancel" } + self.buttons.filter { $0.response == "cancel" }

        for button in orderedButtons {
            let alertButton = alert.addButton(withTitle: button.label)
            alertButton.tag = self.buttons.firstIndex { $0.response == button.response } ?? 0

            if button.response == destructiveResponse {
                alertButton.hasDestructiveAction = true
            }

            if button.response == "cancel" {
                alertButton.keyEquivalent = "\u{1b}"
            }
        }

        if let longMessage, !longMessage.isEmpty {
            addLongMessage(longMessage)
        }
    }

    private func addLongMessage(_ text: String) {
        let textView = TextView(isEditable: false)
        textView.appendLine(text)

        let scrollView = textView.scrollView
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: 380),
            scrollView.heightAnchor.constraint(equalToConstant: 140)
        ])

        container.addArrangedSubview(scrollView)
    }

    private func finishContainer() {
        guard !container.arrangedSubviews.isEmpty else {
            return
        }

        container.layoutSubtreeIfNeeded()
        container.frame = NSRect(origin: .zero, size: container.fittingSize)
        alert.accessoryView = container
    }

    func present() {
        finishContainer()
        Self.activeDialogs.append(self)

        let completion: (NSApplication.ModalResponse) -> Void = { [self] response in
            MainActor.assumeIsolated {
                onResponse(response)
            }
        }

        if let window = MainWindow.shared?.window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: completion)
            alert.window.initialFirstResponder = initialFirstResponder
            return
        }

        // Main window is hidden, show dialog after the current event is processed
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                alert.window.initialFirstResponder = initialFirstResponder
                completion(alert.runModal())
            }
        }
    }

    var initialFirstResponder: NSView? { nil }

    func close() {
        if let sheetParent = alert.window.sheetParent {
            sheetParent.endSheet(alert.window, returnCode: .cancel)
        } else if NSApp.modalWindow === alert.window {
            NSApp.abortModal()
        }
    }

    private func onResponse(_ response: NSApplication.ModalResponse) {
        Self.activeDialogs.removeAll { $0 === self }

        let buttonIndex = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue

        guard buttonIndex >= 0, buttonIndex < alert.buttons.count else {
            return
        }

        let responseID = buttons[alert.buttons[buttonIndex].tag].response

        if responseID != "cancel" {
            callback?(self, responseID)
        }
    }

    static func closeAll() {
        for dialog in activeDialogs.reversed() {
            dialog.close()
        }
    }
}

// MARK: - Option Dialog

/// A message dialog with an optional checkbox.
@MainActor
class OptionDialog: MessageDialog {

    private var toggle: NSButton?

    init(title: String, message: String, longMessage: String? = nil, buttons: [Button]? = nil,
         destructiveResponse: String? = nil, optionLabel: String? = nil, optionValue: Bool = false,
         callback: (@MainActor (MessageDialog, String) -> Void)? = nil) {

        let buttons = buttons ?? [
            Button("cancel", String(localized: "No")),
            Button("ok", String(localized: "Yes"))
        ]

        super.init(title: title, message: message, longMessage: longMessage, buttons: buttons,
                   destructiveResponse: destructiveResponse, callback: callback)

        if let optionLabel, !optionLabel.isEmpty {
            let toggle = NSButton(checkboxWithTitle: optionLabel, target: nil, action: nil)
            toggle.state = optionValue ? .on : .off
            container.addArrangedSubview(toggle)
            self.toggle = toggle
        }
    }

    var optionValue: Bool? {
        toggle.map { $0.state == .on }
    }
}

// MARK: - Entry Dialog

/// A dialog with one or two text entries, optionally with a list of suggestions.
@MainActor
final class EntryDialog: OptionDialog {

    private var entry: NSTextField?
    private var secondEntry: NSView?

    init(title: String, message: String, defaultText: String = "", useSecondEntry: Bool = false,
         secondEntryEditable: Bool = true, secondDefault: String = "", actionButtonLabel: String? = nil,
         droplist: [String]? = nil, secondDroplist: [String]? = nil, isVisible: Bool = true,
         optionLabel: String? = nil, optionValue: Bool = false,
         callback: (@MainActor (MessageDialog, String) -> Void)? = nil) {

        super.init(title: title, message: message, buttons: [
            Button("cancel", String(localized: "Cancel")),
            Button("ok", actionButtonLabel ?? String(localized: "OK"))
        ], optionLabel: optionLabel, optionValue: optionValue, callback: callback)

        let entry = Self.makeEntry(defaultText, droplist: droplist, isVisible: isVisible)
        container.insertArrangedSubview(entry, at: 0)
        self.entry = entry

        if useSecondEntry {
            let secondEntry: NSView

            if secondEntryEditable {
                secondEntry = Self.makeEntry(secondDefault, droplist: secondDroplist, isVisible: isVisible)
            } else {
                let popUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
                popUpButton.addItems(withTitles: secondDroplist ?? [])
                popUpButton.selectItem(withTitle: secondDefault)
                secondEntry = popUpButton
            }

            container.insertArrangedSubview(secondEntry, at: 1)
            self.secondEntry = secondEntry
        }
    }

    private static func makeEntry(_ text: String, droplist: [String]?, isVisible: Bool) -> NSTextField {
        let entry: NSTextField

        if let droplist, !droplist.isEmpty {
            let comboBox = NSComboBox()
            comboBox.addItems(withObjectValues: droplist)
            comboBox.completes = true
            entry = comboBox
        } else if !isVisible {
            entry = NSSecureTextField()
        } else {
            entry = NSTextField()
        }

        entry.stringValue = text
        entry.translatesAutoresizingMaskIntoConstraints = false
        entry.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return entry
    }

    override var initialFirstResponder: NSView? { entry }

    var entryValue: String {
        entry?.stringValue ?? ""
    }

    var secondEntryValue: String? {
        switch secondEntry {
        case let textField as NSTextField: textField.stringValue
        case let popUpButton as NSPopUpButton: popUpButton.titleOfSelectedItem
        default: nil
        }
    }
}
