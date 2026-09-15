// SPDX-License-Identifier: GPL-3.0-or-later
//
// Binary encoding used by the Soulseek protocol: little-endian integers,
// length-prefixed strings, and zlib-compressed payloads.

import Foundation
import zlib

public enum MessageError: Error, CustomStringConvertible {
    case unexpectedEnd(position: Int, needed: Int, available: Int)
    case packingNotSupported(String)
    case parsingNotSupported(String)
    case missingField(String)
    case compressionFailed(Int32)
    case decompressionFailed(Int32)

    public var description: String {
        switch self {
        case let .unexpectedEnd(position, needed, available):
            return "unpack requires a buffer of \(needed) bytes at position \(position), \(available) available"
        case let .packingNotSupported(name):
            return "message \(name) cannot be packed"
        case let .parsingNotSupported(name):
            return "message \(name) cannot be parsed"
        case let .missingField(name):
            return "required field \(name) is missing"
        case let .compressionFailed(code):
            return "zlib compression failed with code \(code)"
        case let .decompressionFailed(code):
            return "zlib decompression failed with code \(code)"
        }
    }
}

// MARK: - Packing

extension Data {
    mutating func appendBool(_ value: Bool) {
        append(value ? 1 : 0)
    }

    mutating func appendUInt8(_ value: Int) {
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendInt32(_ value: Int) {
        Swift.withUnsafeBytes(of: Int32(truncatingIfNeeded: value).littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: Int) {
        Swift.withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: Int) {
        Swift.withUnsafeBytes(of: UInt64(truncatingIfNeeded: value).littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendBytes(_ content: Data) {
        appendUInt32(content.count)
        append(content)
    }

    /// Appends a length-prefixed string. Legacy strings are encoded as Latin-1
    /// if possible, for compatibility with clients that don't support UTF-8.
    mutating func appendString(_ content: String, isLegacy: Bool = false) {
        let encoded: Data

        if isLegacy, let latin1 = content.data(using: .isoLatin1) {
            encoded = latin1
        } else {
            encoded = Data(content.utf8)
        }

        appendBytes(encoded)
    }
}

// MARK: - Unpacking

/// Reads values sequentially from a message payload.
public struct MessageReader {
    public let data: Data
    public private(set) var position: Int

    public init(_ data: Data, position: Int = 0) {
        self.data = data
        self.position = position
    }

    public var remaining: Int {
        Swift.max(data.count - position, 0)
    }

    public var hasRemaining: Bool {
        remaining > 0
    }

    /// Returns the byte at an offset from the current position, without
    /// advancing.
    public func peekByte(at offset: Int = 0) throws -> UInt8 {
        let index = position + offset
        guard index >= 0, index < data.count else {
            throw MessageError.unexpectedEnd(position: index, needed: 1, available: 0)
        }
        return data[data.startIndex + index]
    }

    public mutating func skip(_ count: Int) {
        position += count
    }

    public mutating func seek(to position: Int) {
        self.position = position
    }

    private func load<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size

        guard position >= 0, position + size <= data.count else {
            throw MessageError.unexpectedEnd(position: position, needed: size, available: remaining)
        }

        return data.withUnsafeBytes { buffer in
            T(littleEndian: buffer.loadUnaligned(fromByteOffset: position, as: T.self))
        }
    }

    public mutating func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    public mutating func readUInt8() throws -> Int {
        let value = try peekByte()
        position += 1
        return Int(value)
    }

    /// Reads an unsigned 16-bit integer, occupying 4 bytes in the message.
    public mutating func readUInt16() throws -> Int {
        let value = try load(UInt16.self)
        position += 4
        return Int(value)
    }

    public mutating func readInt32() throws -> Int {
        let value = try load(Int32.self)
        position += 4
        return Int(value)
    }

    public mutating func readUInt32() throws -> Int {
        let value = try load(UInt32.self)
        position += 4
        return Int(value)
    }

    public mutating func readUInt64() throws -> Int {
        let value = try load(UInt64.self)
        position += 8
        return Int(truncatingIfNeeded: value)
    }

    public mutating func readBytes() throws -> Data {
        let length = try readUInt32()
        let start = Swift.min(position, data.count)
        let end = Swift.min(position + length, data.count)
        position += length

        return data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))
    }

    /// Reads a length-prefixed string. Strings that aren't valid UTF-8 are
    /// decoded as Latin-1 (legacy clients).
    public mutating func readString() throws -> String {
        let content = try readBytes()

        if let string = String(data: content, encoding: .utf8) {
            return string
        }

        return String(data: content, encoding: .isoLatin1) ?? String(decoding: content, as: UTF8.self)
    }

    /// Reads an IPv4 address, stored as a little-endian 32-bit integer.
    public mutating func readIPAddress() throws -> String {
        let value = try load(UInt32.self)
        position += 4

        return "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    /// The remaining unread bytes.
    public func remainingData() -> Data {
        guard hasRemaining else {
            return Data()
        }
        return data.subdata(in: (data.startIndex + position)..<data.endIndex)
    }
}

// MARK: - Compression

enum Zlib {
    static func compress(_ data: Data, level: Int32 = Z_DEFAULT_COMPRESSION) throws -> Data {
        var stream = z_stream()
        var status = deflateInit_(&stream, level, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))

        guard status == Z_OK else {
            throw MessageError.compressionFailed(status)
        }
        defer { deflateEnd(&stream) }

        var output = Data(count: Int(deflateBound(&stream, uLong(data.count))))
        let outputCapacity = output.count

        status = data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int32 in
            output.withUnsafeMutableBytes { (outputBuffer: UnsafeMutableRawBufferPointer) -> Int32 in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputCapacity)

                return deflate(&stream, Z_FINISH)
            }
        }

        guard status == Z_STREAM_END else {
            throw MessageError.compressionFailed(status)
        }

        output.count = Int(stream.total_out)
        return output
    }

    static func decompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        var status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))

        guard status == Z_OK else {
            throw MessageError.decompressionFailed(status)
        }
        defer { inflateEnd(&stream) }

        let chunkSize = Swift.max(data.count * 4, 16384)
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        status = data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int32 in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)

            var result: Int32 = Z_OK

            repeat {
                result = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let produced = chunkSize - Int(stream.avail_out)
                output.append(contentsOf: chunk.prefix(produced))

                if result == Z_BUF_ERROR, stream.avail_in == 0 {
                    // Truncated input
                    break
                }

            } while result == Z_OK

            return result
        }

        guard status == Z_STREAM_END else {
            throw MessageError.decompressionFailed(status)
        }

        return output
    }
}
