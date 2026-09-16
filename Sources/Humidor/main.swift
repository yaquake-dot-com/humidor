// SPDX-License-Identifier: GPL-3.0-or-later
//
// Entry point of the macOS application.

import AppKit

MainActor.assumeIsolated {
    let application = Application()
    let app = NSApplication.shared

    app.delegate = application
    app.setActivationPolicy(.regular)
    app.mainMenu = MainMenu.create(application: application)
    app.run()
}
