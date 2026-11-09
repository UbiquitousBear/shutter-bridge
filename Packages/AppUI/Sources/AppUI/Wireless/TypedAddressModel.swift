import CameraTransport
import Foundation
import Observation

/// The sheet where the person types the camera's address, for a camera on the same network as the phone (backlog
/// Iteration 3, section 5: "a typed address is the escape hatch, always offered"; wireless plan W15).
///
/// The text is checked with `TypedCameraAddress` (CameraTransport: an IPv4 address or a name, an optional port, nothing
/// else), and when it can't be used the model says which kind of mistake it is, so the copy can say what to type
/// instead (`TypedAddressWording.problem`). It shows no complaint for an empty field. The camera's own network address,
/// 192.168.122.1, is refused with a pointer to Bluetooth setup: on that network the camera is found without an address, and the
/// phone joins it itself. The address never goes to a log: `TypedCameraAddress` withholds it, and this model logs
/// nothing.
///
/// `add()` hands the checked address to `onAdd` (the app: `WiFiCameraSource.addTypedCamera`) and does nothing for text that
/// isn't a usable address.
@MainActor
@Observable
public final class TypedAddressModel {
    /// What is wrong with the text, by kind of mistake.
    public enum Problem: Sendable, Hashable, CaseIterable {
        /// A URL, a path or user information: `http://…`, `/…`, `name@…`.
        case url
        /// IPv6, in brackets or not (the camera's routes are IPv4).
        case ipv6
        /// A `:port` that isn't 1 to 65535.
        case port
        /// Numbers and dots that aren't four octets of 0 to 255 without leading zeros.
        case numbers
        /// Four good octets that no camera can be at (0.x.x.x, loopback, multicast, reserved).
        case unusable
        /// A name with characters a host name can't have, or a label that is too long.
        case name
        /// The camera's own network (192.168.122.1), where the app needs no address.
        case cameraNetwork
        /// Anything else.
        case other
    }

    /// What the person typed.
    public var text: String

    /// True while `onAdd` runs.
    public private(set) var isAdding = false

    @ObservationIgnored private let onAdd: @MainActor (TypedCameraAddress) async -> Void

    public init(text: String = "", onAdd: @escaping @MainActor (TypedCameraAddress) async -> Void) {
        self.text = text
        self.onAdd = onAdd
    }

    /// The address, when the text is one the app can connect to.
    public var address: TypedCameraAddress? {
        guard let parsed = TypedCameraAddress(text), parsed.host != WirelessCamera.cameraNetworkGateway else { return nil }
        return parsed
    }

    /// What is wrong, or nil for an empty field or a good address.
    public var problem: Problem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = TypedCameraAddress(text) {
            return parsed.host == WirelessCamera.cameraNetworkGateway ? .cameraNetwork : nil
        }
        return Self.classify(trimmed)
    }

    /// The line under the field when there is a problem.
    public var message: String? { problem.map(TypedAddressWording.problem) }

    /// Whether Add Camera is enabled.
    public var canAdd: Bool { address != nil && !isAdding }

    /// Hands the address over. Returns whether it did.
    @discardableResult
    public func add() async -> Bool {
        guard canAdd, let address else { return false }
        isAdding = true
        defer { isAdding = false }
        await onAdd(address)
        return true
    }

    /// Which kind of mistake text that `TypedCameraAddress` refused is. Looks only at the shape of the text; the parser
    /// is the authority on what is accepted.
    static func classify(_ text: String) -> Problem {
        if text.contains("/") || text.contains("@") { return .url }
        if text.contains("[") || text.contains("]") || text.filter({ $0 == ":" }).count > 1 { return .ipv6 }
        var host = Substring(text)
        if let colon = text.firstIndex(of: ":") {
            host = text[..<colon]
            let port = text[text.index(after: colon)...]
            let valid = (1 ... 5).contains(port.count) && port.allSatisfy(\.isASCIIDigit)
                && (1 ... Int(UInt16.max)).contains(Int(port) ?? 0)
            if !valid { return .port }
        }
        if host.hasSuffix(".") { host = host.dropLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) {
            // Four good octets are refused only for the ranges no camera can be at.
            let octets = labels.compactMap { label -> Int? in
                label.count <= 3 && (label == "0" || label.first != "0") ? Int(label) : nil
            }
            if labels.count == 4, octets.count == 4, octets.allSatisfy({ $0 <= 255 }) { return .unusable }
            return .numbers
        }
        let allowed = host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
        return allowed ? .other : .name
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { ("0" ... "9").contains(self) }
}
