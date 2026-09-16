// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore

/// A context menu built from a list of items. Menus are updated by a callback
/// right before they are shown, allowing items to be enabled, disabled or
/// checked depending on the current selection.
@MainActor
class PopupMenu: NSObject {

    enum Item {
        /// A regular item
        case action(String, @MainActor () -> Void)
        /// A regular item that is hidden while disabled
        case hiddenWhenDisabled(String, @MainActor () -> Void)
        /// A checkbox item. The handler receives the new state.
        case toggle(String, @MainActor (Bool) -> Void)
        /// A radio item, part of a group of choices. The handler receives the chosen value.
        case choice(String, value: String, @MainActor (String) -> Void)
        case submenu(String, PopupMenu)
        case separator
    }

    let menu = NSMenu()
    var callback: (@MainActor (PopupMenu) -> Void)?

    private(set) var items: [String: NSMenuItem] = [:]
    private var handlers: [ObjectIdentifier: @MainActor (NSMenuItem) -> Void] = [:]
    private(set) var submenus: [PopupMenu] = []
    private var submenuItems: [(menuItem: NSMenuItem, popupMenu: PopupMenu)] = []

    init(callback: (@MainActor (PopupMenu) -> Void)? = nil) {
        self.callback = callback
        super.init()
        menu.autoenablesItems = false
    }

    func addItems(_ newItems: Item...) {
        addItems(newItems)
    }

    func addItems(_ newItems: [Item]) {
        for item in newItems {
            addItem(item)
        }
    }

    private func addItem(_ item: Item) {
        let menuItem: NSMenuItem
        let label: String

        switch item {
        case .separator:
            // Avoid consecutive or leading separators, like menu sections
            if let lastItem = menu.items.last, !lastItem.isSeparatorItem {
                menu.addItem(.separator())
            }
            return

        case let .action(title, handler), let .hiddenWhenDisabled(title, handler):
            label = title
            menuItem = makeMenuItem(title) { _ in handler() }

            if case .hiddenWhenDisabled = item {
                menuItem.representedObject = HiddenWhenDisabled()
            }

        case let .toggle(title, handler):
            label = title
            menuItem = makeMenuItem(title) { menuItem in
                let newState = (menuItem.state != .on)
                handler(newState)
                menuItem.state = newState ? .on : .off
            }

        case let .choice(title, value, handler):
            label = title
            menuItem = makeMenuItem(title) { [weak self] _ in
                self?.setChoice(value)
                handler(value)
            }
            menuItem.representedObject = ChoiceValue(value: value)

        case let .submenu(title, popupMenu):
            label = title
            menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            submenus.append(popupMenu)
            submenuItems.append((menuItem, popupMenu))

            // A menu can only be the submenu of one menu at a time. Menus shared by
            // several menus are attached when shown.
            if popupMenu.menu.supermenu == nil {
                menuItem.submenu = popupMenu.menu
            }
        }

        items[label] = menuItem
        menu.addItem(menuItem)
    }

    private func makeMenuItem(_ title: String, handler: @escaping @MainActor (NSMenuItem) -> Void) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: #selector(activateItem(_:)), keyEquivalent: "")
        menuItem.target = self
        handlers[ObjectIdentifier(menuItem)] = handler
        return menuItem
    }

    @objc private func activateItem(_ sender: NSMenuItem) {
        handlers[ObjectIdentifier(sender)]?(sender)
    }

    func clear() {
        for submenu in submenus {
            submenu.clear()
        }
        submenus.removeAll()

        for (menuItem, _) in submenuItems {
            menuItem.submenu = nil
        }
        submenuItems.removeAll()
        menu.removeAllItems()
        items.removeAll()
        handlers.removeAll()
    }

    // MARK: Item State

    func setEnabled(_ label: String, _ isEnabled: Bool) {
        guard let menuItem = items[label] else {
            return
        }

        menuItem.isEnabled = isEnabled

        if menuItem.representedObject is HiddenWhenDisabled {
            menuItem.isHidden = !isEnabled
        }
    }

    func setState(_ label: String, _ isActive: Bool) {
        items[label]?.state = isActive ? .on : .off
    }

    func setLabel(_ label: String, _ title: String) {
        items[label]?.title = title
    }

    func setChoice(_ value: String) {
        for menuItem in menu.items {
            guard let choice = menuItem.representedObject as? ChoiceValue else {
                continue
            }
            menuItem.state = (choice.value == value) ? .on : .off
        }
    }

    // MARK: Showing

    /// Updates the menu before it is shown.
    func prepare() {
        attachSubmenus()
        callback?(self)

        for submenu in submenus {
            submenu.prepare()
        }
    }

    func popup(in view: NSView, at point: NSPoint? = nil) {
        prepare()

        let location = point ?? NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY : 0)
        menu.popUp(positioning: nil, at: location, in: view)
    }

    private func attachSubmenus() {
        for (menuItem, popupMenu) in submenuItems where menuItem.submenu !== popupMenu.menu {
            if let supermenu = popupMenu.menu.supermenu {
                for item in supermenu.items where item.submenu === popupMenu.menu {
                    item.submenu = nil
                }
            }
            menuItem.submenu = popupMenu.menu
        }
    }

    /// Shows the menu at the mouse pointer.
    func popupAtMouseLocation() {
        prepare()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private final class HiddenWhenDisabled {}

    private final class ChoiceValue {
        let value: String

        init(value: String) {
            self.value = value
        }
    }
}

