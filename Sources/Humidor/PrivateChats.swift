// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore
import Observation
import SwiftUI

/// Private chat page, containing a tab for each conversation.
@MainActor
@Observable
final class PrivateChatsPage: TabbedPage {

    @ObservationIgnored let window: MainWindow
    let notebook: Notebook<PrivateChatTab>
    @ObservationIgnored private(set) var pages: [String: PrivateChatTab] = [:]
    @ObservationIgnored private(set) var chatEntry: ChatEntry!
    @ObservationIgnored private(set) var history: ChatHistory!
    private(set) var highlightedUsers: [String] = []
    var isHistoryShown = false

    var usernameText = ""
    private(set) var usernameFocusRequest = 0

    init(window: MainWindow) {
        self.window = window
        self.notebook = Notebook(window: window, parentPage: .private)

        chatEntry = ChatEntry(
            sendMessage: { core.privateChat.sendMessage($0, $1) },
            command: { user, command, args in
                core.pluginHandler?.triggerPrivateChatCommandEvent(user: user, command: command, args: args) ?? false
            },
            isSpellCheckEnabled: config.ui.spellCheck
        )
        history = ChatHistory { [unowned self] in isHistoryShown = false }

        notebook.switchPageCallback = { [unowned self] in onSwitchChat($0) }
        notebook.removeAllPagesCallback = { core.privateChat.removeAllUsers() }

        events.connect(.clearPrivateMessages) { [unowned self] in pages[$0]?.chatView.clear() }
        events.connect(.echoPrivateMessage) { [unowned self] in
            pages[$0.target]?.echoPrivateMessage($0.message, messageType: $0.messageType)
        }
        events.connectMessage(.messageUser) { [unowned self] in pages[$0.user]?.messageUser($0) }
        events.connect(.privateChatCompletions) { [unowned self] in updateCompletions($0) }
        events.connect(.privateChatShowUser) { [unowned self] in showUser($0) }
        events.connect(.privateChatRemoveUser) { [unowned self] in removeUser($0) }
        events.connect(.serverDisconnect) { [unowned self] _ in serverDisconnect() }
        events.connect(.serverLogin) { [unowned self] in serverLogin($0) }
        events.connectMessage(.userStatus) { [unowned self] in userStatus($0) }
    }

    func onFocus() {
        guard window.currentPage == .private, notebook.pages.isEmpty else {
            return
        }
        usernameFocusRequest += 1
    }

    private func onReorderedPage() {
        config.privateChat.users = notebook.pages.map(\.user)
    }

    func movePage(fromOffsets source: IndexSet, toOffset destination: Int) {
        notebook.movePage(fromOffsets: source, toOffset: destination)
        onReorderedPage()
    }

    private func onSwitchChat(_ page: PrivateChatTab) {
        guard window.currentPage == .private else {
            return
        }

        chatEntry.setParent(entity: page.user, chatView: page.chatView)
        page.updateRoomUserCompletions()

        if !page.isLoaded {
            page.load()
        }

        // Remove highlight if selected tab belongs to a user in the list of highlights
        unhighlightUser(page.user)
    }

    func onGetPrivateChat() {
        let username = usernameText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !username.isEmpty else {
            return
        }

        usernameText = ""
        core.privateChat.showUser(username)
    }

    func clearNotifications() {
        guard window.currentPage == .private, let page = notebook.currentPage else {
            return
        }

        // Remove highlight
        unhighlightUser(page.user)
    }

    private func userStatus(_ msg: GetUserStatus) {
        if let page = pages[msg.user] {
            notebook.setUserStatus(page, user: msg.user, status: UserStatus(rawValue: msg.status) ?? .offline)
            page.chatView.updateUserTag(msg.user)
        }

        if msg.user == core.users.loginUsername {
            for page in pages.values {
                // We've enabled/disabled away mode, update our username color in all chats
                page.chatView.updateUserTag(msg.user)
            }
        }
    }

