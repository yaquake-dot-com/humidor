// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore
import Observation
import SwiftUI

/// Chat rooms page, containing a tab for each joined room.
@MainActor
@Observable
final class ChatRoomsPage: TabbedPage {

    @ObservationIgnored let window: MainWindow
    let notebook: Notebook<ChatRoomTab>
    @ObservationIgnored private(set) var pages: [String: ChatRoomTab] = [:]
    @ObservationIgnored private(set) var chatEntry: ChatEntry!
    @ObservationIgnored private(set) var roomList: RoomListPopover!
    /// Rooms where we were mentioned, and the user who mentioned us
    @ObservationIgnored private(set) var highlightedRooms = OrderedDictionary<String, String?>()

    var roomText = ""
    private(set) var roomFocusRequest = 0
    private(set) var isRoomEntryEnabled = false
    var isRoomListShown = false
    /// Whether the users of the current room are shown next to the chat
    var isUsersListShown = true

    init(window: MainWindow) {
        self.window = window
        self.notebook = Notebook(window: window, parentPage: .chatrooms)

        chatEntry = ChatEntry(
            sendMessage: { core.chatrooms.sendMessage($0, $1) },
            command: { room, command, args in
                core.pluginHandler?.triggerChatroomCommandEvent(room: room, command: command, args: args) ?? false
            },
            isSpellCheckEnabled: config.ui.spellCheck
        )
        roomList = RoomListPopover { [unowned self] in isRoomListShown = false }

        notebook.switchPageCallback = { [unowned self] in onSwitchChat($0) }
        notebook.removeAllPagesCallback = { core.chatrooms.removeAllRooms() }

        events.connect(.clearRoomMessages) { [unowned self] in
            pages[$0]?.chatView.clear()
            pages[$0]?.activityView.clear()
        }
        events.connect(.echoRoomMessage) { [unowned self] in
            pages[$0.target]?.echoRoomMessage($0.message, messageType: $0.messageType)
        }
        events.connectMessage(.globalRoomMessage) { [unowned self] msg in
            pages[ChatRooms.globalRoomName]?.sayChatRoom(msg)
        }
        events.connect(.ignoreUser) { [unowned self] in ignoreUser($0) }
        events.connect(.ignoreUserIP) { [unowned self] in
            if let username = $0.username {
                ignoreUser(username)
            }
        }
        events.connectMessage(.joinRoom) { [unowned self] in joinRoom($0) }
        events.connectMessage(.leaveRoom) { [unowned self] in pages[$0.room]?.leaveRoom() }
        events.connectMessage(.peerAddress) { [unowned self] msg in
            for page in pages.values {
                page.peerAddress(msg)
            }
        }
        events.connectMessage(.privateRoomAddOperator) { [unowned self] in pages[$0.room]?.privateRoomAddOperator($0) }
        events.connectMessage(.privateRoomAddUser) { [unowned self] in pages[$0.room]?.privateRoomAddUser($0) }
        events.connectMessage(.privateRoomRemoveOperator) { [unowned self] in
            pages[$0.room]?.privateRoomRemoveOperator($0)
        }
        events.connectMessage(.privateRoomRemoveUser) { [unowned self] in pages[$0.room]?.privateRoomRemoveUser($0) }
        events.connect(.removeRoom) { [unowned self] in removeRoom($0) }
        events.connect(.roomCompletions) { [unowned self] in notebook.currentPage?.updateCompletions($0) }
        events.connectMessage(.sayChatRoom) { [unowned self] in pages[$0.room]?.sayChatRoom($0) }
        events.connect(.serverDisconnect) { [unowned self] _ in serverDisconnect() }
        events.connect(.serverLogin) { [unowned self] _ in isRoomEntryEnabled = true }
        events.connect(.showRoom) { [unowned self] in showRoom($0) }
        events.connect(.unignoreUser) { [unowned self] in unignoreUser($0) }
        events.connect(.unignoreUserIP) { [unowned self] in
            if let username = $0.username {
                unignoreUser(username)
            }
        }
        events.connect(.userCountry) { [unowned self] event in
            for page in pages.values {
                page.userCountry(event.username, countryCode: event.countryCode)
            }
        }
        events.connectMessage(.userJoinedRoom) { [unowned self] in pages[$0.room]?.userJoinedRoom($0) }
        events.connectMessage(.userLeftRoom) { [unowned self] in pages[$0.room]?.userLeftRoom($0) }
        events.connect(.userStats) { [unowned self] msg in
            for page in pages.values {
                page.userStats(msg)
            }
        }
        events.connectMessage(.userStatus) { [unowned self] msg in
            for page in pages.values {
                page.userStatus(msg)
            }
        }
    }

    func onFocus() {
        guard window.currentPage == .chatrooms, notebook.pages.isEmpty else {
            return
        }

        if isRoomEntryEnabled {
            roomFocusRequest += 1
        }
    }

    func movePage(fromOffsets source: IndexSet, toOffset destination: Int) {
        notebook.movePage(fromOffsets: source, toOffset: destination)

        // Remember position of opened auto-joined rooms
        config.server.autoJoin = notebook.pages.map(\.room)
    }

