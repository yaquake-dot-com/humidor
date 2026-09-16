// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import NicotineCore
import Observation
import SwiftUI

/// User profiles page, containing a tab for each user.
@MainActor
@Observable
final class UserInfosPage: TabbedPage {

    @ObservationIgnored let window: MainWindow
    let notebook: Notebook<UserInfoTab>
    @ObservationIgnored private(set) var pages: [String: UserInfoTab] = [:]

    var usernameText = ""
    private(set) var usernameFocusRequest = 0

    init(window: MainWindow) {
        self.window = window
        self.notebook = Notebook(window: window, parentPage: .userinfo)

        notebook.removeAllPagesCallback = { core.userInfo.removeAllUsers() }

        events.connect(.addBuddy) { [unowned self] in pages[$0.username]?.updateBuddyButtonState() }
        events.connect(.banUser) { [unowned self] in pages[$0]?.updateBanButtonState() }
        events.connect(.checkPrivileges) { [unowned self] _ in
            for page in pages.values {
                page.updatePrivilegesButtonState()
            }
        }
        events.connect(.ignoreUser) { [unowned self] in pages[$0]?.updateIgnoreButtonState() }
        events.connect(.peerConnectionClosed) { [unowned self] in peerConnectionError($0) }
        events.connect(.peerConnectionError) { [unowned self] in peerConnectionError($0) }
        events.connect(.removeBuddy) { [unowned self] in pages[$0]?.updateBuddyButtonState() }
        events.connect(.serverDisconnect) { [unowned self] _ in serverDisconnect() }
        events.connect(.unbanUser) { [unowned self] in pages[$0]?.updateBanButtonState() }
        events.connect(.unignoreUser) { [unowned self] in pages[$0]?.updateIgnoreButtonState() }
        events.connect(.userCountry) { [unowned self] in pages[$0.username]?.userCountry($0.countryCode) }
        events.connect(.userInfoProgress) { [unowned self] in
            pages[$0.username]?.userInfoProgress(position: $0.bufferLength, total: $0.messageSizeTotal)
        }
        events.connect(.userInfoRemoveUser) { [unowned self] in removeUser($0) }
        events.connect(.userInfoResponse) { [unowned self] msg in
            if let username = msg.username {
                pages[username]?.userInfoResponse(msg)
            }
        }
        events.connect(.userInfoShowUser) { [unowned self] in showUser($0) }
        events.connect(.userInterests) { [unowned self] in pages[$0.user]?.userInterests($0) }
        events.connect(.userStats) { [unowned self] in pages[$0.user]?.userStats($0) }
        events.connectMessage(.userStatus) { [unowned self] msg in
            if let page = pages[msg.user] {
                notebook.setUserStatus(page, user: msg.user, status: UserStatus(rawValue: msg.status) ?? .offline)
            }
        }
    }

    func onFocus() {
        guard window.currentPage == .userinfo, notebook.pages.isEmpty else {
            return
        }
        usernameFocusRequest += 1
    }

    func onShowUserProfile() {
        let username = usernameText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !username.isEmpty else {
            return
        }

        usernameText = ""
        core.userInfo.showUser(username)
    }

    private func showUser(_ event: UserInfoShowUser) {
        let user = event.username
        var page = pages[user]

        if page == nil {
            let newPage = UserInfoTab(userInfos: self, user: user)
            pages[user] = newPage
            notebook.appendPage(newPage, text: user, closeCallback: { [weak newPage] in newPage?.onClose() },
                                user: user)
            page = newPage

        } else if event.refresh {
            page?.setIndeterminateProgress()
        }

        if event.switchPage, let page {
            notebook.setCurrentPage(page)
            window.changeMainPage(.userinfo)
        }
    }

    private func removeUser(_ user: String) {
        guard let page = pages[user] else {
            return
        }

        page.clear()
        notebook.removePage(page) {
            core.userInfo.showUser(user)
        }
        pages.removeValue(forKey: user)
    }

    private func peerConnectionError(_ event: PeerConnectionEvent) {
        if event.connType == ConnectionType.peer.rawValue {
            pages[event.username]?.peerConnectionError()
        }
    }

    private func serverDisconnect() {
        for (user, page) in pages {
            notebook.setUserStatus(page, user: user, status: .offline)
        }
    }
}

// MARK: - User Info Tab

/// Profile of a single user.
@MainActor
@Observable
final class UserInfoTab: NotebookPage {

