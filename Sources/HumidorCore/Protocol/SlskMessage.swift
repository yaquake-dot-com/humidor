// SPDX-License-Identifier: GPL-3.0-or-later
//
// Message classes exchanged between the networking thread and the rest of the
// application. There are three kinds of messages: internal messages, server
// messages and peer-to-peer messages (between clients).

import Foundation

// MARK: - Tokens

private let searchTokensLock = NSLock()
nonisolated(unsafe) private var searchTokensAllowed = Set<Int>()

/// Search tokens for which results are currently accepted. Accessed from both
/// the main thread and the networking thread.
public enum SearchTokens {
    public static func allow(_ token: Int) {
        _ = searchTokensLock.withLock { searchTokensAllowed.insert(token) }
    }

    public static func disallow(_ token: Int) {
        _ = searchTokensLock.withLock { searchTokensAllowed.remove(token) }
    }

    public static func isAllowed(_ token: Int) -> Bool {
        searchTokensLock.withLock { searchTokensAllowed.contains(token) }
    }
}

/// Returns a random token in a large enough range to effectively prevent
/// conflicting tokens between sessions.
public func initialToken() -> Int {
    Int.random(in: 0...(Int(UInt32.max) / 1000))
}

/// Increments a token used by file search, transfer and connection requests.
public func incrementToken(_ token: Int) -> Int {
    // Protocol messages use unsigned integers for tokens
    let token = (token < 0 || token >= Int(UInt32.max)) ? 0 : token
    return token + 1
}

// MARK: - Constants

public enum MessageType: String, Sendable {
    case `internal` = "N"
    case initialization = "I"
    case server = "S"
    case peer = "P"
    case file = "F"
    case distributed = "D"
}

public enum ConnectionType: String, Sendable {
    case server = "S"
    case peer = "P"
    case file = "F"
    case distributed = "D"
}

public enum LoginFailure {
    public static let username = "INVALIDUSERNAME"
    public static let password = "INVALIDPASS"
    public static let version = "INVALIDVERSION"
}

public enum UserStatus: Int, Sendable {
    case offline = 0
    case away = 1
    case online = 2
}

public enum TransferDirection: Int, Sendable {
    case download = 0
    case upload = 1
}

public enum TransferRejectReason {
    public static let queued = "Queued"
    public static let complete = "Complete"
    public static let cancelled = "Cancelled"
    public static let fileReadError = "File read error."
    public static let fileNotShared = "File not shared."
    public static let banned = "Banned"
    public static let pendingShutdown = "Pending shutdown."
    public static let tooManyFiles = "Too many files"
    public static let tooManyMegabytes = "Too many megabytes"
    public static let disallowedExtension = "Disallowed extension"
}

public enum FileAttribute: Int, Sendable {
    case bitrate = 0
    case duration = 1
    case vbr = 2
    case encoder = 3
    case sampleRate = 4
    case bitDepth = 5
}

// MARK: - Sockets and Addresses

/// A socket owned by the networking thread. Messages reference sockets to
/// identify the connection they belong to.
public final class Socket: Hashable, Sendable, CustomStringConvertible {
    public let fileDescriptor: Int32

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    public static func == (lhs: Socket, rhs: Socket) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public var description: String {
        "<socket fd=\(fileDescriptor)>"
    }
}

public struct PeerAddress: Hashable, Sendable, CustomStringConvertible {
    public var ipAddress: String
    public var port: Int

    public init(_ ipAddress: String, _ port: Int) {
        self.ipAddress = ipAddress
        self.port = port
    }

    public var description: String {
        "(\(ipAddress), \(port))"
    }
}

// MARK: - Base Message

/// Parent class for all messages.
public class SlskMessage: CustomStringConvertible, @unchecked Sendable {

    public class var messageType: MessageType { .internal }

    /// Properties not included in the string representation (e.g. passwords)
    class var excludedAttributes: Set<String> { [] }

    /// Messages not written to the message debug log
    var isExcludedFromLog: Bool { false }

