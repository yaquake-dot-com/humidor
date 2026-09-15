// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum PermissionLevel: String, Sendable {
    case `public` = "public"
    case buddy = "buddy"
    case trusted = "trusted"
    case banned = "banned"
}

// MARK: - Peer Init Messages

public class PeerInitMessage: SlskMessage, @unchecked Sendable {
    override public class var messageType: MessageType { .initialization }
}

/// Peer init code 0.
///
/// This message is sent in response to an indirect connection request from
/// another user. If the message goes through to the user, the connection is
/// ready. The token is taken from the ConnectToPeer server message.
public final class PierceFireWall: PeerInitMessage, @unchecked Sendable {
    public var sock: Socket?
    public var token = 0

    public convenience init(sock: Socket?, token: Int) {
        self.init()
        self.sock = sock
        self.token = token
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(token)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        token = try reader.readUInt32()
    }
}

/// Peer init code 1.
///
/// This message is sent to initiate a direct connection to another peer. The
/// token is apparently always 0 and ignored.
public final class PeerInit: PeerInitMessage, @unchecked Sendable {
    public var sock: Socket?
    /// Username of peer who initiated the message
    public var initUser = ""
    /// Username of peer we're connected to
    public var targetUser = ""
    public var connType = ""
    public var outgoingMessages: [SlskMessage] = []
    public var token = 0

    public convenience init(sock: Socket? = nil, initUser: String, targetUser: String, connType: String) {
        self.init()
        self.sock = sock
        self.initUser = initUser
        self.targetUser = targetUser
        self.connType = connType
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(initUser)
        message.appendString(connType)
        message.appendUInt32(token)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        initUser = try reader.readString()
        connType = try reader.readString()

        if targetUser.isEmpty {
            // The user we're connecting to initiated the connection. Set them as target user.
            targetUser = initUser
        }
    }
}

// MARK: - Peer Messages

public class PeerMessage: SlskMessage, @unchecked Sendable {
    override public class var messageType: MessageType { .peer }

    public var username: String?
    public var sock: Socket?
    public var addr: PeerAddress?
}

/// Peer code 4.
///
/// We send this to a peer to ask for a list of shared files.
public final class SharedFileListRequest: PeerMessage, @unchecked Sendable {
    override func makeNetworkMessage() throws -> Data {
        Data()
    }

    override func parseNetworkMessage(_ message: Data) throws {
        // Empty message
    }
}

/// A folder in a received file list.
public struct SharedFolderEntry: Hashable, Sendable {
    public var path: String
    public var files: [FileListEntry]
}

/// Packed file lists of shared folders, keyed by virtual folder path.
public typealias PackedShares = [String: Data]

/// Peer code 5.
///
/// A peer responds with a list of shared files when we've sent a
/// SharedFileListRequest.
public final class SharedFileListResponse: PeerMessage, @unchecked Sendable {
    public var list: [SharedFolderEntry] = []
    public var unknown = 0
    public var privateList: [SharedFolderEntry] = []
    public var built: Data?
    public var permissionLevel: PermissionLevel?
    public var publicShares: PackedShares?
    public var buddyShares: PackedShares?
    public var trustedShares: PackedShares?

    override class var excludedAttributes: Set<String> {
        ["list", "privateList", "built", "publicShares", "buddyShares", "trustedShares"]
    }

    public convenience init(publicShares: PackedShares? = nil, buddyShares: PackedShares? = nil,
                            trustedShares: PackedShares? = nil, permissionLevel: PermissionLevel?) {
        self.init()
        self.publicShares = publicShares
        self.buddyShares = buddyShares
        self.trustedShares = trustedShares
        self.permissionLevel = permissionLevel
    }

    private func makeSharesList(_ shareGroups: [PackedShares]) -> Data {
        var message = Data()
        message.appendUInt32(shareGroups.reduce(0) { $0 + $1.count })

        for shares in shareGroups {
            for key in shares.keys.sorted() {
                message.appendString(key)
                message.append(shares[key]!)
            }
        }

        return message
    }

