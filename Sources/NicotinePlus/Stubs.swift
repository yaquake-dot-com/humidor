// SPDX-License-Identifier: GPL-3.0-or-later
// Temporary placeholders, replaced as pages are ported.

import NicotineCore
import SwiftUI

@MainActor final class Preferences {
    init(application: Application) {}
    func setSettings() {}
    func setActivePage(_ pageID: String) {}
    func present() {}
}

@MainActor final class FastConfigure {
    var invalidPassword = false
    var isVisible = false
    init(application: Application) {}
    func hide() {}
    func present() {}
}

@MainActor final class StatisticsDialog { func present() {} }
@MainActor final class WishList { init(application: Application) {}; func present() {} }
@MainActor final class About { func present() {} }
@MainActor final class Shortcuts { func present() {} }


@MainActor final class InterestsPage: MainPage { init(window: MainWindow) {}; func onFocus() {} }
@MainActor final class ChatRoomsPage: MainPage {
    var highlightedRooms: [(String, String?)] = []
    init(window: MainWindow) {}
    func onFocus() {}
    func clearNotifications() {}
}
@MainActor final class BuddiesPage: MainPage {
    init(window: MainWindow) {}
    func onFocus() {}
    var content: some View { Text("") }
    var pageContent: some View { Text("") }
}
@MainActor final class PrivateChatsPage: MainPage {
    var highlightedUsers: [String] = []
    init(window: MainWindow) {}
    func onFocus() {}
    func clearNotifications() {}
}
@MainActor final class UserInfosPage: MainPage { init(window: MainWindow) {}; func onFocus() {} }
@MainActor final class UserBrowsesPage: MainPage { init(window: MainWindow) {}; func onFocus() {} }

struct UserBrowsesView: View { let page: UserBrowsesPage; var body: some View { Text("Browse") } }
struct UserInfosView: View { let page: UserInfosPage; var body: some View { Text("Info") } }
struct PrivateChatsView: View { let page: PrivateChatsPage; var body: some View { Text("Private") } }
struct ChatRoomsView: View { let page: ChatRoomsPage; var body: some View { Text("Rooms") } }
struct InterestsView: View { let page: InterestsPage; var body: some View { Text("Interests") } }
