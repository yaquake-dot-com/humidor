// SPDX-License-Identifier: GPL-3.0-or-later
//
// Thin wrappers around BSD socket calls.

import Darwin
import Foundation

struct SocketError: Error, CustomStringConvertible {
    let code: Int32

    init(_ code: Int32 = errno) {
        self.code = code
    }

    static let notConnected = SocketError(ENOTCONN)
    static let timedOut = SocketError(ETIMEDOUT)
    static let wouldBlock = SocketError(EWOULDBLOCK)

    var description: String {
        "[Errno \(code)] \(String(cString: strerror(code)))"
    }
}

extension SocketError: LocalizedError {
    var errorDescription: String? { description }
}

enum POSIXSocket {

    static func makeAddress(_ ipAddress: String, port: Int) -> sockaddr_in? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)

        guard inet_pton(AF_INET, ipAddress, &address.sin_addr) == 1 else {
            return nil
        }

        return address
    }

    static func describe(_ address: sockaddr_in) -> PeerAddress {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))

        let ipAddress = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return PeerAddress(ipAddress, Int(UInt16(bigEndian: address.sin_port)))
    }

    /// Resolves a host name to an IPv4 address.
    static func resolve(_ host: String) throws -> String {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)

        guard status == 0, let info = result, let address = info.pointee.ai_addr else {
            throw ResolveError(host: host, message: String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(result) }

        let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        return describe(ipv4).ipAddress
    }

    struct ResolveError: LocalizedError {
        let host: String
        let message: String

        var errorDescription: String? { "\(host): \(message)" }
    }

    static func setOption(_ fileDescriptor: Int32, _ level: Int32, _ option: Int32, _ value: Int32) {
        var value = value
        setsockopt(fileDescriptor, level, option, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNonBlocking(_ fileDescriptor: Int32) {
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }

    static func setReceiveTimeout(_ fileDescriptor: Int32, seconds: Double) {
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func bind(_ fileDescriptor: Int32, ipAddress: String, port: Int) throws {
        guard var address = makeAddress(ipAddress, port: port) else {
            throw SocketError(EADDRNOTAVAIL)
        }

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result != 0 {
            throw SocketError()
        }
    }

    /// Starts a connection. Returns an error code, like connect_ex().
    static func connect(_ fileDescriptor: Int32, ipAddress: String, port: Int) -> Int32 {
        guard var address = makeAddress(ipAddress, port: port) else {
            return EADDRNOTAVAIL
        }

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0 ? 0 : errno
    }

    static func localAddress(_ fileDescriptor: Int32) -> PeerAddress? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fileDescriptor, $0, &length)
            }
        }

        return result == 0 ? describe(address) : nil
    }

    static func sendTo(_ fileDescriptor: Int32, _ data: Data, ipAddress: String, port: Int) throws {
        guard var address = makeAddress(ipAddress, port: port) else {
            throw SocketError(EADDRNOTAVAIL)
        }

        let sent = data.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fileDescriptor, buffer.baseAddress, buffer.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        if sent < 0 {
            throw SocketError()
        }
    }

    /// Receives data. Throws `SocketError.timedOut` if the receive timeout expires.
    static func receive(_ fileDescriptor: Int32, maxLength: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let count = recv(fileDescriptor, &buffer, maxLength, 0)

        if count < 0 {
            let code = errno
            throw (code == EAGAIN || code == EWOULDBLOCK) ? SocketError.timedOut : SocketError(code)
        }

        return Data(buffer.prefix(count))
    }

    /// Returns the "primary" local IP address, even if it's a NAT/private/internal IP.
    static func findLocalIPAddress() -> String {
        let fileDescriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard fileDescriptor >= 0 else {
            return "0.0.0.0"
        }
        defer { close(fileDescriptor) }

        // Connect to a local broadcast address (doesn't need to be reachable,
        // but macOS requires port to be non-zero)
        _ = connect(fileDescriptor, ipAddress: "10.255.255.255", port: 1)

        return localAddress(fileDescriptor)?.ipAddress ?? "0.0.0.0"
    }
}
