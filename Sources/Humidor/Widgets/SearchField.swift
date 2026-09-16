// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Entry for searching something, shown in the middle of an empty page and in
/// the toolbar of a page with content.
struct SearchField: View {

    let placeholder: String
    @Binding var text: String
    /// Title of the menu listing previous entries
    var recentTitle = String(localized: "Recent Searches")
    /// Previous entries, listed in the menu of the entry
    var recentItems: [String] = []
    /// Entries suggested while typing
    var completions: [String] = []
    var tooltip: String?
    /// Changes of this value move keyboard focus to the entry
    var focusRequest = 0
    /// Called when Return is pressed, or an item is chosen from the menu
    var onSubmit: @MainActor () -> Void

    @FocusState private var isFocused: Bool
    @State private var handledFocusRequest = 0

    private static let suggestionLimit = 20

    private var visibleRecentItems: [String] {
        recentItems.filter { !$0.isEmpty }
    }

    private var suggestions: [String] {
        guard !text.isEmpty else {
            return []
        }

        return Array(completions.filter { $0 != text && $0.localizedCaseInsensitiveContains(text) }
            .prefix(Self.suggestionLimit))
    }

    var body: some View {
        HStack(spacing: 4) {
            recentItemsMenu

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(submit)
                .textInputSuggestions(suggestions, id: \.self) { item in
                    Text(item)
                        .textInputCompletion(item)
                }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(String(localized: "Clear"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.fill.tertiary, in: .capsule)
        .help(tooltip ?? "")
        .onAppear { handleFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { _, request in handleFocusRequest(request) }
    }

    @ViewBuilder private var recentItemsMenu: some View {
        if visibleRecentItems.isEmpty {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
        } else {
            Menu {
                Section(recentTitle) {
                    ForEach(visibleRecentItems, id: \.self) { item in
                        Button(item) {
                            text = item
                            submit()
                        }
                    }
                }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(recentTitle)
        }
    }

    private func submit() {
        guard !text.isEmpty else {
            return
        }
        onSubmit()
    }

    private func handleFocusRequest(_ request: Int) {
        guard request != handledFocusRequest else {
            return
        }
        handledFocusRequest = request
        isFocused = true
    }
}
