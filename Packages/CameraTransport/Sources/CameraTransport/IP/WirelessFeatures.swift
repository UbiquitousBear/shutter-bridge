// Switches for wireless behaviour that is built but not turned on in this round (wireless plan W9).

/// Wireless features that are built and tested but stay off until their route is in scope.
///
/// Each switch is a constant, not a setting: Swift 6 rejects a global mutable `static var` (it would be shared mutable
/// state across tasks), and nothing in 1.0 needs to flip one at run time. A test exercises the code behind a switch by
/// passing the value in (`WiFiCameraLocator.locate(gateway:typed:announced:passiveSSDP:)`), not by changing it.
public enum WirelessFeatures {
    /// Whether the app listens for the camera's SSDP announcements (`SSDPListener`) to find it on a network that isn't
    /// its own. Off: on the camera's own network, the 1.0 route, the camera is always at 192.168.122.1 and needs no
    /// discovery, and the other-network route is later (decision 5, backlog section 10). Passive listening worked in
    /// the spike without the multicast entitlement (backlog section 5), so turning this on needs no entitlement, only
    /// the Local Network permission the PTP/IP connection already asks for.
    public static let passiveSSDPDiscovery = false
}
