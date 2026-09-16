// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Content of a page without tabs: an entry in the middle of the page, with
/// previous entries listed below it.
struct PageStart<Entry: View>: View {

    let systemImage: String
    let title: String
    let description: String
    var recentTitle = String(localized: "Recent Searches")
    var recentItems: [String] = []
    var onSelectItem: (@MainActor (String) -> Void)?
    @ViewBuilder var entry: Entry

    /// Number of previous entries shown below the entry
    private static var recentItemLimit: Int { 8 }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.title2.weight(.semibold))

            Text(description)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            entry
                .frame(maxWidth: 420)

            if !visibleItems.isEmpty, let onSelectItem {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recentTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)

                    ForEach(visibleItems, id: \.self) { item in
                        Button {
                            onSelectItem(item)
                        } label: {
                            Text(item)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.accessoryBar)
                    }
                }
                .frame(maxWidth: 420)
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var visibleItems: [String] {
        Array(recentItems.filter { !$0.isEmpty }.prefix(Self.recentItemLimit))
    }
}
