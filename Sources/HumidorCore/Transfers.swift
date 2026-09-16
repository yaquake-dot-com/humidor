// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Status of a transfer. Besides the statuses below, a transfer can have a
/// rejection reason sent by the remote peer as its status.
public struct TransferStatus: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let queued = TransferStatus(rawValue: "Queued")
    public static let gettingStatus = TransferStatus(rawValue: "Getting status")
    public static let transferring = TransferStatus(rawValue: "Transferring")
    public static let paused = TransferStatus(rawValue: "Paused")
    public static let cancelled = TransferStatus(rawValue: "Cancelled")
    public static let filtered = TransferStatus(rawValue: "Filtered")
    public static let finished = TransferStatus(rawValue: "Finished")
    public static let userLoggedOff = TransferStatus(rawValue: "User logged off")
    public static let connectionClosed = TransferStatus(rawValue: "Connection closed")
    public static let connectionTimeout = TransferStatus(rawValue: "Connection timeout")
    public static let downloadFolderError = TransferStatus(rawValue: "Download folder error")
    public static let localFileError = TransferStatus(rawValue: "Local file error")

    /// Statuses used internally, which remote peers cannot set
    public static let internalStatuses: Set<TransferStatus> = [
        .queued, .gettingStatus, .transferring, .paused, .cancelled, .filtered, .finished, .userLoggedOff,
        .connectionClosed, .connectionTimeout, .downloadFolderError, .localFileError
    ]

    public var description: String { rawValue }
}

/// Holds information about a single transfer.
public final class Transfer: Hashable {
    public let username: String
    public let virtualPath: String
    public var folderPath: String
    public var size: Int
    public var status: TransferStatus?
    public var currentByteOffset: Int?
    public var fileAttributes: [Int: Int]

    public var sock: Socket?
    public var fileHandle: FileHandle?
    public var filePath: String?
    public var token: Int?
    public var queuePosition = 0
    /// Status modifier, e.g. "privileged" or "prioritized"
    public var modifier: String?
    var requestTimerID: Int?
    public var startTime: Double?
    public var lastByteOffset: Int?
    public var transferredBytesTotal = 0
    public var speed = 0
    public var averageSpeed = 0
    public var timeElapsed = 0.0
    public var timeLeft = 0
    public var legacyAttempt = false
    public var retryAttempt = false
    public var sizeChanged = false

    public init(username: String, virtualPath: String, folderPath: String = "", size: Int = 0,
                fileAttributes: [Int: Int]? = nil, status: TransferStatus? = nil, currentByteOffset: Int? = nil) {
        self.username = username
        self.virtualPath = virtualPath
        self.folderPath = folderPath
        self.size = size
        self.status = status
        self.currentByteOffset = currentByteOffset
        self.fileAttributes = fileAttributes ?? [:]
    }

    public static func == (lhs: Transfer, rhs: Transfer) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// Shared logic of downloads and uploads.
@MainActor
public class Transfers {

    /// Transfers, keyed by username and virtual path
    public internal(set) var transfers = OrderedDictionary<String, Transfer>()
    var queuedTransfers = OrderedSet<Transfer>()
    public internal(set) var queuedUsers: [String: OrderedDictionary<String, Transfer>] = [:]
    public internal(set) var activeUsers: [String: [Int: Transfer]] = [:]
    public internal(set) var failedUsers: [String: OrderedDictionary<String, Transfer>] = [:]
    let transfersFilePath: String
    public internal(set) var totalBandwidth = 0

    let name: String
    var allowSavingTransfers = false
    var onlineUsers = Set<String>()
    var userQueueLimits: [String: Int] = [:]
    var userQueueSizes: [String: Int] = [:]

    init(name: String) {
        self.name = name
        transfersFilePath = (config.dataFolderPath as NSString).appendingPathComponent("\(name).json")

        events.connect(.quit) { [self] in quit() }
        events.connect(.serverLogin) { [self] msg in serverLogin(msg) }
        events.connect(.serverDisconnect) { [self] msg in serverDisconnect(msg) }
        events.connect(.start) { [self] in start() }
    }

    static func key(_ username: String, _ virtualPath: String) -> String {
        username + virtualPath
    }

    func start() {
        loadTransfers()
        allowSavingTransfers = true

        // Save list of transfers every 3 minutes
        events.schedule(delay: 180, repeat: true) { [self] in saveTransfers() }

        updateTransferLimits()
    }

