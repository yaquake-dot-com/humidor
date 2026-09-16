// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

// MARK: - Message Routing

/// Messages sent over a specific connection.
protocol SocketMessage: AnyObject {
    var sock: Socket? { get set }
}

/// Messages sent to, or received from, a specific peer.
protocol PeerConnectionMessage: SocketMessage {
    var username: String? { get set }
}

extension PierceFireWall: SocketMessage {}
extension PeerInit: SocketMessage {}
extension PeerMessage: PeerConnectionMessage {}
extension FileMessage: PeerConnectionMessage {}
extension DistribMessage: PeerConnectionMessage {}

/// Error for invalid file offsets requested by peers, e.g. Soulseek NS
/// sending an offset of -1 when resuming downloads larger than 2 GB.
public struct FileOffsetError: LocalizedError {
    public let offset: Int

    public var errorDescription: String? {
        "negative seek value \(offset)"
    }
}

private func monotonicTime() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

// MARK: - Connections

class Connection: Hashable {
    var sock: Socket?
    let addr: PeerAddress
    var ioEvents: IOEvents
    var isEstablished = false
    var inBuffer: [UInt8] = []
    var outBuffer: [UInt8] = []
    var lastActive = monotonicTime()
    var recvSize = 51200

    init(sock: Socket, addr: PeerAddress, ioEvents: IOEvents) {
        self.sock = sock
        self.addr = addr
        self.ioEvents = ioEvents
    }

    static func == (lhs: Connection, rhs: Connection) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

final class ServerConnection: Connection {
    var login: LoginCredentials?

    init(sock: Socket, addr: PeerAddress, ioEvents: IOEvents, login: LoginCredentials?) {
        self.login = login
        super.init(sock: sock, addr: addr, ioEvents: ioEvents)
    }
}

final class PeerConnection: Connection {
    var initMessage: PeerInit?
    /// Requesting indirect connection to user
    var requestToken: Int?
    /// Responding to indirect connection request from user
    var responseToken: Int?
    var hasPostInitActivity = false

    init(sock: Socket, addr: PeerAddress, ioEvents: IOEvents, initMessage: PeerInit? = nil,
         requestToken: Int? = nil, responseToken: Int? = nil) {
        self.initMessage = initMessage
        self.requestToken = requestToken
        self.responseToken = responseToken
        super.init(sock: sock, addr: addr, ioEvents: ioEvents)
    }

    var targetUser: String {
        initMessage?.targetUser ?? ""
    }
}

private extension [UInt8] {
    func uint32(at offset: Int) -> Int {
        withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
    }

    func data(_ range: Range<Int>) -> Data {
        Data(self[range])
    }
}

// MARK: - Network Thread

/// The networking thread does all the communication with the Soulseek server
/// and peers. Communication with the rest of the application is done through
/// events.
///
/// The server and peers send each other small binary messages that start with
/// length and message code followed by the actual message data.
public final class NetworkThread: @unchecked Sendable {

    static let inProgressStaleAfter = 2.0
    static let indirectRequestTimeout = 20.0
    static let connectionMaxIdle = 60.0
    static let connectionMaxIdleGhost = 10.0
    static let connectionBacklogLength: Int32 = 65535  // OS limit can be lower
    static let maxIncomingMessageSize = 469_762_048     // 448 MiB, to leave headroom for large shares
    static let allowedPeerConnTypes: Set<String> = [
        ConnectionType.peer.rawValue,
        ConnectionType.file.rawValue,
        ConnectionType.distributed.rawValue
    ]

    // Looping max ~240 times per second (sleepMinIdle) on high activity
    // ~20 (sleepMaxIdle + sleepMinIdle) by default
    static let sleepMaxIdle = 0.04584
    static let sleepMinIdle = 0.00416

    /// Maximum number of concurrent sockets.
    static let maxSockets: Int = {
        // Increase the process file limit to a maximum of 10240 (macOS limit), to provide
        // breathing room for opening both peer sockets and regular files (file transfers,
        // log files etc.)
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)

        let maxFileLimit = Swift.min(limit.rlim_max, 10240)
        limit.rlim_cur = maxFileLimit
        setrlimit(RLIMIT_NOFILE, &limit)

        // Reserve 2/3 of the file limit for sockets, but always limit the maximum number
        // of sockets to 3072 to improve performance.
        return Swift.min(Int(Double(maxFileLimit) * (2.0 / 3.0)), 3072)
    }()

    // State shared with the main thread
    private let queueLock = NSLock()
    private var messageQueue: [SlskMessage] = []
    private var shouldProcessQueueValue = false
    private var wantAbortValue = false
    private var thread: Thread?

    private var shouldProcessQueue: Bool {
        get { queueLock.withLock { shouldProcessQueueValue } }
        set { queueLock.withLock { shouldProcessQueueValue = newValue } }
    }

    private var wantAbort: Bool {
        queueLock.withLock { wantAbortValue }
    }

    // Networking thread state
    private var pendingPeerConns: [PeerAddress: PeerInit] = [:]
    private var pendingInitMsgs: [String: [PeerInit]] = [:]
    private var tokenInitMsgs: [Int: (initMessage: PeerInit, requestTime: Double)] = [:]
    private var usernameInitMsgs: [String: PeerInit] = [:]
    private var userAddresses: [String: PeerAddress?] = [:]

    private var selector: Selector?
    private var listenSocket: Socket?
    private var listenPort: Int?
    private var interfaceName: String?
    private var interfaceAddress: String?
    private var portmapper: PortMapper?
    private var localIPAddress = ""

    private var serverConn: ServerConnection?
    private var serverAddress: PeerAddress?
    private var serverUsername: String?
    private var serverTimeoutTime: Double?
    private var serverTimeoutValue = -1
    private var manualServerDisconnect = false
    private var manualServerReconnect = false
    private var serverRelogged = false

    private var parentConn: PeerConnection?
    private var potentialParents: [String: PeerAddress] = [:]
    private var childPeers: [String: PeerConnection] = [:]
    private var branchLevel = 0
    private var branchRoot: String?
    private var isServerParent = false
    private var distribParentMinSpeed = 0
    private var distribParentSpeedRatio = 1
    private var maxDistribChildren = 0
    private var uploadSpeed = 0

    private var numSockets = 0
    private var lastCycleTime = 0.0

    private var conns: [Socket: Connection] = [:]
    private var socketsByDescriptor: [Int32: Socket] = [:]
    private var token = initialToken()

    private var fileInitMsgs: [Connection: FileTransferInit] = [:]
    private var fileDownloadMsgs: [Connection: DownloadFile] = [:]
    private var fileUploadMsgs: [Connection: UploadFile] = [:]
    private var connsDownloaded: [Connection: Int] = [:]
    private var connsUploaded: [Connection: Int] = [:]
    private var uploadLimitMode = UploadLimitMode.none
    private var uploadLimit = 0
    private var downloadLimit = 0
    private var uploadLimitSplit = 0
    private var downloadLimitSplit = 0
    private var totalUploads = 0
    private var totalDownloads = 0
    private var totalDownloadBandwidth = 0
    private var totalUploadBandwidth = 0

    private enum UploadLimitMode {
        case none
        case total
        case perTransfer
    }

    @MainActor
    public init() {
        events.connect(.enableMessageQueue) { [self] in enableMessageQueue() }
        events.connect(.queueNetworkMessage) { [self] message in queueNetworkMessage(message) }
        events.connect(.scheduleQuit) { [self] in scheduleQuit() }
        events.connect(.start) { [self] in start() }
    }

    private func enableMessageQueue() {
        shouldProcessQueue = true
    }

    private func queueNetworkMessage(_ message: SlskMessage) {
        queueLock.withLock {
            if shouldProcessQueueValue {
                messageQueue.append(message)
            }
        }
    }

    private func scheduleQuit() {
        queueLock.withLock { wantAbortValue = true }
    }

    private func start() {
        let thread = Thread { [self] in run() }
        thread.name = "NetworkThread"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    // MARK: Sockets

    private func makeSocket() -> Socket? {
        let fileDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)

        guard fileDescriptor >= 0 else {
            return nil
        }

        // Prevent SIGPIPE when writing to a closed connection
        POSIXSocket.setOption(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, 1)
        POSIXSocket.setNonBlocking(fileDescriptor)

        let sock = Socket(fileDescriptor: fileDescriptor)
        socketsByDescriptor[fileDescriptor] = sock
        return sock
    }

    private func closeSocket(_ sock: Socket) {
        log.addConn("Shutting down socket \(sock)")

        if shutdown(sock.fileDescriptor, SHUT_RDWR) != 0 {
            let error = SocketError()

            // Can't call shutdown if connection wasn't established, ignore error
            if error.code != ENOTCONN {
                log.addConn("Failed to shut down socket \(sock): \(error)")
            }
        }

        log.addConn("Closing socket \(sock)")
        socketsByDescriptor.removeValue(forKey: sock.fileDescriptor)
        Darwin.close(sock.fileDescriptor)
    }

    // MARK: Listening Socket

    private func createListenSocket() -> Bool {
        guard let sock = makeSocket() else {
            return false
        }

        listenSocket = sock
        numSockets += 1

        // SO_REUSEADDR is necessary to allow binding to the same port immediately
        // after reconnecting
        POSIXSocket.setOption(sock.fileDescriptor, SOL_SOCKET, SO_REUSEADDR, 1)

        guard bindListenPort() else {
            closeListenSocket()
            return false
        }

        selector?.register(sock.fileDescriptor, .read)
        return true
    }

    private func closeListenSocket() {
        guard let listenSocket else {
            return
        }

        selector?.unregister(listenSocket.fileDescriptor)
        closeSocket(listenSocket)

        self.listenSocket = nil
        listenPort = nil
        numSockets -= 1
    }

