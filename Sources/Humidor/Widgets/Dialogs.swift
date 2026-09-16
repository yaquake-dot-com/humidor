// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Presentations

/// Dialogs and file panels requested by the application. The active window shows them as sheets
/// and file dialogs, see `presentationHost(_:)`.
@MainActor
@Observable
final class Presentations {

    static let shared = Presentations()

    private(set) var dialogs: [MessageDialog] = []
    private(set) var fileRequest: FileRequest?

    /// Window that shows what is requested now
    @ObservationIgnored fileprivate var activeHost: String?
    @ObservationIgnored fileprivate var visibleHosts = Set<String>()

    private func host() -> String {
        let mainHost = AppWindow.main.rawValue
        let mainWindow = AppDelegate.shared.window!

        if let activeHost, visibleHosts.contains(activeHost), activeHost != mainHost || mainWindow.isVisible {
            return activeHost
        }

        // No window is active, show the request in the main window
        mainWindow.present()
        return mainHost
    }

    func present(_ dialog: MessageDialog) {
        dialog.host = host()
        dialogs.append(dialog)
    }

    func dismiss(_ dialog: MessageDialog) {
        dialogs.removeAll { $0 === dialog }
    }

    func present(_ request: FileRequest) {
        request.host = host()
        fileRequest = request
    }

    fileprivate func finishFileRequest(_ request: FileRequest, urls: [URL]?) {
        guard fileRequest === request else {
            return
        }

        fileRequest = nil

        if let urls {
            request.callback(urls.map(\.path))
        }
    }

    fileprivate func dialog(for host: String) -> MessageDialog? {
        dialogs.first { $0.host == host }
    }
}

extension View {
    /// Shows the dialogs and file panels requested while this window is active
    func presentationHost(_ id: String) -> some View {
        modifier(PresentationHost(id: id))
    }
}

private struct PresentationHost: ViewModifier {

    let id: String

    @Environment(\.appearsActive) private var appearsActive
    private var presentations = Presentations.shared

    init(id: String) {
        self.id = id
    }

    private var currentDialog: MessageDialog? {
        presentations.dialog(for: id)
    }

    /// Dialogs are system alerts, unless they contain a list to choose from, which alerts can't show
    private func alertDialog(hasOption: Bool) -> MessageDialog? {
        currentDialog.flatMap { !$0.needsSheet && ($0.optionLabel != nil) == hasOption ? $0 : nil }
    }

    private var sheetDialog: Binding<MessageDialog?> {
        Binding(
            get: { currentDialog.flatMap { $0.needsSheet ? $0 : nil } },
            set: { dialog in
                // Closed without choosing a button
                if dialog == nil, let currentDialog {
                    presentations.dismiss(currentDialog)
                }
            }
        )
    }

    private func isAlertPresented(hasOption: Bool) -> Binding<Bool> {
        Binding(
            get: { alertDialog(hasOption: hasOption) != nil },
            set: { isPresented in
                if !isPresented, let dialog = alertDialog(hasOption: hasOption) {
                    presentations.dismiss(dialog)
                }
            }
        )
    }

    private var optionValue: Binding<Bool> {
        Binding(
            get: { alertDialog(hasOption: true)?.values.optionValue ?? false },
            set: { alertDialog(hasOption: true)?.values.optionValue = $0 }
        )
    }

    private func alert(_ view: some View, hasOption: Bool) -> some View {
        let dialog = alertDialog(hasOption: hasOption)

        return view
            .alert(dialog?.title ?? "", isPresented: isAlertPresented(hasOption: hasOption), presenting: dialog) { dialog in
                MessageDialogActions(dialog: dialog)
            } message: { dialog in
                Text(dialog.alertMessage)
            }
    }

    private var fileRequest: FileRequest? {
        presentations.fileRequest.flatMap { $0.host == id ? $0 : nil }
    }

    private var isFileImporterPresented: Binding<Bool> {
        Binding(
            get: { fileRequest != nil },
            set: { isPresented in
                if !isPresented, let fileRequest {
                    presentations.finishFileRequest(fileRequest, urls: nil)
                }
            }
        )
    }

    func body(content: Content) -> some View {
        alert(content, hasOption: false)
            .background {
                // Dialogs with a checkbox, shown in the alert as its suppression toggle
                alert(Color.clear, hasOption: true)
                    .dialogSuppressionToggle(Text(alertDialog(hasOption: true)?.optionLabel ?? ""),
                                             isSuppressed: optionValue)
            }
            .sheet(item: sheetDialog) { dialog in
                MessageDialogView(dialog: dialog)
            }
            .fileImporter(isPresented: isFileImporterPresented,
                          allowedContentTypes: fileRequest?.contentTypes ?? [.item],
                          allowsMultipleSelection: fileRequest?.selectMultiple ?? false) { result in
                if let fileRequest {
                    presentations.finishFileRequest(fileRequest, urls: try? result.get())
                }
            }
            .fileDialogMessage(Text(fileRequest?.title ?? ""))
            .fileDialogDefaultDirectory(fileRequest?.initialFolder)
            .fileDialogConfirmationLabel(Text(fileRequest?.confirmationLabel ?? String(localized: "Open")))
            .onChange(of: appearsActive, initial: true) {
                if appearsActive {
                    presentations.activeHost = id
                }
            }
            .onAppear {
                presentations.visibleHosts.insert(id)
            }
            .onDisappear {
                presentations.visibleHosts.remove(id)
            }
    }
}

