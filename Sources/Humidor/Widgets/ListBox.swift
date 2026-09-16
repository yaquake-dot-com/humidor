// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A list view in a rounded frame, with buttons for its rows below it.
///
/// Buttons for adding, editing and removing rows are shown as icons, as in
/// system windows, other buttons keep their label.
struct ListBox: View {

    let listView: TreeView
    var height: CGFloat?
    var buttons: [ListBoxButton] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            listView.view
                .frame(height: height)

            if !buttons.isEmpty {
                Divider()

                HStack(spacing: 8) {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                        if button.isRowAction {
                            Button(action: button.action) {
                                Image(systemName: button.systemImage)
                                    .frame(width: 16)
                            }
                            .help(button.title)
                        } else {
                            Button(button.title, action: button.action)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .roundedFrame()
    }
}

struct ListBoxButton {

    /// Buttons acting on rows are shown without a label
    private static let rowActionImages = ["plus", "pencil", "minus"]

    let title: String
    let systemImage: String
    let action: @MainActor () -> Void

    var isRowAction: Bool {
        Self.rowActionImages.contains(systemImage)
    }

    static func add(_ action: @escaping @MainActor () -> Void) -> Self {
        Self(title: String(localized: "Add…"), systemImage: "plus", action: action)
    }

    static func edit(_ action: @escaping @MainActor () -> Void) -> Self {
        Self(title: String(localized: "Edit…"), systemImage: "pencil", action: action)
    }

    static func remove(_ action: @escaping @MainActor () -> Void) -> Self {
        Self(title: String(localized: "Remove"), systemImage: "minus", action: action)
    }
}

extension View {

    /// Draws a rounded frame around a view, as used around lists and text views.
    func roundedFrame(cornerRadius: CGFloat = 6) -> some View {
        clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color(nsColor: .separatorColor))
            }
    }

    /// Adds a bar with the given content along the bottom of a window, which
    /// fades out the content scrolling underneath it.
    @ViewBuilder
    func bottomBar(horizontalPadding: CGFloat = 20, verticalPadding: CGFloat = 12,
                   @ViewBuilder _ content: () -> some View) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom) {
                content()
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
            }
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                content()
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                    .background(.bar)
                    .overlay(alignment: .top) {
                        Divider()
                    }
            }
        }
    }
}
