// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

public class ServerMessage: SlskMessage, @unchecked Sendable {
    override public class var messageType: MessageType { .server }
}

/// Server code 1.
///
/// We send this to the server right after the connection has been
/// established. Server responds with the greeting message.
public final class Login: ServerMessage, @unchecked Sendable {
    public var username = ""
    public var password = ""
    public var version = 0
    public var minorVersion = 0
    public var success = false
    public var reason: String?
    public var banner: String?
    public var ipAddress: String?
    public var localAddress: PeerAddress?
    public var serverAddress: ServerAddress?
    public var isSupporter: Bool?

    override class var excludedAttributes: Set<String> { ["password"] }

    public convenience init(username: String, password: String, version: Int, minorVersion: Int) {
        self.init()
        self.username = username
        self.password = password
        self.version = version
        self.minorVersion = minorVersion
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(username)
        message.appendString(password)
        message.appendUInt32(version)

        let digest = Insecure.MD5.hash(data: Data((username + password).utf8))
        message.appendString(digest.map { String(format: "%02x", $0) }.joined())

        message.appendUInt32(minorVersion)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        success = try reader.readBool()

        if !success {
            reason = try reader.readString()
            return
        }

        banner = try reader.readString()
        ipAddress = try reader.readIPAddress()
        _ = try reader.readString()  // MD5 hexdigest of the password you sent
        isSupporter = try reader.readBool()
    }
}

/// Server code 2.
///
/// We send this to the server to indicate the port number that we listen on
/// (2234 by default).
public final class SetWaitPort: ServerMessage, @unchecked Sendable {
    public var port = 0

    public convenience init(port: Int) {
        self.init()
        self.port = port
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(port)
        return message
    }
}

/// Server code 3.
///
/// We send this to the server to ask for a peer's address (IP address and
/// port), given the peer's username.
public final class GetPeerAddress: ServerMessage, @unchecked Sendable {
    public var user = ""
    public var ipAddress = ""
    public var port = 0
    public var unknown = 0
    public var obfuscatedPort = 0

    public convenience init(user: String) {
        self.init()
        self.user = user
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(user)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        user = try reader.readString()
        ipAddress = try reader.readIPAddress()
        port = try reader.readUInt32()
        unknown = try reader.readUInt32()
        obfuscatedPort = try reader.readUInt16()
    }
}

/// Server code 5.
///
/// Used to be kept updated about a user's status. Whenever a user's status
/// changes, the server sends a GetUserStatus message.
///
/// Note that the server does not currently send stat updates (GetUserStats)
/// when watching a user, only the initial stats in the WatchUser response. As
/// a consequence, stats can be outdated.
public final class WatchUser: ServerMessage, @unchecked Sendable {
    public var user = ""
    public var userExists = false
    public var status: Int?
    public var avgSpeed: Int?
    public var uploadNum: Int?
    public var unknown: Int?
    public var files: Int?
    public var dirs: Int?
    public var country: String?
    public var containsStats = false

    public convenience init(user: String) {
        self.init()
        self.user = user
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(user)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        user = try reader.readString()
        userExists = try reader.readBool()

        guard reader.hasRemaining else {
            // User does not exist
            return
        }

        containsStats = true
        status = try reader.readUInt32()
        avgSpeed = try reader.readUInt32()
        uploadNum = try reader.readUInt32()
        unknown = try reader.readUInt32()
        files = try reader.readUInt32()
        dirs = try reader.readUInt32()

        guard reader.hasRemaining else {
            // User is offline
            return
        }

        country = try reader.readString()
    }
}

/// Server code 6.
///
/// Used when we no longer want to be kept updated about a user's status.
public final class UnwatchUser: ServerMessage, @unchecked Sendable {
    public var user = ""

    public convenience init(user: String) {
        self.init()
        self.user = user
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(user)
        return message
    }
}

/// Server code 7.
///
/// The server tells us if a user has gone away or has returned.
public final class GetUserStatus: ServerMessage, @unchecked Sendable {
    public var user = ""
    public var status = 0
    public var privileged: Bool?

    public convenience init(user: String) {
        self.init()
        self.user = user
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(user)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        user = try reader.readString()
        status = try reader.readUInt32()
        privileged = try reader.readBool()
    }
}

/// Server code 11.
///
/// We send this to the server to tell a user we have ignored them. The server
/// tells us a user has ignored us.
///
/// OBSOLETE, no longer used
public final class IgnoreUser: ServerMessage, @unchecked Sendable {
    public var user = ""

    public convenience init(user: String) {
        self.init()
        self.user = user
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(user)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        user = try reader.readString()
    }
}

/// Server code 12.
///
/// We send this to the server to tell a user we are no longer ignoring them.
/// The server tells us a user is no longer ignoring us.
///
/// OBSOLETE, no longer used
public final class UnignoreUser: ServerMessage, @unchecked Sendable {
    public var user = ""

    public convenience init(user: String) {
        self.init()
        self.user = user
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(user)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        user = try reader.readString()
    }
}

/// Server code 13.
///
/// Either we want to say something in the chatroom, or someone else did.
public final class SayChatroom: ServerMessage, @unchecked Sendable {
    public var room = ""
    public var message = ""
    public var user = ""
    public var formattedMessage: String?
    public var chatMessageType: String?

    public convenience init(room: String, message: String, user: String = "") {
        self.init()
        self.room = room
        self.message = message
        self.user = user
    }

    override func makeNetworkMessage() throws -> Data {
        var data = Data()
        data.appendString(room)
        data.appendString(message)
        return data
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
        user = try reader.readString()
        self.message = try reader.readString()
    }
}

/// Server code 14.
///
/// We send this message to the server when we want to join a room. If the
/// room doesn't exist, it is created.
///
/// Server responds with this message when we join a room. Contains users list
/// with data on everyone.
///
/// As long as we're in the room, the server will automatically send us
/// status/stat updates for room users, including ourselves, in the form of
/// GetUserStatus and GetUserStats messages.
///
/// Room names must meet certain requirements, otherwise the server will send a
/// MessageUser message containing an error message. Requirements include:
///
///   - Non-empty string
///   - Only ASCII characters
///   - 24 characters or fewer
///   - No leading or trailing spaces
///   - No consecutive spaces
public final class JoinRoom: ServerMessage, @unchecked Sendable {
    public var room = ""
    public var isPrivate = false
    public var owner: String?
    public var users: [UserData] = []
    public var operators: [String] = []

