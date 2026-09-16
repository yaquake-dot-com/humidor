// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Value Types

public struct ServerAddress: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

public struct SharedFolder: Codable, Hashable, Sendable {
    public var virtualName: String
    public var path: String

    public init(virtualName: String, path: String) {
        self.virtualName = virtualName
        self.path = path
    }
}

public struct BuddyEntry: Codable, Hashable, Sendable {
    public var username: String
    public var note = ""
    public var notifyStatus = false
    public var isPrioritized = false
    public var isTrusted = false
    public var lastSeen = "Never seen"
    public var country = ""

    public init(username: String, note: String = "", notifyStatus: Bool = false, isPrioritized: Bool = false,
                isTrusted: Bool = false, lastSeen: String = "Never seen", country: String = "") {
        self.username = username
        self.note = note
        self.notifyStatus = notifyStatus
        self.isPrioritized = isPrioritized
        self.isTrusted = isTrusted
        self.lastSeen = lastSeen
        self.country = country
    }
}

public struct DownloadFilter: Codable, Hashable, Sendable, Comparable {
    public var pattern: String
    /// Treat the pattern as a wildcard pattern instead of a regular expression
    public var isEscaped: Bool

    public init(pattern: String, isEscaped: Bool) {
        self.pattern = pattern
        self.isEscaped = isEscaped
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.pattern, lhs.isEscaped ? 1 : 0) < (rhs.pattern, rhs.isEscaped ? 1 : 0)
    }
}

public struct SearchFilters: Codable, Hashable, Sendable {
    public var include = ""
    public var exclude = ""
    public var size = ""
    public var bitrate = ""
    public var freeSlot = false
    public var country = ""
    public var fileType = ""
    public var length = ""

    public init() {}
}

public enum SpeedLimitMode: String, Codable, Sendable {
    case unlimited
    case primary
    case alternative
}

public enum GroupingMode: String, Codable, Sendable {
    case ungrouped
    case folderGrouping = "folder_grouping"
    case userGrouping = "user_grouping"
}

// MARK: - Sections

public struct ServerSettings: Codable, Sendable {
    public var server = ServerAddress(host: "server.slsknet.org", port: 2242)
    public var login = ""
    public var password = ""
    public var interface = ""
    public var ctcpMessages = false
    public var autoSearch: [String] = []
    public var autoReply = ""
    public var portRange: ClosedRange<Int> = 2234...2234
    public var upnp = true
    public var upnpInterval = 4
    public var autoConnectStartup = true
    public var userList: [BuddyEntry] = []
    public var banList: [String] = []
    public var ignoreList: [String] = []
    public var ipIgnoreList: [String: String] = [:]
    public var ipBlockList: [String: String] = [:]
    public var autoJoin: [String] = []
    public var autoAway = 15
    public var away = false
    public var privateChatrooms = false
}

public struct TransferSettings: Codable, Sendable {
    public var incompleteDir = Config.dataFolderPlaceholder + "/incomplete"
    public var downloadDir = Config.dataFolderPlaceholder + "/downloads"
    public var uploadDir = Config.dataFolderPlaceholder + "/received"
    public var usernameSubfolders = false
    public var shared: [SharedFolder] = []
    public var buddyShared: [SharedFolder] = []
    public var trustedShared: [SharedFolder] = []
    public var uploadBandwidth = 50
    public var useUploadSpeedLimit = SpeedLimitMode.unlimited
    public var uploadLimit = 1000
    public var uploadLimitAlt = 100
    public var useDownloadSpeedLimit = SpeedLimitMode.unlimited
    public var downloadLimit = 1000
    public var downloadLimitAlt = 100
    public var preferFriends = false
    public var useUploadSlots = false
    public var uploadSlots = 2
    public var afterFinish = ""
    public var afterFolder = ""
    public var fifoQueue = false
    public var useCustomBan = false
    public var limitBy = true
    public var customBan = "Banned, don't bother retrying"
    public var useCustomGeoBlock = false
    public var customGeoBlock = "Sorry, your country is blocked"
    public var queueLimit = 10000
    public var fileLimit = 100
    public var revealBuddyShares = false
    public var revealTrustedShares = false
    public var friendsNoLimits = false
    public var groupDownloads = GroupingMode.folderGrouping
    public var groupUploads = GroupingMode.folderGrouping
    public var geoBlock = false
    public var geoBlockCountryCodes: [String] = [""]
    public var remoteDownloads = false
    public var uploadAllowed = 3
    public var autoClearDownloads = false
    public var autoClearUploads = false
    public var rescanOnStartup = true
    public var enableFilters = false
    public var downloadRegexp = ""
    public var downloadFilters: [DownloadFilter] = [
        DownloadFilter(pattern: "*.DS_Store", isEscaped: true),
        DownloadFilter(pattern: "*.exe", isEscaped: true),
        DownloadFilter(pattern: "*.msi", isEscaped: true),
        DownloadFilter(pattern: "desktop.ini", isEscaped: true),
        DownloadFilter(pattern: "Thumbs.db", isEscaped: true)
    ]
    public var downloadDoubleClick = 2
    public var uploadDoubleClick = 2
    public var downloadsExpanded = true
    public var uploadsExpanded = true
}

