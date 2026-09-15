// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Components that can be enabled when initializing the core.
public enum CoreComponent: String, CaseIterable, Sendable {
    case cli
    case portmapper
    case networkThread
    case shares
    case users
    case notifications
    case networkFilter
    case nowPlaying
    case statistics
    case updateChecker
    case search
    case downloads
    case uploads
    case interests
    case userBrowse
    case userInfo
    case buddies
    case chatrooms
    case privateChat
    case pluginHandler
}

/// Handles initialization, quitting, as well as the various components used by
/// the application.
@MainActor
public final class Core {

    public private(set) var sharesComponent: Shares?
    public private(set) var usersComponent: Users?
    public private(set) var networkFilterComponent: NetworkFilter?
    public private(set) var statisticsComponent: Statistics?
    public private(set) var searchComponent: Search?
    public private(set) var downloadsComponent: Downloads?
    public private(set) var uploadsComponent: Uploads?
    public private(set) var interestsComponent: Interests?
    public private(set) var userBrowseComponent: UserBrowse?
    public private(set) var userInfoComponent: UserInfo?
    public private(set) var buddiesComponent: Buddies?
    public private(set) var privateChatComponent: PrivateChat?
    public private(set) var chatroomsComponent: ChatRooms?
    public private(set) var pluginHandler: PluginHandler?
    public private(set) var nowPlaying: NowPlaying?
    public private(set) var portmapper: PortMapper?
    public private(set) var notifications: Notifications?
    public private(set) var updateChecker: UpdateChecker?
    private var networkThread: NetworkThread?

    public var cliInterfaceAddress: String?
    public var cliListenPort: Int?

    public private(set) var enabledComponents = Set<CoreComponent>()

    // Components that are always enabled in a full application. Accessing a
    // disabled component is a programming error.
    public var shares: Shares { sharesComponent! }
    public var users: Users { usersComponent! }
    public var networkFilter: NetworkFilter { networkFilterComponent! }
    public var statistics: Statistics { statisticsComponent! }
    public var search: Search { searchComponent! }
    public var downloads: Downloads { downloadsComponent! }
    public var uploads: Uploads { uploadsComponent! }
    public var interests: Interests { interestsComponent! }
    public var userBrowse: UserBrowse { userBrowseComponent! }
    public var userInfo: UserInfo { userInfoComponent! }
    public var buddies: Buddies { buddiesComponent! }
    public var privateChat: PrivateChat { privateChatComponent! }
    public var chatrooms: ChatRooms { chatroomsComponent! }

    nonisolated init() {}

    public func initComponents(enabledComponents: Set<CoreComponent>? = nil, isolatedMode: Bool = false) {
        // Enable all components by default
        let enabledComponents = enabledComponents ?? Set(CoreComponent.allCases)
        self.enabledComponents = enabledComponents

        if enabledComponents.contains(.cli) {
            cli.enableLogging()
        }

        config.loadConfig(isolatedMode: isolatedMode)
        events.enable()
        log.enable()

        events.connect(.quit) { [self] in quit() }
        events.connect(.serverReconnect) { [self] _ in serverReconnect() }

        log.add(String(localized: "Loading \(Application.name) \(Application.version)", bundle: .module))
        log.addDebug("Using \(Application.name) executable: \(Bundle.main.executablePath ?? "")")

        if enabledComponents.contains(.portmapper) {
            let portmapper = PortMapper()
            portmapper.setEnabled(config.server.upnp)
            self.portmapper = portmapper
        }

        if enabledComponents.contains(.networkThread) {
            networkThread = NetworkThread()
        } else {
            events.connect(.scheduleQuit) { events.emit(.quit) }
        }

        if enabledComponents.contains(.shares) {
            // Initialized before "users" component in order to send share stats to server
            // before watching our username, otherwise we get outdated stats back.
            sharesComponent = Shares()
        }

        if enabledComponents.contains(.users) {
            usersComponent = Users()
        }

        if enabledComponents.contains(.notifications) {
            notifications = Notifications()
        }

        if enabledComponents.contains(.networkFilter) {
            networkFilterComponent = NetworkFilter()
        }

        if enabledComponents.contains(.nowPlaying) {
            nowPlaying = NowPlaying()
        }

        if enabledComponents.contains(.statistics) {
            statisticsComponent = Statistics()
        }

        if enabledComponents.contains(.updateChecker) {
            updateChecker = UpdateChecker()
        }

        if enabledComponents.contains(.search) {
            searchComponent = Search()
        }

        if enabledComponents.contains(.downloads) {
            downloadsComponent = Downloads()
        }

        if enabledComponents.contains(.uploads) {
            uploadsComponent = Uploads()
        }

        if enabledComponents.contains(.interests) {
            interestsComponent = Interests()
        }

        if enabledComponents.contains(.userBrowse) {
            userBrowseComponent = UserBrowse()
        }

        if enabledComponents.contains(.userInfo) {
            userInfoComponent = UserInfo()
        }

        if enabledComponents.contains(.buddies) {
            buddiesComponent = Buddies()
        }

        if enabledComponents.contains(.chatrooms) {
            chatroomsComponent = ChatRooms()
        }

        if enabledComponents.contains(.privateChat) {
            privateChatComponent = PrivateChat()
        }

        if enabledComponents.contains(.pluginHandler) {
            pluginHandler = PluginHandler(isolatedMode: isolatedMode)
        }
    }

