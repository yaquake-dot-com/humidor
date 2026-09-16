// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct PrivateChatShowUser {
    public var username: String
    public var switchPage: Bool
    public var remembered: Bool
}

/// A local message shown in a chat view, but not sent to others.
public struct EchoMessage {
    public var target: String
    public var message: String
    /// "local", "remote", "action", "hilite" or "command"
    public var messageType: String
}

public extension EventName where Payload == String {
    static var privateChatRemoveUser: Self { .init("private-chat-remove-user") }
    static var clearPrivateMessages: Self { .init("clear-private-messages") }
}

public extension EventName where Payload == PrivateChatShowUser {
    static var privateChatShowUser: Self { .init("private-chat-show-user") }
}

public extension EventName where Payload == EchoMessage {
    static var echoPrivateMessage: Self { .init("echo-private-message") }
    static var echoRoomMessage: Self { .init("echo-room-message") }
}

public extension EventName where Payload == Set<String> {
    static var privateChatCompletions: Self { .init("private-chat-completions") }
    static var roomCompletions: Self { .init("room-completions") }
}

@MainActor
public final class PrivateChat {

    public static let ctcpVersion = "\u{01}VERSION\u{01}"

    public private(set) var completions = Set<String>()
    private var privateMessageQueue: [String: [MessageUser]] = [:]
    private var awayMessageUsers = Set<String>()
    public private(set) var users = Set<String>()

    init() {
        events.connect(.messageUser) { [self] msg in messageUser(msg) }
        events.connect(.peerAddress) { [self] msg in getPeerAddress(msg) }
        events.connect(.quit) { [self] in
            removeAllUsers(isPermanent: false)
            completions.removeAll()
        }
        events.connect(.serverLogin) { [self] msg in serverLogin(msg) }
        events.connect(.serverDisconnect) { [self] _ in serverDisconnect() }
        events.connect(.start) { [self] in start() }
        events.connect(.userStatus) { [self] msg in userStatus(msg) }
    }

    private func start() {
        guard config.privateChat.store else {
            // Clear list of previously open chats if we don't want to restore them
            config.privateChat.users.removeAll()
            return
        }

        for username in config.privateChat.users where !users.contains(username) {
            showUser(username, switchPage: false, remembered: true)
        }

        updateCompletions()
    }

    private func serverLogin(_ msg: Login) {
        guard msg.success else {
            return
        }

        for username in users {
            core.users.watchUser(username, context: "privatechat")  // Get notified of user status
        }
    }

    private func serverDisconnect() {
        privateMessageQueue.removeAll()
        awayMessageUsers.removeAll()
        updateCompletions()
    }

    public func addUser(_ username: String) {
        guard !users.contains(username) else {
            return
        }

        users.insert(username)

        if !config.privateChat.users.contains(username) {
            config.privateChat.users.insert(username, at: 0)
        }
    }

    public func removeUser(_ username: String, isPermanent: Bool = true) {
        if isPermanent {
            config.privateChat.users.removeAll { $0 == username }
        }

        users.remove(username)
        core.users.unwatchUser(username, context: "privatechat")
        events.emit(.privateChatRemoveUser, username)
    }

    public func removeAllUsers(isPermanent: Bool = true) {
        for username in users {
            removeUser(username, isPermanent: isPermanent)
        }
    }

    public func showUser(_ username: String, switchPage: Bool = true, remembered: Bool = false) {
        addUser(username)
        events.emit(.privateChatShowUser, PrivateChatShowUser(username: username, switchPage: switchPage,
                                                              remembered: remembered))
        core.users.watchUser(username, context: "privatechat")
    }

    public func clearPrivateMessages(_ username: String) {
        events.emit(.clearPrivateMessages, username)
    }

    /// Queues a private message until we've received a user's IP address.
    private func privateMessageQueueAdd(_ msg: MessageUser) {
        privateMessageQueue[msg.user, default: []].append(msg)
    }

    public func sendAutomaticMessage(_ username: String, message: String) {
        sendMessage(username, "[Automatic Message] \(message)")
    }

    public func echoMessage(_ username: String, _ message: String, messageType: String = "local") {
        events.emit(.echoPrivateMessage, EchoMessage(target: username, message: message, messageType: messageType))
    }

    public func sendMessage(_ username: String, _ message: String) {
        var username = username
        var message = message

        if let pluginHandler = core.pluginHandler {
            guard let userText = pluginHandler.outgoingPrivateChatEvent(user: username, line: message) else {
                return
            }

            (username, message) = userText
        }

        if config.words.replaceWords && message != Self.ctcpVersion {
            for (word, replacement) in config.words.autoReplaced {
                message = message.replacingOccurrences(of: word, with: replacement)
            }
        }

        core.sendMessageToServer(MessageUser(user: username, message: message))
        core.pluginHandler?.outgoingPrivateChatNotification(user: username, line: message)

        events.emit(.messageUser, MessageUser(user: username, message: message))
    }

    public func sendMessageUsers(target: String, message: String) {
        guard !message.isEmpty else {
            return
        }

        var users: Set<String>?

        if target == "buddies" {
            users = Set(core.buddies.users.keys)
        } else if target == "downloading" {
            users = core.uploads.downloadingUsers()
        }

        if let users, !users.isEmpty {
            core.sendMessageToServer(MessageUsers(users: Array(users), message: message))
        }
    }