    @ObservationIgnored unowned let userInfos: UserInfosPage
    @ObservationIgnored let window: MainWindow
    let user: String

    @ObservationIgnored private var isIndeterminateProgress = false
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private(set) var descriptionView: TextView!
    @ObservationIgnored private(set) var likesListView: TreeView!
    @ObservationIgnored private(set) var dislikesListView: TreeView!
    @ObservationIgnored private var userPopupMenu: UserPopupMenu!
    @ObservationIgnored private(set) var picturePopupMenu: PopupMenu!
    @ObservationIgnored private var pictureData: Data?

    // Widget state
    private(set) var picture: NSImage?
    private(set) var isPictureVisible = false
    private(set) var sharedFilesText = String(localized: "Unknown")
    private(set) var sharedFoldersText = String(localized: "Unknown")
    private(set) var uploadSpeedText = String(localized: "Unknown")
    private(set) var freeUploadSlotsText = String(localized: "Unknown")
    private(set) var uploadSlotsText = String(localized: "Unknown")
    private(set) var queuedUploadsText = String(localized: "Unknown")
    private(set) var isQueuedUploadsVisible = true
    private(set) var countryName: String?
    private(set) var countryCode: String?
    private(set) var progress: Double?
    private(set) var isProgressVisible = false
    private(set) var errorMessage: String?
    private(set) var isRefreshEnabled = true
    private(set) var isLocalUser = false
    private(set) var buddyButtonLabel = ""
    private(set) var banButtonLabel = ""
    private(set) var ignoreButtonLabel = ""
    private(set) var isGiftPrivilegesEnabled = false

    init(userInfos: UserInfosPage, user: String) {
        self.userInfos = userInfos
        self.window = userInfos.window
        self.user = user

        descriptionView = TextView(isEditable: false, verticalMargin: 5)

        let interests = window.interests!

        // Set up likes list
        likesListView = TreeView(
            columns: [TreeColumn(id: "likes", title: String(localized: "Likes"), defaultSortOrder: .ascending)],
            activateRow: { [unowned self] _, _, _ in
                interests.showItemRecommendations(likesListView, columnID: "likes")
            }
        )

        // Set up dislikes list
        dislikesListView = TreeView(
            columns: [TreeColumn(id: "dislikes", title: String(localized: "Dislikes"), defaultSortOrder: .ascending)],
            activateRow: { [unowned self] _, _, _ in
                interests.showItemRecommendations(dislikesListView, columnID: "dislikes")
            }
        )

        // Popup menus
        userPopupMenu = UserPopupMenu(username: user, tabName: .userInfo) { [unowned self] _ in
            userPopupMenu.toggleUserItems()
        }

        let likesPopupMenu = PopupMenu { [unowned self] menu in
            interests.toggleMenuItems(menu, listView: likesListView, columnID: "likes")
        }
        likesPopupMenu.addItems(interests.interestItems(likesListView, columnID: "likes"))
        likesListView.popupMenu = likesPopupMenu

        let dislikesPopupMenu = PopupMenu { [unowned self] menu in
            interests.toggleMenuItems(menu, listView: dislikesListView, columnID: "dislikes")
        }
        dislikesPopupMenu.addItems(interests.interestItems(dislikesListView, columnID: "dislikes"))
        dislikesListView.popupMenu = dislikesPopupMenu

        picturePopupMenu = PopupMenu()
        picturePopupMenu.addItems(
            .action(String(localized: "Copy Picture")) { [unowned self] in onCopyPicture() },
            .action(String(localized: "Save Picture")) { [unowned self] in onSavePicture() },
            .separator,
            .action(String(localized: "Remove")) { [unowned self] in isPictureVisible = false }
        )

        removePicture()
        populateStats()
        updateButtonStates()

        // Wait for the profile, like when the progress bar is first shown
        setIndeterminateProgress()
    }

    var tabMenuItems: [TabMenuItem] {
        [
            TabMenuItem(String(localized: "Close All Tabs…")) { [unowned self] in userInfos.notebook.removeAllPages() },
            TabMenuItem(String(localized: "Close Tab")) { [unowned self] in onClose() }
        ]
    }

    var content: some View {
        UserInfoTabView(tab: self)
    }

    func clear() {
        descriptionView.clear()
        likesListView.clear()
        dislikesListView.clear()
        removePicture()
    }

    // MARK: General

