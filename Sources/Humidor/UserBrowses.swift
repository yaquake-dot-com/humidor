// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore
import Observation
import SwiftUI

/// Browse shares page, containing a tab for each browsed user.
@MainActor
@Observable
final class UserBrowsesPage: TabbedPage {

    @ObservationIgnored let window: MainWindow
    let notebook: Notebook<UserBrowseTab>
    @ObservationIgnored private(set) var pages: [String: UserBrowseTab] = [:]

    var usernameText = ""
    private(set) var usernameFocusRequest = 0
    private(set) var isUsernameEnabled = true

    init(window: MainWindow) {
        self.window = window
        self.notebook = Notebook(window: window, parentPage: .userbrowse)

        notebook.removeAllPagesCallback = { core.userBrowse.removeAllUsers() }

        events.connect(.peerConnectionClosed) { [unowned self] in peerConnectionError($0) }
        events.connect(.peerConnectionError) { [unowned self] in peerConnectionError($0) }
        events.connect(.serverDisconnect) { [unowned self] _ in serverDisconnect() }
        events.connect(.sharedFileListProgress) { [unowned self] in sharedFileListProgress($0) }
        events.connect(.sharedFileListResponse) { [unowned self] in sharedFileList($0) }
        events.connect(.userBrowseRemoveUser) { [unowned self] in removeUser($0) }
        events.connect(.userBrowseShowUser) { [unowned self] in showUser($0) }
        events.connectMessage(.userStatus) { [unowned self] in userStatus($0) }
    }

    func onFocus() {
        guard window.currentPage == .userbrowse, notebook.pages.isEmpty else {
            return
        }

        if isUsernameEnabled {
            usernameFocusRequest += 1
        }
    }

    func onGetShares() {
        let entryText = usernameText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !entryText.isEmpty else {
            return
        }

        usernameText = ""

        if entryText.hasPrefix("slsk://") {
            core.userBrowse.openSoulseekURL(entryText)
        } else {
            core.userBrowse.browseUser(entryText)
        }
    }

    private func showUser(_ event: UserBrowseShowUser) {
        let user = event.username
        var page = pages[user]

        if page == nil {
            let newPage = UserBrowseTab(userBrowses: self, user: user)
            pages[user] = newPage
            notebook.appendPage(newPage, text: user, closeCallback: { [weak newPage] in newPage?.onClose() },
                                user: user)
            page = newPage

        } else if event.newRequest {
            page?.clearModel()
            page?.setIndeterminateProgress()
        }

        guard let page else {
            return
        }

        page.queuedPath = event.path
        page.browseQueuedPath()

        if event.switchPage {
            notebook.setCurrentPage(page)
            window.changeMainPage(.userbrowse)
        }
    }

    private func removeUser(_ user: String) {
        guard let page = pages[user] else {
            return
        }

        page.clear()
        notebook.removePage(page) {
            core.userBrowse.browseUser(user)
        }
        pages.removeValue(forKey: user)
    }

    private func peerConnectionError(_ event: PeerConnectionEvent) {
        guard let page = pages[event.username] else {
            return
        }

        if event.connType == ConnectionType.peer.rawValue {
            page.peerConnectionError()
        }
    }

    private func userStatus(_ msg: GetUserStatus) {
        if let page = pages[msg.user] {
            notebook.setUserStatus(page, user: msg.user, status: UserStatus(rawValue: msg.status) ?? .offline)
        }
    }

    private func sharedFileListProgress(_ progress: MessageProgress) {
        pages[progress.username]?.sharedFileListProgress(position: progress.bufferLength,
                                                          total: progress.messageSizeTotal)
    }

    private func sharedFileList(_ msg: SharedFileListResponse) {
        guard let username = msg.username else {
            return
        }
        pages[username]?.sharedFileList(msg)
    }

    private func serverDisconnect() {
        for (user, page) in pages {
            notebook.setUserStatus(page, user: user, status: .offline)
        }
    }
}

// MARK: - User Browse Tab

/// Shared files of a single user.
@MainActor
@Observable
final class UserBrowseTab: NotebookPage {

    @ObservationIgnored unowned let userBrowses: UserBrowsesPage
    @ObservationIgnored let window: MainWindow
    let user: String

    @ObservationIgnored private var isIndeterminateProgress = false
    @ObservationIgnored private(set) var isRefreshing = false
    @ObservationIgnored private var localPermissionLevel: PermissionLevel?
    @ObservationIgnored var queuedPath: String?
    @ObservationIgnored private var activeFolderPath: String?
    @ObservationIgnored private var selectedFiles = OrderedDictionary<String, Int>()
    @ObservationIgnored private var searchFolderPaths: [String] = []
    @ObservationIgnored private var query: String?
    @ObservationIgnored private var searchPosition = 0
    @ObservationIgnored private var pulseTimerID: Int?

