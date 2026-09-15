// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Plugin API Types

/// Result of a plugin event handler.
public enum PluginResult<Args> {
    /// Give other plugins the event, and let the application process it
    case pass
    /// Continue with modified arguments
    case modify(Args)
    /// Don't give other plugins the event, but let the application process it
    case stop
    /// Don't give other plugins the event, and don't let the application process it
    case zap
}

public enum CommandInterface: String, CaseIterable, Sendable {
    case chatroom
    case privateChat = "private_chat"
    case cli
}

/// Where a command was run from.
public enum CommandSource: Sendable {
    case chatroom(String)
    case privateChat(String)
    case cli

    public var interface: CommandInterface {
        switch self {
        case .chatroom: return .chatroom
        case .privateChat: return .privateChat
        case .cli: return .cli
        }
    }

    public var room: String? {
        if case let .chatroom(room) = self { return room }
        return nil
    }

    public var user: String? {
        if case let .privateChat(user) = self { return user }
        return nil
    }
}

/// A command provided by a plugin.
public struct PluginCommand {
    public typealias Callback = @MainActor (_ args: String, _ source: CommandSource) -> Bool?

    public var aliases: [String] = []
    public var description: String?
    public var disabledInterfaces: Set<CommandInterface> = []
    public var group: String?
    public var parameters: [String] = []
    public var interfaceParameters: [CommandInterface: [String]] = [:]
    /// Returns false if the command failed, true or nil otherwise
    public var callback: Callback

    public init(aliases: [String] = [], description: String? = nil, disabledInterfaces: Set<CommandInterface> = [],
                group: String? = nil, parameters: [String] = [],
                interfaceParameters: [CommandInterface: [String]] = [:], callback: @escaping Callback) {
        self.aliases = aliases
        self.description = description
        self.disabledInterfaces = disabledInterfaces
        self.group = group
        self.parameters = parameters
        self.interfaceParameters = interfaceParameters
        self.callback = callback
    }

    func parameters(for interface: CommandInterface) -> [String] {
        interfaceParameters[interface] ?? parameters
    }
}

public struct PluginInfo: Sendable {
    public var name: String
    public var description: String
    public var authors: [String]
    public var version: String

    public init(name: String, description: String = "", authors: [String] = ["Nicotine+"], version: String) {
        self.name = name
        self.description = description
        self.authors = authors
        self.version = version
    }
}

public enum PluginSettingType: String, Sendable {
    case bool
    case integer
    case float
    case string
    case textView = "textview"
    case listString = "list string"
    case dropdown
    case file
    case folder
}

public struct PluginSettingMeta: Sendable {
    public var description: String
    public var type: PluginSettingType
    public var minimum: Double?
    public var maximum: Double?
    public var stepSize: Double?
    public var options: [String] = []

    public init(description: String, type: PluginSettingType, minimum: Double? = nil, maximum: Double? = nil,
                stepSize: Double? = nil, options: [String] = []) {
        self.description = description
        self.type = type
        self.minimum = minimum
        self.maximum = maximum
        self.stepSize = stepSize
        self.options = options
    }
}

// MARK: - Base Plugin

/// Base class of plugins. Override the event and notification methods to
/// react to application events.
@MainActor
open class BasePlugin {

    /// Technical plugin name
    public internal(set) var internalName = ""
    /// Friendly plugin name
    public internal(set) var humanName = ""
    /// Reference to the plugin handler
    public internal(set) weak var parent: PluginHandler?

    public var commands: [String: PluginCommand] = [:]
    public var settings: [String: JSONValue] = [:]
    public var metaSettings: [String: PluginSettingMeta] = [:]

    fileprivate var eventConnections: [EventConnection] = []
    fileprivate var scheduledEvents: [Int] = []

    public required init() {}

    /// Called when plugin settings have loaded.
    open func initialize() {}

    /// The plugin has finished loading, commands are registered.
    open func loadedNotification() {}

    /// The plugin has started unloading.
    open func disable() {}

