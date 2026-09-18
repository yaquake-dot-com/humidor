// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore

/// Rows of the downloads and uploads, drawn like the results of a search: a user or folder on two
/// lines, with a summary of its files, and the files below it on one line each.
@MainActor
enum TransferRows {

    private static let separator = "  ·  "

    /// Rows of downloads or uploads, whose users are tinted in the color of the direction, as the
    /// speeds in the sidebar and in the Dock
    static func presentation(for direction: TransferDirection) -> TreeRowPresentation {
        TreeRowPresentation(
            height: { treeView, row in
                isTwoLineRow(treeView, row) ? RowCellView.twoLineHeight : RowCellView.oneLineHeight
            },
            view: { treeView, row in
                let cellView = treeView.outlineView.makeView(withIdentifier: TransferCellView.identifier, owner: nil)
                    as? TransferCellView ?? TransferCellView()
                configure(cellView, treeView: treeView, row: row, direction: direction)
                return cellView
            },
            isGroupRow: { treeView, row in
                row.parent == nil && isGroupRow(treeView, row)
            },
            groupRowColor: (direction == .download ? NSColor.systemBlue : .systemGreen).withAlphaComponent(0.1)
        )
    }

    /// A user or folder, grouping transfers
    private static func isGroupRow(_ treeView: TreeView, _ row: TreeRow) -> Bool {
        treeView.rowValue(row, "filename").string.isEmpty
    }

    /// Groups, and files that aren't shown in a folder row: ungrouped, or grouped by user
    private static func isTwoLineRow(_ treeView: TreeView, _ row: TreeRow) -> Bool {
        isGroupRow(treeView, row) || row.parent == nil || !treeView.rowValue(row, "path").string.isEmpty
    }

    private static func configure(_ cellView: TransferCellView, treeView: TreeView, row: TreeRow,
                                  direction: TransferDirection) {
        let value = { (columnID: String) in treeView.rowValue(row, columnID) }
        let transfer = value("transfer_data").object(as: Transfer.self)
        let isDimmed = !value("is_sensitive_data").bool
        let progress = TransferCellView.Progress(percent: value("percent").int,
                                                 status: value("status").string,
                                                 queuePosition: value("queue_position").string,
                                                 size: value("size").string,
                                                 speed: value("speed").string,
                                                 timeLeft: value("time_left").string)

        if isGroupRow(treeView, row) {
            // Folders are grouped below their user, whose name is already shown there
            let isFolder = row.parent != nil

            cellView.configure(
                icon: NSImage(systemSymbolName: isFolder ? "folder.fill" : "person.crop.circle",
                              accessibilityDescription: nil),
                title: isFolder ? folderTitle(transfer, direction: direction) : value("user").string,
                subtitle: RowCellView.symbolText("doc", text: humanize(fileCount(treeView, row))),
                progress: progress, isTwoLines: true, isDimmed: isDimmed
            )
            cellView.toolTip = isFolder ? transfer?.folderPath : nil
            return
        }

        let folderPath = value("path").string
        var subtitle: [String] = []

        if row.parent == nil {
            subtitle.append(value("user").string)
        }

        subtitle.append(folderPath)

        cellView.configure(
            icon: Theme.image(forIconName: value("file_type").string),
            title: value("filename").string,
            subtitle: NSAttributedString(string: subtitle.filter { !$0.isEmpty }.joined(separator: separator)),
            progress: progress, isTwoLines: isTwoLineRow(treeView, row), isDimmed: isDimmed
        )
        cellView.toolTip = transfer?.virtualPath
    }

    /// A folder the way its user knows it: an upload below the shared folder it comes from, and a
    /// download below the download folder, so "Music\Album\CD 1" is shown as "Album/CD 1"
    private static func folderTitle(_ transfer: Transfer?, direction: TransferDirection) -> String {
        guard let transfer else {
            return ""
        }

        if direction == .upload {
            // Shared paths start with the name of the shared folder
            let folders = transfer.folderPath.components(separatedBy: "\\")
            return folders.count > 1 ? folders.dropFirst().joined(separator: "/") : transfer.folderPath
        }

        let downloadFolderPath = core.downloads.defaultDownloadFolder(username: transfer.username)
        let folderPath = transfer.folderPath.isEmpty ? downloadFolderPath : transfer.folderPath

        if folderPath.hasPrefix(downloadFolderPath + "/") {
            return String(folderPath.dropFirst(downloadFolderPath.count + 1))
        }
        return (folderPath as NSString).lastPathComponent
    }

    /// Number of files below a user or folder, which are grouped in folders below a user
    private static func fileCount(_ treeView: TreeView, _ row: TreeRow) -> Int {
        treeView.children(of: row).reduce(0) { count, child in
            count + (isGroupRow(treeView, child) ? fileCount(treeView, child) : 1)
        }
    }
}

// MARK: - Cell View

private final class TransferCellView: RowCellView {

    /// How far a transfer has come, and how fast
    struct Progress {
        let percent: Int
        let status: String
        let queuePosition: String
        let size: String
        let speed: String
        let timeLeft: String
    }

    static let identifier = NSUserInterfaceItemIdentifier("TransferCell")

    private let statusLabel = RowCellView.detailLabel(width: 104)
    private let queueLabel = RowCellView.detailLabel(width: 34)
    private let progressBar = ProgressBarView()
    private let sizeLabel = RowCellView.detailLabel(width: 104)
    private let speedLabel = RowCellView.detailLabel(width: 64)
    private let timeLeftLabel = RowCellView.detailLabel(width: 48)

    init() {
        super.init(identifier: Self.identifier)

        statusLabel.alignment = .left
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: 54).isActive = true
        progressBar.heightAnchor.constraint(equalToConstant: 5).isActive = true

        for view in [statusLabel, queueLabel, progressBar, sizeLabel, speedLabel, timeLeftLabel] as [NSView] {
            trailingStack.addArrangedSubview(view)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(icon: NSImage?, title: String, subtitle: NSAttributedString?, progress: Progress,
                   isTwoLines: Bool, isDimmed: Bool) {
        configure(icon: icon, title: title, subtitle: subtitle, isTwoLines: isTwoLines, isDimmed: isDimmed)

        statusLabel.stringValue = progress.status
        statusLabel.toolTip = progress.status

        queueLabel.stringValue = progress.queuePosition.isEmpty ? "" : "#\(progress.queuePosition)"
        queueLabel.toolTip = String(localized: "Queue")

        progressBar.percent = progress.percent
        progressBar.needsDisplay = true

        sizeLabel.stringValue = progress.size
        speedLabel.stringValue = progress.speed
        timeLeftLabel.stringValue = progress.timeLeft
    }
}

/// How much of a transfer is finished, as a bar.
private final class ProgressBarView: NSView {

    var percent = 0

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2

        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let fraction = Double(max(0, min(percent, 100))) / 100

        guard fraction > 0 else {
            return
        }

        let filled = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * fraction), height: bounds.height)
        (percent >= 100 ? NSColor.systemGreen : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
