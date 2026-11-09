import Foundation
import PTPKit

/// What the app reads from a link to know which camera it reached, without a link knowing about the catalogue.
///
/// `IPLink` is one (over Wi-Fi the camera's serial number, from DeviceInfo, is the key material, wireless plan W15).
/// The serial is private: it is handed only to the keying, which hashes it (`CameraKeys`), and is never logged or
/// shown.
public protocol CameraIdentifying: CameraLink {
    /// The camera's serial number when the session's DeviceInfo has given a non-empty one; nil before the first open,
    /// or when the camera reports none (the captured fixture's is zeroed).
    func cameraKeyMaterial() async -> String?
    /// The camera's model name from DeviceInfo ("ILCE-7CM2"), if it has been read.
    func cameraModelName() async -> String?
}

extension IPLink: CameraIdentifying {
    public func cameraKeyMaterial() -> String? {
        guard let serial = deviceInfo?.serialNumber, !serial.isEmpty else { return nil }
        return serial
    }

    public func cameraModelName() -> String? {
        guard let model = deviceInfo?.model, !model.isEmpty else { return nil }
        return model
    }
}