    private func populateStats() {
        let stats = core.users.watched[user]
        let speed = stats?.uploadSpeed ?? 0

        if speed > 0 {
            uploadSpeedText = humanSpeed(speed)
        }

        if let files = stats?.files {
            sharedFilesText = humanize(files)
        }

        if let folders = stats?.folders {
            sharedFoldersText = humanize(folders)
        }

        if let countryCode = core.users.countries[user] {
            userCountry(countryCode)
        }
    }

    private func removePicture() {
        pictureData = nil
        picture = nil
        isPictureVisible = false
    }

    private func loadPicture(_ data: Data?) {
        guard let data, !data.isEmpty else {
            removePicture()
            return
        }

        guard let image = NSImage(data: data) else {
            let error = "Invalid image data"
            log.add(String(localized: "Failed to load picture for user \(user): \(error)"))
            removePicture()
            return
        }

        pictureData = data
        picture = image
        isPictureVisible = true
    }

    func peerConnectionError() {
        guard isRefreshing else {
            return
        }

        errorMessage = String(localized: "Unable to request information from user. Either you both have a closed listening port, the user is offline, or there's a temporary connectivity issue.")
        setFinished()
    }

    func userInfoProgress(position: Int, total: Int) {
        guard isRefreshing else {
            return
        }

        isIndeterminateProgress = false

        if total <= 0 || position <= 0 {
            progress = 0
        } else if position < total {
            progress = Double(position) / Double(total)
        } else {
            progress = 1
        }
    }

    func setIndeterminateProgress() {
        guard !isIndeterminateProgress else {
            return
        }

        isIndeterminateProgress = true
        isRefreshing = true
        progress = nil
        isProgressVisible = true
        errorMessage = nil
        isRefreshEnabled = false

        if core.users.loginStatus == .offline && user != config.server.login {
            peerConnectionError()
        }
    }

    private func setFinished() {
        isIndeterminateProgress = false
        isRefreshing = false
        userInfos.notebook.requestTabChanged(self)
        progress = 1
        isProgressVisible = false
        isRefreshEnabled = true
    }

    // MARK: Button States

    private func updateLocalButtonsState() {
        let localUsername = core.users.loginUsername ?? config.server.login
        isLocalUser = (user == localUsername)
    }

    func updateBuddyButtonState() {
        buddyButtonLabel = core.buddies.users[user] != nil
            ? String(localized: "Remove Buddy") : String(localized: "Add Buddy")
    }

    func updateBanButtonState() {
        banButtonLabel = core.networkFilter.isUserBanned(user)
            ? String(localized: "Unban User") : String(localized: "Ban User")
    }

    func updateIgnoreButtonState() {
        ignoreButtonLabel = core.networkFilter.isUserIgnored(user)
            ? String(localized: "Unignore User") : String(localized: "Ignore User")
    }

    func updatePrivilegesButtonState() {
        isGiftPrivilegesEnabled = (core.users.privilegesLeft ?? 0) > 0
    }

    private func updateButtonStates() {
        updateLocalButtonsState()
        updateBuddyButtonState()
        updateBanButtonState()
        updateIgnoreButtonState()
        updatePrivilegesButtonState()
    }

    // MARK: Network Messages

    func userInfoResponse(_ msg: UserInfoResponse) {
        guard isRefreshing else {
            return
        }

        descriptionView.clear()
        descriptionView.appendLine(msg.userDescription)

        freeUploadSlotsText = msg.slotsAvailable ? String(localized: "Yes") : String(localized: "No")
        uploadSlotsText = humanize(msg.totalUploads)
        queuedUploadsText = humanize(msg.queueSize)
        isQueuedUploadsVisible = msg.queueSize > 0

        loadPicture(msg.picture)

        errorMessage = nil
        setFinished()
    }

    func userStats(_ msg: GetUserStats) {
        let speed = msg.avgSpeed

        uploadSpeedText = speed > 0 ? humanSpeed(speed) : String(localized: "Unknown")
        sharedFilesText = humanize(msg.files)
        sharedFoldersText = humanize(msg.dirs)
    }

    func userCountry(_ countryCode: String) {
        guard !countryCode.isEmpty else {
            return
        }

        self.countryCode = countryCode
        countryName = Countries.names[countryCode] ?? String(localized: "Unknown")
    }

    func userInterests(_ msg: UserInterests) {
        likesListView.clear()
        likesListView.freeze()
        dislikesListView.clear()
        dislikesListView.freeze()

        for like in msg.likes {
            likesListView.addRow([.string(like)], selectRow: false)
        }

        for hate in msg.hates {
            dislikesListView.addRow([.string(hate)], selectRow: false)
        }

        likesListView.unfreeze()
        dislikesListView.unfreeze()
    }

