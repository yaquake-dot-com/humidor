// SPDX-License-Identifier: GPL-3.0-or-later
//
// Development aid: when NICOTINE_SNAPSHOT_DIR is set in debug builds, sending
// SIGUSR1 to the process saves an image of each visible window to that folder.

#if DEBUG

import AppKit

@MainActor
enum WindowSnapshots {

    private static var signalSource: DispatchSourceSignal?

    static func enableIfRequested() {
        guard let folderPath = ProcessInfo.processInfo.environment["NICOTINE_SNAPSHOT_DIR"] else {
            return
        }

        signal(SIGUSR1, SIG_IGN)

        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                save(to: folderPath)
            }
        }
        source.resume()
        signalSource = source
    }

    private static func save(to folderPath: String) {
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
}

#endif
