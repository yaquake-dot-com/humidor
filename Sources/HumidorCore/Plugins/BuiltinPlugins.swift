// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Anti SHOUT

/// Tries to spot people shouting and converts their messages to a more polite form.
final class AntiShoutPlugin: BasePlugin {

    static let info = PluginInfo(
        name: "Anti SHOUT",
        description: "Tries to spot people shouting and converts their messages to a more polite form.",
        version: "2008-11-18r00"
    )

    required init() {
        super.init()

        settings = [
            "maxscore": .double(0.6),
            "minlength": 10
        ]
        metaSettings = [
            "maxscore": PluginSettingMeta(description: "The maximum ratio of capitals before converting",
                                          type: .float, minimum: 0, maximum: 1, stepSize: 0.1),
            "minlength": PluginSettingMeta(description: "Lines shorter than this will be ignored", type: .integer,
                                           minimum: 0)
        ]
    }

    private static func capitalize(_ text: String) -> String {
        // Don't alter words that look like protocol links (e.g. http://, ftp://)
        if text.contains("://") {
            return text
        }

        return text.prefix(1).uppercased() + text.dropFirst().lowercased()
    }

    override func incomingPrivateChatEvent(user: String, line: String) -> PluginResult<(user: String, line: String)> {
        .modify((user, antiShout(line)))
    }

    override func incomingPublicChatEvent(room: String, user: String, line: String)
        -> PluginResult<(room: String, user: String, line: String)> {
        .modify((room, user, antiShout(line)))
    }

    private func antiShout(_ line: String) -> String {
        let lowers = line.filter(\.isLowercase).count
        let uppers = line.filter(\.isUppercase).count
        var score = -2.0  // unknown state (could be: no letters at all)

        if uppers > 0 {
            score = -1  // We have at least some upper letters
        }

        if lowers > 0 {
            score = Double(uppers) / Double(lowers)
        }

        var newLine = line
        let minLength = settings["minlength"]?.intValue ?? 10
        let maxScore = settings["maxscore"]?.doubleValue ?? 0.6

        if line.count > minLength && (score == -1 || score > maxScore) {
            newLine = line.components(separatedBy: ". ").map(Self.capitalize).joined(separator: ". ")
        }

        if newLine == line {
            return newLine
        }

        return newLine + " [as]"
    }
}

// MARK: - Auto-Browse Shares

/// Automatically browses shared files of a Soulseek user when they log in.
final class AutoUserBrowsePlugin: BasePlugin {

    static let info = PluginInfo(
        name: "Auto-Browse Shares",
        description: "Automatically browses shared files of a Soulseek user when they log in.",
        version: "2021-10-04r00"
    )

    private var processedUsers = Set<String>()

    required init() {
        super.init()

        settings = ["users": []]
        metaSettings = ["users": PluginSettingMeta(description: "Username", type: .listString)]
    }

    private func browseUser(_ user: String) {
        if processedUsers.contains(user) {
            core.userBrowse.browseUser(user, switchPage: false)
        }
    }

    override func userStatusNotification(user: String, status: UserStatus, privileged: Bool?) {
        if status == .offline {
            processedUsers.remove(user)
            return
        }

        guard settings["users"]?.stringArrayValue?.contains(user) == true, !processedUsers.contains(user) else {
            return
        }

        // Wait 30 seconds before browsing shares to ensure they are ready
        // and the server doesn't send an invalid port for the user
        processedUsers.insert(user)
        schedule(delay: 30) { [weak self] in self?.browseUser(user) }
    }

    override func serverDisconnectNotification(userChoice: Bool) {
        processedUsers.removeAll()
    }
}

// MARK: - Leech Detector

/// Detects when leechers are downloading, and sends them a message after a
/// file is leeched.
final class LeechDetectorPlugin: BasePlugin {

    static let info = PluginInfo(
        name: "Leech Detector",
        description: "Detects when leechers are downloading, and sends them a message after a file is leeched.\n\n"
            + "Message placeholders:\n- %files% : number of required files\n- %folders% : number of required folders",
        version: "2023-11-11r00"
    )

