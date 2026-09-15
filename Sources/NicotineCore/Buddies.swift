// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public final class Buddy {
    public let username: String
    public var note: String
    public var notifyStatus: Bool
    public var isPrioritized: Bool
    public var isTrusted: Bool
    public var lastSeen: String
    public var country: String
    public var status: UserStatus

    init(username: String, note: String, notifyStatus: Bool, isPrioritized: Bool, isTrusted: Bool, lastSeen: String,
         country: String, status: UserStatus) {
        self.username = username
        self.note = note
        self.notifyStatus = notifyStatus
        self.isPrioritized = isPrioritized
        self.isTrusted = isTrusted
        self.lastSeen = lastSeen
        self.country = country
        self.status = status
    }
}

public struct BuddyAdded {
    public var username: String
    public var buddy: Buddy
}

public struct BuddyChange<Value> {
    public var username: String
    public var value: Value
}

public extension EventName where Payload == BuddyAdded {
    static var addBuddy: Self { .init("add-buddy") }
}

public extension EventName where Payload == String {
    static var removeBuddy: Self { .init("remove-buddy") }
}

public extension EventName where Payload == BuddyChange<String> {
    static var buddyNote: Self { .init("buddy-note") }
}

public extension EventName where Payload == BuddyChange<Bool> {
    static var buddyNotify: Self { .init("buddy-notify") }
    static var buddyPrioritized: Self { .init("buddy-prioritized") }
    static var buddyTrusted: Self { .init("buddy-trusted") }
    /// Value indicates if the buddy is online
    static var buddyLastSeen: Self { .init("buddy-last-seen") }
}

@MainActor
public final class Buddies {

    public private(set) var users = OrderedDictionary<String, Buddy>()
    private var allowSavingBuddies = false

    init() {
        events.connect(.quit) { [self] in
            users.removeAll()
            allowSavingBuddies = false
        }
        events.connect(.serverLogin) { [self] msg in serverLogin(msg) }
        events.connect(.serverDisconnect) { [self] _ in serverDisconnect() }
        events.connect(.start) { [self] in start() }
        events.connect(.userCountry) { [self] event in userCountry(event) }
        events.connect(.userStatus) { [self] msg in userStatus(msg) }
    }

    private func start() {
        for entry in config.server.userList where users[entry.username] == nil {
            users[entry.username] = Buddy(
                username: entry.username, note: entry.note, notifyStatus: entry.notifyStatus,
                isPrioritized: entry.isPrioritized, isTrusted: entry.isTrusted, lastSeen: entry.lastSeen,
                country: entry.country, status: .offline
            )
        }

        allowSavingBuddies = true
    }

    private func serverLogin(_ msg: Login) {
        guard msg.success else {
            return
        }

        for username in users.keys {
            core.users.watchUser(username, context: "buddies")
        }
    }

    private func serverDisconnect() {
        for (username, userData) in users {
            userData.status = .offline
            setBuddyLastSeen(username, isOnline: false)
        }

        saveBuddyList()
    }

    public func addBuddy(_ username: String) {
        guard users[username] == nil else {
            return
        }

        let countryCode = core.users.countries[username]
        let country = countryCode.map { "flag_\($0)" } ?? ""
        let status = core.users.statuses[username] ?? .offline
        let lastSeen = status == .offline ? "Never seen" : ""

        let userData = Buddy(username: username, note: "", notifyStatus: false, isPrioritized: false, isTrusted: false,
                             lastSeen: lastSeen, country: country, status: status)
        users[username] = userData

        if config.words.buddies {
            core.chatrooms.updateCompletions()
            core.privateChat.updateCompletions()
        }

        saveBuddyList()
        events.emit(.addBuddy, BuddyAdded(username: username, buddy: userData))

        // Request user status, speed and number of shared files
        core.users.watchUser(username, context: "buddies")
    }

    public func removeBuddy(_ username: String) {
        users.removeValue(forKey: username)

        if config.words.buddies {
            core.chatrooms.updateCompletions()
            core.privateChat.updateCompletions()
        }

        core.users.unwatchUser(username, context: "buddies")
        saveBuddyList()
        events.emit(.removeBuddy, username)
    }

    public func setBuddyNote(_ username: String, note: String) {
        guard let buddy = users[username] else {
            return
        }

        buddy.note = note
        saveBuddyList()

        events.emit(.buddyNote, BuddyChange(username: username, value: note))
    }

    public func setBuddyNotify(_ username: String, notify: Bool) {
        guard let buddy = users[username] else {
            return
        }

        buddy.notifyStatus = notify
        saveBuddyList()

        events.emit(.buddyNotify, BuddyChange(username: username, value: notify))
    }

    public func setBuddyPrioritized(_ username: String, prioritized: Bool) {
        guard let buddy = users[username] else {
            return
        }

        buddy.isPrioritized = prioritized
        saveBuddyList()

        events.emit(.buddyPrioritized, BuddyChange(username: username, value: prioritized))
    }

    public func setBuddyTrusted(_ username: String, trusted: Bool) {
        guard let buddy = users[username] else {
            return
        }

        buddy.isTrusted = trusted
        saveBuddyList()

        events.emit(.buddyTrusted, BuddyChange(username: username, value: trusted))
    }

    public func setBuddyLastSeen(_ username: String, isOnline: Bool) {
        guard let buddy = users[username] else {
            return
        }

        if isOnline {
            buddy.lastSeen = ""

        } else if buddy.lastSeen.isEmpty {
            buddy.lastSeen = formatTimestamp("%m/%d/%Y %H:%M:%S")

        } else {
            return
        }

        events.emit(.buddyLastSeen, BuddyChange(username: username, value: isOnline))
    }

    private func userCountry(_ event: UserCountryEvent) {
        guard !event.countryCode.isEmpty, let buddy = users[event.username] else {
            return
        }

        buddy.country = "flag_\(event.countryCode)"
    }

    public func saveBuddyList() {
        guard allowSavingBuddies else {
            return
        }

        config.server.userList = users.values.map { buddy in
            BuddyEntry(username: buddy.username, note: buddy.note, notifyStatus: buddy.notifyStatus,
                       isPrioritized: buddy.isPrioritized, isTrusted: buddy.isTrusted, lastSeen: buddy.lastSeen,
                       country: buddy.country)
        }
        config.writeConfiguration()
    }

    /// Server code 7.
    private func userStatus(_ msg: GetUserStatus) {
        let username = msg.user

        guard let buddy = users[username], msg.status != buddy.status.rawValue else {
            // Buddy status didn't change, don't show notification
            return
        }

        let status = UserStatus(rawValue: msg.status) ?? .offline
        buddy.status = status
        setBuddyLastSeen(username, isOnline: msg.status != UserStatus.offline.rawValue)

        guard buddy.notifyStatus else {
            return
        }

        let statusText: String

        switch status {
        case .away:
            statusText = String(localized: "\(username) is away", bundle: .module)
        case .online:
            statusText = String(localized: "\(username) is online", bundle: .module)
        case .offline:
            statusText = String(localized: "\(username) is offline", bundle: .module)
        }

        log.add(statusText)
        core.notifications?.showNotification(statusText, title: String(localized: "Buddy Status", bundle: .module))
    }
}