    @ObservationIgnored private(set) var folderTreeView: TreeView!
    @ObservationIgnored private(set) var fileListView: TreeView!
    @ObservationIgnored private var userPopupMenu: UserPopupMenu!
    @ObservationIgnored private(set) var folderPopupMenu: PopupMenu!
    @ObservationIgnored private var filePopupMenu: FilePopupMenu!

    // Widget state
    private(set) var numFoldersText = ""
    private(set) var shareSizeText = ""
    private(set) var pathComponents: [String] = []
    private(set) var progress: Double?
    private(set) var infoMessage: (text: String, type: InfoBar.MessageType)?
    private(set) var isRetryVisible = false
    private(set) var isRefreshEnabled = true
    private(set) var isSaveEnabled = false
    var isSearchVisible = false {
        didSet {
            onShowSearch()
        }
    }
    var searchText = ""
    private(set) var searchFocusRequest = 0
    var isExpanded: Bool {
        didSet {
            onExpand()
        }
    }

    private var isLocalUser: Bool { user == config.server.login }

    init(userBrowses: UserBrowsesPage, user: String) {
        self.userBrowses = userBrowses
        self.window = userBrowses.window
        self.user = user
        self.isExpanded = config.userBrowse.expandFolders

        // Setup folder list view
        folderTreeView = TreeView(
            columns: [
                // Visible columns
                TreeColumn(id: "folder", title: String(localized: "Folder"), hidesHeader: true,
                           tooltipCallback: { treeView, row in treeView.rowValue(row, "folder_path_data").string }),

                // Hidden data columns
                .data("folder_path_data", isIteratorKey: true)
            ],
            hasTree: true, multiSelect: true,
            activateRow: { [unowned self] treeView, row, _ in onFolderRowActivated(treeView, row) },
            selectRow: { [unowned self] treeView, row in onSelectFolder(treeView, row) }
        )

        // Popup menu (folder list view)
        userPopupMenu = UserPopupMenu(username: user, tabName: .userBrowse) { [unowned self] _ in
            userPopupMenu.toggleUserItems()
        }

        folderPopupMenu = PopupMenu { [unowned self] _ in userPopupMenu.toggleUserItems() }

        if isLocalUser {
            folderPopupMenu.addItems(
                .action(String(localized: "Upload Folder & Subfolders…")) { [unowned self] in
                    onUploadFolderTo(recurse: true)
                },
                .separator
            )

            if !window.application.isolatedMode {
                folderPopupMenu.addItems(
                    .action(String(localized: "Open in File Manager")) { [unowned self] in onFileManager() }
                )
            }
        } else {
            folderPopupMenu.addItems(
                .action(String(localized: "Download Folder & Subfolders")) { [unowned self] in
                    onDownloadFolder(recurse: true)
                },
                .action(String(localized: "Download Folder & Subfolders To…")) { [unowned self] in
                    onDownloadFolderTo(recurse: true)
                },
                .separator
            )
        }

        folderPopupMenu.addItems(
            .action(String(localized: "File Properties")) { [unowned self] in onFileProperties(allFiles: true) },
            .separator,
            .action(String(localized: "Copy Folder Path")) { [unowned self] in onCopyFolderPath() },
            .action(String(localized: "Copy Folder URL")) { [unowned self] in onCopyFolderURL() },
            .separator,
            .submenu(String(localized: "User Actions"), userPopupMenu)
        )
        folderTreeView.popupMenu = folderPopupMenu

        // Setup file list view
        fileListView = TreeView(
            columns: [
                // Visible columns
                TreeColumn(id: "file_type", title: String(localized: "File Type"), kind: .icon, width: 30,
                           hidesHeader: true),
                TreeColumn(id: "filename", title: String(localized: "File Name"), width: 150, expandsColumn: true,
                           defaultSortOrder: .ascending, isIteratorKey: true),
                TreeColumn(id: "size", title: String(localized: "Size"), kind: .number, width: 100,
                           sortColumn: "size_data"),
                TreeColumn(id: "quality", title: String(localized: "Quality"), kind: .number, width: 150,
                           sortColumn: "bitrate_data"),
                TreeColumn(id: "length", title: String(localized: "Duration"), kind: .number, width: 100,
                           sortColumn: "length_data"),

                // Hidden data columns
                .data("size_data"),
                .data("bitrate_data"),
                .data("length_data"),
                .data("file_attributes_data")
            ],
            multiSelect: true, name: "user_browse",
            activateRow: { [unowned self] _, _, _ in onFileRowActivated() }
        )

        // Popup menu (file list view)
        filePopupMenu = FilePopupMenu { [unowned self] menu in onFilePopupMenu(menu) }

        if isLocalUser {
            filePopupMenu.addItems(
                .action(String(localized: "Upload File(s)…")) { [unowned self] in onUploadFilesTo() },
                .action(String(localized: "Upload Folder…")) { [unowned self] in onUploadFolderTo() },
                .separator
            )

            if !window.application.isolatedMode {
                filePopupMenu.addItems(
                    .action(String(localized: "Open File")) { [unowned self] in onOpenFile() },
                    .action(String(localized: "Open in File Manager")) { [unowned self] in onFileManager() }
                )
            }
        } else {
            filePopupMenu.addItems(
                .action(String(localized: "Download File(s)")) { [unowned self] in onDownloadFiles() },
                .action(String(localized: "Download File(s) To…")) { [unowned self] in onDownloadFilesTo() },
                .separator,
                .action(String(localized: "Download Folder")) { [unowned self] in onDownloadFolder() },
                .action(String(localized: "Download Folder To…")) { [unowned self] in onDownloadFolderTo() },
                .separator
            )
        }

        filePopupMenu.addItems(
            .action(String(localized: "File Properties")) { [unowned self] in onFileProperties() },
            .separator,
            .action(String(localized: "Copy File Path")) { [unowned self] in onCopyFilePath() },
            .action(String(localized: "Copy URL")) { [unowned self] in onCopyURL() },
            .separator,
            .submenu(String(localized: "User Actions"), userPopupMenu)
        )
        fileListView.popupMenu = filePopupMenu

        // Key bindings (folder list view)
        folderTreeView.accelerators = [
            Accelerator(.right) { [unowned self] in onFolderExpandAccelerator() },
            Accelerator(.return, modifiers: .shift) { [unowned self] in onFolderFocusFileTreeAccelerator() },
            Accelerator(.return, modifiers: .command) { [unowned self] in onFolderTransferToAccelerator() },
            Accelerator(.return, modifiers: [.shift, .command]) { [unowned self] in onFolderTransferAccelerator() },
            Accelerator(.return, modifiers: [.command, .option]) { [unowned self] in onFolderOpenManagerAccelerator() },
            Accelerator(.return, modifiers: .option) { [unowned self] in
                onFileProperties(allFiles: true)
                return true
            }
        ] + folderTreeView.accelerators + generalAccelerators()

        // Key bindings (file list view)
        fileListView.accelerators = [
            Accelerator(.backspace) { [unowned self] in onFocusFolderAccelerator() },
            Accelerator(.character("\\")) { [unowned self] in onFocusFolderAccelerator() },
            Accelerator(.left) { [unowned self] in onFocusFolderAccelerator() },
            Accelerator(.return, modifiers: .shift) { [unowned self] in onFileTransferMultiAccelerator() },
            Accelerator(.return, modifiers: .command) { [unowned self] in onFileTransferToAccelerator() },
            Accelerator(.return, modifiers: [.shift, .command]) { [unowned self] in onFileTransferAccelerator() },
            Accelerator(.return, modifiers: [.command, .option]) { [unowned self] in onFileOpenManagerAccelerator() },
            Accelerator(.return, modifiers: .option) { [unowned self] in onFilePropertiesAccelerator() }
        ] + fileListView.accelerators + generalAccelerators()

        // Wait for the shares list, like when the progress bar is first shown
        setIndeterminateProgress()
    }

