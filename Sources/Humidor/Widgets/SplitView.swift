// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// A pane of a ``SplitView``.
struct SplitPane {

    /// Smallest length the pane can be dragged to
    var minLength: CGFloat
    /// Length of the pane when it is first shown, if it doesn't take the remaining space
    var idealLength: CGFloat?
    var isVisible: Bool
    let content: AnyView

    init(minLength: CGFloat = 50, idealLength: CGFloat? = nil, isVisible: Bool = true,
         @ViewBuilder content: () -> some View) {
        self.minLength = minLength
        self.idealLength = idealLength
        self.isVisible = isVisible
        self.content = AnyView(content())
    }
}

/// Panes separated by dividers the user can drag, backed by `NSSplitView`.
///
/// SwiftUI's `HSplitView` and `VSplitView` report a minimum size that follows their
/// current size when they are shown next to an inspector, which keeps the window from
/// getting smaller, and makes it grow when the inspector is resized.
struct SplitView: NSViewRepresentable {

    enum Axis {
        /// Panes side by side
        case horizontal
        /// Panes stacked on top of each other
        case vertical
    }

    let axis: Axis
    let panes: [SplitPane]
    /// Index of the pane that grows and shrinks with the split view
    var resizingPane = 0

    init(_ axis: Axis, resizingPane: Int = 0, panes: [SplitPane]) {
        self.axis = axis
        self.resizingPane = resizingPane
        self.panes = panes
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = (axis == .horizontal)
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator

        context.coordinator.hostingViews = panes.map { pane in
            let hostingView = NSHostingView(rootView: pane.content)
            // The split view decides the size of its panes
            hostingView.sizingOptions = []
            hostingView.translatesAutoresizingMaskIntoConstraints = true
            return hostingView
        }

        updatePanes(of: splitView, coordinator: context.coordinator)
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        let coordinator = context.coordinator

        for (hostingView, pane) in zip(coordinator.hostingViews, panes) {
            hostingView.rootView = pane.content
        }

        updatePanes(of: splitView, coordinator: coordinator)
    }

    /// The split view fills the space it is given, and doesn't report a minimum size of its own.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSplitView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }

    private func updatePanes(of splitView: NSSplitView, coordinator: Coordinator) {
        let visibleIndexes = panes.indices.filter { panes[$0].isVisible }
        let visibleViews = visibleIndexes.map { coordinator.hostingViews[$0] }

        coordinator.panes = panes
        coordinator.visibleIndexes = visibleIndexes
        coordinator.resizingPane = resizingPane

        guard splitView.subviews != visibleViews else {
            return
        }

        for view in splitView.subviews {
            view.removeFromSuperview()
        }

        for view in visibleViews {
            splitView.addSubview(view)
        }

        coordinator.layOut(splitView)
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {

        var hostingViews: [NSHostingView<AnyView>] = []
        var panes: [SplitPane] = []
        /// Indexes of the panes shown in the split view, in order
        var visibleIndexes: [Int] = []
        var resizingPane = 0

        /// Lengths of the panes that keep their size, by pane index
        private var lengths: [Int: CGFloat] = [:]
        private var isLayingOut = false

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            layOut(splitView)
        }

        /// Gives the panes that keep their size their length, and the remaining space to the
        /// resizing pane. Panes are made shorter, down to their minimum length, when the space
        /// runs out.
        func layOut(_ splitView: NSSplitView) {
            let views = splitView.subviews

            guard !views.isEmpty, views.count == visibleIndexes.count else {
                return
            }

            let isVertical = splitView.isVertical
            let totalLength = isVertical ? splitView.bounds.width : splitView.bounds.height
            let availableLength = max(totalLength - splitView.dividerThickness * CGFloat(views.count - 1), 0)
            let resizingPosition = visibleIndexes.firstIndex(of: resizingPane) ?? (views.count - 1)

            var paneLengths = visibleIndexes.enumerated().map { position, index -> CGFloat in
                guard position != resizingPosition else {
                    return 0
                }
                return lengths[index] ?? panes[index].idealLength ?? panes[index].minLength
            }

            let resizingMinLength = panes[visibleIndexes[resizingPosition]].minLength
            var shortfall = resizingMinLength - (availableLength - paneLengths.reduce(0, +))

            for position in paneLengths.indices where position != resizingPosition && shortfall > 0 {
                let reducibleLength = max(paneLengths[position] - panes[visibleIndexes[position]].minLength, 0)
                let reduction = min(reducibleLength, shortfall)
                paneLengths[position] -= reduction
                shortfall -= reduction
            }

            paneLengths[resizingPosition] = max(availableLength - paneLengths.reduce(0, +), 0)

            isLayingOut = true
            defer { isLayingOut = false }

            var offset: CGFloat = 0

            for (view, length) in zip(views, paneLengths) {
                view.frame = isVertical
                    ? NSRect(x: offset, y: 0, width: length, height: splitView.bounds.height)
                    : NSRect(x: 0, y: offset, width: splitView.bounds.width, height: length)
                offset += length + splitView.dividerThickness
            }
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            // Only keep lengths set by dragging a divider, not by resizing the window
            guard !isLayingOut, NSApp.currentEvent?.type == .leftMouseDragged,
                  let splitView = notification.object as? NSSplitView else {
                return
            }

            // A divider was dragged, keep the new lengths
            for (view, index) in zip(splitView.subviews, visibleIndexes) where index != resizingPane {
                lengths[index] = splitView.isVertical ? view.frame.width : view.frame.height
            }
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard dividerIndex < splitView.subviews.count, dividerIndex < visibleIndexes.count else {
                return proposedMinimumPosition
            }

            let frame = splitView.subviews[dividerIndex].frame
            let start = splitView.isVertical ? frame.minX : frame.minY
            return max(proposedMinimumPosition, start + panes[visibleIndexes[dividerIndex]].minLength)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            let nextIndex = dividerIndex + 1

            guard nextIndex < splitView.subviews.count, nextIndex < visibleIndexes.count else {
                return proposedMaximumPosition
            }

            let frame = splitView.subviews[nextIndex].frame
            let end = splitView.isVertical ? frame.maxX : frame.maxY
            return min(proposedMaximumPosition, end - panes[visibleIndexes[nextIndex]].minLength)
        }
    }
}
