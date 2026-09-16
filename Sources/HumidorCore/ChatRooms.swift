// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct ShowRoom {
    public var room: String
    public var isPrivate: Bool
    public var switchPage: Bool
    public var remembered: Bool
}

public extension EventName where Payload == ShowRoom {
    static var showRoom: Self { .init("show-room") }
}

public extension EventName where Payload == String {
    static var removeRoom: Self { .init("remove-room") }
    static var clearRoomMessages: Self { .init("clear-room-messages") }
}

/// A chat message received in a room, or in the public room feed.
protocol ChatRoomMessage: AnyObject {
    var room: String { get }
    var user: String { get }
    var message: String { get set }
    var formattedMessage: String? { get set }
    var chatMessageType: String? { get set }
    var isIgnored: Bool { get set }
}

extension SayChatroom: ChatRoomMessage {}
extension GlobalRoomMessage: ChatRoomMessage {}

public final class JoinedRoom {
    public let name: String
    public var isPrivate: Bool
    public var users = Set<String>()
    public var tickers = OrderedDictionary<String, String>()

    init(name: String, isPrivate: Bool = false) {
        self.name = name
        self.isPrivate = isPrivate
    }
}

public final class PrivateRoom {
    public let name: String
    public var owner: String?
    public var members = Set<String>()
    public var operators = Set<String>()

    init(name: String) {
        self.name = name
    }
}

@MainActor
public final class ChatRooms {

    /// Trailing spaces to avoid conflict with regular rooms
    public static let globalRoomName = "Public "
    public static let roomNameMaxLength = 24

    public private(set) var completions = Set<String>()
    public private(set) var serverRooms = Set<String>()
    public private(set) var joinedRooms = OrderedDictionary<String, JoinedRoom>()
    public private(set) var privateRooms: [String: PrivateRoom] = [:]

    init() {
        events.connect(.globalRoomMessage) { [self] msg in sayChatRoom(msg, isGlobal: true) }
        events.connect(.joinRoom) { [self] msg in joinRoom(msg) }
        events.connect(.leaveRoom) { [self] msg in leaveRoom(msg) }
        events.connect(.privateRoomAddOperator) { [self] msg in privateRooms[msg.room]?.operators.insert(msg.user) }
        events.connect(.privateRoomAddUser) { [self] msg in privateRooms[msg.room]?.members.insert(msg.user) }
        events.connect(.privateRoomAdded) { [self] msg in privateRoomAdded(msg) }
        events.connect(.privateRoomOperatorAdded) { [self] msg in
            if let loginUsername = core.users.loginUsername {
                privateRooms[msg.room]?.operators.insert(loginUsername)
            }
        }
        events.connect(.privateRoomOperatorRemoved) { [self] msg in
            if let loginUsername = core.users.loginUsername {
                privateRooms[msg.room]?.operators.remove(loginUsername)
            }
        }
        events.connect(.privateRoomOperators) { [self] msg in updatePrivateRoom(msg.room, operators: msg.operators) }
        events.connect(.privateRoomRemoveOperator) { [self] msg in privateRooms[msg.room]?.operators.remove(msg.user) }
        events.connect(.privateRoomRemoveUser) { [self] msg in privateRooms[msg.room]?.members.remove(msg.user) }
        events.connect(.privateRoomRemoved) { [self] msg in privateRooms.removeValue(forKey: msg.room) }
        events.connect(.privateRoomToggle) { msg in config.server.privateChatrooms = msg.enabled }
        events.connect(.privateRoomUsers) { [self] msg in updatePrivateRoom(msg.room, members: msg.users) }
        events.connect(.quit) { [self] in
            removeAllRooms(isPermanent: false)
            completions.removeAll()
        }
        events.connect(.roomList) { [self] msg in roomList(msg) }
        events.connect(.sayChatRoom) { [self] msg in sayChatRoom(msg) }
        events.connect(.serverLogin) { [self] msg in serverLogin(msg) }
        events.connect(.serverDisconnect) { [self] _ in serverDisconnect() }
        events.connect(.start) { [self] in start() }
        events.connect(.tickerAdd) { [self] msg in tickerAdd(msg) }
        events.connect(.tickerRemove) { [self] msg in tickerRemove(msg) }
        events.connect(.tickerState) { [self] msg in tickerState(msg) }
        events.connect(.userJoinedRoom) { [self] msg in userJoinedRoom(msg) }
        events.connect(.userLeftRoom) { [self] msg in userLeftRoom(msg) }
    }

