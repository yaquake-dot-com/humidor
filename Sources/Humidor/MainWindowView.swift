// SPDX-License-Identifier: GPL-3.0-or-later

import HumidorCore
import SwiftUI

/// Content of the main window: page list, current page, log pane and status bar.
struct MainWindowView: View {

    @Bindable var mainWindow: MainWindow

    @Bindable private var fastConfigure: FastConfigure

    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    init(mainWindow: MainWindow) {
        self.mainWindow = mainWindow
        fastConfigure = mainWindow.application.fastConfigure
    }

    var body: some View {
        NavigationSplitView {
            PageList(mainWindow: mainWindow)
                .navigationSplitViewColumnWidth(190)
        } detail: {
            VStack(spacing: 0) {
                SplitPane("Log", edge: .bottom, range: 60...600, idealLength: 140,
                          isPaneVisible: mainWindow.isLogPaneVisible) {
                    pageArea
                } pane: {
                    mainWindow.logView.view
                }

            }
        }
        .frame(minWidth: 700, minHeight: 450)
        .sheet(isPresented: $fastConfigure.isPresented) {
            FastConfigureView(assistant: fastConfigure)
                .presentationHost("setup-assistant")
                .frame(width: 720, height: 450)
        }
        // The title stays in the Window menu and Mission Control, but not in the toolbar
        .toolbar(removing: .title)
        .onAppear {
            let application = mainWindow.application
            application.openWindowAction = openWindow
            application.dismissWindowAction = dismissWindow
            application.openSettingsAction = openSettings
            mainWindow.onWindowOpenChanged(true)
        }
        .onDisappear {
            mainWindow.onWindowOpenChanged(false)
        }
        .onChange(of: appearsActive, initial: true) {
            mainWindow.onWindowActiveChanged(appearsActive)
        }
    }

    private var pageArea: some View {
        SplitPane("Buddies", edge: .trailing, range: 200...600, idealLength: 250,
                  isPaneVisible: mainWindow.buddies.position == "always") {
            currentPageView
        } pane: {
            mainWindow.buddies.content
        }
    }

    @ViewBuilder private var currentPageView: some View {
        switch mainWindow.currentPage {
        case .search: SearchesView(page: mainWindow.search)
        case .downloads: TransfersView(page: mainWindow.downloads)
        case .uploads: TransfersView(page: mainWindow.uploads)
        case .userbrowse: UserBrowsesView(page: mainWindow.userBrowse)
        case .userinfo: UserInfosView(page: mainWindow.userInfo)
        case .private: PrivateChatsView(page: mainWindow.privateChat)
        case .userlist: mainWindow.buddies.pageContent
        case .chatrooms: ChatRoomsView(page: mainWindow.chatrooms)
        case .interests: InterestsView(page: mainWindow.interests)
        }
    }
}

// MARK: - Page List

private struct PageList: View {

    @Bindable var mainWindow: MainWindow

