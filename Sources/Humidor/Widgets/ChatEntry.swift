// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore

/// Text entry for chat messages, with support for chat commands and completions.
///
/// A single entry is shared by all tabs of a chat page. Unsent messages are
/// remembered for each tab.
@MainActor
final class ChatEntry: NSObject, NSTextFieldDelegate {

    let textField = NSTextField()

    private let sendMessageCallback: @MainActor (String, String) -> Void
    private let commandCallback: @MainActor (String, String, String) -> Bool

    private(set) var entity: String?
    private weak var chatView: ChatView?
    private var unsentMessages: [String: String] = [:]
    private var completions: [String] = []
    private var currentCompletions: [String] = []
    private var completionIndex = 0
    /// True if the user just used tab completion
    private var isMidwayCompletion = false
    /// True if the drop-down list is open with suggestions
    private var isSelectingCompletion = false
    private var isInsertingCompletion = false
    private var isSpellCheckEnabled: Bool

    init(sendMessage: @escaping @MainActor (String, String) -> Void,
         command: @escaping @MainActor (String, String, String) -> Bool, isSpellCheckEnabled: Bool = false) {

        self.sendMessageCallback = sendMessage
        self.commandCallback = command
        self.isSpellCheckEnabled = isSpellCheckEnabled

        super.init()

        textField.placeholderString = String(localized: "Send message…")
        textField.delegate = self
        textField.isEnabled = false
        textField.lineBreakMode = .byTruncatingHead
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.focusRingType = .default
    }

    func clearUnsentMessage(_ entity: String) {
        unsentMessages.removeValue(forKey: entity)
    }

    func grabFocus() {
        textField.window?.makeFirstResponder(textField)

        // Place cursor at the end without selecting the text
        if let editor = textField.currentEditor() {
            editor.selectedRange = NSRange(location: (textField.stringValue as NSString).length, length: 0)
        }
    }

    var text: String {
        get { textField.stringValue }
        set { textField.stringValue = newValue }
    }

    var isSensitive: Bool {
        get { textField.isEnabled }
        set { textField.isEnabled = newValue }
    }

    private var isCompletionEnabled: Bool {
        config.words.tab || config.words.dropdown
    }

    func addCompletion(_ item: String) {
        guard isCompletionEnabled, !completions.contains(item) else {
            return
        }
        completions.append(item)
    }

    func removeCompletion(_ item: String) {
        guard isCompletionEnabled else {
            return
        }
        completions.removeAll { $0 == item }
    }

    /// Moves the entry to another tab, remembering the unsent message of the previous tab.
    func setParent(entity: String?, chatView: ChatView? = nil) {
        if let currentEntity = self.entity {
            unsentMessages[currentEntity] = textField.stringValue
        }

        self.entity = entity
        self.chatView = chatView

        guard let entity else {
            return
        }

        textField.stringValue = unsentMessages[entity] ?? ""
    }

    func setCompletions(_ completions: Set<String>) {
        self.completions.removeAll()

        guard isCompletionEnabled else {
            return
        }

        self.completions = completions.sorted()
    }

    func setSpellCheckEnabled(_ isEnabled: Bool) {
        isSpellCheckEnabled = isEnabled
        (textField.currentEditor() as? NSTextView)?.isContinuousSpellCheckingEnabled = isEnabled
    }

    // MARK: Events

    func onSendMessage() {
        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let entity else {
            return
        }

        guard !text.isEmpty else {
            chatView?.scrollBottom()
            return
        }

        let isDoubleSlashCommand = text.hasPrefix("//")
        let isSingleSlashCommand = text.hasPrefix("/") && !isDoubleSlashCommand

        if !isSingleSlashCommand {
            // Regular chat message
            textField.stringValue = ""

            // Remove first slash and send the rest of the command as plain text
            sendMessageCallback(entity, isDoubleSlashCommand ? String(text.dropFirst()) : text)
            return
        }

        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let command = String(parts[0].dropFirst())
        let args = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        guard commandCallback(entity, command, args) else {
            return
        }

        // Clear chat entry
        textField.stringValue = ""
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        (textField.currentEditor() as? NSTextView)?.isContinuousSpellCheckingEnabled = isSpellCheckEnabled
    }

