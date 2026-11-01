import Foundation
import Network
import Observation

/// Days 6 and 9: SSDP discovery from the phone.
///
/// - Unicast M-SEARCH to the typed camera IP on UDP 1900 needs only the Local Network permission, not the
///   multicast entitlement. A connected UDP socket only sees replies sent from port 1900; a camera that answers
///   from another port looks like "no reply" here, so compare with the Mac's `tcpdump -i en0 udp port 1900`.
/// - Multicast M-SEARCH to 239.255.255.250:1900 uses NWConnectionGroup, which needs
///   com.apple.developer.networking.multicast. Without it the group fails with a policy error, which is itself the
///   result to record.
///
/// Every reply is logged (status line, ST, USN, SERVER, LOCATION) and the LOCATION description XML is fetched
/// once and summarised (friendlyName, modelName, whether there is a serialNumber but never its value, UDN, service
/// types). The description is saved as a fixture with the serial zeroed.
@Observable
@MainActor
final class SSDPProbe {
    private(set) var replies: [SSDPReply] = []
    private(set) var descriptions: [String: String] = [:]
    private(set) var isRunning = false
    @ObservationIgnored private let log: SpikeLog
    @ObservationIgnored private var group: NWConnectionGroup?
    @ObservationIgnored private var sentAt: ContinuousClock.Instant?
    @ObservationIgnored private var firstReplyAfter: Double?
    @ObservationIgnored private var fetchedLocations: Set<String> = []

    static let sonySearchTarget = "urn:schemas-sony-com:service:DigitalImaging:1"
    static let searchTargets = [sonySearchTarget, "ssdp:all"]

    init(log: SpikeLog) {
        self.log = log
    }

    // MARK: Unicast

    /// M-SEARCH sent straight to `host`:1900; listens `seconds` for replies. Records `measurement` (seconds from
    /// sending to the first reply) if anything answers.
    func searchUnicast(host: String, seconds: Double = 5, measurement: String) async {
        guard !isRunning else { log.warn("SSDP: a search is already running"); return }
        isRunning = true
        defer { isRunning = false }
        replies.removeAll()
        firstReplyAfter = nil

        let queue = DispatchQueue(label: "spike.ssdp.unicast")
        let conn = NWConnection(host: NWEndpoint.Host(host), port: 1900, using: .udp)
        defer { conn.cancel() }
        let log = self.log
        conn.stateUpdateHandler = { state in
            switch state {
            case .waiting(let error):
                Task { @MainActor in log.warn("SSDP unicast socket waiting: \(error)\(PTPIPChannel.hint(for: error, path: nil))") }
            case .failed(let error):
                Task { @MainActor in log.error("SSDP unicast socket failed: \(error)") }
            default:
                break
            }
        }
        conn.start(queue: queue)

        let clock = ContinuousClock()
        let started = clock.now
        sentAt = started
        for target in Self.searchTargets {
            let message = Self.mSearch(hostHeader: "\(host):1900", target: target, mx: 1)
            conn.send(content: message, completion: .contentProcessed { error in
                if let error { Task { @MainActor in log.error("SSDP unicast M-SEARCH send failed: \(error)") } }
            })
        }
        log.note("SSDP unicast M-SEARCH sent to \(host):1900 (ST \(Self.searchTargets.joined(separator: ", "))); listening \(Int(seconds)) s")

        let deadline = started + .seconds(seconds)
        receiving: while clock.now < deadline {
            let remaining = (deadline - clock.now).inSeconds
            // nil: the listening window ended.
            guard let datagram = await Self.receiveDatagram(conn, queue: queue, timeout: remaining) else { break }
            switch datagram {
            case .success(let data):
                received(data, from: host, at: clock.now)
            case .failure(let text):
                // e.g. ECONNREFUSED: the camera sent ICMP port-unreachable, nothing listens on UDP 1900.
                log.warn("SSDP unicast receive: \(text)")
                break receiving
            }
        }
        finish(method: "unicast to \(host)", seconds: seconds, measurement: measurement)
    }

    private enum Datagram: Sendable {
        case success(Data)
        case failure(String)
    }

    private nonisolated static func receiveDatagram(_ conn: NWConnection, queue: DispatchQueue, timeout: Double) async -> Datagram? {
        let result: Datagram?? = try? await withCheckedThrowingContinuation { (c: CheckedContinuation<Datagram?, Error>) in
            let once = OnceContinuation(c)
            conn.receiveMessage { data, _, _, error in
                if let data, !data.isEmpty {
                    once.resume(returning: .success(data))
                } else if let error {
                    once.resume(returning: .failure("\(error)"))
                } else {
                    once.resume(returning: .failure("empty datagram"))
                }
            }
            queue.asyncAfter(deadline: .now() + max(timeout, 0)) { once.resume(returning: nil) }
        }
        return result ?? nil
    }

    // MARK: Multicast

