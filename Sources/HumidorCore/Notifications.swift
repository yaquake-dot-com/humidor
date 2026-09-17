// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation

public struct NotificationMessage {
    /// Room, username or search token the notification is associated with
    public var target: String?
    public var message: String
    public var title: String?
    public var highPriority = false
}

public extension EventName where Payload == NotificationMessage {
    static var showNotification: Self { .init("show-notification") }
    static var showChatroomNotification: Self { .init("show-chatroom-notification") }
    static var showDownloadNotification: Self { .init("show-download-notification") }
    static var showPrivateChatNotification: Self { .init("show-private-chat-notification") }
    static var showSearchNotification: Self { .init("show-search-notification") }
}

@MainActor
public final class Notifications {

    /// Speaks messages one after another
    private let speechSynthesizer = AVSpeechSynthesizer()

    init() {
        events.connect(.quit) { [self] in speechSynthesizer.stopSpeaking(at: .immediate) }
    }

    // MARK: Notification Messages

    public func showNotification(_ message: String, title: String? = nil) {
        events.emit(.showNotification, NotificationMessage(message: message, title: title))
    }

    public func showChatroomNotification(room: String, message: String, title: String? = nil,
                                         highPriority: Bool = false) {
        events.emit(.showChatroomNotification, NotificationMessage(target: room, message: message, title: title,
                                                                   highPriority: highPriority))
    }

    public func showDownloadNotification(_ message: String, title: String? = nil, highPriority: Bool = false) {
        events.emit(.showDownloadNotification, NotificationMessage(message: message, title: title,
                                                                   highPriority: highPriority))
    }

    public func showPrivateChatNotification(username: String, message: String, title: String? = nil) {
        events.emit(.showPrivateChatNotification, NotificationMessage(target: username, message: message, title: title))
    }

    public func showSearchNotification(searchToken: Int, message: String, title: String? = nil) {
        events.emit(.showSearchNotification, NotificationMessage(target: String(searchToken), message: message,
                                                                 title: title))
    }

    // MARK: TTS

    /// Speaks a message with the system voice. Placeholders in the
    /// form "%(name)s" are replaced by the values in `args`.
    public func newTTS(_ message: String, args: [String: String] = [:]) {
        guard config.ui.speechEnabled else {
            return
        }

        var message = message

        for (key, value) in args {
            let cleanedValue = value
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "[", with: " ")
                .replacingOccurrences(of: "]", with: " ")
                .replacingOccurrences(of: "(", with: " ")
                .replacingOccurrences(of: ")", with: " ")

            message = message.replacingOccurrences(of: "%(\(key))s", with: cleanedValue)
        }

        speechSynthesizer.speak(AVSpeechUtterance(string: message))
    }
}
