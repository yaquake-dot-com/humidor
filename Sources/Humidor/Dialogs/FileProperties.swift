// SPDX-License-Identifier: GPL-3.0-or-later

import HumidorCore
import Observation
import SwiftUI

/// Properties of a file, shown in the file properties dialog.
struct FilePropertiesItem {
    var user: String
    var filePath: String
    var basename: String
    var virtualFolderPath: String
    var realFolderPath: String = ""
    var queuePosition: Int = 0
    var speed: Int = 0
    var size: Int
    var fileAttributes: [Int: Int]?
    var countryCode: String?
}

/// Dialog showing the properties of one or more files.
@MainActor
@Observable
final class FileProperties {

    private(set) var properties: [FilePropertiesItem] = []
    private(set) var currentIndex = 0
    @ObservationIgnored private var totalSize = 0
    @ObservationIgnored private var totalLength = 0
    @ObservationIgnored private var dialog: DialogWindow!

    init() {
        dialog = DialogWindow(title: String(localized: "File Properties"), width: 600, height: 380) { [unowned self] in
            FilePropertiesView(fileProperties: self)
        }
    }

    private func updateTitle() {
        let index = currentIndex + 1
        let totalFiles = properties.count
        let totalSize = humanSize(self.totalSize)

        if totalLength > 0 {
            dialog.window.title = String(localized: "File Properties (\(index) of \(totalFiles)  /  \(totalSize)  /  \(humanLength(totalLength)))")
            return
        }

        dialog.window.title = String(localized: "File Properties (\(index) of \(totalFiles)  /  \(totalSize))")
    }

    var currentFile: FilePropertiesItem? {
        properties.indices.contains(currentIndex) ? properties[currentIndex] : nil
    }

    func updateProperties(_ properties: [FilePropertiesItem], totalSize: Int = 0, totalLength: Int = 0) {
        self.properties = properties
        self.totalSize = totalSize
        self.totalLength = totalLength
        currentIndex = 0
        updateTitle()
    }

    func present() {
        dialog.present()
    }

    func onPrevious() {
        currentIndex -= 1

        if currentIndex < 0 {
            currentIndex = properties.count - 1
        }
        updateTitle()
    }

    func onNext() {
        currentIndex += 1

        if currentIndex >= properties.count {
            currentIndex = 0
        }
        updateTitle()
    }
}

private struct FilePropertiesView: View {

    let fileProperties: FileProperties

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let file = fileProperties.currentFile {
                let quality = FileListMessage.parseAudioQualityLength(fileSize: file.size, attributes: file.fileAttributes,
                                                                      alwaysShowBitrate: true)
                let countryName = file.countryCode.flatMap { Countries.names[$0] }
                let country = countryName.map { "\($0) (\(file.countryCode ?? ""))" } ?? ""

                Form {
                    row(String(localized: "Name"), file.basename)
                    // Don't humanize exact size for easier use in filter
                    row(String(localized: "Size"), "\(humanSize(file.size)) (\(file.size) B)")
                    row(String(localized: "Folder"), file.virtualFolderPath)

                    if !file.realFolderPath.isEmpty {
                        row(String(localized: "Path"), file.realFolderPath)
                    }
                    if !quality.humanLength.isEmpty {
                        row(String(localized: "Duration"), quality.humanLength)
                    }
                    if !quality.humanQuality.isEmpty {
                        row(String(localized: "Quality"), quality.humanQuality)
                    }

                    row(String(localized: "Username"), file.user)

                    if file.queuePosition != 0 {
                        row(String(localized: "In Queue"), humanize(file.queuePosition))
                    }
                    if file.speed != 0 {
                        row(String(localized: "Last Speed"), humanSpeed(file.speed))
                    }
                    if !country.isEmpty {
                        row(String(localized: "Country"), country)
                    }
                }
                .formStyle(.grouped)
            }

            if fileProperties.properties.count > 1 {
                HStack {
                    Button {
                        fileProperties.onPrevious()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help(String(localized: "Previous File"))

                    Button {
                        fileProperties.onNext()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .keyboardShortcut(.defaultAction)
                    .help(String(localized: "Next File"))

                    Spacer()
                }
                .padding([.horizontal, .bottom])
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}
