// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct UserBrowseShowUser: Sendable {
    public var username: String
    public var path: String?
    public var newRequest: Bool
    public var switchPage: Bool
}

public extension EventName where Payload == UserBrowseShowUser {
    static var userBrowseShowUser: Self { .init("user-browse-show-user") }
}

public extension EventName where Payload == String {
    static var userBrowseRemoveUser: Self { .init("user-browse-remove-user") }
}

public final class BrowsedUser {
    public let username: String
    public var publicFolders = OrderedDictionary<String, [FileListEntry]>()
    public var privateFolders = OrderedDictionary<String, [FileListEntry]>()
    public var numFolders: Int?
    public var numFiles: Int?
    public var sharedSize: Int?

    init(username: String) {
        self.username = username
    }

    func clear() {
        publicFolders.removeAll()
        privateFolders.removeAll()
        numFolders = nil
        numFiles = nil
        sharedSize = nil
    }
}

@MainActor
public final class UserBrowse {

    public private(set) var users: [String: BrowsedUser] = [:]

    init() {
        events.connect(.quit) { [self] in removeAllUsers() }
        events.connect(.serverLogin) { [self] msg in serverLogin(msg) }
        events.connect(.sharedFileListProgress) { [self] event in sharedFileListProgress(event) }
        events.connect(.sharedFileListResponse) { [self] msg in sharedFileListResponse(msg) }
    }

    private func serverLogin(_ msg: Login) {
        guard msg.success else {
            return
        }

        for username in users.keys {
            core.users.watchUser(username, context: "userbrowse")  // Get notified of user status
        }
    }

    /// Sends a notification to a user when attempting to initiate an upload
    /// from our end.
    public func sendUploadAttemptNotification(_ username: String) {
        core.sendMessageToPeer(username, UploadQueueNotification())
    }

    private func showUser(_ username: String, path: String? = nil, newRequest: Bool = false, switchPage: Bool = true) {
        if users[username] == nil {
            users[username] = BrowsedUser(username: username)
        }

        events.emit(.userBrowseShowUser, UserBrowseShowUser(username: username, path: path, newRequest: newRequest,
                                                            switchPage: switchPage))
    }

    public func removeUser(_ username: String) {
        users.removeValue(forKey: username)
        core.users.unwatchUser(username, context: "userbrowse")
        events.emit(.userBrowseRemoveUser, username)
    }

    public func removeAllUsers() {
        for username in Array(users.keys) {
            removeUser(username)
        }
    }

    private var localUsername: String {
        core.users.loginUsername ?? config.server.login
    }

    /// Browses our own shares.
    public func browseLocalShares(path: String? = nil, permissionLevel: PermissionLevel? = nil,
                                  newRequest: Bool = false, switchPage: Bool = true) {
        let username = localUsername

        guard !username.isEmpty else {
            core.setup()
            return
        }

        if users[username] == nil || newRequest {
            // Check our own permission level, and show relevant shares for it
            let currentPermissionLevel = permissionLevel ?? core.shares.checkUserPermission(username).level
            let built = core.shares.compressedSharesData(for: currentPermissionLevel)

            // Parse the local shares list in the background, and show it in the UI
            Thread {
                let msg = SharedFileListResponse()

                do {
                    try msg.parseNetworkMessage(built ?? Zlib.compress(Data([0, 0, 0, 0])))
                } catch {
                    log.addDebug("Unable to parse local shares: \(error)")
                }

                msg.username = username
                events.emitMainThread(.sharedFileListResponse, msg)
            }.start()
        }

        showUser(username, path: path, newRequest: newRequest, switchPage: switchPage)
        core.users.watchUser(username, context: "userbrowse")
    }

    public func requestUserShares(_ username: String) {
        core.sendMessageToPeer(username, SharedFileListRequest())
    }

    /// Browses a user's shares.
    public func browseUser(_ username: String, path: String? = nil, newRequest: Bool = false,
                           switchPage: Bool = true) {
        guard !username.isEmpty else {
            return
        }

        let browsedUser = users[username]

        if let browsedUser, newRequest {
            browsedUser.clear()
        }

        if username == localUsername {
            browseLocalShares(path: path, newRequest: newRequest, switchPage: switchPage)
            return
        }

        showUser(username, path: path, newRequest: newRequest, switchPage: switchPage)
        core.users.watchUser(username, context: "userbrowse")

        if browsedUser == nil || newRequest {
            requestUserShares(username)
        }
    }

