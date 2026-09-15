// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import NicotineCore

/// Icons, colors and fonts used throughout the user interface.
@MainActor
enum Theme {

    // MARK: Icons

    static let fileTypeIconLabels: [String: String] = [
        "filetype.executable": String(localized: "Executable"),
        "filetype.audio": String(localized: "Audio"),
        "filetype.image": String(localized: "Image"),
        "filetype.archive": String(localized: "Archive"),
        "filetype.miscellaneous": String(localized: "Miscellaneous"),
        "filetype.video": String(localized: "Video"),
        "filetype.document": String(localized: "Document"),
        "filetype.text": String(localized: "Text")
    ]

    static let userStatusIconLabels: [String: String] = [
        "status.online": String(localized: "Online"),
        "status.away": String(localized: "Away"),
        "status.offline": String(localized: "Offline")
    ]

    static func userStatusIconName(_ status: UserStatus) -> String {
        switch status {
        case .online: "status.online"
        case .away: "status.away"
        case .offline: "status.offline"
        }
    }

    static func flagIconName(_ countryCode: String?) -> String {
        guard let countryCode, !countryCode.isEmpty else {
            return ""
        }
        return "flag.\(countryCode.lowercased())"
    }

    static func fileTypeIconName(_ basename: String) -> String {
        let fileExtension = (basename as NSString).pathExtension.lowercased()

        if FileTypes.audio.contains(fileExtension) {
            return "filetype.audio"
        }
        if FileTypes.image.contains(fileExtension) {
            return "filetype.image"
        }
        if FileTypes.video.contains(fileExtension) {
            return "filetype.video"
        }
        if FileTypes.archive.contains(fileExtension) {
            return "filetype.archive"
        }
        if FileTypes.document.contains(fileExtension) {
            return "filetype.document"
        }
        if FileTypes.text.contains(fileExtension) {
            return "filetype.text"
        }
        if FileTypes.executable.contains(fileExtension) {
            return "filetype.executable"
        }
        return "filetype.miscellaneous"
    }

    private static let symbolNames: [String: String] = [
        "filetype.executable": "gearshape",
        "filetype.audio": "music.note",
        "filetype.image": "photo",
        "filetype.archive": "archivebox",
        "filetype.miscellaneous": "doc",
        "filetype.video": "film",
        "filetype.document": "doc.richtext",
        "filetype.text": "doc.text"
    ]

    private static var imageCache: [String: NSImage] = [:]

    /// Returns the image for an icon name, or nil for icons displayed as text (flags).
    static func image(forIconName iconName: String) -> NSImage? {
        if let image = imageCache[iconName] {
            return image
        }

        var image: NSImage?

        switch iconName {
        case "status.online", "status.away", "status.offline":
            image = statusImage(color: statusColor(forIconName: iconName))
        default:
            if let symbolName = symbolNames[iconName] {
                image = NSImage(systemSymbolName: symbolName, accessibilityDescription: fileTypeIconLabels[iconName])
            }
        }

        imageCache[iconName] = image
        return image
    }

    /// Text representation of an icon, used for country flags.
    static func text(forIconName iconName: String) -> String? {
        guard iconName.hasPrefix("flag.") else {
            return nil
        }
        return flagEmoji(String(iconName.dropFirst("flag.".count)))
    }

    static func flagEmoji(_ countryCode: String) -> String {
        let base: UInt32 = 0x1F1E6 - 0x41

        return String(String.UnicodeScalarView(
            countryCode.uppercased().unicodeScalars.compactMap { Unicode.Scalar(base + $0.value) }
        ))
    }

    private static func statusColor(forIconName iconName: String) -> NSColor {
        switch iconName {
        case "status.online": color(hex: "#16BB5C") ?? .systemGreen
        case "status.away": color(hex: "#C9AE13") ?? .systemYellow
        default: color(hex: "#E04F5E") ?? .systemRed
        }
    }

    private static func statusImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 10, height: 10)

        return NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    // MARK: Colors

    static func color(hex: String) -> NSColor? {
        var hex = hex.trimmingCharacters(in: .whitespaces)

        guard hex.hasPrefix("#") else {
            return nil
        }
        hex.removeFirst()

        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            return nil
        }

        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Color configured for a text tag (chat message types, usernames, URLs).
    static func color(forID colorID: String) -> NSColor? {
        let ui = config.ui
        let isHotspotColor = ["useraway", "useronline", "useroffline"].contains(colorID)

        if isHotspotColor && !ui.usernameHotspots {
            return nil
        }

        let colorHex: String = switch colorID {
        case "chatme": ui.chatMe
        case "chatremote": ui.chatRemote
        case "chatlocal": ui.chatLocal
        case "chatcommand": ui.chatCommand
        case "chathilite": ui.chatHighlight
        case "urlcolor": ui.urlColor
        case "useronline": ui.userOnline
        case "useraway": ui.userAway
        case "useroffline": ui.userOffline
        case "tabhilite": ui.tabHighlight
        case "tabchanged": ui.tabChanged
        default: ""
        }

        return color(hex: colorHex)
    }

    static func userStatusColorID(_ status: UserStatus) -> String {
        switch status {
        case .online: "useronline"
        case .away: "useraway"
        case .offline: "useroffline"
        }
    }

    // MARK: Fonts

    /// Font configured for a group of widgets, e.g. "chatfont" or "listfont".
    static func font(_ fontDescription: String, default defaultFont: NSFont = .systemFont(ofSize: NSFont.systemFontSize))
        -> NSFont {
        guard !fontDescription.isEmpty else {
            return defaultFont
        }

        // Font descriptions consist of a family name, followed by the size
        var components = fontDescription.split(separator: " ").map(String.init)
        var size = defaultFont.pointSize

        if let lastComponent = components.last, let parsedSize = Double(lastComponent) {
            size = CGFloat(parsedSize)
            components.removeLast()
        }

        return NSFont(name: components.joined(separator: " "), size: size)
            ?? NSFontManager.shared.font(withFamily: components.joined(separator: " "), traits: [], weight: 5,
                                         size: size)
            ?? defaultFont.withSize(size)
    }
}
