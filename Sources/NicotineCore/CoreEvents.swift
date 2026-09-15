// SPDX-License-Identifier: GPL-3.0-or-later
//
// General application events, and events emitted by the networking thread.

// MARK: - General

public extension EventName where Payload == Void {
    static var quit: Self { .init("quit") }
    static var scheduleQuit: Self { .init("schedule-quit") }
    static var confirmQuit: Self { .init("confirm-quit") }
    static var setup: Self { .init("setup") }
    static var start: Self { .init("start") }
    static var enableMessageQueue: Self { .init("enable-message-queue") }
    static var cliPromptFinished: Self { .init("cli-prompt-finished") }
}

public extension EventName where Payload == SlskMessage {
    static var queueNetworkMessage: Self { .init("queue-network-message") }
}

public struct ConnectionStats: Sendable {
    public var totalConnections = 0
    public var downloadBandwidth = 0
    public var uploadBandwidth = 0

    public init(totalConnections: Int = 0, downloadBandwidth: Int = 0, uploadBandwidth: Int = 0) {
        self.totalConnections = totalConnections
        self.downloadBandwidth = downloadBandwidth
        self.uploadBandwidth = uploadBandwidth
    }
}

public extension EventName where Payload == ConnectionStats {
    static var setConnectionStats: Self { .init("set-connection-stats") }
}

public struct LatestVersionInfo: Sendable {
    public var latestVersion: String?
    public var isOutdated: Bool
    public var errorMessage: String?
}

public extension EventName where Payload == LatestVersionInfo {
    static var checkLatestVersion: Self { .init("check-latest-version") }
}

public struct CLICommand: Sendable {
    public var command: String
    public var args: String
}

public extension EventName where Payload == CLICommand {
    static var cliCommand: Self { .init("cli-command") }
}

// MARK: - Server Connection

public extension EventName where Payload == ServerDisconnect {
    static var serverDisconnect: Self { .init("server-disconnect") }
}

public extension EventName where Payload == ServerReconnect {
    static var serverReconnect: Self { .init("server-reconnect") }
}

// MARK: - Peer Connections

public struct PeerConnectionEvent: Sendable {
    public var username: String
    public var connType: String
    public var msgs: [SlskMessage]
    public var isOffline = false
}

public extension EventName where Payload == PeerConnectionEvent {
    static var peerConnectionClosed: Self { .init("peer-connection-closed") }
    static var peerConnectionError: Self { .init("peer-connection-error") }
}

public struct FileConnectionClosedEvent: Sendable {
    public var username: String
    public var token: Int
    public var sock: Socket
    public var timedOut: Bool
}

public extension EventName where Payload == FileConnectionClosedEvent {
    static var fileConnectionClosed: Self { .init("file-connection-closed") }
}

// MARK: - Transfer Progress

public struct FileDownloadProgress: Sendable {
    public var username: String
    public var token: Int
    public var bytesLeft: Int
    public var speed: Int?
}

public extension EventName where Payload == FileDownloadProgress {
    static var fileDownloadProgress: Self { .init("file-download-progress") }
}

public struct FileUploadProgress: Sendable {
    public var username: String
    public var token: Int
    public var offset: Int?
    public var bytesSent: Int
    public var speed: Int?
}

public extension EventName where Payload == FileUploadProgress {
    static var fileUploadProgress: Self { .init("file-upload-progress") }
}

public struct FileErrorEvent: Sendable {
    public var username: String
    public var token: Int
    public var error: Error
}

public extension EventName where Payload == FileErrorEvent {
    static var downloadFileError: Self { .init("download-file-error") }
    static var uploadFileError: Self { .init("upload-file-error") }
}

/// Progress of a large incoming peer message (shared file list, user info).
public struct MessageProgress: Sendable {
    public var username: String
    public var sock: Socket
    public var bufferLength: Int
    public var messageSizeTotal: Int
}

public extension EventName where Payload == MessageProgress {
    static var sharedFileListProgress: Self { .init("shared-file-list-progress") }
    static var userInfoProgress: Self { .init("user-info-progress") }
}
