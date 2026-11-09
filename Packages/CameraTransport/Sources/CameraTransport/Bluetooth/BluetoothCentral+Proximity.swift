#if canImport(CoreBluetooth) && os(iOS)
import BLEKit
import CoreBluetooth
import Foundation

// The proximity scan on the app's one central (Iteration 4, section 11; wireless plan, W17). Compiled only for iOS (CI's
// Xcode 27 job). The rules are pure and tested on Linux: which peripheral is a camera (`ProximityConfirmer`), when to restart
// (`ProximityRestartRules`), and holding reports for a late reader (`HoldingEventFanOut`). Everything here runs on the
// central's queue (the actor's executor), as the rest of `BluetoothCentral` does.
//
// The sequence is the spike's (`Spike/Sources/Bluetooth/ProximityWatcher.swift`, `startScan` 292-316 and the delegate
// 531-562), proven on the bench from 2 to 5 Nov 2026:
// - scan for service 1800 with `CBCentralManagerScanOptionAllowDuplicatesKey: false`, and register connection events for the
//   same service (none ever arrived; not relied on);
// - when iOS relaunches the app and hands the scan back (`willRestoreState`, scan services [1800]), keep it at the next
//   `poweredOn` instead of stopping and restarting it: the discovery that woke the app can still be queued behind that callback;
// - start the scan again when Bluetooth comes back on (5 Nov 02:17: the camera was reported 0.03 s later).
// No manufacturer data, name or identifier is logged here (nothing here logs at all).

extension BluetoothCentral: ProximityScanning {
    /// Every report while the proximity scan runs, unconfirmed: a peripheral advertising service 1800 (with its manufacturer
    /// data, name and RSSI), or a `peerConnected` connection event. Without duplicates, iOS reports each peripheral about once
    /// per scan. Meant for one reader (the proximity model); reports that arrive while nobody is reading (the 70 ms between a
    /// relaunch and the camera's report, 5 Nov) are held, the newest 16, for the next reader.
    public nonisolated var proximityReports: AsyncStream<ProximityReport> { proximityFan.subscribe() }

