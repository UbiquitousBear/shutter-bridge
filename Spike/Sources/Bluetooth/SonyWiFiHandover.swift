// Builds 10 and 11 (experimental): can the app switch the α7C II's Wi-Fi on over Bluetooth and read the network name
// and password ("Wi-Fi handover"), so the phone can join the camera's network without the QR code?
//
// Everything here about Sony's GATT layout is reverse-engineered (CameraSync's notes on a decompiled Creators' App,
// SonyCameraKit) and unverified on this camera. On 2 Nov the spike listed services 8000FF00, 8000CC00, 8000DD00,
// 8000EE00 and 8000BB00 on the real camera. Inside 8000CC00 (all unverified):
//
//   CC08  "Wi-Fi on": write 0x01 with response            the ONLY value this file writes, after the tester confirms
//   CC06  SSID, CC07 password: read, ASCII after 3 bytes   never logged, displayed, stored or put on the pasteboard
//   CC0C  BSSID: read, optional                            only "present, MAC-shaped yes/no" is logged
//   CC09  status: read/notify                              entries [length 1 B = tag + value][tag 2 B BE][value]
//                                                          (seen on the α7C II, build 12); tag 0x0001's first value
//                                                          byte = Wi-Fi status (0 terminated, 1 launching, 2 launched,
//                                                          3 terminating, per the notes; 0→1→2 and 2→3→0 seen)
//   CC0A  firmware, CC0B model name: read                  logged (unless they look like a serial or a MAC)
//   CC10  battery, CC0F media, CC03 transfer, CC0E initial setting: notify   Sony's app subscribes to these
//
// The writes are CC08 = 0x01 and notification subscriptions (the descriptor write iOS makes for setNotifyValue) on
// characteristics inside 8000CC00, nothing else; unsubscribeAll() turns them off and waits for each answer (those
// turned on over an earlier link are turned on and off again over this one), and Disconnect turns off any still on
// without waiting, closing the link 2 s later. Never written: EE01 (pairing / power off), FF01 (remote),
// anything in DD or BB, any CC characteristic's value but CC08's.
// Every CC value other than CC06, CC07 and CC0C is logged masked (bytes up to 0x0F as hex, larger bytes as "··"),
// including CC09's tag/length/value reading and its status; CC06, CC07 and CC0C only as lengths. Previous values are
// kept in memory for diffs and dropped on the next connection or Disconnect; a link the camera drops keeps the
// timeline, so the run can still report what came before the drop. Build 13: CC09's entries are merged (tag → value)
// from every read and notification, since a read carries every tag and a notification one; changes are logged per
// tag, and the Wi-Fi status comes from that merged state (the learnt status byte only for a value that doesn't parse).
// The camera is bonded to Creators' App on the same iPhone; iOS shares that bond with this app, so an encrypted
// read should work without a prompt. If iOS shows a pairing request instead, lastPairingHint says so.

import Foundation
import Observation
import CoreBluetooth

/// What `discover()` found.
struct HandoverInventory {
    var services: [String]
    /// Service UUID → "characteristic UUID (properties)".
    var characteristics: [String: [String]]
    /// Service 8000CC00 is present.
    var hasCameraControl: Bool
    /// "CC06", "CC07", "CC08", "CC09", "CC0A", "CC0B", "CC0C" → present in service 8000CC00.
    var found: [String: Bool]
    /// Build 11: the codes of every characteristic in 8000CC00 that can notify or indicate, sorted.
    var notifiable: [String] = []
}

/// The camera's Wi-Fi network as read over Bluetooth. `description` is redacted: lengths and yes/no only, never the
/// values. Keep the values in memory only, long enough to join.
struct HandoverCredentials: CustomStringConvertible {
    let ssid: String
    let passphrase: String
    let bssidPresent: Bool

    var description: String {
        "SSID \(ssid.count) chars, DIRECT- prefix \(ssid.hasPrefix("DIRECT-") ? "yes" : "no")"
            + " · passphrase \(passphrase.count) chars, 8–63 printable ASCII \(Self.isValidPassphrase(passphrase) ? "yes" : "no")"
            + " · BSSID \(bssidPresent ? "present" : "absent")"
    }

    /// WPA2 passphrase rule: 8 to 63 printable ASCII characters.
    static func isValidPassphrase(_ text: String) -> Bool {
        (8 ... 63).contains(text.unicodeScalars.count)
            && text.unicodeScalars.allSatisfy { (0x20 ... 0x7E).contains($0.value) }
    }
}

/// `debugPrint`, `dump` and the debugger's summary show the redacted text too.
extension HandoverCredentials: CustomDebugStringConvertible, CustomReflectable {
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["redacted": description]) }
}

/// What CC09 reported since the latest timeline mark (build 11), for the guided run's watch of Creators' App.
struct CC09Watch {
    /// Notifications of every subscribed characteristic since the mark.
    var notifications: Int
    var cc09Notifications: Int
    /// The CC09 byte read as the Wi-Fi status for values that don't parse as the α7C II layout (build 13: the merged
    /// state's tag 0x0001 comes first), and where the status came from ("CC09 tag 0x0001 (α7C II layout)" or the byte
    /// and how it was chosen).
    var position: Int?
    var positionSource: String
    /// The Wi-Fi status's values since the mark: "0 → 1 (+0.15 s) → 2 (+1.20 s)".
    var sequence: String
    /// Seconds from the mark to CC09's first change, and to the first change to Wi-Fi status 2 from a known status
    /// that wasn't 2.
    var firstChangeAt: Double?
    var launchedAt: Double?
    /// Some CC09 value since the mark (or the one at the mark) carried status 2, with or without a change to it.
    var sawLaunched: Bool
    /// The Wi-Fi status now (the merged state's, else CC09's latest value's); nil when unknown.
    var current: Int?
}

enum HandoverError: Error, CustomStringConvertible, LocalizedError {
    case busy
    case bluetooth(String)
    case notFound(String)
    case notConnected
    case disconnected(String)
    case timedOut(String, Double)
    case missing(String)
    case readFailed(String, String)
    case cancelled(String)

    var description: String {
        switch self {
        case .busy: return "another Wi-Fi handover operation is running"
        case .bluetooth(let state): return "Bluetooth isn't available (\(state))"
        case .notFound(let detail): return "camera not found: \(detail)"
        case .notConnected: return "not connected to the camera; tap Connect + discover first"
        case .disconnected(let detail): return "the camera disconnected (\(detail))"
        case .timedOut(let what, let seconds): return String(format: "%@: no answer after %.0f s", what, seconds)
        case .missing(let code): return "the camera has no \(code) characteristic in service 8000CC00"
        case .readFailed(let code, let reason): return "reading \(code) failed: \(reason)"
        case .cancelled(let why): return "cancelled (\(why))"
        }
    }

    var errorDescription: String? { description }

    var isTimeout: Bool {
        if case .timedOut = self { return true }
        return false
    }
}

/// Builds 10 and 11: the Bluetooth half of the Wi-Fi handover. Its own CBCentralManager (no restore identifier, created on
/// the first Connect so launching the app never prompts for Bluetooth), main queue, delegate callbacks bridged to
/// async calls with timeouts. Every call logs what it measured; see the file header for what is never logged.
@Observable
@MainActor
final class SonyWiFiHandover: NSObject {
    nonisolated static let cameraControlService = "8000CC00-CC00-FFFF-FFFF-FFFFFFFFFFFF"
    /// Where the last camera this lab connected to is remembered: the iPhone's own identifier for the peripheral
    /// (random per phone, not a camera hardware ID), so the next Connect can retrieve it straight away.
    nonisolated static let savedPeripheralKey = "ble.handover.peripheralID"
    nonisolated static let codes = ["CC06", "CC07", "CC08", "CC09", "CC0A", "CC0B", "CC0C"]
    /// Never read by safeReads and never logged in any form but lengths and yes/no.
    nonisolated static let secretCodes: Set<String> = ["CC06", "CC07", "CC0C"]
    /// What Sony's app subscribes to (CameraSync's notes, unverified): status, battery, media, push transfer and
    /// initial setting.
    nonisolated static let sonyNotificationCodes = ["CC09", "CC10", "CC0F", "CC03", "CC0E"]
    /// Where the CC09 byte that carries the Wi-Fi status is remembered once learnt: a position, not a camera value.
    nonisolated static let statusByteKey = "ble.handover.cc09StatusByte"
    /// How the remembered byte was learnt ("0 → 1 after CC08", "0 → 1 → 2 in a watch"), for the logs.
    nonisolated static let statusByteSourceKey = "ble.handover.cc09StatusByteSource"
    /// Notification lines logged live per timeline mark; after that they are only counted.
    nonisolated static let liveLineCap = 300

    /// One line for the UI.
    private(set) var status = "idle"
    private(set) var busy = false
    /// The connected camera's name, nil when not connected.
    private(set) var connectedName: String?
    /// Set when an ATT error (or a read that never answers) suggests encryption or authentication: the guided run
    /// asks whether iOS showed a pairing dialog.
    var lastPairingHint: String?

    var isConnected: Bool { connectedName != nil }
    /// Build 11: the codes this app turned notifications on for in 8000CC00 (Disconnect turns them off).
    private(set) var subscribedCodes: Set<String> = []
    /// The latest switchWiFiOn's status-byte values with times ("0 → 1 (+0.15 s) → 0 (+2.40 s)"), for contexts.
    private(set) var lastStatusSequence = "none"
    /// Whether CC09's notifications were on when the latest switchWiFiOn wrote CC08 (nil: it didn't get that far).
    private(set) var lastCC09Notifying: Bool?
    /// The codes this app had turned notifications on for, on that link, when the latest switchWiFiOn wrote CC08
    /// (empty: none, or it didn't get that far).
    private(set) var lastSubscribedAtWrite: [String] = []
    /// Seconds from the timeline mark to the camera dropping the link, kept with the timeline (nil: no drop since).
    private(set) var linkDroppedAt: Double?

    /// Build 13: every characteristic of Sony's set (CC09, CC10, CC0F, CC03, CC0E) that the camera offers with notify
    /// or indicate has notifications on over this link (false before discovery, or when it offers none of them).
    var sonySetNotifying: Bool {
        let offered = Self.sonyNotificationCodes.filter { code in ccAll[code].map { Self.canNotify($0) } ?? false }
        return !offered.isEmpty && offered.allSatisfy { code in ccAll[code]?.isNotifying == true || subscribedCodes.contains(code) }
    }

    /// The codes of 8000CC00's characteristics that can notify or indicate, sorted (empty before discovery).
    var notifiableCodes: [String] {
        ccAll.filter { Self.canNotify($0.value) }.keys.sorted()
    }

    /// How many characteristics of 8000CC00 have notifications on (or were turned on by this app) on this link.
    var notifyingCount: Int { notifyingCharacteristics().count }

    /// Codes this app turned notifications on for over an earlier link since the last Disconnect (the camera dropped
    /// it and the app reconnected), or asked for without an answer, that aren't on over this link. A bonded camera
    /// keeps a client's notification switches across connections, so unsubscribeAll() turns each on and off again.
    var earlierLinkCodes: [String] {
        let onNow = Set(notifyingCharacteristics().map { $0.0 })
        return everSubscribed.subtracting(onNow).sorted()
    }

    /// Build 13: how many peripherals with 8000CC00 iOS lists as connected to the system (any app's link, this app's
    /// included), so a run can tell whether a Disconnect really took the camera's link down; nil when Bluetooth isn't
    /// powered on. Only the count leaves this function; nothing is connected, read or written.
    func systemConnectedCameraCount() -> Int? {
        guard let central, central.state == .poweredOn else { return nil }
        return central.retrieveConnectedPeripherals(withServices: [CBUUID(string: Self.cameraControlService)]).count
    }

    /// Notifications are on for every characteristic in 8000CC00 that offers them.
    var subscribedToAll: Bool {
        let all = notifiableCodes
        return !all.isEmpty && all.allSatisfy { subscribedCodes.contains($0) }
    }

    @ObservationIgnored let log: SpikeLog
    /// The scanner's in-memory camera identifiers (marked rows, GATT listings with 8000CC00, connected peripherals
    /// recognised as the camera, rows named ILCE) are the first route; set by the app.
    @ObservationIgnored weak var scanner: AdvertisementScanner?
    /// For comparing what the camera sends with what the tester typed on the Wi-Fi tab (yes/no only); set by the app.
    @ObservationIgnored weak var wireless: WirelessLab?

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    /// Characteristics of service 8000CC00 by their 4 hex digits.
    @ObservationIgnored private var cc: [String: CBCharacteristic] = [:]
    /// Every characteristic of service 8000CC00 by its 4 hex digits (build 11: subscriptions and the timeline).
    @ObservationIgnored private var ccAll: [String: CBCharacteristic] = [:]
    @ObservationIgnored private var discovered = false
    @ObservationIgnored private var scanFound: CBPeripheral?
    @ObservationIgnored private var cc09Latest: Data?
    @ObservationIgnored private var cc09Updates = 0
    /// Counts Disconnect taps, so a wait can tell a Disconnect from the camera dropping the link.
    @ObservationIgnored private var disconnectRequests = 0
    /// Build 14: counts cancelWaits calls, so switchWiFiOn's wait for the Wi-Fi status (a loop, not a waiter) stops too.
    @ObservationIgnored private var cancelRequests = 0
    /// Every code this app turned notifications on for, over any link: unlike subscribedCodes it outlives a dropped
    /// link (resetLink), so the switches left at the camera can be cleared over the next one. Codes leave it when
    /// confirmed off, or when Disconnect turns them off over a connected link (build 14: Disconnect keeps the rest).
    @ObservationIgnored private var everSubscribed: Set<String> = []
    @ObservationIgnored private var waiters: [String: Waiter] = [:]
    /// The last value seen per code (read or notified), in memory only, for diffs. Never CC06, CC07 or CC0C.
    @ObservationIgnored private var previous: [String: Data] = [:]
    /// The last length seen for CC06, CC07 and CC0C: all that is kept of them.
    @ObservationIgnored private var previousLength: [String: Int] = [:]
    /// Notifications per code since the latest timeline mark.
    @ObservationIgnored private var timeline: [String: TimelineEntry] = [:]
    @ObservationIgnored private var timelineOrigin: ContinuousClock.Instant?
    @ObservationIgnored private var timelineLabel = "none"
    @ObservationIgnored private var liveLines = 0
    @ObservationIgnored private var silentLines = 0
    /// CC09's notifications since the mark, and its value and merged state when the mark was set.
    @ObservationIgnored private var cc09History: [CC09Update] = []
    @ObservationIgnored private var cc09AtMark: Data?
    @ObservationIgnored private var cc09StateAtMark: [Int: [UInt8]] = [:]
    /// While switchWiFiOn waits: CC09's notifications in arrival order, so none is missed between its checks.
    @ObservationIgnored private var cc09Queue: [CC09Update] = []
    @ObservationIgnored private var cc09Watching = false
    /// Build 13: CC09's entries merged from every read and notification on this link (tag → value), from values that
    /// parse as the α7C II layout. Kept after the camera drops the link (like cc09Latest), cleared on the next
    /// connection and on Disconnect. Status flags only (every value shown masked).
    @ObservationIgnored private var cc09State: [Int: [UInt8]] = [:]
    /// A clock that keeps running while the app is suspended, so the timeline's times stay right when Creators' App
    /// is in front.
    private let clock = ContinuousClock()