    public convenience init(room: String, isPrivate: Bool = false) {
        self.init()
        self.room = room
        self.isPrivate = isPrivate
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(room)
        message.appendUInt32(isPrivate ? 1 : 0)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
        users = try UsersMessage.parseUsers(&reader)

        if reader.hasRemaining {
            isPrivate = true
            owner = try reader.readString()
        }

        if reader.hasRemaining && isPrivate {
            let numOperators = try reader.readUInt32()

            for _ in 0..<numOperators {
                operators.append(try reader.readString())
            }
        }
    }
}

/// Server code 15.
///
/// We send this to the server when we want to leave a room.
public final class LeaveRoom: ServerMessage, @unchecked Sendable {
    public var room = ""

    public convenience init(room: String) {
        self.init()
        self.room = room
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(room)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
    }
}

/// Server code 16.
///
/// The server tells us someone has just joined a room we're in.
public final class UserJoinedRoom: ServerMessage, @unchecked Sendable {
    public var room = ""
    public var userData = UserData(username: "")

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()

        userData = UserData(username: try reader.readString())
        userData.status = try reader.readUInt32()
        userData.avgSpeed = try reader.readUInt32()
        userData.uploadNum = try reader.readUInt32()
        userData.unknown = try reader.readUInt32()
        userData.files = try reader.readUInt32()
        userData.dirs = try reader.readUInt32()
        userData.slotsFull = try reader.readUInt32()
        userData.country = try reader.readString()
    }
}

/// Server code 17.
///
/// The server tells us someone has just left a room we're in.
public final class UserLeftRoom: ServerMessage, @unchecked Sendable {
    public var room = ""
    public var username = ""

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
        username = try reader.readString()
    }
}

/// Server code 18.
///
/// We send this to the server to attempt an indirect connection with a user.
/// The server forwards the message to the user, who in turn attempts to
/// establish a connection to our IP address and port from their end.
public final class ConnectToPeer: ServerMessage, @unchecked Sendable {
    public var token = 0
    public var user = ""
    public var connType = ""
    public var ipAddress = ""
    public var port = 0
    public var privileged: Bool?
    public var unknown: Int?
    public var obfuscatedPort: Int?

    public convenience init(token: Int, user: String, connType: String) {
        self.init()
        self.token = token
        self.user = user
        self.connType = connType
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(token)
        message.appendString(user)
        message.appendString(connType)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        user = try reader.readString()
        connType = try reader.readString()
        ipAddress = try reader.readIPAddress()
        port = try reader.readUInt32()
        token = try reader.readUInt32()
        privileged = try reader.readBool()
        unknown = try reader.readUInt32()
        obfuscatedPort = try reader.readUInt32()
    }
}

/// Server code 22.
///
/// Chat phrase sent to someone or received by us in private.
public final class MessageUser: ServerMessage, @unchecked Sendable {
    public var user = ""
    public var message = ""
    /// Only present for received messages
    public var messageID: Int?
    public var timestamp = 0
    public var isNewMessage = true
    /// Set when the message was queued until the user's IP address was received
    public var isQueuedMessage = false
    public var formattedMessage: String?
    public var chatMessageType: String?

    public convenience init(user: String, message: String) {
        self.init()
        self.user = user
        self.message = message
    }

    override func makeNetworkMessage() throws -> Data {
        var data = Data()
        data.appendString(user)
        data.appendString(message)
        return data
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        messageID = try reader.readUInt32()
        timestamp = try reader.readUInt32()
        user = try reader.readString()
        self.message = try reader.readString()
        isNewMessage = try reader.readBool()
    }
}

/// Server code 23.
///
/// We send this to the server to confirm that we received a private message.
/// If we don't send it, the server will keep sending the chat phrase to us.
public final class MessageAcked: ServerMessage, @unchecked Sendable {
    public var messageID = 0

    public convenience init(messageID: Int) {
        self.init()
        self.messageID = messageID
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(messageID)
        return message
    }
}

/// Server code 25.
///
/// We send this to the server when we search for something in a room.
///
/// OBSOLETE, use RoomSearch server message
public final class FileSearchRoom: ServerMessage, @unchecked Sendable {
    public var token = 0
    public var roomID = 0
    public var searchTerm = ""

    public convenience init(token: Int, roomID: Int, text: String) {
        self.init()
        self.token = token
        self.roomID = roomID
        self.searchTerm = text
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(token)
        message.appendUInt32(roomID)
        message.appendString(searchTerm)
        return message
    }
}

/// Removes standalone "-" characters from a search query.
func sanitizedSearchTerm(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).filter { $0 != "-" }.joined(separator: " ")
}

/// Server code 26.
///
/// We send this to the server when we search for something. Alternatively, the
/// server sends this message outside the distributed network to tell us that
/// someone is searching for something, currently used for UserSearch and
/// RoomSearch requests.
///
/// The token is a number generated by the client and is used to track the
/// search results.
public final class FileSearch: ServerMessage, @unchecked Sendable {
    public var token = 0
    public var searchTerm = ""
    public var searchUsername = ""

    public convenience init(token: Int, text: String) {
        self.init()
        self.token = token
        self.searchTerm = sanitizedSearchTerm(text)
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(token)
        message.appendString(searchTerm, isLegacy: true)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        searchUsername = try reader.readString()
        token = try reader.readUInt32()
        searchTerm = try reader.readString()
    }
}

/// Server code 28.
///
/// We send our new status to the server. Status is a way to define whether
/// we're available (online) or busy (away).
///
/// When changing our own status, the server sends us a GetUserStatus message
/// when enabling away status, but not when disabling it.
///
/// 1 = Away 2 = Online
public final class SetStatus: ServerMessage, @unchecked Sendable {
    public var status = 0

