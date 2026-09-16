// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore

/// A menu item running a closure, optionally enabled depending on a condition.
@MainActor
final class ActionMenuItem: NSMenuItem, NSMenuItemValidation {

    private let handler: @MainActor () -> Void
    private let isEnabledHandler: (@MainActor () -> Bool)?

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
         isEnabled: (@MainActor () -> Bool)? = nil, handler: @escaping @MainActor () -> Void) {

        self.handler = handler
        self.isEnabledHandler = isEnabled

        super.init(title: title, action: #selector(activate(_:)), keyEquivalent: key)

        target = self
        keyEquivalentModifierMask = modifiers
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func activate(_ sender: Any?) {
        handler()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        isEnabledHandler?() ?? true
    }
}

/// The application menu bar.
@MainActor
enum MainMenu {

    static func create(application: Application) -> NSMenu {
        let mainMenu = NSMenu()

        for menu in [
            appMenu(application),
            fileMenu(application),
            editMenu(),
            viewMenu(),
            sharesMenu(application),
            windowMenu(),
            helpMenu(application)
        ] {
            let menuItem = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            menuItem.submenu = menu
            mainMenu.addItem(menuItem)
        }

        return mainMenu
    }

    private static func isOnline() -> Bool {
        Application.shared.isOnline
    }

    private static func appMenu(_ application: Application) -> NSMenu {
        let menu = NSMenu(title: HumidorCore.Application.name)

        menu.addItem(ActionMenuItem(String(localized: "About \(HumidorCore.Application.name)")) { application.onAbout() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(String(localized: "Preferences…"), key: ",") { application.onPreferences() })
        menu.addItem(.separator())

        let servicesItem = NSMenuItem(title: String(localized: "Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(servicesItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: String(localized: "Hide \(HumidorCore.Application.name)"), action: #selector(NSApplication.hide(_:)),
                                keyEquivalent: "h"))

        let hideOthersItem = NSMenuItem(title: String(localized: "Hide Others"),
                                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthersItem)

        menu.addItem(NSMenuItem(title: String(localized: "Show All"),
                                action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        menu.addItem(.separator())

        menu.addItem(ActionMenuItem(String(localized: "Force Quit"), key: "q", modifiers: [.command, .option]) {
            application.onForceQuitRequest()
        })
        menu.addItem(ActionMenuItem(String(localized: "Quit \(HumidorCore.Application.name)"), key: "q") {
            application.onConfirmQuitRequest()
        })

        return menu
    }

    private static func fileMenu(_ application: Application) -> NSMenu {
        let menu = NSMenu(title: String(localized: "File"))

        menu.addItem(ActionMenuItem(String(localized: "Connect"), key: "c", modifiers: [.command, .shift],
                                    isEnabled: { !isOnline() }) { application.onConnect() })
        menu.addItem(ActionMenuItem(String(localized: "Disconnect"), key: "d", modifiers: [.command, .shift],
                                    isEnabled: isOnline) { application.onDisconnect() })
        menu.addItem(ActionMenuItem(String(localized: "Soulseek Privileges"), isEnabled: isOnline) {
            application.onSoulseekPrivileges()
        })
        menu.addItem(ActionMenuItem(String(localized: "Away"), key: "a", modifiers: [.command, .shift],
                                    isEnabled: isOnline) { application.onAwayAccelerator() })
        menu.addItem(.separator())

        menu.addItem(ActionMenuItem(String(localized: "Wishlist"), key: "w", modifiers: [.command, .shift]) {
            application.onWishlist()
        })
        menu.addItem(ActionMenuItem(String(localized: "Message Downloading Users"), isEnabled: isOnline) {
            application.onMessageDownloadingUsers()
        })
        menu.addItem(ActionMenuItem(String(localized: "Message Buddies"), isEnabled: isOnline) {
            application.onMessageBuddies()
        })
        menu.addItem(.separator())

        menu.addItem(ActionMenuItem(String(localized: "Reopen Closed Tab"), key: "t", modifiers: [.command, .shift]) {
            MainWindow.shared?.reopenClosedTab()
        })
        menu.addItem(ActionMenuItem(String(localized: "Close Tab"), key: "w") {
            onCloseTab()
        })

        return menu
    }

    private static func onCloseTab() {
        let keyWindow = NSApp.keyWindow

        if let mainWindow = MainWindow.shared, keyWindow === mainWindow.window {
            _ = mainWindow.closeTab()
            return
        }

        keyWindow?.performClose(nil)
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit"))

        menu.addItem(NSMenuItem(title: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z"))

        let redoItem = NSMenuItem(title: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redoItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: String(localized: "Copy"), action: #selector(NSText.copy(_:)),
                                keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: String(localized: "Paste"), action: #selector(NSText.paste(_:)),
                                keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)),
                                keyEquivalent: "a"))
        menu.addItem(.separator())

        let findItem = NSMenuItem(title: String(localized: "Find…"), action: #selector(NSResponder.performTextFinderAction(_:)),
                                  keyEquivalent: "f")
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        menu.addItem(findItem)

        let findNextItem = NSMenuItem(title: String(localized: "Find Next Match"),
                                      action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "g")
        findNextItem.tag = NSTextFinder.Action.nextMatch.rawValue
        menu.addItem(findNextItem)

        let findPreviousItem = NSMenuItem(title: String(localized: "Find Previous Match"),
                                          action: #selector(NSResponder.performTextFinderAction(_:)),
                                          keyEquivalent: "g")
        findPreviousItem.tag = NSTextFinder.Action.previousMatch.rawValue
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(findPreviousItem)

        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "View"))

        menu.addItem(ActionMenuItem(String(localized: "Show Log Pane"), key: "l") {
            MainWindow.shared?.isLogPaneVisible.toggle()
        })
        menu.addItem(.separator())

        menu.addItem(ActionMenuItem(String(localized: "Next Tab"), key: "\t", modifiers: .control) {
            MainWindow.shared?.cycleTabs()
        })
        menu.addItem(ActionMenuItem(String(localized: "Previous Tab"), key: "\t", modifiers: [.control, .shift]) {
            MainWindow.shared?.cycleTabs(backwards: true)
        })
        menu.addItem(.separator())

        for number in 1..<10 {
            menu.addItem(ActionMenuItem(String(localized: "Go to Tab \(number)"), key: String(number)) {
                MainWindow.shared?.changePrimaryTab(number)
            })
        }

        menu.addItem(.separator())

        let fullScreenItem = NSMenuItem(title: String(localized: "Enter Full Screen"),
                                        action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreenItem)

        return menu
    }

    private static func sharesMenu(_ application: Application) -> NSMenu {
        let menu = NSMenu(title: String(localized: "Shares"))

        menu.addItem(ActionMenuItem(String(localized: "Rescan Shares"), key: "r", modifiers: [.command, .shift]) {
            application.onRescanShares()
        })
        menu.addItem(ActionMenuItem(String(localized: "Configure Shares")) { application.onConfigureShares() })
        menu.addItem(.separator())

        menu.addItem(ActionMenuItem(String(localized: "Browse Public Shares")) { application.onBrowsePublicShares() })
        menu.addItem(ActionMenuItem(String(localized: "Browse Buddy Shares")) { application.onBrowseBuddyShares() })
        menu.addItem(ActionMenuItem(String(localized: "Browse Trusted Shares")) {
            application.onBrowseTrustedShares()
        })

        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window"))

        menu.addItem(NSMenuItem(title: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)),
                                keyEquivalent: "m"))
        menu.addItem(NSMenuItem(title: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(HumidorCore.Application.name, key: "0") {
            MainWindow.shared?.present()
        })

        NSApp.windowsMenu = menu
        return menu
    }

    private static func helpMenu(_ application: Application) -> NSMenu {
        let menu = NSMenu(title: String(localized: "Help"))

        menu.addItem(ActionMenuItem(String(localized: "Keyboard Shortcuts"), key: "?") {
            application.onKeyboardShortcuts()
        })
        menu.addItem(ActionMenuItem(String(localized: "Setup Assistant")) { application.onFastConfigure() })
        menu.addItem(ActionMenuItem(String(localized: "Transfer Statistics")) { application.onTransferStatistics() })

        if !application.isolatedMode {
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(String(localized: "Report a Bug")) { application.onReportBug() })
            menu.addItem(ActionMenuItem(String(localized: "Improve Translations")) {
                application.onImproveTranslations()
            })
        }

        NSApp.helpMenu = menu
        return menu
    }
}