    private struct TimelineEntry {
        var count = 0
        var first: Double
        var last: Double
        /// Nil for CC06, CC07 and CC0C.
        var lastValue: Data?
        var lastLength = 0
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Data?, Error>
    }

    /// Build 13: one CC09 notification, for the timeline's history and switchWiFiOn's queue.
    private struct CC09Update {
        let instant: ContinuousClock.Instant
        /// Seconds from the timeline mark.
        let at: Double
        let value: Data
        /// The merged state right after this value; empty when the value didn't parse as the α7C II layout.
        let state: [Int: [UInt8]]
        /// The merged state's Wi-Fi status right after this value; nil when unknown or the value didn't parse.
        let merged: Int?
    }

    /// Build 13: what one CC09 value changed in the merged state.
    private struct CC09Merge {
        /// `tagChanges` against the state before this value.
        let changes: String
        /// The state was empty before: the first value on this link.
        let first: Bool
    }

    private enum ReadOutcome {
        case value(Data)
        case failed(String)
    }

    init(log: SpikeLog) {
        self.log = log
        super.init()
    }

    // MARK: - Connect

    /// Finds the camera (identifier the scanner knows or this lab saved → peripherals connected to the system with
    /// service 8000CC00 → a 10 s scan for Sony's company ID 0x012D and a name with ILCE), connects, and returns its
    /// name. Logs the route and the time.
    func connect(timeout: Double = 20) async throws -> String {
        try await run("Connect") {
            try await self.doConnect(timeout: timeout)
        }
    }

    private func doConnect(timeout: Double) async throws -> String {
        // Each Connect starts without the hint of an earlier session.
        lastPairingHint = nil
        if let p = peripheral, p.state == .connected {
            let name = p.name ?? "(no name)"
            status = "connected to \(name)"
            log.note("Wi-Fi handover: already connected to \(name)")
            return name
        }
        let started = clock.now
        status = "waiting for Bluetooth"
        let central = try await poweredOnCentral()
        let serviceUUID = CBUUID(string: Self.cameraControlService)

        // Route 1: an identifier the scanner or this lab already knows.
        let known = knownIdentifiers()
        let byID = known.isEmpty ? [] : central.retrievePeripherals(withIdentifiers: known.map { $0.id })
        // Route 2: the camera connected to the system (Creators' App holds it), found by its Sony service.
        let systemConnected = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        let connectedIDs = Set(systemConnected.map(\.identifier))
        log.note("Wi-Fi handover: \(known.count) known identifier(s) (\(known.isEmpty ? "none" : known.map { "\($0.id.uuidString.prefix(8)) from \($0.source)" }.joined(separator: ", "))) → \(byID.count) retrieved; \(systemConnected.count) connected to the system with 8000CC00 (\(systemConnected.isEmpty ? "none" : systemConnected.map { "\($0.name ?? "(no name)") [\($0.identifier.uuidString.prefix(8))]" }.joined(separator: ", ")))")

        var attempts: [(CBPeripheral, String, Double)] = []
        if let p = Self.preferCamera(byID) {
            let source = known.first { $0.id == p.identifier }?.source ?? "identifier"
            if connectedIDs.contains(p.identifier) {
                attempts.append((p, "known identifier (\(source)), connected to the system", timeout))
            } else {
                // A retrieved peripheral that isn't nearby never connects and never fails: give it a short go.
                attempts.append((p, "known identifier (\(source))", min(8, timeout)))
            }
        }
        if let p = Self.preferCamera(systemConnected), !attempts.contains(where: { $0.0.identifier == p.identifier }) {
            attempts.append((p, "retrieveConnectedPeripherals(8000CC00)", timeout))
        }
        for (p, route, seconds) in attempts {
            if let name = try await attemptConnect(p, route: route, timeout: seconds, started: started) { return name }
        }

        // Route 3: scan.
        status = "scanning for the camera (10 s)"
        log.note("Wi-Fi handover: scanning 10 s for company 0x012D with ILCE in the name")
        scanFound = nil
        do {
            _ = try await wait("scan", timeout: 10, what: "scan for the camera") {
                central.scanForPeripherals(withServices: nil, options: nil)
            }
        } catch let e as HandoverError where e.isTimeout {
            central.stopScan()
            throw HandoverError.notFound(String(format: "no identifier, nothing connected with 8000CC00, and nothing advertising 0x012D with ILCE in its name in 10 s (%.1f s in all). Is the camera on with Bluetooth Function on?", (clock.now - started).inSeconds))
        } catch {
            central.stopScan()
            throw error
        }
        central.stopScan()
        guard let found = scanFound else { throw HandoverError.notFound("the scan ended without a camera") }
        // Not kept past this attempt: the peripheral's characteristics cache the last values read (the credentials).
        scanFound = nil
        if let name = try await attemptConnect(found, route: "scan (0x012D, ILCE)", timeout: timeout, started: started) {
            return name
        }
        throw HandoverError.notFound(String(format: "found %@ by scanning but couldn't connect in %.0f s", found.name ?? "(no name)", timeout))
    }

