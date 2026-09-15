// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum SearchMode: String, Sendable {
    case global
    case rooms
    case buddies
    case user
    case wishlist
}

public final class SearchRequest {
    public let token: Int
    public let term: String
    public let termSanitized: String
    public let termTransmitted: String
    public let includedWords: [String]
    public let excludedWords: [String]
    public let mode: SearchMode
    public let room: String?
    public let users: [String]?
    public var isIgnored: Bool

    init(token: Int, term: String, termSanitized: String, termTransmitted: String, includedWords: [String],
         excludedWords: [String], mode: SearchMode, room: String?, users: [String]?, isIgnored: Bool) {
        self.token = token
        self.term = term
        self.termSanitized = termSanitized
        self.termTransmitted = termTransmitted
        self.includedWords = includedWords
        self.excludedWords = excludedWords
        self.mode = mode
        self.room = room
        self.users = users
        self.isIgnored = isIgnored
    }
}

public struct SearchAdded {
    public var token: Int
    public var search: SearchRequest
    public var switchPage: Bool
}

public extension EventName where Payload == Int {
    static var removeSearch: Self { .init("remove-search") }
    static var showSearch: Self { .init("show-search") }
}

public extension EventName where Payload == SearchAdded {
    static var addSearch: Self { .init("add-search") }
}

public extension EventName where Payload == String {
    static var addWish: Self { .init("add-wish") }
    static var removeWish: Self { .init("remove-wish") }
}

/// A file to download from search results.
public struct SearchResultFile {
    public var virtualPath: String
    public var size: Int
    public var fileAttributes: [Int: Int]

    public init(virtualPath: String, size: Int, fileAttributes: [Int: Int]) {
        self.virtualPath = virtualPath
        self.size = size
        self.fileAttributes = fileAttributes
    }
}

@MainActor
public final class Search {

    public static let searchHistoryLimit = 200
    public static let resultFilterHistoryLimit = 50
    private static let removedSearchCharacters: Set<Character> = [
        "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/", ":", ";",
        "<", "=", ">", "?", "@", "[", "\\", "]", "^", "_", "`", "{", "|", "}", "~", "–", "—",
        "‐", "’", "“", "”", "…"
    ]

    public private(set) var searches = OrderedDictionary<Int, SearchRequest>()
    public private(set) var excludedPhrases: [String] = []
    public private(set) var token = initialToken()
    public private(set) var wishlistInterval = 0
    private var ownTokens = Set<Int>()
    private var wishlistTimerID: Int?

    init() {
        events.connect(.excludedSearchPhrases) { [self] msg in excludedSearchPhrases(msg) }
        events.connect(.fileSearchRequestDistributed) { [self] msg in fileSearchRequestDistributed(msg) }
        events.connect(.fileSearchRequestServer) { [self] msg in fileSearchRequestServer(msg) }
        events.connect(.fileSearchResponse) { [self] msg in fileSearchResponse(msg) }
        events.connect(.quit) { [self] in removeAllSearches() }
        events.connect(.serverDisconnect) { [self] _ in serverDisconnect() }
        events.connect(.serverLogin) { msg in Self.serverLogin(msg) }
        events.connect(.setWishlistInterval) { [self] msg in setWishlistInterval(msg) }
        events.connect(.start) { [self] in start() }
    }

    private func start() {
        // Create wishlist searches
        for searchTerm in config.server.autoSearch {
            token = incrementToken(token)
            addSearch(searchTerm, mode: .wishlist, isIgnored: true)
        }
    }

    private static func serverLogin(_ msg: Login) {
        guard msg.success else {
            return
        }

        if !config.searches.searchResults {
            log.addSearch("Search responses disabled in preferences, ignoring search requests from other users")
        }
    }

    private func serverDisconnect() {
        excludedPhrases.removeAll()
        ownTokens.removeAll()

        events.cancelScheduled(wishlistTimerID)
        wishlistInterval = 0
    }

    public func requestFolderDownload(username: String, folderPath: String, visibleFiles: [SearchResultFile],
                                      downloadFolderPath: String? = nil) {
        // Ask for the rest of the files in the folder
        core.downloads.enqueueFolder(username: username, folderPath: folderPath, downloadFolderPath: downloadFolderPath)

        // Queue the visible search results
        let destinationFolderPath = core.downloads.folderDestination(username: username, folderPath: folderPath)

        for file in visibleFiles {
            core.downloads.enqueueDownload(username: username, virtualPath: file.virtualPath,
                                           folderPath: destinationFolderPath, size: file.size,
                                           fileAttributes: file.fileAttributes)
        }
    }

