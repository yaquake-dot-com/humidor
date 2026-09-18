// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Path Sanitizing

private let illegalPathCharacters: Set<Character> = {
    var characters: Set<Character> = ["?", ":", ">", "<", "|", "*", "\""]

    // ASCII control characters
    for value in 0x00...0x1F {
        characters.insert(Character(Unicode.Scalar(UInt8(value))))
    }
    return characters
}()

private let illegalFileCharacters = illegalPathCharacters.union(["\\", "/"])
private let replacementCharacter: Character = "_"

private extension String {
    /// Removes trailing periods and spaces, which are not allowed at the end of
    /// file names on Windows machines (and thus on peers' machines).
    func trimmingTrailingPeriodsAndSpaces() -> String {
        var result = self
        while let last = result.last, last == "." || last == " " {
            result.removeLast()
        }
        return result
    }
}

/// Replaces characters that are not allowed in file names.
public func cleanFile(_ basename: String) -> String {
    var cleaned = String(basename.map { illegalFileCharacters.contains($0) ? replacementCharacter : $0 })
    cleaned = cleaned.trimmingTrailingPeriodsAndSpaces()

    return cleaned.isEmpty ? String(replacementCharacter) : cleaned
}

/// Replaces characters that are not allowed in folder paths.
public func cleanPath(_ path: String) -> String {
    let normalized = (path as NSString).standardizingPath
    let cleaned = String(normalized.map { illegalPathCharacters.contains($0) ? replacementCharacter : $0 })

    return cleaned.trimmingTrailingPeriodsAndSpaces()
}

// MARK: - Human-Readable Values

public enum FileSizeUnit: String, Sendable {
    case automatic = ""
    case bytes = "B"
}

/// Formats a duration in seconds as "m:ss", "h:mm:ss" or "d:hh:mm:ss".
public func humanLength(_ seconds: Int) -> String {
    var minutes = seconds / 60
    let seconds = seconds % 60
    var hours = minutes / 60
    minutes %= 60
    let days = hours / 24
    hours %= 24

    if days > 0 {
        return String(format: "%d:%02d:%02d:%02d", days, hours, minutes, seconds)
    }

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }

    return String(format: "%d:%02d", minutes, seconds)
}

// Formatters are safe to use from any thread as long as they aren't changed
nonisolated(unsafe) private let sizeFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter
}()

nonisolated(unsafe) private let speedFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.allowsNonnumericFormatting = false
    return formatter
}()

/// A speed as Finder would show its size, like "532 KB/s". Stopped transfers show "0 KB/s".
public func humanSpeed(_ speed: Int) -> String {
    let size = speedFormatter.string(fromByteCount: Int64(speed))
    return String(localized: "\(size)/s", bundle: .module, comment: "A speed, such as \"532 KB/s\"")
}

/// A size as Finder shows it, like "532 KB" or "1,2 GB"
public func humanSize(_ fileSize: Int, unit: FileSizeUnit = .automatic) -> String {
    if unit == .bytes {
        return humanize(fileSize)
    }
    return sizeFormatter.string(fromByteCount: Int64(fileSize))
}

private let groupingFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    return formatter
}()

/// Formats a number with locale-specific digit grouping.
public func humanize(_ number: Int) -> String {
    groupingFormatter.string(from: NSNumber(value: number)) ?? String(number)
}

/// Converts a file size string with a given unit into a raw integer size.
/// Defaults to binary for "k", "m", "g" suffixes (KiB, MiB, GiB).
///
/// - Returns: the size in bytes (nil if invalid), and the unit factor
public func factorize(_ fileSize: String, base: Int = 1024) -> (size: Int?, factor: Int?) {
    guard !fileSize.isEmpty else {
        return (nil, nil)
    }

    var fileSize = fileSize.lowercased()
    var base = base
    let factor: Int

    if fileSize.hasSuffix("b") {
        base = 1000  // Byte suffix detected, prepare to use decimal if necessary
        fileSize.removeLast()
    }

    if fileSize.hasSuffix("i") {
        base = 1024  // Binary requested, stop using decimal
        fileSize.removeLast()
    }

    if fileSize.hasSuffix("g") {
        factor = base * base * base
        fileSize.removeLast()
    } else if fileSize.hasSuffix("m") {
        factor = base * base
        fileSize.removeLast()
    } else if fileSize.hasSuffix("k") {
        factor = base
        fileSize.removeLast()
    } else {
        factor = 1
    }

    guard let value = Double(fileSize.trimmingCharacters(in: .whitespaces)), value.isFinite else {
        return (nil, factor)
    }

    return (Int(value * Double(factor)), factor)
}