    /// The plugin has finished unloading.
    open func unloadedNotification() {}

    /// The application is shutting down.
    open func shutdownNotification() {}

    // MARK: Events and Notifications

    open func publicRoomMessageNotification(room: String, user: String, line: String) {}
    open func searchRequestNotification(searchTerm: String, user: String, token: Int) {}
    open func distribSearchNotification(searchTerm: String, user: String, token: Int) {}

    open func incomingPrivateChatEvent(user: String, line: String) -> PluginResult<(user: String, line: String)> {
        .pass
    }

    open func incomingPrivateChatNotification(user: String, line: String) {}

    open func incomingPublicChatEvent(room: String, user: String, line: String)
        -> PluginResult<(room: String, user: String, line: String)> {
        .pass
    }

    open func incomingPublicChatNotification(room: String, user: String, line: String) {}

    open func outgoingPrivateChatEvent(user: String, line: String) -> PluginResult<(user: String, line: String)> {
        .pass
    }

    open func outgoingPrivateChatNotification(user: String, line: String) {}

    open func outgoingPublicChatEvent(room: String, line: String) -> PluginResult<(room: String, line: String)> {
        .pass
    }

    open func outgoingPublicChatNotification(room: String, line: String) {}
    open func outgoingGlobalSearchEvent(text: String) async -> PluginResult<String> { .pass }

    open func outgoingRoomSearchEvent(room: String?, text: String) async
        -> PluginResult<(room: String?, text: String)> {
        .pass
    }

    open func outgoingBuddySearchEvent(text: String) async -> PluginResult<String> { .pass }

    open func outgoingUserSearchEvent(users: [String], text: String) async
        -> PluginResult<(users: [String], text: String)> {
        .pass
    }

    open func outgoingWishlistSearchEvent(text: String) async -> PluginResult<String> { .pass }
    open func userResolveNotification(user: String, ipAddress: String, port: Int, country: String?) {}
    open func serverConnectNotification() {}
    open func serverDisconnectNotification(userChoice: Bool) {}
    open func joinChatroomNotification(room: String) {}
    open func leaveChatroomNotification(room: String) {}
    open func userJoinChatroomNotification(room: String, user: String) {}
    open func userLeaveChatroomNotification(room: String, user: String) {}
    open func userStatsNotification(user: String, stats: UserStats) {}
    open func userStatusNotification(user: String, status: UserStatus, privileged: Bool?) {}
    open func uploadQueuedNotification(user: String, virtualPath: String, realPath: String) {}
    open func uploadStartedNotification(user: String, virtualPath: String, realPath: String) {}
    open func uploadFinishedNotification(user: String, virtualPath: String, realPath: String) {}
    open func downloadStartedNotification(user: String, virtualPath: String, realPath: String) {}
    open func downloadFinishedNotification(user: String, virtualPath: String, realPath: String) {}

    // MARK: Helpers

    public func log(_ message: String) {
        NicotineCore.log.add("\(humanName): \(message)")
    }

    /// Connects to an application event. The connection is removed when the
    /// plugin is disabled.
    public func connect<Payload>(_ event: EventName<Payload>, _ function: @escaping @MainActor (Payload) -> Void) {
        eventConnections.append(events.connect(event, function))
    }

    /// Schedules a function to run after a delay. Cancelled when the plugin is
    /// disabled.
    @discardableResult
    public func schedule(delay: TimeInterval, repeat shouldRepeat: Bool = false,
                         _ function: @escaping @MainActor () -> Void) -> Int {
        let eventID = events.schedule(delay: delay, repeat: shouldRepeat, function)
        scheduledEvents.append(eventID)
        return eventID
    }

    /// Sends a chat message to a room, which must already be joined.
    public func sendPublic(_ room: String, _ text: String) {
        core.chatrooms.sendMessage(room, text)
    }