// MARK: - File Menu

/// Context menu showing the number of selected files as its first item.
@MainActor
class FilePopupMenu: PopupMenu {

    private static let selectedFilesLabel = "selected_files"

    override init(callback: (@MainActor (PopupMenu) -> Void)? = nil) {
        super.init(callback: callback)

        addItems(
            .action(Self.selectedFilesLabel) {},
            .separator
        )
    }

    func setNumSelectedFiles(_ numFiles: Int) {
        setEnabled(Self.selectedFilesLabel, false)
        setLabel(Self.selectedFilesLabel, String(localized: "\(numFiles) File(s) Selected"))
    }
}

// MARK: - User Menu

/// Context menu with common actions for a user.
@MainActor
final class UserPopupMenu: PopupMenu {

    enum TabName {
        case userInfo
        case privateChat
        case userBrowse
        case userList
        case privateRooms
        case other
    }

    private static let usernameLabel = "username"

    private(set) var username: String?
    private let tabName: TabName
    private var privateRoomsMenu: UserPopupMenu?

    init(username: String? = nil, tabName: TabName = .other, callback: (@MainActor (PopupMenu) -> Void)? = nil) {
        self.tabName = tabName
        super.init(callback: callback)

        if tabName != .privateRooms {
            privateRoomsMenu = UserPopupMenu(username: username, tabName: .privateRooms)
            setupUserMenu(username)
        }
    }

    func setupUserMenu(_ username: String?) {
        setUser(username)

        addItems(
            .action(Self.usernameLabel) { [unowned self] in onCopyUser() },
            .separator
        )

        if tabName != .userInfo {
            addItems(.action(String(localized: "View User Profile")) { [unowned self] in onUserProfile() })
        }
        if tabName != .privateChat {
            addItems(.action(String(localized: "Send Message")) { [unowned self] in onSendMessage() })
        }
        if tabName != .userBrowse {
            addItems(.action(String(localized: "Browse Files")) { [unowned self] in onBrowseUser() })
        }
        if tabName != .userList {
            addItems(.toggle(String(localized: "Add Buddy")) { [unowned self] in onAddToList($0) })
        }

        addItems(
            .separator,
            .toggle(String(localized: "Ban User")) { [unowned self] in onBanUser($0) },
            .toggle(String(localized: "Ignore User")) { [unowned self] in onIgnoreUser($0) },
            .separator,
            .toggle(String(localized: "Ban IP Address")) { [unowned self] in onBanIP($0) },
            .toggle(String(localized: "Ignore IP Address")) { [unowned self] in onIgnoreIP($0) },
            .action(String(localized: "Show IP Address")) { [unowned self] in onShowIPAddress() },
            .separator
        )

        if let privateRoomsMenu {
            addItems(.submenu(String(localized: "Private Rooms"), privateRoomsMenu))
        }

        updateUsernameItem()
    }

    private func updateUsernameItem() {
        guard let username else {
            return
        }
        setLabel(Self.usernameLabel, username)
    }

