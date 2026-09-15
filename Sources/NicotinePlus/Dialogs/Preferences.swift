// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import NicotineCore
import Observation
import SwiftUI

/// Preferences dialog. Pages edit a working copy of the settings, which is
/// applied when pressing Apply or OK.
@MainActor
@Observable
final class Preferences {

    struct PageInfo: Identifiable {
        let id: String
        let title: String
        let systemImage: String
    }

    static let languages: [(code: String, name: String)] = [
        ("ca", "Català"),
        ("cs", "Čeština"),
        ("de", "Deutsch"),
        ("en", "English"),
        ("es_CL", "Español (Chile)"),
        ("es_ES", "Español (España)"),
        ("et", "Eesti"),
        ("fr", "Français"),
        ("hu", "Magyar"),
        ("it", "Italiano"),
        ("lv", "Latviešu"),
        ("nl", "Nederlands"),
        ("pl", "Polski"),
        ("pt_BR", "Português (Brasil)"),
        ("pt_PT", "Português (Portugal)"),
        ("ru", "Русский"),
        ("ta", "தமிழ்"),
        ("tr", "Türkçe"),
        ("uk", "Українська"),
        ("zh_CN", "汉语")
    ]

    static let formatCodesURL = "https://docs.python.org/3/library/datetime.html#format-codes"

    static let defaultNowPlayingFormats = [
        "$n",
        "$n ($f)",
        "/me np: $n",
        "$a - $t",
        "[$a] $t",
        "$a - $b - $t",
        "$a - $b - $t ($l/$r KBps) from $y $c"
    ]

    static let defaultURLProtocols = [
        "http://", "https://", "audio", "image", "video", "document", "text", "archive", ".mp3", ".jpg", ".pdf"
    ]

    static let defaultURLCommands = [
        "xdg-open $",
        "firefox $",
        "firefox --new-tab $",
        "epiphany $",
        "chromium-browser $",
        "falkon $",
        "links -g $",
        "dillo $",
        "konqueror $",
        "\"c:\\Program Files\\Mozilla Firefox\\Firefox.exe\" $"
    ]

    static let fileManagerCommands = [
        "", "xdg-open $", "explorer $", "nautilus $", "nemo $", "caja $", "thunar $", "dolphin $", "konqueror $",
        "krusader --left $", "xterm -e mc $"
    ]

    @ObservationIgnored let application: Application
    @ObservationIgnored private var dialog: DialogWindow!

    let pages: [PageInfo]
    var activePageID = "network"

    /// Working copy of the settings
    var draft = NicotineCore.Settings()
    let defaults = NicotineCore.Settings()

    // Network page
    var serverAddress = ""
    var listenPort = 2234
    private(set) var networkInterfaces: [String] = []
    private(set) var publicAddressText = String(localized: "Unknown")
    private(set) var portCheckerURL: String?

    // Downloads page
    @ObservationIgnored private(set) var downloadFilterListView: TreeView!
    private(set) var filterStatusText = String(localized: "Unverified")

    // Shares page
    @ObservationIgnored private(set) var sharesListView: TreeView!
    @ObservationIgnored private var lastParentFolder: String?

    // Banned and ignored users pages
    @ObservationIgnored private(set) var bannedUsersListView: TreeView!
    @ObservationIgnored private(set) var bannedIPsListView: TreeView!
    @ObservationIgnored private(set) var ignoredUsersListView: TreeView!
    @ObservationIgnored private(set) var ignoredIPsListView: TreeView!
    @ObservationIgnored private var bannedChanges = UserChanges()
    @ObservationIgnored private var ignoredChanges = UserChanges()
    var geoBlockCountryCodes = ""

    // Chats page
    @ObservationIgnored private(set) var censorListView: TreeView!
    @ObservationIgnored private(set) var replacementListView: TreeView!
    var isCTCPEnabled = false

    // Searches page
    private(set) var isSearchHistoryCleared = false
    private(set) var isFilterHistoryCleared = false

    // URL handlers page
    @ObservationIgnored private(set) var protocolListView: TreeView!

    // Now playing page
    private(set) var nowPlayingOutput = ""

    // Plugins page
    @ObservationIgnored private(set) var pluginListView: TreeView!
    @ObservationIgnored private(set) var pluginDescriptionView: TextView!
    private(set) var selectedPlugin: String?
    private(set) var selectedPluginInfo: PluginInfo?
    private(set) var isPluginSettingsEnabled = false
    @ObservationIgnored private var pluginSettingsDialog: PluginSettingsDialog?

    /// Changes to banned or ignored users, applied through the network filter
    private struct UserChanges {
        var addedUsers = Set<String>()
        var removedUsers = Set<String>()
        var addedIPs = Set<[String]>()
        var removedIPs = Set<[String]>()
    }

    init(application: Application) {
        self.application = application

        var pages = [
            PageInfo(id: "network", title: String(localized: "Network"), systemImage: "network"),
            PageInfo(id: "user-interface", title: String(localized: "User Interface"), systemImage: "square.grid.2x2"),
            PageInfo(id: "shares", title: String(localized: "Shares"), systemImage: "folder"),
            PageInfo(id: "downloads", title: String(localized: "Downloads"), systemImage: "arrow.down.circle"),
            PageInfo(id: "uploads", title: String(localized: "Uploads"), systemImage: "arrow.up.circle"),
            PageInfo(id: "searches", title: String(localized: "Searches"), systemImage: "magnifyingglass"),
            PageInfo(id: "user-profile", title: String(localized: "User Profile"), systemImage: "person.crop.circle"),
            PageInfo(id: "chats", title: String(localized: "Chats"), systemImage: "text.bubble"),
            PageInfo(id: "now-playing", title: String(localized: "Now Playing"), systemImage: "music.note"),
            PageInfo(id: "logging", title: String(localized: "Logging"), systemImage: "doc.text"),
            PageInfo(id: "banned-users", title: String(localized: "Banned Users"), systemImage: "nosign"),
            PageInfo(id: "ignored-users", title: String(localized: "Ignored Users"), systemImage: "speaker.slash"),
            PageInfo(id: "url-handlers", title: String(localized: "URL Handlers"), systemImage: "link"),
            PageInfo(id: "plugins", title: String(localized: "Plugins"), systemImage: "puzzlepiece.extension")
        ]

        if application.isolatedMode {
            pages.removeAll { $0.id == "url-handlers" }
        }

        self.pages = pages

        createListViews()

        dialog = DialogWindow(title: String(localized: "Preferences"), width: 960, height: 650) { [unowned self] in
            PreferencesView(preferences: self)
        }

        events.connect(.serverLogin) { [unowned self] _ in updatePortLabel() }
        events.connect(.serverDisconnect) { [unowned self] _ in updatePortLabel() }
    }