    func quit() {
        saveTransfers()
        allowSavingTransfers = false

        transfers.removeAll()
        failedUsers.removeAll()
    }

    func serverLogin(_ msg: Login) {
        guard msg.success else {
            return
        }

        // Watch transfers for user status updates
        for username in failedUsers.keys {
            core.users.watchUser(username, context: name)
        }

        updateTransferLimits()
    }

    func serverDisconnect(_ msg: ServerDisconnect) {
        let userTransfers = queuedUsers.values.flatMap(\.values)
            + activeUsers.values.flatMap(\.values)
            + failedUsers.values.flatMap(\.values)

        for transfer in userTransfers {
            abortTransfer(transfer, status: .userLoggedOff)
        }

        queuedTransfers.removeAll()
        queuedUsers.removeAll()
        activeUsers.removeAll()
        onlineUsers.removeAll()
        userQueueLimits.removeAll()
        userQueueSizes.removeAll()

        totalBandwidth = 0
    }

    // MARK: Load Transfers

    /// Loads a file of transfers in JSON format.
    static func loadTransfersFile(_ transfersFile: String) throws -> [[Any]]? {
        guard FileManager.default.fileExists(atPath: transfersFile) else {
            return nil
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: transfersFile))
        return try JSONSerialization.jsonObject(with: data) as? [[Any]]
    }

    func loadTransfers() {
        preconditionFailure("Subclasses must implement loadTransfers()")
    }

    private func loadFileAttributes(_ transferRow: [Any]) -> [Int: Int]? {
        guard transferRow.count >= 7 else {
            return nil
        }

        let loadedFileAttributes = transferRow[6]

        if let attributes = loadedFileAttributes as? [String: Any] {
            // JSON stores file attribute types as strings, convert them back to integers
            var fileAttributes: [Int: Int] = [:]

            for (key, value) in attributes {
                if let key = Int(key), let value = (value as? NSNumber)?.intValue {
                    fileAttributes[key] = value
                }
            }
            return fileAttributes.isEmpty ? nil : fileAttributes
        }

        // Legacy bitrate/duration strings
        guard let bitrate = loadedFileAttributes as? String, !bitrate.isEmpty else {
            return nil
        }

        var fileAttributes: [Int: Int] = [:]
        let isVBR = bitrate.contains(" (vbr)")

        if let value = Int(bitrate.replacingOccurrences(of: " (vbr)", with: "")) {
            fileAttributes[FileAttribute.bitrate.rawValue] = value

            if isVBR {
                fileAttributes[FileAttribute.vbr.rawValue] = 1
            }
        }

        guard transferRow.count >= 8, let loadedLength = transferRow[7] as? String, loadedLength.contains(":") else {
            return fileAttributes
        }

        // Convert HH:mm:ss to seconds
        var seconds = 0

        for part in loadedLength.split(separator: ":") {
            seconds = seconds * 60 + (Int(part) ?? 0)
        }

        fileAttributes[FileAttribute.duration.rawValue] = seconds
        return fileAttributes
    }

    func storedTransfers(_ transfersFilePath: String, loadOnlyFinished: Bool = false) -> [Transfer] {
        guard let transferRows = loadFile(transfersFilePath, { try Self.loadTransfersFile($0) }) ?? nil else {
            return []
        }

        let allowedStatuses: Set<TransferStatus> = [.paused, .filtered, .finished]
        var normalizedPaths: [String: String] = [:]
        var result: [Transfer] = []

        for transferRow in transferRows {
            guard transferRow.count >= 3,
                  let username = transferRow[0] as? String,
                  let virtualPath = transferRow[1] as? String,
                  var folderPath = transferRow[2] as? String else {
                continue
            }

            if !folderPath.isEmpty {
                // Normalize and cache path
                if let normalizedPath = normalizedPaths[folderPath] {
                    folderPath = normalizedPath
                } else {
                    let normalizedPath = (folderPath as NSString).standardizingPath
                    normalizedPaths[folderPath] = normalizedPath
                    folderPath = normalizedPath
                }
            }

            // Status
            var statusString = transferRow.count >= 4 ? (transferRow[3] as? String) : nil

            if statusString == "Aborted" {
                statusString = TransferStatus.paused.rawValue
            }

            var status = statusString.map(TransferStatus.init(rawValue:))

            if loadOnlyFinished && status != .finished {
                continue
            }

            if status == nil || !allowedStatuses.contains(status!) {
                status = .userLoggedOff
            }

            // Size / offset
            var size = 0
            var currentByteOffset: Int?

            if transferRow.count >= 5, let loadedSize = transferRow[4] as? NSNumber {
                size = loadedSize.intValue
            }

            if transferRow.count >= 6, let loadedByteOffset = transferRow[5] as? NSNumber, loadedByteOffset.intValue != 0 {
                currentByteOffset = loadedByteOffset.intValue
            }

            // File attributes
            let fileAttributes = loadFileAttributes(transferRow)

            result.append(Transfer(username: username, virtualPath: virtualPath, folderPath: folderPath, size: size,
                                   fileAttributes: fileAttributes, status: status,
                                   currentByteOffset: currentByteOffset))
        }

        return result
    }

