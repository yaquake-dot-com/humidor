// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore

/// Rows of search results, drawn like the lists of Music: a folder or user on two lines, with a
/// summary of its files, and the files below it on one line each.
@MainActor
enum SearchResultRows {

    private static let groupRowHeight: CGFloat = 46
    private static let fileRowHeight: CGFloat = 26
    private static let separator = "  ·  "

    static let presentation = TreeRowPresentation(
        height: { treeView, row in
            isTwoLineRow(treeView, row) ? groupRowHeight : fileRowHeight
        },
        view: { treeView, row in
            let cellView = treeView.outlineView.makeView(withIdentifier: ResultCellView.identifier, owner: nil)
                as? ResultCellView ?? ResultCellView()
            configure(cellView, treeView: treeView, row: row)
            return cellView
        }
    )

    /// A folder or user, grouping files
    private static func isGroupRow(_ treeView: TreeView, _ row: TreeRow) -> Bool {
        treeView.rowValue(row, "filename").string.isEmpty
    }

    /// Groups, and files that aren't shown in a folder row: ungrouped, or grouped by user
    private static func isTwoLineRow(_ treeView: TreeView, _ row: TreeRow) -> Bool {
        isGroupRow(treeView, row) || row.parent == nil || !treeView.rowValue(row, "folder").string.isEmpty
    }

    private static func configure(_ cellView: ResultCellView, treeView: TreeView, row: TreeRow) {
        let value = { (columnID: String) in treeView.rowValue(row, columnID) }
        let hasFreeSlot = value("free_slot_data").bool
        let path = value("file_data").object(as: ResultFile.self)?.path ?? ""

        if isGroupRow(treeView, row) {
            let isFolder = !value("folder").string.isEmpty
            let files = treeView.children(of: row)
            let title = isFolder ? (path.components(separatedBy: "\\").last ?? value("folder").string) : value("user").string

            cellView.configure(
                icon: NSImage(systemSymbolName: isFolder ? "folder.fill" : "person.crop.circle",
                              accessibilityDescription: nil),
                title: title,
                subtitle: groupSummary(treeView, row: row, files: files, showsUser: isFolder),
                detail: nil,
                status: slotStatus(hasFreeSlot: hasFreeSlot, queue: value("in_queue").string),
                isTwoLines: true,
                isDimmed: !hasFreeSlot
            )
            cellView.toolTip = isFolder ? value("folder").string : nil
            return
        }

        let icon = Theme.image(forIconName: value("file_type").string)
        let detail = ResultCellView.Detail(quality: value("quality").string, length: value("length").string,
                                           size: value("size").string)

        if row.parent == nil || !value("folder").string.isEmpty {
            // Ungrouped results, or files grouped by user: show where the file is
            var subtitle: [String] = []

            if row.parent == nil {
                subtitle.append(userText(treeView, row: row))
            }
            subtitle.append(value("folder").string)

            if row.parent == nil {
                subtitle.append(value("speed").string)
            }

            cellView.configure(icon: icon, title: value("filename").string,
                               subtitle: plainText(subtitle.filter { !$0.isEmpty }.joined(separator: separator)),
                               detail: detail,
                               status: row.parent == nil
                                   ? slotStatus(hasFreeSlot: hasFreeSlot, queue: value("in_queue").string) : nil,
                               isTwoLines: true, isDimmed: !hasFreeSlot)
        } else {
            cellView.configure(icon: icon, title: value("filename").string, subtitle: nil, detail: detail,
                               status: nil, isTwoLines: false, isDimmed: !hasFreeSlot)
        }

        cellView.toolTip = path
    }

    // MARK: Summaries

    private static func userText(_ treeView: TreeView, row: TreeRow) -> String {
        let user = treeView.rowValue(row, "user").string
        let flag = Theme.text(forIconName: treeView.rowValue(row, "country").string) ?? ""
        return flag.isEmpty ? user : "\(user) \(flag)"
    }

    /// Format, number of files, total size and speed of the files in a folder or of a user
    private static func groupSummary(_ treeView: TreeView, row: TreeRow, files: [TreeRow],
                                     showsUser: Bool) -> NSAttributedString {
        let summary = NSMutableAttributedString()
        var parts: [NSAttributedString] = []

        if showsUser {
            parts.append(plainText(userText(treeView, row: row)))
        }

        if let format = formatText(treeView, files: files) {
            parts.append(plainText(format))
        }

        let fileCount = files.count
        let totalSize = files.reduce(0) { $0 + treeView.rowValue($1, "size_data").int }

        parts.append(symbolText("doc", text: humanize(fileCount)))
        parts.append(plainText(humanSize(totalSize)))
        parts.append(symbolText("arrow.down", text: treeView.rowValue(row, "speed").string))

        for (index, part) in parts.enumerated() {
            if index > 0 {
                summary.append(plainText(separator))
            }
            summary.append(part)
        }
        return summary
    }