    func present() {
        dialog.present()
    }

    func close() {
        dialog.close()
    }

    func setActivePage(_ pageID: String) {
        activePageID = pageID
    }

    // MARK: List Views

    private func createListViews() {
        downloadFilterListView = TreeView(
            columns: [
                TreeColumn(id: "filter", title: String(localized: "Filter"), width: 150, expandsColumn: true,
                           defaultSortOrder: .ascending),
                TreeColumn(id: "regex", title: String(localized: "Regex"), kind: .toggle, width: 0,
                           toggleCallback: { [unowned self] listView, row in
                               listView.setRowValue(row, "regex", .bool(!listView.rowValue(row, "regex").bool))
                               onVerifyFilter()
                           })
            ],
            multiSelect: true,
            activateRow: { [unowned self] _, _, _ in onEditFilter() },
            deleteAccelerator: { [unowned self] _ in onRemoveFilter() }
        )

        sharesListView = TreeView(
            columns: [
                TreeColumn(id: "virtual_name", title: String(localized: "Virtual Folder"), width: 65,
                           expandsColumn: true, defaultSortOrder: .ascending),
                TreeColumn(id: "folder", title: String(localized: "Folder"), width: 150, expandsColumn: true),
                TreeColumn(id: "accessible_to", title: String(localized: "Accessible To"), width: 0)
            ],
            multiSelect: true,
            activateRow: { [unowned self] _, _, _ in onEditSharedFolder() },
            deleteAccelerator: { [unowned self] _ in onRemoveSharedFolder() }
        )

        func userListView(delete: @escaping @MainActor () -> Void) -> TreeView {
            TreeView(
                columns: [TreeColumn(id: "username", title: String(localized: "Username"), defaultSortOrder: .ascending)],
                multiSelect: true, deleteAccelerator: { _ in delete() }
            )
        }

        func ipListView(delete: @escaping @MainActor () -> Void) -> TreeView {
            TreeView(
                columns: [
                    TreeColumn(id: "ip_address", title: String(localized: "IP Address"), width: 50, expandsColumn: true),
                    TreeColumn(id: "user", title: String(localized: "User"), expandsColumn: true,
                               defaultSortOrder: .ascending)
                ],
                multiSelect: true, deleteAccelerator: { _ in delete() }
            )
        }

        bannedUsersListView = userListView { [unowned self] in onRemoveBannedUser() }
        bannedIPsListView = ipListView { [unowned self] in onRemoveBannedIP() }
        ignoredUsersListView = userListView { [unowned self] in onRemoveIgnoredUser() }
        ignoredIPsListView = ipListView { [unowned self] in onRemoveIgnoredIP() }

        censorListView = TreeView(
            columns: [TreeColumn(id: "pattern", title: String(localized: "Pattern"), defaultSortOrder: .ascending)],
            multiSelect: true,
            activateRow: { [unowned self] _, _, _ in onEditCensored() },
            deleteAccelerator: { [unowned self] _ in onRemoveCensored() }
        )

        replacementListView = TreeView(
            columns: [
                TreeColumn(id: "pattern", title: String(localized: "Pattern"), width: 100, expandsColumn: true,
                           defaultSortOrder: .ascending),
                TreeColumn(id: "replacement", title: String(localized: "Replacement"), expandsColumn: true)
            ],
            multiSelect: true,
            activateRow: { [unowned self] _, _, _ in onEditReplacement() },
            deleteAccelerator: { [unowned self] _ in onRemoveReplacement() }
        )

        protocolListView = TreeView(
            columns: [
                TreeColumn(id: "protocol", title: String(localized: "Protocol"), width: 120, expandsColumn: true,
                           defaultSortOrder: .ascending, isIteratorKey: true),
                TreeColumn(id: "command", title: String(localized: "Command"), expandsColumn: true)
            ],
            multiSelect: true,
            activateRow: { [unowned self] _, _, _ in onEditHandler() },
            deleteAccelerator: { [unowned self] _ in onRemoveHandler() }
        )

        pluginListView = TreeView(
            columns: [
                TreeColumn(id: "enabled", title: String(localized: "Enabled"), kind: .toggle, width: 0,
                           hidesHeader: true,
                           toggleCallback: { [unowned self] listView, row in onPluginToggle(listView, row) }),
                TreeColumn(id: "plugin", title: String(localized: "Plugin"), defaultSortOrder: .ascending),

                // Hidden data columns
                .data("plugin_id", isIteratorKey: true)
            ],
            activateRow: { [unowned self] _, _, columnID in
                if columnID == "plugin" {
                    onPluginSettings()
                }
            },
            selectRow: { [unowned self] listView, row in onSelectPlugin(listView, row) }
        )

        pluginDescriptionView = TextView(isEditable: false, paragraphSpacing: 2)
    }

    // MARK: Loading Settings

