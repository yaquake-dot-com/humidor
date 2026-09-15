// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// A dialog window with SwiftUI content, shown next to the main window.
@MainActor
class DialogWindow: NSObject, NSWindowDelegate {

    let window: NSWindow
    var showCallback: (@MainActor () -> Void)?
    var closeCallback: (@MainActor () -> Void)?

    init<Content: View>(title: String, width: CGFloat = 0, height: CGFloat = 0, isResizable: Bool = true,
                        @ViewBuilder content: () -> Content) {

        let hostingController = NSHostingController(rootView: content())
        hostingController.sizingOptions = (width > 0 || height > 0) ? [] : [.preferredContentSize]

        window = NSWindow(contentViewController: hostingController)
        window.title = title
        window.styleMask = [.titled, .closable]

        if isResizable {
            window.styleMask.insert(.resizable)
        }

        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        if width > 0 || height > 0 {
            window.setContentSize(NSSize(width: max(width, 300), height: max(height, 200)))
        }

        super.init()
        window.delegate = self
    }

    var isVisible: Bool {
        window.isVisible
    }

    func present() {
        if !window.isVisible {
            if let mainWindow = MainWindow.shared?.window, mainWindow.isVisible {
                let frame = mainWindow.frame
                let size = window.frame.size
                window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
            } else {
                window.center()
            }

            showCallback?()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func hide() {
        window.orderOut(nil)
    }

    func close() {
        window.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        closeCallback?()
    }
}