    override func makeNetworkMessage() throws -> Data {
        // Store packed message contents in self.built, and use instead of repacking it
        if let built {
            return built
        }

        enum Group { case buddy, trusted }

        var message = Data()
        var shareGroups: [PackedShares] = []
        var includedGroups: Set<Group> = []

        if permissionLevel != nil, let publicShares, !publicShares.isEmpty {
            shareGroups.append(publicShares)
        }

        if permissionLevel == .buddy || permissionLevel == .trusted, let buddyShares, !buddyShares.isEmpty {
            shareGroups.append(buddyShares)
            includedGroups.insert(.buddy)
        }

        if permissionLevel == .trusted, let trustedShares, !trustedShares.isEmpty {
            shareGroups.append(trustedShares)
            includedGroups.insert(.trusted)
        }

        message.append(makeSharesList(shareGroups))

        // Unknown purpose, but official clients always send a value of 0
        message.appendUInt32(unknown)

        var privateShareGroups: [PackedShares] = []

        if let buddyShares, !buddyShares.isEmpty, !includedGroups.contains(.buddy) {
            privateShareGroups.append(buddyShares)
        }

        if let trustedShares, !trustedShares.isEmpty, !includedGroups.contains(.trusted) {
            privateShareGroups.append(trustedShares)
        }

        if !privateShareGroups.isEmpty {
            message.append(makeSharesList(privateShareGroups))
        }

        let compressed = try Zlib.compress(message)
        built = compressed
        return compressed
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(try Zlib.decompress(message))
        list = try Self.parseResultList(&reader)

        if reader.hasRemaining {
            unknown = try reader.readUInt32()
        }

        if reader.hasRemaining {
            privateList = try Self.parseResultList(&reader)
        }
    }

    static func parseResultList(_ reader: inout MessageReader) throws -> [SharedFolderEntry] {
        let numFolders = try reader.readUInt32()
        var shares: [SharedFolderEntry] = []

        for _ in 0..<numFolders {
            let folder = try reader.readString().replacingOccurrences(of: "/", with: "\\")
            let numFiles = try reader.readUInt32()
            var files: [FileListEntry] = []

            for _ in 0..<numFiles {
                files.append(try FileListMessage.readFileEntry(&reader))
            }

            if numFiles > 1 {
                files.sort { $0.name < $1.name }
            }

            shares.append(SharedFolderEntry(path: folder, files: files))
        }

        if numFolders > 1 {
            shares.sort { $0.path < $1.path }
        }

        return shares
    }
}

/// Peer code 8.
///
/// We send this to the peer when we search for a file. Alternatively, the peer
/// sends this to tell us it is searching for a file.
///
/// OBSOLETE, use UserSearch server message
public final class FileSearchRequest: PeerMessage, @unchecked Sendable {
    public var token = 0
    public var text = ""
    public var searchTerm = ""

    public convenience init(token: Int, text: String) {
        self.init()
        self.token = token
        self.text = text
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(token)
        message.appendString(text)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        token = try reader.readUInt32()
        searchTerm = try reader.readString()
    }
}

/// Peer code 9.
///
/// A peer sends this message when it has a file search match. The token is
/// taken from original FileSearch, UserSearch or RoomSearch server message.
public final class FileSearchResponse: PeerMessage, @unchecked Sendable {
    public var searchUsername = ""
    public var token = 0
    /// Received results
    public var list: [FileListEntry] = []
    public var privateList: [FileListEntry] = []
    /// Results to send
    public var shares: [SharedFileInfo] = []
    public var privateShares: [SharedFileInfo] = []
    public var freeUploadSlots = false
    public var uploadSpeed = 0
    public var inQueue = 0
    public var unknown = 0

    override class var excludedAttributes: Set<String> { ["list", "privateList", "shares", "privateShares"] }

    public convenience init(searchUsername: String, token: Int, shares: [SharedFileInfo], freeUploadSlots: Bool,
                            uploadSpeed: Int, inQueue: Int, privateShares: [SharedFileInfo] = []) {
        self.init()
        self.searchUsername = searchUsername
        self.token = token
        self.shares = shares
        self.privateShares = privateShares
        self.freeUploadSlots = freeUploadSlots
        self.uploadSpeed = uploadSpeed
        self.inQueue = inQueue
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(searchUsername)
        message.appendUInt32(token)
        message.appendUInt32(shares.count)

        for fileInfo in shares {
            message.append(FileListMessage.packFileInfo(fileInfo))
        }

        message.appendBool(freeUploadSlots)
        message.appendUInt32(uploadSpeed)
        message.appendUInt32(inQueue)
        message.appendUInt32(unknown)

        if !privateShares.isEmpty {
            message.appendUInt32(privateShares.count)

            for fileInfo in privateShares {
                message.append(FileListMessage.packFileInfo(fileInfo))
            }
        }

        return try Zlib.compress(message)
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(try Zlib.decompress(message))
        searchUsername = try reader.readString()
        token = try reader.readUInt32()

        guard SearchTokens.isAllowed(token) else {
            // Results are no longer accepted for this search token, stop parsing message
            list = []
            return
        }

        list = try Self.parseResultList(&reader)
        freeUploadSlots = try reader.readBool()
        uploadSpeed = try reader.readUInt32()
        inQueue = try reader.readUInt32()

        if reader.hasRemaining {
            unknown = try reader.readUInt32()
        }

        if reader.hasRemaining {
            privateList = try Self.parseResultList(&reader)
        }
    }

