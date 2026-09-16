// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore
import Observation
import SwiftUI

/// Search files page, containing a tab for each search.
@MainActor
@Observable
final class SearchesPage: TabbedPage {

    static let modes: [(SearchMode, String)] = [
        (.global, String(localized: "Global")),
        (.buddies, String(localized: "Buddies")),
        (.rooms, String(localized: "Rooms")),
        (.user, String(localized: "User"))
    ]

    @ObservationIgnored let window: MainWindow
    let notebook: Notebook<SearchTab>
    @ObservationIgnored private(set) var pages: [Int: SearchTab] = [:]
    @ObservationIgnored var fileProperties: FileProperties?

    private(set) var searchMode = SearchMode.global
    var searchText = ""
    var roomSearchText = ""
    var userSearchText = ""
    /// Joined rooms, suggested in the room entry
    var roomSearchItems: [String] = []
    private(set) var searchHistory: [String] = []
    private(set) var isSearchEnabled = false
    private(set) var searchEntryFocusRequest = 0

    /// Unread search tabs, and whether they contain important (wishlist) results
    var unreadPages: [ObjectIdentifier: Bool] { notebook.unreadPages }

    init(window: MainWindow) {
        self.window = window
        self.notebook = Notebook(window: window, parentPage: .search)

        notebook.switchPageCallback = { [unowned self] _ in onSwitchSearchPage() }
        notebook.removeAllPagesCallback = { core.search.removeAllSearches() }

        events.connect(.addSearch) { [unowned self] in addSearch($0) }
        events.connect(.addWish) { [unowned self] in updateWishButton($0) }
        events.connect(.fileSearchResponse) { [unowned self] in fileSearchResponse($0) }
        events.connect(.removeSearch) { [unowned self] in removeSearch($0) }
        events.connect(.removeWish) { [unowned self] in updateWishButton($0) }
        events.connect(.serverDisconnect) { [unowned self] _ in serverDisconnect() }
        events.connect(.serverLogin) { [unowned self] _ in serverLogin() }
        events.connect(.showSearch) { [unowned self] in showSearch($0) }

        populateSearchHistory()
    }

    func onFocus() {
        guard window.currentPage == .search else {
            return
        }

        if isSearchEnabled {
            focusSearchEntry()
        }
    }

    func focusSearchEntry() {
        searchEntryFocusRequest += 1
    }

    private func onSwitchSearchPage() {
        if window.currentPage == .search {
            window.updateTitle()
        }
    }

    func setSearchMode(_ mode: SearchMode) {
        searchMode = mode
    }

    var searchModeLabel: String {
        Self.modes.first { $0.0 == searchMode }?.1 ?? ""
    }

    func onSearch() {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            return
        }

        let room = roomSearchText
        let user = userSearchText
        let users = user.isEmpty ? [] : [user]

        searchText = ""
        core.search.doSearch(text, mode: searchMode, room: room, users: users)
    }

    // MARK: Search History

    func populateSearchHistory() {
        if !config.searches.enableHistory {
            searchHistory.removeAll()
            return
        }

        searchHistory = Array(config.searches.history.prefix(Search.searchHistoryLimit))
    }

    private func addSearchHistoryItem(_ term: String) {
        guard config.searches.enableHistory else {
            return
        }

        searchHistory.removeAll { $0 == term }
        searchHistory.insert(term, at: 0)

        if searchHistory.count > Search.searchHistoryLimit {
            searchHistory.removeLast(searchHistory.count - Search.searchHistoryLimit)
        }
    }

    func clearSearchHistory() {
        searchText = ""
        config.searches.history = []
        config.writeConfiguration()
        searchHistory.removeAll()
    }

    func addFilterHistoryItem(_ filterID: SearchTab.FilterID, value: String) {
        for page in pages.values {
            page.addFilterHistoryItem(filterID, value: value)
        }
    }

    func clearFilterHistory() {
        // Clear filter history in config
        for filterID in SearchTab.FilterID.allCases {
            filterID.history = []
        }
        config.writeConfiguration()

        // Update filters in search tabs
        for page in pages.values {
            page.filtersUndo = SearchTab.emptyFilters
            page.populateFilterHistory()
        }
    }

    // MARK: Pages

    @discardableResult
    func createPage(token: Int, text: String, mode: SearchMode? = nil, modeLabel: String? = nil, room: String? = nil,
                    users: [String]? = nil, showPage: Bool = true) -> SearchTab {
        var modeLabel = modeLabel
        let page: SearchTab

        if let existingPage = pages[token] {
            page = existingPage
            modeLabel = page.modeLabel
        } else {
            page = SearchTab(searches: self, text: text, token: token, mode: mode ?? .global, modeLabel: modeLabel,
                             room: room, users: users, showPage: showPage)
            pages[token] = page
        }

        guard showPage else {
            return page
        }

        var tabText = text

        if let modeLabel {
            tabText = "(\(modeLabel)) \(text)"
        }

        notebook.appendPage(page, text: tabText) { [weak page] in page?.onClose() }
        return page
    }

    private func addSearch(_ event: SearchAdded) {
        let search = event.search
        let mode = search.mode
        var modeLabel: String?

        switch mode {
        case .rooms:
            modeLabel = search.room?.trimmingCharacters(in: .whitespaces)
        case .user:
            modeLabel = (search.users ?? []).joined(separator: ",")
        case .buddies:
            modeLabel = String(localized: "Buddies")
        default:
            break
        }

        createPage(token: event.token, text: search.termSanitized, mode: mode, modeLabel: modeLabel, room: search.room,
                   users: search.users)

        if event.switchPage {
            showSearch(event.token)
        }

        addSearchHistoryItem(search.termSanitized)
    }

    private func showSearch(_ token: Int) {
        guard let page = pages[token] else {
            return
        }

        notebook.setCurrentPage(page)
        window.changeMainPage(.search)
    }

    private func removeSearch(_ token: Int) {
        guard let page = pages[token] else {
            return
        }

        page.clear()

        if page.showPage {
            var mode = page.mode

            if mode == .wishlist {
                // For simplicity's sake, turn wishlist tabs into regular ones when restored
                mode = .global
            }

            let text = page.text
            let room = page.room
            let searchedUsers = page.searchedUsers

            notebook.removePage(page) {
                core.search.doSearch(text, mode: mode, room: room, users: searchedUsers)
            }
        }

        pages.removeValue(forKey: token)
        window.updateTitle()
    }

    private func fileSearchResponse(_ msg: FileSearchResponse) {
        guard !msg.isIgnored else {
            return
        }

        var page = pages[msg.token]

        if page == nil {
            guard let searchItem = core.search.searches[msg.token] else {
                return
            }

            page = createPage(token: msg.token, text: searchItem.term, mode: .wishlist,
                              modeLabel: String(localized: "Wish"), showPage: false)
        }

        guard let page else {
            return
        }

        // No more things to add because we've reached the result limit
        if page.numResultsFound >= page.maxLimit {
            Search.removeAllowedToken(msg.token)
            page.isMaxLimited = true
            page.updateResultCounter()
            return
        }

        page.fileSearchResponse(msg)
    }

    private func updateWishButton(_ wish: String) {
        for page in pages.values where page.text == wish {
            page.updateWishButton()
        }
    }

    private func serverLogin() {
        isSearchEnabled = true
        onFocus()
    }

    private func serverDisconnect() {
        isSearchEnabled = false
    }
}

