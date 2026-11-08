// The characteristics of service 8000CC00 that the spike's Wi-Fi hand-off touched.

import Foundation

/// A characteristic inside `SonyService.cameraControl`, by its 16-bit code (`0000CC06-CC00-FFFF-FFFF-FFFFFFFFFFFF`).
///
/// Presence: the spike found CC06 to CC0C in service 8000CC00 on the α7C II (3 Nov 00:04, the first Wi-Fi hand-off run;
/// spike-findings.md, *BLE advertisement*). The service has 80 characteristics, 13 of them notifiable (CC03, CC09, CC0E, CC0F,
/// CC10, CC19, CC20, CC21, CC61, CC71, CCA1, CCA5, CCA9: measured, 3 Nov). The roles below say what the spike measured
/// and what rests on the notes.
public enum CameraControlCharacteristic: UInt16, CaseIterable, Sendable {
    /// CC03: push transfer (unverified: the notes). One of Sony's five notifications.
    case pushTransfer = 0xCC03
    /// CC06: the camera's Wi-Fi network name. Read; 24 bytes on the α7C II (a 3-byte prefix and a 21-character name
    /// beginning `DIRECT-`: measured, 3 Nov and 5 Nov). **Never logged, displayed, stored or put on the pasteboard.**
    /// Refused with ATT error 0x9D while the camera's Wi-Fi is off (measured, 5 Nov 02:21).
    case ssid = 0xCC06
    /// CC07: the network password. Read; 11 bytes (the 3-byte prefix and an 8-character password: measured). **Never logged,
    /// displayed, stored or put on the pasteboard.** Refused like CC06 while the Wi-Fi is off.
    case passphrase = 0xCC07
    /// CC08: "Wi-Fi on". Write 0x01 with response (see `CameraControlWrite.wifiOn`).
    case wifiOn = 0xCC08
    /// CC09: status. Read and notify; entries as decoded by `SonyStatusEntries` (measured, 3 Nov 11:35 and later).
    case status = 0xCC09
    /// CC0A: firmware version, ASCII; "2.01" on the α7C II (measured, 3 and 5 Nov).
    case firmware = 0xCC0A
    /// CC0B: model name, ASCII; "ILCE-7CM2" on the α7C II (measured, 3 Nov).
    case modelName = 0xCC0B
    /// CC0C: the BSSID. Read, optional; present and MAC-shaped on the α7C II (measured, 3 Nov: only "present, MAC-shaped"
    /// was logged). **Never logged beyond that.**
    case bssid = 0xCC0C
    /// CC0E: initial setting (unverified: the notes). One of Sony's five notifications.
    case initialSetting = 0xCC0E
    /// CC0F: media (unverified: the notes). One of Sony's five notifications.
    case media = 0xCC0F
    /// CC10: battery (unverified: the notes). One of Sony's five notifications.
    case battery = 0xCC10
    /// CCAB: the Wi-Fi band, "Wi-Fi Freq: 2.4GHz / 5GHz status" (unverified: the notes). Read as `04 00 00 02 03` with the
    /// camera's menu on 5 GHz (measured, 3 Nov 22:44): one entry, tag 0x0000, value 02 03. One menu setting gives one point,
    /// so the mapping stays unverified; 1.0 doesn't need it.
    case wifiBand = 0xCCAB

    /// The four hex digits, upper case: "CC06".
    public var code: String {
        let hex = String(rawValue, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }

    public var uuid: UUID {
        SonyBluetooth.uuid(prefix: [0x00, 0x00, UInt8(rawValue >> 8), UInt8(rawValue & 0xFF)],
                           tail: SonyBluetooth.sonyTail)
    }

    /// The characteristic a UUID names (Sony's long form or the Bluetooth base form), or nil.
    public init?(uuid: UUID) {
        guard let code = SonyBluetooth.shortCode(of: uuid), let match = Self(rawValue: code) else { return nil }
        self = match
    }

    /// The characteristic a four-digit code names ("CC06", any case), or nil for anything else (never traps).
    public init?(code: String) {
        // Four hex digits exactly: UInt16(_:radix:) would also take a leading "+".
        guard code.utf8.count == 4, code.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }),
              let value = UInt16(code, radix: 16), let match = Self(rawValue: value) else { return nil }
        self = match
    }

    /// CC06, CC07 and CC0C: never read by a diagnostics sweep, never logged in any form but lengths and yes/no (measured
    /// rule of the spike, `SonyWiFiHandover.secretCodes`).
    public var isSecret: Bool {
        Self.secret.contains(self)
    }

    public static let secret: Set<CameraControlCharacteristic> = [.ssid, .passphrase, .bssid]

    /// What Sony's app subscribes to, as the notes report it (unverified): CC09, CC10, CC0F, CC03 and CC0E.
    ///
    /// Measured: with all five turned on (each confirmed, 1.4 to 1.7 s), CC08 = 0x01 took CC09's Wi-Fi status 0 → 1 → 2
    /// and it stayed at 2; without them the same write gave 0 → 1 → 0 and no network (3 Nov 00:04 and 11:35). Whether
    /// every one of the five is needed was not tested one by one (unverified).
    public static let sonyNotificationSet: [CameraControlCharacteristic] = [.status, .battery, .media, .pushTransfer, .initialSetting]
}
