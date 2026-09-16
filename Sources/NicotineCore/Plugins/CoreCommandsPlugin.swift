// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Built-in chat and command line commands.
final class CoreCommandsPlugin: BasePlugin {

    static let info = PluginInfo(name: String(localized: "\(Application.name) Commands", bundle: .module),
                                 version: "2023-01-23r00")

    private enum CommandGroup {
        static var chat: String { String(localized: "Chat", bundle: .module) }
        static var chatRooms: String { String(localized: "Chat Rooms", bundle: .module) }
        static var privateChat: String { String(localized: "Private Chat", bundle: .module) }
        static var networkFilters: String { String(localized: "Network Filters", bundle: .module) }
        static var searchFiles: String { String(localized: "Search Files", bundle: .module) }
        static var shares: String { String(localized: "Shares", bundle: .module) }
        static var users: String { String(localized: "Users", bundle: .module) }
    }

    required init() {
        super.init()

        func text(_ value: String.LocalizationValue) -> String {
            String(localized: value, bundle: .module)
        }

        commands = [
            "help": PluginCommand(
                aliases: ["?"], description: text("List available commands"), parameters: ["[query]"],
                callback: { [unowned self] args, source in helpCommand(args, source) }
            ),
            "connect": PluginCommand(
                description: text("Connect to the server"),
                callback: { _, _ in
                    if core.users.loginStatus == .offline { core.connect() }
                    return nil
                }
            ),
            "disconnect": PluginCommand(
                description: text("Disconnect from the server"),
                callback: { _, _ in
                    if core.users.loginStatus != .offline { core.disconnect() }
                    return nil
                }
            ),
            "away": PluginCommand(
                aliases: ["a"], description: text("Toggle away status"),
                callback: { [unowned self] _, _ in awayCommand() }
            ),
            "plugin": PluginCommand(
                description: text("Manage plugins"), parameters: ["<toggle|reload|info>", "<plugin name>"],
                callback: { [unowned self] args, _ in pluginHandlerCommand(args) }
            ),
            "quit": PluginCommand(
                aliases: ["q", "exit"], description: text("Quit \(Application.name)"), parameters: ["[force]"],
                callback: { args, _ in
                    let force = ["force", "f"].contains(String(args.drop(while: { $0 == "-" })))

                    if force {
                        core.quit()
                    } else {
                        core.confirmQuit()
                    }
                    return nil
                }
            ),
            "clear": PluginCommand(
                aliases: ["cl"], description: text("Clear chat window"), disabledInterfaces: [.cli],
                group: CommandGroup.chat,
                callback: { _, source in
                    switch source {
                    case let .chatroom(room): core.chatrooms.clearRoomMessages(room)
                    case let .privateChat(user): core.privateChat.clearPrivateMessages(user)
                    case .cli: break
                    }
                    return nil
                }
            ),
            "me": PluginCommand(
                description: text("Say something in the third-person"), disabledInterfaces: [.cli],
                group: CommandGroup.chat, parameters: ["<something..>"],
                callback: { [unowned self] args, _ in
                    sendMessage("/me " + args)  // /me is sent as plain text
                    return nil
                }
            ),
            "now": PluginCommand(
                description: text("Announce the song currently playing"), disabledInterfaces: [.cli],
                group: CommandGroup.chat,
                callback: { [unowned self] _, source in nowCommand(source) }
            ),
            "join": PluginCommand(
                aliases: ["j"], description: text("Join chat room"), disabledInterfaces: [.cli],
                group: CommandGroup.chatRooms, parameters: ["<room>"],
                callback: { args, _ in
                    core.chatrooms.showRoom(ChatRooms.sanitizeRoomName(args))
                    return nil
                }
            ),
            "leave": PluginCommand(
                aliases: ["l"], description: text("Leave chat room"), disabledInterfaces: [.cli],
                group: CommandGroup.chatRooms, parameters: ["<room>"],
                interfaceParameters: [.chatroom: ["[room]"]],
                callback: { [unowned self] args, source in leaveCommand(args, source) }
            ),
            "say": PluginCommand(
                description: text("Say message in specified chat room"), disabledInterfaces: [.cli],
                group: CommandGroup.chatRooms, parameters: ["<room>", "<message..>"],
                callback: { [unowned self] args, _ in sayCommand(args) }
            ),
            "pm": PluginCommand(
                description: text("Open private chat"), disabledInterfaces: [.cli],
                group: CommandGroup.privateChat, parameters: ["<user>"],
                callback: { args, _ in
                    core.privateChat.showUser(args)
                    return nil
                }
            ),
            "close": PluginCommand(
                aliases: ["c"], description: text("Close private chat"), disabledInterfaces: [.cli],
                group: CommandGroup.privateChat,
                interfaceParameters: [.chatroom: ["<user>"], .privateChat: ["[user]"]],
                callback: { [unowned self] args, source in closeCommand(args, source) }
            ),
            "ctcpversion": PluginCommand(
                description: text("Request user's client version"), disabledInterfaces: [.cli],
                group: CommandGroup.privateChat,
                interfaceParameters: [.chatroom: ["<user>"], .privateChat: ["[user]"]],
                callback: { [unowned self] args, source in
                    if let user = Self.targetUser(args, source) {
                        sendPrivate(user, PrivateChat.ctcpVersion, showUI: true)
                    }
                    return nil
                }
            ),
            "msg": PluginCommand(
                aliases: ["m"], description: text("Send private message to user"), disabledInterfaces: [.cli],
                group: CommandGroup.privateChat, parameters: ["<user>", "<message..>"],
                callback: { [unowned self] args, _ in
                    guard let (user, message) = Self.splitFirstWord(args) else { return false }
                    sendPrivate(user, message, showUI: true, switchPage: false)
                    return nil
                }
            ),
            "add": PluginCommand(
                aliases: ["buddy"], description: text("Add user to buddy list"), group: CommandGroup.users,
                parameters: ["<user>"], interfaceParameters: [.privateChat: ["[user]"]],
                callback: { args, source in
                    if let user = Self.targetUser(args, source) { core.buddies.addBuddy(user) }
                    return nil
                }
            ),
            "rem": PluginCommand(
                aliases: ["unbuddy"], description: text("Remove buddy from buddy list"), group: CommandGroup.users,
                parameters: ["<user>"], interfaceParameters: [.privateChat: ["[user]"]],
                callback: { args, source in
                    if let user = Self.targetUser(args, source) { core.buddies.removeBuddy(user) }
                    return nil
                }
            ),
            "browse": PluginCommand(
                aliases: ["b"], description: text("Browse files of user"), disabledInterfaces: [.cli],
                group: CommandGroup.users, parameters: ["<user>"], interfaceParameters: [.privateChat: ["[user]"]],
                callback: { args, source in
                    if let user = Self.targetUser(args, source) { core.userBrowse.browseUser(user) }
                    return nil
                }
            ),
            "whois": PluginCommand(
                aliases: ["info", "w"], description: text("Show user profile information"),
                disabledInterfaces: [.cli], group: CommandGroup.users, parameters: ["<user>"],
                interfaceParameters: [.privateChat: ["[user]"]],
                callback: { args, source in
                    core.userInfo.showUser(Self.targetUser(args, source))
                    return nil
                }
            ),
            "ip": PluginCommand(
                description: text("Show IP address or username"), group: CommandGroup.networkFilters,
                parameters: ["<user or ip>"], interfaceParameters: [.privateChat: ["[user or ip]"]],
                callback: { [unowned self] args, source in ipAddressCommand(args, source) }
            ),
            "ban": PluginCommand(
                description: text("Block connections from user or IP address"), group: CommandGroup.networkFilters,
                parameters: ["<user or ip>"], interfaceParameters: [.privateChat: ["[user or ip]"]],
                callback: { [unowned self] args, source in banCommand(args, source) }
            ),
            "unban": PluginCommand(
                description: text("Remove user or IP address from ban lists"), group: CommandGroup.networkFilters,
                parameters: ["<user or ip>"], interfaceParameters: [.privateChat: ["[user or ip]"]],
                callback: { [unowned self] args, source in unbanCommand(args, source) }
            ),
            "ignore": PluginCommand(
                description: text("Silence messages from user or IP address"), disabledInterfaces: [.cli],
                group: CommandGroup.networkFilters, parameters: ["<user or ip>"],
                interfaceParameters: [.privateChat: ["[user or ip]"]],
                callback: { [unowned self] args, source in ignoreCommand(args, source) }
            ),
            "unignore": PluginCommand(
                description: text("Remove user or IP address from ignore lists"), disabledInterfaces: [.cli],
                group: CommandGroup.networkFilters, parameters: ["<user or ip>"],
                interfaceParameters: [.privateChat: ["[user or ip]"]],
                callback: { [unowned self] args, source in unignoreCommand(args, source) }
            ),
            "share": PluginCommand(
                description: text("Add share"), group: CommandGroup.shares,
                parameters: ["<public|buddy|trusted>", "<folder path>"],
                callback: { [unowned self] args, _ in shareCommand(args) }
            ),
            "unshare": PluginCommand(
                description: text("Remove share"), group: CommandGroup.shares,
                parameters: ["<virtual name or folder path>"],
                callback: { [unowned self] args, _ in unshareCommand(args) }
            ),
            "shares": PluginCommand(
                aliases: ["ls"], description: text("List shares"), group: CommandGroup.shares,
                parameters: ["[public|buddy|trusted]"],
                callback: { [unowned self] args, _ in listSharesCommand(args) }
            ),
            "rescan": PluginCommand(
                description: text("Rescan shares"), group: CommandGroup.shares, parameters: ["[force|rebuild]"],
                callback: { args, _ in
                    let rebuild = args.contains("rebuild")
                    let force = args.contains("force") || rebuild
                    core.shares.rescanShares(rebuild: rebuild, force: force)
                    return nil
                }
            ),
            "search": PluginCommand(
                aliases: ["s"], description: text("Start global file search"), disabledInterfaces: [.cli],
                group: CommandGroup.searchFiles, parameters: ["<query>"],
                callback: { args, _ in
                    core.search.doSearch(args, mode: .global)
                    return nil
                }
            ),
            "rsearch": PluginCommand(
                aliases: ["rs"], description: text("Search files in joined rooms"), disabledInterfaces: [.cli],
                group: CommandGroup.searchFiles, parameters: ["<query>"],
                callback: { args, _ in
                    core.search.doSearch(args, mode: .rooms)
                    return nil
                }
            ),
            "bsearch": PluginCommand(
                aliases: ["bs"], description: text("Search files of all buddies"), disabledInterfaces: [.cli],
                group: CommandGroup.searchFiles, parameters: ["<query>"],
                callback: { args, _ in
                    core.search.doSearch(args, mode: .buddies)
                    return nil
                }
            ),
            "usearch": PluginCommand(
                aliases: ["us"], description: text("Search a user's shared files"), disabledInterfaces: [.cli],
                group: CommandGroup.searchFiles, parameters: ["<user>", "<query>"],
                callback: { args, _ in
                    guard let (user, query) = Self.splitFirstWord(args) else { return false }
                    core.search.doSearch(query, mode: .user, users: [user])
                    return nil
                }
            )
        ]
    }

