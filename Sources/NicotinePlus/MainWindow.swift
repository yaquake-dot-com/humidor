// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import NicotineCore
import Observation
import SwiftUI

/// The main application window, containing the main pages, the log pane and
/// the status bar.
@MainActor
@Observable
final class MainWindow: NSObject {

    enum Page: String, CaseIterable, Identifiable {
        case search
        case downloads
        case uploads
        case userbrowse
        case userinfo
        case `private`
        case userlist
        case chatrooms
        case interests

        var id: String { rawValue }

        var title: String {
            switch self {
            case .search: String(localized: "Search Files")
            case .downloads: String(localized: "Downloads")
            case .uploads: String(localized: "Uploads")
            case .userbrowse: String(localized: "Browse Shares")
            case .userinfo: String(localized: "User Profiles")
            case .private: String(localized: "Private Chat")
            case .userlist: String(localized: "Buddies")
            case .chatrooms: String(localized: "Chat Rooms")
            case .interests: String(localized: "Interests")
            }
        }

        var systemImage: String {
            switch self {
            case .search: "magnifyingglass"
            case .downloads: "arrow.down.circle"
            case .uploads: "arrow.up.circle"
            case .userbrowse: "folder"
            case .userinfo: "person.crop.circle"
            case .private: "envelope"
            case .userlist: "person.2"
            case .chatrooms: "bubble.left.and.bubble.right"
            case .interests: "star"
            }
        }
    }

    static private(set) var shared: MainWindow?

    @ObservationIgnored let application: Application
    @ObservationIgnored private(set) var window: NSWindow!

    // Pages
    @ObservationIgnored private(set) var interests: InterestsPage!
    @ObservationIgnored private(set) var chatrooms: ChatRoomsPage!
    @ObservationIgnored private(set) var search: SearchesPage!
    @ObservationIgnored private(set) var downloads: DownloadsPage!
    @ObservationIgnored private(set) var uploads: UploadsPage!
    @ObservationIgnored private(set) var buddies: BuddiesPage!
    @ObservationIgnored private(set) var privateChat: PrivateChatsPage!
    @ObservationIgnored private(set) var userInfo: UserInfosPage!
    @ObservationIgnored private(set) var userBrowse: UserBrowsesPage!

    private(set) var currentPage: Page = .search
    private(set) var pageOrder: [Page] = Page.allCases
    private(set) var visiblePages = Set(Page.allCases)
    /// Pages with unread content, and whether the content is important
    var highlightedPages: [Page: Bool] = [:]

    // Status bar
    private(set) var statusText = ""
    private(set) var connectionsText = "0"
    private(set) var scanProgressText: String?
    private(set) var userStatus = UserStatus.offline
    private(set) var userStatusUsername: String?
    var downloadStatusText = ""
    var uploadStatusText = ""
    var isDownloadLimitAlternative = false
    var isUploadLimitAlternative = false
    var isShutdownPending = false

    /// Buddies, suggested in username entries
    var buddyUsernames: [String] = []

    // Log pane
    var isLogPaneVisible: Bool {
        didSet {
            logView.autoScroll = isLogPaneVisible

            if isLogPaneVisible {
                logView.scrollBottom()
            }
            config.logging.logCollapsed = !isLogPaneVisible
        }
    }

    @ObservationIgnored let logView: TextView
    @ObservationIgnored private var logViewMenu: PopupMenu!
    @ObservationIgnored private var logCategoriesMenu: PopupMenu!

    // Auto-away
    @ObservationIgnored private var isAutoAway = false
    @ObservationIgnored private var awayTimerID: Int?
    @ObservationIgnored private var awayCooldownTime: TimeInterval = 0
    @ObservationIgnored private var eventMonitor: Any?