    private func bindListenPort() -> Bool {
        guard let listenSocket, let listenPort else {
            return false
        }

        guard bindSocketInterface(listenSocket) else {
            setServerTimer(useFixedTimeout: true)
            log.add(String(localized: "Specified network interface '\(interfaceName ?? "")' is not available",
                           bundle: .module))
            return false
        }

        let ipAddress = interfaceAddress ?? POSIXSocket.findLocalIPAddress()

        do {
            try POSIXSocket.bind(listenSocket.fileDescriptor, ipAddress: ipAddress, port: listenPort)

            if listen(listenSocket.fileDescriptor, Self.connectionBacklogLength) != 0 {
                throw SocketError()
            }

        } catch {
            setServerTimer(useFixedTimeout: true)
            log.add(String(localized: "Cannot listen on port \(String(listenPort)). Ensure no other application uses it, or choose a different port. Error: \(error.localizedDescription)",
                           bundle: .module))
            self.listenPort = nil
            return false
        }

        localIPAddress = ipAddress

        if let interfaceName, !interfaceName.isEmpty {
            log.addDebug("Network interface: \(interfaceName)")
        }

        log.addDebug("Local IP address: \(ipAddress)")
        log.addDebug("Maximum number of concurrent connections (sockets): \(Self.maxSockets)")
        log.add(String(localized: "Listening on port: \(String(listenPort))", bundle: .module))
        return true
    }

    // MARK: Connections

    private func indirectRequestError(token: Int, initMessage: PeerInit) {
        let username = initMessage.targetUser
        let connType = initMessage.connType

        log.addConn("Indirect connect request of type \(connType) to user \(username) with token \(token) failed")

        guard initMessage.sock == nil else {
            return
        }

        // No direct connection was established, give up
        events.emitMainThread(.peerConnectionError, PeerConnectionEvent(
            username: username, connType: connType, msgs: initMessage.outgoingMessages
        ))
        initMessage.outgoingMessages.removeAll()
        usernameInitMsgs.removeValue(forKey: username + connType)
    }

    private func checkIndirectRequestTimeouts(currentTime: Double = 0, expireAll: Bool = false) {
        guard !tokenInitMsgs.isEmpty else {
            return
        }

        var timedOutRequests: [Int] = []

        for (token, request) in tokenInitMsgs {
            if !expireAll && (currentTime - request.requestTime) < Self.indirectRequestTimeout {
                continue
            }

            indirectRequestError(token: token, initMessage: request.initMessage)
            timedOutRequests.append(token)
        }

        for token in timedOutRequests {
            tokenInitMsgs.removeValue(forKey: token)
        }
    }

    private func isConnectionStillActive(_ conn: Connection) -> Bool {
        if let conn = conn as? PeerConnection, let initMessage = conn.initMessage,
           initMessage.connType != ConnectionType.peer.rawValue || initMessage.targetUser == serverUsername {
            // Distributed and file connections, as well as connections to ourselves,
            // are critical. Always assume they are active.
            return true
        }

        return !conn.outBuffer.isEmpty || !conn.inBuffer.isEmpty
    }

    /// Attempts to bind the socket to the IP address of the network interface
    /// (or the IP address provided with the --bindip CLI argument).
    private func bindSocketInterface(_ sock: Socket) -> Bool {
        if let interfaceAddress {
            if sock != listenSocket {
                try? NetworkInterfaces.bindToInterface(sock.fileDescriptor, address: interfaceAddress)
            }
            return true
        }

        return interfaceName?.isEmpty ?? true
    }

    @discardableResult
    private func addInitMessage(_ initMessage: PeerInit) -> Bool {
        let connType = initMessage.connType

        if connType == ConnectionType.file.rawValue {
            // File transfer connections are not unique or reused later
            return true
        }

        let initKey = initMessage.targetUser + connType

        if usernameInitMsgs[initKey] == nil {
            usernameInitMsgs[initKey] = initMessage
            return true
        }

        return false
    }

    private func packNetworkMessage(_ message: SlskMessage) -> Data? {
        do {
            return try message.makeNetworkMessage()
        } catch {
            log.add("Unable to pack message type \(type(of: message)): \(error)")
        }
        return nil
    }

    private func unpackNetworkMessage(_ messageClass: SlskMessage.Type, content: Data, size: Int, connType: String,
                                      sock: Socket? = nil, addr: PeerAddress? = nil,
                                      username: String? = nil) -> SlskMessage? {
        let message = messageClass.init()

        if let sock, let socketMessage = message as? SocketMessage {
            socketMessage.sock = sock
        }

        if let addr, let peerMessage = message as? PeerMessage {
            peerMessage.addr = addr
        }

        if let username, let peerMessage = message as? PeerConnectionMessage {
            peerMessage.username = username
        }

        do {
            try message.parseNetworkMessage(content)
            return message

        } catch {
            log.addDebug("Unable to parse \(connType) message type \(messageClass), size \(size), "
                         + "contents \(content.prefix(50) as NSData). Error: \(error)")
        }

        return nil
    }

    /// Unpacks a distributed message embedded in another message.
    private func unpackEmbeddedMessage(code: Int, content: Data) -> SlskMessage? {
        guard let distribClass = MessageCodes.distributed.messageClass(for: code) else {
            log.addDebug("Embedded distrib message type \(code) unknown")
            return nil
        }

        let message = distribClass.init()

        do {
            try message.parseNetworkMessage(content)
        } catch {
            log.addDebug("Unable to parse embedded distrib message type \(code): \(error)")
            return nil
        }

        return message
    }

    private func emitNetworkMessageEvent(_ message: SlskMessage?) {
        guard let message else {
            return
        }

        log.addMessageContents(message)
        message.emitNetworkMessageEvent()
    }

    private func modifyConnectionEvents(_ conn: Connection, _ ioEvents: IOEvents) {
        guard conn.ioEvents != ioEvents, let sock = conn.sock else {
            return
        }

        selector?.modify(sock.fileDescriptor, ioEvents)
        conn.ioEvents = ioEvents
    }

    /// A connection is established with the peer, time to queue up our peer
    /// messages for delivery.
    private func processConnMessages(_ initMessage: PeerInit) {
        let username = initMessage.targetUser
        let sock = initMessage.sock
        let messages = initMessage.outgoingMessages

        for message in messages {
            if let peerMessage = message as? PeerConnectionMessage {
                peerMessage.username = username
                peerMessage.sock = sock
            }
        }

        initMessage.outgoingMessages.removeAll()
        processOutgoingMessages(messages)
    }

    private func sendMessageToPeer(_ username: String, _ message: SlskMessage) {
        let connType = message.messageType.rawValue

        guard Self.allowedPeerConnTypes.contains(connType) else {
            log.addConn("Unknown connection type \(connType)")
            return
        }

        let initKey = username + connType

        // Check if there's already a connection for the specified username
        var initMessage = usernameInitMsgs[initKey]

        if initMessage == nil, connType != ConnectionType.file.rawValue, let pendingInits = pendingInitMsgs[username] {
            // Check if we have a pending PeerInit message (currently requesting user IP address)
            initMessage = pendingInits.first { $0.connType == connType }
        }

        guard let initMessage else {
            log.addConn("Sending message of type \(type(of: message)) to user \(username) on new connection")

            // This is a new peer, initiate a connection
            initiateConnectionToPeer(username, connType: connType, message: message)
            return
        }

        log.addConn("Sending message of type \(type(of: message)) to user \(username) on existing connection")
        initMessage.outgoingMessages.append(message)

        if let sock = initMessage.sock, conns[sock]?.isEstablished == true {
            // We have initiated a connection previously, and it's ready
            processConnMessages(initMessage)
        }
    }

    /// Prepares to initiate a connection with a peer.
    private func initiateConnectionToPeer(_ username: String, connType: String, message: SlskMessage? = nil,
                                          inAddress: PeerAddress? = nil) {
        let initMessage = PeerInit(initUser: serverUsername ?? "", targetUser: username, connType: connType)
        var userAddress = userAddresses[username] ?? nil

        if let inAddress {
            userAddress = inAddress

        } else if let address = userAddress, address.port == 0 {
            // Port 0 means the user is likely bugged, ask the server for a new address
            userAddress = nil
        }

        if let message {
            initMessage.outgoingMessages.append(message)
        }

        guard let userAddress else {
            pendingInitMsgs[username, default: []].append(initMessage)
            sendMessageToServer(GetPeerAddress(user: username))

            log.addConn("Requesting address for user \(username)")
            return
        }

        connectToPeer(username, addr: userAddress, initMessage: initMessage)
    }

    /// Initiates a connection with a peer.
    private func connectToPeer(_ username: String, addr: PeerAddress, initMessage: PeerInit, responseToken: Int? = nil) {
        let connType = initMessage.connType

        guard Self.allowedPeerConnTypes.contains(connType) else {
            log.addConn("Unknown connection type \(connType)")
            return
        }

        guard addInitMessage(initMessage) else {
            log.addConn("Direct connection of type \(connType) to user \(username) (\(addr)) requested, "
                        + "but existing connection already exists")
            return
        }

        log.addConn("Attempting direct connection of type \(connType) to user \(username), address \(addr)")
        initPeerConnection(addr: addr, initMessage: initMessage, responseToken: responseToken)
    }

    private func connectError(_ error: Error, conn: Connection) {
        if conn is ServerConnection {
            let address = conn.addr

            log.add(String(localized: "Cannot connect to server \(address.ipAddress):\(String(address.port)): \(error.localizedDescription)",
                           bundle: .module))
            setServerTimer()
            return
        }

        guard let conn = conn as? PeerConnection else {
            return
        }

        let connType = conn.initMessage?.connType ?? ""
        let username = conn.targetUser

        if let responseToken = conn.responseToken {
            log.addConn("Cannot respond to indirect connection request of type \(connType) from user \(username), "
                        + "token \(responseToken): \(error)")
            sendMessageToServer(CantConnectToPeer(token: responseToken, user: username))
            return
        }

        log.addConn("Direct connection of type \(connType) to user \(username) failed: \(error)")
    }

    /// Sends a message to the server to ask the peer to connect to us (indirect
    /// connection).
    @discardableResult
    private func connectToPeerIndirect(_ initMessage: PeerInit) -> Int {
        let username = initMessage.targetUser
        let connType = initMessage.connType

        token = incrementToken(token)
        tokenInitMsgs[token] = (initMessage, monotonicTime())
        sendMessageToServer(ConnectToPeer(token: token, user: username, connType: connType))

        log.addConn("Requesting indirect connection to user \(username) with token \(token)")
        return token
    }

