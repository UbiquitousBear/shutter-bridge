import PTPKit

// Where the camera is on Wi-Fi (backlog section 5; wireless plan W9): on its own network it is always the gateway,
// 192.168.122.1; anywhere else the person types its address (always offered) or, once `WirelessFeatures
// .passiveSSDPDiscovery` is on, its SSDP announcement says where it is. Pure, so every rule is tested on Linux; the
// Network.framework parts are `NWPathGateway` (the path) and `SSDPListener` (the announcements).

/// A camera address the person typed: an IPv4 address or a host name, with an optional `:port` (PTP/IP's 15740 when
/// there is none).
///
/// Accepted: `192.168.122.1`, `192.168.122.1:15740`, `camera.local`, `camera.local.:15740`, surrounding spaces. Refused
/// (nil): an empty string, a URL (`http://…`, any `/`), user info (`@`), IPv6 (in brackets or not; the α7C II's routes
/// are IPv4), a port of 0 or above 65535, an all-numeric host that isn't four octets of 0 to 255 (`192.168.122`,
/// `300.1.1.1`, a typo rather than a name), an octet with a leading zero (`192.168.010.1`, which some resolvers read as
/// octal), an IPv4 address that can't be a camera (0.0.0.0/8, unspecified or "this network", which dials the phone
/// itself; loopback, 127.0.0.0/8; multicast, 224.0.0.0/4; and reserved, 240.0.0.0/4, which holds the broadcast
/// 255.255.255.255), and a name with characters outside letters, digits and hyphens or a label longer than 63 characters.
///
/// Its description withholds the address unless it is the camera's own network, as `PTPIPEndpoint` does: a typed
/// address is usually on a home network, and that stays out of logs.
public struct TypedCameraAddress: Sendable, Hashable, CustomStringConvertible {
    /// The host as it will be dialled: an IPv4 address in dotted form, or a name in lower case without a trailing dot.
    public let host: String
    /// The TCP port of the camera's PTP/IP responder.
    public let port: UInt16
    /// Whether `host` is an IPv4 address rather than a name.
    public let isIPv4: Bool

    /// The longest text looked at; anything longer is refused (a host name is at most 253 characters).
    static let maximumLength = 260

    public init?(_ text: String) {
        let trimmed = Self.trimmed(text)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumLength,
              trimmed.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }),
              !trimmed.contains("/"), !trimmed.contains("@"), !trimmed.contains("["), !trimmed.contains("]")
        else { return nil }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        let hostText: Substring
        var port = PTPIP.defaultPort
        switch parts.count {
        case 1:
            hostText = parts[0]
        case 2:
            hostText = parts[0]
            guard let typed = Self.port(parts[1]) else { return nil }
            port = typed
        default:
            return nil  // IPv6, or a stray colon
        }

        var name = hostText.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        if labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) {
            guard let address = Self.ipv4(labels) else { return nil }
            self.host = address
            self.isIPv4 = true
        } else {
            guard name.count <= 253, labels.allSatisfy(Self.isHostLabel) else { return nil }
            self.host = name
            self.isIPv4 = false
        }
        self.port = port
    }

    /// The PTP/IP endpoint to connect to.
    public var endpoint: PTPIPEndpoint { PTPIPEndpoint(host: host, port: port) }

    /// Whether this is the camera's address on its own network (`PTPIPEndpoint.cameraNetwork`).
    public var isCameraNetwork: Bool { endpoint == .cameraNetwork }

    public var description: String {
        isCameraNetwork ? "\(host):\(port) (camera network)" : "typed camera address (withheld):\(port)"
    }

    // MARK: - Parsing

    private static func trimmed(_ text: String) -> Substring {
        // `Character.isWhitespace` also covers "\r\n", which Swift holds as one Character.
        var slice = Substring(text)
        while let first = slice.first, first.isWhitespace { slice.removeFirst() }
        while let last = slice.last, last.isWhitespace { slice.removeLast() }
        return slice
    }

    private static func port(_ text: Substring) -> UInt16? {
        guard (1 ... 5).contains(text.count), text.allSatisfy(\.isASCIIDigit), let value = Int(text),
              (1 ... Int(UInt16.max)).contains(value)
        else { return nil }
        return UInt16(value)
    }

    /// Four octets of 0 to 255, each without a leading zero, outside the ranges no camera can be at: 0.0.0.0/8,
    /// 127.0.0.0/8, 224.0.0.0/4 and 240.0.0.0/4 (a first octet of 0, 127, or 224 and above).
    private static func ipv4(_ labels: [Substring]) -> String? {
        guard labels.count == 4 else { return nil }
        var octets: [Int] = []
        for label in labels {
            guard label.count <= 3, label == "0" || label.first != "0", let value = Int(label), value <= 255
            else { return nil }
            octets.append(value)
        }
        guard let first = octets.first, first != 0, first != 127, first < 224 else { return nil }
        return labels.joined(separator: ".")
    }

    /// RFC 1123: letters, digits and hyphens, 1 to 63 characters, not starting or ending with a hyphen.
    private static func isHostLabel(_ label: Substring) -> Bool {
        guard (1 ... 63).contains(label.count), label.first != "-", label.last != "-" else { return false }
        return label.allSatisfy { $0.isASCIIDigit || ("a" ... "z").contains($0) || $0 == "-" }
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { ("0" ... "9").contains(self) }
}