// MARK: - Search Tab

/// File of a search result
final class ResultFile {
    let path: String
    let attributes: [Int: Int]?

    init(path: String, attributes: [Int: Int]? = nil) {
        self.path = path
        self.attributes = attributes
    }
}

/// A search result, before it is added to the list view.
private struct SearchResult {
    var user: String
    var flag: String
    var humanSpeed: String
    var humanQueue: String
    var folderPath: String
    var fileTypeIcon: String
    var name: String
    var humanSize: String
    var humanQuality: String
    var humanLength: String
    var speed: Int
    var queue: Int
    var size: Int
    var bitrate: Int
    var length: Int
    var hasFreeSlots: Bool
    var file: ResultFile

    func values(rowID: Int, folderPath: String? = nil) -> [TreeValue] {
        [
            .string(user), .string(flag), .string(humanSpeed), .string(humanQueue),
            .string(folderPath ?? self.folderPath), .string(fileTypeIcon), .string(name), .string(humanSize),
            .string(humanQuality), .string(humanLength), .int(speed), .int(queue), .int(size), .int(bitrate),
            .int(length), .bool(hasFreeSlots), .object(file), .int(rowID)
        ]
    }
}

/// A single search, with its results and result filters.
@MainActor
@Observable
final class SearchTab: NotebookPage {

    enum FilterID: String, CaseIterable {
        case include = "filterin"
        case exclude = "filterout"
        case size = "filtersize"
        case bitrate = "filterbr"
        case freeSlot = "filterslot"
        case country = "filtercc"
        case fileType = "filtertype"
        case length = "filterlength"

        /// Filter history in the config, nil for filters without history
        @MainActor var history: [String]? {
            get {
                switch self {
                case .include: config.searches.filterIncludeHistory
                case .exclude: config.searches.filterExcludeHistory
                case .size: config.searches.filterSizeHistory
                case .bitrate: config.searches.filterBitrateHistory
                case .freeSlot: nil
                case .country: config.searches.filterCountryHistory
                case .fileType: config.searches.filterTypeHistory
                case .length: config.searches.filterLengthHistory
                }
            }
            nonmutating set {
                let newValue = newValue ?? []

                switch self {
                case .include: config.searches.filterIncludeHistory = newValue
                case .exclude: config.searches.filterExcludeHistory = newValue
                case .size: config.searches.filterSizeHistory = newValue
                case .bitrate: config.searches.filterBitrateHistory = newValue
                case .freeSlot: break
                case .country: config.searches.filterCountryHistory = newValue
                case .fileType: config.searches.filterTypeHistory = newValue
                case .length: config.searches.filterLengthHistory = newValue
                }
            }
        }
    }

    /// Filter values as entered by the user
    struct FilterValues: Equatable {
        var include = ""
        var exclude = ""
        var size = ""
        var bitrate = ""
        var freeSlot = false
        var country = ""
        var fileType = ""
        var length = ""

        func text(_ filterID: FilterID) -> String {
            switch filterID {
            case .include: include
            case .exclude: exclude
            case .size: size
            case .bitrate: bitrate
            case .freeSlot: freeSlot ? "1" : ""
            case .country: country
            case .fileType: fileType
            case .length: length
            }
        }
    }

    /// Parsed filters, used when checking results
    private struct Filters {
        var include: NSRegularExpression?
        var exclude: NSRegularExpression?
        var size: [String]?
        var bitrate: [String]?
        var freeSlot = false
        var country: [String]?
        var fileType: [String]?
        var length: [String]?
    }

    static let emptyFilters = FilterValues()

    private static let filterGenericFileTypes: [(String, Set<String>)] = [
        ("audio", FileTypes.audio),
        ("executable", FileTypes.executable),
        ("image", FileTypes.image),
        ("video", FileTypes.video),
        ("document", FileTypes.document),
        ("text", FileTypes.text),
        ("archive", FileTypes.archive)
    ]

    static let filterPresets: [FilterID: [String]] = [
        .bitrate: ["!0", "128 <=192", ">192 <320", "=320", ">320"],
        .size: [">50MiB", ">20MiB <=50MiB", ">10MiB <=20MiB", ">5MiB <=10MiB", "<=5MiB"],
        .fileType: ["audio", "image", "video", "document", "text", "archive", "!executable", "audio image text"],
        .length: [">15:00", ">8:00 <=15:00", ">5:00 <=8:00", ">2:00 <=5:00", "<=2:00"]
    ]

    // [pipe, ampersand, space]
    private static let filterSplitDigitPattern = try! NSRegularExpression(  // swiftlint:disable:this force_try
        pattern: "(?:[|&\\s])+(?<![<>!=]\\s)")
    // [pipe, ampersand, comma, semicolon, space]
    private static let filterSplitTextPattern = try! NSRegularExpression(  // swiftlint:disable:this force_try
        pattern: "(?:[|&,;\\s])+(?<!!\\s)")

    @ObservationIgnored unowned let searches: SearchesPage
    @ObservationIgnored let window: MainWindow
    let text: String
    let token: Int
    let mode: SearchMode
    let modeLabel: String?
    let room: String?
    let searchedUsers: [String]?
    @ObservationIgnored var showPage: Bool

    @ObservationIgnored private var isInitialized = false
    @ObservationIgnored private var users: [String: (row: TreeRow?, children: [TreeRow])] = [:]
    @ObservationIgnored private var folders: [String: (row: TreeRow?, children: [TreeRow])] = [:]
    @ObservationIgnored private var allData: [SearchResult] = []
    @ObservationIgnored private var rowID = 0
    @ObservationIgnored private var filters: Filters?
    @ObservationIgnored private var appliedFilterValues: FilterValues?
    @ObservationIgnored var filtersUndo = SearchTab.emptyFilters
    @ObservationIgnored private var isPopulatingFilters = false
    @ObservationIgnored private var isRefiltering = false
    @ObservationIgnored var numResultsFound = 0
    @ObservationIgnored private var numResultsVisible = 0
    @ObservationIgnored var maxLimit = config.searches.maxDisplayedResults
    @ObservationIgnored var isMaxLimited = false