    private func establishOutgoingPeerConnection(_ conn: PeerConnection) {
        conn.isEstablished = true

        guard let initMessage = conn.initMessage, let sock = conn.sock else {
            return
        }

        initMessage.sock = sock
        let username = initMessage.targetUser
        let connType = initMessage.connType

        log.addConn("Established outgoing connection of type \(connType) with user \(username). List of "
                    + "outgoing messages: \(initMessage.outgoingMessages)")

        if let responseToken = conn.responseToken {
            log.addConn("Responding to indirect connection request of type \(connType) from "
                        + "user \(username), token \(responseToken)")
            processOutgoingMessages([PierceFireWall(sock: sock, token: responseToken)])
            acceptChildPeerConnection(conn)
        } else {
            log.addConn("Sending peer init message of type \(connType) to user \(username)")
            processOutgoingMessages([initMessage])
        }

        processConnMessages(initMessage)
    }

    private func replaceExistingConnection(_ initMessage: PeerInit) {
        let username = initMessage.targetUser
        let connType = initMessage.connType

        guard username != serverUsername else {
            return
        }

        guard let previousInit = usernameInitMsgs.removeValue(forKey: username + connType),
              let previousSock = previousInit.sock else {
            return
        }

        log.addConn("Discarding existing connection of type \(connType) to user \(username)")

        initMessage.outgoingMessages = previousInit.outgoingMessages
        previousInit.outgoingMessages = []

        closeConnection(conns[previousSock])
    }

    private func closeConnection(_ conn: Connection?) {
        guard let conn, let sock = conn.sock else {
            return
        }

        conns.removeValue(forKey: sock)

        if conn === serverConn {
            // Disconnecting from server, clean up connections and queue
            serverDisconnect()
        }

        selector?.unregister(sock.fileDescriptor)
        closeSocket(sock)
        numSockets -= 1

        conn.sock = nil
        conn.inBuffer.removeAll()
        conn.outBuffer.removeAll()

        guard let peerConn = conn as? PeerConnection, let initMessage = peerConn.initMessage else {
            // No peer init message present, nothing to do
            return
        }

        let connType = initMessage.connType
        let username = initMessage.targetUser
        let addr = conn.addr
        let isConnectionReplaced = (initMessage.sock != sock)

        log.addConn("Removed connection of type \(connType) to user \(username), address \(addr)")

        if !isConnectionReplaced {
            initMessage.sock = nil
        }

        if connType == ConnectionType.distributed.rawValue {
            if childPeers[username] === peerConn {
                removeChildPeerConnection(username)

            } else if peerConn === parentConn {
                sendHaveNoParent()
            }

        } else if let fileInit = fileInitMsgs.removeValue(forKey: conn) {
            if shouldProcessQueue, let token = fileInit.token {
                let timedOut = (monotonicTime() - conn.lastActive) > Self.connectionMaxIdle
                events.emitMainThread(.fileConnectionClosed, FileConnectionClosedEvent(
                    username: username, token: token, sock: sock, timedOut: timedOut
                ))
            }
        }

        if fileDownloadMsgs.removeValue(forKey: conn) != nil {
            totalDownloads -= 1

            if totalDownloads == 0 {
                totalDownloadBandwidth = 0
            }

            calcDownloadLimit()

        } else if fileUploadMsgs.removeValue(forKey: conn) != nil {
            totalUploads -= 1

            if totalUploads == 0 {
                totalUploadBandwidth = 0
            }

            calcUploadLimit()
        }

        let initKey = username + connType

        guard let storedInit = usernameInitMsgs[initKey] else {
            return
        }

        log.addConn("Removing peer init message of type \(connType) for user \(username), address \(addr)")

        if isConnectionReplaced || initMessage !== storedInit {
            // Don't remove init message if connection has been superseded
            log.addConn("Cannot remove peer init message, since the connection has been superseded")
            return
        }

        if let requestToken = peerConn.requestToken, tokenInitMsgs[requestToken] != nil {
            // Indirect connection attempt in progress, remove init message later on timeout
            log.addConn("Cannot remove peer init message, since an indirect connection attempt is still in progress")
            return
        }

        let event: EventName<PeerConnectionEvent> = conn.isEstablished ? .peerConnectionClosed : .peerConnectionError
        events.emitMainThread(event, PeerConnectionEvent(
            username: username, connType: connType, msgs: initMessage.outgoingMessages
        ))

        usernameInitMsgs.removeValue(forKey: initKey)
    }

    private func isConnectionInactive(_ conn: Connection, currentTime: Double, numSockets: Int) -> Bool {
        if conn === serverConn {
            return false
        }

        if numSockets >= Self.maxSockets && !isConnectionStillActive(conn) {
            // Connection limit reached, close connection if inactive
            return true
        }

        let timeDiff = currentTime - conn.lastActive

        if let peerConn = conn as? PeerConnection, !peerConn.hasPostInitActivity,
           timeDiff > Self.connectionMaxIdleGhost {
            // "Ghost" connections can appear when an indirect connection is established,
            // search results arrive, we close the connection, and the direct connection attempt
            // succeeds afterwrds. Since the peer already sent a search result message, this connection
            // idles without any messages ever being sent beyond PeerInit. Close it sooner than regular
            // idling connections to prevent connections from piling up.
            return true
        }

        if timeDiff > Self.connectionMaxIdle {
            // No recent activity, peer connection is stale
            return true
        }

        return false
    }

    private func checkConnections(currentTime: Double) {
        let numSockets = self.numSockets
        var inactiveConns: [Connection] = []
        var staleConns: [Connection] = []

        for conn in conns.values {
            if !conn.isEstablished {
                if (currentTime - conn.lastActive) > Self.inProgressStaleAfter {
                    staleConns.append(conn)
                }

            } else if isConnectionInactive(conn, currentTime: currentTime, numSockets: numSockets) {
                inactiveConns.append(conn)

            } else if let fileDownload = fileDownloadMsgs[conn], let token = fileDownload.token {
                events.emitMainThread(.fileDownloadProgress, FileDownloadProgress(
                    username: (conn as? PeerConnection)?.targetUser ?? "", token: token,
                    bytesLeft: fileDownload.leftBytes, speed: fileDownload.speed
                ))
                fileDownload.speed = 0

            } else if let fileUpload = fileUploadMsgs[conn], let token = fileUpload.token {
                events.emitMainThread(.fileUploadProgress, FileUploadProgress(
                    username: (conn as? PeerConnection)?.targetUser ?? "", token: token,
                    offset: fileUpload.offset, bytesSent: fileUpload.sentBytes, speed: fileUpload.speed
                ))
                fileUpload.speed = 0
            }
        }

        for conn in inactiveConns {
            closeConnection(conn)
        }

        for conn in staleConns {
            connectError(SocketError.timedOut, conn: conn)
            closeConnection(conn)
        }

        for (addr, initMessage) in pendingPeerConns {
            initPeerConnection(addr: addr, initMessage: initMessage)
        }
    }

    // MARK: Server Connection

    private func setServerTimer(useFixedTimeout: Bool = false) {
        if useFixedTimeout {
            serverTimeoutValue = 5

        } else if serverTimeoutValue == -1 {
            // Add jitter to spread out connection attempts from clients in case server goes down
            serverTimeoutValue = Int.random(in: 5...15)

        } else if serverTimeoutValue > 0 && serverTimeoutValue < 300 {
            // Exponential backoff, max 5 minute wait
            serverTimeoutValue *= 2
        }

        serverTimeoutTime = monotonicTime() + Double(serverTimeoutValue)
        log.add(String(localized: "Reconnecting to server in \(serverTimeoutValue) seconds", bundle: .module))
    }

    /// Ensures we are disconnected from the server in case of connectivity
    /// issues, by sending TCP keepalive pings.
    ///
    /// Assuming default values are used, once we reach 10 seconds of idle time,
    /// we start sending keepalive pings once every 2 seconds. If 10 failed pings
    /// have been sent in a row (20 seconds), the connection is presumed dead.
    private static func setServerSocketKeepalive(_ fileDescriptor: Int32, idle: Int32 = 10, interval: Int32 = 2) {
        let count: Int32 = 10

        POSIXSocket.setOption(fileDescriptor, SOL_SOCKET, SO_KEEPALIVE, 1)
        POSIXSocket.setOption(fileDescriptor, IPPROTO_TCP, TCP_KEEPINTVL, interval)
        POSIXSocket.setOption(fileDescriptor, IPPROTO_TCP, TCP_KEEPCNT, count)
        POSIXSocket.setOption(fileDescriptor, IPPROTO_TCP, TCP_KEEPALIVE, idle)
    }

    /// We're connecting to the server.
    private func serverConnect(_ message: ServerConnect) {
        guard serverConn == nil else {
            return
        }

        interfaceName = message.interfaceName
        interfaceAddress = message.interfaceAddress ?? NetworkInterfaces.interfaceAddress(interfaceName)
        listenPort = message.listenPort

        guard createListenSocket() else {
            shouldProcessQueue = false
            events.emitMainThread(.setConnectionStats, ConnectionStats())  // Reset connection stats
            return
        }

        portmapper = message.portmapper

        manualServerDisconnect = false
        manualServerReconnect = false
        serverTimeoutTime = nil

        let address = message.addr ?? ServerAddress(host: "", port: 0)
        log.add(String(localized: "Connecting to \(address.host):\(String(address.port))", bundle: .module))

        initServerConn(message)
    }

    private func initServerConn(_ message: ServerConnect) {
        guard let sock = makeSocket(), let serverAddress = message.addr else {
            return
        }

        let ioEvents: IOEvents = [.read, .write]
        var ipAddress = serverAddress.host
        var addr = PeerAddress(ipAddress, serverAddress.port)

        POSIXSocket.setOption(sock.fileDescriptor, IPPROTO_TCP, TCP_NODELAY, 1)

        // Detect if our connection to the server is still alive
        Self.setServerSocketKeepalive(sock.fileDescriptor)

        do {
            ipAddress = try POSIXSocket.resolve(serverAddress.host)
            addr = PeerAddress(ipAddress, serverAddress.port)
            _ = bindSocketInterface(sock)

            let result = POSIXSocket.connect(sock.fileDescriptor, ipAddress: ipAddress, port: serverAddress.port)

            if result != 0 && result != EINPROGRESS {
                throw SocketError(result)
            }

        } catch {
            let conn = ServerConnection(sock: sock, addr: addr, ioEvents: ioEvents, login: message.login)
            connectError(error, conn: conn)
            closeSocket(sock)
            serverDisconnect()
            return
        }

        let conn = ServerConnection(sock: sock, addr: PeerAddress(serverAddress.host, serverAddress.port),
                                    ioEvents: ioEvents, login: message.login)
        serverConn = conn
        conns[sock] = conn
        selector?.register(sock.fileDescriptor, ioEvents)
        numSockets += 1
    }

