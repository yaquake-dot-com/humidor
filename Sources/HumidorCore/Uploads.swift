// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public extension EventName where Payload == Void {
    static var uploadsShutdownRequest: Self { .init("uploads-shutdown-request") }
    static var uploadsShutdownCancel: Self { .init("uploads-shutdown-cancel") }
}

@MainActor
public final class Uploads: Transfers {

    public private(set) var pendingShutdown = false
    public private(set) var uploadSpeed = 0
    private var token = initialToken()

    private var queuePositions: [Transfer: Int] = [:]
    private var queuePositionUsers: [String: [Transfer: Int]] = [:]
    private var privilegedPositionRequested = false
    private var pendingNetworkMessages: [SlskMessage] = []
    private var userUpdateCounter = 0
    private var userUpdateCounters: [String: Int] = [:]

    private var uploadQueueTimerID: Int?
    private var retryFailedUploadsTimerID: Int?

    init() {
        super.init(name: "uploads")

        events.connect(.banUser) { [self] username in banUser(username: username) }
        events.connect(.banUserIP) { [self] event in banUser(username: event.username, ipAddress: event.ipAddress) }
        events.connect(.fileConnectionClosed) { [self] event in fileConnectionClosed(event) }
        events.connect(.fileTransferInit) { [self] msg in fileTransferInit(msg) }
        events.connect(.fileUploadProgress) { [self] event in fileUploadProgress(event) }
        events.connect(.peerConnectionClosed) { [self] event in
            peerConnectionError(event.username, connType: event.connType, msgs: event.msgs, isTimeout: false)
        }
        events.connect(.peerConnectionError) { [self] event in
            peerConnectionError(event.username, connType: event.connType, msgs: event.msgs,
                                isOffline: event.isOffline)
        }
        events.connect(.placeInQueueRequest) { [self] msg in placeInQueueRequest(msg) }
        events.connect(.privilegedUsers) { _ in
            log.addTransfer("\(core.users.privileged.count) privileged users")
        }
        events.connect(.queueUpload) { [self] msg in queueUpload(msg) }
        events.connect(.setConnectionStats) { [self] stats in totalBandwidth = stats.uploadBandwidth }
        events.connect(.sharesReady) { [self] _ in sharesReady() }
        events.connect(.transferRequest) { [self] msg in transferRequest(msg) }
        events.connect(.transferResponse) { [self] msg in transferResponse(msg) }
        events.connect(.uploadFileError) { [self] event in uploadFileError(event) }
        events.connect(.userStats) { [self] msg in
            if msg.user == core.users.loginUsername {
                uploadSpeed = msg.avgSpeed
            }
        }
        events.connect(.userStatus) { [self] msg in userStatus(msg) }
    }

    override func quit() {
        super.quit()
        uploadSpeed = 0
    }

    override func serverLogin(_ msg: Login) {
        guard msg.success else {
            return
        }

        super.serverLogin(msg)

        // Check if queued uploads can be started every 10 seconds
        uploadQueueTimerID = events.schedule(delay: 10, repeat: true) { [self] in checkUploadQueue() }

        // Re-queue timed out uploads every 3 minutes
        retryFailedUploadsTimerID = events.schedule(delay: 180, repeat: true) { [self] in retryFailedUploads() }
    }

    override func serverDisconnect(_ msg: ServerDisconnect) {
        super.serverDisconnect(msg)

        events.cancelScheduled(uploadQueueTimerID)
        events.cancelScheduled(retryFailedUploadsTimerID)

        queuePositions.removeAll()
        queuePositionUsers.removeAll()
        pendingNetworkMessages.removeAll()
        userUpdateCounters.removeAll()
        userUpdateCounter = 0

        // Quit in case we were waiting for uploads to finish
        checkUploadQueue()
    }

    // MARK: Load Transfers

    override func loadTransfers() {
        for transfer in storedTransfers(transfersFilePath, loadOnlyFinished: true) {
            appendTransfer(transfer)
        }
    }

    // MARK: Privileges

    public func isPrivileged(_ username: String?) -> Bool {
        guard let username, !username.isEmpty else {
            return false
        }

        if core.users.privileged.contains(username) {
            return true
        }

        return isBuddyPrioritized(username)
    }

    public func isBuddyPrioritized(_ username: String?) -> Bool {
        guard let username, let userData = core.buddies.users[username] else {
            return false
        }

        // All users
        if config.transfers.preferFriends {
            return true
        }

        // Only explicitly prioritized users
        return userData.isPrioritized
    }

    // MARK: Stats/Limits