    /// What iOS handed back in `willRestoreState` when it relaunched the app for this central: a new stream on every access,
    /// starting with this launch's hand-back if it has happened, then any later one. Nothing when iOS didn't relaunch the app.
    public nonisolated var restored: AsyncStream<RestoredState> {
        let source = restoredFan.subscribe()
        return AsyncStream { continuation in
            let task = Task {
                for await state in source {
                    if let state { continuation.yield(state) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Makes sure the scan for service 1800 runs, and keeps it running while it is wanted: it starts when Bluetooth is on (at
    /// once, or when Bluetooth reports `poweredOn`), again whenever Bluetooth comes back on, and again after a connect's scan.
    /// A running scan is kept, including the one iOS handed back after a relaunch. Making the central may show the Bluetooth
    /// permission prompt (`shared()`); calling this doesn't.
    public func startProximityScan() {
        proximityWanted = true
        guard manager.state == .poweredOn, !broker.isWaiting(.scan), !proximityScanning else { return }
        issueProximityScan()
    }

    /// Stops the scan and starts it again, so every camera in range is reported afresh (`ProximityRestartRules` decides when).
    /// While Bluetooth is off, or a connect's scan runs, the scan starts when that ends instead (a scan iOS handed back is
    /// given up, and a fresh one starts at `poweredOn`).
    public func restartProximityScan() {
        proximityWanted = true
        restoredProximityScan = false
        guard manager.state == .poweredOn, !broker.isWaiting(.scan) else {
            proximityScanning = false
            return
        }
        issueProximityScan()
    }

    /// Stops the proximity scan and its connection events; it no longer starts by itself. A connect's scan that is running
    /// carries on, and the proximity scan doesn't start after it.
    public func stopProximityScan() {
        proximityWanted = false
        restoredProximityScan = false
        let wasScanning = proximityScanning
        proximityScanning = false
        // Core Bluetooth accepts commands only while it is on; when it isn't, there is no scan or registration to stop.
        guard manager.state == .poweredOn else { return }
        if wasScanning, !broker.isWaiting(.scan) { manager.stopScan() }
        // `stopScan` leaves the connection-event registration in place, so it is swapped for one no peer can match (the
        // spike's way; Core Bluetooth has no call to unregister).
        manager.registerForConnectionEvents(options: [.serviceUUIDs: [CBUUID(nsuuid: UUID())]])
    }

    // MARK: From the central (its queue)

    /// Service 1800 exactly as the spike scanned for it, `CBUUID(string: "1800")` (`ProximityWatcher.serviceUUID(from:)`):
    /// the short form, so the scan and its restoration are the bench's byte for byte.
    static func proximityService() -> CBUUID {
        let hex = String(SonyBluetooth.advertisedServiceCode, radix: 16, uppercase: true)
        return CBUUID(string: String(repeating: "0", count: max(0, 4 - hex.count)) + hex)
    }

    /// Starts the scan for 1800, replacing any scan of this central's (Core Bluetooth runs one per central, and starting it
    /// again resets which peripherals it has reported). Only while Bluetooth is on and no connect's scan is running.
    func issueProximityScan() {
        let service = Self.proximityService()
        manager.stopScan()
        manager.scanForPeripherals(withServices: [service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        manager.registerForConnectionEvents(options: [.serviceUUIDs: [service]])
        proximityScanning = true
        restoredProximityScan = false
    }

    /// `willRestoreState`: iOS relaunched the app and hands back what it kept. A scan for 1800 is running now, so its
    /// discoveries are reports from here on, and the next `poweredOn` keeps it.
    func proximityRestored(_ state: RestoredState) {
        if state.includesProximityScan {
            proximityScanning = true
            restoredProximityScan = true
        }
        restoredFan.send(state)
    }

    /// Bluetooth reported `poweredOn`: keep a scan iOS handed back (re-registering the connection events, as the spike did), or
    /// start the scan if it is wanted and not running. A connect waiting for the power starts its own scan later, and the
    /// proximity scan starts again after it.
    func proximityPoweredOn() {
        guard !broker.isWaiting(.scan) else { return }
        if restoredProximityScan {
            restoredProximityScan = false
            proximityScanning = true
            manager.registerForConnectionEvents(options: [.serviceUUIDs: [Self.proximityService()]])
            return
        }
        if proximityWanted, !proximityScanning { issueProximityScan() }
    }

    /// Bluetooth left `poweredOn` (off, resetting, no longer allowed): iOS has ended the scan. A restored scan that hasn't been
    /// kept yet is gone too.
    func proximityPoweredDown() {
        proximityScanning = false
        restoredProximityScan = false
    }

    /// A discovery while no connect's scan is waiting: a report, if the proximity scan is running and the peripheral isn't
    /// one this app is connecting to, connected to or disconnecting from (a discovery still queued from the connect's
    /// unfiltered scan can be the camera it found).
    func proximityDiscovered(_ id: UUID, manufacturerData: Data?, name: String?, rssi: Int) {
        guard proximityScanning, !isOwnConnection(id) else { return }
        proximityFan.send(ProximityReport(peripheral: PeripheralID(id), at: Date(),
                                          rssi: ProximityReport.rssi(fromCoreBluetooth: rssi),
                                          manufacturerData: manufacturerData, name: name))
    }

    /// A connection event: a `peerConnected` is a report (without an advertisement, so only the stored identifier confirms it).
    /// A disconnect says nothing about arrival, and neither does this app's own connection to the camera (every GATT database
    /// has Generic Access, so the registration for 1800 matches it).
    func proximityConnectionEvent(_ id: UUID, name: String?, peerConnected: Bool) {
        guard peerConnected, proximityScanning, !isOwnConnection(id) else { return }
        proximityFan.send(ProximityReport(peripheral: PeripheralID(id), at: Date(), rssi: nil, advertisement: nil,
                                          name: name, source: .connectionEvent))
    }
}
#endif