    // Selected users and results, in the order they were selected
    @ObservationIgnored private var selectedUsers = OrderedSet<String>()
    @ObservationIgnored private var selectedResults = OrderedDictionary<Int, TreeRow>()

    @ObservationIgnored private(set) var treeView: TreeView!
    @ObservationIgnored private var popupMenu: FilePopupMenu!
    @ObservationIgnored private var popupMenuUsers: UserPopupMenu!
    @ObservationIgnored private var popupMenuCopy: PopupMenu!

    // Widget state
    private(set) var groupingMode = GroupingMode.folderGrouping
    var isExpanded: Bool {
        didSet {
            onToggleExpandAll()
        }
    }
    var isFiltersVisible: Bool {
        didSet {
            onToggleFilters()
        }
    }
    var filterValues = FilterValues()
    private(set) var filterHistory: [FilterID: [String]] = [:]
    private(set) var activeFilterCount = 0
    private(set) var hasUndoFilters = false
    private(set) var invalidFilters = Set<FilterID>()
    private(set) var filterFocusRequest = 0
    private(set) var resultsText = "0"
    private(set) var resultsTooltip = String(localized: "Results")
    private(set) var isWishButtonVisible = true
    private(set) var isWish = false

    init(searches: SearchesPage, text: String, token: Int, mode: SearchMode, modeLabel: String?, room: String?,
         users: [String]?, showPage: Bool) {

        self.searches = searches
        self.window = searches.window
        self.text = text
        self.token = token
        self.mode = mode
        self.modeLabel = modeLabel
        self.room = room
        self.searchedUsers = users
        self.showPage = showPage
        self.isExpanded = config.searches.expandSearches
        self.isFiltersVisible = config.searches.filtersVisible

        treeView = TreeView(
            columns: [
                // Visible columns
                TreeColumn(id: "user", title: String(localized: "User"), width: 200, sensitiveColumn: "free_slot_data"),
                TreeColumn(id: "country", title: String(localized: "Country"), kind: .icon, width: 30,
                           hidesHeader: true),
                TreeColumn(id: "speed", title: String(localized: "Speed"), kind: .number, width: 120,
                           sortColumn: "speed_data", sensitiveColumn: "free_slot_data"),
                TreeColumn(id: "in_queue", title: String(localized: "In Queue"), kind: .number, width: 110,
                           sortColumn: "in_queue_data", sensitiveColumn: "free_slot_data"),
                TreeColumn(id: "folder", title: String(localized: "Folder"), width: 200, expandsColumn: true,
                           sensitiveColumn: "free_slot_data",
                           tooltipCallback: { [unowned self] in onFilePathTooltip($0, $1) }),
                TreeColumn(id: "file_type", title: String(localized: "File Type"), kind: .icon, width: 40,
                           hidesHeader: true, sensitiveColumn: "free_slot_data"),
                TreeColumn(id: "filename", title: String(localized: "Filename"), width: 200, expandsColumn: true,
                           sensitiveColumn: "free_slot_data",
                           tooltipCallback: { [unowned self] in onFilePathTooltip($0, $1) }),
                TreeColumn(id: "size", title: String(localized: "Size"), kind: .number, width: 180,
                           sortColumn: "size_data", sensitiveColumn: "free_slot_data"),
                TreeColumn(id: "quality", title: String(localized: "Quality"), kind: .number, width: 150,
                           sortColumn: "bitrate_data", sensitiveColumn: "free_slot_data"),
                TreeColumn(id: "length", title: String(localized: "Duration"), kind: .number, width: 100,
                           sortColumn: "length_data", sensitiveColumn: "free_slot_data"),

                // Hidden data columns
                .data("speed_data"),
                .data("in_queue_data"),
                .data("size_data"),
                .data("bitrate_data"),
                .data("length_data"),
                .data("free_slot_data"),
                .data("file_data"),
                .data("id_data", isIteratorKey: true, sortOrder: .ascending)
            ],
            hasTree: true, multiSelect: true, persistentSort: true, name: "file_search",
            activateRow: { [unowned self] treeView, row, _ in onRowActivated(treeView, row) },
            focusIn: { [unowned self] _ in onRefilter() }
        )

        // Popup menus
        popupMenuUsers = UserPopupMenu()
        popupMenuCopy = PopupMenu()
        popupMenuCopy.addItems(
            .action(String(localized: "Copy File Path")) { [unowned self] in onCopyFilePath() },
            .action(String(localized: "Copy URL")) { [unowned self] in onCopyURL() },
            .action(String(localized: "Copy Folder URL")) { [unowned self] in onCopyFolderURL() }
        )

        popupMenu = FilePopupMenu { [unowned self] menu in onPopupMenu(menu) }
        popupMenu.addItems(
            .action(String(localized: "Download File(s)")) { [unowned self] in onDownloadFiles() },
            .action(String(localized: "Download File(s) To…")) { [unowned self] in onDownloadFilesTo() },
            .separator,
            .action(String(localized: "Download Folder(s)")) { [unowned self] in onDownloadFolders() },
            .action(String(localized: "Download Folder(s) To…")) { [unowned self] in onDownloadFoldersTo() },
            .separator,
            .action(String(localized: "View User Profile")) { [unowned self] in onUserProfile() },
            .action(String(localized: "Browse Folder")) { [unowned self] in onBrowseFolder() },
            .action(String(localized: "File Properties")) { [unowned self] in onFileProperties() },
            .separator,
            .submenu(String(localized: "Copy"), popupMenuCopy),
            .submenu(String(localized: "User Actions"), popupMenuUsers)
        )
        treeView.popupMenu = popupMenu

        // Key bindings
        treeView.accelerators += [
            Accelerator(.character("f"), modifiers: .command) { [unowned self] in onShowFilterBarAccelerator() },
            Accelerator(.return, modifiers: .option) { [unowned self] in onFilePropertiesAccelerator() }
        ]

        populateFilterHistory()
        populateDefaultFilters()

        onGroup(config.searches.groupSearches)

        // Wishlist
        updateWishButton()
    }

    var tabMenuItems: [TabMenuItem] {
        [
            TabMenuItem(String(localized: "Edit…")) { [unowned self] in onEditSearch() },
            TabMenuItem(String(localized: "Copy Search Term")) { [unowned self] in Clipboard.copyText(text) },
            .separator,
            TabMenuItem(String(localized: "Clear All Results")) { [unowned self] in onClear() },
            TabMenuItem(String(localized: "Close All Tabs…")) { [unowned self] in searches.notebook.removeAllPages() },
            TabMenuItem(String(localized: "Close Tab")) { [unowned self] in onClose() }
        ]
    }

    var content: some View {
        SearchTabView(tab: self)
    }

    func clear() {
        clearModel(storedResults: true)
    }