    private func showUser(_ event: PrivateChatShowUser) {
        let user = event.username

        if pages[user] == nil {
            let page = PrivateChatTab(chats: self, user: user)
            pages[user] = page
            notebook.insertPage(page, text: user, closeCallback: { [weak page] in page?.onClose() }, user: user,
                                position: event.remembered ? -1 : 0)
        }

        if event.switchPage, let page = pages[user] {
            notebook.setCurrentPage(page)
            window.changeMainPage(.private)
        }
    }

    private func removeUser(_ user: String) {
        guard let page = pages[user] else {
            return
        }

        if page === notebook.currentPage {
            chatEntry.setParent(entity: nil)
        }

        page.clear()
        notebook.removePage(page) {
            core.privateChat.showUser(user)
        }
        pages.removeValue(forKey: user)
        chatEntry.clearUnsentMessage(user)
    }

    func highlightUser(_ user: String) {
        guard !user.isEmpty, !highlightedUsers.contains(user) else {
            return
        }

        highlightedUsers.append(user)
        window.updateTitle()
    }

    func unhighlightUser(_ user: String) {
        guard let index = highlightedUsers.firstIndex(of: user) else {
            return
        }

        highlightedUsers.remove(at: index)
        window.updateTitle()
    }

    private func updateCompletions(_ completions: Set<String>) {
        notebook.currentPage?.updateCompletions(completions)
    }

    func updateWidgets() {
        chatEntry.setSpellCheckEnabled(config.ui.spellCheck)

        for page in pages.values {
            page.toggleChatButtons()
            page.chatView.updateTags()
        }
    }

    private func serverLogin(_ msg: Login) {
        guard msg.success else {
            return
        }

        chatEntry.isSensitive = true
        _ = notebook.currentPage?.onFocus()
    }

    private func serverDisconnect() {
        chatEntry.isSensitive = false

        for (user, page) in pages {
            page.serverDisconnect()
            notebook.setUserStatus(page, user: user, status: .offline)
        }
    }
}

// MARK: - Private Chat Tab

/// Conversation with a single user.
@MainActor
@Observable
final class PrivateChatTab: NotebookPage {

    @ObservationIgnored unowned let chats: PrivateChatsPage
    @ObservationIgnored let window: MainWindow
    let user: String

    @ObservationIgnored private(set) var isLoaded = false
    @ObservationIgnored private var isOfflineMessageShown = false
    @ObservationIgnored private(set) var chatView: ChatView!
    @ObservationIgnored private var popupMenuUserChat: UserPopupMenu!
    @ObservationIgnored private var popupMenuUserTab: UserPopupMenu!
    @ObservationIgnored private var popupMenu: PopupMenu!

    var isLogEnabled: Bool {
        didSet {
            onLogToggled()
        }
    }
    var isSpeechEnabled = false
    private(set) var isLogToggleVisible = false
    private(set) var isSpeechToggleVisible = false

