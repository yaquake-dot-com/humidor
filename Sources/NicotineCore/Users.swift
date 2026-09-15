// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct UserCountryEvent: Sendable {
    public var username: String
    public var countryCode: String
}

public extension EventName where Payload == UserCountryEvent {
    static var userCountry: Self { .init("user-country") }
}

public extension EventName where Payload == Void {
    static var invalidUsername: Self { .init("invalid-username") }
    static var invalidPassword: Self { .init("invalid-password") }
}

public final class WatchedUser {
    public let username: String
    public var uploadSpeed: Int?
    public var files: Int?
    public var folders: Int?
    public var contexts = Set<String>()
    public var isImplicit = true

    init(username: String) {
        self.username = username
    }
}

/// Statistics of a user, as reported to plugins.
public struct UserStats: Sendable {
    public var uploadSpeed: Int?
    public var files: Int?
    public var folders: Int?
    public var sharedSize: Int?
    public var source: String
}

@MainActor
public final class Users {

    public static let usernameMaxLength = 30

    public private(set) var loginStatus = UserStatus.offline
    /// Only present while logged in
    public private(set) var loginUsername: String?
    public private(set) var publicIPAddress: String?
    public private(set) var publicPort: Int?
    public private(set) var serverHostname: String?
    public private(set) var serverPort: Int?
    public private(set) var privilegesLeft: Int?
    private var shouldOpenPrivilegesURL = false

    public private(set) var addresses: [String: PeerAddress] = [:]
    public private(set) var countries: [String: String] = [:]
    public internal(set) var statuses: [String: UserStatus] = [:]
    public private(set) var watched: [String: WatchedUser] = [:]
    public private(set) var privileged = Set<String>()
    private var ipRequested: [String: Bool] = [:]
    private var pendingWatchRemovals = Set<String>()

    init() {
        events.connect(.adminMessage) { msg in Self.adminMessage(msg) }
        events.connect(.changePassword) { msg in Self.changePassword(msg) }
        events.connect(.checkPrivileges) { [self] msg in checkPrivileges(msg) }
        events.connect(.connectToPeer) { [self] msg in connectToPeer(msg) }
        events.connect(.peerAddress) { [self] msg in getPeerAddress(msg) }
        events.connect(.privilegedUsers) { [self] msg in privilegedUsers(msg) }
        events.connect(.serverDisconnect) { [self] msg in serverDisconnect(msg) }
        events.connect(.serverLogin) { [self] msg in serverLogin(msg) }
        events.connect(.userStats) { [self] msg in userStats(msg) }
        events.connect(.userStatus) { [self] msg in userStatus(msg) }
        events.connect(.watchUser) { [self] msg in watchUser(msg) }
    }

    public func setAwayMode(_ isAway: Bool, saveState: Bool = false) {
        if saveState {
            config.server.away = isAway
        }

        loginStatus = isAway ? .away : .online
        requestSetStatus(loginStatus)

        // Fake a user status message, since server doesn't send updates when we
        // disable away mode
        let msg = GetUserStatus(user: loginUsername ?? "")
        msg.status = loginStatus.rawValue
        events.emit(.userStatus, msg)
    }

    public func openPrivilegesURL() {
        let defaultServerHostname = ServerSettings().server.host
        let defaultServerDomain = defaultServerHostname.split(separator: ".", maxSplits: 1).last.map(String.init) ?? ""

        guard let serverHostname, serverHostname.hasSuffix(".\(defaultServerDomain)"), let loginUsername else {
            // Only official server is supported for now
            return
        }

        let login = loginUsername.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? loginUsername
        openURI(String(format: Application.privilegesURL, login))
    }

    public func requestChangePassword(_ password: String) {
        core.sendMessageToServer(ChangePassword(password: password))
    }

    public func requestCheckPrivileges(shouldOpenURL: Bool = false) {
        shouldOpenPrivilegesURL = shouldOpenURL
        core.sendMessageToServer(CheckPrivileges())
    }

    public func requestGivePrivileges(_ username: String, days: Int) {
        if days > 0 && days <= Int(UInt32.max) {
            core.sendMessageToServer(GivePrivileges(user: username, days: days))
        }
    }

    public func requestIPAddress(_ username: String, notify: Bool = false) {
        guard ipRequested[username] == nil else {
            return
        }

        ipRequested[username] = notify
        core.sendMessageToServer(GetPeerAddress(user: username))
    }

    public func requestSetStatus(_ status: UserStatus) {
        core.sendMessageToServer(SetStatus(status: status.rawValue))
    }

    public func requestUserStats(_ username: String) {
        core.sendMessageToServer(GetUserStats(user: username))
    }

