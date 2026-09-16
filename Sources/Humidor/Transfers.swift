// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore
import Observation
import SwiftUI

/// Base class of the downloads and uploads pages.
@MainActor
@Observable
class TransfersPage: MainPage {

    static let statuses: [TransferStatus: String] = [
        .queued: String(localized: "Queued"),
        TransferStatus(rawValue: "Queued (prioritized)"): String(localized: "Queued (prioritized)"),
        TransferStatus(rawValue: "Queued (privileged)"): String(localized: "Queued (privileged)"),
        .gettingStatus: String(localized: "Getting status"),
        .transferring: String(localized: "Transferring"),
        .connectionClosed: String(localized: "Connection closed"),
        .connectionTimeout: String(localized: "Connection timeout"),
        .userLoggedOff: String(localized: "User logged off"),
        .paused: String(localized: "Paused"),
        .cancelled: String(localized: "Cancelled"),
        .finished: String(localized: "Finished"),
        .filtered: String(localized: "Filtered"),
        .downloadFolderError: String(localized: "Download folder error"),
        .localFileError: String(localized: "Local file error"),
        TransferStatus(rawValue: TransferRejectReason.banned): String(localized: "Banned"),
        TransferStatus(rawValue: TransferRejectReason.fileNotShared): String(localized: "File not shared"),
        TransferStatus(rawValue: TransferRejectReason.pendingShutdown): String(localized: "Pending shutdown"),
        TransferStatus(rawValue: TransferRejectReason.fileReadError): String(localized: "File read error")
    ]

    static let statusPriorities: [TransferStatus: Int] = [
        .filtered: 0,
        .finished: 1,
        .paused: 2,
        .cancelled: 3,
        .queued: 4,
        TransferStatus(rawValue: "Queued (prioritized)"): 4,
        TransferStatus(rawValue: "Queued (privileged)"): 4,
        .userLoggedOff: 5,
        .connectionClosed: 6,
        .connectionTimeout: 7,
        TransferStatus(rawValue: TransferRejectReason.fileNotShared): 8,
        TransferStatus(rawValue: TransferRejectReason.pendingShutdown): 9,
        TransferStatus(rawValue: TransferRejectReason.fileReadError): 10,
        .localFileError: 11,
        .downloadFolderError: 12,
        TransferStatus(rawValue: TransferRejectReason.banned): 13,
        .gettingStatus: 9998,
        .transferring: 9999
    ]

    static let unknownStatusPriority = 1000

    /// Row of a transfer in the list view
    enum RowState {
        /// Row needs to be created when the list is rebuilt
        case pendingRebuild
        /// Row needs to be created, and was added since the page was last shown
        case pendingAdd
        case row(TreeRow)

        var row: TreeRow? {
            if case let .row(row) = self {
                return row
            }
            return nil
        }
    }

    /// Parent row of a user or folder, with its child transfers
    final class ParentRow {
        let row: TreeRow?
        var childTransfers: [Transfer] = []

        init(row: TreeRow?) {
            self.row = row
        }
    }

    struct ClearItem {
        let label: String
        let action: @MainActor () -> Void
    }

    @ObservationIgnored let window: MainWindow
    @ObservationIgnored let transferPage: MainWindow.Page
    @ObservationIgnored let type: TransferDirection
    @ObservationIgnored let pathSeparator: String
    @ObservationIgnored let pathLabel: String
    @ObservationIgnored let retryLabel: String
    @ObservationIgnored let abortLabel: String

    @ObservationIgnored private(set) var treeView: TreeView!
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private(set) var users = OrderedDictionary<String, ParentRow>()
    @ObservationIgnored private var paths = OrderedDictionary<String, ParentRow>()
    @ObservationIgnored private(set) var iterators: [Transfer: RowState] = [:]
    @ObservationIgnored private var pendingFolderRows = Set<String>()
    @ObservationIgnored private var pendingUserRows = Set<String>()
    @ObservationIgnored private var rowID = 0
    @ObservationIgnored private var isInitialized = false

    // Selected users and transfers, in the order they were selected
    @ObservationIgnored private(set) var selectedUsers = OrderedSet<String>()
    @ObservationIgnored private(set) var selectedTransfers = OrderedSet<Transfer>()

    @ObservationIgnored private var popupMenu: FilePopupMenu!
    @ObservationIgnored private var popupMenuUsers: UserPopupMenu!
    @ObservationIgnored private var popupMenuClear: PopupMenu!
    @ObservationIgnored private var popupMenuCopy: PopupMenu!

    private(set) var groupingMode: GroupingMode?
    private(set) var hasTransfers = false
    private(set) var userCountText = "0"
    private(set) var fileCountText = "0"
    var isExpanded: Bool {
        didSet {
            onExpandTree()
        }
    }

