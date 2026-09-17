// SPDX-License-Identifier: GPL-3.0-or-later

import HumidorCore
import SwiftUI

/// Search files page.
struct SearchesView: View {

    @Bindable var page: SearchesPage

    private var hasSearches: Bool { !page.notebook.pages.isEmpty }

    var body: some View {
        Group {
            if hasSearches {
                NotebookView(notebook: page.notebook)
            } else {
                PageStart(
                    systemImage: "magnifyingglass",
                    title: String(localized: "Search Files"),
                    description: String(localized: "Enter a search term to search for files shared by other users on the Soulseek network"),
                    recentItems: page.searchHistory,
                    onSelectItem: { term in
                        page.searchText = term
                        page.onSearch()
                    }
                ) {
                    searchBar
                }
            }
        }
        .toolbar {
            if hasSearches {
                ToolbarItem(placement: .navigation) {
                    searchBar
                        .environment(\.searchFieldHasBackground, false)
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 420)
                }
            }

            ToolbarItem {
                Button {
                    AppDelegate.shared.onWishlist()
                } label: {
                    Label(String(localized: "Wishlist"), systemImage: "list.star")
                        .labelStyle(.titleAndIcon)
                }

            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            scopeMenu

            SearchField(
                placeholder: String(localized: "Search term…"),
                text: $page.searchText,
                recentItems: page.searchHistory,
                tooltip: String(localized: "Search patterns: with a word = term, without a word = -term, partial word = *erm"),
                focusRequest: page.searchEntryFocusRequest
            ) {
                page.onSearch()
            }
        }
        .disabled(!page.isSearchEnabled)
    }