// MARK: - String Helpers

extension String {
    /// Truncates the string to fit inside a byte limit (UTF-8).
    public func truncated(toByteLimit byteLimit: Int, ellipsize: Bool = false) -> String {
        var bytes = Array(utf8)

        guard bytes.count > byteLimit else {
            return self
        }

        if ellipsize {
            let ellipsis = Array("…".utf8)
            bytes = Array(bytes.prefix(Swift.max(byteLimit - ellipsis.count, 0)))

            while let last = bytes.last, last == UInt8(ascii: " ") || last == UInt8(ascii: "\t") || last == UInt8(ascii: "\n") {
                bytes.removeLast()
            }
            bytes += ellipsis
        } else {
            bytes = Array(bytes.prefix(byteLimit))
        }

        // Drop incomplete multi-byte sequences at the end
        while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    /// Removes quotes from the beginning and end of the string, and unescapes
    /// backslash escape sequences.
    public var unescaped: String {
        var result = ""
        var iterator = makeIterator()

        while let character = iterator.next() {
            guard character == "\\", let escaped = iterator.next() else {
                result.append(character)
                continue
            }

            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "\\": result.append("\\")
            case "'": result.append("'")
            case "\"": result.append("\"")
            default:
                result.append("\\")
                result.append(escaped)
            }
        }

        if result.count >= 2, let first = result.first, first == result.last, first == "'" || first == "\"" {
            return String(result.dropFirst().dropLast())
        }

        return result
    }
}

/// Returns the start position of a whole word that is not part of a subword.
public func findWholeWord(_ word: String, in text: String) -> String.Index? {
    guard !word.isEmpty else {
        return nil
    }

    var searchStart = text.startIndex

    while let range = text.range(of: word, range: searchStart..<text.endIndex) {
        let before: Character = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : " "
        let after: Character = range.upperBound < text.endIndex ? text[range.upperBound] : " "

        if before.isWordBoundary && after.isWordBoundary {
            return range.lowerBound
        }

        searchStart = range.upperBound
    }

    return nil
}

/// Replaces censored words with a filler character.
public func censorText(_ text: String, patterns: [String], filler: Character = "*") -> String {
    var text = text

    for word in patterns where !word.isEmpty {
        text = text.replacingOccurrences(of: word, with: String(repeating: filler, count: word.count))
    }

    return text
}

// MARK: - External Commands

public enum CommandError: LocalizedError {
    case executionFailed(command: [String], index: Int, total: Int, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case let .executionFailed(command, index, total, underlying):
            return "Problem while executing command \(command) (\(index) of \(total)): \(underlying.localizedDescription)"
        }
    }
}

/// Splits a command string into subcommands, with partial support for
/// shell-style quoting and pipes.
///
/// A double quotation mark can be used to embed spaces in an argument, and
/// pipes are created using the bar symbol (|). Every occurrence of the
/// placeholder is replaced by the replacement, if provided.
func parseCommand(_ command: String, replacement: String? = nil, placeholder: String = "$") -> [[String]] {
    var unparsed = Substring(command)
    var arguments: [String] = []

    while unparsed.filter({ $0 == "\"" }).count > 1 {
        let parts = unparsed.split(separator: "\"", maxSplits: 2, omittingEmptySubsequences: false)
        let pre = parts[0]

        if !pre.isEmpty {
            arguments += pre.trimmingTrailing(" ").split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        }

        arguments.append(String(parts[1]))
        unparsed = parts.count > 2 ? parts[2].drop(while: { $0 == " " }) : ""
    }

    if !unparsed.isEmpty {
        arguments += unparsed.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    }

    var subcommands: [[String]] = []
    var current: [String] = []

    for argument in arguments {
        if argument == "|" {
            subcommands.append(current)
            current = []
        } else {
            current.append(argument)
        }
    }

    subcommands.append(current)

    if let replacement, !replacement.isEmpty {
        subcommands = subcommands.map { $0.map { $0.replacingOccurrences(of: placeholder, with: replacement) } }
    }

    return subcommands
}

private extension Substring {
    func trimmingTrailing(_ character: Character) -> Substring {
        var result = self
        while result.last == character {
            result.removeLast()
        }
        return result
    }
}

