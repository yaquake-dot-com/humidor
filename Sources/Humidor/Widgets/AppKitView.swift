// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Embeds an existing AppKit view in SwiftUI. The view is owned elsewhere and
/// keeps its state (selection, scroll position) when SwiftUI recreates the
/// surrounding views.
struct AppKitView: NSViewRepresentable {

    let view: NSView

    init(_ view: NSView) {
        self.view = view
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        embed(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            embed(in: container)
        }
    }

    private func embed(in container: NSView) {
        view.removeFromSuperview()

        // Resize with the container, without layout constraints. Constraints make the
        // container keep its current size when SwiftUI asks for its minimum size, which
        // makes the minimum size of the window follow its width.
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = container.bounds
        container.addSubview(view)
    }
}

extension TreeView {
    /// SwiftUI view displaying this list view
    var view: AppKitView { AppKitView(scrollView) }
}

extension TextView {
    /// SwiftUI view displaying this text view
    var view: AppKitView { AppKitView(scrollView) }
}