    // MARK: File Actions

    static func closeFile(_ transfer: Transfer) {
        let fileHandle = transfer.fileHandle
        transfer.fileHandle = nil

        guard let fileHandle else {
            return
        }

        do {
            try fileHandle.close()
        } catch {
            log.addTransfer("Failed to close file \(transfer.filePath ?? ""): \(error.localizedDescription)")
        }
    }

    // MARK: User Actions

    /// Unwatches a user when status updates are no longer required, i.e. no
    /// transfers remain, or all remaining transfers are finished/filtered/paused.
    func unwatchStaleUser(_ username: String) {
        if activeUsers[username] != nil || queuedUsers[username] != nil || failedUsers[username] != nil {
            return
        }

        core.users.unwatchUser(username, context: name)
    }

    // MARK: Limits

    public func updateTransferLimits() {
        preconditionFailure("Subclasses must implement updateTransferLimits()")
    }

    // MARK: Events

    func transferTimeout(_ transfer: Transfer) {
        abortTransfer(transfer, status: .connectionTimeout)
    }

    // MARK: Transfer Actions

    func appendTransfer(_ transfer: Transfer) {
        transfers[Self.key(transfer.username, transfer.virtualPath)] = transfer
    }

    func abortTransfer(_ transfer: Transfer, status: TransferStatus? = nil, deniedMessage: String? = nil) {
        let username = transfer.username
        let virtualPath = transfer.virtualPath

        transfer.legacyAttempt = false
        transfer.sizeChanged = false

        // Reset last byte offset to avoid incorrect offset subtractions between
        // previous and new transfer sessions when updating statistics
        transfer.lastByteOffset = nil

        if let sock = transfer.sock {
            core.sendMessageToNetworkThread(CloseConnection(sock: sock))
        }

        if transfer.fileHandle != nil {
            Self.closeFile(transfer)

        } else if let deniedMessage, queuedUsers[username]?[virtualPath] != nil {
            core.sendMessageToPeer(username, UploadDenied(file: virtualPath, reason: deniedMessage))
        }

        deactivateTransfer(transfer)
        dequeueTransfer(transfer)
        unfailTransfer(transfer)

        if let status {
            transfer.status = status

            if ![.finished, .filtered, .paused].contains(status) {
                failTransfer(transfer)
            }
        }

        // Only attempt to unwatch user after the transfer status is fully set
        unwatchStaleUser(username)
    }

    func updateTransfer(_ transfer: Transfer, updateParent: Bool = true) {
        preconditionFailure("Subclasses must implement updateTransfer()")
    }

    func updateTransferProgress(_ transfer: Transfer, statID: StatisticID, currentByteOffset: Int? = nil,
                                speed: Int? = nil) {
        let size = transfer.size
        let timeElapsed = ProcessInfo.processInfo.systemUptime - (transfer.startTime ?? ProcessInfo.processInfo.systemUptime)

        transfer.status = .transferring
        transfer.timeElapsed = timeElapsed
        transfer.timeLeft = 0

        guard let currentByteOffset else {
            return
        }

        transfer.currentByteOffset = currentByteOffset
        let transferredFragmentSize = currentByteOffset - (transfer.lastByteOffset ?? currentByteOffset)
        transfer.lastByteOffset = currentByteOffset

        if transferredFragmentSize > 0 {
            transfer.transferredBytesTotal += transferredFragmentSize
            core.statistics.appendStatValue(statID, transferredFragmentSize)
        }

        transfer.averageSpeed = Swift.max(0, Int(Double(transfer.transferredBytesTotal) / Swift.max(1, timeElapsed)))

        if let speed {
            transfer.speed = speed <= 0 ? transfer.averageSpeed : speed
        }

        if transfer.speed > 0 && size > currentByteOffset {
            transfer.timeLeft = (size - currentByteOffset) / transfer.speed
        }
    }