    /// Sends a private message to a user.
    ///
    /// `showUI` controls if a private chat view is opened for the user.
    /// `switchPage` controls whether the user's private chat view is shown.
    public func sendPrivate(_ user: String, _ text: String, showUI: Bool = true, switchPage: Bool = true) {
        if showUI {
            core.privateChat.showUser(user, switchPage: switchPage)
        }

        core.privateChat.sendMessage(user, text)
    }

    /// Displays a raw message in a chat room (not sent to others).
    ///
    /// Available message types: action, remote, local, hilite
    public func echoPublic(_ room: String, _ text: String, messageType: String = "local") {
        core.chatrooms.echoMessage(room, text, messageType: messageType)
    }

    /// Displays a raw message in a private chat (not sent to others).
    ///
    /// Available message types: action, remote, local, hilite
    public func echoPrivate(_ user: String, _ text: String, messageType: String = "local") {
        core.privateChat.showUser(user)
        core.privateChat.echoMessage(user, text, messageType: messageType)
    }

    /// Sends a message to the same user/room a plugin command runs for.
    public func sendMessage(_ text: String) {
        guard let commandSource = parent?.commandSource else {
            // Function was not called from a command
            return
        }

        switch commandSource {
        case let .chatroom(room): sendPublic(room, text)
        case let .privateChat(user): sendPrivate(user, text)
        case .cli: break
        }
    }

    /// Displays a raw message in the same window a plugin command runs from.
    public func echoMessage(_ text: String, messageType: String = "local") {
        guard let commandSource = parent?.commandSource else {
            // Function was not called from a command
            return
        }

        switch commandSource {
        case let .chatroom(room): echoPublic(room, text, messageType: messageType)
        case let .privateChat(user): echoPrivate(user, text, messageType: messageType)
        case .cli: print(text)
        }
    }

    public func output(_ text: String) {
        echoMessage(text, messageType: "command")
    }
}

// MARK: - Response Throttle

/// Avoids flooding chat rooms with plugin responses.
///
/// Some plugins respond based on user requests and we do not want to respond
/// too much and encounter a temporary server chat ban. Some of the throttle
/// logic is guesswork as server code is closed source, but works adequately.
@MainActor
public final class ResponseThrottle {
    private struct Usage {
        var lastTime: Double = 0
        var lastRequest = ""
        var lastNick = ""
    }

    private let pluginName: String
    private let logging: Bool
    private var pluginUsage: [String: Usage] = [:]
    private var room: String?
    private var nick: String?
    private var request: String?

    public init(pluginName: String, logging: Bool = false) {
        self.pluginName = pluginName
        self.logging = logging
    }

    public func okToRespond(room: String, nick: String, request: String, secondsLimitMin: Double = 30) -> Bool {
        self.room = room
        self.nick = nick
        self.request = request

        var willingToRespond = true
        var reason = ""
        let currentTime = ProcessInfo.processInfo.systemUptime
        let usage = pluginUsage[room] ?? Usage()
        pluginUsage[room] = usage

        let port = core.users.addresses[nick]?.port ?? 1

        if core.networkFilter.isUserIgnored(nick) {
            (willingToRespond, reason) = (false, "The nick is ignored")

        } else if core.networkFilter.isUserIPIgnored(username: nick) {
            (willingToRespond, reason) = (false, "The nick's Ip is ignored")

        } else if port == 0 {
            (willingToRespond, reason) = (false, "Request likely from simple PHP based griefer bot")

        } else if nick == usage.lastNick && request == usage.lastRequest {
            if currentTime - usage.lastTime < 12 * secondsLimitMin {
                (willingToRespond, reason) = (false, "Too soon for same nick to request same resource in room")
            }

        } else if request == usage.lastRequest {
            if currentTime - usage.lastTime < 3 * secondsLimitMin {
                (willingToRespond, reason) = (false, "Too soon for different nick to request same resource in room")
            }

        } else {
            var recentResponses = 0

            for (respondedRoom, roomUsage) in pluginUsage where currentTime - roomUsage.lastTime < secondsLimitMin {
                recentResponses += 1

                if respondedRoom == room {
                    (willingToRespond, reason) = (false, "Responded in specified room too recently")
                    break
                }
            }

            if recentResponses > 3 {
                (willingToRespond, reason) = (false, "Responded in multiple rooms enough")
            }
        }

        if logging && !willingToRespond {
            NicotineCore.log.addDebug("\(pluginName) plugin request rejected - room '\(room)', nick '\(nick)' - \(reason)")
        }

        return willingToRespond
    }

