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

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func embed(in container: NSView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)

        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
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
