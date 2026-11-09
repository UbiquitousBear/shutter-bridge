// The values the proximity scan speaks in (Iteration 4, section 11; wireless plan, W17): what the scan reports, what iOS hands
// back when it relaunches the app, and the app's cameras as the confirmation sees them. Pure, so the rules that use them are
// tested on Linux; `BluetoothCentral` (Apple-only) makes them from Core Bluetooth's callbacks.
//
// Nothing here prints a peripheral identifier, a name or manufacturer data: the identifier is a device identifier, and the
// manufacturer data may identify the camera (backlog section 11, "The manufacturer data isn't logged").

import BLEKit
import Foundation

/// One sighting from the proximity scan: a peripheral advertising service 1800 (Generic Access), or a connection event for
/// one. Unconfirmed: anything advertising 1800 is reported, and `ProximityConfirmer` decides whether it is one of the app's
/// cameras.
///
/// Prints its source and signal strength only: `peripheral` prints redacted, and `name` and `advertisement` are never shown.
public struct ProximityReport: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    /// What iOS reported.
    public enum Source: Sendable, Equatable {
        /// `didDiscover` from the scan for service 1800.
        case advertisement
        /// `connectionEventDidOccur` with `peerConnected` (registered with the scan, never relied on: no run that armed one
        /// received one, backlog section 11). It carries no advertisement, so only the stored identifier can confirm it.
        case connectionEvent
    }

    public let peripheral: PeripheralID
    /// When the app received it (wall clock, so the restart rules count across a suspension).
    public let at: Date
    /// The signal strength in dBm, or nil when iOS had none (Core Bluetooth's 127, and every connection event). Measured for
    /// the camera: −48 to −83 dBm (4 to 5 Nov).
    public let rssi: Int?
    /// The manufacturer data, split into company ID and payload, if the advertisement had any of at least 2 bytes. Never
    /// logged (its own `description` shows only the company and the payload's length).
    public let advertisement: SonyAdvertisement?
    /// The peripheral's name, or the advertisement's local name, if iOS had one. Used only to confirm; never logged.
    public let name: String?
    public let source: Source

    public init(peripheral: PeripheralID, at: Date, rssi: Int?, advertisement: SonyAdvertisement?, name: String?,
                source: Source = .advertisement) {
        self.peripheral = peripheral
        self.at = at
        self.rssi = rssi
        self.advertisement = advertisement
        self.name = name
        self.source = source
    }

    /// A report from the scan, with the manufacturer data as Core Bluetooth gave it
    /// (`CBAdvertisementDataManufacturerDataKey`). Data under 2 bytes counts as none.
    public init(peripheral: PeripheralID, at: Date, rssi: Int?, manufacturerData: Data?, name: String?) {
        self.init(peripheral: peripheral, at: at, rssi: rssi,
                  advertisement: manufacturerData.flatMap { try? SonyAdvertisement(manufacturerData: $0) },
                  name: name, source: .advertisement)
    }

    /// Core Bluetooth's RSSI as the report keeps it: 127 means "not available" (Apple's documented value), so it is nil.
    public static func rssi(fromCoreBluetooth value: Int) -> Int? {
        value == 127 ? nil : value
    }

    public var description: String {
        let what = source == .advertisement ? "advertisement" : "connection event"
        let strength = rssi.map { "RSSI \($0) dBm" } ?? "no RSSI"
        return "proximity report (\(what), \(strength); identifier, name and manufacturer data not shown)"
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["redacted": description], displayStyle: .struct) }
}

/// What iOS handed back in `willRestoreState` when it relaunched the app for the central (backlog section 11, state
/// restoration). A scene-based app gets no launch options, so this is how the app learns it was relaunched for Bluetooth.
///
/// Measured once (5 Nov 22:26, after the app killed itself): the scan for 1800 and no peripherals; the camera was reported
/// 70 ms after the launch. A relaunch after iOS ends a suspended app, after a swipe-away or after a reboot is untested.
public struct RestoredState: Sendable, Equatable, CustomStringConvertible {
    /// The services of the scan iOS kept running for the app (`CBCentralManagerRestoredStateScanServicesKey`), as full UUIDs.
    public let scanServices: [UUID]
    /// The peripherals iOS kept connected or pending for the app (`CBCentralManagerRestoredStatePeripheralsKey`).
    public let peripherals: [PeripheralID]

    public init(scanServices: [UUID], peripherals: [PeripheralID]) {
        self.scanServices = scanServices
        self.peripherals = peripherals
    }

    /// Whether the scan iOS handed back is the proximity scan (service 1800). The central keeps that scan running rather than
    /// restart it, so the discovery that woke the app isn't lost (the spike's rule, `ProximityWatcher` 536-543).
    public var includesProximityScan: Bool { scanServices.contains(SonyBluetooth.advertisedService) }

    public var description: String {
        "restored state (\(includesProximityScan ? "proximity scan" : "no proximity scan"), \(peripherals.count) peripherals)"
    }
}

/// One of the app's cameras as the proximity confirmation sees it. CameraTransport doesn't depend on Catalogue, so the app
/// builds these from its `CameraRecord`s: the key, the stored peripheral identifier and the model name.
///
/// Prints its model and whether an identifier is stored only: the key (a USB camera's is its serial number) and the
/// identifier are never shown, by `dump` or a mirror either.
public struct KnownCamera: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The app's key for the camera (Catalogue's `CameraKey.rawValue`). Opaque here and never printed.
    public let key: String
    /// The peripheral identifier stored at onboarding (backlog section 6), if the camera has been set up over Bluetooth.
    public let peripheral: PeripheralID?
    /// The camera's model name from DeviceInfo ("ILCE-7CM2"), or empty when no link has read it. The α7C II advertises the
    /// same string as its Bluetooth name (measured: CC0B and the pairing screen).
    public let model: String

    public init(key: String, peripheral: PeripheralID?, model: String) {
        self.key = key
        self.peripheral = peripheral
        self.model = model
    }

    public var description: String {
        "known camera (\(model.isEmpty ? "no model" : model), \(peripheral == nil ? "no identifier" : "identifier stored"))"
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["redacted": description], displayStyle: .struct) }
}