    /// Set when a received message was rejected (e.g. from an ignored user),
    /// and should not be processed further by the user interface.
    public var isIgnored = false

    public required init() {}

    public var messageType: MessageType {
        Self.messageType
    }

    func makeNetworkMessage() throws -> Data {
        throw MessageError.packingNotSupported(String(describing: type(of: self)))
    }

    func parseNetworkMessage(_ message: Data) throws {
        throw MessageError.parsingNotSupported(String(describing: type(of: self)))
    }

    public var description: String {
        let excluded = Self.excludedAttributes
        var attributes: [String] = []
        var mirror: Mirror? = Mirror(reflecting: self)

        while let current = mirror {
            for child in current.children {
                guard let label = child.label, !excluded.contains(label) else {
                    continue
                }
                attributes.append("'\(label)': \(describeValue(child.value))")
            }
            mirror = current.superclassMirror
        }

        return "<\(messageType.rawValue) - \(type(of: self))> {\(attributes.joined(separator: ", "))}"
    }

    private func describeValue(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)

        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else {
                return "nil"
            }
            return describeValue(child.value)
        }

        if let string = value as? String {
            return "'\(string)'"
        }

        if let data = value as? Data {
            return "<\(data.count) bytes>"
        }

        return String(describing: value)
    }
}

// MARK: - Internal Messages

public class InternalMessage: SlskMessage, @unchecked Sendable {
    override public class var messageType: MessageType { .internal }
}

public final class CloseConnection: InternalMessage, @unchecked Sendable {
    public var sock: Socket?

    public convenience init(sock: Socket?) {
        self.init()
        self.sock = sock
    }
}

/// Login credentials sent to the networking thread.
public struct LoginCredentials: Sendable {
    public var username: String
    public var password: String
}

/// Sent to the networking thread to establish a server connection.
public final class ServerConnect: InternalMessage, @unchecked Sendable {
    public var addr: ServerAddress?
    public var login: LoginCredentials?
    public var interfaceName: String?
    public var interfaceAddress: String?
    public var listenPort: Int?
    public var portmapper: PortMapper?

    override class var excludedAttributes: Set<String> { ["login"] }

    public convenience init(addr: ServerAddress, login: LoginCredentials, interfaceName: String?,
                            interfaceAddress: String?, listenPort: Int, portmapper: PortMapper?) {
        self.init()
        self.addr = addr
        self.login = login
        self.interfaceName = interfaceName
        self.interfaceAddress = interfaceAddress
        self.listenPort = listenPort
        self.portmapper = portmapper
    }
}

public final class ServerDisconnect: InternalMessage, @unchecked Sendable {
    public var manualDisconnect = false

    public convenience init(manualDisconnect: Bool) {
        self.init()
        self.manualDisconnect = manualDisconnect
    }
}

public final class ServerReconnect: InternalMessage, @unchecked Sendable {
    public var manualReconnect = false

    public convenience init(manualReconnect: Bool) {
        self.init()
        self.manualReconnect = manualReconnect
    }
}

/// Sent to the networking thread to tell it to emit events for a list of
/// network messages.
///
/// Currently used after shares have rescanned to process any QueueUpload
/// messages that arrived while scanning.
public final class EmitNetworkMessageEvents: InternalMessage, @unchecked Sendable {
    public var msgs: [SlskMessage] = []

    public convenience init(msgs: [SlskMessage]) {
        self.init()
        self.msgs = msgs
    }
}

/// Sent to the networking thread to pass the file handle to write to.
public final class DownloadFile: InternalMessage, @unchecked Sendable {
    public var sock: Socket?
    public var token: Int?
    public var file: FileHandle?
    public var leftBytes = 0
    public var speed = 0

    public convenience init(sock: Socket?, token: Int, file: FileHandle, leftBytes: Int) {
        self.init()
        self.sock = sock
        self.token = token
        self.file = file
        self.leftBytes = leftBytes
    }
}

