// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore
import UniformTypeIdentifiers

/// Rows of the downloads and uploads, drawn like the items of a download manager: each folder (or
/// user, or file, depending on the grouping) with its progress on a bar, and its files on one line
/// each below it, shown with the disclosure triangle.
@MainActor
enum TransferRows {

    private static let itemHeight: CGFloat = 72
    private static let separator = "  ·  "

    static func presentation(for direction: TransferDirection) -> TreeRowPresentation {
        TreeRowPresentation(
            height: { treeView, row in
                if row.parent == nil {
                    return itemHeight
                }
                return treeView.rowValue(row, "path").string.isEmpty ? RowCellView.oneLineHeight
                                                                      : RowCellView.twoLineHeight
            },
            view: { treeView, row in
                let outlineView = treeView.outlineView

                if row.parent == nil {
                    let cellView = outlineView.makeView(withIdentifier: TransferItemCellView.identifier, owner: nil)
                        as? TransferItemCellView ?? TransferItemCellView()
                    configureItem(cellView, treeView: treeView, row: row, direction: direction)
                    return cellView
                }

                let cellView = outlineView.makeView(withIdentifier: TransferCellView.identifier, owner: nil)
                    as? TransferCellView ?? TransferCellView()
                configureFile(cellView, treeView: treeView, row: row, direction: direction)
                return cellView
            },
            isExpandable: { treeView, row in
                // A folder or user with a single file is shown as that file
                treeView.children(of: row).count > 1
            }
        )
    }

    // MARK: Items

    private static func configureItem(_ cellView: TransferItemCellView, treeView: TreeView, row: TreeRow,
                                      direction: TransferDirection) {
        let value = { (columnID: String) in treeView.rowValue(row, columnID) }
        let children = treeView.children(of: row)
        // A folder or user with a single file is shown as that file
        let fileRow = value("filename").string.isEmpty ? (children.count == 1 ? children.first : nil) : row
        let transfer = treeView.rowValue(fileRow ?? row, "transfer_data").object(as: Transfer.self)
        let user = value("user").string
        let isGroup = fileRow == nil
        let isFolder = isGroup && !value("path").string.isEmpty

        let icon: NSImage?
        let title: String
        let info = NSMutableAttributedString()

        if isFolder {
            icon = NSWorkspace.shared.icon(for: .folder)
            title = folderTitle(transfer?.folderPath ?? "", username: user, direction: direction)
            append(RowCellView.symbolText("person", text: user), to: info)

        } else if isGroup {
            icon = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 26, weight: .light))
            title = user

        } else {
            let filename = treeView.rowValue(fileRow ?? row, "filename").string
            icon = fileIcon(filename)
            title = filename
            append(RowCellView.symbolText("person", text: user), to: info)

            if let transfer {
                append(NSAttributedString(string: folderTitle(fileFolderPath(transfer, direction: direction),
                                                              username: user, direction: direction)), to: info)
            }
        }

        if isGroup {
            append(RowCellView.symbolText("doc", text: humanize(children.count)), to: info)
        }

        append(NSAttributedString(string: value("size").string), to: info)

        cellView.configure(icon: icon, title: title, info: info,
                           status: statusText(treeView, row: row, direction: direction),
                           percent: value("percent").int,
                           progressColor: progressColor(transfer, percent: value("percent").int, direction: direction),
                           isDimmed: !value("is_sensitive_data").bool)
        cellView.toolTip = isFolder ? transfer?.folderPath : (isGroup ? nil : transfer?.virtualPath)
    }

    /// Status, speed, time left and place in the queue
    private static func statusText(_ treeView: TreeView, row: TreeRow, direction: TransferDirection)
        -> NSAttributedString {
        let value = { (columnID: String) in treeView.rowValue(row, columnID) }
        let status = NSMutableAttributedString()

        append(NSAttributedString(string: value("status").string), to: status)

        if !value("speed").string.isEmpty {
            append(RowCellView.symbolText(direction == .download ? "arrow.down" : "arrow.up",
                                          text: value("speed").string), to: status)
        }

        if !value("time_left").string.isEmpty {
            append(RowCellView.symbolText("clock", text: value("time_left").string), to: status)
        }

        if !value("queue_position").string.isEmpty {
            append(NSAttributedString(string: "#\(value("queue_position").string)"), to: status)
        }

        return status
    }

    private static func append(_ part: NSAttributedString, to text: NSMutableAttributedString) {
        guard part.length > 0 else {
            return
        }

        if text.length > 0 {
            text.append(NSAttributedString(string: separator))
        }
        text.append(part)
    }

    // MARK: Files

    private static func configureFile(_ cellView: TransferCellView, treeView: TreeView, row: TreeRow,
                                      direction: TransferDirection) {
        let value = { (columnID: String) in treeView.rowValue(row, columnID) }
        let transfer = value("transfer_data").object(as: Transfer.self)
        let folderPath = value("path").string

        cellView.configure(
            icon: Theme.image(forIconName: value("file_type").string),
            title: value("filename").string,
            // Files grouped by user show their folder
            subtitle: NSAttributedString(string: folderPath),
            progress: TransferCellView.Progress(percent: value("percent").int,
                                                color: progressColor(transfer, percent: value("percent").int,
                                                                     direction: direction),
                                                status: value("status").string,
                                                queuePosition: value("queue_position").string,
                                                size: value("size").string,
                                                speed: value("speed").string,
                                                timeLeft: value("time_left").string),
            isTwoLines: !folderPath.isEmpty, isDimmed: !value("is_sensitive_data").bool
        )
        cellView.toolTip = transfer?.virtualPath

        // Files start where the progress bar of their folder does, one level of indentation further
        cellView.leadingInset = max(2, TransferItemCellView.textLeading - treeView.outlineView.indentationPerLevel)
    }

    // MARK: Values

    /// The icon of the kind of a file. The icon of its own type can be the one of whatever
    /// application opens it, which doesn't tell a song from a picture.
    private static func fileIcon(_ filename: String) -> NSImage {
        let fileType = UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
        let kind = [UTType.audio, .movie, .image, .archive, .text].first { fileType.conforms(to: $0) } ?? .data
        return NSWorkspace.shared.icon(for: kind)
    }

    /// The color of the direction while transferring, as the speeds in the sidebar and in the Dock,
    /// green once finished, and gray while waiting
    private static func progressColor(_ transfer: Transfer?, percent: Int, direction: TransferDirection)
        -> NSColor {
        if percent >= 100 {
            return .systemGreen
        }

        if transfer?.status == .transferring {
            return direction == .download ? .systemBlue : .systemGreen
        }
        return .tertiaryLabelColor
    }

    /// The folder of a file: where a download is saved, or the shared folder an upload comes from
    private static func fileFolderPath(_ transfer: Transfer, direction: TransferDirection) -> String {
        guard direction == .upload else {
            return transfer.folderPath
        }
        return transfer.virtualPath.components(separatedBy: "\\").dropLast().joined(separator: "\\")
    }

    /// A folder the way its user knows it: an upload below the shared folder it comes from, and a
    /// download below the download folder, so "Music\Album\CD 1" is shown as "Album/CD 1"
    private static func folderTitle(_ folderPath: String, username: String, direction: TransferDirection) -> String {
        if direction == .upload {
            // Shared paths start with the name of the shared folder
            let folders = folderPath.components(separatedBy: "\\")
            return folders.count > 1 ? folders.dropFirst().joined(separator: "/") : folderPath
        }

        let downloadFolderPath = core.downloads.defaultDownloadFolder(username: username)
        let folderPath = folderPath.isEmpty ? downloadFolderPath : folderPath

        if folderPath.hasPrefix(downloadFolderPath + "/") {
            return String(folderPath.dropFirst(downloadFolderPath.count + 1))
        }
        return (folderPath as NSString).lastPathComponent
    }
}