    private static func parseResultList(_ reader: inout MessageReader) throws -> [FileListEntry] {
        let numFiles = try reader.readUInt32()
        var results: [FileListEntry] = []

        for _ in 0..<numFiles {
            var entry = try FileListMessage.readFileEntry(&reader)
            entry.name = entry.name.replacingOccurrences(of: "/", with: "\\")
            results.append(entry)
        }

        if numFiles > 1 {
            results.sort { $0.name < $1.name }
        }

        return results
    }
}

/// Peer code 15.
///
/// We ask the other peer to send us their user information, picture and all.
public final class UserInfoRequest: PeerMessage, @unchecked Sendable {
    override func makeNetworkMessage() throws -> Data {
        Data()
    }

    override func parseNetworkMessage(_ message: Data) throws {
        // Empty message
    }
}

/// Peer code 16.
///
/// A peer responds with this after we've sent a UserInfoRequest.
public final class UserInfoResponse: PeerMessage, @unchecked Sendable {
    public var userDescription = ""
    public var picture: Data?
    public var totalUploads = 0
    public var queueSize = 0
    public var slotsAvailable = false
    public var uploadAllowed: Int?
    public var hasPicture = false

    override class var excludedAttributes: Set<String> { ["picture"] }

    public convenience init(description: String, picture: Data?, totalUploads: Int, queueSize: Int,
                            slotsAvailable: Bool, uploadAllowed: Int) {
        self.init()
        self.userDescription = description
        self.picture = picture
        self.totalUploads = totalUploads
        self.queueSize = queueSize
        self.slotsAvailable = slotsAvailable
        self.uploadAllowed = uploadAllowed
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(userDescription)

        if let picture {
            message.appendBool(true)
            message.appendBytes(picture)
        } else {
            message.appendBool(false)
        }

        message.appendUInt32(totalUploads)
        message.appendUInt32(queueSize)
        message.appendBool(slotsAvailable)
        message.appendUInt32(uploadAllowed ?? 0)

        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        userDescription = try reader.readString()
        hasPicture = try reader.readBool()

        if hasPicture {
            picture = try reader.readBytes()
        }

        totalUploads = try reader.readUInt32()
        queueSize = try reader.readUInt32()
        slotsAvailable = try reader.readBool()

        // To prevent errors, ensure that >= 4 bytes are left. Museek+ incorrectly sends
        // slotsavail as an integer, resulting in 3 bytes of garbage here.
        if reader.remaining >= 4 {
            uploadAllowed = try reader.readUInt32()
        }
    }
}

/// Peer code 22.
///
/// Chat phrase sent to someone or received by us in private. This is a
/// Nicotine+ extension to the Soulseek protocol.
///
/// OBSOLETE
public final class PMessageUser: PeerMessage, @unchecked Sendable {
    public var messageUsername = ""
    public var message = ""
    public var messageID = 0
    public var timestamp = 0

    public convenience init(messageUsername: String, message: String) {
        self.init()
        self.messageUsername = messageUsername
        self.message = message
    }

    override func makeNetworkMessage() throws -> Data {
        var data = Data()
        data.appendUInt32(0)
        data.appendUInt32(0)
        data.appendString(messageUsername)
        data.appendString(message)
        return data
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        messageID = try reader.readUInt32()
        timestamp = try reader.readUInt32()
        messageUsername = try reader.readString()
        self.message = try reader.readString()
    }
}

/// Peer code 36.
///
/// We ask the peer to send us the contents of a single folder.
public final class FolderContentsRequest: PeerMessage, @unchecked Sendable {
    public var folder = ""
    public var token = 0
    public var legacyClient = false

