// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import NicotineCore
import Observation
import SwiftUI

/// Interests page: personal likes and dislikes, recommendations and similar users.
@MainActor
@Observable
final class InterestsPage: MainPage {

    @ObservationIgnored let window: MainWindow
    @ObservationIgnored private(set) var likesListView: TreeView!
    @ObservationIgnored private(set) var dislikesListView: TreeView!
    @ObservationIgnored private(set) var recommendationsListView: TreeView!
    @ObservationIgnored private(set) var similarUsersListView: TreeView!
    @ObservationIgnored private var popupMenus: [PopupMenu] = []
    @ObservationIgnored private var isRecommendationsPopulated = false

    var likeText = ""
    var dislikeText = ""
    private(set) var recommendationsLabel = String(localized: "Recommendations")
    private(set) var similarUsersLabel = String(localized: "Similar Users")
    private(set) var isRecommendationsEnabled = false

    init(window: MainWindow) {
        self.window = window

        likesListView = TreeView(
            columns: [
                TreeColumn(id: "likes", title: String(localized: "Likes"), defaultSortOrder: .ascending)
            ],
            deleteAccelerator: { [unowned self] _ in onRemoveThingILike() }
        )

        dislikesListView = TreeView(
            columns: [
                TreeColumn(id: "dislikes", title: String(localized: "Dislikes"), defaultSortOrder: .ascending)
            ],
            deleteAccelerator: { [unowned self] _ in onRemoveThingIDislike() }
        )

        recommendationsListView = TreeView(
            columns: [
                // Visible columns
                TreeColumn(id: "rating", title: String(localized: "Rating"), kind: .number, width: 0,
                           sortColumn: "rating_data", defaultSortOrder: .descending),
                TreeColumn(id: "item", title: String(localized: "Item"), isIteratorKey: true),

                // Hidden data columns
                .data("rating_data")
            ],
            activateRow: { [unowned self] _, _, _ in
                showItemRecommendations(recommendationsListView, columnID: "item")
            }
        )

        similarUsersListView = TreeView(
            columns: [
                // Visible columns
                TreeColumn(id: "status", title: String(localized: "Status"), kind: .icon, width: 25, hidesHeader: true),
                TreeColumn(id: "country", title: String(localized: "Country"), kind: .icon, width: 30,
                           hidesHeader: true),
                TreeColumn(id: "user", title: String(localized: "User"), width: 120, expandsColumn: true,
                           isIteratorKey: true),
                TreeColumn(id: "speed", title: String(localized: "Speed"), kind: .number, width: 90,
                           expandsColumn: true, sortColumn: "speed_data"),
                TreeColumn(id: "files", title: String(localized: "Files"), kind: .number, expandsColumn: true,
                           sortColumn: "files_data"),

                // Hidden data columns
                .data("speed_data"),
                .data("files_data"),
                .data("rating_data", sortOrder: .descending)
            ],
            activateRow: { [unowned self] _, _, _ in onSimilarUserRowActivated() }
        )

        likesListView.freeze()
        dislikesListView.freeze()

        for item in config.interests.likes {
            addThingILike(item, selectRow: false)
        }

        for item in config.interests.dislikes {
            addThingIHate(item, selectRow: false)
        }

        likesListView.unfreeze()
        dislikesListView.unfreeze()

        // Popup menus
        let likesMenu = PopupMenu()
        likesMenu.addItems(
            .action(String(localized: "Recommendations for Item")) { [unowned self] in
                showItemRecommendations(likesListView, columnID: "likes")
            },
            .action(String(localized: "Search for Item")) { [unowned self] in
                onRecommendSearch(likesListView, columnID: "likes")
            },
            .separator,
            .action(String(localized: "Remove")) { [unowned self] in onRemoveThingILike() }
        )
        likesListView.popupMenu = likesMenu

        let dislikesMenu = PopupMenu()
        dislikesMenu.addItems(
            .action(String(localized: "Recommendations for Item")) { [unowned self] in
                showItemRecommendations(dislikesListView, columnID: "dislikes")
            },
            .action(String(localized: "Search for Item")) { [unowned self] in
                onRecommendSearch(dislikesListView, columnID: "dislikes")
            },
            .separator,
            .action(String(localized: "Remove")) { [unowned self] in onRemoveThingIDislike() }
        )
        dislikesListView.popupMenu = dislikesMenu

        let recommendationsMenu = PopupMenu { [unowned self] menu in
            toggleMenuItems(menu, listView: recommendationsListView, columnID: "item")
        }
        recommendationsMenu.addItems(interestItems(recommendationsListView, columnID: "item"))
        recommendationsListView.popupMenu = recommendationsMenu

        let similarUsersMenu = UserPopupMenu { [unowned self] menu in onPopupSimilarUsersMenu(menu) }
        similarUsersListView.popupMenu = similarUsersMenu

        popupMenus = [likesMenu, dislikesMenu, recommendationsMenu, similarUsersMenu]

        events.connect(.addDislike) { [unowned self] in addThingIHate($0) }
        events.connect(.addInterest) { [unowned self] in addThingILike($0) }
        events.connect(.globalRecommendations) { [unowned self] in
            setRecommendations($0.recommendations + $0.unrecommendations)
        }
        events.connect(.itemRecommendations) { [unowned self] in
            setRecommendations($0.recommendations + $0.unrecommendations, item: $0.thing)
        }
        events.connect(.itemSimilarUsers) { [unowned self] msg in
            var users = OrderedDictionary<String, Int>()

            for user in msg.users {
                users[user] = 0
            }
            setSimilarUsers(users, item: msg.thing)
        }
        events.connect(.recommendations) { [unowned self] in
            setRecommendations($0.recommendations + $0.unrecommendations)
        }
        events.connect(.removeDislike) { [unowned self] in removeThingIHate($0) }
        events.connect(.removeInterest) { [unowned self] in removeThingILike($0) }
        events.connect(.serverLogin) { [unowned self] in serverLogin($0) }
        events.connect(.serverDisconnect) { [unowned self] _ in serverDisconnect() }
        events.connect(.similarUsers) { [unowned self] in setSimilarUsers($0.users) }
        events.connect(.userCountry) { [unowned self] in userCountry($0) }
        events.connect(.userStats) { [unowned self] in userStats($0) }
        events.connectMessage(.userStatus) { [unowned self] in userStatus($0) }
    }