    // MARK: Filters

    private func updateFilterWidgets() {
        hasUndoFilters = (filtersUndo != Self.emptyFilters)
    }

    var filtersLabel: String {
        activeFilterCount > 0
            ? String(localized: "Result Filters [\(activeFilterCount)]")
            : String(localized: "Result Filters")
    }

    func populateFilterHistory() {
        for filterID in FilterID.allCases where filterID != .freeSlot {
            var items = Self.filterPresets[filterID] ?? []
            let history = filterID.history ?? []

            if !items.isEmpty && !history.isEmpty {
                items.append("")  // Separator
            }

            items += history.prefix(Search.resultFilterHistoryLimit)
            filterHistory[filterID] = items
        }
    }

    private func populateDefaultFilters() {
        guard config.searches.enableFilters else {
            return
        }

        let defaultFilters = config.searches.defaultFilters
        var storedFilters = Self.emptyFilters

        storedFilters.include = defaultFilters.include
        storedFilters.exclude = defaultFilters.exclude
        storedFilters.size = defaultFilters.size
        storedFilters.bitrate = defaultFilters.bitrate
        storedFilters.freeSlot = defaultFilters.freeSlot
        storedFilters.country = defaultFilters.country
        storedFilters.fileType = defaultFilters.fileType
        storedFilters.length = defaultFilters.length

        setFilters(storedFilters)
    }

    /// Recall result filter values.
    private func setFilters(_ storedFilters: FilterValues) {
        isPopulatingFilters = true
        filterValues = storedFilters
        isPopulatingFilters = false
        onRefilter()
    }

    // MARK: Results

    private func addResultList(_ resultList: [FileListEntry], user: String, countryCode: String?, inQueue: Int,
                               uploadSpeed: Int, humanSpeed: String, humanQueue: String, hasFreeSlots: Bool,
                               isPrivate: Bool = false) -> Bool {
        var shouldUpdateUI = false

        guard let search = core.search.searches[token] else {
            return false
        }

        for entry in resultList {
            if numResultsFound >= maxLimit {
                isMaxLimited = true
                break
            }

            let filePath = entry.name
            let filePathLower = filePath.lowercased()

            if search.excludedWords.contains(where: { filePathLower.contains($0) }) {
                // Filter out results with filtered words (e.g. nicotine -music)
                log.addDebug("Filtered out excluded search result \(filePath) from user \(user) for search term \"\(text)\"")
                continue
            }

            if !search.includedWords.allSatisfy({ filePathLower.contains($0) }) {
                // Certain users may send us wrong results, filter out such ones
                continue
            }

            numResultsFound += 1

            var filePathSplit = filePath.components(separatedBy: "\\")
            var name: String

            if config.ui.reverseFilePaths {
                // Reverse file path, file name is the first item
                filePathSplit.reverse()
                name = filePathSplit.removeFirst()
            } else {
                // Regular file path, file name is the last item
                name = filePathSplit.removeLast()
            }

            // Join the resulting items into a folder path
            let folderPath = filePathSplit.joined(separator: "\\")
            let size = entry.size
            let fileSizeUnit = FileSizeUnit(rawValue: config.ui.fileSizeUnit) ?? .automatic
            let quality = FileListMessage.parseAudioQualityLength(fileSize: size, attributes: entry.attributes)

            if isPrivate {
                name = String(localized: "[PRIVATE]  \(name)")
            }

            let isResultVisible = append(SearchResult(
                user: user,
                flag: Theme.flagIconName(countryCode),
                humanSpeed: humanSpeed,
                humanQueue: humanQueue,
                folderPath: folderPath,
                fileTypeIcon: Theme.fileTypeIconName(name),
                name: name,
                humanSize: HumidorCore.humanSize(size, unit: fileSizeUnit),
                humanQuality: quality.humanQuality,
                humanLength: quality.humanLength,
                speed: uploadSpeed,
                queue: inQueue,
                size: size,
                bitrate: quality.bitrate,
                length: quality.length,
                hasFreeSlots: hasFreeSlots,
                file: ResultFile(path: filePath, attributes: entry.attributes)
            ))

            if isResultVisible {
                shouldUpdateUI = true
            }
        }

        return shouldUpdateUI
    }

    func fileSearchResponse(_ msg: FileSearchResponse) {
        guard let user = msg.username, users[user] == nil else {
            return
        }

        isInitialized = true

        let ipAddress = msg.addr?.ipAddress ?? ""
        var countryCode: String? = core.networkFilter.countryCode(ipAddress: ipAddress)

        if countryCode?.isEmpty ?? true {
            countryCode = core.users.countries[user]
        }

        let hasFreeSlots = msg.freeUploadSlots
        let inQueue: Int
        let humanQueue: String

        if hasFreeSlots {
            inQueue = 0
            humanQueue = ""
        } else {
            inQueue = msg.inQueue > 0 ? msg.inQueue : 1  // Ensure value is always >= 1
            humanQueue = humanize(inQueue)
        }

        let uploadSpeed = msg.uploadSpeed
        let humanSpeedText = uploadSpeed > 0 ? humanSpeed(uploadSpeed) : ""

        var shouldUpdateUI = addResultList(msg.list, user: user, countryCode: countryCode, inQueue: inQueue,
                                           uploadSpeed: uploadSpeed, humanSpeed: humanSpeedText,
                                           humanQueue: humanQueue, hasFreeSlots: hasFreeSlots)

        if !msg.privateList.isEmpty && config.searches.privateSearchResults {
            let shouldUpdatePrivateUI = addResultList(
                msg.privateList, user: user, countryCode: countryCode, inQueue: inQueue, uploadSpeed: uploadSpeed,
                humanSpeed: humanSpeedText, humanQueue: humanQueue, hasFreeSlots: hasFreeSlots, isPrivate: true
            )

            if !shouldUpdateUI && shouldUpdatePrivateUI {
                shouldUpdateUI = true
            }
        }

        if shouldUpdateUI {
            // If this search wasn't initiated by us (e.g. wishlist), and the results aren't spoofed, show tab
            let isWishResult = (mode == .wishlist)

            if !showPage {
                searches.createPage(token: token, text: text)
                showPage = true
            }

            let isTabChanged = searches.notebook.requestTabChanged(self, isImportant: isWishResult)

            if isTabChanged && isWishResult {
                window.updateTitle()

                if config.notifications.popupWish {
                    core.notifications?.showSearchNotification(searchToken: token, message: text,
                                                               title: String(localized: "Wishlist Results Found"))
                }
            }
        }

        // Update number of results, even if they are all filtered
        updateResultCounter()
    }

    private func append(_ result: SearchResult) -> Bool {
        allData.append(result)

        guard checkFilter(result) else {
            return false
        }

        addRowToModel(result)
        return true
    }