    public convenience init(status: Int) {
        self.init()
        self.status = status
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendInt32(status)
        return message
    }
}

/// Server code 32.
///
/// We send this to the server at most once per minute to ensure the
/// connection stays alive.
///
/// The server used to send a response message in the past, but this is no
/// longer the case.
///
/// We use TCP keepalive instead of sending this message.
public final class ServerPing: ServerMessage, @unchecked Sendable {
    override func makeNetworkMessage() throws -> Data {
        Data()
    }

    override func parseNetworkMessage(_ message: Data) throws {
        // Obsolete
    }
}

/// Server code 33.
///
/// OBSOLETE, no longer used
public final class SendConnectToken: ServerMessage, @unchecked Sendable {
    public var user = ""
    public var token = 0

    public convenience init(user: String, token: Int) {
        self.init()
        self.user = user
        self.token = token
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(user)
        message.appendUInt32(token)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        user = try reader.readString()
        token = try reader.readUInt32()
    }
}

/// Server code 34.
///
/// We used to send this after a finished download to let the server update
/// the speed statistics for a user.
///
/// OBSOLETE, use SendUploadSpeed server message
public final class SendDownloadSpeed: ServerMessage, @unchecked Sendable {
    public var user = ""
    public var speed = 0

    public convenience init(user: String, speed: Int) {
        self.init()
        self.user = user
        self.speed = speed
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(user)
        message.appendUInt32(speed)
        return message
    }
}

/// Server code 35.
///
/// We send this to server to indicate the number of folder and files that we
/// share.
public final class SharedFoldersFiles: ServerMessage, @unchecked Sendable {
    public var folders = 0
    public var files = 0

    public convenience init(folders: Int, files: Int) {
        self.init()
        self.folders = folders
        self.files = files
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(folders)
        message.appendUInt32(files)
        return message
    }
}

/// Server code 36.
///
/// The server sends this to indicate a change in a user's statistics, if
/// we've requested to watch the user in WatchUser previously. A user's stats
/// can also be requested by sending a GetUserStats message to the server, but
/// WatchUser should be used instead.
public final class GetUserStats: ServerMessage, @unchecked Sendable {
    public var user = ""
    public var avgSpeed = 0
    public var uploadNum = 0
    public var unknown = 0
    public var files = 0
    public var dirs = 0

    public convenience init(user: String) {
        self.init()
        self.user = user
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(user)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        user = try reader.readString()
        avgSpeed = try reader.readUInt32()
        uploadNum = try reader.readUInt32()
        unknown = try reader.readUInt32()
        files = try reader.readUInt32()
        dirs = try reader.readUInt32()
    }
}

/// Server code 40.
///
/// The server sends this to indicate if someone has download slots available
/// or not.
///
/// OBSOLETE, no longer sent by the server
public final class QueuedDownloads: ServerMessage, @unchecked Sendable {
    public var user = ""
    public var slotsFull = 0

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        user = try reader.readString()
        slotsFull = try reader.readUInt32()
    }
}

/// Server code 41.
///
/// The server sends this if someone else logged in under our nickname, and
/// then disconnects us.
public final class Relogged: ServerMessage, @unchecked Sendable {
    override func parseNetworkMessage(_ message: Data) throws {
        // Empty message
    }
}

/// Server code 42.
///
/// We send this to the server when we search a specific user's shares. The
/// token is a number generated by the client and is used to track the search
/// results.
///
/// In the past, the server sent us this message for UserSearch requests from
/// other users. Today, the server sends a FileSearch message instead.
public final class UserSearch: ServerMessage, @unchecked Sendable {
    public var searchUsername = ""
    public var token = 0
    public var searchTerm = ""

    public convenience init(searchUsername: String, token: Int, text: String) {
        self.init()
        self.searchUsername = searchUsername
        self.token = token
        self.searchTerm = text
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(searchUsername)
        message.appendUInt32(token)
        message.appendString(searchTerm, isLegacy: true)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        // Obsolete
        var reader = MessageReader(message)
        searchUsername = try reader.readString()
        token = try reader.readUInt32()
        searchTerm = try reader.readString()
    }
}

/// Server code 50.
///
/// We send this to the server when we are adding a recommendation to our "My
/// recommendations" list, and want to receive a list of similar
/// recommendations.
///
/// The server sends a list of similar recommendations to the one we want to
/// add. Older versions of the official Soulseek client would display a dialog
/// containing such recommendations, asking us if we want to add our original
/// recommendation or one of the similar ones instead.
///
/// OBSOLETE
public final class SimilarRecommendations: ServerMessage, @unchecked Sendable {
    public var recommendation = ""
    public var similarRecommendations: [String] = []

    public convenience init(recommendation: String) {
        self.init()
        self.recommendation = recommendation
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(recommendation)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        recommendation = try reader.readString()
        let count = try reader.readUInt32()

        for _ in 0..<count {
            similarRecommendations.append(try reader.readString())
        }
    }
}

/// Server code 51.
///
/// We send this to the server when we add an item to our likes list.
///
/// DEPRECATED, used in Soulseek NS but not SoulseekQt
public final class AddThingILike: ServerMessage, @unchecked Sendable {
    public var thing = ""

    public convenience init(thing: String) {
        self.init()
        self.thing = thing
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(thing)
        return message
    }
}

/// Server code 52.
///
/// We send this to the server when we remove an item from our likes list.
///
/// DEPRECATED, used in Soulseek NS but not SoulseekQt
public final class RemoveThingILike: ServerMessage, @unchecked Sendable {
    public var thing = ""

    public convenience init(thing: String) {
        self.init()
        self.thing = thing
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(thing)
        return message
    }
}

/// Server code 54.
///
/// The server sends us a list of personal recommendations and a number for
/// each.
///
/// DEPRECATED, used in Soulseek NS but not SoulseekQt
public final class Recommendations: ServerMessage, @unchecked Sendable {
    public var recommendations: [Recommendation] = []
    public var unrecommendations: [Recommendation] = []

    override func makeNetworkMessage() throws -> Data {
        Data()
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        (recommendations, unrecommendations) = try RecommendationsMessage.parseRecommendations(&reader)
    }
}