    private func start() {
        for room in config.server.autoJoin {
            showRoom(room, isPrivate: privateRooms[room] != nil, switchPage: false, remembered: true)
        }
    }

    private func serverLogin(_ msg: Login) {
        guard msg.success else {
            return
        }

        // Request a complete room list. A limited room list not including blacklisted rooms and
        // rooms with few users is automatically sent when logging in, but subsequent room list
        // requests contain all rooms.
        requestRoomList()

        requestPrivateRoomToggle(config.server.privateChatrooms)

        for room in joinedRooms.keys {
            if room == Self.globalRoomName {
                core.sendMessageToServer(JoinGlobalRoom())
            } else {
                core.sendMessageToServer(JoinRoom(room: room))
            }
        }
    }

    private func serverDisconnect() {
        for room in joinedRooms.values {
            room.tickers.removeAll()
            room.users.removeAll()
        }

        serverRooms.removeAll()
        privateRooms.removeAll()
        updateCompletions()
    }

    public func showRoom(_ room: String, isPrivate: Bool = false, switchPage: Bool = true, remembered: Bool = false) {
        let joinedRoom: JoinedRoom

        if let existing = joinedRooms[room] {
            joinedRoom = existing
        } else {
            joinedRoom = JoinedRoom(name: room, isPrivate: isPrivate)
            joinedRooms[room] = joinedRoom

            if !config.server.autoJoin.contains(room) {
                if room == Self.globalRoomName {
                    config.server.autoJoin.insert(room, at: 0)
                } else {
                    // Inserted before the last item
                    config.server.autoJoin.insert(room, at: Swift.max(config.server.autoJoin.count - 1, 0))
                }
            }
        }

        if joinedRoom.users.isEmpty {
            if room == Self.globalRoomName {
                core.sendMessageToServer(JoinGlobalRoom())
            } else {
                core.sendMessageToServer(JoinRoom(room: room, isPrivate: isPrivate))
            }
        }

        events.emit(.showRoom, ShowRoom(room: room, isPrivate: isPrivate, switchPage: switchPage, remembered: remembered))
    }

    public func removeRoom(_ room: String, isPermanent: Bool = true) {
        guard let joinedRoom = joinedRooms.removeValue(forKey: room) else {
            return
        }

        if room == Self.globalRoomName {
            core.sendMessageToServer(LeaveGlobalRoom())
        } else {
            core.sendMessageToServer(LeaveRoom(room: room))
        }

        for username in joinedRoom.users {
            core.users.unwatchUser(username, context: "chatrooms_\(room)")
        }

        if isPermanent {
            if case var .object(roomColumns) = config.columns["chat_room"], roomColumns[room] != nil {
                roomColumns.removeValue(forKey: room)
                config.columns["chat_room"] = .object(roomColumns)
            }

            config.server.autoJoin.removeAll { $0 == room }
        }

        events.emit(.removeRoom, room)
    }

    public func removeAllRooms(isPermanent: Bool = true) {
        for room in joinedRooms.keys {
            removeRoom(room, isPermanent: isPermanent)
        }
    }

    /// Sanitizes a room name according to server requirements.
    public static func sanitizeRoomName(_ room: String) -> String {
        // Replace non-ASCII characters
        let ascii = String(room.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map {
            $0.isASCII ? Character($0) : "?"
        })

        // Remove two or more consecutive spaces
        let collapsed = ascii.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        // Limit to 24 characters
        return String(collapsed.prefix(roomNameMaxLength))
    }