    @discardableResult
    private func addRowToModel(_ result: SearchResult) -> TreeRow? {
        let user = result.user
        let isExpandAllowed = isInitialized
        var shouldExpandUser = false
        var shouldExpandFolder = false
        var parentRow: TreeRow?
        var userRow: TreeRow?
        var userFolderRow: TreeRow?
        var userFolderPath: String?
        var folderPath: String?

        if groupingMode != .ungrouped {
            // Group by folder or user
            if users[user] == nil {
                let row = treeView.addRow([
                    .string(user), .string(result.flag), .string(result.humanSpeed), .string(result.humanQueue),
                    "", "", "", "", "", "", .int(result.speed), .int(result.queue), 0, 0, 0,
                    .bool(result.hasFreeSlots), .object(ResultFile(path: "")), .int(rowID)
                ], selectRow: false)

                if isExpandAllowed {
                    shouldExpandUser = (groupingMode == .folderGrouping) || isExpanded
                }

                rowID += 1
                users[user] = (row, [])
            }

            userRow = users[user]?.row

            if groupingMode == .folderGrouping {
                // Group by folder
                let path = user + result.folderPath
                userFolderPath = path

                if folders[path] == nil {
                    let folderFilePath = result.file.path.components(separatedBy: "\\").dropLast()
                        .joined(separator: "\\")
                    let row = treeView.addRow([
                        .string(user), .string(result.flag), .string(result.humanSpeed), .string(result.humanQueue),
                        .string(result.folderPath), "", "", "", "", "", .int(result.speed), .int(result.queue),
                        0, 0, 0, .bool(result.hasFreeSlots), .object(ResultFile(path: folderFilePath)), .int(rowID)
                    ], selectRow: false, parent: userRow)

                    if let row {
                        users[user]?.children.append(row)
                    }

                    shouldExpandFolder = isExpandAllowed && isExpanded
                    rowID += 1
                    folders[path] = (row, [])
                }

                // Folder not visible for file row if "group by folder" is enabled
                folderPath = ""
                userFolderRow = folders[path]?.row
                parentRow = userFolderRow
            } else {
                parentRow = userRow
            }
        } else if users[user] == nil {
            users[user] = (nil, [])
        }

        let row = treeView.addRow(result.values(rowID: rowID, folderPath: folderPath), selectRow: false,
                                  parent: parentRow)
        rowID += 1

        if let row {
            if let userFolderPath {
                folders[userFolderPath]?.children.append(row)
            } else {
                users[user]?.children.append(row)
            }
        }

        if shouldExpandUser, let userRow {
            treeView.expandRow(userRow)
        }

        if shouldExpandFolder, let userFolderRow {
            treeView.expandRow(userFolderRow)
        }

        numResultsVisible += 1
        return row
    }

    // MARK: Result Filters

    func addFilterHistoryItem(_ filterID: FilterID, value: String) {
        var items = filterHistory[filterID] ?? []
        var position = Self.filterPresets[filterID]?.count ?? 0

        if position > 0 {
            // Separator item
            if position == items.count {
                items.append("")
            }
            position += 1
        }

        let numItemsLimit = Search.resultFilterHistoryLimit + position

        if let index = items.indices.first(where: { $0 >= position && items[$0] == value }) {
            items.remove(at: index)
        }
        items.insert(value, at: min(position, items.count))

        if items.count > numItemsLimit {
            items.removeLast(items.count - numItemsLimit)
        }

        filterHistory[filterID] = items
    }

    private func pushHistory(_ filterID: FilterID, value: String) {
        guard !value.isEmpty, var history = filterID.history else {
            // Button filters do not store history
            return
        }

        if history.first == value {
            // Most recent item selected, nothing to do
            return
        }

        if let index = history.firstIndex(of: value) {
            history.remove(at: index)
        } else if history.count >= Search.resultFilterHistoryLimit {
            history.removeLast()
        }

        history.insert(value, at: 0)
        filterID.history = history
        config.writeConfiguration()

        searches.addFilterHistoryItem(filterID, value: value)
    }

    private enum Operation {
        case lessThan
        case lessThanOrEqual
        case equal
        case notEqual
        case greaterThanOrEqual
        case greaterThan

        func evaluate(_ lhs: Int, _ rhs: Int) -> Bool {
            switch self {
            case .lessThan: lhs < rhs
            case .lessThanOrEqual: lhs <= rhs
            case .equal: lhs == rhs
            case .notEqual: lhs != rhs
            case .greaterThanOrEqual: lhs >= rhs
            case .greaterThan: lhs > rhs
            }
        }
    }

    private static func splitOperator(_ condition: String) -> (Operation, String) {
        let operators: [String: Operation] = [
            "<": .lessThan,
            "<=": .lessThanOrEqual,
            "==": .equal,
            "!=": .notEqual,
            ">=": .greaterThanOrEqual,
            ">": .greaterThan
        ]

        for prefix in [">=", "<=", "==", "!="] where condition.hasPrefix(prefix) {
            return (operators[prefix]!, String(condition.dropFirst(2)))
        }

        for prefix in [">", "<"] where condition.hasPrefix(prefix) {
            return (operators[prefix]!, String(condition.dropFirst()))
        }

        for prefix in ["=", "!"] where condition.hasPrefix(prefix) {
            return (operators[prefix + "="]!, String(condition.dropFirst()))
        }

        return (.greaterThanOrEqual, condition)
    }

    /// Checks if any conditions in the filter match the value.
    private static func checkDigit(_ resultFilter: [String], value: Int, isFileSize: Bool = false) -> Bool {
        var isAllowed = false
        var isBlocked = false

        for condition in resultFilter {
            let (operation, digitString) = splitOperator(condition)
            let digit: Int
            let adjust: Int

            if isFileSize {
                let (size, factor) = factorize(digitString)

                guard let size, let factor else {
                    // Invalid Size unit
                    continue
                }

                digit = size

                // Exact match unlikely, approximate to within +/- 0.1 MiB (or 1 MiB if over 100 MiB)
                adjust = (factor > 1024 && digit < 104_857_600) ? factor / 8 : factor
            } else {
                adjust = 0

                if let number = Int(digitString) {
                    // Bitrate in Kb/s or Duration in seconds
                    digit = number
                } else {
                    guard digitString.contains(":") else {
                        // Invalid syntax
                        continue
                    }

                    // Duration: Convert string from HH:MM:SS or MM:SS into Seconds as integer
                    var seconds = 0
                    var isValid = true

                    for (multiplier, part) in zip([1, 60, 3600], digitString.components(separatedBy: ":").reversed()) {
                        guard let number = Int(part) else {
                            isValid = false
                            break
                        }
                        seconds += multiplier * number
                    }

                    guard isValid else {
                        // Invalid Duration unit
                        continue
                    }

                    digit = seconds
                }
            }

            if (digit - adjust) <= value && value <= (digit + adjust) {
                if operation == .equal {
                    return true
                }

                if operation == .notEqual {
                    return false
                }
            }

            if value != 0 && operation.evaluate(value, digit) && !isBlocked {
                isAllowed = true
                continue
            }

            isBlocked = true
        }

        return isBlocked ? false : isAllowed
    }

