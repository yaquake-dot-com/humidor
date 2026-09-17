// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opening files, folders and URLs with external applications.

import AppKit
import Foundation

private func openWithSystem(_ url: URL) -> Bool {
    NSWorkspace.shared.open(url)
}

/// Opens a file or folder with its default application.
@MainActor
@discardableResult
private func openPath(_ path: String, createFolder: Bool = false, createFile: Bool = false) -> Bool {
    let path = URL(fileURLWithPath: path).standardizedFileURL.path

    do {
        if !FileManager.default.fileExists(atPath: path) {
            if createFolder {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            } else if createFile {
                FileManager.default.createFile(atPath: path, contents: nil)
            } else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "File path does not exist"])
            }
        }

        if !openWithSystem(URL(fileURLWithPath: path)) {
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
    openPath(folderPath, createFolder: createFolder)
}

/// Selects a file in a Finder window, or opens its folder if the file doesn't exist.
@MainActor
@discardableResult
public func showInFinder(_ filePath: String) -> Bool {
    guard FileManager.default.fileExists(atPath: filePath) else {
        return openFolderPath((filePath as NSString).deletingLastPathComponent)
    }

    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
    return true
}

/// Opens a URI in an external (web) browser. The URI has to be properly
/// formed, including the scheme.
@MainActor
@discardableResult
public func openURI(_ uri: String) -> Bool {
    do {
        if uri.hasPrefix("slsk:") {
            core.userBrowse.openSoulseekURL(uri.trimmingCharacters(in: .whitespaces))
            return true
        }

        guard let url = URL(string: uri), openWithSystem(url) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "No known URI provider available"])
        }

        return true

    } catch {
        log.add(String(localized: "Cannot open URL \(uri): \(error.localizedDescription)", bundle: .module))
    }

    return false
}
