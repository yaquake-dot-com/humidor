// SPDX-License-Identifier: MIT
//
// tinytag - an audio meta info reader
// Copyright (c) 2014-2023 Tom Wallroth
// Copyright (c) 2021-2023 Mat (mathiascode)
// Copyright (c) 2020-2023 Nicotine+ Contributors
//
// Sources on GitHub:
// http://github.com/tinytag/tinytag/
//
// MIT License
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// Swift port of the audio properties parsers (duration, bitrate, sample rate,
// bit depth). Tag and image parsing is not needed for sharing files.

import Foundation

struct TinyTagError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

// MARK: - File Reader

/// Buffered file reader supporting seeking and peeking.
final class TinyTagReader {
    private static let bufferSize = 8192

    private let handle: FileHandle?
    private let memory: Data?
    let fileSize: Int
    private(set) var position = 0

    private var buffer = Data()
    private var bufferStart = 0

    init(handle: FileHandle, fileSize: Int) {
        self.handle = handle
        self.memory = nil
        self.fileSize = fileSize
    }

    init(data: Data) {
        self.handle = nil
        self.memory = data
        self.fileSize = data.count
    }

    private func bytes(at offset: Int, count: Int) -> Data {
        guard count > 0, offset < fileSize, offset >= 0 else {
            return Data()
        }

        let end = Swift.min(offset + count, fileSize)

        if let memory {
            return memory.subdata(in: (memory.startIndex + offset)..<(memory.startIndex + end))
        }

        // Serve from buffer if possible
        if offset >= bufferStart && end <= bufferStart + buffer.count {
            let start = buffer.startIndex + (offset - bufferStart)
            return buffer.subdata(in: start..<(start + (end - offset)))
        }

        guard let handle else {
            return Data()
        }

        let readSize = Swift.max(end - offset, Self.bufferSize)

        do {
            try handle.seek(toOffset: UInt64(offset))
            buffer = try handle.read(upToCount: readSize) ?? Data()
            bufferStart = offset
        } catch {
            buffer = Data()
            bufferStart = 0
            return Data()
        }

        let available = Swift.min(end - offset, buffer.count)
        return buffer.prefix(available)
    }

    /// Reads up to `count` bytes.
    func read(_ count: Int) -> Data {
        let data = bytes(at: position, count: count)
        position += data.count
        return data
    }

    /// Reads exactly `count` bytes, throwing at the end of the file.
    func readExactly(_ count: Int) throws -> Data {
        let data = read(count)

        guard data.count == count else {
            throw TinyTagError("Unexpected end of file")
        }
        return data
    }

    /// Returns buffered bytes from the current position without advancing.
    func peek(_ count: Int) -> Data {
        bytes(at: position, count: Swift.max(count, Self.bufferSize))
    }

    func seek(_ offset: Int) {
        position = Swift.max(offset, 0)
    }

    func skip(_ count: Int) {
        position = Swift.max(position + count, 0)
    }

    func seekFromEnd(_ offset: Int) {
        position = Swift.max(fileSize + offset, 0)
    }
}

// MARK: - Byte Helpers

private extension Data {
    subscript(offset offset: Int) -> UInt8 {
        self[startIndex + offset]
    }

    func slice(_ range: Range<Int>) -> Data {
        let lower = Swift.min(range.lowerBound, count)
        let upper = Swift.min(range.upperBound, count)
        return subdata(in: (startIndex + lower)..<(startIndex + upper))
    }

    func bigEndianInt(_ range: Range<Int>) -> Int {
        slice(range).reduce(0) { ($0 << 8) + Int($1) }
    }

    func littleEndianInt(_ range: Range<Int>) -> Int {
        slice(range).reversed().reduce(0) { ($0 << 8) + Int($1) }
    }

    func signedLittleEndianInt32(_ offset: Int) -> Int {
        Int(Int32(bitPattern: UInt32(truncatingIfNeeded: littleEndianInt(offset..<(offset + 4)))))
    }

    func range(of pattern: [UInt8], from start: Int = 0) -> Int? {
        guard pattern.count <= count, start <= count - pattern.count else {
            return nil
        }

        let bytes = [UInt8](self)

        for index in start...(bytes.count - pattern.count) where bytes[index] == pattern[0] {
            if Array(bytes[index..<(index + pattern.count)]) == pattern {
                return index
            }
        }
        return nil
    }

    func hasPrefix(_ bytes: [UInt8]) -> Bool {
        count >= bytes.count && Array(prefix(bytes.count)) == bytes
    }
}

private func ascii(_ string: String) -> [UInt8] {
    Array(string.utf8)
}