    func onFocus() {
        populateRecommendations()
        recommendationsListView.grabFocus()
    }

    private func serverLogin(_ msg: Login) {
        guard msg.success else {
            return
        }

        isRecommendationsEnabled = true

        if window.currentPage != .interests {
            // Only populate recommendations if the tab is open on login
            return
        }

        populateRecommendations()
    }

    private func serverDisconnect() {
        isRecommendationsEnabled = false

        for row in similarUsersListView.iterators.values {
            similarUsersListView.setRowValue(row, "status", .string(Theme.userStatusIconName(.offline)))
        }

        isRecommendationsPopulated = false
    }

    /// Populates the lists of recommendations and similar users if empty.
    private func populateRecommendations() {
        if isRecommendationsPopulated || core.users.loginStatus == .offline {
            return
        }

        showRecommendations()
    }

    func showRecommendations() {
        recommendationsLabel = String(localized: "Recommendations")
        similarUsersLabel = String(localized: "Similar Users")

        if likesListView.isEmpty && dislikesListView.isEmpty {
            core.interests.requestGlobalRecommendations()
        } else {
            core.interests.requestRecommendations()
        }

        core.interests.requestSimilarUsers()
        isRecommendationsPopulated = true
    }

    func showItemRecommendations(_ listView: TreeView, columnID: String) {
        guard let row = listView.selectedRows.first else {
            return
        }

        let item = listView.rowValue(row, columnID).string

        core.interests.requestItemRecommendations(item)
        core.interests.requestItemSimilarUsers(item)
        isRecommendationsPopulated = true

        if window.currentPage != .interests {
            window.changeMainPage(.interests)
        }
    }

    private func addThingILike(_ item: String, selectRow: Bool = true) {
        let item = item.trimmingCharacters(in: .whitespaces).lowercased()

        guard !item.isEmpty, likesListView.iterators[.string(item)] == nil else {
            return
        }

        likesListView.addRow([.string(item)], selectRow: selectRow)
    }

    private func addThingIHate(_ item: String, selectRow: Bool = true) {
        let item = item.trimmingCharacters(in: .whitespaces).lowercased()

        guard !item.isEmpty, dislikesListView.iterators[.string(item)] == nil else {
            return
        }

        dislikesListView.addRow([.string(item)], selectRow: selectRow)
    }