    // MARK: Outgoing Search Requests

    /// Allows parsing search result messages for a search token.
    public static func addAllowedToken(_ token: Int) {
        SearchTokens.allow(token)
    }

    /// Disallows parsing search result messages for a search token.
    public static func removeAllowedToken(_ token: Int) {
        SearchTokens.disallow(token)
    }

    @discardableResult
    func addSearch(_ searchTerm: String, mode: SearchMode, room: String? = nil, users: [String]? = nil,
                   isIgnored: Bool = false) -> SearchRequest {
        let sanitized = sanitizeSearchTerm(searchTerm)
        let search = SearchRequest(
            token: token, term: searchTerm, termSanitized: sanitized.term, termTransmitted: sanitized.termTransmitted,
            includedWords: sanitized.includedWords, excludedWords: sanitized.excludedWords, mode: mode, room: room,
            users: users, isIgnored: isIgnored
        )

        searches[token] = search

        if !isIgnored {
            Self.addAllowedToken(token)
        }

        return search
    }

    public func removeSearch(_ token: Int) {
        Self.removeAllowedToken(token)

        guard let search = searches[token] else {
            return
        }

        if search.mode == .wishlist && config.server.autoSearch.contains(search.term) {
            search.isIgnored = true
        } else {
            searches.removeValue(forKey: token)
        }

        events.emit(.removeSearch, token)
    }

    public func removeAllSearches() {
        for token in searches.keys {
            removeSearch(token)
        }
    }

    public func showSearch(_ token: Int) {
        events.emit(.showSearch, token)
    }

    /// Splits a search term into words, keeping phrases in double quotes
    /// together.
    private static func splitSearchTermWords(_ searchTerm: String) -> [String] {
        var words: [String] = []
        var current = ""
        var isQuoted = false
        var inWord = false

        for character in searchTerm {
            if isQuoted {
                current.append(character)

                if character == "\"" {
                    // Closing quote ends the token
                    words.append(current)
                    current = ""
                    isQuoted = false
                    inWord = false
                }
                continue
            }

            if character.isWhitespace {
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
                continue
            }

            if !inWord && character == "\"" {
                isQuoted = true
                current = "\""
                continue
            }

            current.append(character)
            inWord = true
        }

        if isQuoted {
            // No closing quotation
            return searchTerm.split(whereSeparator: \.isWhitespace).map(String.init)
        }

        if inWord {
            words.append(current)
        }

        return words
    }

    private static func removingSearchCharacters(_ text: String) -> String {
        String(text.map { removedSearchCharacters.contains($0) ? " " : $0 })
    }

    private static func removingPunctuation(_ text: String) -> String {
        String(text.map { Character.punctuation.contains($0) ? " " : $0 })
    }

    public func sanitizeSearchTerm(_ searchTerm: String)
        -> (term: String, termTransmitted: String, includedWords: [String], excludedWords: [String]) {
        var includedWords: [String] = []
        var excludedWords: [String] = []
        var searchTerm = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        var searchTermTransmitted = searchTerm

        var searchTermWords = Self.splitSearchTermWords(searchTerm)

        // Remove certain special characters from search term
        // SoulseekQt doesn't seem to send search results if such characters are included (July 7, 2020)
        var searchTermWordsTransmitted: [String] = []

        for (index, originalWord) in searchTermWords.enumerated() {
            guard let firstCharacter = originalWord.first else {
                continue
            }

            var word = originalWord

            if firstCharacter == "*" && word.count > 1 {
                // Partial word (*erm)
                includedWords.append(String(word.dropFirst()).lowercased())

            } else if firstCharacter == "-" && word.count > 1 {
                // Excluded word (-word)
                excludedWords.append(String(word.dropFirst()).lowercased())

            } else if firstCharacter == "\"" && word.last == "\"" && word.count > 2 {
                // Phrase "some words here"
                word = String(word.dropFirst().dropLast())
                includedWords.append(word.lowercased())

                // Remove problematic characters before appending to outgoing search term
                for innerWord in Self.removingSearchCharacters(word).split(whereSeparator: \.isWhitespace) {
                    searchTermWordsTransmitted.append(String(innerWord))
                }

                continue

            } else {
                // Remove problematic characters before appending to outgoing search term
                let subwords = Self.removingSearchCharacters(word).split(whereSeparator: \.isWhitespace)
                word = subwords.joined(separator: " ")
                searchTermWords[index] = word

                if subwords.isEmpty {
                    continue
                }

                for subword in Self.removingPunctuation(word).split(whereSeparator: \.isWhitespace) {
                    includedWords.append(subword.lowercased())
                }
            }

            searchTermWordsTransmitted.append(word)
        }

        let sanitizedSearchTermTransmitted = searchTermWordsTransmitted.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        // Only modify search term if string also contains non-special characters
        if !sanitizedSearchTermTransmitted.isEmpty {
            searchTerm = searchTermWords.filter { !$0.isEmpty }.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            searchTermTransmitted = sanitizedSearchTermTransmitted
        }

        return (searchTerm, searchTermTransmitted, includedWords, excludedWords)
    }

