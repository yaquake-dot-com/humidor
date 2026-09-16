// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Darwin
import Foundation

// MARK: - Events

public struct TransferUpdate {
    public var transfer: Transfer
    public var updateParent: Bool
}

public struct TransferAbort {
    public var transfer: Transfer
    public var status: TransferStatus
    public var updateParent: Bool
}

public struct TransfersAbort {
    public var transfers: [Transfer]
    public var status: TransferStatus
}

public struct TransfersClear {
    public var transfers: [Transfer]
    public var statuses: Set<TransferStatus>?
    public var clearDeleted: Bool
}

public struct LargeFolderDownload {
    public var username: String
    public var folderPath: String
    public var numFiles: Int
    /// Continues downloading the folder
    public var proceed: @MainActor () -> Void
}

public extension EventName where Payload == TransferUpdate {
    static var updateDownload: Self { .init("update-download") }
    static var clearDownload: Self { .init("clear-download") }
    static var updateUpload: Self { .init("update-upload") }
    static var clearUpload: Self { .init("clear-upload") }
}

public extension EventName where Payload == TransferAbort {
    static var abortDownload: Self { .init("abort-download") }
    static var abortUpload: Self { .init("abort-upload") }
}

public extension EventName where Payload == TransfersAbort {
    static var abortDownloads: Self { .init("abort-downloads") }
    static var abortUploads: Self { .init("abort-uploads") }
}

public extension EventName where Payload == TransfersClear {
    static var clearDownloads: Self { .init("clear-downloads") }
    static var clearUploads: Self { .init("clear-uploads") }
}

public extension EventName where Payload == String {
    static var folderDownloadFinished: Self { .init("folder-download-finished") }
}

public extension EventName where Payload == LargeFolderDownload {
    static var downloadLargeFolder: Self { .init("download-large-folder") }
}

public extension EventName where Payload == Void {
    static var updateDownloadLimits: Self { .init("update-download-limits") }
    static var updateUploadLimits: Self { .init("update-upload-limits") }
}

// MARK: - Downloads

final class RequestedFolder {
    let username: String
    let folderPath: String
    let downloadFolderPath: String?
    var requestTimerID: Int?
    var hasRetried = false
    var legacyAttempt = false

    init(username: String, folderPath: String, downloadFolderPath: String?) {
        self.username = username
        self.folderPath = folderPath
        self.downloadFolderPath = downloadFolderPath
    }
}

@MainActor
public final class Downloads: Transfers {

    private var requestedFolders: [String: [String: RequestedFolder]] = [:]
    private var requestedFolderToken = initialToken()

    private var folderBasenameByteLimits: [String: Int] = [:]
    private var pendingQueueMessages: [Transfer: QueueUpload] = [:]

    private var downloadQueueTimerID: Int?
    private var retryConnectionDownloadsTimerID: Int?
    private var retryIODownloadsTimerID: Int?

    init() {
        super.init(name: "downloads")

        events.connect(.downloadFileError) { [self] event in downloadFileError(event) }
        events.connect(.fileConnectionClosed) { [self] event in fileConnectionClosed(event) }
        events.connect(.fileTransferInit) { [self] msg in fileTransferInit(msg) }
        events.connect(.fileDownloadProgress) { [self] event in fileDownloadProgress(event) }
        events.connect(.folderContentsResponse) { [self] msg in folderContentsResponse(msg) }
        events.connect(.peerConnectionClosed) { [self] event in
            peerConnectionError(event.username, connType: event.connType, msgs: event.msgs, isTimeout: false)
        }
        events.connect(.peerConnectionError) { [self] event in
            peerConnectionError(event.username, connType: event.connType, msgs: event.msgs,
                                isOffline: event.isOffline)
        }
        events.connect(.placeInQueueResponse) { [self] msg in placeInQueueResponse(msg) }
        events.connect(.setConnectionStats) { [self] stats in totalBandwidth = stats.downloadBandwidth }
        events.connect(.sharesReady) { [self] _ in sharesReady() }
        events.connect(.transferRequest) { [self] msg in transferRequest(msg) }
        events.connect(.uploadDenied) { [self] msg in uploadDenied(msg) }
        events.connect(.uploadFailed) { [self] msg in uploadFailed(msg) }
        events.connect(.userStatus) { [self] msg in userStatus(msg) }
    }

    override func start() {
        super.start()
        updateDownloadFilters()
    }

    override func quit() {
        deleteStaleIncompleteDownloads()

        super.quit()

        folderBasenameByteLimits.removeAll()
    }

    override func serverLogin(_ msg: Login) {
        guard msg.success else {
            return
        }

        super.serverLogin(msg)

        // Request queue position of queued downloads every 5 minutes
        downloadQueueTimerID = events.schedule(delay: 300, repeat: true) { [self] in requestQueuePositions() }

        // Retry downloads failed due to connection issues every 3 minutes
        retryConnectionDownloadsTimerID = events.schedule(delay: 180, repeat: true) { [self] in
            retryFailedConnectionDownloads()
        }

        // Retry downloads failed due to file I/O errors every 15 minutes
        retryIODownloadsTimerID = events.schedule(delay: 900, repeat: true) { [self] in retryFailedIODownloads() }
    }

    override func serverDisconnect(_ msg: ServerDisconnect) {
        super.serverDisconnect(msg)

        for timerID in [downloadQueueTimerID, retryConnectionDownloadsTimerID, retryIODownloadsTimerID] {
            events.cancelScheduled(timerID)
        }

        for userRequestedFolders in requestedFolders.values {
            for requestedFolder in userRequestedFolders.values {
                if let timerID = requestedFolder.requestTimerID {
                    events.cancelScheduled(timerID)
                    requestedFolder.requestTimerID = nil
                }
            }
        }

        requestedFolders.removeAll()
    }

    // MARK: Load Transfers

