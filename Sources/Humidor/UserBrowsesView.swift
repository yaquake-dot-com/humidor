// SPDX-License-Identifier: GPL-3.0-or-later

import HumidorCore
import SwiftUI

/// Browse shares page.
struct UserBrowsesView: View {

    @Bindable var page: UserBrowsesPage

    private var hasTabs: Bool { !page.notebook.pages.isEmpty }

    private var entryBar: some View {
        HStack(spacing: 6) {
            SearchField(placeholder: String(localized: "Username…"), text: $page.usernameText,
                        recentTitle: String(localized: "Buddies"), recentItems: page.window.buddyUsernames, completions: page.window.buddyUsernames, focusRequest: page.usernameFocusRequest) {
                page.onGetShares()
            }

            Button {
                page.onGetShares()
            } label: {
                Image(systemName: "folder.badge.person.crop")
            }
            .help(String(localized: "Browse Shares"))
        }
    }

    var body: some View {
        Group {
            if hasTabs {
                NotebookView(notebook: page.notebook)
            } else {
                PageStart(
                    systemImage: "folder",
                    title: String(localized: "Browse Shares"),
                    description: String(localized: "Enter the name of a user, whose shared files you'd like to browse. You can also save the list to disk, and inspect it later on."),
                    recentTitle: String(localized: "Buddies"),
                    recentItems: page.window.buddyUsernames,
                    onSelectItem: { username in
                        page.usernameText = username
                        page.onGetShares()
                    }
                ) {
                    entryBar
                }
            }
        }
        .toolbar {
            if hasTabs {
                ToolbarItem(placement: .navigation) {
                    entryBar
                        .frame(minWidth: 220, idealWidth: 300, maxWidth: 400)
                }
            }

            ToolbarItemGroup {
                Button {
                    Application.shared.onLoadSharesFromDisk()
                } label: {
                    Label(String(localized: "Open List"), systemImage: "doc.badge.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .help(String(localized: "Opens a local list of shared files that was previously saved to disk"))

                Button {
                    Application.shared.onConfigureShares()
                } label: {
                    Label(String(localized: "Configure Shares"), systemImage: "gearshape")
                }
                .help(String(localized: "Configure Shares"))
            }
        }
    }
}

/// Shared files of a single user.
struct UserBrowseTabView: View {

    @Bindable var tab: UserBrowseTab

    var body: some View {
        VStack(spacing: 0) {
            header

            if tab.isSearchVisible {
                Divider()
                searchBar
            }

            if let infoMessage = tab.infoMessage {
                InfoBar(message: infoMessage.text, messageType: infoMessage.type,
                        buttonLabel: tab.isRetryVisible ? String(localized: "Retry") : nil,
                        buttonAction: tab.isRetryVisible ? { tab.onRefresh() } : nil)
            }

            Divider()

            HSplitView {
                tab.folderTreeView.view
                    .frame(minWidth: 240, idealWidth: 300)

                VStack(spacing: 0) {
                    pathBar
                    Divider()
                    tab.fileListView.view
                }
                .frame(minWidth: 250)
                .layoutPriority(1)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(tab.numFoldersText, systemImage: "folder")
                .help(String(localized: "Folders"))

            Label(tab.shareSizeText, systemImage: "internaldrive")

            if tab.isProgressVisible {
                if let progress = tab.progress {
                    ProgressView(value: progress)
                        .frame(maxWidth: 200)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 200)
                }
            }

            Spacer()

            Toggle(isOn: $tab.isExpanded) {
                Image(systemName: tab.isExpanded
                      ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .toggleStyle(.button)
            .help(String(localized: "Expand / Collapse All"))

            Toggle(isOn: $tab.isSearchVisible) {
                Image(systemName: "magnifyingglass")
            }
            .toggleStyle(.button)
            .help(String(localized: "Search Files"))

            Button {
                tab.onSave()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(!tab.isSaveEnabled)
            .help(String(localized: "Save Shares List to Disk"))

            Button {
                tab.onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!tab.isRefreshEnabled)
            .help(String(localized: "Refresh Files"))
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var searchBar: some View {
        ComboBox(
            placeholder: String(localized: "Search Files"),
            text: Binding(get: { tab.searchText }, set: { tab.searchText = $0; tab.onSearchEntryChanged() }),
            focusRequest: tab.searchFocusRequest,
            onSubmit: { tab.findSearchMatches() }
        )
        .onKeyPress(.upArrow) {
            _ = tab.onSearchPreviousAccelerator()
            return .handled
        }
        .onKeyPress(.downArrow) {
            _ = tab.onSearchNextAccelerator()
            return .handled
        }
        .onExitCommand {
            tab.isSearchVisible = false
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var pathBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(tab.pathComponents.enumerated()), id: \.offset) { index, folder in
                        if index > 0 {
                            Text("\\")
                                .foregroundStyle(.secondary)
                                .fontWeight(.semibold)
                        }

                        let isLast = (index == tab.pathComponents.count - 1)
                        let label = folder.count > 10 && !isLast ? String(folder.prefix(10)) + "…" : folder

                        Button {
                            if isLast {
                                tab.folderPopupMenu.popupAtMouseLocation()
                            } else {
                                tab.onPathBarClicked(index)
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Text(label)
                                    .fontWeight(isLast ? .semibold : .regular)

                                if isLast {
                                    Image(systemName: "chevron.down")
                                        .font(.caption2)
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                        .help(folder)
                        .id(index)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
            }
            .onChange(of: tab.pathComponents) {
                proxy.scrollTo(tab.pathComponents.count - 1, anchor: .trailing)
            }
        }
    }
}