    private func processSearchTerm(_ searchTerm: String, mode: SearchMode, room: String? = nil,
                                   users: [String]? = nil) async -> (term: String, room: String?, users: [String]?) {
        var searchTerm = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        var room = room
        var users = users
        let pluginHandler = core.pluginHandler

        switch mode {
        case .global:
            if let feedback = await pluginHandler?.outgoingGlobalSearchEvent(searchTerm) {
                searchTerm = feedback
            }

        case .rooms:
            if room == nil || room?.isEmpty == true {
                room = ServerSettings().autoJoin.first
            }

            if let feedback = await pluginHandler?.outgoingRoomSearchEvent(room: room, text: searchTerm) {
                (room, searchTerm) = feedback
            }

        case .buddies:
            if let feedback = await pluginHandler?.outgoingBuddySearchEvent(searchTerm) {
                searchTerm = feedback
            }

        case .user:
            if users == nil || users?.isEmpty == true {
                users = core.users.loginUsername.map { [$0] } ?? []
            }

            if let feedback = await pluginHandler?.outgoingUserSearchEvent(users: users ?? [], text: searchTerm) {
                (users, searchTerm) = feedback
            }

        case .wishlist:
            if let feedback = await pluginHandler?.outgoingWishlistSearchEvent(searchTerm) {
                searchTerm = feedback
            }
        }

        return (searchTerm, room, users)
    }

    /// Starts a search. The search term is passed through plugins first.
    public func doSearch(_ searchTerm: String, mode: SearchMode, room: String? = nil, users: [String]? = nil,
                         switchPage: Bool = true) {
        Task { @MainActor in
            await performSearch(searchTerm, mode: mode, room: room, users: users, switchPage: switchPage)
        }
    }

    public func performSearch(_ searchTerm: String, mode: SearchMode, room: String? = nil, users: [String]? = nil,
                              switchPage: Bool = true) async {
        // Validate search term and run it through plugins
        let (searchTerm, room, users) = await processSearchTerm(searchTerm, mode: mode, room: room, users: users)

        // Get a new search token
        token = incrementToken(token)
        let search = addSearch(searchTerm, mode: mode, room: room, users: users)

        if config.searches.enableHistory {
            var items = config.searches.history
            items.removeAll { $0 == search.termSanitized }
            items.insert(search.termSanitized, at: 0)

            // Clear old items
            config.searches.history = Array(items.prefix(Self.searchHistoryLimit))
            config.writeConfiguration()
        }

        switch mode {
        case .global:
            doGlobalSearch(search.termTransmitted)
        case .rooms:
            doRoomsSearch(search.termTransmitted, room: room ?? "")
        case .buddies:
            doBuddiesSearch(search.termTransmitted)
        case .user:
            doPeerSearch(search.termTransmitted, users: users ?? [])
        case .wishlist:
            break
        }

        events.emit(.addSearch, SearchAdded(token: search.token, search: search, switchPage: switchPage))
    }

    private func doGlobalSearch(_ text: String) {
        core.sendMessageToServer(FileSearch(token: token, text: text))
    }

    private func doRoomsSearch(_ text: String, room: String) {
        core.sendMessageToServer(RoomSearch(room: room, token: token, text: text))
    }

    private func doBuddiesSearch(_ text: String) {
        for username in core.buddies.users.keys {
            core.sendMessageToServer(UserSearch(searchUsername: username, token: token, text: text))
        }
    }