    public func start() {
        if enabledComponents.contains(.cli) {
            cli.enablePrompt()
        }

        events.emit(.start)
    }

    public func setup() {
        events.emit(.setup)
    }

    public func confirmQuit() {
        events.emit(.confirmQuit)
    }

    public func quit(isTerminating: Bool = false) {
        let status = isTerminating
            ? String(localized: "terminating", bundle: .module)
            : String(localized: "application closing", bundle: .module)

        log.add(String(localized: "Quitting \(Application.name) \(Application.version), \(status)…", bundle: .module))

        // Allow the networking thread to finish up before quitting
        events.emit(.scheduleQuit)
    }

    private func quit() {
        config.writeConfiguration()
        log.add(String(localized: "Quit \(Application.name) \(Application.version)!", bundle: .module))
    }

    public func connect() {
        if config.needsConfig {
            log.add(String(localized: "You need to specify a username and password before connecting…",
                           bundle: .module))
            setup()
            return
        }

        events.emit(.enableMessageQueue)

        let server = config.server
        portmapper?.setEnabled(server.upnp)

        sendMessageToNetworkThread(ServerConnect(
            addr: server.server,
            login: LoginCredentials(username: server.login, password: server.password),
            interfaceName: server.interface,
            interfaceAddress: cliInterfaceAddress,
            listenPort: cliListenPort ?? server.portRange.lowerBound,
            portmapper: portmapper
        ))
    }

    public func disconnect() {
        sendMessageToNetworkThread(ServerDisconnect())
    }

    public func reconnect() {
        sendMessageToNetworkThread(ServerReconnect())
    }

    private func serverReconnect() {
        connect()
    }

    /// Sends a message to the networking thread to inform about something.
    public func sendMessageToNetworkThread(_ message: InternalMessage) {
        events.emit(.queueNetworkMessage, message)
    }

    /// Sends a message to the server.
    public func sendMessageToServer(_ message: ServerMessage) {
        events.emit(.queueNetworkMessage, message)
    }

    /// Sends a message to a peer.
    public func sendMessageToPeer(_ username: String, _ message: SlskMessage) {
        (message as? PeerConnectionMessage)?.username = username
        events.emit(.queueNetworkMessage, message)
    }
}

// MARK: - Update Checker

@MainActor
public final class UpdateChecker {
    private var isChecking = false

    public func check() {
        guard !isChecking else {
            return
        }

        isChecking = true

        Task.detached {
            let info: LatestVersionInfo

            do {
                let (latestVersionString, latestVersion) = try await Self.retrieveLatestVersion()
                let currentVersion = Self.createIntegerVersion(Application.version)

                info = LatestVersionInfo(latestVersion: latestVersionString, isOutdated: currentVersion < latestVersion,
                                         errorMessage: nil)
            } catch {
                info = LatestVersionInfo(latestVersion: nil, isOutdated: false,
                                         errorMessage: error.localizedDescription)
            }

            await MainActor.run {
                self.isChecking = false
                events.emit(.checkLatestVersion, info)
            }
        }
    }

    public nonisolated static func createIntegerVersion(_ version: String) -> Int {
        let parts = version.split(separator: ".").map(String.init)

        guard parts.count >= 3 else {
            return 0
        }

        // A dev version will be one less than a stable version
        let stable = (version.contains("dev") || version.contains("rc")) ? 0 : 1
        let major = Int(parts[0]) ?? 0
        let minor = Int(parts[1]) ?? 0
        let patch = Int(parts[2].components(separatedBy: "rc")[0]) ?? 0

        return (major << 24) + (minor << 16) + (patch << 8) + stable
    }

    private nonisolated static func retrieveLatestVersion() async throws -> (String, Int) {
        let url = URL(string: "https://pypi.org/pypi/nicotine-plus/json")!
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"

        let (data, _) = try await URLSession.shared.data(for: request)

        struct Response: Decodable {
            struct Info: Decodable {
                let version: String
            }
            let info: Info
        }

        let latestVersion = try JSONDecoder().decode(Response.self, from: data).info.version
        return (latestVersion, createIntegerVersion(latestVersion))
    }
}

@MainActor public let core = Core()
