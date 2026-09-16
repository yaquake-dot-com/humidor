// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opening files, folders and URLs with external applications.

import AppKit
import Foundation

private func openWithSystem(_ url: URL) -> Bool {
    NSWorkspace.shared.open(url)
}

/// Opens a folder, or plays an audio file. Tries to run a user-specified
/// command first, and falls back to the system default.
@MainActor
@discardableResult
private func openPath(_ path: String, isFolder: Bool = false, createFolder: Bool = false,
                      createFile: Bool = false) -> Bool {
    let path = URL(fileURLWithPath: path).standardizedFileURL.path

    do {
        let protocolHandlers = config.urls.protocols
        let fileManagerCommand = config.ui.fileManager
        var protocolCommand: String?
        let fileExtension = (path as NSString).pathExtension.lowercased()

        if !fileExtension.isEmpty {
            let protocolName: String?

            if protocolHandlers[".\(fileExtension)"] != nil {
                protocolName = ".\(fileExtension)"
            } else if FileTypes.audio.contains(fileExtension) {
                protocolName = "audio"
            } else if FileTypes.image.contains(fileExtension) {
                protocolName = "image"
            } else if FileTypes.video.contains(fileExtension) {
                protocolName = "video"
            } else if FileTypes.document.contains(fileExtension) {
                protocolName = "document"
            } else if FileTypes.text.contains(fileExtension) {
                protocolName = "text"
            } else if FileTypes.archive.contains(fileExtension) {
                protocolName = "archive"
            } else {
                protocolName = nil
            }

            protocolCommand = protocolName.flatMap { protocolHandlers[$0] }
        }

        if !FileManager.default.fileExists(atPath: path) {
            if createFolder {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            } else if createFile {
                FileManager.default.createFile(atPath: path, contents: nil)
            } else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "File path does not exist"])
            }
        }

        if isFolder && fileManagerCommand.contains("$") {
            try executeCommand(fileManagerCommand, replacement: path)

        } else if let protocolCommand, !protocolCommand.isEmpty {
            try executeCommand(protocolCommand, replacement: path)

        } else if !openWithSystem(URL(fileURLWithPath: path)) {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "No application available"])
        }

    } catch {
        log.add(String(localized: "Cannot open file path \(path): \(error.localizedDescription)", bundle: .module))
        return false
    }

    return true
}

@MainActor
@discardableResult
public func openFilePath(_ filePath: String, createFile: Bool = false) -> Bool {
    openPath(filePath, createFile: createFile)
}

@MainActor
@discardableResult
public func openFolderPath(_ folderPath: String, createFolder: Bool = false) -> Bool {
    openPath(folderPath, isFolder: true, createFolder: createFolder)
}

/// Opens a URI in an external (web) browser. The URI has to be properly
/// formed, including the scheme.
@MainActor
@discardableResult
public func openURI(_ uri: String) -> Bool {
    do {
        // Situation 1, user defined a way of handling the protocol
        let protocolName = uri.firstIndex(of: ":").map { String(uri[..<$0]) } ?? uri
        let fileTypeProtocols: Set<String> = ["audio", "image", "video", "document", "text", "archive"]

        if !protocolName.hasPrefix(".") && !fileTypeProtocols.contains(protocolName) {
            let protocolHandlers = config.urls.protocols

            if let protocolCommand = protocolHandlers[protocolName + "://"] ?? protocolHandlers[protocolName],
               !protocolCommand.isEmpty {
                try executeCommand(protocolCommand, replacement: uri)
                return true
            }

            if protocolName == "slsk" {
                core.userBrowse.openSoulseekURL(uri.trimmingCharacters(in: .whitespaces))
                return true
            }
        }

        // Situation 2, user did not define a way of handling the protocol
        guard let url = URL(string: uri), openWithSystem(url) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "No known URI provider available"])
        }

        return true

    } catch {
        log.add(String(localized: "Cannot open URL \(uri): \(error.localizedDescription)", bundle: .module))
    }

    return false
}
