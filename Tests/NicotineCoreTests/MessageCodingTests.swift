// SPDX-License-Identifier: GPL-3.0-or-later
//
// Expected bytes were produced by the reference Nicotine+ 3.3.10
// implementation, to verify wire compatibility.

import Foundation
import Testing
@testable import NicotineCore

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func bytes(_ hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex

    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}

@Suite struct MessagePackingTests {

    @Test func login() throws {
        let message = Login(username: "user", password: "pass", version: 160, minorVersion: 2)
        #expect(try hex(message.makeNetworkMessage()) ==
            "04000000757365720400000070617373a000000020000000363365373830633366333231643133313039"
            + "633731626638313830353437366502000000")
    }

    @Test func setWaitPort() throws {
        #expect(try hex(SetWaitPort(port: 2234).makeNetworkMessage()) == "ba080000")
    }

    @Test func fileSearchRemovesStandaloneDashesAndUsesLegacyEncoding() throws {
        let message = FileSearch(token: 1234, text: "hello - world é")
        #expect(try hex(message.makeNetworkMessage()) == "d20400000d00000068656c6c6f20776f726c6420e9")
    }

    @Test func joinRoom() throws {
        #expect(try hex(JoinRoom(room: "nicotine", isPrivate: true).makeNetworkMessage())
            == "080000006e69636f74696e6501000000")
    }

    @Test func connectToPeer() throws {
        #expect(try hex(ConnectToPeer(token: 99, user: "bob", connType: "P").makeNetworkMessage())
            == "6300000003000000626f620100000050")
    }

    @Test func transferRequestUpload() throws {
        let message = TransferRequest(direction: .upload, token: 7, file: "a\\b.mp3", fileSize: 12_345_678_901)
        #expect(try hex(message.makeNetworkMessage()) == "010000000700000007000000615c622e6d7033351cdcdf02000000")
    }

    @Test func transferResponseRejected() throws {
        let message = TransferResponse(allowed: false, reason: "Queued", token: 7)
        #expect(try hex(message.makeNetworkMessage()) == "070000000006000000517565756564")
    }

    @Test func peerInit() throws {
        let message = PeerInit(initUser: "me", targetUser: "you", connType: "P")
        #expect(try hex(message.makeNetworkMessage()) == "020000006d65010000005000000000")
    }

    @Test func userInfoResponse() throws {
        let message = UserInfoResponse(description: "desc", picture: Data([1, 2]), totalUploads: 5, queueSize: 3,
                                       slotsAvailable: true, uploadAllowed: 1)
        #expect(try hex(message.makeNetworkMessage())
            == "04000000646573630102000000010205000000030000000101000000")
    }

    @Test func packLossyFileInfo() {
        let fileInfo = SharedFileInfo(virtualPath: "a\\b.mp3", size: 5_000_000,
                                      quality: AudioQuality(bitrate: 320, isVBR: true), duration: 200)
        #expect(hex(FileListMessage.packFileInfo(fileInfo))
            == "0107000000615c622e6d7033404b4c00000000000000000003000000000000004001000001000000c800000002000000"
            + "01000000")
    }

    @Test func packLosslessFileInfo() {
        let fileInfo = SharedFileInfo(virtualPath: "a\\b.flac", size: 30_000_000,
                                      quality: AudioQuality(bitrate: 1411, isVBR: false, sampleRate: 44100,
                                                            bitDepth: 16),
                                      duration: 180)
        #expect(hex(FileListMessage.packFileInfo(fileInfo))
            == "0108000000615c622e666c616380c3c90100000000000000000300000001000000b40000000400000044ac0000050000"
            + "0010000000")
    }

    @Test func negativeBranchLevel() throws {
        #expect(try hex(DistribBranchLevel(level: -1).makeNetworkMessage()) == "ffffffff")
    }
}

@Suite struct MessageParsingTests {

    @Test func getPeerAddress() throws {
        let message = GetPeerAddress()
        try message.parseNetworkMessage(bytes("05000000616c69636504030201ba0800000000000000000000"))

        #expect(message.user == "alice")
        #expect(message.ipAddress == "1.2.3.4")
        #expect(message.port == 2234)
    }

    @Test func truncatedMessageThrows() {
        let message = GetPeerAddress()
        #expect(throws: MessageError.self) {
            try message.parseNetworkMessage(bytes("05000000616c696365"))
        }
    }

    @Test func latin1StringFallback() throws {
        var reader = MessageReader(bytes("01000000e9"))
        #expect(try reader.readString() == "é")
    }

    @Test func sharedFileListRoundTrip() throws {
        let fileInfo = SharedFileInfo(virtualPath: "song.mp3", size: 1000, quality: AudioQuality(bitrate: 128,
                                                                                                 isVBR: false),
                                      duration: 60)
        var packedFiles = Data()
        packedFiles.appendUInt32(1)
        packedFiles.append(FileListMessage.packFileInfo(fileInfo))

        let outgoing = SharedFileListResponse(publicShares: ["Music\\Album": packedFiles], permissionLevel: .public)
        let incoming = SharedFileListResponse()
        try incoming.parseNetworkMessage(outgoing.makeNetworkMessage())

        #expect(incoming.list.count == 1)
        #expect(incoming.list[0].path == "Music\\Album")
        #expect(incoming.list[0].files == [
            FileListEntry(code: 1, name: "song.mp3", size: 1000, attributes: [0: 128, 1: 60, 2: 0])
        ])
    }

    @Test func fileSearchResponseIgnoresUnknownTokens() throws {
        let outgoing = FileSearchResponse(searchUsername: "me", token: 424_242, shares: [
            SharedFileInfo(virtualPath: "a.mp3", size: 1, quality: nil, duration: nil)
        ], freeUploadSlots: true, uploadSpeed: 100, inQueue: 0)
        let data = try outgoing.makeNetworkMessage()

        let ignored = FileSearchResponse()
        try ignored.parseNetworkMessage(data)
        #expect(ignored.list.isEmpty)

        SearchTokens.allow(424_242)
        defer { SearchTokens.disallow(424_242) }

        let accepted = FileSearchResponse()
        try accepted.parseNetworkMessage(data)
        #expect(accepted.list.map(\.name) == ["a.mp3"])
        #expect(accepted.freeUploadSlots)
        #expect(accepted.uploadSpeed == 100)
    }

    @Test func audioQualityLength() {
        let lossless = FileListMessage.parseAudioQualityLength(fileSize: 0, attributes: [1: 180, 4: 44100, 5: 16])
        #expect(lossless.humanQuality == "44.1 kHz / 16 bit")
        #expect(lossless.bitrate == 1411)
        #expect(lossless.humanLength == "3:00")

        let vbr = FileListMessage.parseAudioQualityLength(fileSize: 0, attributes: [0: 245, 1: 3725, 2: 1])
        #expect(vbr.humanQuality == "245 kbps (vbr)")
        #expect(vbr.humanLength == "1:02:05")
    }
}
