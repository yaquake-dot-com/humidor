// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// Reads commands and prompt responses from standard input on a background
/// thread.
final class CLIInputProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private var promptMessage = ""
    private var promptCallback: (@MainActor @Sendable (String) -> Void)?
    private var promptSilent = false
    private var customPromptActive = false
    private var thread: Thread?

    var hasCustomPrompt: Bool {
        lock.withLock { customPromptActive }
    }

    func setPrompt(_ message: String, callback: @escaping @MainActor @Sendable (String) -> Void, isSilent: Bool) {
        lock.withLock {
            promptMessage = message
            promptCallback = callback
            promptSilent = isSilent
        }
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "CLIInputProcessor"
        self.thread = thread
        thread.start()
    }

    private func run() {
        while true {
            // Small time window to set custom prompt
            Thread.sleep(forTimeInterval: 0.25)

            guard handlePrompt() else {
                log.addDebug("CLI input prompt is no longer available")
                return
            }
        }
    }

    private static func readSilently(_ message: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)

        guard let result = readpassphrase(message, &buffer, buffer.count, 0) else {
            return nil
        }

        return String(cString: result)
    }

    /// Returns false when standard input is no longer available.
    private func handlePrompt() -> Bool {
        let (message, callback, isSilent) = lock.withLock {
            customPromptActive = promptCallback != nil
            return (promptMessage, promptCallback, promptSilent)
        }

        let userInput: String?

        if isSilent {
            userInput = Self.readSilently(message)
        } else {
            print(message, terminator: "")
            fflush(stdout)
            userInput = readLine()
        }

        guard let userInput else {
            return false
        }

        lock.withLock {
            customPromptActive = false
            promptMessage = ""
            promptCallback = nil
            promptSilent = false
        }

        events.emitMainThread(.cliPromptFinished)

        // Check if custom prompt is active
        if let callback {
            events.invokeMainThread { callback(userInput) }
            return true
        }

        // No custom prompt, treat input as command
        handlePromptCommand(userInput)
        return true
    }

    private func handlePromptCommand(_ userInput: String) {
        let trimmed = userInput.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            return
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        var command = String(parts[0])
        let args = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        if command.hasPrefix("/") {
            command.removeFirst()
        }

        events.emitMainThread(.cliCommand, CLICommand(command: command, args: args))
    }
}

/// Command line interface, used in headless mode.
@MainActor
public final class CLI {
    private let inputProcessor = CLIInputProcessor()
    private var logMessageQueue: [String] = []
    private var ttyAttributes: termios?

    nonisolated init() {}

    public func enablePrompt() {
        var attributes = termios()

        if tcgetattr(STDIN_FILENO, &attributes) == 0 {
            ttyAttributes = attributes
        }

        events.connect(.quit) { [self] in quit() }
        inputProcessor.start()
    }

    public func enableLogging() {
        events.connect(.cliPromptFinished) { [self] in cliPromptFinished() }
        events.connect(.logMessage) { [self] message in logMessage(message) }
    }

    public func prompt(_ message: String, isSilent: Bool = false,
                       callback: @escaping @MainActor @Sendable (String) -> Void) {
        inputProcessor.setPrompt(message, callback: callback, isSilent: isSilent)
    }

    private func printLogMessage(_ message: String) {
        print(message)
        fflush(stdout)
    }

    private func cliPromptFinished() {
        for message in logMessageQueue {
            printLogMessage(message)
        }
        logMessageQueue.removeAll()
    }

    private func logMessage(_ message: LogMessage) {
        let logMessage: String

        if !message.timestampFormat.isEmpty {
            logMessage = "[\(formatTimestamp(message.timestampFormat))] \(message.message)"
        } else {
            logMessage = message.message
        }

        if inputProcessor.hasCustomPrompt {
            // Don't print log messages while custom prompt is active
            logMessageQueue.append(logMessage)

            if logMessageQueue.count > 1000 {
                logMessageQueue.removeFirst()
            }
            return
        }

        printLogMessage(logMessage)
    }

    /// Restores TTY attributes and re-enables echo on quit.
    private func quit() {
        guard var attributes = ttyAttributes else {
            return
        }

        tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
        ttyAttributes = nil
    }
}

@MainActor public let cli = CLI()
