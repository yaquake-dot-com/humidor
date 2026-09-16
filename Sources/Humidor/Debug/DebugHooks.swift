// SPDX-License-Identifier: GPL-3.0-or-later
//
// Development aids, only available in debug builds when NICOTINE_DEBUG_DIR is set:
// - SIGUSR1 saves an image of each visible window to that folder
// - SIGUSR2 runs the actions listed in the "actions" file in that folder, one per line
//   ("ping" writes the current time to the "ping" file, to measure main thread delays)

#if DEBUG

import AppKit
import HumidorCore

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

    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Captures windows as composited by the window server, including glass effects
    private static let windowImage: WindowImageFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        return unsafeBitCast(symbol, to: WindowImageFunction.self)
    }()

    private static func saveSnapshots(to folderPath: String) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            // Window server image: on-screen, list option "including window", "best resolution" and "ignore framing"
            if let windowImage, let image = windowImage(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?
                .takeRetainedValue() {
                let filePath = (folderPath as NSString).appendingPathComponent("window-\(index)-composited.png")
                let bitmap = NSBitmapImageRep(cgImage: image)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: filePath))
            }

            guard let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                continue
            }

            view.cacheDisplay(in: view.bounds, to: bitmap)

            let filePath = (folderPath as NSString).appendingPathComponent("window-\(index).png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: filePath))
        }
    }

    /// Adds the view hierarchy of a window to a development report.
    private static func dumpViews(_ view: NSView, depth: Int = 0, lines: inout [String]) {
        guard depth < 14 else {
            return
        }

        lines.append("VIEW " + String(repeating: "  ", count: depth)
                     + String(describing: type(of: view)) + " \(view.frame)")

        for subview in view.subviews {
            dumpViews(subview, depth: depth + 1, lines: &lines)
        }
    }

    private static func writeReport(_ lines: [String], name: String, to folderPath: String) {
        let filePath = (folderPath as NSString).appendingPathComponent(name)
        try? (lines.joined(separator: "\n") + "\n").write(toFile: filePath, atomically: true, encoding: .utf8)
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
            case "send":
                let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    core.privateChat.sendMessage(parts[0], parts[1])
                }
            case "say":
                let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    core.chatrooms.sendMessage(parts[0], parts[1])
                }
            case "buddy": core.buddies.addBuddy(argument)
            case "wish": core.search.addWish(argument)
            case "dialog":
                switch argument {
                case "wishlist": AppDelegate.shared.onWishlist()
                case "statistics": AppDelegate.shared.onTransferStatistics()
                case "shortcuts": AppDelegate.shared.onKeyboardShortcuts()
                case "preferences": AppDelegate.shared.onPreferences()
                case "setup": AppDelegate.shared.onFastConfigure()
                case "about": AppDelegate.shared.onAbout()
                default: break
                }
            case "preferences": AppDelegate.shared.onPreferences(pageID: argument)
            case "apply-preferences": AppDelegate.shared.preferences.updateSettings()
            case "plugin-settings":
                AppDelegate.shared.onPreferences(pageID: "plugins")
                _ = core.pluginHandler?.enablePlugin(argument)
                AppDelegate.shared.preferences.showPluginSettings(argument)
            case "dump-views":
                var lines: [String] = []

                for window in NSApp.windows where window.isVisible {
                    guard argument.isEmpty || window.title.contains(argument) else {
                        continue
                    }

                    lines.append("WINDOW \(window.title)")

                    if let frameView = window.contentView?.superview {
                        dumpViews(frameView, lines: &lines)
                    }
                }

                writeReport(lines, name: "view-hierarchy.txt", to: folderPath)
            case "window-width":
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == AppWindow.main.rawValue }), let width = Double(argument) {
                    var frame = window.frame
                    frame.size.width = width
                    window.setFrame(frame, display: true)
                }
            case "close-main":
                NSApp.windows.first { $0.identifier?.rawValue == AppWindow.main.rawValue }?.performClose(nil)
            case "present-main":
                MainWindow.shared?.present()
            case "close-tab": _ = MainWindow.shared?.closeTab()
            case "ping":
                let filePath = (folderPath as NSString).appendingPathComponent("ping")
                try? String(Date().timeIntervalSince1970).write(toFile: filePath, atomically: true, encoding: .utf8)
            case "select-all": (NSApp.keyWindow?.firstResponder as? NSTableView)?.selectAll(nil)
            default: break
            }
        }
    }
}

#endif
