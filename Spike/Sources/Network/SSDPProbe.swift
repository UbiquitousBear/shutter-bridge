import Foundation
import Network

/// Day 9: SSDP M-SEARCH over UDP multicast. Needs the multicast entitlement; without it `NWConnectionGroup`
/// fails with a policy error, which is itself a useful thing to record. The Mac-side `tcpdump` on day 6
/// tells us what the camera actually announces, so this probe sends both a Sony-specific and a wildcard search.
@MainActor
final class SSDPProbe {
    private var group: NWConnectionGroup?
    private let log: SpikeLog

    static let sonySearchTarget = "urn:schemas-sony-com:service:DigitalImaging:1"

    init(log: SpikeLog) { self.log = log }

    func start(seconds: Double = 5) {
        let endpoint = NWEndpoint.hostPort(host: "239.255.255.250", port: 1900)
        guard let multicast = try? NWMulticastGroup(for: [endpoint]) else {
            log.error("NWMulticastGroup could not be created")
            return
        }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let g = NWConnectionGroup(with: multicast, using: params)
        g.setReceiveHandler(maximumMessageSize: 4096, rejectOversizedMessages: true) { [weak self] message, content, _ in
            guard let self, let content, let text = String(data: content, encoding: .utf8) else { return }
            let from = message.remoteEndpoint.map { "\($0)" } ?? "?"
            let headline = text.split(separator: "\r\n").prefix(6).joined(separator: " | ")
            Task { @MainActor in self.log.note("SSDP from \(from): \(headline)") }
        }
        g.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.log.note("SSDP group ready; sending M-SEARCH")
                    self?.sendSearch()
                case .failed(let e):
                    self?.log.error("SSDP group failed: \(e) — no multicast entitlement? Fall back to a typed IP.")
                case .waiting(let e):
                    self?.log.warn("SSDP waiting: \(e)")
                default: break
                }
            }
        }
        group = g
        g.start(queue: .global(qos: .userInitiated))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await MainActor.run { self?.stop() }
        }
    }

    func stop() {
        group?.cancel()
        group = nil
        log.note("SSDP probe stopped")
    }

    private func sendSearch() {
        for target in [Self.sonySearchTarget, "ssdp:all"] {
            let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n\r\n"
            group?.send(content: msg.data(using: .utf8)) { [weak self] error in
                if let error { Task { @MainActor in self?.log.error("M-SEARCH send failed: \(error)") } }
            }
        }
    }
}
