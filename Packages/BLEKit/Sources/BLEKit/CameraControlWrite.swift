// The writes the spike sent. One value write, and nothing else in service 8000CC00's characteristics.

import Foundation

/// A write to a characteristic of service 8000CC00: the characteristic and the bytes.
///
/// The spike sent exactly one value write, CC08 = 0x01, after the tester confirmed, and notification subscriptions (the
/// descriptor write iOS makes for `setNotifyValue`): Sony's five (`CameraControlCharacteristic.sonyNotificationSet`, what
/// the hand-off needs), and in build 11's watch runs all 13 notifiable characteristics of 8000CC00, each turned off again
/// and confirmed (measured, 3 Nov 11:35).
/// Never written: EE01 (pairing / power off), FF01 (remote shutter), anything in DD or BB, any CC characteristic's value
/// but CC08's. Anything new gets its own static here, with its evidence, after it has been measured.
public struct CameraControlWrite: Equatable, Sendable {
    public let characteristic: CameraControlCharacteristic
    public let value: Data

    public init(characteristic: CameraControlCharacteristic, value: Data) {
        self.characteristic = characteristic
        self.value = value
    }

    /// CC08 ← 0x01, written with response: switches the camera's Wi-Fi on. Measured: acknowledged in 55 to 88 ms
    /// (spike-findings.md, *BLE advertisement*, 3 to 5 Nov); CC09's Wi-Fi status then went 1 at +0.09 to +0.11 s and 2
    /// at +0.84 to +2.7 s, with Sony's five notifications on beforehand. Without them the status went 0 → 1 → 0 and no
    /// network appeared. The camera's screen shows nothing. Whether other values do anything is unverified (never sent).
    ///
    /// Write it only when the status isn't already 2, and only when the person has chosen to import: an unused switch-on
    /// gives the camera about 50 s of Wi-Fi (measured).
    public static let wifiOn = CameraControlWrite(characteristic: .wifiOn, value: Data([0x01]))
}
