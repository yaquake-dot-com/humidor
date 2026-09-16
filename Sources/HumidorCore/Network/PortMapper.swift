// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

struct PortmapError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// Common state of port mapping implementations.
class PortMappingImplementation: @unchecked Sendable {
    class var name: String { "" }

    var port: Int?
    var localIPAddress: String?

    var name: String { Self.name }

    func setPort(_ port: Int?, localIPAddress: String?) {
        self.port = port
        self.localIPAddress = localIPAddress
    }

    func addPortMapping(leaseDuration: Int) throws {}
    func removePortMapping() throws {}
}

// MARK: - NAT-PMP

/// Implementation of the NAT-PMP protocol.
///
/// https://www.rfc-editor.org/rfc/rfc6886.
final class NATPMP: PortMappingImplementation, @unchecked Sendable {
    override class var name: String { "NAT-PMP" }

    static let requestPort = 5351
    static let requestAttempts = 2  // spec says 9, but 2 should be enough
    static let requestInitTimeout = 0.250  // seconds
    static let successResult = 0

    private static let reservedValue = 0
    private static let tcpOpCode = 2
    private static let version = 0

    private var gatewayAddress: String?

    private static func packRequest(publicPort: Int, privatePort: Int, leaseDuration: Int) -> Data {
        var data = Data()
        data.append(UInt8(version))
        data.append(UInt8(tcpOpCode))
        withUnsafeBytes(of: UInt16(reservedValue).bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(truncatingIfNeeded: privatePort).bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(truncatingIfNeeded: publicPort).bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: leaseDuration).bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// Returns the result code of a portmap response.
    private static func parseResponseResult(_ message: Data) throws -> Int {
        guard message.count >= 16 else {
            throw PortmapError("Invalid NAT-PMP response")
        }

        let bytes = [UInt8](message)
        return Int(UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
    }

    private static func getGatewayAddress() throws -> String {
        guard let output = try executeCommand("netstat -rn", returnOutput: true) else {
            throw PortmapError("Unable to read routing table")
        }

        let text = String(decoding: output, as: UTF8.self)
        let pattern = try NSRegularExpression(pattern: "(?:default|0\\.0\\.0\\.0|::/0)\\s+([\\w\\.:]+)\\s+.*UG")

        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            throw PortmapError("No default gateway found")
        }

        return String(text[range])
    }

    private func requestPortMapping(publicPort: Int, privatePort: Int, leaseDuration: Int) throws -> Int? {
        let fileDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fileDescriptor >= 0 else {
            throw SocketError()
        }
        defer { close(fileDescriptor) }

        let localIPAddress = localIPAddress ?? "0.0.0.0"
        log.addDebug("NAT-PMP: Binding socket to local IP address \(localIPAddress)")

        try POSIXSocket.bind(fileDescriptor, ipAddress: localIPAddress, port: 0)

        let request = Self.packRequest(publicPort: publicPort, privatePort: privatePort, leaseDuration: leaseDuration)
        let gatewayAddress = gatewayAddress ?? ""
        var timeout = Self.requestInitTimeout

        for attempt in 1...Self.requestAttempts {
            POSIXSocket.setReceiveTimeout(fileDescriptor, seconds: timeout)
            try POSIXSocket.sendTo(fileDescriptor, request, ipAddress: gatewayAddress, port: Self.requestPort)

            log.addDebug("NAT-PMP: Portmap request attempt \(attempt) of \(Self.requestAttempts) to gateway "
                         + "\(gatewayAddress), port \(Self.requestPort): \(request as NSData)")

            do {
                let response = try POSIXSocket.receive(fileDescriptor, maxLength: 16)
                return try Self.parseResponseResult(response)

            } catch let error as SocketError where error.code == ETIMEDOUT {
                timeout *= 2
            }
        }

        log.addDebug("NAT-PMP: Giving up, all \(Self.requestAttempts) portmap requests timed out")
        return nil
    }

    override func addPortMapping(leaseDuration: Int) throws {
        gatewayAddress = try Self.getGatewayAddress()

        let result = try requestPortMapping(publicPort: port ?? 0, privatePort: port ?? 0,
                                            leaseDuration: leaseDuration)

        if result != Self.successResult {
            throw PortmapError("NAT-PMP error code \(result.map(String.init) ?? "None")")
        }
    }

    override func removePortMapping() throws {
        let result = try requestPortMapping(publicPort: 0, privatePort: port ?? 0, leaseDuration: 0)
        gatewayAddress = nil

        if result != Self.successResult {
            throw PortmapError("NAT-PMP error code \(result.map(String.init) ?? "None")")
        }
    }
}

// MARK: - UPnP

/// Implementation of the UPnP protocol.
final class UPnP: PortMappingImplementation, @unchecked Sendable {
    override class var name: String { "UPnP" }