    public convenience init(folder: String, token: Int, legacyClient: Bool = false) {
        self.init()
        self.folder = folder
        self.token = token
        self.legacyClient = legacyClient
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(token)
        message.appendString(folder, isLegacy: legacyClient)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        token = try reader.readUInt32()
        folder = try reader.readString()
    }
}

/// Peer code 37.
///
/// A peer responds with the contents of a particular folder (with all
/// subfolders) after we've sent a FolderContentsRequest.
public final class FolderContentsResponse: PeerMessage, @unchecked Sendable {
    public var folder = ""
    public var token = 0
    /// Received folder contents, keyed by folder path
    public var list: [String: [FileListEntry]] = [:]
    /// Packed folder contents to send, as stored in the shares database
    public var packedFiles: Data?

    override class var excludedAttributes: Set<String> { ["packedFiles"] }

    public convenience init(folder: String, token: Int, packedFiles: Data?) {
        self.init()
        self.folder = folder
        self.token = token
        self.packedFiles = packedFiles
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(try Zlib.decompress(message))
        token = try reader.readUInt32()
        folder = try reader.readString()
        let numFolders = try reader.readUInt32()

        for _ in 0..<numFolders {
            let folderPath = try reader.readString().replacingOccurrences(of: "/", with: "\\")
            let numFiles = try reader.readUInt32()
            var files: [FileListEntry] = []

            for _ in 0..<numFiles {
                files.append(try FileListMessage.readFileEntry(&reader, parseLargeSizes: false))
            }

            if numFiles > 1 {
                files.sort { $0.name < $1.name }
            }

            list[folderPath] = files
        }
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(token)
        message.appendString(folder)

        if let packedFiles {
            message.appendUInt32(1)
            message.appendString(folder)

            // We already saved the folder contents as bytes when scanning our shares
            message.append(packedFiles)
        } else {
            // No folder contents
            message.appendUInt32(0)
        }

        return try Zlib.compress(message)
    }
}

/// Peer code 40.
///
/// This message is sent by a peer once they are ready to start uploading a
/// file. A TransferResponse message is expected from the recipient, either
/// allowing or rejecting the upload attempt.
///
/// This message was formerly used to send a download request (direction 0) as
/// well, but Nicotine+ >= 3.0.3, Museek+ and the official clients use the
/// QueueUpload message for this purpose today.
public final class TransferRequest: PeerMessage, @unchecked Sendable {
    public var direction = 0
    public var token = 0
    /// Virtual file path
    public var file = ""
    public var fileSize: Int?

    public convenience init(direction: TransferDirection, token: Int, file: String, fileSize: Int? = nil) {
        self.init()
        self.direction = direction.rawValue
        self.token = token
        self.file = file
        self.fileSize = fileSize
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(direction)
        message.appendUInt32(token)
        message.appendString(file)

        if direction == TransferDirection.upload.rawValue {
            message.appendUInt64(fileSize ?? 0)
        }

        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        direction = try reader.readUInt32()
        token = try reader.readUInt32()
        file = try reader.readString()

        if direction == TransferDirection.upload.rawValue {
            fileSize = try reader.readUInt64()
        }
    }
}

/// Peer code 41.
///
/// Response to TransferRequest - We (or the other peer) either agrees, or
/// tells the reason for rejecting the file transfer.
public final class TransferResponse: PeerMessage, @unchecked Sendable {
    public var allowed = false
    public var token = 0
    public var reason: String?
    public var fileSize: Int?

    public convenience init(allowed: Bool, reason: String? = nil, token: Int, fileSize: Int? = nil) {
        self.init()
        self.allowed = allowed
        self.token = token
        self.reason = reason
        self.fileSize = fileSize
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(token)
        message.appendBool(allowed)

        if let reason {
            message.appendString(reason)
        }

        if let fileSize {
            message.appendUInt64(fileSize)
        }

        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        token = try reader.readUInt32()
        allowed = try reader.readBool()

        if reader.hasRemaining {
            if allowed {
                fileSize = try reader.readUInt64()
            } else {
                reason = try reader.readString()
            }
        }
    }
}

/// Peer code 42.
///
/// OBSOLETE, no longer used
public final class PlaceholdUpload: PeerMessage, @unchecked Sendable {
    public var file = ""

    public convenience init(file: String) {
        self.init()
        self.file = file
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(file)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        file = try reader.readString()
    }
}

/// Peer code 43.
///
/// This message is used to tell a peer that an upload should be queued on
/// their end. Once the recipient is ready to transfer the requested file, they
/// will send a TransferRequest to us.
public final class QueueUpload: PeerMessage, @unchecked Sendable {
    public var file = ""
    public var legacyClient = false