    public func clearRoomMessages(_ room: String) {
        events.emit(.clearRoomMessages, room)
    }

    public func echoMessage(_ room: String, _ message: String, messageType: String = "local") {
        events.emit(.echoRoomMessage, EchoMessage(target: room, message: message, messageType: messageType))
    }

    public func sendMessage(_ room: String, _ message: String) {
        guard joinedRooms[room] != nil else {
            return
        }

        var room = room
        var message = message

        if let pluginHandler = core.pluginHandler {
            guard let event = pluginHandler.outgoingPublicChatEvent(room: room, line: message) else {
                return
            }

            (room, message) = event
        }

        if config.words.replaceWords {
            for (word, replacement) in config.words.autoReplaced {
                message = message.replacingOccurrences(of: word, with: replacement)
            }
        }

        core.sendMessageToServer(SayChatroom(room: room, message: message))
        core.pluginHandler?.outgoingPublicChatNotification(room: room, line: message)
    }

    public func addUserToPrivateRoom(_ room: String, username: String) {
        core.sendMessageToServer(PrivateRoomAddUser(room: room, user: username))
    }

    public func addOperatorToPrivateRoom(_ room: String, username: String) {
        core.sendMessageToServer(PrivateRoomAddOperator(room: room, user: username))
    }

    public func removeUserFromPrivateRoom(_ room: String, username: String) {
        core.sendMessageToServer(PrivateRoomRemoveUser(room: room, user: username))
    }

    public func removeOperatorFromPrivateRoom(_ room: String, username: String) {
        core.sendMessageToServer(PrivateRoomRemoveOperator(room: room, user: username))
    }

    public func isPrivateRoomOwned(_ room: String) -> Bool {
        guard let privateRoom = privateRooms[room] else {
            return false
        }
        return privateRoom.owner != nil && privateRoom.owner == core.users.loginUsername
    }

    public func isPrivateRoomMember(_ room: String) -> Bool {
        privateRooms[room] != nil
    }

    public func isPrivateRoomOperator(_ room: String) -> Bool {
        guard let privateRoom = privateRooms[room], let loginUsername = core.users.loginUsername else {
            return false
        }
        return privateRoom.operators.contains(loginUsername)
    }

    public func requestRoomList() {
        core.sendMessageToServer(RoomList())
    }

    public func requestPrivateRoomDisown(_ room: String) {
        guard isPrivateRoomOwned(room) else {
            return
        }

        core.sendMessageToServer(PrivateRoomDisown(room: room))
        privateRooms.removeValue(forKey: room)
    }

    public func requestPrivateRoomCancelMembership(_ room: String) {
        guard isPrivateRoomMember(room) else {
            return
        }

        core.sendMessageToServer(PrivateRoomCancelMembership(room: room))
        privateRooms.removeValue(forKey: room)
    }

    public func requestPrivateRoomToggle(_ enabled: Bool) {
        core.sendMessageToServer(PrivateRoomToggle(enabled: enabled))
    }

    public func requestUpdateTicker(_ room: String, message: String) {
        core.sendMessageToServer(RoomTickerSet(room: room, message: message))
    }

    private func updateRoomUser(_ joinedRoom: JoinedRoom, _ userData: inout UserData) {
        let username = userData.username
        joinedRoom.users.insert(username)
        core.users.watchUser(username, context: "chatrooms_\(joinedRoom.name)", isImplicit: true)

        if let watchedUser = core.users.watched[username] {
            watchedUser.uploadSpeed = userData.avgSpeed
            watchedUser.files = userData.files
            watchedUser.folders = userData.dirs
        }

        core.users.statuses[username] = userData.status.flatMap(UserStatus.init(rawValue:)) ?? .offline

        // Request user's IP address, so we can get the country and ignore messages by IP
        if core.users.addresses[username] == nil {
            core.users.requestIPAddress(username)
        }

        // Replace server-provided country with our own
        if let country = core.users.countries[username] {
            userData.country = country
        }
    }