    private func generalAccelerators() -> [Accelerator] {
        [
            Accelerator(.character("f"), modifiers: .command) { [unowned self] in onSearchAccelerator() },
            Accelerator(.function(3)) { [unowned self] in onSearchNextAccelerator() },
            Accelerator(.function(3), modifiers: .shift) { [unowned self] in onSearchPreviousAccelerator() },
            Accelerator(.character("g"), modifiers: .command) { [unowned self] in onSearchNextAccelerator() },
            Accelerator(.character("g"), modifiers: [.command, .shift]) { [unowned self] in
                onSearchPreviousAccelerator()
            },
            Accelerator(.character("\\"), modifiers: .command) { [unowned self] in
                isExpanded.toggle()
                return true
            },
            Accelerator(.function(5)) { [unowned self] in
                onRefresh()
                return true
            },
            Accelerator(.character("r"), modifiers: .command) { [unowned self] in
                onRefresh()
                return true
            },
            Accelerator(.character("s"), modifiers: .command) { [unowned self] in onSaveAccelerator() }
        ]
    }

    var tabMenuItems: [TabMenuItem] {
        [
            TabMenuItem(String(localized: "Save Shares List to Disk")) { [unowned self] in onSave() },
            TabMenuItem(String(localized: "Close All Tabs…")) { [unowned self] in userBrowses.notebook.removeAllPages() },
            TabMenuItem(String(localized: "Close Tab")) { [unowned self] in onClose() }
        ]
    }

    var content: some View {
        UserBrowseTabView(tab: self)
    }

    func clear() {
        clearModel()
        isIndeterminateProgress = false
        events.cancelScheduled(pulseTimerID)
    }

    // MARK: Folder/File Views