// MARK: - Item Cell View

/// A folder, user or file with its progress: its name, a summary, a bar and its status.
private final class TransferItemCellView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("TransferItemCell")

    private static let iconSize: CGFloat = 32
    /// Where the name, summary, bar and status start
    static let textLeading: CGFloat = 2 + iconSize + 10

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")
    private let progressBar = ProgressBarView()
    private let statusLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .secondaryLabelColor

        for label in [titleLabel, infoLabel, statusLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        for label in [infoLabel, statusLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
        }

        let stack = NSStackView(views: [titleLabel, infoLabel, progressBar, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.setCustomSpacing(4, after: infoLabel)
        stack.setCustomSpacing(4, after: progressBar)

        for view in [iconView, stack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textLeading),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 6)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(icon: NSImage?, title: String, info: NSAttributedString, status: NSAttributedString,
                   percent: Int, progressColor: NSColor, isDimmed: Bool) {
        iconView.image = icon
        titleLabel.stringValue = title
        titleLabel.textColor = isDimmed ? .secondaryLabelColor : .labelColor
        infoLabel.attributedStringValue = info
        statusLabel.attributedStringValue = status
        progressBar.percent = percent
        progressBar.color = progressColor
        progressBar.needsDisplay = true
    }
}

// MARK: - File Cell View

/// A file of a folder or user, on one line, or two when its folder is shown.
private final class TransferCellView: RowCellView {

    /// How far a transfer has come, and how fast
    struct Progress {
        let percent: Int
        let color: NSColor
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
        progressBar.color = progress.color
        progressBar.needsDisplay = true

        sizeLabel.stringValue = progress.size
        speedLabel.stringValue = progress.speed
        timeLeftLabel.stringValue = progress.timeLeft
    }
}

/// How much of a transfer is finished, as a bar.
private final class ProgressBarView: NSView {

    var percent = 0
    var color = NSColor.controlAccentColor

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2

        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let fraction = Double(max(0, min(percent, 100))) / 100

        guard fraction > 0 else {
            return
        }

        let filled = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * fraction), height: bounds.height)
        color.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
