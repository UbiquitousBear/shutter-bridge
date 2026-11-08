// A firmware version string with the place it was read, so two are ordered only when they come from the same
// place. The α7C II reports the same firmware differently by mode: DeviceInfo's DeviceVersion is "2.0" in MTP over
// USB (vendor extension 0xFFFFFFFF; `usb/deviceinfo.bin`) and "2.01" in PC Remote over PTP/IP (Sony's 0x11;
// `ptpip/deviceinfo.bin`), both checked by the `firmwareModes` fixture test. PC Remote over USB also reported 2.01
// (unverified: spike, 4 Nov), and Bluetooth's CC0A reads "2.01" (unverified: spike, 3 and 5 Nov; no Bluetooth
// fixture is committed). Compared across modes, "2.0" < "2.01" would claim an older firmware that isn't there.

import Foundation

public struct PTPFirmwareVersion: Hashable, Sendable, CustomStringConvertible {
    public enum Source: Hashable, Sendable {
        /// DeviceInfo's DeviceVersion, keyed by that DeviceInfo's VendorExtensionID, which tells the camera's
        /// modes apart on the α7C II: 0xFFFFFFFF in MTP over USB and 0x11 in PC Remote over PTP/IP (both from the
        /// DeviceInfo fixtures); 0x11 in PC Remote over USB too (unverified: spike, 4 Nov).
        case deviceInfo(vendorExtensionID: UInt32)
        /// A source outside PTP, named by the caller, e.g. "ble-CC0A" for Sony's Bluetooth firmware characteristic.
        case other(String)
    }

    /// The string as read.
    public let string: String
    public let source: Source

    public init(_ string: String, source: Source) {
        self.string = string
        self.source = source
    }

    /// e.g. "2.01 (DeviceInfo, vendor extension 0x00000011)" or "2.01 (ble-CC0A)".
    public var description: String {
        switch source {
        case .deviceInfo(let id):
            let hex = String(id, radix: 16, uppercase: false)
            return "\(string) (DeviceInfo, vendor extension 0x\(String(repeating: "0", count: max(0, 8 - hex.count)))\(hex))"
        case .other(let name):
            return "\(string) (\(name))"
        }
    }

    /// Orders two versions read from the same source. Returns nil when the sources differ (a cross-mode
    /// comparison is never answered) or when either string isn't "M" or "M.F" in ASCII digits after trimming
    /// spaces. M compares as a whole number, F as a decimal fraction (Sony's "2.01": 2.0 < 2.01 < 2.1 = 2.10),
    /// both digit by digit, so no length of digits can overflow. `==` compares the string as read and its source;
    /// use this for ordering.
    public func compare(_ other: PTPFirmwareVersion) -> ComparisonResult? {
        guard source == other.source, let a = Self.parts(string), let b = Self.parts(other.string) else { return nil }
        let majorA = a.major.drop(while: { $0 == 0x30 })
        let majorB = b.major.drop(while: { $0 == 0x30 })
        if majorA.count != majorB.count { return majorA.count < majorB.count ? .orderedAscending : .orderedDescending }
        if let r = Self.lexicographic(Array(majorA), Array(majorB)) { return r }
        let width = max(a.fraction.count, b.fraction.count)
        let fracA = a.fraction + [UInt8](repeating: 0x30, count: width - a.fraction.count)
        let fracB = b.fraction + [UInt8](repeating: 0x30, count: width - b.fraction.count)
        return Self.lexicographic(fracA, fracB) ?? .orderedSame
    }

    /// nil when equal.
    private static func lexicographic(_ a: [UInt8], _ b: [UInt8]) -> ComparisonResult? {
        for (x, y) in zip(a, b) where x != y { return x < y ? .orderedAscending : .orderedDescending }
        return nil
    }

    private static func parts(_ string: String) -> (major: [UInt8], fraction: [UInt8])? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2 else { return nil }
        var bytes: [[UInt8]] = []
        for piece in pieces {
            let utf8 = Array(piece.utf8)
            guard !utf8.isEmpty, utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
            bytes.append(utf8)
        }
        return (bytes[0], bytes.count == 2 ? bytes[1] : [])
    }
}

extension PTPDeviceInfo {
    /// `deviceVersion` tagged with this DeviceInfo's vendor extension ID: MTP's "2.0" and PC Remote's "2.01"
    /// never compare (`firmwareModes`, on `usb/deviceinfo.bin` and `ptpip/deviceinfo.bin`).
    public var firmwareVersion: PTPFirmwareVersion {
        PTPFirmwareVersion(deviceVersion, source: .deviceInfo(vendorExtensionID: vendorExtensionID))
    }
}
