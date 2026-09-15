// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum LogLevel: String, CaseIterable, Codable, Sendable {
    case `default` = "default"
    case download = "download"
    case upload = "upload"
    case search = "search"
    case chat = "chat"
    case connection = "connection"
    case message = "message"
    case transfer = "transfer"
    case miscellaneous = "miscellaneous"

    var prefix: String? {
        switch self {
        case .default: return nil
        case .download: return "Download"
        case .upload: return "Upload"
        case .search: return "Search"
        case .chat: return "Chat"
        case .connection: return "Conn"
        case .message: return "Msg"
        case .transfer: return "Transfer"
        case .miscellaneous: return "Misc"
        }
    }
}

public struct LogMessage: Sendable {
    public let timestampFormat: String
    public let message: String
    public let title: String?
    public let level: LogLevel
}

extension EventName where Payload == LogMessage {
    public static var logMessage: Self { Self("log-message") }
}

/// Formats a date using a strftime(3) format string, as stored in the
/// timestamp preferences.
public func formatTimestamp(_ format: String, date: Date = Date()) -> String {
    var time = time_t(date.timeIntervalSince1970)
    var components = tm()
    localtime_r(&time, &components)

    var buffer = [Int8](repeating: 0, count: 256)
    let length = strftime(&buffer, buffer.count, format, &components)

    return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Application logger. Safe to use from any thread.
public final class Logger: @unchecked Sendable {

    private final class LogFile {
        let path: String
        let handle: FileHandle
        var lastActive: TimeInterval

        init(path: String, handle: FileHandle) {
            self.path = path
            self.handle = handle
            self.lastActive = ProcessInfo.processInfo.systemUptime
        }
    }

    public let debugFileName: String
    public let downloadsFileName: String
    public let uploadsFileName: String

    private let lock = NSRecursiveLock()
    private var logLevels: Set<LogLevel> = [.default]
    private var logFiles: [String: LogFile] = [:]

    // Cached logging preferences, since messages can be logged from any thread
    private var timestampFormat = "%x %X"
    private var isDebugFileOutputEnabled = false
    private var isTransferLoggingEnabled = false

    public private(set) var debugFolderPath: String?
    public private(set) var transferFolderPath: String?
    public private(set) var roomFolderPath: String?
    public private(set) var privateChatFolderPath: String?

    init() {
        let currentDateTime = formatTimestamp("%Y-%m-%d_%H-%M-%S")

        debugFileName = "debug_\(currentDateTime)"
        downloadsFileName = "downloads_\(currentDateTime)"
        uploadsFileName = "uploads_\(currentDateTime)"
    }

    @MainActor
    func enable() {
        events.connect(.quit) { [self] in closeLogFiles() }
        events.schedule(delay: 10, repeat: true) { [self] in closeInactiveLogFiles() }
    }

    // MARK: Preferences

    @MainActor
    public func applyConfig() {
        let logging = config.logging

        lock.withLock {
            timestampFormat = logging.logTimestamp
            isDebugFileOutputEnabled = logging.debugFileOutput
            isTransferLoggingEnabled = logging.transfers
            logLevels = Set([.default] + logging.debugModes)

            debugFolderPath = Self.normalizeFolderPath(logging.debugLogsDir)
            transferFolderPath = Self.normalizeFolderPath(logging.transfersLogsDir)
            roomFolderPath = Self.normalizeFolderPath(logging.roomLogsDir)
            privateChatFolderPath = Self.normalizeFolderPath(logging.privateLogsDir)
        }
    }

    @MainActor
    private static func normalizeFolderPath(_ folderPath: String) -> String {
        (config.expandingDataFolder(folderPath) as NSString).standardizingPath
    }

    // MARK: Log Levels

    public func isLevelEnabled(_ level: LogLevel) -> Bool {
        lock.withLock { logLevels.contains(level) }
    }

    @MainActor
    public func addLogLevel(_ level: LogLevel, isPermanent: Bool = true) {
        _ = lock.withLock { logLevels.insert(level) }

        if isPermanent, !config.logging.debugModes.contains(level) {
            config.logging.debugModes.append(level)
        }
    }

    @MainActor
    public func removeLogLevel(_ level: LogLevel, isPermanent: Bool = true) {
        _ = lock.withLock { logLevels.remove(level) }

        if isPermanent {
            config.logging.debugModes.removeAll { $0 == level }
        }
    }

    // MARK: Log Files

    private func logFilePath(folderPath: String, basename: String) -> String {
        (folderPath as NSString).appendingPathComponent(cleanFile("\(basename).log"))
    }

    private func getLogFile(folderPath: String, basename: String, shouldCreateFile: Bool = true) throws -> LogFile? {
        let filePath = logFilePath(folderPath: folderPath, basename: basename)

        if let logFile = logFiles[filePath] {
            return logFile
        }

        let fileManager = FileManager.default

        if !shouldCreateFile && !fileManager.fileExists(atPath: filePath) {
            return nil
        }

        if !fileManager.fileExists(atPath: folderPath) {
            try fileManager.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: filePath) {
            // Disable file access for outsiders
            fileManager.createFile(atPath: filePath, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: filePath))
        try handle.seekToEnd()

        let logFile = LogFile(path: filePath, handle: handle)
        logFiles[filePath] = logFile

        return logFile
    }

    public func writeLogFile(folderPath: String, basename: String, text: String, timestamp: Date? = nil) {
        let folderPath = (folderPath as NSString).standardizingPath
        var failure: Error?

        lock.withLock {
            do {
                guard let logFile = try getLogFile(folderPath: folderPath, basename: basename) else {
                    return
                }

                var line = text

                if !timestampFormat.isEmpty {
                    line = formatTimestamp(timestampFormat, date: timestamp ?? Date()) + " " + text
                }

                try logFile.handle.seekToEnd()
                try logFile.handle.write(contentsOf: Data((line + "\n").utf8))
                logFile.lastActive = ProcessInfo.processInfo.systemUptime

            } catch {
                failure = error
            }
        }

        if let failure {
            // Avoid infinite recursion
            let shouldLogFile = (folderPath != debugFolderPath)
            let filePath = logFilePath(folderPath: folderPath, basename: basename)

            add(String(localized: "Couldn't write to log file \"\(filePath)\": \(failure.localizedDescription)",
                       bundle: .module),
                level: .default, shouldLogFile: shouldLogFile)
        }
    }

    private func closeLogFile(_ logFile: LogFile) {
        do {
            try logFile.handle.close()
        } catch {
            addDebug("Failed to close log file \"\(logFile.path)\": \(error.localizedDescription)")
        }

        logFiles.removeValue(forKey: logFile.path)
    }

    private func closeLogFiles() {
        lock.withLock {
            for logFile in Array(logFiles.values) {
                closeLogFile(logFile)
            }
        }
    }

    private func closeInactiveLogFiles() {
        let currentTime = ProcessInfo.processInfo.systemUptime

        lock.withLock {
            for logFile in Array(logFiles.values) where currentTime - logFile.lastActive >= 10 {
                closeLogFile(logFile)
            }
        }
    }

    /// Reads the last lines of a log file.
    public func readLog(folderPath: String, basename: String, numLines: Int) -> [String]? {
        var lines: [String]?
        var failure: Error?

        lock.withLock {
            do {
                guard let logFile = try getLogFile(folderPath: folderPath, basename: basename,
                                                   shouldCreateFile: false) else {
                    return
                }

                lines = try Self.lastLines(of: logFile.handle, count: numLines)
                closeLogFile(logFile)

            } catch {
                failure = error
            }
        }

        if let failure {
            let filePath = logFilePath(folderPath: folderPath, basename: basename)
            add(String(localized: "Cannot access log file \(filePath): \(failure.localizedDescription)", bundle: .module))
        }

        return lines
    }

    private static func lastLines(of handle: FileHandle, count numLines: Int) throws -> [String] {
        let blockSize: UInt64 = 8192
        let fileSize = try handle.seekToEnd()
        var readOffset = fileSize
        var data = Data()
        var linesLeft = numLines + 1

        while linesLeft > 0 {
            var readSize = blockSize

            if readOffset < blockSize {
                // Reached beginning of file, read remaining data
                readSize = readOffset
                readOffset = 0
            } else {
                readOffset -= blockSize
            }

            try handle.seek(toOffset: readOffset)
            let block = try handle.read(upToCount: Int(readSize)) ?? Data()
            data = block + data

            if readOffset == 0 {
                // Fewer lines in file than our limit, stop here
                break
            }

            linesLeft -= block.filter { $0 == UInt8(ascii: "\n") }.count
        }

        try handle.seekToEnd()

        let lines = String(decoding: data, as: UTF8.self).split(omittingEmptySubsequences: false) {
            $0 == "\n" || $0 == "\r\n"
        }
        let trimmed = lines.last?.isEmpty == true ? lines.dropLast() : lines[...]

        return trimmed.suffix(numLines).map(String.init)
    }

    public func deleteLog(folderPath: String, basename: String) {
        let filePath = logFilePath(folderPath: folderPath, basename: basename)

        do {
            try FileManager.default.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
            try FileManager.default.removeItem(atPath: filePath)
        } catch {
            add(String(localized: "Cannot access log file \(filePath): \(error.localizedDescription)", bundle: .module))
        }
    }

    public func logFileURL(folderPath: String, basename: String) -> URL {
        URL(fileURLWithPath: logFilePath(folderPath: folderPath, basename: basename))
    }

    private func logTransfer(basename: String, _ message: String) {
        let (isEnabled, folderPath) = lock.withLock { (isTransferLoggingEnabled, transferFolderPath) }

        guard isEnabled, let folderPath else {
            return
        }

        writeLogFile(folderPath: folderPath, basename: basename, text: message)
    }

    // MARK: Log Messages

    private func add(_ message: String, title: String? = nil, level: LogLevel, shouldLogFile: Bool = true) {
        var message = message

        if let prefix = level.prefix {
            message = "[\(prefix)] \(message)"
        }

        let (format, isDebugFileOutput, debugFolderPath) = lock.withLock {
            (timestampFormat, isDebugFileOutputEnabled, self.debugFolderPath)
        }

        if shouldLogFile, isDebugFileOutput, let debugFolderPath {
            let text = message
            events.invokeMainThread { [self] in
                writeLogFile(folderPath: debugFolderPath, basename: debugFileName, text: text)
            }
        }

        let logMessage = LogMessage(timestampFormat: format, message: message, title: title, level: level)

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                events.emit(.logMessage, logMessage)
            }
        } else {
            events.emitMainThread(.logMessage, logMessage)
        }
    }

    public func add(_ message: String, title: String? = nil) {
        add(message, title: title, level: .default)
    }

    public func addDownload(_ message: String) {
        logTransfer(basename: downloadsFileName, message)

        if isLevelEnabled(.download) {
            add(message, level: .download)
        }
    }

    public func addUpload(_ message: String) {
        logTransfer(basename: uploadsFileName, message)

        if isLevelEnabled(.upload) {
            add(message, level: .upload)
        }
    }

    public func addSearch(_ message: @autoclosure () -> String) {
        if isLevelEnabled(.search) {
            add(message(), level: .search)
        }
    }

    public func addChat(_ message: @autoclosure () -> String) {
        if isLevelEnabled(.chat) {
            add(message(), level: .chat)
        }
    }

    public func addConn(_ message: @autoclosure () -> String) {
        if isLevelEnabled(.connection) {
            add(message(), level: .connection)
        }
    }

    func addMessageContents(_ message: SlskMessage, isOutgoing: Bool = false) {
        guard isLevelEnabled(.message), !message.isExcludedFromLog else {
            return
        }

        let direction = isOutgoing ? "OUT" : "IN"
        add("\(direction): \(message)", level: .message)
    }

    public func addTransfer(_ message: @autoclosure () -> String) {
        if isLevelEnabled(.transfer) {
            add(message(), level: .transfer)
        }
    }

    public func addDebug(_ message: @autoclosure () -> String) {
        if isLevelEnabled(.miscellaneous) {
            add(message(), level: .miscellaneous)
        }
    }
}

public let log = Logger()