    init(application: Application) {
        self.application = application
        self.isLogPaneVisible = !config.logging.logCollapsed

        logView = TextView(autoScroll: !config.logging.logCollapsed, parseURLs: false, isEditable: false,
                           verticalMargin: 5, paragraphSpacing: 2)

        super.init()

        Self.shared = self

        createLogContextMenu()

        events.connect(.logMessage) { [unowned self] message in updateLog(message) }

        events.connect(.quit) { [unowned self] in onQuit() }
        events.connect(.serverLogin) { [unowned self] _ in updateUserStatus() }
        events.connect(.serverDisconnect) { [unowned self] _ in updateUserStatus() }
        events.connect(.setConnectionStats) { [unowned self] stats in setConnectionStats(stats) }
        events.connect(.sharesPreparing) { [unowned self] in sharesPreparing() }
        events.connect(.sharesReady) { [unowned self] _ in sharesReady() }
        events.connect(.sharesScanning) { [unowned self] folderCount in sharesScanning(folderCount) }
        events.connectMessage(.userStatus) { [unowned self] msg in onUserStatusMessage(msg) }

        // Secondary pages
        interests = InterestsPage(window: self)
        chatrooms = ChatRoomsPage(window: self)
        search = SearchesPage(window: self)
        downloads = DownloadsPage(window: self)
        uploads = UploadsPage(window: self)
        buddies = BuddiesPage(window: self)
        privateChat = PrivateChatsPage(window: self)
        userInfo = UserInfosPage(window: self)
        userBrowse = UserBrowsesPage(window: self)

        // Tab visibility/order
        setMainTabsOrder()
        setMainTabsVisibility()
        setLastSessionTab()

        initWindow()
    }

    // MARK: Initialize