    static let userAgent = "Swift UPnP/2.0 \(Application.name)/\(Application.version)"
    static let multicastHost = "239.255.255.250"
    static let multicastPort = 1900
    static let multicastTTL: UInt8 = 2  // Should default to 2 according to UPnP specification
    static let mxResponseDelay = 1      // At least 1 second is sufficient according to UPnP specification
    static let httpRequestTimeout: TimeInterval = 5

    private static let deviceNamespace = "urn:schemas-upnp-org:device-1-0"
    private static let controlNamespace = "urn:schemas-upnp-org:control-1-0"
    private static let envelopeNamespace = "http://schemas.xmlsoap.org/soap/envelope/"

    private static let wanIPConnection2 = "urn:schemas-upnp-org:service:WANIPConnection:2"
    private static let wanIPConnection1 = "urn:schemas-upnp-org:service:WANIPConnection:1"
    private static let wanPPPConnection1 = "urn:schemas-upnp-org:service:WANPPPConnection:1"

    struct Service {
        let serviceType: String
        let controlURL: String
    }

    private var service: Service?

    // MARK: SSDP

    /// Builds a Simple Service Discovery Protocol (SSDP) request.
    private static func makeSSDPRequest(searchTarget: String) -> Data {
        let headers = [
            ("HOST", "\(multicastHost):\(multicastPort)"),
            ("ST", searchTarget),
            ("MAN", "\"ssdp:discover\""),
            ("MX", String(mxResponseDelay)),
            ("USER-AGENT", userAgent)
        ]

        let lines = ["M-SEARCH * HTTP/1.1"] + headers.map { "\($0): \($1)" }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// Parses the headers of a Simple Service Discovery Protocol (SSDP) response.
    private static func parseSSDPHeaders(_ message: String) -> [String: String] {
        var headers: [String: String] = [:]

        for line in message.components(separatedBy: .newlines).dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }

            let name = line[..<separator].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)

            if headers[name] == nil {
                headers[name] = value
            }
        }

