// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Row of a list drawn like the lists of Music: an icon, one or two lines of text, and details
/// aligned in columns at the trailing edge. Subclasses add their details to `trailingStack`.
class RowCellView: NSTableCellView {

    /// Height of a row with a title and a subtitle
    static let twoLineHeight: CGFloat = 46
    /// Height of a row with a title alone
    static let oneLineHeight: CGFloat = 26

    /// Details at the trailing edge, filled by subclasses
    let trailingStack = NSStackView()

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private var iconWidth: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor

        for label in [titleLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleLabel.textColor = .secondaryLabelColor

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        trailingStack.orientation = .horizontal
        trailingStack.spacing = 6
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A column of details, as wide as the widest value it shows
    static func detailLabel(width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    /// A symbol followed by a value, such as the number of files of a folder
    static func symbolText(_ symbolName: String, text: String) -> NSAttributedString {
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

    func configure(icon: NSImage?, title: String, subtitle: NSAttributedString?, isTwoLines: Bool, isDimmed: Bool) {
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
    }
}
