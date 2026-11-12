import CameraTransport
import Catalogue
import Foundation

// The Wi-Fi cameras the app knows (wireless plan W15): what an entry is, how a camera that has been paired but never
// connected is remembered, and the two protocols the app's live composition (W16) fills in.

/// One camera the person set up for Wi-Fi: paired over Bluetooth (its own network, `.wifi(.cameraNetwork)`) or typed in
/// by address (the phone's network, `.wifi(.otherNetwork)`).
///
/// The catalogue key (`CameraKeys`: the hash of the DeviceInfo serial) is known only after the first session has
/// opened, so a camera that was paired but never connected has none (`key` is nil; `isConnectedBefore` is false).
/// Everything else here is private to the person (a Bluetooth identifier, an address, a GUID), so the descriptions of
/// the types it holds redact it, and `description` says only which are set.
public struct WiFiCameraEntry: Sendable, Hashable, CustomStringConvertible {
    /// The descriptor discovery lists. Its ID is made once, from the initiator GUID, and never changes, so a camera
    /// being browsed isn't dropped when its key becomes known. Its name (D11, one name per body; Shamil, 12 Nov) is the
    /// catalogue's friendly name, else the model the camera reported in DeviceInfo ("ILCE-7CM2", written at each
    /// connection), else "Camera" until the camera has connected (`WiFiCameraSource` renames it then), so its Staging
    /// folder and album are the ones its MTP imports use.
    public var descriptor: CameraDescriptor
    /// The catalogue's key once a session has read the serial.
    public var key: CameraKey?
    /// The peripheral iOS gave the camera when it was paired (nil for a typed-address camera, or to find by a scan).
    public var peripheral: PeripheralID?
    /// The initiator GUID sent in `Init_Command_Request`, kept per camera so it never changes (`IPLink.Configuration`).
    public var guid: UUID
    /// The address the person typed, for a camera on the phone's own network.
    public var typed: TypedCameraAddress?

    public init(descriptor: CameraDescriptor, key: CameraKey?, peripheral: PeripheralID?, guid: UUID,
                typed: TypedCameraAddress? = nil) {
        self.descriptor = descriptor
        self.key = key
        self.peripheral = peripheral
        self.guid = guid
        self.typed = typed
    }

    public var id: CameraDescriptor.ID { descriptor.id }
    public var isConnectedBefore: Bool { key != nil }

    /// The name a Wi-Fi camera has before its first connection has read its model.
    public static let defaultName = CamerasWording.genericName

    /// The name for a camera's catalogue row: its friendly name, else its model, else `defaultName`.
    static func name(for record: CameraRecord) -> String {
        if !record.friendlyName.isEmpty { return record.friendlyName }
        let model = record.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? defaultName : model
    }

    /// The descriptor's ID for an initiator GUID.
    public static func id(forGUID guid: UUID) -> CameraDescriptor.ID {
        CameraDescriptor.ID(rawValue: "wifi-" + guid.uuidString.lowercased())
    }

    /// An entry from a catalogue row (`preferredCarrier == .wifi`).
    init(record: CameraRecord) {
        let guid = record.ptpipGUID ?? UUID()
        // An address that isn't the camera's own network is a typed one (`CameraRecord.lastIP`). A row with a peripheral
        // is a paired camera whatever else it holds: one set up on both routes lists once, as paired, and keeps its
        // address in the row.
        let paired = record.bluetoothPeripheralID != nil
        let typed = paired ? nil : record.lastIP.flatMap(TypedCameraAddress.init)
            .flatMap { $0.host == WirelessCamera.cameraNetworkGateway ? nil : $0 }
        let name = Self.name(for: record)
        self.init(descriptor: CameraDescriptor(id: Self.id(forGUID: guid), name: name,
                                               mode: .wifi(typed == nil ? .cameraNetwork : .otherNetwork)),
                  key: record.key, peripheral: record.bluetoothPeripheralID.map(PeripheralID.init), guid: guid,
                  typed: typed)
    }

    /// An entry for a camera paired or typed in but not yet connected.
    init(pending: PendingWiFiCamera) {
        let typed = pending.typedAddress.flatMap(TypedCameraAddress.init)
        self.init(descriptor: CameraDescriptor(id: Self.id(forGUID: pending.guid), name: Self.defaultName,
                                               mode: .wifi(typed == nil ? .cameraNetwork : .otherNetwork)),
                  key: nil, peripheral: pending.peripheral.map(PeripheralID.init), guid: pending.guid, typed: typed)
    }

    public var description: String {
        var parts = [isConnectedBefore ? "connected before" : "not connected yet"]
        if peripheral != nil { parts.append("peripheral") }
        if typed != nil { parts.append("typed address") }
        return "WiFiCameraEntry(\(parts.joined(separator: ", ")))"
    }
}

