import Foundation

/// One SSDP NOTIFY datagram (UPnP Device Architecture 1.1, section 1.2), parsed. Pure: `SSDPListener` hands it the
/// bytes it hears on 239.255.255.250:1900.
///
/// What the α7C II sends (backlog section 5; findings, *SSDP discovery*): NOTIFYs for `upnp:rootdevice`,
/// `urn:schemas-upnp-org:device:Basic:1` and `urn:schemas-sony-com:service:DigitalImaging:1`, with LOCATION
/// `http://<its address>:64321/dd.xml`, both on its own network (from 192.168.122.1, 0.73 s after joining) and on a home
/// network (four, 1.91 s and 4.65 s into a 5 s listen). Only the Sony type identifies a camera; the other two are sent by
/// every UPnP device (`announcesSonyCamera`).
///
/// The parser throws on anything that isn't a well-formed NOTIFY: more than `maximumSize` bytes, text that isn't
/// UTF-8, another start line (an M-SEARCH, our own looped back, or a search response), a header line without a colon
/// or with a space in its name, a missing NT, NTS or USN, or an `ssdp:alive` without an http LOCATION that names a
/// host. It never traps.
///
/// **Privacy.** The USN carries the camera's UDN, whose last 12 hex digits are its hardware ID (the MAC-like ID that is
/// zeroed in fixtures). `uniqueServiceName` keeps it for matching announcements; never log it. `description` leaves the
/// USN out and withholds any address but the camera network's.
public struct SSDPNotify: Sendable, Hashable, CustomStringConvertible {
    /// NTS: what the notification says.
    public enum Subtype: Sendable, Hashable {
        /// `ssdp:alive`: the device is there (or still there).
        case alive
        /// `ssdp:byebye`: the device is leaving.
        case byebye
        /// `ssdp:update`: the device's boot ID changed.
        case update
        /// Anything else, as sent.
        case other(String)

        init(_ text: String) {
            switch text.lowercased() {
            case "ssdp:alive": self = .alive
            case "ssdp:byebye": self = .byebye
            case "ssdp:update": self = .update
            default: self = .other(text)
            }
        }
    }

    /// Why a datagram isn't a NOTIFY this parser accepts.
    public enum ParseError: Error, Sendable, Hashable {
        /// Larger than `maximumSize` (the byte count).
        case tooLarge(Int)
        /// Not UTF-8 text.
        case notText
        /// The start line isn't `NOTIFY * HTTP/1.1` (the line, cut to 64 characters).
        case notANotify(String)
        /// A header line without a colon, or with an empty name or one with a space in it.
        case malformedHeader
        /// A required header is absent (its name).
        case missingHeader(String)
        /// LOCATION isn't an http URL with a host and a valid port.
        case badLocation
    }

    /// The largest datagram parsed. An SSDP message is meant to fit one UDP datagram on an Ethernet MTU; the camera's
    /// are far smaller (a few hundred bytes).
    public static let maximumSize = 8 * 1024
    /// Sony's imaging service type: the one notification type that identifies a camera.
    public static let sonyImagingType = "urn:schemas-sony-com:service:DigitalImaging:1"
    /// The notification types the α7C II was heard sending (findings, *SSDP discovery*).
    public static let cameraNotificationTypes: Set<String> = [
        "upnp:rootdevice", "urn:schemas-upnp-org:device:Basic:1", sonyImagingType,
    ]

    /// NT: the notification type.
    public let notificationType: String
    /// NTS.
    public let subtype: Subtype
    /// USN. Carries the camera's hardware ID: never log it.
    public let uniqueServiceName: String
    /// LOCATION as sent: the device description's URL. Nil only in a byebye or update without one.
    public let location: String?
    /// LOCATION's host and port (80 when it names none).
    public let locationHost: String?
    public let locationPort: UInt16?
    /// CACHE-CONTROL's `max-age`, in seconds: how long the announcement holds. Nil when absent or unreadable.
    public let maxAge: Int?
    /// SERVER, as sent.
    public let server: String?

    public init(_ data: Data) throws(ParseError) {
        guard data.count <= Self.maximumSize else { throw .tooLarge(data.count) }
        guard let text = String(data: data, encoding: .utf8) else { throw .notText }
        try self.init(text)
    }