    private static let placeholders = [
        "%files%": "num_files",
        "%folders%": "num_folders"
    ]

    private var probedUsers: [String: String] = [:]

    required init() {
        super.init()

        settings = [
            "message": "Please consider sharing more files if you would like to download from me again. Thanks :)",
            "open_private_chat": true,
            "num_files": 1,
            "num_folders": 1,
            "detected_leechers": []
        ]
        metaSettings = [
            "message": PluginSettingMeta(
                description: "Private chat message to send to leechers. Each line is sent as a separate message, "
                    + "too many message lines may get you temporarily banned for spam!",
                type: .textView
            ),
            "open_private_chat": PluginSettingMeta(
                description: "Open chat tabs when sending private messages to leechers", type: .bool
            ),
            "num_files": PluginSettingMeta(
                description: "Require users to have a minimum number of shared files:", type: .integer, minimum: 0
            ),
            "num_folders": PluginSettingMeta(
                description: "Require users to have a minimum number of shared folders:", type: .integer, minimum: 1
            ),
            "detected_leechers": PluginSettingMeta(description: "Detected leechers", type: .listString)
        ]
    }

    private var detectedLeechers: [String] {
        get { settings["detected_leechers"]?.stringArrayValue ?? [] }
        set { settings["detected_leechers"] = .array(newValue.map { .string($0) }) }
    }

    override func loadedNotification() {
        let minNumFiles = Int(metaSettings["num_files"]?.minimum ?? 0)
        let minNumFolders = Int(metaSettings["num_folders"]?.minimum ?? 1)

        if (settings["num_files"]?.intValue ?? 0) < minNumFiles {
            settings["num_files"] = .int(minNumFiles)
        }

        if (settings["num_folders"]?.intValue ?? 0) < minNumFolders {
            settings["num_folders"] = .int(minNumFolders)
        }

        log("Require users have a minimum of \(settings["num_files"]?.intValue ?? 0) files in "
            + "\(settings["num_folders"]?.intValue ?? 0) shared public folders.")
    }

    private func checkUser(_ user: String, numFiles: Int, numFolders: Int, source: String = "server") {
        guard let probeState = probedUsers[user] else {
            // We are not watching this user
            return
        }

        if probeState == "okay" {
            // User was already accepted previously, nothing to do
            return
        }

        if probeState == "requesting_shares" && source != "peer" {
            // Waiting for stats from peer, but received stats from server. Ignore.
            return
        }

        let isUserAccepted = numFiles >= (settings["num_files"]?.intValue ?? 1)
            && numFolders >= (settings["num_folders"]?.intValue ?? 1)

        if isUserAccepted || core.buddies.users[user] != nil {
            detectedLeechers.removeAll { $0 == user }
            probedUsers[user] = "okay"

            if isUserAccepted {
                log("User \(user) is okay, sharing \(numFiles) files in \(numFolders) folders.")
            } else {
                log("Buddy \(user) is sharing \(numFiles) files in \(numFolders) folders. Not complaining.")
            }
            return
        }

        if !probeState.hasPrefix("requesting") {
            // We already dealt with the user this session
            return
        }

        if detectedLeechers.contains(user) {
            // We already messaged the user in a previous session
            probedUsers[user] = "processed_leecher"
            return
        }

        if (numFiles <= 0 || numFolders <= 0) && probeState != "requesting_shares" {
            // SoulseekQt only sends the number of shared files/folders to the server once on startup.
            // Verify user's actual number of files/folders.
            log("User \(user) has no shared files according to the server, requesting shares to verify…")

            probedUsers[user] = "requesting_shares"
            core.userBrowse.requestUserShares(user)
            return
        }

        let action = (settings["message"]?.stringValue ?? "").isEmpty ? "log" : "message"

        probedUsers[user] = "pending_leecher"
        log("Leecher detected, \(user) is only sharing \(numFiles) files in \(numFolders) folders. "
            + "Going to \(action) leecher after transfer…")
    }

