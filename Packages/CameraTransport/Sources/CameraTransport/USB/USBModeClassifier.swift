import Foundation

/// Which USB mode a camera is in, from what ImageCaptureCore shows (backlog section 2, *Discover*; decision 7: the
/// transport type decides, never `acceptsPTPCommands`, which says yes even in MSC where no PTP command is answered).
///
/// Pure, so it is unit-tested on Linux; `USBLink` and `USBCameraBrowser` feed it the strings and counts they read.
enum USBModeClassifier {
    /// `ICDevice.transportType` in Image Transfer (MSC), as the spike logged it (1 Nov).
    static let massStorageTransport = "ICTransportTypeMassStorage"
    /// `ICDevice.transportType` in Image Transfer (MTP) and in Remote Shoot (PC Remote), as the spike logged it.
    static let usbTransport = "ICTransportTypeUSB"

    /// The mode discovery reports, before any session is open. `ICTransportTypeUSB` is MTP *or* Remote Shoot, and
    /// nothing tells them apart before the catalogue, so it starts as MTP and `mode(after:provisional:)` refines it.
    /// Nil for a transport the α7C II never showed (an unknown device is not offered as a camera to import from).
    static func provisionalMode(transportType: String?) -> USBMode? {
        switch transportType {
        case massStorageTransport?: .massStorage
        case usbTransport?: .mtp
        default: nil
        }
    }

    /// What a link knows once ImageCaptureCore's catalogue has completed.
    struct CatalogueEvidence: Sendable, Hashable {
        /// Files in `mediaFiles` when the catalogue completed.
        var fileCount: Int
        /// From the open request to the catalogue completing.
        var secondsToComplete: Double
        /// The number of operations in the camera's `GetDeviceInfo`, if a link ever reads it. **Seam, not used
        /// yet:** in PC Remote the spike saw 81 operations with Sony's extension, in MTP 24 and none (one run each).
        /// `USBLink` sends no PTP command in Iteration 1, so this is always nil for now (open point, section 2).
        var deviceInfoOperationCount: Int? = nil
    }

    /// A catalogue that completes "at once" with no files: under this many seconds. PC Remote's completed in 0.03 s;
    /// a cold MTP catalogue costs 149–166 ms a file and a kept one (an app relaunch with the camera plugged in)
    /// came back with 391 files in 0.09 s, so a file count of 0 is what decides, and the time only guards it.
    /// `unverified`: one PC Remote run.
    static let remoteShootCatalogueSeconds = 1.0

    /// Operations above this in `GetDeviceInfo` mean PC Remote (81 seen) rather than MTP (24 seen). `unverified`:
    /// one run each; used only if `deviceInfoOperationCount` is ever filled in.
    static let remoteShootOperationThreshold = 40

    /// The mode once the catalogue is complete. MSC stays MSC. For `ICTransportTypeUSB`, **the rule is `unverified`**
    /// (backlog section 2, open point *Telling MTP from Remote Shoot*): a catalogue that completes at once with 0
    /// files is taken as Remote Shoot (PC Remote), which lists no files (decision 1). An empty card in MTP looks
    /// the same, so the app's copy for this case asks for MSC or MTP without saying the card is empty; the
    /// `GetDeviceInfo` operation count would tell them apart and is the seam for it.
    static func mode(after evidence: CatalogueEvidence, provisional: USBMode) -> USBMode {
        guard provisional != .massStorage else { return .massStorage }
        if let operations = evidence.deviceInfoOperationCount {
            return operations > remoteShootOperationThreshold ? .remoteShoot : .mtp
        }
        if evidence.fileCount == 0 && evidence.secondsToComplete < remoteShootCatalogueSeconds {
            return .remoteShoot
        }
        return .mtp
    }
}

/// Whether the app may read the camera's contents, from `ICDeviceBrowser.requestContentsAuthorization`.
enum USBContentsAccess: String, Sendable, Hashable, CaseIterable {
    case authorised
    case denied
    case restricted
    /// What the iOS 26.1 beta returned without a prompt (forum reports). iOS 27.2 returned `authorized` with no
    /// prompt on the bench, so this is let through: browsing is tried, and a camera that then refuses fails there.
    case notDetermined

    /// Denied and restricted stop discovery with `notAuthorised`; the others go on.
    var allowsBrowsing: Bool {
        switch self {
        case .authorised, .notDetermined: true
        case .denied, .restricted: false
        }
    }
}

/// The camera key's raw material over USB: a seam for an open point (backlog section 2, *How to key the camera in
/// MSC*). It is private data (in MTP the device's UUID string embeds what looks like the camera's USB serial), so
/// `description` never shows it; the catalogue hashes it into its `CameraKey` and never logs or stores it raw.
public struct USBCameraKeyMaterial: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { "usb-camera-key(\(rawValue.count) chars)" }

    /// **Open point.** In MTP: the device's UUID string, provisionally (stable across sessions and replugs on the
    /// bench, as the handles were). In MSC: nil, since the device is named after the card's volume ("Untitled"),
    /// answers no PTP, and whether its UUID (USB ID 0000:0000) carries the serial isn't recorded; week 1 settles a
    /// key both modes can share. In Remote Shoot: nil, as nothing is imported.
    static func material(mode: USBMode, deviceUUID: String?) -> USBCameraKeyMaterial? {
        guard mode == .mtp, let uuid = deviceUUID, !uuid.isEmpty else { return nil }
        return USBCameraKeyMaterial(rawValue: uuid)
    }
}