    public func responded() {
        guard let room else {
            return
        }

        pluginUsage[room] = Usage(lastTime: ProcessInfo.processInfo.systemUptime, lastRequest: request ?? "",
                                  lastNick: nick ?? "")
    }
}

// MARK: - Plugin Handler

@MainActor
public final class PluginHandler {

    public struct PluginEntry {
        public let info: PluginInfo
        let make: @MainActor () -> BasePlugin
    }

    /// Plugins included in the application, keyed by internal name.
    public static let builtinPlugins: [String: PluginEntry] = [
        "core_commands": PluginEntry(info: CoreCommandsPlugin.info) { CoreCommandsPlugin() },
        "anti_shout": PluginEntry(info: AntiShoutPlugin.info) { AntiShoutPlugin() },
        "auto_user_browse": PluginEntry(info: AutoUserBrowsePlugin.info) { AutoUserBrowsePlugin() },
        "leech_detector": PluginEntry(info: LeechDetectorPlugin.info) { LeechDetectorPlugin() },
        "multipaste": PluginEntry(info: MultiPastePlugin.info) { MultiPastePlugin() },
        "now_playing_search": PluginEntry(info: NowPlayingSearchPlugin.info) { NowPlayingSearchPlugin() },
        "plugin_debugger": PluginEntry(info: PluginDebuggerPlugin.info) { PluginDebuggerPlugin() },
        "spamfilter": PluginEntry(info: SpamFilterPlugin.info) { SpamFilterPlugin() },
        "youtube_info": PluginEntry(info: YouTubeInfoPlugin.info) { YouTubeInfoPlugin() }
    ]

    public private(set) var enabledPlugins = OrderedDictionary<String, BasePlugin>()
    public private(set) var commandSource: CommandSource?
    private var commands: [CommandInterface: [String: PluginCommand]] = [
        .chatroom: [:],
        .privateChat: [:],
        .cli: [:]
    ]

    init(isolatedMode: Bool = false) {
        events.connect(.cliCommand) { [self] command in _ = triggerCLICommandEvent(command.command, args: command.args) }
        events.connect(.start) { [self] in start() }
        events.connect(.quit) { [self] in quit() }
    }

    private func start() {
        log.add(String(localized: "Loading plugin system", bundle: .module))
        enablePlugin("core_commands")

        guard config.plugins.enable else {
            return
        }

        let toEnable = config.plugins.enabled
        log.addDebug("Enabled plugin(s): \(toEnable.joined(separator: ", "))")

        for plugin in toEnable {
            enablePlugin(plugin)
        }
    }

    private func quit() {
        // Notify plugins
        shutdownNotification()

        // Disable plugins
        for plugin in installedPlugins() {
            disablePlugin(plugin, isPermanent: false)
        }
    }

    private func updateCompletions(_ plugin: BasePlugin) {
        guard config.words.commands, !plugin.commands.isEmpty else {
            return
        }

        core.chatroomsComponent?.updateCompletions()
        core.privateChatComponent?.updateCompletions()
    }

    private func pluginInstance(_ pluginName: String) -> BasePlugin? {
        guard let entry = Self.builtinPlugins[pluginName] else {
            log.addDebug("Failed to load plugin '\(pluginName)', could not find it")
            return nil
        }

        let instance = entry.make()
        instance.internalName = pluginName
        instance.humanName = entry.info.name
        instance.parent = self

        loadPluginSettings(pluginName, instance)
        return instance
    }