// MARK: - TinyTag

/// Reads audio properties of a file.
class TinyTag {
    final let reader: TinyTagReader
    final var fileSize: Int { reader.fileSize }

    final var bitrate: Double?
    final var channels: Int?
    final var duration: Double?
    final var sampleRate: Int?
    final var bitDepth: Int?
    final var audioOffset: Int?
    final var isVBR = false

    required init(reader: TinyTagReader) {
        self.reader = reader
    }

    /// Returns the parser for a file name, based on the file extension.
    static func parserClass(for fileName: String) -> TinyTag.Type? {
        let fileName = fileName.lowercased()
        let mapping: [([String], TinyTag.Type)] = [
            ([".mp1", ".mp2", ".mp3"], ID3.self),
            ([".oga", ".ogg", ".opus", ".spx"], Ogg.self),
            ([".wav"], Wave.self),
            ([".flac"], Flac.self),
            ([".wma"], Wma.self),
            ([".m4b", ".m4a", ".m4r", ".m4v", ".mp4", ".aax", ".aaxc"], MP4.self),
            ([".aiff", ".aifc", ".aif", ".afc"], Aiff.self)
        ]

        for (extensions, parserClass) in mapping where extensions.contains(where: fileName.hasSuffix) {
            return parserClass
        }

        return nil
    }

    /// Loads the audio properties of the file.
    func load() throws {
        try determineDuration()
    }

    func determineDuration() throws {
        preconditionFailure("Subclasses must implement determineDuration()")
    }

    /// Copies the audio properties of another tag.
    final func update(from other: TinyTag) {
        bitrate = other.bitrate
        channels = other.channels
        duration = other.duration
        sampleRate = other.sampleRate
        bitDepth = other.bitDepth
        audioOffset = other.audioOffset
        isVBR = other.isVBR
    }
}

// MARK: - MP4

final class MP4: TinyTag {

    private enum Node {
        case tree([String: Node])
        case parser((Data) -> Void)
    }

    private static let versionedAtoms: Set<String> = ["meta", "stsd"]  // those have an extra 4 byte header
    private static let flaggedAtoms: Set<String> = ["stsd"]  // these also have an extra 4 byte header

    override func determineDuration() throws {
        // see: https://developer.apple.com/library/mac/documentation/QuickTime/QTFF/QTFFChap3/qtff3.html
        let audioDataTree: [String: Node] = [
            "moov": .tree([
                "mvhd": .parser { [self] data in parseMVHD(data) },
                "trak": .tree(["mdia": .tree(["minf": .tree(["stbl": .tree(["stsd": .tree([
                    "mp4a": .parser { [self] data in parseAudioSampleEntryMP4A(data) },
                    "alac": .parser { [self] data in parseAudioSampleEntryALAC(data) }
                ])])])])])
            ])
        ]

        traverseAtoms(path: audioDataTree)
    }

    private static func readExtendedDescriptor(_ reader: TinyTagReader) {
        for _ in 0..<4 where reader.read(1) != Data([0x80]) {
            break
        }
    }

    private func parseAudioSampleEntryMP4A(_ data: Data) {
        // this atom also contains the esds atom:
        // https://ffmpeg.org/doxygen/0.6/mov_8c-source.html
        // http://xhelmboyx.tripod.com/formats/mp4-layout.txt
        guard data.count >= 36 else {
            return
        }

        let channels = data.bigEndianInt(16..<18)
        let sampleRate = data.bigEndianInt(22..<26)

        // ES Description Atom
        let esdsAtomSize = data.bigEndianInt(28..<32)
        let esdsAtom = TinyTagReader(data: data.slice(36..<(36 + esdsAtomSize)))
        esdsAtom.skip(5)  // jump over version, flags and tag

        // ES Descriptor
        Self.readExtendedDescriptor(esdsAtom)
        esdsAtom.skip(4)  // jump over ES id, flags and tag

        // Decoder Config Descriptor
        Self.readExtendedDescriptor(esdsAtom)
        esdsAtom.skip(9)

        let bitrateData = esdsAtom.read(4)
        guard bitrateData.count == 4 else {
            return
        }

        setIfEmpty(\.channels, channels)
        setIfEmpty(\.sampleRate, sampleRate)
        setIfEmpty(\.bitrate, Double(bitrateData.bigEndianInt(0..<4)) / 1000)  // kbit/s
    }

