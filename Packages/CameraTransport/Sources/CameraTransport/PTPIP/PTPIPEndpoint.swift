import PTPKit

/// Where a camera's PTP/IP responder listens: a host and a TCP port (both channels go to the same one).
///
/// Its description withholds the address unless it is the camera's own network (192.168.122.1, which is public: every
/// α7C II uses it), because a camera on a home network has the home network's address, and that stays out of logs and
/// diagnostics.
public struct PTPIPEndpoint: Sendable, Hashable, CustomStringConvertible {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16 = PTPIP.defaultPort) {
        self.host = host
        self.port = port
    }

    /// The camera's address on its own network, where its PTP/IP port and its SSDP announcements both came from. It
    /// is fixed (backlog section 1, "The camera's address on its own network is fixed").
    public static let cameraNetwork = PTPIPEndpoint(host: "192.168.122.1", port: PTPIP.defaultPort)

    public var description: String {
        self == .cameraNetwork ? "\(host):\(port) (camera network)" : "PTP/IP endpoint (address withheld):\(port)"
    }
}