/// Executes a command string (see `parseCommand`).
///
/// If `background` is false, waits for all launched processes to finish. If the
/// command ends with an ampersand, it always runs in the background, unless
/// output is requested.
@discardableResult
public func executeCommand(_ command: String, replacement: String? = nil, background: Bool = true,
                           returnOutput: Bool = false, placeholder: String = "$") throws -> Data? {
    var command = command.trimmingCharacters(in: .whitespacesAndNewlines)
    var background = returnOutput ? false : background

    if command.hasSuffix("&") {
        command.removeLast()

        if returnOutput {
            log.add("Yikes, I was asked to return output but I'm also asked to launch "
                    + "the process in the background. returnOutput gets precedence.")
        } else {
            background = true
        }
    }

    let subcommands = parseCommand(command, replacement: replacement, placeholder: placeholder)
    var processes: [Process] = []
    var previousPipe: Pipe?
    let outputPipe = returnOutput ? Pipe() : nil

    for (index, subcommand) in subcommands.enumerated() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = subcommand

        if let previousPipe {
            process.standardInput = previousPipe
        }

        if index < subcommands.count - 1 {
            let pipe = Pipe()
            process.standardOutput = pipe
            previousPipe = pipe
        } else if let outputPipe {
            process.standardOutput = outputPipe
        }

        do {
            try process.run()
        } catch {
            throw CommandError.executionFailed(command: subcommand, index: index + 1,
                                               total: subcommands.count, underlying: error)
        }

        processes.append(process)
    }

    if let outputPipe {
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        processes.last?.waitUntilExit()
        return output
    }

    if !background {
        processes.last?.waitUntilExit()
    }

    return nil
}

// MARK: - File Loading/Saving

/// Loads a file using the provided loader. If loading fails, attempts to load
/// the backup (*.old) file instead.
public func loadFile<T>(_ filePath: String, useOldFile: Bool = false, _ load: (String) throws -> T) -> T? {
    let fileManager = FileManager.default
    var filePath = filePath

    do {
        if useOldFile {
            filePath += ".old"

        } else if fileManager.fileExists(atPath: filePath + ".old") {
            guard fileManager.fileExists(atPath: filePath) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "*.old file is present but main file is missing"
                ])
            }

            let size = (try? fileManager.attributesOfItem(atPath: filePath)[.size] as? Int) ?? 0

            guard size > 0 else {
                // Empty files should be considered broken/corrupted
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "*.old file is present but main file is empty"
                ])
            }
        }

        return try load(filePath)

    } catch {
        log.add(String(localized: "Something went wrong while reading file \(filePath): \(error.localizedDescription)", bundle: .module))

        if !useOldFile {
            log.add(String(localized: "Attempting to load backup of file \(filePath)", bundle: .module))
            return loadFile(filePath, useOldFile: true, load)
        }
    }

    return nil
}

/// Backs up an existing file to *.old, and writes a new file using the
/// provided writer. Restores the backup if writing fails.
public func writeFileAndBackup(_ path: String, protect: Bool = false, _ write: (inout Data) throws -> Void) {
    let fileManager = FileManager.default
    let oldPath = path + ".old"

    // Back up old file to path.old
    do {
        if let size = try? fileManager.attributesOfItem(atPath: path)[.size] as? Int, size > 0 {
            if fileManager.fileExists(atPath: oldPath) {
                try fileManager.removeItem(atPath: oldPath)
            }
            try fileManager.moveItem(atPath: path, toPath: oldPath)

            if protect {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oldPath)
            }
        }
    } catch {
        log.add(String(localized: "Unable to back up file \(path): \(error.localizedDescription)", bundle: .module))
        return
    }

    // Save new file
    do {
        var data = Data()
        try write(&data)

        let url = URL(fileURLWithPath: path)
        try data.write(to: url, options: [.atomic])

        if protect {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }

        log.addDebug("Backed up and saved file \(path)")

    } catch {
        log.add(String(localized: "Unable to save file \(path): \(error.localizedDescription)", bundle: .module))

        // Attempt to restore file
        do {
            if fileManager.fileExists(atPath: oldPath) {
                if fileManager.fileExists(atPath: path) {
                    try fileManager.removeItem(atPath: path)
                }
                try fileManager.moveItem(atPath: oldPath, toPath: path)
            }
        } catch {
            log.add(String(localized: "Unable to restore previous file \(path): \(error.localizedDescription)", bundle: .module))
        }
    }
}