/// Sent to the networking thread to pass the file handle to read from.
public final class UploadFile: InternalMessage, @unchecked Sendable {
    public var sock: Socket?
    public var token: Int?
    public var file: FileHandle?
    public var size = 0
    public var sentBytes = 0
    public var offset: Int?
    public var speed = 0

    public convenience init(sock: Socket?, token: Int, file: FileHandle, size: Int, sentBytes: Int = 0,
                            offset: Int? = nil) {
        self.init()
        self.sock = sock
        self.token = token
        self.file = file
        self.size = size
        self.sentBytes = sentBytes
        self.offset = offset
    }
}

/// Sent to the networking thread to indicate changes in bandwidth shaping rules.
public final class SetUploadLimit: InternalMessage, @unchecked Sendable {
    public var limit = 0
    public var limitBy = false

    public convenience init(limit: Int, limitBy: Bool) {
        self.init()
        self.limit = limit
        self.limitBy = limitBy
    }
}

/// Sent to the networking thread to indicate changes in bandwidth shaping rules.
public final class SetDownloadLimit: InternalMessage, @unchecked Sendable {
    public var limit = 0

    public convenience init(limit: Int) {
        self.init()
        self.limit = limit
    }
}

// MARK: - File Lists

public struct AudioQuality: Hashable, Sendable {
    public var bitrate: Int?
    public var isVBR: Bool?
    public var sampleRate: Int?
    public var bitDepth: Int?

    public init(bitrate: Int? = nil, isVBR: Bool? = nil, sampleRate: Int? = nil, bitDepth: Int? = nil) {
        self.bitrate = bitrate
        self.isVBR = isVBR
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }
}

/// A shared file, as stored in the shares database.
public struct SharedFileInfo: Hashable, Sendable {
    public var virtualPath: String
    public var size: Int
    public var quality: AudioQuality?
    public var duration: Int?

    public init(virtualPath: String, size: Int, quality: AudioQuality?, duration: Int?) {
        self.virtualPath = virtualPath
        self.size = size
        self.quality = quality
        self.duration = duration
    }
}

/// A file entry received in a file list (search results, browsed shares,
/// folder contents).
public struct FileListEntry: Hashable, Sendable {
    public var code: Int
    public var name: String
    public var size: Int
    public var attributes: [Int: Int]

    public init(code: Int = 1, name: String, size: Int, attributes: [Int: Int] = [:]) {
        self.code = code
        self.name = name
        self.size = size
        self.attributes = attributes
    }
}

/// Audio properties of a file, parsed from its file attributes.
public struct FileAttributes: Hashable, Sendable {
    public var bitrate: Int?
    public var length: Int?
    public var vbr: Int?
    public var sampleRate: Int?
    public var bitDepth: Int?
}

/// Human-readable audio quality and length of a file.
public struct AudioQualityLength: Hashable, Sendable {
    public var humanQuality: String
    public var bitrate: Int
    public var humanLength: String
    public var length: Int
}

public enum FileListMessage {

    static let validFileAttributes: Set<Int> = [
        FileAttribute.bitrate.rawValue,
        FileAttribute.duration.rawValue,
        FileAttribute.vbr.rawValue,
        FileAttribute.sampleRate.rawValue,
        FileAttribute.bitDepth.rawValue
    ]

    public static func packFileInfo(_ fileInfo: SharedFileInfo) -> Data {
        var message = Data()
        let quality = fileInfo.quality
        let bitrate = quality?.bitrate
        let isVBR = quality?.isVBR
        let sampleRate = quality?.sampleRate
        let bitDepth = quality?.bitDepth
        let duration = fileInfo.duration

        message.appendUInt8(1)
        message.appendString(fileInfo.virtualPath)
        message.appendUInt64(fileInfo.size)
        message.appendUInt32(0)  // empty ext

        var numAttributes = 0
        var attributes = Data()

        func appendAttribute(_ attribute: FileAttribute, _ value: Int) {
            attributes.appendUInt32(attribute.rawValue)
            attributes.appendUInt32(value)
            numAttributes += 1
        }

        let isLossless = bitDepth != nil

        if isLossless {
            if let duration { appendAttribute(.duration, duration) }
            if let sampleRate { appendAttribute(.sampleRate, sampleRate) }
            if let bitDepth { appendAttribute(.bitDepth, bitDepth) }
        } else {
            if let bitrate { appendAttribute(.bitrate, bitrate) }
            if let duration { appendAttribute(.duration, duration) }
            if bitrate != nil { appendAttribute(.vbr, isVBR == true ? 1 : 0) }
        }

        message.appendUInt32(numAttributes)
        message.append(attributes)

        return message
    }

