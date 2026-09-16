// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import NicotineCore
import Observation
import SwiftUI

/// Wishlist dialog, listing search terms that are searched at regular intervals.
@MainActor
@Observable
final class WishList {

    @ObservationIgnored private let application: Application
    @ObservationIgnored private(set) var listView: TreeView!
    @ObservationIgnored private var dialog: DialogWindow!

    var wishText = ""
    private(set) var wishFocusRequest = 0

    init(application: Application) {
        self.application = application

        listView = TreeView(
            columns: [TreeColumn(id: "wish", title: String(localized: "Wish"), defaultSortOrder: .ascending)],
            multiSelect: true,
            activateRow: { [unowned self] _, _, _ in onEditWish() },
            deleteAccelerator: { [unowned self] _ in onRemoveWish() }
        )

        listView.freeze()

        for searchItem in core.search.searches.values where searchItem.mode == .wishlist {
            addWish(searchItem.term, isSelected: false)
        }

        listView.unfreeze()

        let popupMenu = PopupMenu()
        popupMenu.addItems(
            .action(String(localized: "Search for Item")) { [unowned self] in onSearchWish() },
            .action(String(localized: "Edit…")) { [unowned self] in onEditWish() },
            .separator,
            .action(String(localized: "Remove")) { [unowned self] in onRemoveWish() }
        )
        listView.popupMenu = popupMenu

        dialog = DialogWindow(title: String(localized: "Wishlist"), width: 600, height: 600) { [unowned self] in
            WishListView(wishList: self)
        }
        dialog.showCallback = { [unowned self] in onShow() }

        events.connect(.addWish) { [unowned self] in addWish($0) }
        events.connect(.removeWish) { [unowned self] in removeWish($0) }
    }

    func present() {
        dialog.present()
    }

    var wishes: [String] {
        listView.iterators.keys.map(\.string).sorted()
    }

    func onAddWish() {
        let wish = wishText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !wish.isEmpty else {
            return
        }

        let wishExists = listView.iterators[.string(wish)] != nil

        wishText = ""
        core.search.addWish(wish)

        if wishExists {
            selectWish(wish)
        }
    }

    func onEditWish() {
        guard let row = listView.selectedRows.first else {
            return
        }

        let oldWish = listView.rowValue(row, "wish").string

        EntryDialog(
            title: String(localized: "Edit Wish"),
            message: String(localized: "Enter new value for wish '\(oldWish)':"),
            defaultText: oldWish,
            actionButtonLabel: String(localized: "Edit")
        ) { [weak self] dialog, _ in
            let wish = ((dialog as? EntryDialog)?.entryValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            guard !wish.isEmpty else {
                return
            }

            core.search.removeWish(oldWish)
            core.search.addWish(wish)
            self?.selectWish(wish)
        }.present()
    }

    private func onSearchWish() {
        if let row = listView.selectedRows.first {
            core.search.doSearch(listView.rowValue(row, "wish").string, mode: .global)
        }
    }

    func onRemoveWish() {
        for row in listView.selectedRows.reversed() {
            core.search.removeWish(listView.rowValue(row, "wish").string)
        }

        wishFocusRequest += 1
    }

    func onClearWishlist() {
        OptionDialog(
            title: String(localized: "Clear Wishlist?"),
            message: String(localized: "Do you really want to clear your wishlist?"),
            destructiveResponse: "ok"
        ) { [weak self] _, _ in
            guard let self else {
                return
            }

            for wish in listView.iterators.keys.map(\.string) {
                core.search.removeWish(wish)
            }
            wishFocusRequest += 1
        }.present()
    }

    private func addWish(_ wish: String, isSelected: Bool = true) {
        listView.addRow([.string(wish)], selectRow: isSelected)
    }

    private func removeWish(_ wish: String) {
        if let row = listView.iterators[.string(wish)] {
            listView.removeRow(row)
        }
    }

    private func selectWish(_ wish: String) {
        if let row = listView.iterators[.string(wish)] {
            listView.selectRow(row)
        }
    }

    private func onShow() {
        guard let text = application.window.search.notebook.currentPage?.text, !text.isEmpty else {
            listView.unselectAllRows()
            return
        }

        if let row = listView.iterators[.string(text)] {
            // Highlight existing wish row
            listView.selectRow(row)
            wishText = ""
            return
        }

        // Pre-fill text field with search term from active search tab
        listView.unselectAllRows()
        wishText = text
        wishFocusRequest += 1
    }
}

private struct WishListView: View {

    @Bindable var wishList: WishList

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Wishlist items are auto-searched at regular intervals, for discovering uncommon files."))
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                ComboBox(placeholder: String(localized: "Add Wish…"), text: $wishList.wishText, items: wishList.wishes,
                         focusRequest: wishList.wishFocusRequest, onSubmit: { wishList.onAddWish() })

                Button {
                    wishList.onAddWish()
                } label: {
                    Image(systemName: "plus")
                }
            }

            ListBox(listView: wishList.listView, buttons: [
                .edit { wishList.onEditWish() },
                .remove { wishList.onRemoveWish() }
            ])
        }
        .padding(16)
        .frame(minWidth: 400, minHeight: 300)
        .bottomBar {
            HStack {
                Spacer()
                Button(String(localized: "Clear All…")) { wishList.onClearWishlist() }
            }
        }
    }
}