    private func onSwitchChat(_ page: ChatRoomTab) {
        guard window.currentPage == .chatrooms else {
            return
        }

        let joinedRoom = core.chatrooms.joinedRooms[page.room]

        chatEntry.setParent(entity: page.room, chatView: page.chatView)
        chatEntry.isSensitive = !(joinedRoom?.users.isEmpty ?? true)
        page.updateRoomUserCompletions()

        if !page.isLoaded {
            page.load()
        }

        // Remove highlight
        unhighlightRoom(page.room)
    }

    func onCreateRoom() {
        var room = roomText.trimmingCharacters(in: .whitespaces)

        guard !room.isEmpty else {
            return
        }

        if !core.chatrooms.serverRooms.contains(room) && core.chatrooms.privateRooms[room] == nil {
            room = ChatRooms.sanitizeRoomName(room)

            OptionDialog(
                title: String(localized: "Create New Room?"),
                message: String(localized: "Do you really want to create a new room \"\(room)\"?"),
                optionLabel: String(localized: "Make room private")
            ) { dialog, _ in
                let isPrivate = (dialog as? OptionDialog)?.optionValue ?? false
                core.chatrooms.showRoom(room, isPrivate: isPrivate)
            }.present()
        } else {
            core.chatrooms.showRoom(room)
        }

        roomText = ""
    }

    func clearNotifications() {
        guard window.currentPage == .chatrooms, let page = notebook.currentPage else {
            return
        }

        // Remove highlight
        unhighlightRoom(page.room)
    }

    private func showRoom(_ event: ShowRoom) {
        let room = event.room

        if pages[room] == nil {
            let isGlobal = (room == ChatRooms.globalRoomName)
            let tabPosition = (isGlobal && !event.remembered) ? 0 : -1
            let page = ChatRoomTab(chatrooms: self, room: room, isPrivate: event.isPrivate, isGlobal: isGlobal)

            pages[room] = page
            notebook.insertPage(page, text: room, closeCallback: { [weak page] in page?.onLeaveRoom() },
                                position: tabPosition)

            if !isGlobal {
                window.search.roomSearchItems.append(room)
            }
        }

        if event.switchPage, let page = pages[room] {
            notebook.setCurrentPage(page)
            window.changeMainPage(.chatrooms)
        }
    }

    private func removeRoom(_ room: String) {
        guard let page = pages[room] else {
            return
        }

        if page === notebook.currentPage {
            chatEntry.setParent(entity: nil)
        }

        page.clear()

        let isPrivate = page.isPrivate
        notebook.removePage(page) {
            core.chatrooms.showRoom(room, isPrivate: isPrivate)
        }
        pages.removeValue(forKey: room)
        chatEntry.clearUnsentMessage(room)

        if room != ChatRooms.globalRoomName {
            window.search.roomSearchItems.removeAll { $0 == room }
        }
    }

    func highlightRoom(_ room: String, user: String?) {
        guard !room.isEmpty, highlightedRooms[room] == nil else {
            return
        }

        highlightedRooms[room] = user
        window.updateNotificationBadge()
    }

    func unhighlightRoom(_ room: String) {
        guard highlightedRooms.removeValue(forKey: room) != nil else {
            return
        }

        window.updateNotificationBadge()
    }

    private func joinRoom(_ msg: JoinRoom) {
        guard let page = pages[msg.room] else {
            return
        }

        page.joinRoom(msg)

        if page === notebook.currentPage {
            chatEntry.isSensitive = true
            _ = page.onFocus()
        }
    }

    private func ignoreUser(_ username: String) {
        for page in pages.values {
            page.ignoreUser(username)
        }
    }

    private func unignoreUser(_ username: String) {
        for page in pages.values {
            page.unignoreUser(username)
        }
    }

    func updateWidgets() {
        chatEntry.setSpellCheckEnabled(config.ui.spellCheck)

        for page in pages.values {
            page.toggleChatButtons()
            page.chatView.updateTags()
        }
    }

    private func serverDisconnect() {
        isRoomEntryEnabled = false
        chatEntry.isSensitive = false

        for page in pages.values {
            page.serverDisconnect()
        }
    }
}

// MARK: - Chat Room Tab

/// A single chat room.
@MainActor
@Observable
final class ChatRoomTab: NotebookPage {

    @ObservationIgnored unowned let chatrooms: ChatRoomsPage
    @ObservationIgnored let window: MainWindow
    let room: String
    @ObservationIgnored private(set) var isPrivate: Bool
    let isGlobal: Bool

    @ObservationIgnored private(set) var isLoaded = false
    @ObservationIgnored private(set) var activityView: TextView!
    @ObservationIgnored private(set) var chatView: ChatView!
    @ObservationIgnored private(set) var usersListView: TreeView!
    @ObservationIgnored private var popupMenuUserChat: UserPopupMenu!
    @ObservationIgnored private var popupMenuUserList: UserPopupMenu!
    @ObservationIgnored private(set) var roomWall: RoomWall!

