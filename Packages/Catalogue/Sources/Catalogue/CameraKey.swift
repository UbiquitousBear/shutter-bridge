/// The catalogue's key for one camera body. What fills it is an open point: MSC answers no PTP, so the serial from
/// `GetDeviceInfo` isn't available there, and the device's UUID string in MTP embeds what looks like the USB serial
/// (backlog sections 2 and 4). Whatever the value, it is private: `description` shows only its length, and anything
/// derived from a serial is hashed before it gets here.
public struct CameraKey: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public var description: String { "camera-key(\(rawValue.count) chars)" }
}
