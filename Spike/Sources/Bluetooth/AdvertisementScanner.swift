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
//    and include it in the snapshot; record log.flag("ble.connected.<state>.<pairing>.seen", …) for the camera.
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
//
// Where each item lives: (1) PairingContext and saveSnapshot (both advert-<state>.json, the name Fixtures/README
// uses, and advert-<state>-<pairing>.json are written); (2) checkConnected, run by "Check connected" and by every
// snapshot; (3) ProximityWatcher; (4) listServices, the Experimental · GATT section of the Bluetooth tab.

import Foundation
import Observation
import CoreBluetooth

/// Day 6 (BLE): what does the α7C II advertise, and when? Foreground scan with duplicates and no service filter
/// so every packet and every advertisement key is seen; the production app (and ProximityWatcher) filters on the
/// service UUID this scan reveals. Sony's Bluetooth SIG company identifier is 0x012D, which is how the camera is
/// picked out of the room, along with a name containing "ILCE" or "Sony", or a row the user marks as the camera.
@Observable
@MainActor
final class AdvertisementScanner: NSObject {
    enum PowerState: String, CaseIterable, Identifiable {
        case on, asleep, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .on: return "On"
            case .asleep: return "Asleep"
            case .off: return "Off"
            }
        }
    }

    /// Requirement 1: the second dimension next to power state.
    enum PairingContext: String, CaseIterable, Identifiable {
        case connected, unlinked, unpaired
        var id: String { rawValue }
        var label: String {
            switch self {
            case .connected: return "Creators' App connected"
            case .unlinked: return "Creators' App quit, link down"
            case .unpaired: return "Not paired"
            }
        }
    }

    /// Running statistics for one peripheral during a scan.
    struct Stats {
        let id: UUID
        var name: String
        var localName: String?
        var companyID: UInt16?
        var nameLooksLikeCamera: Bool
        var count = 0
        var rssiSamples = 0
        var rssiSum = 0
        var rssiMin = Int.max
        var rssiMax = Int.min
        var firstSeen: Date
        var lastSeen: Date
        var lastInstant: ContinuousClock.Instant
        var gapsMs: [Double] = []
        /// Callbacks under 20 ms after the previous one (a scan response or repeat in the same advertising event):
        /// not counted as gaps, since advertising events are at least 20 ms apart.
        var shortGapsMerged = 0
        var serviceUUIDs: Set<String> = []
        var overflowUUIDs: Set<String> = []
        var solicitedUUIDs: Set<String> = []
        var serviceDataHex: [String: String] = [:]
        var manufacturerHex: String?
        var manufacturerVariants: [String] = []
        var txPower: Int?
        var connectable: Bool?
        var keys: Set<String> = []

        var rssiAverage: Double? { rssiSamples > 0 ? Double(rssiSum) / Double(rssiSamples) : nil }
        var medianIntervalMs: Double? {
            guard !gapsMs.isEmpty else { return nil }
            let sorted = gapsMs.sorted()
            let mid = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
        }
    }

    /// What the list shows; rebuilt once a second so a busy room doesn't redraw the list on every packet.
    struct Row: Identifiable {
        let id: UUID
        let name: String
        let isCamera: Bool
        let isMarked: Bool
        let count: Int
        let rssiAverage: Double?
        let rssiMin: Int?
        let rssiMax: Int?
        let intervalMs: Double?
        let serviceUUIDs: [String]
        let overflowUUIDs: [String]
        let solicitedUUIDs: [String]
        let serviceData: [String]
        let manufacturerHex: String?
        let companyID: String?
        let txPower: Int?
        let connectable: Bool?
        let lastSeen: Date
        let gattServices: [String]?
    }

    /// One peripheral in the day-6 fixture (ble/advert-<state>.json).
    struct PeripheralRecord: Codable {
        let identifier: String
        let name: String
        let localName: String?
        let companyID: String?
        let isSonyCompanyID: Bool
        let nameLooksLikeCamera: Bool
        let markedAsCamera: Bool
        let advertisementCount: Int
        let firstSeen: Date
        let lastSeen: Date
        let rssiMin: Int?
        let rssiMax: Int?
        let rssiAverage: Double?
        let medianIntervalMs: Double?
        let intervalSamples: Int
        let shortGapsMerged: Int
        let serviceUUIDs: [String]
        let overflowServiceUUIDs: [String]
        let solicitedServiceUUIDs: [String]
        let serviceDataHex: [String: String]
        let manufacturerDataHex: String?
        let manufacturerDataVariants: [String]
        let txPowerLevel: Int?
        let isConnectable: Bool?
        let advertisementKeys: [String]
        let gattServices: [String]?
    }

    /// A peripheral another app (or the system) holds a connection to, from retrieveConnectedPeripherals.
    struct ConnectedRecord: Codable, Identifiable {
        let identifier: String
        let name: String
        let state: String
        /// Marked by hand, or a name with ILCE/Sony (company ID alone would also match Sony headphones).
        let isCamera: Bool
        var id: String { identifier }
    }

    struct Snapshot: Codable {
        let powerState: String
        let pairingContext: String
        let capturedAt: Date
        let scanStartedAt: Date?
        /// When Stop was tapped (or Bluetooth went off); nil if the scan was still running at capture.
        let scanEndedAt: Date?
        let scanSeconds: Double
        let scanFilter: String
        let scanOptions: String
        let proximityServiceUUID: String?
        let device: DeviceContext
        let cameraPeripherals: [PeripheralRecord]
        let otherPeripheralCount: Int
        let connectedQueryServiceUUIDs: [String]
        let connectedPeripherals: [ConnectedRecord]
        let note: String
    }

    static let sonyCompanyID: UInt16 = 0x012D

    /// Sony camera GATT service UUIDs reported by community remote-control projects. unverified on the α7C II:
    /// used only as extra queries for retrieveConnectedPeripherals, never for reads or writes.
    static let unverifiedSonyServiceCandidates = [
        "8000FF00-FF00-FFFF-FFFF-FFFFFFFFFFFF",
        "8000CC00-CC00-FFFF-FFFF-FFFFFFFFFFFF",
        "8000DD00-DD00-FFFF-FFFF-FFFFFFFFFFFF",
        "8000EE00-EE00-FFFF-FFFF-FFFFFFFFFFFF",
    ]

    private(set) var state = "off"
    private(set) var isScanning = false
    private(set) var filterToSony = true
    private(set) var rows: [Row] = []
    private(set) var trackedCount = 0
    private(set) var scanStartedAt: Date?
    /// Set by Stop (or Bluetooth going off) so a snapshot saved later reports how long the scan actually ran.
    private(set) var scanEndedAt: Date?
    private(set) var markedCameras: Set<UUID> = []
    private(set) var connected: [ConnectedRecord] = []
    private(set) var gattServices: [UUID: [String]] = [:]
    private(set) var gattStatus = "idle"
    private(set) var gattBusy = false
    var log: SpikeLog?

    @ObservationIgnored private var central: CBCentralManager?
    /// True between Scan and Stop: a Bluetooth power-on only (re)starts the scan while one was asked for.
    @ObservationIgnored private var scanRequested = false
    @ObservationIgnored private var stats: [UUID: Stats] = [:]
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var gattTarget: CBPeripheral?
    @ObservationIgnored private var gattStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var gattTimeout: Task<Void, Never>?
    private let clock = ContinuousClock()

    // MARK: - Scanning

    func start(sonyOnly: Bool = true) {
        filterToSony = sonyOnly
        scanRequested = true
        stats.removeAll()
        rows.removeAll()
        trackedCount = 0
        scanStartedAt = nil
        scanEndedAt = nil
        if central == nil {
            state = "starting"
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        } else {
            beginScan()
        }
    }

    func stop() {
        scanRequested = false
        central?.stopScan()
        refreshTask?.cancel()
        endScanTiming()
        state = "stopped"
        publishRows()
        let seconds = scanDuration()
        let cameras = stats.values.filter { isCameraLike($0) }
        log?.note(String(format: "BLE scan stopped after %.0f s; %ld peripherals tracked, %ld camera-like", seconds, stats.count, cameras.count))
        for s in cameras.sorted(by: { $0.count > $1.count }) {
            log?.note("  \(summary(s))")
        }
    }

    private func beginScan() {
        guard let central else { return }
        guard central.state == .poweredOn else {
            log?.warn("BLE: can't scan, Bluetooth is \(ProximityWatcher.describe(central.state)); the scan starts when it powers on")
            return
        }
        // No service filter here on purpose: the production filter UUID is what this scan is meant to discover.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        // A restart after Bluetooth was switched off and on keeps the original start: the stats run on.
        if scanStartedAt == nil { scanStartedAt = Date() }
        scanEndedAt = nil
        state = filterToSony ? "scanning (camera-like only)" : "scanning (everything)"
        log?.note("BLE scanning, all services, duplicates on (\(filterToSony ? "camera-like only" : "everything")). Let it run 30 s or more per power state.")
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.publishRows()
            }
        }
    }

    /// Marks the end of the scan (Stop, or Bluetooth going off) for the duration in the snapshot.
    private func endScanTiming() {
        if isScanning { scanEndedAt = Date() }
        isScanning = false
    }

    /// Seconds from the scan's start to Stop, or to `now` while it is still running.
    private func scanDuration(now: Date = Date()) -> Double {
        guard let started = scanStartedAt else { return 0 }
        return (scanEndedAt ?? now).timeIntervalSince(started)
    }

    func toggleMarked(_ id: UUID) {
        if markedCameras.contains(id) {
            markedCameras.remove(id)
            log?.note("BLE: \(stats[id]?.name ?? id.uuidString) no longer marked as the camera")
        } else {
            markedCameras.insert(id)
            log?.note("BLE: \(stats[id]?.name ?? id.uuidString) [\(id.uuidString.prefix(8))] marked as the camera")
        }
        publishRows()
    }

    /// Every service UUID seen on a camera-like peripheral (advertised, overflow, or listed over GATT), sorted:
    /// the choices for the proximity filter.
    var candidateServiceUUIDs: [String] {
        var all = Set<String>()
        for row in rows where row.isCamera {
            all.formUnion(row.serviceUUIDs)
            all.formUnion(row.overflowUUIDs)
        }
        for (_, services) in gattServices { all.formUnion(services) }
        return all.sorted()
    }

    /// Service UUIDs a camera-like peripheral advertises (main or overflow area): the only ones a background scan
    /// can filter on, so the only choices for the proximity filter. Services found by a GATT listing are left out:
    /// the camera's Sony services (8000FF00 and the rest) only show up after connecting, so a filter on one of them
    /// never wakes the app (2 Nov, the filter had been set to 8000FF00 from the list).
    var advertisedServiceUUIDs: [String] {
        var all = Set<String>()
        for row in rows where row.isCamera {
            all.formUnion(row.serviceUUIDs)
            all.formUnion(row.overflowUUIDs)
        }
        return all.sorted()
    }

    // MARK: - Snapshot (day 6 fixture + measurements)

    /// Writes ble/advert-<state>.json and ble/advert-<state>-<pairing>.json and records
    /// ble.advert.<state>.<pairing>.seen, .rssi [dBm] and .interval [ms] for the camera, plus
    /// ble.connected.<state>.<pairing>.seen (requirement 2): the pairing is in the name so one context's
    /// snapshot doesn't overwrite another's in the measurements table.
    func saveSnapshot(power: PowerState, pairing: PairingContext, proximityUUID: String?) {
        guard let started = scanStartedAt else {
            log?.warn("Save snapshot: no scan has run yet. Tap Scan, wait 30 s or more, then save.")
            return
        }
        publishRows()
        let now = Date()
        let seconds = scanDuration(now: now)
        if seconds < 20 {
            log?.warn(String(format: "Save snapshot: the scan has only run %.0f s; the interval estimate needs 30 s or more", seconds))
        }
        let cameras = stats.values.filter { isCameraLike($0) }.sorted { $0.count > $1.count }
        let (query, connectedNow) = checkConnected(extra: proximityUUID)
        let snapshot = Snapshot(
            powerState: power.rawValue,
            pairingContext: pairing.rawValue,
            capturedAt: now,
            scanStartedAt: started,
            scanEndedAt: scanEndedAt,
            scanSeconds: seconds,
            scanFilter: filterToSony ? "camera-like only" : "everything (only camera-like peripherals saved)",
            scanOptions: "foreground, no service filter, CBCentralManagerScanOptionAllowDuplicatesKey = true",
            proximityServiceUUID: proximityUUID,
            device: DeviceContext.current(),
            cameraPeripherals: cameras.map { record($0) },
            otherPeripheralCount: stats.count - cameras.count,
            connectedQueryServiceUUIDs: query,
            connectedPeripherals: connectedNow,
            note: "Camera-like = company ID 0x012D, a name containing ILCE/Sony, or marked by hand. Intervals are the "
                + "median gap between advertising events (callbacks under 20 ms apart, such as scan responses, are "
                + "merged); iOS can miss events, so treat them as an upper bound.")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(snapshot)
            FixtureStore.save(data, link: .ble, name: "advert-\(power.rawValue).json", log: log)
            FixtureStore.save(data, link: .ble, name: "advert-\(power.rawValue)-\(pairing.rawValue).json", log: log)
        } catch {
            log?.error("Save snapshot: could not encode the snapshot: \(error)")
        }

        let base = "ble.advert.\(power.rawValue).\(pairing.rawValue)"
        let pairingText = "pairing: \(pairing.label)"
        if let camera = primaryCamera(cameras) {
            // Sony's company ID alone also matches Sony headphones and speakers: the reason shows which rule chose it.
            log?.flag("\(base).seen", true, context: String(format: "%@ ×%ld in %.0f s, chosen by %@; %@",
                                                            camera.name, camera.count, seconds, cameraReason(camera), pairingText))
            if let rssi = camera.rssiAverage {
                log?.measure("\(base).rssi", rssi, "dBm",
                             context: "\(camera.name): average of \(camera.rssiSamples), min \(camera.rssiMin), max \(camera.rssiMax); \(pairingText)")
            } else {
                log?.warn("\(camera.name): no usable RSSI samples (all 127 = unavailable)")
            }
            if let interval = camera.medianIntervalMs {
                log?.measure("\(base).interval", interval, "ms",
                             context: "\(camera.name): median of \(camera.gapsMs.count) gaps between advertising events (\(camera.shortGapsMerged) callbacks under 20 ms merged), foreground scan with duplicates (upper bound); \(pairingText)")
            } else {
                log?.warn("\(camera.name): only one advertisement, no interval yet; scan longer")
            }
        } else {
            log?.flag("\(base).seen", false, context: String(format: "no camera-like peripheral in %.0f s of scanning (%ld others); %@", seconds, stats.count, pairingText))
            log?.warn("No camera-like peripheral seen. If the camera shows up under Scan (everything) with another name, mark it as the camera and save again.")
        }
        // An empty query means Bluetooth wasn't ready and nothing was asked: record no flag rather than a false "no".
        let connectedName = "ble.connected.\(power.rawValue).\(pairing.rawValue).seen"
        guard !query.isEmpty else {
            log?.warn("\(connectedName) not recorded: retrieveConnectedPeripherals didn't run (Bluetooth not powered on)")
            return
        }
        // Only the camera counts: the query also matches wearables and headphones that share a service UUID.
        let held = connectedNow.filter(\.isCamera)
        let others = connectedNow.filter { !$0.isCamera }
        func names(_ records: [ConnectedRecord]) -> String { records.isEmpty ? "none" : records.map(\.name).joined(separator: ", ") }
        log?.flag(connectedName, !held.isEmpty,
                  context: "retrieveConnectedPeripherals over \(query.count) service UUIDs → camera: \(names(held)); other connected: \(names(others)); \(pairingText)")
        if held.isEmpty, !others.isEmpty {
            log?.warn("\(others.count) connected peripherals, none recognised as the camera (\(names(others))). If one is the camera, mark it as the camera and save again.")
        }
    }

    // MARK: - Connected peripherals (requirement 2)

    /// retrieveConnectedPeripherals for every service UUID seen so far, the proximity UUID, services listed over
    /// GATT and the unverified Sony candidates: finds a camera that another app (Creators' App) holds connected,
    /// which may not advertise at all. Logs and returns the query and what came back.
    @discardableResult
    func checkConnected(extra: String?) -> (query: [String], connected: [ConnectedRecord]) {
        guard let central, central.state == .poweredOn else {
            log?.warn("Check connected: Bluetooth isn't ready (\(state)); tap Scan first")
            return ([], [])
        }
        var strings = Set(candidateServiceUUIDs)
        for s in stats.values { strings.formUnion(s.serviceUUIDs) }
        if let extra, !extra.isEmpty { strings.insert(extra) }
        strings.formUnion(Self.unverifiedSonyServiceCandidates)
        var uuids: [CBUUID] = []
        var query: [String] = []
        for s in strings.sorted() {
            if let uuid = ProximityWatcher.serviceUUID(from: s) {
                uuids.append(uuid)
                query.append(uuid.uuidString)
            }
        }
        guard !uuids.isEmpty else { return ([], []) }
        let found = central.retrieveConnectedPeripherals(withServices: uuids)
        var records: [ConnectedRecord] = []
        for p in found {
            peripherals[p.identifier] = p
            let isCamera = markedCameras.contains(p.identifier) || Self.nameLooksLikeCamera(p.name)
                || stats[p.identifier].map { $0.nameLooksLikeCamera || Self.nameLooksLikeCamera($0.localName) } == true
            records.append(ConnectedRecord(identifier: p.identifier.uuidString, name: p.name ?? "(no name)",
                                           state: Self.describe(p.state), isCamera: isCamera))
        }
        connected = records
        if records.isEmpty {
            log?.note("Check connected: no peripheral connected to the system with any of \(query.count) service UUIDs")
        } else {
            for r in records {
                log?.note("Check connected: \(r.name) [\(r.identifier.prefix(8))] is connected to the system (\(r.state)); another app may hold it\(r.isCamera ? " (the camera)" : " (not recognised as the camera)")")
            }
        }
        return (query, records)
    }

    // MARK: - Experimental: list GATT services (requirement 4)

    /// Connects, discovers services (UUIDs only), disconnects. No characteristic is read or written. If Creators'
    /// App already holds the link, iOS shares it and cancelling only drops this app's use of it.
    func listServices(_ id: UUID) {
        guard !gattBusy else { log?.warn("GATT: a service listing is already running"); return }
        guard let central, central.state == .poweredOn else {
            log?.warn("GATT: Bluetooth isn't ready (\(state)); tap Scan first")
            return
        }
        guard let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            log?.warn("GATT: that peripheral is no longer known; scan again so it's seen")
            return
        }
        gattBusy = true
        gattTarget = peripheral
        gattStartedAt = clock.now
        gattStatus = "connecting to \(peripheral.name ?? "(no name)")"
        peripheral.delegate = self
        log?.warn("GATT (experimental): connecting to \(peripheral.name ?? "(no name)") [\(id.uuidString.prefix(8))] to list service UUIDs only; no characteristic reads or writes")
        central.connect(peripheral, options: nil)
        gattTimeout?.cancel()
        gattTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.gattBusy else { return }
            self.log?.warn("GATT: no connection or no services after 20 s (camera asleep, out of range or not connectable); cancelled")
            self.finishGATT(status: "timed out")
        }
    }

    private func finishGATT(status: String) {
        gattTimeout?.cancel()
        gattTimeout = nil
        if let target = gattTarget, target.state != .disconnected {
            central?.cancelPeripheralConnection(target)
        }
        gattTarget = nil
        gattBusy = false
        gattStatus = status
    }

    // MARK: - Helpers

    private func isCameraLike(_ s: Stats) -> Bool {
        s.companyID == Self.sonyCompanyID || s.nameLooksLikeCamera || markedCameras.contains(s.id)
    }

    /// The camera for the measurements: marked by hand first, then a name with ILCE, then Sony's company ID; the
    /// most advertisements breaks a tie.
    private func primaryCamera(_ cameras: [Stats]) -> Stats? {
        func rank(_ s: Stats) -> Int {
            if markedCameras.contains(s.id) { return 3 }
            if (s.localName ?? s.name).uppercased().contains("ILCE") || s.name.uppercased().contains("ILCE") { return 2 }
            if s.companyID == Self.sonyCompanyID { return 1 }
            return 0
        }
        return cameras.max { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.count < b.count
        }
    }

    /// Which rule made `s` the measured camera, for the measurement context.
    private func cameraReason(_ s: Stats) -> String {
        if markedCameras.contains(s.id) { return "marking by hand" }
        if (s.localName ?? s.name).uppercased().contains("ILCE") || s.name.uppercased().contains("ILCE") { return "ILCE in the name" }
        if s.companyID == Self.sonyCompanyID { return "Sony company ID 0x012D only" }
        return "Sony in the name only"
    }

    static func nameLooksLikeCamera(_ name: String?) -> Bool {
        guard let n = name?.uppercased() else { return false }
        return n.contains("ILCE") || n.contains("SONY")
    }

    private func summary(_ s: Stats) -> String {
        var parts = ["\(s.name) [\(s.id.uuidString.prefix(8))] ×\(s.count)"]
        if let avg = s.rssiAverage { parts.append(String(format: "RSSI avg %.1f (%ld…%ld)", avg, s.rssiMin, s.rssiMax)) }
        if let interval = s.medianIntervalMs { parts.append(String(format: "interval ~%.0f ms", interval)) }
        if let company = s.companyID { parts.append(String(format: "company 0x%04X", company)) }
        parts.append("services \(s.serviceUUIDs.isEmpty ? "none" : s.serviceUUIDs.sorted().joined(separator: ","))")
        if !s.overflowUUIDs.isEmpty { parts.append("overflow \(s.overflowUUIDs.sorted().joined(separator: ","))") }
        if !s.solicitedUUIDs.isEmpty { parts.append("solicited \(s.solicitedUUIDs.sorted().joined(separator: ","))") }
        for (uuid, hex) in s.serviceDataHex.sorted(by: { $0.key < $1.key }) { parts.append("data[\(uuid)] \(hex)") }
        if let mfg = s.manufacturerHex { parts.append("mfg \(mfg)") }
        if s.manufacturerVariants.count > 1 { parts.append("\(s.manufacturerVariants.count) mfg variants") }
        if let tx = s.txPower { parts.append("tx \(tx) dBm") }
        if let c = s.connectable { parts.append(c ? "connectable" : "not connectable") }
        return parts.joined(separator: " · ")
    }

    private func record(_ s: Stats) -> PeripheralRecord {
        PeripheralRecord(
            identifier: s.id.uuidString,
            name: s.name,
            localName: s.localName,
            companyID: s.companyID.map { String(format: "0x%04X", $0) },
            isSonyCompanyID: s.companyID == Self.sonyCompanyID,
            nameLooksLikeCamera: s.nameLooksLikeCamera,
            markedAsCamera: markedCameras.contains(s.id),
            advertisementCount: s.count,
            firstSeen: s.firstSeen,
            lastSeen: s.lastSeen,
            rssiMin: s.rssiSamples > 0 ? s.rssiMin : nil,
            rssiMax: s.rssiSamples > 0 ? s.rssiMax : nil,
            rssiAverage: s.rssiAverage,
            medianIntervalMs: s.medianIntervalMs,
            intervalSamples: s.gapsMs.count,
            shortGapsMerged: s.shortGapsMerged,
            serviceUUIDs: s.serviceUUIDs.sorted(),
            overflowServiceUUIDs: s.overflowUUIDs.sorted(),
            solicitedServiceUUIDs: s.solicitedUUIDs.sorted(),
            serviceDataHex: s.serviceDataHex,
            manufacturerDataHex: s.manufacturerHex,
            manufacturerDataVariants: s.manufacturerVariants,
            txPowerLevel: s.txPower,
            isConnectable: s.connectable,
            advertisementKeys: s.keys.sorted(),
            gattServices: gattServices[s.id])
    }

    private func publishRows() {
        trackedCount = stats.count
        let sorted = stats.values.sorted { a, b in
            let ca = isCameraLike(a), cb = isCameraLike(b)
            return ca != cb ? ca : a.count > b.count
        }
        rows = sorted.prefix(60).map { s in
            Row(id: s.id,
                name: s.name,
                isCamera: isCameraLike(s),
                isMarked: markedCameras.contains(s.id),
                count: s.count,
                rssiAverage: s.rssiAverage,
                rssiMin: s.rssiSamples > 0 ? s.rssiMin : nil,
                rssiMax: s.rssiSamples > 0 ? s.rssiMax : nil,
                intervalMs: s.medianIntervalMs,
                serviceUUIDs: s.serviceUUIDs.sorted(),
                overflowUUIDs: s.overflowUUIDs.sorted(),
                solicitedUUIDs: s.solicitedUUIDs.sorted(),
                serviceData: s.serviceDataHex.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" },
                manufacturerHex: s.manufacturerHex,
                companyID: s.companyID.map { String(format: "0x%04X", $0) },
                txPower: s.txPower,
                connectable: s.connectable,
                lastSeen: s.lastSeen,
                gattServices: gattServices[s.id])
        }
    }

    nonisolated static func describe(_ state: CBPeripheralState) -> String {
        switch state {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnected: return "disconnected"
        case .disconnecting: return "disconnecting"
        @unknown default: return "state \(state.rawValue)"
        }
    }

    private static func uuidStrings(_ value: Any?) -> [String] {
        (value as? [CBUUID])?.map(\.uuidString) ?? []
    }
}