    func clearModel() {
        searchPosition = 0
        searchFolderPaths.removeAll()
        activeFolderPath = nil
        populatePathBar()
        selectedFiles.removeAll()
        folderTreeView.clear()
        fileListView.clear()
    }

    private func rebuildModel() {
        clearModel()

        guard let browsedUser = core.userBrowse.users[user], let numFolders = browsedUser.numFolders,
              let sharedSize = browsedUser.sharedSize else {
            return
        }

        // Generate the folder tree and select first folder
        createFolderTree(browsedUser.publicFolders)

        if !browsedUser.privateFolders.isEmpty {
            createFolderTree(browsedUser.privateFolders, isPrivate: true)
        }

        numFoldersText = humanize(numFolders)
        shareSizeText = humanSize(sharedSize)

        if isExpanded {
            folderTreeView.expandAllRows()
        } else {
            folderTreeView.expandRootRows()
        }

        selectSearchMatchFolder()
    }

    private func createFolderTree(_ folders: OrderedDictionary<String, [FileListEntry]>, isPrivate: Bool = false) {
        guard !folders.isEmpty else {
            return
        }

        for (folderPath, files) in folders.reversed() {
            var currentPath: String?
            var parent: TreeRow?

            if let query, !folderPath.lowercased().contains(query),
               !files.contains(where: { $0.name.lowercased().contains(query) }) {
                continue
            }

            for var subfolder in folderPath.components(separatedBy: "\\") {
                if let path = currentPath {
                    currentPath = path + "\\" + subfolder
                } else {
                    currentPath = subfolder
                }

                if let existingRow = folderTreeView.iterators[.string(currentPath!)] {
                    // Folder was already added to tree
                    parent = existingRow
                    continue
                }

                if subfolder.isEmpty {
                    // Most likely a root folder
                    subfolder = "\\"
                }

                if isPrivate {
                    subfolder = String(localized: "[PRIVATE]  \(subfolder)")
                }

                parent = folderTreeView.addRow([.string(subfolder), .string(currentPath!)], selectRow: false,
                                               parent: parent)
            }

            if query != nil {
                searchFolderPaths.append(folderPath)
            }
        }

        searchFolderPaths.reverse()
    }

    func browseQueuedPath() {
        guard let queuedPath, !queuedPath.isEmpty else {
            return
        }

        // Reset search to show all folders
        searchText = ""
        isSearchVisible = false

        let pathComponents = queuedPath.components(separatedBy: "\\")
        let folderPath = pathComponents.dropLast().joined(separator: "\\")
        let basename = pathComponents.last ?? ""

        guard let folderRow = folderTreeView.iterators[.string(folderPath)] else {
            return
        }

        self.queuedPath = nil

        // Scroll to the requested folder
        folderTreeView.selectRow(folderRow)

        guard let fileRow = fileListView.iterators[.string(basename)] else {
            folderTreeView.grabFocus()
            return
        }

        // Scroll to the requested file
        fileListView.selectRow(fileRow)
        fileListView.grabFocus()
    }

    func sharedFileList(_ msg: SharedFileListResponse) {
        guard isRefreshing else {
            return
        }

        let isEmpty = msg.list.isEmpty && msg.privateList.isEmpty

        localPermissionLevel = msg.permissionLevel
        rebuildModel()
        infoMessage = nil

        if isEmpty {
            infoMessage = (String(localized: "User's list of shared files is empty. Either the user is not sharing anything, or they are sharing files privately."), .info)
            isRetryVisible = false
        } else {
            browseQueuedPath()
        }

        setFinished()
    }

    func peerConnectionError() {
        guard isRefreshing else {
            return
        }

        infoMessage = (String(localized: "Unable to request shared files from user. Either the user is offline, the listening ports are closed on both sides, or there is a temporary connectivity issue."), .error)
        isRetryVisible = true
        setFinished()
    }

    func sharedFileListProgress(position: Int, total: Int) {
        guard isRefreshing else {
            return
        }

        isIndeterminateProgress = false
        events.cancelScheduled(pulseTimerID)

        if total <= 0 || position <= 0 {
            progress = 0
        } else if position < total {
            progress = Double(position) / Double(total)
        } else {
            progress = 1

            events.schedule(delay: 1) { [weak self] in
                self?.setFinishing()
            }
        }
    }

    func setIndeterminateProgress() {
        guard !isIndeterminateProgress else {
            return
        }

        isIndeterminateProgress = true
        isRefreshing = true
        progress = nil

        infoMessage = nil
        isRefreshEnabled = false
        isSaveEnabled = false

        if core.users.loginStatus == .offline && !isLocalUser {
            peerConnectionError()
        }
    }

    private func setFinishing() {
        if !isRefreshEnabled {
            setIndeterminateProgress()
        }
    }

    private func setFinished() {
        isIndeterminateProgress = false
        isRefreshing = false
        userBrowses.notebook.requestTabChanged(self)
        progress = 1
        isRefreshEnabled = true
        isSaveEnabled = !folderTreeView.isEmpty
    }