    init(chats: PrivateChatsPage, user: String) {
        self.chats = chats
        self.window = chats.window
        self.user = user
        self.isLogEnabled = config.logging.privateChats.contains(user)

        chatView = ChatView(autoScroll: false, horizontalMargin: 10, verticalMargin: 5, paragraphSpacing: 2,
                            font: Theme.font(config.ui.chatFont)) { [unowned self] point, username in
            usernameEvent(username)
        }
        chatView.pageDownCallback = { [unowned chats] in
            chats.chatEntry.grabFocus()
            return true
        }

        toggleChatButtons()

        popupMenuUserChat = UserPopupMenu(username: user, tabName: .privateChat)
        popupMenuUserTab = UserPopupMenu(username: user, tabName: .privateChat) { [unowned self] _ in
            popupMenuUserTab.toggleUserItems()
        }

        for menu in [popupMenuUserChat!, popupMenuUserTab!] {
            menu.addItems(
                .separator,
                .action(String(localized: "Close All Tabs…")) { [unowned chats] in chats.notebook.removeAllPages() },
                .action(String(localized: "Close Tab")) { [unowned self] in onClose() }
            )
        }

        popupMenu = PopupMenu { [unowned self] menu in onPopupMenuChat(menu) }
        popupMenu.addItems(
            .action(String(localized: "Find…")) { [unowned self] in chatView.showFindBar() },
            .separator,
            .action(String(localized: "Copy")) { [unowned self] in chatView.onCopyText() },
            .action(String(localized: "Copy Link")) { [unowned self] in chatView.onCopyLink() },
            .action(String(localized: "Copy All")) { [unowned self] in chatView.onCopyAllText() },
            .separator
        )

        if !window.application.isolatedMode {
            popupMenu.addItems(
                .action(String(localized: "View Chat Log")) { [unowned self] in onViewChatLog() }
            )
        }

        popupMenu.addItems(
            .action(String(localized: "Delete Chat Log…")) { [unowned self] in onDeleteChatLog() },
            .separator,
            .action(String(localized: "Clear Message View")) { [unowned self] in chatView.onClearAllText() },
            .separator,
            .submenu(String(localized: "User Actions"), popupMenuUserTab)
        )
        chatView.popupMenu = popupMenu

        prependOldMessages()
    }

    var tabMenuItems: [TabMenuItem] {
        [
            TabMenuItem(String(localized: "Close All Tabs…")) { [unowned chats] in chats.notebook.removeAllPages() },
            TabMenuItem(String(localized: "Close Tab")) { [unowned self] in onClose() }
        ]
    }

    var content: some View {
        PrivateChatTabView(tab: self)
    }

