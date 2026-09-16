// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore
import UserNotifications

/// Application delegate. Handles application-wide actions, notifications and
/// dialogs shown in response to core events.
@MainActor
final class Application: NSObject, NSApplicationDelegate {

    static private(set) var shared: Application!

    private(set) var isOnline = false
    private(set) var enabledLogLevels = Set<LogLevel>()

    private(set) var isolatedMode = false
    private var startHidden = false
    private var awayAcceleratorCooldownTime: TimeInterval = 0
    private var isTerminating = false
    private var signalSources: [DispatchSourceSignal] = []

    private(set) var window: MainWindow!
    private(set) var preferences: Preferences?
    private var fastConfigure: FastConfigure?
    private var statistics: StatisticsDialog?
    private var wishlist: WishList?
    private var about: About?
    private var shortcuts: Shortcuts?

    override init() {
        super.init()
        Self.shared = self
        parseArguments()
    }

    // MARK: Launching

    func applicationWillFinishLaunching(_ notification: Notification) {
        core.initComponents(isolatedMode: isolatedMode)

        events.connect(.confirmQuit) { [unowned self] in onConfirmQuit() }
        events.connect(.invalidPassword) { [unowned self] in onInvalidPassword() }
        events.connect(.invalidUsername) { [unowned self] in onInvalidPassword() }
        events.connect(.quit) { [unowned self] in onQuit() }
        events.connect(.setup) { [unowned self] in onFastConfigure() }
        events.connect(.serverLogin) { [unowned self] _ in updateUserStatus() }
        events.connect(.serverDisconnect) { [unowned self] _ in updateUserStatus() }
        events.connect(.sharesUnavailable) { [unowned self] shares in onSharesUnavailable(shares) }
        events.connect(.showNotification) { [unowned self] in showNotification($0) }
        events.connect(.showChatroomNotification) { [unowned self] in showChatroomNotification($0) }
        events.connect(.showDownloadNotification) { [unowned self] in showDownloadNotification($0) }
        events.connect(.showPrivateChatNotification) { [unowned self] in showPrivateChatNotification($0) }
        events.connect(.showSearchNotification) { [unowned self] in showSearchNotification($0) }
        events.connectMessage(.userStatus) { [unowned self] msg in onUserStatus(msg) }

        enabledLogLevels = Set(config.logging.debugModes)

        if !config.ui.language.isEmpty {
            Self.setLanguage(config.ui.language)
        }
    }

    /// Sets the language of the user interface, used from the next start of the
    /// application. An empty language code uses the system language.
    static func setLanguage(_ language: String) {
        guard !language.isEmpty else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            return
        }

        let languageCode = (language == "zh_CN") ? "zh-Hans" : language.replacingOccurrences(of: "_", with: "-")
        UserDefaults.standard.set([languageCode], forKey: "AppleLanguages")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        setUpSignalHandlers()

        #if DEBUG
        DebugHooks.enableIfRequested()
        #endif

        window = MainWindow(application: self)
        core.start()

        if config.server.autoConnectStartup {
            core.connect()
        }

        // Check command line option and config option
        let shouldStartHidden = startHidden || (config.ui.trayIcon && config.ui.startupHidden)

        if !shouldStartHidden {
            window.present()
        }