    var body: some View {
        let selection = Binding<MainWindow.Page?>(
            get: { mainWindow.currentPage },
            set: { page in
                if let page {
                    mainWindow.setCurrentPage(page)
                }
            }
        )

        List(selection: selection) {
            ForEach(MainWindow.Section.allCases) { section in
                let pages = mainWindow.visiblePages(in: section)

                if !pages.isEmpty {
                    Section {
                        ForEach(pages) { page in
                            row(for: page)
                                .listRowBackground(selectionBackground(for: page))
                                .tag(page)
                        }
                        .onMove { source, destination in
                            mainWindow.movePages(in: section, fromOffsets: source, toOffset: destination)
                        }
                    } header: {
                        if let title = section.title {
                            Text(title)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarStatus(mainWindow: mainWindow)
        }
    }

    /// The list dims its selection when the keyboard focus moves to another view, but the page
    /// stays open, so the current page keeps the colors of a selected row
    @ViewBuilder private func row(for page: MainWindow.Page) -> some View {
        let isCurrent = page == mainWindow.currentPage
        let label = Label {
            Text(page.title)
        } icon: {
            Image(systemName: page.systemImage)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .badge(badge(for: page))

        if isCurrent {
            label.foregroundStyle(.white)
        } else {
            label
        }
    }

    /// The highlight of a selected row, drawn above the one of the list
    @ViewBuilder private func selectionBackground(for page: MainWindow.Page) -> some View {
        if page == mainWindow.currentPage {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor)
                .padding(.horizontal, 10)
        }
    }

    /// Number of unread conversations or mentions, or a dot for other changes
    private func badge(for page: MainWindow.Page) -> Text? {
        guard let isImportant = mainWindow.highlightedPages[page] else {
            return nil
        }

        let count = switch page {
        case .private: mainWindow.privateChat.highlightedUsers.count
        case .chatrooms: mainWindow.chatrooms.highlightedRooms.count
        default: 0
        }

        if count > 0 {
            return Text(humanize(count))
        }

        let color = Color(nsColor: Theme.color(forID: isImportant ? "tabhilite" : "tabchanged") ?? .controlAccentColor)

        return Text(Image(systemName: isImportant ? "exclamationmark.circle.fill" : "circle.fill"))
            .foregroundStyle(color)
    }
}

// MARK: - Status

/// Connection status and transfer speeds, at the bottom of the sidebar.
private struct SidebarStatus: View {

    @Bindable var mainWindow: MainWindow
    @State private var isDownloadSpeedsShown = false
    @State private var isUploadSpeedsShown = false

    private var statusColor: Color {
        switch mainWindow.userStatus {
        case .online: .green
        case .away: .yellow
        case .offline: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let scanProgressText = mainWindow.scanProgressText {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(scanProgressText)
                        .lineLimit(1)
                }
                .help(scanProgressText)
            }

            HStack(spacing: 8) {
                Button {
                    mainWindow.onToggleStatus()
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(mainWindow.userStatusText)
                    }
                }
                .help(mainWindow.userStatusUsername ?? "")

                Spacer(minLength: 0)

                // Numbers keep their width, the status is shortened when space runs out
                Button {
                    AppDelegate.shared.onTransferStatistics()
                } label: {
                    Label(mainWindow.connectionsText, systemImage: "network")
                        .monospacedDigit()
                }
                .fixedSize()
                .help(String(localized: "Connections"))

                Toggle(isOn: $mainWindow.isLogPaneVisible) {
                    Image(systemName: "text.alignleft")
                }
                .toggleStyle(.button)
                .fixedSize()
                .help(String(localized: "Show Log Pane"))
            }

            SpeedMeter(symbolName: "arrow.down", speed: mainWindow.downloadSpeed, color: .blue,
                       isLimitAlternative: mainWindow.isDownloadLimitAlternative) {
                isDownloadSpeedsShown.toggle()
            }
            .help(speedTooltip(String(localized: "Downloading (Speed / Active Users)"),
                               speed: mainWindow.downloadSpeed, userCount: mainWindow.downloadUserCount))
            .popover(isPresented: $isDownloadSpeedsShown) {
                TransferSpeedsView(direction: .download)
            }

            SpeedMeter(symbolName: "arrow.up", speed: mainWindow.uploadSpeed, color: .green,
                       isLimitAlternative: mainWindow.isUploadLimitAlternative) {
                isUploadSpeedsShown.toggle()
            }
            .help(speedTooltip(String(localized: "Uploading (Speed / Active Users)"),
                               speed: mainWindow.uploadSpeed, userCount: mainWindow.uploadUserCount))
            .popover(isPresented: $isUploadSpeedsShown) {
                TransferSpeedsView(direction: .upload)
            }
        }
        .lineLimit(1)
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func speedTooltip(_ title: String, speed: Int, userCount: Int) -> String {
        "\(title)\n\(humanSpeed(speed)) / \(humanize(userCount))"
    }
}

/// A transfer speed, and its level on a row of segments. Speeds range from a few kilobytes to tens
/// of megabytes a second, so each segment stands for four times the speed of the one before.
private struct SpeedMeter: View {

    let symbolName: String
    let speed: Int
    let color: Color
    /// Whether the alternative speed limit is in use, shown by underlining the speed
    let isLimitAlternative: Bool
    let action: () -> Void

    /// Speeds lighting each segment: 1 KB/s, 4 KB/s, 16 KB/s … 16 MB/s
    private static let levels = (0..<8).map { 1000 << (2 * $0) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .foregroundStyle(color)

                Text(humanSpeed(speed))
                    .monospacedDigit()
                    .underline(isLimitAlternative)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                HStack(spacing: 2) {
                    ForEach(Self.levels, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(speed >= level ? AnyShapeStyle(color) : AnyShapeStyle(.quaternary))
                            .frame(width: 5, height: 11)
                    }
                }
            }
            .contentShape(.rect)
        }
    }
}