    /// Whether the progress bar is shown
    var isProgressVisible: Bool {
        isRefreshing
    }

    private func populatePathBar(_ folderPath: String = "") {
        pathComponents = folderPath.isEmpty ? [] : folderPath.components(separatedBy: "\\")
    }

    private func setActiveFolder(_ folderPath: String?) {
        guard activeFolderPath != folderPath else {
            return
        }

        guard let browsedUser = core.userBrowse.users[user] else {
            // Redundant row selection event when closing tab, prevent crash
            return
        }

        populatePathBar(folderPath ?? "")
        fileListView.clear()
        activeFolderPath = folderPath

        guard let folderPath else {
            return
        }

        var files = browsedUser.publicFolders[folderPath] ?? []

        if files.isEmpty {
            files = browsedUser.privateFolders[folderPath] ?? []

            if files.isEmpty {
                return
            }
        }

        let fileSizeUnit = FileSizeUnit(rawValue: config.ui.fileSizeUnit) ?? .automatic

        // Temporarily disable sorting for increased performance
        fileListView.freeze()

        for file in files {
            let quality = FileListMessage.parseAudioQualityLength(fileSize: file.size, attributes: file.attributes)

            fileListView.addRow([
                .string(Theme.fileTypeIconName(file.name)),
                .string(file.name),
                .string(humanSize(file.size, unit: fileSizeUnit)),
                .string(quality.humanQuality),
                .string(quality.humanLength),
                .int(file.size),
                .int(quality.bitrate),
                .int(quality.length),
                .object(Box(file.attributes))
            ], selectRow: false)
        }

        fileListView.unfreeze()
        selectSearchMatchFiles()
    }

    private func selectFiles() {
        selectedFiles.removeAll()

        for row in fileListView.selectedRows {
            selectedFiles[fileListView.rowValue(row, "filename").string] = fileListView.rowValue(row, "size_data").int
        }
    }

    private var selectedFolderPath: String? {
        guard let row = folderTreeView.selectedRows.first else {
            return nil
        }
        return folderTreeView.rowValue(row, "folder_path_data").string + "\\"
    }

    private var selectedFilePath: String {
        (selectedFolderPath ?? "") + (selectedFiles.first?.key ?? "")
    }

    // MARK: Search

    private func selectSearchMatchFolder() {
        var row: TreeRow?

        if !searchFolderPaths.isEmpty {
            row = folderTreeView.iterators[.string(searchFolderPaths[searchPosition])]
        }

        folderTreeView.selectRow(row)
    }

    private func selectSearchMatchFiles() {
        guard let query else {
            return
        }

        var resultRows: [TreeRow] = []
        var hasFoundFirstMatch = false

        for (key, row) in fileListView.iterators where key.string.lowercased().contains(query) {
            resultRows.append(row)
        }

        fileListView.unselectAllRows()

        for row in resultRows {
            // Select each matching file in folder
            fileListView.selectRow(row, shouldScroll: !hasFoundFirstMatch)
            hasFoundFirstMatch = true
        }
    }

    @discardableResult
    func findSearchMatches(reverse: Bool = false) -> Bool {
        let newQuery = searchText.isEmpty ? nil : searchText.lowercased()

        if query != newQuery {
            // New search query, rebuild result list
            let activeFolderPath = self.activeFolderPath

            query = newQuery
            rebuildModel()

            if searchFolderPaths.isEmpty {
                if let activeFolderPath, let row = folderTreeView.iterators[.string(activeFolderPath)] {
                    folderTreeView.selectRow(row)
                }
                return false
            }
        } else if query != nil {
            // Increment/decrement search position
            searchPosition += reverse ? -1 : 1
        } else {
            return false
        }

        if searchPosition < 0 {
            searchPosition = searchFolderPaths.count - 1
        } else if searchPosition >= searchFolderPaths.count {
            searchPosition = 0
        }

        // Set active folder
        selectSearchMatchFolder()

        // Get matching files in the current folder
        selectSearchMatchFiles()
        return true
    }

    // MARK: Callbacks (Folder List View)

    private func onSelectFolder(_ treeView: TreeView, _ row: TreeRow?) {
        guard let row else {
            return
        }

        if treeView.numSelectedRows > 1 {
            // Multiple folders selected. Avoid any confusion by clearing the path bar and file list view.
            setActiveFolder(nil)
        } else {
            setActiveFolder(treeView.rowValue(row, "folder_path_data").string)
        }
    }

    private func onDownloadFolder(downloadFolderPath: String? = nil, recurse: Bool = false) {
        var previousFolderPath: String?

        for row in folderTreeView.selectedRows {
            let folderPath = folderTreeView.rowValue(row, "folder_path_data").string

            if recurse, let previousFolderPath, folderPath.contains(previousFolderPath) {
                // Already recursing, avoid redundant request for subfolder
                continue
            }

            core.userBrowse.downloadFolder(username: user, requestedFolderPath: folderPath,
                                           downloadFolderPath: downloadFolderPath, recurse: recurse)
            previousFolderPath = folderPath
        }
    }

