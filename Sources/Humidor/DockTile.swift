// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Transfer speeds shown on the application icon in the Dock, below the badge of the unread
/// messages. The icon returns to its usual appearance while nothing is transferred.
@MainActor
final class DockTile {

    /// Speeds below this are not worth a badge
    fileprivate static let minimumSpeed = 1024

    private let tileView = DockTileView()
    private var downloadSpeed = 0
    private var uploadSpeed = 0

    func update(downloadSpeed: Int, uploadSpeed: Int) {
        guard downloadSpeed != self.downloadSpeed || uploadSpeed != self.uploadSpeed else {
            return
        }

        self.downloadSpeed = downloadSpeed
        self.uploadSpeed = uploadSpeed

        let tile = NSApp.dockTile
        let isIdle = downloadSpeed < Self.minimumSpeed && uploadSpeed < Self.minimumSpeed

        guard !isIdle else {
            if tile.contentView != nil {
                tile.contentView = nil
                tile.display()
            }
            return
        }

        tileView.downloadSpeed = downloadSpeed
        tileView.uploadSpeed = uploadSpeed

        if tile.contentView !== tileView {
            tile.contentView = tileView
        }

        tile.display()
    }
}

/// The application icon with a badge per direction being transferred.
private final class DockTileView: NSView {

    var downloadSpeed = 0
    var uploadSpeed = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)

        let height = bounds.height * 0.21
        let spacing = height * 0.14
        var bottom = bounds.height * 0.05

        // The upload badge is the lower one, as in the status of the sidebar
        for (speed, symbolName, color) in [(uploadSpeed, "arrow.up", NSColor.systemGreen),
                                           (downloadSpeed, "arrow.down", NSColor.systemBlue)]
        where speed >= DockTile.minimumSpeed {
            drawBadge(text(speed: speed, symbolName: symbolName, height: height),
                      color: color, height: height, bottom: bottom)
            bottom += height + spacing
        }
    }

    private func drawBadge(_ text: NSAttributedString, color: NSColor, height: CGFloat, bottom: CGFloat) {
        let textSize = text.size()
        let width = min(bounds.width, textSize.width + height)
        let badge = NSRect(x: (bounds.width - width) / 2, y: bottom, width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = height * 0.12
        shadow.shadowOffset = NSSize(width: 0, height: -height * 0.04)
        shadow.set()

        color.setFill()
        NSBezierPath(roundedRect: badge, xRadius: height / 2, yRadius: height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.setStroke()
        let border = NSBezierPath(roundedRect: badge.insetBy(dx: height * 0.04, dy: height * 0.04),
                                  xRadius: height / 2, yRadius: height / 2)
        border.lineWidth = height * 0.08
        border.stroke()

        text.draw(at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2))
    }

    /// An arrow and a short speed, like "392 K"
    private func text(speed: Int, symbolName: String, height: CGFloat) -> NSAttributedString {
        let fontSize = height * 0.58
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let result = NSMutableAttributedString()

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: fontSize, weight: .bold)) {
            let attachment = NSTextAttachment()
            attachment.image = image
            let arrow = NSMutableAttributedString(attachment: attachment)
            arrow.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: arrow.length))
            result.append(arrow)
        }

        result.append(NSAttributedString(string: " " + Self.shortSpeed(speed),
                                         attributes: [.font: font, .foregroundColor: NSColor.white]))
        return result
    }

    /// A speed without its unit, short enough for the Dock, like "1,2 M" or "392 K"
    private static func shortSpeed(_ speed: Int) -> String {
        var value = Double(speed)
        var unit = ""

        for nextUnit in ["K", "M", "G"] where value >= 1024 {
            value /= 1024
            unit = nextUnit
        }

        let digits = (value < 10 && (unit == "M" || unit == "G")) ? 1 : 0
        return "\(value.formatted(.number.precision(.fractionLength(digits)))) \(unit)"
    }
}
