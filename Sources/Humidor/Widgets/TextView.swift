// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore

// MARK: - Text Tags

/// A text tag, applied to ranges of text to change their appearance or to
/// make them clickable (URLs and usernames).
@MainActor
final class TextTag {
    var colorID: String?
    let url: String?
    let username: String?
    let callback: (@MainActor (NSPoint, String) -> Void)?

    /// Tagged ranges, as absolute positions since the view was created
    fileprivate var ranges: [NSRange] = []

    fileprivate init(colorID: String?, url: String?, username: String?,
                     callback: (@MainActor (NSPoint, String) -> Void)?) {
        self.colorID = colorID
        self.url = url
        self.username = username
        self.callback = callback
    }
}

private extension NSAttributedString.Key {
    static let textTag = NSAttributedString.Key("HumidorTextTag")
}

// MARK: - Text View

/// Scrollable text view for logs and chat messages.
@MainActor
class TextView: NSObject {

    static let maxNumLines = 50000
    private static let urlPattern = try! NSRegularExpression(  // swiftlint:disable:this force_try
        pattern: "(\\w+\\://[^\\s]+)|(www\\.\\w+\\.[^\\s]+)|(mailto\\:[^\\s]+)"
    )

    let scrollView = NSScrollView()
    let textView = ClickableTextView()

    var autoScroll: Bool
    var typeTags: [String: TextTag] = [:]
    var popupMenu: PopupMenu?
    var pageDownCallback: (@MainActor () -> Bool)?

    private let parseURLs: Bool
    private var tags: [TextTag] = []
    private var numLines = 0
    /// Number of characters removed from the start of the text
    private var removedOffset = 0
    private(set) var pressedPoint = NSPoint.zero
    private(set) var pressedCharacterIndex: Int?

    var font: NSFont {
        didSet {
            textView.font = font
        }
    }

    init(autoScroll: Bool = false, parseURLs: Bool = true, isEditable: Bool = true, horizontalMargin: CGFloat = 12,
         verticalMargin: CGFloat = 8, paragraphSpacing: CGFloat = 1, font: NSFont? = nil) {

        self.autoScroll = autoScroll
        self.parseURLs = parseURLs
        self.font = font ?? .systemFont(ofSize: NSFont.systemFontSize)

        super.init()

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        textView.owner = self
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = !isEditable
        textView.importsGraphics = false
        textView.allowsUndo = isEditable
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: horizontalMargin, height: verticalMargin)
        textView.font = self.font
        textView.textColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = paragraphSpacing
        paragraphStyle.paragraphSpacingBefore = paragraphSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping
        textView.defaultParagraphStyle = paragraphStyle

