/// How the phone reaches a camera.
public enum CameraCarrier: String, Sendable, Hashable, Codable, CaseIterable {
    case usb
    case wifi
}

/// The camera's USB connection mode, as its *Select USB Connect Mode* prompt names them. Live Stream (USB
/// Streaming) is absent because ImageCaptureCore never enumerates it (spike findings).
public enum USBMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Image Transfer (MSC): the card as a mass-storage volume (`ICTransportTypeMassStorage`). No PTP at all.
    case massStorage
    /// Image Transfer (MTP): `ICTransportTypeUSB`; PTP pass-through works once ImageCaptureCore's catalogue ends.
    case mtp
    /// Remote Shoot (PC Remote): also `ICTransportTypeUSB`, but its catalogue completes at once with no files.
    case remoteShoot

    /// The camera's own wording for the mode, for the app's copy.
    public var cameraWording: String {
        switch self {
        case .massStorage: "Image Transfer (MSC)"
        case .mtp: "Image Transfer (MTP)"
        case .remoteShoot: "Remote Shoot (PC Remote)"
        }
    }

    /// Whether files can be imported in this mode. In Remote Shoot ImageCaptureCore lists none, so the app asks
    /// for MSC or MTP instead (decision 1).
    public var listsFiles: Bool { self != .remoteShoot }

    /// The mode the app's copy recommends: MSC lists a card in 7–12 s where MTP takes 65–123 s (decision 7).
    public static let recommended: USBMode = .massStorage
}

/// The mode a camera is connected in. Wi-Fi's routes (the camera's own network, the home network) arrive with
/// `IPLink` in Iteration 3.
public enum CameraMode: Sendable, Hashable, Codable {
    case usb(USBMode)
    case wifi

    public var carrier: CameraCarrier {
        switch self {
        case .usb: .usb
        case .wifi: .wifi
        }
    }
}

/// A camera a link can open, as discovery surfaces it: name, carrier and mode (backlog section 2, *Discover*).
public struct CameraDescriptor: Sendable, Hashable, Identifiable {
    /// The discovering link's handle for this connection. Over USB it comes from the device's UUID string, which in
    /// MTP embeds what looks like the camera's USB serial, so its value never reaches a log: `description` shows
    /// only its length. It is not the catalogue's camera key, which is still an open point in MSC (section 2).
    public struct ID: Sendable, Hashable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public var description: String { "camera-link(\(rawValue.count) chars)" }
    }

    public var id: ID
    /// What the camera calls itself. In MSC this is the card's volume name ("Untitled"), not the model.
    public var name: String
    public var mode: CameraMode

    public var carrier: CameraCarrier { mode.carrier }

    public init(id: ID, name: String, mode: CameraMode) {
        self.id = id
        self.name = name
        self.mode = mode
    }
}