/// Server code 55.
///
/// We send this to the server to ask for our own list of added
/// likes/recommendations (called "My recommendations" in older versions of the
/// official Soulseek client).
///
/// The server sends us the list of recommendations it knows we have added. For
/// any recommendations present locally, but not on the server, the official
/// Soulseek client would send a AddThingILike message for each missing item.
///
/// OBSOLETE
public final class MyRecommendations: ServerMessage, @unchecked Sendable {
    public var myRecommendations: [String] = []

    override func makeNetworkMessage() throws -> Data {
        Data()
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        let count = try reader.readUInt32()

        for _ in 0..<count {
            myRecommendations.append(try reader.readString())
        }
    }
}

/// Server code 56.
///
/// The server sends us a list of global recommendations and a number for
/// each.
///
/// DEPRECATED, used in Soulseek NS but not SoulseekQt
public final class GlobalRecommendations: ServerMessage, @unchecked Sendable {
    public var recommendations: [Recommendation] = []
    public var unrecommendations: [Recommendation] = []

    override func makeNetworkMessage() throws -> Data {
        Data()
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        (recommendations, unrecommendations) = try RecommendationsMessage.parseRecommendations(&reader)
    }
}

/// Server code 57.
///
/// We ask the server for a user's liked and hated interests. The server
/// responds with a list of interests.
///
/// DEPRECATED, used in Soulseek NS but not SoulseekQt
public final class UserInterests: ServerMessage, @unchecked Sendable {
    public var user = ""
    public var likes: [String] = []
    public var hates: [String] = []

    public convenience init(user: String) {
        self.init()
        self.user = user
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(user)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        user = try reader.readString()

        let likesCount = try reader.readUInt32()
        for _ in 0..<likesCount {
            likes.append(try reader.readString())
        }

        let hatesCount = try reader.readUInt32()
        for _ in 0..<hatesCount {
            hates.append(try reader.readString())
        }
    }
}

/// Server code 58.
///
/// We send this to the server to run an admin command (e.g. to ban or silence
/// a user) if we have admin status on the server.
///
/// OBSOLETE, no longer used since Soulseek stopped supporting third-party
/// servers in 2002
public final class AdminCommand: ServerMessage, @unchecked Sendable {
    public var command = ""
    public var commandArgs: [String] = []

    public convenience init(command: String, commandArgs: [String]) {
        self.init()
        self.command = command
        self.commandArgs = commandArgs
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(command)
        message.appendUInt32(commandArgs.count)

        for argument in commandArgs {
            message.appendString(argument)
        }
        return message
    }
}

/// Server code 60.
///
/// The server sends this to indicate change in place in queue while we're
/// waiting for files from another peer.
///
/// OBSOLETE, use PlaceInQueueResponse peer message
public final class PlaceInLineResponse: ServerMessage, @unchecked Sendable {
    public var token = 0
    public var user = ""
    public var place = 0

    public convenience init(user: String, token: Int, place: Int) {
        self.init()
        self.user = user
        self.token = token
        self.place = place
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(user)
        message.appendUInt32(token)
        message.appendUInt32(place)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        user = try reader.readString()
        token = try reader.readUInt32()
        place = try reader.readUInt32()
    }
}

/// Server code 62.
///
/// The server tells us a new room has been added.
///
/// OBSOLETE, no longer sent by the server
public final class RoomAdded: ServerMessage, @unchecked Sendable {
    public var room = ""

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
    }
}

/// Server code 63.
///
/// The server tells us a room has been removed.
///
/// OBSOLETE, no longer sent by the server
public final class RoomRemoved: ServerMessage, @unchecked Sendable {
    public var room = ""

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
    }
}

public struct RoomInfo: Hashable, Sendable {
    public var name: String
    public var userCount: Int?
}

/// Server code 64.
///
/// The server tells us a list of rooms and the number of users in them. When
/// connecting to the server, the server only sends us rooms with at least 5
/// users. A few select rooms are also excluded, such as nicotine and The
/// Lobby. Requesting the room list yields a response containing the missing
/// rooms.
public final class RoomList: ServerMessage, @unchecked Sendable {
    public var rooms: [RoomInfo] = []
    public var ownedPrivateRooms: [RoomInfo] = []
    public var otherPrivateRooms: [RoomInfo] = []
    public var operatedPrivateRooms: [String] = []

    override func makeNetworkMessage() throws -> Data {
        Data()
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        rooms = try parseRooms(&reader)
        ownedPrivateRooms = try parseRooms(&reader)
        otherPrivateRooms = try parseRooms(&reader)
        operatedPrivateRooms = try parseRoomNames(&reader)
    }

    private func parseRoomNames(_ reader: inout MessageReader) throws -> [String] {
        let count = try reader.readUInt32()
        var rooms: [String] = []

        for _ in 0..<count {
            rooms.append(try reader.readString())
        }
        return rooms
    }

    private func parseRooms(_ reader: inout MessageReader) throws -> [RoomInfo] {
        var rooms = try parseRoomNames(&reader).map { RoomInfo(name: $0, userCount: nil) }
        let numUserCounts = try reader.readUInt32()

        for index in 0..<numUserCounts {
            let userCount = try reader.readUInt32()

            guard index < rooms.count else {
                throw MessageError.missingField("rooms")
            }
            rooms[index].userCount = userCount
        }

        return rooms
    }
}

/// Server code 65.
///
/// We send this to search for an exact file name and folder, to find other
/// sources.
///
/// OBSOLETE, no results even with official client
public final class ExactFileSearch: ServerMessage, @unchecked Sendable {
    public var token = 0
    public var file = ""
    public var folder = ""
    public var size = 0
    public var checksum = 0
    public var user = ""
    public var unknown = 0

    public convenience init(token: Int, file: String, folder: String, size: Int, checksum: Int, unknown: Int) {
        self.init()
        self.token = token
        self.file = file
        self.folder = folder
        self.size = size
        self.checksum = checksum
        self.unknown = unknown
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(token)
        message.appendString(file)
        message.appendString(folder)
        message.appendUInt64(size)
        message.appendUInt32(checksum)
        message.appendUInt8(unknown)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        user = try reader.readString()
        token = try reader.readUInt32()
        file = try reader.readString()
        folder = try reader.readString()
        size = try reader.readUInt64()
        checksum = try reader.readUInt32()
    }
}