    func setSettings() {
        draft = config.settings

        // Network page
        networkInterfaces = [""] + NetworkInterfaces.interfaceAddresses().keys.sorted()
        serverAddress = "\(draft.server.server.host):\(draft.server.server.port)"
        listenPort = draft.server.portRange.lowerBound
        updatePortLabel()

        // Downloads page
        downloadFilterListView.clear()
        downloadFilterListView.freeze()

        for filter in draft.transfers.downloadFilters {
            downloadFilterListView.addRow([.string(filter.pattern), .bool(!filter.isEscaped)], selectRow: false)
        }

        downloadFilterListView.unfreeze()

        // Shares page
        populateShares()

        // Banned and ignored users pages
        bannedChanges = UserChanges()
        ignoredChanges = UserChanges()
        populateUserList(bannedUsersListView, draft.server.banList)
        populateIPList(bannedIPsListView, draft.server.ipBlockList)
        populateUserList(ignoredUsersListView, draft.server.ignoreList)
        populateIPList(ignoredIPsListView, draft.server.ipIgnoreList)
        geoBlockCountryCodes = draft.transfers.geoBlockCountryCodes.first ?? ""

        // Chats page
        isCTCPEnabled = !draft.server.ctcpMessages
        censorListView.clear()
        censorListView.freeze()

        for pattern in draft.words.censored {
            censorListView.addRow([.string(pattern)], selectRow: false)
        }

        censorListView.unfreeze()
        replacementListView.clear()
        replacementListView.freeze()

        for (pattern, replacement) in draft.words.autoReplaced {
            replacementListView.addRow([.string(pattern), .string(replacement)], selectRow: false)
        }

        replacementListView.unfreeze()

        // Searches page
        isSearchHistoryCleared = false
        isFilterHistoryCleared = false

        // URL handlers page
        protocolListView.clear()
        protocolListView.freeze()

        for (urlProtocol, command) in draft.urls.protocols {
            protocolListView.addRow([.string(urlProtocol), .string(command)], selectRow: false)
        }

        protocolListView.unfreeze()

        // Plugins page
        pluginListView.clear()
        pluginListView.freeze()

        if let pluginHandler = core.pluginHandler {
            for pluginID in pluginHandler.installedPlugins() {
                let name = pluginHandler.pluginInfo(pluginID)?.name ?? pluginID
                let isEnabled = draft.plugins.enabled.contains(pluginID)

                pluginListView.addRow([.bool(isEnabled), .string(name), .string(pluginID)], selectRow: false)
            }
        }

        pluginListView.unfreeze()
        onSelectPlugin(pluginListView, nil)
    }

    private func populateUserList(_ listView: TreeView, _ users: [String]) {
        listView.clear()
        listView.freeze()

        for user in users {
            listView.addRow([.string(user)], selectRow: false)
        }

        listView.unfreeze()
    }

    private func populateIPList(_ listView: TreeView, _ addresses: [String: String]) {
        listView.clear()
        listView.freeze()

        for (ipAddress, user) in addresses {
            listView.addRow([.string(ipAddress), .string(user)], selectRow: false)
        }

        listView.unfreeze()
    }

    private func updatePortLabel() {
        let unknownLabel = String(localized: "Unknown")

        guard let publicPort = core.users.publicPort, publicPort > 0 else {
            publicAddressText = unknownLabel
            portCheckerURL = nil
            return
        }

        publicAddressText = String(localized: "\(core.users.publicIPAddress ?? unknownLabel), port \(String(publicPort))")
        portCheckerURL = application.isolatedMode
            ? nil : NicotineCore.Application.portCheckerURL(port: publicPort)
    }

    // MARK: Applying Settings

    private func collectSettings() -> NicotineCore.Settings {
        var settings = draft

        // Network page
        let addressParts = serverAddress.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }

        if addressParts.count == 2, let port = Int(addressParts[1]) {
            settings.server.server = ServerAddress(host: addressParts[0], port: port)
        } else {
            settings.server.server = defaults.server.server
        }

        settings.server.portRange = listenPort...listenPort

        // Downloads page
        settings.transfers.downloadFilters = downloadFilterListView.iterators.values.map { row in
            DownloadFilter(pattern: downloadFilterListView.rowValue(row, "filter").string,
                           isEscaped: !downloadFilterListView.rowValue(row, "regex").bool)
        }
        settings.transfers.afterFinish = settings.transfers.afterFinish.trimmingCharacters(in: .whitespaces)
        settings.transfers.afterFolder = settings.transfers.afterFolder.trimmingCharacters(in: .whitespaces)

        // Banned users page
        settings.transfers.geoBlockCountryCodes = [geoBlockCountryCodes.uppercased()]

        // Chats page
        settings.server.ctcpMessages = !isCTCPEnabled
        settings.words.censored = censorListView.iterators.keys.map(\.string)
        settings.words.autoReplaced = Dictionary(uniqueKeysWithValues: replacementListView.iterators.values.map {
            (replacementListView.rowValue($0, "pattern").string, replacementListView.rowValue($0, "replacement").string)
        })
        settings.ui.speechCommand = settings.ui.speechCommand.trimmingCharacters(in: .whitespaces)

        // URL handlers page
        settings.urls.protocols = Dictionary(uniqueKeysWithValues: protocolListView.iterators.values.map {
            (protocolListView.rowValue($0, "protocol").string, protocolListView.rowValue($0, "command").string)
        })
        settings.ui.fileManager = settings.ui.fileManager.trimmingCharacters(in: .whitespaces)

        // Now playing page
        let nowPlayingFormat = settings.players.npFormat

        if !nowPlayingFormat.trimmingCharacters(in: .whitespaces).isEmpty,
           !settings.players.npFormatList.contains(nowPlayingFormat),
           !Self.defaultNowPlayingFormats.contains(nowPlayingFormat) {
            settings.players.npFormatList.append(nowPlayingFormat)
        }

        // Managed through the network filter and plugin handler
        settings.server.banList = config.server.banList
        settings.server.ipBlockList = config.server.ipBlockList
        settings.server.ignoreList = config.server.ignoreList
        settings.server.ipIgnoreList = config.server.ipIgnoreList
        settings.plugins.enabled = config.plugins.enabled
        settings.plugins.settings = config.plugins.settings

        // State managed elsewhere, which may have changed while the dialog was open
        settings.columns = config.settings.columns
        settings.searches.history = config.searches.history
        settings.statistics = config.statistics
        settings.ui.lastTabID = config.ui.lastTabID
        settings.ui.modesOrder = config.ui.modesOrder
        settings.server.userList = config.server.userList
        settings.server.autoJoin = config.server.autoJoin
        settings.server.autoSearch = config.server.autoSearch
        settings.privateChat.users = config.privateChat.users
        settings.transfers.downloadsExpanded = config.transfers.downloadsExpanded
        settings.transfers.uploadsExpanded = config.transfers.uploadsExpanded
        settings.transfers.groupDownloads = config.transfers.groupDownloads
        settings.transfers.groupUploads = config.transfers.groupUploads
        settings.logging.debugModes = config.logging.debugModes
        settings.logging.logCollapsed = config.logging.logCollapsed
        settings.logging.privateChats = config.logging.privateChats
        settings.logging.rooms = config.logging.rooms

