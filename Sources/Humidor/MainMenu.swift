// SPDX-License-Identifier: GPL-3.0-or-later

import HumidorCore
import SwiftUI

/// Commands of the application menu bar. Standard items (Hide, Quit, Edit, Minimize,
/// full screen…) are provided by the system.
struct MainCommands: Commands {

    let application: AppDelegate

    private var isOffline: Bool { !application.isOnline }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(String(localized: "About \(Application.name)")) { application.onAbout() }
        }

        CommandGroup(replacing: .newItem) {
            Button(String(localized: "Connect")) { application.onConnect() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(application.isOnline)
            Button(String(localized: "Disconnect")) { application.onDisconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(isOffline)
            Button(String(localized: "Soulseek Privileges")) { application.onSoulseekPrivileges() }
                .disabled(isOffline)
            Button(String(localized: "Away")) { application.onAwayAccelerator() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(isOffline)

            Divider()

            Button(String(localized: "Wishlist")) { application.onWishlist() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Button(String(localized: "Message Downloading Users")) { application.onMessageDownloadingUsers() }
                .disabled(isOffline)
            Button(String(localized: "Message Buddies")) { application.onMessageBuddies() }
                .disabled(isOffline)

            Divider()

            Button(String(localized: "Reopen Closed Tab")) { MainWindow.shared?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button(String(localized: "Close Tab")) { onCloseTab() }
                .keyboardShortcut("w")
        }

        TextEditingCommands()

        CommandGroup(before: .sidebar) {
            Button(String(localized: "Show Log Pane")) { MainWindow.shared?.isLogPaneVisible.toggle() }
                .keyboardShortcut("l")

            Divider()

            Button(String(localized: "Next Tab")) { MainWindow.shared?.cycleTabs() }
                .keyboardShortcut(.tab, modifiers: .control)
            Button(String(localized: "Previous Tab")) { MainWindow.shared?.cycleTabs(backwards: true) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

            Divider()

            ForEach(1..<10) { number in
                Button(String(localized: "Go to Tab \(number)")) { MainWindow.shared?.changePrimaryTab(number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))))
            }

            Divider()
        }

        CommandMenu(String(localized: "Shares")) {
            Button(String(localized: "Rescan Shares")) { application.onRescanShares() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button(String(localized: "Configure Shares")) { application.onConfigureShares() }

            Divider()

            Button(String(localized: "Browse Public Shares")) { application.onBrowsePublicShares() }
            Button(String(localized: "Browse Buddy Shares")) { application.onBrowseBuddyShares() }
            Button(String(localized: "Browse Trusted Shares")) { application.onBrowseTrustedShares() }
        }

        CommandGroup(after: .windowArrangement) {
            Divider()
            Button(String(localized: "Transfer Statistics")) { application.onTransferStatistics() }
        }

        CommandGroup(replacing: .help) {
            Button(String(localized: "Keyboard Shortcuts")) { application.onKeyboardShortcuts() }
                .keyboardShortcut("?")
            Button(String(localized: "Setup Assistant")) { application.onFastConfigure() }

            if !application.isolatedMode {
                Divider()
                Button(String(localized: "Report a Bug")) { application.onReportBug() }
                Button(String(localized: "Improve Translations")) { application.onImproveTranslations() }
            }
        }
    }

    private func onCloseTab() {
        if let mainWindow = MainWindow.shared, mainWindow.isActive {
            _ = mainWindow.closeTab()
            return
        }

        NSApp.keyWindow?.performClose(nil)
    }
}
