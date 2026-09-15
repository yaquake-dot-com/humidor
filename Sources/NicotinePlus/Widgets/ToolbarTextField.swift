// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Text entry for the toolbar, with suggestions matching the entered text.
struct ToolbarTextField: View {

    let placeholder: String
    @Binding var text: String
    var suggestions: [String] = []
    var tooltip: String?
    /// Changes of this value move keyboard focus to the entry
    var focusRequest = 0
    /// Called when Return is pressed
    var onSubmit: @MainActor () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .textInputSuggestions {
                ForEach(matchingSuggestions, id: \.self) { suggestion in
                    Text(suggestion)
                        .textInputCompletion(suggestion)
                }
            }
            .onSubmit(onSubmit)
            .help(tooltip ?? "")
            .onChange(of: focusRequest) {
                isFocused = true
            }
    }

    private var matchingSuggestions: [String] {
        let query = text.trimmingCharacters(in: .whitespaces)

        return suggestions.filter { suggestion in
            !suggestion.isEmpty && suggestion != text
                && (query.isEmpty || suggestion.localizedCaseInsensitiveContains(query))
        }
    }
}