    init(window: MainWindow, type: TransferDirection, page: MainWindow.Page, pathSeparator: String,
         pathLabel: String, retryLabel: String, abortLabel: String) {

        self.window = window
        self.type = type
        self.transferPage = page
        self.pathSeparator = pathSeparator
        self.pathLabel = pathLabel
        self.retryLabel = retryLabel
        self.abortLabel = abortLabel
        self.isExpanded = (type == .download) ? config.transfers.downloadsExpanded : config.transfers.uploadsExpanded

        treeView = TreeView(
            columns: [
                // Visible columns
                TreeColumn(id: "user", title: String(localized: "User"), width: 200,
                           sensitiveColumn: "is_sensitive_data"),
                TreeColumn(id: "path", title: pathLabel, width: 200, expandsColumn: true,
                           sensitiveColumn: "is_sensitive_data",
                           tooltipCallback: { [unowned self] in onFilePathTooltip($0, $1) }),
                TreeColumn(id: "file_type", title: String(localized: "File Type"), kind: .icon, width: 40,
                           hidesHeader: true, sensitiveColumn: "is_sensitive_data"),
                TreeColumn(id: "filename", title: String(localized: "Filename"), width: 200, expandsColumn: true,
                           sensitiveColumn: "is_sensitive_data",
                           tooltipCallback: { [unowned self] in onFilePathTooltip($0, $1) }),
                TreeColumn(id: "status", title: String(localized: "Status"), width: 140,
                           sensitiveColumn: "is_sensitive_data"),
                TreeColumn(id: "queue_position", title: String(localized: "Queue"), kind: .number, width: 90,
                           sortColumn: "queue_position_data"),
                TreeColumn(id: "percent", title: String(localized: "Percent"), kind: .progress, width: 90,
                           sensitiveColumn: "is_sensitive_data"),
                TreeColumn(id: "size", title: String(localized: "Size"), kind: .number, width: 180,
                           sortColumn: "size_data", sensitiveColumn: "is_sensitive_data"),
                TreeColumn(id: "speed", title: String(localized: "Speed"), kind: .number, width: 100,
                           sortColumn: "speed_data", sensitiveColumn: "is_sensitive_data"),
                TreeColumn(id: "time_elapsed", title: String(localized: "Time Elapsed"), kind: .number, width: 140,
                           sortColumn: "time_elapsed_data", sensitiveColumn: "is_sensitive_data"),
                TreeColumn(id: "time_left", title: String(localized: "Time Left"), kind: .number, width: 140,
                           sortColumn: "time_left_data", sensitiveColumn: "is_sensitive_data"),

                // Hidden data columns
                .data("size_data"),
                .data("current_bytes_data"),
                .data("speed_data"),
                .data("queue_position_data"),
                .data("time_elapsed_data"),
                .data("time_left_data"),
                .data("is_sensitive_data"),
                .data("transfer_data"),
                .data("id_data", isIteratorKey: true, sortOrder: .ascending)
            ],
            hasTree: true, multiSelect: true, persistentSort: true, name: type == .download ? "download" : "upload",
            activateRow: { [unowned self] _, row, _ in onRowActivated(row) },
            deleteAccelerator: { [unowned self] _ in onRemoveTransfersAccelerator() }
        )

        treeView.accelerators += [
            Accelerator(.character("t")) { [unowned self] in onAbortTransfersAccelerator() },
            Accelerator(.character("r")) { [unowned self] in onRetryTransfersAccelerator() },
            Accelerator(.return, modifiers: .option) { [unowned self] in onFilePropertiesAccelerator() }
        ]

        popupMenuUsers = UserPopupMenu()
        popupMenuClear = PopupMenu()
        popupMenuCopy = PopupMenu()
        popupMenuCopy.addItems(
            .action(String(localized: "Copy File Path")) { [unowned self] in onCopyFilePath() },
            .action(String(localized: "Copy URL")) { [unowned self] in onCopyURL() },
            .action(String(localized: "Copy Folder URL")) { [unowned self] in onCopyFolderURL() }
        )

        popupMenu = FilePopupMenu { [unowned self] menu in onPopupMenu(menu) }

        if !window.application.isolatedMode {
            popupMenu.addItems(
                .action(String(localized: "Open File")) { [unowned self] in onOpenFile() },
                .action(String(localized: "Open in File Manager")) { [unowned self] in onOpenFileManager() }
            )
        }

        popupMenu.addItems(
            .action(String(localized: "File Properties")) { [unowned self] in onFileProperties() },
            .separator,
            .action(retryLabel) { [unowned self] in onRetryTransfer() },
            .action(abortLabel) { [unowned self] in onAbortTransfer() },
            .action(String(localized: "Remove")) { [unowned self] in onRemoveTransfer() },
            .separator,
            .action(String(localized: "View User Profile")) { [unowned self] in onUserProfile() },
            .action(String(localized: "Browse Folder")) { [unowned self] in onBrowseFolder() },
            .action(String(localized: "Search")) { [unowned self] in onFileSearch() },
            .separator,
            .submenu(String(localized: "Copy"), popupMenuCopy),
            .submenu(String(localized: "Clear All"), popupMenuClear),
            .submenu(String(localized: "User Actions"), popupMenuUsers)
        )

        treeView.popupMenu = popupMenu

        onToggleTree((type == .download) ? config.transfers.groupDownloads : config.transfers.groupUploads)
    }

    func setUpClearMenu() {
        for item in clearItems {
            if let item {
                popupMenuClear.addItems(.action(item.label, item.action))
            } else {
                popupMenuClear.addItems(.separator)
            }
        }
    }

    func onFocus() {
        updateModel()
        window.removeTabChanged(transferPage)

        if hasTransfers {
            treeView.grabFocus()
        }
    }

    // MARK: Subclass Hooks

    /// Items of the "Clear All" menu. Nil items are separators.
    var clearItems: [ClearItem?] { [] }

    var transferList: [Transfer] { [] }

    func transferFolderPath(_ transfer: Transfer) -> String { transfer.folderPath }
    func retrySelectedTransfers() {}
    func abortSelectedTransfers() {}
    func removeSelectedTransfers() {}
    func onCopyURL() {}
    func onCopyFolderURL() {}
    func onOpenFile() {}
    func onOpenFileManager() {}
    func onBrowseFolder() {}

    // MARK: Transfers

    func initTransfers() {
        isStarted = true

        for transfer in transferList {
            // Tab highlights are only used when transfers are appended, but we
            // won't create a transfer row until the tab is active. To prevent
            // spurious highlights when a previously added transfer changes, but
            // the tab wasn't activated yet (row state is nil), mark the row as pending.
            iterators[transfer] = .pendingRebuild
        }

        hasTransfers = !transferList.isEmpty
    }

    func selectTransfers() {
        selectedTransfers.removeAll()
        selectedUsers.removeAll()

        for row in treeView.selectedRows {
            if let transfer = treeView.rowValue(row, "transfer_data").object(as: Transfer.self) {
                selectTransfer(transfer, selectUser: true)
            }
        }
    }

