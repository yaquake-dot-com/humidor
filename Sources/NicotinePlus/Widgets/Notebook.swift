// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import NicotineCore
import Observation
import SwiftUI

/// A page in a secondary notebook (a search, chat room, user profile, etc.).
@MainActor
protocol NotebookPage: AnyObject {
    associatedtype Content: View

    /// Focuses the default widget of the page. Returns false if nothing was focused.
    func onFocus() -> Bool

    /// The content of the page
    @ViewBuilder var content: Content { get }
}

/// Label of a notebook tab.
struct TabLabel {
    var text: String
    var fullText: String
    var tooltip: String?
    var isChanged = false
    var isImportant = false
    var status: UserStatus?
    var closeCallback: (@MainActor () -> Void)?

    /// Chat mentions have priority over normal notifications
    mutating func requestChanged(isImportant: Bool = false) {
        if !self.isImportant {
            self.isImportant = isImportant
        }
        isChanged = true
    }

    mutating func removeChanged() {
        isImportant = false
        isChanged = false
    }

    mutating func setText(_ text: String) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Tabbed container of secondary pages, with icons, close buttons, unread
/// tab highlights and a menu listing all tabs.
@MainActor
@Observable
final class Notebook<Page: NotebookPage> {

    private(set) var pages: [Page] = []
    private(set) var labels: [ObjectIdentifier: TabLabel] = [:]
    private(set) var currentPage: Page?
    /// Unread pages, in the order they were changed, and whether they are important
    private(set) var unreadPages: [ObjectIdentifier: Bool] = [:]
    @ObservationIgnored private var unreadOrder: [ObjectIdentifier] = []
    /// Low limit to prevent excessive server traffic
    @ObservationIgnored private var recentlyRemovedPages: [@MainActor () -> Void] = []
    private(set) var hasRecentlyRemovedPages = false

    @ObservationIgnored private weak var window: MainWindow?
    @ObservationIgnored let parentPage: MainWindow.Page?
    @ObservationIgnored var switchPageCallback: (@MainActor (Page) -> Void)?
    @ObservationIgnored var removeAllPagesCallback: (@MainActor () -> Void)?
    @ObservationIgnored private var shouldFocusPage = true

    init(window: MainWindow?, parentPage: MainWindow.Page?) {
        self.window = window
        self.parentPage = parentPage
    }

    // MARK: Tabs

    func label(_ page: Page) -> TabLabel? {
        labels[ObjectIdentifier(page)]
    }

    func updateLabel(_ page: Page, _ update: (inout TabLabel) -> Void) {
        guard var label = labels[ObjectIdentifier(page)] else {
            return
        }
        update(&label)
        labels[ObjectIdentifier(page)] = label
    }

    var numPages: Int { pages.count }

    func pageIndex(_ page: Page) -> Int? {
        pages.firstIndex { $0 === page }
    }

    func appendPage(_ page: Page, text: String, closeCallback: (@MainActor () -> Void)? = nil, user: String? = nil) {
        insertPage(page, text: text, closeCallback: closeCallback, user: user, position: -1)
    }

    func prependPage(_ page: Page, text: String, closeCallback: (@MainActor () -> Void)? = nil, user: String? = nil) {
        insertPage(page, text: text, closeCallback: closeCallback, user: user, position: 0)
    }

    func insertPage(_ page: Page, text: String, closeCallback: (@MainActor () -> Void)? = nil, user: String? = nil,
                    position: Int? = nil) {
        let fullText = text
        let text = text.count > 25 ? String(text.prefix(25)) + "…" : text

        labels[ObjectIdentifier(page)] = TabLabel(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            fullText: fullText,
            tooltip: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            closeCallback: closeCallback
        )

        var position = position ?? currentPage.flatMap(pageIndex).map { $0 + 1 } ?? pages.count

        if position < 0 || position > pages.count {
            position = pages.count
        }

        // Open new tab adjacent to current tab, unless a position is given
        pages.insert(page, at: position)

        if currentPage == nil {
            setCurrentPage(page)
        }

        if let user {
            setUserStatus(page, user: text, status: core.users.statuses[user] ?? .offline)
        }
    }

    func restoreRemovedPage() {
        guard let restore = recentlyRemovedPages.popLast() else {
            return
        }

        hasRecentlyRemovedPages = !recentlyRemovedPages.isEmpty
        restore()
    }

    func removePage(_ page: Page, restore: (@MainActor () -> Void)? = nil) {
        guard let index = pageIndex(page) else {
            return
        }

        pages.remove(at: index)
        removeUnreadPage(page)
        labels.removeValue(forKey: ObjectIdentifier(page))

        if let restore {
            // Allow for restoring page after closing it
            recentlyRemovedPages.append(restore)

            if recentlyRemovedPages.count > 5 {
                recentlyRemovedPages.removeFirst()
            }
            hasRecentlyRemovedPages = true
        }

        if currentPage === page {
            currentPage = nil

            if !pages.isEmpty {
                setCurrentPage(pages[min(index, pages.count - 1)])
            }
        }
    }