    override func uploadQueuedNotification(user: String, virtualPath: String, realPath: String) {
        guard probedUsers[user] == nil else {
            return
        }

        probedUsers[user] = "requesting_stats"

        guard core.users.watched[user] != nil else {
            // Transfer manager will request the stats from the server shortly
            return
        }

        // We've received the user's stats in the past. They could be outdated by
        // now, so request them again.
        core.users.requestUserStats(user)
    }

    override func userStatsNotification(user: String, stats: UserStats) {
        checkUser(user, numFiles: stats.files ?? 0, numFolders: stats.folders ?? 0, source: stats.source)
    }

    override func uploadFinishedNotification(user: String, virtualPath: String, realPath: String) {
        guard probedUsers[user] == "pending_leecher" else {
            return
        }

        probedUsers[user] = "processed_leecher"

        let message = settings["message"]?.stringValue ?? ""

        guard !message.isEmpty else {
            log("Leecher \(user) doesn't share enough files. No message is specified in plugin settings.")
            return
        }

        for var line in message.components(separatedBy: .newlines) {
            for (placeholder, optionKey) in Self.placeholders {
                // Replace message placeholders with actual values specified in the plugin settings
                line = line.replacingOccurrences(of: placeholder, with: String(settings[optionKey]?.intValue ?? 0))
            }

            sendPrivate(user, line, showUI: settings["open_private_chat"]?.boolValue ?? true, switchPage: false)
        }

        if !detectedLeechers.contains(user) {
            detectedLeechers.append(user)
        }

        log("Leecher \(user) doesn't share enough files. Message sent.")
    }
}

// MARK: - Multi Paste

/// Intercepts messages you send with newlines in them, and splits them up in
/// separate messages. This is useful on the official Soulseek servers since
/// they block messages with newlines.
final class MultiPastePlugin: BasePlugin {

    static let info = PluginInfo(
        name: "Multi Paste",
        description: "This plugin intercepts messages you send with newlines in them, and splits them up in separate "
            + "messages. This is useful on the official Soulseek servers since they block messages with newlines.",
        version: "2008-07-03r00"
    )

    required init() {
        super.init()

        settings = [
            "maxpubliclines": 4,
            "maxprivatelines": 8
        ]
        metaSettings = [
            "maxpubliclines": PluginSettingMeta(
                description: "The maximum number of lines that will be pasted in public", type: .integer
            ),
            "maxprivatelines": PluginSettingMeta(
                description: "The maximum number of lines that will be pasted in private", type: .integer
            )
        ]
    }

    private func splitLines(_ line: String, maxLines: Int) -> [String]? {
        let lines = line.components(separatedBy: .newlines).filter { !$0.isEmpty }

        guard lines.count > 1 else {
            return nil
        }

        if lines.count > maxLines {
            log("Posting \(maxLines) of \(lines.count) lines.")
        } else {
            log("Splitting lines.")
        }

        return Array(lines.prefix(maxLines))
    }

    override func outgoingPrivateChatEvent(user: String, line: String) -> PluginResult<(user: String, line: String)> {
        guard let lines = splitLines(line, maxLines: settings["maxprivatelines"]?.intValue ?? 8) else {
            return .pass
        }

        for splitLine in lines {
            sendPrivate(user, splitLine)
        }

        return .zap
    }

    override func outgoingPublicChatEvent(room: String, line: String) -> PluginResult<(room: String, line: String)> {
        guard let lines = splitLines(line, maxLines: settings["maxpubliclines"]?.intValue ?? 4) else {
            return .pass
        }

        for splitLine in lines {
            sendPublic(room, splitLine)
        }

        return .zap
    }
}

// MARK: - Now Playing Search

/// Searches for a song your media player is currently playing.
final class NowPlayingSearchPlugin: BasePlugin {