    @discardableResult
    public func enablePlugin(_ pluginName: String) -> Bool {
        guard enabledPlugins[pluginName] == nil, let plugin = pluginInstance(pluginName) else {
            return false
        }

        plugin.initialize()

        for (command, var data) in plugin.commands {
            if data.group == nil {
                // Group commands under human-friendly plugin name by default
                data.group = plugin.humanName
                plugin.commands[command] = data
            }

            for commandInterface in CommandInterface.allCases where !data.disabledInterfaces.contains(commandInterface) {
                if commands[commandInterface]?[command] != nil {
                    log.add(String(localized: "Conflicting \(commandInterface.rawValue) command in plugin \(plugin.humanName): /\(command)",
                                   bundle: .module))
                    continue
                }

                commands[commandInterface]?[command] = data
            }
        }

        updateCompletions(plugin)

        if !config.plugins.enabled.contains(pluginName) {
            config.plugins.enabled.append(pluginName)
        }

        enabledPlugins[pluginName] = plugin
        plugin.loadedNotification()

        log.add(String(localized: "Loaded plugin \(plugin.humanName)", bundle: .module))
        return true
    }

    /// Returns the names of plugins that can be enabled by the user.
    public func installedPlugins() -> [String] {
        Self.builtinPlugins.keys.filter { $0 != "core_commands" }.sorted()
    }

    @discardableResult
    public func disablePlugin(_ pluginName: String, isPermanent: Bool = true) -> Bool {
        guard pluginName != "core_commands", let plugin = enabledPlugins[pluginName] else {
            return false
        }

        plugin.disable()

        for command in plugin.commands.keys {
            for commandInterface in CommandInterface.allCases {
                // Remove only if the command was registered by this plugin
                if let registered = commands[commandInterface]?[command],
                   registered.group == plugin.commands[command]?.group {
                    commands[commandInterface]?.removeValue(forKey: command)
                }
            }
        }

        updateCompletions(plugin)
        plugin.unloadedNotification()
        log.add(String(localized: "Unloaded plugin \(plugin.humanName)", bundle: .module))

        // Remove any event callbacks registered and scheduled by the plugin
        for connection in plugin.eventConnections {
            events.disconnect(connection)
        }

        for eventID in plugin.scheduledEvents {
            events.cancelScheduled(eventID)
        }

        plugin.eventConnections.removeAll()
        plugin.scheduledEvents.removeAll()

        if isPermanent {
            config.plugins.enabled.removeAll { $0 == pluginName }
        }

        enabledPlugins.removeValue(forKey: pluginName)
        return true
    }

    /// Toggles a plugin. Returns true if the plugin is now enabled.
    @discardableResult
    public func togglePlugin(_ pluginName: String) -> Bool {
        if enabledPlugins[pluginName] != nil {
            return !disablePlugin(pluginName)
        }

        return enablePlugin(pluginName)
    }

    public func reloadPlugin(_ pluginName: String) {
        disablePlugin(pluginName)
        enablePlugin(pluginName)
    }

    public func pluginSettings(_ pluginName: String) -> [String: PluginSettingMeta]? {
        guard let plugin = enabledPlugins[pluginName], !plugin.metaSettings.isEmpty else {
            return nil
        }
        return plugin.metaSettings
    }

    public func pluginInfo(_ pluginName: String) -> PluginInfo? {
        Self.builtinPlugins[pluginName]?.info
    }

    private func loadPluginSettings(_ pluginName: String, _ plugin: BasePlugin) {
        let pluginName = pluginName.lowercased()

        guard !plugin.settings.isEmpty else {
            return
        }

        let previousSettings = config.plugins.settings[pluginName] ?? [:]

        for (key, value) in previousSettings {
            guard plugin.settings[key] != nil else {
                log.addDebug("Stored setting '\(key)' is no longer present in the '\(pluginName)' plugin")
                continue
            }

            plugin.settings[key] = value
        }

        // Persist plugin settings in the config
        config.plugins.settings[pluginName] = plugin.settings
    }