    func closePage(_ page: Page) {
        label(page)?.closeCallback?()
    }

    func removeAllPages() {
        OptionDialog(
            title: String(localized: "Close All Tabs?"),
            message: String(localized: "Do you really want to close all tabs?"),
            destructiveResponse: "ok"
        ) { [weak self] _, _ in
            self?.onRemoveAllPages()
        }.present()
    }

    private func onRemoveAllPages() {
        removeAllPagesCallback?()

        // Don't allow restoring tabs after removing all
        recentlyRemovedPages.removeAll()
        hasRecentlyRemovedPages = false
    }

    func setCurrentPage(_ page: Page) {
        guard pageIndex(page) != nil else {
            return
        }

        currentPage = page
        onSwitchPage(page)
    }

    func movePage(fromOffsets source: IndexSet, toOffset destination: Int) {
        pages.move(fromOffsets: source, toOffset: destination)
    }

    /// Selects the next or previous tab, wrapping around at the ends.
    func cycle(backwards: Bool = false) {
        guard let currentPage, let index = pageIndex(currentPage), !pages.isEmpty else {
            return
        }

        let newIndex = backwards ? (index - 1 + pages.count) % pages.count : (index + 1) % pages.count
        setCurrentPage(pages[newIndex])
    }

    // MARK: Tab Highlights

    /// Highlights a tab with unread content. Returns true if the unread state changed.
    @discardableResult
    func requestTabChanged(_ page: Page, isImportant: Bool = false, isQuiet: Bool = false) -> Bool {
        var hasTabChanged = false

        if let parentPage, let window {
            let isCurrentParent = (window.currentPage == parentPage)
            let isCurrentPage = (currentPage === page)

            if isCurrentParent && isCurrentPage {
                return hasTabChanged
            }

            if !isQuiet || isImportant {
                // Highlight top-level tab, but don't for global feed unless mentioned
                window.requestTabChanged(parentPage, isImportant: isImportant)
                hasTabChanged = appendUnreadPage(page, isImportant: isImportant)
            }
        } else {
            hasTabChanged = true
        }

        updateLabel(page) { $0.requestChanged(isImportant: isImportant) }
        return hasTabChanged
    }

    func removeTabChanged(_ page: Page) {
        updateLabel(page) { $0.removeChanged() }

        if parentPage != nil {
            removeUnreadPage(page)
        }
    }

    private func appendUnreadPage(_ page: Page, isImportant: Bool = false) -> Bool {
        let pageID = ObjectIdentifier(page)

        // Remove existing page and move it to the end
        let isCurrentlyImportant = unreadPages.removeValue(forKey: pageID)
        unreadOrder.removeAll { $0 == pageID }

        if isCurrentlyImportant == true && !isImportant {
            // Important pages are persistent
            unreadPages[pageID] = true
            unreadOrder.append(pageID)
            return false
        }

        unreadPages[pageID] = isImportant
        unreadOrder.append(pageID)

        return isCurrentlyImportant != isImportant
    }

    private func removeUnreadPage(_ page: Page) {
        let pageID = ObjectIdentifier(page)

        guard let isImportantPageRemoved = unreadPages.removeValue(forKey: pageID) else {
            return
        }

        unreadOrder.removeAll { $0 == pageID }

        guard let parentPage, let window else {
            return
        }

        if unreadPages.isEmpty {
            window.removeTabChanged(parentPage)
            return
        }

        // No important unread pages left, reset top-level tab highlight
        if isImportantPageRemoved && !unreadPages.values.contains(true) {
            window.removeTabChanged(parentPage)
            window.requestTabChanged(parentPage, isImportant: false)
        }
    }

    var unreadPagesInOrder: [Page] {
        unreadOrder.compactMap { pageID in pages.first { ObjectIdentifier($0) == pageID } }
    }

    var pagesMenuTooltip: String {
        unreadPages.isEmpty ? String(localized: "All Tabs") : String(localized: "\(unreadPages.count) Unread Tab(s)")
    }

    // MARK: Tab User Status

    func setUserStatus(_ page: Page, user: String, status: UserStatus) {
        let statusText = switch status {
        case .away: String(localized: "Away")
        case .online: String(localized: "Online")
        case .offline: String(localized: "Offline")
        }

        updateLabel(page) { label in
            label.status = status
            label.setText(user)
            label.tooltip = "\(user) (\(statusText))"
        }
    }

    // MARK: Events

    /// The main page containing this notebook was shown.
    func onShowParentPage() {
        if let currentPage {
            onSwitchPage(currentPage)
        }
    }

    private func onSwitchPage(_ page: Page) {
        switchPageCallback?(page)

        // Focus the default widget on the page
        if shouldFocusPage && (parentPage == nil || window?.currentPage == parentPage) {
            DispatchQueue.main.async { [weak page] in
                MainActor.assumeIsolated {
                    _ = page?.onFocus()
                }
            }
        }

        // Dismiss tab highlight
        if parentPage != nil {
            removeTabChanged(page)
        }

        shouldFocusPage = true
    }
}

// MARK: - Main Window Tab Highlights

extension MainWindow {

