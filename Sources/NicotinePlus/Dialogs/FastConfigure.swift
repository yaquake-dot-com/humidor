// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import NicotineCore
import Observation
import SwiftUI

/// Setup assistant, shown on first run or when the password is invalid.
@MainActor
@Observable
final class FastConfigure {

    enum Page: Int, CaseIterable {
        case welcome
        case account
        case port
        case share
        case summary
    }

    @ObservationIgnored private let application: Application
    @ObservationIgnored private var dialog: DialogWindow!
    @ObservationIgnored private(set) var sharesListView: TreeView!
    @ObservationIgnored private var isRescanRequired = false

    var invalidPassword = false
    private(set) var page = Page.welcome
    private(set) var isAccountPageVisible = true
    var username = ""
    var password = ""
    var listenPort = 2234
    var downloadFolder = "" {
        didSet {
            config.transfers.downloadDir = downloadFolder
        }
    }
    private(set) var usernameFocusRequest = 0

    init(application: Application) {
        self.application = application

        sharesListView = TreeView(
            columns: [
                TreeColumn(id: "virtual_name", title: String(localized: "Virtual Folder"), width: 1,
                           expandsColumn: true, defaultSortOrder: .ascending),
                TreeColumn(id: "folder", title: String(localized: "Folder"), width: 125, expandsColumn: true)
            ],
            multiSelect: true,
            activateRow: { [unowned self] _, _, _ in onEditSharedFolder() },
            deleteAccelerator: { [unowned self] _ in onRemoveSharedFolder() }
        )

        dialog = DialogWindow(title: String(localized: "Setup Assistant"), width: 720, height: 450) { [unowned self] in
            FastConfigureView(assistant: self)
        }
        dialog.showCallback = { [unowned self] in onShow() }
        dialog.closeCallback = { [unowned self] in onClose() }
    }

    var isVisible: Bool {
        dialog.isVisible
    }

    func present() {
        dialog.present()
    }

    func hide() {
        dialog.hide()
    }

    // MARK: Navigation

    private var visiblePages: [Page] {
        Page.allCases.filter { $0 != .account || isAccountPageVisible }
    }

    var isPageComplete: Bool {
        switch page {
        case .welcome, .port, .summary: true
        case .account: !username.isEmpty && !password.isEmpty
        case .share: !downloadFolder.isEmpty
        }
    }

    var isFinished: Bool {
        invalidPassword ? page == .account : page == .summary
    }

    var previousLabel: String {
        invalidPassword ? String(localized: "Cancel") : String(localized: "Previous")
    }

    var nextLabel: String {
        isFinished ? String(localized: "Finish") : String(localized: "Next")
    }

    private func setPage(_ page: Page) {
        self.page = page

        if page == .account {
            usernameFocusRequest += 1
        }
    }

    func onUserEntryActivate() {
        if username.isEmpty || password.isEmpty {
            usernameFocusRequest += 1
            return
        }

        onNext()
    }

    func onNext() {
        if isFinished {
            onFinished()
            return
        }

        if let nextPage = visiblePages.first(where: { $0.rawValue > page.rawValue }) {
            setPage(nextPage)
        }
    }

    func onPrevious() {
        if invalidPassword {
            dialog.close()
            return
        }

        if let previousPage = visiblePages.last(where: { $0.rawValue < page.rawValue }) {
            setPage(previousPage)
        }
    }

    private func onFinished() {
        if isRescanRequired {
            core.shares.rescanShares()
        }

        // Port page
        config.server.portRange = listenPort...listenPort

        // Account page
        if invalidPassword || config.needsConfig {
            config.server.login = username
            config.server.password = password
        }

        if core.users.loginStatus == .offline {
            core.connect()
        }

        dialog.close()
    }

    private func onClose() {
        invalidPassword = false
        isRescanRequired = false
    }

    private func onShow() {
        isAccountPageVisible = invalidPassword || config.needsConfig
        setPage(invalidPassword ? .account : .welcome)

        // Account page
        username = config.server.login
        password = config.server.password

        // Port page
        listenPort = config.server.portRange.lowerBound

        // Share page
        downloadFolder = core.downloads.defaultDownloadFolder()

        sharesListView.clear()
        sharesListView.freeze()

        for share in config.transfers.shared {
            sharesListView.addRow([.string(share.virtualName), .string(share.path)], selectRow: false)
        }

        sharesListView.unfreeze()
    }

    var invalidPasswordMessage: String {
        String(localized: "User \(config.server.login) already exists, and the password you entered is invalid. Please choose another username if this is your first time logging in.")
    }

    // MARK: Shares

    func onAddSharedFolder() {
        FileChooser.chooseFolders(title: String(localized: "Add a Shared Folder"), selectMultiple: true) {
            [weak self] folderPaths in
            guard let self else {
                return
            }

            for folderPath in folderPaths {
                if let virtualName = core.shares.addShare(folderPath) {
                    sharesListView.addRow([.string(virtualName), .string(folderPath)])
                    isRescanRequired = true
                }
            }
        }
    }