    private func parseAudioSampleEntryALAC(_ data: Data) {
        // https://github.com/macosforge/alac/blob/master/ALACMagicCookieDescription.txt
        guard data.count >= 36 else {
            return
        }

        let alacAtomSize = data.bigEndianInt(28..<32)
        let alacAtom = TinyTagReader(data: data.slice(36..<(36 + alacAtomSize)))
        alacAtom.skip(9)
        let bitDepth = Int(Int8(bitPattern: alacAtom.read(1).first ?? 0))
        alacAtom.skip(3)
        let channels = Int(Int8(bitPattern: alacAtom.read(1).first ?? 0))
        alacAtom.skip(6)
        let bitrateData = alacAtom.read(4)
        let sampleRateData = alacAtom.read(4)

        guard bitrateData.count == 4, sampleRateData.count == 4 else {
            return
        }

        setIfEmpty(\.channels, channels)
        setIfEmpty(\.sampleRate, sampleRateData.bigEndianInt(0..<4))
        setIfEmpty(\.bitrate, Double(bitrateData.bigEndianInt(0..<4)) / 1000)  // kbit/s
        setIfEmpty(\.bitDepth, bitDepth)
    }

    private func parseMVHD(_ data: Data) {
        // http://stackoverflow.com/a/3639993/1191373
        guard let version = data.first else {
            return
        }

        let timeScale: Int
        let duration: Int

        if version == 0 {
            // uses 32 bit integers for timestamps
            guard data.count >= 20 else { return }
            timeScale = data.bigEndianInt(12..<16)
            duration = data.bigEndianInt(16..<20)
        } else {
            // uses 64 bit integers for timestamps
            guard data.count >= 32 else { return }
            timeScale = data.bigEndianInt(20..<24)
            duration = Int(Int64(bitPattern: UInt64(truncatingIfNeeded: data.bigEndianInt(24..<32))))
        }

        guard timeScale > 0 else {
            return
        }

        setIfEmpty(\.duration, Double(duration) / Double(timeScale))
    }

    private func setIfEmpty<T: Numeric>(_ keyPath: ReferenceWritableKeyPath<MP4, T?>, _ value: T) {
        // Do not overwrite existing data
        if let existing = self[keyPath: keyPath], existing != 0 {
            return
        }
        self[keyPath: keyPath] = value
    }

    private func traverseAtoms(path: [String: Node], stopPosition: Int? = nil) {
        let headerSize = 8
        var atomHeader = reader.read(headerSize)

        while atomHeader.count == headerSize {
            let atomSize = atomHeader.bigEndianInt(0..<4) - headerSize
            let atomType = String(decoding: atomHeader.slice(4..<8), as: UTF8.self)

            if atomSize <= 0 {
                // empty atom, jump to next one
                atomHeader = reader.read(headerSize)
                continue
            }

            if Self.versionedAtoms.contains(atomType) {
                // jump atom version for now
                reader.skip(4)
            }

            if Self.flaggedAtoms.contains(atomType) {
                // jump atom flags for now
                reader.skip(4)
            }

            switch path[atomType] {
            case let .tree(subPath):
                // if the path leaf is a dict, traverse deeper into the tree
                let atomEndPosition = reader.position + atomSize
                traverseAtoms(path: subPath, stopPosition: atomEndPosition)

            case let .parser(parse):
                // if the path-leaf is a callable, call it on the atom data
                parse(reader.read(atomSize))

            case nil:
                // if no action was specified, jump over atom
                reader.skip(atomSize)
            }

            // check if we have reached the end of this branch
            if let stopPosition, stopPosition > 0, reader.position >= stopPosition {
                return  // return to parent (next parent node in tree)
            }

            atomHeader = reader.read(headerSize)  // read next atom
        }
    }
}

// MARK: - ID3 (MP3)

final class ID3: TinyTag {

    private static let maxEstimationSeconds = 30
    private static let cbrDetectionFrameCount = 5
    private static let useXingHeader = true  // much faster, but can be deactivated for testing

