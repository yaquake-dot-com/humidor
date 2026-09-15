// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import NicotineCore
import Observation
import SwiftUI

/// Buddy list, shown as a page or next to chat rooms.
@MainActor
@Observable
final class BuddiesPage: MainPage {

    /// Sort value for buddies that are online
    private static let lastSeenOnline = Int.max

    @ObservationIgnored let window: MainWindow
    @ObservationIgnored private(set) var listView: TreeView!
    @ObservationIgnored private var popupMenu: UserPopupMenu!

    var buddyText = ""
    private(set) var hasBuddies = false

    init(window: MainWindow) {
        self.window = window

        listView = TreeView(
            columns: [
                // Visible columns
                TreeColumn(id: "status", title: String(localized: "Status"), kind: .icon, width: 25, hidesHeader: true),
                TreeColumn(id: "country", title: String(localized: "Country"), kind: .icon, width: 30,
                           hidesHeader: true),
                TreeColumn(id: "user", title: String(localized: "User"), width: 250, defaultSortOrder: .ascending,
                           isIteratorKey: true),
                TreeColumn(id: "speed", title: String(localized: "Speed"), kind: .number, width: 150,
                           sortColumn: "speed_data"),
                TreeColumn(id: "files", title: String(localized: "Files"), kind: .number, width: 150,
                           sortColumn: "files_data"),
                TreeColumn(id: "trusted", title: String(localized: "Trusted"), kind: .toggle, width: 0,
                           toggleCallback: { [unowned self] in onTrusted($0, $1) }),
                TreeColumn(id: "notify", title: String(localized: "Notify"), kind: .toggle, width: 0,
                           toggleCallback: { [unowned self] in onNotify($0, $1) }),
                TreeColumn(id: "privileged", title: String(localized: "Prioritized"), kind: .toggle, width: 0,
                           toggleCallback: { [unowned self] in onPrioritized($0, $1) }),
                TreeColumn(id: "last_seen", title: String(localized: "Last Seen"), width: 160,
                           sortColumn: "last_seen_data"),
                TreeColumn(id: "comments", title: String(localized: "Note"), width: 400),

                // Hidden data columns
                .data("speed_data"),
                .data("files_data"),
                .data("last_seen_data")
            ],
            persistentSort: true, name: "buddy_list",
            activateRow: { [unowned self] _, _, columnID in onRowActivated(columnID) },
            deleteAccelerator: { [unowned self] _ in onRemoveBuddy() }
        )

        // Popup menus
        popupMenu = UserPopupMenu(tabName: .userList) { [unowned self] menu in onPopupMenu(menu) }
        popupMenu.addItems(
            .action(String(localized: "Add User Note…")) { [unowned self] in onAddNote() },
            .separator,
            .action(String(localized: "Remove")) { [unowned self] in onRemoveBuddy() }
        )
        listView.popupMenu = popupMenu

        events.connect(.addBuddy) { [unowned self] in addBuddy($0.username, buddy: $0.buddy) }
        events.connect(.buddyNote) { [unowned self] in setValue($0.username, "comments", .string($0.value)) }
        events.connect(.buddyNotify) { [unowned self] in setValue($0.username, "notify", .bool($0.value)) }
        events.connect(.buddyLastSeen) { [unowned self] in buddyLastSeen($0.username, isOnline: $0.value) }
        events.connect(.buddyPrioritized) { [unowned self] in setValue($0.username, "privileged", .bool($0.value)) }
        events.connect(.buddyTrusted) { [unowned self] in setValue($0.username, "trusted", .bool($0.value)) }
        events.connect(.removeBuddy) { [unowned self] in removeBuddy($0) }
        events.connect(.serverDisconnect) { [unowned self] _ in serverDisconnect() }
        events.connect(.start) { [unowned self] in start() }
        events.connect(.userCountry) { [unowned self] in userCountry($0) }
        events.connect(.userStats) { [unowned self] in userStats($0) }
        events.connectMessage(.userStatus) { [unowned self] in userStatus($0) }
    }

    private func start() {
        listView.freeze()

        for (username, buddy) in core.buddies.users {
            addBuddy(username, buddy: buddy, selectRow: false)
        }

        listView.unfreeze()
    }