    private func updatePrivateRoom(_ room: String, owner: String? = nil, members: [String]? = nil,
                                   operators: [String]? = nil) {
        let privateRoom = privateRooms[room] ?? PrivateRoom(name: room)
        privateRooms[room] = privateRoom

        if let owner, !owner.isEmpty {
            privateRoom.owner = owner
        }

        if let members {
            privateRoom.members.formUnion(members)
        }

        if let operators {
            privateRoom.operators.formUnion(operators)
        }
    }

    /// Server code 14.
    private func joinRoom(_ msg: JoinRoom) {
        guard let joinedRoom = joinedRooms[msg.room] else {
            // Reject unsolicited room join messages from the server
            core.sendMessageToServer(LeaveRoom(room: msg.room))
            return
        }

        joinedRoom.isPrivate = msg.isPrivate
        serverRooms.insert(msg.room)

        if msg.isPrivate {
            updatePrivateRoom(msg.room, owner: msg.owner, operators: msg.operators)
        }

        for index in msg.users.indices {
            updateRoomUser(joinedRoom, &msg.users[index])
        }

        core.pluginHandler?.joinChatroomNotification(msg.room)
    }

    /// Server code 15.
    private func leaveRoom(_ msg: LeaveRoom) {
        if let joinedRoom = joinedRooms[msg.room] {
            for username in joinedRoom.users {
                core.users.unwatchUser(username, context: "chatrooms_\(msg.room)")
            }

            joinedRoom.users.removeAll()
        }

        core.pluginHandler?.leaveChatroomNotification(msg.room)
    }

    /// Server code 139.
    private func privateRoomAdded(_ msg: PrivateRoomAdded) {
        guard privateRooms[msg.room] == nil else {
            return
        }

        updatePrivateRoom(msg.room)

        if joinedRooms[msg.room] != nil {
            // Room tab previously opened, join room now
            showRoom(msg.room, isPrivate: true, switchPage: false)
        }

        log.add(String(localized: "You have been added to a private room: \(msg.room)", bundle: .module))
    }

    /// Server code 64.
    private func roomList(_ msg: RoomList) {
        for room in msg.rooms {
            serverRooms.insert(room.name)
        }

        for room in msg.ownedPrivateRooms {
            updatePrivateRoom(room.name, owner: core.users.loginUsername)
        }

        for room in msg.otherPrivateRooms {
            updatePrivateRoom(room.name)
        }

        if config.words.roomNames {
            updateCompletions()
            core.privateChat.updateCompletions()
        }
    }

    public func messageType(user: String, text: String) -> String {
        if text.hasPrefix("/me ") {
            return "action"
        }

        if user == core.users.loginUsername {
            return "local"
        }

        if let loginUsername = core.users.loginUsername,
           findWholeWord(loginUsername.lowercased(), in: text.lowercased()) != nil {
            return "hilite"
        }

        return "remote"
    }

