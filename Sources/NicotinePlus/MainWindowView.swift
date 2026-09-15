// SPDX-License-Identifier: GPL-3.0-or-later

import NicotineCore
import SwiftUI

/// Content of the main window: page list, current page, log pane and status bar.
struct MainWindowView: View {

    @Bindable var mainWindow: MainWindow

    var body: some View {
        NavigationSplitView {
            PageList(mainWindow: mainWindow)
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
        } detail: {
            VStack(spacing: 0) {
                VSplitView {
                    HStack(spacing: 0) {
                        currentPageView
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if config.ui.buddyListInChatrooms == "always" {
                            Divider()
                            mainWindow.buddies.content
                                .frame(minWidth: 200, idealWidth: 250, maxWidth: 400)
                        }
                    }
                    .frame(minHeight: 200)
                    .layoutPriority(1)

                    if mainWindow.isLogPaneVisible {
                        mainWindow.logView.view
                            .frame(minHeight: 60, idealHeight: 140)
                    }
                }

                Divider()
                StatusBar(mainWindow: mainWindow)
            }
        }
        .navigationTitle("")
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
            ForEach(mainWindow.orderedVisiblePages) { page in
                Label {
                    Text(page.title)
                        .fontWeight(mainWindow.highlightedPages[page] != nil ? .bold : .regular)
                } icon: {
                    Image(systemName: page.systemImage)
                }
                .badge(badge(for: page))
                .tag(page)
            }
            .onMove { source, destination in
                mainWindow.movePages(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.sidebar)
    }

    private func badge(for page: MainWindow.Page) -> Text? {
        guard let isImportant = mainWindow.highlightedPages[page] else {
            return nil
        }

        let colorID = isImportant ? "tabhilite" : "tabchanged"
        let color = Color(nsColor: Theme.color(forID: colorID) ?? .controlAccentColor)

        return Text(Image(systemName: isImportant ? "exclamationmark.circle.fill" : "circle.fill"))
            .foregroundStyle(color)
    }
}

// MARK: - Status Bar

private struct StatusBar: View {

    @Bindable var mainWindow: MainWindow
    @State private var isDownloadSpeedsShown = false
    @State private var isUploadSpeedsShown = false

    var body: some View {
        HStack(spacing: 12) {
            Text(mainWindow.statusText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(mainWindow.statusText)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let scanProgressText = mainWindow.scanProgressText {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text(scanProgressText)
                }
                .help(scanProgressText)
            }

            Button {
                Application.shared.onTransferStatistics()
            } label: {
                Label(mainWindow.connectionsText, systemImage: "network")
            }
            .help(String(localized: "Connections"))

            Button {
                isDownloadSpeedsShown.toggle()
            } label: {
                Label(mainWindow.downloadStatusText, systemImage: "arrow.down")
            }
            .help(String(localized: "Downloading (Speed / Active Users)"))
            .popover(isPresented: $isDownloadSpeedsShown) {
                TransferSpeedsView(direction: .download)
            }

            Button {
                isUploadSpeedsShown.toggle()
            } label: {
                Label(mainWindow.uploadStatusText, systemImage: "arrow.up")
            }
            .help(String(localized: "Uploading (Speed / Active Users)"))
            .popover(isPresented: $isUploadSpeedsShown) {
                TransferSpeedsView(direction: .upload)
            }

            Button {
                mainWindow.onToggleStatus()
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(nsColor: Theme.color(forID: Theme.userStatusColorID(mainWindow.userStatus))
                                    ?? .secondaryLabelColor))
                        .frame(width: 8, height: 8)
                    Text(mainWindow.userStatusText)
                }
            }
            .help(mainWindow.userStatusUsername ?? "")

            Toggle(isOn: $mainWindow.isLogPaneVisible) {
                Image(systemName: "text.alignleft")
            }
            .toggleStyle(.button)
            .help(String(localized: "Show Log Pane"))
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
