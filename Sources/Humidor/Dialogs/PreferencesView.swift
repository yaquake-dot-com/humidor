// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore
import SwiftUI

struct PreferencesView: View {

    @Bindable var preferences: Preferences

    var body: some View {
        NavigationSplitView {
            List(preferences.pages, selection: $preferences.activePageID) { page in
                Label(page.title, systemImage: page.systemImage)
                    .tag(page.id)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detailView
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 760, minHeight: 500)
    }

    @ViewBuilder private var detailView: some View {
        pageView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .bottomBar {
                buttonBar
            }
    }

    private var buttonBar: some View {
        HStack(spacing: 12) {
            Spacer()

            Button(String(localized: "Export…")) { preferences.onBackUpConfig() }
            Button(String(localized: "Cancel")) { preferences.close() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Apply")) { preferences.updateSettings() }
            Button(String(localized: "OK")) { preferences.updateSettings(isClosing: true) }
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var pageView: some View {
        switch preferences.activePageID {
        case "network": NetworkSettingsPage(preferences: preferences)
        case "user-interface": UserInterfaceSettingsPage(preferences: preferences)
        case "shares": SharesSettingsPage(preferences: preferences)
        case "downloads": DownloadsSettingsPage(preferences: preferences)
        case "uploads": UploadsSettingsPage(preferences: preferences)
        case "searches": SearchesSettingsPage(preferences: preferences)
        case "user-profile": UserProfileSettingsPage(preferences: preferences)
        case "chats": ChatsSettingsPage(preferences: preferences)
        case "now-playing": NowPlayingSettingsPage(preferences: preferences)
        case "logging": LoggingSettingsPage(preferences: preferences)
        case "banned-users": BannedUsersSettingsPage(preferences: preferences)
        case "ignored-users": IgnoredUsersSettingsPage(preferences: preferences)
        case "url-handlers": URLHandlersSettingsPage(preferences: preferences)
        case "plugins": PluginsSettingsPage(preferences: preferences)
        default: EmptyView()
        }
    }
}

// MARK: - Building Blocks

private struct PageForm<Content: View>: View {

    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
    }
}

/// Integer entry with a stepper
private struct NumberField: View {

    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...Int.max
    var step = 1

    var body: some View {
        LabeledContent(title) {
            NumberInput(value: $value, range: range, step: step)
        }
    }
}

private struct NumberInput: View {

    @Binding var value: Int
    var range: ClosedRange<Int> = 0...Int.max
    var step = 1

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $value, format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}

/// Radio button row, with an optional control at the end
private struct RadioRow<Value: Hashable, Accessory: View>: View {

    let title: String
    let value: Value
    @Binding var selection: Value
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Button {
                selection = value
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selection == value ? "record.circle.fill" : "circle")
                        .foregroundStyle(selection == value ? Color.accentColor : Color.secondary)
                    Text(title)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()
            accessory
        }
    }
}

extension RadioRow where Accessory == EmptyView {

    init(title: String, value: Value, selection: Binding<Value>) {
        self.init(title: title, value: value, selection: selection) { EmptyView() }
    }
}

/// Color entry, with a text field for the hexadecimal value and a color well
private struct ColorField: View {

    let title: String
    @Binding var hex: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", text: $hex)
                    .labelsHidden()
                    .frame(width: 90)
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: Theme.color(hex: hex) ?? .textColor) },
                    set: { hex = Self.hexString(NSColor($0)) }
                ), supportsOpacity: false)
                .labelsHidden()
                Button {
                    hex = ""
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Clear"))
                .disabled(hex.isEmpty)
            }
        }
    }

    private static func hexString(_ color: NSColor) -> String {
        guard let color = color.usingColorSpace(.sRGB) else {
            return ""
        }

        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return "#" + [red, green, blue].map { String(format: "%02X", $0) }.joined()
    }
}

/// Font selection button, using the system font panel
private struct FontField: View {

    let title: String
    @Binding var fontDescription: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Button(fontDescription.isEmpty ? String(localized: "Default") : fontDescription) {
                    FontChooser.shared.choose(initialFont: Theme.font(fontDescription)) { font in
                        fontDescription = "\(font.familyName ?? font.fontName) \(String(Int(font.pointSize)))"
                    }
                }
                Button {
                    fontDescription = ""
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Clear"))
                .disabled(fontDescription.isEmpty)
            }
        }
    }
}

/// Folder selection with a button for restoring the default folder
private struct FolderField: View {

    let title: String
    @Binding var path: String
    let defaultPath: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                FileChooserButton(path: $path, chooserType: .folder,
                                  showsOpenButton: !Application.shared.isolatedMode)
                    .frame(maxWidth: 320)
                Button {
                    path = defaultPath
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Default"))
            }
        }
    }
}