    private static func checkCountry(_ resultFilter: [String], value: String) -> Bool {
        var isAllowed = false

        for countryCode in resultFilter {
            if countryCode == value {
                isAllowed = true
            } else if countryCode.hasPrefix("!") && String(countryCode.dropFirst()) != value {
                isAllowed = true
            } else if countryCode.hasPrefix("!") && String(countryCode.dropFirst()) == value {
                return false
            }
        }

        return isAllowed
    }

    private static func checkFileType(_ resultFilter: [String], value: String) -> Bool {
        var isAllowed = false
        var hasFoundInclusive = false

        for ext in resultFilter {
            if ext.hasPrefix("!") {
                var excludedExtension = String(ext.dropFirst())

                if !excludedExtension.hasPrefix(".") {
                    excludedExtension = "." + excludedExtension
                }

                if value.hasSuffix(excludedExtension) {
                    return false
                }
                continue
            }

            let ext = ext.hasPrefix(".") ? ext : "." + ext
            hasFoundInclusive = true

            if value.hasSuffix(ext) {
                isAllowed = true
            }
        }

        if !hasFoundInclusive {
            isAllowed = true
        }

        return isAllowed
    }

    private static func regexSearch(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func regexFullMatch(_ regex: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: .anchored, range: range)?.range == range
    }

    private func checkFilter(_ result: SearchResult) -> Bool {
        guard activeFilterCount > 0, let filters else {
            return true
        }

        if let fileType = filters.fileType, !fileType.isEmpty,
           !Self.checkFileType(fileType, value: result.file.path.lowercased()) {
            return false
        }

        if let country = filters.country, !country.isEmpty,
           !Self.checkCountry(country, value: String(result.flag.suffix(2)).uppercased()) {
            return false
        }

        if let include = filters.include, !Self.regexSearch(include, result.file.path),
           !Self.regexFullMatch(include, result.user) {
            return false
        }

        if let exclude = filters.exclude,
           Self.regexSearch(exclude, result.file.path) || Self.regexFullMatch(exclude, result.user) {
            return false
        }

        if filters.freeSlot && result.queue > 0 {
            return false
        }

        if let size = filters.size, !size.isEmpty, !Self.checkDigit(size, value: result.size, isFileSize: true) {
            return false
        }

        if let bitrate = filters.bitrate, !bitrate.isEmpty, !Self.checkDigit(bitrate, value: result.bitrate) {
            return false
        }

        if let length = filters.length, !length.isEmpty, !Self.checkDigit(length, value: result.length) {
            return false
        }

        return true
    }

    func clearModel(storedResults: Bool = false) {
        isInitialized = false

        if storedResults {
            allData.removeAll()
            numResultsFound = 0
            isMaxLimited = false
            maxLimit = config.searches.maxDisplayedResults
        }

        users.removeAll()
        folders.removeAll()
        treeView.clear()
        rowID = 0
        numResultsVisible = 0
    }

    private func updateModel() {
        treeView.freeze()

        for result in allData where checkFilter(result) {
            addRowToModel(result)
        }

        // Update number of results
        updateResultCounter()
        treeView.unfreeze()

        if groupingMode != .ungrouped {
            // Group by folder or user
            if isExpanded {
                treeView.expandAllRows()
            } else {
                treeView.collapseAllRows()

                if groupingMode == .folderGrouping {
                    treeView.expandRootRows()
                }
            }
        }

        isInitialized = true
    }

    func updateWishButton() {
        guard mode == .global || mode == .wishlist else {
            isWishButtonVisible = false
            return
        }

        isWish = core.search.isWish(text)
    }

    func onAddWish() {
        if core.search.isWish(text) {
            core.search.removeWish(text)
        } else {
            core.search.addWish(text)
        }
    }

    // MARK: Selection

    private func addPopupMenuUser(_ popup: UserPopupMenu, user: String) {
        popup.addItems(
            .separator,
            .action(String(localized: "Select User's Results")) { [unowned self] in onSelectUserResults(user) }
        )
        popup.toggleUserItems()
    }

    private func populatePopupMenuUsers() {
        popupMenuUsers.clear()

        guard !selectedUsers.isEmpty else {
            return
        }

        // Multiple users, create submenus for some of them
        if selectedUsers.count > 1 {
            for user in selectedUsers.prefix(20) {
                let popup = UserPopupMenu(username: user)
                addPopupMenuUser(popup, user: user)
                popupMenuUsers.addItems(.submenu(user, popup))
            }
            return
        }

        // Single user, add items directly to "User Actions" submenu
        let user = selectedUsers.first { _ in true }!
        popupMenuUsers.setupUserMenu(user)
        addPopupMenuUser(popupMenuUsers, user: user)
    }

    private func onSelectUserResults(_ selectedUser: String) {
        guard !selectedUsers.isEmpty, let userData = users[selectedUser] else {
            return
        }

        treeView.unselectAllRows()

        for row in userData.children {
            if !treeView.rowValue(row, "filename").string.isEmpty {
                treeView.selectRow(row, shouldScroll: false)
                continue
            }

            let userFolderPath = selectedUser + treeView.rowValue(row, "folder").string

            for childRow in folders[userFolderPath]?.children ?? [] {
                treeView.selectRow(childRow, shouldScroll: false)
            }
        }
    }

    private func selectResult(_ row: TreeRow) {
        let user = treeView.rowValue(row, "user").string

        if !selectedUsers.contains(user) {
            selectedUsers.append(user)
        }

        if !treeView.rowValue(row, "filename").string.isEmpty {
            let rowID = treeView.rowValue(row, "id_data").int

            if selectedResults[rowID] == nil {
                selectedResults[rowID] = row
            }
            return
        }

        selectChildResults(row, user: user)
    }

    private func selectChildResults(_ row: TreeRow, user: String) {
        let folderPath = treeView.rowValue(row, "folder").string
        let children = folderPath.isEmpty ? users[user]?.children : folders[user + folderPath]?.children

        for childRow in children ?? [] {
            selectResult(childRow)
        }
    }

    private func selectResults() {
        selectedResults.removeAll()
        selectedUsers.removeAll()

        for row in treeView.selectedRows {
            selectResult(row)
        }
    }

    private var firstSelectedResult: TreeRow? {
        selectedResults.first?.value
    }