    /// Connects to `p`; the name on success, nil on a timeout or failure (logged) so the next route can be tried.
    private func attemptConnect(_ p: CBPeripheral, route: String, timeout: Double,
                                started: ContinuousClock.Instant) async throws -> String? {
        guard let central else { throw HandoverError.bluetooth("no central") }
        let name = p.name ?? "(no name)"
        status = "connecting to \(name) (\(route))"
        log.note("Wi-Fi handover: connecting to \(name) [\(p.identifier.uuidString.prefix(8))] via \(route), state \(AdvertisementScanner.describe(p.state))")
        peripheral = p
        p.delegate = self
        let attemptStart = clock.now
        do {
            _ = try await wait("connect", timeout: timeout, what: "connect") {
                central.connect(p, options: nil)
            }
        } catch let e as HandoverError where e.isTimeout {
            central.cancelPeripheralConnection(p)
            peripheral = nil
            log.warn(String(format: "Wi-Fi handover: %@ via %@ didn't connect in %.0f s; cancelled", name, route, timeout))
            return nil
        } catch let e as HandoverError {
            peripheral = nil
            throw e
        } catch {
            peripheral = nil
            noteIfPairing(error, during: "connect")
            log.warn("Wi-Fi handover: connecting to \(name) via \(route) failed: \(Self.errorName(error))")
            return nil
        }
        connectedName = name
        resetLink()
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedPeripheralKey)
        let total = (clock.now - started).inSeconds
        let attemptSeconds = (clock.now - attemptStart).inSeconds
        status = "connected to \(name)"
        log.note(String(format: "Wi-Fi handover: connected to %@ via %@ in %.2f s (%.2f s since Connect)", name, route, attemptSeconds, total))
        return name
    }

    // MARK: - Discover

    /// Lists every service and characteristic UUID with its properties (no values), keeps every characteristic of
    /// 8000CC00 by its short code, logs which of them can notify or indicate (codes only), and records
    /// `<record>.services` and `<record>.cameraControl` (ble.handover.* by default; nil records nothing, for callers
    /// that record their own outcome, such as the Wi-Fi runs' join over Bluetooth).
    func discover(record: String? = "ble.handover") async throws -> HandoverInventory {
        try await run("Discover") {
            try await self.doDiscover(record: record)
        }
    }

    private func doDiscover(record: String? = "ble.handover") async throws -> HandoverInventory {
        let p = try connectedPeripheral()
        let started = clock.now
        status = "discovering services"
        // Subscriptions stay: they belong to the link, not to this listing.
        cc = [:]
        ccAll = [:]
        discovered = false
        _ = try await wait("services", timeout: 15, what: "service discovery") {
            p.discoverServices(nil)
        }
        let services = p.services ?? []
        var inventory = HandoverInventory(services: services.map(\.uuid.uuidString), characteristics: [:],
                                          hasCameraControl: false, found: [:])
        for code in Self.codes { inventory.found[code] = false }
        log.note("Wi-Fi handover: \(services.count) services: \(inventory.services.joined(separator: ", "))")
        for service in services {
            status = "discovering characteristics of \(service.uuid.uuidString)"
            _ = try await wait("chars:\(service.uuid.uuidString)", timeout: 15,
                               what: "characteristic discovery for \(service.uuid.uuidString)") {
                p.discoverCharacteristics(nil, for: service)
            }
            let isControl = Self.isCameraControl(service.uuid)
            if isControl { inventory.hasCameraControl = true }
            var lines: [String] = []
            for c in service.characteristics ?? [] {
                let line = "\(c.uuid.uuidString) (\(Self.describe(c.properties)))"
                lines.append(line)
                if isControl, let code = Self.shortCode(c.uuid) {
                    ccAll[code] = c
                    if Self.codes.contains(code) {
                        cc[code] = c
                        inventory.found[code] = true
                    }
                }
            }
            inventory.characteristics[service.uuid.uuidString] = lines
            log.note("  \(service.uuid.uuidString)\(service.isPrimary ? "" : " (secondary)"): \(lines.isEmpty ? "no characteristics" : lines.joined(separator: ", "))")
        }
        discovered = true
        inventory.notifiable = notifiableCodes
        if inventory.hasCameraControl {
            log.note("Wi-Fi handover: 8000CC00 has \(ccAll.count) characteristics with a short code; \(inventory.notifiable.count) can notify or indicate: \(inventory.notifiable.isEmpty ? "none" : inventory.notifiable.joined(separator: ", "))")
        }
        let present = Self.codes.filter { inventory.found[$0] == true }
        let absent = Self.codes.filter { inventory.found[$0] != true }
        let seconds = (clock.now - started).inSeconds
        if let record {
            log.measure("\(record).services", Double(services.count), "count",
                        context: String(format: "%@, discovered in %.2f s", connectedName ?? "camera", seconds))
            log.flag("\(record).cameraControl", inventory.hasCameraControl,
                     context: inventory.hasCameraControl
                        ? "8000CC00 present; \(present.isEmpty ? "none" : present.joined(separator: ", ")) found\(absent.isEmpty ? "" : ", \(absent.joined(separator: ", ")) missing")"
                        : "no 8000CC00 service")
        } else {
            log.note(String(format: "Wi-Fi handover: %ld services discovered in %.2f s; 8000CC00 %@ (not recorded as ble.handover.*)",
                            services.count, seconds, inventory.hasCameraControl ? "present" : "absent"))
        }
        status = "discovered \(services.count) services; \(present.count) of \(Self.codes.count) CC characteristics"
        return inventory
    }

    // MARK: - Safe reads

    /// Reads CC0A (firmware), CC0B (model), CC09 (status, parsed) and, for other readable CC characteristics except
    /// CC06/CC07/CC0C, logs only the length. ATT errors are logged by name; a disconnect throws. Returns the Wi-Fi
    /// status: the merged CC09 state's tag 0x0001, else the value's (wifiStatus(in:)); nil when unknown.
    func safeReads() async throws -> Int? {
        try await run("Safe reads") {
            try await self.doSafeReads()
        }
    }

    private func doSafeReads() async throws -> Int? {
        _ = try connectedPeripheral()
        if !discovered { _ = try await doDiscover() }
        status = "reading firmware, model and status"
        for (code, label) in [("CC0A", "firmware"), ("CC0B", "model")] {
            guard let c = cc[code] else { log.note("Wi-Fi handover: no \(code) (\(label))"); continue }
            switch try await read(c, code: code) {
            case .value(let data): log.note("Wi-Fi handover: \(code) \(label): \(Self.describeInfo(data))")
            case .failed(let reason): log.warn("Wi-Fi handover: \(code) \(label) read failed: \(reason)")
            }
        }
        var wifiStatus: Int?
        if let c = cc["CC09"] {
            if c.properties.contains(.read) {
                switch try await read(c, code: "CC09") {
                case .value(let data):
                    // The merged state first (the read has just been merged into it), the value itself as a fallback.
                    wifiStatus = currentWiFiStatus() ?? Self.wifiStatus(in: data)
                    log.note("Wi-Fi handover: CC09 status: \(Self.describeCC09(data))\(Self.statusByteNote(data))")
                case .failed(let reason):
                    log.warn("Wi-Fi handover: CC09 status read failed: \(reason)")
                }
            } else {
                log.note("Wi-Fi handover: CC09 isn't readable (\(Self.describe(c.properties))); its status arrives only by notification")
            }
        } else {
            log.note("Wi-Fi handover: no CC09 (status)")
        }
        let others = cc.filter { code, c in
            !["CC0A", "CC0B", "CC09"].contains(code) && !Self.secretCodes.contains(code) && c.properties.contains(.read)
        }
        for (code, c) in others.sorted(by: { $0.key < $1.key }) {
            switch try await read(c, code: code) {
            case .value(let data): log.note("Wi-Fi handover: \(code) readable, \(data.count) B (value not logged)")
            case .failed(let reason): log.warn("Wi-Fi handover: \(code) read failed: \(reason)")
            }
        }
        // Build 14: CCAB (the Wi-Fi band, per the notes), masked, with the Wi-Fi status just read for comparison.
        _ = try await doReadWiFiBand("at the safe reads, Wi-Fi status \(wifiStatus == nil ? "unknown" : Self.shownStatus(wifiStatus))")
        status = "safe reads done; Wi-Fi status \(wifiStatus == nil ? "unknown" : Self.shownStatus(wifiStatus))"
        return wifiStatus
    }

    /// Build 11: one harmless CC09 read (`why` names it in the log), for a baseline or a final status. Returns the
    /// Wi-Fi status as safeReads does; nil when CC09 can't be read or the status is unknown. A disconnect throws.
    func readStatus(_ why: String) async throws -> Int? {
        try await run("Read CC09") {
            try await self.doReadStatus(why)
        }
    }

    private func doReadStatus(_ why: String) async throws -> Int? {
        try await doReadCC09(why, previous: nil, polling: false).status
    }

    /// Build 14: one harmless CC09 read for a polling loop (`why` names it in the log). Its log line is written only
    /// when the value differs from `previous` (the loop's previous value; nil: always), so a poll that sees the same
    /// value every 2 s doesn't fill the log; a failed read is always logged. Returns the Wi-Fi status, as readStatus
    /// does, and the value read (nil when CC09 can't be read or the read failed). Never writes; a disconnect throws.
    func pollWiFiStatus(_ why: String, previous: Data?) async throws -> (status: Int?, value: Data?) {
        try await run("Read CC09") {
            try await self.doReadCC09(why, previous: previous, polling: true)
        }
    }

    /// readStatus and pollWiFiStatus: `polling` logs the value only when it differs from `previous`.
    private func doReadCC09(_ why: String, previous: Data?, polling: Bool) async throws -> (status: Int?, value: Data?) {
        _ = try connectedPeripheral()
        if !discovered { _ = try await doDiscover() }
        guard let c = cc["CC09"], c.properties.contains(.read) else {
            log.note("Wi-Fi handover: CC09 isn't readable, so no status read \(why)")
            return (status: nil, value: nil)
        }
        status = "reading the camera's status"
        switch try await read(c, code: "CC09") {
        case .value(let data):
            let s = currentWiFiStatus() ?? Self.wifiStatus(in: data)
            if !polling || previous != data {
                log.note("Wi-Fi handover: CC09 \(why) (read): \(Self.describeCC09(data))\(Self.statusByteNote(data))")
            }
            status = "Wi-Fi status \(s == nil ? "unknown" : Self.shownStatus(s))"
            return (status: s, value: data)
        case .failed(let reason):
            log.warn("Wi-Fi handover: CC09 read \(why) failed: \(reason)")
            status = "CC09 read failed: \(reason)"
            return (status: nil, value: nil)
        }
    }

    // MARK: - Wi-Fi band (build 14)

    /// What one CCAB read gave: masked for the log and contexts, plus the first value byte when the value parses in
    /// the [length 1 B][tag 2 B BE][value] layout CC09 has (`value`: unmasked, for a measurement only when ≤ 0x0F).
    struct WiFiBandRead {
        let length: Int
        let masked: String
        /// "[length][tag][value]: tag 0x00··, value 1" or "not in the [length][tag][value] layout".
        let layout: String
        let value: Int?
    }

    nonisolated static let wifiBandLogPrefix = "CCAB (Wi-Fi band, per the notes; mapping unverified)"

    /// Build 14: one harmless read of CCAB, "Wi-Fi Freq: 2.4GHz / 5GHz status" (read) in 8000CC00 per the
    /// reverse-engineered notes on Sony's service list (the α7C II offers it with read); its layout is unknown. Logged
    /// with its length and masked bytes and, when it parses as CC09's [length][tag][value] entries, the first entry's
    /// tag and value (masked). Returns nil when CCAB isn't offered, isn't readable or the read failed (all logged).
    /// Never writes; a disconnect throws. `why` names the moment in the log.
    func readWiFiBand(_ why: String) async throws -> WiFiBandRead? {
        try await run("Read CCAB") {
            try await self.doReadWiFiBand(why)
        }
    }

    private func doReadWiFiBand(_ why: String) async throws -> WiFiBandRead? {
        _ = try connectedPeripheral()
        if !discovered { _ = try await doDiscover() }
        guard let c = ccAll["CCAB"] else {
            log.note("\(Self.wifiBandLogPrefix): not offered by the camera (\(why))")
            return nil
        }
        guard c.properties.contains(.read) else {
            log.note("\(Self.wifiBandLogPrefix): not readable (\(Self.describe(c.properties))) (\(why))")
            return nil
        }
        switch try await read(c, code: "CCAB") {
        case .value(let data):
            let masked = Self.maskedHex(data)
            if let entries = Self.alpha7CIIEntries(data), let first = entries.first {
                let layout = "[length][tag][value]: tag \(Self.maskedTag(first.tag)), value \(Self.cc09ValueText(first.value))"
                    + (entries.count > 1 ? " (+\(entries.count - 1) more entries)" : "")
                log.note("\(Self.wifiBandLogPrefix): \(why): \(data.count) B: \(masked); \(layout)")
                return WiFiBandRead(length: data.count, masked: masked, layout: layout, value: first.value.first.map { Int($0) })
            }
            let layout = "not in the [length][tag][value] layout"
            log.note("\(Self.wifiBandLogPrefix): \(why): \(data.count) B: \(masked); \(layout)")
            return WiFiBandRead(length: data.count, masked: masked, layout: layout, value: nil)
        case .failed(let reason):
            log.warn("\(Self.wifiBandLogPrefix): read \(why) failed: \(reason)")
            return nil
        }
    }

    // MARK: - Wi-Fi status (build 13)

    /// The camera's Wi-Fi status in the merged CC09 state: tag 0x0001's first value byte (0 terminated, 1 launching,
    /// 2 launched, 3 terminating, per the notes), as last read or notified on this link (kept after the camera drops
    /// the link, until the next connection). Nil when unknown. The unmasked number: log it with `shownStatus`.
    func currentWiFiStatus() -> Int? {
        Self.statusInState(cc09State)
    }

    /// One harmless CC09 read (readStatus, `why` names it in the log); returns the Wi-Fi status, merged state first.
    /// Nil when CC09 can't be read or the status is unknown; a disconnect throws.
    func readWiFiStatus(_ why: String = "for the Wi-Fi status") async throws -> Int? {
        try await readStatus(why)
    }

    /// Waits until the Wi-Fi status (the merged state's, else the learnt status byte in CC09's latest value) is in
    /// `target` or `timeout` seconds pass. Watches CC09's notifications; reads CC09 once a second only while CC09
    /// isn't notifying. Never writes anything. Ends early when the link drops or another operation is running (both
    /// logged). Returns the status at the end (nil: unknown), the seconds waited and the status's values with times
    /// ("0 → 1 (+0.09 s) → 2 (+2.22 s)").
    func waitForWiFiStatus(_ target: Set<Int>, timeout: Double) async -> (status: Int?, seconds: Double, sequence: String) {
        let started = clock.now
        func statusNow() -> Int? {
            currentWiFiStatus() ?? cc09Latest.flatMap { Self.wifiStatus(in: $0) }
        }
        var current = statusNow()
        var sequence: [String] = [Self.shownStatus(current)]
        let wanted = target.sorted().map { Self.shownStatus($0) }.joined(separator: " or ")
        guard !busy else {
            log.warn("Wi-Fi handover: wait for Wi-Fi status \(wanted) refused: another operation is running")
            return (current, 0, sequence.joined(separator: " → "))
        }
        busy = true
        defer { busy = false }
        status = "waiting for Wi-Fi status \(wanted) (up to \(Int(timeout)) s)"
        let link = peripheral
        var nextPoll = clock.now
        var pollingStopped = false
        var ending = "timed out"
        while true {
            if let s = current, target.contains(s) {
                ending = "reached"
                break
            }
            guard let p = link, peripheral === p, p.state == .connected else {
                ending = "the Bluetooth link is down"
                break
            }
            if (clock.now - started).inSeconds >= timeout { break }
            if let c09 = cc["CC09"], !c09.isNotifying, c09.properties.contains(.read), !pollingStopped, clock.now >= nextPoll {
                nextPoll = clock.now + .seconds(1)
                do {
                    let outcome = try await read(c09, code: "CC09", timeout: 5)
                    if case .failed(let reason) = outcome {
                        log.warn("Wi-Fi handover: CC09 poll failed (\(reason)) while waiting for the Wi-Fi status; polling stops")
                        pollingStopped = true
                    }
                } catch {
                    ending = "stopped: \(Self.errorName(error))"
                    break
                }
            } else {
                try? await Task.sleep(for: .milliseconds(250))
            }
            let now = statusNow()
            if now != current {
                sequence.append("\(Self.shownStatus(now)) (" + String(format: "+%.2f s", (clock.now - started).inSeconds) + ")")
                current = now
            }
        }
        let seconds = (clock.now - started).inSeconds
        let text = sequence.joined(separator: " → ")
        log.note(String(format: "Wi-Fi handover: waited %.1f s for Wi-Fi status %@ (%@): %@", seconds, wanted, ending, text))
        status = "Wi-Fi status \(current == nil ? "unknown" : Self.shownStatus(current)) after \(Int(seconds)) s"
        return (current, seconds, text)
    }

    /// Merges a CC09 value into cc09State when it parses as the α7C II layout; nil when it doesn't (the caller
    /// falls back to byteChanges and the status byte).
    private func mergeCC09(_ value: Data) -> CC09Merge? {
        guard let entries = Self.alpha7CIIEntries(value) else { return nil }
        let before = cc09State
        for entry in entries { cc09State[entry.tag] = entry.value }
        return CC09Merge(changes: Self.tagChanges(old: before, new: cc09State), first: before.isEmpty)
    }

    // MARK: - Subscriptions (build 11)

    /// Turns notifications on for `codes` in 8000CC00 (nil: every characteristic there that can notify or indicate),
    /// as Sony's app does for CC09, CC10, CC0F, CC03 and CC0E when it connects. Each is a descriptor write iOS makes
    /// for setNotifyValue, answered within 10 s; a failure is logged by name and the next code is tried, a
    /// disconnect throws. Codes that are absent or can't notify are logged and skipped. Sets a timeline mark, waits
    /// 1 s for the first notifications, and records ble.handover.subscribed. Returns the codes now notifying.
    /// `attempt` (build 13): the run that subscribes, named in ble.handover.subscribed's context (nil: none named).
    func subscribe(_ codes: [String]?, attempt: String? = nil) async throws -> [String] {
        try await run("Subscribe") {
            try await self.doSubscribe(codes, attempt: attempt)
        }
    }

    private func doSubscribe(_ codes: [String]?, attempt: String?) async throws -> [String] {
        let p = try connectedPeripheral()
        if !discovered { _ = try await doDiscover() }
        let requests = disconnectRequests
        let wanted = codes ?? notifiableCodes
        let label = codes == nil ? "every 8000CC00 notification (\(wanted.count))" : wanted.joined(separator: ", ")
        markTimeline("Subscribe: \(label)")
        var done: [String] = []
        var skipped: [String: String] = [:]
        var failed: [String: String] = [:]
        for code in wanted {
            guard let c = ccAll[code] else {
                log.note("Wi-Fi handover: \(code) isn't in 8000CC00; not subscribed")
                skipped[code] = "absent"
                continue
            }
            guard Self.canNotify(c) else {
                log.note("Wi-Fi handover: \(code) can't notify (\(Self.describe(c.properties))); not subscribed")
                skipped[code] = "can't notify"
                continue
            }
            if let reason = try await enableNotifications(code, c, p) {
                failed[code] = reason
            } else {
                done.append(code)
            }
        }
        status = "collecting the first notifications"
        try? await Task.sleep(for: .seconds(1))
        guard peripheral === p, p.state == .connected else {
            if disconnectRequests != requests { throw HandoverError.cancelled("Disconnect") }
            throw HandoverError.disconnected("the link dropped after subscribing")
        }
        let initial = timeline.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value.count)" }
        var sony: [String] = []
        for code in Self.sonyNotificationCodes where !done.contains(code) {
            if let reason = failed[code] {
                sony.append("\(code) failed (\(reason))")
            } else if let reason = skipped[code] {
                sony.append("\(code) \(reason)")
            } else {
                sony.append("\(code) not requested")
            }
        }
        let failures = failed.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }
        let skips = skipped.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }
        let summary = "\(done.count) of \(wanted.count) requested now notifying: \(done.isEmpty ? "none" : done.joined(separator: ", "))"
            + (failures.isEmpty ? "" : "; failed: \(failures.joined(separator: ", "))")
            + (skips.isEmpty ? "" : "; skipped: \(skips.joined(separator: ", "))")
        log.note("Wi-Fi handover: subscribed (\(label)): \(summary); first second: \(initial.isEmpty ? "no notifications" : initial.joined(separator: ", "))")
        log.measure("ble.handover.subscribed", Double(done.count), "count",
                    context: "\(attempt.map { "attempt \($0): " } ?? "")\(codes == nil ? "every 8000CC00 notification" : "requested \(label)"):\(done.isEmpty ? "none" : done.joined(separator: ", ")); Sony's set (CC09, CC10, CC0F, CC03, CC0E): \(sony.isEmpty ? "all subscribed" : sony.joined(separator: ", ") + ", the rest subscribed")")
        status = "subscribed to \(subscribedCodes.count) characteristic(s)"
        return done
    }

    /// One setNotifyValue(true) and its answer (10 s). Nil when notifications are on (or already were), else why
    /// not (logged). Throws only for a disconnect, a Disconnect tap or Bluetooth going off.
    private func enableNotifications(_ code: String, _ c: CBCharacteristic, _ p: CBPeripheral) async throws -> String? {
        if c.isNotifying {
            subscribedCodes.insert(code)
            everSubscribed.insert(code)
            return nil
        }
        status = "subscribing to \(code)"
        // Counted as this app's from the request on, so a first notification that beats the answer isn't marked as
        // unsolicited; taken back if the subscription fails. everSubscribed keeps it after a timeout or a dropped
        // link (the request may still have reached the camera), not after a refusal.
        let wasEver = everSubscribed.contains(code)
        subscribedCodes.insert(code)
        everSubscribed.insert(code)
        do {
            _ = try await wait("notify:\(c.uuid.uuidString)", timeout: 10, what: "\(code) subscription") {
                p.setNotifyValue(true, for: c)
            }
        } catch let e as HandoverError where !e.isTimeout {
            throw e
        } catch {
            subscribedCodes.remove(code)
            let timedOut = (error as? HandoverError)?.isTimeout == true
            if !timedOut && !wasEver { everSubscribed.remove(code) }
            noteIfPairing(error, during: "\(code) subscription")
            let reason = Self.errorName(error)
            log.warn("Wi-Fi handover: \(code) subscription failed: \(reason)")
            return reason
        }
        guard c.isNotifying else {
            subscribedCodes.remove(code)
            if !wasEver { everSubscribed.remove(code) }
            log.warn("Wi-Fi handover: \(code) subscription answered, but isNotifying is no")
            return "isNotifying no"
        }
        return nil
    }

    /// Turns off every notification on in 8000CC00 (those this app turned on, and any the characteristic objects
    /// report as on), one at a time, each waiting up to 5 s for the camera's answer, and logs which were confirmed
    /// off and which weren't. Returns the codes not confirmed off. A disconnect throws; Disconnect still turns off
    /// whatever is left without waiting.
    func unsubscribeAll() async throws -> [String] {
        try await run("Unsubscribe") {
            try await self.doUnsubscribeAll()
        }
    }

    private func doUnsubscribeAll() async throws -> [String] {
        let p = try connectedPeripheral()
        // Switches turned on over an earlier link first: on and off again over this one (CCCD writes only).
        let earlier = earlierLinkCodes
        var unconfirmedEarlier: [String] = []
        if !earlier.isEmpty {
            if !discovered { _ = try await doDiscover(record: nil) }
            unconfirmedEarlier = try await clearEarlierLinkCodes(earlier, p)
        }
        let targets = notifyingCharacteristics()
        guard !targets.isEmpty else {
            log.note("Wi-Fi handover: no notifications on in 8000CC00 over this link; nothing more to turn off")
            return unconfirmedEarlier
        }
        var confirmed: [String] = []
        var unconfirmed: [String] = unconfirmedEarlier
        for (code, c) in targets {
            status = "turning off \(code)'s notifications"
            do {
                _ = try await wait("notify:\(c.uuid.uuidString)", timeout: 5, what: "\(code) notifications off") {
                    p.setNotifyValue(false, for: c)
                }
                if c.isNotifying {
                    unconfirmed.append("\(code) (answered, isNotifying still yes)")
                } else {
                    confirmed.append(code)
                    subscribedCodes.remove(code)
                    everSubscribed.remove(code)
                }
            } catch let e as HandoverError where !e.isTimeout {
                log.warn("Wi-Fi handover: turning notifications off stopped at \(code) (\(e)); off: \(confirmed.isEmpty ? "none" : confirmed.joined(separator: ", "))")
                throw e
            } catch {
                unconfirmed.append("\(code) (\(Self.errorName(error)))")
            }
        }
        log.note("Wi-Fi handover: notifications turned off, confirmed by the camera, for \(confirmed.count) of \(targets.count): \(confirmed.isEmpty ? "none" : confirmed.joined(separator: ", "))\(unconfirmed.isEmpty ? "" : "; not confirmed: " + unconfirmed.joined(separator: ", "))")
        if !unconfirmed.isEmpty {
            log.warn("Wi-Fi handover: \(unconfirmed.count) notification(s) not confirmed off; the camera may keep them on for this phone (a bonded client) until another app turns them off")
        }
        status = "notifications off for \(confirmed.count) of \(targets.count)"
        return unconfirmed
    }

    /// Codes turned on over an earlier link (`codes`, none notifying over this one): each is turned on (10 s for the
    /// answer) and off again (5 s), descriptor writes inside 8000CC00 only, so the switch the bonded camera keeps
    /// from the earlier link is cleared; CoreBluetooth sends no "off" for a characteristic it thinks is already off.
    /// Logs which were cleared and which couldn't be confirmed, and returns the latter. A disconnect throws.
    private func clearEarlierLinkCodes(_ codes: [String], _ p: CBPeripheral) async throws -> [String] {
        log.note("Wi-Fi handover: \(codes.count) notification(s) this app turned on over an earlier link, not on over this one: \(codes.joined(separator: ", ")); turning each on and off again so the camera doesn't keep them on")
        var cleared: [String] = []
        var unconfirmed: [String] = []
        for code in codes {
            guard let c = ccAll[code], Self.canNotify(c) else {
                unconfirmed.append("\(code) (earlier link; not in 8000CC00 over this link)")
                continue
            }
            if let reason = try await enableNotifications(code, c, p) {
                unconfirmed.append("\(code) (earlier link; turning it on again failed: \(reason))")
                continue
            }
            status = "turning off \(code)'s notifications (earlier link)"
            do {
                _ = try await wait("notify:\(c.uuid.uuidString)", timeout: 5, what: "\(code) notifications off") {
                    p.setNotifyValue(false, for: c)
                }
                if c.isNotifying {
                    unconfirmed.append("\(code) (earlier link; answered, isNotifying still yes)")
                } else {
                    cleared.append(code)
                    subscribedCodes.remove(code)
                    everSubscribed.remove(code)
                }
            } catch let e as HandoverError where !e.isTimeout {
                log.warn("Wi-Fi handover: clearing the earlier link's notifications stopped at \(code) (\(e)); cleared: \(cleared.isEmpty ? "none" : cleared.joined(separator: ", "))")
                throw e
            } catch {
                unconfirmed.append("\(code) (earlier link; \(Self.errorName(error)))")
            }
        }
        log.note("Wi-Fi handover: earlier link's notifications cleared, confirmed by the camera, for \(cleared.count) of \(codes.count): \(cleared.isEmpty ? "none" : cleared.joined(separator: ", "))\(unconfirmed.isEmpty ? "" : "; not confirmed: " + unconfirmed.joined(separator: ", "))")
        return unconfirmed
    }

    /// The characteristics of 8000CC00 with notifications on, or turned on by this app on this link, by code:
    /// those discovered (ccAll) plus any in the peripheral's current 8000CC00 service, sorted by code.
    private func notifyingCharacteristics() -> [(String, CBCharacteristic)] {
        var found: [String: CBCharacteristic] = [:]
        for (code, c) in ccAll where c.isNotifying || subscribedCodes.contains(code) { found[code] = c }
        if let p = peripheral, let service = p.services?.first(where: { Self.isCameraControl($0.uuid) }) {
            for c in service.characteristics ?? [] where c.isNotifying {
                if let code = Self.shortCode(c.uuid), found[code] == nil { found[code] = c }
            }
        }
        return found.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    // MARK: - Notification timeline (build 11)

    /// Starts a new timeline: the times of the notifications logged from now on are from here, and the counts and
    /// timelineSummary() start again. Logs the label.
    func markTimeline(_ label: String) {
        clearTimeline()
        timelineOrigin = clock.now
        timelineLabel = label
        cc09AtMark = cc09Latest
        cc09StateAtMark = cc09State
        log.note("Wi-Fi handover: timeline mark \"\(label)\" (notification times below are from here)")
    }

    private func clearTimeline() {
        timeline = [:]
        timelineOrigin = nil
        timelineLabel = "none"
        liveLines = 0
        silentLines = 0
        cc09History = []
        cc09AtMark = nil
        cc09StateAtMark = [:]
        linkDroppedAt = nil
    }

    /// Per characteristic since the latest mark: how many notifications, the first and last time, and the last value
    /// masked (CC06, CC07, CC0C: its length). Logged and returned.
    @discardableResult
    func timelineSummary() -> String {
        let since = timelineOrigin.map { (clock.now - $0).inSeconds } ?? 0
        let entries = timeline.sorted { a, b in
            a.value.first != b.value.first ? a.value.first < b.value.first : a.key < b.key
        }
        let total = entries.reduce(0) { $0 + $1.value.count }
        var text: String
        if entries.isEmpty {
            text = "no notifications"
        } else {
            let parts = entries.map { item -> String in
                let e = item.value
                let last = e.lastValue.map { Self.maskedHex($0) } ?? "\(e.lastLength) B (value not logged)"
                return "\(item.key) ×\(e.count) (" + String(format: "+%.2f s … +%.2f s", e.first, e.last) + "), last \(last)"
            }
            text = "\(total) notification(s) from \(entries.count) characteristic(s): " + parts.joined(separator: "; ")
        }
        if silentLines > 0 { text += " (\(silentLines) not logged live)" }
        log.note("Wi-Fi handover: timeline since \"\(timelineLabel)\" (" + String(format: "%.1f s", since) + "): \(text)")
        return text
    }

    /// CC09 since the latest mark: the Wi-Fi status's values with times, when CC09 first changed (its merged state when
    /// both values parse, else its bytes) and when the status first changed to 2. The status is the merged state's
    /// tag 0x0001; only for values that don't parse as the α7C II layout, the status byte (remembered, else the byte
    /// that went 0 → 1 → 2, which is then remembered; a 0 → 1 → 2 at another byte than the remembered one replaces
    /// it; nothing is learnt when the merged state carried the status). No I/O but the log line for a learnt byte.
    func cc09Watch() -> CC09Watch {
        let history = cc09History
        let markMerged = Self.statusInState(cc09StateAtMark)
        let usesTags = markMerged != nil || history.contains { $0.merged != nil }
        let values = (cc09AtMark.map { [$0] } ?? []) + history.map(\.value)
        var position = Self.savedStatusByte()
        var source: String
        if usesTags {
            source = "CC09 tag 0x0001 (α7C II layout)" + (position.map { "; status byte [\($0)] only for values that don't parse" } ?? "")
        } else {
            source = position.map { "status byte [\($0)], remembered (\(Self.savedStatusByteSource()))" } ?? "unknown: no tag 0x0001 and no byte went 0 → 1 → 2"
            if let learnt = Self.launchPosition(values), learnt != position {
                let replaced = position
                // A remembered byte that went 0 → 1 → 2 itself keeps its place; otherwise the byte that did wins.
                if replaced == nil || Self.launchPosition(values, only: replaced) == nil {
                    position = learnt
                    source = "status byte [\(learnt)], the byte that went 0 → 1 → 2 during the watch" + (replaced.map { ", replacing [\($0)]" } ?? "")
                    Self.saveStatusByte(learnt, source: "0 → 1 → 2 in a watch")
                    log.measure("ble.handover.cc09.statusByte", Double(learnt), "index",
                                context: "learnt from the watch (\"\(timelineLabel)\"): the byte that went 0 → 1 → 2\(replaced.map { "; replaces [\($0)], which didn't" } ?? ""); remembered for later runs")
                }
            }
        }
        /// The merged status when the value parsed, else the status byte, else a fallback layout's tag 0x0001.
        func statusOf(_ value: Data?, merged: Int?) -> Int? {
            if let merged { return merged }
            guard let value, Self.alpha7CIIEntries(value) == nil else { return nil }
            return position.flatMap { Self.byte(at: $0, in: value) } ?? Self.describeStatus(value).status
        }
        var previousValue = cc09AtMark
        var previousState = cc09StateAtMark
        var previousStatus = statusOf(cc09AtMark, merged: markMerged)
        var firstChangeAt: Double?
        var launchedAt: Double?
        var sawLaunched = previousStatus == 2
        var lastShown = previousStatus
        var sequence: [String] = [Self.shownStatus(lastShown)]
        for item in history {
            let changed: Bool
            if !item.state.isEmpty && !previousState.isEmpty {
                changed = item.state != previousState
            } else if let old = previousValue {
                changed = old != item.value
            } else {
                changed = false
            }
            if changed, firstChangeAt == nil { firstChangeAt = item.at }
            previousValue = item.value
            if !item.state.isEmpty { previousState = item.state }
            let s = statusOf(item.value, merged: item.merged)
            if let s, s != lastShown {
                sequence.append("\(Self.shownStatus(s)) (" + String(format: "+%.2f s", item.at) + ")")
                lastShown = s
            }
            if s == 2 {
                sawLaunched = true
                // Only a change to 2 from a known other status counts as the launch.
                if launchedAt == nil, let before = previousStatus, before != 2 { launchedAt = item.at }
            }
            if s != nil { previousStatus = s }
        }
        let current = currentWiFiStatus() ?? statusOf(cc09Latest, merged: nil)
        let total = timeline.values.reduce(0) { $0 + $1.count }
        return CC09Watch(notifications: total, cc09Notifications: history.count, position: position,
                         positionSource: source, sequence: sequence.joined(separator: " → "),
                         firstChangeAt: firstChangeAt, launchedAt: launchedAt, sawLaunched: sawLaunched, current: current)
    }

    /// Build 14: CC09's tag changes since the latest mark other than the Wi-Fi status (tag 0x0001), from its
    /// notifications (reads aren't in the history), masked like `tagChanges` and with times from the mark: "+12.40 s
    /// tag 0x0003 remote control available 1 → 0". Values that don't parse as the α7C II layout are skipped; with no
    /// known state at the mark, the first parsed value only sets the baseline. No I/O.
    func cc09OtherTagChanges() -> [String] {
        var before = cc09StateAtMark
        before[0x0001] = nil
        var out: [String] = []
        for item in cc09History where !item.state.isEmpty {
            var state = item.state
            state[0x0001] = nil
            if !before.isEmpty, state != before {
                out.append(String(format: "+%.2f s ", item.at) + Self.tagChanges(old: before, new: state))
            }
            before = state
        }
        return out
    }

    /// A value of a characteristic in 8000CC00 that wasn't the answer to a read: counted on the timeline, logged
    /// live as a change from the previous value (masked; CC06, CC07, CC0C as a length; CC09 per tag of its merged
    /// state when `merge` is given, as a byte diff otherwise), up to liveLineCap lines per mark.
    private func recordNotification(_ code: String, _ value: Data, merge: CC09Merge? = nil) {
        let now = clock.now
        if timelineOrigin == nil {
            timelineOrigin = now
            timelineLabel = "first notification"
        }
        let at = (now - (timelineOrigin ?? now)).inSeconds
        let secret = Self.secretCodes.contains(code)
        let change: String
        if secret {
            let was = previousLength[code].map { $0 == value.count ? "" : ", was \($0) B" } ?? ""
            change = "\(value.count) B (value not logged\(was))"
        } else if code == "CC09", let merge {
            change = merge.changes
        } else {
            change = Self.byteChanges(old: previous[code], new: value)
        }
        // A notification this app didn't turn on in this connection (left on from an earlier run, say).
        let unsolicited = subscribedCodes.contains(code) ? "" : " (not subscribed by this app on this link)"
        var entry = timeline[code] ?? TimelineEntry(first: at, last: at)
        entry.count += 1
        entry.last = at
        entry.lastLength = value.count
        entry.lastValue = secret ? nil : value
        timeline[code] = entry
        remember(code, value)
        if code == "CC09" {
            let update = CC09Update(instant: now, at: at, value: value, state: merge == nil ? [:] : cc09State,
                                    merged: merge == nil ? nil : currentWiFiStatus())
            if cc09History.count < 2000 { cc09History.append(update) }
            if cc09Watching { cc09Queue.append(update) }
        }
        // switchWiFiOn logs CC09's changes itself while it waits, with the status byte read.
        if code == "CC09" && cc09Watching { return }
        if liveLines < Self.liveLineCap {
            liveLines += 1
            log.note("Wi-Fi handover: " + String(format: "+%.2f s", at) + " \(code) notify: \(change)\(unsolicited)")
            if liveLines == Self.liveLineCap {
                log.note("Wi-Fi handover: \(Self.liveLineCap) notification lines since \"\(timelineLabel)\"; further ones are only counted until the next mark")
            }
        } else {
            silentLines += 1
        }
    }

    /// Keeps `value` for the next diff; for CC06, CC07 and CC0C only its length.
    private func remember(_ code: String, _ value: Data) {
        if Self.secretCodes.contains(code) {
            previousLength[code] = value.count
        } else {
            previous[code] = value
        }
    }

    /// Forgets the link's characteristics, subscriptions and remembered values. With `keepTimeline` (the camera
    /// dropping the link, Bluetooth off) the timeline, CC09's history, its latest value and switchWiFiOn's queue stay,
    /// so the run can still report what came before the drop, and the drop's time is noted; they go at the next
    /// mark, the next connection or Disconnect.
    private func resetLink(keepTimeline: Bool = false) {
        cc = [:]
        ccAll = [:]
        discovered = false
        subscribedCodes = []
        previous = [:]
        previousLength = [:]
        if keepTimeline {
            if let origin = timelineOrigin, linkDroppedAt == nil { linkDroppedAt = (clock.now - origin).inSeconds }
            return
        }
        clearTimeline()
        cc09Latest = nil
        cc09State = [:]
        cc09Queue = []
        cc09Watching = false
    }

    // MARK: - Switch Wi-Fi on (the one write)

    /// Writes 0x01 to CC08 with response, then waits up to `timeout` for CC09 to report Wi-Fi status 2. If CC09 can
    /// notify it subscribes first, as Sony's app does, and listens; it polls CC09 once a second when it can't notify
    /// (or the subscription failed), and also when no CC09 notification has come 3 s after the acknowledgement. The
    /// Wi-Fi status is the merged CC09 state's tag 0x0001 (build 13); only for values that don't parse as the α7C II
    /// layout, the status byte: the CC09 byte remembered from an earlier run, else the first byte to change after the
    /// write (one going 0 → 1 preferred); only a 0 → 1 is remembered for later runs (ble.handover.cc09.statusByte). If
    /// the status changes and returns to its value from before the write, it waits 3 s more and stops. Records what CC09
    /// reported as ble.handover.wifiOn.reported (the guided run records what the camera shows),
    /// ble.handover.wifiOn.latency for status 2, ble.handover.cc09.firstChange for the first change of any kind and
    /// ble.handover.linkDroppedAfterWrite, each with `attempt` and the status's values in its context, then logs
    /// timelineSummary() so every characteristic that changed after the write is listed. A link drop after the write
    /// is an outcome, not an error (returns whether CC09 reported status 2 before it); the link is otherwise kept up.
    /// Returns whether CC09 reported status 2. Call only after the tester has confirmed.
    func switchWiFiOn(timeout: Double = 30, attempt: String = "Bluetooth tab") async throws -> Bool {
        try await run("Switch Wi-Fi on") {
            try await self.doSwitchWiFiOn(timeout: timeout, attempt: attempt)
        }
    }

    private func doSwitchWiFiOn(timeout: Double, attempt: String) async throws -> Bool {
        let p = try connectedPeripheral()
        if !discovered { _ = try await doDiscover() }
        lastStatusSequence = "none"
        lastCC09Notifying = nil
        lastSubscribedAtWrite = []
        guard let cc08 = cc["CC08"] else {
            log.flag("ble.handover.wifiOn.reported", false, context: "attempt \(attempt): no CC08 characteristic in 8000CC00; nothing written")
            throw HandoverError.missing("CC08")
        }
        let cc09 = cc["CC09"]
        let readable = cc09?.properties.contains(.read) == true
        var notifying = cc09?.isNotifying == true
        // Sony's app listens for CC09's notifications rather than polling, so subscribe whenever CC09 offers them.
        if let cc09, Self.canNotify(cc09), !notifying {
            if let reason = try await enableNotifications("CC09", cc09, p) {
                log.warn("Wi-Fi handover: CC09 subscription failed (\(reason))\(readable ? "; polling CC09 instead" : "")")
            } else {
                log.note("Wi-Fi handover: subscribed to CC09's notifications before the write, as Sony's app does; they are turned off at the end")
            }
            notifying = cc09.isNotifying
        }
        lastCC09Notifying = notifying
        lastSubscribedAtWrite = subscribedCodes.sorted()
        var pollCC09 = readable && !notifying
        var baseline: Data?
        // The merged state with the baseline in it (empty when the baseline doesn't parse as the α7C II layout) and its
        // Wi-Fi status.
        var baseState: [Int: [UInt8]] = [:]
        var baseMerged: Int?
        if let cc09, readable {
            switch try await read(cc09, code: "CC09") {
            case .value(let data):
                baseline = data
                if Self.alpha7CIIEntries(data) != nil {
                    baseState = cc09State
                    baseMerged = currentWiFiStatus()
                }
                log.note("Wi-Fi handover: CC09 before the write (read): \(Self.describeCC09(data))")
            case .failed(let reason):
                log.warn("Wi-Fi handover: CC09 read before the write failed: \(reason)")
            }
        }
        // Not read: the latest notification (the value the camera sent on subscribing, if any) is the baseline.
        if baseline == nil, let value = cc09Latest {
            baseline = value
            if Self.alpha7CIIEntries(value) != nil {
                baseState = cc09State
                baseMerged = currentWiFiStatus()
            }
            log.note("Wi-Fi handover: CC09 before the write (latest notification): \(Self.describeCC09(value))")
        }
        if !notifying && !pollCC09 {
            log.warn("Wi-Fi handover: CC09 can't be read or subscribed to: the camera's Wi-Fi state can't be seen over Bluetooth after the write; check the camera's screen")
        }
        // The Wi-Fi status: the merged state's tag 0x0001; the status byte (remembered from an earlier run, else
        // learnt from the first change after the write) only for values that don't parse as the α7C II layout.
        var position = Self.savedStatusByte()
        // Some value since the baseline carried the status in the merged state.
        var usedTags = baseMerged != nil
        /// A CC09 value's Wi-Fi status: `merged` (the merged state's, when the value parsed), else the status byte,
        /// else a fallback layout's tag 0x0001; nil for a value that parsed without the status being known.
        func statusOf(_ value: Data?, merged: Int?) -> Int? {
            if let merged { return merged }
            guard let value, Self.alpha7CIIEntries(value) == nil else { return nil }
            return position.flatMap { Self.byte(at: $0, in: value) } ?? Self.describeStatus(value).status
        }
        var statusBaseline: Int? = statusOf(baseline, merged: baseMerged)
        if let position {
            log.measure("ble.handover.cc09.statusByte", Double(position), "index",
                        context: "attempt \(attempt): remembered (\(Self.savedStatusByteSource())); \(usedTags ? "the Wi-Fi status comes from CC09's tag 0x0001, the byte only for values that don't parse" : "value before the write \(statusBaseline == nil ? "unknown" : Self.shownStatus(statusBaseline))")")
        }
        let props = Self.describe(cc08.properties)
        if !cc08.properties.contains(.write) {
            log.warn("Wi-Fi handover: CC08's properties are \(props), without write; trying the write with response anyway")
        }

        markTimeline("CC08 write, attempt \(attempt)")
        cc09Queue = []
        cc09Watching = true
        defer {
            cc09Watching = false
            cc09Queue = []
        }
        status = "writing 0x01 to CC08"
        log.warn("Wi-Fi handover: writing 0x01 to CC08 with response (\(props)), confirmed by the tester; attempt \(attempt); CC09 \(notifying ? "notifying" : (pollCC09 ? "polled once a second" : "not observable"))")
        let updatesBeforeWrite = cc09Updates
        let requestsBeforeWrite = disconnectRequests
        let cancelsBeforeWrite = cancelRequests
        let writeStart = clock.now
        do {
            _ = try await wait("write:\(cc08.uuid.uuidString)", timeout: 15, what: "CC08 write") {
                p.writeValue(Data([0x01]), for: cc08, type: .withResponse)
            }
        } catch let e as HandoverError where !e.isTimeout {
            if case .disconnected(let reason) = e {
                let result = linkDropped(writeStart, attempt: attempt, during: "the CC08 write's acknowledgement", reason: reason,
                                         changes: "none", launchedAt: nil)
                timelineSummary()
                return result
            }
            // Disconnect tapped or Bluetooth off: no answer about the camera's Wi-Fi, so nothing is recorded.
            log.warn("Wi-Fi handover: the CC08 write stopped (\(e)); ble.handover.wifiOn.reported not recorded")
            throw e
        } catch {
            noteIfPairing(error, during: "CC08 write")
            let reason = Self.errorName(error)
            log.error("Wi-Fi handover: CC08 write failed: \(reason)")
            log.flag("ble.handover.wifiOn.reported", false, context: "attempt \(attempt): CC08 ← 0x01 failed: \(reason)")
            status = "CC08 write failed: \(reason)"
            return false
        }
        let ackAt = clock.now
        let ackSeconds = (ackAt - writeStart).inSeconds
        log.note(String(format: "Wi-Fi handover: CC08 ← 0x01 acknowledged in %.0f ms; waiting up to %.0f s for CC09 status 2", ackSeconds * 1000, timeout))

        guard let status09 = cc09, notifying || pollCC09 else {
            status = "CC08 written; no CC09 to confirm (check the camera)"
            log.warn("Wi-Fi handover: ble.handover.wifiOn.reported not recorded: no CC09 status to confirm it; check the camera's screen")
            timelineSummary()
            return false
        }

        var last = baseline
        var lastState = baseState
        var history: [String] = []
        var on = false
        // Seconds from the write to the CC09 value that carried status 2.
        var onElapsed: Double?
        var changed = false
        // The latest known Wi-Fi status, and its values with times since the write.
        var lastKnown = statusBaseline
        var sequence: [String] = [Self.shownStatus(statusBaseline)]
        // When the status went back to its value from before the write: the wait ends 3 s later.
        var returnedAt: ContinuousClock.Instant?
        var gaveUp = false
        var nextPoll = clock.now
        // A CC09 notification has arrived since the write; without one 3 s after the acknowledgement, CC09 is polled.
        var notified = false
        var silencePolling = false
        let alreadyOn = statusBaseline == 2
        let deadline = writeStart + .seconds(timeout)
        status = "waiting for the camera's Wi-Fi (up to \(Int(timeout)) s)"

        /// The Wi-Fi status's values so far, and where they come from, for the contexts.
        func statusText() -> String {
            let source = usedTags ? "Wi-Fi status (CC09 tag 0x0001)"
                : (position.map { "status byte [\($0)]" } ?? "Wi-Fi status (status byte unknown)")
            return "\(source) \(sequence.joined(separator: " → "))"
        }

        /// True only when the Wi-Fi status after `value` is 2 (`merged`, the merged state's, when the value parsed as
        /// the α7C II layout; else the status byte or a fallback layout's tag 0x0001). Every change is logged, per tag
        /// of the merged state when both values parse (a 43-byte read and a 5-byte notification compare by their
        /// tags), else as a byte diff; the first is timed on its own. Without a merged status, the first change also
        /// teaches the status byte if none is known.
        func consider(_ value: Data, state: [Int: [UInt8]], merged: Int?, via source: String,
                      at instant: ContinuousClock.Instant) -> Bool {
            let byTags = !state.isEmpty && !lastState.isEmpty
            if byTags {
                guard state != lastState else { return false }
            } else {
                guard value != last else { return false }
            }
            if merged != nil { usedTags = true }
            let elapsed = (instant - writeStart).inSeconds
            guard let old = last else {
                // Nothing from before the write: this first value is the baseline.
                last = value
                if !state.isEmpty { lastState = state }
                statusBaseline = statusOf(value, merged: merged)
                lastKnown = statusBaseline
                sequence = [Self.shownStatus(statusBaseline)]
                log.note("Wi-Fi handover: " + String(format: "+%.2f s", elapsed) + " since the write, CC09 (\(source)): first value seen, taken as the baseline: \(Self.describeCC09(value))")
                return statusBaseline == 2
            }
            let diff = byTags ? Self.tagChanges(old: lastState, new: state) : Self.byteChanges(old: old, new: value)
            last = value
            if !state.isEmpty { lastState = state }
            if !usedTags, position == nil, let guess = Self.statusByteGuess(old: old, new: value) {
                position = guess.index
                statusBaseline = Self.byte(at: guess.index, in: old)
                lastKnown = statusBaseline
                sequence = [Self.shownStatus(statusBaseline)]
                if guess.zeroToOne {
                    Self.saveStatusByte(guess.index, source: "0 → 1 after CC08")
                    log.measure("ble.handover.cc09.statusByte", Double(guess.index), "index",
                                context: "attempt \(attempt): learnt from CC09's first change after CC08 ← 0x01, a 0 → 1 (\(diff)); remembered for later runs")
                } else {
                    log.measure("ble.handover.cc09.statusByte", Double(guess.index), "index",
                                context: "attempt \(attempt): guessed from CC09's first change after CC08 ← 0x01 (\(diff)); no byte went 0 → 1, so for this attempt only, not remembered")
                }
            }
            let s = statusOf(value, merged: merged)
            if let s, s != lastKnown {
                sequence.append("\(Self.shownStatus(s)) (" + String(format: "+%.2f s", elapsed) + ")")
                lastKnown = s
                returnedAt = s == statusBaseline ? instant : nil
            }
            let statusNote = s.map { "; Wi-Fi status \(Self.shownStatus($0))\(Self.statusMeaning($0))" } ?? ""
            history.append(String(format: "+%.2f s ", elapsed) + diff)
            log.note("Wi-Fi handover: " + String(format: "+%.2f s", elapsed) + " since the write, CC09 (\(source)): \(diff)\(statusNote)")
            if !changed {
                changed = true
                log.measure("ble.handover.cc09.firstChange", elapsed, "s",
                            context: "attempt \(attempt): first change of CC09 after CC08 ← 0x01 (\(source)): \(diff)")
            }
            let launched = s == 2
            if launched && onElapsed == nil { onElapsed = elapsed }
            return launched
        }

        /// Passes CC09's queued notifications to consider() in arrival order; true when one carried status 2.
        func drainQueue() -> Bool {
            guard !cc09Queue.isEmpty else { return false }
            notified = true
            let queued = cc09Queue
            cc09Queue = []
            for item in queued {
                if consider(item.value, state: item.state, merged: item.merged, via: "notification", at: item.instant) { return true }
            }
            return false
        }

        if alreadyOn {
            log.warn("Wi-Fi handover: CC09 already reported status 2 before the write; no latency to measure")
        }
        do {
            waiting: while !alreadyOn && clock.now < deadline {
                // First the notifications already queued, including any that came just before a drop.
                if drainQueue() {
                    on = true
                    break waiting
                }
                guard peripheral === p, p.state == .connected else {
                    if disconnectRequests != requestsBeforeWrite { throw HandoverError.cancelled("Disconnect") }
                    throw HandoverError.disconnected("the link dropped while waiting for the Wi-Fi status")
                }
                // Build 14: cancelWaits (a copy's continued task expired over a link it doesn't own).
                if cancelRequests != cancelsBeforeWrite { throw HandoverError.cancelled("the wait was cancelled") }
                if let returned = returnedAt, clock.now >= returned + .seconds(3) {
                    gaveUp = true
                    break waiting
                }
                // Subscribed, but no CC09 notification 3 s after the acknowledgement: read CC09 as well.
                if notifying, readable, !pollCC09, !notified, !silencePolling, clock.now >= ackAt + .seconds(3) {
                    silencePolling = true
                    pollCC09 = true
                    log.note("Wi-Fi handover: no CC09 notification in 3 s after the acknowledgement; polling CC09 once a second as well")
                }
                if pollCC09, clock.now >= nextPoll {
                    nextPoll = clock.now + .seconds(1)
                    switch try await read(status09, code: "CC09", timeout: 5) {
                    case .value(let data):
                        // The read has been merged by the delegate: the merged state now holds it.
                        let parsed = Self.alpha7CIIEntries(data) != nil
                        if consider(data, state: parsed ? cc09State : [:], merged: parsed ? currentWiFiStatus() : nil,
                                    via: "read", at: clock.now) {
                            on = true
                            break waiting
                        }
                    case .failed(let reason):
                        log.warn("Wi-Fi handover: CC09 poll failed (\(reason)); polling stops\(notifying ? ", notifications only" : "")")
                        pollCC09 = false
                        if !notifying { break waiting }
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        } catch HandoverError.disconnected(let reason) {
            // The notifications that arrived before the drop still count.
            let launched = drainQueue()
            lastStatusSequence = statusText()
            let result = linkDropped(writeStart, attempt: attempt, during: "the wait for CC09", reason: reason,
                                     changes: "\(statusText()); \(Self.listChanges(history))",
                                     launchedAt: launched ? onElapsed : nil)
            timelineSummary()
            return result
        } catch {
            // Disconnect tapped (or the guided run's time limit): no answer about the camera's Wi-Fi, nothing recorded.
            lastStatusSequence = statusText()
            let elapsed = (clock.now - writeStart).inSeconds
            log.warn(String(format: "Wi-Fi handover: the wait stopped %.1f s after CC08 ← 0x01 (%@); ble.handover.wifiOn.reported not recorded; %@; changes: %@",
                            elapsed, "\(error)", statusText(), Self.listChanges(history)))
            throw error
        }

        let elapsed = (clock.now - writeStart).inSeconds
        let changes = Self.listChanges(history)
        let statusLine = statusText()
        lastStatusSequence = statusLine
        let ack = String(format: "ack %.0f ms", ackSeconds * 1000)
        let linkUp = peripheral === p && p.state == .connected
        log.note("Wi-Fi handover: attempt \(attempt): \(statusLine); CC09 updates since the write \(cc09Updates - updatesBeforeWrite)\(silencePolling ? "; polled after 3 s without a CC09 notification" : "")")
        if linkUp {
            log.flag("ble.handover.linkDroppedAfterWrite", false,
                     context: String(format: "attempt %@: link still up %.1f s after CC08 ← 0x01; %@", attempt, elapsed, statusLine))
        } else {
            log.flag("ble.handover.linkDroppedAfterWrite", true,
                     context: String(format: "attempt %@: link down %.1f s after CC08 ← 0x01, after CC09 reported status 2; %@", attempt, elapsed, statusLine))
        }
        if alreadyOn {
            log.flag("ble.handover.wifiOn.reported", true,
                     context: "attempt \(attempt): CC09 already reported status 2 before CC08 ← 0x01 (\(ack)); no latency recorded; \(statusLine)")
            status = "camera Wi-Fi already on"
        } else if on {
            let latency = onElapsed ?? elapsed
            log.measure("ble.handover.wifiOn.latency", latency, "s",
                        context: "attempt \(attempt): CC08 ← 0x01 (\(ack)) → CC09 status 2; \(statusLine); changes: \(changes)")
            log.flag("ble.handover.wifiOn.reported", true, context: "attempt \(attempt): CC09 reported status 2 after the CC08 write; \(statusLine); changes: \(changes)")
            status = String(format: "camera Wi-Fi on after %.1f s", latency)
        } else if gaveUp {
            let back = Self.shownStatus(statusBaseline)
            log.flag("ble.handover.wifiOn.reported", false,
                     context: "attempt \(attempt): launching, then back to \(back): \(statusLine) (\(ack)); stopped 3 s after it went back; changes: \(changes)")
            status = "the camera started its Wi-Fi, then went back to \(back) (check the camera)"
        } else {
            let lastText: String = lastKnown.map { "\(Self.shownStatus($0)) (\(usedTags ? "tag 0x0001" : "status byte"))" } ?? "unknown"
            log.flag("ble.handover.wifiOn.reported", false,
                     context: String(format: "attempt %@: no CC09 status 2 within %.0f s of CC08 ← 0x01 (last status %@); %@; changes: %@",
                                     attempt, elapsed, lastText, statusLine, changes))
            status = "no Wi-Fi-on status after \(Int(elapsed)) s (check the camera)"
        }
        timelineSummary()
        return on || alreadyOn
    }

    /// The link dropped after CC08 ← 0x01. That is an outcome (the camera may drop Bluetooth when its Wi-Fi comes
    /// on), not a failure: records ble.handover.linkDroppedAfterWrite and, only when CC09 reported status 2 before
    /// the drop (`launchedAt`, seconds from the write), ble.handover.wifiOn.reported and its latency. Returns whether
    /// CC09 reported status 2; the guided run asks what the camera shows either way.
    private func linkDropped(_ writeStart: ContinuousClock.Instant, attempt: String, during what: String, reason: String,
                             changes: String, launchedAt: Double?) -> Bool {
        let elapsed = (clock.now - writeStart).inSeconds
        let before = launchedAt.map { String(format: "; CC09 reported status 2 at +%.2f s, before the drop", $0) } ?? "; no CC09 status 2 before the drop"
        log.warn(String(format: "Wi-Fi handover: the Bluetooth link dropped %.1f s after CC08 ← 0x01, during %@ (%@)%@; check the camera's screen", elapsed, what, reason, before))
        log.flag("ble.handover.linkDroppedAfterWrite", true,
                 context: String(format: "attempt %@: %.1f s after CC08 ← 0x01, during %@ (%@)%@; CC09: %@", attempt, elapsed, what, reason, before, changes))
        if let launchedAt {
            log.measure("ble.handover.wifiOn.latency", launchedAt, "s",
                        context: "attempt \(attempt): CC08 ← 0x01 → CC09 status 2, then the link dropped; CC09: \(changes)")
            log.flag("ble.handover.wifiOn.reported", true,
                     context: "attempt \(attempt): CC09 reported status 2 after the CC08 write, then the link dropped; CC09: \(changes)")
        } else {
            log.note("Wi-Fi handover: ble.handover.wifiOn.reported not recorded (the link dropped before CC09 reported status 2)")
        }
        status = String(format: "link dropped %.1f s after the write (check the camera)", elapsed)
        return launchedAt != nil
    }

    // MARK: - Credentials

    /// Reads CC06 (SSID), CC07 (password) and CC0C (BSSID, if present). Logs and returns only what
    /// `HandoverCredentials.description` shows, yes/no comparisons with the Wi-Fi tab's fields and the values' layout
    /// as lengths and yes/no (`credentialLayout`). `<record>.credentials` (ble.handover.credentials by default; nil
    /// records nothing, for callers that record their own outcome) is yes only for a usable pair: an SSID and an 8–63
    /// printable ASCII passphrase.
    func readCredentials(record: String? = "ble.handover") async throws -> HandoverCredentials {
        try await run("Read Wi-Fi details") {
            try await self.doReadCredentials(record: record)
        }
    }

    private func doReadCredentials(record: String?) async throws -> HandoverCredentials {
        _ = try connectedPeripheral()
        if !discovered { _ = try await doDiscover(record: record) }
        status = "reading Wi-Fi details"
        do {
            let (ssid, ssidLayout) = try await readText("CC06", label: "SSID")
            let (passphrase, passphraseLayout) = try await readText("CC07", label: "password")
            log.note("Wi-Fi handover: layout (3-byte header unverified): CC06 \(ssidLayout); CC07 \(passphraseLayout)")
            var bssidPresent = false
            var bssidShaped = false
            if let c = cc["CC0C"] {
                switch try await read(c, code: "CC0C") {
                case .value(let data):
                    bssidPresent = !data.isEmpty
                    bssidShaped = Self.isMACShaped(data)
                case .failed(let reason):
                    log.warn("Wi-Fi handover: CC0C (BSSID) read failed: \(reason)")
                }
            }
            let credentials = HandoverCredentials(ssid: ssid, passphrase: passphrase, bssidPresent: bssidPresent)
            var comparisons: [String] = []
            if let wireless {
                comparisons.append("SSID equals the Wi-Fi tab's: " + (wireless.joinSSID.isEmpty ? "(none typed)" : (wireless.joinSSID == ssid ? "yes" : "no")))
                comparisons.append("passphrase equals the typed one: " + (wireless.joinPassphrase.isEmpty ? "(none typed)" : (wireless.joinPassphrase == passphrase ? "yes" : "no")))
            }
            if bssidPresent { comparisons.append("BSSID present, MAC-shaped \(bssidShaped ? "yes" : "no")") }
            log.note("Wi-Fi handover: Wi-Fi details read: \(credentials.description)\(comparisons.isEmpty ? "" : "; " + comparisons.joined(separator: "; "))")
            let usable = !ssid.isEmpty && HandoverCredentials.isValidPassphrase(passphrase)
            if let record {
                log.flag("\(record).credentials", usable,
                         context: credentials.description + (usable ? "" : "; not usable: an empty SSID or a passphrase that isn't 8–63 printable ASCII (see the layout line)"))
            }
            status = "Wi-Fi details read: \(credentials.description)"
            return credentials
        } catch {
            if let record { log.flag("\(record).credentials", false, context: "\(error)") }
            throw error
        }
    }

    /// CC06 or CC07 as text: the first 3 bytes stripped, trailing NULs dropped, UTF-8 (ASCII expected), with its
    /// `credentialLayout`. Never logs the value or the bytes.
    private func readText(_ code: String, label: String) async throws -> (text: String, layout: String) {
        guard let c = cc[code] else { throw HandoverError.missing(code) }
        let data: Data
        switch try await read(c, code: code) {
        case .value(let d): data = d
        case .failed(let reason): throw HandoverError.readFailed("\(code) (\(label))", reason)
        }
        let layout = Self.credentialLayout(data, password: code == "CC07")
        if data.count <= 3 {
            log.warn("Wi-Fi handover: \(code) (\(label)) is \(data.count) B, not more than the 3-byte header")
            return ("", layout)
        }
        var payload = Array(data.dropFirst(3))
        while payload.last == 0 { payload.removeLast() }
        guard let text = String(bytes: payload, encoding: .utf8) else {
            log.warn("Wi-Fi handover: \(code) (\(label)) isn't UTF-8 after the 3-byte header (\(data.count) B in all)")
            return ("", layout)
        }
        return (text, layout)
    }

    /// A CC06 or CC07 value's layout as lengths and yes/no only, never its bytes, so one run can tell a wrong header
    /// guess from a wrong network: the byte count, then for the SSID the byte offset where "DIRECT-" starts (or
    /// none), for the password whether it is 8–63 printable ASCII after the 3-byte header and as a whole.
    nonisolated static func credentialLayout(_ data: Data, password: Bool) -> String {
        func trimmed(_ bytes: [UInt8]) -> [UInt8] {
            var out = bytes
            while out.last == 0 { out.removeLast() }
            return out
        }
        let whole = trimmed(Array(data))
        if password {
            func valid(_ bytes: [UInt8]) -> String {
                (8 ... 63).contains(bytes.count) && bytes.allSatisfy { (0x20 ... 0x7E).contains($0) } ? "yes" : "no"
            }
            let afterHeader: [UInt8] = data.count > 3 ? trimmed(Array(data.dropFirst(3))) : []
            return "\(data.count) B; 8–63 printable ASCII after the 3-byte header \(valid(afterHeader)), as a whole \(valid(whole))"
        }
        let marker = Array("DIRECT-".utf8)
        var offset: Int?
        if whole.count >= marker.count {
            for i in 0 ... whole.count - marker.count where Array(whole[i ..< i + marker.count]) == marker {
                offset = i
                break
            }
        }
        return "\(data.count) B; DIRECT- at byte \(offset.map { String($0) } ?? "none")"
    }

    // MARK: - Status byte (build 11)

    /// Forgets the CC09 status byte remembered from an earlier run (the Bluetooth tab's button, or the guided runs'
    /// offer at the start) and logs which byte it was (a position, not a camera value).
    func forgetRememberedStatusByte(_ why: String) {
        let index = Self.savedStatusByte()
        let source = Self.savedStatusByteSource()
        Self.forgetStatusByte()
        log.note("Wi-Fi handover: CC09 status byte \(index.map { "[\($0)] (\(source))" } ?? "(none remembered)") forgotten (\(why)); it is learnt again from CC09's next changes")
    }

    // MARK: - Disconnect

    /// Turns off, without waiting, every notification still on (unsubscribeAll() is the way that waits for the
    /// camera's answers and also clears those turned on over an earlier link; call it first when there is time),
    /// drops this app's connection (if Creators' App holds one too, iOS keeps the link for it), ends any operation that
    /// is waiting, and forgets the subscriptions, the remembered values and the timeline. Build 14: codes it couldn't
    /// turn off (on over an earlier link, or every code when no link is up) stay listed in earlierLinkCodes, so the next
    /// connect's unsubscribeAll() clears them at the camera. When it turned notifications
    /// off, the connection is cancelled 2 s later rather than at once (CoreBluetooth may drop commands still pending
    /// when a connection is cancelled), unless a new Connect has taken the same camera by then.
    func disconnect() {
        disconnectRequests += 1
        central?.stopScan()
        // Switches turned on over an earlier link (or over the link the camera dropped) and not cleared: they can't be
        // cleared without waiting. Build 14: they stay in everSubscribed, so the next connect's unsubscribeAll() turns
        // them on and off again over its link (a guided run's end, or a Disconnect with the link down, would otherwise
        // forget switches the camera keeps on). Only the codes turned off below, over this link, are forgotten; with no
        // link up nothing is turned off, so every code is kept.
        let linkUp = peripheral?.state == .connected
        let leftEarlier = linkUp ? earlierLinkCodes : everSubscribed.sorted()
        if !leftEarlier.isEmpty {
            log.warn("Wi-Fi handover: notifications turned on over an earlier link and not cleared: \(leftEarlier.joined(separator: ", ")); the camera may keep them on for this phone (a bonded client) until the next Bluetooth connect turns them off (kept in memory for it)")
        }
        everSubscribed = Set(leftEarlier)
        if let p = peripheral, p.state != .disconnected {
            // Undo the subscriptions left on; the link stays up 2 s so the camera can see the descriptor writes.
            var off: [String] = []
            if p.state == .connected {
                for (code, c) in notifyingCharacteristics() {
                    p.setNotifyValue(false, for: c)
                    off.append(code)
                }
            }
            let name = p.name ?? "(no name)"
            if off.isEmpty {
                central?.cancelPeripheralConnection(p)
                log.note("Wi-Fi handover: disconnecting from \(name)")
            } else {
                log.note("Wi-Fi handover: notifications turned off for \(off.joined(separator: ", ")) without waiting for the camera's answers; disconnecting from \(name) in 2 s, so the descriptor writes go out first")
                let closing = central
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    // A Connect since then that took the same camera keeps the link.
                    if let self, self.peripheral === p { return }
                    closing?.cancelPeripheralConnection(p)
                    self?.log.note("Wi-Fi handover: disconnected from \(name) (2 s after turning the notifications off)")
                }
            }
        } else {
            log.note("Wi-Fi handover: Disconnect (not connected)")
        }
        failAll(HandoverError.cancelled("Disconnect"))
        peripheral = nil
        scanFound = nil
        connectedName = nil
        resetLink()
        status = "disconnected"
    }

    /// Build 14: ends the operation that is waiting (a connect, discovery, read, write or subscription answer, or
    /// switchWiFiOn's wait for the Wi-Fi status) with `.cancelled`, without dropping the link or turning anything off,
    /// for a copy whose continued task expired while it used a link the Bluetooth tab or the guided run holds. Nothing
    /// is written; a subscription request already sent stays in everSubscribed, so it is cleared later as usual.
    func cancelWaits(_ why: String) {
        cancelRequests += 1
        log.note("Wi-Fi handover: the operation waiting was cancelled (\(why)); the link stays up")
        failAll(HandoverError.cancelled(why))
    }

    // MARK: - Plumbing

    /// Runs one operation at a time; logs and shows a failure before rethrowing it.
    private func run<T>(_ operation: String, _ body: () async throws -> T) async throws -> T {
        guard !busy else {
            log.warn("Wi-Fi handover: \(operation) refused: another operation is running")
            throw HandoverError.busy
        }
        busy = true
        defer { busy = false }
        do {
            return try await body()
        } catch {
            log.error("Wi-Fi handover: \(operation) failed: \(error)")
            status = "\(operation) failed: \(error)"
            throw error
        }
    }

    private func poweredOnCentral() async throws -> CBCentralManager {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        }
        guard let central else { throw HandoverError.bluetooth("no central") }
        switch central.state {
        case .poweredOn:
            return central
        case .unknown, .resetting:
            _ = try await wait("power", timeout: 30, what: "Bluetooth power-on (or the permission prompt)") {}
            return central
        default:
            throw HandoverError.bluetooth(ProximityWatcher.describe(central.state))
        }
    }

    private func connectedPeripheral() throws -> CBPeripheral {
        guard let p = peripheral, p.state == .connected else { throw HandoverError.notConnected }
        return p
    }

    /// Identifiers to try first, best first: rows marked as the camera, peripherals whose GATT listing had 8000CC00,
    /// connected peripherals recognised as the camera, rows named ILCE (all from the scanner, this launch), then the
    /// one this lab saved after its last connection.
    private func knownIdentifiers() -> [(id: UUID, source: String)] {
        var out: [(id: UUID, source: String)] = []
        func add(_ id: UUID?, _ source: String) {
            guard let id, !out.contains(where: { $0.id == id }) else { return }
            out.append((id: id, source: source))
        }
        if let scanner {
            for id in scanner.markedCameras.sorted(by: { $0.uuidString < $1.uuidString }) { add(id, "marked on the Bluetooth tab") }
            for (id, services) in scanner.gattServices where services.contains(where: Self.isCameraControlString) {
                add(id, "GATT listing")
            }
            for record in scanner.connected where record.isCamera { add(UUID(uuidString: record.identifier), "Check connected") }
            for row in scanner.rows where row.isCamera && row.name.uppercased().contains("ILCE") { add(row.id, "scan") }
        }
        add(UserDefaults.standard.string(forKey: Self.savedPeripheralKey).flatMap(UUID.init(uuidString:)), "last handover connection")
        return out
    }

    private static func preferCamera(_ list: [CBPeripheral]) -> CBPeripheral? {
        list.first { ($0.name ?? "").uppercased().contains("ILCE") } ?? list.first
    }

    /// Registers a continuation under `key`, runs `start`, and waits for the delegate to resolve it or for
    /// `timeout`. A newer wait under the same key ends an older one.
    private func wait(_ key: String, timeout: Double, what: String, _ start: () -> Void) async throws -> Data? {
        if let old = waiters.removeValue(forKey: key) {
            old.continuation.resume(throwing: HandoverError.cancelled("replaced by a newer \(what)"))
        }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.resolve(key, id: id, .failure(HandoverError.timedOut(what, timeout)))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[key] = Waiter(id: id, continuation: continuation)
            start()
        }
    }

    private func resolve(_ key: String, id: UUID? = nil, _ result: Result<Data?, Error>) {
        guard let waiter = waiters[key], id == nil || waiter.id == id else { return }
        waiters[key] = nil
        waiter.continuation.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let all = waiters
        waiters = [:]
        for (_, waiter) in all { waiter.continuation.resume(throwing: error) }
    }

    /// One read. ATT errors and timeouts come back as `.failed` (logged by the caller); a disconnect throws.
    private func read(_ c: CBCharacteristic, code: String, timeout: Double = 15) async throws -> ReadOutcome {
        let p = try connectedPeripheral()
        do {
            let data = try await wait("read:\(c.uuid.uuidString)", timeout: timeout, what: "\(code) read") {
                p.readValue(for: c)
            }
            return .value(data ?? Data())
        } catch let e as HandoverError {
            guard e.isTimeout else { throw e }
            if lastPairingHint == nil {
                lastPairingHint = "\(code) read didn't answer in \(Int(timeout)) s: was an iOS Bluetooth pairing request on screen?"
            }
            return .failed("no answer in \(Int(timeout)) s")
        } catch {
            noteIfPairing(error, during: "\(code) read")
            return .failed(Self.errorName(error))
        }
    }

    private func noteIfPairing(_ error: Error, during what: String) {
        let ns = error as NSError
        let pairingATT: Set<Int> = [0x05, 0x08, 0x0C, 0x0F]
        let pairingCB: Set<Int> = [14, 15]
        if (ns.domain == CBATTErrorDomain && pairingATT.contains(ns.code)) || (ns.domain == CBErrorDomain && pairingCB.contains(ns.code)) {
            lastPairingHint = "\(Self.errorName(error)) during \(what): did iOS show a Bluetooth pairing request?"
            log.warn("Wi-Fi handover: \(lastPairingHint ?? "")")
        }
    }

    // MARK: - Helpers (no I/O)

    /// The 4 hex digits of a characteristic UUID given as 16-bit ("CC06"), Sony 128-bit
    /// ("0000CC06-CC00-FFFF-FFFF-FFFFFFFFFFFF") or Bluetooth-base 128-bit ("0000CC06-0000-1000-8000-00805F9B34FB").
    nonisolated static func shortCode(_ uuid: CBUUID) -> String? {
        let s = uuid.uuidString.uppercased()
        if s.count == 4 { return s }
        guard s.count == 36, s.hasPrefix("0000") else { return nil }
        let start = s.index(s.startIndex, offsetBy: 4)
        let end = s.index(start, offsetBy: 4)
        let tail = s[end...]
        guard tail == "-CC00-FFFF-FFFF-FFFFFFFFFFFF" || tail == "-0000-1000-8000-00805F9B34FB" else { return nil }
        return String(s[start ..< end])
    }

    nonisolated static func isCameraControl(_ uuid: CBUUID) -> Bool {
        isCameraControlString(uuid.uuidString)
    }

    nonisolated static func isCameraControlString(_ text: String) -> Bool {
        text.uppercased() == cameraControlService
    }

    nonisolated static func describe(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read) { parts.append("read") }
        if p.contains(.write) { parts.append("write") }
        if p.contains(.writeWithoutResponse) { parts.append("writeWithoutResponse") }
        if p.contains(.notify) { parts.append("notify") }
        if p.contains(.indicate) { parts.append("indicate") }
        return parts.isEmpty ? "none of read/write/notify" : parts.joined(separator: ", ")
    }

    /// An ATT or CoreBluetooth error by name ("ATT insufficientEncryption"), never with values.
    nonisolated static func errorName(_ error: Error) -> String {
        if let h = error as? HandoverError { return h.description }
        let ns = error as NSError
        if ns.domain == CBATTErrorDomain {
            let names = [1: "invalidHandle", 2: "readNotPermitted", 3: "writeNotPermitted", 4: "invalidPdu",
                         5: "insufficientAuthentication", 6: "requestNotSupported", 7: "invalidOffset",
                         8: "insufficientAuthorization", 9: "prepareQueueFull", 10: "attributeNotFound",
                         11: "attributeNotLong", 12: "insufficientEncryptionKeySize", 13: "invalidAttributeValueLength",
                         14: "unlikelyError", 15: "insufficientEncryption", 16: "unsupportedGroupType",
                         17: "insufficientResources"]
            return "ATT \(names[ns.code] ?? String(format: "error 0x%02X", ns.code))"
        }
        if ns.domain == CBErrorDomain {
            let names = [0: "unknown", 1: "invalidParameters", 2: "invalidHandle", 3: "notConnected", 4: "outOfSpace",
                         5: "operationCancelled", 6: "connectionTimeout", 7: "peripheralDisconnected",
                         8: "uuidNotAllowed", 9: "alreadyAdvertising", 10: "connectionFailed",
                         11: "connectionLimitReached", 12: "unknownDevice", 13: "operationNotSupported",
                         14: "peerRemovedPairingInformation", 15: "encryptionTimedOut", 16: "tooManyLEPairedDevices"]
            return "CoreBluetooth \(names[ns.code] ?? "error \(ns.code)")"
        }
        return "\(ns.domain) \(ns.code)"
    }

    /// A firmware or model value for the log: printable text unless it looks like a serial number, a MAC address or
    /// the network name, a short binary value masked (`maskedHex`), anything else as a length only.
    nonisolated static func describeInfo(_ data: Data) -> String {
        var bytes = Array(data)
        while bytes.last == 0 { bytes.removeLast() }
        func printable(_ b: ArraySlice<UInt8>) -> String? {
            guard !b.isEmpty, b.allSatisfy({ (0x20 ... 0x7E).contains($0) }) else { return nil }
            return String(decoding: b, as: UTF8.self)
        }
        func show(_ text: String, prefix: String) -> String {
            if looksLikeHardwareID(text) {
                return "\(prefix)\(text.count) chars that look like a serial number or MAC address (not logged)"
            }
            // The CC map is unverified: if this is the network name ("DIRECT-xxXX:ILCE-7CM2"), only its length.
            let upper = text.uppercased()
            if upper.contains("DIRECT-") || upper.contains(":ILCE") {
                return "\(prefix)\(text.count) chars that look like the network name (not logged)"
            }
            return "\(prefix)\"\(text)\" (\(data.count) B)"
        }
        if let text = printable(bytes[...]) { return show(text, prefix: "") }
        if bytes.count > 3, let text = printable(bytes[3...]) {
            return show(text, prefix: "after a 3-byte header \(maskedHex(Data(bytes.prefix(3)))), ")
        }
        if data.count <= 4 { return "\(data.count) B: \(maskedHex(data))" }
        return "\(data.count) B, not text (not logged)"
    }

    /// Six or more digits in a row (a serial), or 12 hex digits with or without separators (a MAC address).
    nonisolated static func looksLikeHardwareID(_ text: String) -> Bool {
        text.range(of: #"[0-9]{6,}"#, options: .regularExpression) != nil
            || text.range(of: #"([0-9A-Fa-f]{2}[:-]?){5}[0-9A-Fa-f]{2}"#, options: .regularExpression) != nil
    }

    /// 6 bytes (optionally after the 3-byte header), or "AA:BB:CC:DD:EE:FF" / 12 hex digits as text.
    nonisolated static func isMACShaped(_ data: Data) -> Bool {
        if data.count == 6 || data.count == 9 { return true }
        var bytes = Array(data.count > 3 && data.count != 17 && data.count != 12 ? data.dropFirst(3) : data[...])
        while bytes.last == 0 { bytes.removeLast() }
        guard let text = String(bytes: bytes, encoding: .ascii) else { return false }
        return text.range(of: #"^([0-9A-Fa-f]{2}[:-]?){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil
    }

    struct TLVItem {
        let tag: Int
        /// The tag's size in bytes (1 or 2), so the log can mask it byte by byte.
        let tagSize: Int
        let value: [UInt8]
    }

    /// The layout CC09 has on the α7C II (build 12's reads and notifications).
    nonisolated static let alpha7CIILayout = "len8/tag16 BE (α7C II)"

    /// CC09 in the α7C II's layout: entries of [length: 1 byte, counting the tag and the value][tag: 2 bytes
    /// big-endian][value: length − 2 bytes], using every byte. A read carries every tag (43 B on the α7C II), a
    /// notification one entry ("04 00 01 02 00": tag 0x0001, value 02 00). Nil when the bytes don't fit.
    nonisolated static func alpha7CIIEntries(_ data: Data) -> [TLVItem]? {
        let bytes = Array(data)
        var items: [TLVItem] = []
        var i = 0
        while i < bytes.count {
            let length = Int(bytes[i])
            // The length counts the 2-byte tag, so it is at least 2, and the entry must end inside the value.
            guard length >= 2, i + 1 + length <= bytes.count else { return nil }
            let tag = Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])
            items.append(TLVItem(tag: tag, tagSize: 2, value: Array(bytes[(i + 3) ..< (i + 1 + length)])))
            i += 1 + length
        }
        return items.isEmpty ? nil : items
    }

    /// The Wi-Fi status in a merged CC09 state: tag 0x0001's first value byte; nil when absent.
    nonisolated static func statusInState(_ state: [Int: [UInt8]]) -> Int? {
        state[0x0001]?.first.map { Int($0) }
    }

    /// The notes' names for CC09's tags (CameraSync, BLE_STATE_MONITORING.md); nil for 0x0004, 0x0006 and any other.
    nonisolated static func cc09TagName(_ tag: Int) -> String? {
        switch tag {
        case 0x0001: return "Wi-Fi status"
        case 0x0002: return "image transfer available"
        case 0x0003: return "remote control available"
        case 0x0005: return "time set"
        case 0x0007: return "live streaming"
        case 0x0008: return "movie recording"
        case 0x0009: return "streaming mode"
        case 0x000A: return "background transfer available"
        default: return nil
        }
    }

    /// A 2-byte tag as "0x0002", each byte masked like `maskedByte`.
    nonisolated static func maskedTag(_ tag: Int) -> String {
        "0x" + [UInt8(truncatingIfNeeded: tag >> 8), UInt8(truncatingIfNeeded: tag)].map { maskedByte($0) }.joined()
    }

    /// A CC09 tag for a change line: "Wi-Fi status", "tag 0x0002 image transfer available", "tag 0x0004".
    nonisolated static func cc09TagLabel(_ tag: Int) -> String {
        if tag == 0x0001 { return "Wi-Fi status" }
        return "tag \(maskedTag(tag))" + (cc09TagName(tag).map { " \($0)" } ?? "")
    }

    /// A CC09 entry's value for the log: one byte as its number (masked above 0x0F like `shownStatus`), longer
    /// values as `maskedHex`.
    nonisolated static func cc09ValueText(_ value: [UInt8]) -> String {
        if value.isEmpty { return "empty" }
        if value.count == 1 { return shownStatus(Int(value[0])) }
        return maskedHex(Data(value))
    }

    /// What changed from one merged CC09 state to the next, per tag, masked: "Wi-Fi status 0 → 1 (launching)",
    /// "tag 0x0002 image transfer available 1 → 0"; a tag seen for the first time as "… = value". "no change" when
    /// equal; from an empty state, "first value: " and every tag.
    nonisolated static func tagChanges(old: [Int: [UInt8]], new: [Int: [UInt8]]) -> String {
        if old == new { return "no change" }
        var parts: [String] = []
        for tag in Set(old.keys).union(new.keys).sorted() {
            let a = old[tag]
            let b = new[tag]
            guard a != b else { continue }
            let label = cc09TagLabel(tag)
            switch (a, b) {
            case (.none, .some(let value)):
                if tag == 0x0001, let first = value.first {
                    parts.append("\(label) \(shownStatus(Int(first)))\(statusName(Int(first)).map { " (\($0))" } ?? "")\(value.count > 1 ? " (value \(maskedHex(Data(value))))" : "")")
                } else {
                    parts.append("\(label) = \(cc09ValueText(value))")
                }
            case (.some(let was), .none):
                parts.append("\(label) gone (was \(cc09ValueText(was)))")
            case (.some(let was), .some(let value)):
                if tag == 0x0001, let x = was.first, let y = value.first, x != y {
                    parts.append("\(label) \(shownStatus(Int(x))) → \(shownStatus(Int(y)))\(statusName(Int(y)).map { " (\($0))" } ?? "")")
                } else {
                    parts.append("\(label) \(cc09ValueText(was)) → \(cc09ValueText(value))")
                }
            case (.none, .none):
                break
            }
        }
        let text = parts.joined(separator: "; ")
        return old.isEmpty ? "first value: \(text)" : text
    }

    /// CC09 as a tag/length/value list. The α7C II's layout first (`alpha7CIIEntries`); the older guesses only after
    /// it, in turn, the first that uses every byte winning: 16-bit tag and length big-endian, the same little-endian,
    /// 16-bit tag with an 8-bit length, 8-bit tag and length; then the same after a 3-byte header.
    nonisolated static func parseTLV(_ data: Data) -> (layout: String, items: [TLVItem])? {
        if let items = alpha7CIIEntries(data) { return (alpha7CIILayout, items) }
        let all = Array(data)
        let layouts: [(name: String, tagSize: Int, lengthSize: Int, bigEndian: Bool)] = [
            ("tag16/len16 BE", 2, 2, true), ("tag16/len16 LE", 2, 2, false),
            ("tag16 BE/len8", 2, 1, true), ("tag8/len8", 1, 1, true),
        ]
        func number(_ b: ArraySlice<UInt8>, bigEndian: Bool) -> Int {
            let ordered = bigEndian ? Array(b) : Array(b.reversed())
            return ordered.reduce(0) { $0 << 8 | Int($1) }
        }
        for (skip, label) in [(0, ""), (3, " after a 3-byte header")] where all.count > skip {
            let bytes = Array(all[skip...])
            for layout in layouts {
                var items: [TLVItem] = []
                var i = 0
                var ok = true
                while i < bytes.count {
                    let headerEnd = i + layout.tagSize + layout.lengthSize
                    guard headerEnd <= bytes.count else { ok = false; break }
                    let tag = number(bytes[i ..< i + layout.tagSize], bigEndian: layout.bigEndian)
                    let length = number(bytes[i + layout.tagSize ..< headerEnd], bigEndian: layout.bigEndian)
                    guard headerEnd + length <= bytes.count else { ok = false; break }
                    items.append(TLVItem(tag: tag, tagSize: layout.tagSize, value: Array(bytes[headerEnd ..< headerEnd + length])))
                    i = headerEnd + length
                }
                if ok, !items.isEmpty { return (layout.name + label, items) }
            }
        }
        return nil
    }

    /// CC09 for the log: the layout, every tag with its length, the value of tag 0x0001 only (1 or 2 bytes; the other
    /// tags are unknown and could hold a serial or part of an address), and the Wi-Fi status from tag 0x0001. The
    /// parser is lenient, so its "tags" and "lengths" may really be data bytes: every byte shown, tags, lengths, the
    /// value and the status, is masked like `maskedHex` (above 0x0F as "··"). A value that isn't a tag/length/value
    /// list is logged only as `maskedHex`. `status` is the unmasked number, for comparisons only, never for the log.
    /// Build 13: in the α7C II's layout every entry is shown with the notes' name for its tag (unknown ones as
    /// "tag 0x0004") and its value masked, and the Wi-Fi status is tag 0x0001's first value byte.
    nonisolated static func describeStatus(_ data: Data) -> (status: Int?, text: String) {
        guard let parsed = parseTLV(data) else {
            return (nil, "\(data.count) B, not a tag/length/value list: \(maskedHex(data))")
        }
        if parsed.layout == alpha7CIILayout {
            let wifi = parsed.items.first { $0.tag == 0x0001 }?.value.first.map { Int($0) }
            let parts = parsed.items.map { item -> String in
                "\(maskedTag(item.tag))\(cc09TagName(item.tag).map { " \($0)" } ?? "") = \(cc09ValueText(item.value))"
            }
            let statusText: String
            if let wifi {
                let name = statusName(wifi).map { "\($0), per the notes; " } ?? "meaning unknown; "
                statusText = "Wi-Fi status \(shownStatus(wifi)) (\(name)0→1→2 and 2→3→0 seen on the α7C II)"
            } else {
                statusText = "no tag 0x0001 in this value"
            }
            return (wifi, "\(statusText); \(parsed.layout): \(parts.joined(separator: ", "))")
        }
        var status: Int?
        let parts = parsed.items.map { item -> String in
            let tagBytes = (0 ..< item.tagSize).reversed().map { UInt8(truncatingIfNeeded: item.tag >> (8 * $0)) }
            let tag = "0x" + tagBytes.map { maskedByte($0) }.joined()
            if item.tag == 0x0001, status == nil, !item.value.isEmpty {
                // One byte expected; for a longer value the first byte is taken (unverified).
                status = Int(item.value[0])
            }
            guard item.tag == 0x0001, (1 ... 2).contains(item.value.count) else {
                return "\(tag): \(shownStatus(item.value.count)) B"
            }
            return "\(tag) = \(maskedHex(Data(item.value)))"
        }
        let statusText = status.map { "Wi-Fi status \(shownStatus($0))\(statusMeaning($0))" } ?? "no tag 0x0001"
        return (status, "\(statusText); \(parsed.layout): \(parts.joined(separator: ", "))")
    }

    /// The notes' name for a Wi-Fi status value (CameraSync, BLE_STATE_MONITORING.md); nil for any other value.
    nonisolated static func statusName(_ s: Int) -> String? {
        switch s {
        case 0: return "terminated"
        case 1: return "launching"
        case 2: return "launched"
        case 3: return "terminating"
        default: return nil
        }
    }

    /// The notes' Wi-Fi status values (CameraSync, BLE_STATE_MONITORING.md); on the α7C II, CC08 = 01 took it
    /// 0 → 1 → 2, and 2 → 3 → 0 when the Wi-Fi went off (build 12), in the notes' order.
    nonisolated static func statusMeaning(_ s: Int) -> String {
        statusName(s).map { " (\($0), per the notes)" } ?? " (meaning unknown)"
    }

    /// CC09 for the log: masked bytes, plus the tag/length/value reading when one fits.
    nonisolated static func describeCC09(_ data: Data) -> String {
        guard parseTLV(data) != nil else { return describeStatus(data).text }
        return "\(maskedHex(data)) (\(describeStatus(data).text))"
    }

    // MARK: - Build 11 helpers (no I/O)

    nonisolated static func canNotify(_ c: CBCharacteristic) -> Bool {
        c.properties.contains(.notify) || c.properties.contains(.indicate)
    }

    /// Bytes up to 0x0F as two hex digits, larger bytes as "··", so flags and structure show but no text or large
    /// binary value can: "00 01 ·· 0A". At most 64 bytes, then "… (N B)".
    nonisolated static func maskedHex(_ data: Data) -> String {
        let bytes = Array(data)
        if bytes.isEmpty { return "0 B" }
        let shown = bytes.prefix(64).map { maskedByte($0) }.joined(separator: " ")
        return bytes.count > 64 ? shown + " … (\(bytes.count) B)" : shown
    }

    nonisolated static func maskedByte(_ b: UInt8) -> String {
        b <= 0x0F ? String(format: "%02X", b) : "··"
    }

    /// A status byte's value for the log: the number up to 15, "··" above (masked like `maskedHex`), "?" unknown.
    nonisolated static func shownStatus(_ value: Int?) -> String {
        guard let value else { return "?" }
        return (0 ... 0x0F).contains(value) ? String(value) : "··"
    }

    /// What changed from `old` to `new`, masked like `maskedHex`: the length change if any, then the positions that
    /// differ ("[3] 00→01"; "–" for a byte past the end), at most 8 and then "+N more". "no change" when equal;
    /// without `old`, the masked value.
    nonisolated static func byteChanges(old: Data?, new: Data) -> String {
        guard let old else { return "first value, \(new.count) B: \(maskedHex(new))" }
        if old == new { return "no change" }
        let a = Array(old)
        let b = Array(new)
        var parts: [String] = []
        if a.count != b.count { parts.append("length \(a.count) → \(b.count) B") }
        var positions: [String] = []
        var more = 0
        for i in 0 ..< max(a.count, b.count) {
            let x: UInt8? = i < a.count ? a[i] : nil
            let y: UInt8? = i < b.count ? b[i] : nil
            guard x != y else { continue }
            if positions.count < 8 {
                positions.append("[\(i)] \(x.map { maskedByte($0) } ?? "–")→\(y.map { maskedByte($0) } ?? "–")")
            } else {
                more += 1
            }
        }
        if !positions.isEmpty { parts.append(positions.joined(separator: ", ") + (more > 0 ? " +\(more) more" : "")) }
        return parts.joined(separator: "; ")
    }

    /// The byte at `index`, nil past the end.
    nonisolated static func byte(at index: Int, in data: Data) -> Int? {
        let bytes = Array(data)
        return index >= 0 && index < bytes.count ? Int(bytes[index]) : nil
    }

    /// The status byte as guessed from one change: the first position that went 0 → 1 (`zeroToOne`), else the first
    /// that changed. Only a 0 → 1 is good enough to remember for later runs.
    nonisolated static func statusByteGuess(old: Data, new: Data) -> (index: Int, zeroToOne: Bool)? {
        let a = Array(old)
        let b = Array(new)
        let common = min(a.count, b.count)
        let changed = (0 ..< common).filter { a[$0] != b[$0] }
        if let i = changed.first(where: { a[$0] == 0 && b[$0] == 1 }) { return (index: i, zeroToOne: true) }
        guard let first = changed.first else { return nil }
        return (index: first, zeroToOne: false)
    }

    /// The first position whose values, in order, went 0, then 1, then 2 (other values in between allowed); with
    /// `only`, that position or nil.
    nonisolated static func launchPosition(_ values: [Data], only: Int? = nil) -> Int? {
        let arrays = values.map { Array($0) }
        let width = arrays.map(\.count).max() ?? 0
        let positions: [Int] = only.map { $0 >= 0 && $0 < width ? [$0] : [] } ?? Array(0 ..< width)
        for i in positions {
            var wanted: UInt8 = 0
            for bytes in arrays where i < bytes.count && bytes[i] == wanted {
                wanted += 1
                if wanted == 3 { return i }
            }
        }
        return nil
    }

    /// The CC09 status byte remembered from an earlier run, if any.
    nonisolated static func savedStatusByte() -> Int? {
        guard let index = UserDefaults.standard.object(forKey: statusByteKey) as? Int, index >= 0 else { return nil }
        return index
    }

    /// How the remembered status byte was learnt, for the logs.
    nonisolated static func savedStatusByteSource() -> String {
        let source = UserDefaults.standard.string(forKey: statusByteSourceKey) ?? "how it was learnt not recorded"
        return "learnt from \(source)"
    }

    nonisolated static func saveStatusByte(_ index: Int, source: String) {
        UserDefaults.standard.set(index, forKey: statusByteKey)
        UserDefaults.standard.set(source, forKey: statusByteSourceKey)
    }

    /// Forgets the remembered status byte (forgetRememberedStatusByte logs it).
    nonisolated static func forgetStatusByte() {
        UserDefaults.standard.removeObject(forKey: statusByteKey)
        UserDefaults.standard.removeObject(forKey: statusByteSourceKey)
    }

    /// One CC09 value's Wi-Fi status on its own: in the α7C II's layout tag 0x0001's first value byte (nil when the
    /// value has no tag 0x0001: a notification of another tag); else the byte at the remembered position, else a
    /// fallback layout's tag 0x0001. The instance's currentWiFiStatus() (the merged state) comes first wherever a
    /// link is up. The unmasked number, for comparisons; log it with `shownStatus`.
    nonisolated static func wifiStatus(in data: Data) -> Int? {
        if let entries = alpha7CIIEntries(data) {
            return entries.first { $0.tag == 0x0001 }?.value.first.map { Int($0) }
        }
        if let index = savedStatusByte(), let b = byte(at: index, in: data) { return b }
        return describeStatus(data).status
    }

    /// "; status byte [i] = n (meaning)" for a CC09 value when a status byte is remembered and the value doesn't parse
    /// as the α7C II layout (whose status is tag 0x0001's, shown by describeCC09), else "".
    nonisolated static func statusByteNote(_ data: Data) -> String {
        guard alpha7CIIEntries(data) == nil, let index = savedStatusByte(), let b = byte(at: index, in: data) else { return "" }
        return "; status byte [\(index)] = \(shownStatus(b))\(statusMeaning(b))"
    }

    /// Up to 12 changes for a context, "none" when there were none.
    nonisolated static func listChanges(_ history: [String]) -> String {
        guard !history.isEmpty else { return "none" }
        return history.prefix(12).joined(separator: ", ") + (history.count > 12 ? ", +\(history.count - 12) more" : "")
    }
}

extension SonyWiFiHandover: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = ProximityWatcher.describe(central.state)
        switch central.state {
        case .poweredOn:
            resolve("power", .success(nil))
        case .unknown, .resetting:
            break
        default:
            log.warn("Wi-Fi handover: Bluetooth is \(state)")
            failAll(HandoverError.bluetooth(state))
            connectedName = nil
            resetLink(keepTimeline: true)
            status = "Bluetooth \(state)"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard waiters["scan"] != nil, scanFound == nil else { return }
        guard let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 2 else { return }
        let company = UInt16(mfg[mfg.startIndex]) | UInt16(mfg[mfg.startIndex + 1]) << 8
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard company == AdvertisementScanner.sonyCompanyID, name.uppercased().contains("ILCE") else { return }
        scanFound = peripheral
        log.note("Wi-Fi handover: scan found \(name) [\(peripheral.identifier.uuidString.prefix(8))] RSSI \(RSSI)")
        central.stopScan()
        resolve("scan", .success(nil))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        resolve("connect", .success(nil))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        resolve("connect", .failure(error ?? HandoverError.disconnected("connection failed, no error given")))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        let reason = error.map { Self.errorName($0) } ?? "no error given"
        log.warn("Wi-Fi handover: disconnected from \(peripheral.name ?? "(no name)") (\(reason))")
        if let error { noteIfPairing(error, during: "the connection") }
        failAll(HandoverError.disconnected(reason))
        self.peripheral = nil
        scanFound = nil
        connectedName = nil
        // The timeline stays: the run may still want what the camera reported before it dropped the link.
        resetLink(keepTimeline: true)
        status = "disconnected (\(reason))"
    }
}