    private var scopeMenu: some View {
        HStack(spacing: 6) {
            Menu(page.searchModeLabel) {
                Picker(String(localized: "Search Scope"),
                       selection: Binding(get: { page.searchMode }, set: { page.setSearchMode($0) })) {
                    ForEach(SearchesPage.modes, id: \.0) { mode, label in
                        Text(label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .fixedSize()
            .help(String(localized: "Search Scope"))

            if page.searchMode == .rooms {
                SearchField(placeholder: String(localized: "Room…"), text: $page.roomSearchText,
                            recentItems: page.roomSearchItems, completions: page.roomSearchItems) {
                    page.onSearch()
                }
                .frame(width: 140)
            }

            if page.searchMode == .user {
                SearchField(placeholder: String(localized: "Username…"), text: $page.userSearchText,
                            recentItems: page.window.buddyUsernames, completions: page.window.buddyUsernames) {
                    page.onSearch()
                }
                .frame(width: 140)
            }
        }
    }
}

/// A single search tab: result counter, filters and results.
struct SearchTabView: View {

    @Bindable var tab: SearchTab

    var body: some View {
        VStack(spacing: 0) {
            header

            if tab.isFiltersVisible {
                Divider()
                filterBar
            }

            Divider()
            tab.treeView.view
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            quickFilter("FLAC", isOn: tab.hasFileTypeFilter(["flac"])) {
                tab.toggleFileTypeFilter(["flac"])
            }
            quickFilter("MP3", isOn: tab.hasFileTypeFilter(["mp3"])) {
                tab.toggleFileTypeFilter(["mp3"])
            }
            quickFilter(String(localized: "Lossless"), isOn: tab.hasFileTypeFilter(SearchTab.losslessFileTypes)) {
                tab.toggleFileTypeFilter(SearchTab.losslessFileTypes)
            }
            quickFilter("\(SearchTab.highBitrate)+", isOn: tab.hasHighBitrateFilter) {
                tab.toggleHighBitrateFilter()
            }
            quickFilter(String(localized: "Free Slot"), isOn: tab.filterValues.freeSlot) {
                tab.toggleFreeSlotFilter()
            }

            Toggle(isOn: $tab.isFiltersVisible) {
                Label(tab.filtersLabel, systemImage: "line.3.horizontal.decrease")
            }
            .toggleStyle(.button)
            .buttonBorderShape(.capsule)
            .help(String(localized: "\(tab.activeFilterCount) active filter(s)"))

            Spacer(minLength: 12)

            Button {
                tab.onCounterButton()
            } label: {
                Label(tab.resultsText, systemImage: "doc.text.magnifyingglass")
                    .labelStyle(.titleAndIcon)
                    .monospacedDigit()
            }
            .buttonStyle(.borderless)
            .help(tab.resultsTooltip)

            if tab.isWishButtonVisible {
                Button {
                    tab.onAddWish()
                } label: {
                    Label(tab.isWish ? String(localized: "Remove Wish") : String(localized: "Add Wish"),
                          systemImage: tab.isWish ? "star.fill" : "star")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(tab.isWish ? String(localized: "Remove Wish") : String(localized: "Add Wish"))
            }

            sortMenu

            GroupingMenu(mode: tab.groupingMode) { mode in
                tab.onGroup(mode)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if tab.groupingMode != .ungrouped {
                Toggle(isOn: $tab.isExpanded) {
                    Image(systemName: tab.isExpanded
                          ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help(String(localized: "Expand / Collapse All"))
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func quickFilter(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { _ in action() }))
            .toggleStyle(.button)
            .buttonBorderShape(.capsule)
    }

    private static let sortColumns: [(id: String, title: String)] = [
        ("", String(localized: "Default")),
        ("filename", String(localized: "Filename")),
        ("folder", String(localized: "Folder")),
        ("user", String(localized: "User")),
        ("size", String(localized: "Size")),
        ("quality", String(localized: "Quality")),
        ("length", String(localized: "Duration")),
        ("speed", String(localized: "Speed")),
        ("in_queue", String(localized: "In Queue"))
    ]

    private var sortMenu: some View {
        Menu {
            ForEach(Self.sortColumns, id: \.id) { column in
                Button {
                    tab.sortResults(by: column.id)
                } label: {
                    if tab.sortColumnID == column.id {
                        Label(column.title, systemImage: column.id.isEmpty
                              ? "checkmark" : (tab.isSortAscending ? "chevron.up" : "chevron.down"))
                    } else {
                        Text(column.title)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Sort"))
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            filterEntry(.include, \.include, String(localized: "Include text…"),
                        String(localized: "Filter in results whose file paths contain the specified text. Multiple phrases and words can be specified, e.g. exact phrase|music|term|exact phrase two"),
                        focus: true)
            filterEntry(.exclude, \.exclude, String(localized: "Exclude text…"),
                        String(localized: "Filter out results whose file paths contain the specified text. Multiple phrases and words can be specified, e.g. exact phrase|music|term|exact phrase two"))
            filterEntry(.fileType, \.fileType, String(localized: "File type…"),
                        String(localized: "File type, e.g. flac wav or !mp3 !m4a"))
            filterEntry(.size, \.size, String(localized: "File size…"),
                        String(localized: "File size, e.g. >10.5m <1g"))
            filterEntry(.bitrate, \.bitrate, String(localized: "Bitrate…"),
                        String(localized: "Bitrate, e.g. 256 <1412"))
            filterEntry(.length, \.length, String(localized: "Duration…"),
                        String(localized: "Duration, e.g. >6:00 <12:00 !6:54"))
            filterEntry(.country, \.country, String(localized: "Country code…"),
                        String(localized: "Country code, e.g. US ES or !DE !GB"))

            Button {
                tab.onClearUndoFilters()
            } label: {
                Image(systemName: tab.hasUndoFilters ? "arrow.uturn.backward" : "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help(tab.hasUndoFilters ? String(localized: "Restore Filters") : String(localized: "Clear Filters"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onExitCommand {
            tab.onCloseFilterBar()
        }
    }

    private func filterEntry(_ filterID: SearchTab.FilterID, _ keyPath: WritableKeyPath<SearchTab.FilterValues, String>,
                             _ placeholder: String, _ tooltip: String, focus: Bool = false) -> some View {
        ComboBox(
            placeholder: placeholder,
            text: Binding(
                get: { tab.filterValues[keyPath: keyPath] },
                set: { value in
                    tab.filterValues[keyPath: keyPath] = value
                    tab.onFilterEntryChanged(filterID)
                }
            ),
            items: tab.filterHistory[filterID] ?? [],
            tooltip: tooltip,
            focusRequest: focus ? tab.filterFocusRequest : 0,
            isError: tab.invalidFilters.contains(filterID),
            onSubmit: { tab.onRefilter() },
            onSelectItem: { tab.onRefilter() }
        )
        .frame(minWidth: 70)
    }
}