    private func selectChildTransfers(_ transfer: Transfer) {
        guard transfer.virtualPath.isEmpty else {
            return
        }

        // Dummy Transfer object for user/folder rows
        let user = transfer.username
        let parentRow = transfer.folderPath.isEmpty ? users[user] : paths[user + transferFolderPath(transfer)]

        for childTransfer in parentRow?.childTransfers ?? [] {
            selectTransfer(childTransfer)
        }
    }

    private func selectTransfer(_ transfer: Transfer, selectUser: Bool = false) {
        if !transfer.virtualPath.isEmpty && !selectedTransfers.contains(transfer) {
            selectedTransfers.append(transfer)
        }

        if selectUser && !selectedUsers.contains(transfer.username) {
            selectedUsers.append(transfer.username)
        }

        selectChildTransfers(transfer)
    }

    func onFileSearch() {
        guard let transfer = selectedTransfers.first(where: { _ in true }) else {
            return
        }

        let basename = transfer.virtualPath.components(separatedBy: "\\").last ?? ""
        window.search.searchText = basename
        window.changeMainPage(.search)
    }

    func translateStatus(_ status: TransferStatus) -> String {
        Self.statuses[status] ?? status.rawValue
    }

    func updateLimits() {
        // Underline status bar bandwidth labels when alternative speed limits are active
        let mode = (type == .download) ? config.transfers.useDownloadSpeedLimit : config.transfers.useUploadSpeedLimit

        if type == .download {
            window.isDownloadLimitAlternative = (mode == .alternative)
        } else {
            window.isUploadLimitAlternative = (mode == .alternative)
        }
    }

    private func updateNumUsersFiles() {
        userCountText = humanize(users.count)
        fileCountText = humanize(transferList.count)
    }

    func updateModel(_ transfer: Transfer? = nil, updateParent: Bool = true) {
        guard isStarted else {
            return
        }

        if window.currentPage != transferPage {
            if let transfer, iterators[transfer] == nil {
                window.requestTabChanged(transferPage)
                iterators[transfer] = .pendingAdd
            }

            // No need to do unnecessary work if transfers are not visible
            return
        }

        var hasDisabledSorting = false
        var hasSelectedParent = false
        var shouldUpdateCounters = false
        let useReverseFilePath = config.ui.reverseFilePaths

        if let transfer {
            shouldUpdateCounters = updateSpecific(transfer, useReverseFilePath: useReverseFilePath)

        } else {
            for transfer in transferList {
                let shouldSelectParent: Bool

                if case .pendingAdd = iterators[transfer] {
                    shouldSelectParent = !hasSelectedParent
                } else {
                    shouldSelectParent = false
                }

                let isRowAdded = updateSpecific(transfer, selectParent: shouldSelectParent,
                                                useReverseFilePath: useReverseFilePath)

                if shouldSelectParent {
                    hasSelectedParent = true
                }

                guard isRowAdded else {
                    continue
                }

                shouldUpdateCounters = true

                if !hasDisabledSorting {
                    // Optimization: disable sorting while adding rows
                    treeView.freeze()
                    hasDisabledSorting = true
                }
            }
        }

        if updateParent {
            updateParentRows(transfer)
        }

        if shouldUpdateCounters {
            updateNumUsersFiles()
        }

        if hasDisabledSorting {
            treeView.unfreeze()
        }

        if !isInitialized {
            onExpandTree()
            isInitialized = true
        }
    }

    func updatePendingParentRows() {
        for userFolderPath in pendingFolderRows {
            guard let parentRow = paths[userFolderPath], let row = parentRow.row else {
                continue
            }
            updateParentRow(row, childTransfers: parentRow.childTransfers, userFolderPath: userFolderPath)
        }

        for username in pendingUserRows {
            guard let parentRow = users[username], let row = parentRow.row else {
                continue
            }
            updateParentRow(row, childTransfers: parentRow.childTransfers, username: username)
        }

        pendingFolderRows.removeAll()
        pendingUserRows.removeAll()
    }

    private func updateParentRows(_ transfer: Transfer? = nil) {
        guard groupingMode != .ungrouped else {
            return
        }

        if let transfer {
            let username = transfer.username

            if !paths.isEmpty {
                pendingFolderRows.insert(username + transferFolderPath(transfer))
            }

            pendingUserRows.insert(username)
            return
        }

        if !paths.isEmpty {
            for (userFolderPath, parentRow) in Array(paths) {
                if let row = parentRow.row {
                    updateParentRow(row, childTransfers: parentRow.childTransfers, userFolderPath: userFolderPath)
                }
            }
        }

        for (username, parentRow) in Array(users) {
            if let row = parentRow.row {
                updateParentRow(row, childTransfers: parentRow.childTransfers, username: username)
            }
        }
    }

    static func humanQueuePosition(_ queuePosition: Int) -> String {
        queuePosition > 0 ? String(queuePosition) : ""
    }

    static func humanSizeProgress(_ currentByteOffset: Int, _ size: Int) -> String {
        if currentByteOffset >= size {
            return humanSize(size)
        }
        return "\(humanSize(currentByteOffset)) / \(humanSize(size))"
    }

    static func humanSpeedValue(_ speed: Int) -> String {
        speed > 0 ? humanSpeed(speed) : ""
    }

    static func humanElapsed(_ elapsed: Int) -> String {
        elapsed > 0 ? humanLength(elapsed) : ""
    }

    static func humanLeft(_ left: Int) -> String {
        left >= 1 ? humanLength(left) : ""
    }

    static func percent(_ currentByteOffset: Int, _ size: Int) -> Int {
        if currentByteOffset > size || size <= 0 {
            return 100
        }

        // Multiply first to avoid decimals
        return (100 * currentByteOffset) / size
    }