    // MARK: Callbacks

    func onEditProfile() {
        window.application.onPreferences(pageID: "user-profile")
    }

    func onEditInterests() {
        window.changeMainPage(.interests)
    }

    func onSendMessage() {
        core.privateChat.showUser(user)
    }

    func onShowIPAddress() {
        core.users.requestIPAddress(user, notify: true)
    }

    func onBrowseUser() {
        core.userBrowse.browseUser(user)
    }

    func onAddRemoveBuddy() {
        if core.buddies.users[user] != nil {
            core.buddies.removeBuddy(user)
            return
        }
        core.buddies.addBuddy(user)
    }

    func onBanUnbanUser() {
        if core.networkFilter.isUserBanned(user) {
            core.networkFilter.unbanUser(user)
            return
        }
        core.networkFilter.banUser(user)
    }

    func onIgnoreUnignoreUser() {
        if core.networkFilter.isUserIgnored(user) {
            core.networkFilter.unignoreUser(user)
            return
        }
        core.networkFilter.ignoreUser(user)
    }

    func onGivePrivileges(error: String? = nil) {
        core.users.requestCheckPrivileges()

        let days = core.users.privilegesLeft.map { String($0 / 60 / 60 / 24) } ?? String(localized: "Unknown")
        var message = String(localized: "Gift days of your Soulseek privileges to user \(user) (\(String(localized: "\(days) days left"))):")

        if let error {
            message += "\n\n" + error
        }

        EntryDialog(
            title: String(localized: "Gift Privileges"),
            message: message,
            actionButtonLabel: String(localized: "Give Privileges")
        ) { [weak self] dialog, _ in
            guard let self, let text = (dialog as? EntryDialog)?.entryValue, !text.isEmpty else {
                return
            }

            guard let days = Int(text) else {
                onGivePrivileges(error: String(localized: "Please enter number of days."))
                return
            }

            core.users.requestGivePrivileges(user, days: days)
        }.present()
    }

    private func onCopyPicture() {
        guard let picture else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([picture])
    }

    private func onSavePicture() {
        guard let picture, let tiffData = picture.tiffRepresentation,
              let pngData = NSBitmapImageRep(data: tiffData)?.representation(using: .png, properties: [:]) else {
            return
        }

        let currentDateTime = formatTimestamp("%Y-%m-%d_%H-%M-%S")

        FileChooser.saveFile(initialFolder: core.downloads.defaultDownloadFolder(),
                             initialFile: "\(user)_\(currentDateTime).png") { filePaths in
            if let filePath = filePaths.first {
                UserInfo.saveUserPicture(filePath, pictureData: pngData)
            }
        }
    }

    func onRefresh() {
        core.userInfo.showUser(user, refresh: true)
    }

    func onFocus() -> Bool {
        true
    }

    func onClose() {
        core.userInfo.removeUser(user)
    }
}

// MARK: - Views

/// User profiles page.
struct UserInfosView: View {

    @Bindable var page: UserInfosPage

    private var hasTabs: Bool { !page.notebook.pages.isEmpty }

    private var entryBar: some View {
        HStack(spacing: 6) {
            ToolbarTextField(placeholder: String(localized: "Username…"), text: $page.usernameText,
                             suggestions: page.window.buddyUsernames, focusRequest: page.usernameFocusRequest) {
                page.onShowUserProfile()
            }

            Button {
                page.onShowUserProfile()
            } label: {
                Image(systemName: "person.crop.circle.badge.questionmark")
            }
            .help(String(localized: "Show User Profile"))
        }
    }

    var body: some View {
        Group {
            if hasTabs {
                NotebookView(notebook: page.notebook)
            } else {
                PageStart(
                    systemImage: "person.crop.circle",
                    title: String(localized: "User Profiles"),
                    description: String(localized: "Enter the name of a user to view their user description, information and personal picture"),
                    recentTitle: String(localized: "Buddies"),
                    recentItems: page.window.buddyUsernames,
                    onSelectItem: { username in
                        page.usernameText = username
                        page.onShowUserProfile()
                    }
                ) {
                    entryBar
                }
            }
        }
        .toolbar {
            if hasTabs {
                ToolbarItem(placement: .navigation) {
                    entryBar
                        .frame(minWidth: 220, idealWidth: 300, maxWidth: 400)
                }
            }

            ToolbarItemGroup {
                Button {
                    Application.shared.onPersonalProfile()
                } label: {
                    Label(String(localized: "Personal Profile"), systemImage: "person.crop.circle")
                        .labelStyle(.titleAndIcon)
                }

                Button {
                    Application.shared.onConfigureAccount()
                } label: {
                    Label(String(localized: "Configure Account"), systemImage: "gearshape")
                }
                .help(String(localized: "Configure Account"))
            }
        }
    }
}