    func onFocus() {
        updateVisible()

        if hasBuddies {
            listView.grabFocus()
        }
    }

    /// Whether the buddy list is shown in its own page
    var isShownAsPage: Bool {
        !["always", "chatrooms"].contains(config.ui.buddyListInChatrooms)
    }

    private func updateVisible() {
        hasBuddies = !listView.isEmpty
    }

    private var selectedUsername: String? {
        listView.selectedRows.first.map { listView.rowValue($0, "user").string }
    }

    private func onRowActivated(_ columnID: String) {
        guard let user = selectedUsername else {
            return
        }

        if columnID == "comments" {
            onAddNote()
            return
        }

        core.privateChat.showUser(user)
    }

    private func onPopupMenu(_ menu: PopupMenu) {
        guard let menu = menu as? UserPopupMenu else {
            return
        }

        menu.setUser(selectedUsername)
        menu.toggleUserItems()
    }

    private func setValue(_ user: String, _ columnID: String, _ value: TreeValue) {
        if let row = listView.iterators[.string(user)] {
            listView.setRowValue(row, columnID, value)
        }
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

    private func userStats(_ msg: GetUserStats) {
        guard let row = listView.iterators[.string(msg.user)] else {
            return
        }

        let speed = msg.avgSpeed
        let numFiles = msg.files
        var values: [String: TreeValue] = [:]

        if speed != listView.rowValue(row, "speed_data").int {
            values["speed"] = .string(speed > 0 ? humanSpeed(speed) : "")
            values["speed_data"] = .int(speed)
        }

        if numFiles != listView.rowValue(row, "files_data").int {
            values["files"] = .string(humanize(numFiles))
            values["files_data"] = .int(numFiles)
        }

        if !values.isEmpty {
            listView.setRowValues(row, values)
        }
    }

    private static let lastSeenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yyyy HH:mm:ss"
        return formatter
    }()

    private func addBuddy(_ user: String, buddy: Buddy, selectRow: Bool = true) {
        let countryCode = buddy.country.replacingOccurrences(of: "flag_", with: "")
        let stats = core.users.watched[user]
        let speed = stats?.uploadSpeed ?? 0
        let files = stats?.files
        var lastSeen = Self.lastSeenOnline
        var humanLastSeen = ""

        if !buddy.lastSeen.isEmpty {
            if let date = Self.lastSeenFormatter.date(from: buddy.lastSeen) {
                lastSeen = Int(date.timeIntervalSince1970)
                humanLastSeen = formatTimestamp("%x %X", date: date)
            } else {
                lastSeen = 0
                humanLastSeen = String(localized: "Never seen")
            }
        }

        listView.addRow([
            .string(Theme.userStatusIconName(buddy.status)),
            .string(Theme.flagIconName(countryCode)),
            .string(user),
            .string(speed > 0 ? humanSpeed(speed) : ""),
            .string(files.map(humanize) ?? ""),
            .bool(buddy.isTrusted),
            .bool(buddy.notifyStatus),
            .bool(buddy.isPrioritized),
            .string(humanLastSeen),
            .string(buddy.note),
            .int(speed),
            .int(files ?? 0),
            .int(lastSeen)
        ], selectRow: selectRow)

        if !window.buddyUsernames.contains(user) {
            window.buddyUsernames.append(user)
        }

        updateVisible()
    }

    private func removeBuddy(_ user: String) {
        guard let row = listView.iterators[.string(user)] else {
            return
        }

        listView.removeRow(row)
        updateVisible()
        window.buddyUsernames.removeAll { $0 == user }
    }

    private func buddyLastSeen(_ user: String, isOnline: Bool) {
        guard let row = listView.iterators[.string(user)] else {
            return
        }

        var lastSeen = Self.lastSeenOnline
        var humanLastSeen = ""

        if !isOnline {
            let date = Date()
            lastSeen = Int(date.timeIntervalSince1970)
            humanLastSeen = formatTimestamp("%x %X", date: date)
        }

        listView.setRowValues(row, ["last_seen": .string(humanLastSeen), "last_seen_data": .int(lastSeen)])
    }