    var isLogEnabled: Bool {
        didSet {
            onLogToggled()
        }
    }
    var isSpeechEnabled = false
    private(set) var isLogToggleVisible = false
    private(set) var isSpeechToggleVisible = false
    private(set) var userCountText = "0"
    var isRoomWallShown = false

    init(chatrooms: ChatRoomsPage, room: String, isPrivate: Bool, isGlobal: Bool) {
        self.chatrooms = chatrooms
        self.window = chatrooms.window
        self.room = room
        self.isPrivate = isPrivate
        self.isGlobal = isGlobal
        self.isLogEnabled = config.logging.rooms.contains(room)

        activityView = TextView(parseURLs: false, isEditable: false, horizontalMargin: 10, verticalMargin: 5,
                                paragraphSpacing: 2)

        chatView = ChatView(autoScroll: false, horizontalMargin: 10, verticalMargin: 5, paragraphSpacing: 2,
                            font: Theme.font(config.ui.chatFont)) { [unowned self] _, username in
            usernameEvent(username)
        }
        chatView.statusUsers = { core.chatrooms.joinedRooms[room]?.users ?? [] }
        chatView.pageDownCallback = { [unowned chatrooms] in
            chatrooms.chatEntry.grabFocus()
            return true
        }

        toggleChatButtons()

        usersListView = TreeView(
            columns: [
                // Visible columns
                TreeColumn(id: "status", title: String(localized: "Status"), kind: .icon, width: 25, hidesHeader: true),
                TreeColumn(id: "country", title: String(localized: "Country"), kind: .icon, width: 30,
                           hidesHeader: true),
                TreeColumn(id: "user", title: String(localized: "User"), width: 110, expandsColumn: true,
                           defaultSortOrder: .ascending, isIteratorKey: true,
                           textWeightColumn: "username_weight_data", textUnderlineColumn: "username_underline_data",
                           sensitiveColumn: "is_unignored_data"),
                TreeColumn(id: "speed", title: String(localized: "Speed"), kind: .number, width: 80,
                           expandsColumn: true, sortColumn: "speed_data", sensitiveColumn: "is_unignored_data"),
                TreeColumn(id: "files", title: String(localized: "Files"), kind: .number, expandsColumn: true,
                           sortColumn: "files_data", sensitiveColumn: "is_unignored_data"),

                // Hidden data columns
                .data("speed_data"),
                .data("files_data"),
                .data("username_weight_data"),
                .data("username_underline_data"),
                .data("is_unignored_data")
            ],
            persistentSort: true, name: "chat_room", secondaryName: room,
            activateRow: { [unowned self] _, _, _ in
                if let user = selectedUsername {
                    core.userInfo.showUser(user)
                }
            }
        )

        popupMenuUserChat = UserPopupMenu()
        popupMenuUserList = UserPopupMenu { [unowned self] menu in
            if let user = selectedUsername, let menu = menu as? UserPopupMenu {
                populateUserMenu(user, menu: menu)
            }
        }

        for menu in [popupMenuUserChat!, popupMenuUserList!] {
            menu.addItems(
                .separator,
                .action(String(localized: "Search User's Files")) { [weak menu] in menu?.onSearchUser() }
            )
        }
        usersListView.popupMenu = popupMenuUserList

        let activityMenu = PopupMenu { [unowned self] menu in
            menu.setEnabled(String(localized: "Copy"), activityView.hasSelection)
        }
        activityMenu.addItems(
            .action(String(localized: "Find…")) { [unowned self] in activityView.showFindBar() },
            .separator,
            .action(String(localized: "Copy")) { [unowned self] in activityView.onCopyText() },
            .action(String(localized: "Copy All")) { [unowned self] in activityView.onCopyAllText() },
            .separator,
            .action(String(localized: "Clear Activity View")) { [unowned self] in activityView.onClearAllText() },
            .separator,
            .action(String(localized: "Leave Room")) { [unowned self] in onLeaveRoom() }
        )
        activityView.popupMenu = activityMenu

        let chatMenu = PopupMenu { [unowned self] menu in
            menu.setEnabled(String(localized: "Copy"), chatView.hasSelection)
            menu.setEnabled(String(localized: "Copy Link"), !chatView.urlForCurrentPosition.isEmpty)
        }
        chatMenu.addItems(
            .action(String(localized: "Find…")) { [unowned self] in chatView.showFindBar() },
            .separator,
            .action(String(localized: "Copy")) { [unowned self] in chatView.onCopyText() },
            .action(String(localized: "Copy Link")) { [unowned self] in chatView.onCopyLink() },
            .action(String(localized: "Copy All")) { [unowned self] in chatView.onCopyAllText() },
            .separator
        )

        if !window.application.isolatedMode {
            chatMenu.addItems(.action(String(localized: "View Room Log")) { [unowned self] in onViewRoomLog() })
        }

        chatMenu.addItems(
            .action(String(localized: "Delete Room Log…")) { [unowned self] in onDeleteRoomLog() },
            .separator,
            .action(String(localized: "Clear Message View")) { [unowned self] in chatView.onClearAllText() },
            .action(String(localized: "Leave Room")) { [unowned self] in onLeaveRoom() }
        )
        chatView.popupMenu = chatMenu

        roomWall = RoomWall(room: room)

        setupPublicFeed()
        prependOldMessages()
    }