// MARK: - File Request

/// A request to choose files or folders.
@MainActor
final class FileRequest {

    let title: String
    let initialFolder: URL?
    let contentTypes: [UTType]
    let selectMultiple: Bool
    let confirmationLabel: String?
    let callback: @MainActor ([String]) -> Void
    fileprivate var host: String?

    init(title: String, initialFolder: URL?, contentTypes: [UTType], selectMultiple: Bool,
         confirmationLabel: String? = nil, callback: @escaping @MainActor ([String]) -> Void) {
        self.title = title
        self.initialFolder = initialFolder
        self.contentTypes = contentTypes
        self.selectMultiple = selectMultiple
        self.confirmationLabel = confirmationLabel
        self.callback = callback
    }
}

// MARK: - Message Dialog

/// A message dialog with custom buttons, presented as a sheet on the active window.
///
/// Buttons are identified by response IDs. The callback is not called for the
/// "cancel" response.
@MainActor
class MessageDialog: Identifiable {

    struct Button {
        let response: String
        let label: String

        init(_ response: String, _ label: String) {
            self.response = response
            self.label = label
        }
    }

    /// A text entry, optionally with suggestions, or a list to choose from
    struct Entry {
        var suggestions: [String] = []
        var isSecure = false
        var isEditable = true
    }

    /// Values edited in the dialog
    @Observable
    final class Values {
        var optionValue = false
        var entryText = ""
        var secondEntryText = ""
    }

    let title: String
    let message: String
    let longMessage: String?
    let destructiveResponse: String?
    let values = Values()
    fileprivate(set) var optionLabel: String?
    fileprivate(set) var entry: Entry?
    fileprivate(set) var secondEntry: Entry?
    fileprivate var host: String?

    private let buttons: [Button]
    private let callback: (@MainActor (MessageDialog, String) -> Void)?

    init(title: String, message: String, longMessage: String? = nil, buttons: [Button]? = nil,
         destructiveResponse: String? = nil, callback: (@MainActor (MessageDialog, String) -> Void)? = nil) {

        self.title = title
        self.message = message
        self.longMessage = longMessage
        self.buttons = buttons ?? [Button("cancel", String(localized: "Close"))]
        self.destructiveResponse = destructiveResponse
        self.callback = callback
    }

    /// Whether the dialog contains a list to choose from, shown in a sheet instead of an alert
    var needsSheet: Bool {
        secondEntry?.isEditable == false
    }

    /// Message of an alert, followed by the long message
    var alertMessage: String {
        guard let longMessage, !longMessage.isEmpty else {
            return message
        }
        return message.isEmpty ? longMessage : "\(message)\n\n\(longMessage)"
    }

    /// Buttons of an alert: the default button first, cancel buttons last
    var alertButtons: [Button] {
        buttons.filter { $0.response != "cancel" } + buttons.filter { $0.response == "cancel" }
    }

    /// Buttons from left to right: cancel buttons first, then the others, the default button last
    var orderedButtons: [Button] {
        (buttons.filter { $0.response != "cancel" } + buttons.filter { $0.response == "cancel" }).reversed()
    }

    /// The first button that isn't a cancel button
    var defaultResponse: String? {
        buttons.first { $0.response != "cancel" }?.response
    }

    func present() {
        Presentations.shared.present(self)
    }

    func close() {
        Presentations.shared.dismiss(self)
    }

    func onResponse(_ response: String) {
        Presentations.shared.dismiss(self)

        if response != "cancel" {
            callback?(self, response)
        }
    }

    static func closeAll() {
        for dialog in Presentations.shared.dialogs.reversed() {
            dialog.close()
        }
    }
}

// MARK: - Option Dialog

/// A message dialog with an optional checkbox.
@MainActor
class OptionDialog: MessageDialog {

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
            self.optionLabel = optionLabel
            values.optionValue = optionValue
        }
    }

    var optionValue: Bool? {
        optionLabel == nil ? nil : values.optionValue
    }
}

// MARK: - Entry Dialog

/// A dialog with one or two text entries, optionally with a list of suggestions.
@MainActor
final class EntryDialog: OptionDialog {