public struct UserBrowseSettings: Codable, Sendable {
    public var expandFolders = true
}

public struct UserInfoSettings: Codable, Sendable {
    public var description = ""
    public var picture = ""
}

public struct WordsSettings: Codable, Sendable {
    public var censored: [String] = []
    public var autoReplaced: [String: String] = [
        "teh ": "the ",
        "taht ": "that ",
        "tihng": "thing",
        "youre": "you're",
        "jsut": "just",
        "thier": "their",
        "tihs": "this"
    ]
    public var censorWords = false
    public var replaceWords = false
    public var tab = true
    public var dropdown = false
    public var characters = 3
    public var roomNames = false
    public var buddies = true
    public var roomUsers = true
    public var commands = true
}

public struct LoggingSettings: Codable, Sendable {
    public var debug = false
    public var debugModes: [LogLevel] = []
    public var debugLogsDir = Config.dataFolderPlaceholder + "/logs/debug"
    public var logCollapsed = true
    public var transfersLogsDir = Config.dataFolderPlaceholder + "/logs/transfers"
    public var roomsTimestamp = "%X"
    public var privateTimestamp = "%x %X"
    public var logTimestamp = "%x %X"
    public var privateChat = true
    public var chatrooms = true
    public var transfers = false
    public var debugFileOutput = false
    public var roomLogsDir = Config.dataFolderPlaceholder + "/logs/rooms"
    public var privateLogsDir = Config.dataFolderPlaceholder + "/logs/private"
    public var readRoomLines = 200
    public var readPrivateLines = 200
    public var privateChats: [String] = []
    public var rooms: [String] = []
}

public struct PrivateChatSettings: Codable, Sendable {
    public var store = true
    public var users: [String] = []
}

public struct SearchSettings: Codable, Sendable {
    public var expandSearches = true
    public var groupSearches = GroupingMode.folderGrouping
    public var maxResults = 300
    public var enableHistory = true
    public var history: [String] = []
    public var enableFilters = false
    public var filtersVisible = false
    public var defaultFilters = SearchFilters()
    public var filterCountryHistory: [String] = []
    public var filterIncludeHistory: [String] = []
    public var filterExcludeHistory: [String] = []
    public var filterSizeHistory: [String] = []
    public var filterBitrateHistory: [String] = []
    public var filterTypeHistory: [String] = []
    public var filterLengthHistory: [String] = []
    public var searchResults = true
    public var maxDisplayedResults = 2500
    public var minSearchCharacters = 3
    public var privateSearchResults = false
}

public struct UISettings: Codable, Sendable {
    public var language = ""
    public var darkMode = false
    public var headerBar = true
    public var iconTheme = ""
    public var chatMe = "#908E8B"
    public var chatRemote = ""
    public var chatLocal = ""
    public var chatCommand = "#908E8B"
    public var chatHighlight = "#5288CE"
    public var urlColor = "#5288CE"
    public var userOnline = "#16BB5C"
    public var userAway = "#C9AE13"
    public var userOffline = "#E04F5E"
    public var usernameHotspots = true
    public var usernameStyle = "bold"
    public var textBackground = ""
    public var search = ""
    public var inputColor = ""
    public var spellCheck = true
    public var exitDialog = 1
    public var tabDefault = ""
    public var tabHighlight = "#497EC2"
    public var tabChanged = "#497EC2"
    public var tabSelectPrevious = true
    public var tabMain = "Top"
    public var tabRooms = "Top"
    public var tabPrivate = "Top"
    public var tabInfo = "Top"
    public var tabBrowse = "Top"
    public var tabSearch = "Top"
    public var globalFont = ""
    public var textViewFont = ""
    public var chatFont = ""
    public var tabClosers = true
    public var searchFont = ""
    public var listFont = ""
    public var browserFont = ""
    public var transfersFont = ""
    public var lastTabID = ""
    public var modesVisible: [String: Bool] = [
        "search": true,
        "downloads": true,
        "uploads": true,
        "userbrowse": true,
        "userinfo": true,
        "private": true,
        "chatrooms": true,
        "interests": true
    ]
    public var modesOrder = [
        "search", "downloads", "uploads", "userbrowse", "userinfo", "private", "userlist", "chatrooms", "interests"
    ]
    public var buddyListInChatrooms = "tab"
    public var trayIcon = true
    public var startupHidden = false
    public var fileManager = ""
    public var speechEnabled = false
    public var speechPrivate = "User %(user)s told you: %(message)s"
    public var speechRooms = "In room %(room)s, user %(user)s said: %(message)s"
    public var speechCommand = "flite -t $"
    public var width = 800
    public var height = 600
    public var xPosition = -1
    public var yPosition = -1
    public var maximized = true
    public var reverseFilePaths = true
    public var fileSizeUnit = ""
}