    public init(_ text: String) throws(ParseError) {
        guard text.utf8.count <= Self.maximumSize else { throw .tooLarge(text.utf8.count) }
        // Lines end in CRLF; a bare LF is accepted too. Swift treats "\r\n" as one Character, so split on both.
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\r\n" || $0 == "\n" }
        let startLine = lines.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let words = startLine.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count == 3, words[0] == "NOTIFY", words[1] == "*", words[2].uppercased() == "HTTP/1.1" else {
            throw .notANotify(String(startLine.prefix(64)))
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }  // the end of the headers
            guard let colon = line.firstIndex(of: ":") else { throw .malformedHeader }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { throw .malformedHeader }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] == nil { headers[name] = value }  // the first of a repeated header counts
        }

        func required(_ name: String) throws(ParseError) -> String {
            guard let value = headers[name], !value.isEmpty else { throw .missingHeader(name) }
            return value
        }
        notificationType = try required("NT")
        subtype = Subtype(try required("NTS"))
        uniqueServiceName = try required("USN")
        server = headers["SERVER"].flatMap { $0.isEmpty ? nil : $0 }
        maxAge = headers["CACHE-CONTROL"].flatMap(Self.maxAge)

        if let location = headers["LOCATION"], !location.isEmpty {
            guard let (host, port) = Self.hostAndPort(of: location) else { throw .badLocation }
            self.location = location
            locationHost = host
            locationPort = port
        } else if subtype == .alive {
            throw .missingHeader("LOCATION")
        } else {
            location = nil
            locationHost = nil
            locationPort = nil
        }
    }

    /// Whether this announces a Sony camera that is there: `ssdp:alive` (or `ssdp:update`) for Sony's imaging service,
    /// with a LOCATION.
    public var announcesSonyCamera: Bool {
        guard notificationType == Self.sonyImagingType, locationHost != nil else { return false }
        switch subtype {
        case .alive, .update: return true
        case .byebye, .other: return false
        }
    }

    /// The camera's PTP/IP address from LOCATION's host, when that is an IPv4 address: the host, with PTP/IP's port
    /// (15740), not the description's. On the camera's own network the PTP/IP port and the announcements came from the
    /// same address, 192.168.122.1 (backlog section 1). On a home network the spike connected to the address taken from
    /// the SSDP result or typed (which of the two was not logged), so the same rule there is `unverified`.
    public var cameraAddress: TypedCameraAddress? {
        guard let locationHost, let address = TypedCameraAddress(locationHost), address.isIPv4 else { return nil }
        return address
    }

    /// Whether the datagram came from the host its LOCATION names (`sender`, the IPv4 address the listener saw it from).
    /// A NOTIFY that points elsewhere is ignored, so another device on the network can't send the app to a third host.
    public func isSent(from sender: String) -> Bool {
        locationHost == sender
    }

    public var description: String {
        let place: String
        if let address = cameraAddress, address.isCameraNetwork {
            place = "from \(address.host) (camera network)"
        } else {
            place = locationHost == nil ? "with no location" : "from an address withheld"
        }
        return "SSDP NOTIFY \(subtype) \(notificationType) \(place)" + (maxAge.map { ", max-age \($0) s" } ?? "")
    }

    // MARK: - Header values

    /// `max-age=N` from a CACHE-CONTROL value (directives separated by commas, spaces allowed around `=`).
    private static func maxAge(_ value: String) -> Int? {
        for directive in value.split(separator: ",") {
            let pair = directive.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[0].lowercased() == "max-age", !pair[1].isEmpty,
                  pair[1].allSatisfy({ ("0" ... "9").contains($0) }), let seconds = Int(pair[1]) else { continue }
            return seconds
        }
        return nil
    }

    /// The host and port of an http URL; nil for another scheme, no host, or a port outside 1 to 65535.
    private static func hostAndPort(of location: String) -> (String, UInt16)? {
        guard let components = URLComponents(string: location), components.scheme?.lowercased() == "http",
              let host = components.host, !host.isEmpty
        else { return nil }
        guard let port = components.port else { return (host, 80) }
        guard (1 ... Int(UInt16.max)).contains(port) else { return nil }
        return (host, UInt16(port))
    }
}