    func load() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.readPrivateLogFinished()
            }
        }
        isLoaded = true
    }

    private func readPrivateLogFinished() {
        chatView.scrollBottom()
        chatView.autoScroll = true
    }

    private func prependOldMessages() {
        guard let folderPath = log.privateChatFolderPath else {
            return
        }

        let logLines = log.readLog(folderPath: folderPath, basename: user,
                                   numLines: config.logging.readPrivateLines) ?? []
        chatView.appendLogLines(logLines, loginUsername: config.server.login)
    }

    func serverDisconnect() {
        isOfflineMessageShown = false
        chatView.updateUserTags()
    }

    func clear() {
        chatView.clear()
        chats.unhighlightUser(user)
    }

    private func onPopupMenuChat(_ menu: PopupMenu) {
        popupMenuUserTab.toggleUserItems()
        menu.setEnabled(String(localized: "Copy"), chatView.hasSelection)
        menu.setEnabled(String(localized: "Copy Link"), !chatView.urlForCurrentPosition.isEmpty)
    }

    func toggleChatButtons() {
        isLogToggleVisible = !config.logging.privateChat
        isSpeechToggleVisible = config.ui.speechEnabled
    }

    private func onLogToggled() {
        if !isLogEnabled {
            config.logging.privateChats.removeAll { $0 == user }
            return
        }

        if !config.logging.privateChats.contains(user) {
            config.logging.privateChats.append(user)
        }
    }

    private func onViewChatLog() {
        guard let folderPath = log.privateChatFolderPath else {
            return
        }
        _ = openFilePath(log.logFileURL(folderPath: folderPath, basename: user).path, createFile: true)
    }

    private func onDeleteChatLog() {
        OptionDialog(
            title: String(localized: "Delete Logged Messages?"),
            message: String(localized: "Do you really want to permanently delete all logged messages for this user?"),
            destructiveResponse: "ok"
        ) { [weak self] _, _ in
            guard let self, let folderPath = log.privateChatFolderPath else {
                return
            }

            log.deleteLog(folderPath: folderPath, basename: user)
            chats.history.removeUser(user)
            chatView.clear()
        }.present()
    }

    private func showNotification(_ text: String, isMentioned: Bool = false) {
        let isBuddy = core.buddies.users[user] != nil

        chats.notebook.requestTabChanged(self, isImportant: isBuddy || isMentioned)

        if chats.notebook.currentPage === self && window.currentPage == .private && window.isActive {
            // Don't show notifications if the chat is open and the window is in use
            return
        }

        // Show urgency hint
        chats.highlightUser(user)

        if config.notifications.popupPrivateMessage {
            core.notifications?.showPrivateChatNotification(username: user, message: text,
                                                            title: String(localized: "Private Message from \(user)"))
        }
    }

    func messageUser(_ msg: MessageUser) {
        let isOutgoingMessage = (msg.messageID == nil)
        let isNewMessage = msg.isNewMessage
        let messageType = msg.chatMessageType
        let username = msg.user
        let tagUsername = isOutgoingMessage ? (core.users.loginUsername ?? username) : username
        let userTag = chatView.userTag(tagUsername)
        let timestamp = isNewMessage ? nil : Date(timeIntervalSince1970: TimeInterval(msg.timestamp))
        let timestampFormat = config.logging.privateTimestamp
        let message = msg.message
        let formattedMessage = msg.formattedMessage ?? message

        if !isOutgoingMessage {
            showNotification(message, isMentioned: messageType == "hilite")

            if isSpeechEnabled {
                core.notifications?.newTTS(config.ui.speechPrivate, args: ["user": tagUsername, "message": message])
            }
        }

        if !isOutgoingMessage && !isNewMessage {
            if !isOfflineMessageShown {
                chatView.appendLine(String(localized: "* Messages sent while you were offline"), messageType: "hilite",
                                    timestampFormat: timestampFormat)
                isOfflineMessageShown = true
            }
        } else {
            isOfflineMessageShown = false
        }

        chatView.appendLine(formattedMessage, messageType: messageType, timestamp: timestamp,
                            timestampFormat: timestampFormat, username: tagUsername, userTag: userTag)
        chats.history.updateUser(username, message: formattedMessage)
    }

    func echoPrivateMessage(_ text: String, messageType: String) {
        let timestampFormat = (messageType != "command") ? config.logging.privateTimestamp : nil
        chatView.appendLine(text, messageType: messageType, timestampFormat: timestampFormat)
    }

    private func usernameEvent(_ username: String) {
        popupMenuUserChat.setUser(username)
        popupMenuUserChat.toggleUserItems()
        popupMenuUserChat.popupAtMouseLocation()
    }

    func onFocus() -> Bool {
        if window.currentPage == .private {
            if chats.chatEntry.isSensitive {
                chats.chatEntry.grabFocus()
            } else {
                chatView.grabFocus()
            }
        }
        return true
    }

    func onClose() {
        core.privateChat.removeUser(user)
    }

    func updateRoomUserCompletions() {
        updateCompletions(core.privateChat.completions)
    }

    func updateCompletions(_ completions: Set<String>) {
        // Tab-complete the recipient username
        var completions = completions
        completions.insert(user)
        chats.chatEntry.setCompletions(completions)
    }
}

// MARK: - Chat History

/// List of users with previous private conversations.
@MainActor
final class ChatHistory {

    let listView: TreeView

    init(onShowUser: @escaping @MainActor () -> Void) {
        listView = TreeView(
            columns: [
                TreeColumn(id: "status", title: String(localized: "Status"), kind: .icon, width: 25, hidesHeader: true),
                TreeColumn(id: "user", title: String(localized: "User"), width: 175, isIteratorKey: true),
                TreeColumn(id: "latest_message", title: String(localized: "Latest Message")),

                // Hidden data columns
                .data("timestamp_data", sortOrder: .descending)
            ],
            activateRow: { treeView, row, _ in
                core.privateChat.showUser(treeView.rowValue(row, "user").string)
                onShowUser()
            }
        )

        loadUsers()

        events.connect(.serverLogin) { [unowned self] in serverLogin($0) }
        events.connect(.serverDisconnect) { [unowned self] _ in serverDisconnect() }
        events.connectMessage(.userStatus) { [unowned self] in userStatus($0) }
    }

