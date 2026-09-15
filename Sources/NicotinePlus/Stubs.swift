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


@MainActor final class BuddiesPage: MainPage {
    init(window: MainWindow) {}
    func onFocus() {}
    var content: some View { Text("") }
    var pageContent: some View { Text("") }
}