    private func doPeerSearch(_ text: String, users: [String]) {
        for username in users {
            if username == core.users.loginUsername {
                ownTokens.insert(token)
            }

            core.sendMessageToServer(UserSearch(searchUsername: username, token: token, text: text))
        }
    }

    private func doWishlistSearch(token: Int, text: String) async {
        let (text, _, _) = await processSearchTerm(text, mode: .wishlist)

        guard !text.isEmpty else {
            return
        }

        log.addSearch(String(localized: "Searching for wishlist item \"\(text)\"", bundle: .module))

        Self.addAllowedToken(token)
        core.sendMessageToServer(WishlistSearch(token: token, text: text))
    }

    private func doWishlistSearchInterval() {
        guard let term = config.server.autoSearch.popLast() else {
            return
        }

        // Search for a maximum of 1 item at each search interval
        config.server.autoSearch.insert(term, at: 0)

        for search in searches.values where search.term == term && search.mode == .wishlist {
            search.isIgnored = false

            let token = search.token
            let text = search.termTransmitted
            Task { @MainActor in await doWishlistSearch(token: token, text: text) }
            break
        }
    }

    public func addWish(_ wish: String) {
        guard !wish.isEmpty else {
            return
        }

        if !config.server.autoSearch.contains(wish) {
            config.server.autoSearch.append(wish)
            config.writeConfiguration()
        }

        if !searches.values.contains(where: { $0.term == wish && $0.mode == .wishlist }) {
            // Get a new search token
            token = incrementToken(token)
            addSearch(wish, mode: .wishlist, isIgnored: true)
        }

        events.emit(.addWish, wish)
    }

    public func removeWish(_ wish: String) {
        guard config.server.autoSearch.contains(wish) else {
            return
        }

        config.server.autoSearch.removeAll { $0 == wish }
        config.writeConfiguration()

        for (token, search) in searches where search.term == wish && search.mode == .wishlist {
            if search.isIgnored {
                searches.removeValue(forKey: token)
            }
            break
        }

        events.emit(.removeWish, wish)
    }

    public func isWish(_ wish: String) -> Bool {
        config.server.autoSearch.contains(wish)
    }

    /// Server code 104.
    private func setWishlistInterval(_ msg: WishlistInterval) {
        wishlistInterval = msg.seconds

        guard wishlistInterval > 0 else {
            return
        }

        log.addSearch(String(localized: "Wishlist wait period set to \(wishlistInterval) seconds", bundle: .module))

        events.cancelScheduled(wishlistTimerID)
        wishlistTimerID = events.schedule(delay: TimeInterval(wishlistInterval), repeat: true) { [self] in
            doWishlistSearchInterval()
        }
    }

    /// Server code 160.
    private func excludedSearchPhrases(_ msg: ExcludedSearchPhrases) {
        if !excludedPhrases.isEmpty && excludedPhrases != msg.phrases {
            log.addSearch("Previous list of excluded search phrases: \(excludedPhrases)")
        }

        excludedPhrases = msg.phrases
        log.addSearch("Server provided \(msg.phrases.count) excluded search phrase(s): \(msg.phrases)")
    }

    /// Peer code 9.
    private func fileSearchResponse(_ msg: FileSearchResponse) {
        guard SearchTokens.isAllowed(msg.token), let search = searches[msg.token], !search.isIgnored,
              let username = msg.username else {
            msg.isIgnored = true
            return
        }

        if core.networkFilter.isUserIgnored(username)
            || core.networkFilter.isUserIPIgnored(username: username, ipAddress: msg.addr?.ipAddress) {
            msg.isIgnored = true
        }
    }

    /// Server code 26.
    private func fileSearchRequestServer(_ msg: FileSearch) {
        processSearchRequest(msg.searchTerm, username: msg.searchUsername, token: msg.token)
        core.pluginHandler?.searchRequestNotification(msg.searchTerm, user: msg.searchUsername, token: msg.token)
    }

    /// Distrib code 3.
    private func fileSearchRequestDistributed(_ msg: DistribSearch) {
        processSearchRequest(msg.searchTerm, username: msg.searchUsername, token: msg.token)
        core.pluginHandler?.distribSearchNotification(msg.searchTerm, user: msg.searchUsername, token: msg.token)
    }

    // MARK: Incoming Search Requests