        return settings
    }

    func updateSettings(isClosing: Bool = false) {
        let settings = collectSettings()
        let current = config.settings

        let isReconnectRequired = settings.server.login != current.server.login
            || settings.server.portRange != current.server.portRange
            || settings.server.interface != current.server.interface
            || settings.server.server != current.server.server
        let isPortmapChanged = settings.server.upnp != current.server.upnp
        let isRescanRequired = settings.transfers.shared != current.transfers.shared
            || settings.transfers.buddyShared != current.transfers.buddyShared
            || settings.transfers.trustedShared != current.transfers.trustedShared
        let isRecompressSharesRequired = settings.transfers.revealBuddyShares != current.transfers.revealBuddyShares
            || settings.transfers.revealTrustedShares != current.transfers.revealTrustedShares
        let isUserProfileRequired = settings.userInfo.description != current.userInfo.description
            || settings.userInfo.picture != current.userInfo.picture
        let isCompletionRequired = Self.completionOptions(settings.words) != Self.completionOptions(current.words)
        let isPrivateRoomRequired = settings.server.privateChatrooms != current.server.privateChatrooms
        let isSearchHistoryRequired = settings.searches.enableHistory != current.searches.enableHistory
        let isLanguageChanged = settings.ui.language != current.ui.language

        config.settings = settings

        applyUserChanges()

        if isReconnectRequired {
            core.reconnect()
        }

        if isPortmapChanged {
            if settings.server.upnp {
                core.portmapper?.addPortMapping()
            } else {
                core.portmapper?.removePortMapping()
            }
        }

        if isUserProfileRequired {
            core.userInfo.showUser(refresh: true, switchPage: false)
        }

        if isPrivateRoomRequired {
            application.window.chatrooms.roomList.isPrivateRoomsAccepted = settings.server.privateChatrooms
        }

        if isCompletionRequired {
            core.chatrooms.updateCompletions()
            core.privateChat.updateCompletions()
        }

        if isSearchHistoryRequired {
            application.window.search.populateSearchHistory()
        }

        if isRecompressSharesRequired && !isRescanRequired {
            core.shares.rescanShares(initializing: true, rescan: false)
        }

        if isLanguageChanged {
            // Applied when the application is restarted
            if settings.ui.language.isEmpty {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([settings.ui.language.replacingOccurrences(of: "_", with: "-")],
                                          forKey: "AppleLanguages")
            }
        }

        // Dark mode
        NSApp.appearance = settings.ui.darkMode ? NSAppearance(named: .darkAqua) : nil

        // Chats
        application.window.chatrooms.updateWidgets()
        application.window.privateChat.updateWidgets()

        // Buddies
        application.window.buddies.setBuddyListPosition()

        // Transfers
        core.downloads.updateTransferLimits()
        core.downloads.updateDownloadFilters()
        core.uploads.updateTransferLimits()

        // Logging
        log.applyConfig()

        // Main window
        application.window.setMainTabsVisibility()

        // Update configuration
        config.writeConfiguration()

        guard isClosing else {
            return
        }

        close()

        if isRescanRequired {
            core.shares.rescanShares()
        }

        if config.needsConfig {
            core.setup()
        }
    }

    private static func completionOptions(_ words: WordsSettings) -> [Int] {
        let toggles = [words.tab, words.dropdown, words.roomNames, words.buddies, words.roomUsers, words.commands]
        return toggles.map { $0 ? 1 : 0 } + [words.characters]
    }

    private func applyUserChanges() {
        let networkFilter = core.networkFilter

        for username in bannedChanges.addedUsers {
            networkFilter.banUser(username)
        }
        for pair in bannedChanges.addedIPs {
            _ = networkFilter.banUserIP(username: pair[0].isEmpty ? nil : pair[0], ipAddress: pair[1])
        }
        for username in bannedChanges.removedUsers {
            networkFilter.unbanUser(username)
        }
        for pair in bannedChanges.removedIPs {
            _ = networkFilter.unbanUserIP(username: pair[0].isEmpty ? nil : pair[0], ipAddress: pair[1])
        }

        for username in ignoredChanges.addedUsers {
            networkFilter.ignoreUser(username)
        }
        for pair in ignoredChanges.addedIPs {
            _ = networkFilter.ignoreUserIP(username: pair[0].isEmpty ? nil : pair[0], ipAddress: pair[1])
        }
        for username in ignoredChanges.removedUsers {
            networkFilter.unignoreUser(username)
        }
        for pair in ignoredChanges.removedIPs {
            _ = networkFilter.unignoreUserIP(username: pair[0].isEmpty ? nil : pair[0], ipAddress: pair[1])
        }

        bannedChanges = UserChanges()
        ignoredChanges = UserChanges()
    }

    func onBackUpConfig() {
        let currentDateTime = formatTimestamp("%Y-%m-%d_%H-%M-%S")

        FileChooser.saveFile(
            title: String(localized: "Pick a File Name for Config Backup"),
            initialFolder: (config.configFilePath as NSString).deletingLastPathComponent,
            initialFile: "config_backup_\(currentDateTime).tar.bz2"
        ) { filePaths in
            if let filePath = filePaths.first {
                config.writeConfigBackup(to: filePath)
            }
        }
    }

    // MARK: Network Page

    func onChangePassword() {
        let message: String

        if core.users.loginStatus != .offline {
            message = String(localized: "Enter a new password for your Soulseek account:")
        } else {
            message = String(localized: "You are currently logged out of the Soulseek network. If you want to change the password of an existing Soulseek account, you need to be logged into that account.")
                + "\n\n" + String(localized: "Enter password to use when logging in:")
        }

        let userStatus = core.users.loginStatus

        EntryDialog(
            title: String(localized: "Change Password"),
            message: message,
            actionButtonLabel: String(localized: "Change"),
            isVisible: false
        ) { [weak self] dialog, _ in
            let password = (dialog as? EntryDialog)?.entryValue ?? ""

            if userStatus != core.users.loginStatus {
                MessageDialog(
                    title: String(localized: "Password Change Rejected"),
                    message: String(localized: "Since your login status changed, your password has not been changed. Please try again.")
                ).present()
                return
            }

            if password.isEmpty {
                self?.onChangePassword()
                return
            }

            if core.users.loginStatus == .offline {
                config.server.password = password
                config.writeConfiguration()
                return
            }

            core.users.requestChangePassword(password)
        }.present()
    }

    func onDefaultServer() {
        serverAddress = "\(defaults.server.server.host):\(defaults.server.server.port)"
    }

    // MARK: Downloads Page

    private var filterSyntaxDescription: String {
        String(localized: "Syntax: Case-insensitive. If enabled, Python regular expressions can be used, otherwise only wildcard * matches are supported.")
    }

    func onAddFilter() {
        EntryDialog(
            title: String(localized: "Add Download Filter"),
            message: filterSyntaxDescription + "\n\n" + String(localized: "Enter a new download filter:"),
            actionButtonLabel: String(localized: "Add"),
            droplist: downloadFilterListView.iterators.keys.map(\.string),
            optionLabel: String(localized: "Enable regular expressions")
        ) { [weak self] dialog, _ in
            guard let self, let dialog = dialog as? EntryDialog else {
                return
            }

            let filter = dialog.entryValue
            let isRegexEnabled = dialog.optionValue ?? false

            if let row = downloadFilterListView.iterators[.string(filter)] {
                downloadFilterListView.setRowValue(row, "regex", .bool(isRegexEnabled))
            } else {
                downloadFilterListView.addRow([.string(filter), .bool(isRegexEnabled)])
            }

            onVerifyFilter()
        }.present()
    }

    func onEditFilter() {
        guard let row = downloadFilterListView.selectedRows.first else {
            return
        }

        let filter = downloadFilterListView.rowValue(row, "filter").string
        let isRegexEnabled = downloadFilterListView.rowValue(row, "regex").bool

        EntryDialog(
            title: String(localized: "Edit Download Filter"),
            message: filterSyntaxDescription + "\n\n" + String(localized: "Modify the following download filter:"),
            defaultText: filter,
            actionButtonLabel: String(localized: "Edit"),
            optionLabel: String(localized: "Enable regular expressions"),
            optionValue: isRegexEnabled
        ) { [weak self] dialog, _ in
            guard let self, let dialog = dialog as? EntryDialog else {
                return
            }

            if let originalRow = downloadFilterListView.iterators[.string(filter)] {
                downloadFilterListView.removeRow(originalRow)
            }

            downloadFilterListView.addRow([.string(dialog.entryValue), .bool(dialog.optionValue ?? false)])
            onVerifyFilter()
        }.present()
    }

    func onRemoveFilter() {
        for row in downloadFilterListView.selectedRows.reversed() {
            downloadFilterListView.removeRow(row)
        }
        onVerifyFilter()
    }

    func onDefaultFilters() {
        downloadFilterListView.clear()
        downloadFilterListView.freeze()

        for filter in defaults.transfers.downloadFilters {
            downloadFilterListView.addRow([.string(filter.pattern), .bool(!filter.isEscaped)], selectRow: false)
        }

        downloadFilterListView.unfreeze()
        onVerifyFilter()
    }

    func onVerifyFilter() {
        var failed: [(String, String)] = []
        var patterns: [String] = []

        for row in downloadFilterListView.iterators.values {
            var filter = downloadFilterListView.rowValue(row, "filter").string

            if !downloadFilterListView.rowValue(row, "regex").bool {
                filter = NSRegularExpression.escapedPattern(for: filter).replacingOccurrences(of: "\\*", with: ".*")
            }

            do {
                _ = try NSRegularExpression(pattern: "(" + filter + ")", options: .caseInsensitive)
                patterns.append(filter)
            } catch {
                failed.append((filter, error.localizedDescription))
            }
        }

        let outFilter = "(\\\\(" + patterns.joined(separator: "|") + ")$)"

        do {
            _ = try NSRegularExpression(pattern: outFilter, options: .caseInsensitive)
        } catch {
            failed.append((outFilter, error.localizedDescription))
        }

        guard !failed.isEmpty else {
            filterStatusText = String(localized: "Filters Successful")
            return
        }

        let errors = failed.map { "Filter: \($0.0) Error: \($0.1) " }.joined()
        filterStatusText = String(localized: "\(failed.count) Failed! \(errors) ")
    }

    // MARK: Shares Page

    private static let permissionLevels: [(label: String, level: PermissionLevel)] = [
        (String(localized: "Public"), .public),
        (String(localized: "Buddies"), .buddy),
        (String(localized: "Trusted buddies"), .trusted)
    ]

    private func populateShares() {
        sharesListView.clear()
        sharesListView.freeze()

        for share in draft.transfers.shared {
            sharesListView.addRow([.string(share.virtualName), .string(share.path), .string(String(localized: "Public"))],
                                  selectRow: false)
        }

        for share in draft.transfers.buddyShared {
            sharesListView.addRow([.string(share.virtualName), .string(share.path), .string(String(localized: "Buddies"))],
                                  selectRow: false)
        }

        for share in draft.transfers.trustedShared {
            sharesListView.addRow([.string(share.virtualName), .string(share.path), .string(String(localized: "Trusted"))],
                                  selectRow: false)
        }

        sharesListView.unfreeze()
    }

    private var allSharedFolders: [SharedFolder] {
        draft.transfers.shared + draft.transfers.buddyShared + draft.transfers.trustedShared
    }

    private func addShare(_ folderPath: String, permissionLevel: PermissionLevel = .public, virtualName: String? = nil,
                          validatePath: Bool = true) -> String? {
        if validatePath && !FileManager.default.isReadableFile(atPath: folderPath) {
            return nil
        }

        // Remove previous share with same path if present
        removeShare(folderPath)

        let virtualName = core.shares.normalizedVirtualName(
            virtualName ?? (folderPath as NSString).lastPathComponent, sharedFolders: allSharedFolders
        )
        let share = SharedFolder(virtualName: virtualName, path: (folderPath as NSString).standardizingPath)

        switch permissionLevel {
        case .buddy: draft.transfers.buddyShared.append(share)
        case .trusted: draft.transfers.trustedShared.append(share)
        default: draft.transfers.shared.append(share)
        }

        return virtualName
    }

    private func removeShare(_ virtualNameOrFolderPath: String) {
        let normalizedFolderPath = (virtualNameOrFolderPath as NSString).standardizingPath

        func matches(_ share: SharedFolder) -> Bool {
            virtualNameOrFolderPath == share.virtualName || virtualNameOrFolderPath == share.path
                || normalizedFolderPath == share.path
        }

        draft.transfers.shared.removeAll(where: matches)
        draft.transfers.buddyShared.removeAll(where: matches)
        draft.transfers.trustedShared.removeAll(where: matches)
    }

    func onAddSharedFolder() {
        // By default, show parent folder of last added share as initial folder
        var initialFolder = lastParentFolder

        // If present, show parent folder of selected share as initial folder
        if let row = sharesListView.selectedRows.first {
            initialFolder = (sharesListView.rowValue(row, "folder").string as NSString).deletingLastPathComponent
        }

        if let folder = initialFolder, !FileManager.default.fileExists(atPath: folder) {
            initialFolder = nil
        }

        FileChooser.chooseFolders(title: String(localized: "Add a Shared Folder"), initialFolder: initialFolder,
                                  selectMultiple: true) { [weak self] folderPaths in
            guard let self else {
                return
            }

            for folderPath in folderPaths {
                guard let virtualName = addShare(folderPath) else {
                    continue
                }

                lastParentFolder = (folderPath as NSString).deletingLastPathComponent
                sharesListView.addRow([.string(virtualName), .string(folderPath), .string(String(localized: "Public"))])
            }
        }
    }

    func onEditSharedFolder() {
        guard let row = sharesListView.selectedRows.first else {
            return
        }

        let virtualName = sharesListView.rowValue(row, "virtual_name").string
        let folderPath = sharesListView.rowValue(row, "folder").string
        let accessibleTo = sharesListView.rowValue(row, "accessible_to").string
        let trustedLabel = String(localized: "Trusted")
        let trustedBuddiesLabel = String(localized: "Trusted buddies")

        EntryDialog(
            title: String(localized: "Edit Shared Folder"),
            message: String(localized: "Enter new virtual name for '\(folderPath)':"),
            defaultText: virtualName,
            useSecondEntry: true,
            secondEntryEditable: false,
            secondDefault: accessibleTo.replacingOccurrences(of: trustedLabel, with: trustedBuddiesLabel),
            actionButtonLabel: String(localized: "Edit"),
            secondDroplist: Self.permissionLevels.map(\.label)
        ) { [weak self] dialog, _ in
            guard let self, let dialog = dialog as? EntryDialog else {
                return
            }

            let newVirtualName = dialog.entryValue
            let newAccessibleTo = dialog.secondEntryValue ?? ""
            let newAccessibleToShort = newAccessibleTo.replacingOccurrences(of: trustedBuddiesLabel, with: trustedLabel)

            guard newVirtualName != virtualName || newAccessibleToShort != accessibleTo else {
                return
            }

            let permissionLevel = Self.permissionLevels.first { $0.label == newAccessibleTo }?.level ?? .public

            if let originalRow = sharesListView.iterators[.string(virtualName)] {
                sharesListView.removeRow(originalRow)
            }

            removeShare(virtualName)

            if let addedVirtualName = addShare(folderPath, permissionLevel: permissionLevel,
                                               virtualName: newVirtualName, validatePath: false) {
                sharesListView.addRow([.string(addedVirtualName), .string(folderPath), .string(newAccessibleToShort)])
            }
        }.present()
    }

    func onRemoveSharedFolder() {
        for row in sharesListView.selectedRows.reversed() {
            let virtualName = sharesListView.rowValue(row, "virtual_name").string
            removeShare(virtualName)
            sharesListView.removeRow(row)
        }
    }

    // MARK: Banned and Ignored Users Pages

    private func addUser(_ listView: TreeView, changes: inout UserChanges, user: String) {
        let user = user.trimmingCharacters(in: .whitespaces)

        guard !user.isEmpty, listView.iterators[.string(user)] == nil else {
            return
        }

        listView.addRow([.string(user)])
        changes.addedUsers.insert(user)
        changes.removedUsers.remove(user)
    }

    private func removeUsers(_ listView: TreeView, changes: inout UserChanges) {
        for row in listView.selectedRows.reversed() {
            let user = listView.rowValue(row, "username").string
            listView.removeRow(row)

            if !changes.addedUsers.contains(user) {
                changes.removedUsers.insert(user)
            }
            changes.addedUsers.remove(user)
        }
    }

    private func addIP(_ listView: TreeView, changes: inout UserChanges, ipAddress: String) {
        let ipAddress = ipAddress.trimmingCharacters(in: .whitespaces)

        guard NetworkFilter.isIPAddress(ipAddress), listView.iterators[.string(ipAddress)] == nil else {
            return
        }

        let user = core.networkFilter.onlineUsername(ipAddress: ipAddress) ?? ""
        let pair = [user, ipAddress]

        listView.addRow([.string(ipAddress), .string(user)])
        changes.addedIPs.insert(pair)
        changes.removedIPs.remove(pair)
    }

    private func removeIPs(_ listView: TreeView, changes: inout UserChanges) {
        for row in listView.selectedRows.reversed() {
            let pair = [listView.rowValue(row, "user").string, listView.rowValue(row, "ip_address").string]
            listView.removeRow(row)

            if !changes.addedIPs.contains(pair) {
                changes.removedIPs.insert(pair)
            }
            changes.addedIPs.remove(pair)
        }
    }

    private func askForEntry(title: String, message: String, completion: @escaping @MainActor (String) -> Void) {
        EntryDialog(title: title, message: message, actionButtonLabel: String(localized: "Add")) { dialog, _ in
            completion((dialog as? EntryDialog)?.entryValue ?? "")
        }.present()
    }

    func onAddBannedUser() {
        askForEntry(title: String(localized: "Ban User"),
                    message: String(localized: "Enter the name of the user you want to ban:")) { [weak self] user in
            guard let self else { return }
            addUser(bannedUsersListView, changes: &bannedChanges, user: user)
        }
    }

    func onRemoveBannedUser() {
        removeUsers(bannedUsersListView, changes: &bannedChanges)
    }

    func onAddBannedIP() {
        askForEntry(title: String(localized: "Ban IP Address"),
                    message: String(localized: "Enter an IP address you want to ban:") + " "
                        + String(localized: "* is a wildcard")) { [weak self] ipAddress in
            guard let self else { return }
            addIP(bannedIPsListView, changes: &bannedChanges, ipAddress: ipAddress)
        }
    }

    func onRemoveBannedIP() {
        removeIPs(bannedIPsListView, changes: &bannedChanges)
    }

    func onAddIgnoredUser() {
        askForEntry(title: String(localized: "Ignore User"),
                    message: String(localized: "Enter the name of the user you want to ignore:")) { [weak self] user in
            guard let self else { return }
            addUser(ignoredUsersListView, changes: &ignoredChanges, user: user)
        }
    }

    func onRemoveIgnoredUser() {
        removeUsers(ignoredUsersListView, changes: &ignoredChanges)
    }

    func onAddIgnoredIP() {
        askForEntry(title: String(localized: "Ignore IP Address"),
                    message: String(localized: "Enter an IP address you want to ignore:") + " "
                        + String(localized: "* is a wildcard")) { [weak self] ipAddress in
            guard let self else { return }
            addIP(ignoredIPsListView, changes: &ignoredChanges, ipAddress: ipAddress)
        }
    }

    func onRemoveIgnoredIP() {
        removeIPs(ignoredIPsListView, changes: &ignoredChanges)
    }

    // MARK: Chats Page

    private var censorMessage: String {
        String(localized: "Enter a pattern you want to censor. Add spaces around the pattern if you don't want to match strings inside words (may fail at the beginning and end of lines).")
    }

    func onAddCensored() {
        EntryDialog(title: String(localized: "Censor Pattern"), message: censorMessage,
                    actionButtonLabel: String(localized: "Add")) { [weak self] dialog, _ in
            guard let self, let pattern = (dialog as? EntryDialog)?.entryValue, !pattern.isEmpty,
                  censorListView.iterators[.string(pattern)] == nil else {
                return
            }
            censorListView.addRow([.string(pattern)])
        }.present()
    }

    func onEditCensored() {
        guard let row = censorListView.selectedRows.first else {
            return
        }

        let oldPattern = censorListView.rowValue(row, "pattern").string

        EntryDialog(title: String(localized: "Edit Censored Pattern"), message: censorMessage, defaultText: oldPattern,
                    actionButtonLabel: String(localized: "Edit")) { [weak self] dialog, _ in
            guard let self, let pattern = (dialog as? EntryDialog)?.entryValue, !pattern.isEmpty else {
                return
            }

            if let originalRow = censorListView.iterators[.string(oldPattern)] {
                censorListView.removeRow(originalRow)
            }
            censorListView.addRow([.string(pattern)])
        }.present()
    }

    func onRemoveCensored() {
        for row in censorListView.selectedRows.reversed() {
            censorListView.removeRow(row)
        }
    }

    func onAddReplacement() {
        EntryDialog(title: String(localized: "Add Replacement"),
                    message: String(localized: "Enter a text pattern and what to replace it with:"),
                    useSecondEntry: true, actionButtonLabel: String(localized: "Add")) { [weak self] dialog, _ in
            guard let self, let dialog = dialog as? EntryDialog, !dialog.entryValue.isEmpty,
                  let replacement = dialog.secondEntryValue, !replacement.isEmpty else {
                return
            }

            if let row = replacementListView.iterators[.string(dialog.entryValue)] {
                replacementListView.setRowValue(row, "replacement", .string(replacement))
            } else {
                replacementListView.addRow([.string(dialog.entryValue), .string(replacement)])
            }
        }.present()
    }

    func onEditReplacement() {
        guard let row = replacementListView.selectedRows.first else {
            return
        }

        let oldPattern = replacementListView.rowValue(row, "pattern").string
        let oldReplacement = replacementListView.rowValue(row, "replacement").string

        EntryDialog(title: String(localized: "Edit Replacement"),
                    message: String(localized: "Enter a text pattern and what to replace it with:"),
                    defaultText: oldPattern, useSecondEntry: true, secondDefault: oldReplacement,
                    actionButtonLabel: String(localized: "Edit")) { [weak self] dialog, _ in
            guard let self, let dialog = dialog as? EntryDialog, !dialog.entryValue.isEmpty,
                  let replacement = dialog.secondEntryValue, !replacement.isEmpty else {
                return
            }

            if let originalRow = replacementListView.iterators[.string(oldPattern)] {
                replacementListView.removeRow(originalRow)
            }
            replacementListView.addRow([.string(dialog.entryValue), .string(replacement)])
        }.present()
    }

    func onRemoveReplacement() {
        for row in replacementListView.selectedRows.reversed() {
            replacementListView.removeRow(row)
        }
    }

    // MARK: Searches Page

    func onClearSearchHistory() {
        application.window.search.clearSearchHistory()
        isSearchHistoryCleared = true
    }

    func onClearFilterHistory() {
        application.window.search.clearFilterHistory()
        isFilterHistoryCleared = true
    }

    // MARK: URL Handlers Page

    func onAddHandler() {
        EntryDialog(
            title: String(localized: "Add URL Handler"),
            message: String(localized: "Enter the protocol and the command for the URL handler:"),
            useSecondEntry: true, actionButtonLabel: String(localized: "Add"),
            droplist: Self.defaultURLProtocols, secondDroplist: Self.defaultURLCommands
        ) { [weak self] dialog, _ in
            guard let self, let dialog = dialog as? EntryDialog else {
                return
            }

            var urlProtocol = dialog.entryValue.trimmingCharacters(in: .whitespaces)
            let command = (dialog.secondEntryValue ?? "").trimmingCharacters(in: .whitespaces)

            guard !urlProtocol.isEmpty, !command.isEmpty else {
                return
            }

            if urlProtocol.hasPrefix(".") {
                // Only keep last part of file extension (e.g. .tar.gz -> .gz)
                urlProtocol = "." + (urlProtocol.components(separatedBy: ".").last ?? "")
            } else if !urlProtocol.hasSuffix("://") && !Self.defaultURLProtocols.contains(urlProtocol) {
                urlProtocol += "://"
            }

            if let row = protocolListView.iterators[.string(urlProtocol)] {
                protocolListView.setRowValue(row, "command", .string(command))
                return
            }

            protocolListView.addRow([.string(urlProtocol), .string(command)])
        }.present()
    }

    func onEditHandler() {
        guard let row = protocolListView.selectedRows.first else {
            return
        }

        let urlProtocol = protocolListView.rowValue(row, "protocol").string
        let command = protocolListView.rowValue(row, "command").string

        EntryDialog(
            title: String(localized: "Edit Command"),
            message: String(localized: "Enter a new command for protocol \(urlProtocol):"),
            defaultText: command, actionButtonLabel: String(localized: "Edit"), droplist: Self.defaultURLCommands
        ) { [weak self] dialog, _ in
            guard let self, let command = (dialog as? EntryDialog)?.entryValue.trimmingCharacters(in: .whitespaces),
                  !command.isEmpty, let row = protocolListView.iterators[.string(urlProtocol)] else {
                return
            }
            protocolListView.setRowValue(row, "command", .string(command))
        }.present()
    }

    func onRemoveHandler() {
        for row in protocolListView.selectedRows.reversed() {
            protocolListView.removeRow(row)
        }
    }

    // MARK: Now Playing Page

    func nowPlayingReplacers(for player: String) -> [(String, String)] {
        let replacers: [String]

        switch player {
        case "other": replacers = ["$n"]
        case "mpris": replacers = ["$n", "$p", "$a", "$b", "$t", "$y", "$c", "$r", "$k", "$l", "$f"]
        default: replacers = ["$n", "$t", "$a", "$b"]
        }

        return replacers.map { item in
            let label = switch item {
            case "$t": String(localized: "Title")
            case "$n": String(localized: "Now Playing (typically \"\(String(localized: "Artist")) - \(String(localized: "Title"))\")")
            case "$l": String(localized: "Duration")
            case "$r": String(localized: "Bitrate")
            case "$c": String(localized: "Comment")
            case "$a": String(localized: "Artist")
            case "$b": String(localized: "Album")
            case "$k": String(localized: "Track Number")
            case "$y": String(localized: "Year")
            case "$f": String(localized: "Filename (URI)")
            case "$p": String(localized: "Program")
            default: ""
            }
            return (item, label)
        }
    }

    func nowPlayingCommandLabel(for player: String) -> String {
        switch player {
        case "listenbrainz": String(localized: "Username: ")
        case "other": String(localized: "Command:")
        default: String(localized: "Username;APIKEY")
        }
    }

    func onTestNowPlaying() {
        guard let nowPlaying = core.nowPlaying else {
            return
        }

        let player = draft.players.npPlayer
        let command = draft.players.npOtherCommand.trimmingCharacters(in: .whitespaces)
        let format = draft.players.npFormat

        Task {
            let title = await nowPlaying.nowPlaying(player: player, command: command, format: format)
            nowPlayingOutput = title ?? ""
        }
    }

    // MARK: Plugins Page

    private func updatePluginSettingsButton(_ pluginID: String?) {
        guard let pluginID else {
            isPluginSettingsEnabled = false
            return
        }

        let settings = core.pluginHandler?.pluginSettings(pluginID) ?? [:]
        isPluginSettingsEnabled = !settings.isEmpty && core.pluginHandler?.enabledPlugins[pluginID] != nil
    }

    private func onSelectPlugin(_ listView: TreeView, _ row: TreeRow?) {
        guard let row else {
            selectedPlugin = nil
            selectedPluginInfo = nil
            pluginDescriptionView.clear()
            updatePluginSettingsButton(nil)
            return
        }

        let pluginID = listView.rowValue(row, "plugin_id").string
        let info = core.pluginHandler?.pluginInfo(pluginID)

        selectedPlugin = pluginID
        selectedPluginInfo = info

        pluginDescriptionView.clear()
        pluginDescriptionView.appendLine((info?.description ?? "").replacingOccurrences(of: "\\n", with: "\n"))
        pluginDescriptionView.placeCursorAtLine(0)
        updatePluginSettingsButton(pluginID)
    }

    private func onPluginToggle(_ listView: TreeView, _ row: TreeRow) {
        let pluginID = listView.rowValue(row, "plugin_id").string
        let isEnabled = core.pluginHandler?.togglePlugin(pluginID) ?? false

        listView.setRowValue(row, "enabled", .bool(isEnabled))
        updatePluginSettingsButton(pluginID)
    }

    func onEnablePlugins(_ isEnabled: Bool) {
        guard let pluginHandler = core.pluginHandler else {
            return
        }

        let enabledPluginIDs = config.plugins.enabled

        if isEnabled {
            // Enable all selected plugins
            for pluginID in enabledPluginIDs {
                _ = pluginHandler.enablePlugin(pluginID)
            }
            updatePluginSettingsButton(selectedPlugin)
            return
        }

        // Disable all plugins
        for pluginID in pluginHandler.enabledPlugins.keys {
            _ = pluginHandler.disablePlugin(pluginID)
        }

        config.plugins.enabled = enabledPluginIDs
        isPluginSettingsEnabled = false
    }

    func onPluginSettings() {
        if let pluginID = selectedPlugin {
            showPluginSettings(pluginID)
        }
    }

    func showPluginSettings(_ pluginID: String) {
        guard let settings = core.pluginHandler?.pluginSettings(pluginID), !settings.isEmpty else {
            return
        }

        if pluginSettingsDialog == nil {
            pluginSettingsDialog = PluginSettingsDialog()
        }

        pluginSettingsDialog?.updateSettings(pluginID: pluginID, metaSettings: settings)
        pluginSettingsDialog?.present()
    }
}