    override func loadTransfers() {
        for transfer in storedTransfers(transfersFilePath) {
            appendTransfer(transfer)

            if transfer.status == .userLoggedOff {
                // Mark transfer as failed in order to resume it when connected
                failTransfer(transfer)
            }
        }
    }

    // MARK: Filters/Limits

    public func updateDownloadFilters() {
        var failed: [String: Error] = [:]
        var outFilter = "(\\\\("
        let downloadFilters = config.transfers.downloadFilters.sorted()

        // Get filters from config file and check their escaped status.
        // Test if they are valid regular expressions and save error messages
        for (index, item) in downloadFilters.enumerated() {
            var filter = item.pattern

            if item.isEscaped {
                filter = NSRegularExpression.escapedPattern(for: filter).replacingOccurrences(of: "\\*", with: ".*")
            }

            do {
                _ = try NSRegularExpression(pattern: "(\(filter))")
                outFilter += filter

                if index < downloadFilters.count - 1 {
                    outFilter += "|"
                }
            } catch {
                failed[filter] = error
            }
        }

        outFilter += ")$)"

        do {
            _ = try NSRegularExpression(pattern: outFilter)
        } catch {
            // Strange that individual filters _and_ the composite filter both fail
            log.add(String(localized: "Error: Download Filter failed! Verify your filters. Reason: \(error.localizedDescription)",
                           bundle: .module))
            config.transfers.downloadRegexp = ""
            return
        }

        config.transfers.downloadRegexp = outFilter

        // Send error messages for each failed filter to log window
        guard !failed.isEmpty else {
            return
        }

        let errors = failed.map { "Filter: \($0.key) Error: \($0.value.localizedDescription) " }.joined()
        log.add(String(localized: "Error: \(failed.count) Download filters failed! \(errors) ", bundle: .module))
    }

    override public func updateTransferLimits() {
        events.emit(.updateDownloadLimits)

        let speedLimit: Int

        switch config.transfers.useDownloadSpeedLimit {
        case .primary: speedLimit = config.transfers.downloadLimit
        case .alternative: speedLimit = config.transfers.downloadLimitAlt
        case .unlimited: speedLimit = 0
        }

        core.sendMessageToNetworkThread(SetDownloadLimit(limit: speedLimit))
    }

    // MARK: Transfer Actions

    override func updateTransfer(_ transfer: Transfer, updateParent: Bool = true) {
        events.emit(.updateDownload, TransferUpdate(transfer: transfer, updateParent: updateParent))
    }

    override var isAutoClearEnabled: Bool {
        config.transfers.autoClearDownloads
    }

    @discardableResult
    private func enqueueDownload(_ transfer: Transfer, bypassFilter: Bool = false) -> Bool {
        let username = transfer.username
        let virtualPath = transfer.virtualPath
        let size = transfer.size

        if !bypassFilter && config.transfers.enableFilters,
           let downloadRegexp = try? NSRegularExpression(pattern: config.transfers.downloadRegexp,
                                                         options: .caseInsensitive),
           downloadRegexp.firstMatch(in: virtualPath, range: NSRange(virtualPath.startIndex..., in: virtualPath)) != nil {
            log.addTransfer("Filtering: \(virtualPath)")

            if !autoClearTransfer(transfer) {
                abortTransfer(transfer, status: .filtered)
            }

            return false
        }

        if core.users.loginStatus == .offline || core.users.statuses[username] == .offline {
            // Either we are offline or the user we want to download from is
            abortTransfer(transfer, status: .userLoggedOff)
            return false
        }

        log.addTransfer("Adding file \(virtualPath) from user \(username) to download queue")

        let (_, fileExists) = completeDownloadFilePath(username: username, virtualPath: virtualPath, size: size,
                                                       downloadFolderPath: transfer.folderPath)

        if fileExists {
            finishTransfer(transfer)
            return false
        }

        super.enqueueTransfer(transfer)

        let msg = QueueUpload(file: virtualPath, legacyClient: transfer.legacyAttempt)

        if !core.shares.isInitialized {
            // Remain queued locally until our shares have initialized, to prevent invalid
            // messages about not sharing any files
            pendingQueueMessages[transfer] = msg
        } else {
            core.sendMessageToPeer(username, msg)
        }

        return true
    }

    override func enqueueTransfer(_ transfer: Transfer) -> Bool {
        enqueueDownload(transfer)
    }

    override func enqueueLimitedTransfers(_ username: String) {
        var numLimitedTransfers = 0

        guard let queueSizeLimit = userQueueLimits[username] else {
            return
        }

        for download in Array((failedUsers[username] ?? [:]).values) {
            if download.status?.rawValue != TransferRejectReason.queued {
                continue
            }

            if numLimitedTransfers >= queueSizeLimit {
                // Only enqueue a small number of downloads at a time
                return
            }

            unfailTransfer(download)

            if enqueueDownload(download) {
                updateTransfer(download)
            }

            numLimitedTransfers += 1
        }

        // No more limited downloads
        userQueueLimits.removeValue(forKey: username)
    }

    @discardableResult
    override func dequeueTransfer(_ transfer: Transfer) -> Bool {
        guard super.dequeueTransfer(transfer) else {
            return false
        }

        pendingQueueMessages.removeValue(forKey: transfer)
        return true
    }

    private func fileDownloadedActions(username: String, filePath: String) {
        if config.notifications.popupFile {
            let fileName = (filePath as NSString).lastPathComponent

            core.notifications?.showDownloadNotification(
                String(localized: "\(fileName) downloaded from \(username)", bundle: .module),
                title: String(localized: "File Downloaded", bundle: .module)
            )
        }

        let command = config.transfers.afterFinish

        guard !command.isEmpty else {
            return
        }

        do {
            try executeCommand(command, replacement: filePath)
            log.add(String(localized: "Executed: \(command)", bundle: .module))
        } catch {
            log.add(String(localized: "Executing '\(command)' failed: \(error.localizedDescription)", bundle: .module))
        }
    }