    private func userCountry(_ event: UserCountryEvent) {
        guard let row = listView.iterators[.string(event.username)] else {
            return
        }

        let flagIconName = Theme.flagIconName(event.countryCode)

        if !flagIconName.isEmpty && flagIconName != listView.rowValue(row, "country").string {
            listView.setRowValue(row, "country", .string(flagIconName))
        }
    }

    func onAddBuddy() {
        let username = buddyText.trimmingCharacters(in: .whitespaces)

        guard !username.isEmpty else {
            return
        }

        buddyText = ""
        core.buddies.addBuddy(username)
        listView.grabFocus()
    }

    private func onRemoveBuddy() {
        if let user = selectedUsername {
            core.buddies.removeBuddy(user)
        }
    }

    private func onTrusted(_ listView: TreeView, _ row: TreeRow) {
        let user = listView.rowValue(row, "user").string
        core.buddies.setBuddyTrusted(user, trusted: !listView.rowValue(row, "trusted").bool)
    }

    private func onNotify(_ listView: TreeView, _ row: TreeRow) {
        let user = listView.rowValue(row, "user").string
        core.buddies.setBuddyNotify(user, notify: !listView.rowValue(row, "notify").bool)
    }

    private func onPrioritized(_ listView: TreeView, _ row: TreeRow) {
        let user = listView.rowValue(row, "user").string
        core.buddies.setBuddyPrioritized(user, prioritized: !listView.rowValue(row, "privileged").bool)
    }

    private func onAddNote() {
        guard let user = selectedUsername, let row = listView.iterators[.string(user)] else {
            return
        }

        let note = listView.rowValue(row, "comments").string

        EntryDialog(
            title: String(localized: "Add User Note"),
            message: String(localized: "Add a note about user \(user):"),
            defaultText: note,
            actionButtonLabel: String(localized: "Add")
        ) { [weak self] dialog, _ in
            guard self?.listView.iterators[.string(user)] != nil, let note = (dialog as? EntryDialog)?.entryValue else {
                return
            }
            core.buddies.setBuddyNote(user, note: note)
        }.present()
    }

    private func serverDisconnect() {
        for row in listView.iterators.values {
            listView.setRowValue(row, "status", .string(Theme.userStatusIconName(.offline)))
        }
    }

    // MARK: Views

    /// Buddy list with a side toolbar, shown next to chat rooms or the main pages.
    var content: some View {
        BuddyListSideView(page: self)
    }

    /// Buddy list shown in its own page.
    var pageContent: some View {
        BuddyListPageView(page: self)
    }
}

/// Buddy list shown next to chat rooms or the main pages.
private struct BuddyListSideView: View {

    @Bindable var page: BuddiesPage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Buddies"))
                    .font(.headline)

                TextField(String(localized: "Add buddy…"), text: $page.buddyText)
                    .onSubmit { page.onAddBuddy() }
            }
            .padding(8)

            Divider()
            page.listView.view
        }
    }
}

/// Buddy list shown in its own page.
private struct BuddyListPageView: View {

    @Bindable var page: BuddiesPage

    var body: some View {
        Group {
            if page.hasBuddies {
                page.listView.view
            } else {
                PageDescription(
                    systemImage: "person.2",
                    title: String(localized: "Buddies"),
                    description: String(localized: "Add users as buddies to share specific folders with them and receive notifications when they are online")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    TextField(String(localized: "Add buddy…"), text: $page.buddyText)
                        .onSubmit { page.onAddBuddy() }
                        .frame(minWidth: 200, idealWidth: 300, maxWidth: 400)

                    Button {
                        page.onAddBuddy()
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                }
            }

            ToolbarItemGroup {
                Button {
                    Application.shared.onMessageBuddies()
                } label: {
                    Label(String(localized: "Message All"), systemImage: "paperplane")
                        .labelStyle(.titleAndIcon)
                }

                Button {
                    Application.shared.onConfigureIgnoredUsers()
                } label: {
                    Label(String(localized: "Configure Ignored Users"), systemImage: "gearshape")
                }
                .help(String(localized: "Configure Ignored Users"))
            }
        }
    }
}