        return headers
    }

    private static func httpRequest(_ url: URL, body: Data? = nil, headers: [String: String] = [:]) throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: httpRequestTimeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body

        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var responseData: Data?
        nonisolated(unsafe) var responseError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            // HTTP errors may still contain a useful response body
            responseData = data
            responseError = error
            semaphore.signal()
        }

        task.resume()
        semaphore.wait()

        if let responseError {
            throw responseError
        }

        return responseData ?? Data()
    }

    private static func getServiceControlURL(_ locationURL: String) -> Service? {
        do {
            guard let url = URL(string: locationURL) else {
                throw PortmapError("Invalid URL")
            }

            let responseBody = try httpRequest(url)
            log.addDebug("UPnP: Device description response from \(locationURL): "
                         + String(decoding: responseBody, as: UTF8.self))

            let xml = try XMLTreeElement.parse(responseBody)

            for service in xml.findAll(namespace: deviceNamespace, name: "service") {
                guard let foundServiceType = service.find(namespace: deviceNamespace, name: "serviceType")?.text,
                      [wanIPConnection2, wanIPConnection1, wanPPPConnection1].contains(foundServiceType) else {
                    continue
                }

                // We found a router with UPnP enabled
                let locationURLBase = "\(url.scheme ?? "http")://\(url.host ?? "")"
                    + (url.port.map { ":\($0)" } ?? "") + "/"
                var controlURL = service.find(namespace: deviceNamespace, name: "controlURL")?.text ?? ""

                if controlURL.hasPrefix("/") {
                    // Relative URL
                    controlURL = locationURLBase + controlURL.drop(while: { $0 == "/" })

                } else if !controlURL.hasPrefix(locationURLBase) {
                    // Absolute URL (allowed in UPnP 1.0)
                    log.addDebug("UPnP: Invalid control URL \(controlURL) for service \(foundServiceType), ignoring")
                    continue
                }

                return Service(serviceType: foundServiceType, controlURL: controlURL)
            }

        } catch {
            // Invalid response
            log.addDebug("UPnP: Invalid device description response from \(locationURL): \(error)")
        }

        return nil
    }

    private static func addService(_ services: inout [String: Service], _ locations: inout Set<String>,
                                   _ response: String) {
        let responseHeaders = parseSSDPHeaders(response)
        log.addDebug("UPnP: Device search response: \(response)")

        guard let location = responseHeaders["LOCATION"] else {
            log.addDebug("UPnP: M-SEARCH response did not contain a LOCATION header: \(responseHeaders)")
            return
        }

        guard !locations.contains(location) else {
            log.addDebug("UPnP: Device location was previously processed, ignoring")
            return
        }

        locations.insert(location)

        guard let service = getServiceControlURL(location) else {
            log.addDebug("UPnP: No router with UPnP enabled in device search response, ignoring")
            return
        }

        log.addDebug("UPnP: Device details: service_type '\(service.serviceType)'; "
                     + "control_url '\(service.controlURL)'")

        guard services[service.serviceType] == nil else {
            log.addDebug("UPnP: Service was previously added, ignoring")
            return
        }

        services[service.serviceType] = service
        log.addDebug("UPnP: Added service to list")
    }

    private static func getServices(privateIP: String) throws -> [String: Service] {
        log.addDebug("UPnP: Discovering... delay=\(mxResponseDelay) seconds")

        let fileDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fileDescriptor >= 0 else {
            throw SocketError()
        }
        defer { close(fileDescriptor) }

        log.addDebug("UPnP: Binding socket to local IP address \(privateIP)")

        var interfaceAddress = in_addr()
        inet_pton(AF_INET, privateIP, &interfaceAddress)
        setsockopt(fileDescriptor, IPPROTO_IP, IP_MULTICAST_IF, &interfaceAddress,
                   socklen_t(MemoryLayout<in_addr>.size))

        var ttl = multicastTTL
        setsockopt(fileDescriptor, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        POSIXSocket.setOption(fileDescriptor, SOL_SOCKET, SO_BROADCAST, 1)

        // Larger timeout in case data arrives at the last moment
        POSIXSocket.setReceiveTimeout(fileDescriptor, seconds: Double(mxResponseDelay) + 0.1)
        try POSIXSocket.bind(fileDescriptor, ipAddress: privateIP, port: 0)

        for searchTarget in [
            // Protocol 2
            "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
            wanIPConnection2,

            // Protocol 1
            "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
            wanIPConnection1,
            wanPPPConnection1
        ] {
            let request = makeSSDPRequest(searchTarget: searchTarget)
            try POSIXSocket.sendTo(fileDescriptor, request, ipAddress: multicastHost, port: multicastPort)
            log.addDebug("UPnP: SSDP request sent: \(String(decoding: request, as: UTF8.self))")
        }

        var locations = Set<String>()
        var services: [String: Service] = [:]

        while true {
            do {
                // Maximum size of UDP message
                let message = try POSIXSocket.receive(fileDescriptor, maxLength: 65507)
                addService(&services, &locations, String(decoding: message, as: UTF8.self))

            } catch let error as SocketError where error.code == ETIMEDOUT {
                break
            }
        }

        log.addDebug("UPnP: \(services.count) service(s) detected")
        return services
    }

    private static func findService(privateIP: String) throws -> Service? {
        let services = try getServices(privateIP: privateIP)

        return services[wanIPConnection2] ?? services[wanIPConnection1] ?? services[wanPPPConnection1]
    }

    // MARK: Port Mapping

    private static func soapEnvelope(_ body: String) -> Data {
        Data(("<?xml version=\"1.0\"?>\r\n"
              + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
              + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
              + "<s:Body>" + body + "</s:Body>"
              + "</s:Envelope>\r\n").utf8)
    }

    /// Adds a port mapping to the router. If a port mapping already exists, it
    /// is updated with a new lease period.
    private func requestPortMapping(service: Service, publicPort: Int, privateIP: String, privatePort: Int,
                                    mappingDescription: String, leaseDuration: Int) throws
        -> (errorCode: String?, errorDescription: String?) {
        let serviceType = service.serviceType
        let controlURL = service.controlURL

        log.addDebug("UPnP: Adding port mapping (\(privateIP) \(privatePort), \(serviceType)) at url '\(controlURL)'")

        guard let url = URL(string: controlURL) else {
            throw PortmapError("Invalid control URL \(controlURL)")
        }

        let headers = [
            "Host": url.host.map { host in url.port.map { "\(host):\($0)" } ?? host } ?? "",
            "Content-Type": "text/xml; charset=utf-8",
            "USER-AGENT": Self.userAgent,
            "SOAPACTION": "\"\(serviceType)#AddPortMapping\""
        ]

        let body = Self.soapEnvelope(
            "<u:AddPortMapping xmlns:u=\"\(serviceType)\">"
            + "<NewRemoteHost></NewRemoteHost>"
            + "<NewExternalPort>\(publicPort)</NewExternalPort>"
            + "<NewProtocol>TCP</NewProtocol>"
            + "<NewInternalPort>\(privatePort)</NewInternalPort>"
            + "<NewInternalClient>\(privateIP)</NewInternalClient>"
            + "<NewEnabled>1</NewEnabled>"
            + "<NewPortMappingDescription>\(mappingDescription)</NewPortMappingDescription>"
            + "<NewLeaseDuration>\(leaseDuration)</NewLeaseDuration>"
            + "</u:AddPortMapping>"
        )

        log.addDebug("UPnP: Add port mapping request headers: \(headers)")
        log.addDebug("UPnP: Add port mapping request contents: \(String(decoding: body, as: UTF8.self))")

        // HTTP errors may contain a UPnP error code, e.g. MikroTik routers that send
        // UPnP error 725 (OnlyPermanentLeasesSupported).
        let responseBody = try Self.httpRequest(url, body: body, headers: headers)
        let xml = try XMLTreeElement.parse(responseBody)

        guard xml.find(namespace: Self.envelopeNamespace, name: "Body") != nil else {
            throw PortmapError("Invalid response: \(String(decoding: responseBody, as: UTF8.self))")
        }

        log.addDebug("UPnP: Add port mapping response: \(String(decoding: responseBody, as: UTF8.self))")

        let errorCode = xml.find(namespace: Self.controlNamespace, name: "errorCode")?.text
        let errorDescription = xml.find(namespace: Self.controlNamespace, name: "errorDescription")?.text

        return (errorCode, errorDescription)
    }

    /// Creates a port mapping via the UPnP IGDv1 and IGDv2 protocol.
    ///
    /// Any UPnP port mapping done with IGDv2 will expire after a maximum of 7
    /// days (lease period), according to the protocol. We set the lease period
    /// to a shorter 12 hours, and regularly renew the port mapping.
    override func addPortMapping(leaseDuration: Int) throws {
        // Find router
        service = try Self.findService(privateIP: localIPAddress ?? "0.0.0.0")

        guard let service else {
            throw PortmapError(Self.noDevicesFoundMessage)
        }

        let port = port ?? 0
        let localIPAddress = localIPAddress ?? ""

        // Perform the port mapping
        log.addDebug("UPnP: Trying to redirect external WAN port \(port) TCP => \(localIPAddress) port \(port) TCP")

        let (errorCode, errorDescription) = try requestPortMapping(
            service: service, publicPort: port, privateIP: localIPAddress, privatePort: port,
            mappingDescription: "NicotinePlus", leaseDuration: leaseDuration
        )

        if errorCode == "725" && leaseDuration > 0 {
            log.addDebug("UPnP: Router requested permanent lease duration")
            try addPortMapping(leaseDuration: 0)
            return
        }

        if errorCode != nil || errorDescription != nil {
            throw PortmapError("Error code \(errorCode ?? "None"): \(errorDescription ?? "None")")
        }
    }

    static var noDevicesFoundMessage: String {
        String(localized: "No UPnP devices found", bundle: .module)
    }

    override func removePortMapping() throws {
        guard let service else {
            return
        }

        self.service = nil

        guard let url = URL(string: service.controlURL) else {
            return
        }

        let headers = [
            "Host": url.host.map { host in url.port.map { "\(host):\($0)" } ?? host } ?? "",
            "Content-Type": "text/xml; charset=utf-8",
            "SOAPACTION": "\"\(service.serviceType)#DeletePortMapping\""
        ]

        let body = Self.soapEnvelope(
            "<u:DeletePortMapping xmlns:u=\"\(service.serviceType)\">"
            + "<NewRemoteHost></NewRemoteHost>"
            + "<NewExternalPort>\(port ?? 0)</NewExternalPort>"
            + "<NewProtocol>TCP</NewProtocol>"
            + "</u:DeletePortMapping>"
        )

        log.addDebug("UPnP: Remove port mapping request headers: \(headers)")
        log.addDebug("UPnP: Remove port mapping request contents: \(String(decoding: body, as: UTF8.self))")

        let responseBody = try Self.httpRequest(url, body: body, headers: headers)
        log.addDebug("UPnP: Remove port mapping response: \(String(decoding: responseBody, as: UTF8.self))")
    }
}

