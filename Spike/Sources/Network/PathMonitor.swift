import Foundation
import Network
import Observation

/// Days 6 and 8: what the phone's network path looks like while the Wi-Fi tab is visible. On the camera's
/// access point the phone usually keeps Wi-Fi (no internet) and moves internet traffic to cellular; the log
/// lines here and "Check internet" record exactly what happens, for the findings page.
@Observable
@MainActor
final class PathMonitor {
    private(set) var current: PathSnapshot?
    private(set) var isMonitoring = false
    private(set) var internet = "not checked"
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private let log: SpikeLog

    init(log: SpikeLog) {
        self.log = log
    }

    /// Starts logging every path change (status, interfaces, isExpensive, isConstrained, gateways).
    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let snapshot = PathSnapshot(path)
            Task { @MainActor in self?.update(snapshot) }
        }
        m.start(queue: DispatchQueue(label: "spike.path"))
        monitor = m
        isMonitoring = true
        log.note("network path monitor started")
    }

    func stop() {
        guard let m = monitor else { return }
        m.cancel()
        monitor = nil
        isMonitoring = false
        log.note("network path monitor stopped")
    }

    private func update(_ snapshot: PathSnapshot) {
        guard snapshot != current else { return }
        current = snapshot
        log.note("path: \(snapshot.summary)")
    }

    /// Fetches Apple's captive-portal probe with a 5 s timeout: does the phone still reach the internet while it
    /// is on the camera's access point?
    func checkInternet() async {
        guard let url = URL(string: "https://captive.apple.com/hotspot-detect.html") else { return }
        internet = "checking…"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5   // waitsForConnectivity defaults to false: fail fast, don't wait
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        let clock = ContinuousClock()
        let started = clock.now
        let pathText = current?.summary ?? "path unknown (monitor not running)"
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data, as: UTF8.self)
            let ms = (clock.now - started).inSeconds * 1000
            if status == 200, body.contains("Success") {
                internet = String(format: "reachable (%.0f ms)", ms)
            } else {
                internet = "captive or filtered (HTTP \(status))"
            }
            log.note("internet check: \(internet); \(pathText)")
        } catch {
            let seconds = (clock.now - started).inSeconds
            internet = "no internet"
            log.note(String(format: "internet check: no internet after %.1f s (%@); %@", seconds, error.localizedDescription, pathText))
        }
    }

    /// Waits up to `timeout` seconds for a Wi-Fi path that `accept` likes (e.g. satisfied with a new gateway).
    /// Returns nil on timeout.
    nonisolated static func waitForWiFi(timeout: Double, accept: @escaping @Sendable (PathSnapshot) -> Bool) async -> PathSnapshot? {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let queue = DispatchQueue(label: "spike.path.wait")
        let result: PathSnapshot? = try? await withCheckedThrowingContinuation { (c: CheckedContinuation<PathSnapshot?, Error>) in
            let once = OnceContinuation(c)
            monitor.pathUpdateHandler = { path in
                let snapshot = PathSnapshot(path)
                if accept(snapshot) { once.resume(returning: snapshot) }
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.resume(returning: nil) }
        }
        monitor.cancel()
        return result
    }
}

/// An NWPath reduced to loggable values.
struct PathSnapshot: Equatable, Sendable {
    var status: String
    var isSatisfied: Bool
    var interfaces: [String]
    var usesWiFi: Bool
    var usesCellular: Bool
    var isExpensive: Bool
    var isConstrained: Bool
    var gateways: [String]
    var firstIPv4Gateway: String?
    var unsatisfiedReason: String?
    var linkQuality: String

    init(_ path: NWPath) {
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requires connection"
        @unknown default: status = "unknown"
        }
        isSatisfied = path.status == .satisfied
        interfaces = path.availableInterfaces.map { "\($0.name) (\(NetFormat.interfaceType($0.type)))" }
        usesWiFi = path.usesInterfaceType(.wifi)
        usesCellular = path.usesInterfaceType(.cellular)
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        gateways = path.gateways.map(NetFormat.endpoint)
        firstIPv4Gateway = path.gateways.lazy.compactMap(NetFormat.ipv4Host).first
        if path.status == .satisfied {
            unsatisfiedReason = nil
        } else if path.unsatisfiedReason == .localNetworkDenied {
            unsatisfiedReason = "Local Network denied"
        } else {
            unsatisfiedReason = "\(path.unsatisfiedReason)"
        }
        linkQuality = "\(path.linkQuality)"
    }

    var summary: String {
        var parts = [status]
        if let unsatisfiedReason { parts.append("reason: \(unsatisfiedReason)") }
        parts.append("interfaces [\(interfaces.joined(separator: ", "))]")
        parts.append("uses Wi-Fi \(usesWiFi ? "yes" : "no"), cellular \(usesCellular ? "yes" : "no")")
        parts.append("expensive \(isExpensive ? "yes" : "no"), constrained \(isConstrained ? "yes" : "no")")
        parts.append("gateways [\(gateways.joined(separator: ", "))]")
        parts.append("link quality \(linkQuality)")
        return parts.joined(separator: " · ")
    }
}

/// Address formatting shared by the Wi-Fi probes. Nonisolated: used from Network.framework callback queues.
enum NetFormat {
    static func host(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return address.rawValue.map { String($0) }.joined(separator: ".")
        case .ipv6(let address):
            return "\(address)"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }

    static func endpoint(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            return port.rawValue == 0 ? Self.host(host) : "\(Self.host(host)):\(port.rawValue)"
        case .service(let name, let type, let domain, _):
            return "\(name).\(type)\(domain)"
        default:
            return "\(endpoint)"
        }
    }

    /// The host of a host:port endpoint if it is an IPv4 address, e.g. a gateway.
    static func ipv4Host(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint, case .ipv4 = host else { return nil }
        return Self.host(host)
    }

    static func interfaceType(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "Wi-Fi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "wired"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }
}