    var tabMenuItems: [TabMenuItem] {
        [TabMenuItem(String(localized: "Leave Room")) { [unowned self] in onLeaveRoom() }]
    }

    var content: some View {
        ChatRoomTabView(tab: self)
    }

    func load() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.readRoomLogsFinished()
            }
        }
        isLoaded = true
    }

    func clear() {
        activityView.clear()
        chatView.clear()
        usersListView.clear()
    }

    private func setupPublicFeed() {
        guard isGlobal else {
            return
        }

        // Public feed is jibberish and too fast for TTS
        isSpeechEnabled = false
    }

    private func addUserRow(_ userData: UserData) {
        let username = userData.username
        let status = UserStatus(rawValue: userData.status ?? UserStatus.offline.rawValue) ?? .offline
        let speed = userData.avgSpeed ?? 0
        let files = userData.files
        var weight = 400
        var isUnderlined = false
        let isUnignored = !(core.networkFilter.isUserIgnored(username)
                            || core.networkFilter.isUserIPIgnored(username: username))

        if let privateRoom = core.chatrooms.privateRooms[room] {
            if username == privateRoom.owner {
                weight = 700
                isUnderlined = true
            } else if privateRoom.operators.contains(username) {
                weight = 700
            }
        }

        usersListView.addRow([
            .string(Theme.userStatusIconName(status)),
            .string(Theme.flagIconName(userData.country)),
            .string(username),
            .string(speed > 0 ? humanSpeed(speed) : ""),
            .string(files.map(humanize) ?? ""),
            .int(speed),
            .int(files ?? 0),
            .int(weight),
            .bool(isUnderlined),
            .bool(isUnignored)
        ], selectRow: false)
    }

    private func readRoomLogsFinished() {
        activityView.scrollBottom()
        chatView.scrollBottom()
        activityView.autoScroll = true
        chatView.autoScroll = true
    }

    private func prependOldMessages() {
        guard let folderPath = log.roomFolderPath else {
            return
        }

        let logLines = log.readLog(folderPath: folderPath, basename: room, numLines: config.logging.readRoomLines) ?? []
        chatView.appendLogLines(logLines, loginUsername: config.server.login)
    }

    private func populateRoomUsers(_ joinedUsers: [UserData]) {
        // Temporarily disable sorting for increased performance
        usersListView.freeze()

        for userData in joinedUsers {
            if let row = usersListView.iterators[.string(userData.username)] {
                usersListView.removeRow(row)
            }
            addUserRow(userData)
        }

        // List private room members who are offline/not currently joined
        if let privateRoom = core.chatrooms.privateRooms[room] {
            for username in privateRoom.members where usersListView.iterators[.string(username)] == nil {
                addUserRow(Self.offlineUserData(username))
            }

            if let owner = privateRoom.owner, !owner.isEmpty, usersListView.iterators[.string(owner)] == nil {
                addUserRow(Self.offlineUserData(owner))
            }
        }

        usersListView.unfreeze()

        // Update user count
        updateUserCount()

        // Update all username tags in chat log
        chatView.updateUserTags()

        // Add room users to completion list
        if chatrooms.notebook.currentPage === self {
            updateRoomUserCompletions()
        }
    }

    private static func offlineUserData(_ username: String) -> UserData {
        var userData = UserData(username: username)
        userData.status = UserStatus.offline.rawValue
        return userData
    }

    private func populateUserMenu(_ user: String, menu: UserPopupMenu) {
        menu.setUser(user)
        menu.toggleUserItems()
    }

    private var selectedUsername: String? {
        usersListView.selectedRows.first.map { usersListView.rowValue($0, "user").string }
    }

    func toggleChatButtons() {
        isLogToggleVisible = !config.logging.chatrooms
        isSpeechToggleVisible = config.ui.speechEnabled
    }

    private func showNotification(room: String, user: String, text: String, isMentioned: Bool) {
        chatrooms.notebook.requestTabChanged(self, isImportant: isMentioned, isQuiet: isGlobal)

        if isGlobal && core.chatrooms.joinedRooms[room] != nil {
            // Don't show notifications about the Public feed that's duplicated in an open tab
            return
        }

        if isMentioned {
            log.add(String(localized: "\(user) mentioned you in room \(room)"))

            if config.notifications.popupChatroomMention {
                core.notifications?.showChatroomNotification(
                    room: room, message: text, title: String(localized: "Mentioned by \(user) in Room \(room)"),
                    highPriority: true
                )
            }
        }

        if chatrooms.notebook.currentPage === self && window.currentPage == .chatrooms && window.isActive {
            // Don't show notifications if the chat is open and the window is in use
            return
        }

        if isMentioned {
            // We were mentioned, show urgency hint
            chatrooms.highlightRoom(room, user: user)
            return
        }

        if !isGlobal && config.notifications.popupChatroom {
            // Don't show notifications for public feed room, they're too noisy
            core.notifications?.showChatroomNotification(room: room, message: text,
                                                         title: String(localized: "Message by \(user) in Room \(room)"))
        }
    }

    func sayChatRoom(_ msg: SayChatroom) {
        sayChatRoom(room: msg.room, user: msg.user, message: msg.message,
                    formattedMessage: msg.formattedMessage ?? msg.message, messageType: msg.chatMessageType)
    }

    func sayChatRoom(_ msg: GlobalRoomMessage) {
        sayChatRoom(room: msg.room, user: msg.user, message: msg.message,
                    formattedMessage: msg.formattedMessage ?? msg.message, messageType: msg.chatMessageType)
    }

    private func sayChatRoom(room: String, user: String, message: String, formattedMessage: String,
                             messageType: String?) {
        let userTag = chatView.userTag(user)

        if messageType != "local" {
            if isSpeechEnabled {
                core.notifications?.newTTS(config.ui.speechRooms, args: ["room": room, "user": user, "message": message])
            }

            showNotification(room: room, user: user, text: message, isMentioned: messageType == "hilite")
        }

        chatView.appendLine(formattedMessage, messageType: messageType, timestampFormat: config.logging.roomsTimestamp,
                            username: user, userTag: userTag)
    }

    func echoRoomMessage(_ text: String, messageType: String) {
        let timestampFormat = (messageType != "command") ? config.logging.roomsTimestamp : nil
        chatView.appendLine(text, messageType: messageType, timestampFormat: timestampFormat)
    }

    private func isUserIgnored(_ username: String) -> Bool {
        core.networkFilter.isUserIgnored(username) || core.networkFilter.isUserIPIgnored(username: username)
    }

    func userJoinedRoom(_ msg: UserJoinedRoom) {
        let userData = msg.userData
        let username = userData.username

        if let row = usersListView.iterators[.string(username)] {
            guard isPrivate else {
                return
            }
            usersListView.removeRow(row)
        }

        // Add to completion list, and completion drop-down
        if chatrooms.notebook.currentPage === self {
            chatrooms.chatEntry.addCompletion(username)
        }

        if username != core.users.loginUsername && !isUserIgnored(username) {
            activityView.appendLine(String(localized: "\(username) joined the room"),
                                    timestampFormat: config.logging.roomsTimestamp)
        }

        addUserRow(userData)
        chatView.updateUserTag(username)
        updateUserCount()
    }

    func userLeftRoom(_ msg: UserLeftRoom) {
        let username = msg.username

        guard let row = usersListView.iterators[.string(username)] else {
            return
        }

        // Remove from completion list, and completion drop-down
        if chatrooms.notebook.currentPage === self && core.buddies.users[username] == nil {
            chatrooms.chatEntry.removeCompletion(username)
        }

        if !isUserIgnored(username) {
            activityView.appendLine(String(localized: "\(username) left the room"),
                                    timestampFormat: config.logging.roomsTimestamp)
        }

        if isPrivate {
            usersListView.setRowValues(row, [
                "status": .string(Theme.userStatusIconName(.offline)),
                "speed": "",
                "speed_data": 0,
                "files": "",
                "files_data": 0,
                "country": ""
            ])
        } else {
            usersListView.removeRow(row)
        }

        chatView.updateUserTag(username)
        updateUserCount()
    }

    func privateRoomAddOperator(_ msg: PrivateRoomAddOperator) {
        if let row = usersListView.iterators[.string(msg.user)] {
            usersListView.setRowValues(row, ["username_weight_data": 700, "username_underline_data": false])
        }
    }

    func privateRoomAddUser(_ msg: PrivateRoomAddUser) {
        let username = msg.user

        guard usersListView.iterators[.string(username)] == nil else {
            return
        }

        addUserRow(Self.offlineUserData(username))
        chatView.updateUserTag(username)
        updateUserCount()
    }

    func privateRoomRemoveOperator(_ msg: PrivateRoomRemoveOperator) {
        if let row = usersListView.iterators[.string(msg.user)] {
            usersListView.setRowValues(row, ["username_weight_data": 400, "username_underline_data": false])
        }
    }

    func privateRoomRemoveUser(_ msg: PrivateRoomRemoveUser) {
        let username = msg.user

        guard let row = usersListView.iterators[.string(username)] else {
            return
        }

        usersListView.removeRow(row)
        chatView.updateUserTag(username)
        updateUserCount()
    }

    private func updateUserCount() {
        userCountText = humanize(usersListView.iterators.count)
    }

    func ignoreUser(_ username: String) {
        guard let row = usersListView.iterators[.string(username)] else {
            return
        }

        if usersListView.rowValue(row, "is_unignored_data").bool {
            usersListView.setRowValue(row, "is_unignored_data", false)
        }
    }

    func unignoreUser(_ username: String) {
        guard let row = usersListView.iterators[.string(username)], !isUserIgnored(username) else {
            return
        }

        if !usersListView.rowValue(row, "is_unignored_data").bool {
            usersListView.setRowValue(row, "is_unignored_data", true)
        }
    }

    func peerAddress(_ msg: GetPeerAddress) {
        if core.networkFilter.isUserIPIgnored(username: msg.user) {
            ignoreUser(msg.user)
        }
    }

    private func isJoinedUser(_ user: String) -> Bool {
        // Private room members may be offline/not currently joined
        core.chatrooms.joinedRooms[room]?.users.contains(user) ?? false
    }

    func userStats(_ msg: GetUserStats) {
        let user = msg.user

        guard let row = usersListView.iterators[.string(user)], isJoinedUser(user) else {
            return
        }

        let speed = msg.avgSpeed
        let numFiles = msg.files
        var values: [String: TreeValue] = [:]

        if speed != usersListView.rowValue(row, "speed_data").int {
            values["speed"] = .string(speed > 0 ? humanSpeed(speed) : "")
            values["speed_data"] = .int(speed)
        }

        if numFiles != usersListView.rowValue(row, "files_data").int {
            values["files"] = .string(humanize(numFiles))
            values["files_data"] = .int(numFiles)
        }

        if !values.isEmpty {
            usersListView.setRowValues(row, values)
        }
    }

    func userStatus(_ msg: GetUserStatus) {
        let user = msg.user

        guard let row = usersListView.iterators[.string(user)], isJoinedUser(user),
              let status = UserStatus(rawValue: msg.status) else {
            return
        }

        let statusIconName = Theme.userStatusIconName(status)

        guard statusIconName != usersListView.rowValue(row, "status").string else {
            return
        }

        let action: String

        switch status {
        case .away:
            action = String(localized: "\(user) has gone away")
        case .online:
            action = String(localized: "\(user) has returned")
        case .offline:
            // If we reach this point, the server did something wrong. The user should have
            // left the room before an offline status is sent.
            return
        }

        if !isUserIgnored(user) {
            activityView.appendLine(action, timestampFormat: config.logging.roomsTimestamp)
        }

        usersListView.setRowValue(row, "status", .string(statusIconName))
        chatView.updateUserTag(user)
    }

    func userCountry(_ user: String, countryCode: String) {
        guard let row = usersListView.iterators[.string(user)], isJoinedUser(user) else {
            return
        }

        let flagIconName = Theme.flagIconName(countryCode)

        if !flagIconName.isEmpty && flagIconName != usersListView.rowValue(row, "country").string {
            usersListView.setRowValue(row, "country", .string(flagIconName))
        }
    }

    private func usernameEvent(_ username: String) {
        populateUserMenu(username, menu: popupMenuUserChat)
        popupMenuUserChat.popupAtMouseLocation()
    }

    func serverDisconnect() {
        leaveRoom()
    }

    func joinRoom(_ msg: JoinRoom) {
        isPrivate = msg.isPrivate
        populateRoomUsers(msg.users)
        activityView.appendLine(String(localized: "\(core.users.loginUsername ?? "") joined the room"),
                                timestampFormat: config.logging.roomsTimestamp)
    }

    func leaveRoom() {
        usersListView.clear()
        updateUserCount()

        if chatrooms.notebook.currentPage === self {
            updateRoomUserCompletions()
        }

        chatView.updateUserTags()
    }

    func onFocus() -> Bool {
        if window.currentPage == .chatrooms {
            if chatrooms.chatEntry.isSensitive {
                chatrooms.chatEntry.grabFocus()
            } else {
                chatView.grabFocus()
            }
        }
        return true
    }

    func onLeaveRoom() {
        core.chatrooms.removeRoom(room)
    }

    private func onLogToggled() {
        if !isLogEnabled {
            config.logging.rooms.removeAll { $0 == room }
            return
        }

        if !config.logging.rooms.contains(room) {
            config.logging.rooms.append(room)
        }
    }

    private func onViewRoomLog() {
        guard let folderPath = log.roomFolderPath else {
            return
        }
        _ = openFilePath(log.logFileURL(folderPath: folderPath, basename: room).path, createFile: true)
    }

    private func onDeleteRoomLog() {
        OptionDialog(
            title: String(localized: "Delete Logged Messages?"),
            message: String(localized: "Do you really want to permanently delete all logged messages for this room?"),
            destructiveResponse: "ok"
        ) { [weak self] _, _ in
            guard let self, let folderPath = log.roomFolderPath else {
                return
            }

            log.deleteLog(folderPath: folderPath, basename: room)
            activityView.clear()
            chatView.clear()
        }.present()
    }

    func updateRoomUserCompletions() {
        updateCompletions(core.chatrooms.completions)
    }

    func updateCompletions(_ completions: Set<String>) {
        var completions = completions

        // We want to include users for this room only
        if config.words.roomUsers {
            completions.formUnion(core.chatrooms.joinedRooms[room]?.users ?? [])
        }

        chatrooms.chatEntry.setCompletions(completions)
    }
}

