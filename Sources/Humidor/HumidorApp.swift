// SPDX-License-Identifier: GPL-3.0-or-later

import HumidorCore
import SwiftUI

@main
struct HumidorApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var application

    var body: some Scene {
        // A single main window, as in the original program
        Window(Application.name, id: AppWindow.main.rawValue) {
            MainWindowView(mainWindow: application.window)
                .presentationHost(AppWindow.main.rawValue)
        }
        .defaultSize(width: 1100, height: 750)
        .commands {
            MainCommands(application: application)
        }

        Settings {
            PreferencesView(preferences: application.preferences)
                .presentationHost("settings")
        }
        .windowResizability(.contentMinSize)

        Window(String(localized: "About"), id: AppWindow.about.rawValue) {
            AboutView(about: application.about)
                .presentationHost(AppWindow.about.rawValue)
        }
        .dialogWindow(width: 425, height: 540)

        Window(String(localized: "Transfer Statistics"), id: AppWindow.statistics.rawValue) {
            StatisticsView(statistics: application.statistics)
                .presentationHost(AppWindow.statistics.rawValue)
        }
        .dialogWindow()
        .windowResizability(.contentSize)

        Window(String(localized: "Wishlist"), id: AppWindow.wishlist.rawValue) {
            WishListView(wishList: application.wishlist)
                .presentationHost(AppWindow.wishlist.rawValue)
        }
        .dialogWindow(width: 600, height: 600)

        Window(String(localized: "Keyboard Shortcuts"), id: AppWindow.shortcuts.rawValue) {
            Shortcuts.content
                .presentationHost(AppWindow.shortcuts.rawValue)
        }
        .dialogWindow(width: 720, height: 560)

        Window(String(localized: "File Properties"), id: AppWindow.fileProperties.rawValue) {
            FilePropertiesView(fileProperties: application.fileProperties)
                .presentationHost(AppWindow.fileProperties.rawValue)
        }
        .dialogWindow(width: 600, height: 380)

        Window(String(localized: "Settings"), id: AppWindow.pluginSettings.rawValue) {
            PluginSettingsView(dialog: application.preferences.pluginSettingsDialog)
                .presentationHost(AppWindow.pluginSettings.rawValue)
        }
        .dialogWindow(width: 600, height: 425)
    }
}

private extension Scene {

    /// A secondary window, opened by the application: centered, not restored at launch and not
    /// listed in the Window menu
    func dialogWindow(width: CGFloat? = nil, height: CGFloat? = nil) -> some Scene {
        self
            .defaultSize(width: width ?? 0, height: height ?? 0)
            .defaultPosition(.center)
            .restorationBehavior(.disabled)
            .commandsRemoved()
    }
}