    public convenience init(file: String, legacyClient: Bool = false) {
        self.init()
        self.file = file
        self.legacyClient = legacyClient
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(file, isLegacy: legacyClient)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        file = try reader.readString()
    }
}

/// Peer code 44.
///
/// The peer replies with the upload queue placement of the requested file.
public final class PlaceInQueueResponse: PeerMessage, @unchecked Sendable {
    public var filename = ""
    public var place = 0

    public convenience init(filename: String, place: Int) {
        self.init()
        self.filename = filename
        self.place = place
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(filename)
        message.appendUInt32(place)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        filename = try reader.readString()
        place = try reader.readUInt32()
    }
}

/// Peer code 46.
///
/// This message is sent whenever a file connection of an active upload
/// closes. Soulseek NS clients can also send this message when a file cannot
/// be read. The recipient either re-queues the upload (download on their end),
/// or ignores the message if the transfer finished.
public final class UploadFailed: PeerMessage, @unchecked Sendable {
    public var file = ""

    public convenience init(file: String) {
        self.init()
        self.file = file
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(file)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        file = try reader.readString()
    }
}

/// Peer code 50.
///
/// This message is sent to reject QueueUpload attempts and previously queued
/// files. The reason for rejection will appear in the transfer list of the
/// recipient.
public final class UploadDenied: PeerMessage, @unchecked Sendable {
    public var file = ""
    public var reason = ""

    public convenience init(file: String, reason: String) {
        self.init()
        self.file = file
        self.reason = reason
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(file)
        message.appendString(reason)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        file = try reader.readString()
        reason = try reader.readString()
    }
}

/// Peer code 51.
///
/// This message is sent when asking for the upload queue placement of a file.
public final class PlaceInQueueRequest: PeerMessage, @unchecked Sendable {
    public var file = ""
    public var legacyClient = false

    public convenience init(file: String, legacyClient: Bool = false) {
        self.init()
        self.file = file
        self.legacyClient = legacyClient
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(file, isLegacy: legacyClient)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        file = try reader.readString()
    }
}

/// Peer code 52.
///
/// This message is sent to inform a peer about an upload attempt initiated by
/// us.
///
/// DEPRECATED, sent by Soulseek NS but not SoulseekQt
public final class UploadQueueNotification: PeerMessage, @unchecked Sendable {
    override func makeNetworkMessage() throws -> Data {
        Data()
    }

    override func parseNetworkMessage(_ message: Data) throws {
        // Empty message
    }
}

/// Peer code 12547.
///
/// UNKNOWN
public final class UnknownPeerMessage: PeerMessage, @unchecked Sendable {
    override var isExcludedFromLog: Bool { true }

    override func parseNetworkMessage(_ message: Data) throws {
        // Empty message
    }
}

// MARK: - File Messages

public class FileMessage: SlskMessage, @unchecked Sendable {
    override public class var messageType: MessageType { .file }

    public var sock: Socket?
    public var username: String?
}

/// We send this to a peer via a 'F' connection to tell them that we want to
/// start uploading a file. The token is the same as the one previously
/// included in the TransferRequest peer message.
///
/// Note that slskd and Nicotine+ <= 3.0.2 use legacy download requests, and
/// send this message when initializing our file upload connection from their
/// end.
public final class FileTransferInit: FileMessage, @unchecked Sendable {
    public var token: Int?
    public var isOutgoing = false

    public convenience init(token: Int, isOutgoing: Bool = false) {
        self.init()
        self.token = token
        self.isOutgoing = isOutgoing
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(token ?? 0)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        token = try reader.readUInt32()
    }
}

/// We send this to the uploading peer at the beginning of a 'F' connection, to
/// tell them how many bytes of the file we've previously downloaded. If nothing
/// was downloaded, the offset is 0.
///
/// Note that Soulseek NS fails to read the size of an incomplete download if
/// more than 2 GB of the file has been downloaded, and the download is
/// resumed. In consequence, the client sends an invalid file offset of -1.
public final class FileOffset: FileMessage, @unchecked Sendable {
    public var offset: Int?

    public convenience init(sock: Socket?, offset: Int) {
        self.init()
        self.sock = sock
        self.offset = offset
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt64(offset ?? 0)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        offset = try reader.readUInt64()
    }
}

// MARK: - Distributed Messages

