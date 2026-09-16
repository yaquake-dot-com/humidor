// SPDX-License-Identifier: GPL-3.0-or-later

import NicotineCore
import SwiftUI

/// Placeholder shown on pages without content.
struct PageDescription: View {

    let systemImage: String
    let title: String
    let description: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Message bar shown above the content of a page.
struct InfoBar: View {

    enum MessageType {
        case info
        case error
    }

    let message: String
    let messageType: MessageType
    var buttonLabel: String?
    var buttonAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: messageType == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(messageType == .error ? .red : .accentColor)

            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if let buttonLabel, let buttonAction {
                Button(buttonLabel, action: buttonAction)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(messageType == .error ? Color.red.opacity(0.12) : Color.accentColor.opacity(0.12))
    }
}

/// Downloads or uploads page.
struct TransfersView: View {

    @Bindable var page: TransfersPage

    private var isDownloads: Bool { page.type == .download }

    var body: some View {
        VStack(spacing: 0) {
            if page.hasTransfers {
                page.treeView.view
                    .bottomBar(horizontalPadding: 10, verticalPadding: 6) {
                        actionBar
                    }
            } else if isDownloads {
                PageDescription(
                    systemImage: "arrow.down.circle",
                    title: String(localized: "Downloads"),
                    description: String(localized: "Files you download from other users are queued here, and can be paused and resumed on demand")
                )
            } else {
                PageDescription(
                    systemImage: "arrow.up.circle",
                    title: String(localized: "Uploads"),
                    description: String(localized: "Users' attempts to download your shared files are queued and managed here")
                )
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Application.shared.onTransferStatistics()
                } label: {
                    Label(page.userCountText, systemImage: "person.2")
                        .labelStyle(.titleAndIcon)
                }
                .help(String(localized: "Users"))

                Button {
                    Application.shared.onTransferStatistics()
                } label: {
                    Label(page.fileCountText, systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .help(String(localized: "Files"))

                if page.groupingMode != .ungrouped {
                    Toggle(isOn: $page.isExpanded) {
                        Label(String(localized: "Expand / Collapse All"),
                              systemImage: page.isExpanded
                                ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .help(String(localized: "Expand / Collapse All"))
                }

                GroupingMenu(mode: page.groupingMode ?? .folderGrouping) { mode in
                    page.onToggleTree(mode)
                }

                Button {
                    if isDownloads {
                        Application.shared.onConfigureDownloads()
                    } else {
                        Application.shared.onConfigureUploads()
                    }
                } label: {
                    Label(isDownloads ? String(localized: "Configure Downloads") : String(localized: "Configure Uploads"),
                          systemImage: "gearshape")
                }
                .help(isDownloads ? String(localized: "Configure Downloads") : String(localized: "Configure Uploads"))
            }
        }
    }

    @ViewBuilder private var actionBar: some View {
        HStack(spacing: 8) {
            if isDownloads {
                Button(String(localized: "Resume"), systemImage: "arrow.clockwise") { page.onRetryTransfer() }
                Button(String(localized: "Pause"), systemImage: "pause") { page.onAbortTransfer() }
                Button(String(localized: "Remove"), systemImage: "minus") { page.onRemoveTransfer() }
            } else if let uploads = page as? UploadsPage {
                Button(String(localized: "Abort"), systemImage: "stop") { page.onAbortTransfer() }
                Button(String(localized: "Abort User(s)"), systemImage: "stop.circle") { uploads.onAbortUsers() }
                Button(String(localized: "Ban User(s)"), systemImage: "nosign") { uploads.onBanUsers() }
            }

            Spacer()

            if let downloads = page as? DownloadsPage {
                Button(String(localized: "Clear Finished"), systemImage: "xmark.circle") {
                    downloads.onClearFinishedFiltered()
                }
                .help(String(localized: "Clear All Finished/Filtered Downloads"))

            } else if let uploads = page as? UploadsPage {
                Button(String(localized: "Clear Finished"), systemImage: "xmark.circle") {
                    uploads.onClearFinishedCancelled()
                }
                .help(String(localized: "Clear All Finished/Cancelled Uploads"))

                Button(String(localized: "Message All"), systemImage: "paperplane") {
                    Application.shared.onMessageDownloadingUsers()
                }
                .help(String(localized: "Message All"))
            }

            Menu(String(localized: "Clear All…")) {
                ForEach(Array(page.clearItems.enumerated()), id: \.offset) { _, item in
                    if let item {
                        Button(item.label, action: item.action)
                    } else {
                        Divider()
                    }
                }
            }
            .fixedSize()
            .help(isDownloads ? String(localized: "Clear Specific Downloads") : String(localized: "Clear Specific Uploads"))
        }
        .buttonStyle(.borderless)
    }
}

/// Menu for choosing how files are grouped in a list.
struct GroupingMenu: View {

    let mode: GroupingMode
    let action: @MainActor @Sendable (GroupingMode) -> Void

    var body: some View {
        Menu {
            Picker(String(localized: "File Grouping Mode"), selection: Binding(get: { mode }, set: action)) {
                Text(String(localized: "Ungrouped")).tag(GroupingMode.ungrouped)
                Text(String(localized: "Group by Folder")).tag(GroupingMode.folderGrouping)
                Text(String(localized: "Group by User")).tag(GroupingMode.userGrouping)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(String(localized: "File Grouping Mode"), systemImage: "list.bullet.indent")
                .labelStyle(.iconOnly)
        }
        .help(String(localized: "File Grouping Mode"))
    }
}

/// Popover for changing transfer speed limits.
struct TransferSpeedsView: View {

    let direction: TransferDirection

    @State private var mode = SpeedLimitMode.unlimited
    @State private var limit = 0
    @State private var alternativeLimit = 0

    var body: some View {
        Form {
            Text(direction == .download ? String(localized: "Download Speed Limits")
                                        : String(localized: "Upload Speed Limits"))
                .font(.headline)

            Picker(selection: $mode) {
                Text(direction == .download ? String(localized: "Unlimited download speed")
                                            : String(localized: "Unlimited upload speed"))
                    .tag(SpeedLimitMode.unlimited)

                HStack {
                    Text(direction == .download ? String(localized: "Use download speed limit (KiB/s):")
                                                : String(localized: "Use upload speed limit (KiB/s):"))
                    Spacer()
                    speedField($limit)
                }
                .tag(SpeedLimitMode.primary)

                HStack {
                    Text(direction == .download ? String(localized: "Use alternative download speed limit (KiB/s):")
                                                : String(localized: "Use alternative upload speed limit (KiB/s):"))
                    Spacer()
                    speedField($alternativeLimit)
                }
                .tag(SpeedLimitMode.alternative)
            } label: {
                EmptyView()
            }
            .pickerStyle(.radioGroup)
        }
        .padding()
        .frame(width: 440)
        .onAppear(perform: onShow)
        .onChange(of: mode) { onActiveLimitToggled() }
        .onChange(of: limit) { onLimitChanged() }
        .onChange(of: alternativeLimit) { onAlternativeLimitChanged() }
    }

    private func speedField(_ value: Binding<Int>) -> some View {
        HStack(spacing: 2) {
            TextField("", value: value, format: .number.grouping(.never))
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
            Stepper("", value: value, in: 0...1_000_000, step: 10)
                .labelsHidden()
        }
    }

    private func updateTransferLimits() {
        if direction == .download {
            core.downloads.updateTransferLimits()
        } else {
            core.uploads.updateTransferLimits()
        }
    }

    private func onShow() {
        if direction == .download {
            alternativeLimit = config.transfers.downloadLimitAlt
            limit = config.transfers.downloadLimit
            mode = config.transfers.useDownloadSpeedLimit
        } else {
            alternativeLimit = config.transfers.uploadLimitAlt
            limit = config.transfers.uploadLimit
            mode = config.transfers.useUploadSpeedLimit
        }
    }

    private func onActiveLimitToggled() {
        let previousMode = (direction == .download)
            ? config.transfers.useDownloadSpeedLimit : config.transfers.useUploadSpeedLimit

        if direction == .download {
            config.transfers.useDownloadSpeedLimit = mode
        } else {
            config.transfers.useUploadSpeedLimit = mode
        }

        if previousMode != mode {
            updateTransferLimits()
        }
    }

    private func onLimitChanged() {
        let limit = max(0, min(limit, 1_000_000))

        if direction == .download {
            guard limit != config.transfers.downloadLimit else { return }
            config.transfers.downloadLimit = limit
        } else {
            guard limit != config.transfers.uploadLimit else { return }
            config.transfers.uploadLimit = limit
        }
        updateTransferLimits()
    }

    private func onAlternativeLimitChanged() {
        let limit = max(0, min(alternativeLimit, 1_000_000))

        if direction == .download {
            guard limit != config.transfers.downloadLimitAlt else { return }
            config.transfers.downloadLimitAlt = limit
        } else {
            guard limit != config.transfers.uploadLimitAlt else { return }
            config.transfers.uploadLimitAlt = limit
        }
        updateTransferLimits()
    }
}