    /// The most common file type, with its quality when all files of that type share it
    private static func formatText(_ treeView: TreeView, files: [TreeRow]) -> String? {
        var counts: [String: Int] = [:]

        for file in files {
            let fileExtension = (treeView.rowValue(file, "filename").string as NSString).pathExtension.lowercased()

            if !fileExtension.isEmpty {
                counts[fileExtension, default: 0] += 1
            }
        }

        // Audio files describe a folder better than the pictures and documents next to them
        let audioCounts = counts.filter { FileTypes.audio.contains($0.key) }
        let candidates = audioCounts.isEmpty ? counts : audioCounts

        guard let fileExtension = candidates.max(by: { $0.value < $1.value })?.key else {
            return nil
        }

        let qualities = Set(files
            .filter { (treeView.rowValue($0, "filename").string as NSString).pathExtension.lowercased() == fileExtension }
            .map { treeView.rowValue($0, "quality").string })

        let format = fileExtension.uppercased()

        if qualities.count == 1, let quality = qualities.first, !quality.isEmpty {
            return "\(format) \(quality)"
        }
        return format
    }

    private static func slotStatus(hasFreeSlot: Bool, queue: String) -> ResultCellView.Status {
        hasFreeSlot
            ? .init(symbolName: "checkmark.circle.fill", text: nil, color: .systemGreen,
                    tooltip: String(localized: "Free Slot"))
            : .init(symbolName: "hourglass", text: queue, color: .secondaryLabelColor,
                    tooltip: String(localized: "In Queue"))
    }

    private static func plainText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text)
    }

    private static func symbolText(_ symbolName: String, text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let attachment = NSTextAttachment()
            attachment.image = image.withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " "))
        }

        result.append(NSAttributedString(string: text))
        return result
    }
}

// MARK: - Cell View

private final class ResultCellView: NSTableCellView {

    /// Quality, duration and size of a file, aligned in columns
    struct Detail {
        let quality: String
        let length: String
        let size: String
    }

    struct Status {
        let symbolName: String
        let text: String?
        let color: NSColor
        let tooltip: String
    }

    static let identifier = NSUserInterfaceItemIdentifier("SearchResultCell")

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let qualityLabel = NSTextField(labelWithString: "")
    private let lengthLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let trailingStack = NSStackView()
    private var iconWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor

        for label in [titleLabel, subtitleLabel, qualityLabel, lengthLabel, sizeLabel, statusLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleLabel.textColor = .secondaryLabelColor
        for (label, width) in [(qualityLabel, 130.0), (lengthLabel, 44.0), (sizeLabel, 72.0)] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        statusLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        trailingStack.orientation = .horizontal
        trailingStack.spacing = 6
        trailingStack.addArrangedSubview(qualityLabel)
        trailingStack.addArrangedSubview(lengthLabel)
        trailingStack.addArrangedSubview(sizeLabel)
        trailingStack.addArrangedSubview(statusLabel)
        trailingStack.addArrangedSubview(statusIcon)
        trailingStack.setContentHuggingPriority(.required, for: .horizontal)

        for view in [iconView, textStack, trailingStack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        iconWidth = iconView.widthAnchor.constraint(equalToConstant: 16)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingStack.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 12),
            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        textField = titleLabel
        imageView = iconView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(icon: NSImage?, title: String, subtitle: NSAttributedString?, detail: Detail?, status: Status?,
                   isTwoLines: Bool, isDimmed: Bool) {
        iconView.image = icon
        iconWidth.constant = isTwoLines ? 22 : 16

        titleLabel.stringValue = title
        titleLabel.font = isTwoLines
            ? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            : .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.textColor = isDimmed ? .secondaryLabelColor : .labelColor

        if let subtitle, isTwoLines {
            subtitleLabel.attributedStringValue = subtitle
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.isHidden = true
        }

        qualityLabel.stringValue = detail?.quality ?? ""
        lengthLabel.stringValue = detail?.length ?? ""
        sizeLabel.stringValue = detail?.size ?? ""

        for label in [qualityLabel, lengthLabel, sizeLabel] {
            label.isHidden = (detail == nil)
        }

        if let status {
            statusIcon.image = NSImage(systemSymbolName: status.symbolName, accessibilityDescription: status.tooltip)
            statusIcon.contentTintColor = status.color
            statusIcon.toolTip = status.tooltip
            statusIcon.isHidden = false
            statusLabel.stringValue = status.text ?? ""
            statusLabel.isHidden = (status.text ?? "").isEmpty
            statusLabel.toolTip = status.tooltip
        } else {
            statusIcon.isHidden = true
            statusLabel.isHidden = true
        }
    }
}
