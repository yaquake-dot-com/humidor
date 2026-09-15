// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A value that can be stored in a ``ShareDatabase``.
protocol ShareDatabaseValue {
    func encoded() -> Data
    init(decoding reader: inout MessageReader) throws
}

extension Data: ShareDatabaseValue {
    func encoded() -> Data { self }

    init(decoding reader: inout MessageReader) throws {
        self = reader.remainingData()
    }
}

extension Double: ShareDatabaseValue {
    func encoded() -> Data {
        var data = Data()
        data.appendUInt64(Int(truncatingIfNeeded: bitPattern))
        return data
    }

    init(decoding reader: inout MessageReader) throws {
        self = Double(bitPattern: UInt64(truncatingIfNeeded: try reader.readUInt64()))
    }
}

extension Array: ShareDatabaseValue where Element == Int {
    func encoded() -> Data {
        var data = Data()
        data.appendUInt32(count)
        for value in self {
            data.appendUInt32(value)
        }
        return data
    }

    init(decoding reader: inout MessageReader) throws {
        let count = try reader.readUInt32()
        var values: [Int] = []
        values.reserveCapacity(count)

        for _ in 0..<count {
            values.append(try reader.readUInt32())
        }
        self = values
    }
}

extension SharedFileInfo: ShareDatabaseValue {
    private static func appendOptional(_ value: Int?, to data: inout Data) {
        data.appendBool(value != nil)
        data.appendUInt64(value ?? 0)
    }

    private static func readOptional(_ reader: inout MessageReader) throws -> Int? {
        let hasValue = try reader.readBool()
        let value = try reader.readUInt64()
        return hasValue ? value : nil
    }

    func encoded() -> Data {
        var data = Data()
        data.appendString(virtualPath)
        data.appendUInt64(size)
        data.appendBool(quality != nil)

        if let quality {
            Self.appendOptional(quality.bitrate, to: &data)
            Self.appendOptional(quality.isVBR.map { $0 ? 1 : 0 }, to: &data)
            Self.appendOptional(quality.sampleRate, to: &data)
            Self.appendOptional(quality.bitDepth, to: &data)
        }

        Self.appendOptional(duration, to: &data)
        return data
    }

    init(decoding reader: inout MessageReader) throws {
        let virtualPath = try reader.readString()
        let size = try reader.readUInt64()
        var quality: AudioQuality?

        if try reader.readBool() {
            quality = AudioQuality(
                bitrate: try Self.readOptional(&reader),
                isVBR: try Self.readOptional(&reader).map { $0 != 0 },
                sampleRate: try Self.readOptional(&reader),
                bitDepth: try Self.readOptional(&reader)
            )
        }

        let duration = try Self.readOptional(&reader)
        self.init(virtualPath: virtualPath, size: size, quality: quality, duration: duration)
    }
}

struct ShareDatabaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Custom key-value database format for shares. Values are appended to the
/// file, and read on demand using an index of value offsets.
final class ShareDatabase<Value: ShareDatabaseValue>: @unchecked Sendable {

    static var fileSignature: Data { Data("DBN+".utf8) }
    static var version: UInt8 { 0x53 }  // Distinct from other implementations of the format
    static var lengthDataSize: Int { 8 }

    private var valueOffsets: [String: (offset: Int, length: Int)] = [:]
    /// Keys in insertion order
    private(set) var keys: [String] = []
    private var fileHandle: FileHandle?
    private var mappedContent: Data?
    private var fileOffset = 0
    private let overwrite: Bool

    init(filePath: String, overwrite: Bool = true) throws {
        let fileManager = FileManager.default
        let folderPath = (filePath as NSString).deletingLastPathComponent

        if !fileManager.fileExists(atPath: folderPath) {
            try fileManager.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
        }

        if overwrite && fileManager.fileExists(atPath: filePath) {
            try fileManager.removeItem(atPath: filePath)
        }

        self.overwrite = overwrite

        if overwrite {
            var header = Self.fileSignature
            header.append(Self.version)
            fileManager.createFile(atPath: filePath, contents: header)

            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
            fileOffset = Int(try handle.seekToEnd())
            fileHandle = handle
        } else {
            let content = try Data(contentsOf: URL(fileURLWithPath: filePath), options: .alwaysMapped)
            (valueOffsets, keys) = try Self.parseContent(content)
            mappedContent = content
            fileOffset = content.count
        }
    }

    private static func parseContent(_ content: Data) throws
        -> ([String: (offset: Int, length: Int)], [String]) {
        var valueOffsets: [String: (offset: Int, length: Int)] = [:]
        var keys: [String] = []
        let signatureLength = fileSignature.count

        guard content.count > signatureLength, content.prefix(signatureLength) == fileSignature else {
            throw ShareDatabaseError(message: "Not a database file")
        }

        guard content[content.startIndex + signatureLength] == version else {
            throw ShareDatabaseError(message: "Incompatible version")
        }

        var reader = MessageReader(content, position: signatureLength + 1)

        while reader.hasRemaining {
            let keyLength = Int(UInt32(bigEndian: UInt32(truncatingIfNeeded: try reader.readUInt32())))
            let valueLength = Int(UInt32(bigEndian: UInt32(truncatingIfNeeded: try reader.readUInt32())))
            let keyOffset = reader.position

            guard keyOffset + keyLength + valueLength <= content.count else {
                throw ShareDatabaseError(message: "Truncated database file")
            }

            let keyData = content.subdata(in: (content.startIndex + keyOffset)..<(content.startIndex + keyOffset + keyLength))
            let key = String(decoding: keyData, as: UTF8.self)

            if valueOffsets[key] == nil {
                keys.append(key)
            }

            valueOffsets[key] = (keyOffset + keyLength, valueLength)
            reader.skip(keyLength + valueLength)
        }

        return (valueOffsets, keys)
    }

    func contains(_ key: String) -> Bool {
        valueOffsets[key] != nil
    }

    var count: Int {
        valueOffsets.count
    }

    subscript(key: String) -> Value? {
        get {
            guard let (offset, length) = valueOffsets[key], let content = mappedContent else {
                return nil
            }

            let data = content.subdata(in: (content.startIndex + offset)..<(content.startIndex + offset + length))
            var reader = MessageReader(data)
            return try? Value(decoding: &reader)
        }
    }

    func set(_ key: String, _ value: Value) throws {
        guard let fileHandle else {
            throw ShareDatabaseError(message: "Database is read-only")
        }

        let encodedKey = Data(key.utf8)
        let encodedValue = value.encoded()

        var itemData = Data()
        itemData.append(contentsOf: withUnsafeBytes(of: UInt32(encodedKey.count).bigEndian, Array.init))
        itemData.append(contentsOf: withUnsafeBytes(of: UInt32(encodedValue.count).bigEndian, Array.init))
        itemData.append(encodedKey)
        itemData.append(encodedValue)

        try fileHandle.write(contentsOf: itemData)

        if valueOffsets[key] == nil {
            keys.append(key)
        }

        valueOffsets[key] = (fileOffset + Self.lengthDataSize + encodedKey.count, encodedValue.count)
        fileOffset += itemData.count
    }

    func update(_ values: some Sequence<(String, Value)>) throws {
        for (key, value) in values {
            try set(key, value)
        }
    }

    func close() {
        if overwrite, let fileHandle {
            try? fileHandle.synchronize()
            try? fileHandle.close()
        }

        fileHandle = nil
        mappedContent = nil
    }
}