/// Server code 66.
///
/// A global message from the server admin has arrived.
public final class AdminMessage: ServerMessage, @unchecked Sendable {
    public var message = ""

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        self.message = try reader.readString()
    }
}

/// Server code 67.
///
/// We send this to get a global list of all users online.
///
/// OBSOLETE, no longer used
public final class GlobalUserList: ServerMessage, @unchecked Sendable {
    public var users: [UserData] = []

    override func makeNetworkMessage() throws -> Data {
        Data()
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        users = try UsersMessage.parseUsers(&reader)
    }
}

/// Server code 68.
///
/// Server message for tunneling a chat message.
///
/// OBSOLETE, no longer used
public final class TunneledMessage: ServerMessage, @unchecked Sendable {
    public var user = ""
    public var token = 0
    public var code = 0
    public var message = ""
    public var addr: PeerAddress?

    public convenience init(user: String, token: Int, code: Int, message: String) {
        self.init()
        self.user = user
        self.token = token
        self.code = code
        self.message = message
    }

    override func makeNetworkMessage() throws -> Data {
        var data = Data()
        data.appendString(user)
        data.appendUInt32(token)
        data.appendUInt32(code)
        data.appendString(message)
        return data
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        user = try reader.readString()
        code = try reader.readUInt32()
        token = try reader.readUInt32()

        let ipAddress = try reader.readIPAddress()
        let port = try reader.readUInt32()
        addr = PeerAddress(ipAddress, port)

        self.message = try reader.readString()
    }
}

/// Server code 69.
///
/// The server sends us a list of privileged users, a.k.a. users who have
/// donated.
public final class PrivilegedUsers: ServerMessage, @unchecked Sendable {
    public var users: [String] = []

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        let numUsers = try reader.readUInt32()

        for _ in 0..<numUsers {
            users.append(try reader.readString())
        }
    }
}

/// Server code 71.
///
/// We inform the server if we have a distributed parent or not. If not, the
/// server eventually sends us a PossibleParents message with a list of 10
/// possible parents to connect to.
public final class HaveNoParent: ServerMessage, @unchecked Sendable {
    public var noParent = false

    public convenience init(noParent: Bool) {
        self.init()
        self.noParent = noParent
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendBool(noParent)
        return message
    }
}

/// Server code 73.
///
/// We send the IP address of our parent to the server.
///
/// DEPRECATED, sent by Soulseek NS but not SoulseekQt
public final class SearchParent: ServerMessage, @unchecked Sendable {
    public var parentIP = ""

    public convenience init(parentIP: String) {
        self.init()
        self.parentIP = parentIP
    }

    override func makeNetworkMessage() throws -> Data {
        let octets = parentIP.split(separator: ".").compactMap { UInt32($0) }

        guard octets.count == 4 else {
            throw MessageError.missingField("parentIP")
        }

        // Packed in reverse byte order, same as received IP addresses
        let value = octets[0] << 24 | octets[1] << 16 | octets[2] << 8 | octets[3]

        var message = Data()
        message.appendUInt32(Int(value))
        return message
    }
}

/// Server code 83.
///
/// The server informs us about the minimum upload speed required to become a
/// parent in the distributed network.
public final class ParentMinSpeed: ServerMessage, @unchecked Sendable {
    public var speed = 0

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        speed = try reader.readUInt32()
    }
}

/// Server code 84.
///
/// The server sends us a speed ratio determining the number of children we
/// can have in the distributed network. The maximum number of children is our
/// upload speed divided by the speed ratio.
public final class ParentSpeedRatio: ServerMessage, @unchecked Sendable {
    public var ratio = 0

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        ratio = try reader.readUInt32()
    }
}

/// Server code 86.
///
/// OBSOLETE, no longer sent by the server
public final class ParentInactivityTimeout: ServerMessage, @unchecked Sendable {
    public var seconds = 0

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        seconds = try reader.readUInt32()
    }
}

/// Server code 87.
///
/// OBSOLETE, no longer sent by the server
public final class SearchInactivityTimeout: ServerMessage, @unchecked Sendable {
    public var seconds = 0

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        seconds = try reader.readUInt32()
    }
}

/// Server code 88.
///
/// OBSOLETE, no longer sent by the server
public final class MinParentsInCache: ServerMessage, @unchecked Sendable {
    public var num = 0

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        num = try reader.readUInt32()
    }
}

/// Server code 90.
///
/// OBSOLETE, no longer sent by the server
public final class DistribPingInterval: ServerMessage, @unchecked Sendable {
    public var seconds = 0

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        seconds = try reader.readUInt32()
    }
}

/// Server code 91.
///
/// The server sends us the username of a new privileged user, which we add to
/// our list of global privileged users.
///
/// OBSOLETE, no longer sent by the server
public final class AddToPrivileged: ServerMessage, @unchecked Sendable {
    public var user = ""

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        user = try reader.readString()
    }
}

/// Server code 92.
///
/// We ask the server how much time we have left of our privileges. The server
/// responds with the remaining time, in seconds.
public final class CheckPrivileges: ServerMessage, @unchecked Sendable {
    public var seconds = 0

    override func makeNetworkMessage() throws -> Data {
        Data()
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        seconds = try reader.readUInt32()
    }
}

/// Server code 93.
///
/// The server sends us an embedded distributed message. The only type of
/// distributed message sent at present is DistribSearch (distributed code 3).
/// If we receive such a message, we are a branch root in the distributed
/// network, and we distribute the embedded message (not the unpacked
/// distributed message) to our child peers.
public final class EmbeddedMessage: ServerMessage, @unchecked Sendable {
    public var distribCode = 0
    public var distribMessage = Data()

    override var isExcludedFromLog: Bool { true }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        distribCode = try reader.readUInt8()
        distribMessage = reader.remainingData()
    }
}