    /// Usernames in the history, suggested in the username entry
    var usernames: [String] {
        listView.iterators.keys.map(\.string).sorted()
    }

    private func serverLogin(_ msg: Login) {
        guard msg.success else {
            return
        }

        for row in listView.iterators.values {
            core.users.watchUser(listView.rowValue(row, "user").string, context: "chathistory")
        }
    }

    private func serverDisconnect() {
        for row in listView.iterators.values {
            listView.setRowValue(row, "status", .string(Theme.userStatusIconName(.offline)))
        }
    }

    /// Reads the username and latest message from a given log file.
    ///
    /// Usernames are first extracted from the file name. In case the extracted
    /// username contains underscores, attempt to fetch the original username
    /// from logged messages, since illegal filename characters are substituted
    /// with underscores.
    private static func loadUser(_ fileURL: URL) throws -> (username: String, latestMessage: String?, timestamp: Date) {
        var username = fileURL.deletingPathExtension().lastPathComponent
        let isSafeUsername = !username.contains("_")
        let loginUsername = config.server.login
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let timestamp = attributes[.modificationDate] as? Date ?? Date()
        let readNumLines = isSafeUsername ? 1 : 25
        let data = try Data(contentsOf: fileURL)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(readNumLines).map(String.init)
        var latestMessage: String?
        let usernameCharacters = Set(username.replacingOccurrences(of: "_", with: ""))

        for line in lines {
            if latestMessage == nil {
                latestMessage = line

                if isSafeUsername {
                    break
                }
            }

            if line.contains(loginUsername) {
                continue
            }

            guard let startRange = line.range(of: " ["),
                  let endRange = line.range(of: "] ", range: startRange.upperBound..<line.endIndex) else {
                continue
            }

            let lineUsername = String(line[startRange.upperBound..<endRange.lowerBound])

            guard lineUsername.count == username.count else {
                continue
            }

            if username == lineUsername {
                // Nothing to do, username is already correct
                break
            }

            if usernameCharacters.isSubset(of: Set(lineUsername)) {
                username = lineUsername
                break
            }
        }

        return (username, latestMessage, timestamp)
    }

    private func loadUsers() {
        guard let folderPath = log.privateChatFolderPath,
              let fileURLs = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: folderPath), includingPropertiesForKeys: nil) else {
            return
        }

        listView.freeze()

        for fileURL in fileURLs where fileURL.pathExtension == "log" {
            guard let (username, latestMessage, timestamp) = try? Self.loadUser(fileURL), let latestMessage else {
                continue
            }

            updateUser(username, message: latestMessage.trimmingCharacters(in: .whitespacesAndNewlines),
                       timestamp: timestamp)
        }

        listView.unfreeze()
    }

    func removeUser(_ username: String) {
        if let row = listView.iterators[.string(username)] {
            listView.removeRow(row)
        }
    }

    func updateUser(_ username: String, message: String, timestamp: Date? = nil) {
        removeUser(username)
        core.users.watchUser(username, context: "chathistory")

        var message = message
        let timestamp = timestamp ?? {
            message = "\(formatTimestamp(config.logging.logTimestamp)) \(message)"
            return Date()
        }()

        let status = core.users.statuses[username] ?? .offline

        listView.addRow([
            .string(Theme.userStatusIconName(status)),
            .string(username),
            .string(message),
            .int(Int(timestamp.timeIntervalSince1970))
        ], selectRow: false)
    }

    private func userStatus(_ msg: GetUserStatus) {
        guard let row = listView.iterators[.string(msg.user)], let status = UserStatus(rawValue: msg.status) else {
            return
        }

        let statusIconName = Theme.userStatusIconName(status)

        if statusIconName != listView.rowValue(row, "status").string {
            listView.setRowValue(row, "status", .string(statusIconName))
        }
    }
}

// MARK: - Views

/// Private chat page.
struct PrivateChatsView: View {

