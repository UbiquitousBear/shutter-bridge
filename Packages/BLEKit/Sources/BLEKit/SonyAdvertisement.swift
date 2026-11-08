// What the spike parsed from the camera's advertisement: the company ID at the front of the manufacturer data.
//
// Measured (spike-findings.md, *BLE advertisement*, 2 Nov): the manufacturer data is Sony's company ID (0x012D, little-endian
// on the wire) and 20 bytes after it, the same with the camera on, asleep and off with Creators' App quit; bytes 6 to 8
// and 12 to 13 of those 20 change while Creators' App is connected. The 20 bytes are not recorded anywhere, because they
// may identify the camera, and the spike only ever logged them as hex. spike-findings.md (*BLE advertisement*, 2 Nov) records
// the advertisement's tag 0x21 as 0xF0, decoded by hand with the notes' tagged layout ("camera on, Wi-Fi handover supported
// and enabled"). The spike's code never parsed it, and the layout is unverified on this body, so `payload` stays raw.

import Foundation

public enum SonyAdvertisementError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Fewer than the 2 bytes of a company ID.
    case tooShort(byteCount: Int)

    public var description: String {
        switch self {
        case .tooShort(let byteCount): "manufacturer data is \(byteCount) byte(s), under the 2 of a company ID"
        }
    }
}

public struct SonyAdvertisement: Equatable, Sendable {
    /// The Bluetooth SIG company identifier at the front of the manufacturer data.
    public let companyID: UInt16
    /// The bytes after the company ID, as received. May identify the camera: never logged (`description` shows the length).
    public let payload: [UInt8]

    /// How many bytes followed the company ID on the α7C II (measured, 2 Nov, all three power states). Not enforced: a
    /// firmware update may change it.
    public static let observedPayloadLength = 20

    /// Splits manufacturer data (the `CBAdvertisementDataManufacturerDataKey` value) into its company ID and payload.
    /// Any company's data decodes; ask `isSony`. Throws only for fewer than 2 bytes.
    public init(manufacturerData: Data) throws {
        let bytes = [UInt8](manufacturerData)
        guard bytes.count >= 2 else { throw SonyAdvertisementError.tooShort(byteCount: bytes.count) }
        companyID = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        payload = Array(bytes[2...])
    }

    public var isSony: Bool { companyID == SonyBluetooth.companyID }

    /// The spike's "camera-like" name rule: "ILCE" or "SONY" anywhere in the name, any case. The α7C II calls itself
    /// "ILCE-7CM2" (CC0B and the pairing screen: measured). "Sony" alone matches any Sony device, so the proximity
    /// reminder confirms by the stored peripheral identifier, or by `isSony` together with this.
    public static func nameLooksLikeCamera(_ name: String?) -> Bool {
        guard let upper = name?.uppercased() else { return false }
        return upper.contains("ILCE") || upper.contains("SONY")
    }
}

/// The payload may identify the camera, so every print shows its length only.
extension SonyAdvertisement: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        let company = String(companyID, radix: 16, uppercase: true)
        return "company 0x" + String(repeating: "0", count: max(0, 4 - company.count)) + company + ", \(payload.count) payload bytes (not shown)"
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["redacted": description], displayStyle: .struct) }
}
