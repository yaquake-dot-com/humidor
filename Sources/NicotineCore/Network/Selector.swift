// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin

private typealias KernelEvent = Darwin.kevent

/// I/O readiness events.
struct IOEvents: OptionSet, Hashable {
    let rawValue: Int

    static let read = IOEvents(rawValue: 1 << 0)
    static let write = IOEvents(rawValue: 1 << 1)
}

/// Watches file descriptors for I/O readiness using kqueue.
final class Selector {
    private let queue: Int32
    private var registered: [Int32: IOEvents] = [:]
    private var eventBuffer: [KernelEvent]

    init() {
        queue = kqueue()
        eventBuffer = [KernelEvent](repeating: KernelEvent(), count: 256)
    }

    deinit {
        close()
    }

    func close() {
        registered.removeAll()
        Darwin.close(queue)
    }

    private func change(_ fileDescriptor: Int32, filter: Int32, flags: Int32) {
        var event = KernelEvent(ident: UInt(fileDescriptor), filter: Int16(filter), flags: UInt16(flags), fflags: 0,
                           data: 0, udata: nil)
        _ = kevent(queue, &event, 1, nil, 0, nil)
    }

    private func apply(_ fileDescriptor: Int32, from oldEvents: IOEvents, to newEvents: IOEvents) {
        if oldEvents.contains(.read) != newEvents.contains(.read) {
            change(fileDescriptor, filter: EVFILT_READ, flags: newEvents.contains(.read) ? EV_ADD : EV_DELETE)
        }

        if oldEvents.contains(.write) != newEvents.contains(.write) {
            change(fileDescriptor, filter: EVFILT_WRITE, flags: newEvents.contains(.write) ? EV_ADD : EV_DELETE)
        }
    }

    func register(_ fileDescriptor: Int32, _ events: IOEvents) {
        apply(fileDescriptor, from: [], to: events)
        registered[fileDescriptor] = events
    }

    func modify(_ fileDescriptor: Int32, _ events: IOEvents) {
        guard let oldEvents = registered[fileDescriptor] else {
            return
        }

        apply(fileDescriptor, from: oldEvents, to: events)
        registered[fileDescriptor] = events
    }

    func unregister(_ fileDescriptor: Int32) {
        guard let oldEvents = registered.removeValue(forKey: fileDescriptor) else {
            return
        }

        apply(fileDescriptor, from: oldEvents, to: [])
    }

    var isEmpty: Bool {
        registered.isEmpty
    }

    /// Waits until registered file descriptors are ready, or the timeout (in
    /// seconds) expires.
    func select(timeout: Double) -> [(fileDescriptor: Int32, events: IOEvents)] {
        var timeoutSpec = timespec(tv_sec: Int(timeout), tv_nsec: Int((timeout - Double(Int(timeout))) * 1e9))
        let maxEvents = Swift.max(registered.count * 2, 1)

        if eventBuffer.count < maxEvents {
            eventBuffer = [KernelEvent](repeating: KernelEvent(), count: maxEvents)
        }

        let count = kevent(queue, nil, 0, &eventBuffer, Int32(eventBuffer.count), &timeoutSpec)

        guard count > 0 else {
            return []
        }

        var order: [Int32] = []
        var ready: [Int32: IOEvents] = [:]

        for index in 0..<Int(count) {
            let event = eventBuffer[index]
            let fileDescriptor = Int32(event.ident)

            guard let registeredEvents = registered[fileDescriptor] else {
                continue
            }

            var events: IOEvents = []

            if event.filter == Int16(EVFILT_READ), registeredEvents.contains(.read) {
                events.insert(.read)
            }

            if event.filter == Int16(EVFILT_WRITE), registeredEvents.contains(.write) {
                events.insert(.write)
            }

            guard !events.isEmpty else {
                continue
            }

            if ready[fileDescriptor] == nil {
                order.append(fileDescriptor)
            }

            ready[fileDescriptor, default: []].formUnion(events)
        }

        return order.map { ($0, ready[$0]!) }
    }
}

/// Network interface addresses.
public enum NetworkInterfaces {

    /// Returns a dictionary of network interface names and IPv4 addresses.
    public static func interfaceAddresses() -> [String: String] {
        var addresses: [String: String] = [:]
        var interfaces: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&interfaces) == 0 else {
            log.addDebug("Failed to get list of network interfaces: \(SocketError())")
            return addresses
        }
        defer { freeifaddrs(interfaces) }

        var current = interfaces

        while let interface = current {
            defer { current = interface.pointee.ifa_next }

            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }

            let name = String(cString: interface.pointee.ifa_name)
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }

            if addresses[name] == nil {
                addresses[name] = POSIXSocket.describe(ipv4).ipAddress
            }
        }

        return addresses
    }

    /// Returns the IP address of a specific network interface.
    static func interfaceAddress(_ interfaceName: String?) -> String? {
        guard let interfaceName, !interfaceName.isEmpty else {
            return nil
        }
        return interfaceAddresses()[interfaceName]
    }

    /// Binds a socket to the IP address of a network interface.
    static func bindToInterface(_ fileDescriptor: Int32, address: String) throws {
        try POSIXSocket.bind(fileDescriptor, ipAddress: address, port: 0)
    }
}