    static let info = PluginInfo(
        name: "Now Playing Search",
        description: "Searches for a song your media player is currently playing. This plugin uses the media player "
            + "specified in the settings of the 'Now Playing'-feature.\n\nThe following keywords can be used when "
            + "searching:\n- $t : Title\n- $n : Now Playing (typically 'Artist' - 'Title')\n- $l : Duration\n"
            + "- $r : Bitrate\n- $c : Comment\n- $a : Artist\n- $b : Album\n- $k : Track Number\n- $y : Year\n"
            + "- $f : Filename (URI)\n- $p : Program",
        version: "2020-11-08r00"
    )

    private func nowPlaying(_ text: String) async -> String {
        await core.nowPlaying?.nowPlaying(format: text) ?? text
    }

    override func outgoingGlobalSearchEvent(text: String) async -> PluginResult<String> {
        .modify(await nowPlaying(text))
    }

    override func outgoingRoomSearchEvent(room: String?, text: String) async
        -> PluginResult<(room: String?, text: String)> {
        .modify((room, await nowPlaying(text)))
    }

    override func outgoingBuddySearchEvent(text: String) async -> PluginResult<String> {
        .modify(await nowPlaying(text))
    }

    override func outgoingUserSearchEvent(users: [String], text: String) async
        -> PluginResult<(users: [String], text: String)> {
        .modify((users, await nowPlaying(text)))
    }
}

// MARK: - Spamfilter

/// Blocks a number of different kinds of spam.
final class SpamFilterPlugin: BasePlugin {

    static let info = PluginInfo(
        name: "Spamfilter",
        description: "The plugin blocks a number of different kind of spam:\n1) It blocks ASCII art spam. These are "
            + "messages in chatrooms that are made up of a few different characters that together form pictures like "
            + "a christmas tree or a middle finger.\n2) It blocks extremely long sentences uttered in chatrooms, "
            + "filtering out copy/paste spam like long rants\n3) It blocks chat room and private messages containing "
            + "sentences you consider spam, for example messages trying to sell you foobar.",
        version: "2021-05-11r00"
    )

    required init() {
        super.init()

        settings = [
            "minlength": 200,
            "maxlength": 400,
            "maxdiffcharacters": 10,
            "badprivatephrases": []
        ]
        metaSettings = [
            "minlength": PluginSettingMeta(
                description: "The minimum length of a line before it's considered as ASCII spam", type: .integer
            ),
            "maxdiffcharacters": PluginSettingMeta(
                description: "The maximum number of different characters that is still considered ASCII spam",
                type: .integer
            ),
            "maxlength": PluginSettingMeta(
                description: "The maximum length of a line before it's considered as spam.", type: .integer
            ),
            "badprivatephrases": PluginSettingMeta(description: "Filter chat messages containing phrase:",
                                                   type: .listString)
        ]
    }

    override func loadedNotification() {
        log("A line should be at least \(settings["minlength"]?.intValue ?? 200) long with a maximum of "
            + "\(settings["maxdiffcharacters"]?.intValue ?? 10) different characters before it's considered ASCII spam.")
    }

    private func containsBadPhrase(user: String, line: String) -> Bool {
        for phrase in settings["badprivatephrases"]?.stringArrayValue ?? [] where line.lowercased().contains(phrase) {
            log("Blocked spam from \(user): \(line)")
            return true
        }

        return false
    }

    override func incomingPublicChatEvent(room: String, user: String, line: String)
        -> PluginResult<(room: String, user: String, line: String)> {
        if line.count >= (settings["minlength"]?.intValue ?? 200)
            && Set(line).count < (settings["maxdiffcharacters"]?.intValue ?? 10) {
            log("Filtered ASCII spam from \"\(user)\" in room \"\(room)\"")
            return .zap
        }

        if line.count > (settings["maxlength"]?.intValue ?? 400) {
            log("Filtered really long line (\(line.count) characters) from \"\(user)\" in room \"\(room)\"")
            return .zap
        }

        return containsBadPhrase(user: user, line: line) ? .zap : .pass
    }