    static func parseFileSize(_ reader: inout MessageReader) throws -> Int {
        if try reader.peekByte(at: 7) == 255 {
            // Soulseek NS bug: >2 GiB files show up as ~16 EiB when unpacking the size
            // as uint64 (8 bytes), due to the first 4 bytes containing the size, and the
            // last 4 bytes containing garbage (a value of 4294967295 bytes, integer limit).
            // Only unpack the first 4 bytes to work around this issue.
            let size = try reader.readUInt32()
            _ = try reader.readUInt32()
            return size
        }

        // Everything looks fine, parse size as usual
        return try reader.readUInt64()
    }

    static func unpackFileAttributes(_ reader: inout MessageReader) throws -> [Int: Int] {
        var attributes: [Int: Int] = [:]
        let numAttributes = try reader.readUInt32()

        for _ in 0..<numAttributes {
            let attributeNum = try reader.readUInt32()
            let attribute = try reader.readUInt32()

            if validFileAttributes.contains(attributeNum) {
                attributes[attributeNum] = attribute
            }
        }

        return attributes
    }

    /// Reads a single file entry (code, name, size, ext, attributes).
    static func readFileEntry(_ reader: inout MessageReader, parseLargeSizes: Bool = true) throws -> FileListEntry {
        let code = try reader.readUInt8()
        let name = try reader.readString()
        let size = parseLargeSizes ? try parseFileSize(&reader) : try reader.readUInt64()
        let extLength = try reader.readUInt32()  // Obsolete, ignore
        reader.skip(extLength)
        let attributes = try unpackFileAttributes(&reader)

        return FileListEntry(code: code, name: name, size: size, attributes: attributes)
    }

    public static func parseFileAttributes(_ attributes: [Int: Int]?) -> FileAttributes {
        let attributes = attributes ?? [:]

        return FileAttributes(
            bitrate: attributes[FileAttribute.bitrate.rawValue],
            length: attributes[FileAttribute.duration.rawValue],
            vbr: attributes[FileAttribute.vbr.rawValue],
            sampleRate: attributes[FileAttribute.sampleRate.rawValue],
            bitDepth: attributes[FileAttribute.bitDepth.rawValue]
        )
    }

    public static func parseAudioQualityLength(fileSize: Int, attributes: [Int: Int]?,
                                               alwaysShowBitrate: Bool = false) -> AudioQualityLength {
        let parsed = parseFileAttributes(attributes)
        var bitrate: Int
        var length: Int
        let humanQuality: String
        let humanLengthValue: String

        if let parsedBitrate = parsed.bitrate {
            bitrate = parsedBitrate
        } else if let sampleRate = parsed.sampleRate, let bitDepth = parsed.bitDepth, sampleRate > 0, bitDepth > 0 {
            // Bitrate = sample rate (Hz) * word length (bits) * channel count
            // Bitrate = 44100 * 16 * 2
            bitrate = (sampleRate * bitDepth * 2) / 1000
        } else {
            bitrate = -1
        }

        if let parsedLength = parsed.length {
            length = parsedLength
        } else if bitrate > 0 {
            // Dividing the file size by the bitrate in Bytes should give us a good enough approximation
            length = fileSize / (bitrate * 125)
        } else {
            length = -1
        }

        // Ignore invalid values
        if bitrate <= 0 || bitrate > Int(UInt32.max) {
            bitrate = 0
            humanQuality = ""

        } else if let sampleRate = parsed.sampleRate, let bitDepth = parsed.bitDepth, sampleRate > 0, bitDepth > 0 {
            var quality = String(format: "%.3g kHz / %d bit", Double(sampleRate) / 1000, bitDepth)

            if alwaysShowBitrate {
                quality += " / \(bitrate) kbps"
            }
            humanQuality = quality

        } else {
            humanQuality = parsed.vbr == 1 ? "\(bitrate) kbps (vbr)" : "\(bitrate) kbps"
        }

        if length < 0 || length > Int(UInt32.max) {
            length = 0
            humanLengthValue = ""
        } else {
            humanLengthValue = humanLength(length)
        }

        return AudioQualityLength(humanQuality: humanQuality, bitrate: bitrate, humanLength: humanLengthValue,
                                  length: length)
    }
}