    /// Tells the server we want to be notified of status updates for a user.
    ///
    /// The context specifies where the user is being watched. The same context
    /// must be provided when calling ``unwatchUser(_:context:)``, when we no
    /// longer wish to receive updates for the user in said context.
    ///
    /// `isImplicit` is set when receiving status updates from the server
    /// without sending a message first. At present, this only happens for users
    /// in a joined chat room.
    public func watchUser(_ username: String, context: String, isImplicit: Bool = false) {
        guard loginStatus != .offline else {
            return
        }

        let watchedUser = watched[username] ?? WatchedUser(username: username)
        watched[username] = watchedUser

        guard !watchedUser.contexts.contains(context) else {
            return
        }

        if !isImplicit && watchedUser.isImplicit {
            core.sendMessageToServer(WatchUser(user: username))
            core.sendMessageToServer(GetUserStatus(user: username))  // Get privilege status
            watchedUser.isImplicit = false
        }

        watchedUser.contexts.insert(context)
        log.addConn("Watching user \(username) in context '\(context)'. Active contexts: \(watchedUser.contexts)")
    }

    /// Tells the server we no longer wish to receive status updates for a user.
    ///
    /// The context must be the same as previously provided in
    /// ``watchUser(_:context:isImplicit:)``.
    public func unwatchUser(_ username: String, context: String) {
        guard let watchedUser = watched[username] else {
            return
        }

        watchedUser.contexts.remove(context)
        log.addConn("Unwatching user \(username) in context '\(context)'. Remaining contexts: \(watchedUser.contexts)")

        guard watchedUser.contexts.isEmpty else {
            return
        }

        if !watchedUser.isImplicit {
            core.sendMessageToServer(UnwatchUser(user: username))
        }

        addresses.removeValue(forKey: username)
        countries.removeValue(forKey: username)
        statuses.removeValue(forKey: username)
        watched.removeValue(forKey: username)
    }

    private func serverDisconnect(_ msg: ServerDisconnect) {
        loginStatus = .offline

        core.pluginHandler?.serverDisconnectNotification(userChoice: msg.manualDisconnect)

        // Clean up connections
        addresses.removeAll()
        countries.removeAll()
        statuses.removeAll()
        watched.removeAll()
        privileged.removeAll()
        ipRequested.removeAll()
        pendingWatchRemovals.removeAll()

        loginUsername = nil
        publicIPAddress = nil
        publicPort = nil
        serverHostname = nil
        serverPort = nil
        privilegesLeft = nil
        shouldOpenPrivilegesURL = false
    }

    /// Server code 1.
    private func serverLogin(_ msg: Login) {
        if msg.success {
            let username = msg.username

            loginStatus = .online
            loginUsername = username
            publicPort = msg.localAddress?.port
            serverHostname = msg.serverAddress?.host
            serverPort = msg.serverAddress?.port
            addresses[username] = msg.localAddress

            core.sendMessageToServer(CheckPrivileges())
            setAwayMode(config.server.away)
            watchUser(username, context: "login")

            if let ipAddress = msg.ipAddress {
                publicIPAddress = ipAddress

                let countryCode = core.networkFilter.countryCode(ipAddress: ipAddress)
                countries[username] = countryCode
                events.emit(.userCountry, UserCountryEvent(username: username, countryCode: countryCode))
            }

            if let banner = msg.banner, !banner.isEmpty {
                log.add(banner)
            }

            core.pluginHandler?.serverConnectNotification()
            return
        }

        if msg.reason == LoginFailure.username {
            events.emit(.invalidUsername)
            return
        }

        if msg.reason == LoginFailure.password {
            events.emit(.invalidPassword)
            return
        }

        log.add(String(localized: "Unable to connect to the server. Reason: \(msg.reason ?? "")", bundle: .module),
                title: String(localized: "Cannot Connect", bundle: .module))
    }

    /// Server code 3.
    private func getPeerAddress(_ msg: GetPeerAddress) {
        let username = msg.user
        let notify = ipRequested.removeValue(forKey: username)
        let ipAddress = msg.ipAddress
        let userOffline = (ipAddress == "0.0.0.0")
        let countryCode = core.networkFilter.countryCode(ipAddress: ipAddress)

        if userOffline {
            addresses.removeValue(forKey: username)
            countries.removeValue(forKey: username)

        } else if watched[username] != nil {
            // Only cache IP address of watched users, otherwise we won't know if
            // a user reconnects and changes their IP address.
            // Don't update our own IP address, since we already store a local IP
            // address.

            if username != loginUsername {
                addresses[username] = PeerAddress(ipAddress, msg.port)
            }

            countries[username] = countryCode
            events.emit(.userCountry, UserCountryEvent(username: username, countryCode: countryCode))
        }

        guard notify == true else {
            core.pluginHandler?.userResolveNotification(username, ipAddress: ipAddress, port: msg.port)
            return
        }

        core.pluginHandler?.userResolveNotification(username, ipAddress: ipAddress, port: msg.port,
                                                    country: countryCode)

        if userOffline {
            log.add(String(localized: "Cannot retrieve the IP of user \(username), since this user is offline",
                           bundle: .module))
            return
        }

        var country = ""

        if !countryCode.isEmpty {
            let countryName = Countries.names[countryCode] ?? String(localized: "Unknown", bundle: .module)
            country = " (\(countryCode) / \(countryName))"
        }

        log.add(String(localized: "IP address of user \(username): \(ipAddress), port \(String(msg.port))\(country)",
                       bundle: .module),
                title: String(localized: "IP Address", bundle: .module))
    }

