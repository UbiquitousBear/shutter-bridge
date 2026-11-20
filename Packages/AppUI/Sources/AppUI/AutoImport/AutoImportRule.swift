import CameraTransport
import Catalogue
import Foundation

/// Whether auto-import is on for a camera (backlog section 14), by one name per body (D11).
enum AutoImportDecision: Sendable, Hashable {
    case on
    case off
    /// "Camera": MSC with no single named body, or a camera never named.
    case noName
    /// `CameraKeys.isUnidentifiedWiFi(key)`: a Wi-Fi camera with no key of its own, which Browse never imports under.
    case unidentified
    /// `.usb(.remoteShoot)`: a guard only, since USB discovery reports Remote Shoot as MTP until the card is listed.
    case remoteShoot
    /// The catalogue couldn't be read: treated as off.
    case unreadable

    /// The log's words for a decision that isn't `.on`.
    var logWords: String {
        switch self {
        case .on: "on"
        case .off: "off for this camera"
        case .noName: "no camera name (MSC with no single named camera, or never named)"
        case .unidentified: "no key of its own"
        case .remoteShoot: "Remote Shoot"
        case .unreadable: "the catalogue couldn't be read"
        }
    }
}

/// One camera in Settings › *Import When Connected*: a body by its name (D11), and whether its switch is on.
public struct AutoImportChoice: Sendable, Hashable, Identifiable {
    public var name: String
    public var isOn: Bool
    public var id: String { name }

    public init(name: String, isOn: Bool) {
        self.name = name
        self.isOn = isOn
    }
}

/// Auto-import's setting over the catalogue's Camera rows (backlog section 14; D11: one body has MSC, MTP and Wi-Fi keys
/// and one name). Pure, so the rule is tested on Linux.
///
/// - The setting lives in `CameraRecord.autoImport`, written only on one-body keys (`CameraNaming.namesOneBody`:
///   `usb-device:` and `wifi-serial:`) whose row reads as the body's name (`HistoryWording.cameraName`). A key shared by
///   bodies (`usb-msc-name:`, `usb-mtp-name:`, `usb-remote-shoot-name:`, `wifi-name:`) never holds it.
/// - It is read by name: a camera is on when any one-body row whose name is the camera's D11 name
///   (`CameraNaming.name(for:key:records:)`) has it. A body's key that appears later (its first Wi-Fi key, an MTP link
///   with no key material) follows with no write; MSC follows the one named body (`onlyBodyName`), and with none or
///   several its name is "Camera", which is never on; two bodies of one model share one switch (D11 (a)).
enum AutoImportRule {
    /// Whether auto-import is on for `descriptor`, whose catalogue key is `key` when it is known, over every Camera row.
    static func decision(for descriptor: CameraDescriptor, key: CameraKey?, records: [CameraRecord])
        -> AutoImportDecision {
        if let key, CameraKeys.isUnidentifiedWiFi(key) { return .unidentified }
        if descriptor.mode == .usb(.remoteShoot) { return .remoteShoot }
        let name = CameraNaming.name(for: descriptor, key: key, records: records)
        if name == CamerasWording.genericName { return .noName }
        let on = records.contains { record in
            CameraNaming.namesOneBody(record.key) && record.autoImport && HistoryWording.cameraName(record) == name
        }
        return on ? .on : .off
    }

    /// Settings' rows: one per distinct name among the one-body rows, "Camera" left out, in the catalogue's order (most
    /// recently seen first); on when any row of that name is.
    static func choices(among records: [CameraRecord]) -> [AutoImportChoice] {
        var choices: [AutoImportChoice] = []
        var index: [String: Int] = [:]
        for record in records where CameraNaming.namesOneBody(record.key) {
            let name = HistoryWording.cameraName(record)
            guard name != CamerasWording.genericName else { continue }
            if let at = index[name] {
                if record.autoImport { choices[at].isOn = true }
            } else {
                index[name] = choices.count
                choices.append(AutoImportChoice(name: name, isOn: record.autoImport))
            }
        }
        return choices
    }

    /// The one-body keys whose row reads as `name`: the keys a switch writes.
    static func keys(named name: String, among records: [CameraRecord]) -> [CameraKey] {
        records.filter { CameraNaming.namesOneBody($0.key) && HistoryWording.cameraName($0) == name }.map(\.key)
    }
}