    private func initWindow() {
        let hostingController = NSHostingController(rootView: MainWindowView(mainWindow: self))
        hostingController.sceneBridgingOptions = [.toolbars]

        let window = NSWindow(contentViewController: hostingController)
        window.title = NicotineCore.Application.name
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: config.ui.width, height: config.ui.height))
        window.minSize = NSSize(width: 700, height: 450)
        self.window = window

        // Set main window position
        let xPosition = config.ui.xPosition
        let yPosition = config.ui.yPosition

        if xPosition == -1 && yPosition == -1 {
            window.center()
        } else {
            window.setFrameOrigin(NSPoint(x: xPosition, y: yPosition))
        }

        // Maximize main window if necessary
        if config.ui.maximized || application.isolatedMode {
            window.setFrame(window.screen?.visibleFrame ?? window.frame, display: false)
        }

        // Auto-away mode
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown, .rightMouseDown,
                                                                   .otherMouseDown]) { [weak self] event in
            if event.window === self?.window {
                self?.onCancelAutoAway()
            }
            return event
        }
    }

    var isVisible: Bool {
        window.isVisible && !NSApp.isHidden
    }

    var isActive: Bool {
        window.isKeyWindow && NSApp.isActive
    }

    func present() {
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: Window State

    fileprivate func onWindowActiveChanged() {
        saveWindowState()

        guard isActive else {
            return
        }

        chatrooms.clearNotifications()
        privateChat.clearNotifications()
        onCancelAutoAway()
        setUrgencyHint(false)
    }

    func updateTitle() {
        var notificationText = ""

        if !config.notifications.windowTitle {
            // Reset Title
        } else if let user = privateChat.highlightedUsers.last {
            // Private Chats have a higher priority
            notificationText = String(localized: "Private Message from \(user)")
            setUrgencyHint(true)

        } else if let (room, user) = chatrooms.highlightedRooms.last {
            // Allow for the possibility the username is not available
            notificationText = String(localized: "Mentioned by \(user ?? "") in Room \(room)")
            setUrgencyHint(true)

        } else if search.unreadPages.values.contains(true) {
            notificationText = String(localized: "Wishlist Results Found")
        }

        guard !notificationText.isEmpty else {
            window.title = NicotineCore.Application.name
            return
        }

        window.title = "\(NicotineCore.Application.name) - \(notificationText)"
    }

    private var attentionRequest: Int?

    func setUrgencyHint(_ isEnabled: Bool) {
        if let attentionRequest {
            NSApp.cancelUserAttentionRequest(attentionRequest)
            self.attentionRequest = nil
        }

        if isEnabled && !isActive {
            attentionRequest = NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func saveWindowState() {
        guard let screenFrame = window.screen?.visibleFrame else {
            return
        }

        let frame = window.frame
        config.ui.maximized = window.isZoomed || frame == screenFrame

        guard !config.ui.maximized, frame.width > 0, frame.height > 0 else {
            return
        }

        let contentSize = window.contentRect(forFrameRect: frame).size
        config.ui.width = Int(contentSize.width)
        config.ui.height = Int(contentSize.height)
        config.ui.xPosition = Int(frame.origin.x)
        config.ui.yPosition = Int(frame.origin.y)
    }

    // MARK: Main Pages

    func page(_ page: Page) -> any MainPage {
        switch page {
        case .search: search
        case .downloads: downloads
        case .uploads: uploads
        case .userbrowse: userBrowse
        case .userinfo: userInfo
        case .private: privateChat
        case .userlist: buddies
        case .chatrooms: chatrooms
        case .interests: interests
        }
    }

    var orderedVisiblePages: [Page] {
        pageOrder.filter { visiblePages.contains($0) }
    }

    func setCurrentPage(_ page: Page) {
        currentPage = page
        config.ui.lastTabID = page.rawValue

        let mainPage = self.page(page)
        mainPage.onShow()
        mainPage.onFocus()
    }

    func showCurrentPage() {
        let mainPage = page(currentPage)
        mainPage.onShow()
        mainPage.onFocus()
    }

    func changeMainPage(_ page: Page) {
        showTab(page)
        setCurrentPage(page)
    }

    func showTab(_ page: Page) {
        config.ui.modesVisible[page.rawValue] = true
        visiblePages.insert(page)
    }

    func hideTab(_ page: Page) {
        config.ui.modesVisible[page.rawValue] = false
        visiblePages.remove(page)

        if currentPage == page, let firstPage = orderedVisiblePages.first {
            setCurrentPage(firstPage)
        }
    }

    func movePages(fromOffsets source: IndexSet, toOffset destination: Int) {
        var visibleOrder = orderedVisiblePages
        visibleOrder.move(fromOffsets: source, toOffset: destination)

        // Keep hidden pages at their previous position
        var newOrder = visibleOrder
        for (index, page) in pageOrder.enumerated() where !visiblePages.contains(page) {
            newOrder.insert(page, at: min(index, newOrder.count))
        }

        pageOrder = newOrder
        config.ui.modesOrder = newOrder.map(\.rawValue)
    }

    private func setMainTabsOrder() {
        var order: [Page] = []

        for pageID in config.ui.modesOrder {
            if let page = Page(rawValue: pageID), !order.contains(page) {
                order.append(page)
            }
        }

        // If any pages were missing in the config, insert them
        for (index, page) in Page.allCases.enumerated() where !order.contains(page) {
            order.insert(page, at: min(index, order.count))
        }

        pageOrder = order
    }

    func setMainTabsVisibility() {
        var visibleTabFound = false
        let isBuddiesTabActive = (config.ui.buddyListInChatrooms == "tab")

        for page in pageOrder {
            if config.ui.modesVisible[page.rawValue] ?? true {
                if page == .userlist && !isBuddiesTabActive {
                    visiblePages.remove(page)
                    continue
                }

                visibleTabFound = true
                showTab(page)
                continue
            }

            hideTab(page)
        }

        if !visibleTabFound {
            // Ensure at least one tab is visible
            showTab(.search)
        }
    }

    private func setLastSessionTab() {
        if let firstPage = orderedVisiblePages.first {
            currentPage = firstPage
        }

        guard config.ui.tabSelectPrevious, let page = Page(rawValue: config.ui.lastTabID),
              visiblePages.contains(page) else {
            return
        }

        currentPage = page
    }

    /// Command+1-9: change main page.
    func changePrimaryTab(_ tabNumber: Int) {
        let pages = orderedVisiblePages

        guard tabNumber <= pages.count else {
            return
        }

        setCurrentPage(pages[tabNumber - 1])
    }

    /// Command+Shift+T: reopen recently closed tab.
    func reopenClosedTab() {
        page(currentPage).restoreRemovedTab()
    }

    /// Command+W: close current secondary tab.
    func closeTab() -> Bool {
        page(currentPage).closeCurrentTab()
    }

    /// Control+Tab and Control+Shift+Tab: cycle through secondary tabs.
    func cycleTabs(backwards: Bool = false) {
        page(currentPage).cycleTabs(backwards: backwards)
    }

    // MARK: Connection

    func updateUserStatus() {
        let status = core.users.loginStatus

        // Away mode
        if status != .away {
            setAutoAway(false)
        } else {
            removeAwayTimer()
        }

        userStatus = status
        userStatusUsername = (status == .offline) ? nil : core.users.loginUsername
    }

    var userStatusText: String {
        if isShutdownPending {
            return String(localized: "Quitting...")
        }

        return switch userStatus {
        case .away: String(localized: "Away")
        case .online: String(localized: "Online")
        case .offline: String(localized: "Offline")
        }
    }

    private func onUserStatusMessage(_ msg: GetUserStatus) {
        if msg.user == core.users.loginUsername {
            updateUserStatus()
        }
    }

    // MARK: Search

    func searchUser(_ username: String) {
        search.setSearchMode(.user)
        search.userSearchText = username
        changeMainPage(.search)
        search.focusSearchEntry()
    }

    // MARK: Away Mode

    private func setAutoAway(_ isActive: Bool = true) {
        if isActive {
            isAutoAway = true
            awayTimerID = nil

            if core.users.loginStatus != .away {
                core.users.setAwayMode(true)
            }
            return
        }

        if isAutoAway {
            isAutoAway = false

            if core.users.loginStatus == .away {
                core.users.setAwayMode(false)
            }
        }

        // Reset away timer
        removeAwayTimer()
        createAwayTimer()
    }

    private func createAwayTimer() {
        guard core.users.loginStatus == .online else {
            return
        }

        let awayInterval = config.server.autoAway

        if awayInterval > 0 {
            awayTimerID = events.schedule(delay: TimeInterval(60 * awayInterval)) { [weak self] in
                self?.setAutoAway()
            }
        }
    }

    private func removeAwayTimer() {
        events.cancelScheduled(awayTimerID)
    }

    private func onCancelAutoAway() {
        let currentTime = ProcessInfo.processInfo.systemUptime

        if currentTime - awayCooldownTime >= 5 {
            setAutoAway(false)
            awayCooldownTime = currentTime
        }
    }

    // MARK: Log Pane

    private func createLogContextMenu() {
        logCategoriesMenu = PopupMenu { menu in
            for (label, level) in Self.logCategories {
                menu.setState(label, Application.shared.isLogLevelEnabled(level))
            }
        }

        for (index, (label, level)) in Self.logCategories.enumerated() {
            if index == 4 {
                logCategoriesMenu.addItems(.separator)
            }

            logCategoriesMenu.addItems(.toggle(label) { isEnabled in
                Application.shared.setLogLevel(level, enabled: isEnabled)
            })
        }

        logViewMenu = PopupMenu { [unowned self] menu in
            menu.setEnabled(String(localized: "Copy"), logView.hasSelection)
        }

        logViewMenu.addItems(
            .action(String(localized: "Find…")) { [unowned self] in logView.showFindBar() },
            .separator,
            .action(String(localized: "Copy")) { [unowned self] in logView.onCopyText() },
            .action(String(localized: "Copy All")) { [unowned self] in logView.onCopyAllText() },
            .separator
        )

        if !application.isolatedMode {
            logViewMenu.addItems(
                .action(String(localized: "View Debug Logs")) {
                    if let path = log.debugFolderPath {
                        _ = openFolderPath(path, createFolder: true)
                    }
                },
                .action(String(localized: "View Transfer Logs")) {
                    if let path = log.transferFolderPath {
                        _ = openFolderPath(path, createFolder: true)
                    }
                },
                .separator
            )
        }

        logViewMenu.addItems(
            .submenu(String(localized: "Log Categories"), logCategoriesMenu),
            .separator,
            .action(String(localized: "Clear Log View")) { [unowned self] in onClearLogView() }
        )

        logView.popupMenu = logViewMenu
    }

    static let logCategories: [(String, LogLevel)] = [
        (String(localized: "Downloads"), .download),
        (String(localized: "Uploads"), .upload),
        (String(localized: "Search"), .search),
        (String(localized: "Chat"), .chat),
        (String(localized: "[Debug] Connections"), .connection),
        (String(localized: "[Debug] Messages"), .message),
        (String(localized: "[Debug] Transfers"), .transfer),
        (String(localized: "[Debug] Miscellaneous"), .miscellaneous)
    ]

    private func updateLog(_ message: LogMessage) {
        if let title = message.title {
            MessageDialog(title: title, message: message.message).present()
        }

        // Keep verbose debug messages out of statusbar to make it more useful
        if ![.transfer, .connection, .message, .miscellaneous].contains(message.level) {
            setStatusText(message.message)
        }

        logView.appendLine(message.message, timestampFormat: message.timestampFormat)
    }

    func onClearLogView() {
        logView.onClearAllText()
        setStatusText("")
    }

    // MARK: Status Bar

    func setStatusText(_ message: String) {
        statusText = message
    }

    private func setConnectionStats(_ stats: ConnectionStats) {
        let totalConnectionsText = String(stats.totalConnections)

        if connectionsText != totalConnectionsText {
            connectionsText = totalConnectionsText
        }
    }

    private func sharesPreparing() {
        scanProgressText = String(localized: "Preparing Shares")
    }

    private func sharesScanning(_ folderCount: Int?) {
        if let folderCount {
            scanProgressText = "\(String(localized: "Shared Folders")): \(humanize(folderCount))"
            return
        }

        scanProgressText = String(localized: "Scanning Shares")
    }

    private func sharesReady() {
        scanProgressText = nil
    }

    func onToggleStatus() {
        if core.uploads.pendingShutdown {
            core.uploads.cancelShutdown()
        } else {
            application.onAway()
        }
    }

    // MARK: Exit

    fileprivate func onCloseWindowRequest() -> Bool {
        switch config.ui.exitDialog {
        case 0:
            // Quit Program
            core.quit()
        case 1:
            // Show Confirmation Dialog
            core.confirmQuit()
        default:
            // Run in Background
            hide()
        }
        return false
    }

    private func onQuit() {
        saveWindowState()

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    func hide() {
        guard isVisible else {
            return
        }

        // Close any visible dialogs
        MessageDialog.closeAll()

        // Save config, in case application is killed later
        config.writeConfiguration()

        // Hide the application, to ensure it is restored when clicking the dock icon
        NSApp.hide(nil)
    }
}

// MARK: - Window Delegate

extension MainWindow: NSWindowDelegate {

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseWindowRequest()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onWindowActiveChanged()
    }

    func windowDidResignKey(_ notification: Notification) {
        onWindowActiveChanged()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveWindowState()
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowState()
    }
}

// MARK: - Pages

/// A page in the main window.
@MainActor
protocol MainPage: AnyObject {
    /// Focuses the default widget of the page
    func onFocus()

    /// The page was shown
    func onShow()

    func restoreRemovedTab()
    func closeCurrentTab() -> Bool
    func cycleTabs(backwards: Bool)
}

extension MainPage {
    func onShow() {}
    func restoreRemovedTab() {}
    func closeCurrentTab() -> Bool { false }
    func cycleTabs(backwards: Bool) {}
}

/// A main page containing secondary tabs.
@MainActor
protocol TabbedPage: MainPage {
    associatedtype Tab: NotebookPage
    var notebook: Notebook<Tab> { get }
}

extension TabbedPage {
    func onShow() {
        notebook.onShowParentPage()
    }

    func restoreRemovedTab() {
        notebook.restoreRemovedPage()
    }

    func closeCurrentTab() -> Bool {
        guard let currentTab = notebook.currentPage else {
            return false
        }

        notebook.closePage(currentTab)
        return true
    }

    func cycleTabs(backwards: Bool) {
        notebook.cycle(backwards: backwards)
    }
}