    func updateResultCounter() {
        var plus = ""

        if isMaxLimited || numResultsFound > numResultsVisible {
            // Append plus symbol "+" if Results are Filtered and/or reached 'Maximum per search'
            plus = "+"

            // Display total results on the tooltip, but only if we know the exact number of results
            let total = isMaxLimited ? "> \(maxLimit)+" : String(numResultsFound)
            resultsTooltip = String(localized: "Total: \(total)")
        } else {
            resultsTooltip = String(localized: "Results")
        }

        resultsText = humanize(numResultsVisible) + plus
    }

    // MARK: Events

    private func onFilePathTooltip(_ treeView: TreeView, _ row: TreeRow) -> String? {
        let path = treeView.rowValue(row, "file_data").object(as: ResultFile.self)?.path ?? ""
        return path.isEmpty ? nil : path
    }

    private func onRowActivated(_ treeView: TreeView, _ row: TreeRow) {
        selectResults()

        let folderPath = treeView.rowValue(row, "folder").string
        let basename = treeView.rowValue(row, "filename").string

        if folderPath.isEmpty && basename.isEmpty {
            // Don't activate user rows
            return
        }

        if basename.isEmpty {
            onDownloadFolders()
        } else {
            onDownloadFiles()
        }

        treeView.unselectAllRows()
    }

    private func onPopupMenu(_ menu: PopupMenu) {
        selectResults()
        populatePopupMenuUsers()
        (menu as? FilePopupMenu)?.setNumSelectedFiles(selectedResults.count)
    }

    /// Escape: hide filter bar.
    func onCloseFilterBar() {
        isFiltersVisible = false
    }

    /// Command+F: show filter bar.
    private func onShowFilterBarAccelerator() -> Bool {
        isFiltersVisible = true
        filterFocusRequest += 1
        return true
    }

    /// Option+Return: show file properties dialog.
    private func onFilePropertiesAccelerator() -> Bool {
        selectResults()
        onFileProperties()
        return true
    }

    private func onBrowseFolder() {
        guard let row = firstSelectedResult,
              let file = treeView.rowValue(row, "file_data").object(as: ResultFile.self) else {
            return
        }

        core.userBrowse.browseUser(treeView.rowValue(row, "user").string, path: file.path)
    }

    private func onUserProfile() {
        guard let row = firstSelectedResult else {
            return
        }
        core.userInfo.showUser(treeView.rowValue(row, "user").string)
    }

    private func onFileProperties() {
        var data: [FilePropertiesItem] = []
        var selectedSize = 0
        var selectedLength = 0

        for row in selectedResults.values {
            guard let file = treeView.rowValue(row, "file_data").object(as: ResultFile.self) else {
                continue
            }

            let filePath = file.path
            let fileSize = treeView.rowValue(row, "size_data").int
            let pathComponents = filePath.components(separatedBy: "\\")

            selectedSize += fileSize
            selectedLength += treeView.rowValue(row, "length_data").int

            data.append(FilePropertiesItem(
                user: treeView.rowValue(row, "user").string,
                filePath: filePath,
                basename: pathComponents.last ?? "",
                virtualFolderPath: pathComponents.dropLast().joined(separator: "\\"),
                queuePosition: treeView.rowValue(row, "in_queue_data").int,
                speed: treeView.rowValue(row, "speed_data").int,
                size: fileSize,
                fileAttributes: file.attributes,
                countryCode: String(treeView.rowValue(row, "country").string.suffix(2)).uppercased()
            ))
        }

        guard !data.isEmpty else {
            return
        }

        if searches.fileProperties == nil {
            searches.fileProperties = FileProperties()
        }

        searches.fileProperties?.updateProperties(data, totalSize: selectedSize, totalLength: selectedLength)
        searches.fileProperties?.present()
    }

    private func onDownloadFiles(downloadFolderPath: String? = nil) {
        for row in selectedResults.values {
            guard let file = treeView.rowValue(row, "file_data").object(as: ResultFile.self) else {
                continue
            }

            core.downloads.enqueueDownload(
                username: treeView.rowValue(row, "user").string, virtualPath: file.path,
                folderPath: downloadFolderPath, size: treeView.rowValue(row, "size_data").int,
                fileAttributes: file.attributes
            )
        }
    }

    private func onDownloadFilesTo() {
        FileChooser.chooseFolders(
            title: String(localized: "Select Destination Folder for File(s)"),
            initialFolder: core.downloads.defaultDownloadFolder()
        ) { [weak self] folderPaths in
            self?.onDownloadFiles(downloadFolderPath: folderPaths.first)
        }
    }

    private func onDownloadFolders(downloadFolderPath: String? = nil) {
        var requestedFolders = Set<String>()

        for row in selectedResults.values {
            let user = treeView.rowValue(row, "user").string

            guard let file = treeView.rowValue(row, "file_data").object(as: ResultFile.self) else {
                continue
            }

            let folderPath = file.path.components(separatedBy: "\\").dropLast().joined(separator: "\\")
            let userFolderKey = user + folderPath

            if requestedFolders.contains(userFolderKey) {
                // Ensure we don't send folder content requests for a folder more than once,
                // e.g. when several selected results belong to the same folder
                continue
            }

            var visibleFiles: [SearchResultFile] = []

            for result in allData {
                // Find the wanted folder
                guard folderPath == result.file.path.components(separatedBy: "\\").dropLast().joined(separator: "\\")
                else {
                    continue
                }

                visibleFiles.append(SearchResultFile(virtualPath: result.file.path, size: result.size,
                                                     fileAttributes: result.file.attributes ?? [:]))
            }

            core.search.requestFolderDownload(username: user, folderPath: folderPath, visibleFiles: visibleFiles,
                                              downloadFolderPath: downloadFolderPath)
            requestedFolders.insert(userFolderKey)
        }
    }

    private func onDownloadFoldersTo() {
        FileChooser.chooseFolders(
            title: String(localized: "Select Destination Folder"),
            initialFolder: core.downloads.defaultDownloadFolder()
        ) { [weak self] folderPaths in
            self?.onDownloadFolders(downloadFolderPath: folderPaths.first)
        }
    }

    private func onCopyFilePath() {
        guard let row = firstSelectedResult,
              let file = treeView.rowValue(row, "file_data").object(as: ResultFile.self) else {
            return
        }
        Clipboard.copyText(file.path)
    }

    private func onCopyURL() {
        guard let row = firstSelectedResult,
              let file = treeView.rowValue(row, "file_data").object(as: ResultFile.self) else {
            return
        }

        let user = treeView.rowValue(row, "user").string
        Clipboard.copyText(UserBrowse.soulseekURL(username: user, path: file.path))
    }