    private func onDownloadFolderTo(recurse: Bool = false) {
        let title = recurse
            ? String(localized: "Select Destination for Downloading Multiple Folders")
            : String(localized: "Select Destination Folder")

        FileChooser.chooseFolders(title: title, initialFolder: core.downloads.defaultDownloadFolder()) {
            [weak self] folderPaths in
            self?.onDownloadFolder(downloadFolderPath: folderPaths.first, recurse: recurse)
        }
    }

    private func onUploadFolderTo(recurse: Bool = false) {
        let title = recurse
            ? String(localized: "Upload Folder (with Subfolders) To User")
            : String(localized: "Upload Folder To User")

        EntryDialog(
            title: title,
            message: String(localized: "Enter the name of the user you want to upload to:"),
            actionButtonLabel: String(localized: "Upload"),
            droplist: core.buddies.users.keys.sorted()
        ) { [weak self] dialog, _ in
            self?.onUploadFolderToResponse((dialog as? EntryDialog)?.entryValue ?? "", recurse: recurse)
        }.present()
    }

    private func onUploadFolderToResponse(_ uploadUser: String, recurse: Bool) {
        guard !uploadUser.isEmpty, let localBrowsedUser = core.userBrowse.users[user] else {
            return
        }

        var previousFolderPath: String?
        var hasSentUploadNotification = false

        for row in folderTreeView.selectedRows {
            let folderPath = folderTreeView.rowValue(row, "folder_path_data").string

            if recurse, let previousFolderPath, folderPath.contains(previousFolderPath) {
                // Already recursing, avoid redundant request for subfolder
                continue
            }

            if !hasSentUploadNotification {
                core.userBrowse.sendUploadAttemptNotification(uploadUser)
                hasSentUploadNotification = true
            }

            core.userBrowse.uploadFolder(username: uploadUser, requestedFolderPath: folderPath,
                                         localBrowsedUser: localBrowsedUser, recurse: recurse)
            previousFolderPath = folderPath
        }
    }

    private func onCopyFolderPath() {
        Clipboard.copyText(selectedFolderPath ?? "")
    }

    private func onCopyFolderURL() {
        Clipboard.copyText(UserBrowse.soulseekURL(username: user, path: selectedFolderPath ?? ""))
    }

    // MARK: Key Bindings (Folder List View)

    private func onFolderRowActivated(_ treeView: TreeView, _ row: TreeRow) {
        // Keyboard accessibility support for <Return> key behavior
        let isExpandable = treeView.isRowExpanded(row) ? treeView.collapseRow(row) : treeView.expandRow(row)

        if !isExpandable && !fileListView.isEmpty {
            // This is the deepest level, so move focus over to Files if there are any
            fileListView.grabFocus()
        }
    }

    /// Right: expand row.
    private func onFolderExpandAccelerator() -> Bool {
        guard let row = folderTreeView.focusedRow else {
            return false
        }

        if row.hasChildren && !folderTreeView.isRowExpanded(row) {
            // Let the list view expand the row
            return false
        }

        if !fileListView.isEmpty {
            fileListView.grabFocus()
        }
        return true
    }

    /// Shift+Return: focus selection over file list.
    private func onFolderFocusFileTreeAccelerator() -> Bool {
        if !fileListView.isEmpty {
            fileListView.grabFocus()
            return true
        }

        guard let row = folderTreeView.focusedRow else {
            return false
        }

        folderTreeView.expandRow(row)
        return true
    }

    /// Command+Return: Upload Folder To, Download Folder Into.
    private func onFolderTransferToAccelerator() -> Bool {
        if isLocalUser {
            onUploadFolderTo(recurse: true)
        } else {
            onDownloadFolderTo(recurse: true)
        }
        return true
    }

    /// Shift+Command+Return: Upload Folder Recursive To, Download Folder (without prompt).
    private func onFolderTransferAccelerator() -> Bool {
        if isLocalUser {
            onUploadFolderTo(recurse: true)
        } else {
            onDownloadFolder(recurse: true)
        }
        return true
    }

    /// Command+Option+Return: Open folder in file manager.
    private func onFolderOpenManagerAccelerator() -> Bool {
        guard isLocalUser else {
            return false
        }

        onFileManager()
        return true
    }

    // MARK: Callbacks (File List View)

    private func onFilePopupMenu(_ menu: PopupMenu) {
        selectFiles()
        (menu as? FilePopupMenu)?.setNumSelectedFiles(selectedFiles.count)
        userPopupMenu.toggleUserItems()
    }