    func finishTransfer(_ transfer: Transfer) {
        deactivateTransfer(transfer)
        Self.closeFile(transfer)
        unwatchStaleUser(transfer.username)

        transfer.status = .finished
        transfer.currentByteOffset = transfer.size
        transfer.lastByteOffset = nil
    }

    var isAutoClearEnabled: Bool {
        preconditionFailure("Subclasses must implement isAutoClearEnabled")
    }

    func autoClearTransfer(_ transfer: Transfer) -> Bool {
        if isAutoClearEnabled {
            clearTransfer(transfer)
            return true
        }

        return false
    }

    func clearTransfer(_ transfer: Transfer, deniedMessage: String? = nil) {
        abortTransfer(transfer, deniedMessage: deniedMessage)
        transfers.removeValue(forKey: Self.key(transfer.username, transfer.virtualPath))
    }

    @discardableResult
    func enqueueTransfer(_ transfer: Transfer) -> Bool {
        core.users.watchUser(transfer.username, context: name)

        transfer.status = .queued

        queuedUsers[transfer.username, default: [:]][transfer.virtualPath] = transfer
        queuedTransfers.append(transfer)
        userQueueSizes[transfer.username, default: 0] += transfer.size

        return true
    }

    /// Optional hook, called when a user has no more queued transfers.
    func enqueueLimitedTransfers(_ username: String) {}

    @discardableResult
    func dequeueTransfer(_ transfer: Transfer) -> Bool {
        let username = transfer.username
        let virtualPath = transfer.virtualPath

        guard queuedUsers[username]?[virtualPath] != nil else {
            return false
        }

        userQueueSizes[username, default: 0] -= transfer.size
        queuedTransfers.remove(transfer)
        queuedUsers[username]?.removeValue(forKey: virtualPath)

        if (userQueueSizes[username] ?? 0) <= 0 {
            userQueueSizes.removeValue(forKey: username)
        }

        if queuedUsers[username]?.isEmpty == true {
            queuedUsers.removeValue(forKey: username)

            // No more queued transfers, resume limited transfers if present
            enqueueLimitedTransfers(username)
        }

        transfer.queuePosition = 0
        return true
    }

    func activateTransfer(_ transfer: Transfer, token: Int) {
        core.users.watchUser(transfer.username, context: name)

        transfer.status = .gettingStatus
        transfer.token = token
        transfer.speed = 0
        transfer.averageSpeed = 0
        transfer.queuePosition = 0

        // When our port is closed, certain clients can take up to ~30 seconds before they
        // initiate a 'F' connection, since they only send an indirect connection request after
        // attempting to connect to our port for a certain time period.
        // Known clients: Nicotine+ 2.2.0 - 3.2.0, 2 s; Soulseek NS, ~20 s; soulseeX, ~30 s.
        // To account for potential delays while initializing the connection, add 15 seconds
        // to the timeout value.

        transfer.requestTimerID = events.schedule(delay: 45) { [weak self, weak transfer] in
            guard let self, let transfer else { return }
            transferTimeout(transfer)
        }

        activeUsers[transfer.username, default: [:]][token] = transfer
    }

    @discardableResult
    func deactivateTransfer(_ transfer: Transfer) -> Bool {
        let username = transfer.username

        guard let token = transfer.token, activeUsers[username]?[token] != nil else {
            return false
        }

        activeUsers[username]?.removeValue(forKey: token)

        if activeUsers[username]?.isEmpty == true {
            activeUsers.removeValue(forKey: username)
        }

        if transfer.speed > 0 {
            totalBandwidth = Swift.max(0, totalBandwidth - transfer.speed)
        }

        if let requestTimerID = transfer.requestTimerID {
            events.cancelScheduled(requestTimerID)
            transfer.requestTimerID = nil
        }

        transfer.speed = transfer.averageSpeed
        transfer.sock = nil
        transfer.token = nil

        return true
    }

    func failTransfer(_ transfer: Transfer) {
        failedUsers[transfer.username, default: [:]][transfer.virtualPath] = transfer
    }