        // Show active page and focus default widget
        window.showCurrentPage()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !window.isVisible {
            window.present()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating {
            return .terminateNow
        }

        let eventType = NSApp.currentEvent?.type

        if eventType == .keyDown {
            // Command+Q
            onConfirmQuitRequest()
        } else if eventType == nil || eventType == .appKitDefined || eventType == .systemDefined {
            // Logging out or shutting down
            core.quit(isTerminating: true)
        } else {
            onQuitRequest()
        }

        return .terminateCancel
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func parseArguments() {
        var iterator = CommandLine.arguments.dropFirst().makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "-c", "--config":
                if let value = iterator.next() {
                    config.setConfigFile(value)
                }
            case "-u", "--user-data":
                if let value = iterator.next() {
                    config.setDataFolder(value)
                }
            case "-s", "--hidden":
                startHidden = true
            case "-b", "--bindip":
                core.cliInterfaceAddress = iterator.next()
            case "-l", "--port":
                core.cliListenPort = iterator.next().flatMap(Int.init)
            case "--isolated":
                isolatedMode = true
            default:
                break
            }
        }
    }

    private func setUpSignalHandlers() {
        // Quit gracefully on Ctrl+C and "kill"
        for signalType in [SIGINT, SIGTERM] {
            signal(signalType, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: signalType, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    core.quit(isTerminating: signalType == SIGTERM)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: User Status

    private func updateUserStatus() {
        isOnline = (core.users.loginStatus != .offline)
    }

    private func onUserStatus(_ msg: GetUserStatus) {
        if msg.user == core.users.loginUsername {
            updateUserStatus()
        }
    }

    // MARK: Notifications

    private func showNotification(_ notification: NotificationMessage, action: String? = nil) {
        let title = (notification.title ?? HumidorCore.Application.name).trimmingCharacters(in: .whitespaces)
        let message = notification.message.trimmingCharacters(in: .whitespaces)

        guard Bundle.main.bundleIdentifier != nil else {
            log.add(String(localized: "Unable to show notification: \("\(title): \(message)")"))
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.interruptionLevel = notification.highPriority ? .timeSensitive : .active

        if config.notifications.popupSound {
            content.sound = .default
        }

        if let action {
            content.userInfo = ["action": action, "target": notification.target ?? ""]
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

        UNUserNotificationCenter.current().add(request) { error in
            guard let error else {
                return
            }

            let description = error.localizedDescription

            Task { @MainActor in
                log.add(String(localized: "Unable to show notification: \(description)"))
            }
        }
    }

    private func showChatroomNotification(_ notification: NotificationMessage) {
        showNotification(notification, action: "chatroom")

        if notification.highPriority {
            window.setUrgencyHint(true)
        }
    }

    private func showDownloadNotification(_ notification: NotificationMessage) {
        showNotification(notification, action: "download")
    }

    private func showPrivateChatNotification(_ notification: NotificationMessage) {
        var notification = notification
        notification.highPriority = true

        showNotification(notification, action: "private-chat")
        window.setUrgencyHint(true)
    }

    private func showSearchNotification(_ notification: NotificationMessage) {
        var notification = notification
        notification.highPriority = true

        showNotification(notification, action: "search")
    }

    private func onNotificationActivated(action: String, target: String) {
        switch action {
        case "chatroom":
            core.chatrooms.showRoom(target)
        case "private-chat":
            core.privateChat.showUser(target)
        case "search":
            if let token = Int(target) {
                core.search.showSearch(token)
            }
        case "download":
            window.changeMainPage(.downloads)
        default:
            break
        }

        window.present()
    }

    // MARK: Core Events

    private func onConfirmQuit() {
        let hasActiveUploads = core.uploads.hasActiveUploads

        if !window.isVisible {
            // Never show confirmation dialog when main window is hidden
            core.quit()
            return
        }

        let message: String
        let optionLabel: String?

        if hasActiveUploads {
            message = String(localized: "You are still uploading files. Do you really want to exit?")
            optionLabel = String(localized: "Wait for uploads to finish")
        } else {
            message = String(localized: "Do you really want to exit?")
            optionLabel = nil
        }

        OptionDialog(
            title: String(localized: "Quit \(HumidorCore.Application.name)"),
            message: message,
            buttons: [
                .init("cancel", String(localized: "No")),
                .init("quit", String(localized: "Quit")),
                .init("run_background", String(localized: "Run in Background"))
            ],
            optionLabel: optionLabel
        ) { [unowned self] dialog, response in
            let shouldFinishUploads = (dialog as? OptionDialog)?.optionValue ?? false

            if response == "quit" {
                if shouldFinishUploads {
                    core.uploads.requestShutdown()
                } else {
                    core.quit()
                }
            } else if response == "run_background" {
                window.hide()
            }
        }.present()
    }

    private func onSharesUnavailable(_ shares: [SharedFolder]) {
        var sharesListMessage = ""

        for share in shares {
            sharesListMessage += "• \"\(share.virtualName)\" \(share.path)\n"
        }

        OptionDialog(
            title: String(localized: "Shares Not Available"),
            message: String(localized: "Verify that external disks are mounted and folder permissions are correct."),
            longMessage: sharesListMessage,
            buttons: [
                .init("cancel", String(localized: "Cancel")),
                .init("ok", String(localized: "Retry")),
                .init("force_rescan", String(localized: "Force Rescan"))
            ],
            destructiveResponse: "force_rescan"
        ) { _, response in
            core.shares.rescanShares(force: response == "force_rescan")
        }.present()
    }

    private func onInvalidPassword() {
        onFastConfigure(invalidPassword: true)
    }

    private func onQuit() {
        isTerminating = true

        // Let the quit event finish processing before terminating
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    // MARK: Actions

    func onConnect() {
        if core.users.loginStatus == .offline {
            core.connect()
        }
    }

    func onDisconnect() {
        if core.users.loginStatus != .offline {
            core.disconnect()
        }
    }

    func onSoulseekPrivileges() {
        core.users.requestCheckPrivileges(shouldOpenURL: true)
    }

    func onPreferences(pageID: String = "network") {
        if preferences == nil {
            preferences = Preferences(application: self)
        }

        preferences?.setSettings()
        preferences?.setActivePage(pageID)
        preferences?.present()
    }

    func isLogLevelEnabled(_ level: LogLevel) -> Bool {
        enabledLogLevels.contains(level)
    }

    func setLogLevel(_ level: LogLevel, enabled: Bool) {
        if enabled {
            log.addLogLevel(level)
            enabledLogLevels.insert(level)
        } else {
            log.removeLogLevel(level)
            enabledLogLevels.remove(level)
        }
    }

    func onFastConfigure(invalidPassword: Bool = false) {
        if fastConfigure == nil {
            fastConfigure = FastConfigure(application: self)
        }

        if invalidPassword, fastConfigure?.isVisible == true {
            fastConfigure?.hide()
        }

        fastConfigure?.invalidPassword = invalidPassword
        fastConfigure?.present()
    }

    func onKeyboardShortcuts() {
        if shortcuts == nil {
            shortcuts = Shortcuts()
        }
        shortcuts?.present()
    }

    func onTransferStatistics() {
        if statistics == nil {
            statistics = StatisticsDialog()
        }
        statistics?.present()
    }

    func onReportBug() {
        openURI(HumidorCore.Application.issueTrackerURL)
    }

    func onImproveTranslations() {
        openURI(HumidorCore.Application.translationsURL)
    }

    func onWishlist() {
        if wishlist == nil {
            wishlist = WishList(application: self)
        }
        wishlist?.present()
    }

    func onAbout() {
        if about == nil {
            about = About()
        }
        about?.present()
    }

    private func onMessageUsersResponse(_ dialog: MessageDialog, target: String) {
        guard let message = (dialog as? EntryDialog)?.entryValue, !message.isEmpty else {
            return
        }
        core.privateChat.sendMessageUsers(target: target, message: message)
    }

    func onMessageDownloadingUsers() {
        EntryDialog(
            title: String(localized: "Message Downloading Users"),
            message: String(localized: "Send private message to all users who are downloading from you:"),
            actionButtonLabel: String(localized: "Send Message")
        ) { [unowned self] dialog, _ in
            onMessageUsersResponse(dialog, target: "downloading")
        }.present()
    }

    func onMessageBuddies() {
        EntryDialog(
            title: String(localized: "Message Buddies"),
            message: String(localized: "Send private message to all online buddies:"),
            actionButtonLabel: String(localized: "Send Message")
        ) { [unowned self] dialog, _ in
            onMessageUsersResponse(dialog, target: "buddies")
        }.present()
    }

    func onRescanShares() {
        core.shares.rescanShares()
    }

    func onBrowsePublicShares() {
        core.userBrowse.browseLocalShares(permissionLevel: .public, newRequest: true)
    }

    func onBrowseBuddyShares() {
        core.userBrowse.browseLocalShares(permissionLevel: .buddy, newRequest: true)
    }

    func onBrowseTrustedShares() {
        core.userBrowse.browseLocalShares(permissionLevel: .trusted, newRequest: true)
    }

    func onLoadSharesFromDisk() {
        FileChooser.chooseFiles(
            title: String(localized: "Select a Saved Shares List File"),
            initialFolder: core.userBrowse.createUserSharesFolder(),
            selectMultiple: true
        ) { filePaths in
            for filePath in filePaths {
                core.userBrowse.loadSharesListFromDisk(filePath)
            }
        }
    }

    func onPersonalProfile() {
        core.userInfo.showUser()
    }

    func onConfigureShares() { onPreferences(pageID: "shares") }
    func onConfigureSearches() { onPreferences(pageID: "searches") }
    func onConfigureChats() { onPreferences(pageID: "chats") }
    func onConfigureDownloads() { onPreferences(pageID: "downloads") }
    func onConfigureUploads() { onPreferences(pageID: "uploads") }
    func onConfigureIgnoredUsers() { onPreferences(pageID: "ignored-users") }
    func onConfigureAccount() { onPreferences(pageID: "network") }
    func onConfigureUserProfile() { onPreferences(pageID: "user-profile") }

    /// Shift+Command+A: Away/Online toggle.
    func onAwayAccelerator() {
        let currentTime = ProcessInfo.processInfo.systemUptime

        if currentTime - awayAcceleratorCooldownTime >= 1 {
            // Prevent rapid key-repeat toggling to avoid server ban
            onAway()
            awayAcceleratorCooldownTime = currentTime
        }
    }

    /// Away/Online status button.
    func onAway() {
        if core.users.loginStatus == .offline {
            core.connect()
            return
        }

        core.users.setAwayMode(core.users.loginStatus != .away, saveState: true)
    }

    func onConfirmQuitRequest() {
        core.confirmQuit()
    }

    func onForceQuitRequest() {
        core.quit()
    }

    func onQuitRequest() {
        if !core.uploads.hasActiveUploads {
            core.quit()
            return
        }

        core.confirmQuit()
    }
}

// MARK: - Notification Center Delegate

extension Application: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo

        guard let action = userInfo["action"] as? String else {
            return
        }

        let target = userInfo["target"] as? String ?? ""

        await MainActor.run {
            onNotificationActivated(action: action, target: target)
        }
    }
}
