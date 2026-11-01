// REQUIREMENT (from Shamil, 1 Nov 2026): the owner's α7C II has Bluetooth on and is paired with Sony's
// Creators' App on the iPhone for regular transfers. A peripheral that is bonded and connected to another app
// often stops advertising (or advertises differently), so the day-6 capture and the proximity go/no-go must
// cover that real setup, not only a free-advertising camera:
//
// 1. Pairing context is a second dimension next to power state (on / asleep / off): "Creators' App connected"
//    (the normal setup), "Creators' App quit / phone Bluetooth link down", and "not paired" if it is tested.
//    Snapshots record it and are named ble/advert-<on|asleep|off>-<connected|unlinked|unpaired>.json.
// 2. Scanning alone cannot see a camera that another app holds. Also call
//    CBCentralManager.retrieveConnectedPeripherals(withServices:) — documented to include peripherals other
//    apps connected — for every service UUID seen so far plus the chosen proximity UUID, log what it returns,
//    and include it in the snapshot; record log.flag("ble.connected.<state>.seen", …).
// 3. ProximityWatcher: besides the filtered background scan, call
//    registerForConnectionEvents(options: [.serviceUUIDs: [uuid]]) and log every
//    centralManager(_:connectionEventDidOccur:for:) (peerConnected / peerDisconnected) with the app state, post
//    the same test notification on peerConnected, and record ble.proximity.connectionEvent.latency [s] from
//    "Camera switched on now". Whether these events reach a suspended app is unknown: that is a spike question.
//    This could be the better 1.0 proximity signal: when the camera comes near, Creators' App reconnects to
//    it and the phone sees the connection, with no advertising and no Sony GATT traffic on our side.
// 4. If no service UUID is advertised in the paired setup, offer an explicitly experimental "List services"
//    action (connect, discoverServices(nil), log service UUIDs only, disconnect; no characteristic reads or
//    writes) so the proximity filter UUID can still be found. Warn in the UI that it opens a GATT connection.

import Foundation
import Observation
import CoreBluetooth

/// Day 6 (BLE): what does the α7C II advertise, and when? Foreground scan with no service filter so we can see
/// everything; the production app will filter on the service UUID this scan reveals. Sony's Bluetooth SIG
/// company identifier is 0x012D, which is how we pick the camera out of the room.
@Observable
@MainActor
final class AdvertisementScanner: NSObject {
    struct Seen: Identifiable {
        let id: UUID
        var name: String
        var rssi: Int
        var serviceUUIDs: [String]
        var manufacturerHex: String
        var isSony: Bool
        var count: Int
        var lastSeen: Date
    }

    private var central: CBCentralManager?
    private(set) var seen: [UUID: Seen] = [:]
    private(set) var state = "off"
    private(set) var filterToSony = true
    var log: SpikeLog?

    static let sonyCompanyID: UInt16 = 0x012D

    func start(sonyOnly: Bool = true) {
        filterToSony = sonyOnly
        seen.removeAll()
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        } else {
            beginScan()
        }
    }

    func stop() {
        central?.stopScan()
        state = "stopped"
        log?.note("BLE scan stopped; \(seen.count) peripherals seen")
        for s in seen.values.sorted(by: { $0.rssi > $1.rssi }) where s.isSony || !filterToSony {
            log?.note("  \(s.name) rssi=\(s.rssi) services=\(s.serviceUUIDs) mfg=\(s.manufacturerHex) x\(s.count)")
        }
    }

    private func beginScan() {
        guard central?.state == .poweredOn else { return }
        // No service filter here on purpose: the production filter UUID is what this scan is meant to discover.
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        state = "scanning"
        log?.note("BLE scanning (all services). Try: camera on → asleep → powered off with Remote Power ON/OFF enabled.")
    }
}

extension AdvertisementScanner: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: state = "powered on"; beginScan()
        case .poweredOff: state = "Bluetooth off"
        case .unauthorized: state = "unauthorized"; log?.error("Bluetooth permission denied")
        case .unsupported: state = "unsupported"
        default: state = "\(central.state.rawValue)"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        var isSony = false
        if let mfg, mfg.count >= 2 {
            let company = UInt16(mfg[mfg.startIndex]) | UInt16(mfg[mfg.startIndex + 1]) << 8
            isSony = company == Self.sonyCompanyID
        }
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "(no name)"
        if filterToSony, !isSony, !name.lowercased().contains("ilce"), !name.lowercased().contains("sony") { return }

        var entry = seen[peripheral.identifier] ?? Seen(id: peripheral.identifier, name: name, rssi: RSSI.intValue, serviceUUIDs: services, manufacturerHex: mfg?.hexDump(limit: 32) ?? "-", isSony: isSony, count: 0, lastSeen: Date())
        if entry.count == 0 {
            log?.note("BLE: \(name) rssi=\(RSSI) services=\(services) mfg=\(mfg?.hexDump(limit: 32) ?? "-") sony=\(isSony)")
        }
        entry.rssi = RSSI.intValue
        entry.count += 1
        entry.lastSeen = Date()
        entry.serviceUUIDs = services.isEmpty ? entry.serviceUUIDs : services
        seen[peripheral.identifier] = entry
    }
}
