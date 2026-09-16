// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Entry for searching something, shown in the middle of an empty page and in
/// the toolbar of a page with content.
struct SearchField: NSViewRepresentable {

    let placeholder: String
    @Binding var text: String
    /// Title of the menu listing previous entries
    var recentTitle = String(localized: "Recent Searches")
    /// Previous entries, listed in the menu of the entry
    var recentItems: [String] = []
    /// Entries completed while typing
    var completions: [String] = []
    var tooltip: String?
    /// Changes of this value move keyboard focus to the entry
    var focusRequest = 0
    /// Called when Return is pressed, or an item is chosen from the menu
    var onSubmit: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()

        searchField.delegate = context.coordinator
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.onAction(_:))
        searchField.sendsWholeSearchString = true
        searchField.sendsSearchStringImmediately = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        searchField.placeholderString = placeholder
        searchField.toolTip = tooltip

        if searchField.stringValue != text {
            searchField.stringValue = text
        }

        let items = recentItems.filter { !$0.isEmpty }

        if coordinator.recentItems != items {
            coordinator.recentItems = items
            searchField.searchMenuTemplate = items.isEmpty ? nil : Self.menuTemplate(title: recentTitle)
            searchField.recentSearches = items
        }

        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest

            DispatchQueue.main.async {
                searchField.window?.makeFirstResponder(searchField)
            }
        }
    }

    /// Menu listing previous entries, filled in by the search field
    private static func menuTemplate(title: String) -> NSMenu {
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        titleItem.tag = Int(NSSearchField.recentsTitleMenuItemTag)
        menu.addItem(titleItem)

        let recentsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        recentsItem.tag = Int(NSSearchField.recentsMenuItemTag)
        menu.addItem(recentsItem)

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: String(localized: "Clear"), action: nil, keyEquivalent: "")
        clearItem.tag = Int(NSSearchField.clearRecentsMenuItemTag)
        menu.addItem(clearItem)

        return menu
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {

        var parent: SearchField
        var recentItems: [String] = []
        var focusRequest: Int
        private var isCompleting = false

        init(_ parent: SearchField) {
            self.parent = parent
            self.focusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else {
                return
            }

            parent.text = searchField.stringValue

            guard !isCompleting, !searchField.stringValue.isEmpty,
                  let editor = searchField.currentEditor() as? NSTextView else {
                return
            }

            isCompleting = true
            editor.complete(nil)
            isCompleting = false
        }

        func control(_ control: NSControl, textView: NSTextView, completions words: [String],
                     forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>)
            -> [String] {
            let query = (textView.string as NSString).substring(with: charRange)

            guard !query.isEmpty else {
                return []
            }

            return parent.completions.filter { $0 != query && $0.localizedCaseInsensitiveContains(query) }
        }

        @objc func onAction(_ sender: NSSearchField) {
            parent.text = sender.stringValue

            guard !sender.stringValue.isEmpty else {
                return
            }

            parent.onSubmit()
        }
    }
}
