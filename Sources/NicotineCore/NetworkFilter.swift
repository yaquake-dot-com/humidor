// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct UserIPEvent: Sendable {
    public var username: String?
    public var ipAddress: String?
}

public struct UserIPsEvent: Sendable {
    public var username: String?
    public var ipAddresses: Set<String>
}

public extension EventName where Payload == String {
    static var banUser: Self { .init("ban-user") }
    static var unbanUser: Self { .init("unban-user") }
    static var ignoreUser: Self { .init("ignore-user") }
    static var unignoreUser: Self { .init("unignore-user") }
}

public extension EventName where Payload == UserIPEvent {
    static var banUserIP: Self { .init("ban-user-ip") }
    static var ignoreUserIP: Self { .init("ignore-user-ip") }
}

public extension EventName where Payload == UserIPsEvent {
    static var unbanUserIP: Self { .init("unban-user-ip") }
    static var unignoreUserIP: Self { .init("unignore-user-ip") }
}

/// Functions related to banning and ignoring users.
@MainActor
public final class NetworkFilter {

    public enum IPListAction {
        case add
        case remove
    }

    private enum IPList {
        case blocked
        case ignored

        var keyPath: WritableKeyPath<ServerSettings, [String: String]> {
            switch self {
            case .blocked: return \.ipBlockList
            case .ignored: return \.ipIgnoreList
            }
        }
    }

    public private(set) var ipBanRequested: [String: IPListAction] = [:]
    public private(set) var ipIgnoreRequested: [String: IPListAction] = [:]

    private var bannedUsers = Set<String>()
    private var ignoredUsers = Set<String>()
    private var ipRangeValues: [UInt32] = []
    private var ipRangeCountries: [String] = []
    private var isIPCountryDataLoaded = false

    init() {
        events.connect(.peerAddress) { [self] msg in getPeerAddress(msg) }
        events.connect(.quit) { [self] in quit() }
        events.connect(.serverDisconnect) { [self] _ in serverDisconnect() }
        events.connect(.start) { [self] in start() }
    }

    private func start() {
        bannedUsers.formUnion(config.server.banList)
        ignoredUsers.formUnion(config.server.ignoreList)
    }

    private func populateIPCountryData() {
        guard !isIPCountryDataLoaded else {
            return
        }

        isIPCountryDataLoaded = true

        guard let url = Bundle.module.url(forResource: "ip_country_data", withExtension: "csv"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }

        for line in contents.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)

            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            if !ipRangeValues.isEmpty {
                ipRangeCountries = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                break
            }