// MARK: - Room List

/// List of rooms on the server.
@MainActor
@Observable
final class RoomListPopover {

    private static let privateUsersOffset = 10_000_000

    @ObservationIgnored private(set) var listView: TreeView!
    @ObservationIgnored private var popupRoom: String?
    @ObservationIgnored private let onJoin: @MainActor () -> Void
    @ObservationIgnored private var isUpdatingToggle = false

    var searchText = "" {
        didSet {
            listView.selectFirstMatch(searchText)
        }
    }
    var isPublicFeedEnabled = false {
        didSet {
            if isPublicFeedEnabled != oldValue && !isUpdatingToggle {
                onTogglePublicFeed()
            }
        }
    }
    var isPrivateRoomsAccepted: Bool {
        didSet {
            if isPrivateRoomsAccepted != oldValue && !isUpdatingToggle {
                config.server.privateChatrooms = isPrivateRoomsAccepted
                core.chatrooms.requestPrivateRoomToggle(isPrivateRoomsAccepted)
            }
        }
    }

    init(onJoin: @escaping @MainActor () -> Void) {
        self.onJoin = onJoin
        self.isPrivateRoomsAccepted = config.server.privateChatrooms

        listView = TreeView(
            columns: [
                // Visible columns
                TreeColumn(id: "room", title: String(localized: "Room"), width: 260, expandsColumn: true,
                           isIteratorKey: true, textWeightColumn: "room_weight_data",
                           textUnderlineColumn: "room_underline_data"),
                TreeColumn(id: "users", title: String(localized: "Users"), kind: .number, sortColumn: "users_data",
                           defaultSortOrder: .descending),

                // Hidden data columns
                .data("users_data"),
                .data("is_private_data"),
                .data("room_weight_data"),
                .data("room_underline_data")
            ],
            activateRow: { [unowned self] _, _, _ in onRowActivated() }
        )

        let popupMenu = PopupMenu { [unowned self] menu in onPopupMenu(menu) }
        popupMenu.addItems(
            .hiddenWhenDisabled(String(localized: "Join Room")) { [unowned self] in onPopupJoin() },
            .hiddenWhenDisabled(String(localized: "Leave Room")) { [unowned self] in
                if let popupRoom {
                    core.chatrooms.removeRoom(popupRoom)
                }
            },
            .separator,
            .hiddenWhenDisabled(String(localized: "Disown Private Room")) { [unowned self] in
                if let popupRoom {
                    core.chatrooms.requestPrivateRoomDisown(popupRoom)
                }
            },
            .hiddenWhenDisabled(String(localized: "Cancel Room Membership")) { [unowned self] in
                if let popupRoom {
                    core.chatrooms.requestPrivateRoomCancelMembership(popupRoom)
                }
            }
        )
        listView.popupMenu = popupMenu

        events.connectMessage(.joinRoom) { [unowned self] in joinRoom($0) }
        events.connectMessage(.privateRoomAdded) { [unowned self] in addRoom($0.room, isPrivate: true) }
        events.connect(.removeRoom) { [unowned self] in removeRoom($0) }
        events.connectMessage(.roomList) { [unowned self] in roomList($0) }
        events.connect(.serverDisconnect) { [unowned self] _ in listView.clear() }
        events.connect(.showRoom) { [unowned self] in
            if $0.room == ChatRooms.globalRoomName {
                setPublicFeedToggle(true)
            }
        }
        events.connectMessage(.userJoinedRoom) { [unowned self] msg in
            if msg.userData.username != core.users.loginUsername {
                updateRoomUserCount(msg.room)
            }
        }
        events.connectMessage(.userLeftRoom) { [unowned self] msg in
            if msg.username != core.users.loginUsername {
                updateRoomUserCount(msg.room, decrement: true)
            }
        }
    }