        scrollView.documentView = textView
    }

    private var textStorage: NSTextStorage { textView.textStorage! }

    var isAtBottom: Bool {
        let visibleRect = scrollView.contentView.documentVisibleRect
        return visibleRect.maxY >= textView.bounds.maxY - 4
    }

    func scrollBottom() {
        textView.scrollToEndOfDocument(nil)
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: textView.defaultParagraphStyle ?? NSParagraphStyle.default
        ]
    }

    private func insertText(_ text: String, tag: TextTag?, into buffer: NSMutableAttributedString) {
        guard !text.isEmpty else {
            return
        }

        var attributes = baseAttributes()

        if let tag {
            attributes.merge(tagAttributes(tag)) { _, new in new }
            attributes[.textTag] = tag

            let location = textStorage.length + buffer.length + removedOffset
            tag.ranges.append(NSRange(location: location, length: (text as NSString).length))
        }

        buffer.append(NSAttributedString(string: text, attributes: attributes))
    }

    private func removeOldLines() {
        guard numLines >= Self.maxNumLines else {
            return
        }

        // Optimization: remove lines in batches
        let numRemovedLines = numLines - (Self.maxNumLines - 1000)
        let string = textStorage.string as NSString
        var location = 0

        for _ in 0..<numRemovedLines {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)

            if location >= string.length {
                break
            }
        }

        textStorage.deleteCharacters(in: NSRange(location: 0, length: location))
        removedOffset += location
        numLines -= numRemovedLines

        for tag in tags {
            tag.ranges.removeAll { NSMaxRange($0) <= removedOffset }
        }

        // URL tags are only used once, forget them once their text is gone
        tags.removeAll { $0.url != nil && $0.ranges.isEmpty }
    }

    func appendLine(_ line: String, messageType: String? = nil, timestamp: Date? = nil,
                    timestampFormat: String? = nil, username: String? = nil, userTag: TextTag? = nil) {

        let tag = messageType.flatMap { typeTags[$0] }
        var line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        let buffer = NSMutableAttributedString()
        let shouldScroll = autoScroll && isAtBottom

        if let timestampFormat, !timestampFormat.isEmpty {
            line = formatTimestamp(timestampFormat, date: timestamp ?? Date()) + " " + line
        }

        if textStorage.length > 0 {
            // No tag applied on line breaks to prevent visual glitch where text on the
            // next line has the wrong color
            insertText("\n", tag: nil, into: buffer)
        }

        // Tag usernames with popup menu creating tag, and away/online/offline colors
        if let username, !username.isEmpty, let usernameRange = line.range(of: username) {
            insertText(String(line[..<usernameRange.lowerBound]), tag: tag, into: buffer)
            insertText(username, tag: userTag, into: buffer)
            line = String(line[usernameRange.upperBound...])
        }

        // Highlight urls, if found and tag them
        if parseURLs && (line.contains("://") || line.contains("www.") || line.contains("mailto:")) {
            while let match = Self.urlPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let matchRange = Range(match.range, in: line) {
                insertText(String(line[..<matchRange.lowerBound]), tag: tag, into: buffer)

                let url = String(line[matchRange])
                insertText(url, tag: createTag(colorID: "urlcolor", url: url), into: buffer)

                line = String(line[matchRange.upperBound...])
            }
        }

        insertText(line, tag: tag, into: buffer)

        textStorage.beginEditing()
        textStorage.append(buffer)
        textStorage.endEditing()

        numLines += 1
        removeOldLines()

        if shouldScroll {
            scrollBottom()
        }
    }

    var hasSelection: Bool {
        textView.selectedRange().length > 0
    }

    var text: String {
        textStorage.string
    }

    func grabFocus() {
        textView.window?.makeFirstResponder(textView)
    }

    /// Sets text without any additional processing, and clears the undo stack.
    func setText(_ text: String) {
        textStorage.setAttributedString(NSAttributedString(string: text, attributes: baseAttributes()))
        textView.undoManager?.removeAllActions()

        for tag in tags {
            tag.ranges.removeAll()
        }

        tags.removeAll { $0.url != nil }
        removedOffset = 0
        numLines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
    }

    func clear() {
        setText("")
    }

    func placeCursorAtLine(_ lineNumber: Int) {
        let string = textStorage.string as NSString
        var location = 0

        for _ in 0..<lineNumber {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)

            if location >= string.length {
                break
            }
        }

        textView.setSelectedRange(NSRange(location: min(location, string.length), length: 0))
        textView.scrollRangeToVisible(NSRange(location: min(location, string.length), length: 0))
    }

    // MARK: Text Tags

    func createTag(colorID: String? = nil, callback: (@MainActor (NSPoint, String) -> Void)? = nil,
                   username: String? = nil, url: String? = nil) -> TextTag {
        var url = url

        if let tagURL = url, tagURL.hasPrefix("www.") {
            url = "http://" + tagURL
        }

        let tag = TextTag(colorID: colorID, url: url, username: username, callback: callback)
        tags.append(tag)
        return tag
    }

    private func tagAttributes(_ tag: TextTag) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: tag.colorID.flatMap { Theme.color(forID: $0) } ?? NSColor.labelColor
        ]

        if tag.colorID == "urlcolor" {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.cursor] = NSCursor.pointingHand
        }

        if tag.username != nil {
            let usernameStyle = config.ui.usernameStyle
            var usernameFont = font

            if usernameStyle == "bold" {
                usernameFont = NSFontManager.shared.convert(usernameFont, toHaveTrait: .boldFontMask)
            } else if usernameStyle == "italic" {
                usernameFont = NSFontManager.shared.convert(usernameFont, toHaveTrait: .italicFontMask)
            }

            attributes[.font] = usernameFont
            attributes[.cursor] = NSCursor.arrow

            if usernameStyle == "underline" {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
        }

        return attributes
    }

    func updateTag(_ tag: TextTag, colorID: String? = nil) {
        if let colorID {
            tag.colorID = colorID
        }

        let attributes = tagAttributes(tag)
        let length = textStorage.length

        textStorage.beginEditing()

        for range in tag.ranges {
            let location = range.location - removedOffset

            guard location >= 0, location + range.length <= length else {
                continue
            }
            textStorage.addAttributes(attributes, range: NSRange(location: location, length: range.length))
        }

        textStorage.endEditing()
    }

    func updateTags() {
        for tag in tags {
            updateTag(tag)
        }
    }

    func setFont(_ font: NSFont) {
        self.font = font

        textStorage.beginEditing()
        textStorage.addAttribute(.font, value: font, range: NSRange(location: 0, length: textStorage.length))
        textStorage.endEditing()
        updateTags()
    }

    // MARK: Events

    fileprivate func tag(at point: NSPoint) -> TextTag? {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
            return nil
        }

        let containerPoint = NSPoint(x: point.x - textView.textContainerOrigin.x,
                                     y: point.y - textView.textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer,
                                                  fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1),
                                                   in: textContainer)

        // Points are also returned for whitespace after the last character, avoid accidental URL clicks
        guard glyphRect.contains(containerPoint) else {
            return nil
        }

        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        pressedCharacterIndex = characterIndex

        guard characterIndex < textStorage.length else {
            return nil
        }
        return textStorage.attribute(.textTag, at: characterIndex, effectiveRange: nil) as? TextTag
    }

    var urlForCurrentPosition: String {
        tag(at: pressedPoint)?.url ?? ""
    }

    fileprivate func onReleasedPrimary(_ point: NSPoint) -> Bool {
        pressedPoint = point

        guard !hasSelection, let tag = tag(at: point) else {
            return false
        }

        if let url = tag.url {
            openURI(url)
            return true
        }

        if let username = tag.username, let callback = tag.callback {
            callback(point, username)
            return true
        }
        return false
    }

    fileprivate enum SecondaryPressResult {
        case handled
        case menu(NSMenu)
        case defaultMenu
    }

    fileprivate func onPressedSecondary(_ point: NSPoint) -> SecondaryPressResult {
        pressedPoint = point

        if !hasSelection, let tag = tag(at: point), let username = tag.username, let callback = tag.callback {
            callback(point, username)
            return .handled
        }

        guard let popupMenu else {
            return .defaultMenu
        }

        popupMenu.prepare()
        return .menu(popupMenu.menu)
    }

    func onCopyText() {
        textView.copy(nil)
    }

    func onCopyLink() {
        Clipboard.copyText(urlForCurrentPosition)
    }

    func onCopyAllText() {
        Clipboard.copyText(text)
    }

    func onClearAllText() {
        clear()
    }

    func showFindBar() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performFindPanelAction(item)
    }
}