    @Bindable var page: PrivateChatsPage

    private var hasTabs: Bool { !page.notebook.pages.isEmpty }

    private var entryBar: some View {
        HStack(spacing: 6) {
            SearchField(placeholder: String(localized: "Username…"), text: $page.usernameText,
                        recentTitle: String(localized: "Chat History"), recentItems: page.history.usernames, completions: page.history.usernames, focusRequest: page.usernameFocusRequest) {
                page.onGetPrivateChat()
            }

            Button {
                page.isHistoryShown.toggle()
            } label: {
                Label(String(localized: "Chat History"), systemImage: "clock.arrow.circlepath")
                    .labelStyle(.titleAndIcon)
            }
            .popover(isPresented: $page.isHistoryShown) {
                page.history.listView.view
                    .frame(width: 700, height: 500)
            }
        }
    }

    var body: some View {
        Group {
            if hasTabs {
                NotebookView(notebook: page.notebook)
            } else {
                PageStart(
                    systemImage: "envelope",
                    title: String(localized: "Private Chat"),
                    description: String(localized: "Enter the name of a user to start a text conversation with them in private"),
                    recentTitle: String(localized: "Chat History"),
                    recentItems: page.history.usernames,
                    onSelectItem: { username in
                        page.usernameText = username
                        page.onGetPrivateChat()
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

            ToolbarItem {
                Button {
                    Application.shared.onConfigureChats()
                } label: {
                    Label(String(localized: "Configure Chats"), systemImage: "gearshape")
                }
                .help(String(localized: "Configure Chats"))
            }
        }
    }
}

/// Conversation with a single user.
struct PrivateChatTabView: View {

    @Bindable var tab: PrivateChatTab

    var body: some View {
        VStack(spacing: 0) {
            tab.chatView.view

            Divider()

            ChatEntryBar(chatEntry: tab.chats.chatEntry, interface: .privateChat,
                         helpTooltip: String(localized: "Private Chat Command Help")) {
                if tab.isLogToggleVisible {
                    Toggle(isOn: $tab.isLogEnabled) {
                        Image(systemName: "doc.text")
                    }
                    .toggleStyle(.button)
                    .help(String(localized: "Log"))
                }

                if tab.isSpeechToggleVisible {
                    Toggle(isOn: $tab.isSpeechEnabled) {
                        Image(systemName: "speaker.wave.2")
                    }
                    .toggleStyle(.button)
                    .help(String(localized: "Toggle Text-to-Speech"))
                }
            }
        }
    }
}

/// Chat entry with a send button, command help and additional buttons.
struct ChatEntryBar<Buttons: View>: View {

    let chatEntry: ChatEntry
    let interface: CommandInterface
    let helpTooltip: String
    @ViewBuilder var buttons: Buttons
    @State private var isCommandHelpShown = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                chatEntry.onSendMessage()
            } label: {
                Image(systemName: "paperplane")
            }
            .buttonStyle(.borderless)

            AppKitView(chatEntry.textField)
                .frame(height: 22)

            buttons

            Button {
                isCommandHelpShown.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help(helpTooltip)
            .popover(isPresented: $isCommandHelpShown) {
                ChatCommandHelp(interface: interface)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// List of available chat commands.
struct ChatCommandHelp: View {

    let interface: CommandInterface

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let groups = core.pluginHandler?.commandGroupsData(for: interface) ?? OrderedDictionary()

                ForEach(Array(groups.keys.enumerated()), id: \.offset) { _, groupName in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(groupName)
                            .font(.headline)

                        ForEach(Array((groups[groupName] ?? []).enumerated()), id: \.offset) { _, command in
                            HStack(alignment: .top, spacing: 12) {
                                Text("/\(([command.command] + command.aliases).joined(separator: ", /")) \(command.parameters.joined(separator: " "))"
                                    .trimmingCharacters(in: .whitespaces))
                                    .italic()
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(command.description)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 600, height: 450)
    }
}