    private func removeThingILike(_ item: String) {
        if let row = likesListView.iterators[.string(item)] {
            likesListView.removeRow(row)
        }
    }

    private func removeThingIHate(_ item: String) {
        if let row = dislikesListView.iterators[.string(item)] {
            dislikesListView.removeRow(row)
        }
    }

    func onAddThingILike() {
        let item = likeText.trimmingCharacters(in: .whitespaces)

        guard !item.isEmpty else {
            return
        }

        likeText = ""
        core.interests.addThingILike(item)
    }

    func onAddThingIDislike() {
        let item = dislikeText.trimmingCharacters(in: .whitespaces)

        guard !item.isEmpty else {
            return
        }

        dislikeText = ""
        core.interests.addThingIHate(item)
    }

    private func onRemoveThingILike() {
        if let row = likesListView.selectedRows.first {
            core.interests.removeThingILike(likesListView.rowValue(row, "likes").string)
        }
    }

    private func onRemoveThingIDislike() {
        if let row = dislikesListView.selectedRows.first {
            core.interests.removeThingIHate(dislikesListView.rowValue(row, "dislikes").string)
        }
    }

    // MARK: Interest Item Menus

    /// Menu items for liking, disliking and searching for the selected item of a list view.
    func interestItems(_ listView: TreeView, columnID: String) -> [PopupMenu.Item] {
        [
            .toggle(String(localized: "I Like This")) { [unowned self] isActive in
                onLikeRecommendation(listView, columnID: columnID, isActive: isActive)
            },
            .toggle(String(localized: "I Dislike This")) { [unowned self] isActive in
                onDislikeRecommendation(listView, columnID: columnID, isActive: isActive)
            },
            .separator,
            .action(String(localized: "Recommendations for Item")) { [unowned self] in
                showItemRecommendations(listView, columnID: columnID)
            },
            .action(String(localized: "Search for Item")) { [unowned self] in
                onRecommendSearch(listView, columnID: columnID)
            }
        ]
    }

    func toggleMenuItems(_ menu: PopupMenu, listView: TreeView, columnID: String) {
        guard let row = listView.selectedRows.first else {
            return
        }

        let item = listView.rowValue(row, columnID).string

        menu.setState(String(localized: "I Like This"), config.interests.likes.contains(item))
        menu.setState(String(localized: "I Dislike This"), config.interests.dislikes.contains(item))
    }

    private func onLikeRecommendation(_ listView: TreeView, columnID: String, isActive: Bool) {
        guard let row = listView.selectedRows.first else {
            return
        }

        let item = listView.rowValue(row, columnID).string

        if isActive {
            core.interests.addThingILike(item)
        } else {
            core.interests.removeThingILike(item)
        }
    }

    private func onDislikeRecommendation(_ listView: TreeView, columnID: String, isActive: Bool) {
        guard let row = listView.selectedRows.first else {
            return
        }

        let item = listView.rowValue(row, columnID).string

        if isActive {
            core.interests.addThingIHate(item)
        } else {
            core.interests.removeThingIHate(item)
        }
    }

    private func onRecommendSearch(_ listView: TreeView, columnID: String) {
        if let row = listView.selectedRows.first {
            core.search.doSearch(listView.rowValue(row, columnID).string, mode: .global)
        }
    }

    // MARK: Recommendations

    private func setRecommendations(_ recommendations: [Recommendation], item: String? = nil) {
        if let item {
            recommendationsLabel = String(localized: "Recommendations (\(item))")
        } else {
            recommendationsLabel = String(localized: "Recommendations")
        }

        recommendationsListView.clear()
        recommendationsListView.freeze()

        for recommendation in recommendations {
            recommendationsListView.addRow([
                .string(humanize(recommendation.rating)), .string(recommendation.item), .int(recommendation.rating)
            ], selectRow: false)
        }

        recommendationsListView.unfreeze()
    }

    private func setSimilarUsers(_ users: OrderedDictionary<String, Int>, item: String? = nil) {
        if let item {
            similarUsersLabel = String(localized: "Similar Users (\(item))")
        } else {
            similarUsersLabel = String(localized: "Similar Users")
        }

        similarUsersListView.clear()
        similarUsersListView.freeze()

        for (index, (user, userRating)) in users.reversed().enumerated() {
            let status = core.users.statuses[user] ?? .offline
            let countryCode = core.users.countries[user] ?? ""
            let stats = core.users.watched[user]
            let rating = index + (1000 * userRating)  // Preserve default sort order
            let speed = stats?.uploadSpeed ?? 0
            let files = stats?.files

            similarUsersListView.addRow([
                .string(Theme.userStatusIconName(status)),
                .string(Theme.flagIconName(countryCode)),
                .string(user),
                .string(speed > 0 ? humanSpeed(speed) : ""),
                .string(files.map(humanize) ?? ""),
                .int(speed),
                .int(files ?? 0),
                .int(rating)
            ], selectRow: false)
        }

        similarUsersListView.unfreeze()
    }