    @discardableResult
    func unfailTransfer(_ transfer: Transfer) -> Bool {
        let username = transfer.username
        let virtualPath = transfer.virtualPath

        guard failedUsers[username]?[virtualPath] != nil else {
            return false
        }

        failedUsers[username]?.removeValue(forKey: virtualPath)

        if failedUsers[username]?.isEmpty == true {
            failedUsers.removeValue(forKey: username)
        }

        return true
    }

    // MARK: Saving

    /// Rows of transfers to dump to file.
    func transferRows() -> [[Any]] {
        transfers.values.map { transfer in
            [
                transfer.username, transfer.virtualPath, transfer.folderPath, transfer.status?.rawValue ?? NSNull(),
                transfer.size, transfer.currentByteOffset ?? NSNull(),
                Dictionary(uniqueKeysWithValues: transfer.fileAttributes.map { (String($0.key), $0.value) })
            ]
        }
    }

    /// Saves the list of transfers.
    public func saveTransfers() {
        guard allowSavingTransfers else {
            // Don't save if transfers didn't load properly!
            return
        }

        try? FileManager.default.createDirectory(atPath: config.dataFolderPath, withIntermediateDirectories: true)

        let rows = transferRows()

        writeFileAndBackup(transfersFilePath) { data in
            // Dump every transfer to the file individually
            data.append(contentsOf: Array("[".utf8))

            for (index, row) in rows.enumerated() {
                if index > 0 {
                    data.append(contentsOf: Array(",\n".utf8))
                }
                data.append(try JSONSerialization.data(withJSONObject: row, options: [.withoutEscapingSlashes]))
            }

            data.append(contentsOf: Array("]".utf8))
        }
    }
}

// MARK: - Statistics

public enum StatisticID: String, CaseIterable, Sendable {
    case sinceTimestamp = "since_timestamp"
    case startedDownloads = "started_downloads"
    case completedDownloads = "completed_downloads"
    case downloadedSize = "downloaded_size"
    case startedUploads = "started_uploads"
    case completedUploads = "completed_uploads"
    case uploadedSize = "uploaded_size"

    var keyPath: WritableKeyPath<StatisticsSettings, Int> {
        switch self {
        case .sinceTimestamp: return \.sinceTimestamp
        case .startedDownloads: return \.startedDownloads
        case .completedDownloads: return \.completedDownloads
        case .downloadedSize: return \.downloadedSize
        case .startedUploads: return \.startedUploads
        case .completedUploads: return \.completedUploads
        case .uploadedSize: return \.uploadedSize
        }
    }
}

public struct StatUpdate: Sendable {
    public var statID: StatisticID
    public var sessionValue: Int
    public var totalValue: Int
}

public extension EventName where Payload == StatUpdate {
    static var updateStat: Self { .init("update-stat") }
}

@MainActor
public final class Statistics {
    public private(set) var sessionStats: [StatisticID: Int] = [:]

    init() {
        events.connect(.quit) { [self] in sessionStats.removeAll() }
        events.connect(.start) { [self] in start() }
    }

    private func start() {
        let now = Int(Date().timeIntervalSince1970)
        let defaults = StatisticsSettings()
        let current = config.statistics

        // Only populate total since date on first run
        if current.sinceTimestamp == 0
            && StatisticID.allCases.allSatisfy({ current[keyPath: $0.keyPath] == defaults[keyPath: $0.keyPath] }) {
            config.statistics.sinceTimestamp = now
        }

        for statID in StatisticID.allCases {
            sessionStats[statID] = statID == .sinceTimestamp ? now : 0
        }
    }

    public func appendStatValue(_ statID: StatisticID, _ value: Int) {
        sessionStats[statID, default: 0] += value
        config.statistics[keyPath: statID.keyPath] += value

        updateStat(statID)
    }

    private func updateStat(_ statID: StatisticID) {
        events.emit(.updateStat, StatUpdate(
            statID: statID, sessionValue: sessionStats[statID] ?? 0,
            totalValue: config.statistics[keyPath: statID.keyPath]
        ))
    }

    public func updateStats() {
        for statID in sessionStats.keys {
            updateStat(statID)
        }
    }

    public func resetStats() {
        let now = Int(Date().timeIntervalSince1970)

        for statID in StatisticID.allCases {
            let value = statID == .sinceTimestamp ? now : 0
            sessionStats[statID] = value
            config.statistics[keyPath: statID.keyPath] = value
        }

        updateStats()
    }
}
