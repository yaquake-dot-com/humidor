// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore

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
        case "status.online": .systemGreen
        case "status.away": .systemYellow
        default: .systemRed
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

    /// System color of a text tag (chat message types, usernames, URLs) and of tab labels.
    static func color(forID colorID: String) -> NSColor? {
        switch colorID {
        case "chatme", "chatcommand": .secondaryLabelColor
        case "chathilite", "tabhilite", "tabchanged": .controlAccentColor
        case "urlcolor": .linkColor
        case "useronline": config.ui.usernameHotspots ? .systemGreen : nil
        case "useraway": config.ui.usernameHotspots ? .systemYellow : nil
        case "useroffline": config.ui.usernameHotspots ? .systemRed : nil
        default: nil
        }
    }

    static func userStatusColorID(_ status: UserStatus) -> String {
        switch status {
        case .online: "useronline"
        case .away: "useraway"
        case .offline: "useroffline"
        }
    }
}