    override func incomingPrivateChatEvent(user: String, line: String) -> PluginResult<(user: String, line: String)> {
        containsBadPhrase(user: user, line: line) ? .zap : .pass
    }
}

// MARK: - Plugin Debugger

/// Examines the flow of events in the plugin system.
final class PluginDebuggerPlugin: BasePlugin {

    static let info = PluginInfo(
        name: "Plugin Debugger",
        description: "Plugin to examine the flow of events in the plugin system. Useful if you're a programmer.",
        version: "2021-12-30r00"
    )

    override func initialize() { log("init()") }
    override func disable() { log("disable()") }
    override func loadedNotification() { log("loaded_notification()") }
    override func unloadedNotification() { log("unloaded_notification()") }
    override func shutdownNotification() { log("shutdown_notification()") }

    override func publicRoomMessageNotification(room: String, user: String, line: String) {
        log("public_room_message_notification(room=\(room), user=\(user), line=\(line))")
    }

    override func searchRequestNotification(searchTerm: String, user: String, token: Int) {
        log("search_request_notification(searchterm=\(searchTerm), user=\(user), token=\(token))")
    }

    override func incomingPrivateChatEvent(user: String, line: String) -> PluginResult<(user: String, line: String)> {
        log("incoming_private_chat_event(user=\(user), line=\(line))")
        return .pass
    }

    override func incomingPrivateChatNotification(user: String, line: String) {
        log("incoming_private_chat_notification(user=\(user), line=\(line))")
    }

    override func incomingPublicChatEvent(room: String, user: String, line: String)
        -> PluginResult<(room: String, user: String, line: String)> {
        log("incoming_public_chat_event(room=\(room), user=\(user), line=\(line))")
        return .pass
    }

    override func incomingPublicChatNotification(room: String, user: String, line: String) {
        log("incoming_public_chat_notification(room=\(room), user=\(user), line=\(line))")
    }

    override func outgoingPrivateChatEvent(user: String, line: String) -> PluginResult<(user: String, line: String)> {
        log("outgoing_private_chat_event(user=\(user), line=\(line))")
        return .pass
    }

    override func outgoingPrivateChatNotification(user: String, line: String) {
        log("outgoing_private_chat_notification(user=\(user), line=\(line))")
    }

    override func outgoingPublicChatEvent(room: String, line: String) -> PluginResult<(room: String, line: String)> {
        log("outgoing_public_chat_event(room=\(room), line=\(line))")
        return .pass
    }

    override func outgoingPublicChatNotification(room: String, line: String) {
        log("outgoing_public_chat_notification(room=\(room), line=\(line))")
    }

    override func outgoingGlobalSearchEvent(text: String) async -> PluginResult<String> {
        log("outgoing_global_search_event(text=\(text))")
        return .pass
    }

    override func outgoingRoomSearchEvent(room: String?, text: String) async
        -> PluginResult<(room: String?, text: String)> {
        log("outgoing_room_search_event(rooms=\(room ?? "None"), text=\(text))")
        return .pass
    }

    override func outgoingBuddySearchEvent(text: String) async -> PluginResult<String> {
        log("outgoing_buddy_search_event(text=\(text))")
        return .pass
    }

    override func outgoingUserSearchEvent(users: [String], text: String) async
        -> PluginResult<(users: [String], text: String)> {
        log("outgoing_user_search_event(users=\(users), text=\(text))")
        return .pass
    }

    override func userResolveNotification(user: String, ipAddress: String, port: Int, country: String?) {
        log("user_resolve_notification(user=\(user), ip_address=\(ipAddress), port=\(port), "
            + "country=\(country ?? "None"))")
    }

    override func serverConnectNotification() { log("server_connect_notification()") }

    override func serverDisconnectNotification(userChoice: Bool) {
        log("server_disconnect_notification(userchoice=\(userChoice))")
    }

    override func joinChatroomNotification(room: String) { log("join_chatroom_notification(room=\(room))") }
    override func leaveChatroomNotification(room: String) { log("leave_chatroom_notification(room=\(room))") }