    /// M-SEARCH to the SSDP multicast group. Needs the multicast entitlement; logs the policy failure if absent.
    func searchMulticast(seconds: Double = 5, measurement: String) async {
        guard !isRunning else { log.warn("SSDP: a search is already running"); return }
        isRunning = true
        defer { isRunning = false }
        replies.removeAll()
        firstReplyAfter = nil
        sentAt = nil

        let multicast: NWMulticastGroup
        do {
            multicast = try NWMulticastGroup(for: [.hostPort(host: "239.255.255.250", port: 1900)])
        } catch {
            log.error("SSDP multicast: NWMulticastGroup could not be created: \(error)")
            return
        }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .wifi
        let g = NWConnectionGroup(with: multicast, using: params)
        group = g
        g.setReceiveHandler(maximumMessageSize: 65_535, rejectOversizedMessages: true) { [weak self] message, content, _ in
            let at = ContinuousClock.now
            let from = message.remoteEndpoint.map(NetFormat.endpoint) ?? "?"
            guard let content, !content.isEmpty else { return }
            Task { @MainActor in self?.received(content, from: from, at: at) }
        }
        g.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.groupStateChanged(state) }
        }
        g.start(queue: DispatchQueue(label: "spike.ssdp.multicast"))
        log.note("SSDP multicast group starting (needs com.apple.developer.networking.multicast); listening \(Int(seconds)) s")
        try? await Task.sleep(for: .seconds(seconds))
        g.cancel()
        group = nil
        finish(method: "multicast", seconds: seconds, measurement: measurement)
    }

    private func groupStateChanged(_ state: NWConnectionGroup.State) {
        switch state {
        case .ready:
            sendMulticastSearch()
        case .waiting(let error):
            log.warn("SSDP multicast group waiting: \(error) — a policy/permission error here means the multicast entitlement (or Local Network permission) is missing")
        case .failed(let error):
            log.error("SSDP multicast group failed: \(error) — expected until Apple grants com.apple.developer.networking.multicast and it is in Spike.entitlements; use the unicast search or a typed IP meanwhile")
        default:
            break
        }
    }

    private func sendMulticastSearch() {
        guard let g = group else { return }
        sentAt = ContinuousClock.now
        let log = self.log
        for target in Self.searchTargets {
            let message = Self.mSearch(hostHeader: "239.255.255.250:1900", target: target, mx: 2)
            g.send(content: message) { error in
                if let error { Task { @MainActor in log.error("SSDP multicast M-SEARCH send failed: \(error)") } }
            }
        }
        log.note("SSDP multicast group ready; M-SEARCH sent (ST \(Self.searchTargets.joined(separator: ", ")))")
    }

    // MARK: Replies

    private func received(_ data: Data, from: String, at: ContinuousClock.Instant) {
        guard let text = String(data: data, encoding: .utf8) else {
            log.note("SSDP: \(data.count)-byte non-UTF-8 datagram from \(from)")
            return
        }
        // Our own multicast M-SEARCH loops back to the group; other phones' searches arrive too.
        if text.hasPrefix("M-SEARCH") { return }
        guard let reply = SSDPReply.parse(text, from: from) else {
            log.note("SSDP: unparsable datagram from \(from) (\(data.count) bytes)")
            return
        }
        if firstReplyAfter == nil, let sentAt { firstReplyAfter = (at - sentAt).inSeconds }
        guard !replies.contains(where: { $0.dedupeKey == reply.dedupeKey }) else { return }
        replies.append(reply)
        log.note("SSDP from \(from): \(reply.headline)")
        if let location = reply.location, !fetchedLocations.contains(location) {
            fetchedLocations.insert(location)
            Task { await fetchDescription(location) }
        }
    }

    private func finish(method: String, seconds: Double, measurement: String) {
        if let first = firstReplyAfter {
            let froms = Set(replies.map(\.from)).sorted().joined(separator: ", ")
            log.measure(measurement, first, "s", context: "\(method); \(replies.count) distinct repl(ies) from \(froms)")
        } else {
            log.note("SSDP \(method): no reply within \(Int(seconds)) s (camera mode? Compare with the Mac's tcpdump of udp port 1900)")
        }
    }

    // MARK: Device description

    /// GET the LOCATION URL (5 s timeout) and log what the camera says it is. Plain-HTTP loads from an IP
    /// address need NSAppTransportSecurity › NSAllowsLocalNetworking in Info.plist on iOS 17+.
    func fetchDescription(_ location: String) async {
        guard let url = URL(string: location), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            log.warn("SSDP LOCATION is not an http(s) URL: \(location)")
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                log.warn("SSDP description \(location): HTTP \(status), \(data.count) bytes")
                return
            }
            // The description carries the camera's serial: the fixture and the log only ever see it zeroed.
            FixtureStore.saveSSDPDescription(data, log: log)
            guard let d = SSDPDeviceDescription.parse(data) else {
                let zeroed = FixtureStore.zeroingSSDPSerial(in: data)?.data ?? Data()
                var shown = String(decoding: zeroed.prefix(160), as: UTF8.self)
                // Belt and braces for malformed XML (a CDATA serial is not zeroed): show nothing from any serialNumber on.
                if let tag = shown.range(of: "serialNumber", options: .caseInsensitive) {
                    shown = String(shown[..<tag.lowerBound]) + "…"
                }
                log.warn("SSDP description \(location) did not parse as XML (\(data.count) bytes): \(shown)")
                return
            }
            descriptions[location] = d.shortSummary
            log.note("UPnP description \(location): \(d.summary)")
        } catch {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, ns.code == -1022 {
                // NSURLErrorAppTransportSecurityRequiresSecureConnection
                log.error("SSDP description blocked by App Transport Security: add NSAppTransportSecurity › NSAllowsLocalNetworking = YES to Info.plist (project.yml)")
            } else {
                log.warn("SSDP description \(location) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Message

    static func mSearch(hostHeader: String, target: String, mx: Int) -> Data {
        let text = "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: \(hostHeader)\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: \(mx)\r\n"
            + "ST: \(target)\r\n"
            + "USER-AGENT: iOS/27 UPnP/1.1 SBSpike/0.1\r\n"
            + "\r\n"
        return Data(text.utf8)
    }
}

/// One SSDP response or NOTIFY.
struct SSDPReply: Identifiable, Equatable, Sendable {
    let id = UUID()
    let from: String
    let statusLine: String
    /// Header names upper-cased.
    let headers: [String: String]

    var location: String? { headers["LOCATION"] }
    var searchTarget: String? { headers["ST"] ?? headers["NT"] }
    var usn: String? { headers["USN"] }
    var server: String? { headers["SERVER"] }

    /// The host part of LOCATION: what "Use this IP" puts in the camera IP field.
    var locationHost: String? {
        guard let location, let host = URLComponents(string: location)?.host, !host.isEmpty else { return nil }
        return host
    }

    var dedupeKey: String { "\(from)|\(usn ?? "")|\(searchTarget ?? "")" }

    var headline: String {
        [statusLine,
         "ST \(searchTarget ?? "-")",
         "USN \(usn ?? "-")",
         "SERVER \(server ?? "-")",
         "LOCATION \(location ?? "-")"].joined(separator: " | ")
    }

    static func parse(_ text: String, from: String) -> SSDPReply? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, !first.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }
        return SSDPReply(from: from, statusLine: first.trimmingCharacters(in: .whitespaces), headers: headers)
    }

    static func == (a: SSDPReply, b: SSDPReply) -> Bool { a.id == b.id }
}