    // see this page for the magic values used in mp3:
    // http://www.mpgedit.org/mpgedit/mpeg_format/mpeghdr.htm
    private static let sampleRates: [[Int]] = [
        [11025, 12000, 8000],   // MPEG 2.5
        [],                     // reserved
        [22050, 24000, 16000],  // MPEG 2
        [44100, 48000, 32000]   // MPEG 1
    ]
    private static let v1l1 = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0]
    private static let v1l2 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0]
    private static let v1l3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
    private static let v2l1 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0]
    private static let v2l2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]
    private static let v2l3 = v2l2
    private static let bitrateByVersionByLayer: [[[Int]]?] = [
        [[], v2l3, v2l2, v2l1],  // MPEG Version 2.5  # note that the layers go
        nil,                     // reserved          # from 3 to 1 by design.
        [[], v2l3, v2l2, v2l1],  // MPEG Version 2    # the first layer id is
        [[], v1l3, v1l2, v1l1]   // MPEG Version 1    # reserved
    ]
    private static let samplesPerFrame = 1152  // the default frame size for mp3
    private static let channelsPerChannelMode = [
        2,  // 00 Stereo
        2,  // 01 Joint stereo (Stereo)
        2,  // 10 Dual channel (2 mono channels)
        1   // 11 Single channel (Mono)
    ]

    /// Position after the ID3 tag, for duration measurement speedup
    private var bytePositionAfterID3v2: Int?

    private static func parseXingHeader(_ reader: TinyTagReader) -> (frames: Int?, byteCount: Int?) {
        // see: http://www.mp3-tech.org/programmer/sources/vbrheadersdk.zip
        func readInt32() -> Int {
            Int(Int32(bitPattern: UInt32(truncatingIfNeeded: reader.read(4).bigEndianInt(0..<4))))
        }

        reader.skip(4)  // read over Xing header
        let headerFlags = readInt32()
        var frames: Int?
        var byteCount: Int?

        if headerFlags & 1 != 0 {  // FRAMES FLAG
            frames = readInt32()
        }

        if headerFlags & 2 != 0 {  // BYTES FLAG
            byteCount = readInt32()
        }

        if headerFlags & 4 != 0 {  // TOC FLAG
            reader.skip(100)
        }

        if headerFlags & 8 != 0 {  // VBR SCALE FLAG
            _ = readInt32()
        }

        return (frames, byteCount)
    }

    override func determineDuration() throws {
        // find start position of audio data
        if bytePositionAfterID3v2 == nil {
            try parseID3v2Header()
        }

        let maxEstimationFrames = (Self.maxEstimationSeconds * 44100) / Self.samplesPerFrame
        var frameSizeAccumulator = 0
        let headerBytes = 4
        var frames = 0  // count frames for determining mp3 duration
        var bitrateAccumulator = 0  // add up bitrates to find average bitrate to detect
        var lastBitrates: [Int] = []  // CBR mp3s (multiple frames with same bitrates)

        // seek to first position after id3 tag (speedup for large header)
        reader.seek(bytePositionAfterID3v2 ?? 0)

        while true {
            // reading through garbage until 11 '1' sync-bits are found
            let buffer = reader.peek(4)

            if buffer.count < 4 {
                if frames > 0 {
                    bitrate = Double(bitrateAccumulator) / Double(frames)
                }
                break  // EOF
            }

            let sync = buffer[offset: 0]
            let conf = buffer[offset: 1]
            let bitrateFrequency = buffer[offset: 2]
            let rest = buffer[offset: 3]

            let bitrateID = Int((bitrateFrequency >> 4) & 0x0F)  // biterate id
            let sampleRateID = Int((bitrateFrequency >> 2) & 0x03)  // sample rate id
            let padding = bitrateFrequency & 0x02 > 0 ? 1 : 0
            let mpegID = Int((conf >> 3) & 0x03)
            let layerID = Int((conf >> 1) & 0x03)
            let channelMode = Int((rest >> 6) & 0x03)

            // check for eleven 1s, validate bitrate and sample rate
            let isSync = sync == 0xFF && conf > 0xE0
            if !isSync || bitrateID > 14 || bitrateID == 0 || sampleRateID == 3 || layerID == 0 || mpegID == 1 {
                // invalid frame, find next sync header
                let index = buffer.range(of: [0xFF], from: 1) ?? buffer.count
                reader.skip(Swift.max(index, 1))
                continue
            }

            guard let layers = Self.bitrateByVersionByLayer[mpegID], layerID < layers.count,
                  bitrateID < layers[layerID].count, sampleRateID < Self.sampleRates[mpegID].count else {
                throw TinyTagError("mp3 parsing failed")
            }

            channels = Self.channelsPerChannelMode[channelMode]
            let frameBitrate = layers[layerID][bitrateID]
            let frameSampleRate = Self.sampleRates[mpegID][sampleRateID]
            sampleRate = frameSampleRate

            // There might be a xing header in the first frame that contains
            // all the info we need, otherwise parse multiple frames to find the
            // accurate average bitrate
            if frames == 0 && Self.useXingHeader {
                if let xingHeaderOffset = buffer.range(of: ascii("Xing")) {
                    reader.skip(xingHeaderOffset)
                    let (xingFrames, byteCount) = Self.parseXingHeader(reader)

                    if let xingFrames, xingFrames != 0, let byteCount, byteCount != 0 {
                        // MPEG-2 Audio Layer III uses 576 samples per frame
                        let samplesPerFrame = mpegID <= 2 ? 576 : Self.samplesPerFrame
                        let duration = Double(xingFrames * samplesPerFrame) / Double(frameSampleRate)

                        self.duration = duration
                        bitrate = Double(byteCount * 8) / duration / 1000
                        audioOffset = reader.position
                        isVBR = true
                        return
                    }
                    continue
                }
            }

            frames += 1  // it's most probably an mp3 frame
            bitrateAccumulator += frameBitrate

            if frames == 1 {
                audioOffset = reader.position
            }

            if frames <= Self.cbrDetectionFrameCount {
                lastBitrates.append(frameBitrate)
            }

            reader.skip(4)  // jump over peeked bytes

            let frameLength = (144_000 * frameBitrate) / frameSampleRate + padding
            frameSizeAccumulator += frameLength

            // if bitrate does not change over time its probably CBR
            let isCBR = frames == Self.cbrDetectionFrameCount && Set(lastBitrates).count == 1

            if frames == maxEstimationFrames || isCBR {
                // try to estimate duration
                reader.seekFromEnd(-128)  // jump to last byte (leaving out id3v1 tag)
                let audioStreamSize = reader.position - (audioOffset ?? 0)
                let estimatedFrameCount = Double(audioStreamSize) / (Double(frameSizeAccumulator) / Double(frames))
                let samples = estimatedFrameCount * Double(Self.samplesPerFrame)

                duration = samples / Double(frameSampleRate)
                bitrate = Double(bitrateAccumulator) / Double(frames)
                return
            }

            if frameLength > 1 {
                // jump over current frame body
                reader.skip(frameLength - headerBytes)
            }
        }

        if let sampleRate, sampleRate > 0 {
            duration = Double(frames * Self.samplesPerFrame) / Double(sampleRate)
        }
    }

    private static func calcSize(_ bytes: Data, bitsPerByte: Int) -> Int {
        // length of some mp3 header fields is described by 7 or 8-bit-bytes
        bytes.reduce(0) { ($0 << bitsPerByte) + Int($1) }
    }

    /// Parses the ID3v2 header, and returns its size.
    @discardableResult
    func parseID3v2Header() throws -> Int {
        var size = 0

        // for info on the specs, see: http://id3.org/Developer%20Information
        let header = try reader.readExactly(10)

        // check if there is an ID3v2 tag at the beginning of the file
        if header.hasPrefix(ascii("ID3")) {
            size = Self.calcSize(header.slice(6..<10), bitsPerByte: 7)
        }

        bytePositionAfterID3v2 = size
        return size
    }
}