            ipRangeValues = line.split(separator: ",").compactMap { UInt32($0) }
        }
    }

    private func serverDisconnect() {
        ipBanRequested.removeAll()
        ipIgnoreRequested.removeAll()
    }

    private func quit() {
        bannedUsers.removeAll()
        ignoredUsers.removeAll()
        ipRangeValues = []
        ipRangeCountries = []
        isIPCountryDataLoaded = false
    }

    // MARK: IP Filter List Management

    /// Asks for the IP address of an unknown user.
    ///
    /// Once a GetPeerAddress response arrives, either `banUnbanUserIPCallback`
    /// or `ignoreUnignoreUserIPCallback` is called.
    private func requestIP(_ username: String, action: IPListAction, list: IPList) {
        switch list {
        case .blocked:
            if ipBanRequested[username] == nil { ipBanRequested[username] = action }
        case .ignored:
            if ipIgnoreRequested[username] == nil { ipIgnoreRequested[username] = action }
        }

        core.users.requestIPAddress(username)
    }

    /// Adds the current IP address and username of a user to a list.
    @discardableResult
    private func addUserIPToList(_ list: IPList, username: String? = nil, ipAddress: String? = nil) -> String? {
        var username = username
        var ipAddress = ipAddress

        if username == nil || username?.isEmpty == true {
            // Try to get a username from currently active connections
            username = ipAddress.flatMap { onlineUsername(ipAddress: $0) }

        } else if let knownUsername = username, !Self.isIPAddress(ipAddress) {
            // Try to get a known address for the user, use username as placeholder otherwise
            let ipAddresses = userIPAddresses(knownUsername, list: list, requestAction: .add)
            ipAddress = ipAddresses.first ?? "? (\(knownUsername))"
        }

        guard let ipAddress, !ipAddress.isEmpty else {
            return nil
        }

        let entries = config.server[keyPath: list.keyPath]

        if entries[ipAddress] == nil || (username != nil && entries[ipAddress] != username) {
            config.server[keyPath: list.keyPath][ipAddress] = username ?? ""
            config.writeConfiguration()
        }

        return ipAddress
    }

    /// Removes the previously saved IP addresses of a user from a list.
    private func removeUserIPsFromList(_ list: IPList, username: String? = nil,
                                       ipAddresses: Set<String> = []) -> Set<String> {
        var ipAddresses = ipAddresses

        if ipAddresses.isEmpty, let username {
            // Try to get a known address for the user
            ipAddresses = userIPAddresses(username, list: list, requestAction: .remove)
        }

        for ipAddress in ipAddresses {
            config.server[keyPath: list.keyPath].removeValue(forKey: ipAddress)
        }

        config.writeConfiguration()
        return ipAddresses
    }

    // MARK: IP List Lookup Functions

    /// Retrieves IP addresses of a user previously saved in an IP list.
    private func previousUserIPAddresses(_ username: String, list: IPList) -> Set<String> {
        Set(config.server[keyPath: list.keyPath].filter { $0.value == username }.keys)
    }

    /// Returns the known IP addresses of a user, requests one otherwise.
    private func userIPAddresses(_ username: String, list: IPList, requestAction: IPListAction) -> Set<String> {
        var ipAddresses = Set<String>()

        switch requestAction {
        case .add:
            // Get current IP for user, if known
            if let onlineAddress = core.users.addresses[username] {
                ipAddresses.insert(onlineAddress.ipAddress)
            }

        case .remove:
            // Remove all known IP addresses for user
            ipAddresses = previousUserIPAddresses(username, list: list)
        }

        if !ipAddresses.isEmpty {
            return ipAddresses
        }

        // User's IP address is unknown, request it from the server
        requestIP(username, action: requestAction, list: list)
        return ipAddresses
    }

    /// Tries to match a username from watched and known connections, for
    /// updating an IP list item if the username is unspecified.
    public func onlineUsername(ipAddress: String) -> String? {
        core.users.addresses.first { $0.value.ipAddress == ipAddress }?.key
    }

    public func countryCode(ipAddress: String) -> String {
        populateIPCountryData()

        guard !ipRangeCountries.isEmpty,
              let address = POSIXSocket.makeAddress(ipAddress, port: 0) else {
            return ""
        }

        let ipNumber = UInt32(bigEndian: address.sin_addr.s_addr)

        // Binary search for the first range end value >= ipNumber
        var low = 0
        var high = ipRangeValues.count

        while low < high {
            let middle = (low + high) / 2

            if ipRangeValues[middle] < ipNumber {
                low = middle + 1
            } else {
                high = middle
            }
        }

        return low < ipRangeCountries.count ? ipRangeCountries[low] : ""
    }

    /// Checks if the given value is an IPv4 address or not.
    public static func isIPAddress(_ ipAddress: String?, allowZero: Bool = true, allowWildcard: Bool = true) -> Bool {
        guard let ipAddress, !ipAddress.isEmpty, ipAddress.filter({ $0 == "." }).count == 3 else {
            return false
        }

        if !allowZero && ipAddress == "0.0.0.0" {
            // User is offline if IP address is "0.0.0.0" (not nil!)
            return false
        }

        for part in ipAddress.split(separator: ".", omittingEmptySubsequences: false) {
            if allowWildcard && part == "*" {
                continue
            }

            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let value = Int(part),
                  value <= 255 else {
                return false
            }
        }

        return true
    }

    // MARK: IP Filter Rule Processing

    /// Checks if an IP address is present in a list.
    private func isUserIPFiltered(_ list: IPList, username: String? = nil, ipAddress: String? = nil) -> Bool {
        let entries = config.server[keyPath: list.keyPath]

        if let username, !username.isEmpty, entries.values.contains(username) {
            // Username is present in the list, so we want to filter it
            return true
        }

        var ipAddress = ipAddress

        if ipAddress == nil || ipAddress?.isEmpty == true {
            guard let username, let address = core.users.addresses[username] else {
                // Username not listed and is offline, so we can't filter it
                return false
            }

            ipAddress = address.ipAddress
        }

        guard let ipAddress else {
            return false
        }

        if entries[ipAddress] != nil {
            // IP filtered
            return true
        }

        let addressParts = ipAddress.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

        for address in entries.keys where address.contains("*") {
            // Wildcard in IP rule
            let parts = address.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            var segment = 0

            for part in parts {
                // Stop if there's no wildcard or matching string number
                guard segment < addressParts.count, part == addressParts[segment] || part == "*" else {
                    break
                }

                segment += 1

                // Last time around
                if segment == 4 {
                    // Wildcard filter, add actual IP address and username into list
                    addUserIPToList(list, username: username, ipAddress: ipAddress)
                    return true
                }
            }
        }

        // Not filtered
        return false
    }

    // MARK: Callbacks

    /// Checks if a user's IP address has changed and updates the lists.
    private func updateSavedUserIPAddresses(_ list: IPList, username: String, ipAddress: String) {
        let previousIPAddresses = previousUserIPAddresses(username, list: list)

        guard !previousIPAddresses.isEmpty else {
            // User is not filtered
            return
        }

        let ipAddressPlaceholder = "? (\(username))"

        if previousIPAddresses.contains(ipAddressPlaceholder) {
            _ = removeUserIPsFromList(list, ipAddresses: [ipAddressPlaceholder])
        }

        if !previousIPAddresses.contains(ipAddress) {
            addUserIPToList(list, username: username, ipAddress: ipAddress)
        }
    }

    /// Server code 3.
    private func getPeerAddress(_ msg: GetPeerAddress) {
        let username = msg.user
        let ipAddress = msg.ipAddress

        guard ipAddress != "0.0.0.0" else {
            // User is offline
            return
        }

        // If the IP address changed, make sure our IP ban/ignore list reflects this
        updateSavedUserIPAddresses(.blocked, username: username, ipAddress: ipAddress)
        updateSavedUserIPAddresses(.ignored, username: username, ipAddress: ipAddress)

        // Check pending "add" and "remove" requests for IP-based filtering of previously offline users
        banUnbanUserIPCallback(username, ipAddress: ipAddress)
        ignoreUnignoreUserIPCallback(username, ipAddress: ipAddress)
    }

    // MARK: Banning

    public func banUser(_ username: String) {
        if !isUserBanned(username) {
            bannedUsers.insert(username)
            config.server.banList.append(username)
            config.writeConfiguration()
        }

        events.emit(.banUser, username)
    }

    public func unbanUser(_ username: String) {
        if isUserBanned(username) {
            bannedUsers.remove(username)
            config.server.banList.removeAll { $0 == username }
            config.writeConfiguration()
        }

        events.emit(.unbanUser, username)
    }

    @discardableResult
    public func banUserIP(username: String? = nil, ipAddress: String? = nil) -> String? {
        let ipAddress = addUserIPToList(.blocked, username: username, ipAddress: ipAddress)

        events.emit(.banUserIP, UserIPEvent(username: username, ipAddress: ipAddress))
        return ipAddress
    }

    @discardableResult
    public func unbanUserIP(username: String? = nil, ipAddress: String? = nil) -> Set<String> {
        let ipAddresses = removeUserIPsFromList(.blocked, username: username,
                                                ipAddresses: ipAddress.map { [$0] } ?? [])

        events.emit(.unbanUserIP, UserIPsEvent(username: username, ipAddresses: ipAddresses))
        return ipAddresses
    }

    private func banUnbanUserIPCallback(_ username: String, ipAddress: String) {
        switch ipBanRequested.removeValue(forKey: username) {
        case .add: banUserIP(username: username, ipAddress: ipAddress)
        case .remove: unbanUserIP(username: username, ipAddress: ipAddress)
        case nil: break
        }
    }

    public func isUserBanned(_ username: String) -> Bool {
        bannedUsers.contains(username)
    }

    public func isUserIPBanned(username: String? = nil, ipAddress: String? = nil) -> Bool {
        isUserIPFiltered(.blocked, username: username, ipAddress: ipAddress)
    }

    // MARK: Ignoring

    public func ignoreUser(_ username: String) {
        if !isUserIgnored(username) {
            ignoredUsers.insert(username)
            config.server.ignoreList.append(username)
            config.writeConfiguration()
        }

        events.emit(.ignoreUser, username)
    }

    public func unignoreUser(_ username: String) {
        if isUserIgnored(username) {
            ignoredUsers.remove(username)
            config.server.ignoreList.removeAll { $0 == username }
            config.writeConfiguration()
        }

        events.emit(.unignoreUser, username)
    }

    @discardableResult
    public func ignoreUserIP(username: String? = nil, ipAddress: String? = nil) -> String? {
        let ipAddress = addUserIPToList(.ignored, username: username, ipAddress: ipAddress)

        events.emit(.ignoreUserIP, UserIPEvent(username: username, ipAddress: ipAddress))
        return ipAddress
    }

    @discardableResult
    public func unignoreUserIP(username: String? = nil, ipAddress: String? = nil) -> Set<String> {
        let ipAddresses = removeUserIPsFromList(.ignored, username: username,
                                                ipAddresses: ipAddress.map { [$0] } ?? [])

        events.emit(.unignoreUserIP, UserIPsEvent(username: username, ipAddresses: ipAddresses))
        return ipAddresses
    }

    private func ignoreUnignoreUserIPCallback(_ username: String, ipAddress: String) {
        switch ipIgnoreRequested.removeValue(forKey: username) {
        case .add: ignoreUserIP(username: username, ipAddress: ipAddress)
        case .remove: unignoreUserIP(username: username, ipAddress: ipAddress)
        case nil: break
        }
    }

    public func isUserIgnored(_ username: String) -> Bool {
        ignoredUsers.contains(username)
    }

    public func isUserIPIgnored(username: String? = nil, ipAddress: String? = nil) -> Bool {
        isUserIPFiltered(.ignored, username: username, ipAddress: ipAddress)
    }
}
