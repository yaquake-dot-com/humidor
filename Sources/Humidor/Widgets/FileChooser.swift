// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import HumidorCore
import SwiftUI
import UniformTypeIdentifiers

/// Open and save panels for files and folders.
@MainActor
enum FileChooser {

    static func chooseFiles(title: String = String(localized: "Select a File"), initialFolder: String? = nil,
                            selectMultiple: Bool = false, callback: @escaping @MainActor ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = selectMultiple
        present(panel, initialFolder: initialFolder, callback: callback)
    }

    static func chooseFolders(title: String = String(localized: "Select a Folder"), initialFolder: String? = nil,
                              selectMultiple: Bool = false, callback: @escaping @MainActor ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.prompt = String(localized: "Select")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = selectMultiple
        present(panel, initialFolder: initialFolder, callback: callback)
    }

    static func chooseImage(title: String = String(localized: "Select an Image"), initialFolder: String? = nil,
                            callback: @escaping @MainActor ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        present(panel, initialFolder: initialFolder, callback: callback)
    }

    static func saveFile(title: String = String(localized: "Save as…"), initialFolder: String? = nil,
                         initialFile: String = "", callback: @escaping @MainActor ([String]) -> Void) {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = initialFile
        panel.canCreateDirectories = true
        present(panel, initialFolder: initialFolder, callback: callback)
    }

    private static func present(_ panel: NSSavePanel, initialFolder: String?,
                                callback: @escaping @MainActor ([String]) -> Void) {
        if let initialFolder, !initialFolder.isEmpty {
            let folderPath = config.expandingDataFolder(initialFolder)
            try? FileManager.default.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
            panel.directoryURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        }

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else {
                return
            }

            let urls = (panel as? NSOpenPanel)?.urls ?? panel.url.map { [$0] } ?? []

            MainActor.assumeIsolated {
                callback(urls.map(\.path))
            }
        }

        if let window = NSApp.keyWindow ?? MainWindow.shared?.window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

// MARK: - File Chooser Button

/// Button showing a selected file or folder path, used in preferences.
struct FileChooserButton: View {

    enum ChooserType {
        case file
        case folder
        case image
    }

    @Binding var path: String
    var chooserType = ChooserType.folder
    var title: String?
    var showsOpenButton = true

    var body: some View {
        HStack(spacing: 6) {
            Button {
                onOpenFileChooser()
            } label: {
                HStack {
                    Image(systemName: chooserType == .folder ? "folder" : "doc")
                    Text(displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .help(expandedPath)

            if showsOpenButton && !path.isEmpty {
                Button {
                    onOpenFolder()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help(String(localized: "Open in File Manager"))
            }
        }
    }

    private var expandedPath: String {
        config.expandingDataFolder(path)
    }

    private var displayPath: String {
        guard !path.isEmpty else {
            return String(localized: "(None)")
        }

        let expandedPath = self.expandedPath
        return chooserType == .folder
            ? expandedPath
            : (expandedPath as NSString).lastPathComponent
    }

    private func onOpenFileChooser() {
        let initialFolder = path.isEmpty
            ? nil
            : (chooserType == .folder ? expandedPath : (expandedPath as NSString).deletingLastPathComponent)

        let callback: @MainActor ([String]) -> Void = { paths in
            guard var selectedPath = paths.first else {
                return
            }

            // Use the data folder placeholder for paths inside the data folder
            let dataFolderPath = config.dataFolderPath

            if selectedPath.hasPrefix(dataFolderPath) {
                selectedPath = Config.dataFolderPlaceholder + selectedPath.dropFirst(dataFolderPath.count)
            }

            path = selectedPath
        }

        switch chooserType {
        case .file:
            FileChooser.chooseFiles(title: title ?? String(localized: "Select a File"), initialFolder: initialFolder,
                                    callback: callback)
        case .folder:
            FileChooser.chooseFolders(title: title ?? String(localized: "Select a Folder"),
                                      initialFolder: initialFolder, callback: callback)
        case .image:
            FileChooser.chooseImage(title: title ?? String(localized: "Select an Image"),
                                    initialFolder: initialFolder, callback: callback)
        }
    }

    private func onOpenFolder() {
        let folderPath = chooserType == .folder ? expandedPath : (expandedPath as NSString).deletingLastPathComponent
        _ = openFolderPath(folderPath, createFolder: true)
    }
}