// MARK: - Ogg

final class Ogg: TinyTag {

    private var tagsParsed = false
    /// Maximum sample position ever read
    private var maxSampleNumber = 0

    override func determineDuration() throws {
        let maxPageSize = 65536  // https://xiph.org/ogg/doc/libogg/ogg_page.html

        if !tagsParsed {
            try parseHeaders()  // determine sample rate
            reader.seek(0)      // and rewind to start
        }

        guard duration == nil, let sampleRate, sampleRate > 0 else {
            return  // either ogg flac or invalid file
        }

        if fileSize > maxPageSize {
            reader.seekFromEnd(-maxPageSize)  // go to last possible page position
        }

        while true {
            let buffer = reader.peek(4)

            if buffer.isEmpty {
                return  // EOF
            }

            if buffer.hasPrefix(ascii("OggS")) {
                // look for an ogg header
                try parsePages { _ in true }  // parse all remaining pages
                duration = Double(maxSampleNumber) / Double(sampleRate)
            } else {
                // try to find header in peeked data
                let seekPosition = buffer.range(of: ascii("OggS")) ?? (buffer.count - 3)
                reader.skip(Swift.max(seekPosition, 1))
            }
        }
    }

    private func parseHeaders() throws {
        var pageStartPosition = reader.position  // set audio offset later if its audio data
        var checkFlacSecondPacket = false
        var checkSpeexSecondPacket = false

        try parsePages { [self] packet in
            if packet.hasPrefix([0x01] + ascii("vorbis")) {
                guard packet.count >= 28 else { return false }

                sampleRate = packet.signedLittleEndianInt32(12)
                let nominalBitrate = packet.signedLittleEndianInt32(20)

                if audioOffset == nil {
                    bitrate = Double(nominalBitrate) / 1000
                    audioOffset = pageStartPosition
                }

            } else if packet.hasPrefix([0x03] + ascii("vorbis")) {
                // Comments, not needed

            } else if packet.hasPrefix(ascii("OpusHead")) {
                // parse opus header
                // https://www.videolan.org/developers/vlc/modules/codec/opus_header.c
                // https://mf4.xiph.org/jenkins/view/opus/job/opusfile-unix/ws/doc/html/structOpusHead.html
                guard packet.count >= 19 else { return false }

                let version = packet[offset: 8]

                if version & 0xF0 == 0 {
                    // only major version 0 supported
                    channels = Int(packet[offset: 9])
                    sampleRate = 48000  // internally opus always uses 48khz
                }

            } else if packet.hasPrefix(ascii("OpusTags")) {
                // Comments, not needed

            } else if packet.hasPrefix([0x7F] + ascii("FLAC")) {
                // https://xiph.org/flac/ogg_mapping.html
                // jump over header name, version and number of headers
                let flacTag = Flac(reader: TinyTagReader(data: packet.slice(9..<packet.count)), fileSize: fileSize)
                try flacTag.load()
                update(from: flacTag)
                checkFlacSecondPacket = true

            } else if checkFlacSecondPacket {
                // second packet contains FLAC metadata block
                checkFlacSecondPacket = false

            } else if packet.hasPrefix(ascii("Speex   ")) {
                // https://speex.org/docs/manual/speex-manual/node8.html
                guard packet.count >= 56 else { return false }

                // jump over header name and irrelevant fields
                sampleRate = packet.signedLittleEndianInt32(36)
                channels = packet.signedLittleEndianInt32(48)
                bitrate = Double(packet.signedLittleEndianInt32(52))
                checkSpeexSecondPacket = true

            } else if checkSpeexSecondPacket {
                checkSpeexSecondPacket = false

            } else {
                return false
            }

            pageStartPosition = reader.position
            return true
        }

        tagsParsed = true
    }