public struct URLSettings: Codable, Sendable {
    public var protocols: [String: String] = [:]
}

public struct InterestsSettings: Codable, Sendable {
    public var likes: [String] = []
    public var dislikes: [String] = []
}

public struct PlayersSettings: Codable, Sendable {
    public var npOtherCommand = ""
    public var npPlayer = "mpris"
    public var npFormatList: [String] = []
    public var npFormat = ""
}

public struct NotificationsSettings: Codable, Sendable {
    public var windowTitle = true
    public var tabColors = false
    public var popupSound = false
    public var popupFile = true
    public var popupFolder = true
    public var popupPrivateMessage = true
    public var popupChatroom = false
    public var popupChatroomMention = true
    public var popupWish = true
}

public struct PluginsSettings: Codable, Sendable {
    public var enable = true
    public var enabled: [String] = []
    /// Settings of individual plugins, keyed by plugin name
    public var settings: [String: [String: JSONValue]] = [:]
}

public struct StatisticsSettings: Codable, Sendable {
    public var sinceTimestamp = 0
    public var startedDownloads = 0
    public var completedDownloads = 0
    public var downloadedSize = 0
    public var startedUploads = 0
    public var completedUploads = 0
    public var uploadedSize = 0
}

/// All configuration sections, as stored in the configuration file.
public struct Settings: Codable, Sendable {
    public var server = ServerSettings()
    public var transfers = TransferSettings()
    public var userBrowse = UserBrowseSettings()
    public var userInfo = UserInfoSettings()
    public var words = WordsSettings()
    public var logging = LoggingSettings()
    public var privateChat = PrivateChatSettings()
    /// Column layout of list views, managed by the user interface
    public var columns: [String: JSONValue] = [:]
    public var searches = SearchSettings()
    public var ui = UISettings()
    public var urls = URLSettings()
    public var interests = InterestsSettings()
    public var players = PlayersSettings()
    public var notifications = NotificationsSettings()
    public var plugins = PluginsSettings()
    public var statistics = StatisticsSettings()

    public init() {}
}

// MARK: - Config

/// Holds configuration information, and reads/writes it to disk.
@MainActor
@dynamicMemberLookup
public final class Config {

    /// Placeholder for the data folder in folder paths, expanded at runtime
    public nonisolated static let dataFolderPlaceholder = "${NICOTINE_DATA_HOME}"

    /// Sections without a fixed set of options
    private static let freeFormSections: Set<String> = ["columns"]

    public private(set) var configFilePath: String
    public private(set) var dataFolderPath: String
    public private(set) var isConfigLoaded = false

    public var settings = Settings()

    nonisolated init() {
        let folderPath = Self.defaultFolderPath()

        configFilePath = (folderPath as NSString).appendingPathComponent("config.json")
        dataFolderPath = folderPath
    }

    public subscript<Section>(dynamicMember keyPath: WritableKeyPath<Settings, Section>) -> Section {
        get { settings[keyPath: keyPath] }
        set { settings[keyPath: keyPath] = newValue }
    }

    private nonisolated static func defaultFolderPath() -> String {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

        return applicationSupport.appendingPathComponent(Application.name).path
    }

    public func setConfigFile(_ filePath: String) {
        configFilePath = URL(fileURLWithPath: filePath).standardizedFileURL.path
    }

    public func setDataFolder(_ folderPath: String) {
        dataFolderPath = URL(fileURLWithPath: folderPath).standardizedFileURL.path
    }

    /// Replaces the data folder placeholder in a path with the actual data folder.
    public func expandingDataFolder(_ path: String) -> String {
        path.replacingOccurrences(of: Self.dataFolderPlaceholder, with: dataFolderPath)
    }

    // MARK: Folders

    @discardableResult
    private func createConfigFolder() -> Bool {
        let folderPath = (configFilePath as NSString).deletingLastPathComponent

        guard !folderPath.isEmpty else {
            // Only file name specified, use current folder
            return true
        }

        do {
            try FileManager.default.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
        } catch {
            log.add(String(localized: "Can't create directory '\(folderPath)', reported error: \(error.localizedDescription)",
                           bundle: .module))
            return false
        }

        return true
    }

