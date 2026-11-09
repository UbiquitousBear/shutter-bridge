#if canImport(Network)
import Foundation
@preconcurrency import Network

/// The phone's Wi-Fi path from `NWPathMonitor(requiredInterfaceType: .wifi)`, as `WiFiPathWatching` (wireless plan W9):
/// how `WirelessSession` confirms a join (the camera's gateway, 192.168.122.1, appearing; `apply` returning is not a
/// join) and how `WiFiCameraLocator` tells the camera's own network from another.
///
/// Each call starts its own monitor and cancels it when it returns, as the spike's `PathMonitor.waitForWiFi` did
/// (`Spike/Sources/Network/PathMonitor.swift`): nothing runs between calls. The monitor's reports are reduced to a
/// `WiFiPathSnapshot` (satisfied, IPv4 gateways) on its queue, so no Network.framework value leaves the callback. Code
/// compiled only by CI's Xcode 27 job; the snapshot's rules are tested on Linux.
public struct NWPathGateway: WiFiPathWatching {
    /// How long `gateway()` waits for the monitor's first report. The spike's read before joining
    /// (`PathMonitor.waitForWiFi(timeout: 0.5)`, `HotspotJoiner.swift`, line 53); a monitor reports the current path at
    /// once on start, so this only bounds a system that doesn't.
    public static let firstReportWait: Duration = .milliseconds(500)

    public init() {}

    public func gateway() async -> String? {
        await Self.firstSnapshot(within: Self.firstReportWait) { _ in true }?.gateway
    }

    public func waitForGateway(_ ip: String, timeout: Duration) async -> Bool {
        await Self.firstSnapshot(within: timeout) { $0.hasGateway(ip) } != nil
    }

    /// The first report that `accept` takes, or nil when `timeout` passes first or the task is cancelled.
    static func firstSnapshot(within timeout: Duration,
                              where accept: @escaping @Sendable (WiFiPathSnapshot) -> Bool) async -> WiFiPathSnapshot? {
        if Task.isCancelled { return nil }
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let queue = DispatchQueue(label: "NWPathGateway")
        let found = OnceResume<WiFiPathSnapshot?>()
        monitor.pathUpdateHandler = { path in
            let snapshot = Self.snapshot(of: path)
            if accept(snapshot) { found.resume(snapshot) }
        }
        monitor.start(queue: queue)
        queue.asyncAfter(deadline: .now() + NWByteChannel.seconds(timeout)) { found.resume(nil) }
        let snapshot = await withTaskCancellationHandler {
            await found.wait()
        } onCancel: {
            found.resume(nil)
        }
        monitor.cancel()
        return snapshot
    }

    /// The path's status and IPv4 gateways. IPv6 gateways are left out: a link-local one can be built from the router's
    /// MAC address, and on the camera's network the router is the camera.
    static func snapshot(of path: NWPath) -> WiFiPathSnapshot {
        WiFiPathSnapshot(isSatisfied: path.status == .satisfied, ipv4Gateways: path.gateways.compactMap(ipv4Host))
    }

    /// The host of a host-and-port endpoint when it is an IPv4 address, in dotted form; nil otherwise.
    static func ipv4Host(_ endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint, case let .ipv4(address) = host else { return nil }
        return address.rawValue.map { String($0) }.joined(separator: ".")
    }
}
#endif