    /// Parses Ogg pages, calling the handler for each packet. Stops when the
    /// handler returns false.
    private func parsePages(_ handlePacket: (Data) throws -> Bool) throws {
        // for the spec, see: https://wiki.xiph.org/Ogg
        var previousPage = Data()  // contains data from previous (continuing) pages
        var headerData = reader.read(27)  // read ogg page header

        while headerData.count == 27 {
            // https://xiph.org/ogg/doc/framing.html
            let version = headerData[offset: 4]
            let position = Int(Int64(bitPattern: UInt64(truncatingIfNeeded: headerData.littleEndianInt(6..<14))))
            let segments = Int(headerData[offset: 26])

            maxSampleNumber = Swift.max(maxSampleNumber, position)

            guard headerData.hasPrefix(ascii("OggS")), version == 0 else {
                throw TinyTagError("Not a valid ogg file!")
            }

            let segmentSizes = reader.read(segments)
            var total = 0

            for segmentSize in segmentSizes {
                // read all segments
                total += Int(segmentSize)

                if total < 255 {
                    // less than 255 bytes means end of page
                    let packet = previousPage + reader.read(total)
                    previousPage = Data()
                    total = 0

                    if try !handlePacket(packet) {
                        return
                    }
                }
            }

            if total != 0 {
                if total % 255 == 0 {
                    previousPage += reader.read(total)
                } else {
                    let packet = previousPage + reader.read(total)
                    previousPage = Data()

                    if try !handlePacket(packet) {
                        return
                    }
                }
            }

            headerData = reader.read(27)
        }
    }
}

// MARK: - Wave

final class Wave: TinyTag {
    override func determineDuration() throws {
        // see: http://www-mmsp.ece.mcgill.ca/Documents/AudioFormats/WAVE/WAVE.html
        // and: https://en.wikipedia.org/wiki/WAV
        let header = reader.read(12)

        guard header.count == 12, header.hasPrefix(ascii("RIFF")), header.slice(8..<12) == Data(ascii("WAVE")) else {
            throw TinyTagError("not a wave file!")
        }

        bitDepth = 16  // assume 16bit depth (CD quality)
        var chunkHeader = reader.read(8)

        while chunkHeader.count == 8 {
            let subchunkID = chunkHeader.slice(0..<4)
            var subchunkSize = chunkHeader.littleEndianInt(4..<8)
            subchunkSize += subchunkSize % 2  // IFF chunks are padded to an even number of bytes

            if subchunkID == Data(ascii("fmt ")) {
                let format = try reader.readExactly(16)
                let channels = format.littleEndianInt(2..<4)
                let sampleRate = format.littleEndianInt(4..<8)
                var bitDepth = format.littleEndianInt(14..<16)

                if bitDepth == 0 {
                    // Certain codecs (e.g. GSM 6.10) give us a bit depth of zero.
                    // Avoid division by zero when calculating duration.
                    bitDepth = 1
                }

                self.channels = channels
                self.sampleRate = sampleRate
                self.bitDepth = bitDepth
                bitrate = Double(sampleRate * channels * bitDepth) / 1000

                let remainingSize = subchunkSize - 16
                if remainingSize > 0 {
                    reader.skip(remainingSize)  // skip remaining data in chunk
                }

            } else if subchunkID == Data(ascii("data")) {
                if let channels, channels > 0, let sampleRate, sampleRate > 0, let bitDepth {
                    duration = Double(subchunkSize) / Double(channels) / Double(sampleRate) / (Double(bitDepth) / 8)
                }

                audioOffset = reader.position - 8  // rewind to data header
                reader.skip(subchunkSize)

            } else {
                // some other chunk, just skip the data
                reader.skip(subchunkSize)
            }

            chunkHeader = reader.read(8)
        }
    }
}