    private func updateParentRow(_ row: TreeRow, childTransfers: [Transfer], username: String? = nil,
                                 userFolderPath: String? = nil) {
        var speed = 0
        var totalSize = 0
        var currentByteOffset = 0
        var elapsed = 0
        var parentStatus = TransferStatus.finished

        if childTransfers.isEmpty {
            // Remove parent row if no children are present anymore
            if let userFolderPath {
                if let transfer = treeView.rowValue(row, "transfer_data").object(as: Transfer.self) {
                    users[transfer.username]?.childTransfers.removeAll { $0 === transfer }
                }
                paths.removeValue(forKey: userFolderPath)

            } else if let username {
                users.removeValue(forKey: username)
            }

            treeView.removeRow(row)

            if treeView.isEmpty {
                // Show tab description
                hasTransfers = false
            }

            updateNumUsersFiles()
            return
        }

        for transfer in childTransfers {
            let status = transfer.status ?? TransferStatus(rawValue: "")

            if status == .transferring {
                // "Transferring" status always has the highest priority
                parentStatus = status
                speed += transfer.speed

            } else if let parentStatusPriority = Self.statusPriorities[parentStatus] {
                let statusPriority = Self.statusPriorities[status] ?? Self.unknownStatusPriority

                if statusPriority > parentStatusPriority {
                    parentStatus = status
                }
            }

            if status == .filtered && !transfer.virtualPath.isEmpty {
                // We don't want to count filtered files when calculating the progress
                continue
            }

            elapsed += Int(transfer.timeElapsed)
            totalSize += transfer.size
            currentByteOffset += transfer.currentByteOffset ?? 0
        }

        guard let transfer = treeView.rowValue(row, "transfer_data").object(as: Transfer.self) else {
            return
        }

        var shouldUpdateSize = false
        var values: [String: TreeValue] = [:]

        if transfer.status != parentStatus {
            values["status"] = .string(translateStatus(parentStatus))

            if parentStatus == .userLoggedOff {
                values["is_sensitive_data"] = false
            } else if transfer.status == .userLoggedOff {
                values["is_sensitive_data"] = true
            }

            transfer.status = parentStatus
        }

        if transfer.speed != speed {
            values["speed"] = .string(Self.humanSpeedValue(speed))
            values["speed_data"] = .int(speed)
            transfer.speed = speed
        }

        if Int(transfer.timeElapsed) != elapsed {
            let left = (speed > 0 && totalSize > currentByteOffset) ? (totalSize - currentByteOffset) / speed : 0

            values["time_elapsed"] = .string(Self.humanElapsed(elapsed))
            values["time_left"] = .string(Self.humanLeft(left))
            values["time_elapsed_data"] = .int(elapsed)
            values["time_left_data"] = .int(left)
            transfer.timeElapsed = Double(elapsed)
        }

        if transfer.currentByteOffset != currentByteOffset {
            values["current_bytes_data"] = .int(currentByteOffset)
            transfer.currentByteOffset = currentByteOffset
            shouldUpdateSize = true
        }

        if transfer.size != totalSize {
            values["size_data"] = .int(totalSize)
            transfer.size = totalSize
            shouldUpdateSize = true
        }

        if shouldUpdateSize {
            values["percent"] = .int(Self.percent(currentByteOffset, totalSize))
            values["size"] = .string(Self.humanSizeProgress(currentByteOffset, totalSize))
        }

        if !values.isEmpty {
            treeView.setRowValues(row, values)
        }
    }