/// Server code 100.
///
/// We tell the server if we want to accept child nodes.
public final class AcceptChildren: ServerMessage, @unchecked Sendable {
    public var enabled = false

    public convenience init(enabled: Bool) {
        self.init()
        self.enabled = enabled
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendBool(enabled)
        return message
    }
}

/// Server code 102.
///
/// The server send us a list of 10 possible distributed parents to connect
/// to. This message is sent to us at regular intervals until we tell the
/// server we don't need more possible parents, through a HaveNoParent message.
public final class PossibleParents: ServerMessage, @unchecked Sendable {
    public var parents: [String: PeerAddress] = [:]
    /// Usernames in the order they were received
    public var usernames: [String] = []

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        let count = try reader.readUInt32()

        for _ in 0..<count {
            let username = try reader.readString()
            let ipAddress = try reader.readIPAddress()
            let port = try reader.readUInt32()

            if parents[username] == nil {
                usernames.append(username)
            }
            parents[username] = PeerAddress(ipAddress, port)
        }
    }
}

/// Server code 103.
///
/// We send the server one of our wishlist search queries at each interval.
public final class WishlistSearch: ServerMessage, @unchecked Sendable {
    public var token = 0
    public var searchTerm = ""

    public convenience init(token: Int, text: String) {
        self.init()
        self.token = token
        self.searchTerm = sanitizedSearchTerm(text)
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(token)
        message.appendString(searchTerm, isLegacy: true)
        return message
    }
}

/// Server code 104.
///
/// The server tells us the wishlist search interval.
public final class WishlistInterval: ServerMessage, @unchecked Sendable {
    public var seconds = 0

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        seconds = try reader.readUInt32()
    }
}

/// Server code 110.
///
/// The server sends us a list of similar users related to our interests.
///
/// DEPRECATED, used in Soulseek NS but not SoulseekQt
public final class SimilarUsers: ServerMessage, @unchecked Sendable {
    public var users: [String: Int] = [:]

    override func makeNetworkMessage() throws -> Data {
        Data()
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        let count = try reader.readUInt32()

        for _ in 0..<count {
            let user = try reader.readString()
            let rating = try reader.readUInt32()
            users[user] = rating
        }
    }
}

/// Server code 111.
///
/// The server sends us a list of recommendations related to a specific item,
/// which is usually present in the like/dislike list or an existing
/// recommendation list.
///
/// DEPRECATED, used in Soulseek NS but not SoulseekQt
public final class ItemRecommendations: ServerMessage, @unchecked Sendable {
    public var thing = ""
    public var recommendations: [Recommendation] = []
    public var unrecommendations: [Recommendation] = []

    public convenience init(thing: String) {
        self.init()
        self.thing = thing
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(thing)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        thing = try reader.readString()
        (recommendations, unrecommendations) = try RecommendationsMessage.parseRecommendations(&reader)
    }
}

/// Server code 112.
///
/// The server sends us a list of similar users related to a specific item,
/// which is usually present in the like/dislike list or recommendation list.
///
/// DEPRECATED, used in Soulseek NS but not SoulseekQt
public final class ItemSimilarUsers: ServerMessage, @unchecked Sendable {
    public var thing = ""
    public var users: [String] = []

    public convenience init(thing: String) {
        self.init()
        self.thing = thing
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(thing)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        thing = try reader.readString()
        let count = try reader.readUInt32()

        for _ in 0..<count {
            users.append(try reader.readString())
        }
    }
}

public struct RoomTicker: Hashable, Sendable {
    public var user: String
    public var message: String
}

/// Server code 113.
///
/// The server returns a list of tickers in a chat room.
///
/// Tickers are customizable, user-specific messages that appear on chat room
/// walls.
public final class RoomTickerState: ServerMessage, @unchecked Sendable {
    public var room = ""
    public var user: String?
    public var messages: [RoomTicker] = []

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
        let count = try reader.readUInt32()

        for _ in 0..<count {
            let user = try reader.readString()
            let text = try reader.readString()
            messages.append(RoomTicker(user: user, message: text))
        }
    }
}

/// Server code 114.
///
/// The server sends us a new ticker that was added to a chat room.
///
/// Tickers are customizable, user-specific messages that appear on chat room
/// walls.
public final class RoomTickerAdd: ServerMessage, @unchecked Sendable {
    public var room = ""
    public var user = ""
    public var message = ""

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
        user = try reader.readString()
        self.message = try reader.readString()
    }
}

/// Server code 115.
///
/// The server informs us that a ticker was removed from a chat room.
///
/// Tickers are customizable, user-specific messages that appear on chat room
/// walls.
public final class RoomTickerRemove: ServerMessage, @unchecked Sendable {
    public var room = ""
    public var user = ""

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
        user = try reader.readString()
    }
}

/// Server code 116.
///
/// We send this to the server when we change our own ticker in a chat room.
/// Sending an empty ticker string removes any existing ticker in the room.
///
/// Tickers are customizable, user-specific messages that appear on chat room
/// walls.
public final class RoomTickerSet: ServerMessage, @unchecked Sendable {
    public var room = ""
    public var message = ""

    public convenience init(room: String, message: String = "") {
        self.init()
        self.room = room
        self.message = message
    }

    override func makeNetworkMessage() throws -> Data {
        var data = Data()
        data.appendString(room)
        data.appendString(message)
        return data
    }
}

/// Server code 117.
///
/// We send this to the server when we add an item to our hate list.
///
/// DEPRECATED, used in Soulseek NS but not SoulseekQt
public final class AddThingIHate: ServerMessage, @unchecked Sendable {
    public var thing = ""

    public convenience init(thing: String) {
        self.init()
        self.thing = thing
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(thing)
        return message
    }
}

/// Server code 118.
///
/// We send this to the server when we remove an item from our hate list.
///
/// DEPRECATED, used in Soulseek NS but not SoulseekQt
public final class RemoveThingIHate: ServerMessage, @unchecked Sendable {
    public var thing = ""

    public convenience init(thing: String) {
        self.init()
        self.thing = thing
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(thing)
        return message
    }
}

