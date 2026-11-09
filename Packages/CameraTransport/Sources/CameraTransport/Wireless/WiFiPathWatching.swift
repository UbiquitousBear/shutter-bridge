// The phone's Wi-Fi path, as far as the join needs it: which gateway it has. The Network.framework adapter (`NWPathGateway`,
// `Wireless/NWPathGateway.swift`) implements it; tests use a scripted fake.

/// The IPv4 gateway of the phone's Wi-Fi path. On the camera's own network it is the camera, 192.168.122.1
/// (`WirelessCamera.cameraNetworkGateway`); the spike confirmed every join by it appearing (`HotspotJoiner`).
public protocol WiFiPathWatching: Sendable {
    /// The Wi-Fi path's gateway now, or nil when there is no satisfied Wi-Fi path or it has no IPv4 gateway. With several,
    /// the camera's 192.168.122.1 when it is among them (the rule `waitForGateway` uses), otherwise the first.
    func gateway() async -> String?

    /// Returns true as soon as the Wi-Fi path is satisfied with `ip` among its gateways (at once if it already is), or false
    /// when `timeout` passes first or the task is cancelled.
    func waitForGateway(_ ip: String, timeout: Duration) async -> Bool
}