extension AdvertisementScanner: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            state = "powered on"
            // Only while a scan was asked for: after Stop, switching Bluetooth off and on must not restart it.
            if scanRequested { beginScan() }
        case .poweredOff:
            endScanTiming()
            state = "Bluetooth off"
            log?.warn("BLE: Bluetooth is off (Control Centre or Settings)")
        case .unauthorized:
            endScanTiming()
            state = "unauthorised"
            log?.error("BLE: Bluetooth permission denied (Settings → SB Spike → Bluetooth)")
        case .unsupported:
            endScanTiming()
            state = "unsupported"
            log?.error("BLE: Bluetooth LE unsupported on this device")
        default:
            state = ProximityWatcher.describe(central.state)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let now = Date()
        let instant = clock.now
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        var company: UInt16?
        if let mfg, mfg.count >= 2 {
            company = UInt16(mfg[mfg.startIndex]) | UInt16(mfg[mfg.startIndex + 1]) << 8
        }
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let looksLikeCamera = Self.nameLooksLikeCamera(peripheral.name) || Self.nameLooksLikeCamera(localName)
        let cameraLike = company == Self.sonyCompanyID || looksLikeCamera || markedCameras.contains(id)
        if filterToSony, !cameraLike, stats[id] == nil { return }

        let isNew = stats[id] == nil
        var s = stats[id] ?? Stats(id: id, name: peripheral.name ?? localName ?? "(no name)", localName: localName,
                                   companyID: company, nameLooksLikeCamera: looksLikeCamera,
                                   firstSeen: now, lastSeen: now, lastInstant: instant)
        // Advertising events are at least 20 ms apart; a callback sooner than that is the scan response (or a
        // repeat) of the same event, so it adds no gap and the timing stays on the event's first packet.
        let gapMs = (instant - s.lastInstant).inSeconds * 1000
        if s.count > 0, gapMs < 20 {
            s.shortGapsMerged += 1
        } else {
            if s.count > 0, s.gapsMs.count < 5000 { s.gapsMs.append(gapMs) }
            s.lastInstant = instant
        }
        s.count += 1
        s.lastSeen = now
        if let name = peripheral.name ?? localName { s.name = name }
        if let localName { s.localName = localName }
        if let company { s.companyID = company }
        s.nameLooksLikeCamera = s.nameLooksLikeCamera || looksLikeCamera
        let rssi = RSSI.intValue
        if rssi != 127 {   // 127 = RSSI unavailable
            s.rssiSamples += 1
            s.rssiSum += rssi
            s.rssiMin = min(s.rssiMin, rssi)
            s.rssiMax = max(s.rssiMax, rssi)
        }
        s.keys.formUnion(advertisementData.keys)
        let services = Self.uuidStrings(advertisementData[CBAdvertisementDataServiceUUIDsKey])
        let newServices = services.filter { !s.serviceUUIDs.contains($0) }
        s.serviceUUIDs.formUnion(services)
        s.overflowUUIDs.formUnion(Self.uuidStrings(advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey]))
        s.solicitedUUIDs.formUnion(Self.uuidStrings(advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey]))
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (uuid, data) in serviceData { s.serviceDataHex[uuid.uuidString] = data.hexDump(limit: 64) }
        }
        if let mfg {
            let hex = mfg.hexDump(limit: 64)
            s.manufacturerHex = hex
            if !s.manufacturerVariants.contains(hex), s.manufacturerVariants.count < 16 { s.manufacturerVariants.append(hex) }
        }
        if let tx = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber { s.txPower = tx.intValue }
        if let c = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber { s.connectable = c.boolValue }
        stats[id] = s

        if cameraLike {
            peripherals[id] = peripheral
            if isNew {
                log?.note("BLE: first seen \(summary(s))")
            } else if !newServices.isEmpty {
                log?.note("BLE: \(s.name) now also advertises \(newServices.joined(separator: ", "))")
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === gattTarget else { return }
        let ms = gattStartedAt.map { (clock.now - $0).inSeconds * 1000 } ?? 0
        gattStatus = "discovering services"
        log?.note(String(format: "GATT: connected to %@ in %.0f ms; discovering services", peripheral.name ?? "(no name)", ms))
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === gattTarget else { return }
        log?.error("GATT: connection to \(peripheral.name ?? "(no name)") failed: \(error.map { "\($0)" } ?? "no error given")")
        finishGATT(status: "connection failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log?.note("GATT: disconnected from \(peripheral.name ?? "(no name)")" + (error.map { " (\($0))" } ?? ""))
        if peripheral === gattTarget, gattBusy { finishGATT(status: "disconnected before services were listed") }
    }
}

extension AdvertisementScanner: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === gattTarget else { return }
        if let error {
            log?.error("GATT: service discovery on \(peripheral.name ?? "(no name)") failed: \(error)")
            finishGATT(status: "service discovery failed")
            return
        }
        let services = peripheral.services ?? []
        let uuids = services.map(\.uuid.uuidString)
        gattServices[peripheral.identifier] = uuids
        let described = services.map { "\($0.uuid.uuidString)\($0.isPrimary ? "" : " (secondary)")" }
        log?.note("GATT: \(peripheral.name ?? "(no name)") has \(services.count) services: \(described.isEmpty ? "none" : described.joined(separator: ", ")); disconnecting")
        publishRows()
        finishGATT(status: "listed \(services.count) services")
    }
}
