// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

@MainActor
enum Clipboard {

    static func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func text() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