// MARK: - Flac

final class Flac: TinyTag {
    static let metadataStreamInfo = 0
    static let metadataVorbisComment = 4

    private var overriddenFileSize: Int?

    required init(reader: TinyTagReader) {
        super.init(reader: reader)
    }

    convenience init(reader: TinyTagReader, fileSize: Int) {
        self.init(reader: reader)
        overriddenFileSize = fileSize
    }

    private var totalFileSize: Int {
        overriddenFileSize ?? fileSize
    }

    override func load() throws {
        var header = reader.peek(4)

        if header.hasPrefix(ascii("ID3")) {
            // skip ID3 header if it exists
            let id3 = ID3(reader: reader)
            let size = try id3.parseID3v2Header()
            reader.skip(size)
            header = reader.peek(4)  // after ID3 should be fLaC
        }

        guard header.hasPrefix(ascii("fLaC")) else {
            throw TinyTagError("Invalid flac header")
        }

        reader.skip(4)
        try determineDuration()
    }

    override func determineDuration() throws {
        // for spec, see https://xiph.org/flac/ogg_mapping.html
        var headerData = reader.read(4)

        while headerData.count == 4 {
            let blockType = Int(headerData[offset: 0] & 0x7F)
            let isLastBlock = headerData[offset: 0] & 0x80 != 0
            let size = headerData.bigEndianInt(1..<4)

            if blockType == Self.metadataStreamInfo {
                // http://xiph.org/flac/format.html#metadata_block_streaminfo
                let streamInfo = reader.read(size)

                if streamInfo.count < 34 {
                    // invalid streaminfo
                    return
                }

                // |----- samplerate -----| |-||----| |---------~   ~----|
                // 0000 0000 0000 0000 0000 0000 0000 0000 0000      0000
                // #---4---# #---5---# #---6---# #---7---# #--8-~   ~-12-#
                let header = streamInfo.slice(10..<18)
                let sampleRate = header.bigEndianInt(0..<3) >> 4

                self.sampleRate = sampleRate
                channels = Int((header[offset: 2] >> 1) & 0x07) + 1
                bitDepth = Int((header[offset: 2] & 1) << 4) + Int((header[offset: 3] & 0xF0) >> 4) + 1

                let totalSamples = Int(header[offset: 3] & 0x0F) << 32 | header.bigEndianInt(4..<8)

                if sampleRate > 0 {
                    let duration = Double(totalSamples) / Double(sampleRate)
                    self.duration = duration

                    if duration > 0 {
                        bitrate = Double(totalFileSize) / duration * 8 / 1000
                    }
                }

            } else if blockType >= 127 {
                return  // invalid block type

            } else {
                reader.skip(size)  // seek over this block
            }

            if isLastBlock {
                return
            }

            headerData = reader.read(4)
        }
    }
}

// MARK: - Wma

final class Wma: TinyTag {
    private static let asfHeaderObject: [UInt8] = [
        0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C
    ]
    private static let asfFilePropertyObject: [UInt8] = [
        0xA1, 0xDC, 0xAB, 0x8C, 0x47, 0xA9, 0xCF, 0x11, 0x8E, 0xE4, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65
    ]
    private static let asfStreamPropertiesObject: [UInt8] = [
        0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65
    ]
    private static let streamTypeASFAudioMedia: [UInt8] = [
        0x40, 0x9E, 0x69, 0xF8, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B
    ]