    private func appendFileInfo(_ fileList: inout [SharedFileInfo], _ fileInfo: SharedFileInfo) {
        let filePathLower = fileInfo.virtualPath.lowercased()

        // Check if file path contains phrase excluded from the search network
        if let excludedPhrase = excludedPhrases.first(where: { filePathLower.contains($0) }) {
            log.addSearch("Excluding file \(fileInfo.virtualPath) from search response because server "
                          + "disallowed phrase \"\(excludedPhrase)\"")
            return
        }

        fileList.append(fileInfo)
    }

    /// Given a list of file indices, retrieves the file information for each index.
    private func createFileInfoList(_ results: Set<Int>, maxResults: Int, permissionLevel: PermissionLevel)
        -> (count: Int, fileInfos: [SharedFileInfo], privateFileInfos: [SharedFileInfo]) {
        let revealBuddyShares = config.transfers.revealBuddyShares
        let revealTrustedShares = config.transfers.revealTrustedShares
        let isBuddy = permissionLevel == .buddy
        let isTrusted = permissionLevel == .trusted

        var fileInfos: [SharedFileInfo] = []
        var privateFileInfos: [SharedFileInfo] = []

        let shareDBs = core.shares.shareDBs
        let filePathIndex = core.shares.filePathIndex

        for index in results.prefix(Swift.min(results.count, maxResults)) {
            guard index < filePathIndex.count else {
                continue
            }

            let filePath = filePathIndex[index]

            if let publicFiles = shareDBs.files[.public], publicFiles.contains(filePath) {
                if let fileInfo = publicFiles[filePath] {
                    appendFileInfo(&fileInfos, fileInfo)
                }
                continue
            }

            if isBuddy || revealBuddyShares, let buddyFiles = shareDBs.files[.buddy], buddyFiles.contains(filePath) {
                if let fileInfo = buddyFiles[filePath] {
                    if isBuddy {
                        appendFileInfo(&fileInfos, fileInfo)
                    } else {
                        appendFileInfo(&privateFileInfos, fileInfo)
                    }
                }
                continue
            }

            if isTrusted || revealTrustedShares, let trustedFiles = shareDBs.files[.trusted],
               trustedFiles.contains(filePath), let fileInfo = trustedFiles[filePath] {
                if isTrusted {
                    appendFileInfo(&fileInfos, fileInfo)
                } else {
                    appendFileInfo(&privateFileInfos, fileInfo)
                }
            }
        }

        fileInfos.sort { $0.virtualPath < $1.virtualPath }
        privateFileInfos.sort { $0.virtualPath < $1.virtualPath }

        return (fileInfos.count + privateFileInfos.count, fileInfos, privateFileInfos)
    }

    /// Updates the search result list with indices for a new word.
    private static func updateSearchResults(_ results: Set<Int>?, _ wordIndices: [Int]?, excluded: Bool = false)
        -> Set<Int>? {
        guard let wordIndices, !wordIndices.isEmpty else {
            if excluded {
                // We don't care if an excluded word doesn't exist in our DB
                return results
            }

            // Included word does not exist in our DB, no results
            return []
        }

        guard var results else {
            if excluded {
                // No results yet, but word is excluded. Bail.
                return []
            }

            // First match for included word, return results
            return Set(wordIndices)
        }

        if excluded {
            // Remove results for excluded word
            results.subtract(wordIndices)
        } else {
            // Only retain common results for all words so far
            results.formIntersection(wordIndices)
        }

        return results
    }