    private func onDownloadFiles(downloadFolderPath: String? = nil) {
        guard let folderPath = activeFolderPath, let browsedUser = core.userBrowse.users[user] else {
            return
        }

        var files = browsedUser.publicFolders[folderPath] ?? []

        if files.isEmpty {
            files = browsedUser.privateFolders[folderPath] ?? []

            if files.isEmpty {
                return
            }
        }

        // Find the wanted files
        for file in files where selectedFiles[file.name] != nil {
            core.userBrowse.downloadFile(username: user, folderPath: folderPath, file: file,
                                         downloadFolderPath: downloadFolderPath)
        }
    }

    private func onDownloadFilesTo() {
        FileChooser.chooseFolders(title: String(localized: "Select Destination Folder for Files"),
                                  initialFolder: core.downloads.defaultDownloadFolder()) { [weak self] folderPaths in
            self?.onDownloadFiles(downloadFolderPath: folderPaths.first)
        }
    }

    private func onUploadFilesTo() {
        EntryDialog(
            title: String(localized: "Upload File(s) To User"),
            message: String(localized: "Enter the name of the user you want to upload to:"),
            actionButtonLabel: String(localized: "Upload"),
            droplist: core.buddies.users.keys.sorted()
        ) { [weak self] dialog, _ in
            guard let self, let uploadUser = (dialog as? EntryDialog)?.entryValue, !uploadUser.isEmpty,
                  let folderPath = activeFolderPath else {
                return
            }

            core.userBrowse.sendUploadAttemptNotification(uploadUser)

            for (basename, size) in selectedFiles {
                core.userBrowse.uploadFile(username: uploadUser, folderPath: folderPath,
                                           file: FileListEntry(name: basename, size: size))
            }
        }.present()
    }

    private func onOpenFile() {
        guard let activeFolderPath else {
            return
        }

        let folderPath = core.shares.virtualToReal(activeFolderPath)

        for basename in selectedFiles.keys {
            _ = openFilePath((folderPath as NSString).appendingPathComponent(basename))
        }
    }

    private func onFileManager() {
        guard let row = folderTreeView.selectedRows.first else {
            return
        }

        let folderPath = folderTreeView.rowValue(row, "folder_path_data").string
        _ = openFolderPath(core.shares.virtualToReal(folderPath))
    }

    private func onFileProperties(allFiles: Bool = false) {
        var data: [FilePropertiesItem] = []
        var selectedSize = 0
        var selectedLength = 0
        let speed = core.users.watched[user]?.uploadSpeed ?? 0

        if allFiles {
            var previousFolderPath: String?

            guard let browsedUser = core.userBrowse.users[user] else {
                return
            }

            for row in folderTreeView.selectedRows {
                let selectedFolderPath = folderTreeView.rowValue(row, "folder_path_data").string

                if let previousFolderPath, selectedFolderPath.contains(previousFolderPath) {
                    // Already recursing, avoid duplicates
                    continue
                }

                for (folderPath, files) in core.userBrowse.matchingFolders(selectedFolderPath, browsedUser: browsedUser,
                                                                           recurse: true) {
                    for file in files {
                        let length = FileListMessage.parseFileAttributes(file.attributes).length

                        selectedSize += file.size

                        if let length {
                            selectedLength += length
                        }

                        data.append(FilePropertiesItem(
                            user: user, filePath: [folderPath, file.name].joined(separator: "\\"),
                            basename: file.name, virtualFolderPath: folderPath, speed: speed, size: file.size,
                            fileAttributes: file.attributes
                        ))
                    }
                }

                previousFolderPath = selectedFolderPath
            }
        } else {
            let selectedFolderPath = activeFolderPath ?? ""

            for row in fileListView.selectedRows {
                let basename = fileListView.rowValue(row, "filename").string
                let fileSize = fileListView.rowValue(row, "size_data").int

                selectedSize += fileSize
                selectedLength += fileListView.rowValue(row, "length_data").int

                data.append(FilePropertiesItem(
                    user: user, filePath: [selectedFolderPath, basename].joined(separator: "\\"),
                    basename: basename, virtualFolderPath: selectedFolderPath, speed: speed, size: fileSize,
                    fileAttributes: fileListView.rowValue(row, "file_attributes_data")
                        .object(as: Box<[Int: Int]>.self)?.value,
                    countryCode: core.users.countries[user]
                ))
            }
        }

        guard !data.isEmpty else {
            return
        }

        let fileProperties = AppDelegate.shared.fileProperties
        fileProperties.updateProperties(data, totalSize: selectedSize, totalLength: selectedLength)
        fileProperties.present()
    }

    private func onCopyFilePath() {
        Clipboard.copyText(selectedFilePath)
    }

    private func onCopyURL() {
        Clipboard.copyText(UserBrowse.soulseekURL(username: user, path: selectedFilePath))
    }

    // MARK: Key Bindings (File List View)