private func descriptionText(_ text: String) -> some View {
    Text(text)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - Network

private struct NetworkSettingsPage: View {

    @Bindable var preferences: Preferences

    var body: some View {
        PageForm {
            Section {
                descriptionText(String(localized: "Log in to an existing Soulseek account or create a new one. Usernames are case-sensitive and unique."))

                LabeledContent(String(localized: "Username: ")) {
                    HStack {
                        TextField("", text: Binding(
                            get: { preferences.draft.server.login },
                            set: { preferences.draft.server.login = String($0.prefix(Users.usernameMaxLength)) }
                        ))
                        .labelsHidden()
                        .frame(maxWidth: 220)

                        Button(String(localized: "Change Password")) { preferences.onChangePassword() }
                    }
                }

                LabeledContent(String(localized: "Public IP address:")) {
                    HStack {
                        Text(preferences.publicAddressText)
                            .textSelection(.enabled)

                        if let url = preferences.portCheckerURL.flatMap(URL.init(string:)) {
                            Link(String(localized: "Check Port Status"), destination: url)
                        }
                    }
                }

                NumberField(title: String(localized: "Listening port:"), value: $preferences.listenPort,
                            range: 1024...65535)

                Toggle(String(localized: "Automatically forward listening port (UPnP/NAT-PMP)"),
                       isOn: $preferences.draft.server.upnp)
            } header: {
                Text(String(localized: "Network"))
            }

            Section(String(localized: "Away Status")) {
                NumberField(title: String(localized: "Minutes of inactivity before going away (0 to disable):"),
                            value: $preferences.draft.server.autoAway, range: 0...10000, step: 5)

                TextField(String(localized: "Auto-reply message when away:"),
                          text: $preferences.draft.server.autoReply)
            }

            Section(String(localized: "Connections")) {
                Toggle(String(localized: "Auto-connect to server on startup"),
                       isOn: $preferences.draft.server.autoConnectStartup)

                LabeledContent(String(localized: "Soulseek server:")) {
                    HStack {
                        TextField("", text: $preferences.serverAddress)
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        Button {
                            preferences.onDefaultServer()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Default"))
                    }
                }

                LabeledContent(String(localized: "Network interface:")) {
                    ComboBox(placeholder: "", text: $preferences.draft.server.interface,
                             items: preferences.networkInterfaces)
                        .frame(maxWidth: 220)
                }
                .help(String(localized: "Binds connections to a specific network interface, useful for e.g. ensuring a VPN is used at all times. Leave empty to use any available interface. Only change this value if you know what you are doing."))
            }
        }
    }
}

// MARK: - User Interface

private struct UserInterfaceSettingsPage: View {

    @Bindable var preferences: Preferences

    private static let visibleTabs: [(id: String, title: String)] = [
        ("search", String(localized: "Search Files")),
        ("downloads", String(localized: "Downloads")),
        ("uploads", String(localized: "Uploads")),
        ("userbrowse", String(localized: "Browse Shares")),
        ("userinfo", String(localized: "User Profiles")),
        ("private", String(localized: "Private Chat")),
        ("userlist", String(localized: "Buddies")),
        ("chatrooms", String(localized: "Chat Rooms")),
        ("interests", String(localized: "Interests"))
    ]

    var body: some View {
        PageForm {
            Section(String(localized: "User Interface")) {
                Toggle(String(localized: "Prefer dark mode"), isOn: $preferences.draft.ui.darkMode)

                Picker(String(localized: "Language (requires a restart):"), selection: $preferences.draft.ui.language) {
                    Text(String(localized: "System default")).tag("")
                    ForEach(Preferences.languages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }

                Picker(String(localized: "When closing window:"), selection: $preferences.draft.ui.exitDialog) {
                    Text(String(localized: "Quit \(HumidorCore.Application.name)")).tag(0)
                    Text(String(localized: "Show confirmation dialog")).tag(1)
                    Text(String(localized: "Run in the background")).tag(2)
                }
            }

            Section(String(localized: "Notifications")) {
                Toggle(String(localized: "Enable sound for notifications"),
                       isOn: $preferences.draft.notifications.popupSound)
                Toggle(String(localized: "Show notification for private chats and mentions in the window title"),
                       isOn: $preferences.draft.notifications.windowTitle)

                LabeledContent(String(localized: "Show notifications for:")) {
                    VStack(alignment: .leading) {
                        Toggle(String(localized: "Finished file downloads"),
                               isOn: $preferences.draft.notifications.popupFile)
                        Toggle(String(localized: "Finished folder downloads"),
                               isOn: $preferences.draft.notifications.popupFolder)
                        Toggle(String(localized: "Private messages"),
                               isOn: $preferences.draft.notifications.popupPrivateMessage)
                        Toggle(String(localized: "Chat room messages"),
                               isOn: $preferences.draft.notifications.popupChatroom)
                        Toggle(String(localized: "Chat room mentions"),
                               isOn: $preferences.draft.notifications.popupChatroomMention)
                        Toggle(String(localized: "Wishlist results found"),
                               isOn: $preferences.draft.notifications.popupWish)
                    }
                }
            }

            Section(String(localized: "Tabs")) {
                Toggle(String(localized: "Restore the previously active main tab at startup"),
                       isOn: $preferences.draft.ui.tabSelectPrevious)
                Toggle(String(localized: "Close-buttons on secondary tabs"), isOn: $preferences.draft.ui.tabClosers)

                ColorField(title: String(localized: "Regular tab label color:"), hex: $preferences.draft.ui.tabDefault)
                ColorField(title: String(localized: "Changed tab label color:"), hex: $preferences.draft.ui.tabChanged)
                ColorField(title: String(localized: "Highlighted tab label color:"),
                           hex: $preferences.draft.ui.tabHighlight)

                Picker(String(localized: "Buddy list position:"),
                       selection: $preferences.draft.ui.buddyListInChatrooms) {
                    Text(String(localized: "Separate Buddies tab")).tag("tab")
                    Text(String(localized: "Sidebar in Chat Rooms tab")).tag("chatrooms")
                    Text(String(localized: "Always visible sidebar")).tag("always")
                }

                LabeledContent(String(localized: "Visible main tabs:")) {
                    VStack(alignment: .leading) {
                        ForEach(Self.visibleTabs, id: \.id) { tab in
                            Toggle(tab.title, isOn: Binding(
                                get: { preferences.draft.ui.modesVisible[tab.id] ?? true },
                                set: { preferences.draft.ui.modesVisible[tab.id] = $0 }
                            ))
                            .disabled(tab.id == "userlist" && preferences.draft.ui.buddyListInChatrooms != "tab")
                        }
                    }
                }
            }

            Section(String(localized: "Lists")) {
                Toggle(String(localized: "Show reverse file paths (requires a restart)"),
                       isOn: $preferences.draft.ui.reverseFilePaths)
                Toggle(String(localized: "Show exact file sizes (requires a restart)"), isOn: Binding(
                    get: { preferences.draft.ui.fileSizeUnit == FileSizeUnit.bytes.rawValue },
                    set: { preferences.draft.ui.fileSizeUnit = $0 ? FileSizeUnit.bytes.rawValue : "" }
                ))
                ColorField(title: String(localized: "List text color:"), hex: $preferences.draft.ui.search)
            }

            Section(String(localized: "Chats")) {
                Toggle(String(localized: "Enable colored usernames"), isOn: $preferences.draft.ui.usernameHotspots)

                Picker(String(localized: "Chat username appearance:"), selection: $preferences.draft.ui.usernameStyle) {
                    Text(String(localized: "bold")).tag("bold")
                    Text(String(localized: "italic")).tag("italic")
                    Text(String(localized: "underline")).tag("underline")
                    Text(String(localized: "normal")).tag("normal")
                }

                ColorField(title: String(localized: "Remote text color:"), hex: $preferences.draft.ui.chatRemote)
                ColorField(title: String(localized: "Local text color:"), hex: $preferences.draft.ui.chatLocal)
                ColorField(title: String(localized: "Command output text color:"),
                           hex: $preferences.draft.ui.chatCommand)
                ColorField(title: String(localized: "/me action text color:"), hex: $preferences.draft.ui.chatMe)
                ColorField(title: String(localized: "Highlighted text color:"), hex: $preferences.draft.ui.chatHighlight)
                ColorField(title: String(localized: "URL link text color:"), hex: $preferences.draft.ui.urlColor)
            }

            Section(String(localized: "User Statuses")) {
                ColorField(title: String(localized: "Online color:"), hex: $preferences.draft.ui.userOnline)
                ColorField(title: String(localized: "Away color:"), hex: $preferences.draft.ui.userAway)
                ColorField(title: String(localized: "Offline color:"), hex: $preferences.draft.ui.userOffline)
            }

            Section(String(localized: "Text Entries")) {
                ColorField(title: String(localized: "Text entry background color:"),
                           hex: $preferences.draft.ui.textBackground)
                ColorField(title: String(localized: "Text entry text color:"), hex: $preferences.draft.ui.inputColor)
            }

            Section(String(localized: "Fonts")) {
                FontField(title: String(localized: "Global font:"), fontDescription: $preferences.draft.ui.globalFont)
                FontField(title: String(localized: "List font:"), fontDescription: $preferences.draft.ui.listFont)
                FontField(title: String(localized: "Text view font:"),
                          fontDescription: $preferences.draft.ui.textViewFont)
                FontField(title: String(localized: "Chat font:"), fontDescription: $preferences.draft.ui.chatFont)
                FontField(title: String(localized: "Transfers font:"),
                          fontDescription: $preferences.draft.ui.transfersFont)
                FontField(title: String(localized: "Search font:"), fontDescription: $preferences.draft.ui.searchFont)
                FontField(title: String(localized: "Browse font:"), fontDescription: $preferences.draft.ui.browserFont)
            }
        }
    }
}

// MARK: - Shares

private struct SharesSettingsPage: View {

    @Bindable var preferences: Preferences

    var body: some View {
        PageForm {
            Section(String(localized: "Shares")) {
                descriptionText(String(localized: "Soulseek users will be able to download from your shares. Contribute to the Soulseek network by sharing your own files and by resharing what you downloaded from other users."))

                Toggle(String(localized: "Rescan shares on startup"), isOn: $preferences.draft.transfers.rescanOnStartup)
                    .help(String(localized: "Automatically rescans the contents of your shared folders on startup. If disabled, your shares are only updated when you manually initiate a rescan."))

                LabeledContent(String(localized: "Visible to everyone:")) {
                    VStack(alignment: .leading) {
                        Toggle(String(localized: "Buddy shares"), isOn: $preferences.draft.transfers.revealBuddyShares)
                        Toggle(String(localized: "Trusted shares"),
                               isOn: $preferences.draft.transfers.revealTrustedShares)
                    }
                }
            }

            Section {
                ListBox(listView: preferences.sharesListView, height: 260, buttons: [
                    .add { preferences.onAddSharedFolder() },
                    .edit { preferences.onEditSharedFolder() },
                    .remove { preferences.onRemoveSharedFolder() }
                ])
            }
        }
    }
}

// MARK: - Downloads

private struct DownloadsSettingsPage: View {

    @Bindable var preferences: Preferences

    private var isolatedMode: Bool { Application.shared.isolatedMode }

    var body: some View {
        PageForm {
            Section(String(localized: "Downloads")) {
                Toggle(String(localized: "Autoclear finished/filtered downloads from transfer list"),
                       isOn: $preferences.draft.transfers.autoClearDownloads)
                Toggle(String(localized: "Store completed downloads in username subfolders"),
                       isOn: $preferences.draft.transfers.usernameSubfolders)

                Picker(String(localized: "Double-click action for downloads:"),
                       selection: $preferences.draft.transfers.downloadDoubleClick) {
                    Text(String(localized: "Nothing")).tag(0)
                    if !isolatedMode {
                        Text(String(localized: "Open File")).tag(1)
                        Text(String(localized: "Open in File Manager")).tag(2)
                    }
                    Text(String(localized: "Search")).tag(3)
                    Text(String(localized: "Pause")).tag(4)
                    Text(String(localized: "Remove")).tag(5)
                    Text(String(localized: "Resume")).tag(6)
                    Text(String(localized: "Browse Folder")).tag(7)
                }

                HStack {
                    Toggle(String(localized: "Allow users to send you any files:"),
                           isOn: $preferences.draft.transfers.remoteDownloads)
                    Spacer()
                    Picker("", selection: $preferences.draft.transfers.uploadAllowed) {
                        Text(String(localized: "No one")).tag(0)
                        Text(String(localized: "Everyone")).tag(1)
                        Text(String(localized: "Buddies")).tag(2)
                        Text(String(localized: "Trusted buddies")).tag(3)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!preferences.draft.transfers.remoteDownloads)
                }
            }

            Section(String(localized: "Download Speed Limits")) {
                SpeedLimitPicker(
                    mode: $preferences.draft.transfers.useDownloadSpeedLimit,
                    limit: $preferences.draft.transfers.downloadLimit,
                    alternativeLimit: $preferences.draft.transfers.downloadLimitAlt,
                    unlimitedTitle: String(localized: "Unlimited download speed"),
                    limitTitle: String(localized: "Use download speed limit (KiB/s):"),
                    alternativeTitle: String(localized: "Use alternative download speed limit (KiB/s):")
                )
            }

            Section(String(localized: "Folders")) {
                FolderField(title: String(localized: "Finished downloads:"),
                            path: $preferences.draft.transfers.downloadDir,
                            defaultPath: preferences.defaults.transfers.downloadDir)
                FolderField(title: String(localized: "Incomplete downloads:"),
                            path: $preferences.draft.transfers.incompleteDir,
                            defaultPath: preferences.defaults.transfers.incompleteDir)
                FolderField(title: String(localized: "Received files:"),
                            path: $preferences.draft.transfers.uploadDir,
                            defaultPath: preferences.defaults.transfers.uploadDir)
            }

            Section(String(localized: "Events")) {
                TextField(String(localized: "Run command after file download finishes ($ for file path):"),
                          text: $preferences.draft.transfers.afterFinish)
                TextField(String(localized: "Run command after folder download finishes ($ for folder path):"),
                          text: $preferences.draft.transfers.afterFolder)
            }

            Section(String(localized: "Download Filters")) {
                Toggle(String(localized: "Enable download filters"), isOn: $preferences.draft.transfers.enableFilters)

                ListBox(listView: preferences.downloadFilterListView, buttons: [
                    .add { preferences.onAddFilter() },
                    .edit { preferences.onEditFilter() },
                    .remove { preferences.onRemoveFilter() },
                    ListBoxButton(title: String(localized: "Load Defaults"), systemImage: "arrow.uturn.backward") { preferences.onDefaultFilters() }
                ])

                HStack {
                    Button(String(localized: "Verify Filters")) { preferences.onVerifyFilter() }
                    Text(preferences.filterStatusText)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct SpeedLimitPicker: View {

    @Binding var mode: SpeedLimitMode
    @Binding var limit: Int
    @Binding var alternativeLimit: Int
    let unlimitedTitle: String
    let limitTitle: String
    let alternativeTitle: String

    var body: some View {
        RadioRow(title: unlimitedTitle, value: .unlimited, selection: $mode)
        RadioRow(title: limitTitle, value: .primary, selection: $mode) {
            NumberInput(value: $limit, range: 1...1_000_000, step: 10)
        }
        RadioRow(title: alternativeTitle, value: .alternative, selection: $mode) {
            NumberInput(value: $alternativeLimit, range: 1...1_000_000, step: 10)
        }
    }
}

// MARK: - Uploads

private struct UploadsSettingsPage: View {

    @Bindable var preferences: Preferences

    var body: some View {
        PageForm {
            Section(String(localized: "Uploads")) {
                Toggle(String(localized: "Autoclear finished/cancelled uploads from transfer list"),
                       isOn: $preferences.draft.transfers.autoClearUploads)

                Picker(String(localized: "Double-click action for uploads:"),
                       selection: $preferences.draft.transfers.uploadDoubleClick) {
                    Text(String(localized: "Nothing")).tag(0)
                    if !Application.shared.isolatedMode {
                        Text(String(localized: "Open File")).tag(1)
                        Text(String(localized: "Open in File Manager")).tag(2)
                    }
                    Text(String(localized: "Search")).tag(3)
                    Text(String(localized: "Abort")).tag(4)
                    Text(String(localized: "Remove")).tag(5)
                    Text(String(localized: "Retry")).tag(6)
                    Text(String(localized: "Browse Folder")).tag(7)
                }
            }

            Section(String(localized: "Upload Speed Limits")) {
                Picker(String(localized: "Limit upload speed:"), selection: $preferences.draft.transfers.limitBy) {
                    Text(String(localized: "Per transfer")).tag(false)
                    Text(String(localized: "Total transfers")).tag(true)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()

                SpeedLimitPicker(
                    mode: $preferences.draft.transfers.useUploadSpeedLimit,
                    limit: $preferences.draft.transfers.uploadLimit,
                    alternativeLimit: $preferences.draft.transfers.uploadLimitAlt,
                    unlimitedTitle: String(localized: "Unlimited upload speed"),
                    limitTitle: String(localized: "Use upload speed limit (KiB/s):"),
                    alternativeTitle: String(localized: "Use alternative upload speed limit (KiB/s):")
                )
            }

            Section(String(localized: "Upload Slots")) {
                Picker(String(localized: "Upload queue type:"), selection: $preferences.draft.transfers.fifoQueue) {
                    Text(String(localized: "Round Robin")).tag(false)
                    Text(String(localized: "First In, First Out")).tag(true)
                }
                .help(String(localized: "Round Robin: Files will be uploaded in cyclical fashion to the users waiting in queue.\nFirst In, First Out: Files will be uploaded in the order they were queued."))

                RadioRow(title: String(localized: "Allocate upload slots until total speed reaches (KiB/s):"),
                         value: false, selection: $preferences.draft.transfers.useUploadSlots) {
                    NumberInput(value: $preferences.draft.transfers.uploadBandwidth, range: 0...1_000_000, step: 10)
                }
                RadioRow(title: String(localized: "Fixed number of upload slots:"),
                         value: true, selection: $preferences.draft.transfers.useUploadSlots) {
                    NumberInput(value: $preferences.draft.transfers.uploadSlots, range: 1...1_000_000)
                }

                Toggle(String(localized: "Prioritize all buddies"), isOn: $preferences.draft.transfers.preferFriends)
            }

            Section(String(localized: "Queue Limits")) {
                NumberField(title: String(localized: "Maximum number of queued files per user:"),
                            value: $preferences.draft.transfers.fileLimit, range: 0...1_000_000, step: 10)
                NumberField(title: String(localized: "Maximum total size of queued files per user (MiB):"),
                            value: $preferences.draft.transfers.queueLimit, range: 0...1_000_000, step: 25)
                Toggle(String(localized: "Limits do not apply to buddies"),
                       isOn: $preferences.draft.transfers.friendsNoLimits)
            }
        }
    }
}

// MARK: - Searches

private struct SearchesSettingsPage: View {

    @Bindable var preferences: Preferences
    @State private var isFilterHelpShown = false

    var body: some View {
        PageForm {
            Section(String(localized: "Searches")) {
                HStack {
                    Toggle(String(localized: "Enable search history"), isOn: $preferences.draft.searches.enableHistory)
                    Spacer()
                    Button(String(localized: "Clear Search History")) { preferences.onClearSearchHistory() }
                        .disabled(preferences.isSearchHistoryCleared)
                }

                Toggle(String(localized: "Show privately shared files in search results"),
                       isOn: $preferences.draft.searches.privateSearchResults)
                    .help(String(localized: "Privately shared files that have been made visible to everyone will be prefixed with '[PRIVATE]', and cannot be downloaded until the uploader gives explicit permission. Ask them kindly."))

                NumberField(title: String(localized: "Limit number of results per search:"),
                            value: $preferences.draft.searches.maxDisplayedResults, range: 100...25000, step: 50)
            }

            Section {
                Toggle(String(localized: "Enable search result filters by default"),
                       isOn: $preferences.draft.searches.enableFilters)

                filterField(String(localized: "Include:"), $preferences.draft.searches.defaultFilters.include,
                            String(localized: "Filter in results whose file paths contain the specified text. Multiple phrases and words can be specified, e.g. exact phrase|music|term|exact phrase two"))
                filterField(String(localized: "Exclude:"), $preferences.draft.searches.defaultFilters.exclude,
                            String(localized: "Filter out results whose file paths contain the specified text. Multiple phrases and words can be specified, e.g. exact phrase|music|term|exact phrase two"))
                filterField(String(localized: "File Type:"), $preferences.draft.searches.defaultFilters.fileType,
                            String(localized: "File type, e.g. flac wav or !mp3 !m4a"))
                filterField(String(localized: "Size:"), $preferences.draft.searches.defaultFilters.size,
                            String(localized: "File size, e.g. >10.5m <1g"))
                filterField(String(localized: "Bitrate:"), $preferences.draft.searches.defaultFilters.bitrate,
                            String(localized: "Bitrate, e.g. 256 <1412"))
                filterField(String(localized: "Duration:"), $preferences.draft.searches.defaultFilters.length,
                            String(localized: "Duration, e.g. >6:00 <12:00 !6:54"))
                filterField(String(localized: "Country Code:"), $preferences.draft.searches.defaultFilters.country,
                            String(localized: "Country code, e.g. US ES or !DE !GB"))

                Toggle(String(localized: "Free Slot"), isOn: $preferences.draft.searches.defaultFilters.freeSlot)
                    .help(String(localized: "Only show results from users with an available upload slot."))

                HStack {
                    Spacer()
                    Button(String(localized: "Clear Filter History")) { preferences.onClearFilterHistory() }
                        .disabled(preferences.isFilterHistoryCleared)
                }
            } header: {
                HStack {
                    Text(String(localized: "Search Result Filters"))
                    Button {
                        isFilterHelpShown.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Result Filter Help"))
                    .popover(isPresented: $isFilterHelpShown) {
                        SearchFilterHelp()
                    }
                }
            }

            Section(String(localized: "Network Searches")) {
                Toggle(String(localized: "Respond to search requests from other users"),
                       isOn: $preferences.draft.searches.searchResults)
                NumberField(title: String(localized: "Searches shorter than this number of characters will be ignored:"),
                            value: $preferences.draft.searches.minSearchCharacters, range: 0...50)
                NumberField(title: String(localized: "Maximum search results to send per search request:"),
                            value: $preferences.draft.searches.maxResults, range: 50...10000, step: 25)
            }
        }
    }

    private func filterField(_ title: String, _ text: Binding<String>, _ tooltip: String) -> some View {
        TextField(title, text: text)
            .help(tooltip)
    }
}

// MARK: - User Profile

private struct UserProfileSettingsPage: View {

    @Bindable var preferences: Preferences

    var body: some View {
        PageForm {
            Section(String(localized: "Self Description")) {
                descriptionText(String(localized: "Add things you want everyone to see, such as a short description, helpful tips, or guidelines for downloading your shares."))

                TextEditor(text: $preferences.draft.userInfo.description)
                    .font(.body)
                    .frame(minHeight: 200)
            }

            Section {
                LabeledContent(String(localized: "Picture:")) {
                    HStack(spacing: 6) {
                        FileChooserButton(path: $preferences.draft.userInfo.picture, chooserType: .image,
                                          showsOpenButton: !Application.shared.isolatedMode)
                            .frame(maxWidth: 320)
                        Button(String(localized: "Reset Picture")) {
                            preferences.draft.userInfo.picture = ""
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Chats

private struct ChatsSettingsPage: View {

    @Bindable var preferences: Preferences

    var body: some View {
        PageForm {
            Section(String(localized: "Chats")) {
                Toggle(String(localized: "Accept private room invitations"),
                       isOn: $preferences.draft.server.privateChatrooms)
                Toggle(String(localized: "Restore previously open private chats on startup"),
                       isOn: $preferences.draft.privateChat.store)
                Toggle(String(localized: "Enable spell checker"), isOn: $preferences.draft.ui.spellCheck)
                Toggle(String(localized: "Enable CTCP-like private message responses (client version)"),
                       isOn: $preferences.isCTCPEnabled)
                NumberField(title: String(localized: "Number of recent private chat messages to show:"),
                            value: $preferences.draft.logging.readPrivateLines, range: 0...10000, step: 50)
                NumberField(title: String(localized: "Number of recent chat room messages to show:"),
                            value: $preferences.draft.logging.readRoomLines, range: 0...10000, step: 50)
            }

            Section(String(localized: "Chat Completion")) {
                Toggle(String(localized: "Enable tab-key completion"), isOn: $preferences.draft.words.tab)
                Toggle(String(localized: "Enable completion drop-down list"), isOn: $preferences.draft.words.dropdown)
                NumberField(title: String(localized: "Minimum characters required to display drop-down:"),
                            value: $preferences.draft.words.characters, range: 1...10)

                LabeledContent(String(localized: "Allowed chat completions:")) {
                    VStack(alignment: .leading) {
                        Toggle(String(localized: "Buddy names"), isOn: $preferences.draft.words.buddies)
                        Toggle(String(localized: "Chat room usernames"), isOn: $preferences.draft.words.roomUsers)
                        Toggle(String(localized: "Room names"), isOn: $preferences.draft.words.roomNames)
                        Toggle(String(localized: "Commands"), isOn: $preferences.draft.words.commands)
                    }
                }
            }

            Section(String(localized: "Timestamps")) {
                TextField(String(localized: "Private chat format:"), text: $preferences.draft.logging.privateTimestamp)
                TextField(String(localized: "Chat room format:"), text: $preferences.draft.logging.roomsTimestamp)
                FormatCodesLink()
            }

            Section(String(localized: "Text-to-Speech")) {
                Toggle(String(localized: "Enable Text-to-Speech"), isOn: $preferences.draft.ui.speechEnabled)

                LabeledContent(String(localized: "Text-to-Speech command:")) {
                    ComboBox(placeholder: "", text: $preferences.draft.ui.speechCommand,
                             items: ["flite -t $", "echo $ | festival --tts"])
                        .frame(maxWidth: 260)
                }

                TextField(String(localized: "Private chat message:"), text: $preferences.draft.ui.speechPrivate)
                TextField(String(localized: "Chat room message:"), text: $preferences.draft.ui.speechRooms)
            }

            Section(String(localized: "Censor")) {
                Toggle(String(localized: "Enable censoring of text patterns"),
                       isOn: $preferences.draft.words.censorWords)

                ListBox(listView: preferences.censorListView, height: 150, buttons: [
                    .add { preferences.onAddCensored() },
                    .edit { preferences.onEditCensored() },
                    .remove { preferences.onRemoveCensored() }
                ])
            }

            Section(String(localized: "Auto-Replace")) {
                Toggle(String(localized: "Enable automatic replacement of words"),
                       isOn: $preferences.draft.words.replaceWords)

                ListBox(listView: preferences.replacementListView, height: 150, buttons: [
                    .add { preferences.onAddReplacement() },
                    .edit { preferences.onEditReplacement() },
                    .remove { preferences.onRemoveReplacement() }
                ])
            }
        }
    }
}

private struct FormatCodesLink: View {

    var body: some View {
        Link(String(localized: "Format codes"), destination: URL(string: Preferences.formatCodesURL)!)
    }
}

// MARK: - Now Playing

private struct NowPlayingSettingsPage: View {

    @Bindable var preferences: Preferences

    private var formats: [String] {
        Preferences.defaultNowPlayingFormats + preferences.draft.players.npFormatList
    }

    var body: some View {
        let player = preferences.draft.players.npPlayer

        PageForm {
            Section(String(localized: "Now Playing")) {
                descriptionText(String(localized: "Now Playing allows you to display what your media player is playing by using the /now command in chat."))

                Picker("", selection: $preferences.draft.players.npPlayer) {
                    Text(verbatim: "Last.fm").tag("lastfm")
                    Text(verbatim: "ListenBrainz").tag("listenbrainz")
                    Text(String(localized: "Other")).tag("other")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                TextField(preferences.nowPlayingCommandLabel(for: player),
                          text: $preferences.draft.players.npOtherCommand)
            }

            Section(String(localized: "Now Playing Format")) {
                LabeledContent(String(localized: "Now Playing message format:")) {
                    ComboBox(placeholder: "", text: $preferences.draft.players.npFormat, items: formats)
                        .frame(maxWidth: 320)
                }

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    ForEach(preferences.nowPlayingReplacers(for: player), id: \.0) { item, label in
                        GridRow {
                            Text(verbatim: item)
                                .font(.system(.body, design: .monospaced))
                            Text(label)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Button(String(localized: "Test Configuration")) { preferences.onTestNowPlaying() }
                    Text(preferences.nowPlayingOutput)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Logging

private struct LoggingSettingsPage: View {

    @Bindable var preferences: Preferences

    var body: some View {
        PageForm {
            Section(String(localized: "Logging")) {
                Toggle(String(localized: "Log chatrooms by default"), isOn: $preferences.draft.logging.chatrooms)
                Toggle(String(localized: "Log private chat by default"), isOn: $preferences.draft.logging.privateChat)
                Toggle(String(localized: "Log transfers to file"), isOn: $preferences.draft.logging.transfers)
                Toggle(String(localized: "Log debug messages to file"),
                       isOn: $preferences.draft.logging.debugFileOutput)
                TextField(String(localized: "Log timestamp format:"), text: $preferences.draft.logging.logTimestamp)
                FormatCodesLink()
            }

            Section(String(localized: "Folder Locations")) {
                FolderField(title: String(localized: "Chatroom logs folder:"),
                            path: $preferences.draft.logging.roomLogsDir,
                            defaultPath: preferences.defaults.logging.roomLogsDir)
                FolderField(title: String(localized: "Private chat logs folder:"),
                            path: $preferences.draft.logging.privateLogsDir,
                            defaultPath: preferences.defaults.logging.privateLogsDir)
                FolderField(title: String(localized: "Transfer logs folder:"),
                            path: $preferences.draft.logging.transfersLogsDir,
                            defaultPath: preferences.defaults.logging.transfersLogsDir)
                FolderField(title: String(localized: "Debug logs folder:"),
                            path: $preferences.draft.logging.debugLogsDir,
                            defaultPath: preferences.defaults.logging.debugLogsDir)
            }
        }
    }
}

// MARK: - Banned and Ignored Users

private struct BannedUsersSettingsPage: View {

    @Bindable var preferences: Preferences

    var body: some View {
        PageForm {
            Section(String(localized: "Banned Users")) {
                descriptionText(String(localized: "Prohibit users from accessing your shared files, based on username, IP address or country."))

                HStack {
                    Toggle(String(localized: "Country codes to block (comma separated):"),
                           isOn: $preferences.draft.transfers.geoBlock)
                    TextField("", text: $preferences.geoBlockCountryCodes)
                        .labelsHidden()
                        .help(String(localized: "Codes must be in ISO 3166-2 format."))
                }

                HStack {
                    Toggle(String(localized: "Use custom geo block message:"),
                           isOn: $preferences.draft.transfers.useCustomGeoBlock)
                    TextField("", text: $preferences.draft.transfers.customGeoBlock)
                        .labelsHidden()
                }

                HStack {
                    Toggle(String(localized: "Use custom ban message:"),
                           isOn: $preferences.draft.transfers.useCustomBan)
                    TextField("", text: $preferences.draft.transfers.customBan)
                        .labelsHidden()
                }
            }

            Section(String(localized: "Users")) {
                ListBox(listView: preferences.bannedUsersListView, height: 150, buttons: [
                    .add { preferences.onAddBannedUser() },
                    .remove { preferences.onRemoveBannedUser() }
                ])
            }

            Section(String(localized: "IP Addresses")) {
                ListBox(listView: preferences.bannedIPsListView, height: 150, buttons: [
                    .add { preferences.onAddBannedIP() },
                    .remove { preferences.onRemoveBannedIP() }
                ])
            }
        }
    }
}

private struct IgnoredUsersSettingsPage: View {

    let preferences: Preferences

    var body: some View {
        PageForm {
            Section(String(localized: "Ignored Users")) {
                descriptionText(String(localized: "Ignore chat messages and search results from users, based on username or IP address."))
            }

            Section(String(localized: "Users")) {
                ListBox(listView: preferences.ignoredUsersListView, height: 150, buttons: [
                    .add { preferences.onAddIgnoredUser() },
                    .remove { preferences.onRemoveIgnoredUser() }
                ])
            }

            Section(String(localized: "IP Addresses")) {
                ListBox(listView: preferences.ignoredIPsListView, height: 150, buttons: [
                    .add { preferences.onAddIgnoredIP() },
                    .remove { preferences.onRemoveIgnoredIP() }
                ])
            }
        }
    }
}

// MARK: - URL Handlers

private struct URLHandlersSettingsPage: View {

    @Bindable var preferences: Preferences

    var body: some View {
        PageForm {
            Section(String(localized: "URL Handlers")) {
                descriptionText(String(localized: "Instances of $ are replaced by the URL. Default system applications are used in cases where a protocol has not been configured."))

                LabeledContent(String(localized: "File manager command:")) {
                    ComboBox(placeholder: "", text: $preferences.draft.ui.fileManager,
                             items: Preferences.fileManagerCommands)
                        .frame(maxWidth: 260)
                }
            }

            Section {
                ListBox(listView: preferences.protocolListView, height: 260, buttons: [
                    .add { preferences.onAddHandler() },
                    .edit { preferences.onEditHandler() },
                    .remove { preferences.onRemoveHandler() }
                ])
            }
        }
    }
}

// MARK: - Plugins

private struct PluginsSettingsPage: View {

    @Bindable var preferences: Preferences

    var body: some View {
        PageForm {
            Section(String(localized: "Plugins")) {
                Toggle(String(localized: "Enable plugins"), isOn: Binding(
                    get: { preferences.draft.plugins.enable },
                    set: {
                        preferences.draft.plugins.enable = $0
                        preferences.onEnablePlugins($0)
                    }
                ))

                preferences.pluginListView.view
                    .frame(height: 180)
                    .disabled(!preferences.draft.plugins.enable)
            }

            Section {
                HStack {
                    Text(preferences.selectedPluginInfo?.name ?? preferences.selectedPlugin
                         ?? String(localized: "No Plugin Selected"))
                        .font(.headline)
                    Spacer()
                    Button(String(localized: "Settings")) { preferences.onPluginSettings() }
                        .disabled(!preferences.isPluginSettingsEnabled)
                }

                LabeledContent(String(localized: "Version:"), value: preferences.selectedPluginInfo?.version ?? "-")
                LabeledContent(String(localized: "Created by:"),
                               value: preferences.selectedPluginInfo?.authors.joined(separator: ", ") ?? "-")

                preferences.pluginDescriptionView.view
                    .frame(height: 150)
            }
        }
    }
}

// MARK: - Font Chooser

/// Shows the system font panel, and reports the selected font.
@MainActor
private final class FontChooser: NSObject, NSFontChanging {

    static let shared = FontChooser()

    private var currentFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private var completion: (@MainActor (NSFont) -> Void)?

    func choose(initialFont: NSFont, completion: @escaping @MainActor (NSFont) -> Void) {
        let fontManager = NSFontManager.shared

        currentFont = initialFont
        self.completion = completion

        fontManager.target = self
        fontManager.setSelectedFont(initialFont, isMultiple: false)
        fontManager.orderFrontFontPanel(nil)
    }

    func changeFont(_ sender: NSFontManager?) {
        guard let sender else {
            return
        }

        currentFont = sender.convert(currentFont)
        completion?(currentFont)
    }

    func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.face, .size, .collection]
    }
}