// MARK: - Clickable Text View

final class ClickableTextView: NSTextView {

    fileprivate weak var owner: TextView?
    private var mouseDownPoint = NSPoint.zero

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)

        // NSTextView tracks the mouse until it is released
        let point = convert(NSApp.currentEvent?.locationInWindow ?? event.locationInWindow, from: nil)

        guard abs(point.x - mouseDownPoint.x) < 3, abs(point.y - mouseDownPoint.y) < 3 else {
            return
        }

        _ = owner?.onReleasedPrimary(point)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let result = owner?.onPressedSecondary(point) ?? .defaultMenu

        switch result {
        case .handled: return nil
        case let .menu(menu): return menu
        case .defaultMenu: return super.menu(for: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        let key = Accelerator.key(for: event)

        if key == .pageDown || key == .down, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            if let owner, let pageDownCallback = owner.pageDownCallback, owner.isAtBottom, pageDownCallback() {
                return
            }
        }

        super.keyDown(with: event)
    }
}

// MARK: - Chat View

/// Text view for chat rooms and private chats, with colored and clickable usernames.
@MainActor
final class ChatView: TextView {

    private(set) var userTags: [String: TextTag] = [:]
    /// Users whose online status is shown. In chat rooms, only users currently in the room.
    var statusUsers: (() -> Set<String>)?
    private let usernameEvent: (@MainActor (NSPoint, String) -> Void)?

    init(autoScroll: Bool = true, horizontalMargin: CGFloat = 12, verticalMargin: CGFloat = 8,
         paragraphSpacing: CGFloat = 1, font: NSFont? = nil,
         usernameEvent: (@MainActor (NSPoint, String) -> Void)?) {

        self.usernameEvent = usernameEvent

        super.init(autoScroll: autoScroll, parseURLs: true, isEditable: false, horizontalMargin: horizontalMargin,
                   verticalMargin: verticalMargin, paragraphSpacing: paragraphSpacing, font: font)

        typeTags = [
            "remote": createTag(colorID: "chatremote"),
            "local": createTag(colorID: "chatlocal"),
            "command": createTag(colorID: "chatcommand"),
            "action": createTag(colorID: "chatme"),
            "hilite": createTag(colorID: "chathilite")
        ]
    }

    func appendLogLines(_ logLines: [String], loginUsername: String?) {
        guard !logLines.isEmpty else {
            return
        }

        let loginUsernameLower = loginUsername?.lowercased()

        for line in logLines {
            var user: String?
            var messageType: String?
            var userTag: TextTag?

            if let startRange = line.range(of: " ["), let endRange = line.range(of: "] ", range: startRange.upperBound..<line.endIndex),
               endRange.lowerBound > startRange.upperBound {
                let username = String(line[startRange.upperBound..<endRange.lowerBound])
                let text = String(line[endRange.upperBound...]).dropLast()

                user = username
                userTag = self.userTag(username)

                if username == loginUsername {
                    messageType = "local"
                } else if let loginUsernameLower, findWholeWord(loginUsernameLower, in: text.lowercased()) != nil {
                    messageType = "hilite"
                } else {
                    messageType = "remote"
                }

            } else if line.contains("* ") {
                messageType = "action"
            }

            appendLine(line, messageType: messageType, username: user, userTag: userTag)
        }

        appendLine(String(localized: "--- old messages above ---"), messageType: "hilite")
    }

    override func clear() {
        super.clear()
        userTags.removeAll()
    }

    func userTag(_ username: String) -> TextTag {
        if let tag = userTags[username] {
            return tag
        }

        let tag = createTag(callback: usernameEvent, username: username)
        userTags[username] = tag
        updateUserTag(username)
        return tag
    }

    func updateUserTag(_ username: String) {
        guard let tag = userTags[username] else {
            return
        }

        var status = UserStatus.offline

        if statusUsers?().contains(username) ?? true {
            status = core.users.statuses[username] ?? .offline
        }

        updateTag(tag, colorID: Theme.userStatusColorID(status))
    }

    func updateUserTags() {
        for username in userTags.keys {
            updateUserTag(username)
        }
    }
}