// MARK: - Recommendations

public struct Recommendation: Hashable, Sendable {
    public var item: String
    public var rating: Int
}

enum RecommendationsMessage {
    private static func populateRecommendations(_ recommendations: inout [Recommendation],
                                                _ unrecommendations: inout [Recommendation],
                                                _ reader: inout MessageReader) throws {
        let count = try reader.readUInt32()

        for _ in 0..<count {
            let key = try reader.readString()
            let rating = try reader.readInt32()
            let item = Recommendation(item: key, rating: rating)

            if rating >= 0 {
                if !recommendations.contains(item) { recommendations.append(item) }
            } else if !unrecommendations.contains(item) {
                unrecommendations.append(item)
            }
        }
    }

    static func parseRecommendations(_ reader: inout MessageReader) throws
        -> (recommendations: [Recommendation], unrecommendations: [Recommendation]) {
        var recommendations: [Recommendation] = []
        var unrecommendations: [Recommendation] = []

        try populateRecommendations(&recommendations, &unrecommendations, &reader)

        if reader.hasRemaining {
            try populateRecommendations(&recommendations, &unrecommendations, &reader)
        }

        return (recommendations, unrecommendations)
    }
}

// MARK: - Users

/// When we join a room, the server sends us a bunch of these for each user.
public struct UserData: Hashable, Sendable {
    public var username: String
    public var status: Int?
    public var avgSpeed: Int?
    public var uploadNum: Int?
    public var unknown: Int?
    public var files: Int?
    public var dirs: Int?
    public var slotsFull: Int?
    public var country: String?

    public init(username: String) {
        self.username = username
    }
}

enum UsersMessage {
    static func parseUsers(_ reader: inout MessageReader) throws -> [UserData] {
        let numUsers = try reader.readUInt32()
        var users: [UserData] = []
        users.reserveCapacity(Swift.min(numUsers, 100_000))

        for _ in 0..<numUsers {
            users.append(UserData(username: try reader.readString()))
        }

        let statusCount = try reader.readUInt32()
        for index in 0..<statusCount {
            guard index < users.count else { throw MessageError.missingField("users") }
            users[index].status = try reader.readUInt32()
        }

        let statsCount = try reader.readUInt32()
        for index in 0..<statsCount {
            guard index < users.count else { throw MessageError.missingField("users") }
            users[index].avgSpeed = try reader.readUInt32()
            users[index].uploadNum = try reader.readUInt32()
            users[index].unknown = try reader.readUInt32()
            users[index].files = try reader.readUInt32()
            users[index].dirs = try reader.readUInt32()
        }

        let slotsCount = try reader.readUInt32()
        for index in 0..<slotsCount {
            guard index < users.count else { throw MessageError.missingField("users") }
            users[index].slotsFull = try reader.readUInt32()
        }

        let countryCount = try reader.readUInt32()
        for index in 0..<countryCount {
            guard index < users.count else { throw MessageError.missingField("users") }
            users[index].country = try reader.readString()
        }

        return users
    }
}