    private static func currentFileSize(_ filePath: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? Int) ?? nil
    }

    public func downloadingUsers() -> Set<String> {
        Set(activeUsers.keys).union(queuedUsers.keys)
    }

    public func totalUploadsAllowed() -> Int {
        var uploadSlots: Int

        if config.transfers.useUploadSlots {
            uploadSlots = config.transfers.uploadSlots
        } else {
            uploadSlots = activeUsers.count

            if isNewUploadAccepted() {
                return uploadSlots + 1
            }
        }

        if uploadSlots <= 0 {
            uploadSlots = 1
        }

        return uploadSlots
    }

    public func uploadQueueSize(_ username: String) -> Int {
        if isPrivileged(username) {
            return queuedUsers.filter { isPrivileged($0.key) }.reduce(0) { $0 + $1.value.count }
        }

        return queuedTransfers.count
    }

    public var hasActiveUploads: Bool {
        !activeUsers.isEmpty || !queuedUsers.isEmpty
    }

    public func isQueueLimitReached(_ username: String) -> (reached: Bool, reason: String?) {
        let fileLimit = config.transfers.fileLimit
        let queueSizeLimit = config.transfers.queueLimit * 1024 * 1024

        if fileLimit >= 1 && (queuedUsers[username]?.count ?? 0) >= fileLimit {
            return (true, TransferRejectReason.tooManyFiles)
        }

        if queueSizeLimit >= 1 && (userQueueSizes[username] ?? 0) >= queueSizeLimit {
            return (true, TransferRejectReason.tooManyMegabytes)
        }

        return (false, nil)
    }

    public func isSlotLimitReached() -> Bool {
        var uploadSlotLimit = config.transfers.uploadSlots

        if uploadSlotLimit <= 0 {
            uploadSlotLimit = 1
        }

        return activeUsers.count >= uploadSlotLimit
    }

    public func isBandwidthLimitReached() -> Bool {
        let bandwidthLimit = config.transfers.uploadBandwidth * 1024

        guard bandwidthLimit != 0 else {
            return false
        }

        return totalBandwidth >= bandwidthLimit
    }

    public func isNewUploadAccepted(enforceLimits: Bool = true) -> Bool {
        guard let shares = core.sharesComponent, !shares.isRescanning else {
            return false
        }

        guard enforceLimits else {
            return true
        }

        if config.transfers.useUploadSlots {
            // Limit by upload slots
            if isSlotLimitReached() {
                return false
            }

        } else if isBandwidthLimitReached() {
            // Limit by maximum bandwidth
            return false
        }

        // No limits
        return true
    }

    public static func isFileReadable(virtualPath: String, realPath: String) -> Bool {
        if FileManager.default.isReadableFile(atPath: realPath) {
            return true
        }

        log.addTransfer("Cannot access file, not sharing: \(virtualPath) with real path \(realPath)")
        return false
    }

    public func isUploadQueued(_ username: String, virtualPath: String) -> Bool {
        if queuedUsers[username]?[virtualPath] != nil {
            return true
        }

        return activeUsers[username]?.values.contains { $0.virtualPath == virtualPath } ?? false
    }

    override public func updateTransferLimits() {
        events.emit(.updateUploadLimits)

        let speedLimit: Int

        switch config.transfers.useUploadSpeedLimit {
        case .primary: speedLimit = config.transfers.uploadLimit
        case .alternative: speedLimit = config.transfers.uploadLimitAlt
        case .unlimited: speedLimit = 0
        }

        core.sendMessageToNetworkThread(SetUploadLimit(limit: speedLimit, limitBy: config.transfers.limitBy))
        checkUploadQueue()
    }

    // MARK: Transfer Actions

    override var isAutoClearEnabled: Bool {
        config.transfers.autoClearUploads
    }

    @discardableResult
    override func enqueueTransfer(_ transfer: Transfer) -> Bool {
        let username = transfer.username

        super.enqueueTransfer(transfer)

        if isPrivileged(username) {
            transfer.modifier = core.users.privileged.contains(username) ? "privileged" : "prioritized"
        }

        // Clear queue position cache until next position request
        queuePositions.removeAll()
        queuePositionUsers.removeValue(forKey: username)

        return true
    }

    @discardableResult
    override func dequeueTransfer(_ transfer: Transfer) -> Bool {
        let username = transfer.username

        guard super.dequeueTransfer(transfer) else {
            return false
        }

        if queuedUsers[username] == nil {
            userUpdateCounters.removeValue(forKey: username)
        }

        transfer.modifier = nil

        // Clear queue position cache until next position request
        queuePositions.removeAll()
        queuePositionUsers.removeValue(forKey: username)

        return true
    }

    override func activateTransfer(_ transfer: Transfer, token: Int) {
        super.activateTransfer(transfer, token: token)
        userUpdateCounters.removeValue(forKey: transfer.username)
    }

    override func updateTransfer(_ transfer: Transfer, updateParent: Bool = true) {
        let username = transfer.username

        // Don't update existing user counter for queued uploads
        // We don't want to push the user back in the queue if they enqueued new files
        if userUpdateCounters[username] == nil || queuedUsers[username]?[transfer.virtualPath] == nil {
            updateUserCounter(username)
        }

        events.emit(.updateUpload, TransferUpdate(transfer: transfer, updateParent: updateParent))
    }

    override func finishTransfer(_ transfer: Transfer) {
        finishUpload(transfer)
    }

    private func finishUpload(_ transfer: Transfer, alreadyExists: Bool = false) {
        let username = transfer.username
        let virtualPath = transfer.virtualPath

        super.finishTransfer(transfer)

        if !autoClearTransfer(transfer) {
            updateTransfer(transfer)
        }

        if !alreadyExists {
            core.statistics.appendStatValue(.completedUploads, 1)

            let realPath = core.shares.virtualToReal(virtualPath)
            core.pluginHandler?.uploadFinishedNotification(username, virtualPath: virtualPath, realPath: realPath)

            let ipAddress = core.users.addresses[username].map { "\($0)" } ?? "None"
            log.addUpload(String(localized: "Upload finished: user \(username), IP address \(ipAddress), file \(virtualPath)",
                                 bundle: .module))
        }

        checkUploadQueue()
    }

    override func abortTransfer(_ transfer: Transfer, status: TransferStatus? = nil, deniedMessage: String? = nil) {
        abortUpload(transfer, status: status, deniedMessage: deniedMessage)
    }

    private func abortUpload(_ transfer: Transfer, status: TransferStatus? = nil, deniedMessage: String? = nil,
                             updateParent: Bool = true) {
        if transfer.fileHandle != nil {
            log.addUpload(String(localized: "Upload aborted, user \(transfer.username) file \(transfer.virtualPath)",
                                 bundle: .module))
        }

        super.abortTransfer(transfer, status: status, deniedMessage: deniedMessage)
        updateUserCounter(transfer.username)

        if let status {
            events.emit(.abortUpload, TransferAbort(transfer: transfer, status: status, updateParent: updateParent))
        }
    }

    override func clearTransfer(_ transfer: Transfer, deniedMessage: String? = nil) {
        clearUpload(transfer, deniedMessage: deniedMessage)
    }

    private func clearUpload(_ transfer: Transfer, deniedMessage: String? = nil, updateParent: Bool = true) {
        let virtualPath = transfer.virtualPath
        let username = transfer.username

        log.addTransfer("Clearing upload \(virtualPath) to user \(username)")

        if transfers[Self.key(username, virtualPath)] == nil {
            log.add("FIXME: failed to remove upload \(virtualPath) to user \(username), not present in list")
        }

        super.clearTransfer(transfer, deniedMessage: deniedMessage)
        events.emit(.clearUpload, TransferUpdate(transfer: transfer, updateParent: updateParent))
    }

    private func retryFailedUploads() {
        for failedUploads in Array(failedUsers.values) {
            for upload in failedUploads.values where upload.status == .connectionTimeout {
                unfailTransfer(upload)
                enqueueTransfer(upload)
                updateTransfer(upload)
            }
        }
    }

    private func checkQueueUploadAllowed(username: String, addr: PeerAddress?, virtualPath: String, realPath: String,
                                         msg: SlskMessage) -> (allowed: Bool, reason: String?, size: Int?) {
        // Is user allowed to download?
        let (permissionLevel, rejectReason) = core.shares.checkUserPermission(username, ipAddress: addr?.ipAddress)

        if permissionLevel == .banned {
            var rejectMessage = TransferRejectReason.banned

            if !rejectReason.isEmpty {
                rejectMessage += " (\(rejectReason))"
            }

            return (false, rejectMessage, nil)
        }

        if core.shares.isRescanning {
            pendingNetworkMessages.append(msg)
            return (false, nil, nil)
        }

        // Is that file already in the queue?
        if isUploadQueued(username, virtualPath: virtualPath) {
            return (false, TransferRejectReason.queued, nil)
        }

        // Are we waiting for existing uploads to finish?
        if pendingShutdown {
            return (false, TransferRejectReason.pendingShutdown, nil)
        }

        // Has user hit queue limit?
        let enableLimits = !(config.transfers.friendsNoLimits && core.buddies.users[username] != nil)

        if enableLimits {
            let (limitReached, reason) = isQueueLimitReached(username)

            if limitReached {
                return (false, reason, nil)
            }
        }

        let (isFileShared, size) = core.shares.fileIsShared(username: username, virtualPath: virtualPath,
                                                            realPath: realPath)

        // Do we actually share that file with the world?
        if !isFileShared {
            return (false, TransferRejectReason.fileNotShared, size)
        }

        return (true, nil, size)
    }

    /// Retrieves a suitable queued transfer for uploading.
    ///
    /// Round Robin: Get the first queued item from the oldest user
    /// FIFO: Get the first queued item in the list
    private func uploadCandidate() -> (candidate: Transfer?, hasActiveUploads: Bool) {
        let isFIFOQueue = config.transfers.fifoQueue
        let hasActiveUploads = !activeUsers.isEmpty
        var targetUsername: String?

        guard !userUpdateCounters.isEmpty else {
            // No queued uploads to start right now
            return (nil, hasActiveUploads)
        }

        let privilegedUsers = Set(userUpdateCounters.keys.filter { isPrivileged($0) })

        if isFIFOQueue {
            for upload in queuedTransfers {
                let username = upload.username

                if !privilegedUsers.isEmpty && !privilegedUsers.contains(username) {
                    continue
                }

                if userUpdateCounters[username] == nil {
                    continue
                }

                targetUsername = username
                break
            }
        } else {
            var oldestTime: Int?

            for (username, updateTime) in userUpdateCounters {
                if !privilegedUsers.isEmpty && !privilegedUsers.contains(username) {
                    continue
                }

                if oldestTime == nil {
                    oldestTime = updateTime + 1
                }

                if let currentOldest = oldestTime, updateTime < currentOldest {
                    targetUsername = username
                    oldestTime = updateTime
                }
            }
        }

        let candidate = targetUsername.flatMap { queuedUsers[$0]?.first?.value }
        return (candidate, hasActiveUploads)
    }

    /// Called when an upload associated with a user has changed.
    ///
    /// The user update counter is used by the Round Robin queue system to
    /// determine which user has waited the longest since their last download.
    private func updateUserCounter(_ username: String) {
        if queuedUsers[username] != nil && activeUsers[username] == nil {
            userUpdateCounter += 1
            userUpdateCounters[username] = userUpdateCounter
        }
    }

    /// Finds the next file to upload.
    private func checkUploadQueue(_ uploadCandidate: Transfer? = nil) {
        var uploadCandidate = uploadCandidate
        var finalUploadCandidate: Transfer?

        while finalUploadCandidate == nil {
            // If a candidate is provided, we want to upload it immediately
            guard isNewUploadAccepted(enforceLimits: uploadCandidate == nil) else {
                return
            }

            if uploadCandidate == nil {
                let (candidate, hasActiveUploads) = self.uploadCandidate()

                guard let candidate else {
                    if !hasActiveUploads && pendingShutdown {
                        pendingShutdown = false
                        core.quit()
                    }
                    return
                }

                uploadCandidate = candidate

            } else if let candidate = uploadCandidate,
                      queuedUsers[candidate.username]?.values.contains(candidate) != true {
                return
            }

            guard let candidate = uploadCandidate else {
                return
            }

            let username = candidate.username

            if core.users.loginStatus == .offline || core.users.statuses[username] == .offline {
                // Either we are offline or the user we want to upload to is
                if !autoClearTransfer(candidate) {
                    abortTransfer(candidate, status: .userLoggedOff)
                }

                uploadCandidate = nil
                continue
            }

            let virtualPath = candidate.virtualPath
            let realPath = core.shares.virtualToReal(virtualPath)
            let (isFileShared, _) = core.shares.fileIsShared(username: username, virtualPath: virtualPath,
                                                             realPath: realPath)

            if !isFileShared {
                clearTransfer(candidate, deniedMessage: TransferRejectReason.fileNotShared)
                uploadCandidate = nil
                continue
            }

            if !Self.isFileReadable(virtualPath: virtualPath, realPath: realPath) {
                abortTransfer(candidate, status: .localFileError, deniedMessage: TransferRejectReason.fileReadError)
                uploadCandidate = nil
                continue
            }

            if let currentSize = Self.currentFileSize(realPath) {
                candidate.size = currentSize
            }

            finalUploadCandidate = candidate
        }

        guard let upload = finalUploadCandidate else {
            return
        }

        token = incrementToken(token)
        let username = upload.username
        let virtualPath = upload.virtualPath

        log.addTransfer("Checked upload queue, requesting to upload file \(virtualPath) with token \(token) "
                        + "to user \(username)")

        dequeueTransfer(upload)
        unfailTransfer(upload)
        activateTransfer(upload, token: token)

        core.sendMessageToPeer(username, TransferRequest(direction: .upload, token: token, file: virtualPath,
                                                         fileSize: upload.size))

        updateTransfer(upload)
    }

    public func enqueueUpload(username: String, virtualPath: String) {
        var transfer = transfers[Self.key(username, virtualPath)]
        let realPath = core.shares.virtualToReal(virtualPath)
        let (isFileShared, size) = core.shares.fileIsShared(username: username, virtualPath: virtualPath,
                                                            realPath: realPath)

        guard isFileShared else {
            return
        }

        if let existing = transfer {
            if activeUsers[username]?.values.contains(existing) == true {
                // Upload already in progress
                return
            }

            if queuedUsers[username]?[virtualPath] != nil {
                // Upload already queued
                return
            }

            unfailTransfer(existing)
            existing.size = size ?? 0
        } else {
            let folderPath = (realPath as NSString).deletingLastPathComponent
            let newTransfer = Transfer(username: username, virtualPath: virtualPath, folderPath: folderPath,
                                       size: size ?? 0)
            appendTransfer(newTransfer)
            transfer = newTransfer
        }

        guard let transfer else {
            return
        }

        if core.users.loginStatus == .offline || core.users.statuses[username] == .offline {
            // Either we are offline or the user we want to upload to is
            if !autoClearTransfer(transfer) {
                abortTransfer(transfer, status: .userLoggedOff)
            }
            return
        }

        enqueueTransfer(transfer)
        updateTransfer(transfer)
        checkUploadQueue()
    }

    public func retryUpload(_ transfer: Transfer) {
        let activeUploads = activeUsers[transfer.username]?.values.map { $0 } ?? []

        if activeUploads.contains(transfer) || transfer.status == .finished {
            // Don't retry active or finished uploads
            return
        }

        if queuedUsers[transfer.username]?.values.contains(transfer) != true {
            unfailTransfer(transfer)
            enqueueTransfer(transfer)
            updateTransfer(transfer)
        }

        if activeUploads.isEmpty {
            // No active upload, transfer a queued upload immediately
            checkUploadQueue(transfer)
        }
    }

    public func retryUploads(_ uploads: [Transfer]) {
        for upload in uploads {
            retryUpload(upload)
        }
    }

    public func abortUploads(_ uploads: [Transfer], deniedMessage: String? = nil, status: TransferStatus = .cancelled) {
        let ignoredStatuses: Set<TransferStatus> = [status, .finished]

        for upload in uploads where !(upload.status.map(ignoredStatuses.contains) ?? false) {
            abortUpload(upload, status: status, deniedMessage: deniedMessage, updateParent: false)
        }

        events.emit(.abortUploads, TransfersAbort(transfers: uploads, status: status))
    }

    public func clearUploads(_ uploads: [Transfer]? = nil, statuses: Set<TransferStatus>? = nil,
                             deniedMessage: String? = nil) {
        // Clear all uploads if none are specified
        let uploads = uploads ?? transfers.values

        for upload in uploads {
            if let statuses, !(upload.status.map(statuses.contains) ?? false) {
                continue
            }

            clearUpload(upload, deniedMessage: deniedMessage, updateParent: false)
        }

        events.emit(.clearUploads, TransfersClear(transfers: uploads, statuses: statuses, clearDeleted: false))
    }

    /// Schedules a shutdown after all queued uploads have finished.
    public func requestShutdown() {
        guard !pendingShutdown else {
            return
        }

        pendingShutdown = true
        checkUploadQueue()

        events.emit(.uploadsShutdownRequest)
    }

    public func cancelShutdown() {
        guard pendingShutdown else {
            return
        }

        pendingShutdown = false
        events.emit(.uploadsShutdownCancel)
    }

    // MARK: Events

    /// Processes any file transfer queue requests that arrived while scanning shares.
    private func sharesReady() {
        guard !pendingNetworkMessages.isEmpty else {
            return
        }

        core.sendMessageToNetworkThread(EmitNetworkMessageEvents(msgs: pendingNetworkMessages))
        pendingNetworkMessages.removeAll()
    }

    /// Server code 7.
    private func userStatus(_ msg: GetUserStatus) {
        let username = msg.user

        guard core.users.watched[username] != nil else {
            // Skip redundant status updates from users in joined rooms
            return
        }

        if msg.status == UserStatus.offline.rawValue {
            for upload in failedUsers[username]?.values ?? [] {
                abortTransfer(upload, status: .userLoggedOff)
            }

            for upload in Array((activeUsers[username] ?? [:]).values) where upload.status != .transferring {
                if !autoClearTransfer(upload) {
                    abortTransfer(upload, status: .userLoggedOff)
                }

                checkUploadQueue()
            }

            onlineUsers.remove(username)
            return
        }

        // No need to check transfers on away status change
        if onlineUsers.contains(username) {
            return
        }

        // User logged in, mark "User logged off" transfers as cancelled
        for upload in failedUsers[username]?.values ?? [] {
            abortTransfer(upload, status: .cancelled)
        }

        onlineUsers.insert(username)
    }

    /// Bans a user, cancels all the user's uploads, sends a 'Banned' message
    /// via the transfers, and clears the transfers from the uploads list.
    private func banUser(username: String? = nil, ipAddress: String? = nil) {
        let banMessage = config.transfers.useCustomBan ? config.transfers.customBan : ""
        let status = banMessage.isEmpty
            ? TransferRejectReason.banned : "\(TransferRejectReason.banned) (\(banMessage))"

        var username = username
        var removedUploads: [Transfer] = []

        if username == nil, let ipAddress {
            outer: for activeUploads in activeUsers.values {
                for upload in activeUploads.values {
                    if let sock = upload.sock, POSIXSocket.localAddress(sock.fileDescriptor)?.ipAddress == ipAddress {
                        username = upload.username
                        break outer
                    }
                }
            }
        }

        if let username {
            removedUploads += (activeUsers[username] ?? [:]).values
            removedUploads += queuedUsers[username]?.values ?? []
            removedUploads += failedUsers[username]?.values ?? []
        }

        clearUploads(removedUploads, deniedMessage: status)
        checkUploadQueue()
    }

    private func peerConnectionError(_ username: String, connType: String, msgs: [SlskMessage],
                                     isOffline: Bool = false, isTimeout: Bool = true) {
        guard !msgs.isEmpty, connType == ConnectionType.file.rawValue || connType == ConnectionType.peer.rawValue else {
            return
        }

        for msg in msgs {
            if let transferRequest = msg as? TransferRequest {
                cantConnectUpload(username, token: transferRequest.token, isOffline: isOffline, isTimeout: isTimeout)

            } else if let fileTransferInit = msg as? FileTransferInit, let token = fileTransferInit.token {
                cantConnectUpload(username, token: token, isOffline: isOffline, isTimeout: isTimeout)
            }
        }
    }

    /// We can't connect to the user, either way (TransferRequest, FileTransferInit).
    private func cantConnectUpload(_ username: String, token: Int, isOffline: Bool, isTimeout: Bool) {
        guard let upload = activeUsers[username]?[token] else {
            return
        }

        let status: TransferStatus = isOffline ? .userLoggedOff : (isTimeout ? .connectionTimeout : .connectionClosed)

        log.addTransfer("Upload attempt for file \(upload.virtualPath) with token \(token) to user \(username) "
                        + "failed with status \(status)")

        let uploadCleared = isOffline && autoClearTransfer(upload)

        if !uploadCleared {
            abortTransfer(upload, status: status)
        }

        checkUploadQueue()
    }

    /// Peer code 43.
    ///
    /// Peer remotely queued a download (upload here). This is the modern
    /// replacement to a TransferRequest with direction 0 (download request).
    /// We will initiate the upload of the queued file later.
    private func queueUpload(_ msg: QueueUpload) {
        guard let username = msg.username else {
            return
        }

        let virtualPath = msg.file
        let realPath = core.shares.virtualToReal(virtualPath)
        let (allowed, reason, size) = checkQueueUploadAllowed(username: username, addr: msg.addr,
                                                              virtualPath: virtualPath, realPath: realPath, msg: msg)

        log.addTransfer("Upload request for file \(virtualPath) from user: \(username), allowed: \(allowed), "
                        + "reason: \(reason ?? "None")")

        guard allowed else {
            if let reason, reason != TransferRejectReason.queued {
                core.sendMessageToPeer(username, UploadDenied(file: virtualPath, reason: reason))
            }
            return
        }

        let transfer = prepareQueuedTransfer(username: username, virtualPath: virtualPath, realPath: realPath,
                                             size: size ?? 0)

        enqueueTransfer(transfer)
        updateTransfer(transfer)

        // Must be emitted after the final update to prevent inconsistent state
        core.pluginHandler?.uploadQueuedNotification(username, virtualPath: virtualPath, realPath: realPath)

        checkUploadQueue()
    }

    private func prepareQueuedTransfer(username: String, virtualPath: String, realPath: String, size: Int) -> Transfer {
        let folderPath = (realPath as NSString).deletingLastPathComponent

        if let transfer = transfers[Self.key(username, virtualPath)] {
            unfailTransfer(transfer)

            transfer.folderPath = folderPath
            transfer.size = size

            if transfer.status == .finished {
                transfer.currentByteOffset = nil
                transfer.speed = 0
                transfer.averageSpeed = 0
                transfer.timeElapsed = 0
                transfer.timeLeft = 0
            }

            return transfer
        }

        let transfer = Transfer(username: username, virtualPath: virtualPath, folderPath: folderPath, size: size)
        appendTransfer(transfer)
        return transfer
    }

    /// Peer code 40.
    private func transferRequest(_ msg: TransferRequest) {
        guard msg.direction == TransferDirection.download.rawValue, let username = msg.username,
              let response = transferRequestUploads(msg, username: username) else {
            return
        }

        log.addTransfer("Responding to legacy upload request \(response.token) for file \(msg.file) from user "
                        + "\(username), allowed: \(response.allowed), reason: \(response.reason ?? "None")")

        core.sendMessageToPeer(username, response)
    }

    /// Remote peer is requesting to download a file through our upload queue.
    ///
    /// Note that the QueueUpload peer message has replaced this method of
    /// requesting a download in most clients.
    private func transferRequestUploads(_ msg: TransferRequest, username: String) -> TransferResponse? {
        let virtualPath = msg.file
        let token = msg.token

        log.addTransfer("Received legacy upload request \(token) for file \(virtualPath) from user \(username)")

        // Is user allowed to download?
        let realPath = core.shares.virtualToReal(virtualPath)
        let (allowed, reason, size) = checkQueueUploadAllowed(username: username, addr: msg.addr,
                                                              virtualPath: virtualPath, realPath: realPath, msg: msg)

        guard allowed else {
            if let reason {
                return TransferResponse(allowed: false, reason: reason, token: token)
            }
            return nil
        }

        // All checks passed, user can queue file!
        let transfer = prepareQueuedTransfer(username: username, virtualPath: virtualPath, realPath: realPath,
                                             size: size ?? 0)

        if !isNewUploadAccepted() || activeUsers[username] != nil {
            enqueueTransfer(transfer)
            updateTransfer(transfer)

            // Must be emitted after the final update to prevent inconsistent state
            core.pluginHandler?.uploadQueuedNotification(username, virtualPath: virtualPath, realPath: realPath)

            return TransferResponse(allowed: false, reason: TransferRejectReason.queued, token: token)
        }

        // All checks passed, starting a new upload.
        if let currentSize = Self.currentFileSize(realPath) {
            transfer.size = currentSize
        }

        activateTransfer(transfer, token: token)
        updateTransfer(transfer)

        // Must be emitted after the final update to prevent inconsistent state
        core.pluginHandler?.uploadQueuedNotification(username, virtualPath: virtualPath, realPath: realPath)

        return TransferResponse(allowed: true, token: token, fileSize: size)
    }

    /// Peer code 41.
    ///
    /// Received a response to the file request from the peer.
    private func transferResponse(_ msg: TransferResponse) {
        guard let username = msg.username else {
            return
        }

        let token = msg.token
        var reason = msg.reason

        log.addTransfer("Received response for upload with token: \(token), allowed: \(msg.allowed), "
                        + "reason: \(reason ?? "None"), file size: \(msg.fileSize.map(String.init) ?? "None")")

        guard let upload = activeUsers[username]?[token] else {
            log.addTransfer("Received unknown upload response: \(msg)")
            return
        }

        if upload.sock != nil {
            log.addTransfer("Upload with token \(token) already has an existing file connection")
            return
        }

        if var rejectReason = reason {
            if TransferStatus.internalStatuses.contains(TransferStatus(rawValue: rejectReason))
                || rejectReason == TransferRejectReason.disallowedExtension {
                // Don't allow internal statuses as reason
                rejectReason = TransferRejectReason.cancelled
            }

            reason = rejectReason
            abortTransfer(upload, status: TransferStatus(rawValue: rejectReason))

            if rejectReason == TransferRejectReason.complete {
                // A complete download of this file already exists on the user's end
                finishUpload(upload, alreadyExists: true)

            } else if rejectReason == TransferRejectReason.cancelled {
                _ = autoClearTransfer(upload)
            }

            checkUploadQueue()
            return
        }

        core.sendMessageToPeer(upload.username, FileTransferInit(token: token, isOutgoing: true))
        checkUploadQueue()
    }

    override func transferTimeout(_ transfer: Transfer) {
        guard transfer.requestTimerID != nil else {
            return
        }

        log.addTransfer("Upload \(transfer.virtualPath) with token \(transfer.token.map(String.init) ?? "None") "
                        + "for user \(transfer.username) timed out")

        super.transferTimeout(transfer)
        checkUploadQueue()
    }

    /// The networking thread encountered a local file error for an upload.
    private func uploadFileError(_ event: FileErrorEvent) {
        guard let upload = activeUsers[event.username]?[event.token] else {
            return
        }

        let status: TransferStatus
        var errorDescription = event.error.localizedDescription

        if event.error is FileOffsetError {
            status = .cancelled
            errorDescription = "Remote client does not support large file transfers: \(errorDescription)"
        } else {
            status = .localFileError
        }

        abortTransfer(upload, status: status)

        log.add(String(localized: "Upload I/O error: \(errorDescription)", bundle: .module))
        checkUploadQueue()
    }

    /// We are requesting to start uploading a file to a peer.
    private func fileTransferInit(_ msg: FileTransferInit) {
        guard let username = msg.username, let token = msg.token, let upload = activeUsers[username]?[token],
              upload.sock == nil else {
            return
        }

        let virtualPath = upload.virtualPath
        let sock = msg.sock
        var needUpdate = true
        var uploadStarted = false

        upload.sock = sock

        log.addTransfer("Initializing upload with token \(token) for file \(virtualPath) to user \(username)")

        let realPath = core.shares.virtualToReal(virtualPath)

        do {
            // Open File
            let fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: realPath))

            upload.fileHandle = fileHandle
            upload.filePath = realPath
            upload.startTime = ProcessInfo.processInfo.systemUptime - upload.timeElapsed

            core.statistics.appendStatValue(.startedUploads, 1)
            uploadStarted = true

            let ipAddress = core.users.addresses[username].map { "\($0)" } ?? "None"
            log.addUpload(String(localized: "Upload started: user \(username), IP address \(ipAddress), file \(virtualPath)",
                                 bundle: .module))

            if upload.size > 0 {
                upload.status = .transferring
                core.sendMessageToNetworkThread(UploadFile(sock: sock, token: token, file: fileHandle, size: upload.size))
            } else {
                finishTransfer(upload)
                needUpdate = false
            }

        } catch {
            log.add(String(localized: "Upload I/O error: \(error.localizedDescription)", bundle: .module))
            abortTransfer(upload, status: .localFileError)
            checkUploadQueue()
        }

        if needUpdate {
            updateTransfer(upload)
        }

        if uploadStarted {
            // Must be emitted after the final update to prevent inconsistent state
            core.pluginHandler?.uploadStartedNotification(username, virtualPath: virtualPath, realPath: realPath)
        }
    }

    /// A file upload is in progress.
    private func fileUploadProgress(_ event: FileUploadProgress) {
        guard let upload = activeUsers[event.username]?[event.token] else {
            return
        }

        if let timerID = upload.requestTimerID {
            events.cancelScheduled(timerID)
            upload.requestTimerID = nil
        }

        if upload.lastByteOffset == nil {
            upload.lastByteOffset = event.offset
        }

        updateTransferProgress(upload, statID: .uploadedSize,
                               currentByteOffset: event.offset.map { $0 + event.bytesSent }, speed: event.speed)
        updateTransfer(upload)
    }

    /// A file upload connection has closed for any reason.
    private func fileConnectionClosed(_ event: FileConnectionClosedEvent) {
        guard let upload = activeUsers[event.username]?[event.token], upload.sock == event.sock else {
            return
        }

        if !event.timedOut, let currentByteOffset = upload.currentByteOffset, currentByteOffset >= upload.size {
            // We finish the upload here in case the downloading peer has a slow/limited download
            // speed and finishes later than us

            finishTransfer(upload)

            if upload.averageSpeed > 0 {
                // Inform the server about the average upload speed for this transfer
                log.addTransfer("Sending average upload speed \(upload.averageSpeed) to the server")
                core.sendMessageToServer(SendUploadSpeed(speed: upload.averageSpeed))
            }

            return
        }

        let status: TransferStatus

        if core.users.statuses[upload.username] == .offline {
            status = .userLoggedOff
        } else {
            status = .cancelled

            // Transfer ended abruptly. Tell the peer to re-queue the file. If the transfer was
            // intentionally cancelled, the peer should ignore this message.
            core.sendMessageToPeer(upload.username, UploadFailed(file: upload.virtualPath))
        }

        if !autoClearTransfer(upload) {
            abortTransfer(upload, status: status)
        }

        checkUploadQueue()
    }

    /// Peer code 51.
    private func placeInQueueRequest(_ msg: PlaceInQueueRequest) {
        guard let username = msg.username, let upload = queuedUsers[username]?[msg.file] else {
            return
        }

        let virtualPath = msg.file
        let isFIFOQueue = config.transfers.fifoQueue
        let isPrivilegedQueue = isPrivileged(username)
        let privilegedQueuedUsers = queuedUsers.filter { isPrivileged($0.key) }.mapValues(\.count)
        var queuePosition = 0

        if isFIFOQueue {
            if isPrivilegedQueue != privilegedPositionRequested || queuePositions[upload] == nil {
                queuePositionUsers.removeAll()

                if isPrivilegedQueue {
                    queuePositions.removeAll()
                    var position = 1

                    for queuedUpload in queuedTransfers where privilegedQueuedUsers[queuedUpload.username] != nil {
                        queuePositions[queuedUpload] = position
                        position += 1
                    }
                } else {
                    queuePositions = Dictionary(uniqueKeysWithValues: queuedTransfers.enumerated().map {
                        ($0.element, $0.offset + 1)
                    })
                }
            }

            queuePosition = queuePositions[upload] ?? 0
        } else {
            var userQueuePositions = queuePositionUsers[username] ?? [:]

            if userQueuePositions[upload] == nil {
                queuePositions.removeAll()

                for (index, queuedUpload) in (queuedUsers[username]?.values ?? []).enumerated() {
                    userQueuePositions[queuedUpload] = index + 1
                }

                queuePositionUsers[username] = userQueuePositions
            }

            let numQueuedUsers: Int

            if isPrivilegedQueue {
                numQueuedUsers = privilegedQueuedUsers.count
            } else {
                // Cycling through privileged users first
                queuePosition += privilegedQueuedUsers.values.reduce(0, +)
                numQueuedUsers = queuedUsers.count
            }

            queuePosition += numQueuedUsers + (userQueuePositions[upload] ?? 0)
        }

        privilegedPositionRequested = isPrivilegedQueue

        if queuePosition > 0 {
            core.sendMessageToPeer(username, PlaceInQueueResponse(filename: virtualPath, place: queuePosition))
        }

        // Update queue position in our list of uploads
        upload.queuePosition = queuePosition
        updateTransfer(upload, updateParent: false)
    }
}
