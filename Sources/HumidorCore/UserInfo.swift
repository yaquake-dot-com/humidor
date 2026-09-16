// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct UserInfoShowUser: Sendable {
    public var username: String
    public var refresh: Bool
    public var switchPage: Bool
}

public extension EventName where Payload == UserInfoShowUser {
    static var userInfoShowUser: Self { .init("user-info-show-user") }
}

public extension EventName where Payload == String {
    static var userInfoRemoveUser: Self { .init("user-info-remove-user") }
}

@MainActor
public final class UserInfo {

    public private(set) var users = Set<String>()
    private var requestedInfoTimes: [String: Double] = [:]

    init() {
        events.connect(.quit) { [self] in removeAllUsers() }
        events.connect(.serverLogin) { [self] msg in serverLogin(msg) }
        events.connect(.serverDisconnect) { [self] _ in requestedInfoTimes.removeAll() }
        events.connect(.userInfoProgress) { [self] event in userInfoProgress(event) }
        events.connect(.userInfoRequest) { [self] msg in userInfoRequest(msg) }
    }

    private func serverLogin(_ msg: Login) {
        guard msg.success else {
            return
        }

        for username in users {
            core.users.watchUser(username, context: "userinfo")  // Get notified of user status
        }
    }

    private func userInfoResponse(requestingUsername: String? = nil,
                                  requestingIPAddress: String? = nil) -> UserInfoResponse {
        var permissionLevel = PermissionLevel.public
        var rejectReason = ""

        if let requestingUsername, let requestingIPAddress {
            (permissionLevel, rejectReason) = core.shares.checkUserPermission(requestingUsername,
                                                                              ipAddress: requestingIPAddress)
        }

        let msg: UserInfoResponse

        if permissionLevel == .banned {
            // Hide most details from banned users
            var description = ""

            if !rejectReason.isEmpty {
                description = "You are not allowed to download my shared files.\nReason: \(rejectReason)"
            }

            msg = UserInfoResponse(description: description, picture: nil, totalUploads: 0, queueSize: 0,
                                   slotsAvailable: false, uploadAllowed: 0)
        } else {
            let picturePath = config.expandingDataFolder(config.userInfo.picture)
            let picture = picturePath.isEmpty ? nil : try? Data(contentsOf: URL(fileURLWithPath: picturePath))

            msg = UserInfoResponse(
                description: config.userInfo.description,
                picture: picture,
                totalUploads: core.uploads.totalUploadsAllowed(),
                queueSize: core.uploads.uploadQueueSize(requestingUsername ?? ""),
                slotsAvailable: core.uploads.isNewUploadAccepted(),
                uploadAllowed: config.transfers.remoteDownloads ? config.transfers.uploadAllowed : 0
            )
        }

        msg.username = core.users.loginUsername ?? config.server.login
        return msg
    }

    public func showUser(_ username: String? = nil, refresh: Bool = false, switchPage: Bool = true) {
        let localUsername = core.users.loginUsername ?? config.server.login
        var refresh = refresh
        var username = username ?? ""

        if username.isEmpty {
            username = localUsername

            guard !username.isEmpty else {
                core.setup()
                return
            }
        }

        if !users.contains(username) {
            users.insert(username)
            refresh = true
        }

        events.emit(.userInfoShowUser, UserInfoShowUser(username: username, refresh: refresh, switchPage: switchPage))

        guard refresh else {
            return
        }

        // Request user status, speed and number of shared files
        core.users.watchUser(username, context: "userinfo")

        // Request user interests
        core.sendMessageToServer(UserInterests(user: username))

        if username == localUsername {
            events.emit(.userInfoResponse, userInfoResponse())
        } else {
            // Request user description, picture and queue information
            core.sendMessageToPeer(username, UserInfoRequest())
        }
    }

    public func removeUser(_ username: String) {
        users.remove(username)
        core.users.unwatchUser(username, context: "userinfo")
        events.emit(.userInfoRemoveUser, username)
    }

    public func removeAllUsers() {
        for username in users {
            removeUser(username)
        }
    }

    public static func saveUserPicture(_ filePath: String, pictureData: Data) {
        do {
            try pictureData.write(to: URL(fileURLWithPath: filePath))
            log.add(String(localized: "Picture saved to \(filePath)", bundle: .module))
        } catch {
            log.add(String(localized: "Cannot save picture to \(filePath): \(error.localizedDescription)",
                           bundle: .module))
        }
    }

    private func userInfoProgress(_ event: MessageProgress) {
        if !users.contains(event.username) {
            // We've removed the user. Close the connection to stop the user from
            // sending their response and wasting bandwidth.
            core.sendMessageToNetworkThread(CloseConnection(sock: event.sock))
        }
    }

    /// Peer code 15.
    private func userInfoRequest(_ msg: UserInfoRequest) {
        guard let username = msg.username else {
            return
        }

        let requestTime = ProcessInfo.processInfo.systemUptime

        if let previousTime = requestedInfoTimes[username], requestTime < previousTime + 0.4 {
            // Ignoring request, because it's less than half a second since the
            // last one by this user
            return
        }

        requestedInfoTimes[username] = requestTime
        let response = userInfoResponse(requestingUsername: username, requestingIPAddress: msg.addr?.ipAddress)

        log.add(String(localized: "User \(username) is viewing your profile", bundle: .module))
        core.sendMessageToPeer(username, response)
    }
}