    /// Room names, suggested in the room entry
    var roomNames: [String] {
        listView.iterators.keys.map(\.string).sorted()
    }

    /// Room names in the default order of the room list: private rooms first, then by user count
    var popularRoomNames: [String] {
        listView.iterators
            .sorted { listView.rowValue($0.value, "users_data").int > listView.rowValue($1.value, "users_data").int }
            .map(\.key.string)
    }

    private var selectedRoom: String? {
        listView.selectedRows.first.map { listView.rowValue($0, "room").string }
    }

    private func setPublicFeedToggle(_ isEnabled: Bool) {
        isUpdatingToggle = true
        isPublicFeedEnabled = isEnabled
        isUpdatingToggle = false
    }

    private func addRoom(_ room: String, userCount: Int = 0, isPrivate: Bool = false, isOwned: Bool = false) {
        var userCount = userCount
        let humanUserCount = humanize(userCount)

        if isPrivate {
            // Large internal value to sort private rooms first
            userCount += Self.privateUsersOffset
        }

        listView.addRow([
            .string(room),
            .string(humanUserCount),
            .int(userCount),
            .bool(isPrivate),
            .int(isPrivate ? 700 : 400),
            .bool(isOwned)
        ], selectRow: false)
    }

    private func updateRoomUserCount(_ room: String, userCount: Int? = nil, decrement: Bool = false) {
        guard let row = listView.iterators[.string(room)] else {
            return
        }

        let isPrivate = listView.rowValue(row, "is_private_data").bool
        var newUserCount: Int

        if let userCount {
            newUserCount = userCount

            if isPrivate {
                // Large internal value to sort private rooms first
                newUserCount += Self.privateUsersOffset
            }
        } else {
            newUserCount = listView.rowValue(row, "users_data").int

            if decrement {
                if newUserCount > 0 {
                    newUserCount -= 1
                }
            } else {
                newUserCount += 1
            }
        }

        let humanUserCount = isPrivate ? humanize(newUserCount - Self.privateUsersOffset) : humanize(newUserCount)
        listView.setRowValues(row, ["users": .string(humanUserCount), "users_data": .int(newUserCount)])
    }

