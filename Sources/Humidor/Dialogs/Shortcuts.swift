// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Keyboard shortcuts, listed in their window.
@MainActor
enum Shortcuts {

    private struct Section: Identifiable {
        let title: String
        let shortcuts: [(keys: String, title: String)]

        var id: String { title }
    }

    private static let sections: [Section] = [
        Section(title: String(localized: "General"), shortcuts: [
            ("⇧⌘C", String(localized: "Connect")),
            ("⇧⌘D", String(localized: "Disconnect")),
            ("⇧⌘A", String(localized: "Away")),
            ("⇧⌘R", String(localized: "Rescan Shares")),
            ("⌘L", String(localized: "Show Log Pane")),
            ("⌘?", String(localized: "Keyboard Shortcuts")),
            ("⌘,", String(localized: "Preferences")),
            ("⌘Q", String(localized: "Confirm Quit")),
            ("⌥⌘Q", String(localized: "Quit"))
        ]),
        Section(title: String(localized: "Tabs"), shortcuts: [
            ("⌘1…9", String(localized: "Change Main Tab")),
            ("⌃⇧⇥", String(localized: "Go to Previous Secondary Tab")),
            ("⌃⇥", String(localized: "Go to Next Secondary Tab")),
            ("⇧⌘T", String(localized: "Reopen Closed Secondary Tab")),
            ("⌘W", String(localized: "Close Secondary Tab"))
        ]),
        Section(title: String(localized: "Lists"), shortcuts: [
            ("⌘C", String(localized: "Copy Selected Cell")),
            ("⌘A", String(localized: "Select All")),
            ("⌘F", String(localized: "Find")),
            ("⌦", String(localized: "Remove Selected Row"))
        ]),
        Section(title: String(localized: "Editing"), shortcuts: [
            ("⌘X", String(localized: "Cut")),
            ("⌘C", String(localized: "Copy")),
            ("⌘V", String(localized: "Paste")),
            ("⌃⌘Space", String(localized: "Insert Emoji")),
            ("⌘A", String(localized: "Select All")),
            ("⌘F", String(localized: "Find")),
            ("⌘G", String(localized: "Find Next Match")),
            ("⇧⌘G", String(localized: "Find Previous Match"))
        ]),
        Section(title: String(localized: "File Transfers"), shortcuts: [
            ("R", String(localized: "Resume / Retry Transfer")),
            ("T", String(localized: "Pause / Abort Transfer")),
            ("⌥↩", String(localized: "File Properties"))
        ]),
        Section(title: String(localized: "Browse Shares"), shortcuts: [
            ("⌘↩", String(localized: "Download / Upload To")),
            ("⌥↩", String(localized: "File Properties")),
            ("⌘S", String(localized: "Save List to Disk")),
            ("⌘G", String(localized: "Find Next Match")),
            ("⌘R", String(localized: "Refresh")),
            ("⌘\\", String(localized: "Expand / Collapse All")),
            ("⌫", String(localized: "Back to Parent Folder"))
        ]),
        Section(title: String(localized: "File Search"), shortcuts: [
            ("⌘F", String(localized: "Result Filters")),
            ("⌥↩", String(localized: "File Properties")),
            ("⇧⌘W", String(localized: "Wishlist"))
        ])
    ]

    static var content: ShortcutsView {
        ShortcutsView(sections: sections.map { ($0.title, $0.shortcuts) })
    }
}

struct ShortcutsView: View {

    let sections: [(title: String, shortcuts: [(keys: String, title: String)])]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)],
                      alignment: .leading, spacing: 24) {
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(.headline)

                        ForEach(Array(section.shortcuts.enumerated()), id: \.offset) { _, shortcut in
                            HStack {
                                Text(shortcut.keys)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 90, alignment: .leading)
                                Text(shortcut.title)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}
