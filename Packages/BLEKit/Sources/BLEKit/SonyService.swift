// The five GATT services the α7C II listed, and the characteristics of service 8000CC00 the spike used.

import Foundation

/// A Sony GATT service, `8000xx00-xx00-FFFF-FFFF-FFFFFFFFFFFF`.
///
/// Measured: the spike listed exactly these five on the real camera (Bluetooth tab › *List services*, 2 Nov 22:59;
/// spike-findings.md, *BLE advertisement*). What each is for comes from the reverse-engineered notes and is
/// unverified, except `cameraControl`, whose hand-off characteristics the spike used (see `CameraControlCharacteristic`).
///
/// The spike read and wrote nothing outside `cameraControl`. Never written: EE01 (pairing / power off), FF01 (remote
/// shutter), anything in DD or BB.
public enum SonyService: UInt8, CaseIterable, Sendable {
    /// 8000FF00: remote shutter (unverified: the notes). Not used.
    case remoteShutter = 0xFF
    /// 8000CC00: "Camera Control" (unverified name: the notes). Carries the Wi-Fi hand-off; about 80 characteristics.
    case cameraControl = 0xCC
    /// 8000DD00: location and time (unverified: the notes). Not used.
    case locationAndTime = 0xDD
    /// 8000EE00: Sony's own pairing (unverified: the notes). Not used.
    case pairing = 0xEE
    /// 8000BB00: not in any source the spike found (unverified). Not used.
    case unidentifiedBB = 0xBB

    public var uuid: UUID {
        SonyBluetooth.uuid(prefix: [0x80, 0x00, rawValue, 0x00],
                           tail: [rawValue, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    /// The service a UUID names, or nil. Compares all sixteen bytes.
    public init?(uuid: UUID) {
        guard let match = Self.allCases.first(where: { $0.uuid == uuid }) else { return nil }
        self = match
    }
}