    @discardableResult
    private func updateSpecific(_ transfer: Transfer, selectParent: Bool = false,
                                useReverseFilePath: Bool = true) -> Bool {
        let currentByteOffset = transfer.currentByteOffset ?? 0
        let queuePosition = transfer.queuePosition
        var status = transfer.status ?? TransferStatus(rawValue: "")

        if let modifier = transfer.modifier, status == .queued {
            // Priority status
            status = TransferStatus(rawValue: "\(status.rawValue) (\(modifier))")
        }

        let translatedStatus = translateStatus(status)
        let size = transfer.size
        let speed = transfer.speed
        let elapsed = Int(transfer.timeElapsed)
        let left = transfer.timeLeft

        // Modify old transfer
        if let row = iterators[transfer]?.row {
            var shouldUpdateSize = false
            let oldTranslatedStatus = treeView.rowValue(row, "status").string
            var values: [String: TreeValue] = [:]

            if oldTranslatedStatus != translatedStatus {
                values["status"] = .string(translatedStatus)

                if transfer.status == .userLoggedOff {
                    values["is_sensitive_data"] = false
                } else if oldTranslatedStatus == String(localized: "User logged off") {
                    values["is_sensitive_data"] = true
                }
            }

            if treeView.rowValue(row, "speed_data").int != speed {
                values["speed"] = .string(Self.humanSpeedValue(speed))
                values["speed_data"] = .int(speed)
            }

            if treeView.rowValue(row, "time_elapsed_data").int != elapsed {
                values["time_elapsed"] = .string(Self.humanElapsed(elapsed))
                values["time_left"] = .string(Self.humanLeft(left))
                values["time_elapsed_data"] = .int(elapsed)
                values["time_left_data"] = .int(left)
            }

            if treeView.rowValue(row, "current_bytes_data").int != currentByteOffset {
                values["current_bytes_data"] = .int(currentByteOffset)
                shouldUpdateSize = true
            }

            if treeView.rowValue(row, "size_data").int != size {
                values["size_data"] = .int(size)
                shouldUpdateSize = true
            }

            if treeView.rowValue(row, "queue_position_data").int != queuePosition {
                values["queue_position"] = .string(Self.humanQueuePosition(queuePosition))
                values["queue_position_data"] = .int(queuePosition)
            }

            if shouldUpdateSize {
                values["percent"] = .int(Self.percent(currentByteOffset, size))
                values["size"] = .string(Self.humanSizeProgress(currentByteOffset, size))
            }

            if !values.isEmpty {
                treeView.setRowValues(row, values)
            }
            return false
        }

        let isExpandAllowed = isInitialized
        var shouldExpandUser = false
        var shouldExpandFolder = false
        var userRow: TreeRow?
        var userFolderPathRow: TreeRow?
        var parentRow: TreeRow?
        var selectRow: TreeRow?

        let user = transfer.username
        let basename = transfer.virtualPath.components(separatedBy: "\\").last ?? ""
        let originalFolderPath = transferFolderPath(transfer)
        var folderPath = originalFolderPath
        let isSensitive = (status != .userLoggedOff)

        if useReverseFilePath {
            folderPath = folderPath.components(separatedBy: pathSeparator).reversed().joined(separator: pathSeparator)
        }

        if treeView.isEmpty {
            // Hide tab description
            hasTransfers = true
        }

        if groupingMode != .ungrouped {
            // Group by folder or user
            if users[user] == nil {
                // Create parent if it doesn't exist
                let row = treeView.addRow(
                    parentRowValues(user: user, path: "", status: translatedStatus, isSensitive: isSensitive,
                                    transfer: Transfer(username: user, virtualPath: "", status: status)),
                    selectRow: false
                )

                if isExpandAllowed {
                    shouldExpandUser = (groupingMode == .folderGrouping) || isExpanded
                }

                rowID += 1
                users[user] = ParentRow(row: row)
            }

            let userParentRow = users[user]!
            userRow = userParentRow.row
            parentRow = userRow

            if selectParent {
                selectRow = parentRow
            }

            if groupingMode == .folderGrouping {
                // Group by folder
                // Make sure we don't add files to the wrong user in the list view
                let userFolderPath = user + originalFolderPath

                if paths[userFolderPath] == nil {
                    // Dummy Transfer object
                    let pathTransfer = Transfer(username: user, virtualPath: "", folderPath: originalFolderPath,
                                                status: status)
                    let row = treeView.addRow(
                        parentRowValues(user: user, path: folderPath, status: translatedStatus,
                                        isSensitive: isSensitive, transfer: pathTransfer),
                        selectRow: false, parent: userRow
                    )

                    userParentRow.childTransfers.append(pathTransfer)
                    shouldExpandFolder = isExpandAllowed && isExpanded
                    rowID += 1
                    paths[userFolderPath] = ParentRow(row: row)
                }

                let folderParentRow = paths[userFolderPath]!
                userFolderPathRow = folderParentRow.row
                parentRow = userFolderPathRow
                folderParentRow.childTransfers.append(transfer)

                if selectParent, let userRow, shouldExpandUser || treeView.isRowExpanded(userRow) {
                    selectRow = parentRow
                }

                // Group by folder, path not visible in file rows
                folderPath = ""
            } else {
                userParentRow.childTransfers.append(transfer)
            }
        } else {
            // No grouping
            if users[user] == nil {
                users[user] = ParentRow(row: nil)
            }
            users[user]!.childTransfers.append(transfer)
        }

        // Add a new transfer
        let row = treeView.addRow([
            .string(user),
            .string(folderPath),
            .string(Theme.fileTypeIconName(basename)),
            .string(basename),
            .string(translatedStatus),
            .string(Self.humanQueuePosition(queuePosition)),
            .int(Self.percent(currentByteOffset, size)),
            .string(Self.humanSizeProgress(currentByteOffset, size)),
            .string(Self.humanSpeedValue(speed)),
            .string(Self.humanElapsed(elapsed)),
            .string(Self.humanLeft(left)),
            .int(size),
            .int(currentByteOffset),
            .int(speed),
            .int(queuePosition),
            .int(elapsed),
            .int(left),
            .bool(isSensitive),
            .object(transfer),
            .int(rowID)
        ], selectRow: false, parent: parentRow)

        iterators[transfer] = row.map { .row($0) }
        rowID += 1

        if shouldExpandUser, let userRow {
            treeView.expandRow(userRow)
        }

        if shouldExpandFolder, let userFolderPathRow {
            treeView.expandRow(userFolderPathRow)
        }

        if let selectRow, !treeView.isRowSelected(selectRow) || treeView.numSelectedRows != 1 {
            // Select parent row of newly added transfer, and scroll to it.
            // Unselect any other rows to prevent accidental actions on previously
            // selected transfers.
            treeView.unselectAllRows()
            treeView.selectRow(selectRow, expandRows: false)
        }

        return true
    }

    private func parentRowValues(user: String, path: String, status: String, isSensitive: Bool,
                                 transfer: Transfer) -> [TreeValue] {
        [
            .string(user), .string(path), "", "", .string(status), "", 0, "", "", "", "",
            0, 0, 0, 0, 0, 0,
            .bool(isSensitive),
            .object(transfer),
            .int(rowID)
        ]
    }

    func clearModel() {
        isInitialized = false
        users.removeAll()
        paths.removeAll()
        pendingFolderRows.removeAll()
        pendingUserRows.removeAll()
        selectedTransfers.removeAll()
        selectedUsers.removeAll()
        treeView.clear()
        rowID = 0

        iterators.removeAll()

        if isStarted {
            for transfer in transferList {
                iterators[transfer] = .pendingRebuild
            }
        }
    }

    // MARK: Core Events

    func abortTransfer(_ event: TransferAbort) {
        if event.status != .queued {
            updateModel(event.transfer, updateParent: event.updateParent)
        }
    }

    func abortTransfers(_ event: TransfersAbort) {
        updateParentRows()
    }

    func clearTransfer(_ event: TransferUpdate) {
        let transfer = event.transfer
        let rowState = iterators.removeValue(forKey: transfer)

        guard let row = rowState?.row else {
            return
        }

        let user = transfer.username

        if groupingMode == .folderGrouping {
            paths[user + transferFolderPath(transfer)]?.childTransfers.removeAll { $0 === transfer }
        } else {
            users[user]?.childTransfers.removeAll { $0 === transfer }

            if groupingMode == .ungrouped, users[user]?.childTransfers.isEmpty == true {
                users.removeValue(forKey: user)
            }
        }

        treeView.removeRow(row)

        if event.updateParent {
            updateParentRows(transfer)
            updateNumUsersFiles()
        }

        if treeView.isEmpty {
            // Show tab description
            hasTransfers = false
        }
    }

    func clearTransfers(_ event: TransfersClear) {
        updateParentRows()
    }

    // MARK: User Menu

    private func addPopupMenuUser(_ popup: UserPopupMenu, user: String) {
        popup.addItems(
            .separator,
            .action(String(localized: "Select User's Transfers")) { [unowned self] in onSelectUserTransfers(user) }
        )
        popup.toggleUserItems()
    }

