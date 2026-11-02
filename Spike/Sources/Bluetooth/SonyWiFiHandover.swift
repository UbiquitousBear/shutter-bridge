// Build 10 (experimental): can the app switch the α7C II's Wi-Fi on over Bluetooth and read the network name and
// password ("Wi-Fi handover"), so the phone can join the camera's network without the QR code?
//
// Everything here about Sony's GATT layout is reverse-engineered (CameraSync's notes on a decompiled Creators' App,
// SonyCameraKit) and unverified on this camera. On 2 Nov the spike listed services 8000FF00, 8000CC00, 8000DD00,
// 8000EE00 and 8000BB00 on the real camera. Inside 8000CC00 (all unverified):
//
//   CC08  "Wi-Fi on": write 0x01 with response            the ONLY write this file makes, after the tester confirms
//   CC06  SSID, CC07 password: read, ASCII after 3 bytes   never logged, displayed, stored or put on the pasteboard
//   CC0C  BSSID: read, optional                            only "present, MAC-shaped yes/no" is logged
//   CC09  status: read/notify, tag/length/value list       tag 0x0001 = Wi-Fi status (0 off … 2 launched)
//   CC0A  firmware, CC0B model name: read                  logged (unless they look like a serial or a MAC)
//
// Never written: EE01 (pairing / power off), FF01 (remote), anything in DD or BB, any CC characteristic but CC08.
// The only other change: when CC09 can't be read, switchWiFiOn subscribes to its notifications (a descriptor write
// iOS makes for setNotifyValue), and Disconnect turns them off again.
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