    /// Saves the settings of a plugin after they were changed.
    public func savePluginSettings(_ pluginName: String) {
        guard let plugin = enabledPlugins[pluginName] else {
            return
        }

        config.plugins.settings[pluginName.lowercased()] = plugin.settings
        config.writeConfiguration()
    }

    /// Returns a list of every command and alias available. Currently used for
    /// auto-completion in chats.
    public func commandList(for commandInterface: CommandInterface) -> [String] {
        var result: [String] = []

        for (command, data) in commands[commandInterface] ?? [:] {
            result.append("/\(command) ")

            for alias in data.aliases {
                result.append("/\(alias) ")
            }
        }

        return result
    }

    public struct CommandHelp {
        public var command: String
        public var aliases: [String]
        public var parameters: [String]
        public var description: String
    }

    /// Returns the available command groups and data of commands in them.
    /// Currently used for the /help command.
    public func commandGroupsData(for commandInterface: CommandInterface, searchQuery: String? = nil)
        -> OrderedDictionary<String, [CommandHelp]> {
        var commandGroups = OrderedDictionary<String, [CommandHelp]>()

        for (command, data) in (commands[commandInterface] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let aliases = data.aliases
            let parameters = data.parameters(for: commandInterface)
            let description = data.description ?? String(localized: "No description", bundle: .module)
            let group = data.group ?? String(localized: "Miscellaneous", bundle: .module)

            if let searchQuery, !searchQuery.isEmpty,
               !group.lowercased().contains(searchQuery),
               !command.lowercased().contains(searchQuery),
               !aliases.contains(where: { $0.contains(searchQuery) }),
               !parameters.contains(where: { $0.contains(searchQuery) }),
               !description.lowercased().contains(searchQuery) {
                continue
            }

            commandGroups[group, default: []].append(CommandHelp(command: command, aliases: aliases,
                                                                 parameters: parameters, description: description))
        }

        return commandGroups
    }

    public func triggerChatroomCommandEvent(room: String, command: String, args: String) -> Bool {
        triggerCommand(command, args: args, source: .chatroom(room))
    }

    public func triggerPrivateChatCommandEvent(user: String, command: String, args: String) -> Bool {
        triggerCommand(command, args: args, source: .privateChat(user))
    }

    public func triggerCLICommandEvent(_ command: String, args: String) -> Bool {
        triggerCommand(command, args: args, source: .cli)
    }

    private func triggerCommand(_ command: String, args: String, source: CommandSource) -> Bool {
        var lastPlugin: BasePlugin?
        var commandFound = false
        var isSuccessful = false
        let commandInterface = source.interface

        commandSource = source
        defer { commandSource = nil }

        for plugin in enabledPlugins.values {
            lastPlugin = plugin

            for (trigger, data) in plugin.commands {
                guard command == trigger || data.aliases.contains(command) else {
                    continue
                }

                if data.disabledInterfaces.contains(commandInterface) {
                    continue
                }

                commandFound = true
                var rejectionMessage: String?
                let parameters = data.parameters(for: commandInterface)
                let argsSplit = args.split(whereSeparator: \.isWhitespace).map(String.init)
                var numRequiredArgs = 0

                for (index, parameter) in parameters.enumerated() {
                    if parameter.hasPrefix("<") {
                        numRequiredArgs += 1
                    }

                    if argsSplit.count < numRequiredArgs {
                        rejectionMessage = String(localized: "Missing \(parameter) argument", bundle: .module)
                        break
                    }

                    if argsSplit.count <= index || !parameter.contains("|") {
                        continue
                    }

                    let choices = parameter.dropFirst().dropLast().split(separator: "|").map(String.init)

                    if !choices.contains(argsSplit[index]) {
                        let choicesText = choices.joined(separator: " | ")
                        rejectionMessage = String(localized: "Invalid argument, possible choices: \(choicesText)",
                                                  bundle: .module)
                        break
                    }
                }

                if let rejectionMessage {
                    plugin.output(rejectionMessage)
                    plugin.output(String(localized: "Usage: /\(command) \(parameters.joined(separator: " "))",
                                         bundle: .module))
                    break
                }

                // Command didn't return anything, default to success
                isSuccessful = data.callback(args, source) ?? true
            }

            if commandFound {
                lastPlugin = nil
                break
            }
        }

        if let lastPlugin {
            lastPlugin.output(String(localized: "Unknown command: /\(command). Type /help to list available commands.",
                                     bundle: .module))
        }

        return isSuccessful
    }