    public func createUserSharesFolder() -> String? {
        let sharesFolder = (config.dataFolderPath as NSString).appendingPathComponent("usershares")

        do {
            try FileManager.default.createDirectory(atPath: sharesFolder, withIntermediateDirectories: true)
        } catch {
            log.add(String(localized: "Can't create directory '\(sharesFolder)', reported error: \(error.localizedDescription)",
                           bundle: .module))
            return nil
        }

        return sharesFolder
    }

    public func matchingFolders(_ requestedFolderPath: String, browsedUser: BrowsedUser, recurse: Bool = false)
        -> [(folderPath: String, files: [FileListEntry])] {
        var result: [(folderPath: String, files: [FileListEntry])] = []

        for folders in [browsedUser.publicFolders, browsedUser.privateFolders] {
            for (folderPath, files) in folders {
                if requestedFolderPath != folderPath && !(recurse && folderPath.hasPrefix("\(requestedFolderPath)\\")) {
                    continue
                }

                result.append((folderPath, files))

                if !recurse {
                    return result
                }
            }
        }

        return result
    }

    public func loadSharesListFromDisk(_ filePath: String) {
        var sharesList: [SharedFolderEntry] = []

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))

            guard let folders = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
                throw CocoaError(.fileReadCorruptFile)
            }

            for folder in folders {
                guard folder.count >= 2, let folderPath = folder[0] as? String, let files = folder[1] as? [[Any]] else {
                    throw CocoaError(.fileReadCorruptFile)
                }

                var entries: [FileListEntry] = []

                // Sanitization
                for fileInfo in files {
                    guard fileInfo.count >= 5 else {
                        throw CocoaError(.fileReadCorruptFile)
                    }

                    guard let name = fileInfo[1] as? String else {
                        throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Invalid file name"])
                    }

                    guard let size = (fileInfo[2] as? NSNumber)?.intValue else {
                        throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Invalid file size"])
                    }

                    // JSON stores file attribute types as strings, convert them back to integers
                    var attributes: [Int: Int] = [:]

                    if let storedAttributes = fileInfo[4] as? [String: Any] {
                        for (key, value) in storedAttributes {
                            if let key = Int(key), let value = (value as? NSNumber)?.intValue {
                                attributes[key] = value
                            }
                        }
                    }

                    let code = (fileInfo[0] as? NSNumber)?.intValue ?? 1
                    entries.append(FileListEntry(code: code, name: name, size: size, attributes: attributes))
                }

                sharesList.append(SharedFolderEntry(path: folderPath, files: entries))
            }

        } catch {
            log.add(String(localized: "Loading Shares from disk failed: \(error.localizedDescription)", bundle: .module))
            return
        }

        let username = (filePath as NSString).lastPathComponent

        users[username]?.clear()
        showUser(username)

        let msg = SharedFileListResponse()
        msg.username = username
        msg.list = sharesList

        events.emit(.sharedFileListResponse, msg)
    }

    public func saveSharesListToDisk(_ username: String) {
        guard let folderPath = createUserSharesFolder(), let browsedUser = users[username] else {
            return
        }

        let filePath = (folderPath as NSString).appendingPathComponent(cleanFile(username))

        do {
            var data = Data("[".utf8)
            var isFirstItem = true

            for folders in [browsedUser.publicFolders, browsedUser.privateFolders] {
                for (folder, files) in folders {
                    if isFirstItem {
                        isFirstItem = false
                    } else {
                        data.append(Data(",\n".utf8))
                    }

                    let item: [Any] = [
                        folder,
                        files.map { file -> [Any] in
                            [file.code, file.name, file.size, "",
                             Dictionary(uniqueKeysWithValues: file.attributes.map { (String($0.key), $0.value) })]
                        }
                    ]

                    data.append(try JSONSerialization.data(withJSONObject: item, options: [.withoutEscapingSlashes]))
                }
            }

            data.append(Data("]".utf8))
            try data.write(to: URL(fileURLWithPath: filePath))

            log.add(String(localized: "Saved list of shared files for user '\(username)' to \(folderPath)",
                           bundle: .module))

        } catch {
            log.add(String(localized: "Can't save shares, '\(username)', reported error: \(error.localizedDescription)",
                           bundle: .module))
        }
    }

    public func downloadFile(username: String, folderPath: String, file: FileListEntry,
                             downloadFolderPath: String? = nil) {
        let filePath = [folderPath, file.name].joined(separator: "\\")

        core.downloads.enqueueDownload(username: username, virtualPath: filePath, folderPath: downloadFolderPath,
                                       size: file.size, fileAttributes: file.attributes)
    }

    public func downloadFolder(username: String, requestedFolderPath: String?, downloadFolderPath: String? = nil,
                               recurse: Bool = false, checkNumFiles: Bool = true) {
        guard let requestedFolderPath, let browsedUser = users[username] else {
            return
        }

        let folders = matchingFolders(requestedFolderPath, browsedUser: browsedUser, recurse: recurse)
        let numFiles = folders.reduce(0) { $0 + $1.files.count }

        if checkNumFiles && numFiles > 1000 {
            // Large folder, ask user for confirmation before downloading
            events.emit(.downloadLargeFolder, LargeFolderDownload(
                username: username, folderPath: requestedFolderPath, numFiles: numFiles,
                proceed: { [self] in
                    downloadFolder(username: username, requestedFolderPath: requestedFolderPath,
                                   downloadFolderPath: downloadFolderPath, recurse: recurse, checkNumFiles: false)
                }
            ))
            return
        }

        for (folderPath, files) in folders {
            // Get final download destination
            let destinationFolderPath = core.downloads.folderDestination(
                username: username, folderPath: folderPath, rootFolderPath: requestedFolderPath,
                downloadFolderPath: downloadFolderPath
            )

            for file in files {
                let filePath = [folderPath, file.name].joined(separator: "\\")

                core.downloads.enqueueDownload(username: username, virtualPath: filePath,
                                               folderPath: destinationFolderPath, size: file.size,
                                               fileAttributes: file.attributes)
            }
        }
    }

    public func uploadFile(username: String, folderPath: String, file: FileListEntry) {
        let filePath = [folderPath, file.name].joined(separator: "\\")
        core.uploads.enqueueUpload(username: username, virtualPath: filePath)
    }

    public func uploadFolder(username: String, requestedFolderPath: String, localBrowsedUser: BrowsedUser,
                             recurse: Bool = false) {
        guard !requestedFolderPath.isEmpty, !username.isEmpty else {
            return
        }

        for (folderPath, files) in matchingFolders(requestedFolderPath, browsedUser: localBrowsedUser,
                                                   recurse: recurse) {
            for file in files {
                let filePath = [folderPath, file.name].joined(separator: "\\")
                core.uploads.enqueueUpload(username: username, virtualPath: filePath)
            }
        }
    }

    public static func soulseekURL(username: String, path: String) -> String {
        let path = path.replacingOccurrences(of: "\\", with: "/")
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        let encoded = "\(username)/\(path)".addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "slsk://" + encoded
    }

    public func openSoulseekURL(_ url: String) {
        let withoutScheme = url.hasPrefix("slsk://") ? String(url.dropFirst("slsk://".count)) : url
        let decoded = withoutScheme.removingPercentEncoding ?? withoutScheme
        let parts = decoded.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let username = parts.first.map(String.init) ?? ""
        let filePath = parts.count > 1 ? String(parts[1]).replacingOccurrences(of: "/", with: "\\") : ""

        browseUser(username, path: filePath)
    }

    private func sharedFileListProgress(_ event: MessageProgress) {
        if users[event.username] == nil {
            // We've removed the user. Close the connection to stop the user from
            // sending their response and wasting bandwidth.
            core.sendMessageToNetworkThread(CloseConnection(sock: event.sock))
        }
    }

    private func sharedFileListResponse(_ msg: SharedFileListResponse) {
        let username = msg.username ?? ""
        let numFolders = msg.list.count + msg.privateList.count
        var numFiles = 0
        var sharedSize = 0

        for folder in msg.list + msg.privateList {
            for file in folder.files {
                sharedSize += file.size
            }
            numFiles += folder.files.count
        }

        if let browsedUser = users[username] {
            browsedUser.publicFolders = OrderedDictionary()
            browsedUser.privateFolders = OrderedDictionary()

            for folder in msg.list {
                browsedUser.publicFolders[folder.path] = folder.files
            }

            for folder in msg.privateList {
                browsedUser.privateFolders[folder.path] = folder.files
            }

            browsedUser.numFolders = numFolders
            browsedUser.numFiles = numFiles
            browsedUser.sharedSize = sharedSize
        }

        core.pluginHandler?.userStatsNotification(username, stats: UserStats(
            uploadSpeed: nil, files: numFiles, folders: numFolders, sharedSize: sharedSize, source: "peer"
        ))
    }
}