    private func onFileRowActivated() {
        selectFiles()

        if isLocalUser {
            onOpenFile()
        } else {
            onDownloadFiles()
        }
    }

    /// Backspace, backslash, Left: focus selection back parent folder.
    private func onFocusFolderAccelerator() -> Bool {
        folderTreeView.grabFocus()
        return true
    }

    /// Command+Return: Upload File(s) To, Download File(s) Into.
    private func onFileTransferToAccelerator() -> Bool {
        if fileListView.isEmpty {
            // Avoid navigation trap
            folderTreeView.grabFocus()
            return true
        }

        selectFiles()

        if isLocalUser {
            if fileListView.isSelectionEmpty {
                onUploadFolderTo()
            } else {
                onUploadFilesTo()
            }
            return true
        }

        if fileListView.isSelectionEmpty {
            onDownloadFolderTo()
        } else {
            onDownloadFilesTo()
        }
        return true
    }

    /// Shift+Command+Return: Upload File(s) To, Download File(s) (without prompt).
    private func onFileTransferAccelerator() -> Bool {
        if fileListView.isEmpty {
            // Avoid navigation trap
            folderTreeView.grabFocus()
            return true
        }

        selectFiles()

        if isLocalUser {
            if fileListView.isSelectionEmpty {
                onUploadFolderTo()
            } else {
                onUploadFilesTo()
            }
            return true
        }

        if fileListView.isSelectionEmpty {
            // Without prompt, no selection means all files
            onDownloadFolder()
        } else {
            onDownloadFiles()
        }
        return true
    }

    /// Shift+Return: Open File, Download Files (multiple).
    private func onFileTransferMultiAccelerator() -> Bool {
        if fileListView.isEmpty {
            // Avoid navigation trap
            folderTreeView.grabFocus()
            return true
        }

        // Support multi-select with Up/Down keys
        selectFiles()

        if isLocalUser {
            onOpenFile()
        } else {
            onDownloadFiles()
        }
        return true
    }

    /// Command+Option+Return: Open in File Manager.
    private func onFileOpenManagerAccelerator() -> Bool {
        if isLocalUser {
            onFileManager()
        } else {
            _ = onFilePropertiesAccelerator()
        }
        return true
    }

    /// Option+Return: show file properties dialog.
    private func onFilePropertiesAccelerator() -> Bool {
        if fileListView.isEmpty {
            // Avoid navigation trap
            folderTreeView.grabFocus()
        }

        onFileProperties()
        return true
    }

    // MARK: Callbacks (General)

    func onPathBarClicked(_ index: Int) {
        let folderPath = pathComponents.prefix(index + 1).joined(separator: "\\")

        if let row = folderTreeView.iterators[.string(folderPath)] {
            folderTreeView.selectRow(row)
            folderTreeView.grabFocus()
        }
    }

    private func onExpand() {
        if isExpanded {
            folderTreeView.expandAllRows()
        } else {
            folderTreeView.collapseAllRows()
        }

        config.userBrowse.expandFolders = isExpanded
    }

    private func onShowSearch() {
        if isSearchVisible {
            searchFocusRequest += 1
        } else if !fileListView.isSelectionEmpty {
            fileListView.grabFocus()
        } else {
            folderTreeView.grabFocus()
        }
    }

    func onSearchEntryChanged() {
        if searchText.isEmpty {
            findSearchMatches()
        }
    }

    func onSave() {
        core.userBrowse.saveSharesListToDisk(user)
    }

    func onRefresh() {
        guard !isRefreshing else {
            return
        }

        // Remember selection after refresh
        selectFiles()

        let filePath = selectedFilePath

        if isLocalUser {
            core.userBrowse.browseLocalShares(path: filePath, permissionLevel: localPermissionLevel, newRequest: true)
        } else {
            core.userBrowse.browseUser(user, path: filePath, newRequest: true)
        }
    }

    func onFocus() -> Bool {
        if fileListView.isSelectionEmpty {
            folderTreeView.grabFocus()
        } else {
            fileListView.grabFocus()
        }
        return true
    }

    func onClose() {
        core.userBrowse.removeUser(user)
    }

    // MARK: Key Bindings (General)

    /// Command+S: save shares list.
    private func onSaveAccelerator() -> Bool {
        guard isSaveEnabled else {
            return false
        }

        onSave()
        return true
    }

    /// Command+F: find.
    private func onSearchAccelerator() -> Bool {
        isSearchVisible = true
        searchFocusRequest += 1
        return true
    }

    /// Command+G or F3: find next.
    func onSearchNextAccelerator() -> Bool {
        if !findSearchMatches() {
            searchFocusRequest += 1
        }
        return true
    }

    /// Shift+Command+G or Shift+F3: find previous.
    func onSearchPreviousAccelerator() -> Bool {
        if !findSearchMatches(reverse: true) {
            searchFocusRequest += 1
        }
        return true
    }
}