    private func establishOutgoingServerConnection(_ conn: ServerConnection) {
        conn.isEstablished = true
        let address = conn.addr

        log.add(String(localized: "Connected to server \(address.ipAddress):\(String(address.port)), logging in…",
                       bundle: .module))

        guard let login = conn.login, let listenPort else {
            return
        }

        userAddresses[login.username] = PeerAddress(localIPAddress, listenPort)
        conn.login = nil

        serverAddress = conn.addr
        serverUsername = login.username
        branchRoot = login.username
        serverTimeoutValue = -1

        sendMessageToServer(Login(
            username: login.username, password: login.password,
            // Soulseek client version
            // NS and SoulseekQt use 157
            // Version number sent by Nicotine+, which other clients recognize
            version: 160,
            // Soulseek client minor version
            // 17 stands for 157 ns 13c, 19 for 157 ns 13e
            // SoulseekQt seems to go higher than this
            // Minor version sent by Nicotine+, which other clients recognize
            minorVersion: 2
        ))

        sendMessageToServer(SetWaitPort(port: listenPort))
    }

    private func processServerMessage(code: Int, size: Int, content: Data) -> Bool {
        guard let messageClass = MessageCodes.server.messageClass(for: code),
              var message = unpackNetworkMessage(messageClass, content: content, size: size, connType: "server") else {
            // Ignore unknown message and keep connection open
            return true
        }

        switch message {
        case let embedded as EmbeddedMessage:
            distributeEmbeddedMessage(embedded)

            guard let unpacked = unpackEmbeddedMessage(code: embedded.distribCode,
                                                       content: embedded.distribMessage) else {
                return true
            }
            message = unpacked

        case let login as Login:
            guard login.success else {
                // Emit event and close connection
                emitNetworkMessageEvent(login)
                return false
            }

            if let serverUsername, let localAddress = userAddresses[serverUsername] ?? nil {
                // Ensure listening port is open
                login.localAddress = localAddress
                portmapper?.setPort(localAddress.port, localIPAddress: localAddress.ipAddress)
                portmapper?.addPortMapping(blocking: true)
            }

            login.username = serverUsername ?? ""
            login.serverAddress = serverAddress.map { ServerAddress(host: $0.ipAddress, port: $0.port) }

            // Ask for a list of parents to connect to (distributed network)
            sendHaveNoParent()

        case let connectToPeer as ConnectToPeer:
            let username = connectToPeer.user
            let addr = PeerAddress(connectToPeer.ipAddress, connectToPeer.port)
            let connType = connectToPeer.connType
            let token = connectToPeer.token
            let initMessage = PeerInit(initUser: username, targetUser: username, connType: connType)

            log.addConn("Received indirect connection request of type \(connType) from user \(username), "
                        + "token \(token), address \(addr)")

            self.connectToPeer(username, addr: addr, initMessage: initMessage, responseToken: token)

        case let cantConnect as CantConnectToPeer:
            let token = cantConnect.token

            if let request = tokenInitMsgs.removeValue(forKey: token) {
                indirectRequestError(token: token, initMessage: request.initMessage)
            }

        case let userStatus as GetUserStatus:
            if userStatus.status == UserStatus.offline.rawValue, userAddresses[userStatus.user] != nil {
                // User went offline, reset stored IP address
                userAddresses[userStatus.user] = .some(nil)
            }

        case let peerAddress as GetPeerAddress:
            let username = peerAddress.user
            let pendingInits = pendingInitMsgs.removeValue(forKey: username) ?? []

            if peerAddress.port == 0 {
                log.addConn("Server reported port 0 for user \(username)")
            }

            var addr: PeerAddress? = PeerAddress(peerAddress.ipAddress, peerAddress.port)
            let userOffline = (peerAddress.ipAddress == "0.0.0.0")

            for initMessage in pendingInits {
                // We now have the IP address for a user we previously didn't know,
                // attempt a connection with the peer/user
                if userOffline {
                    events.emitMainThread(.peerConnectionError, PeerConnectionEvent(
                        username: username, connType: initMessage.connType, msgs: initMessage.outgoingMessages,
                        isOffline: true
                    ))
                } else if let addr {
                    self.connectToPeer(username, addr: addr, initMessage: initMessage)
                }
            }

            // We already store a local IP address for our username
            if username != serverUsername, userAddresses[username] != nil {
                if userOffline || peerAddress.port == 0 {
                    addr = nil
                }

                userAddresses[username] = .some(addr)
            }

        case let watchUser as WatchUser:
            if watchUser.user == serverUsername {
                if let avgSpeed = watchUser.avgSpeed {
                    updateOwnUploadSpeed(avgSpeed)
                }

            } else if !watchUser.userExists {
                userAddresses.removeValue(forKey: watchUser.user)
            }

        case let userStats as GetUserStats:
            if userStats.user == serverUsername {
                updateOwnUploadSpeed(userStats.avgSpeed)
            }

        case is Relogged:
            manualServerDisconnect = true
            serverRelogged = true

        case let possibleParents as PossibleParents:
            // Server sent a list of 10 potential parents, whose purpose is to forward us search requests.
            // We attempt to connect to them all at once, since connection errors are fairly common.

            potentialParents = possibleParents.parents
            log.addConn("Server sent us a list of \(possibleParents.parents.count) possible parents")

            if parentConn == nil {
                for username in possibleParents.usernames {
                    guard let addr = possibleParents.parents[username] else {
                        continue
                    }

                    log.addConn("Attempting parent connection to user \(username)")
                    initiateConnectionToPeer(username, connType: ConnectionType.distributed.rawValue,
                                             inAddress: addr)
                }
            }

        case let parentMinSpeed as ParentMinSpeed:
            distribParentMinSpeed = parentMinSpeed.speed
            log.addConn("Received minimum distributed parent speed \(parentMinSpeed.speed) from the server")
            updateMaximumDistributedChildren()

        case let parentSpeedRatio as ParentSpeedRatio:
            distribParentSpeedRatio = parentSpeedRatio.ratio
            log.addConn("Received distributed parent speed ratio \(parentSpeedRatio.ratio) from the server")
            updateMaximumDistributedChildren()

        case is ResetDistributed:
            log.addConn("Received a reset request for distributed network")

            if let parentConn {
                closeConnection(parentConn)
            }

            for childConn in Array(childPeers.values) {
                closeConnection(childConn)
            }

            sendHaveNoParent()

        default:
            break
        }

        emitNetworkMessageEvent(message)
        return true
    }

    private func updateOwnUploadSpeed(_ speed: Int) {
        uploadSpeed = speed
        log.addConn("Server reported our upload speed as \(humanSpeed(speed))")
        updateMaximumDistributedChildren()
    }

    /// Reads messages from the input buffer of a server connection.
    private func processServerInput(_ conn: Connection) {
        var bufferLength = conn.inBuffer.count
        let messageContentOffset = 8
        var index = 0

        // Server messages are 8 bytes or greater in length
        while bufferLength >= messageContentOffset {
            let messageSize = conn.inBuffer.uint32(at: index)
            let messageCode = conn.inBuffer.uint32(at: index + 4)

            if messageSize > Self.maxIncomingMessageSize {
                log.addConn("Received message larger than maximum size \(Self.maxIncomingMessageSize) from server. "
                            + "Closing connection.")
                manualServerDisconnect = true
                closeConnection(conn)
                return
            }

            let messageSizeTotal = messageSize + 4

            if messageSizeTotal > bufferLength {
                // Buffer is being filled
                break
            }

            // Unpack server messages
            if MessageCodes.server.messageClass(for: messageCode) != nil {
                let content = conn.inBuffer.data((index + messageContentOffset)..<(index + messageSizeTotal))

                if !processServerMessage(code: messageCode, size: messageSize, content: content) {
                    manualServerDisconnect = true
                    closeConnection(conn)
                    return
                }
            } else {
                let content = conn.inBuffer.data((index + messageContentOffset)..<(index + Swift.min(50, messageSizeTotal)))
                log.addDebug("Server message type \(messageCode) size \(messageSize) contents \(content as NSData) unknown")
            }

            index += messageSizeTotal
            bufferLength -= messageSizeTotal
        }

        if index > 0, conn.sock != nil {
            conn.inBuffer.removeFirst(index)
        }
    }

    private func processServerOutput(_ message: SlskMessage) {
        guard let content = packNetworkMessage(message), let conn = serverConn,
              let code = MessageCodes.server.code(for: message) else {
            return
        }

        if let watchUser = message as? WatchUser, userAddresses[watchUser.user] == nil {
            // Only cache IP address of watched users, otherwise we won't know if
            // a user reconnects and changes their IP address.
            userAddresses[watchUser.user] = .some(nil)

        } else if let unwatchUser = message as? UnwatchUser, unwatchUser.user != serverUsername {
            userAddresses.removeValue(forKey: unwatchUser.user)
        }

        var header = Data()
        header.appendUInt32(content.count + 4)
        header.appendUInt32(code)

        conn.outBuffer += header
        conn.outBuffer += content

        modifyConnectionEvents(conn, [.read, .write])
    }