    /// Server code 5.
    private func watchUser(_ msg: WatchUser) {
        guard msg.userExists else {
            // User does not exist. The server will not keep us informed if the user is created
            // later, so we need to remove the user from our list.
            // Due to a bug, the server will in rare cases tell us a user doesn't exist, while
            // the user is actually online. Remove the user when we receive a UserStatus message
            // telling us the user is offline.
            pendingWatchRemovals.insert(msg.user)
            return
        }

        if msg.containsStats {
            let stats = GetUserStats(user: msg.user)
            stats.avgSpeed = msg.avgSpeed ?? 0
            stats.uploadNum = msg.uploadNum ?? 0
            stats.unknown = msg.unknown ?? 0
            stats.files = msg.files ?? 0
            stats.dirs = msg.dirs ?? 0

            events.emit(.userStats, stats)
        }
    }

    /// Server code 7.
    private func userStatus(_ msg: GetUserStatus) {
        let username = msg.user
        let status = msg.status

        if let isPrivileged = msg.privileged {
            if isPrivileged {
                privileged.insert(username)
            } else {
                privileged.remove(username)
            }
        }

        guard let userStatus = UserStatus(rawValue: status) else {
            log.addDebug("Received an unknown status \(status) for user \(username) from the server")
            return
        }

        // Ignore invalid status updates for our own username in case we've already
        // changed our status again by the time they arrive from the server
        if username == loginUsername && userStatus != loginStatus {
            msg.isIgnored = true
            return
        }

        let isWatched = watched[username] != nil

        // User went offline, reset stored IP address and country
        if userStatus == .offline {
            addresses.removeValue(forKey: username)
            countries.removeValue(forKey: username)

            if pendingWatchRemovals.contains(username) {
                // User does not exist, remove it from list
                log.addConn("Unwatching non-existent user \(username)")
                watched.removeValue(forKey: username)
            }

        } else if isWatched {
            let previousStatus = statuses[username]

            if previousStatus == nil {
                // Online user seen for the first time, request IP address and country
                requestIPAddress(username)

            } else if previousStatus == .offline {
                // Previously watched user logged in again. Server will not send user stats, so request them.
                requestUserStats(username)
                requestIPAddress(username)
            }
        }

        if isWatched {
            statuses[username] = userStatus
        }

        pendingWatchRemovals.remove(username)
        core.pluginHandler?.userStatusNotification(username, status: userStatus, privileged: msg.privileged)
    }

    /// Server code 18.
    private func connectToPeer(_ msg: ConnectToPeer) {
        guard let isPrivileged = msg.privileged else {
            return
        }

        if isPrivileged {
            privileged.insert(msg.user)
        } else {
            privileged.remove(msg.user)
        }
    }

    /// Server code 36.
    private func userStats(_ msg: GetUserStats) {
        let username = msg.user

        if let stats = watched[username] {
            stats.uploadSpeed = msg.avgSpeed
            stats.files = msg.files
            stats.folders = msg.dirs
        }

        core.pluginHandler?.userStatsNotification(username, stats: UserStats(
            uploadSpeed: msg.avgSpeed, files: msg.files, folders: msg.dirs, sharedSize: nil, source: "server"
        ))
    }

    /// Server code 66.
    private static func adminMessage(_ msg: AdminMessage) {
        log.add(msg.message, title: String(localized: "Soulseek Announcement", bundle: .module))
    }

    /// Server code 69.
    private func privilegedUsers(_ msg: PrivilegedUsers) {
        privileged.formUnion(msg.users)
    }

    /// Server code 92.
    private func checkPrivileges(_ msg: CheckPrivileges) {
        let minutes = msg.seconds / 60
        let hours = minutes / 60
        let days = hours / 24

        if msg.seconds <= 0 {
            log.add(String(localized: "You have no Soulseek privileges. While privileges are active, your downloads will be queued ahead of those of non-privileged users.",
                           bundle: .module))

            if shouldOpenPrivilegesURL {
                openPrivilegesURL()
            }
        } else {
            log.add(String(localized: "\(days) days, \(hours % 24) hours, \(minutes % 60) minutes, \(msg.seconds % 60) seconds of Soulseek privileges left",
                           bundle: .module))
        }

        privilegesLeft = msg.seconds
        shouldOpenPrivilegesURL = false
    }

    /// Server code 142.
    private static func changePassword(_ msg: ChangePassword) {
        config.server.password = msg.password
        config.writeConfiguration()

        log.add(String(localized: "Your password has been changed", bundle: .module),
                title: String(localized: "Password Changed", bundle: .module))
    }
}