    override func userJoinChatroomNotification(room: String, user: String) {
        log("user_join_chatroom_notification(room=\(room), user=\(user))")
    }

    override func userLeaveChatroomNotification(room: String, user: String) {
        log("user_leave_chatroom_notification(room=\(room), user=\(user))")
    }

    override func userStatsNotification(user: String, stats: UserStats) {
        log("user_stats_notification(user=\(user), stats=\(stats))")
    }

    override func userStatusNotification(user: String, status: UserStatus, privileged: Bool?) {
        log("user_status_notification(user=\(user), status=\(status.rawValue), "
            + "privileged=\(privileged.map(String.init) ?? "None"))")
    }

    override func uploadQueuedNotification(user: String, virtualPath: String, realPath: String) {
        log("upload_queued_notification(user=\(user), virtual_path=\(virtualPath), real_path=\(realPath))")
    }

    override func uploadStartedNotification(user: String, virtualPath: String, realPath: String) {
        log("upload_started_notification(user=\(user), virtual_path=\(virtualPath), real_path=\(realPath))")
    }

    override func uploadFinishedNotification(user: String, virtualPath: String, realPath: String) {
        log("upload_finished_notification(user=\(user), virtual_path=\(virtualPath), real_path=\(realPath))")
    }

    override func downloadStartedNotification(user: String, virtualPath: String, realPath: String) {
        log("download_started_notification(user=\(user), virtual_path=\(virtualPath), real_path=\(realPath))")
    }

    override func downloadFinishedNotification(user: String, virtualPath: String, realPath: String) {
        log("download_finished_notification(user=\(user), virtual_path=\(virtualPath), real_path=\(realPath))")
    }
}

// MARK: - YouTube Info

/// Discretely displays information for YouTube links posted in chat (only you
/// can see it).
final class YouTubeInfoPlugin: BasePlugin {

    static let info = PluginInfo(
        name: "YouTube Info",
        description: "This plugin discretely displays information for YouTube links posted in chat (only you can see "
            + "it).\n\nPlaceholders:\n- %title%\n- %description%\n- %duration%\n- %quality%\n- %channel%\n- %views%\n"
            + "- %likes%\n\nRequest an API key:\nhttps://developers.google.com/youtube/v3/getting-started",
        version: "2022-12-17r00"
    )

    private static let videoIDPattern = try? NSRegularExpression(
        pattern: "(https?://((m|music)\\.)?|www\\.)youtu(\\.be/|be\\.com/(shorts/|watch\\S+v=))(?<videoid>[-\\w]{11})"
    )

    private var lastVideoID: [String: [String: String]] = ["private": [:], "public": [:]]

    required init() {
        super.init()

        settings = [
            "api_key": "",
            "color": "Local",
            "format": ["* Title: %title%", "* Duration: %duration% - Views: %views%"]
        ]
        metaSettings = [
            "api_key": PluginSettingMeta(description: "YouTube Data v3 API key:", type: .string),
            "color": PluginSettingMeta(description: "Message color:", type: .dropdown,
                                       options: ["Remote", "Local", "Action", "Hilite"]),
            "format": PluginSettingMeta(description: "Message format", type: .listString)
        ]
    }

    override func incomingPublicChatNotification(room: String, user: String, line: String) {
        guard !core.networkFilter.isUserIgnored(user), !core.networkFilter.isUserIPIgnored(username: user),
              let videoID = videoID(mode: "public", source: room, line: line) else {
            return
        }

        showVideoInfo(videoID) { [weak self] text, color in
            self?.echoPublic(room, text, messageType: color)
        }
    }

    override func incomingPrivateChatNotification(user: String, line: String) {
        guard !core.networkFilter.isUserIgnored(user), !core.networkFilter.isUserIPIgnored(username: user),
              let videoID = videoID(mode: "private", source: user, line: line) else {
            return
        }

        showVideoInfo(videoID) { [weak self] text, color in
            self?.echoPrivate(user, text, messageType: color)
        }
    }