    private func populatePopupMenuUsers() {
        popupMenuUsers.clear()

        guard !selectedUsers.isEmpty else {
            return
        }

        // Multiple users, create submenus for some of them
        if selectedUsers.count > 1 {
            for user in selectedUsers.prefix(20) {
                let popup = UserPopupMenu(username: user)
                addPopupMenuUser(popup, user: user)
                popupMenuUsers.addItems(.submenu(user, popup))
            }
            return
        }

        // Single user, add items directly to "User Actions" submenu
        let user = selectedUsers.first { _ in true }!
        popupMenuUsers.setupUserMenu(user)
        addPopupMenuUser(popupMenuUsers, user: user)
    }

    // MARK: Events

    private func onExpandTree() {
        guard groupingMode != .ungrouped else {
            return
        }

        if isExpanded {
            treeView.expandAllRows()
        } else {
            treeView.collapseAllRows()

            if groupingMode == .folderGrouping {
                treeView.expandRootRows()
            }
        }

        if type == .download {
            config.transfers.downloadsExpanded = isExpanded
        } else {
            config.transfers.uploadsExpanded = isExpanded
        }
        config.writeConfiguration()
    }

    func onToggleTree(_ mode: GroupingMode) {
        let isActive = (mode != .ungrouped)

        if type == .download {
            config.transfers.groupDownloads = mode
        } else {
            config.transfers.groupUploads = mode
        }

        groupingMode = mode
        clearModel()
        treeView.hasTree = isActive

        if !transferList.isEmpty {
            updateModel()
        }
    }

    private func onPopupMenu(_ menu: PopupMenu) {
        selectTransfers()
        (menu as? FilePopupMenu)?.setNumSelectedFiles(selectedTransfers.count)
        populatePopupMenuUsers()
    }

    private func onFilePathTooltip(_ treeView: TreeView, _ row: TreeRow) -> String? {
        guard let transfer = treeView.rowValue(row, "transfer_data").object(as: Transfer.self) else {
            return nil
        }
        return transfer.virtualPath.isEmpty ? transferFolderPath(transfer) : transfer.virtualPath
    }

    private func onRowActivated(_ row: TreeRow) {
        if treeView.collapseRow(row) {
            return
        }

        if treeView.expandRow(row) {
            return
        }

        selectTransfers()

        let action = (type == .download) ? config.transfers.downloadDoubleClick : config.transfers.uploadDoubleClick

        if window.application.isolatedMode && [1, 2].contains(action) {
            // External applications not available in isolated mode
            return
        }

        switch action {
        case 1: onOpenFile()                   // Open File
        case 2: onOpenFileManager()            // Open in File Manager
        case 3: onFileSearch()                 // Search
        case 4: abortSelectedTransfers()       // Pause / Abort
        case 5: removeSelectedTransfers()      // Remove
        case 6: retrySelectedTransfers()       // Resume / Retry
        case 7: onBrowseFolder()               // Browse Folder
        default: break
        }
    }

    private func onSelectUserTransfers(_ selectedUser: String) {
        guard !selectedUsers.isEmpty, let userParentRow = users[selectedUser] else {
            return
        }

        treeView.unselectAllRows()

        for transfer in userParentRow.childTransfers {
            if let row = iterators[transfer]?.row {
                treeView.selectRow(row, shouldScroll: false)
                continue
            }

            // Dummy Transfer object for folder rows
            guard let folderParentRow = paths[transfer.username + transferFolderPath(transfer)] else {
                continue
            }

            for childTransfer in folderParentRow.childTransfers {
                if let row = iterators[childTransfer]?.row {
                    treeView.selectRow(row, shouldScroll: false)
                }
            }
        }
    }

    /// T: abort transfer.
    private func onAbortTransfersAccelerator() -> Bool {
        selectTransfers()
        abortSelectedTransfers()
        return true
    }

    /// R: retry transfers.
    private func onRetryTransfersAccelerator() -> Bool {
        selectTransfers()
        retrySelectedTransfers()
        return true
    }

    /// Delete: remove transfers.
    private func onRemoveTransfersAccelerator() {
        selectTransfers()
        removeSelectedTransfers()
    }

    /// Option+Return: show file properties dialog.
    private func onFilePropertiesAccelerator() -> Bool {
        selectTransfers()
        onFileProperties()
        return true
    }

    private func onUserProfile() {
        if let username = selectedUsers.first(where: { _ in true }) {
            core.userInfo.showUser(username)
        }
    }

    private func onFileProperties() {
        var data: [FilePropertiesItem] = []
        var selectedSize = 0
        var selectedLength = 0

        for transfer in selectedTransfers {
            let username = transfer.username
            let filePath = transfer.virtualPath
            let fileSize = transfer.size
            let length = FileListMessage.parseFileAttributes(transfer.fileAttributes).length
            let pathComponents = filePath.components(separatedBy: "\\")

            selectedSize += fileSize

            if let length {
                selectedLength += length
            }

            data.append(FilePropertiesItem(
                user: username,
                filePath: filePath,
                basename: pathComponents.last ?? "",
                virtualFolderPath: pathComponents.dropLast().joined(separator: "\\"),
                realFolderPath: transfer.folderPath,
                queuePosition: transfer.queuePosition,
                speed: core.users.watched[username]?.uploadSpeed ?? 0,
                size: fileSize,
                fileAttributes: transfer.fileAttributes,
                countryCode: core.users.countries[username]
            ))
        }

        guard !data.isEmpty else {
            return
        }

        let fileProperties = AppDelegate.shared.fileProperties
        fileProperties.updateProperties(data, totalSize: selectedSize, totalLength: selectedLength)
        fileProperties.present()
    }

    private func onCopyFilePath() {
        if let transfer = selectedTransfers.first(where: { _ in true }) {
            Clipboard.copyText(transfer.virtualPath)
        }
    }

    func onRetryTransfer() {
        selectTransfers()
        retrySelectedTransfers()
    }