    /// Triggers an event for the plugins. Events and notifications are
    /// precisely the same except for how the application responds to them.
    ///
    /// - Returns: the (possibly modified) arguments, or nil if a plugin
    ///   requested the event to be dropped
    private func triggerEvent<Args>(_ args: Args, _ handler: (BasePlugin, Args) -> PluginResult<Args>) -> Args? {
        var args = args

        for plugin in enabledPlugins.values {
            switch handler(plugin, args) {
            case .pass:
                // Nothing changed, continue to the next plugin
                continue
            case let .modify(newArgs):
                // The original args were modified, update them
                args = newArgs
            case .zap:
                return nil
            case .stop:
                return args
            }
        }

        return args
    }

    private func triggerAsyncEvent<Args>(_ args: Args,
                                         _ handler: @MainActor (BasePlugin, Args) async -> PluginResult<Args>) async -> Args? {
        var args = args

        for plugin in enabledPlugins.values {
            switch await handler(plugin, args) {
            case .pass:
                continue
            case let .modify(newArgs):
                args = newArgs
            case .zap:
                return nil
            case .stop:
                return args
            }
        }

        return args
    }

    private func notifyPlugins(_ handler: (BasePlugin) -> Void) {
        for plugin in enabledPlugins.values {
            handler(plugin)
        }
    }

    // MARK: Plugin Events

    func searchRequestNotification(_ searchTerm: String, user: String, token: Int) {
        notifyPlugins { $0.searchRequestNotification(searchTerm: searchTerm, user: user, token: token) }
    }

    func distribSearchNotification(_ searchTerm: String, user: String, token: Int) {
        notifyPlugins { $0.distribSearchNotification(searchTerm: searchTerm, user: user, token: token) }
    }

    func publicRoomMessageNotification(room: String, user: String, line: String) {
        notifyPlugins { $0.publicRoomMessageNotification(room: room, user: user, line: line) }
    }

    func incomingPrivateChatEvent(user: String, line: String) -> (user: String, line: String)? {
        if user == core.users.loginUsername {
            // Don't trigger the scripts on our own talking - we've got "outgoing" for that
            return (user, line)
        }

        return triggerEvent((user, line)) { $0.incomingPrivateChatEvent(user: $1.user, line: $1.line) }
    }

    func incomingPrivateChatNotification(user: String, line: String) {
        notifyPlugins { $0.incomingPrivateChatNotification(user: user, line: line) }
    }

    func incomingPublicChatEvent(room: String, user: String, line: String) -> (room: String, user: String, line: String)? {
        triggerEvent((room, user, line)) { $0.incomingPublicChatEvent(room: $1.room, user: $1.user, line: $1.line) }
    }

    func incomingPublicChatNotification(room: String, user: String, line: String) {
        notifyPlugins { $0.incomingPublicChatNotification(room: room, user: user, line: line) }
    }

    func outgoingPrivateChatEvent(user: String, line: String) -> (user: String, line: String)? {
        triggerEvent((user, line)) { $0.outgoingPrivateChatEvent(user: $1.user, line: $1.line) }
    }

    func outgoingPrivateChatNotification(user: String, line: String) {
        notifyPlugins { $0.outgoingPrivateChatNotification(user: user, line: line) }
    }

    func outgoingPublicChatEvent(room: String, line: String) -> (room: String, line: String)? {
        triggerEvent((room, line)) { $0.outgoingPublicChatEvent(room: $1.room, line: $1.line) }
    }