/// A camera paired (or typed in) whose first session hasn't opened, so it has no key to be a catalogue row under. It
/// is kept apart from the catalogue until it has one, so the catalogue never holds a row under a key that will change.
/// `WiFiCameraSource` moves it into the catalogue at the first connection.
public struct PendingWiFiCamera: Sendable, Hashable, Codable {
    public var guid: UUID
    public var peripheral: UUID?
    /// "host:port", for a typed-address camera.
    public var typedAddress: String?

    public init(guid: UUID, peripheral: UUID? = nil, typedAddress: String? = nil) {
        self.guid = guid
        self.peripheral = peripheral
        self.typedAddress = typedAddress
    }
}

/// Where cameras paired but not yet connected are remembered between launches.
public protocol PendingWiFiCameraStore: Sendable {
    func load() -> [PendingWiFiCamera]
    func save(_ cameras: [PendingWiFiCamera])
}

/// The store in memory: for tests and previews.
public final class InMemoryPendingWiFiCameraStore: PendingWiFiCameraStore, @unchecked Sendable {
    private let lock = NSLock()
    private var cameras: [PendingWiFiCamera]

    public init(_ cameras: [PendingWiFiCamera] = []) { self.cameras = cameras }

    public func load() -> [PendingWiFiCamera] { lock.withLock { cameras } }
    public func save(_ cameras: [PendingWiFiCamera]) { lock.withLock { self.cameras = cameras } }
}

/// The store in `UserDefaults`, as one JSON value. Foundation only. (`UserDefaults` is thread-safe, hence
/// `@unchecked Sendable`.) A value that doesn't decode reads as no cameras: the person pairs again.
public final class UserDefaultsPendingWiFiCameraStore: PendingWiFiCameraStore, @unchecked Sendable {
    public static let key = "pendingWiFiCameras"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> [PendingWiFiCamera] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([PendingWiFiCamera].self, from: data)) ?? []
    }

    public func save(_ cameras: [PendingWiFiCamera]) {
        if cameras.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(cameras) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// What `WirelessSession` offers the app, as a protocol so the source and the models are tested on Linux against a fake.
/// `WirelessSession` is the real one.
public protocol WirelessControlling: Sendable {
    /// Every change of phase; each read starts with the current phase.
    nonisolated var phases: AsyncStream<WirelessPhase> { get }
    /// How long the stay has left now; nil when not staying.
    var stayRemaining: Duration? { get async }
    /// The camera network's name while joined (for the catalogue, so the configuration can be removed after a crash).
    var network: String? { get async }
    /// The peripheral the last Bluetooth connection reached (for the catalogue).
    var peripheral: PeripheralID? { get async }
    /// Where the session is now (the source hands out a cached link only while this is `.ready`).
    var phase: WirelessPhase { get async }
    func prepareImport() async throws(WirelessFailure) -> any CameraLink
    func importFinished() async
    func appMovedToBackground() async
    func appBecameActive() async
    func leave() async
}

extension WirelessSession: WirelessControlling {}

/// What the app's live composition (W16) gives the source: a session per camera on its own network, and a way to open a
/// typed-address camera on the phone's network.
public protocol WiFiConnecting: Sendable {
    /// The camera's session: Bluetooth, the join, the stay and the leave (`WirelessSession`). Called once per camera;
    /// the source keeps it. The app's `openLink` for it should call `WiFiCameraSource.observe(_:for:)` with the new link
    /// before opening it, so the Local Network wait is seen, and give `IPLink.Configuration` the entry's `guid`.
    func session(for camera: WiFiCameraEntry) -> any WirelessControlling
    /// Opens the camera at a typed address (the phone is already on its network: no Bluetooth and no join), returning an
    /// open link. The same `observe` rule applies.
    func openTyped(_ address: TypedCameraAddress, for camera: WiFiCameraEntry) async throws(CameraLinkFailure)
        -> any CameraLink
}

/// What the source reports about a connection, for `WiFiImportModel`.
public enum WiFiConnectionEvent: Sendable, Equatable {
    /// A connection was begun for the camera (after the Local Network explanation, if one was due): earlier failures
    /// and notes no longer apply.
    case connecting(CameraDescriptor.ID)
    /// The camera's session changed phase. `stayRemaining` is read at the change into `.staying`.
    case phase(CameraDescriptor.ID, WirelessPhase, stayRemaining: Duration?)
    /// Connecting failed.
    case failed(CameraDescriptor.ID, WirelessFailure)
    /// The camera's link reported an event (`WiFiCameraSource.observe`).
    case link(CameraDescriptor.ID, CameraLinkEvent)
}

/// Where a connection event comes from (`WiFiCameraSource`), so `WiFiImportModel` is tested against a fake.
public protocol WiFiConnectionSource: Sendable {
    nonisolated var connectionEvents: AsyncStream<WiFiConnectionEvent> { get }
}
