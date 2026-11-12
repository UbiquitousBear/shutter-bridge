import CameraTransport
import Catalogue
import Foundation

/// One name per body (D11; Shamil, 12 Nov): the name a camera's Photos album and its Staging folder are given, that its
/// Cameras row and Browse title show, and that History and the cull screen read back from its Camera row. Pure over
/// catalogue rows, so the rule is tested on Linux.
///
/// - **MTP and Wi-Fi:** the model the camera reports ("ILCE-7CM2"): in MTP the device's name, over Wi-Fi the DeviceInfo
///   model `WiFiCameraSource` writes to the Camera row at each connection (and names the descriptor with). A Wi-Fi
///   descriptor made before the camera's first connection still says "Camera", so its row's name is read too.
/// - **MSC:** the camera reports no model (ImageCaptureCore names the device after the card's volume, "Untitled"), so it
///   takes the name of the one named body the catalogue knows (`onlyBodyName(among:)`), when there is exactly one: a
///   one-body owner gets one album and one Staging folder across MSC, MTP and Wi-Fi. With two or more named bodies, or
///   none, it is "Camera", as before.
///
/// Bodies are counted by name, not by key: one body's MTP key (its USB device) and Wi-Fi key (its serial) can't be told
/// to be one body, and two bodies with one name share an album and folder anyway (the risk accepted in D11 (a)).
///
/// The name is written to the key's Camera row as its friendly name (`learn(_:for:in:)`), only when the row doesn't
/// already read as it, so History and the cull screen, which name a key by its row (`HistoryWording.cameraName`), show
/// the name its last album and folder had. No schema change: `friendlyName` has been a column since V1.
public enum CameraNaming {
    /// Whether `key` stands for one body: MTP's device key or Wi-Fi's serial key (`CameraKeys`). A name-hash key (MSC's
    /// volume name, a Wi-Fi camera with no serial, MTP or Remote Shoot without key material) can be shared by bodies,
    /// so its row never names a body here.
    static func namesOneBody(_ key: CameraKey) -> Bool {
        key.rawValue.hasPrefix("usb-device:") || key.rawValue.hasPrefix("wifi-serial:")
    }

    /// The one name the catalogue's bodies have: the names of the rows under one-body keys (`HistoryWording
    /// .cameraName`, "Camera" left out); nil unless exactly one name is left.
    public static func onlyBodyName(among records: [CameraRecord]) -> String? {
        let names = Set(records.lazy.filter { namesOneBody($0.key) }.map(HistoryWording.cameraName)
            .filter { $0 != CamerasWording.genericName })
        return names.count == 1 ? names.first : nil
    }

    /// The name for `descriptor` when the one named body is `onlyBodyName` (nil: none, or several): for the Cameras row
    /// and Browse's title, which have no catalogue read at hand.
    public static func displayName(for descriptor: CameraDescriptor, onlyBodyName: String?) -> String {
        if descriptor.mode == .usb(.massStorage) { return onlyBodyName ?? CamerasWording.genericName }
        return CamerasWording.displayName(for: descriptor)
    }

    /// The camera's name, with every Camera row the catalogue has: in MSC the one named body's (or "Camera"); otherwise
    /// the camera's own name, else its row's (a Wi-Fi descriptor listed before the camera's first connection), else
    /// "Camera".
    public static func name(for descriptor: CameraDescriptor, key: CameraKey?, records: [CameraRecord]) -> String {
        if descriptor.mode == .usb(.massStorage) {
            return displayName(for: descriptor, onlyBodyName: onlyBodyName(among: records))
        }
        let own = CamerasWording.displayName(for: descriptor)
        guard own == CamerasWording.genericName, let key, let row = records.first(where: { $0.key == key }) else {
            return own
        }
        return HistoryWording.cameraName(row)
    }

    /// `name(for:key:records:)` with the catalogue's rows; with no catalogue, or one that can't be read, the name
    /// discovery gives (`CamerasWording.displayName(for:)`).
    public static func name(for descriptor: CameraDescriptor, key: CameraKey?,
                            catalogue: (any CatalogueStore)?) async -> String {
        guard let catalogue, let records = try? await catalogue.cameras() else {
            return CamerasWording.displayName(for: descriptor)
        }
        return name(for: descriptor, key: key, records: records)
    }

    /// Writes `name` to `key`'s Camera row as its friendly name ("Camera" as none), when the row doesn't already read
    /// as `name`: History and the cull screen then show the name the camera's album and folder have. Never under a Wi-Fi
    /// name-hash key, which every camera with that name would share. Returns whether it wrote; a failed write is
    /// dropped (the next import or listing writes again).
    @discardableResult
    public static func learn(_ name: String, for key: CameraKey, in catalogue: (any CatalogueStore)?) async -> Bool {
        guard let catalogue, !CameraKeys.isUnidentifiedWiFi(key) else { return false }
        let friendly = name == CamerasWording.genericName ? "" : name
        do {
            guard HistoryWording.cameraName(try await catalogue.camera(key)) != name else { return false }
            try await catalogue.updateCamera(key) { $0.friendlyName = friendly }
            return true
        } catch {
            return false
        }
    }
}
