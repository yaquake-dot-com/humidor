// SPDX-License-Identifier: GPL-3.0-or-later
//
// Development aids, only available in debug builds when NICOTINE_DEBUG_DIR is set:
// - SIGUSR1 saves an image of each visible window to that folder
// - SIGUSR2 runs the actions listed in the "actions" file in that folder, one per line

#if DEBUG

import AppKit
import NicotineCore

@MainActor
enum DebugHooks {

    private static var signalSources: [DispatchSourceSignal] = []

    static func enableIfRequested() {
        guard let folderPath = ProcessInfo.processInfo.environment["NICOTINE_DEBUG_DIR"] else {
            return
        }

        for signalType in [SIGUSR1, SIGUSR2] {
            signal(signalType, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: signalType, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    if signalType == SIGUSR1 {
                        saveSnapshots(to: folderPath)
                    } else {
                        runActions(from: folderPath)
                    }
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private static func saveSnapshots(to folderPath: String) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                continue
            }

            view.cacheDisplay(in: view.bounds, to: bitmap)

            let filePath = (folderPath as NSString).appendingPathComponent("window-\(index).png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: filePath))
        }
    }

    private static func runActions(from folderPath: String) {
        let filePath = (folderPath as NSString).appendingPathComponent("actions")

        guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return
        }

        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""

            switch parts.first {
            case "search": core.search.doSearch(argument, mode: .global)
            case "page": MainWindow.shared?.changeMainPage(MainWindow.Page(rawValue: argument) ?? .search)
            case "browse": core.userBrowse.browseUser(argument)
            case "userinfo": core.userInfo.showUser(argument)
            case "join": core.chatrooms.showRoom(argument)
            case "message": core.privateChat.showUser(argument)
            case "select-all": (NSApp.keyWindow?.firstResponder as? NSTableView)?.selectAll(nil)
            default: break
            }
        }
    }
}

#endif