    func onAbortTransfer() {
        selectTransfers()
        abortSelectedTransfers()
    }

    func onRemoveTransfer() {
        selectTransfers()
        removeSelectedTransfers()
    }
}

// MARK: - Downloads

@MainActor
final class DownloadsPage: TransfersPage {

    init(window: MainWindow) {
        super.init(window: window, type: .download, page: .downloads, pathSeparator: "/",
                   pathLabel: String(localized: "Path"), retryLabel: String(localized: "Resume"),
                   abortLabel: String(localized: "Pause"))

        setUpClearMenu()

        events.connect(.abortDownload) { [unowned self] in abortTransfer($0) }
        events.connect(.abortDownloads) { [unowned self] in abortTransfers($0) }
        events.connect(.clearDownload) { [unowned self] in clearTransfer($0) }
        events.connect(.clearDownloads) { [unowned self] in clearTransfers($0) }
        events.connect(.downloadLargeFolder) { [unowned self] in downloadLargeFolder($0) }
        events.connect(.folderDownloadFinished) { [unowned self] _ in folderDownloadFinished() }
        events.connect(.setConnectionStats) { [unowned self] in setConnectionStats($0) }
        events.connect(.start) { [unowned self] in initTransfers() }
        events.connect(.updateDownload) { [unowned self] in updateModel($0.transfer, updateParent: $0.updateParent) }
        events.connect(.updateDownloadLimits) { [unowned self] in updateLimits() }
    }

    override var clearItems: [ClearItem?] {
        [
            ClearItem(label: String(localized: "Finished / Filtered")) { [unowned self] in onClearFinishedFiltered() },
            nil,
            ClearItem(label: String(localized: "Finished")) {
                core.downloads.clearDownloads(statuses: [.finished])
            },
            ClearItem(label: String(localized: "Paused")) {
                core.downloads.clearDownloads(statuses: [.paused])
            },
            ClearItem(label: String(localized: "Filtered")) {
                core.downloads.clearDownloads(statuses: [.filtered])
            },
            ClearItem(label: String(localized: "Deleted")) {
                core.downloads.clearDownloads(clearDeleted: true)
            },
            ClearItem(label: String(localized: "Queued…")) { [unowned self] in onTryClearQueued() },
            nil,
            ClearItem(label: String(localized: "Everything…")) { [unowned self] in onTryClearAll() }
        ]
    }

    override var transferList: [Transfer] {
        core.downloads.transfers.values
    }

    override func transferFolderPath(_ transfer: Transfer) -> String {
        transfer.folderPath
    }

    override func retrySelectedTransfers() {
        core.downloads.retryDownloads(Array(selectedTransfers))
    }

    override func abortSelectedTransfers() {
        core.downloads.abortDownloads(Array(selectedTransfers))
    }

    override func removeSelectedTransfers() {
        core.downloads.clearDownloads(Array(selectedTransfers))
    }

    private func setConnectionStats(_ stats: ConnectionStats) {
        // Sync parent row updates with connection stats
        updatePendingParentRows()

        let downloadBandwidth = humanSpeed(stats.downloadBandwidth)
        window.downloadStatusText = "\(downloadBandwidth) ( \(core.downloads.activeUsers.count) )"
    }

    func onClearFinishedFiltered() {
        core.downloads.clearDownloads(statuses: [.finished, .filtered])
    }

    private func onTryClearQueued() {
        OptionDialog(
            title: String(localized: "Clear Queued Downloads"),
            message: String(localized: "Do you really want to clear all queued downloads?"),
            destructiveResponse: "ok"
        ) { _, _ in
            core.downloads.clearDownloads(statuses: [.queued])
        }.present()
    }

    private func onTryClearAll() {
        OptionDialog(
            title: String(localized: "Clear All Downloads"),
            message: String(localized: "Do you really want to clear all downloads?"),
            destructiveResponse: "ok"
        ) { _, _ in
            core.downloads.clearDownloads()
        }.present()
    }

    private func folderDownloadFinished() {
        if window.currentPage != transferPage {
            window.requestTabChanged(transferPage, isImportant: true)
        }
    }

    private func downloadLargeFolder(_ request: LargeFolderDownload) {
        OptionDialog(
            title: String(localized: "Download \(request.numFiles) files?"),
            message: String(localized: "Do you really want to download \(request.numFiles) files from \(request.username)'s folder \(request.folderPath)?"),
            buttons: [
                .init("cancel", String(localized: "Cancel")),
                .init("download", String(localized: "Download Folder"))
            ]
        ) { _, _ in
            request.proceed()
        }.present()
    }

    override func onCopyURL() {
        if let transfer = selectedTransfers.first(where: { _ in true }) {
            Clipboard.copyText(UserBrowse.soulseekURL(username: transfer.username, path: transfer.virtualPath))
        }
    }

    override func onCopyFolderURL() {
        guard let transfer = selectedTransfers.first(where: { _ in true }) else {
            return
        }

        let folderPath = transfer.virtualPath.components(separatedBy: "\\").dropLast().joined(separator: "\\")
        Clipboard.copyText(UserBrowse.soulseekURL(username: transfer.username, path: folderPath + "\\"))
    }

    override func onOpenFileManager() {
        var folderPath: String?

        for transfer in selectedTransfers {
            let filePath = core.downloads.currentDownloadFilePath(transfer)
            folderPath = (filePath as NSString).deletingLastPathComponent

            if transfer.status == .finished {
                // Prioritize finished downloads
                break
            }
        }

        if let folderPath {
            _ = openFolderPath(folderPath)
        }
    }

    override func onOpenFile() {
        for transfer in selectedTransfers {
            _ = openFilePath(core.downloads.currentDownloadFilePath(transfer))
        }
    }

    override func onBrowseFolder() {
        guard let transfer = selectedTransfers.first(where: { _ in true }) else {
            return
        }

        core.userBrowse.browseUser(transfer.username, path: transfer.virtualPath)
    }
}

// MARK: - Uploads