/// Server code 120.
///
/// We send this to the server to search files shared by users who have joined
/// a specific chat room. The token is a number generated by the client and is
/// used to track the search results.
///
/// In the past, the server sent us this message for RoomSearch requests from
/// other users. Today, the server sends a FileSearch message instead.
public final class RoomSearch: ServerMessage, @unchecked Sendable {
    public var room = ""
    public var token = 0
    public var searchTerm = ""
    public var searchUsername: String?

    public convenience init(room: String, token: Int, text: String) {
        self.init()
        self.room = room
        self.token = token
        self.searchTerm = sanitizedSearchTerm(text)
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(room)
        message.appendUInt32(token)
        message.appendString(searchTerm, isLegacy: true)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        // Obsolete
        var reader = MessageReader(message)
        searchUsername = try reader.readString()
        token = try reader.readUInt32()
        searchTerm = try reader.readString()
    }
}

/// Server code 121.
///
/// We send this after a finished upload to let the server update the speed
/// statistics for ourselves.
public final class SendUploadSpeed: ServerMessage, @unchecked Sendable {
    public var speed = 0

    public convenience init(speed: Int) {
        self.init()
        self.speed = speed
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(speed)
        return message
    }
}

/// Server code 122.
///
/// We ask the server whether a user is privileged or not.
///
/// DEPRECATED, use WatchUser and GetUserStatus server messages
public final class UserPrivileged: ServerMessage, @unchecked Sendable {
    public var user = ""
    public var privileged: Bool?

    public convenience init(user: String) {
        self.init()
        self.user = user
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(user)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        user = try reader.readString()
        privileged = try reader.readBool()
    }
}

/// Server code 123.
///
/// We give (part of) our privileges, specified in days, to another user on
/// the network.
public final class GivePrivileges: ServerMessage, @unchecked Sendable {
    public var user = ""
    public var days = 0

    public convenience init(user: String, days: Int) {
        self.init()
        self.user = user
        self.days = days
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(user)
        message.appendUInt32(days)
        return message
    }
}

/// Server code 124.
///
/// DEPRECATED, sent by Soulseek NS but not SoulseekQt
public final class NotifyPrivileges: ServerMessage, @unchecked Sendable {
    public var token = 0
    public var user = ""

    public convenience init(token: Int, user: String) {
        self.init()
        self.token = token
        self.user = user
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        token = try reader.readUInt32()
        user = try reader.readString()
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(token)
        message.appendString(user)
        return message
    }
}

/// Server code 125.
///
/// DEPRECATED, no longer used
public final class AckNotifyPrivileges: ServerMessage, @unchecked Sendable {
    public var token = 0

    public convenience init(token: Int) {
        self.init()
        self.token = token
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        token = try reader.readUInt32()
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(token)
        return message
    }
}

/// Server code 126.
///
/// We tell the server what our position is in our branch (xth generation) on
/// the distributed network.
public final class BranchLevel: ServerMessage, @unchecked Sendable {
    public var value = 0

    public convenience init(value: Int) {
        self.init()
        self.value = value
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(value)
        return message
    }
}

/// Server code 127.
///
/// We tell the server the username of the root of the branch we’re in on the
/// distributed network.
public final class BranchRoot: ServerMessage, @unchecked Sendable {
    public var user = ""

    public convenience init(user: String) {
        self.init()
        self.user = user
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(user)
        return message
    }
}

/// Server code 129.
///
/// We tell the server the maximum number of generation of children we have on
/// the distributed network.
///
/// DEPRECATED, sent by Soulseek NS but not SoulseekQt
public final class ChildDepth: ServerMessage, @unchecked Sendable {
    public var value = 0

    public convenience init(value: Int) {
        self.init()
        self.value = value
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(value)
        return message
    }
}

/// Server code 130.
///
/// The server asks us to reset our distributed parent and children.
public final class ResetDistributed: ServerMessage, @unchecked Sendable {
    override func parseNetworkMessage(_ message: Data) throws {
        // Empty message
    }
}

/// Server code 133.
///
/// The server sends us a list of members (excluding the owner) in a private
/// room we are in.
public final class PrivateRoomUsers: ServerMessage, @unchecked Sendable {
    public var room = ""
    public var numUsers = 0
    public var users: [String] = []

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
        numUsers = try reader.readUInt32()

        for _ in 0..<numUsers {
            users.append(try reader.readString())
        }
    }
}

/// Base for private room messages containing a room and a username.
public class PrivateRoomUserMessage: ServerMessage, @unchecked Sendable {
    public var room = ""
    public var user = ""

    public convenience init(room: String, user: String) {
        self.init()
        self.room = room
        self.user = user
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(room)
        message.appendString(user)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
        user = try reader.readString()
    }
}

/// Server code 134.
///
/// We send this to the server to add a member to a private room, if we are the
/// owner or an operator.
///
/// The server tells us a member has been added to a private room we are in.
public final class PrivateRoomAddUser: PrivateRoomUserMessage, @unchecked Sendable {}

/// Server code 135.
///
/// We send this to the server to remove a member from a private room, if we
/// are the owner or an operator. Owners can remove operators and regular
/// members, operators can only remove regular members.
///
/// The server tells us a member has been removed from a private room we are
/// in.
public final class PrivateRoomRemoveUser: PrivateRoomUserMessage, @unchecked Sendable {}

/// Base for private room messages containing only a room name.
public class PrivateRoomMessage: ServerMessage, @unchecked Sendable {
    public var room = ""

    public convenience init(room: String) {
        self.init()
        self.room = room
    }
}

/// Server code 136.
///
/// We send this to the server to cancel our own membership of a private room.
public final class PrivateRoomCancelMembership: PrivateRoomMessage, @unchecked Sendable {
    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(room)
        return message
    }
}

/// Server code 137.
///
/// We send this to the server to stop owning a private room.
public final class PrivateRoomDisown: PrivateRoomMessage, @unchecked Sendable {
    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(room)
        return message
    }
}

/// Server code 138.
///
/// OBSOLETE, no longer used
public final class PrivateRoomSomething: PrivateRoomMessage, @unchecked Sendable {
    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(room)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
    }
}

