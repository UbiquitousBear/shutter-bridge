#if canImport(Network)
import Foundation
@preconcurrency import Network

/// Listens for the camera's SSDP announcements on the multicast group 239.255.255.250:1900, over Wi-Fi (backlog
/// section 5; wireless plan W9). Behind `WirelessFeatures.passiveSSDPDiscovery`, which is off in this round: with it
/// off, `announcements()` finishes at once and nothing touches the network.
///
/// The spike's `SSDPProbe.searchMulticast` (`Spike/Sources/Network/SSDPProbe.swift`) without the M-SEARCH: the group
/// became ready and received the camera's NOTIFYs without `com.apple.developer.networking.multicast` (requested on 8 Nov,
/// pending), while its own M-SEARCH never went out, so this only listens. Each datagram is parsed by `SSDPNotify`; one
/// that doesn't parse, or whose LOCATION names a host other than the sender, is dropped. How often the camera announces
/// is not measured, so how long to listen is the caller's (listen past 5 s, or until a typed address is used). Code
/// compiled only by CI's Xcode 27 job; the parser is tested on Linux.
public struct SSDPListener: Sendable {
    /// The SSDP multicast group and port.
    public static let groupHost = "239.255.255.250"
    public static let groupPort: UInt16 = 1900
    /// Announcements kept for a slow reader; older ones are dropped first (the camera repeats them).
    static let buffered = 32

    public init() {}

    /// The NOTIFYs heard from now on, in order, until the reader stops iterating (which leaves the group) or the group
    /// fails. Finishes at once when passive discovery is off or the group can't be made.
    public func announcements() -> AsyncStream<SSDPNotify> {
        let (stream, continuation) = AsyncStream.makeStream(of: SSDPNotify.self,
                                                           bufferingPolicy: .bufferingNewest(Self.buffered))
        guard WirelessFeatures.passiveSSDPDiscovery else {
            continuation.finish()
            return stream
        }
        let multicast: NWMulticastGroup
        do {
            multicast = try NWMulticastGroup(for: [
                .hostPort(host: NWEndpoint.Host(Self.groupHost), port: NWEndpoint.Port(rawValue: Self.groupPort) ?? 1900),
            ])
        } catch {
            continuation.finish()
            return stream
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .wifi
        let group = NWConnectionGroup(with: multicast, using: parameters)
        group.setReceiveHandler(maximumMessageSize: SSDPNotify.maximumSize, rejectOversizedMessages: true) {
            message, content, _ in
            guard let content, let sender = message.remoteEndpoint.flatMap(NWPathGateway.ipv4Host),
                  let notify = try? SSDPNotify(content), notify.isSent(from: sender)
            else { return }
            continuation.yield(notify)
        }
        group.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: continuation.finish()
            default: break
            }
        }
        continuation.onTermination = { _ in group.cancel() }
        group.start(queue: DispatchQueue(label: "SSDPListener"))
        return stream
    }
}
#endif