    // MARK: Helpers

    /// Returns the user a command applies to: the argument if provided,
    /// otherwise the user of the private chat the command runs in.
    private static func targetUser(_ args: String, _ source: CommandSource) -> String? {
        args.isEmpty ? source.user : args
    }

    private static func splitFirstWord(_ args: String) -> (String, String)? {
        let parts = args.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    // MARK: Application Commands

    private func helpCommand(_ args: String, _ source: CommandSource) -> Bool? {
        let searchQuery = args.lowercased().split(separator: " ", maxSplits: 1).joined(separator: " ")
        let commandGroups = parent?.commandGroupsData(for: source.interface, searchQuery: searchQuery) ?? [:]
        let numCommands = commandGroups.values.reduce(0) { $0 + $1.count }
        var outputText: String

        if searchQuery.isEmpty {
            outputText = String(localized: "Listing \(numCommands) available commands:", bundle: .module)
        } else {
            outputText = String(localized: "Listing \(numCommands) available commands matching \"\(searchQuery)\":",
                                bundle: .module)
        }

        for (groupName, commandData) in commandGroups {
            outputText += "\n\n\(groupName):"

            for help in commandData {
                let names = ([help.command] + help.aliases).joined(separator: ", /")
                let commandMessage = "/\(names) \(help.parameters.joined(separator: " "))"
                    .trimmingCharacters(in: .whitespaces)
                outputText += "\n\t\(commandMessage)  -  \(help.description)"
            }
        }

        if searchQuery.isEmpty {
            outputText += "\n\n" + String(localized: "Type \("/help [query]") to list similar commands", bundle: .module)
        } else if numCommands == 0 {
            outputText += "\n" + String(localized: "Type \("/help") to list available commands", bundle: .module)
        }

        output(outputText)
        return nil
    }

    private func awayCommand() -> Bool? {
        if core.users.loginStatus == .offline {
            output(String(localized: "\(config.server.login) is offline", bundle: .module))
            return nil
        }

        core.users.setAwayMode(core.users.loginStatus != .away, saveState: true)
        let username = core.users.loginUsername ?? ""

        if core.users.loginStatus == .online {
            output(String(localized: "\(username) is online", bundle: .module))
        } else {
            output(String(localized: "\(username) is away", bundle: .module))
        }

        return nil
    }

    // MARK: Chat

    private func nowCommand(_ source: CommandSource) -> Bool? {
        guard let nowPlaying = core.nowPlaying else {
            return false
        }

        Task { @MainActor [weak self] in
            guard let title = await nowPlaying.nowPlaying(), let self else {
                return
            }

            switch source {
            case let .chatroom(room): sendPublic(room, title)
            case let .privateChat(user): sendPrivate(user, title)
            case .cli: break
            }
        }

        return nil
    }

    // MARK: Chat Rooms

    private func leaveCommand(_ args: String, _ source: CommandSource) -> Bool? {
        let room = args.isEmpty ? (source.room ?? "") : args

        guard core.chatrooms.joinedRooms[room] != nil else {
            output(String(localized: "Not joined in room \(room)", bundle: .module))
            return false
        }

        core.chatrooms.removeRoom(room)
        return true
    }

    private func sayCommand(_ args: String) -> Bool? {
        guard let (room, text) = Self.splitFirstWord(args) else {
            return false
        }

        guard core.chatrooms.joinedRooms[room] != nil else {
            output(String(localized: "Not joined in room \(room)", bundle: .module))
            return false
        }

        sendPublic(room, text)
        return true
    }

    // MARK: Private Chat

    private func closeCommand(_ args: String, _ source: CommandSource) -> Bool? {
        let user = Self.targetUser(args, source) ?? ""

        guard core.privateChat.users.contains(user) else {
            output(String(localized: "Not messaging with user \(user)", bundle: .module))
            return false
        }

        core.privateChat.removeUser(user)
        output(String(localized: "Closed private chat of user \(user)", bundle: .module))
        return true
    }

    // MARK: Network Filters

    private func ipAddressCommand(_ args: String, _ source: CommandSource) -> Bool? {
        if NetworkFilter.isIPAddress(args) {
            output(core.networkFilter.onlineUsername(ipAddress: args) ?? "None")
            return nil
        }

        if let user = Self.targetUser(args, source) {
            core.users.requestIPAddress(user, notify: true)
        }

        return nil
    }

    private func banCommand(_ args: String, _ source: CommandSource) -> Bool? {
        var bannedIPAddress: String?
        var user = ""

        if NetworkFilter.isIPAddress(args) {
            bannedIPAddress = core.networkFilter.banUserIP(ipAddress: args)
        } else {
            user = Self.targetUser(args, source) ?? ""
            core.networkFilter.banUser(user)
        }

        output(String(localized: "Banned \(bannedIPAddress ?? user)", bundle: .module))
        return nil
    }

    private func unbanCommand(_ args: String, _ source: CommandSource) -> Bool? {
        var unbannedIPAddresses: Set<String>
        var user = ""

        if NetworkFilter.isIPAddress(args) {
            unbannedIPAddresses = core.networkFilter.unbanUserIP(ipAddress: args)

            if let onlineUsername = core.networkFilter.onlineUsername(ipAddress: args) {
                core.networkFilter.unbanUser(onlineUsername)
            }
        } else {
            user = Self.targetUser(args, source) ?? ""
            unbannedIPAddresses = core.networkFilter.unbanUserIP(username: user)
            core.networkFilter.unbanUser(user)
        }

        let unbanned = unbannedIPAddresses.isEmpty ? user : unbannedIPAddresses.sorted().joined(separator: " & ")
        output(String(localized: "Unbanned \(unbanned)", bundle: .module))
        return nil
    }

    private func ignoreCommand(_ args: String, _ source: CommandSource) -> Bool? {
        var ignoredIPAddress: String?
        var user = ""

        if NetworkFilter.isIPAddress(args) {
            ignoredIPAddress = core.networkFilter.ignoreUserIP(ipAddress: args)
        } else {
            user = Self.targetUser(args, source) ?? ""
            core.networkFilter.ignoreUser(user)
        }

        output(String(localized: "Ignored \(ignoredIPAddress ?? user)", bundle: .module))
        return nil
    }

    private func unignoreCommand(_ args: String, _ source: CommandSource) -> Bool? {
        var unignoredIPAddresses: Set<String>
        var user = ""

        if NetworkFilter.isIPAddress(args) {
            unignoredIPAddresses = core.networkFilter.unignoreUserIP(ipAddress: args)

            if let onlineUsername = core.networkFilter.onlineUsername(ipAddress: args) {
                core.networkFilter.unignoreUser(onlineUsername)
            }
        } else {
            user = Self.targetUser(args, source) ?? ""
            unignoredIPAddresses = core.networkFilter.unignoreUserIP(username: user)
            core.networkFilter.unignoreUser(user)
        }

        let unignored = unignoredIPAddresses.isEmpty ? user : unignoredIPAddresses.sorted().joined(separator: " & ")
        output(String(localized: "Unignored \(unignored)", bundle: .module))
        return nil
    }

    // MARK: Configure Shares

    private func listSharesCommand(_ args: String) -> Bool? {
        let groups = core.shares.sharedFolders
        let shareGroups: [(PermissionLevel, [SharedFolder])] = [
            (.public, groups.public), (.buddy, groups.buddy), (.trusted, groups.trusted)
        ]
        var numTotal = 0
        var numListed = 0

        for (permissionLevel, shareGroup) in shareGroups {
            let numShares = shareGroup.count
            numTotal += numShares

            if numShares == 0 || (!args.isEmpty && !args.lowercased().contains(permissionLevel.rawValue)) {
                continue
            }

            output("\n\(numShares) \(permissionLevel.rawValue) shares:")

            for share in shareGroup {
                output("• \"\(share.virtualName)\" \(share.path)")
            }

            numListed += numShares
        }

        output("\n" + String(localized: "\(numListed) shares listed (\(numTotal) configured)", bundle: .module))
        return nil
    }

    private func shareCommand(_ args: String) -> Bool? {
        guard let (permissionLevelName, rawFolderPath) = Self.splitFirstWord(args) else {
            return false
        }

        let folderPath = rawFolderPath.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        let permissionLevel = PermissionLevel(rawValue: permissionLevelName) ?? .public

        guard let virtualName = core.shares.addShare(folderPath, permissionLevel: permissionLevel) else {
            output(String(localized: "Cannot share inaccessible folder \"\(folderPath)\"", bundle: .module))
            return false
        }

        output(String(localized: "Added \(permissionLevelName) share \"\(virtualName)\" (rescan required)",
                      bundle: .module))
        return true
    }

    private func unshareCommand(_ args: String) -> Bool? {
        let virtualNameOrFolderPath = args.trimmingCharacters(in: CharacterSet(charactersIn: " \""))

        guard core.shares.removeShare(virtualNameOrFolderPath) else {
            output(String(localized: "No share with name \"\(virtualNameOrFolderPath)\"", bundle: .module))
            return false
        }

        output(String(localized: "Removed share \"\(virtualNameOrFolderPath)\" (rescan required)", bundle: .module))
        return true
    }

    // MARK: Plugin Commands

    private func pluginHandlerCommand(_ args: String) -> Bool? {
        guard let (action, pluginName) = Self.splitFirstWord(args), let parent else {
            return false
        }

        switch action {
        case "toggle":
            parent.togglePlugin(pluginName)

        case "reload":
            parent.reloadPlugin(pluginName)

        case "info":
            if let info = parent.pluginInfo(pluginName) {
                output("• Name: \(info.name)")
                output("• Description: \(info.description)")
                output("• Authors: \(info.authors.joined(separator: ", "))")
                output("• Version: \(info.version)")
            }

        default:
            break
        }

        return nil
    }
}
