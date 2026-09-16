// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A side pane of a split layout, separated from the main content by a divider that can be
/// dragged. The length of the pane is remembered between launches.
///
/// The main content takes the remaining space, so resizing the window only resizes the content.
struct SplitPane<Content: View, Pane: View>: View {

    enum Edge {
        case leading
        case trailing
        case top
        case bottom
    }

    private let edge: Edge
    private let range: ClosedRange<CGFloat>
    private let isPaneVisible: Bool
    private let content: Content
    private let pane: Pane

    @AppStorage private var length: Double
    @State private var dragStartLength: Double?

    /// - Parameters:
    ///   - id: name under which the length of the pane is stored
    ///   - edge: side of the content the pane is on
    init(_ id: String, edge: Edge, range: ClosedRange<CGFloat>, idealLength: CGFloat, isPaneVisible: Bool = true,
         @ViewBuilder content: () -> Content, @ViewBuilder pane: () -> Pane) {

        self.edge = edge
        self.range = range
        self.isPaneVisible = isPaneVisible
        self.content = content()
        self.pane = pane()
        _length = AppStorage(wrappedValue: idealLength, "SplitPane.\(id)")
    }

    private var isHorizontal: Bool { edge == .leading || edge == .trailing }
    private var isPaneFirst: Bool { edge == .leading || edge == .top }
    private var paneLength: CGFloat { min(max(length, range.lowerBound), range.upperBound) }

    var body: some View {
        let layout = isHorizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))

        layout {
            if isPaneVisible && isPaneFirst {
                sizedPane
                divider
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isPaneVisible && !isPaneFirst {
                divider
                sizedPane
            }
        }
    }

    private var sizedPane: some View {
        pane
            .frame(width: isHorizontal ? paneLength : nil, height: isHorizontal ? nil : paneLength)
    }

    private var divider: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: isHorizontal ? 8 : nil, height: isHorizontal ? nil : 8)
                    .contentShape(.rect)
                    .pointerStyle(isHorizontal ? .columnResize : .rowResize)
                    .gesture(dragGesture)
            }
            .zIndex(1)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let startLength = dragStartLength ?? paneLength
                dragStartLength = startLength

                let translation = isHorizontal ? value.translation.width : value.translation.height
                let newLength = isPaneFirst ? startLength + translation : startLength - translation
                length = min(max(newLength, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                dragStartLength = nil
            }
    }
}