    /// Server codes 13 and 152.
    private func sayChatRoom(_ msg: ChatRoomMessage, isGlobal: Bool = false) {
        var room = msg.room
        let username = msg.user

        if !isGlobal {
            guard joinedRooms[room] != nil else {
                msg.isIgnored = true
                return
            }

            log.addChat(String(localized: "Chat message from user '\(username)' in room '\(room)': \(msg.message)",
                               bundle: .module))

            if username != "server" {
                if core.networkFilter.isUserIgnored(username) || core.networkFilter.isUserIPIgnored(username: username) {
                    msg.isIgnored = true
                    return
                }
            }

            if let pluginHandler = core.pluginHandler {
                guard let event = pluginHandler.incomingPublicChatEvent(room: room, user: username,
                                                                        line: msg.message) else {
                    msg.isIgnored = true
                    return
                }

                msg.message = event.line
            }
        } else {
            room = Self.globalRoomName
        }

        var message = msg.message
        msg.chatMessageType = messageType(user: username, text: message)
        let isActionMessage = msg.chatMessageType == "action"

        if isActionMessage, let range = message.range(of: "/me ") {
            message.replaceSubrange(range, with: "")
        }

        if config.words.censorWords && username != core.users.loginUsername {
            message = censorText(message, patterns: config.words.censored)
        }

        var formattedMessage: String

        if isActionMessage {
            msg.message = "* \(username) \(message)"
            formattedMessage = msg.message
        } else {
            formattedMessage = "[\(username)] \(message)"
        }

        if isGlobal {
            formattedMessage = "\(msg.room) | \(formattedMessage)"
        }

        msg.formattedMessage = formattedMessage

        if config.logging.chatrooms || config.logging.rooms.contains(room), let folderPath = log.roomFolderPath {
            log.writeLogFile(folderPath: folderPath, basename: room, text: formattedMessage)
        }

        if isGlobal {
            core.pluginHandler?.publicRoomMessageNotification(room: msg.room, user: username, line: msg.message)
        } else {
            core.pluginHandler?.incomingPublicChatNotification(room: room, user: username, line: msg.message)
        }
    }

    /// Server code 16.
    private func userJoinedRoom(_ msg: UserJoinedRoom) {
        guard let joinedRoom = joinedRooms[msg.room] else {
            msg.isIgnored = true
            return
        }

        updateRoomUser(joinedRoom, &msg.userData)
        core.pluginHandler?.userJoinChatroomNotification(room: msg.room, user: msg.userData.username)
    }

    /// Server code 17.
    private func userLeftRoom(_ msg: UserLeftRoom) {
        guard let joinedRoom = joinedRooms[msg.room] else {
            msg.isIgnored = true
            return
        }

        let username = msg.username
        joinedRoom.users.remove(username)
        core.users.unwatchUser(username, context: "chatrooms_\(msg.room)")

        core.pluginHandler?.userLeaveChatroomNotification(room: msg.room, user: username)
    }

    private func isUserFiltered(_ username: String) -> Bool {
        core.networkFilter.isUserIgnored(username) || core.networkFilter.isUserIPIgnored(username: username)
    }

    /// Server code 113.
    private func tickerState(_ msg: RoomTickerState) {
        guard let joinedRoom = joinedRooms[msg.room] else {
            msg.isIgnored = true
            return
        }

        joinedRoom.tickers.removeAll()

        for ticker in msg.messages where !isUserFiltered(ticker.user) {
            joinedRoom.tickers[ticker.user] = ticker.message
        }
    }

    /// Server code 114.
    private func tickerAdd(_ msg: RoomTickerAdd) {
        guard let joinedRoom = joinedRooms[msg.room] else {
            msg.isIgnored = true
            return
        }

        guard !isUserFiltered(msg.user) else {
            // User ignored, ignore ticker messages
            return
        }

        joinedRoom.tickers[msg.user] = msg.message
    }

    /// Server code 115.
    private func tickerRemove(_ msg: RoomTickerRemove) {
        guard let joinedRoom = joinedRooms[msg.room] else {
            msg.isIgnored = true
            return
        }

        joinedRoom.tickers.removeValue(forKey: msg.user)
    }

    public func updateCompletions() {
        completions.removeAll()
        completions.insert(config.server.login)

        if config.words.roomNames {
            completions.formUnion(serverRooms)
        }

        if config.words.buddies {
            completions.formUnion(core.buddies.users.keys)
        }

        if config.words.commands, let pluginHandler = core.pluginHandler {
            completions.formUnion(pluginHandler.commandList(for: .chatroom))
        }

        events.emit(.roomCompletions, completions)
    }
}