    private func onCopyFolderURL() {
        guard let row = firstSelectedResult,
              let file = treeView.rowValue(row, "file_data").object(as: ResultFile.self) else {
            return
        }

        let user = treeView.rowValue(row, "user").string
        let folderPath = file.path.components(separatedBy: "\\").dropLast().joined(separator: "\\")
        Clipboard.copyText(UserBrowse.soulseekURL(username: user, path: folderPath + "\\"))
    }

    func onCounterButton() {
        if numResultsFound > numResultsVisible {
            onClearUndoFilters()
        } else {
            Application.shared.onConfigureSearches()
        }
    }

    func onGroup(_ mode: GroupingMode) {
        let isActive = (mode != .ungrouped)

        config.searches.groupSearches = mode
        groupingMode = mode

        clearModel()
        treeView.hasTree = isActive
        updateModel()
    }

    private func onToggleExpandAll() {
        if isExpanded {
            treeView.expandAllRows()
        } else {
            treeView.collapseAllRows()

            if groupingMode == .folderGrouping {
                treeView.expandRootRows()
            }
        }

        config.searches.expandSearches = isExpanded
    }

    private func onToggleFilters() {
        config.searches.filtersVisible = isFiltersVisible

        if isFiltersVisible {
            filterFocusRequest += 1
            return
        }

        treeView.grabFocus()
    }

    private func onEditSearch() {
        if mode == .wishlist {
            Application.shared.onWishlist()
            return
        }

        searches.setSearchMode(mode)

        if mode == .rooms {
            searches.roomSearchText = room ?? ""
        } else if mode == .user {
            searches.userSearchText = searchedUsers?.first ?? ""
        }

        searches.searchText = text
        searches.focusSearchEntry()
    }

    private static func split(_ text: String, pattern: NSRegularExpression) -> [String] {
        var parts: [String] = []
        var location = text.startIndex

        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else {
                continue
            }

            parts.append(String(text[location..<range.lowerBound]))
            location = range.upperBound
        }

        parts.append(String(text[location...]))
        return parts
    }

    func onRefilter() {
        guard !isPopulatingFilters else {
            return
        }

        isRefiltering = true
        defer { isRefiltering = false }

        var newFilters = Filters()
        var filterStrings = FilterValues()

        filterStrings.include = filterValues.include.trimmingCharacters(in: .whitespaces)
        filterStrings.exclude = filterValues.exclude.trimmingCharacters(in: .whitespaces)
        filterStrings.size = filterValues.size.trimmingCharacters(in: .whitespaces)
        filterStrings.bitrate = filterValues.bitrate.trimmingCharacters(in: .whitespaces)
        filterStrings.country = filterValues.country.trimmingCharacters(in: .whitespaces)
        filterStrings.fileType = filterValues.fileType.trimmingCharacters(in: .whitespaces)
        filterStrings.length = filterValues.length.trimmingCharacters(in: .whitespaces)
        filterStrings.freeSlot = filterValues.freeSlot

        // Include/exclude text
        var errorFilters = Set<FilterID>()

        if !filterStrings.include.isEmpty {
            newFilters.include = try? NSRegularExpression(pattern: filterStrings.include, options: .caseInsensitive)

            if newFilters.include == nil {
                errorFilters.insert(.include)
            }
        }

        if !filterStrings.exclude.isEmpty {
            newFilters.exclude = try? NSRegularExpression(pattern: filterStrings.exclude, options: .caseInsensitive)

            if newFilters.exclude == nil {
                errorFilters.insert(.exclude)
            }
        }

        // Mark entries with invalid regex patterns
        invalidFilters = errorFilters

        // Split at | pipes ampersands & space(s) but don't split <>=! math operators spaced before digit condition
        if !filterStrings.size.isEmpty {
            newFilters.size = Self.split(filterStrings.size, pattern: Self.filterSplitDigitPattern)
        }

        if !filterStrings.bitrate.isEmpty {
            newFilters.bitrate = Self.split(filterStrings.bitrate, pattern: Self.filterSplitDigitPattern)
        }

        if !filterStrings.length.isEmpty {
            newFilters.length = Self.split(filterStrings.length, pattern: Self.filterSplitDigitPattern)
        }

        // Split at commas, in addition to | pipes ampersands & space(s) but don't split ! not operator before condition
        if !filterStrings.country.isEmpty {
            newFilters.country = Self.split(filterStrings.country.uppercased(), pattern: Self.filterSplitTextPattern)
        }

        if !filterStrings.fileType.isEmpty {
            var fileTypes = Self.split(filterStrings.fileType.lowercased(), pattern: Self.filterSplitTextPattern)

            // Replace generic file type filters with real file extensions
            for (filterName, fileExtensions) in Self.filterGenericFileTypes {
                let excludedFilterName = "!\(filterName)"

                if let index = fileTypes.firstIndex(of: filterName) {
                    fileTypes.remove(at: index)
                    fileTypes += fileExtensions.sorted()

                } else if let index = fileTypes.firstIndex(of: excludedFilterName) {
                    fileTypes.remove(at: index)
                    fileTypes += fileExtensions.sorted().map { "!" + $0 }
                }
            }

            newFilters.fileType = fileTypes
        }

        newFilters.freeSlot = filterStrings.freeSlot

        if appliedFilterValues == filterStrings {
            // Filters have not changed, no need to refilter
            return
        }

        if appliedFilterValues != nil && filterStrings == Self.emptyFilters {
            // Filters cleared, enable Restore Filters
            filtersUndo = appliedFilterValues ?? Self.emptyFilters
        } else {
            // Filters active, enable Clear Filters
            filtersUndo = Self.emptyFilters
        }

        activeFilterCount = 0

        // Add filters to history
        for filterID in FilterID.allCases {
            let value = filterStrings.text(filterID)

            guard !value.isEmpty else {
                continue
            }

            pushHistory(filterID, value: value)
            activeFilterCount += 1
        }

        // Apply the new filters
        filters = newFilters
        appliedFilterValues = filterStrings
        updateFilterWidgets()
        clearModel()
        updateModel()
    }

    /// Called when the text of a filter entry changes.
    func onFilterEntryChanged(_ filterID: FilterID) {
        if !isRefiltering && filterValues.text(filterID).isEmpty {
            onRefilter()
        }
    }

    func onClearUndoFilters() {
        setFilters(filtersUndo)

        if !isFiltersVisible {
            treeView.grabFocus()
        }
    }

    func onClear() {
        clearModel(storedResults: true)

        // Allow parsing search result messages again
        Search.addAllowedToken(token)

        // Update number of results widget
        updateResultCounter()
    }

    func onFocus() -> Bool {
        if searches.searchText.isEmpty {
            // Only focus list view if we're not entering a new search term
            treeView.grabFocus()
        }
        return true
    }

    func onClose() {
        core.search.removeSearch(token)
    }
}
