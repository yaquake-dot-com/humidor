// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// SwiftUI text entry with an optional menu of known values.
struct ComboBox: View {

    let placeholder: String
    @Binding var text: String
    var items: [String] = []
    var tooltip: String?
    var focusRequest = 0
    var isError = false
    var onSubmit: (@MainActor () -> Void)?
    var onSelectItem: (@MainActor () -> Void)?

    @FocusState private var isFocused: Bool
    @State private var handledFocusRequest = 0

    private var visibleItems: [String] {
        var seen = Set<String>()
        return items.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .foregroundStyle(isError ? Color.red : Color.primary)
                .onSubmit { onSubmit?() }

            if !visibleItems.isEmpty {
                Menu {
                    ForEach(visibleItems, id: \.self) { item in
                        Button(item) {
                            text = item
                            onSelectItem?()
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .help(tooltip ?? "")
        .onAppear { handleFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { _, request in handleFocusRequest(request) }
    }

    private func handleFocusRequest(_ request: Int) {
        guard request != handledFocusRequest else {
            return
        }
        handledFocusRequest = request
        isFocused = true
    }
}