    private func folderDownloadedActions(username: String, folderPath: String) {
        guard !folderPath.isEmpty, folderPath != defaultDownloadFolder(username: username) else {
            return
        }

        let userDownloads = Array((queuedUsers[username] ?? [:]).values) + Array((activeUsers[username] ?? [:]).values)
            + Array((failedUsers[username] ?? [:]).values)

        if userDownloads.contains(where: { $0.folderPath == folderPath }) {
            return
        }

        events.emit(.folderDownloadFinished, folderPath)

        if config.notifications.popupFolder {
            core.notifications?.showDownloadNotification(
                String(localized: "\(folderPath) downloaded from \(username)", bundle: .module),
                title: String(localized: "Folder Downloaded", bundle: .module)
            )
        }

        let command = config.transfers.afterFolder

        guard !command.isEmpty else {
            return
        }

        do {
            try executeCommand(command, replacement: folderPath)
            log.add(String(localized: "Executed on folder: \(command)", bundle: .module))
        } catch {
            log.add(String(localized: "Executing '\(command)' failed: \(error.localizedDescription)", bundle: .module))
        }
    }

    private func moveFinishedTransfer(_ transfer: Transfer, incompleteFilePath: String) -> String? {
        let downloadFolderPath = transfer.folderPath.isEmpty
            ? defaultDownloadFolder(username: transfer.username) : transfer.folderPath

        let downloadBasename = downloadBasename(virtualPath: transfer.virtualPath,
                                                downloadFolderPath: downloadFolderPath, avoidConflict: true)
        let downloadFilePath = (downloadFolderPath as NSString).appendingPathComponent(downloadBasename)

        do {
            try FileManager.default.createDirectory(atPath: downloadFolderPath, withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: incompleteFilePath, toPath: downloadFilePath)

        } catch {
            log.add(String(localized: "Couldn't move '\(incompleteFilePath)' to '\(downloadFilePath)': \(error.localizedDescription)",
                           bundle: .module))
            abortTransfer(transfer, status: .downloadFolderError)
            core.notifications?.showDownloadNotification(
                error.localizedDescription, title: String(localized: "Download Folder Error", bundle: .module),
                highPriority: true
            )
            return nil
        }

        return downloadFilePath
    }

    override func finishTransfer(_ transfer: Transfer) {
        let username = transfer.username
        let virtualPath = transfer.virtualPath
        let alreadyExists = transfer.fileHandle == nil
        let incompleteFilePath = alreadyExists ? nil : transfer.filePath
        var downloadFilePath: String?

        super.finishTransfer(transfer)

        if !alreadyExists, let incompleteFilePath {
            downloadFilePath = moveFinishedTransfer(transfer, incompleteFilePath: incompleteFilePath)

            if downloadFilePath == nil {
                // Download was not moved successfully
                return
            }
        }

        if !autoClearTransfer(transfer) {
            updateTransfer(transfer)
        }

        guard !alreadyExists, let downloadFilePath else {
            log.addTransfer("File \(virtualPath) is already downloaded")
            return
        }

        core.statistics.appendStatValue(.completedDownloads, 1)

        // Attempt to show notification and execute commands
        fileDownloadedActions(username: username, filePath: downloadFilePath)
        folderDownloadedActions(username: username, folderPath: transfer.folderPath)

        core.pluginHandler?.downloadFinishedNotification(username, virtualPath: virtualPath, realPath: downloadFilePath)

        log.addDownload(String(localized: "Download finished: user \(username), file \(virtualPath)", bundle: .module))
    }

    override func abortTransfer(_ transfer: Transfer, status: TransferStatus? = nil, deniedMessage: String? = nil) {
        abortDownload(transfer, status: status, deniedMessage: deniedMessage)
    }

    private func abortDownload(_ transfer: Transfer, status: TransferStatus? = nil, deniedMessage: String? = nil,
                               updateParent: Bool = true) {
        if transfer.fileHandle != nil {
            log.addDownload(String(localized: "Download aborted, user \(transfer.username) file \(transfer.virtualPath)",
                                   bundle: .module))
        }

        super.abortTransfer(transfer, status: status, deniedMessage: deniedMessage)

        if let status {
            events.emit(.abortDownload, TransferAbort(transfer: transfer, status: status, updateParent: updateParent))
        }
    }

    override func clearTransfer(_ transfer: Transfer, deniedMessage: String? = nil) {
        clearDownload(transfer, deniedMessage: deniedMessage)
    }

    private func clearDownload(_ transfer: Transfer, deniedMessage: String? = nil, updateParent: Bool = true) {
        let virtualPath = transfer.virtualPath
        let username = transfer.username

        log.addTransfer("Clearing download \(virtualPath) from user \(username)")

        if transfers[Self.key(username, virtualPath)] == nil {
            log.add("FIXME: failed to remove download \(virtualPath) from user \(username), not present in list")
        }

        super.clearTransfer(transfer, deniedMessage: deniedMessage)
        events.emit(.clearDownload, TransferUpdate(transfer: transfer, updateParent: updateParent))
    }