    /// We're disconnecting from the server, clean up.
    private func serverDisconnect() {
        serverConn = nil
        shouldProcessQueue = false
        interfaceName = nil
        interfaceAddress = nil
        localIPAddress = ""

        closeListenSocket()

        if let portmapper {
            portmapper.removePortMapping(blocking: true)
            portmapper.setPort(nil, localIPAddress: nil)
            self.portmapper = nil
        }

        parentConn = nil
        potentialParents.removeAll()
        branchLevel = 0
        branchRoot = nil
        isServerParent = false
        distribParentMinSpeed = 0
        distribParentSpeedRatio = 1
        maxDistribChildren = 0
        uploadSpeed = 0
        userAddresses.removeAll()

        checkIndirectRequestTimeouts(expireAll: true)

        for conn in Array(conns.values) {
            closeConnection(conn)
        }

        queueLock.withLock { messageQueue.removeAll() }
        pendingPeerConns.removeAll()
        pendingInitMsgs.removeAll()
        usernameInitMsgs.removeAll()

        // Reset connection stats
        events.emitMainThread(.setConnectionStats, ConnectionStats())

        guard let address = serverAddress else {
            // We didn't successfully establish a connection to the server
            return
        }

        log.add(String(localized: "Disconnected from server \(address.ipAddress):\(String(address.port))", bundle: .module))

        if serverRelogged {
            log.add(String(localized: "Someone logged in to your Soulseek account elsewhere", bundle: .module))
            serverRelogged = false
        }

        if !manualServerDisconnect {
            setServerTimer(useFixedTimeout: manualServerReconnect)
        }

        serverAddress = nil
        serverUsername = nil

        events.emitMainThread(.serverDisconnect, ServerDisconnect(manualDisconnect: manualServerDisconnect))
    }

    private func sendMessageToServer(_ message: SlskMessage) {
        processOutgoingMessages([message])
    }

    // MARK: Peer Init

    private func processPeerInitMessage(_ conn: PeerConnection, code: Int, size: Int, content: Data) -> PeerInit? {
        guard let messageClass = MessageCodes.peerInit.messageClass(for: code),
              let message = unpackNetworkMessage(messageClass, content: content, size: size, connType: "peer init",
                                                 sock: conn.sock) else {
            return nil
        }

        var initMessage: PeerInit?

        if let pierceFireWall = message as? PierceFireWall {
            let token = pierceFireWall.token
            log.addConn("Received indirect connection response (PierceFireWall) with token \(token), address \(conn.addr)")
            log.addConn("Number of stored peer init message tokens: \(tokenInitMsgs.count)")

            guard let request = tokenInitMsgs.removeValue(forKey: token) else {
                log.addConn("Indirect connection attempt with token \(token) previously expired, closing connection")
                return nil
            }

            let storedInit = request.initMessage
            let previousSock = storedInit.sock
            let isDirectConnInProgress = previousSock.map { conns[$0]?.isEstablished == false } ?? false

            log.addConn("Indirect connection to user \(storedInit.targetUser) with token \(token) established")

            if previousSock == nil || isDirectConnInProgress {
                storedInit.sock = conn.sock
                log.addConn("Using as primary connection, since no direct connection is established")
            } else {
                // We already have a direct connection, but some clients may send a message over
                // the indirect connection. Keep it open.
                log.addConn("Direct connection was already established, keeping it as primary connection")
            }

            if isDirectConnInProgress, let previousSock {
                log.addConn("Stopping direct connection attempt to user \(storedInit.targetUser)")
                closeConnection(conns[previousSock])
            }

            initMessage = storedInit

        } else if let peerInit = message as? PeerInit {
            let username = peerInit.targetUser
            let connType = peerInit.connType

            log.addConn("Received incoming direct connection of type \(connType) from user "
                        + "\(username), address \(conn.addr)")

            guard Self.allowedPeerConnTypes.contains(connType) else {
                log.addConn("Unknown connection type \(connType)")
                return nil
            }

            initMessage = peerInit
            replaceExistingConnection(peerInit)
        }

        emitNetworkMessageEvent(message)
        return initMessage
    }

    /// Reads peer init messages from the input buffer of a peer connection.
    private func processPeerInitInput(_ conn: PeerConnection) -> PeerInit? {
        var initMessage: PeerInit?
        var bufferLength = conn.inBuffer.count
        let messageContentOffset = 5
        var index = 0

        // Peer init messages are 5 bytes or greater in length
        while bufferLength >= messageContentOffset && initMessage == nil {
            let messageSize = conn.inBuffer.uint32(at: index)

            if messageSize > Self.maxIncomingMessageSize {
                log.addConn("Received message larger than maximum size \(Self.maxIncomingMessageSize) from peer "
                            + "\(conn.addr). Closing connection.")
                break
            }

            let messageSizeTotal = messageSize + 4

            if messageSizeTotal > bufferLength {
                // Buffer is being filled
                conn.hasPostInitActivity = true
                break
            }

            // Unpack peer init messages
            let messageCode = Int(conn.inBuffer[index + 4])

            if MessageCodes.peerInit.messageClass(for: messageCode) != nil {
                let content = conn.inBuffer.data((index + messageContentOffset)..<(index + messageSizeTotal))
                initMessage = processPeerInitMessage(conn, code: messageCode, size: messageSize, content: content)
            } else {
                let content = conn.inBuffer.data((index + messageContentOffset)..<(index + Swift.min(50, messageSizeTotal)))
                log.addDebug("Peer init message type \(messageCode) size \(messageSize) contents \(content as NSData) unknown")
            }

            if initMessage == nil {
                break
            }

            index += messageSizeTotal
            bufferLength -= messageSizeTotal
        }

        guard let initMessage else {
            closeConnection(conn)
            return nil
        }

        if index > 0 {
            conn.inBuffer.removeFirst(index)
        }

        conn.initMessage = initMessage

        addInitMessage(initMessage)
        processConnMessages(initMessage)
        acceptChildPeerConnection(conn)
        return initMessage
    }

    private func processPeerInitOutput(_ message: SlskMessage) {
        guard let sock = (message as? SocketMessage)?.sock, let conn = conns[sock],
              let content = packNetworkMessage(message), let code = MessageCodes.peerInit.code(for: message) else {
            return
        }

        var header = Data()
        header.appendUInt32(content.count + 1)
        header.appendUInt8(code)

        conn.outBuffer += header
        conn.outBuffer += content

        modifyConnectionEvents(conn, [.read, .write])
    }

    // MARK: Peer Connection