    private func createDataFolder() {
        do {
            try FileManager.default.createDirectory(atPath: dataFolderPath, withIntermediateDirectories: true)
        } catch {
            log.add(String(localized: "Can't create directory '\(dataFolderPath)', reported error: \(error.localizedDescription)",
                           bundle: .module))
        }
    }

    // MARK: Loading

    public func loadConfig(isolatedMode: Bool = false) {
        guard !isConfigLoaded else {
            return
        }

        var defaults = Settings()

        // Resume/retry (6) action in isolated mode, open in file manager (2) action otherwise
        let transferDoubleClickAction = isolatedMode ? 6 : 2
        defaults.transfers.downloadDoubleClick = transferDoubleClickAction
        defaults.transfers.uploadDoubleClick = transferDoubleClickAction

        createConfigFolder()
        createDataFolder()

        settings = loadFile(configFilePath) { path in
            try self.parseConfig(path, defaults: defaults)
        } ?? defaults

        validateSettings(defaults: defaults)
        isConfigLoaded = true

        log.applyConfig()
        log.addDebug("Using configuration: \(configFilePath)")

        events.connect(.quit) { [self] in
            isConfigLoaded = false
        }
    }

    public var needsConfig: Bool {
        // Check if we have specified a username or password
        settings.server.login.isEmpty || settings.server.password.isEmpty
    }

    /// Reads the configuration file. Options missing from the file use their
    /// default values. Options with invalid values are reset to their default.
    private func parseConfig(_ filePath: String, defaults: Settings) throws -> Settings {
        guard FileManager.default.fileExists(atPath: filePath) else {
            return defaults
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        guard !data.isEmpty else {
            return defaults
        }

        guard let fileSections = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let defaultData = try encoder.encode(defaults)
        var merged = try JSONSerialization.jsonObject(with: defaultData) as? [String: Any] ?? [:]

        for (sectionName, fileOptions) in fileSections {
            if Self.freeFormSections.contains(sectionName) {
                var candidate = merged
                candidate[sectionName] = fileOptions

                if let candidateData = try? JSONSerialization.data(withJSONObject: candidate),
                   (try? decoder.decode(Settings.self, from: candidateData)) != nil {
                    merged = candidate
                }
                continue
            }

            guard var section = merged[sectionName] as? [String: Any] else {
                log.addDebug("Unknown config section '\(sectionName)'")
                continue
            }

            guard let fileOptions = fileOptions as? [String: Any] else {
                continue
            }

            for (option, value) in fileOptions {
                guard section[option] != nil else {
                    log.addDebug("Unknown config option '\(option)' in section '\(sectionName)'")
                    continue
                }

                let previousValue = section[option]
                section[option] = value

                var candidate = merged
                candidate[sectionName] = section

                // Check that the value is of the expected type. If not, reset the value.
                if let candidateData = try? JSONSerialization.data(withJSONObject: candidate),
                   (try? decoder.decode(Settings.self, from: candidateData)) != nil {
                    merged = candidate
                    continue
                }

                section[option] = previousValue
                log.add("Config error: Couldn't decode '\(sectionName)' section '\(option)' value, value has been reset")
            }
        }

        let mergedData = try JSONSerialization.data(withJSONObject: merged)
        return try decoder.decode(Settings.self, from: mergedData)
    }

    private func validateSettings(defaults: Settings) {
        let portRange = settings.server.portRange

        if portRange.lowerBound < 0 || portRange.upperBound > 65535 {
            settings.server.portRange = defaults.server.portRange
        }

        if settings.server.server.host.isEmpty {
            settings.server.server = defaults.server.server
        }
    }

    // MARK: Writing

    public func writeConfiguration() {
        guard isConfigLoaded, createConfigFolder() else {
            return
        }

        let settings = self.settings

        writeFileAndBackup(configFilePath, protect: true) { data in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(settings)
        }
    }

    public func writeConfigBackup(to filePath: String) {
        var filePath = filePath

        if !filePath.hasSuffix(".tar.bz2") {
            filePath += ".tar.bz2"
        }

        do {
            if FileManager.default.fileExists(atPath: filePath) {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "File \(filePath) exists"])
            }

            guard FileManager.default.fileExists(atPath: configFilePath) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Config file missing"])
            }

            let folderPath = (configFilePath as NSString).deletingLastPathComponent
            let fileName = (configFilePath as NSString).lastPathComponent

            try executeCommand("tar -cjf $ -C \"\(folderPath)\" \"\(fileName)\"", replacement: filePath,
                               background: false)

        } catch {
            log.add(String(localized: "Error backing up config: \(error.localizedDescription)", bundle: .module))
            return
        }

        log.add(String(localized: "Config backed up to: \(filePath)", bundle: .module))
    }
}

@MainActor public let config = Config()