    private func joinRoom(_ msg: JoinRoom) {
        let room = msg.room

        guard core.chatrooms.joinedRooms[room] != nil else {
            return
        }

        let userCount = msg.users.count

        if listView.iterators[.string(room)] == nil {
            addRoom(room, userCount: userCount, isPrivate: msg.isPrivate,
                    isOwned: msg.owner == core.users.loginUsername)
        }

        updateRoomUserCount(room, userCount: userCount)
    }

    private func removeRoom(_ room: String) {
        if room == ChatRooms.globalRoomName {
            setPublicFeedToggle(false)
        }

        updateRoomUserCount(room, decrement: true)
    }

    private func roomList(_ msg: RoomList) {
        listView.freeze()
        listView.clear()

        for room in msg.ownedPrivateRooms {
            addRoom(room.name, userCount: room.userCount ?? 0, isPrivate: true, isOwned: true)
        }

        for room in msg.otherPrivateRooms {
            addRoom(room.name, userCount: room.userCount ?? 0, isPrivate: true)
        }

        for room in msg.rooms {
            addRoom(room.name, userCount: room.userCount ?? 0)
        }

        listView.unfreeze()
    }

    private func onRowActivated() {
        guard let room = selectedRoom else {
            return
        }

        popupRoom = room
        onPopupJoin()
    }