    private func deleteStaleIncompleteDownloads() {
        guard allowSavingTransfers else {
            return
        }

        let incompleteDownloadFolderPath = incompleteDownloadFolder()
        let allowedIncompleteFilePaths = Set(transfers.values.compactMap { transfer -> String? in
            guard (transfer.currentByteOffset ?? 0) > 0, transfer.status != .finished else {
                return nil
            }
            return incompleteDownloadFilePath(username: transfer.username, virtualPath: transfer.virtualPath)
        })

        let prefix = "INCOMPLETE"
        let md5Length = 32
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

        let entries: [URL]

        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: incompleteDownloadFolderPath), includingPropertiesForKeys: [.isDirectoryKey])
        } catch {
            log.addTransfer("Cannot read incomplete download folder: \(error.localizedDescription)")
            return
        }

        for entry in entries {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                continue
            }

            if allowedIncompleteFilePaths.contains(entry.path) {
                continue
            }

            let basename = entry.lastPathComponent

            // Skip files that are not incomplete downloads
            guard basename.hasPrefix(prefix), basename.utf8.count > prefix.count + md5Length else {
                continue
            }

            let md5Part = basename.dropFirst(prefix.count).prefix(md5Length)

            guard md5Part.unicodeScalars.allSatisfy(hexDigits.contains) else {
                continue
            }

            // Incomplete file no longer has a download associated with it. Delete it.
            do {
                try FileManager.default.removeItem(at: entry)
                log.addTransfer("Deleted stale incomplete download \(entry.path)")
            } catch {
                log.addTransfer("Cannot delete incomplete download \(entry.path): \(error.localizedDescription)")
            }
        }
    }

    private func requestQueuePositions() {
        for download in queuedTransfers {
            core.sendMessageToPeer(download.username,
                                   PlaceInQueueRequest(file: download.virtualPath, legacyClient: download.legacyAttempt))
        }
    }

    private func retryFailedDownloads(withStatuses statuses: Set<TransferStatus>) {
        for failedDownloads in Array(failedUsers.values) {
            for download in Array(failedDownloads.values) {
                guard let status = download.status, statuses.contains(status) else {
                    continue
                }

                unfailTransfer(download)

                if enqueueDownload(download) {
                    updateTransfer(download)
                }
            }
        }
    }

    private func retryFailedConnectionDownloads() {
        retryFailedDownloads(withStatuses: [
            .connectionClosed, .connectionTimeout, TransferStatus(rawValue: TransferRejectReason.pendingShutdown)
        ])
    }

    private func retryFailedIODownloads() {
        retryFailedDownloads(withStatuses: [
            .downloadFolderError, .localFileError, TransferStatus(rawValue: TransferRejectReason.fileReadError)
        ])
    }

    public func canUpload(_ username: String) -> Bool {
        let transfers = config.transfers

        guard transfers.remoteDownloads else {
            return false
        }

        switch transfers.uploadAllowed {
        case 1:
            // Everyone
            return true
        case 2:
            // Buddies
            return core.buddies.users[username] != nil
        case 3:
            // Trusted buddies
            return core.buddies.users[username]?.isTrusted == true
        default:
            return false
        }
    }

    public func folderDestination(username: String, folderPath: String, rootFolderPath: String? = nil,
                                  downloadFolderPath: String? = nil) -> String {
        // Remove parent folders of the requested folder from path
        let parentFolderPath = (rootFolderPath?.isEmpty == false ? rootFolderPath! : folderPath)
        let removedParentFolders = parentFolderPath.range(of: "\\", options: .backwards)
            .map { String(parentFolderPath[..<$0.lowerBound]) } ?? ""

        var targetFolders = folderPath

        if !removedParentFolders.isEmpty, let range = targetFolders.range(of: removedParentFolders) {
            targetFolders.removeSubrange(range)
        }

        targetFolders = String(targetFolders.drop(while: { $0 == "\\" })).replacingOccurrences(of: "\\", with: "/")

        // Check if a custom download location was specified
        var downloadFolderPath = downloadFolderPath

        if downloadFolderPath == nil || downloadFolderPath?.isEmpty == true {
            if let requestedFolder = requestedFolders[username]?[folderPath],
               let requestedPath = requestedFolder.downloadFolderPath, !requestedPath.isEmpty {
                downloadFolderPath = requestedPath
            } else {
                downloadFolderPath = defaultDownloadFolder(username: username)
            }
        }

        // Merge download path with target folder name
        return (downloadFolderPath! as NSString).appendingPathComponent(targetFolders)
    }

    public func defaultDownloadFolder(username: String? = nil) -> String {
        var downloadFolderPath = (config.expandingDataFolder(config.transfers.downloadDir) as NSString).standardizingPath

        // Check if username subfolders should be created for downloads
        if let username, config.transfers.usernameSubfolders {
            downloadFolderPath = (downloadFolderPath as NSString).appendingPathComponent(cleanFile(username))
        }

        return downloadFolderPath
    }

    public func incompleteDownloadFolder() -> String {
        (config.expandingDataFolder(config.transfers.incompleteDir) as NSString).standardizingPath
    }

    private func basenameByteLimit(folderPath: String) -> Int {
        if let maxBytes = folderBasenameByteLimits[folderPath] {
            return maxBytes
        }

        var info = statvfs()
        let maxBytes = statvfs(folderPath, &info) == 0 ? Int(info.f_namemax) : 255

        folderBasenameByteLimits[folderPath] = maxBytes
        return maxBytes
    }

    /// Splits a file name into the name without extension, and the extension
    /// (including the separator).
    private static func splitExtension(_ basename: String) -> (name: String, extension: String) {
        guard let range = basename.range(of: ".", options: .backwards) else {
            return (basename, "")
        }

        return (String(basename[..<range.lowerBound]), String(basename[range.lowerBound...]))
    }

    /// Returns the download basename for a virtual file path.
    public func downloadBasename(virtualPath: String, downloadFolderPath: String, avoidConflict: Bool = false) -> String {
        let maxBytes = basenameByteLimit(folderPath: downloadFolderPath)

        let basename = cleanFile(virtualPath.components(separatedBy: "\\").last ?? virtualPath)
        var (basenameNoExtension, fileExtension) = Self.splitExtension(basename)
        let basenameLimit = maxBytes - fileExtension.utf8.count
        basenameNoExtension = basenameNoExtension.truncated(toByteLimit: Swift.max(0, basenameLimit))

        if basenameLimit < 0 {
            fileExtension = fileExtension.truncated(toByteLimit: maxBytes)
        }

        var correctedBasename = basenameNoExtension + fileExtension

        guard avoidConflict else {
            return correctedBasename
        }

        var counter = 1

        while FileManager.default.fileExists(atPath: (downloadFolderPath as NSString)
            .appendingPathComponent(correctedBasename)) {
            correctedBasename = "\(basenameNoExtension) (\(counter))\(fileExtension)"
            counter += 1
        }

        return correctedBasename
    }

    /// Returns the download path of a complete download, if available.
    public func completeDownloadFilePath(username: String, virtualPath: String, size: Int,
                                         downloadFolderPath: String? = nil) -> (path: String, exists: Bool) {
        let downloadFolderPath = (downloadFolderPath?.isEmpty == false)
            ? downloadFolderPath! : defaultDownloadFolder(username: username)

        let basename = downloadBasename(virtualPath: virtualPath, downloadFolderPath: downloadFolderPath)
        let (basenameNoExtension, fileExtension) = Self.splitExtension(basename)
        var downloadFilePath = (downloadFolderPath as NSString).appendingPathComponent(basename)
        var fileExists = false
        var counter = 1

        while FileManager.default.fileExists(atPath: downloadFilePath) {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: downloadFilePath)[.size] as? Int) ?? -1

            if fileSize == size {
                // Found a previous download with a matching file size
                fileExists = true
                break
            }

            downloadFilePath = (downloadFolderPath as NSString)
                .appendingPathComponent("\(basenameNoExtension) (\(counter))\(fileExtension)")
            counter += 1
        }

        return (downloadFilePath, fileExists)
    }

    /// Returns the path to store a download while it's still transferring.
    public func incompleteDownloadFilePath(username: String, virtualPath: String) -> String {
        let digest = Insecure.MD5.hash(data: Data((virtualPath + username).utf8))
        let prefix = "INCOMPLETE" + digest.map { String(format: "%02x", $0) }.joined()

        // Ensure file name length doesn't exceed file system limit
        let incompleteFolderPath = incompleteDownloadFolder()
        let maxBytes = basenameByteLimit(folderPath: incompleteFolderPath)

        let basename = cleanFile(virtualPath.components(separatedBy: "\\").last ?? virtualPath)
        var (basenameNoExtension, fileExtension) = Self.splitExtension(basename)
        let basenameLimit = maxBytes - prefix.count - fileExtension.utf8.count
        basenameNoExtension = basenameNoExtension.truncated(toByteLimit: Swift.max(0, basenameLimit))

        if basenameLimit < 0 {
            fileExtension = fileExtension.truncated(toByteLimit: maxBytes - prefix.count)
        }

        return (incompleteFolderPath as NSString).appendingPathComponent(prefix + basenameNoExtension + fileExtension)
    }

    /// Returns the current file path of a download.
    public func currentDownloadFilePath(_ transfer: Transfer) -> String {
        let (filePath, fileExists) = completeDownloadFilePath(
            username: transfer.username, virtualPath: transfer.virtualPath, size: transfer.size,
            downloadFolderPath: transfer.folderPath
        )

        if fileExists || transfer.status == .finished {
            return filePath
        }

        return incompleteDownloadFilePath(username: transfer.username, virtualPath: transfer.virtualPath)
    }

    public func enqueueFolder(username: String, folderPath: String, downloadFolderPath: String? = nil) {
        let requestedFolder = requestedFolders[username]?[folderPath]
            ?? RequestedFolder(username: username, folderPath: folderPath, downloadFolderPath: downloadFolderPath)
        requestedFolders[username, default: [:]][folderPath] = requestedFolder

        // First timeout is shorter to get a response sooner in case the first request
        // failed. Second timeout is longer in case the response is delayed.
        let timeout: TimeInterval = requestedFolder.hasRetried ? 60 : 15

        if let timerID = requestedFolder.requestTimerID {
            events.cancelScheduled(timerID)
            requestedFolder.requestTimerID = nil
        }

        requestedFolder.requestTimerID = events.schedule(delay: timeout) { [self] in
            requestedFolderTimeout(requestedFolder)
        }

        log.addTransfer("Requesting contents of folder \(folderPath) from user \(username)")

        requestedFolderToken = incrementToken(requestedFolderToken)

        core.sendMessageToPeer(username, FolderContentsRequest(
            folder: folderPath, token: requestedFolderToken, legacyClient: requestedFolder.legacyAttempt
        ))
    }

    public func enqueueDownload(username: String, virtualPath: String, folderPath: String? = nil, size: Int = 0,
                                fileAttributes: [Int: Int]? = nil, bypassFilter: Bool = false) {
        var transfer = transfers[Self.key(username, virtualPath)]
        let folderPath = (folderPath?.isEmpty == false) ? cleanPath(folderPath!) : defaultDownloadFolder(username: username)

        if let existing = transfer, existing.folderPath != folderPath, existing.status == .finished {
            // Only one user + virtual path transfer possible at a time, remove the old one
            clearDownload(existing, updateParent: false)
            transfer = nil
        }

        if transfer != nil {
            // Duplicate download found, stop here
            return
        }

        let newTransfer = Transfer(username: username, virtualPath: virtualPath, folderPath: folderPath, size: size,
                                   fileAttributes: fileAttributes)

        appendTransfer(newTransfer)

        if enqueueDownload(newTransfer, bypassFilter: bypassFilter) {
            updateTransfer(newTransfer)
        }
    }

    public func retryDownload(_ transfer: Transfer, bypassFilter: Bool = false) {
        let activeDownloads = activeUsers[transfer.username]?.values.map { $0 } ?? []

        if activeDownloads.contains(transfer) || transfer.status == .finished {
            // Don't retry active or finished downloads
            return
        }

        dequeueTransfer(transfer)
        unfailTransfer(transfer)

        if enqueueDownload(transfer, bypassFilter: bypassFilter) {
            updateTransfer(transfer)
        }
    }

    public func retryDownloads(_ downloads: [Transfer]) {
        for download in downloads {
            // Provide a way to bypass download filters in case the user actually wants a file.
            // To avoid accidentally bypassing filters, ensure that only a single file is selected,
            // and it has the "Filtered" status.
            let bypassFilter = downloads.count == 1 && download.status == .filtered
            retryDownload(download, bypassFilter: bypassFilter)
        }
    }

    public func abortDownloads(_ downloads: [Transfer], status: TransferStatus = .paused) {
        let ignoredStatuses: Set<TransferStatus> = [status, .finished]

        for download in downloads where !(download.status.map(ignoredStatuses.contains) ?? false) {
            abortDownload(download, status: status, updateParent: false)
        }

        events.emit(.abortDownloads, TransfersAbort(transfers: downloads, status: status))
    }

    public func clearDownloads(_ downloads: [Transfer]? = nil, statuses: Set<TransferStatus>? = nil,
                               clearDeleted: Bool = false) {
        // Clear all downloads if none are specified
        let downloads = downloads ?? Array(transfers.values)

        for download in downloads {
            if let statuses, !(download.status.map(statuses.contains) ?? false) {
                continue
            }

            if clearDeleted {
                if download.status != .finished {
                    continue
                }

                let (_, fileExists) = completeDownloadFilePath(
                    username: download.username, virtualPath: download.virtualPath, size: download.size,
                    downloadFolderPath: download.folderPath
                )

                if fileExists {
                    continue
                }
            }

            clearDownload(download, updateParent: false)
        }

        events.emit(.clearDownloads, TransfersClear(transfers: downloads, statuses: statuses,
                                                    clearDeleted: clearDeleted))
    }

    // MARK: Events

    /// Sends any QueueUpload messages we delayed while our shares were initializing.
    private func sharesReady() {
        for (transfer, msg) in pendingQueueMessages {
            core.sendMessageToPeer(transfer.username, msg)
        }

        pendingQueueMessages.removeAll()
    }

    /// Server code 7.
    private func userStatus(_ msg: GetUserStatus) {
        let username = msg.user

        guard core.users.watched[username] != nil else {
            // Skip redundant status updates from users in joined rooms
            return
        }

        if msg.status == UserStatus.offline.rawValue {
            for download in Array((queuedUsers[username] ?? [:]).values) + Array((failedUsers[username] ?? [:]).values) {
                abortTransfer(download, status: .userLoggedOff)
            }

            for download in Array((activeUsers[username] ?? [:]).values) where download.status != .transferring {
                abortTransfer(download, status: .userLoggedOff)
            }

            onlineUsers.remove(username)
            return
        }

        // No need to check transfers on away status change
        if onlineUsers.contains(username) {
            return
        }

        // User logged in, resume "User logged off" transfers
        for download in Array((failedUsers[username] ?? [:]).values) {
            unfailTransfer(download)

            if enqueueDownload(download) {
                updateTransfer(download)
            }
        }

        onlineUsers.insert(username)
    }

    private func peerConnectionError(_ username: String, connType: String, msgs: [SlskMessage],
                                     isOffline: Bool = false, isTimeout: Bool = true) {
        guard !msgs.isEmpty, connType == ConnectionType.file.rawValue || connType == ConnectionType.peer.rawValue else {
            return
        }

        for msg in msgs {
            if let queueUpload = msg as? QueueUpload {
                cantConnectQueueFile(username, virtualPath: queueUpload.file, isOffline: isOffline, isTimeout: isTimeout)

            } else if let placeInQueueRequest = msg as? PlaceInQueueRequest {
                cantConnectQueueFile(username, virtualPath: placeInQueueRequest.file, isOffline: isOffline,
                                     isTimeout: isTimeout)
            }
        }
    }

    /// We can't connect to the user, either way (QueueUpload, PlaceInQueueRequest).
    private func cantConnectQueueFile(_ username: String, virtualPath: String, isOffline: Bool, isTimeout: Bool) {
        guard let download = queuedUsers[username]?[virtualPath] else {
            return
        }

        let status: TransferStatus = isOffline ? .userLoggedOff : (isTimeout ? .connectionTimeout : .connectionClosed)

        log.addTransfer("Download attempt for file \(virtualPath) from user \(username) failed with status \(status)")
        abortTransfer(download, status: status)
    }

    private func requestedFolderTimeout(_ requestedFolder: RequestedFolder) {
        guard requestedFolder.requestTimerID != nil else {
            return
        }

        requestedFolder.requestTimerID = nil
        let username = requestedFolder.username
        let folderPath = requestedFolder.folderPath

        if requestedFolder.hasRetried {
            log.addTransfer("Folder content request for folder \(folderPath) from user \(username) timed out, giving up")
            requestedFolders[username]?.removeValue(forKey: folderPath)
            return
        }

        log.addTransfer("Folder content request for folder \(folderPath) from user \(username) timed out, retrying")

        requestedFolder.hasRetried = true
        enqueueFolder(username: username, folderPath: folderPath, downloadFolderPath: requestedFolder.downloadFolderPath)
    }

    /// Peer code 37.
    private func folderContentsResponse(_ msg: FolderContentsResponse, checkNumFiles: Bool = true) {
        guard let username = msg.username, let requestedFolder = requestedFolders[username]?[msg.folder] else {
            return
        }

        let folderPath = msg.folder

        log.addTransfer("Received response for folder content request for folder \(folderPath) from user \(username)")

        if let timerID = requestedFolder.requestTimerID {
            events.cancelScheduled(timerID)
            requestedFolder.requestTimerID = nil
        }

        if msg.list.isEmpty && !requestedFolder.legacyAttempt {
            log.addTransfer("Folder content response is empty. Trying legacy latin-1 request.")
            requestedFolder.legacyAttempt = true
            enqueueFolder(username: username, folderPath: folderPath, downloadFolderPath: requestedFolder.downloadFolderPath)
            return
        }

        for (responseFolderPath, files) in msg.list where responseFolderPath == folderPath {
            let numFiles = files.count

            if checkNumFiles && numFiles > 100 {
                events.emit(.downloadLargeFolder, LargeFolderDownload(
                    username: username, folderPath: folderPath, numFiles: numFiles,
                    proceed: { [self] in folderContentsResponse(msg, checkNumFiles: false) }
                ))
                return
            }

            let destinationFolderPath = folderDestination(username: username, folderPath: folderPath)

            log.addTransfer("Attempting to download files in folder \(folderPath) for user \(username). "
                            + "Destination path: \(destinationFolderPath)")

            var parentPath = folderPath
            while parentPath.hasSuffix("\\") { parentPath.removeLast() }

            for file in files {
                let virtualPath = parentPath + "\\" + file.name

                enqueueDownload(username: username, virtualPath: virtualPath, folderPath: destinationFolderPath,
                                size: file.size, fileAttributes: file.attributes)
            }
        }

        requestedFolders[username]?.removeValue(forKey: folderPath)
    }

    /// Peer code 40.
    private func transferRequest(_ msg: TransferRequest) {
        guard msg.direction == TransferDirection.upload.rawValue, let username = msg.username else {
            return
        }

        let response = transferRequestDownloads(msg, username: username)

        log.addTransfer("Responding to download request with token \(response.token) for file \(msg.file) "
                        + "from user: \(username), allowed: \(response.allowed), reason: \(response.reason ?? "None")")

        core.sendMessageToPeer(username, response)
    }

    private func transferRequestDownloads(_ msg: TransferRequest, username: String) -> TransferResponse {
        let virtualPath = msg.file
        let size = msg.fileSize ?? 0
        let token = msg.token

        log.addTransfer("Received download request with token \(token) for file \(virtualPath) from user \(username)")

        if let download = queuedUsers[username]?[virtualPath] ?? failedUsers[username]?[virtualPath] {
            // Remote peer is signaling a transfer is ready, attempting to download it

            // If the file is larger than 2GB, the SoulseekQt client seems to
            // send a malformed file size (0 bytes) in the TransferRequest response.
            // In that case, we rely on the cached, correct file size we received when
            // we initially added the download.

            unfailTransfer(download)
            dequeueTransfer(download)

            if size > 0 {
                if download.size != size {
                    // The remote user's file contents have changed since we queued the download
                    download.sizeChanged = true
                }

                download.size = size
            }

            activateTransfer(download, token: token)
            updateTransfer(download)

            return TransferResponse(allowed: true, token: token)
        }

        var cancelReason = TransferRejectReason.cancelled

        if let download = transfers[Self.key(username, virtualPath)] {
            if download.status == .finished {
                // SoulseekQt sends "Complete" as the reason for rejecting the download if it exists
                cancelReason = TransferRejectReason.complete
            }

        } else if canUpload(username) {
            // Check if download exists in our default download folder
            let (_, fileExists) = completeDownloadFilePath(username: username, virtualPath: virtualPath, size: size)

            if fileExists {
                cancelReason = TransferRejectReason.complete
            } else {
                // If this file is not in your download queue, then it must be
                // a remotely initiated download and someone is manually uploading to you
                let pathParts = virtualPath.replacingOccurrences(of: "/", with: "\\").components(separatedBy: "\\")
                let parentFolderPath = pathParts.count >= 2 ? pathParts[pathParts.count - 2] : ""
                let receivedFolderPath = (config.expandingDataFolder(config.transfers.uploadDir) as NSString)
                    .standardizingPath
                let folderPath = ((receivedFolderPath as NSString).appendingPathComponent(username) as NSString)
                    .appendingPathComponent(parentFolderPath)

                let transfer = Transfer(username: username, virtualPath: virtualPath, folderPath: folderPath, size: size)

                appendTransfer(transfer)
                activateTransfer(transfer, token: token)
                updateTransfer(transfer)

                return TransferResponse(allowed: true, token: token)
            }
        }

        log.addTransfer("Denied file request: user \(username), message \(msg)")
        return TransferResponse(allowed: false, reason: cancelReason, token: token)
    }

    override func transferTimeout(_ transfer: Transfer) {
        guard transfer.requestTimerID != nil else {
            return
        }

        log.addTransfer("Download \(transfer.virtualPath) with token \(transfer.token.map(String.init) ?? "None") "
                        + "for user \(transfer.username) timed out")

        super.transferTimeout(transfer)
    }

    /// The networking thread encountered a local file error for a download.
    private func downloadFileError(_ event: FileErrorEvent) {
        guard let download = activeUsers[event.username]?[event.token] else {
            return
        }

        abortTransfer(download, status: .localFileError)
        log.add(String(localized: "Download I/O error: \(event.error.localizedDescription)", bundle: .module))
    }

    /// A peer is requesting to start uploading a file to us.
    private func fileTransferInit(_ msg: FileTransferInit) {
        guard !msg.isOutgoing else {
            // Upload init message sent to ourselves, ignore
            return
        }

        guard let username = msg.username, let token = msg.token, let download = activeUsers[username]?[token],
              download.sock == nil else {
            return
        }

        let virtualPath = download.virtualPath
        let incompleteFolderPath = incompleteDownloadFolder()
        let sock = msg.sock
        let incompleteFilePath = incompleteDownloadFilePath(username: username, virtualPath: virtualPath)
        var needUpdate = true
        var downloadStarted = false

        download.sock = sock

        log.addTransfer("Received file download init with token \(token) for file \(virtualPath) from user \(username)")

        do {
            try FileManager.default.createDirectory(atPath: incompleteFolderPath, withIntermediateDirectories: true)

            if !FileManager.default.fileExists(atPath: incompleteFilePath) {
                FileManager.default.createFile(atPath: incompleteFilePath, contents: nil)
            }

            let fileHandle = try FileHandle(forUpdating: URL(fileURLWithPath: incompleteFilePath))

            if lockf(fileHandle.fileDescriptor, F_TLOCK, 0) != 0 {
                log.add(String(localized: "Can't get an exclusive lock on file - I/O error: \(SocketError().description)",
                               bundle: .module))
            }

            if download.sizeChanged {
                // Remote user sent a different file size than we originally requested,
                // wipe any existing data in the incomplete file to avoid corruption
                try fileHandle.truncate(atOffset: 0)
            }

            // Seek to the end of the file for resuming the download
            let offset = Int(try fileHandle.seekToEnd())

            download.fileHandle = fileHandle
            download.filePath = incompleteFilePath
            download.lastByteOffset = offset
            download.startTime = ProcessInfo.processInfo.systemUptime - download.timeElapsed
            download.retryAttempt = false

            core.statistics.appendStatValue(.startedDownloads, 1)
            downloadStarted = true

            log.addDownload(String(localized: "Download started: user \(username), file \(incompleteFilePath)",
                                   bundle: .module))

            if download.size > offset {
                download.status = .transferring
                core.sendMessageToNetworkThread(DownloadFile(sock: sock, token: token, file: fileHandle,
                                                             leftBytes: download.size - offset))
                core.sendMessageToPeer(username, FileOffset(sock: sock, offset: offset))
            } else {
                finishTransfer(download)
                needUpdate = false
            }

        } catch {
            log.add(String(localized: "Cannot save file in \(incompleteFolderPath): \(error.localizedDescription)",
                           bundle: .module))
            abortTransfer(download, status: .downloadFolderError)
            core.notifications?.showDownloadNotification(
                error.localizedDescription, title: String(localized: "Download Folder Error", bundle: .module),
                highPriority: true
            )
            needUpdate = false
        }

        if needUpdate {
            updateTransfer(download)
        }

        if downloadStarted {
            // Must be emitted after the final update to prevent inconsistent state
            core.pluginHandler?.downloadStartedNotification(username, virtualPath: virtualPath,
                                                            realPath: incompleteFilePath)
        }
    }

    /// Peer code 50.
    private func uploadDenied(_ msg: UploadDenied) {
        guard let username = msg.username else {
            return
        }

        let virtualPath = msg.file
        var reason = msg.reason
        let queuedDownloads = queuedUsers[username] ?? [:]

        guard let download = queuedDownloads[virtualPath] else {
            return
        }

        if TransferStatus.internalStatuses.contains(TransferStatus(rawValue: reason)) {
            // Don't allow internal statuses as reason
            reason = TransferRejectReason.cancelled
        }

        if reason == TransferRejectReason.fileNotShared && !download.legacyAttempt {
            // The peer is possibly using an old client that doesn't support Unicode
            // (Soulseek NS). Attempt to request file name encoded as latin-1 once.

            log.addTransfer("User \(username) responded with reason '\(reason)' for download request \(virtualPath). "
                            + "Attempting to request file as latin-1.")

            dequeueTransfer(download)
            download.legacyAttempt = true

            if enqueueDownload(download) {
                updateTransfer(download)
            }

            return
        }

        if reason == TransferRejectReason.tooManyFiles || reason == TransferRejectReason.tooManyMegabytes
            || reason.hasPrefix("User limit of") {
            // Make limited downloads appear as queued, and automatically resume them later
            reason = TransferRejectReason.queued
            userQueueLimits[username] = Swift.max(5, queuedDownloads.count - 1)
        }

        abortTransfer(download, status: TransferStatus(rawValue: reason))
        updateTransfer(download)

        log.addTransfer("Download request denied by user \(username) for file \(virtualPath). Reason: \(msg.reason)")
    }

    /// Peer code 46.
    private func uploadFailed(_ msg: UploadFailed) {
        guard let username = msg.username else {
            return
        }

        let virtualPath = msg.file

        guard let download = transfers[Self.key(username, virtualPath)] else {
            return
        }

        let isActive = download.token.map { activeUsers[username]?[$0] != nil } ?? false

        if !isActive && failedUsers[username]?[virtualPath] == nil && queuedUsers[username]?[virtualPath] == nil {
            return
        }

        if download.status == .downloadFolderError || download.status == .localFileError {
            // Local error, no need to retry
            return
        }

        if !download.retryAttempt {
            // Attempt to request file name encoded as latin-1 once

            // We mark download as failed when aborting it, to avoid a redundant request
            // to unwatch the user. Need to unfail the transfer to undo this.
            abortTransfer(download, status: .connectionClosed)
            unfailTransfer(download)

            download.legacyAttempt = true
            download.retryAttempt = true

            if enqueueDownload(download) {
                updateTransfer(download)
            }

            return
        }

        // Already failed once previously, give up
        abortTransfer(download, status: .connectionClosed)
        download.retryAttempt = false

        log.addTransfer("Upload attempt by user \(virtualPath) for file \(username) failed. "
                        + "Reason: \(download.status?.rawValue ?? "None")")
    }

    /// A file download is in progress.
    private func fileDownloadProgress(_ event: FileDownloadProgress) {
        guard let download = activeUsers[event.username]?[event.token] else {
            return
        }

        if let timerID = download.requestTimerID {
            events.cancelScheduled(timerID)
            download.requestTimerID = nil
        }

        updateTransferProgress(download, statID: .downloadedSize, currentByteOffset: download.size - event.bytesLeft,
                               speed: event.speed)
        updateTransfer(download)
    }

    /// A file download connection has closed for any reason.
    private func fileConnectionClosed(_ event: FileConnectionClosedEvent) {
        guard let download = activeUsers[event.username]?[event.token], download.sock == event.sock else {
            return
        }

        if let currentByteOffset = download.currentByteOffset, currentByteOffset >= download.size {
            finishTransfer(download)
            return
        }

        let status: TransferStatus = core.users.statuses[download.username] == .offline ? .userLoggedOff : .cancelled
        abortTransfer(download, status: status)
    }

    /// Peer code 44.
    ///
    /// The peer tells us our place in queue for a particular transfer.
    private func placeInQueueResponse(_ msg: PlaceInQueueResponse) {
        guard let username = msg.username, let download = queuedUsers[username]?[msg.filename] else {
            return
        }

        download.queuePosition = msg.place
        updateTransfer(download, updateParent: false)
    }
}