@MainActor
final class UploadsPage: TransfersPage {

    init(window: MainWindow) {
        super.init(window: window, type: .upload, page: .uploads, pathSeparator: "\\",
                   pathLabel: String(localized: "Folder"), retryLabel: String(localized: "Retry"),
                   abortLabel: String(localized: "Abort"))

        setUpClearMenu()

        events.connect(.abortUpload) { [unowned self] in abortTransfer($0) }
        events.connect(.abortUploads) { [unowned self] in abortTransfers($0) }
        events.connect(.clearUpload) { [unowned self] in clearTransfer($0) }
        events.connect(.clearUploads) { [unowned self] in clearTransfers($0) }
        events.connect(.setConnectionStats) { [unowned self] in setConnectionStats($0) }
        events.connect(.start) { [unowned self] in initTransfers() }
        events.connect(.updateUpload) { [unowned self] in updateModel($0.transfer, updateParent: $0.updateParent) }
        events.connect(.updateUploadLimits) { [unowned self] in updateLimits() }
        events.connect(.uploadsShutdownRequest) { [unowned self] in shutdownRequest() }
        events.connect(.uploadsShutdownCancel) { [unowned self] in shutdownCancel() }
    }

    override var clearItems: [ClearItem?] {
        [
            ClearItem(label: String(localized: "Finished / Cancelled / Failed")) {
                core.uploads.clearUploads(statuses: [.cancelled, .finished, .connectionTimeout, .localFileError])
            },
            ClearItem(label: String(localized: "Finished / Cancelled")) { [unowned self] in onClearFinishedCancelled() },
            nil,
            ClearItem(label: String(localized: "Finished")) {
                core.uploads.clearUploads(statuses: [.finished])
            },
            ClearItem(label: String(localized: "Cancelled")) {
                core.uploads.clearUploads(statuses: [.cancelled])
            },
            ClearItem(label: String(localized: "Failed")) {
                core.uploads.clearUploads(statuses: [.connectionTimeout, .localFileError])
            },
            ClearItem(label: String(localized: "User Logged Off")) {
                core.uploads.clearUploads(statuses: [.userLoggedOff])
            },
            ClearItem(label: String(localized: "Queued…")) { [unowned self] in onTryClearQueued() },
            nil,
            ClearItem(label: String(localized: "Everything…")) { [unowned self] in onTryClearAll() }
        ]
    }

    override var transferList: [Transfer] {
        core.uploads.transfers.values
    }

    override func transferFolderPath(_ transfer: Transfer) -> String {
        let virtualPath = transfer.virtualPath

        if !virtualPath.isEmpty {
            return virtualPath.components(separatedBy: "\\").dropLast().joined(separator: "\\")
        }
        return transfer.folderPath
    }

    override func retrySelectedTransfers() {
        core.uploads.retryUploads(Array(selectedTransfers))
    }

    override func abortSelectedTransfers() {
        core.uploads.abortUploads(Array(selectedTransfers), deniedMessage: "Cancelled")
    }

    override func removeSelectedTransfers() {
        core.uploads.clearUploads(Array(selectedTransfers))
    }

    private func setConnectionStats(_ stats: ConnectionStats) {
        // Sync parent row updates with connection stats
        updatePendingParentRows()

        let uploadBandwidth = humanSpeed(stats.uploadBandwidth)
        window.uploadStatusText = "\(uploadBandwidth) ( \(core.uploads.activeUsers.count) )"
    }

    private func shutdownRequest() {
        window.isShutdownPending = true
    }

    private func shutdownCancel() {
        window.isShutdownPending = false
        window.updateUserStatus()
    }

    func onClearFinishedCancelled() {
        core.uploads.clearUploads(statuses: [.cancelled, .finished])
    }

    private func onTryClearQueued() {
        OptionDialog(
            title: String(localized: "Clear Queued Uploads"),
            message: String(localized: "Do you really want to clear all queued uploads?"),
            destructiveResponse: "ok"
        ) { _, _ in
            core.uploads.clearUploads(statuses: [.queued])
        }.present()
    }

    private func onTryClearAll() {
        OptionDialog(
            title: String(localized: "Clear All Uploads"),
            message: String(localized: "Do you really want to clear all uploads?"),
            destructiveResponse: "ok"
        ) { _, _ in
            core.uploads.clearUploads()
        }.present()
    }

    override func onCopyURL() {
        if let transfer = selectedTransfers.first(where: { _ in true }) {
            Clipboard.copyText(UserBrowse.soulseekURL(username: config.server.login, path: transfer.virtualPath))
        }
    }

    override func onCopyFolderURL() {
        guard let transfer = selectedTransfers.first(where: { _ in true }) else {
            return
        }

        let folderPath = transfer.virtualPath.components(separatedBy: "\\").dropLast().joined(separator: "\\")
        Clipboard.copyText(UserBrowse.soulseekURL(username: config.server.login, path: folderPath + "\\"))
    }

    override func onOpenFileManager() {
        if let transfer = selectedTransfers.first(where: { _ in true }) {
            _ = openFolderPath(transfer.folderPath)
        }
    }

    override func onOpenFile() {
        for transfer in selectedTransfers {
            let basename = transfer.virtualPath.components(separatedBy: "\\").last ?? ""
            _ = openFilePath((transfer.folderPath as NSString).appendingPathComponent(basename))
        }
    }

    override func onBrowseFolder() {
        guard let transfer = selectedTransfers.first(where: { _ in true }) else {
            return
        }

        core.userBrowse.browseUser(config.server.login, path: transfer.virtualPath)
    }

    func onAbortUsers() {
        selectTransfers()

        var transfers = selectedTransfers

        for transfer in transferList where selectedUsers.contains(transfer.username) && !transfers.contains(transfer) {
            transfers.append(transfer)
        }

        core.uploads.abortUploads(Array(transfers), deniedMessage: "Cancelled")
    }

    func onBanUsers() {
        selectTransfers()

        for username in selectedUsers {
            core.networkFilter.banUser(username)
        }
    }
}