    func setUser(_ username: String?) {
        guard username != self.username else {
            return
        }

        self.username = username
        updateUsernameItem()
        privateRoomsMenu?.setUser(username)
    }

    func toggleUserItems() {
        guard let username else {
            return
        }

        let localUsername = core.users.loginUsername ?? config.server.login

        setState(String(localized: "Add Buddy"), core.buddies.users[username] != nil)

        for (label, value) in [
            (String(localized: "Ban User"), core.networkFilter.isUserBanned(username)),
            (String(localized: "Ignore User"), core.networkFilter.isUserIgnored(username)),
            (String(localized: "Ban IP Address"), core.networkFilter.isUserIPBanned(username: username)),
            (String(localized: "Ignore IP Address"), core.networkFilter.isUserIPIgnored(username: username))
        ] {
            // Disable menu item if it's our own username and we haven't banned ourselves before
            setEnabled(label, username != localUsername || value)
            setState(label, value)
        }

        privateRoomsMenu?.populatePrivateRooms()
        setEnabled(String(localized: "Private Rooms"), !(privateRoomsMenu?.items.isEmpty ?? true))
    }

    private func populatePrivateRooms() {
        clear()

        guard let username else {
            return
        }

        for (room, data) in core.chatrooms.privateRooms {
            let isOwned = core.chatrooms.isPrivateRoomOwned(room)
            let isOperator = core.chatrooms.isPrivateRoomOperator(room)

            guard isOwned || isOperator, username != data.owner else {
                continue
            }

            let isUserMember = data.members.contains(username)
            let isUserOperator = data.operators.contains(username)

            if !isUserOperator {
                if isUserMember {
                    addItems(.action(String(localized: "Remove from Private Room \(room)")) {
                        core.chatrooms.removeUserFromPrivateRoom(room, username: username)
                    })
                } else {
                    addItems(.action(String(localized: "Add to Private Room \(room)")) {
                        core.chatrooms.addUserToPrivateRoom(room, username: username)
                    })
                }
            }

            guard isOwned else {
                continue
            }

            if isUserOperator {
                addItems(.action(String(localized: "Remove as Operator of \(room)")) {
                    core.chatrooms.removeOperatorFromPrivateRoom(room, username: username)
                })
            } else if isUserMember {
                addItems(.action(String(localized: "Add as Operator of \(room)")) {
                    core.chatrooms.addOperatorToPrivateRoom(room, username: username)
                })
            }

            addItems(.separator)
        }
    }

    // MARK: Events

    func onSearchUser() {
        guard let username else {
            return
        }
        MainWindow.shared?.searchUser(username)
    }

    private func onSendMessage() {
        guard let username else { return }
        core.privateChat.showUser(username)
    }

    private func onShowIPAddress() {
        guard let username else { return }
        core.users.requestIPAddress(username, notify: true)
    }

    private func onUserProfile() {
        guard let username else { return }
        core.userInfo.showUser(username)
    }

    private func onBrowseUser() {
        guard let username else { return }
        core.userBrowse.browseUser(username)
    }

    private func onAddToList(_ isActive: Bool) {
        guard let username else { return }

        if isActive {
            core.buddies.addBuddy(username)
        } else {
            core.buddies.removeBuddy(username)
        }
    }

    private func onBanUser(_ isActive: Bool) {
        guard let username else { return }

        if isActive {
            core.networkFilter.banUser(username)
        } else {
            core.networkFilter.unbanUser(username)
        }
    }

    private func onBanIP(_ isActive: Bool) {
        guard let username else { return }

        if isActive {
            _ = core.networkFilter.banUserIP(username: username)
        } else {
            _ = core.networkFilter.unbanUserIP(username: username)
        }
    }

    private func onIgnoreIP(_ isActive: Bool) {
        guard let username else { return }

        if isActive {
            _ = core.networkFilter.ignoreUserIP(username: username)
        } else {
            _ = core.networkFilter.unignoreUserIP(username: username)
        }
    }

    private func onIgnoreUser(_ isActive: Bool) {
        guard let username else { return }

        if isActive {
            core.networkFilter.ignoreUser(username)
        } else {
            core.networkFilter.unignoreUser(username)
        }
    }

    private func onCopyUser() {
        guard let username else { return }
        Clipboard.copyText(username)
    }
}