/// Build 10: the Bluetooth half of the Wi-Fi handover. Its own CBCentralManager (no restore identifier, created on
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

    /// One line for the UI.
    private(set) var status = "idle"
    private(set) var busy = false
    /// The connected camera's name, nil when not connected.
    private(set) var connectedName: String?
    /// Set when an ATT error (or a read that never answers) suggests encryption or authentication: the guided run
    /// asks whether iOS showed a pairing dialog.
    var lastPairingHint: String?

    var isConnected: Bool { connectedName != nil }

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
    @ObservationIgnored private var discovered = false
    @ObservationIgnored private var scanFound: CBPeripheral?
    @ObservationIgnored private var cc09Latest: Data?
    @ObservationIgnored private var cc09Updates = 0
    /// Counts Disconnect taps, so a wait can tell a Disconnect from the camera dropping the link.
    @ObservationIgnored private var disconnectRequests = 0
    @ObservationIgnored private var waiters: [String: Waiter] = [:]
    private let clock = ContinuousClock()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Data?, Error>
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
        cc = [:]
        discovered = false
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedPeripheralKey)
        let total = (clock.now - started).inSeconds
        let attemptSeconds = (clock.now - attemptStart).inSeconds
        status = "connected to \(name)"
        log.note(String(format: "Wi-Fi handover: connected to %@ via %@ in %.2f s (%.2f s since Connect)", name, route, attemptSeconds, total))
        return name
    }

    // MARK: - Discover

    /// Lists every service and characteristic UUID with its properties (no values) and records
    /// ble.handover.services and ble.handover.cameraControl.
    func discover() async throws -> HandoverInventory {
        try await run("Discover") {
            try await self.doDiscover()
        }
    }

    private func doDiscover() async throws -> HandoverInventory {
        let p = try connectedPeripheral()
        let started = clock.now
        status = "discovering services"
        cc = [:]
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
                if isControl, let code = Self.shortCode(c.uuid), Self.codes.contains(code) {
                    cc[code] = c
                    inventory.found[code] = true
                }
            }
            inventory.characteristics[service.uuid.uuidString] = lines
            log.note("  \(service.uuid.uuidString)\(service.isPrimary ? "" : " (secondary)"): \(lines.isEmpty ? "no characteristics" : lines.joined(separator: ", "))")
        }
        discovered = true
        let present = Self.codes.filter { inventory.found[$0] == true }
        let absent = Self.codes.filter { inventory.found[$0] != true }
        let seconds = (clock.now - started).inSeconds
        log.measure("ble.handover.services", Double(services.count), "count",
                    context: String(format: "%@, discovered in %.2f s", connectedName ?? "camera", seconds))
        log.flag("ble.handover.cameraControl", inventory.hasCameraControl,
                 context: inventory.hasCameraControl
                    ? "8000CC00 present; \(present.isEmpty ? "none" : present.joined(separator: ", ")) found\(absent.isEmpty ? "" : ", \(absent.joined(separator: ", ")) missing")"
                    : "no 8000CC00 service")
        status = "discovered \(services.count) services; \(present.count) of \(Self.codes.count) CC characteristics"
        return inventory
    }

    // MARK: - Safe reads

    /// Reads CC0A (firmware), CC0B (model), CC09 (status, parsed) and, for other readable CC characteristics except
    /// CC06/CC07/CC0C, logs only the length. ATT errors are logged by name; a disconnect throws. Returns the Wi-Fi
    /// status if CC09 carries tag 0x0001.
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
                    let parsed = Self.describeStatus(data)
                    wifiStatus = parsed.status
                    log.note("Wi-Fi handover: CC09 status: \(parsed.text)")
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
        status = "safe reads done; Wi-Fi status \(wifiStatus.map { String($0) } ?? "unknown")"
        return wifiStatus
    }

    // MARK: - Switch Wi-Fi on (the one write)

    /// Writes 0x01 to CC08 with response, then waits up to `timeout` for CC09 to report status 2, polling CC09 once
    /// a second when it is readable. Only when CC09 can't be read does it subscribe to CC09's notifications (a
    /// descriptor write; Disconnect turns them off). Records what CC09 reported as ble.handover.wifiOn.reported (the
    /// guided run records what the camera shows as ble.handover.wifiOn), ble.handover.wifiOn.latency for status 2,
    /// ble.handover.cc09.firstChange for the first change of any kind, and ble.handover.linkDroppedAfterWrite. A link
    /// drop after the write is an outcome (returns false), not an error. Call only after the tester has confirmed.
    func switchWiFiOn(timeout: Double = 30) async throws -> Bool {
        try await run("Switch Wi-Fi on") {
            try await self.doSwitchWiFiOn(timeout: timeout)
        }
    }

    private func doSwitchWiFiOn(timeout: Double) async throws -> Bool {
        let p = try connectedPeripheral()
        if !discovered { _ = try await doDiscover() }
        guard let cc08 = cc["CC08"] else {
            log.flag("ble.handover.wifiOn.reported", false, context: "no CC08 characteristic in 8000CC00; nothing written")
            throw HandoverError.missing("CC08")
        }
        let cc09 = cc["CC09"]
        var pollCC09 = cc09?.properties.contains(.read) == true
        var baseline: Data?
        var lastStatus: Int?
        if let cc09, pollCC09 {
            switch try await read(cc09, code: "CC09") {
            case .value(let data):
                baseline = data
                let parsed = Self.describeStatus(data)
                lastStatus = parsed.status
                log.note("Wi-Fi handover: CC09 before the write: \(parsed.text)")
            case .failed(let reason):
                log.warn("Wi-Fi handover: CC09 read before the write failed: \(reason)")
            }
        }
        var notifying = false
        // Subscribing writes CC09's descriptor on the camera, so it happens only when CC09 can't be polled.
        if let cc09, !pollCC09, cc09.properties.contains(.notify) || cc09.properties.contains(.indicate) {
            status = "subscribing to CC09"
            cc09Latest = nil
            do {
                _ = try await wait("notify:\(cc09.uuid.uuidString)", timeout: 10, what: "CC09 subscription") {
                    p.setNotifyValue(true, for: cc09)
                }
                notifying = cc09.isNotifying
                log.note("Wi-Fi handover: CC09 isn't readable, so subscribed to its notifications (isNotifying \(cc09.isNotifying ? "yes" : "no")); Disconnect turns them off")
            } catch let e as HandoverError where !e.isTimeout {
                throw e
            } catch {
                noteIfPairing(error, during: "CC09 subscription")
                log.warn("Wi-Fi handover: CC09 subscription failed: \(Self.errorName(error))")
            }
        }
        // CC09 not readable: the value the camera sent on subscribing (if any) is the baseline.
        if baseline == nil, notifying, let value = cc09Latest {
            baseline = value
            let parsed = Self.describeStatus(value)
            lastStatus = parsed.status
            log.note("Wi-Fi handover: CC09 before the write (notification): \(parsed.text)")
        }
        if !notifying && !pollCC09 {
            log.warn("Wi-Fi handover: CC09 can't be read or subscribed to: the camera's Wi-Fi state can't be seen over Bluetooth after the write; check the camera's screen")
        }
        let props = Self.describe(cc08.properties)
        if !cc08.properties.contains(.write) {
            log.warn("Wi-Fi handover: CC08's properties are \(props), without write; trying the write with response anyway")
        }

        status = "writing 0x01 to CC08"
        log.warn("Wi-Fi handover: writing 0x01 to CC08 with response (\(props)), confirmed by the tester")
        let updatesBeforeWrite = cc09Updates
        let requestsBeforeWrite = disconnectRequests
        let writeStart = clock.now
        do {
            _ = try await wait("write:\(cc08.uuid.uuidString)", timeout: 15, what: "CC08 write") {
                p.writeValue(Data([0x01]), for: cc08, type: .withResponse)
            }
        } catch let e as HandoverError where !e.isTimeout {
            if case .disconnected(let reason) = e {
                return linkDropped(writeStart, during: "the CC08 write's acknowledgement", reason: reason, changes: "none")
            }
            // Disconnect tapped or Bluetooth off: no answer about the camera's Wi-Fi, so nothing is recorded.
            log.warn("Wi-Fi handover: the CC08 write stopped (\(e)); ble.handover.wifiOn.reported not recorded")
            throw e
        } catch {
            noteIfPairing(error, during: "CC08 write")
            let reason = Self.errorName(error)
            log.error("Wi-Fi handover: CC08 write failed: \(reason)")
            log.flag("ble.handover.wifiOn.reported", false, context: "CC08 ← 0x01 failed: \(reason)")
            status = "CC08 write failed: \(reason)"
            return false
        }
        let ackSeconds = (clock.now - writeStart).inSeconds
        log.note(String(format: "Wi-Fi handover: CC08 ← 0x01 acknowledged in %.0f ms; waiting up to %.0f s for CC09 status 2", ackSeconds * 1000, timeout))

        guard let status09 = cc09, notifying || pollCC09 else {
            status = "CC08 written; no CC09 to confirm (check the camera)"
            log.warn("Wi-Fi handover: ble.handover.wifiOn.reported not recorded: no CC09 status to confirm it; check the camera's screen")
            return false
        }

        var last = baseline
        var history: [String] = []
        var on = false
        var changed = false
        var seenUpdates = updatesBeforeWrite
        var nextPoll = clock.now
        let alreadyOn = lastStatus == 2
        let deadline = writeStart + .seconds(timeout)
        status = "waiting for the camera's Wi-Fi (up to \(Int(timeout)) s)"

        /// True only when `value` carries status 2. Any change is logged, and the first is timed on its own.
        func consider(_ value: Data, via source: String) -> Bool {
            guard value != last else { return false }
            let elapsed = (clock.now - writeStart).inSeconds
            let parsed = Self.describeStatus(value)
            last = value
            let summary: String = parsed.status.map { "status \($0)" } ?? "changed, no status tag"
            history.append(String(format: "+%.2f s %@", elapsed, summary))
            log.note(String(format: "Wi-Fi handover: +%.2f s since the write, CC09 (%@): %@", elapsed, source, parsed.text))
            if !changed {
                changed = true
                log.measure("ble.handover.cc09.firstChange", elapsed, "s",
                            context: "first change of CC09 after CC08 ← 0x01 (\(source)): \(summary)")
            }
            guard let s = parsed.status else { return false }
            lastStatus = s
            return s == 2
        }

        if alreadyOn {
            log.warn("Wi-Fi handover: CC09 already reported status 2 before the write; no latency to measure")
        }
        do {
            waiting: while !alreadyOn && clock.now < deadline {
                guard peripheral === p, p.state == .connected else {
                    if disconnectRequests != requestsBeforeWrite { throw HandoverError.cancelled("Disconnect") }
                    throw HandoverError.disconnected("the link dropped while waiting for the Wi-Fi status")
                }
                if cc09Updates != seenUpdates {
                    seenUpdates = cc09Updates
                    if let value = cc09Latest, consider(value, via: "notification") { on = true; break waiting }
                }
                if pollCC09, clock.now >= nextPoll {
                    nextPoll = clock.now + .seconds(1)
                    switch try await read(status09, code: "CC09", timeout: 5) {
                    case .value(let data):
                        seenUpdates = cc09Updates
                        if consider(data, via: "read") { on = true; break waiting }
                    case .failed(let reason):
                        log.warn("Wi-Fi handover: CC09 poll failed (\(reason)); polling stops\(notifying ? ", notifications only" : "")")
                        pollCC09 = false
                        if !notifying { break waiting }
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        } catch HandoverError.disconnected(let reason) {
            return linkDropped(writeStart, during: "the wait for CC09", reason: reason,
                               changes: history.isEmpty ? "none" : history.joined(separator: ", "))
        } catch {
            // Disconnect tapped (or the guided run's time limit): no answer about the camera's Wi-Fi, nothing recorded.
            let elapsed = (clock.now - writeStart).inSeconds
            log.warn(String(format: "Wi-Fi handover: the wait stopped %.1f s after CC08 ← 0x01 (%@); ble.handover.wifiOn.reported not recorded; changes: %@",
                            elapsed, "\(error)", history.isEmpty ? "none" : history.joined(separator: ", ")))
            throw error
        }

        let elapsed = (clock.now - writeStart).inSeconds
        let changes = history.isEmpty ? "none" : history.joined(separator: ", ")
        log.flag("ble.handover.linkDroppedAfterWrite", false, context: String(format: "link still up %.1f s after CC08 ← 0x01", elapsed))
        if alreadyOn {
            log.flag("ble.handover.wifiOn.reported", true,
                     context: String(format: "CC09 already reported status 2 before CC08 ← 0x01 (ack %.0f ms); no latency recorded", ackSeconds * 1000))
            status = "camera Wi-Fi already on"
            return true
        }
        if on {
            log.measure("ble.handover.wifiOn.latency", elapsed, "s",
                        context: String(format: "CC08 ← 0x01 (ack %.0f ms) → CC09 status 2; changes: %@", ackSeconds * 1000, changes))
            log.flag("ble.handover.wifiOn.reported", true, context: "CC09 reported status 2 after the CC08 write; changes: \(changes)")
            status = String(format: "camera Wi-Fi on after %.1f s", elapsed)
        } else {
            let lastText: String = lastStatus.map { String($0) } ?? "unknown"
            log.flag("ble.handover.wifiOn.reported", false,
                     context: String(format: "no CC09 status 2 within %.0f s of CC08 ← 0x01 (last status %@); changes: %@",
                                     elapsed, lastText, changes))
            status = "no Wi-Fi-on status after \(Int(elapsed)) s (check the camera)"
        }
        return on
    }

    /// The link dropped after CC08 ← 0x01. That is an outcome (the camera may drop Bluetooth when its Wi-Fi comes
    /// on), not a failure: records ble.handover.linkDroppedAfterWrite, leaves ble.handover.wifiOn.reported
    /// unrecorded, and returns false so the guided run still asks what the camera shows.
    private func linkDropped(_ writeStart: ContinuousClock.Instant, during what: String, reason: String,
                             changes: String) -> Bool {
        let elapsed = (clock.now - writeStart).inSeconds
        log.warn(String(format: "Wi-Fi handover: the Bluetooth link dropped %.1f s after CC08 ← 0x01, during %@ (%@); ble.handover.wifiOn.reported not recorded; check the camera's screen", elapsed, what, reason))
        log.flag("ble.handover.linkDroppedAfterWrite", true,
                 context: String(format: "%.1f s after CC08 ← 0x01, during %@ (%@); CC09 changes: %@", elapsed, what, reason, changes))
        status = String(format: "link dropped %.1f s after the write (check the camera)", elapsed)
        return false
    }

    // MARK: - Credentials

    /// Reads CC06 (SSID), CC07 (password) and CC0C (BSSID, if present). Logs and returns only what
    /// `HandoverCredentials.description` shows, yes/no comparisons with the Wi-Fi tab's fields and the values' layout
    /// as lengths and yes/no (`credentialLayout`). ble.handover.credentials is yes only for a usable pair: an SSID and
    /// an 8–63 printable ASCII passphrase.
    func readCredentials() async throws -> HandoverCredentials {
        try await run("Read Wi-Fi details") {
            try await self.doReadCredentials()
        }
    }

    private func doReadCredentials() async throws -> HandoverCredentials {
        _ = try connectedPeripheral()
        if !discovered { _ = try await doDiscover() }
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
            log.flag("ble.handover.credentials", usable,
                     context: credentials.description + (usable ? "" : "; not usable: an empty SSID or a passphrase that isn't 8–63 printable ASCII (see the layout line)"))
            status = "Wi-Fi details read: \(credentials.description)"
            return credentials
        } catch {
            log.flag("ble.handover.credentials", false, context: "\(error)")
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

    // MARK: - Disconnect

    /// Drops this app's connection (if Creators' App holds one too, iOS keeps the link for it) and ends any
    /// operation that is waiting.
    func disconnect() {
        disconnectRequests += 1
        central?.stopScan()
        if let p = peripheral, p.state != .disconnected {
            // Undo switchWiFiOn's CC09 subscription, if it made one (the link may close before the camera sees it).
            if p.state == .connected, let c = cc["CC09"], c.isNotifying {
                p.setNotifyValue(false, for: c)
                log.note("Wi-Fi handover: CC09 notifications turned off")
            }
            central?.cancelPeripheralConnection(p)
            log.note("Wi-Fi handover: disconnecting from \(p.name ?? "(no name)")")
        } else {
            log.note("Wi-Fi handover: Disconnect (not connected)")
        }
        failAll(HandoverError.cancelled("Disconnect"))
        peripheral = nil
        scanFound = nil
        connectedName = nil
        cc = [:]
        discovered = false
        status = "disconnected"
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
    /// the network name, a short binary value as hex, anything else as a length only.
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
            return show(text, prefix: "after a 3-byte header \(Data(bytes.prefix(3)).hexDump()), ")
        }
        if data.count <= 4 { return "\(data.count) B: \(data.hexDump())" }
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
        let value: [UInt8]
    }

    /// CC09 as a tag/length/value list. The layout is unverified, so these are tried in turn and the first that
    /// uses every byte wins: 16-bit tag and length big-endian, the same little-endian, 16-bit tag with an 8-bit
    /// length, 8-bit tag and length; then the same after a 3-byte header.
    nonisolated static func parseTLV(_ data: Data) -> (layout: String, items: [TLVItem])? {
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
                    items.append(TLVItem(tag: tag, value: Array(bytes[headerEnd ..< headerEnd + length])))
                    i = headerEnd + length
                }
                if ok, !items.isEmpty { return (layout.name + label, items) }
            }
        }
        return nil
    }

    /// CC09 for the log: the layout, every tag with its length, the value of tag 0x0001 only (1 or 2 bytes; the other
    /// tags are unknown and could hold a serial or part of an address), and the Wi-Fi status from tag 0x0001. Raw
    /// bytes are never logged beyond the first 3.
    nonisolated static func describeStatus(_ data: Data) -> (status: Int?, text: String) {
        guard let parsed = parseTLV(data) else {
            return (nil, "\(data.count) B, not a tag/length/value list (starts \(Data(data.prefix(3)).hexDump()))")
        }
        var status: Int?
        let parts = parsed.items.map { item -> String in
            let tag = String(format: "0x%04X", item.tag)
            if item.tag == 0x0001, status == nil, !item.value.isEmpty {
                // One byte expected; for a longer value the first byte is taken (unverified).
                status = Int(item.value[0])
            }
            guard item.tag == 0x0001, (1 ... 2).contains(item.value.count) else {
                return "\(tag): \(item.value.count) B"
            }
            let value = item.value.reduce(0) { $0 << 8 | Int($1) }
            return "\(tag) = \(value)\(item.value.count == 1 ? "" : " (\(item.value.count) B)")"
        }
        let statusText = status.map { "Wi-Fi status \($0)\(statusMeaning($0))" } ?? "no tag 0x0001"
        return (status, "\(statusText); \(parsed.layout): \(parts.joined(separator: ", "))")
    }

    nonisolated static func statusMeaning(_ s: Int) -> String {
        switch s {
        case 0: return " (off)"
        case 2: return " (launched)"
        default: return " (meaning unverified)"
        }
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
            cc = [:]
            discovered = false
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
        cc = [:]
        discovered = false
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
        let isStatus = characteristic.service.map { Self.isCameraControl($0.uuid) } == true
            && Self.shortCode(characteristic.uuid) == "CC09"
        if isStatus, error == nil, let value = characteristic.value {
            cc09Latest = value
            cc09Updates += 1
        }
        // A read's answer; anything else is a notification (only CC09 is subscribed to) and is handled above.
        let key = "read:\(characteristic.uuid.uuidString)"
        guard waiters[key] != nil else { return }
        if let error {
            resolve(key, .failure(error))
        } else {
            resolve(key, .success(characteristic.value ?? Data()))
        }
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
        log.warn("Wi-Fi handover: the camera changed its services (\(invalidatedServices.map(\.uuid.uuidString).joined(separator: ", "))); discover again")
        cc = [:]
        discovered = false
    }
}
