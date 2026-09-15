// SPDX-License-Identifier: GPL-3.0-or-later
//
// Expected values were produced by the reference Nicotine+ 3.3.10 tinytag
// implementation, using the same fixture files.

import Foundation
import Testing
@testable import NicotineCore

@Suite struct TinyTagTests {

    struct Expectation: Sendable {
        let file: String
        let bitrate: Double?
        let sampleRate: Int?
        let bitDepth: Int?
        let duration: Double?
        let isVBR: Bool
    }

    static let expectations: [Expectation] = [
        Expectation(file: "tone.aiff", bitrate: 1411.2, sampleRate: 44100, bitDepth: 16, duration: 0.5, isVBR: false),
        Expectation(file: "tone.flac", bitrate: 121.504, sampleRate: 44100, bitDepth: 16, duration: 0.5, isVBR: false),
        Expectation(file: "tone.m4a", bitrate: 128.0, sampleRate: 44100, bitDepth: nil, duration: 0.5572789115646258,
                    isVBR: false),
        Expectation(file: "tone.ogg", bitrate: 0.0, sampleRate: 44100, bitDepth: nil, duration: 0.5006802721088436,
                    isVBR: false),
        Expectation(file: "tone.opus", bitrate: nil, sampleRate: 48000, bitDepth: nil, duration: 0.5065, isVBR: false),
        Expectation(file: "tone.wav", bitrate: 1411.2, sampleRate: 44100, bitDepth: 16, duration: 0.5, isVBR: false),
        Expectation(file: "tone.wma", bitrate: 128.0, sampleRate: 44100, bitDepth: nil, duration: 0.5099999999999998,
                    isVBR: false),
        Expectation(file: "tone_alac.m4a", bitrate: 128.108, sampleRate: 44100, bitDepth: 16, duration: 0.5,
                    isVBR: false),
        Expectation(file: "tone_cbr.mp3", bitrate: 192.0, sampleRate: 44100, bitDepth: nil,
                    duration: 0.5695994580404776, isVBR: false),
        Expectation(file: "tone_vbr.mp3", bitrate: 47.454166666666666, sampleRate: 44100, bitDepth: nil,
                    duration: 0.5485714285714286, isVBR: true)
    ]

    private static func isClose(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return abs(lhs - rhs) < 1e-9
        default: return false
        }
    }

    @Test(arguments: expectations)
    func audioProperties(_ expected: Expectation) throws {
        let url = try #require(Bundle.module.url(forResource: expected.file, withExtension: nil,
                                                 subdirectory: "Fixtures"))
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let parserClass = try #require(TinyTag.parserClass(for: url.lastPathComponent))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let tag = parserClass.init(reader: TinyTagReader(handle: handle, fileSize: size))
        try tag.load()

        #expect(Self.isClose(tag.bitrate, expected.bitrate), "bitrate \(String(describing: tag.bitrate))")
        #expect(tag.sampleRate == expected.sampleRate)
        #expect(tag.bitDepth == expected.bitDepth)
        #expect(Self.isClose(tag.duration, expected.duration), "duration \(String(describing: tag.duration))")
        #expect(tag.isVBR == expected.isVBR)
    }
}