/// The interesting parts of a UPnP device description.
struct SSDPDeviceDescription: Sendable {
    var deviceType = ""
    var friendlyName = ""
    var manufacturer = ""
    var modelName = ""
    var modelNumber = ""
    var serialNumber = ""
    /// Every serialNumber element's value, any case, in document order (the summary uses only the first, above): for
    /// FixtureStore's check that a zeroed description holds no serial.
    var allSerialNumbers: [String] = []
    var udn = ""
    var serviceTypes: [String] = []
    /// Vendor elements (X_…), e.g. Sony's X_ScalarWebAPI_* entries, as "name=value".
    var vendorFields: [String] = []

    var shortSummary: String { "\(friendlyName.isEmpty ? "?" : friendlyName) · \(modelName.isEmpty ? "?" : modelName)" }

    var summary: String {
        var parts = ["friendlyName \"\(friendlyName)\"", "manufacturer \"\(manufacturer)\"",
                     "modelName \"\(modelName)\" \(modelNumber)", "serialNumber \(serialNumber.isEmpty ? "absent" : "present (\(serialNumber.count) chars, redacted)")",
                     "UDN \(udn.isEmpty ? "-" : udn)", "deviceType \(deviceType)",
                     "services [\(serviceTypes.joined(separator: ", "))]"]
        if !vendorFields.isEmpty { parts.append("vendor [\(vendorFields.joined(separator: "; "))]") }
        return parts.joined(separator: " · ")
    }

    static func parse(_ data: Data) -> SSDPDeviceDescription? {
        let parser = XMLParser(data: data)
        let delegate = DeviceDescriptionParser()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.result
    }
}

/// Collects the first value of each standard field (the root device) and every serviceType.
private final class DeviceDescriptionParser: NSObject, XMLParserDelegate {
    var result = SSDPDeviceDescription()
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    /// A value wrapped in <![CDATA[…]]> arrives here, not in foundCharacters.
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if local.caseInsensitiveCompare("serialNumber") == .orderedSame { result.allSerialNumbers.append(value) }
        switch local {
        case "deviceType": if result.deviceType.isEmpty { result.deviceType = value }
        case "friendlyName": if result.friendlyName.isEmpty { result.friendlyName = value }
        case "manufacturer": if result.manufacturer.isEmpty { result.manufacturer = value }
        case "modelName": if result.modelName.isEmpty { result.modelName = value }
        case "modelNumber": if result.modelNumber.isEmpty { result.modelNumber = value }
        case "serialNumber": if result.serialNumber.isEmpty { result.serialNumber = value }
        case "UDN": if result.udn.isEmpty { result.udn = value }
        case "serviceType": if !value.isEmpty { result.serviceTypes.append(value) }
        default:
            if local.hasPrefix("X_"), !value.isEmpty, result.vendorFields.count < 20 {
                result.vendorFields.append("\(local)=\(value.prefix(120))")
            }
        }
    }
}