    init(title: String, message: String, defaultText: String = "", useSecondEntry: Bool = false,
         secondEntryEditable: Bool = true, secondDefault: String = "", actionButtonLabel: String? = nil,
         droplist: [String]? = nil, secondDroplist: [String]? = nil, isVisible: Bool = true,
         optionLabel: String? = nil, optionValue: Bool = false,
         callback: (@MainActor (MessageDialog, String) -> Void)? = nil) {

        super.init(title: title, message: message, buttons: [
            Button("cancel", String(localized: "Cancel")),
            Button("ok", actionButtonLabel ?? String(localized: "OK"))
        ], optionLabel: optionLabel, optionValue: optionValue, callback: callback)

        entry = Entry(suggestions: droplist ?? [], isSecure: !isVisible && (droplist ?? []).isEmpty)
        values.entryText = defaultText

        if useSecondEntry {
            secondEntry = Entry(suggestions: secondDroplist ?? [],
                                isSecure: !isVisible && secondEntryEditable && (secondDroplist ?? []).isEmpty,
                                isEditable: secondEntryEditable)
            values.secondEntryText = secondDefault
        }
    }

    var entryValue: String {
        values.entryText
    }

    var secondEntryValue: String? {
        secondEntry == nil ? nil : values.secondEntryText
    }
}

// MARK: - Dialog View

private struct MessageDialogView: View {

    let dialog: MessageDialog
    @Bindable private var values: MessageDialog.Values
    @FocusState private var isEntryFocused: Bool

    init(dialog: MessageDialog) {
        self.dialog = dialog
        values = dialog.values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)

            Text(dialog.title)
                .font(.headline)

            if !dialog.message.isEmpty {
                Text(dialog.message)
            }

            if let longMessage = dialog.longMessage, !longMessage.isEmpty {
                ScrollView {
                    Text(longMessage)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: 140)
                .roundedFrame()
            }

            if let entry = dialog.entry {
                entryView(entry, text: $values.entryText)
                    .focused($isEntryFocused)
            }

            if let secondEntry = dialog.secondEntry {
                entryView(secondEntry, text: $values.secondEntryText)
            }

            if let optionLabel = dialog.optionLabel {
                Toggle(optionLabel, isOn: $values.optionValue)
            }

            HStack {
                Spacer()

                ForEach(dialog.orderedButtons, id: \.response) { button in
                    buttonView(button)
                }
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            isEntryFocused = true
        }
    }

    @ViewBuilder private func entryView(_ entry: MessageDialog.Entry, text: Binding<String>) -> some View {
        if !entry.isEditable {
            Picker("", selection: text) {
                ForEach(entry.suggestions, id: \.self) { item in
                    Text(item).tag(item)
                }
            }
            .labelsHidden()
        } else if entry.isSecure {
            SecureField("", text: text)
        } else {
            TextField("", text: text)
                .textInputSuggestions(entry.suggestions, id: \.self) { item in
                    Text(item)
                        .textInputCompletion(item)
                }
                .onSubmit {
                    if let response = dialog.defaultResponse {
                        dialog.onResponse(response)
                    }
                }
        }
    }

    @ViewBuilder private func buttonView(_ button: MessageDialog.Button) -> some View {
        let role: ButtonRole? = button.response == "cancel"
            ? .cancel
            : (button.response == dialog.destructiveResponse ? .destructive : nil)

        let view = SwiftUI.Button(button.label, role: role) {
            dialog.onResponse(button.response)
        }

        if button.response == "cancel" {
            view.keyboardShortcut(.cancelAction)
        } else if button.response == dialog.defaultResponse {
            view.keyboardShortcut(.defaultAction)
        } else {
            view
        }
    }
}

// MARK: - Alert Content

/// Text entries and buttons of a dialog shown as an alert.
private struct MessageDialogActions: View {

    let dialog: MessageDialog

    var body: some View {
        @Bindable var values = dialog.values

        if let entry = dialog.entry {
            entryField(entry, text: $values.entryText)
        }

        if let secondEntry = dialog.secondEntry {
            entryField(secondEntry, text: $values.secondEntryText)
        }

        buttons
    }

    private var buttons: some View {
        ForEach(dialog.alertButtons, id: \.response) { button in
            SwiftUI.Button(button.label, role: role(of: button)) {
                dialog.onResponse(button.response)
            }
        }
    }

    @ViewBuilder private func entryField(_ entry: MessageDialog.Entry, text: Binding<String>) -> some View {
        if entry.isSecure {
            SecureField("", text: text)
        } else {
            TextField("", text: text)
        }
    }

    private func role(of button: MessageDialog.Button) -> ButtonRole? {
        if button.response == "cancel" {
            return .cancel
        }
        return button.response == dialog.destructiveResponse ? .destructive : nil
    }
}