    /// Server code 3.
    ///
    /// Received a user's IP address, process any queued private messages and
    /// check if the IP is ignored.
    private func getPeerAddress(_ msg: GetPeerAddress) {
        let username = msg.user

        guard let queuedMessages = privateMessageQueue.removeValue(forKey: username) else {
            return
        }

        for queuedMessage in queuedMessages {
            queuedMessage.user = username
            queuedMessage.isIgnored = false
            queuedMessage.isQueuedMessage = true
            events.emit(.messageUser, queuedMessage)
        }
    }

    /// Server code 7.
    private func userStatus(_ msg: GetUserStatus) {
        if msg.user == core.users.loginUsername && msg.status != UserStatus.away.rawValue {
            // Reset list of users we've sent away messages to when the away session ends
            awayMessageUsers.removeAll()
        }

        if msg.status == UserStatus.offline.rawValue {
            privateMessageQueue.removeValue(forKey: msg.user)
        }
    }

    public func messageType(_ text: String, isOutgoingMessage: Bool) -> String {
        if text.hasPrefix("/me ") {
            return "action"
        }

        if isOutgoingMessage {
            return "local"
        }

        if let loginUsername = core.users.loginUsername,
           findWholeWord(loginUsername.lowercased(), in: text.lowercased()) != nil {
            return "hilite"
        }

        return "remote"
    }

    /// Server code 22.
    private func messageUser(_ msg: MessageUser) {
        let isOutgoingMessage = msg.messageID == nil
        let isQueuedMessage = msg.isQueuedMessage

        let username = msg.user
        let tagUsername = isOutgoingMessage ? (core.users.loginUsername ?? "") : username
        var message = msg.message
        let timestamp = msg.isNewMessage ? nil : Date(timeIntervalSince1970: TimeInterval(msg.timestamp))

        if !isOutgoingMessage {
            if !isQueuedMessage {
                log.addChat(String(localized: "Private message from user '\(username)': \(message)", bundle: .module))

                if let messageID = msg.messageID {
                    core.sendMessageToServer(MessageAcked(messageID: messageID))
                }
            }

            if username == "server" {
                let startString = "The room you are trying to enter ("

                if message.hasPrefix(startString), let endRange = message.range(of: ") ", options: .backwards),
                   endRange.lowerBound >= message.index(message.startIndex, offsetBy: startString.count) {
                    // Redirect message to chat room tab if join wasn't successful
                    msg.isIgnored = true

                    let room = String(message[message.index(message.startIndex, offsetBy: startString.count)
                                              ..< endRange.lowerBound])
                    events.emit(.sayChatRoom, SayChatroom(room: room, message: message, user: username))
                    return
                }
            } else {
                // Check ignore status for all other users except "server"
                if core.networkFilter.isUserIgnored(username) {
                    msg.isIgnored = true
                    return
                }

                if core.users.addresses[username] != nil {
                    if core.networkFilter.isUserIPIgnored(username: username) {
                        msg.isIgnored = true
                        return
                    }

                } else if !isQueuedMessage {
                    // Ask for user's IP address and queue the private message until we receive the address
                    if privateMessageQueue[username] == nil {
                        core.users.requestIPAddress(username)
                    }

                    privateMessageQueueAdd(msg)
                    msg.isIgnored = true
                    return
                }
            }

            if let pluginHandler = core.pluginHandler {
                guard let userText = pluginHandler.incomingPrivateChatEvent(user: username, line: message) else {
                    msg.isIgnored = true
                    return
                }

                msg.message = userText.line
            }

            showUser(username, switchPage: false)
            message = msg.message
        }

        msg.chatMessageType = messageType(message, isOutgoingMessage: isOutgoingMessage)
        let isActionMessage = msg.chatMessageType == "action"
        let isCTCPVersion = message == Self.ctcpVersion

        // Send client version to user if the following string is sent
        if isCTCPVersion {
            message = "CTCP VERSION"
            msg.message = message
        }

        if isActionMessage, let range = message.range(of: "/me ") {
            message.replaceSubrange(range, with: "")
        }

        if !isOutgoingMessage && config.words.censorWords {
            message = censorText(message, patterns: config.words.censored)
        }

        if isActionMessage {
            msg.message = "* \(tagUsername) \(message)"
            msg.formattedMessage = msg.message
        } else {
            msg.formattedMessage = "[\(tagUsername)] \(message)"
        }

        if config.logging.privateChat || config.logging.privateChats.contains(username),
           let folderPath = log.privateChatFolderPath, let formattedMessage = msg.formattedMessage {
            log.writeLogFile(folderPath: folderPath, basename: username, text: formattedMessage, timestamp: timestamp)
        }

        if isOutgoingMessage {
            return
        }

        core.pluginHandler?.incomingPrivateChatNotification(user: username, line: msg.message)

        if isCTCPVersion && !config.server.ctcpMessages {
            sendMessage(username, "\(Application.name) \(Application.version)")
        }

        guard msg.isNewMessage else {
            // Message was sent while offline, don't auto-reply
            return
        }

        let autoReply = config.server.autoReply

        if !autoReply.isEmpty && core.users.loginStatus == .away && !awayMessageUsers.contains(username) {
            sendAutomaticMessage(username, message: autoReply)
            awayMessageUsers.insert(username)
        }
    }

    public func updateCompletions() {
        completions.removeAll()
        completions.insert(config.server.login)

        if config.words.roomNames {
            completions.formUnion(core.chatrooms.serverRooms)
        }

        if config.words.buddies {
            completions.formUnion(core.buddies.users.keys)
        }

        if config.words.commands, let pluginHandler = core.pluginHandler {
            completions.formUnion(pluginHandler.commandList(for: .privateChat))
        }

        events.emit(.privateChatCompletions, completions)
    }
}