    func controlTextDidChange(_ notification: Notification) {
        // If the entry was modified by the user, we're no longer completing
        if !isInsertingCompletion {
            isMidwayCompletion = false
            isSelectingCompletion = false
        }

        guard config.words.dropdown, !isInsertingCompletion,
              let textView = textField.currentEditor() as? NSTextView,
              NSApp.currentEvent?.type == .keyDown,
              NSApp.currentEvent?.charactersIgnoringModifiers.map({ !$0.isEmpty && $0 != "\u{7f}" }) ?? false,
              !matchingCompletions(textView).isEmpty else {
            return
        }

        // Show drop-down list with matching completions
        isInsertingCompletion = true
        isSelectingCompletion = true
        textView.complete(nil)
        isInsertingCompletion = false
    }

    /// Word to the left of the cursor
    private func currentWord(_ textView: NSTextView) -> (word: String, range: NSRange) {
        let text = textView.string as NSString
        let position = textView.selectedRange().location
        let prefix = text.substring(to: min(position, text.length))
        let word = prefix.components(separatedBy: " ").last ?? ""
        let wordLength = (word as NSString).length

        return (word, NSRange(location: position - wordLength, length: wordLength))
    }

    private func matchingCompletions(_ textView: NSTextView) -> [String] {
        let (word, _) = currentWord(textView)

        guard !word.isEmpty, word.count >= config.words.characters else {
            return []
        }

        // Case-insensitive matching
        let wordLower = word.lowercased()
        return completions.filter { $0.lowercased().hasPrefix(wordLower) && $0.lowercased() != wordLower }
    }

    func control(_ control: NSControl, textView: NSTextView, completions words: [String],
                 forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>)
        -> [String] {
        index.pointee = -1

        guard config.words.dropdown else {
            return []
        }

        return matchingCompletions(textView)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onSendMessage()
            return true

        case #selector(NSResponder.insertTab(_:)):
            return onTabComplete(textView, backwards: false)

        case #selector(NSResponder.insertBacktab(_:)):
            return onTabComplete(textView, backwards: true)

        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.scrollPageDown(_:)),
             #selector(NSResponder.pageDown(_:)):
            // Scroll chat view to bottom, and keep input focus in entry
            guard !isSelectingCompletion else {
                return false
            }
            chatView?.scrollBottom()
            return true

        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            // Move up into view to begin scrolling message history
            guard !isSelectingCompletion else {
                return false
            }
            chatView?.grabFocus()
            return true

        default:
            return false
        }
    }

    /// Tab and Shift+Tab: tab complete chat.
    private func onTabComplete(_ textView: NSTextView, backwards: Bool) -> Bool {
        guard config.words.tab else {
            return false
        }

        let text = textView.string as NSString

        guard text.length > 0 else {
            return false
        }

        let position = textView.selectedRange().location
        let lastWord = text.substring(to: position).components(separatedBy: " ").last ?? ""
        let lastWordLength = (lastWord as NSString).length
        let wordStart = position - lastWordLength
        var currentWord = lastWord

        if !isMidwayCompletion {
            guard lastWordLength >= 1 else {
                return false
            }

            let lastWordLower = lastWord.lowercased()
            currentCompletions = completions.filter {
                $0.lowercased().hasPrefix(lastWordLower) && $0.count >= lastWord.count
            }

            if !currentCompletions.isEmpty {
                isMidwayCompletion = true
                completionIndex = -1
            }
        } else {
            currentWord = currentCompletions[completionIndex]
        }

        if isMidwayCompletion {
            // We're still completing, avoid resetting the completion state
            isInsertingCompletion = true

            let currentWordLength = (currentWord as NSString).length
            let direction = backwards ? -1 : 1
            completionIndex = (completionIndex + direction + currentCompletions.count) % currentCompletions.count

            let newWord = currentCompletions[completionIndex]
            let replaceRange = NSRange(location: position - currentWordLength, length: currentWordLength)

            textView.insertText(newWord, replacementRange: replaceRange)
            textView.setSelectedRange(NSRange(location: wordStart + (newWord as NSString).length, length: 0))
            isInsertingCompletion = false
        }

        return true
    }
}