/// Profile of a single user.
struct UserInfoTabView: View {

    @Bindable var tab: UserInfoTab

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = tab.errorMessage {
                InfoBar(message: errorMessage, messageType: .error, buttonLabel: String(localized: "Retry")) {
                    tab.onRefresh()
                }
            }

            HSplitView {
                userInfo
                    .frame(minWidth: 260, idealWidth: 320)

                interests
                    .frame(minWidth: 200, idealWidth: 250)

                if tab.isPictureVisible, let picture = tab.picture {
                    Image(nsImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(minWidth: 150, maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(PictureMenuView(menu: tab.picturePopupMenu))
                }
            }

            Divider()
            actionBar
        }
    }

    private var userInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(tab.user)
                    .font(.title2.bold())
                    .lineLimit(1)
                    .help(tab.user)

                if let countryName = tab.countryName, let countryCode = tab.countryCode {
                    Button {
                        tab.onShowIPAddress()
                    } label: {
                        Text("\(Theme.flagEmoji(countryCode)) \(countryName)")
                    }
                    .buttonStyle(.borderless)
                    .help("\(countryName) (\(countryCode))")
                }

                Spacer()

                if tab.isLocalUser {
                    Button {
                        tab.onEditProfile()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Edit Profile"))
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                statRow(String(localized: "Shared Files"), tab.sharedFilesText)
                statRow(String(localized: "Shared Folders"), tab.sharedFoldersText)
                statRow(String(localized: "Upload Speed"), tab.uploadSpeedText)
                statRow(String(localized: "Free Upload Slots"), tab.freeUploadSlotsText)
                statRow(String(localized: "Upload Slots"), tab.uploadSlotsText)

                if tab.isQueuedUploadsVisible {
                    statRow(String(localized: "Queued Uploads"), tab.queuedUploadsText)
                }
            }

            tab.descriptionView.view
                .roundedFrame()
        }
        .padding(12)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private var interests: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "Interests"))
                    .font(.headline)
                Spacer()

                if tab.isLocalUser {
                    Button {
                        tab.onEditInterests()
                    } label: {
                        Label(String(localized: "Add…"), systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Edit Interests"))
                }
            }

            VSplitView {
                tab.likesListView.view
                    .frame(minHeight: 80)
                tab.dislikesListView.view
                    .frame(minHeight: 80)
            }
        }
        .padding(12)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(String(localized: "Send Message"), systemImage: "envelope") { tab.onSendMessage() }
            Button(String(localized: "Browse Files"), systemImage: "folder") { tab.onBrowseUser() }
            Button(tab.buddyButtonLabel, systemImage: "person.badge.plus") { tab.onAddRemoveBuddy() }

            if !tab.isLocalUser {
                Button(tab.banButtonLabel, systemImage: "nosign") { tab.onBanUnbanUser() }
                Button(tab.ignoreButtonLabel, systemImage: "eye.slash") { tab.onIgnoreUnignoreUser() }
            }

            Button(String(localized: "Gift Privileges…"), systemImage: "gift") { tab.onGivePrivileges() }
                .disabled(!tab.isGiftPrivilegesEnabled)

            Spacer()

            if tab.isProgressVisible {
                if let progress = tab.progress {
                    ProgressView(value: progress)
                        .frame(maxWidth: 150)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 150)
                }
            }

            Button(String(localized: "Refresh Profile"), systemImage: "arrow.clockwise") { tab.onRefresh() }
                .disabled(!tab.isRefreshEnabled)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// Transparent view showing a context menu on right click.
private struct PictureMenuView: NSViewRepresentable {

    let menu: PopupMenu

    func makeNSView(context: Context) -> MenuView {
        let view = MenuView()
        view.popupMenu = menu
        return view
    }

    func updateNSView(_ view: MenuView, context: Context) {
        view.popupMenu = menu
    }

    final class MenuView: NSView {
        var popupMenu: PopupMenu?

        override func menu(for event: NSEvent) -> NSMenu? {
            popupMenu?.prepare()
            return popupMenu?.menu
        }
    }
}