/// Server code 139.
///
/// The server tells us we were added to a private room.
public final class PrivateRoomAdded: PrivateRoomMessage, @unchecked Sendable {
    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
    }
}

/// Server code 140.
///
/// The server tells us we were removed from a private room.
public final class PrivateRoomRemoved: PrivateRoomMessage, @unchecked Sendable {
    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
    }
}

/// Server code 141.
///
/// We send this when we want to enable or disable invitations to private
/// rooms.
public final class PrivateRoomToggle: ServerMessage, @unchecked Sendable {
    public var enabled = false

    public convenience init(enabled: Bool) {
        self.init()
        self.enabled = enabled
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendBool(enabled)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        enabled = try reader.readBool()
    }
}

/// Server code 142.
///
/// We send this to the server to change our password. We receive a response
/// if our password changes.
public final class ChangePassword: ServerMessage, @unchecked Sendable {
    public var password = ""

    override class var excludedAttributes: Set<String> { ["password"] }

    public convenience init(password: String) {
        self.init()
        self.password = password
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(password)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        password = try reader.readString()
    }
}

/// Server code 143.
///
/// We send this to the server to add private room operator abilities to a
/// member.
///
/// The server tells us a member received operator abilities in a private room
/// we are in.
public final class PrivateRoomAddOperator: PrivateRoomUserMessage, @unchecked Sendable {}

/// Server code 144.
///
/// We send this to the server to remove private room operator abilities from a
/// member.
///
/// The server tells us operator abilities were removed for a member in a
/// private room we are in.
public final class PrivateRoomRemoveOperator: PrivateRoomUserMessage, @unchecked Sendable {}

/// Server code 145.
///
/// The server tells us we were given operator abilities in a private room we
/// are in.
public final class PrivateRoomOperatorAdded: PrivateRoomMessage, @unchecked Sendable {
    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
    }
}

/// Server code 146.
///
/// The server tells us our operator abilities were removed in a private room
/// we are in.
public final class PrivateRoomOperatorRemoved: PrivateRoomMessage, @unchecked Sendable {
    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(room)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
    }
}

/// Server code 148.
///
/// The server sends us a list of operators in a private room we are in.
public final class PrivateRoomOperators: ServerMessage, @unchecked Sendable {
    public var room = ""
    public var number = 0
    public var operators: [String] = []

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
        number = try reader.readUInt32()

        for _ in 0..<number {
            operators.append(try reader.readString())
        }
    }
}

/// Server code 149.
///
/// Sends a broadcast private message to the given list of online users.
public final class MessageUsers: ServerMessage, @unchecked Sendable {
    public var users: [String] = []
    public var message = ""

    public convenience init(users: [String], message: String) {
        self.init()
        self.users = users
        self.message = message
    }

    override func makeNetworkMessage() throws -> Data {
        var data = Data()
        data.appendUInt32(users.count)

        for user in users {
            data.appendString(user)
        }

        data.appendString(message)
        return data
    }
}

/// Server code 150.
///
/// We ask the server to send us messages from all public rooms, also known as
/// public room feed.
///
/// DEPRECATED, used in Soulseek NS but not SoulseekQt
public final class JoinGlobalRoom: ServerMessage, @unchecked Sendable {
    override func makeNetworkMessage() throws -> Data {
        Data()
    }
}

/// Server code 151.
///
/// We ask the server to stop sending us messages from all public rooms, also
/// known as public room feed.
///
/// DEPRECATED, used in Soulseek NS but not SoulseekQt
public final class LeaveGlobalRoom: ServerMessage, @unchecked Sendable {
    override func makeNetworkMessage() throws -> Data {
        Data()
    }
}

/// Server code 152.
///
/// The server sends this when a new message has been written in the public
/// room feed (every single line written in every public room).
///
/// DEPRECATED, used in Soulseek NS but not SoulseekQt
public final class GlobalRoomMessage: ServerMessage, @unchecked Sendable {
    public var room = ""
    public var user = ""
    public var message = ""
    public var formattedMessage: String?
    public var chatMessageType: String?

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
        user = try reader.readString()
        self.message = try reader.readString()
    }
}

/// Server code 153.
///
/// The server returns a list of related search terms for a search query.
///
/// OBSOLETE, server sends empty list as of 2018
public final class RelatedSearch: ServerMessage, @unchecked Sendable {
    public var query = ""
    public var terms: [(term: String, score: Int)] = []

    public convenience init(query: String) {
        self.init()
        self.query = query
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(query)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        query = try reader.readString()
        let count = try reader.readUInt32()

        for _ in 0..<count {
            let term = try reader.readString()
            let score = try reader.readUInt32()
            terms.append((term, score))
        }
    }
}

/// Server code 160.
///
/// The server sends a list of phrases not allowed on the search network. File
/// paths containing such phrases should be excluded when responding to search
/// requests.
public final class ExcludedSearchPhrases: ServerMessage, @unchecked Sendable {
    public var phrases: [String] = []

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        let count = try reader.readUInt32()

        for _ in 0..<count {
            phrases.append(try reader.readString())
        }
    }
}

/// Server code 1001.
///
/// We send this when we are not able to respond to an indirect connection
/// request. We receive this if a peer was not able to respond to our indirect
/// connection request. The token is taken from the ConnectToPeer message.
///
/// Do not rely on receiving this message from peers. Keep a local timeout for
/// indirect connections as well.
public final class CantConnectToPeer: ServerMessage, @unchecked Sendable {
    public var token = 0
    public var user = ""

    public convenience init(token: Int, user: String) {
        self.init()
        self.token = token
        self.user = user
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(token)
        message.appendString(user)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        token = try reader.readUInt32()
    }
}

/// Server code 1003.
///
/// Server tells us a new room cannot be created. This message only seems to be
/// sent if we try to create a room with the same name as an existing private
/// room. In other cases, such as using a room name with leading or trailing
/// spaces, only a private message containing an error message is sent.
public final class CantCreateRoom: ServerMessage, @unchecked Sendable {
    public var room = ""

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        room = try reader.readString()
    }
}