    func requestTabChanged(_ page: Page, isImportant: Bool = false) {
        // Chat mentions have priority over normal notifications
        highlightedPages[page] = (highlightedPages[page] ?? false) || isImportant
    }

    func removeTabChanged(_ page: Page) {
        highlightedPages.removeValue(forKey: page)
    }
}

// MARK: - Views

/// Tab bar and content of a notebook.
struct NotebookView<Page: NotebookPage>: View {

    let notebook: Notebook<Page>

    var body: some View {
        VStack(spacing: 0) {
            if !notebook.pages.isEmpty {
                NotebookTabBar(notebook: notebook)
                Divider()
            }

            if let currentPage = notebook.currentPage {
                currentPage.content
                    .id(ObjectIdentifier(currentPage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
    }
}

private struct NotebookTabBar<Page: NotebookPage>: View {

    let notebook: Notebook<Page>

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(notebook.pages.enumerated()), id: \.1.identifier) { _, page in
                            NotebookTab(notebook: notebook, page: page)
                                .id(ObjectIdentifier(page))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .onChange(of: notebook.currentPage.map(ObjectIdentifier.init)) { _, pageID in
                    if let pageID {
                        withAnimation {
                            proxy.scrollTo(pageID)
                        }
                    }
                }
            }

            NotebookPagesMenu(notebook: notebook)
                .padding(.trailing, 6)
        }
        .background(.bar)
    }
}

private extension NotebookPage {
    var identifier: ObjectIdentifier { ObjectIdentifier(self) }
}

private struct NotebookTab<Page: NotebookPage>: View {

    let notebook: Notebook<Page>
    let page: Page
    @State private var isHovering = false

    var body: some View {
        let label = notebook.label(page)
        let isSelected = (notebook.currentPage === page)

        HStack(spacing: 4) {
            if label?.closeCallback != nil && config.ui.tabClosers {
                Button {
                    notebook.closePage(page)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.borderless)
                .opacity(isHovering || isSelected ? 1 : 0.4)
                .help(String(localized: "Close Tab"))
            }

            if let status = label?.status {
                Circle()
                    .fill(Color(nsColor: Theme.color(forID: Theme.userStatusColorID(status)) ?? .secondaryLabelColor))
                    .frame(width: 8, height: 8)
            }

            Text(label?.text ?? "")
                .lineLimit(1)
                .fontWeight(label?.isChanged == true ? .bold : .regular)
                .foregroundStyle(tabColor(label))

            if label?.isChanged == true {
                Image(systemName: label?.isImportant == true ? "exclamationmark.circle.fill" : "circle.fill")
                    .font(.system(size: label?.isImportant == true ? 10 : 6))
                    .foregroundStyle(tabColor(label))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : (isHovering ? Color.primary.opacity(0.06) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            notebook.setCurrentPage(page)
        }
        .onHover { isHovering = $0 }
        .help(label?.tooltip ?? "")
        .overlay(MiddleClickView { notebook.closePage(page) })
    }

    private func tabColor(_ label: TabLabel?) -> Color {
        guard let label, label.isChanged else {
            return .primary
        }

        let colorID = label.isImportant ? "tabhilite" : "tabchanged"
        return Color(nsColor: Theme.color(forID: colorID) ?? .controlAccentColor)
    }
}

private struct NotebookPagesMenu<Page: NotebookPage>: View {

    let notebook: Notebook<Page>

    var body: some View {
        Menu {
            let unreadPages = notebook.unreadPagesInOrder

            // Unread pages (most recently changed first)
            ForEach(Array(unreadPages.reversed().enumerated()), id: \.offset) { _, page in
                Button("*  " + (notebook.label(page)?.text ?? "")) {
                    notebook.setCurrentPage(page)
                }
            }

            if !unreadPages.isEmpty {
                Divider()
            }

            // All pages
            ForEach(Array(notebook.pages.enumerated()), id: \.offset) { _, page in
                if !unreadPages.contains(where: { $0 === page }) {
                    Button(notebook.label(page)?.text ?? "") {
                        notebook.setCurrentPage(page)
                    }
                }
            }

            Divider()

            Button(String(localized: "Reopen Closed Tab")) {
                notebook.restoreRemovedPage()
            }
            .disabled(!notebook.hasRecentlyRemovedPages)

            Button(String(localized: "Close All Tabs…")) {
                notebook.removeAllPages()
            }
        } label: {
            Image(systemName: notebook.unreadPages.isEmpty ? "chevron.down" : "exclamationmark.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(notebook.pagesMenuTooltip)
    }
}

/// Invisible view that reports middle mouse button clicks.
private struct MiddleClickView: NSViewRepresentable {

    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ClickView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ClickView)?.action = action
    }

    private final class ClickView: NSView {
        var action: (@MainActor () -> Void)?

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 {
                MainActor.assumeIsolated {
                    action?()
                }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only intercept middle clicks, let other events pass through
            guard let event = NSApp.currentEvent,
                  [.otherMouseDown, .otherMouseUp].contains(event.type) else {
                return nil
            }
            return super.hitTest(point)
        }
    }
}