    // see:
    // http://web.archive.org/web/20131203084402/http://msdn.microsoft.com/en-us/library/bb643323.aspx
    override func determineDuration() throws {
        guard reader.read(16) == Data(Self.asfHeaderObject) else {
            // not a valid ASF container! see: http://www.garykessler.net/library/file_sigs.html
            return
        }

        reader.skip(8)  // size
        reader.skip(4)  // object count

        guard reader.read(2) == Data([0x01, 0x02]) else {
            return  // not a valid asf header!
        }

        while true {
            let objectID = reader.read(16)
            let objectSize = reader.read(8).littleEndianInt(0..<8)

            if objectSize == 0 || objectSize > fileSize {
                break  // invalid object, stop parsing.
            }

            if objectID == Data(Self.asfFilePropertyObject) {
                let blocks = reader.read(80)
                guard blocks.count == 80 else { break }

                let playDuration = blocks.littleEndianInt(40..<48)
                let preroll = Double(blocks.littleEndianInt(56..<64)) / 1000

                // According to the specification, we need to subtract the preroll from play_duration
                // to get the actual duration of the file
                duration = Swift.max(Double(playDuration) / 10_000_000 - preroll, 0.0)

            } else if objectID == Data(Self.asfStreamPropertiesObject) {
                let blocks = reader.read(54)
                guard blocks.count == 54 else { break }

                let streamType = blocks.slice(0..<16)
                let typeSpecificDataLength = blocks.littleEndianInt(40..<44)
                let errorCorrectionDataLength = blocks.littleEndianInt(44..<48)
                var alreadyRead = 0

                if streamType == Data(Self.streamTypeASFAudioMedia) {
                    let streamInfo = reader.read(16)
                    guard streamInfo.count == 16 else { break }

                    let codecIDFormatTag = streamInfo.littleEndianInt(0..<2)
                    sampleRate = streamInfo.littleEndianInt(4..<8)
                    bitrate = Double(streamInfo.littleEndianInt(8..<12) * 8) / 1000

                    if codecIDFormatTag == 355 {
                        // lossless
                        bitDepth = streamInfo.littleEndianInt(14..<16)
                    }

                    alreadyRead = 16
                }

                reader.skip(typeSpecificDataLength - alreadyRead)
                reader.skip(errorCorrectionDataLength)

            } else {
                reader.skip(objectSize - 24)  // read over unknown object ids
            }
        }
    }
}

// MARK: - Aiff

/// AIFF is part of the IFF family of file formats.
///
/// https://en.wikipedia.org/wiki/Audio_Interchange_File_Format#Data_format
final class Aiff: TinyTag {
    override func determineDuration() throws {
        let header = reader.read(12)
        let form = header.slice(8..<12)

        guard header.count == 12, header.hasPrefix(ascii("FORM")),
              form == Data(ascii("AIFC")) || form == Data(ascii("AIFF")) else {
            throw TinyTagError("not an aiff file!")
        }

        var chunkHeader = reader.read(8)

        while chunkHeader.count == 8 {
            let subChunkID = chunkHeader.slice(0..<4)
            var subChunkSize = chunkHeader.bigEndianInt(4..<8)
            subChunkSize += subChunkSize % 2  // IFF chunks are padded to an even number of bytes

            if subChunkID == Data(ascii("COMM")) {
                let common = reader.read(18)
                guard common.count == 18 else { break }

                let channels = Int(Int16(bitPattern: UInt16(common.bigEndianInt(0..<2))))
                let numFrames = common.bigEndianInt(2..<6)
                let bitDepth = Int(Int16(bitPattern: UInt16(common.bigEndianInt(6..<8))))

                self.channels = channels
                self.bitDepth = bitDepth

                // Extended precision
                let exponent = common.bigEndianInt(8..<10)
                let mantissa = UInt64(truncatingIfNeeded: common.bigEndianInt(10..<18))
                let sampleRateValue = Double(mantissa) * pow(2, Double(exponent - 0x3FFF - 63))

                if sampleRateValue.isFinite, sampleRateValue >= 1, sampleRateValue < Double(Int.max) {
                    let sampleRate = Int(sampleRateValue)
                    self.sampleRate = sampleRate
                    duration = Double(numFrames) / Double(sampleRate)
                    bitrate = Double(sampleRate * channels * bitDepth) / 1000
                } else {
                    // invalid sample rate
                    sampleRate = nil
                    duration = nil
                    bitrate = nil
                }

                reader.skip(subChunkSize - 18)  // skip remaining data in chunk

            } else if subChunkID == Data(ascii("SSND")) {
                audioOffset = reader.position
                reader.skip(subChunkSize)

            } else {
                // some other chunk, just skip the data
                reader.skip(subChunkSize)
            }

            chunkHeader = reader.read(8)
        }
    }
}
