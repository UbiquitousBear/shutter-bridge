// Sony's Bluetooth identifiers as the spike used them: the company ID in the advertisement, the service UUIDs the
// α7C II listed, and the parsing of a UUID back to its 16-bit code.
//
// Pure Swift and Foundation: no CoreBluetooth, so this builds and tests on Linux. Callers convert CBUUID to
// Foundation's UUID at their boundary with `SonyBluetooth.uuid(bluetoothString: cbuuid.uuidString)`, not with
// `UUID(uuidString:)`: CoreBluetooth reports a 16-bit UUID such as the advertised service 1800 in its short form
// ("1800"), which `UUID(uuidString:)` rejects.
//
// Evidence labels used throughout this package:
//   measured    seen on the α7C II (firmware 2.01) in the spike, with the date and findings section named;
//   unverified  from reverse-engineered notes on Sony's apps (CameraSync's notes on a decompiled Creators' App,
//               SonyCameraKit), or only logged by the spike and never checked against a second source.

import Foundation

public enum SonyBluetooth {
    /// Sony's Bluetooth SIG company identifier, 0x012D. The first two bytes of the camera's manufacturer data, little-endian
    /// (bytes 2D 01). Measured: advertised with the camera on, asleep and off, with and without Creators' App connected,
    /// and after the pairing was removed (spike-findings.md, *BLE advertisement*, 2 and 4 Nov).
    public static let companyID: UInt16 = 0x012D

    /// The only service UUID the camera advertises, 0x1800 (Generic Access), the same on, asleep and off (measured:
    /// *BLE advertisement*, 2 Nov). It isn't Sony-specific, so a scan for it also wakes the app for other devices; confirm the
    /// camera by its stored peripheral identifier or by `companyID` with the name.
    public static let advertisedServiceCode: UInt16 = 0x1800

    /// `advertisedServiceCode` as a Foundation UUID (Bluetooth's base UUID with the 16-bit code in place).
    public static let advertisedService = bluetoothBaseUUID(code: advertisedServiceCode)

    /// A UUID from the text CoreBluetooth's `CBUUID.uuidString` gives: 4 hex digits (a 16-bit code), 8 hex digits (a 32-bit
    /// code), both expanded onto the Bluetooth base UUID, or the 36-character `8-4-4-4-12` form as it is. Hex digits in either
    /// case. Nil for anything else, including signs, spaces and non-ASCII digits. Never traps.
    public static func uuid(bluetoothString text: String) -> UUID? {
        let digits = Array(text.utf8)
        func isHex(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
        switch digits.count {
        case 4, 8:
            // Foundation's UInt32(_:radix:) would also take a leading "+" or "-", so the digits are checked first.
            guard digits.allSatisfy(isHex), let value = UInt32(text, radix: 16) else { return nil }
            let prefix = [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
            return uuid(prefix: prefix, tail: bluetoothBaseTail)
        case 36:
            // Foundation's parser is strict about the layout; the digits are checked here too, so both agree on what is hex.
            for (i, c) in digits.enumerated() {
                if [8, 13, 18, 23].contains(i) { guard c == 0x2D else { return nil } } else { guard isHex(c) else { return nil } }
            }
            return UUID(uuidString: text)
        default:
            return nil
        }
    }

    /// The 16-bit code of a UUID given in one of the two long forms the camera's identifiers take, or nil for any other UUID:
    /// Sony's `0000CC06-CC00-FFFF-FFFF-FFFFFFFFFFFF` (characteristics inside service 8000CC00; the spike's rule) or the
    /// Bluetooth base form `0000CC06-0000-1000-8000-00805F9B34FB`. Never traps.
    public static func shortCode(of uuid: UUID) -> UInt16? {
        let bytes = bytes(of: uuid)
        guard bytes[0] == 0, bytes[1] == 0 else { return nil }
        let tail = Array(bytes[4...])
        guard tail == sonyTail || tail == bluetoothBaseTail else { return nil }
        return UInt16(bytes[2]) << 8 | UInt16(bytes[3])
    }

    /// Bytes 4 to 15 of a characteristic UUID in service 8000CC00: `CC00-FFFF-FFFF-FFFFFFFFFFFF`.
    static let sonyTail: [UInt8] = [0xCC, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    /// Bytes 4 to 15 of a Bluetooth-base UUID: `0000-1000-8000-00805F9B34FB`.
    static let bluetoothBaseTail: [UInt8] = [0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB]

    static func bluetoothBaseUUID(code: UInt16) -> UUID {
        uuid(prefix: [0x00, 0x00, UInt8(code >> 8), UInt8(code & 0xFF)], tail: bluetoothBaseTail)
    }

    /// A UUID from its first four bytes and its last twelve.
    static func uuid(prefix: [UInt8], tail: [UInt8]) -> UUID {
        let b = prefix + tail
        precondition(b.count == 16, "a UUID is 16 bytes")   // internal callers pass constants of 4 and 12 bytes
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func bytes(of uuid: UUID) -> [UInt8] {
        let b = uuid.uuid
        return [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7, b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15]
    }
}