    func outgoingPublicChatNotification(room: String, line: String) {
        notifyPlugins { $0.outgoingPublicChatNotification(room: room, line: line) }
    }

    func outgoingGlobalSearchEvent(_ text: String) async -> String? {
        await triggerAsyncEvent(text) { await $0.outgoingGlobalSearchEvent(text: $1) }
    }

    func outgoingRoomSearchEvent(room: String?, text: String) async -> (room: String?, text: String)? {
        await triggerAsyncEvent((room, text)) { await $0.outgoingRoomSearchEvent(room: $1.room, text: $1.text) }
    }

    func outgoingBuddySearchEvent(_ text: String) async -> String? {
        await triggerAsyncEvent(text) { await $0.outgoingBuddySearchEvent(text: $1) }
    }

    func outgoingUserSearchEvent(users: [String], text: String) async -> (users: [String], text: String)? {
        await triggerAsyncEvent((users, text)) { await $0.outgoingUserSearchEvent(users: $1.users, text: $1.text) }
    }

    func outgoingWishlistSearchEvent(_ text: String) async -> String? {
        await triggerAsyncEvent(text) { await $0.outgoingWishlistSearchEvent(text: $1) }
    }

    /// Notification for user IP:Port resolving. Note that the country is only
    /// set when the user requested the resolving.
    func userResolveNotification(_ user: String, ipAddress: String, port: Int, country: String? = nil) {
        notifyPlugins { $0.userResolveNotification(user: user, ipAddress: ipAddress, port: port, country: country) }
    }

    func serverConnectNotification() {
        notifyPlugins { $0.serverConnectNotification() }
    }

    func serverDisconnectNotification(userChoice: Bool) {
        notifyPlugins { $0.serverDisconnectNotification(userChoice: userChoice) }
    }

    func joinChatroomNotification(_ room: String) {
        notifyPlugins { $0.joinChatroomNotification(room: room) }
    }

    func leaveChatroomNotification(_ room: String) {
        notifyPlugins { $0.leaveChatroomNotification(room: room) }
    }

    func userJoinChatroomNotification(room: String, user: String) {
        notifyPlugins { $0.userJoinChatroomNotification(room: room, user: user) }
    }

    func userLeaveChatroomNotification(room: String, user: String) {
        notifyPlugins { $0.userLeaveChatroomNotification(room: room, user: user) }
    }

    func userStatsNotification(_ user: String, stats: UserStats) {
        notifyPlugins { $0.userStatsNotification(user: user, stats: stats) }
    }

    func userStatusNotification(_ user: String, status: UserStatus, privileged: Bool?) {
        notifyPlugins { $0.userStatusNotification(user: user, status: status, privileged: privileged) }
    }

    func uploadQueuedNotification(_ user: String, virtualPath: String, realPath: String) {
        notifyPlugins { $0.uploadQueuedNotification(user: user, virtualPath: virtualPath, realPath: realPath) }
    }

    func uploadStartedNotification(_ user: String, virtualPath: String, realPath: String) {
        notifyPlugins { $0.uploadStartedNotification(user: user, virtualPath: virtualPath, realPath: realPath) }
    }

    func uploadFinishedNotification(_ user: String, virtualPath: String, realPath: String) {
        notifyPlugins { $0.uploadFinishedNotification(user: user, virtualPath: virtualPath, realPath: realPath) }
    }

    func downloadStartedNotification(_ user: String, virtualPath: String, realPath: String) {
        notifyPlugins { $0.downloadStartedNotification(user: user, virtualPath: virtualPath, realPath: realPath) }
    }

    func downloadFinishedNotification(_ user: String, virtualPath: String, realPath: String) {
        notifyPlugins { $0.downloadFinishedNotification(user: user, virtualPath: virtualPath, realPath: realPath) }
    }

    func shutdownNotification() {
        notifyPlugins { $0.shutdownNotification() }
    }
}