    private func videoID(mode: String, source: String, line: String) -> String? {
        guard let match = Self.videoIDPattern?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(withName: "videoid"), in: line) else {
            return nil
        }

        let videoID = String(line[range])

        if lastVideoID[mode]?[source] == videoID {
            return nil
        }

        lastVideoID[mode]?[source] = videoID
        return videoID
    }

    private func showVideoInfo(_ videoID: String, echo: @escaping @MainActor (String, String) -> Void) {
        let apiKey = settings["api_key"]?.stringValue ?? ""
        let formats = settings["format"]?.stringArrayValue ?? []
        let color = (settings["color"]?.stringValue ?? "Local").lowercased()

        Task { @MainActor [weak self] in
            guard let self, let parsed = await parseResponse(videoID, apiKey: apiKey) else {
                return
            }

            for format in formats {
                echo(Self.replacing(format, parsed), color)
            }
        }
    }

    private func parseResponse(_ videoID: String, apiKey: String) async -> [String: String]? {
        guard !apiKey.isEmpty else {
            log("No API key specified")
            return nil
        }

        let responseBody: Data

        do {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
            components.queryItems = [
                URLQueryItem(name: "part", value: "snippet,statistics,contentDetails"),
                URLQueryItem(name: "id", value: videoID),
                URLQueryItem(name: "key", value: apiKey)
            ]

            let request = URLRequest(url: components.url!, timeoutInterval: 10)
            (responseBody, _) = try await URLSession.shared.data(for: request)
        } catch {
            log("Failed to connect to www.googleapis.com: \(error.localizedDescription)")
            return nil
        }

        guard let data = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any] else {
            log("Failed to parse response from www.googleapis.com")
            return nil
        }

        if let errorInfo = data["error"] {
            log(((errorInfo as? [String: Any])?["message"] as? String) ?? String(describing: errorInfo))
            return nil
        }

        let totalResults = (data["pageInfo"] as? [String: Any])?["totalResults"] as? Int

        guard let totalResults, totalResults > 0 else {
            if totalResults != nil {
                // Video removed / invalid id
                log("Video unavailable")
            } else {
                log("Youtube API appears to be broken")
            }
            return nil
        }

        guard let item = (data["items"] as? [[String: Any]])?.first,
              let snippet = item["snippet"] as? [String: Any],
              let contentDetails = item["contentDetails"] as? [String: Any],
              let statistics = item["statistics"] as? [String: Any],
              let title = snippet["title"] as? String,
              let description = snippet["description"] as? String,
              let channel = snippet["channelTitle"] as? String,
              let live = snippet["liveBroadcastContent"] as? String,
              let isoDuration = contentDetails["duration"] as? String,
              let definition = contentDetails["definition"] as? String else {
            log("An error occurred while parsing id \"\(videoID)\"")
            return nil
        }

        var views = "RESTRICTED"
        var likes = "LIKES"

        if let viewCount = (statistics["viewCount"] as? String).flatMap(Int.init) {
            views = humanize(viewCount)
        }

        if let likeCount = (statistics["likeCount"] as? String).flatMap(Int.init) {
            likes = humanize(likeCount)
        }

        let duration = ["live", "upcoming"].contains(live) ? live.uppercased() : Self.duration(isoDuration)

        return [
            "%title%": title, "%description%": description, "%duration%": duration,
            "%quality%": definition.uppercased(), "%channel%": channel, "%views%": views, "%likes%": likes
        ]
    }

    private static func replacing(_ subject: String, _ replacements: [String: String]) -> String {
        replacements.reduce(subject) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    private static func duration(_ iso8601Duration: String) -> String {
        let intervals: [Character: Int] = ["D": 86400, "H": 3600, "M": 60, "S": 1]
        var seconds = 0
        var number = ""

        for character in iso8601Duration {
            if character.isNumber {
                number.append(character)
            } else {
                if let interval = intervals[character], let value = Int(number) {
                    seconds += interval * value
                }
                number = ""
            }
        }

        return humanLength(seconds)
    }
}
