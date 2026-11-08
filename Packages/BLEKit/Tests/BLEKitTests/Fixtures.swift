// Bytes the tests share. Nothing here is a capture: no Bluetooth fixture is committed (CC06, CC07 and CC0C must never
// be, and the spike logged the other values masked). The status bytes are built from what spike-findings.md records
// ("CC09's layout on the α7C II"); the network values are synthetic.

import Foundation
@testable import BLEKit

enum Fixtures {
    /// A CC09 read with the Wi-Fi off, as the findings' table lists it: ten tags, 43 bytes.
    /// 0x0001 `00 00`, 0x0002 `01`, 0x0003 `01`, 0x0004 `00 00 00`, 0x0005 `01`, 0x0006 `00`, 0x0007 `00`, 0x0008 `00`,
    /// 0x0009 `00`, 0x000A `01`.
    static let cc09ReadWiFiOff: Data = {
        let entries: [[UInt8]] = [
            [0x04, 0x00, 0x01, 0x00, 0x00],
            [0x03, 0x00, 0x02, 0x01],
            [0x03, 0x00, 0x03, 0x01],
            [0x05, 0x00, 0x04, 0x00, 0x00, 0x00],
            [0x03, 0x00, 0x05, 0x01],
            [0x03, 0x00, 0x06, 0x00],
            [0x03, 0x00, 0x07, 0x00],
            [0x03, 0x00, 0x08, 0x00],
            [0x03, 0x00, 0x09, 0x00],
            [0x03, 0x00, 0x0A, 0x01],
        ]
        return Data(entries.flatMap { $0 })
    }()

    /// One notification: tag 0x0001, value `<status> 00` (the findings' example is `04 00 01 02 00`).
    static func wifiStatusNotification(_ status: UInt8) -> Data {
        Data([0x04, 0x00, 0x01, status, 0x00])
    }

    /// CCAB as read with the menu on 5 GHz (measured, 3 Nov 22:44): tag 0x0000, value `02 03`.
    static let ccABRead = Data([0x04, 0x00, 0x00, 0x02, 0x03])
    /// A CCA1 notification seen while Creators' App was connected (measured, 3 Nov 11:36): tag 0x0000, value `02 01`
    /// (meaning unknown).
    static let ccA1Notification = Data([0x04, 0x00, 0x00, 0x02, 0x01])

    // Synthetic network values: never a real network name or password.
    static let ssid = "DIRECT-ab12:TEST-CAM"
    static let passphrase = "test-pass-1234"
    /// The 3-byte prefix before the text (what it holds is unverified, so any three bytes do).
    static let prefix: [UInt8] = [0x01, 0x02, 0x03]

    static func networkValue(_ text: String, prefix: [UInt8] = Fixtures.prefix, padding: Int = 0) -> Data {
        Data(prefix + Array(text.utf8) + [UInt8](repeating: 0, count: padding))
    }

    /// Entries encoded the way the camera does: [length][tag BE][value].
    static func encode(_ entries: [SonyStatusEntry]) -> Data {
        var out: [UInt8] = []
        for entry in entries {
            out.append(UInt8(2 + entry.value.count))
            out.append(UInt8(entry.tag.rawValue >> 8))
            out.append(UInt8(entry.tag.rawValue & 0xFF))
            out += entry.value
        }
        return Data(out)
    }
}