    private func userCountry(_ event: UserCountryEvent) {
        guard let row = similarUsersListView.iterators[.string(event.username)] else {
            return
        }

        let flagIconName = Theme.flagIconName(event.countryCode)

        if !flagIconName.isEmpty && flagIconName != similarUsersListView.rowValue(row, "country").string {
            similarUsersListView.setRowValue(row, "country", .string(flagIconName))
        }
    }

    private func userStatus(_ msg: GetUserStatus) {
        guard let row = similarUsersListView.iterators[.string(msg.user)],
              let status = UserStatus(rawValue: msg.status) else {
            return
        }

        let statusIconName = Theme.userStatusIconName(status)

        if statusIconName != similarUsersListView.rowValue(row, "status").string {
            similarUsersListView.setRowValue(row, "status", .string(statusIconName))
        }
    }

    private func userStats(_ msg: GetUserStats) {
        guard let row = similarUsersListView.iterators[.string(msg.user)] else {
            return
        }

        let speed = msg.avgSpeed
        let numFiles = msg.files
        var values: [String: TreeValue] = [:]

        if speed != similarUsersListView.rowValue(row, "speed_data").int {
            values["speed"] = .string(speed > 0 ? humanSpeed(speed) : "")
            values["speed_data"] = .int(speed)
        }

        if numFiles != similarUsersListView.rowValue(row, "files_data").int {
            values["files"] = .string(humanize(numFiles))
            values["files_data"] = .int(numFiles)
        }

        if !values.isEmpty {
            similarUsersListView.setRowValues(row, values)
        }
    }

    private func onPopupSimilarUsersMenu(_ menu: PopupMenu) {
        guard let row = similarUsersListView.selectedRows.first, let menu = menu as? UserPopupMenu else {
            return
        }

        menu.setUser(similarUsersListView.rowValue(row, "user").string)
        menu.toggleUserItems()
    }

    private func onSimilarUserRowActivated() {
        if let row = similarUsersListView.selectedRows.first {
            core.userInfo.showUser(similarUsersListView.rowValue(row, "user").string)
        }
    }
}

/// Interests page.
struct InterestsView: View {

    @Bindable var page: InterestsPage

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VSplitView {
                    interestList(title: String(localized: "Personal Interests"),
                                 placeholder: String(localized: "Add something you like…"),
                                 text: $page.likeText, listView: page.likesListView) {
                        page.onAddThingILike()
                    }

                    interestList(title: String(localized: "Personal Dislikes"),
                                 placeholder: String(localized: "Add something you dislike…"),
                                 text: $page.dislikeText, listView: page.dislikesListView) {
                        page.onAddThingIDislike()
                    }
                }
            }
            .frame(minWidth: 200, idealWidth: 260)

            VStack(spacing: 0) {
                HStack {
                    Text(page.recommendationsLabel)
                        .font(.headline)
                    Spacer()
                    Button {
                        page.showRecommendations()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!page.isRecommendationsEnabled)
                    .help(String(localized: "Refresh Recommendations"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                page.recommendationsListView.view
            }
            .frame(minWidth: 200)

            VStack(spacing: 0) {
                Text(page.similarUsersLabel)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)

                page.similarUsersListView.view
            }
            .frame(minWidth: 250)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Application.shared.onConfigureUserProfile()
                } label: {
                    Label(String(localized: "Configure User Profile"), systemImage: "gearshape")
                }
                .help(String(localized: "Configure User Profile"))
            }
        }
    }

    private func interestList(title: String, placeholder: String, text: Binding<String>, listView: TreeView,
                              onSubmit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)

            HStack {
                TextField(placeholder, text: text)
                    .onSubmit(onSubmit)
                Button(action: onSubmit) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }

            listView.view
                .border(Color(nsColor: .separatorColor))
        }
        .padding(10)
        .frame(minHeight: 150)
    }
}