extension SonyWiFiHandover: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        resolve("services", error.map { .failure($0) } ?? .success(nil))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        resolve("chars:\(service.uuid.uuidString)", error.map { .failure($0) } ?? .success(nil))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        let inControl = characteristic.service.map { Self.isCameraControl($0.uuid) } == true
        let code = inControl ? Self.shortCode(characteristic.uuid) : nil
        // Build 13: every CC09 value, read or notified, is merged into the CC09 state first.
        var merge: CC09Merge?
        if code == "CC09", error == nil, let value = characteristic.value {
            cc09Latest = value
            cc09Updates += 1
            merge = mergeCC09(value)
        }
        // The answer to a pending read; anything else in 8000CC00 is a notification, for the timeline.
        let key = "read:\(characteristic.uuid.uuidString)"
        if waiters[key] != nil {
            if let error {
                resolve(key, .failure(error))
            } else {
                let value = characteristic.value ?? Data()
                if let code { remember(code, value) }
                // A read that changed tags already known (a notification may have been missed); the first value on a
                // link is logged by the caller, and switchWiFiOn logs its own polls.
                if let merge, !merge.first, !cc09Watching, merge.changes != "no change" {
                    log.note("Wi-Fi handover: CC09 (read) changed: \(merge.changes)")
                }
                resolve(key, .success(value))
            }
            return
        }
        guard let code else { return }
        if let error {
            log.warn("Wi-Fi handover: \(code) notification with an error: \(Self.errorName(error))")
            return
        }
        recordNotification(code, characteristic.value ?? Data(), merge: merge)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        resolve("write:\(characteristic.uuid.uuidString)", error.map { .failure($0) } ?? .success(nil))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        resolve("notify:\(characteristic.uuid.uuidString)", error.map { .failure($0) } ?? .success(nil))
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === self.peripheral else { return }
        // Only 8000CC00's characteristics matter here; those of a service that wasn't invalidated stay valid.
        guard invalidatedServices.contains(where: { Self.isCameraControl($0.uuid) }) else {
            log.warn("Wi-Fi handover: the camera changed services other than 8000CC00 (\(invalidatedServices.map(\.uuid.uuidString).joined(separator: ", "))); 8000CC00 and its subscriptions are unchanged")
            return
        }
        log.warn("Wi-Fi handover: the camera changed its services, including 8000CC00 (\(invalidatedServices.map(\.uuid.uuidString).joined(separator: ", "))); its subscriptions are gone; discover again")
        cc = [:]
        ccAll = [:]
        discovered = false
        subscribedCodes = []
    }
}