public class DistribMessage: SlskMessage, @unchecked Sendable {
    override public class var messageType: MessageType { .distributed }

    public var sock: Socket?
    public var username: String?

    /// Creates a copy of the message, to be sent to a child peer.
    func copyForChildPeer() -> DistribMessage {
        preconditionFailure("\(type(of: self)) cannot be sent to child peers")
    }
}

/// Distrib code 0.
///
/// We ping distributed children every 60 seconds.
///
/// DEPRECATED, sent by Soulseek NS but not SoulseekQt
public final class DistribPing: DistribMessage, @unchecked Sendable {
    override func makeNetworkMessage() throws -> Data {
        Data()
    }

    override func parseNetworkMessage(_ message: Data) throws {
        // Empty message
    }
}

/// Distrib code 3.
///
/// Search request that arrives through the distributed network. We transmit
/// the search request to our child peers.
public final class DistribSearch: DistribMessage, @unchecked Sendable {
    public var unknown = 0
    public var searchUsername = ""
    public var token = 0
    public var searchTerm = ""

    override var isExcludedFromLog: Bool { true }

    public convenience init(unknown: Int, searchUsername: String, token: Int, searchTerm: String) {
        self.init()
        self.unknown = unknown
        self.searchUsername = searchUsername
        self.token = token
        self.searchTerm = searchTerm
    }

    override func copyForChildPeer() -> DistribMessage {
        DistribSearch(unknown: unknown, searchUsername: searchUsername, token: token, searchTerm: searchTerm)
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt32(unknown)
        message.appendString(searchUsername)
        message.appendUInt32(token)
        message.appendString(searchTerm)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        unknown = try reader.readUInt32()
        searchUsername = try reader.readString()
        token = try reader.readUInt32()
        searchTerm = try reader.readString()
    }
}

/// Distrib code 4.
///
/// We tell our distributed children what our position is in our branch (xth
/// generation) on the distributed network.
///
/// If we receive a branch level of 0 from a parent, we should mark the parent
/// as our branch root, since they won't send a DistribBranchRoot message in
/// this case.
public final class DistribBranchLevel: DistribMessage, @unchecked Sendable {
    public var level = 0

    public convenience init(level: Int) {
        self.init()
        self.level = level
    }

    override func copyForChildPeer() -> DistribMessage {
        DistribBranchLevel(level: level)
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendInt32(level)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        level = try reader.readInt32()
    }
}

/// Distrib code 5.
///
/// We tell our distributed children the username of the root of the branch
/// we’re in on the distributed network.
///
/// This message should not be sent when we're the branch root.
public final class DistribBranchRoot: DistribMessage, @unchecked Sendable {
    public var rootUsername = ""

    public convenience init(rootUsername: String) {
        self.init()
        self.rootUsername = rootUsername
    }

    override func copyForChildPeer() -> DistribMessage {
        DistribBranchRoot(rootUsername: rootUsername)
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendString(rootUsername)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        rootUsername = try reader.readString()
    }
}

/// Distrib code 7.
///
/// We tell our distributed parent the maximum number of generation of
/// children we have on the distributed network.
///
/// DEPRECATED, sent by Soulseek NS but not SoulseekQt
public final class DistribChildDepth: DistribMessage, @unchecked Sendable {
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

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message)
        value = try reader.readUInt32()
    }
}

/// Distrib code 93.
///
/// A branch root sends us an embedded distributed message. We unpack the
/// distributed message and distribute it to our child peers. The only type of
/// distributed message sent at present is DistribSearch (distributed code 3).
public final class DistribEmbeddedMessage: DistribMessage, @unchecked Sendable {
    public var distribCode = 0
    public var distribMessage = Data()

    override var isExcludedFromLog: Bool { true }

    public convenience init(distribCode: Int, distribMessage: Data) {
        self.init()
        self.distribCode = distribCode
        self.distribMessage = distribMessage
    }

    override func copyForChildPeer() -> DistribMessage {
        DistribEmbeddedMessage(distribCode: distribCode, distribMessage: distribMessage)
    }

    override func makeNetworkMessage() throws -> Data {
        var message = Data()
        message.appendUInt8(distribCode)
        message.append(distribMessage)
        return message
    }

    override func parseNetworkMessage(_ message: Data) throws {
        var reader = MessageReader(message, position: 3)
        distribCode = try reader.readUInt8()
        distribMessage = reader.remainingData()
    }
}