    /// Returns a list of common file indices for each word in a search term.
    private func createSearchResultList(includedWords: Set<String>, excludedWords: Set<String>,
                                        partialWords: Set<String>, maxResults: Int,
                                        wordIndex: ShareDatabase<[Int]>) -> Set<Int>? {
        var results: Set<Int>?

        for word in includedWords where !wordIndex.contains(word) {
            // No results
            return results
        }

        var includedWords = includedWords
        let startWord = includedWords.first
        let hasSingleWord = (includedWords.count + excludedWords.count + partialWords.count) == 1

        if let startWord {
            includedWords.remove(startWord)
        }

        // Partial search words (e.g. *ello)
        for partialWord in partialWords {
            var partialResults = Set<Int>()
            var numPartialResults = 0

            for completeWord in wordIndex.keys {
                guard completeWord.count >= partialWord.count, completeWord.hasSuffix(partialWord),
                      var indices = wordIndex[completeWord] else {
                    continue
                }

                if hasSingleWord {
                    // Attempt to avoid large memory usage if someone searches for e.g. "*lac"
                    indices = Array(indices.prefix(Swift.max(0, maxResults - numPartialResults)))
                }

                partialResults.formUnion(indices)

                guard hasSingleWord else {
                    continue
                }

                numPartialResults = partialResults.count

                if numPartialResults >= maxResults {
                    break
                }
            }

            if partialResults.isEmpty {
                return nil
            }

            results = Self.updateSearchResults(results, Array(partialResults))
        }

        // Included search words (e.g. hello)
        if let startWord {
            var startResults = wordIndex[startWord] ?? []

            if hasSingleWord {
                // Attempt to avoid large memory usage if someone searches for e.g. "flac"
                startResults = Array(startResults.prefix(maxResults))
            }

            results = Self.updateSearchResults(results, startResults)

            for includedWord in includedWords {
                guard wordIndex.contains(includedWord) else {
                    return nil
                }

                results = Self.updateSearchResults(results, wordIndex[includedWord])
            }
        }

        // Excluded search words (e.g. -hello)
        if let currentResults = results, !currentResults.isEmpty {
            for excludedWord in excludedWords where wordIndex.contains(excludedWord) {
                results = Self.updateSearchResults(results, wordIndex[excludedWord], excluded: true)
            }
        }

        guard let results, !results.isEmpty else {
            return nil
        }

        return results
    }

    /// Accessed every time a search request arrives, several times per second.
    private func processSearchRequest(_ searchTerm: String, username: String, token: Int) {
        guard !searchTerm.isEmpty else {
            return
        }

        guard config.searches.searchResults else {
            // Don't return _any_ results when this option is disabled
            return
        }

        guard !core.uploads.pendingShutdown else {
            // Don't return results when waiting to quit after finishing uploads
            return
        }

        let localUsername = core.users.loginUsername

        if username == localUsername {
            guard ownTokens.contains(token) else {
                // We shouldn't send a search response if we initiated the search
                // request, unless we're specifically searching our own username
                return
            }

            ownTokens.remove(token)
        }

        let maxResults = config.searches.maxResults

        guard maxResults > 0 else {
            return
        }

        guard searchTerm.count >= config.searches.minSearchCharacters else {
            // Don't send search response if search term contains too few characters
            return
        }

        let (permissionLevel, _) = core.shares.checkUserPermission(username)

        guard permissionLevel != .banned, let wordIndex = core.shares.shareDBs.words else {
            return
        }

        let originalSearchTerm = searchTerm
        let lowercasedSearchTerm = searchTerm.lowercased()

        // Extract included/excluded/partial words from search term
        var excludedWords = Set<String>()
        var partialWords = Set<String>()

        if lowercasedSearchTerm.contains("-") || lowercasedSearchTerm.contains("*") {
            for word in lowercasedSearchTerm.split(whereSeparator: \.isWhitespace) {
                guard let firstCharacter = word.first else {
                    continue
                }

                let subwords = Self.removingPunctuation(String(word)).split(whereSeparator: \.isWhitespace)

                if firstCharacter == "-" {
                    excludedWords.formUnion(subwords.map(String.init))
                } else if firstCharacter == "*" {
                    partialWords.formUnion(subwords.map(String.init))
                }
            }
        }

        // Strip punctuation
        let strippedSearchTerm = Self.removingPunctuation(lowercasedSearchTerm)
        let includedWords = Set(strippedSearchTerm.split(whereSeparator: \.isWhitespace).map(String.init))
            .subtracting(excludedWords)
            .subtracting(partialWords)

        // Find common file matches for each word in search term
        guard let results = createSearchResultList(
            includedWords: includedWords, excludedWords: excludedWords, partialWords: partialWords,
            maxResults: maxResults, wordIndex: wordIndex
        ) else {
            return
        }

        // Get file information for each file index in result list
        let (numResults, fileInfos, privateFileInfos) = createFileInfoList(results, maxResults: maxResults,
                                                                           permissionLevel: permissionLevel)

        guard numResults > 0 else {
            return
        }

        core.sendMessageToPeer(username, FileSearchResponse(
            searchUsername: localUsername ?? "",
            token: token,
            shares: fileInfos,
            freeUploadSlots: core.uploads.isNewUploadAccepted(),
            uploadSpeed: core.uploads.uploadSpeed,
            inQueue: core.uploads.uploadQueueSize(username),
            privateShares: privateFileInfos
        ))

        log.addSearch(String(localized: "User \(username) is searching for \"\(originalSearchTerm)\", found \(numResults) results",
                             bundle: .module))
    }
}