// MARK: - Port Mapper

/// Handles port mapping. Port mappings are added and removed from the
/// networking thread, or from background threads.
public final class PortMapper: @unchecked Sendable {

    static let renewalInterval: TimeInterval = 7200  // 2 hours
    static let leaseDuration = 43200                 // 12 hours

    private let lock = NSLock()
    private let natpmp = NATPMP()
    private let upnp = UPnP()
    private var activeImplementation: PortMappingImplementation?
    private var hasPort = false
    private var isMappingPort = false
    private var isEnabled = true
    private var timerID: Int?

    public init() {}

    /// Enables or disables port mapping. Called when the preference changes.
    public func setEnabled(_ enabled: Bool) {
        lock.withLock { isEnabled = enabled }
    }

    private var enabled: Bool {
        lock.withLock { isEnabled }
    }

    private func waitUntilReady() {
        while lock.withLock({ isMappingPort }) {
            // Port mapping in progress, wait until it's finished
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func performAddPortMapping() {
        waitUntilReady()

        guard enabled else {
            return
        }

        lock.withLock { isMappingPort = true }
        log.addDebug("Creating Port Mapping rule...")

        var implementation: PortMappingImplementation = natpmp

        do {
            try natpmp.addPortMapping(leaseDuration: Self.leaseDuration)

        } catch let natpmpError {
            log.addDebug("NAT-PMP not available, falling back to UPnP: \(natpmpError.localizedDescription)")
            implementation = upnp

            do {
                try upnp.addPortMapping(leaseDuration: Self.leaseDuration)

            } catch let upnpError {
                let port = upnp.port.map(String.init) ?? "None"
                log.add(String(localized: "\(upnp.name): Failed to forward external port \(port): \(upnpError.localizedDescription)",
                               bundle: .module))

                lock.withLock {
                    activeImplementation = nil
                    isMappingPort = false
                }
                return
            }
        }

        let port = implementation.port.map(String.init) ?? "None"
        let localIPAddress = implementation.localIPAddress ?? "None"

        log.add(String(localized: "\(implementation.name): External port \(port) successfully forwarded to local IP address \(localIPAddress) port \(port)",
                       bundle: .module))

        lock.withLock {
            activeImplementation = implementation
            isMappingPort = false
        }
    }

    private func performRemovePortMapping() {
        waitUntilReady()

        guard let implementation = lock.withLock({ activeImplementation }) else {
            return
        }

        lock.withLock { isMappingPort = true }

        do {
            try implementation.removePortMapping()
        } catch {
            log.addDebug("\(implementation.name): Failed to remove port mapping: \(error.localizedDescription)")
        }

        lock.withLock {
            activeImplementation = nil
            isMappingPort = false
        }
    }

    private func startRenewalTimer() {
        events.invokeMainThread { [self] in
            events.cancelScheduled(lock.withLock { timerID })

            let newTimerID = events.schedule(delay: Self.renewalInterval) { [self] in
                addPortMapping()
            }
            lock.withLock { timerID = newTimerID }
        }
    }

    private func cancelRenewalTimer() {
        events.invokeMainThread { [self] in
            events.cancelScheduled(lock.withLock { timerID })
            lock.withLock { timerID = nil }
        }
    }

    public func setPort(_ port: Int?, localIPAddress: String?) {
        natpmp.setPort(port, localIPAddress: localIPAddress)
        upnp.setPort(port, localIPAddress: localIPAddress)

        lock.withLock { hasPort = (port != nil) }
    }

    public func addPortMapping(blocking: Bool = false) {
        // Check if we want to do a port mapping
        guard enabled, lock.withLock({ hasPort }) else {
            return
        }

        // Do the port mapping
        if blocking {
            performAddPortMapping()
        } else {
            let thread = Thread { [self] in performAddPortMapping() }
            thread.name = "AddPortmapping"
            thread.start()
        }

        // Renew port mapping entry regularly
        startRenewalTimer()
    }

    public func removePortMapping(blocking: Bool = false) {
        cancelRenewalTimer()

        if blocking {
            performRemovePortMapping()
            return
        }

        let thread = Thread { [self] in performRemovePortMapping() }
        thread.name = "RemovePortmapping"
        thread.start()
    }
}

// MARK: - XML

/// Minimal namespace-aware XML element tree.
final class XMLTreeElement {
    let namespace: String?
    let name: String
    var text = ""
    var children: [XMLTreeElement] = []

    init(namespace: String?, name: String) {
        self.namespace = namespace
        self.name = name
    }

    /// Finds the first descendant element with the given namespace and name.
    func find(namespace: String, name: String) -> XMLTreeElement? {
        for child in children {
            if child.namespace == namespace && child.name == name {
                return child
            }
            if let match = child.find(namespace: namespace, name: name) {
                return match
            }
        }
        return nil
    }

    /// Finds all descendant elements with the given namespace and name.
    func findAll(namespace: String, name: String) -> [XMLTreeElement] {
        var matches: [XMLTreeElement] = []

        for child in children {
            if child.namespace == namespace && child.name == name {
                matches.append(child)
            }
            matches += child.findAll(namespace: namespace, name: name)
        }
        return matches
    }

    static func parse(_ data: Data) throws -> XMLTreeElement {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = builder

        guard parser.parse(), let root = builder.root.children.first else {
            throw parser.parserError ?? PortmapError("Invalid XML document")
        }

        return root
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        let root = XMLTreeElement(namespace: nil, name: "")
        private lazy var stack: [XMLTreeElement] = [root]

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let element = XMLTreeElement(namespace: namespaceURI, name: elementName)
            stack.last?.children.append(element)
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if let element = stack.popLast() {
                element.text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }
}