    private func onPopupMenu(_ menu: PopupMenu) {
        let room = selectedRoom ?? ""
        popupRoom = room

        let isPrivateRoomOwned = core.chatrooms.isPrivateRoomOwned(room)
        let isPrivateRoomMember = core.chatrooms.isPrivateRoomMember(room)
        let isJoined = core.chatrooms.joinedRooms[room] != nil

        menu.setEnabled(String(localized: "Join Room"), !isJoined)
        menu.setEnabled(String(localized: "Leave Room"), isJoined)
        menu.setEnabled(String(localized: "Disown Private Room"), isPrivateRoomOwned)
        menu.setEnabled(String(localized: "Cancel Room Membership"), isPrivateRoomMember && !isPrivateRoomOwned)
    }

    private func onPopupJoin() {
        if let popupRoom {
            core.chatrooms.showRoom(popupRoom)
        }
        onJoin()
    }

    private func onTogglePublicFeed() {
        let globalRoomName = ChatRooms.globalRoomName

        if isPublicFeedEnabled {
            if core.chatrooms.joinedRooms[globalRoomName] == nil {
                core.chatrooms.showRoom(globalRoomName)
            }
            onJoin()
            return
        }

        core.chatrooms.removeRoom(globalRoomName)
    }

    func onRefresh() {
        core.chatrooms.requestRoomList()
    }
}

// MARK: - Room Wall

/// Messages that room users can leave on the room wall.
@MainActor
@Observable
final class RoomWall {

    let room: String
    @ObservationIgnored let messageView = TextView(isEditable: false, verticalMargin: 4, paragraphSpacing: 3)
    var messageText = ""
    private(set) var messageFocusRequest = 0

    init(room: String) {
        self.room = room
    }

    private func updateMessageList() {
        let tickers = core.chatrooms.joinedRooms[room]?.tickers ?? OrderedDictionary()
        let messages = tickers.reversed().map { user, message in
            "> [\(user)] \(message.replacingOccurrences(of: "\n", with: " "))"
        }

        messageView.appendLine(messages.joined(separator: "\n"))
        messageView.placeCursorAtLine(0)
    }

    func onSetRoomWallMessage() {
        let entryText = messageText

        core.chatrooms.requestUpdateTicker(room, message: entryText)

        if let loginUsername = core.users.loginUsername {
            core.chatrooms.joinedRooms[room]?.tickers.removeValue(forKey: loginUsername)
        }

        messageView.clear()

        if !entryText.isEmpty {
            messageView.appendLine("> [\(core.users.loginUsername ?? "")] \(entryText)")
            messageText = ""
        }

        updateMessageList()
    }

    func onClearMessage() {
        messageText = ""
        onSetRoomWallMessage()
    }

    func onShow() {
        messageView.clear()
        updateMessageList()

        let tickers = core.chatrooms.joinedRooms[room]?.tickers ?? OrderedDictionary()
        messageText = core.users.loginUsername.flatMap { tickers[$0] } ?? ""

        if tickers.isEmpty {
            // Focus message entry instead of list when no tickers are present
            messageFocusRequest += 1
        }
    }
}