    func onEditSharedFolder() {
        guard let row = sharesListView.selectedRows.first else {
            return
        }

        let virtualName = sharesListView.rowValue(row, "virtual_name").string
        let folderPath = sharesListView.rowValue(row, "folder").string

        EntryDialog(
            title: String(localized: "Edit Shared Folder"),
            message: String(localized: "Enter new virtual name for '\(folderPath)':"),
            defaultText: virtualName,
            actionButtonLabel: String(localized: "Edit")
        ) { [weak self] dialog, _ in
            guard let self, let newVirtualName = (dialog as? EntryDialog)?.entryValue,
                  newVirtualName != virtualName else {
                return
            }

            isRescanRequired = true

            if let originalRow = sharesListView.iterators[.string(virtualName)] {
                sharesListView.removeRow(originalRow)
            }

            core.shares.removeShare(virtualName)

            if let addedVirtualName = core.shares.addShare(folderPath, virtualName: newVirtualName,
                                                           validatePath: false) {
                sharesListView.addRow([.string(addedVirtualName), .string(folderPath)])
            }
        }.present()
    }

    func onRemoveSharedFolder() {
        for row in sharesListView.selectedRows.reversed() {
            let virtualName = sharesListView.rowValue(row, "virtual_name").string

            core.shares.removeShare(virtualName)

            if let originalRow = sharesListView.iterators[.string(virtualName)] {
                sharesListView.removeRow(originalRow)
            }

            isRescanRequired = true
        }
    }
}

private struct FastConfigureView: View {

    @Bindable var assistant: FastConfigure

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch assistant.page {
                case .welcome: welcomePage
                case .account: accountPage
                case .port: portPage
                case .share: sharePage
                case .summary: summaryPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

        }
        .frame(minWidth: 600, minHeight: 400)
        .bottomBar {
            if assistant.page != .welcome {
                HStack {
                    Button(assistant.previousLabel) {
                        assistant.onPrevious()
                    }

                    Spacer()

                    Button(assistant.nextLabel) {
                        assistant.onNext()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!assistant.isPageComplete)
                }
            }
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)

            Text(String(localized: "Welcome to Nicotine+"))
                .font(.largeTitle.bold())

            Text(String(localized: "Graphical client for the Soulseek peer-to-peer network"))
                .foregroundStyle(.secondary)

            Button(String(localized: "Next")) {
                assistant.onNext()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
    }

    private var accountPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if assistant.invalidPassword {
                InfoBar(message: assistant.invalidPasswordMessage, messageType: .error)
            }

            Text(String(localized: "To create a new Soulseek account, fill in your desired username and password. If you already have an account, fill in your existing login details."))
                .fixedSize(horizontal: false, vertical: true)

            Text(String(localized: "If your desired username is already taken, you will be prompted to change it."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                LabeledContent(String(localized: "Username: ")) {
                    ComboBox(placeholder: "", text: Binding(
                        get: { assistant.username },
                        set: { assistant.username = String($0.prefix(Users.usernameMaxLength)) }
                    ), focusRequest: assistant.usernameFocusRequest, onSubmit: { assistant.onUserEntryActivate() })
                    .frame(width: 280)
                }

                LabeledContent(String(localized: "Password: ")) {
                    SecureField("", text: $assistant.password)
                        .onSubmit { assistant.onUserEntryActivate() }
                        .frame(width: 280)
                }
            }
        }
    }

    private var portPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "To connect with other Soulseek peers, a listening port on your router has to be forwarded to your computer."))
                .fixedSize(horizontal: false, vertical: true)

            Text(String(localized: "If your listening port is closed, you will only be able to connect to users whose listening ports are open."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(localized: "If necessary, choose a different listening port below. This can also be done later in the preferences."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("", value: $assistant.listenPort, format: .number.grouping(.never))
                    .frame(width: 80)
                Stepper("", value: $assistant.listenPort, in: 0...65535)
                    .labelsHidden()
            }
        }
    }

    private var sharePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Download Files to Folder"))
                .font(.headline)

            FileChooserButton(path: $assistant.downloadFolder, chooserType: .folder,
                              showsOpenButton: !Application.shared.isolatedMode)

            Text(String(localized: "Share Folders"))
                .font(.headline)

            Text(String(localized: "Soulseek users will be able to download from your shares. Contribute to the Soulseek network by sharing your own files and by resharing what you downloaded from other users."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ListBox(listView: assistant.sharesListView, buttons: [
                .add { assistant.onAddSharedFolder() },
                .edit { assistant.onEditSharedFolder() },
                .remove { assistant.onRemoveSharedFolder() }
            ])
        }
    }

    private var summaryPage: some View {
        VStack(spacing: 24) {
            Text(String(localized: "You are ready to use Nicotine+!"))
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            VStack(spacing: 18) {
                Text(String(localized: "Soulseek is an unencrypted protocol not intended for secure communication."))
                Text(String(localized: "Donating to Soulseek grants you privileges for a certain time period. If you have privileges, your downloads will be queued ahead of non-privileged users."))
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
            .textSelection(.enabled)
        }
    }
}
