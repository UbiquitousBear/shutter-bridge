import Foundation
import Network

/// Day 6: does the camera advertise PTP/IP over Bonjour (`_ptp._tcp`, listed in NSBonjourServices)? Browses for a
/// few seconds, logs every result with its TXT record and interfaces, records the time to the first result, and
/// resolves each found service to an address by opening (and immediately closing) a TCP connection to it.
@MainActor
final class BonjourProbe {
    struct Found: Sendable {
        let name: String
        let endpoint: NWEndpoint
        let interfaces: [String]
        let txt: [String: String]
        /// Seconds from starting the browser to this result.
        let after: Double
    }

    private let log: SpikeLog
    private var found: [String: Found] = [:]
    private var firstResultAfter: Double?

    init(log: SpikeLog) {
        self.log = log
    }

    /// Browses `type` for `seconds`; records `measurement` (seconds to the first result) if anything is found.
    /// Returns the resolved "host:port" of each result, for "Use this IP".
    func browse(type: String = "_ptp._tcp", seconds: Double = 5, measurement: String) async -> [String] {
        found = [:]
        firstResultAfter = nil
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: params)
        let started = ContinuousClock.now
        let log = self.log
        browser.stateUpdateHandler = { state in
            let text: String?
            switch state {
            case .ready:
                text = "Bonjour browse \(type): ready"
            case .waiting(let error):
                text = "Bonjour browse \(type) waiting: \(error)\(Self.hint(error))"
            case .failed(let error):
                text = "Bonjour browse \(type) failed: \(error)\(Self.hint(error))"
            default:
                text = nil
            }
            if let text { Task { @MainActor in log.note(text) } }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let after = (ContinuousClock.now - started).inSeconds
            let items: [Found] = results.map { result in
                var txt: [String: String] = [:]
                if case .bonjour(let record) = result.metadata { txt = record.dictionary }
                return Found(name: NetFormat.endpoint(result.endpoint), endpoint: result.endpoint,
                             interfaces: result.interfaces.map(\.name), txt: txt, after: after)
            }
            Task { @MainActor in self?.update(items) }
        }
        browser.start(queue: DispatchQueue(label: "spike.bonjour"))
        log.note("Bonjour: browsing \(type) for \(Int(seconds)) s")
        try? await Task.sleep(for: .seconds(seconds))
        browser.cancel()

        guard let first = firstResultAfter else {
            log.note("Bonjour: no \(type) service within \(Int(seconds)) s (the camera may simply not advertise it; also check the Local Network permission)")
            return []
        }
        log.measure(measurement, first, "s", context: "\(found.count) \(type) service(s): \(found.keys.sorted().joined(separator: ", "))")
        var addresses: [String] = []
        for item in found.values.sorted(by: { $0.name < $1.name }).prefix(3) {
            if let address = await Self.resolve(item.endpoint, timeout: 5) {
                log.note("Bonjour: \(item.name) resolves to \(address)")
                addresses.append(address)
            } else {
                log.warn("Bonjour: could not resolve \(item.name) within 5 s")
            }
        }
        return addresses
    }

    private func update(_ items: [Found]) {
        for item in items where found[item.name] == nil {
            found[item.name] = item
            if firstResultAfter == nil { firstResultAfter = item.after }
            let txt = item.txt.isEmpty ? "none" : item.txt.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            log.note(String(format: "Bonjour: found %@ after %.2f s on [%@], TXT %@", item.name, item.after,
                            item.interfaces.joined(separator: ", "), txt))
        }
    }

    /// Opens a TCP connection to a service endpoint and reads the address it resolved to, then closes it.
    nonisolated static func resolve(_ endpoint: NWEndpoint, timeout: Double) async -> String? {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "spike.bonjour.resolve")
        let address: String? = try? await withCheckedThrowingContinuation { (c: CheckedContinuation<String?, Error>) in
            let once = OnceContinuation(c)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let remote = connection.currentPath?.remoteEndpoint.map(NetFormat.endpoint)
                    once.resume(returning: remote)
                case .failed, .cancelled:
                    once.resume(returning: nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.resume(returning: nil) }
        }
        connection.cancel()
        return address
    }

    nonisolated static func hint(_ error: NWError) -> String {
        if case .dns(let code) = error, code == -65570 {
            return " — policy denied: Local Network permission off, or the type is missing from NSBonjourServices"
        }
        return ""
    }
}