/// The phone's Wi-Fi path as the locator needs it: whether it is up, and its IPv4 gateways. `NWPathGateway` reads one
/// from `NWPathMonitor` (IPv6 gateways are left out: a link-local one can be built from the router's MAC address, and on
/// the camera's network the router is the camera).
public struct WiFiPathSnapshot: Sendable, Hashable {
    /// The path is satisfied (the phone is on a Wi-Fi network that works).
    public var isSatisfied: Bool
    /// The IPv4 gateways in the order the system lists them.
    public var ipv4Gateways: [String]

    public init(isSatisfied: Bool, ipv4Gateways: [String]) {
        self.isSatisfied = isSatisfied
        self.ipv4Gateways = ipv4Gateways
    }

    /// The gateway of a satisfied path, as `WiFiPathWatching.gateway()` gives it: the camera's 192.168.122.1 when it is
    /// among the gateways (so `gateway == cameraNetworkGateway` and `isCameraNetwork` agree, wherever the system lists
    /// it), otherwise the first; nil when the path isn't satisfied or has no IPv4 gateway.
    public var gateway: String? {
        guard isSatisfied else { return nil }
        return isCameraNetwork ? WirelessCamera.cameraNetworkGateway : ipv4Gateways.first
    }

    /// Whether the path is satisfied with `ip` among its gateways.
    public func hasGateway(_ ip: String) -> Bool { isSatisfied && ipv4Gateways.contains(ip) }

    /// Whether the phone is on the camera's own network: the camera is the gateway (every join in the spike was
    /// confirmed by 192.168.122.1 appearing, `HotspotJoiner`).
    public var isCameraNetwork: Bool { hasGateway(WirelessCamera.cameraNetworkGateway) }
}

/// Where the camera was found, and how.
public struct WiFiCameraLocation: Sendable, Hashable, CustomStringConvertible {
    public enum Source: Sendable, Hashable {
        /// The phone's Wi-Fi gateway is 192.168.122.1: the phone is on the camera's own network.
        case cameraNetworkGateway
        /// The person typed the address.
        case typed
        /// The camera's SSDP announcement gave it (only with `WirelessFeatures.passiveSSDPDiscovery` on).
        case announced
    }

    /// Where to connect.
    public var endpoint: PTPIPEndpoint
    /// Which network the camera is on: the camera's own (192.168.122.1) or another.
    public var route: WiFiRoute
    public var source: Source

    public init(endpoint: PTPIPEndpoint, route: WiFiRoute, source: Source) {
        self.endpoint = endpoint
        self.route = route
        self.source = source
    }

    /// Uses the endpoint's own description, which withholds any address but the camera network's.
    public var description: String { "\(endpoint) via \(source)" }
}

/// Decides where the camera is (backlog section 5).
///
/// In order:
/// 1. **The camera's own network:** when the phone's Wi-Fi gateway is 192.168.122.1, the camera is there, on 15740. No
///    discovery and no typed address are needed; a typed address is ignored, since the camera's network has one host.
/// 2. **A typed address,** always offered: the person's explicit choice beats an announcement.
/// 3. **An SSDP announcement** of Sony's imaging service (`SSDPNotify.announcesSonyCamera`), only when passive discovery
///    is on: its LOCATION host, with PTP/IP's port. Off in this round (`WirelessFeatures.passiveSSDPDiscovery`).
/// 4. Otherwise nil: the app asks for an address. An announcement never proves the camera will take a session (it
///    announced with access authentication on and refused port 15740, backlog section 5), so a location is only where
///    to try.
public enum WiFiCameraLocator {
    /// Whether `gateway` (the phone's Wi-Fi gateway) is the camera's own network.
    public static func isCameraNetwork(gateway: String?) -> Bool {
        gateway == WirelessCamera.cameraNetworkGateway
    }

    /// Where the camera is, by the rules above.
    ///
    /// - Parameters:
    ///   - gateway: The phone's Wi-Fi gateway now (`WiFiPathWatching.gateway()`), nil when there is none.
    ///   - typed: The address the person typed, if any.
    ///   - announced: The latest camera announcement heard, if any.
    ///   - passiveSSDP: Whether announcements count; `WirelessFeatures.passiveSSDPDiscovery` unless a test says.
    public static func locate(gateway: String?, typed: TypedCameraAddress?, announced: SSDPNotify? = nil,
                              passiveSSDP: Bool = WirelessFeatures.passiveSSDPDiscovery) -> WiFiCameraLocation? {
        if isCameraNetwork(gateway: gateway) {
            return WiFiCameraLocation(endpoint: .cameraNetwork, route: .cameraNetwork, source: .cameraNetworkGateway)
        }
        if let typed {
            return WiFiCameraLocation(endpoint: typed.endpoint, route: route(host: typed.host), source: .typed)
        }
        if passiveSSDP, let announced, announced.announcesSonyCamera, let address = announced.cameraAddress {
            return WiFiCameraLocation(endpoint: address.endpoint, route: route(host: address.host), source: .announced)
        }
        return nil
    }

    /// The network a host is on, from the host alone (a typed `192.168.122.1:15741` is still the camera's network).
    static func route(host: String) -> WiFiRoute {
        host == WirelessCamera.cameraNetworkGateway ? .cameraNetwork : .otherNetwork
    }

    /// Where the camera is, reading the gateway from the phone's Wi-Fi path.
    public static func locate(path: any WiFiPathWatching, typed: TypedCameraAddress?, announced: SSDPNotify? = nil,
                              passiveSSDP: Bool = WirelessFeatures.passiveSSDPDiscovery) async -> WiFiCameraLocation? {
        locate(gateway: await path.gateway(), typed: typed, announced: announced, passiveSSDP: passiveSSDP)
    }
}