    private func acceptIncomingPeerConnections() {
        guard let listenSocket else {
            return
        }

        while numSockets < Self.maxSockets {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)

            let fileDescriptor = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenSocket.fileDescriptor, $0, &length)
                }
            }

            if fileDescriptor < 0 {
                let error = SocketError()

                if error.code == EWOULDBLOCK || error.code == EAGAIN {
                    // No more incoming connections
                    break
                }

                log.addConn("Incoming connection failed: \(error)")
                continue
            }

            POSIXSocket.setOption(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, 1)
            POSIXSocket.setNonBlocking(fileDescriptor)
            POSIXSocket.setOption(fileDescriptor, IPPROTO_TCP, TCP_NODELAY, 1)

            let sock = Socket(fileDescriptor: fileDescriptor)
            let incomingAddr = POSIXSocket.describe(address)
            let ioEvents: IOEvents = .read

            socketsByDescriptor[fileDescriptor] = sock
            let conn = PeerConnection(sock: sock, addr: incomingAddr, ioEvents: ioEvents)
            conns[sock] = conn
            numSockets += 1

            // Event flags are modified to include 'write' in subsequent loops, if necessary.
            // Don't do it here, otherwise connections may break.
            selector?.register(fileDescriptor, ioEvents)
            conn.isEstablished = true

            log.addConn("Incoming connection from address \(incomingAddr)")
        }
    }

    private func initPeerConnection(addr: PeerAddress, initMessage: PeerInit, responseToken: Int? = nil) {
        if numSockets >= Self.maxSockets {
            // Connection limit reached, re-queue
            pendingPeerConns[addr] = initMessage
            return
        }

        var requestToken: Int?
        pendingPeerConns.removeValue(forKey: addr)

        if responseToken == nil {
            // No token provided, we're not responding to an indirect connection request.
            // Request indirect connection from our end in case the user's port is closed.
            requestToken = connectToPeerIndirect(initMessage)
        }

        guard addr.port > 0 && addr.port <= 65535 else {
            log.addConn("Skipping direct connection attempt of type \(initMessage.connType) to user "
                        + "\(initMessage.targetUser) due to invalid address \(addr)")
            return
        }

        guard let sock = makeSocket() else {
            return
        }

        let ioEvents: IOEvents = [.read, .write]
        let conn = PeerConnection(sock: sock, addr: addr, ioEvents: ioEvents, initMessage: initMessage,
                                  requestToken: requestToken, responseToken: responseToken)

        POSIXSocket.setOption(sock.fileDescriptor, IPPROTO_TCP, TCP_NODELAY, 1)
        _ = bindSocketInterface(sock)

        let result = POSIXSocket.connect(sock.fileDescriptor, ipAddress: addr.ipAddress, port: addr.port)

        if result != 0 && result != EINPROGRESS {
            connectError(SocketError(result), conn: conn)
            closeSocket(sock)
            return
        }

        initMessage.sock = sock
        conns[sock] = conn
        selector?.register(sock.fileDescriptor, ioEvents)
        numSockets += 1
    }

    /// Reads messages from the input buffer of a 'P' connection.
    private func processPeerInput(_ conn: PeerConnection) {
        var bufferLength = conn.inBuffer.count
        let messageContentOffset = 8
        var index = 0
        var searchResultReceived = false

        // Peer messages are 8 bytes or greater in length
        while bufferLength >= messageContentOffset {
            let messageSize = conn.inBuffer.uint32(at: index)
            let messageCode = conn.inBuffer.uint32(at: index + 4)

            if messageSize > Self.maxIncomingMessageSize {
                log.addConn("Received message larger than maximum size \(Self.maxIncomingMessageSize) from user "
                            + "\(conn.targetUser). Closing connection.")
                closeConnection(conn)
                return
            }

            let messageSizeTotal = messageSize + 4
            let messageClass = MessageCodes.peer.messageClass(for: messageCode)

            // Send progress to the main thread
            if messageClass == SharedFileListResponse.self, let sock = conn.sock {
                events.emitMainThread(.sharedFileListProgress, MessageProgress(
                    username: conn.targetUser, sock: sock, bufferLength: bufferLength, messageSizeTotal: messageSizeTotal
                ))

            } else if messageClass == UserInfoResponse.self, let sock = conn.sock {
                events.emitMainThread(.userInfoProgress, MessageProgress(
                    username: conn.targetUser, sock: sock, bufferLength: bufferLength, messageSizeTotal: messageSizeTotal
                ))
            }

            if messageSizeTotal > bufferLength {
                // Buffer is being filled
                break
            }

            // Unpack peer messages
            if let messageClass {
                let content = conn.inBuffer.data((index + messageContentOffset)..<(index + messageSizeTotal))
                let message = unpackNetworkMessage(messageClass, content: content, size: messageSize, connType: "peer",
                                                   sock: conn.sock, addr: conn.addr, username: conn.targetUser)

                if messageClass == FileSearchResponse.self {
                    searchResultReceived = true
                }

                emitNetworkMessageEvent(message)
            } else {
                let content = conn.inBuffer.data((index + messageContentOffset)..<(index + Swift.min(50, messageSizeTotal)))
                log.addDebug("Peer message type \(messageCode) size \(messageSize) contents \(content as NSData) unknown, "
                             + "from user: \(conn.targetUser), address \(conn.addr)")
            }

            index += messageSizeTotal
            bufferLength -= messageSizeTotal
        }

        if index > 0 {
            conn.inBuffer.removeFirst(index)
            conn.hasPostInitActivity = true
        }

        if searchResultReceived && !isConnectionStillActive(conn) {
            // Forcibly close peer connection. Only used after receiving a search result,
            // as we need to get rid of peer connections before they pile up.
            closeConnection(conn)
        }
    }

    private func processPeerOutput(_ message: SlskMessage) {
        guard let sock = (message as? SocketMessage)?.sock, let conn = conns[sock] as? PeerConnection,
              let content = packNetworkMessage(message), let code = MessageCodes.peer.code(for: message) else {
            return
        }

        var header = Data()
        header.appendUInt32(content.count + 4)
        header.appendUInt32(code)

        conn.outBuffer += header
        conn.outBuffer += content

        conn.hasPostInitActivity = true
        modifyConnectionEvents(conn, [.read, .write])
    }

    // MARK: File Connection

    private func calcUploadLimit() {
        var limit = uploadLimit
        let loopLimit = 1024  // 1 KB/s is the minimum upload speed per transfer

        if uploadLimitMode == .none || limit < loopLimit {
            uploadLimitSplit = 0
            return
        }

        if uploadLimitMode == .total && totalUploads > 1 {
            limit /= totalUploads
        }

        uploadLimitSplit = limit
    }

    private func calcDownloadLimit() {
        var limit = downloadLimit
        let loopLimit = 1024  // 1 KB/s is the minimum download speed per transfer

        if limit < loopLimit {
            // Download limit disabled
            downloadLimitSplit = 0
            return
        }

        if totalDownloads > 1 {
            limit /= totalDownloads
        }

        downloadLimitSplit = limit
    }

    private func processFileInitMessage(_ conn: PeerConnection) -> Int {
        let messageSize = 4
        let message = unpackNetworkMessage(FileTransferInit.self, content: conn.inBuffer.data(0..<Swift.min(messageSize, conn.inBuffer.count)),
                                           size: messageSize, connType: "file", sock: conn.sock,
                                           username: conn.targetUser) as? FileTransferInit

        if let message, message.token != nil {
            fileInitMsgs[conn] = message
            emitNetworkMessageEvent(message)
        }

        return messageSize
    }

    private func processFileOffsetMessage(_ conn: PeerConnection) -> Int? {
        guard let fileUpload = fileUploadMsgs[conn] else {
            return 0
        }

        if fileUpload.offset != nil {
            // No more incoming messages on this connection after receiving the
            // file offset. If peer sends something anyway, clear it.
            return conn.inBuffer.count
        }

        let messageSize = 8
        let message = unpackNetworkMessage(FileOffset.self, content: conn.inBuffer.data(0..<Swift.min(messageSize, conn.inBuffer.count)),
                                           size: messageSize, connType: "file", sock: conn.sock,
                                           username: conn.targetUser) as? FileOffset

        guard let offset = message?.offset else {
            return messageSize
        }

        fileUpload.offset = offset

        if let token = fileUpload.token {
            events.emitMainThread(.fileUploadProgress, FileUploadProgress(
                username: conn.targetUser, token: token, offset: offset, bytesSent: fileUpload.sentBytes
            ))
        }

        do {
            guard offset >= 0 else {
                throw FileOffsetError(offset: offset)
            }

            try fileUpload.file?.seek(toOffset: UInt64(offset))
            modifyConnectionEvents(conn, [.read, .write])

        } catch {
            events.emitMainThread(.uploadFileError, FileErrorEvent(
                username: conn.targetUser, token: fileUpload.token ?? 0, error: error
            ))
            closeConnection(conn)
            return nil
        }

        return messageSize
    }

    private func writeDownloadFile(_ fileDownload: DownloadFile, _ data: ArraySlice<UInt8>) throws {
        guard !data.isEmpty else {
            return
        }

        fileDownload.speed += data.count
        totalDownloadBandwidth += data.count

        try fileDownload.file?.write(contentsOf: data)
        fileDownload.leftBytes -= data.count
    }

    private func processDownload(_ conn: PeerConnection, _ data: ArraySlice<UInt8>) -> Bool {
        guard let fileDownload = fileDownloadMsgs[conn] else {
            return true
        }

        let leftBytes = fileDownload.leftBytes

        do {
            if data.count > leftBytes {
                try writeDownloadFile(fileDownload, data.prefix(Swift.max(leftBytes, 0)))
            } else {
                try writeDownloadFile(fileDownload, data)
            }

        } catch {
            events.emitMainThread(.downloadFileError, FileErrorEvent(
                username: conn.targetUser, token: fileDownload.token ?? 0, error: error
            ))
            return false  // Close the connection
        }

        // Download finished
        if fileDownload.leftBytes <= 0 {
            events.emitMainThread(.fileDownloadProgress, FileDownloadProgress(
                username: conn.targetUser, token: fileDownload.token ?? 0, bytesLeft: fileDownload.leftBytes
            ))
            return false  // Close the connection
        }

        return true
    }

    private func processUpload(_ conn: Connection, numSentBytes: Int, currentTime: Double) -> Bool {
        guard let fileUpload = fileUploadMsgs[conn], let offset = fileUpload.offset else {
            return true
        }

        let username = (conn as? PeerConnection)?.targetUser ?? ""
        let outBufferLength = conn.outBuffer.count
        fileUpload.sentBytes += numSentBytes
        let totalReadBytes = offset + fileUpload.sentBytes + outBufferLength
        let size = fileUpload.size

        do {
            if totalReadBytes < size {
                let numBytesToRead = Int(
                    (Swift.max(4096, Double(numSentBytes) * 1.25) / Swift.max(1, currentTime - conn.lastActive))
                    - Double(outBufferLength)
                )

                if numBytesToRead > 0, let data = try fileUpload.file?.read(upToCount: numBytesToRead) {
                    conn.outBuffer += data
                    modifyConnectionEvents(conn, [.read, .write])
                }
            }

        } catch {
            events.emitMainThread(.uploadFileError, FileErrorEvent(
                username: username, token: fileUpload.token ?? 0, error: error
            ))
            return false  // Close the connection
        }

        fileUpload.speed += numSentBytes
        totalUploadBandwidth += numSentBytes

        // Upload finished
        if offset + fileUpload.sentBytes == size {
            events.emitMainThread(.fileUploadProgress, FileUploadProgress(
                username: username, token: fileUpload.token ?? 0, offset: offset, bytesSent: fileUpload.sentBytes
            ))
        }

        return true
    }

    /// Reads file messages from the input buffer of a 'F' connection.
    private func processFileInput(_ conn: PeerConnection) {
        var index: Int? = 0

        if fileInitMsgs[conn] == nil {
            guard conn.inBuffer.count >= 4 else {
                return
            }
            index = processFileInitMessage(conn)

        } else if fileUploadMsgs[conn] != nil {
            if fileUploadMsgs[conn]?.offset == nil && conn.inBuffer.count < 8 {
                return
            }
            index = processFileOffsetMessage(conn)
        }

        if let index, index > 0, conn.sock != nil {
            conn.inBuffer.removeFirst(Swift.min(index, conn.inBuffer.count))
            conn.hasPostInitActivity = true
        }
    }

    private func processFileOutput(_ message: SlskMessage) {
        guard let sock = (message as? SocketMessage)?.sock, let conn = conns[sock] as? PeerConnection,
              let content = packNetworkMessage(message) else {
            return
        }

        if let fileTransferInit = message as? FileTransferInit {
            fileInitMsgs[conn] = fileTransferInit
            conn.outBuffer += content
            emitNetworkMessageEvent(fileTransferInit)

        } else if message is FileOffset {
            conn.outBuffer += content
        }

        conn.hasPostInitActivity = true
        modifyConnectionEvents(conn, [.read, .write])
    }

    // MARK: Distributed Connection

    private func acceptChildPeerConnection(_ conn: PeerConnection) {
        guard let initMessage = conn.initMessage, initMessage.connType == ConnectionType.distributed.rawValue else {
            return
        }

        let username = initMessage.targetUser

        if username == serverUsername {
            // We can't connect to ourselves
            return
        }

        if potentialParents[username] != nil {
            // This is not a child peer, ignore
            return
        }

        if parentConn == nil && !isServerParent {
            // We have no parent user and the server hasn't sent search requests, no point
            // in accepting child peers
            log.addConn("Rejecting distributed child peer connection from user \(username), since we have no parent")
            closeConnection(conn)
            return
        }

        if childPeers[username] != nil {
            log.addConn("Rejecting distributed child peer connection from user \(username), since an existing "
                        + "connection already exists")
            closeConnection(conn)
            return
        }

        if childPeers.count >= maxDistribChildren {
            log.addConn("Rejecting distributed child peer connection from user \(username), since child peer limit "
                        + "of \(maxDistribChildren) was reached")
            closeConnection(conn)
            return
        }

        childPeers[username] = conn
        sendMessageToPeer(username, DistribBranchLevel(level: branchLevel))

        if parentConn != nil, let branchRoot {
            // Only sent when we're not the branch root
            sendMessageToPeer(username, DistribBranchRoot(rootUsername: branchRoot))
        }

        log.addConn("Adopting user \(username) as distributed child peer. Number of current child peers: "
                    + "\(childPeers.count)")

        if childPeers.count >= maxDistribChildren {
            log.addConn("Maximum number of distributed child peers reached (\(maxDistribChildren)), "
                        + "no longer accepting new connections")
            sendMessageToServer(AcceptChildren(enabled: false))
        }
    }

    private func removeChildPeerConnection(_ username: String) {
        childPeers.removeValue(forKey: username)

        guard shouldProcessQueue else {
            return
        }

        if childPeers.count == maxDistribChildren - 1 {
            log.addConn("Available to accept a new distributed child peer")
            sendMessageToServer(AcceptChildren(enabled: true))
        }

        log.addConn("Number of current child peers: \(childPeers.count)")
    }

    private func sendMessageToChildPeers(_ message: DistribMessage) {
        var messages: [SlskMessage] = []

        for conn in childPeers.values {
            let childMessage = message.copyForChildPeer()
            childMessage.sock = conn.sock
            messages.append(childMessage)
        }

        processOutgoingMessages(messages)
    }

    /// Distributes an embedded message from the server to our child peers.
    private func distributeEmbeddedMessage(_ message: EmbeddedMessage) {
        if parentConn != nil {
            // The server shouldn't send embedded messages while it's not our parent, but let's be safe
            return
        }

        sendMessageToChildPeers(DistribEmbeddedMessage(distribCode: message.distribCode,
                                                       distribMessage: message.distribMessage))

        if isServerParent {
            return
        }

        isServerParent = true

        if childPeers.count < maxDistribChildren {
            sendMessageToServer(AcceptChildren(enabled: true))
        }

        log.addConn("Server is our parent, ready to distribute search requests as a branch root")
    }

    /// Verifies that a connection is our current parent connection.
    private func verifyParentConnection(_ conn: PeerConnection, messageClass: SlskMessage.Type) -> Bool {
        guard conn === parentConn else {
            log.addConn("Received a distributed message \(messageClass) from user \(conn.targetUser), who is not "
                        + "our parent. Closing connection.")
            return false
        }

        return true
    }

    /// Informs the server we have no parent.
    ///
    /// The server should either send us a PossibleParents message, or start
    /// sending us search requests.
    private func sendHaveNoParent() {
        guard shouldProcessQueue else {
            return
        }

        // Note that we don't clear the previous list of possible parents here, since
        // it's possible the parent connection was closed immediately or superseded by
        // an indirect connection
        parentConn = nil
        branchLevel = 0
        branchRoot = serverUsername

        log.addConn("We have no parent, requesting a new one")

        sendMessageToServer(HaveNoParent(noParent: true))
        sendMessageToServer(BranchRoot(user: branchRoot ?? ""))
        sendMessageToServer(BranchLevel(value: branchLevel))
        sendMessageToServer(AcceptChildren(enabled: false))
    }

    /// Informs the server and child peers of our branch root.
    private func setBranchRoot(_ username: String) {
        guard !username.isEmpty, username != branchRoot else {
            return
        }

        branchRoot = username
        sendMessageToServer(BranchRoot(user: username))
        sendMessageToChildPeers(DistribBranchRoot(rootUsername: username))

        log.addConn("Our branch root is user \(username)")
    }

    private func updateMaximumDistributedChildren() {
        let previousMaxDistribChildren = maxDistribChildren
        let numChildPeers = childPeers.count

        if uploadSpeed >= distribParentMinSpeed && distribParentSpeedRatio > 0 {
            // Limit maximum distributed child peers to 10 for now due to socket limit concerns
            maxDistribChildren = Swift.min(uploadSpeed / distribParentSpeedRatio / 100, 10)
        } else {
            // Server does not allow us to accept distributed child peers
            maxDistribChildren = 0
        }

        log.addConn("Distributed child peer limit updated, maximum connections: \(maxDistribChildren)")

        if maxDistribChildren <= numChildPeers && numChildPeers < previousMaxDistribChildren {
            log.addConn("Our current number of distributed child peers (\(numChildPeers)) reached the new limit, "
                        + "no longer accepting new connections")
            sendMessageToServer(AcceptChildren(enabled: false))
        }
    }

    private func processDistribMessage(_ conn: PeerConnection, code: Int, size: Int, content: Data) -> Bool {
        guard let messageClass = MessageCodes.distributed.messageClass(for: code),
              var message = unpackNetworkMessage(messageClass, content: content, size: size, connType: "distrib",
                                                 sock: conn.sock, username: conn.targetUser) else {
            // Ignore unknown message and keep connection open
            return true
        }

        switch message {
        case let search as DistribSearch:
            guard verifyParentConnection(conn, messageClass: messageClass) else {
                return false
            }

            sendMessageToChildPeers(search)

        case let embedded as DistribEmbeddedMessage:
            guard verifyParentConnection(conn, messageClass: messageClass) else {
                return false
            }

            guard let unpacked = unpackEmbeddedMessage(code: embedded.distribCode,
                                                       content: embedded.distribMessage) else {
                return true
            }

            if let unpacked = unpacked as? DistribMessage {
                sendMessageToChildPeers(unpacked)
            }
            message = unpacked

        case let branchLevelMessage as DistribBranchLevel:
            let username = branchLevelMessage.username ?? ""

            if branchLevelMessage.level < 0 {
                // There are rare cases of parents sending a branch level value of -1,
                // presumably buggy clients
                log.addConn("Received an invalid branch level value \(branchLevelMessage.level) from user "
                            + "\(username). Closing connection.")
                return false
            }

            if parentConn == nil, potentialParents[username] != nil {
                // We have a successful connection with a potential parent. Tell the server who
                // our parent is, and stop requesting new potential parents.
                parentConn = conn
                branchLevel = branchLevelMessage.level + 1
                isServerParent = false

                sendMessageToServer(HaveNoParent(noParent: false))
                sendMessageToServer(BranchLevel(value: branchLevel))

                if childPeers.count < maxDistribChildren {
                    sendMessageToServer(AcceptChildren(enabled: true))
                }

                sendMessageToChildPeers(DistribBranchLevel(level: branchLevel))
                childPeers.removeValue(forKey: username)

                log.addConn("Adopting user \(username) as parent")
                log.addConn("Our branch level is \(branchLevel)")

                if branchLevel == 1 {
                    // Our current branch level is 1, our parent is a branch root
                    setBranchRoot(username)
                }

            } else if !verifyParentConnection(conn, messageClass: messageClass) {
                return false

            } else {
                // Inform the server and child peers of our new branch level
                branchLevel = branchLevelMessage.level + 1
                sendMessageToServer(BranchLevel(value: branchLevel))
                sendMessageToChildPeers(DistribBranchLevel(level: branchLevel))

                log.addConn("Received a branch level update from our parent. Our new branch level is \(branchLevel)")
            }

        case let branchRootMessage as DistribBranchRoot:
            guard verifyParentConnection(conn, messageClass: messageClass) else {
                return false
            }

            setBranchRoot(branchRootMessage.rootUsername)

        default:
            break
        }

        emitNetworkMessageEvent(message)
        return true
    }

    /// Reads messages from the input buffer of a 'D' connection.
    private func processDistribInput(_ conn: PeerConnection) {
        var bufferLength = conn.inBuffer.count
        let messageContentOffset = 5
        var index = 0

        // Distributed messages are 5 bytes or greater in length
        while bufferLength >= messageContentOffset {
            let messageSize = conn.inBuffer.uint32(at: index)

            if messageSize > Self.maxIncomingMessageSize {
                log.addConn("Received message larger than maximum size \(Self.maxIncomingMessageSize) from user "
                            + "\(conn.targetUser). Closing connection.")
                closeConnection(conn)
                return
            }

            let messageSizeTotal = messageSize + 4

            if messageSizeTotal > bufferLength {
                // Buffer is being filled
                conn.hasPostInitActivity = true
                break
            }

            // Unpack distributed messages
            let messageCode = Int(conn.inBuffer[index + 4])

            if MessageCodes.distributed.messageClass(for: messageCode) != nil {
                let content = conn.inBuffer.data((index + messageContentOffset)..<(index + messageSizeTotal))

                if !processDistribMessage(conn, code: messageCode, size: messageSize, content: content) {
                    closeConnection(conn)
                    return
                }
            } else {
                let content = conn.inBuffer.data((index + messageContentOffset)..<(index + Swift.min(50, messageSizeTotal)))
                log.addDebug("Distrib message type \(messageCode) size \(messageSize) contents \(content as NSData) unknown")
            }

            index += messageSizeTotal
            bufferLength -= messageSizeTotal
        }

        if index > 0, conn.sock != nil {
            conn.inBuffer.removeFirst(index)
            conn.hasPostInitActivity = true
        }
    }

    private func processDistribOutput(_ message: SlskMessage) {
        guard let sock = (message as? SocketMessage)?.sock, let conn = conns[sock] as? PeerConnection,
              let content = packNetworkMessage(message), let code = MessageCodes.distributed.code(for: message) else {
            return
        }

        var header = Data()
        header.appendUInt32(content.count + 1)
        header.appendUInt8(code)

        conn.outBuffer += header
        conn.outBuffer += content

        conn.hasPostInitActivity = true
        modifyConnectionEvents(conn, [.read, .write])
    }

    // MARK: Internal Messages

    private func processInternalMessage(_ message: SlskMessage) {
        switch message {
        case let closeConnection as CloseConnection:
            if let sock = closeConnection.sock {
                self.closeConnection(conns[sock])
            }

        case let serverConnect as ServerConnect:
            self.serverConnect(serverConnect)

        case is ServerDisconnect:
            manualServerDisconnect = true
            closeConnection(serverConn)

        case is ServerReconnect:
            manualServerReconnect = true
            closeConnection(serverConn)

        case let downloadFile as DownloadFile:
            if let sock = downloadFile.sock, let conn = conns[sock] {
                fileDownloadMsgs[conn] = downloadFile

                totalDownloads += 1
                calcDownloadLimit()
                processConnIncomingMessages(conn)
            }

        case let uploadFile as UploadFile:
            if let sock = uploadFile.sock, let conn = conns[sock] {
                fileUploadMsgs[conn] = uploadFile

                totalUploads += 1
                calcUploadLimit()
                processConnIncomingMessages(conn)
            }

        case let setDownloadLimit as SetDownloadLimit:
            downloadLimit = setDownloadLimit.limit * 1024
            calcDownloadLimit()

        case let setUploadLimit as SetUploadLimit:
            if setUploadLimit.limit > 0 {
                uploadLimitMode = setUploadLimit.limitBy ? .total : .perTransfer
            } else {
                uploadLimitMode = .none
            }

            uploadLimit = setUploadLimit.limit * 1024
            calcUploadLimit()

        case let emitEvents as EmitNetworkMessageEvents:
            for networkMessage in emitEvents.msgs {
                emitNetworkMessageEvent(networkMessage)
            }

        default:
            break
        }
    }

    // MARK: Input/Output

    private func processReadyInputSocket(_ sock: Socket, currentTime: Double) {
        guard let conn = conns[sock] else {
            // Unknown connection
            return
        }

        if downloadLimitSplit > 0, let downloaded = connsDownloaded[conn], downloaded >= downloadLimitSplit {
            return
        }

        var connError: Error?

        do {
            if try readData(conn, currentTime: currentTime) {
                processConnIncomingMessages(conn)
                return
            }

        } catch {
            log.addConn("Cannot read data from connection \(conn.addr), closing connection. Error: \(error)")
            connError = error
        }

        if !conn.isEstablished {
            // No error when connection shuts down gracefully (recv() returns 0 bytes),
            // but we need to display one anyway
            connectError(connError ?? SocketError.notConnected, conn: conn)
        }

        closeConnection(conn)
    }

    private func processReadyOutputSocket(_ sock: Socket, currentTime: Double) {
        guard let conn = conns[sock] else {
            // Unknown connection
            return
        }

        if !conn.isEstablished {
            if let serverConn = conn as? ServerConnection, serverConn === self.serverConn {
                establishOutgoingServerConnection(serverConn)
            } else if let peerConn = conn as? PeerConnection {
                establishOutgoingPeerConnection(peerConn)
            }

            if conns[sock] == nil {
                // Connection was closed while being established
                return
            }
        }

        if uploadLimitSplit > 0, let uploaded = connsUploaded[conn], uploaded >= uploadLimitSplit {
            return
        }

        do {
            if try writeData(conn, currentTime: currentTime) {
                return
            }
        } catch {
            log.addConn("Cannot write data to connection \(conn.addr), closing connection. Error: \(error)")
        }

        closeConnection(conn)
    }

    private func processReadySockets(currentTime: Double) {
        guard let selector, let listenSocket else {
            return
        }

        for (fileDescriptor, ioEvents) in selector.select(timeout: Self.sleepMaxIdle) {
            guard let sock = socketsByDescriptor[fileDescriptor] else {
                continue
            }

            if ioEvents.contains(.read) {
                if sock == listenSocket {
                    acceptIncomingPeerConnections()
                    continue
                }

                processReadyInputSocket(sock, currentTime: currentTime)
            }

            if ioEvents.contains(.write) {
                processReadyOutputSocket(sock, currentTime: currentTime)
            }
        }
    }

    private func processConnIncomingMessages(_ conn: Connection) {
        guard !conn.inBuffer.isEmpty else {
            return
        }

        if conn === serverConn {
            processServerInput(conn)
            return
        }

        guard let conn = conn as? PeerConnection else {
            return
        }

        var initMessage = conn.initMessage

        if initMessage == nil {
            initMessage = processPeerInitInput(conn)
            conn.initMessage = initMessage

            guard initMessage != nil, !conn.inBuffer.isEmpty else {
                return
            }
        }

        guard let initMessage else {
            return
        }

        switch initMessage.connType {
        case ConnectionType.peer.rawValue:
            processPeerInput(conn)

        case ConnectionType.file.rawValue:
            processFileInput(conn)

        case ConnectionType.distributed.rawValue:
            processDistribInput(conn)

        default:
            break
        }

        if let sock = conn.sock, initMessage.sock != sock {
            log.addConn("Received message on secondary connection of type \(initMessage.connType) to user "
                        + "\(initMessage.targetUser), promoting to primary connection")
            initMessage.sock = sock
        }
    }

    private func processOutgoingMessages(_ messages: [SlskMessage]) {
        for message in messages {
            guard shouldProcessQueue else {
                return
            }

            let sock: Socket?
            let process: (SlskMessage) -> Void

            switch message.messageType {
            case .initialization:
                process = processPeerInitOutput
                sock = (message as? SocketMessage)?.sock

            case .internal:
                process = processInternalMessage
                sock = nil

            case .peer, .file:
                let peerMessage = message as? PeerConnectionMessage
                if message.messageType == .peer {
                    process = processPeerOutput
                } else {
                    process = processFileOutput
                }
                sock = peerMessage?.sock

                if sock == nil {
                    sendMessageToPeer(peerMessage?.username ?? "", message)
                    continue
                }

            case .distributed:
                process = processDistribOutput
                sock = (message as? SocketMessage)?.sock

            case .server:
                process = processServerOutput
                sock = serverConn?.sock
            }

            log.addMessageContents(message, isOutgoing: true)

            if message.messageType == .server, serverConn == nil {
                log.addConn("Cannot send the message over the closed connection: \(type(of: message)) \(message)")
                continue
            }

            if let sock, conns[sock] == nil {
                log.addConn("Cannot send the message over the closed connection: \(type(of: message)) \(message)")
                continue
            }

            process(message)
        }
    }

    private func processQueueMessages() {
        let messages = queueLock.withLock {
            let messages = messageQueue
            messageQueue.removeAll()
            return messages
        }

        guard !messages.isEmpty else {
            return
        }

        processOutgoingMessages(messages)
    }

    private func readData(_ conn: Connection, currentTime: Double) throws -> Bool {
        guard let sock = conn.sock else {
            return false
        }

        var currentRecvSize = conn.recvSize
        let isFileDownload = fileDownloadMsgs[conn] != nil
        let useDownloadLimit = downloadLimitSplit > 0 && isFileDownload

        if useDownloadLimit {
            let limit = downloadLimitSplit - (connsDownloaded[conn] ?? 0)

            if currentRecvSize > limit {
                currentRecvSize = limit
            }
        }

        var receiveError: SocketError?
        let buffer = [UInt8](unsafeUninitializedCapacity: Swift.max(currentRecvSize, 1)) { buffer, count in
            let result = recv(sock.fileDescriptor, buffer.baseAddress, currentRecvSize, 0)

            if result < 0 {
                receiveError = SocketError()
                count = 0
            } else {
                count = result
            }
        }

        if let receiveError {
            if receiveError.code == EAGAIN || receiveError.code == EWOULDBLOCK {
                // No data available yet
                return true
            }
            throw receiveError
        }

        let dataLength = buffer.count

        guard dataLength > 0 else {
            return false  // Close the connection
        }

        let data = buffer[0..<dataLength]

        // An intermediate buffer is useless when downloading a file. Write to the
        // file immediately, and let the OS handle buffering when necessary.
        if !isFileDownload {
            conn.inBuffer += data

        } else if let peerConn = conn as? PeerConnection, !processDownload(peerConn, data) {
            return false  // Close the connection
        }

        if useDownloadLimit {
            connsDownloaded[conn, default: 0] += dataLength

        // Grow or shrink recv buffer depending on how much data we're receiving
        } else if dataLength >= currentRecvSize / 2 {
            conn.recvSize *= 2

        } else if dataLength <= currentRecvSize / 6 {
            conn.recvSize /= 2
        }

        conn.lastActive = currentTime
        return true
    }

    private func writeData(_ conn: Connection, currentTime: Double) throws -> Bool {
        guard let sock = conn.sock else {
            return false
        }

        let isFileUpload = fileUploadMsgs[conn] != nil
        var length = conn.outBuffer.count

        if isFileUpload && uploadLimitSplit > 0 {
            let limit = uploadLimitSplit - (connsUploaded[conn] ?? 0)
            length = Swift.min(length, limit)
        }

        var numBytesSent = 0

        if length > 0 {
            let result = conn.outBuffer.withUnsafeBytes { buffer in
                send(sock.fileDescriptor, buffer.baseAddress, length, 0)
            }

            if result < 0 {
                let error = SocketError()

                guard error.code == EAGAIN || error.code == EWOULDBLOCK else {
                    throw error
                }
            } else {
                numBytesSent = result
            }
        }

        if isFileUpload && uploadLimitSplit > 0 {
            connsUploaded[conn, default: 0] += numBytesSent
        }

        conn.outBuffer.removeFirst(numBytesSent)

        if isFileUpload && !processUpload(conn, numSentBytes: numBytesSent, currentTime: currentTime) {
            return false  // Close the connection
        }

        if conn.outBuffer.isEmpty {
            // Nothing else to send, stop watching connection for writes
            modifyConnectionEvents(conn, .read)
        }

        conn.lastActive = currentTime
        return true
    }

    // MARK: Networking Loop

    private func loop() {
        while !wantAbort {
            let currentTime = monotonicTime()

            if currentTime - lastCycleTime >= 1 {
                checkConnections(currentTime: currentTime)
                checkIndirectRequestTimeouts(currentTime: currentTime)

                events.emitMainThread(.setConnectionStats, ConnectionStats(
                    totalConnections: numSockets,
                    downloadBandwidth: totalDownloadBandwidth,
                    uploadBandwidth: totalUploadBandwidth
                ))

                connsDownloaded.removeAll()
                connsUploaded.removeAll()

                totalDownloadBandwidth = 0
                totalUploadBandwidth = 0

                lastCycleTime = currentTime
            }

            if !shouldProcessQueue {
                if let serverTimeoutTime, serverTimeoutTime - currentTime <= 0 {
                    self.serverTimeoutTime = nil
                    events.emitMainThread(.serverReconnect, ServerReconnect(manualReconnect: manualServerReconnect))
                }

                Thread.sleep(forTimeInterval: Self.sleepMaxIdle + Self.sleepMinIdle)
                continue
            }

            // Process queue messages
            processQueueMessages()

            // Check which connections are ready to send/receive data
            processReadySockets(currentTime: currentTime)

            // Don't exhaust the CPU
            Thread.sleep(forTimeInterval: Self.sleepMinIdle)
        }
    }

    private func run() {
        events.emitMainThread(.setConnectionStats, ConnectionStats())

        // Watch sockets for I/O readiness. Only register sockets after they are bound.
        selector = Selector()

        loop()

        // Networking thread aborted
        manualServerDisconnect = true
        closeConnection(serverConn)
        selector?.close()
        selector = nil

        // We're ready to quit
        events.emitMainThread(.quit)
    }
}
