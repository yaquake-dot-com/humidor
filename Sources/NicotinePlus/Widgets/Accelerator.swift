// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// A keyboard shortcut handled by a specific view.
///
/// The handler returns true if the key press was handled, false to let the
/// view process it normally.
@MainActor
struct Accelerator {

    enum Key: Equatable {
        case character(String)
        case `return`
        case delete
        case backspace
        case escape
        case tab
        case up
        case down
        case left
        case right
        case pageUp
        case pageDown
        case home
        case end
        case function(Int)
    }

    let key: Key
    let modifiers: NSEvent.ModifierFlags
    let handler: @MainActor () -> Bool

    init(_ key: Key, modifiers: NSEvent.ModifierFlags = [], handler: @escaping @MainActor () -> Bool) {
        self.key = key
        self.modifiers = modifiers
        self.handler = handler
    }

    private static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    func matches(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(Self.relevantModifiers) == modifiers else {
            return false
        }
        return Self.key(for: event) == key
    }

    static func key(for event: NSEvent) -> Key? {
        switch Int(event.keyCode) {
        case 36, 76: return .return
        case 117: return .delete
        case 51: return .backspace
        case 53: return .escape
        case 48: return .tab
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 116: return .pageUp
        case 121: return .pageDown
        case 115: return .home
        case 119: return .end
        case 122: return .function(1)
        case 120: return .function(2)
        case 99: return .function(3)
        case 118: return .function(4)
        case 96: return .function(5)
        case 97: return .function(6)
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else {
                return nil
            }
            return .character(characters)
        }
    }

    /// Runs the first matching accelerator. Returns true if the event was handled.
    static func handle(_ event: NSEvent, accelerators: [Accelerator]) -> Bool {
        for accelerator in accelerators where accelerator.matches(event) {
            if accelerator.handler() {
                return true
            }
        }
        return false
    }
}
