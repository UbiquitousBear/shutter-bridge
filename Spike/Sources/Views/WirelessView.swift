import SwiftUI
import UIKit
import PTPKit

/// Week 2 (days 6–9): PTP/IP over Wi-Fi. Every button is one runbook step; each logs what it saw and records the
/// measurements the Log tab exports into the spike plan's table (names "ptpip.<net>.…", net = ap or lan from the
/// Network picker).
struct WirelessView: View {
    /// Created by the app and shared with the Guided tab's runner.
    @Environment(WirelessLab.self) private var lab

    var body: some View {
        NavigationStack {
            WirelessPanel(lab: lab)
                .navigationTitle("Wi-Fi")
        }
    }
}

private struct WirelessPanel: View {
    @Bindable var lab: WirelessLab
    @Environment(ContinuedTask.self) private var continued
    @AppStorage("ptpip.net") private var net = "ap"
    @AppStorage("ptpip.host") private var host = "192.168.122.1"
    /// Written on first appearance and kept: the day-7 question is whether the camera remembers this GUID.
    @AppStorage("ptpip.guid") private var guidString = ""
    @AppStorage("ptpip.pauseAtHalf") private var pauseAtHalf = true
    @State private var showScanner = false

    private var target: WiFiTarget {
        WiFiTarget(net: net == "lan" ? "lan" : "ap",
                   host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                   guid: UUID(uuidString: guidString) ?? UUID())
    }

    /// One camera operation at a time; a continued-task download counts as one.
    private var cameraLocked: Bool { lab.busy || continued.isRunning }

    var body: some View {
        Form {
            cameraSection
            statusSection
            probeSection
            handshakeSection
            sonySection
            downloadSection
            CopyAllSection(linkName: "Wi-Fi", canStart: lab.isConnected && !lab.busy, canContinue: !lab.busy,
                           continuePaused: { lab.continuePausedCopy() }) { lab.copyAllARW() }
            resumeSection
        }
        .onAppear {
            if UUID(uuidString: guidString) == nil { guidString = UUID().uuidString }
            lab.path.start()
        }
        .onDisappear { lab.path.stop() }
        .sheet(isPresented: $showScanner) {
            QRScannerSheet(onPayload: { payload in
                showScanner = false
                lab.applyScanned(payload)
            }, onFailure: { message in
                showScanner = false
                lab.log.warn("QR scanner: \(message)")
            }, onCancel: {
                showScanner = false
            })
        }
    }

    private var cameraSection: some View {
        Section("Camera") {
            Picker("Network", selection: $net) {
                Text("Camera AP").tag("ap")
                Text("Home LAN").tag("lan")
            }
            .pickerStyle(.segmented)
            TextField("Camera IP", text: $host)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            LabeledContent("Initiator GUID") {
                Text(guidString).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            Button("New GUID (re-pair test)") {
                guidString = UUID().uuidString
                lab.log.note("New initiator GUID \(guidString); the camera should now treat the phone as a stranger")
            }
            .disabled(cameraLocked)
        }
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Session", value: lab.connectionState)
            if let connectedNet = lab.sessionNet, connectedNet != target.net {
                Text("Connected as \(connectedNet == "lan" ? "Home LAN" : "Camera AP"); its numbers stay in that column until you reconnect.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if lab.busy {
                VStack(alignment: .leading, spacing: 6) {
                    Text(lab.activity).font(.callout)
                    if let progress = lab.progress { ProgressView(value: progress) } else { ProgressView() }
                }
            }
            if continued.isRunning {
                LabeledContent("Continued task", value: "\(continued.state) · \(continued.progressText)")
                Button("Stop continued task", role: .destructive) { continued.stop() }
            }
        }
    }

    private var probeSection: some View {
        Section {
            Button("TCP connect to port 15740") { lab.probePort(target) }
            Button("Bonjour browse _ptp._tcp (5 s)") { lab.browseBonjour(target) }
            ForEach(lab.bonjourAddresses, id: \.self) { address in
                Button("Use \(address) as camera IP") { host = Self.hostPart(address) }
            }
            Button("SSDP M-SEARCH to camera IP") { lab.ssdpUnicast(target) }
            Button("SSDP M-SEARCH multicast") { lab.ssdpMulticast(target) }
            ForEach(lab.ssdp.replies) { reply in
                VStack(alignment: .leading, spacing: 4) {
                    Text(reply.headline).font(.caption2.monospaced())
                    if let location = reply.location, let description = lab.ssdp.descriptions[location] {
                        Text(description).font(.caption)
                    }
                    if let ip = reply.locationHost {
                        Button("Use this IP (\(ip))") { host = ip }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
            LabeledContent("Network path") {
                Text(lab.path.current?.summary ?? "—").font(.caption2)
            }
            LabeledContent("Internet", value: lab.path.internet)
            Button("Check internet") { lab.checkInternet() }
        } header: {
            Text("Day 6 · Probe")
        } footer: {
            Text("Multicast needs the com.apple.developer.networking.multicast entitlement; without it the log shows the policy failure. Unicast needs only a typed IP.")
        }
        .disabled(lab.probing)
    }

    private var handshakeSection: some View {
        Section {
            Button("Connect + OpenSession + GetDeviceInfo") { lab.connect(target) }
            Button("Reconnect (same GUID)") { lab.reconnect(target) }
            Button("Sony SDIO init sequence") { lab.sonySDIO() }
                .disabled(!lab.isConnected)
            Button("Disconnect", role: .destructive) { lab.disconnect() }
                .disabled(!lab.isConnected)
        } header: {
            Text("Day 7 · Handshake")
        } footer: {
            Text("Power-cycle test: switch the camera off and on, rejoin its Wi-Fi, tap Reconnect and note what the camera shows. Then New GUID, Connect, and note it again.")
        }
        .disabled(cameraLocked)
    }

    /// Build 9: Sony's private PC Remote init sequence after Connect, the keep-alive, and the two contents-transfer
    /// sessions, after Imagedge (field-tested on a ZV-E10; unverified on the α7C II).
    private var sonySection: some View {
        Section {
            Toggle("SDIO straight after Connect", isOn: $lab.sdioAfterConnect)
            Self.caption("After OpenSession and GetDeviceInfo, Connect and Reconnect send the Sony init sequence (GetStorageIDs, SDIO_Connect 1, 2, 3, SDIO_GetExtDeviceInfo) when the camera lists SDIO_Connect 0x9201.")
            Toggle("Keep-alive every 10 s (\(lab.keepAlives) sent)", isOn: $lab.keepAlive)
            Self.caption("Sends GetDeviceInfo after every 10 s with nothing else running, while a session is open and the app is in the foreground.")
            Button("Contents transfer: whole card") { lab.connectContentsTransfer(target, mode: .wholeCard) }
                .disabled(cameraLocked)
            Self.caption("Reconnects with SDIO_OpenSession 0x9210 [1, 1] instead of OpenSession, the init sequence, 0x9212 [2,0,0] then [2,1,0], and waits up to 120 s for the card to list.")
            Button("Contents transfer: photos sent from the camera") { lab.connectContentsTransfer(target, mode: .selectedOnCamera) }
                .disabled(cameraLocked)
            Self.caption("Reconnects with OpenSession, the init sequence and 0x9212 [1,0,0]; once it says connected, send photos from the camera, and it waits up to 90 s for them to list.")
            Button("Selected set in this session") { lab.selectedSetInSession() }
                .disabled(cameraLocked || !lab.isConnected)
            Self.caption("The same on the session already open, without reconnecting: the init sequence if it hasn't run, 0x9212 [1,0,0], then up to 90 s for the photos sent to list.")
        } header: {
            Text("Sony (build 9)")
        } footer: {
            Text("PC Remote mode. The session stays open afterwards, so List card, Thumbnails, GetObject and Shutter test work on it, and Reconnect and Resume read reopen the same kind of session until the next Connect.")
        }
    }

    /// Verbatim: the square brackets and digits are what is sent, not Markdown.
    private static func caption(_ text: String) -> some View {
        Text(verbatim: text).font(.caption).foregroundStyle(.secondary)
    }

    private var downloadSection: some View {
        Section {
            Button("List card") { lab.listCard() }
            Button("Thumbnails for 50 newest") { lab.thumbnails() }
            Button("GetObject 20 newest ARW") { lab.downloadARW() }
            Button("GetObject 3 newest MP4") { lab.downloadMP4() }
            Button("GetObject 20 newest ARW in a continued task") { lab.downloadARWContinued() }
            Button("Shutter test (20 s)") { lab.shutterTest() }
            LabeledContent("Card", value: lab.objects.isEmpty ? "not listed" : "\(lab.objects.count) objects")
            LabeledContent("ObjectAdded events", value: "\(lab.objectAddedCount)")
            if let battery = lab.batteryLine {
                LabeledContent("Battery") { Text(battery).font(.caption) }
            }
        } header: {
            Text("Day 8 · Enumerate and download")
        } footer: {
            Text("Downloads stream to temporary files, are hashed and timed, then deleted. Battery per GB is recorded once 1 GB has downloaded in one session. Continued task: start it, then lock the phone.")
        }
        .disabled(cameraLocked || !lab.isConnected)
    }

    private var resumeSection: some View {
        Section {
            Group {
                Button("Partial read probe (newest ARW)") { lab.probePartialReads() }
                    .disabled(cameraLocked || !lab.isConnected)
                Text(verbatim: "Byte-range reads on \(target.netLabel): \(lab.partialProbeLabel(net: target.net))")
                    .font(.caption)
                Button("Reference hash (GetObject newest ARW)") { lab.referenceHash() }
                    .disabled(cameraLocked || !lab.isConnected)
                // Verbatim: a "%" in a LocalizedStringKey literal can be read as a format specifier.
                Toggle(isOn: $pauseAtHalf) { Text(verbatim: "Pause at 50 % for Wi-Fi off") }
                Button("Start resumable read (newest ARW)") { lab.startResumableRead(pauseAtHalf: pauseAtHalf) }
                    .disabled(cameraLocked || !lab.isConnected)
                Button("Resume read") { lab.resumeRead(target) }
                    .disabled(cameraLocked || lab.resumeSummary == nil)
                if let saved = lab.resumeSummary {
                    Text("Saved: \(saved)").font(.caption)
                    Button("Forget partial read", role: .destructive) { lab.forgetPartialRead() }
                        .disabled(cameraLocked)
                }
            }
            Group {
                Button("Scan camera QR code") {
                    if let reason = QRScannerView.unavailableReason {
                        lab.log.warn("QR scanner unavailable: \(reason)")
                    } else {
                        showScanner = true
                    }
                }
                if let summary = lab.qrSummary {
                    Text(summary).font(.caption)
                }
                TextField("Camera SSID", text: $lab.joinSSID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Passphrase", text: $lab.joinPassphrase)
                Button(lab.joining ? "Joining…" : "Join camera Wi-Fi") { lab.join() }
                    .disabled(lab.joining || lab.joinSSID.isEmpty)
                if let gateway = lab.gatewayCandidate {
                    Button("Use gateway as camera IP (\(gateway))") { host = gateway }
                }
                Button("Forget joined network (to re-time the join)") { lab.forgetJoinedNetwork() }
                    .disabled(lab.joining || lab.joinSSID.isEmpty)
            }
        } header: {
            Text("Day 9 · Resume, discovery, join")
        } footer: {
            Text(verbatim: "Resume: Partial read probe once per network (it tries each byte-range layout the camera lists against a GetObject of the same file, and Start resumable read then uses the one that works), Reference hash, then Start resumable read; turn Wi-Fi off when it pauses at 50 %; turn Wi-Fi on, rejoin the camera, tap Resume read. SSDP and Bonjour are under Day 6 · Probe.")
        }
    }

    /// "192.168.122.1:15740" → "192.168.122.1"; "[fe80::1%en0]:15740" → "fe80::1%en0" (NetFormat brackets IPv6
    /// host:port). Anything else is returned as is.
    static func hostPart(_ address: String) -> String {
        if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
            return String(address[address.index(after: address.startIndex) ..< close])
        }
        let parts = address.split(separator: ":")
        return parts.count == 2 ? String(parts[0]) : address
    }
}

// MARK: - Model

/// Which measurement column, which camera, and who we are, captured from the controls at the moment of the tap.
struct WiFiTarget: Sendable {
    /// "ap" or "lan".
    let net: String
    let host: String
    let guid: UUID

    var prefix: String { "ptpip.\(net)" }
    var netLabel: String { net == "lan" ? "Home LAN" : "Camera AP" }
}

/// What *Partial read probe* found on a network in one kind of session, kept in UserDefaults under
/// "ptpip.partialVariant.<net>.<session>" (session: a SonyContentsMode raw value, or "plain"; the value a
/// PTPPartialRead.Variant raw value, or "none"). The refusal on 2 Nov was seen in the whole-card contents transfer
/// only, so a result in one kind of session says nothing about another. Start resumable read uses the remembered
/// variant; the guided resume run probes first when nothing is remembered.
enum PartialReadProbe: Equatable, Sendable {
    /// No probe has finished on this network.
    case notProbed
    /// The probe ran and no layout returned the right bytes: an interrupted file restarts from zero.
    case noneWorks
    /// The first layout in PTPPartialRead.probeOrder whose two chunks matched the GetObject reference.
    case works(PTPPartialRead.Variant)

    /// Each probe request asks for 1 MiB.
    static let chunkLength: UInt32 = 1024 * 1024
    /// A layout the camera doesn't understand may get no answer; 15 s rather than the client's 30 s.
    static let idleTimeout: Double = 15
    private static let noneValue = "none"

    static func key(net: String, session: String) -> String { "ptpip.partialVariant.\(net).\(session)" }

    static func remembered(net: String, session: String) -> PartialReadProbe {
        guard let raw = UserDefaults.standard.string(forKey: key(net: net, session: session)) else { return .notProbed }
        if raw == noneValue { return .noneWorks }
        if let variant = PTPPartialRead.Variant(rawValue: raw) { return .works(variant) }
        return .notProbed
    }

    static func remember(_ variant: PTPPartialRead.Variant?, net: String, session: String) {
        UserDefaults.standard.set(variant?.rawValue ?? noneValue, forKey: key(net: net, session: session))
    }

    /// Back to not probed: a probe that stopped before any layout worked and before every listed layout was sent.
    static func forget(net: String, session: String) {
        UserDefaults.standard.removeObject(forKey: key(net: net, session: session))
    }

    var label: String {
        switch self {
        case .notProbed: return "not probed yet"
        case .noneWorks: return "none works (an interrupted file restarts)"
        case .works(let variant): return "\(variant.rawValue) works"
        }
    }
}

/// Build 9: Sony's two contents-transfer sessions, as Imagedge opens them (field-tested on a ZV-E10 by
/// github.com/mvpzac/Imagedge; `unverified` on the α7C II).
enum SonyContentsMode: String, CaseIterable, Sendable {
    /// SDIO_OpenSession (0x9210) with functionMode 1, ContentsTransfer: the whole card.
    case wholeCard
    /// Standard OpenSession (functionMode 0, RemoteControl): the photos the user sends from the camera, listed under
    /// a virtual storage (0xF10001 on the ZV-E10).
    case selectedOnCamera

    var label: String {
        switch self {
        case .wholeCard: return "whole card"
        case .selectedOnCamera: return "photos sent from the camera"
        }
    }

    /// SDIO_SetContentsTransferMode (0x9212) calls in order, each with the pause Imagedge makes after it. Other
    /// parameters for the selected set ({1}, {0,0,0}) answered 0x201D on the ZV-E10.
    var transferModeSteps: [(p1: UInt32, p2: UInt32, p3: UInt32, pauseMilliseconds: Int)] {
        switch self {
        case .wholeCard: return [(2, 0, 0, 200), (2, 1, 0, 1500)]
        case .selectedOnCamera: return [(1, 0, 0, 0)]
        }
    }

    /// How long to keep polling for a non-empty handle list: a big card takes a while to index, and the tester sends
    /// photos from the camera only once the session is open.
    var pollLimit: Double {
        switch self {
        case .wholeCard: return 120
        case .selectedOnCamera: return 90
        }
    }
}

/// One object on the card with its ObjectInfo, as listed in this session.
struct CardObject: Identifiable, Sendable {
    let handle: PTPObjectHandle
    let info: PTPObjectInfo
    /// Capture date, falling back to modification date; nil sorts last.
    let date: Date?

    init(handle: PTPObjectHandle, info: PTPObjectInfo) {
        self.handle = handle
        self.info = info
        self.date = info.captureDate ?? info.modificationDate
    }

    var id: UInt32 { handle.rawValue }

    static func newestFirst(_ a: CardObject, _ b: CardObject) -> Bool {
        let da = a.date ?? .distantPast
        let db = b.date ?? .distantPast
        if da != db { return da > db }
        return a.handle.rawValue > b.handle.rawValue
    }
}

enum WiFiLabError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

/// Build 14: what a Wi-Fi *Copy all RAW to Files* may do to recover, and what it was copied under. The Wi-Fi tab's
/// button passes the default (no Bluetooth, Creators' App not asked); the guided run asks the tester for both.
struct CopyAllRecovery {
    /// The Bluetooth lab when the tester allowed the copy to switch the camera's Wi-Fi back on over Bluetooth if it goes
    /// off (CC08 = 01 and Sony's five status notifications, turned off afterwards); nil: no Bluetooth.
    var bluetooth: SonyWiFiHandover? = nil
    /// "Creators' App quit" or "Creators' App open in the background"; nil when not asked.
    var creatorsApp: String? = nil
    /// In place of "Bluetooth recovery off/allowed" when the question wasn't asked for a reason (the home LAN).
    var bluetoothNote: String? = nil

    /// For the context of every copy measurement.
    var conditions: String {
        "\(creatorsApp ?? "Creators' App not asked"); \(bluetoothNote ?? "Bluetooth recovery \(bluetooth == nil ? "off" : "allowed")")"
    }
}

/// Build 14: a failure that stops the Wi-Fi copy loop for a recovery instead of counting against a file.
private struct CopyInterruption {
    /// For the log, the recovery's measurements and, if the copy gives up, its stop reason.
    let cause: String
    /// The camera reported its card gone (StoreRemoved or StoreNotAvailable): the recovery first waits for StoreAdded.
    let storeGone: Bool
    /// A file was in flight (it is tried again after the recovery).
    let inFlight: Bool
}

/// Build 14: a file that got a non-OK answer and isn't counted yet: counted as failed once a later file copies, tried
/// again after a recovery otherwise.
private struct PendingCopyFailure {
    /// Its place in the copy's queue.
    let position: Int
    let name: String
    let code: PTPResponseCode
    let why: String
}

private enum CopyRecoveryOutcome {
    /// The session is back with the card listed again, on this client.
    case resumed(PTPIPClient, steps: String)
    /// The recovery didn't get the session back: why, and the steps it took.
    case failed(String, steps: String)
    /// Stop, Cancel run or the continued task's expiry, during the recovery.
    case stopped(String)
}

/// Build 14: the Bluetooth link a copy's recovery used, until releaseCopyBluetooth.
private struct CopyBluetoothHold {
    let handover: SonyWiFiHandover
    /// The recovery connected it (rather than the Bluetooth tab or the guided run).
    let ownLink: Bool
    /// The recovery turned Sony's notifications on.
    let subscribedHere: Bool
    /// Notifications already on over the link before the recovery.
    let notifyingBefore: Int
    /// The codes the recovery's subscribe reported notifying (empty: it didn't subscribe).
    var turnedOn: [String] = []
}

/// Build 14: the copy's continued-task progress in bytes. Apple documents expiry for tasks that report little or slow
/// progress (a DTS engineer: report 2–10 times a second, on the task's own progress), so the units are the bytes of the
/// files done (copied, or failed at their listed size) plus the bytes received of the file in flight, which GetObject
/// reports at most every 0.25 s. A recovery's waits add `recoveryStepBytes` of units at most once a second, so the
/// progress keeps moving while nothing arrives: those units are made up, so they are capped one unit short of the real
/// total (they never complete it). Until real progress has caught up with them, every report still moves it by
/// `catchUpStepBytes` (also kept short of the total), so it never sits still while bytes arrive (a recovery can add
/// 100–200 MB of made-up units, 10–40 s of real bytes). It never goes backwards (a file in flight dropped for a
/// recovery keeps what was shown). Before a continued copy's run exists, the paused copy's bytes stand in for the run's.
@MainActor
private final class CopyProgress {
    /// About 1 MB a second during a recovery's waits: a small fraction of the link's 13–19.5 MB/s.
    static let recoveryStepBytes = 1_000_000
    /// Each report's step while real progress is behind what was shown: a few KB, at most every 0.25 s.
    static let catchUpStepBytes = 4_096
    private let send: ContinuedTask.Report
    private let total: Int
    private let baseline: Int
    private var run: CopyAllRun?
    private var inFlight = 0
    /// Bumped for every file started or ended, so a late progress callback for a file that has ended is ignored.
    private var file = 0
    private var lastSent = 0
    private var lastTick: ContinuousClock.Instant?

    init(report: @escaping ContinuedTask.Report, totalBytes: UInt64, doneBytes: UInt64 = 0) {
        send = report
        total = max(1, Int(clamping: totalBytes))
        baseline = Int(clamping: doneBytes)
    }

    /// From here the units come from `run`'s bytes.
    func attach(_ run: CopyAllRun) {
        self.run = run
    }

    private var real: Int {
        (run.map { Int(clamping: $0.doneBytes) } ?? baseline) + inFlight
    }

    /// Files done changed (a file copied or failed, a recovery, a stop) or a new subtitle: the bytes of the file in
    /// flight are dropped. `count` (files done) is for the call site's reader; the units come from the run's bytes.
    func files(_ count: Int, _ subtitle: String?) {
        file += 1
        inFlight = 0
        push(subtitle)
    }

    /// A file is about to be fetched: its number, for `received`.
    func startFile() -> Int {
        file += 1
        inFlight = 0
        return file
    }

    /// Bytes received so far of file `number` (GetObject's progress callback, at most every 0.25 s).
    func received(_ bytes: UInt64, file number: Int) {
        guard number == file else { return }
        inFlight = Int(clamping: bytes)
        push(nil)
    }

    /// One step of a recovery's wait: `recoveryStepBytes` more, at most once a second, never up to the total.
    func tick() {
        let now = ContinuousClock().now
        if let last = lastTick, (now - last).inSeconds < 1 { return }
        lastTick = now
        let value = min(max(lastSent, real) + Self.recoveryStepBytes, total - 1)
        guard value > lastSent else { return }
        lastSent = value
        send(value, nil)
    }

    private func push(_ subtitle: String?) {
        let current = real
        let value: Int
        if current > lastSent {
            value = min(total, current)
        } else {
            // Behind the made-up units (or nothing new): a small step, never up to the total, so the count still moves.
            value = min(lastSent + Self.catchUpStepBytes, max(lastSent, total - 1))
        }
        lastSent = value
        send(value, subtitle)
    }
}

/// Build 14: one recovery's steps with their times, for the log and the recovery measurement's context. Each step
/// (and each `tick`) also moves the continued task's progress.
@MainActor
private final class CopyRecoverySteps {
    let log: SpikeLog
    let number: Int
    let meter: CopyProgress?
    /// For the log lines: "recovery 2", or (build 14) "continuing the paused copy".
    let label: String
    private let started = ContinuousClock().now
    private(set) var lines: [String] = []

    init(log: SpikeLog, number: Int, meter: CopyProgress? = nil, label: String? = nil) {
        self.log = log
        self.number = number
        self.meter = meter
        self.label = label ?? "recovery \(number)"
    }

    func add(_ text: String) {
        let line = String(format: "%.1f s: ", (ContinuousClock().now - started).inSeconds) + text
        lines.append(line)
        log.note("Copy all RAW: \(label): \(line)")
        meter?.tick()
    }

    /// A wait still going on (a port probe, the StoreAdded wait, the join): progress only, nothing logged.
    func tick() {
        meter?.tick()
    }

    var summary: String { lines.joined(separator: "; ") }
}

/// The Wi-Fi tab's state and actions. Main-actor isolated; the PTP/IP client is an actor of its own.
@Observable
@MainActor
final class WirelessLab {
    let log: SpikeLog
    let continued: ContinuedTask
    let lifecycle: LifecycleMonitor
    let ssdp: SSDPProbe
    let path: PathMonitor
    let bonjour: BonjourProbe

    private(set) var client: PTPIPClient?
    /// "ap" or "lan" for the open session: every session measurement goes in that column.
    private(set) var sessionNet: String?
    /// The target of the latest session, so an action on a dropped connection can reconnect to it.
    @ObservationIgnored private var sessionTarget: WiFiTarget?
    private(set) var deviceInfo: PTPDeviceInfo?
    private(set) var connectionState = "not connected"
    /// The card, newest first by capture date.
    private(set) var objects: [CardObject] = []
    private(set) var busy = false
    private(set) var activity = ""
    private(set) var progress: Double?
    private(set) var probing = false
    private(set) var resumeSummary: String?
    private(set) var batteryLine: String?
    private(set) var objectAddedCount = 0
    private(set) var eventCount = 0
    private(set) var bonjourAddresses: [String] = []
    private(set) var joinedGateway: String?
    private(set) var joining = false
    private(set) var qrSummary: String?
    /// Successful QR parses this launch: the guided run waits for this to change, since the same camera's code reads
    /// the same every time.
    private(set) var qrScans = 0
    /// The gateway the latest join reported, nil while joining or if it failed (joinedGateway keeps older joins').
    private(set) var lastJoinGateway: String?
    /// Whether the latest join found the phone already on that network (apply answered alreadyAssociated, so iOS
    /// showed no prompt); nil while joining or if it failed.
    private(set) var lastJoinAlreadyAssociated: Bool?
    var joinSSID = ""
    /// Never logged or persisted.
    var joinPassphrase = ""
    /// Build 9: run the Sony init sequence straight after Connect / Reconnect / Resume read when DeviceInfo lists
    /// SDIO_Connect (0x9201). In PC Remote the camera drops the session about 30 s after OpenSession without it.
    var sdioAfterConnect: Bool {
        get { sdioAfterConnectSetting }
        set {
            sdioAfterConnectSetting = newValue
            UserDefaults.standard.set(newValue, forKey: "ptpip.sdioAfterConnect")
        }
    }
    /// Build 9: GetDeviceInfo every 10 s while a session is open, idle and in the foreground (the camera drops an
    /// idle session otherwise, per Imagedge).
    var keepAlive: Bool {
        get { keepAliveSetting }
        set {
            keepAliveSetting = newValue
            UserDefaults.standard.set(newValue, forKey: "ptpip.keepAlive")
            if newValue { startKeepAlive() } else { stopKeepAlive() }
        }
    }
    /// Observed storage behind the two toggles (computed wrappers persist them).
    private var sdioAfterConnectSetting = UserDefaults.standard.object(forKey: "ptpip.sdioAfterConnect") as? Bool ?? true
    private var keepAliveSetting = UserDefaults.standard.object(forKey: "ptpip.keepAlive") as? Bool ?? true
    /// Keep-alives answered OK this session.
    private(set) var keepAlives = 0
    /// Build 9: the contents-transfer mode of the latest session, nil after a plain Connect. Reconnect and Resume read
    /// reopen that kind of session, since in PC Remote a plain one can't see the card (GetStorageIDs answers 0x2013).
    private(set) var contentsMode: SonyContentsMode?

    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var savedEventFixtures: Set<String> = []
    @ObservationIgnored private var batteryWindow: BatteryWindow?
    @ObservationIgnored private var batteryUnsupported = false
    /// Measurement prefixes ("ptpip.ap", "ptpip.lan") whose getPartialObject.supported has been recorded.
    @ObservationIgnored private var partialSupportFlagged: Set<String> = []
    /// Bumped when the partial read probe remembers a result, so the Wi-Fi tab's line about it redraws.
    private(set) var partialProbeRuns = 0
    /// The latest whole-file GetObject kept on disk (Reference hash or the partial read probe), so the probe can
    /// reuse it in the same session. Discarded with its file when a new client connects or a new copy starts.
    @ObservationIgnored private var referenceCopy: ReferenceCopy?
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    /// True while a keep-alive (or the back-from-background check) has a transaction on the socket; a camera
    /// operation waits for it before starting, so the two never overlap.
    @ObservationIgnored private var keepAliveInFlight = false
    /// Set when the app leaves the foreground with a session open; read on the way back.
    @ObservationIgnored private var backgroundSnapshot: BackgroundSnapshot?
    @ObservationIgnored private var appObservers: [NSObjectProtocol] = []
    /// True once the Sony init sequence has run to the end on the current client.
    @ObservationIgnored private var initSequenceDone = false
    /// Build 14: storage IDs the camera reported removed (StoreRemoved) and hasn't added back on this session.
    @ObservationIgnored private var removedStores: Set<UInt32> = []
    /// Build 14: StoreRemoved and StoreAdded events since launch, so the copy can tell the first file after a store
    /// change; and StoreAdded alone, which the copy's recovery waits for.
    @ObservationIgnored private var storeChanges = 0
    @ObservationIgnored private var storeAdds = 0
    @ObservationIgnored private var storeRemovedAt: Date?
    /// Build 14: the Wi-Fi copy in progress, for the StoreRemoved / StoreAdded lines.
    @ObservationIgnored private var copyWatch: CopyAllRun?
    /// Build 14: the Bluetooth link a copy's recovery used to switch the camera's Wi-Fi back on, released (notifications
    /// off, disconnected if the copy connected it) once the session is back or the copy ends.
    @ObservationIgnored private var copyBluetooth: CopyBluetoothHold?
    /// Build 14: the files a copy hadn't copied when iOS expired its continued task (the file in flight first), set by
    /// copyAllLoop on that stop, for the pause record.
    @ObservationIgnored private var copyLeft: [CardObject] = []
    /// Build 14: what the paused copy was copied under (the guided run's Creators' App answer and Bluetooth permission).
    /// Only the guided run's own Continue passes Bluetooth on; the Wi-Fi tab's Continue keeps the Creators' App answer
    /// and drops Bluetooth, and after a relaunch a continued copy recovers without Bluetooth.
    @ObservationIgnored private var pausedRecovery: CopyAllRecovery?
    /// Build 14: a copy's recovery (or Continue copy's reconnect) is running: an expiry then cuts the PTP/IP client off
    /// at once (runCopy's onExpire), so the recovery's pending calls fail and reach their stop checks.
    @ObservationIgnored private var copyRecovering = false
    /// Build 14: the copy loop ended because a recovery failed or the recovery limit was reached (the session is lost).
    @ObservationIgnored private var copySessionLost = false

    /// The session part of the partial read probe's key (PartialReadProbe): the contents-transfer mode, or "plain".
    var partialProbeSession: String { contentsMode?.rawValue ?? "plain" }

    /// What kind of session is open, for the context of measurements that depend on it.
    private var sessionKind: String {
        if let contentsMode { return "contents transfer (\(contentsMode.label))" }
        return initSequenceDone ? "OpenSession + Sony init sequence" : "OpenSession"
    }

    private struct BackgroundSnapshot {
        let at: Date
        let keepAlive: Bool
        let net: String
        let client: PTPIPClient
    }

    private struct ContentsPoll {
        /// Seconds from the start of the operation to the first non-empty handle list; nil if none came.
        var ready: Double?
        var storages = "none"
        var summary = ""
    }

    private struct BatteryWindow {
        let prefix: String
        let startPercent: Int
        let startedAt: Date
        var bytes: UInt64
    }

    private struct FoundObject {
        let handle: PTPObjectHandle
        let info: PTPObjectInfo
        let scanned: Int
        let seconds: Double
    }

    private struct ReferenceCopy {
        /// The session it was downloaded on: handles are only valid within one.
        let client: PTPIPClient
        let handle: PTPObjectHandle
        let size: UInt64
        let url: URL
        let sha256: String
    }

    /// One layout's answers in the partial read probe.
    private struct ProbeOutcome {
        let variant: PTPPartialRead.Variant
        let operation: String
        /// "OK", a response code, "no answer (…)" or "failed (…)" for the first chunk.
        var first: String
        var firstBytes: Int?
        var firstMatches = false
        /// nil while the middle chunk hasn't been asked for with this layout.
        var middle: String?
        var middleBytes: Int?
        var middleMatches: Bool?

        var works: Bool { firstMatches && middleMatches == true }

        var summary: String {
            var text = "\(variant.rawValue) (\(operation)): [0, 1 MiB) \(first)"
            if let firstBytes { text += ", \(firstBytes) bytes, \(firstMatches ? "matches" : "does NOT match")" }
            if let middle {
                text += "; middle \(middle)"
                if let middleBytes { text += ", \(middleBytes) bytes, \(middleMatches == true ? "matches" : "does NOT match")" }
            } else if firstMatches {
                text += "; middle not asked for"
            }
            return text
        }
    }

    private struct BatchResult {
        var bytes: UInt64 = 0
        var files = 0
        var failures = 0
        var seconds: Double = 0
    }

    init(log: SpikeLog, continued: ContinuedTask, lifecycle: LifecycleMonitor) {
        self.log = log
        self.continued = continued
        self.lifecycle = lifecycle
        self.ssdp = SSDPProbe(log: log)
        self.path = PathMonitor(log: log)
        self.bonjour = BonjourProbe(log: log)
        refreshResumeSummary()
        observeApp()
    }

    var isConnected: Bool { client != nil && sessionNet != nil }

    var gatewayCandidate: String? { joinedGateway ?? path.current?.firstIPv4Gateway }

    /// The resume identity's camera key: a one-way tag of the serial (CameraSerialTag), never the serial itself,
    /// because identities and `.part` paths are logged and the log is exported.
    private var cameraSerial: String {
        let serial = deviceInfo?.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return serial.isEmpty ? "unknown-serial" : CameraSerialTag.tag(serial)
    }

    // MARK: Running actions

    /// `transferLink` ("ptpip.ap" / "ptpip.lan") marks a download or resumable read, so locking the phone during it
    /// counts as locking during a transfer even before its first file finishes.
    private func runCamera(_ label: String, transferLink: String? = nil, _ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { log.warn("\(label): wait for \(activity) to finish"); return }
        guard !continued.isRunning else { log.warn("\(label): a continued task is running; stop it first"); return }
        busy = true
        activity = label
        progress = nil
        if let transferLink { lifecycle.transferStarted(link: transferLink) }
        Task { @MainActor in
            // A keep-alive may have a transaction on the socket: one at a time (the client refuses a second).
            while self.keepAliveInFlight { try? await Task.sleep(for: .milliseconds(20)) }
            do {
                try await work()
            } catch {
                await self.failed(label, error)
            }
            self.busy = false
            self.activity = ""
            self.progress = nil
            if transferLink != nil { self.lifecycle.transferEnded() }
            self.lifecycle.operationEnded()
        }
    }

    /// Runs `work` with the open session's client and its net ("ap" / "lan"). If the connection has dropped since
    /// (the camera closed it, or iOS did while the app was in the background), it reconnects first, the same way
    /// Reconnect does, so a tap on a dead connection doesn't just fail.
    private func runSession(_ label: String, transfer: Bool = false, needsListing: Bool = false,
                            _ work: @escaping @MainActor (PTPIPClient, String) async throws -> Void) {
        guard client != nil, let net = sessionNet else {
            log.warn("\(label): not connected; tap Connect first")
            return
        }
        runCamera(label, transferLink: transfer ? "ptpip.\(net)" : nil) {
            guard var c = self.client else { throw WiFiLabError.message("not connected; tap Connect first") }
            if let failure = await c.linkFailure {
                guard let t = self.sessionTarget else { throw failure }
                self.log.warn("\(label): the connection had dropped (\(failure)); reconnecting first")
                // A new session starts with an empty listing (and may number the objects differently), so an action
                // that works on the listing lists the card again first.
                let hadListing = !self.objects.isEmpty
                c = try await self.reopen(t)
                if needsListing && hadListing {
                    self.log.note("\(label): listing the card again on the new session")
                    try await self.listObjects(c, net: t.net)
                }
            }
            guard let current = self.sessionNet else { throw WiFiLabError.message("not connected; tap Connect first") }
            try await work(c, current)
        }
    }

    private func failed(_ label: String, _ error: Error) async {
        log.error("\(label) failed: \(error)")
        if let c = client, let failure = await c.linkFailure {
            connectionState = "connection lost (\(failure)); tap Reconnect"
        }
    }

    private func runProbe(_ label: String, _ work: @escaping @MainActor () async -> Void) {
        guard !probing else { log.warn("\(label): another probe is running"); return }
        probing = true
        Task { @MainActor in
            await work()
            self.probing = false
        }
    }

    // MARK: Day 6 · Probe

    func probePort(_ t: WiFiTarget) {
        runProbe("TCP 15740") {
            self.log.note("TCP connect test to \(t.host):15740 on \(t.netLabel)…")
            do {
                let seconds = try await PTPIPClient.probePort(host: t.host, log: PTPIPClient.logger(self.log))
                self.log.measure("\(t.prefix).port15740", seconds, "s", context: "TCP connect to \(t.host):15740 succeeded (\(t.netLabel))")
            } catch {
                self.log.warn("TCP connect to \(t.host):15740 on \(t.netLabel) failed: \(error)")
            }
        }
    }

    func browseBonjour(_ t: WiFiTarget) {
        runProbe("Bonjour") {
            self.bonjourAddresses = await self.bonjour.browse(measurement: "\(t.prefix).discovery.bonjour")
        }
    }

    func ssdpUnicast(_ t: WiFiTarget) {
        runProbe("SSDP unicast") {
            await self.ssdp.searchUnicast(host: t.host, measurement: "\(t.prefix).discovery.ssdp")
        }
    }

    func ssdpMulticast(_ t: WiFiTarget) {
        runProbe("SSDP multicast") {
            await self.ssdp.searchMulticast(measurement: "\(t.prefix).discovery.ssdp")
        }
    }

    func checkInternet() {
        Task { await path.checkInternet() }
    }

    // MARK: Day 7 · Handshake

    func connect(_ t: WiFiTarget) {
        runCamera("Connect") { try await self.open(t, closingPrevious: true, sdio: self.sdioAfterConnect) }
    }

    func reconnect(_ t: WiFiTarget) {
        runCamera("Reconnect") {
            self.log.note("Reconnect with the same GUID \(t.guid.uuidString): note what the camera shows (no prompt / prompt once / prompt every time)")
            try await self.reopen(t)
        }
    }

    /// Reconnect and Resume read: the same kind of session as the latest one, a plain one (with the init sequence when
    /// `sdioAfterConnect` is on) or Sony's contents transfer, followed by a short wait for the card to list again.
    /// `shouldStop` (build 14, a copy's recovery): the wait for the listing ends (throwing) once it is true.
    @discardableResult
    private func reopen(_ t: WiFiTarget, shouldStop: ContinuedTask.ShouldStop = { false }) async throws -> PTPIPClient {
        guard let mode = contentsMode else {
            return try await open(t, closingPrevious: false, sdio: sdioAfterConnect).0
        }
        log.note("The latest session was Sony's contents transfer (\(mode.label)), so the same kind of session is reopened (Connect opens a plain one)")
        let (c, _) = try await openContents(t, mode: mode, closingPrevious: false)
        let clock = ContinuousClock()
        let poll = try await pollForHandles(c, mode: mode, clock: clock, started: clock.now, limit: 30, shouldStop: shouldStop)
        if let ready = poll.ready {
            log.note(String(format: "Contents transfer (%@) reopened: a handle listed after %.1f s", mode.label, ready))
        } else {
            log.warn("Contents transfer (\(mode.label)) reopened, but no storage listed a handle within 30 s (\(poll.summary))")
        }
        return c
    }

    func disconnect() {
        runCamera("Disconnect") {
            await self.closeClient(closingSession: true)
            self.log.note("PTP/IP: disconnected")
        }
    }

    private func closeClient(closingSession: Bool) async {
        stopKeepAlive()
        eventsTask?.cancel()
        eventsTask = nil
        if let c = client { await c.disconnect(closingSession: closingSession) }
        client = nil
        sessionNet = nil
        connectionState = "not connected"
    }

    /// Handshake + OpenSession + GetDeviceInfo, then, with `sdio` on and SDIO_Connect (0x9201) in DeviceInfo, the
    /// Sony init sequence. Used by Connect, Reconnect and Resume read.
    @discardableResult
    private func open(_ t: WiFiTarget, closingPrevious: Bool, sdio: Bool = false) async throws -> (PTPIPClient, PTPDeviceInfo) {
        contentsMode = nil
        do {
            let c = try await connectFresh(t, closingPrevious: closingPrevious)
            let alreadyOpen = try await c.openSession()
            log.note(alreadyOpen ? "OpenSession: SessionAlreadyOpen (treated as success)" : "OpenSession: OK")
            var info = try await sessionDeviceInfo(c, t)
            if sdio {
                if info.supports(.sonySDIOConnect) {
                    log.note("SDIO straight after Connect: DeviceInfo lists SDIO_Connect (0x9201), so the Sony init sequence runs now (a PC Remote camera drops the session about 30 s after OpenSession without it)")
                    try await sonyInitSequence(c)
                    info = deviceInfo ?? info
                } else {
                    log.note("SDIO straight after Connect: DeviceInfo doesn't list SDIO_Connect (0x9201); init sequence not sent")
                }
            }
            startKeepAlive()
            return (c, info)
        } catch {
            await closeClient(closingSession: false)
            connectionState = "not connected (last attempt failed)"
            throw error
        }
    }

    /// Closes any previous client (with CloseSession when `closingPrevious`), resets the per-session state and makes
    /// a new client the lab's. Shared by `open` and Contents transfer.
    private func newClient(_ t: WiFiTarget, closingPrevious: Bool) async throws -> PTPIPClient {
        if client != nil { await closeClient(closingSession: closingPrevious) }
        guard !t.host.isEmpty else { throw WiFiLabError.message("enter the camera IP first") }
        // Its handle belongs to the old session.
        discardReferenceCopy()
        objects = []
        objectAddedCount = 0
        eventCount = 0
        batteryWindow = nil
        batteryLine = nil
        keepAlives = 0
        initSequenceDone = false
        // A new session lists its storages afresh.
        removedStores = []
        // Per session: BatteryLevel support depends on the camera mode, and day 6–8 switch modes between connects.
        batteryUnsupported = false
        let c = PTPIPClient(host: t.host, guid: t.guid, log: PTPIPClient.logger(log))
        client = c
        sessionNet = t.net
        sessionTarget = t
        connectionState = "connecting to \(t.host) (\(t.netLabel))…"
        listen(to: c, prefix: t.prefix)
        log.note("PTP/IP: connecting to \(t.host):15740 on \(t.netLabel) as \"\(c.friendlyName)\", GUID \(t.guid.uuidString)")
        return c
    }

    /// `newClient`, then the handshake. When an earlier client was closed first, it waits 500 ms for the camera to
    /// release the old connection and retries a failed handshake once, after 1 s, on a fresh client: Imagedge found
    /// the camera may briefly refuse a new connection straight after the old session closes (`unverified` on the
    /// α7C II). The caller closes the client if this throws.
    private func connectFresh(_ t: WiFiTarget, closingPrevious: Bool) async throws -> PTPIPClient {
        let hadPrevious = client != nil
        var c = try await newClient(t, closingPrevious: closingPrevious)
        guard hadPrevious else {
            try await handshake(c, t)
            return c
        }
        try await Task.sleep(for: .milliseconds(500))
        do {
            try await handshake(c, t)
        } catch {
            log.warn("PTP/IP: handshake straight after closing the previous connection failed: \(error); retrying once in 1 s on a fresh connection")
            await closeClient(closingSession: false)
            try await Task.sleep(for: .seconds(1))
            c = try await newClient(t, closingPrevious: false)
            try await handshake(c, t)
            log.note("PTP/IP: handshake retry OK")
        }
        return c
    }

    /// The two-channel handshake, measured. The responder GUID ends in the camera's hardware ID, so the log shows
    /// its first four groups and a keyed tag of the whole (stable per install, so reconnects can be compared).
    private func handshake(_ c: PTPIPClient, _ t: WiFiTarget) async throws {
        let hs = try await c.connect()
        log.measure("\(t.prefix).handshake", hs.total, "s", context: hs.breakdown)
        let guidBytes = withUnsafeBytes(of: hs.responderGUID.uuid) { Data($0) }
        let guidText = "\(hs.responderGUID.uuidString.prefix(24))… (hardware ID redacted, \(CameraSerialTag.tag(bytes: guidBytes)))"
        log.note("Init_Command_Ack: responder \"\(hs.responderName)\", GUID \(guidText), connection #\(hs.connectionNumber), protocol 0x\(String(hs.protocolVersion, radix: 16)); Init_Event_Ack received")
    }

    /// GetDeviceInfo for a new session: logged, saved as a fixture (serial zeroed), and the lab marked connected.
    private func sessionDeviceInfo(_ c: PTPIPClient, _ t: WiFiTarget) async throws -> PTPDeviceInfo {
        let (info, raw) = try await c.getDeviceInfo()
        deviceInfo = info
        logDeviceInfo(info, raw: raw)
        FixtureStore.saveDeviceInfo(raw, link: .ptpip, log: log)
        FixtureStore.recordFirmware(model: info.model, version: info.deviceVersion, link: .ptpip, log: log)
        connectionState = "connected · \(info.model) \(info.deviceVersion) · \(t.netLabel)"
        return info
    }

    private func logDeviceInfo(_ di: PTPDeviceInfo, raw: Data) {
        func yn(_ b: Bool) -> String { b ? "yes" : "no" }
        let vendor = di.vendorExtension.map { "\($0)" } ?? String(format: "0x%08X", di.vendorExtensionID)
        log.note("DeviceInfo (\(raw.count) bytes): \(di.manufacturer) \(di.model), firmware \(di.deviceVersion), \(di.serialNumber.isEmpty ? "serial (empty)" : "serial present (\(di.serialNumber.count) characters, redacted)"); PTP \(di.standardVersion), vendor extension \(vendor) v\(di.vendorExtensionVersion) \"\(di.vendorExtensionDescription)\", functional mode \(di.functionalMode)")
        let ops = di.operationsSupported.map { code -> String in
            String(format: "0x%04X ", code) + PTPOperationCode(rawValue: code).description
        }
        log.note("operations (\(ops.count)): \(ops.joined(separator: ", "))")
        let events = di.eventsSupported.map { code -> String in
            String(format: "0x%04X ", code) + PTPEventCode(rawValue: code).description
        }
        log.note("events (\(events.count)): \(events.joined(separator: ", "))")
        let formats = di.imageFormats.map { PTPObjectFormat(rawValue: $0).description }
        log.note("device properties: \(di.devicePropertiesSupported.count); image formats: \(formats.joined(separator: ", "))")
        log.note("supports GetPartialObject 0x101B \(yn(di.supports(.getPartialObject))), GetPartialObject64 0x95C1 \(yn(di.supports(.getPartialObject64))), GetThumb \(yn(di.supports(.getThumb))), Sony SDIO_Connect \(yn(di.supports(.sonySDIOConnect))), SDIO_GetExtDeviceInfo \(yn(di.supports(.sonySDIOGetExtDeviceInfo))), SDIO_GetPartialLargeObject 0x9211 \(yn(di.supports(.sonySDIOGetPartialLargeObject))), 0x9219 \(yn(di.supports(.sonySDIO0x9219))), SDIO_SetContentsTransferMode \(yn(di.supports(.sonySDIOSetContentsTransferMode))); emits ObjectAdded \(yn(di.emits(.objectAdded))), Sony ObjectAdded \(yn(di.emits(.sonyObjectAdded)))")
    }

    /// Logs every event; flags ObjectAdded and saves the first Event packet of each kind as a fixture.
    private func listen(to c: PTPIPClient, prefix: String) {
        eventsTask?.cancel()
        let stream = c.events
        eventsTask = Task { @MainActor [weak self] in
            for await item in stream {
                guard let self else { return }
                self.handle(item, prefix: prefix)
            }
        }
    }

    private func handle(_ item: PTPIPClient.IncomingEvent, prefix: String) {
        let e = item.event
        eventCount += 1
        let params = e.parameters.map { String(format: "0x%08X", $0) }.joined(separator: ", ")
        log.note("PTP/IP event on the \(item.channel) channel: \(e.code) (\(String(format: "0x%04X", e.code.rawValue))) tx \(e.transactionID) params [\(params)]")
        if e.code == .storeRemoved || e.code == .storeAdded { storeEvent(e) }
        if e.code.signalsNewObject {
            objectAddedCount += 1
            if objectAddedCount == 1 {
                log.flag("\(prefix).event.objectAdded", true, context: "\(e.code) on the \(item.channel) channel, params [\(params)]; session: \(sessionKind)")
            }
            if !savedEventFixtures.contains("objectadded") {
                savedEventFixtures.insert("objectadded")
                FixtureStore.save(item.packet, link: .ptpip, name: "event-objectadded.bin", log: log)
            }
        } else {
            let name = String(format: "event-%04x.bin", e.code.rawValue)
            if !savedEventFixtures.contains(name) {
                savedEventFixtures.insert(name)
                FixtureStore.save(item.packet, link: .ptpip, name: name, log: log)
            }
        }
    }

    /// Build 14: StoreRemoved / StoreAdded (parameter 1 the storage ID), kept for the Wi-Fi copy's failure classification
    /// and recovery, with one clear line each while a copy runs. On 3 Nov the camera sent StoreRemoved for 0x00010001
    /// 28 s into a copy, then answered StoreNotAvailable and InvalidObjectHandle, then dropped its Wi-Fi.
    private func storeEvent(_ e: PTPIP.Event) {
        let id = e.parameters.first ?? 0
        let idText = String(format: "0x%08X", id)
        storeChanges += 1
        if e.code == .storeRemoved {
            removedStores.insert(id)
            storeRemovedAt = Date()
            if let run = copyWatch {
                log.warn("Copy all RAW: the camera removed its card storage (StoreRemoved, storage \(idText)) during the copy, after \(run.copied) files [\(lifecycle.stateDescription)]")
            }
        } else {
            storeAdds += 1
            // Added back under another ID: take it as the card coming back.
            if removedStores.remove(id) == nil { removedStores.removeAll() }
            if let run = copyWatch {
                // storeRemovedAt is cleared when the copy starts and once used here, so it is a StoreRemoved of this copy.
                if let removedAt = storeRemovedAt {
                    storeRemovedAt = nil
                    log.note(String(format: "Copy all RAW: the camera added its card storage back (StoreAdded, storage %@) %.1f s after it was removed, with %ld files copied [%@]",
                                    idText, Date().timeIntervalSince(removedAt), run.copied, lifecycle.stateDescription))
                } else {
                    // The camera announces its card storage this way whenever a whole-card session opens (a recovery's reopen).
                    log.note("Copy all RAW: StoreAdded (storage \(idText)) on session open; the card wasn't reported removed during this copy (\(run.copied) files copied) [\(lifecycle.stateDescription)]")
                }
            }
        }
    }

    func sonySDIO() {
        runSession("Sony SDIO init sequence") { c, _ in
            try await self.sonyInitSequence(c)
        }
    }

    /// Sony's private init sequence for PC Remote modes, in Imagedge's order (alpha-fairy's init_table; Imagedge
    /// field-tested it on a ZV-E10, `unverified` on the α7C II): GetDeviceInfo, GetStorageIDs, SDIO_Connect 1 and 2,
    /// SDIO_GetExtDeviceInfo, SDIO_Connect 3, SDIO_GetExtDeviceInfo again, then GetDeviceInfo to compare with the
    /// first. On 2 Nov, without it, the camera dropped both connections about 30 s after OpenSession. Every step
    /// logs its response code; a non-OK response is logged and the sequence goes on; a link failure throws.
    private func sonyInitSequence(_ c: PTPIPClient) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        var failures: [String] = []
        log.note("Sony init sequence (Imagedge's order; unverified on the α7C II): GetDeviceInfo, GetStorageIDs, SDIO_Connect 1, 2, SDIO_GetExtDeviceInfo(0x12C), SDIO_Connect 3, SDIO_GetExtDeviceInfo(0x12C), GetDeviceInfo")
        let first: (info: PTPDeviceInfo, raw: Data)? = try await initStep(c, "GetDeviceInfo", failures: &failures, {
            try await c.getDeviceInfo()
        }, summary: { "\($0.raw.count) bytes; \(WirelessLab.counts($0.info))" })
        let before = first?.info ?? deviceInfo
        try await initStep(c, "GetStorageIDs", failures: &failures, {
            try await c.getStorageIDs().ids
        }, summary: { "storage IDs \(WirelessLab.storageList($0))" })
        try await initStep(c, "SDIO_Connect(1)", failures: &failures, {
            try await c.sonySDIOConnect(phase: 1)
        }, summary: { WirelessLab.dataSummary($0) })
        try await initStep(c, "SDIO_Connect(2)", failures: &failures, {
            try await c.sonySDIOConnect(phase: 2)
        }, summary: { WirelessLab.dataSummary($0) })
        var ext: Data? = try await initStep(c, "SDIO_GetExtDeviceInfo(0x12C)", failures: &failures, {
            try await c.sonySDIOGetExtDeviceInfo(version: 0x12C)
        }, summary: { WirelessLab.dataSummary($0) })
        if ext == nil {
            ext = try await initStep(c, "SDIO_GetExtDeviceInfo(0xC8)", failures: &failures, {
                try await c.sonySDIOGetExtDeviceInfo(version: 0xC8)
            }, summary: { WirelessLab.dataSummary($0) })
        }
        if let ext {
            FixtureStore.save(ext, link: .ptpip, name: "sdio-extdeviceinfo.bin", log: log)
            logExtDeviceInfo(ext)
        }
        try await initStep(c, "SDIO_Connect(3)", failures: &failures, {
            try await c.sonySDIOConnect(phase: 3)
        }, summary: { WirelessLab.dataSummary($0) })
        let ext2: Data? = try await initStep(c, "SDIO_GetExtDeviceInfo(0x12C) again", failures: &failures, {
            try await c.sonySDIOGetExtDeviceInfo(version: 0x12C)
        }, summary: { WirelessLab.dataSummary($0) })
        if let ext2 {
            if let ext, ext == ext2 {
                log.note("SDIO_GetExtDeviceInfo after SDIO_Connect(3): the same \(ext2.count) bytes as before it")
            } else {
                log.note("SDIO_GetExtDeviceInfo after SDIO_Connect(3) differs from the first (\(ext2.count) bytes):")
                logExtDeviceInfo(ext2)
                if ext == nil { FixtureStore.save(ext2, link: .ptpip, name: "sdio-extdeviceinfo.bin", log: log) }
            }
        }
        let last: (info: PTPDeviceInfo, raw: Data)? = try await initStep(c, "GetDeviceInfo (after)", failures: &failures, {
            try await c.getDeviceInfo()
        }, summary: { "\($0.raw.count) bytes; \(WirelessLab.counts($0.info))" })
        if let after = last?.info { deviceInfo = after }

        var compare = "DeviceInfo before: \(before.map { WirelessLab.counts($0) } ?? "none"); after: \(last.map { WirelessLab.counts($0.info) } ?? "none")"
        if let before, let after = last?.info {
            let added = Set(after.operationsSupported).subtracting(before.operationsSupported).sorted()
            let removed = Set(before.operationsSupported).subtracting(after.operationsSupported).sorted()
            if !added.isEmpty { compare += "; operations added: " + added.map { String(format: "0x%04X", $0) }.joined(separator: " ") }
            if !removed.isEmpty { compare += "; operations gone: " + removed.map { String(format: "0x%04X", $0) }.joined(separator: " ") }
        }
        let outcome = failures.isEmpty ? "every step OK" : "\(failures.count) step(s) not OK (\(failures.joined(separator: ", ")))"
        log.note(String(format: "Sony init sequence done in %.2f s: ", (clock.now - started).inSeconds) + "\(outcome). \(compare)")
        if client === c { initSequenceDone = true }
    }

    /// One step of the Sony init sequence. OK: logs `summary` and returns the value. A non-OK response (or a dataset
    /// that didn't decode, the link still healthy) is logged, added to `failures`, and returns nil. A link failure
    /// throws.
    @discardableResult
    private func initStep<T>(_ c: PTPIPClient, _ label: String, failures: inout [String],
                             _ body: () async throws -> T, summary: (T) -> String) async throws -> T? {
        do {
            let value = try await body()
            log.note("Sony init · \(label): OK, \(summary(value))")
            return value
        } catch PTPIPClient.ClientError.response(_, let code) {
            failures.append("\(label) \(WirelessLab.codeText(code))")
            log.warn("Sony init · \(label): \(WirelessLab.codeText(code)); continuing")
            return nil
        } catch {
            let linkGone = (error as? PTPIPClient.ClientError)?.isLinkFailure ?? false
            if !linkGone, await c.linkFailure == nil {
                failures.append("\(label) failed")
                log.warn("Sony init · \(label): \(error); continuing")
                return nil
            }
            log.error("Sony init · \(label): \(error); sequence stopped")
            throw error
        }
    }

    nonisolated static func codeText(_ code: PTPResponseCode) -> String {
        "\(code) (" + String(format: "0x%04X", code.rawValue) + ")"
    }

    nonisolated static func counts(_ di: PTPDeviceInfo) -> String {
        String(format: "%ld operations, %ld events, %ld properties, functional mode 0x%04X",
               di.operationsSupported.count, di.eventsSupported.count, di.devicePropertiesSupported.count, di.functionalMode)
    }

    nonisolated static func storageList(_ ids: [PTPStorageID]) -> String {
        ids.isEmpty ? "none" : ids.map { String(format: "0x%08X", $0.rawValue) }.joined(separator: ", ")
    }

    nonisolated static func dataSummary(_ data: Data) -> String {
        "\(data.count) bytes \(data.hexDump())"
    }

    private func logExtDeviceInfo(_ data: Data) {
        // libgphoto2 reads: u16 version, then two u16 arrays of vendor codes.
        var r = PTPReader(data)
        guard let version = try? r.u16(), let first = try? r.u16Array() else {
            log.note("SDIO_GetExtDeviceInfo: \(data.count) bytes, layout not as libgphoto2 describes: \(data.hexDump())")
            return
        }
        let second = (try? r.u16Array()) ?? []
        let firstText = first.prefix(60).map { String(format: "%04X", $0) }.joined(separator: " ")
        log.note("SDIO_GetExtDeviceInfo: version 0x\(String(version, radix: 16)), \(first.count) codes [\(firstText)\(first.count > 60 ? " …" : "")], then \(second.count) codes")
    }

    // MARK: Build 9 · Sony contents transfer

    /// A new session the way Imagedge opens one for `mode` (see SonyContentsMode), then polls until a storage lists
    /// at least one handle. Records `ptpip.<net>.contentsTransfer.<mode>.ready` (s from the tap to the first
    /// non-empty handle list) and the flag `….lists`. Leaves the session open for List card and the downloads.
    func connectContentsTransfer(_ t: WiFiTarget, mode: SonyContentsMode) {
        runCamera("Contents transfer: \(mode.label)") {
            let clock = ContinuousClock()
            let started = clock.now
            self.log.note("Contents transfer (\(mode.label); Imagedge's sequence, field-tested on a ZV-E10, unverified on the α7C II): " +
                          (mode == .wholeCard
                            ? "SDIO_OpenSession 0x9210 [1, 1] in place of OpenSession, the init sequence, 0x9212 [2,0,0], 200 ms, [2,1,0], 1500 ms, then GetStorageIDs and GetObjectHandles until the card lists (up to 120 s)"
                            : "OpenSession, the init sequence, 0x9212 [1,0,0], then GetStorageIDs and GetObjectHandles until the photos sent from the camera list (up to \(Int(mode.pollLimit)) s)"))
            let (c, codes) = try await self.openContents(t, mode: mode, closingPrevious: true)
            try await self.pollAndRecord(c, mode: mode, prefix: t.prefix, codes: codes, clock: clock, started: started)
        }
    }

    /// Build 9: Sony's selected-set mode on the session already open, as Imagedge does it in one session: the init
    /// sequence if this session hasn't had it (and DeviceInfo lists SDIO_Connect), 0x9212 [1,0,0], then a poll for
    /// the photos the camera sends. Records the same measurements as Contents transfer: photos sent from the camera.
    func selectedSetInSession() {
        runSession("Selected set in this session") { c, net in
            let mode = SonyContentsMode.selectedOnCamera
            let clock = ContinuousClock()
            let started = clock.now
            self.log.note("Selected set in this session (Imagedge's order, unverified on the α7C II): the init sequence if not yet run, 0x9212 [1,0,0], then GetStorageIDs and GetObjectHandles until the photos sent from the camera list (up to \(Int(mode.pollLimit)) s)")
            var codes: [String] = []
            if self.initSequenceDone {
                codes.append("init sequence already run")
            } else if self.deviceInfo?.supports(.sonySDIOConnect) == true {
                try await self.sonyInitSequence(c)
                codes.append("init sequence run")
            } else {
                codes.append("init sequence not sent (no 0x9201)")
                self.log.note("Selected set in this session: DeviceInfo doesn't list SDIO_Connect (0x9201); init sequence not sent")
            }
            codes += try await self.setTransferMode(c, mode: mode)
            self.contentsMode = mode
            if !self.connectionState.contains("contents transfer") {
                self.connectionState += " · contents transfer (\(mode.label))"
            }
            try await self.pollAndRecord(c, mode: mode, prefix: "ptpip.\(net)", codes: codes, clock: clock, started: started)
        }
    }

    /// The session set-up for `mode`, as Imagedge opens one: SDIO_OpenSession 0x9210 [1, 1] (falling back to
    /// OpenSession) or OpenSession, GetDeviceInfo, the init sequence and the 0x9212 steps. Marks the lab connected in
    /// that mode and starts the keep-alive. Returns the client and each step's result for the measurement context.
    private func openContents(_ t: WiFiTarget, mode: SonyContentsMode, closingPrevious: Bool) async throws -> (PTPIPClient, [String]) {
        var codes: [String] = []
        do {
            let c = try await connectFresh(t, closingPrevious: closingPrevious)
            switch mode {
            case .wholeCard:
                do {
                    try await c.sonySDIOOpenSession(functionMode: 1)
                    codes.append("0x9210 OK")
                    log.note("SDIO_OpenSession (0x9210) [1, 1], ContentsTransfer: OK")
                } catch PTPIPClient.ClientError.response(_, let code) {
                    codes.append("0x9210 \(WirelessLab.codeText(code))")
                    log.warn("SDIO_OpenSession (0x9210) [1, 1]: \(WirelessLab.codeText(code)); falling back to the standard OpenSession (0x1002)")
                    let alreadyOpen = try await c.openSession()
                    codes.append("fallback OpenSession \(alreadyOpen ? "SessionAlreadyOpen" : "OK")")
                    log.note(alreadyOpen ? "fallback OpenSession: SessionAlreadyOpen (treated as success)" : "fallback OpenSession: OK")
                }
            case .selectedOnCamera:
                let alreadyOpen = try await c.openSession()
                codes.append("OpenSession \(alreadyOpen ? "SessionAlreadyOpen" : "OK")")
                log.note(alreadyOpen ? "OpenSession: SessionAlreadyOpen (treated as success)" : "OpenSession: OK")
            }
            let info = try await sessionDeviceInfo(c, t)
            try await sonyInitSequence(c)
            codes += try await setTransferMode(c, mode: mode)
            contentsMode = mode
            connectionState = "connected · \(info.model) \(info.deviceVersion) · \(t.netLabel) · contents transfer (\(mode.label))"
            // Runs from here on, but skips while an operation is busy (polling included).
            startKeepAlive()
            return (c, codes)
        } catch {
            await closeClient(closingSession: false)
            connectionState = "not connected (last attempt failed)"
            throw error
        }
    }

    /// SDIO_SetContentsTransferMode (0x9212) for `mode`, with the pause Imagedge makes after each call. A non-OK
    /// response is logged and the steps go on; a link failure throws. Returns each call's result.
    private func setTransferMode(_ c: PTPIPClient, mode: SonyContentsMode) async throws -> [String] {
        var codes: [String] = []
        for step in mode.transferModeSteps {
            let label = "0x9212 [\(step.p1),\(step.p2),\(step.p3)]"
            do {
                try await c.sonySetContentsTransferMode(step.p1, step.p2, step.p3)
                codes.append("\(label) OK")
                log.note("SDIO_SetContentsTransferMode \(label): OK")
            } catch PTPIPClient.ClientError.response(_, let code) {
                codes.append("\(label) \(WirelessLab.codeText(code))")
                log.warn("SDIO_SetContentsTransferMode \(label): \(WirelessLab.codeText(code)); continuing")
            }
            if step.pauseMilliseconds > 0 { try await Task.sleep(for: .milliseconds(step.pauseMilliseconds)) }
        }
        return codes
    }

    /// Polls for handles (`pollForHandles`) and records `<prefix>.contentsTransfer.<mode>.ready` and `….lists`.
    private func pollAndRecord(_ c: PTPIPClient, mode: SonyContentsMode, prefix: String, codes: [String],
                               clock: ContinuousClock, started: ContinuousClock.Instant) async throws {
        let name = "\(prefix).contentsTransfer.\(mode.rawValue)"
        let poll: ContentsPoll
        do {
            poll = try await pollForHandles(c, mode: mode, clock: clock, started: started)
        } catch {
            if let failure = await c.linkFailure {
                log.flag("\(name).lists", false,
                         context: String(format: "link lost %.0f s in: %@; %@", (clock.now - started).inSeconds, "\(failure)", codes.joined(separator: ", ")))
            }
            throw error
        }
        let context = "storage IDs \(poll.storages); \(codes.joined(separator: ", ")); \(poll.summary)"
        if let ready = poll.ready {
            log.measure("\(name).ready", ready, "s", context: context)
        } else {
            log.warn("Contents transfer (\(mode.label)): no storage listed a handle within \(Int(mode.pollLimit)) s; the session stays open")
        }
        log.flag("\(name).lists", poll.ready != nil, context: context)
    }

    /// GetStorageIDs, then GetObjectHandles(storage, all formats, parent 0) for every storage with a logical store,
    /// until one lists a handle: after 2, 3 and 5 s, then every 5 s, up to `limit` s (`mode.pollLimit` by default).
    /// The first replies are often empty while the camera indexes the card (Imagedge). Non-OK responses are logged
    /// per attempt; a link failure throws. Build 14: `shouldStop` (a copy's recovery) is checked before each poll and
    /// each wait, and throws once it is true.
    private func pollForHandles(_ c: PTPIPClient, mode: SonyContentsMode, clock: ContinuousClock,
                                started: ContinuousClock.Instant, limit: Double? = nil,
                                shouldStop: ContinuedTask.ShouldStop = { false }) async throws -> ContentsPoll {
        let limit = limit ?? mode.pollLimit
        var result = ContentsPoll()
        let pollStarted = clock.now
        let waits: [Double] = [2, 3, 5]
        var attempt = 0
        while true {
            if shouldStop() { throw WiFiLabError.message("the copy stopped (Stop, or iOS ended the continued task) during the poll for handles") }
            attempt += 1
            var parts: [String] = []
            var most = 0
            do {
                let (ids, _) = try await c.getStorageIDs()
                result.storages = WirelessLab.storageList(ids)
                if ids.isEmpty { parts.append("no storage IDs") }
                for id in ids {
                    let idText = String(format: "0x%08X", id.rawValue)
                    guard id.hasLogicalStore else { parts.append("\(idText) no logical store"); continue }
                    do {
                        let (handles, _) = try await c.getObjectHandles(storage: id)
                        parts.append("\(idText) \(handles.count) handle(s)")
                        most = max(most, handles.count)
                    } catch PTPIPClient.ClientError.response(_, let code) {
                        parts.append("\(idText) GetObjectHandles \(WirelessLab.codeText(code))")
                    }
                }
            } catch PTPIPClient.ClientError.response(_, let code) {
                parts.append("GetStorageIDs \(WirelessLab.codeText(code))")
            }
            let elapsed = (clock.now - started).inSeconds
            log.note(String(format: "contents transfer poll %ld at %.1f s: ", attempt, elapsed) + parts.joined(separator: "; "))
            result.summary = "\(attempt) poll(s); last: \(parts.joined(separator: "; "))"
            if most > 0 {
                result.ready = elapsed
                return result
            }
            let wait = attempt <= waits.count ? waits[attempt - 1] : 5
            let polled = (clock.now - pollStarted).inSeconds
            if polled + wait > limit { return result }
            activity = String(format: "Contents transfer: waiting for a listing (%.0f of %.0f s)", polled, limit)
            progress = min(polled / limit, 1)
            if shouldStop() { throw WiFiLabError.message("the copy stopped (Stop, or iOS ended the continued task) during the poll for handles") }
            try await Task.sleep(for: .seconds(wait))
        }
    }

    // MARK: Build 9 · Keep-alive and background

    /// (Re)starts the keep-alive loop for the current client: GetDeviceInfo every 10 s while the session is open,
    /// nothing else is running and the app is in the foreground. Ends when the client changes or the link fails.
    private func startKeepAlive() {
        stopKeepAlive()
        guard keepAlive, let c = client, sessionNet != nil else { return }
        keepAliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let lab = self, lab.keepAlive, lab.client === c else { return }
                // Checked right before sending, with no suspension in between: never two transactions at once.
                guard !lab.busy, !lab.probing, !lab.continued.isRunning, !lab.keepAliveInFlight,
                      lab.lifecycle.isInForeground else { continue }
                if !(await lab.sendKeepAlive(c)) { return }
            }
        }
    }

    private func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    /// One keep-alive. Logs the first OK and any failure, not every success. Returns false once the link is gone.
    private func sendKeepAlive(_ c: PTPIPClient) async -> Bool {
        keepAliveInFlight = true
        defer { keepAliveInFlight = false }
        do {
            // The default 30 s timeout: a timeout poisons the channel, and the camera may be slow to answer while it
            // rebuilds its content set or writes to the card (Imagedge).
            _ = try await c.getDeviceInfo()
            keepAlives += 1
            if keepAlives == 1 {
                log.note("keep-alive: first GetDeviceInfo after 10 s idle answered OK (later ones are counted on the Wi-Fi tab, not logged)")
            }
            return true
        } catch PTPIPClient.ClientError.busy(_, _) {
            return true
        } catch {
            log.warn("keep-alive GetDeviceInfo failed after \(keepAlives) OK: \(error)")
            if let failure = await c.linkFailure {
                if client === c { connectionState = "connection lost (\(failure)); tap Reconnect" }
                return false
            }
            return true
        }
    }

    private func observeApp() {
        let nc = NotificationCenter.default
        appObservers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appEnteredBackground() }
        })
        appObservers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appEnteringForeground() }
        })
    }

    private func appEnteredBackground() {
        guard let c = client, let net = sessionNet else {
            backgroundSnapshot = nil
            return
        }
        backgroundSnapshot = BackgroundSnapshot(at: Date(), keepAlive: keepAlive, net: net, client: c)
        log.note("Wi-Fi session open as the app leaves the foreground (keep-alive \(keepAlive ? "on, paused while away" : "off"))")
    }

    private func appEnteringForeground() {
        guard let snapshot = backgroundSnapshot else { return }
        backgroundSnapshot = nil
        let away = Date().timeIntervalSince(snapshot.at)
        Task { @MainActor in await self.checkSessionAfterBackground(snapshot, away: away) }
    }

    /// Back in the foreground with a session that was open: is it still usable? Records the flag
    /// `ptpip.<net>.session.survivesBackground`. Doesn't reconnect.
    private func checkSessionAfterBackground(_ snapshot: BackgroundSnapshot, away: Double) async {
        let name = "ptpip.\(snapshot.net).session.survivesBackground"
        let context = String(format: "away %.0f s; keep-alive %@", away, snapshot.keepAlive ? "on" : "off")
        let c = snapshot.client
        guard client === c else {
            log.note("back in the foreground: the session was replaced while away; \(name) not recorded")
            return
        }
        if let failure = await c.linkFailure {
            log.flag(name, false, context: "\(context); \(failure)")
            if client === c { connectionState = "connection lost (\(failure)); tap Reconnect" }
            return
        }
        if !(await c.isConnected) {
            log.flag(name, false, context: "\(context); not connected")
            return
        }
        // Checked right before sending, with no suspension in between.
        // The link state alone proves nothing here: a dead connection still looks healthy until a receive fails, and
        // its timer doesn't run while the phone sleeps. Without a transaction of our own, no answer is recorded.
        if busy || continued.isRunning || keepAliveInFlight {
            log.note("back in the foreground: \(name) not recorded (\(context)); an operation was running, so no GetDeviceInfo was sent; see that operation's outcome and lifecycle.progressAfterBackground")
            return
        }
        keepAliveInFlight = true
        defer { keepAliveInFlight = false }
        do {
            _ = try await c.getDeviceInfo(idleTimeout: 10)
            log.flag(name, true, context: "\(context); GetDeviceInfo OK on return")
        } catch {
            log.flag(name, false, context: "\(context); \(error)")
            if let failure = await c.linkFailure, client === c {
                connectionState = "connection lost (\(failure)); tap Reconnect"
            }
        }
    }

    // MARK: Day 8 · Enumerate and download

    func listCard() {
        runSession("List card") { c, net in try await self.listObjects(c, net: net) }
    }

    /// List card's work: every storage's handles and ObjectInfo, into `objects`. Also used to list again after an
    /// action reconnected a dropped session (a new session may number the objects differently). `record` false (build 14,
    /// the copy's recovery listing the card again): no enumerate/objects measurements and no fixtures.
    private func listObjects(_ c: PTPIPClient, net: String, record: Bool = true) async throws {
            let prefix = "ptpip.\(net)"
            let clock = ContinuousClock()
            let started = clock.now
            var fixtures: [(String, Data)] = []
            var listed: [CardObject] = []
            var folders = 0
            var savedKinds: Set<String> = []

            let (ids, idsRaw) = try await c.getStorageIDs()
            fixtures.append(("storageids.bin", idsRaw))
            var storageNotes: [String] = []
            for id in ids {
                let idText = String(format: "0x%08X", id.rawValue)
                // Sony's contents-transfer storages (0x00010001 for the card, virtual 0x00F10001 for photos sent from
                // the camera) have a non-zero low half, so they pass this filter.
                guard id.hasLogicalStore else {
                    storageNotes.append("\(idText): no logical store (empty slot?)")
                    continue
                }
                do {
                    let (si, siRaw) = try await c.getStorageInfo(id)
                    if !fixtures.contains(where: { $0.0 == "storageinfo.bin" }) { fixtures.append(("storageinfo.bin", siRaw)) }
                    storageNotes.append(String(format: "%@ \"%@\" label \"%@\", %.1f GB free of %.1f GB, type %ld fs %ld access %ld",
                                               idText, si.storageDescription, si.volumeLabel,
                                               Double(si.freeSpaceInBytes) / 1e9, Double(si.maxCapacity) / 1e9,
                                               Int(si.storageType), Int(si.filesystemType), Int(si.accessCapability)))
                } catch let error as PTPIPClient.ClientError where !error.isLinkFailure {
                    // A virtual storage may not answer GetStorageInfo (or answer it oddly): note it and list its
                    // handles anyway. A dead link still ends the listing.
                    storageNotes.append("\(idText): GetStorageInfo failed (\(error)); handles listed anyway")
                    self.log.warn("GetStorageInfo \(idText): \(error); listing its handles anyway")
                }
                let (handles, handlesRaw) = try await c.getObjectHandles(storage: id)
                if !fixtures.contains(where: { $0.0 == "objecthandles.bin" }) { fixtures.append(("objecthandles.bin", handlesRaw)) }
                for (i, handle) in handles.enumerated() {
                    let (info, raw) = try await c.getObjectInfo(handle)
                    if i % 10 == 0 {
                        self.progress = Double(i) / Double(max(handles.count, 1))
                        self.activity = "List card: \(i) of \(handles.count)"
                    }
                    if info.isFolder { folders += 1; continue }
                    let ext = info.fileExtension.lowercased()
                    if ["arw", "jpg", "hif", "mp4"].contains(ext), !savedKinds.contains(ext) {
                        savedKinds.insert(ext)
                        fixtures.append(("objectinfo-\(ext).bin", raw))
                    }
                    listed.append(CardObject(handle: handle, info: info))
                }
            }
            let seconds = (clock.now - started).inSeconds

            self.objects = listed.sorted(by: CardObject.newestFirst)
            let byKind = Dictionary(grouping: listed, by: { $0.info.fileExtension.isEmpty ? "?" : $0.info.fileExtension })
            let breakdown = byKind.keys.sorted().map { "\($0) \(byKind[$0]?.count ?? 0)" }.joined(separator: ", ")
            guard record else {
                self.log.note(String(format: "listed again in %.1f s: %ld objects (%@; %ld folder(s) not counted) over %ld storage ID(s); not recorded as %@.enumerate",
                                     seconds, listed.count, breakdown, folders, ids.count, prefix))
                for note in storageNotes { self.log.note("storage \(note)") }
                return
            }
            self.log.measure("\(prefix).enumerate", seconds, "s",
                             context: "GetStorageIDs + GetStorageInfo + GetObjectHandles + GetObjectInfo × \(listed.count + folders) over \(ids.count) storage ID(s)")
            self.log.measure("\(prefix).objects", Double(listed.count), "count", context: "\(breakdown); \(folders) folder(s) not counted")
            for note in storageNotes { self.log.note("storage \(note)") }
            if let newest = self.objects.first {
                self.log.note("newest: \(newest.info.filename) \(newest.info.captureDateRaw) \(newest.info.objectCompressedSize) bytes, format \(newest.info.objectFormat), handle \(newest.handle)")
            }
            for (name, data) in fixtures { FixtureStore.save(data, link: .ptpip, name: name, log: self.log) }
    }

    func thumbnails() {
        runSession("Thumbnails for 50 newest", needsListing: true) { c, net in
            let items = Array(self.objects.prefix(50))
            guard !items.isEmpty else { throw WiFiLabError.message("nothing listed; tap List card first") }
            let clock = ContinuousClock()
            var times: [Double] = []
            var bytes = 0
            var failures: [String] = []
            for (i, o) in items.enumerated() {
                self.progress = Double(i) / Double(items.count)
                let started = clock.now
                do {
                    let thumb = try await c.getThumb(o.handle)
                    times.append((clock.now - started).inSeconds)
                    bytes += thumb.count
                } catch PTPIPClient.ClientError.response(_, let code) {
                    failures.append("\(o.info.filename): \(code)")
                }
            }
            guard !times.isEmpty else { throw WiFiLabError.message("no GetThumb succeeded (\(failures.prefix(3).joined(separator: "; ")))") }
            let average = times.reduce(0, +) / Double(times.count) * 1000
            let slowest = (times.max() ?? 0) * 1000
            self.log.measure("ptpip.\(net).thumb.avg", average, "ms",
                             context: String(format: "%ld thumbnails, %ld KB, slowest %.0f ms, %ld failed", times.count, bytes / 1024, slowest, failures.count))
            if !failures.isEmpty { self.log.note("GetThumb failures: \(failures.prefix(10).joined(separator: "; "))") }
        }
    }

    func downloadARW() {
        runSession("GetObject 20 newest ARW", transfer: true, needsListing: true) { c, net in
            let prefix = "ptpip.\(net)"
            let items = self.newest(ext: "ARW", count: 20)
            guard !items.isEmpty else { throw WiFiLabError.message("no ARW listed; tap List card first") }
            await self.batteryBeforeDownload(c, prefix: prefix)
            let result = try await self.log.withMemoryPeak("\(prefix).download", context: "\(items.count) ARW via GetObject") {
                try await self.downloadBatch(items, client: c, prefix: prefix, perFile: "\(prefix).getObject.file", label: "ARW")
            }
            if result.files > 0 {
                self.log.throughput("\(prefix).getObject.throughput", bytes: Int(result.bytes), seconds: result.seconds,
                                    context: String(format: "%ld ARW, %.1f MB, batch wall time %.1f s (first Cmd_Request to last response)%@",
                                                    result.files, Double(result.bytes) / 1e6, result.seconds,
                                                    result.failures > 0 ? ", \(result.failures) failed" : ""))
            }
            await self.batteryAfterDownload(c, bytes: result.bytes, prefix: prefix)
        }
    }

    /// Build 13: whether the latest downloadOneARW got the whole file (nil while it hasn't finished, or when it never
    /// started: not connected, or another action running), and one line about it (file name, size, time; or why
    /// not), for a guided run's context.
    private(set) var oneARWDownloaded: Bool?
    private(set) var oneARWSummary = "not run"

    /// Build 13: GetObject of one ARW, the `index`-th newest (0 the newest, 1 the second-newest), to a temporary file
    /// deleted after measuring (`ptpip.<net>.getObject.file`), as GetObject 20 newest ARW does. A session that has
    /// dropped is reopened first in the same kind of session (runSession), and the card listed again.
    func downloadOneARW(newestIndex index: Int) {
        oneARWDownloaded = nil
        oneARWSummary = "not started (not connected, or another action was running)"
        runSession("GetObject ARW \(index + 1) newest", transfer: true, needsListing: true) { c, net in
            let prefix = "ptpip.\(net)"
            let items = self.newest(ext: "ARW", count: index + 1)
            guard items.count > index else {
                self.oneARWDownloaded = false
                self.oneARWSummary = "only \(items.count) ARW listed"
                throw WiFiLabError.message("fewer than \(index + 1) ARW listed; tap List card first")
            }
            let o = items[index]
            let url = try self.downloadURL(for: o)
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let r = try await c.getObject(o.handle, to: url)
                let expected = UInt64(o.info.objectCompressedSize)
                let whole = o.info.objectCompressedSize == UInt32.max || r.bytes == expected
                self.log.throughput("\(prefix).getObject.file", bytes: Int(r.bytes), seconds: r.seconds,
                                    context: String(format: "%@ (ARW %ld newest), %.1f MB in %.2f s, sha256 %@…", o.info.filename, index + 1,
                                                    Double(r.bytes) / 1e6, r.seconds, String(r.sha256.prefix(12))))
                self.oneARWDownloaded = whole
                self.oneARWSummary = String(format: "%@ (ARW %ld newest): %.1f MB in %.2f s%@", o.info.filename, index + 1,
                                            Double(r.bytes) / 1e6, r.seconds, whole ? "" : ", but ObjectInfo says \(expected) bytes")
            } catch {
                self.oneARWDownloaded = false
                self.oneARWSummary = "\(o.info.filename) (ARW \(index + 1) newest): \(error)"
                throw error
            }
        }
    }

    func downloadMP4() {
        runSession("GetObject 3 newest MP4", transfer: true, needsListing: true) { c, net in
            let prefix = "ptpip.\(net)"
            let items = self.newest(ext: "MP4", count: 3)
            guard !items.isEmpty else { throw WiFiLabError.message("no MP4 listed; tap List card first") }
            await self.batteryBeforeDownload(c, prefix: prefix)
            let result = try await self.log.withMemoryPeak("\(prefix).download", context: "\(items.count) MP4 via GetObject") {
                try await self.downloadBatch(items, client: c, prefix: prefix, perFile: "\(prefix).getObject.file", label: "MP4")
            }
            // One batch figure, like usb.download.mp4, so the table's MP4 row compares like with like.
            if result.files > 0 {
                self.log.throughput("\(prefix).getObject.mp4", bytes: Int(result.bytes), seconds: result.seconds,
                                    context: String(format: "%ld MP4, %.1f MB, batch wall time %.1f s (first Cmd_Request to last response)%@",
                                                    result.files, Double(result.bytes) / 1e6, result.seconds,
                                                    result.failures > 0 ? ", \(result.failures) failed" : ""))
            }
            await self.batteryAfterDownload(c, bytes: result.bytes, prefix: prefix)
        }
    }

    /// The same ARW batch inside a BGContinuedProcessingTask: start it, then lock the phone.
    func downloadARWContinued() {
        guard let c = client, let net = sessionNet else { log.warn("continued download: not connected"); return }
        guard !busy, !continued.isRunning else { log.warn("continued download: another operation is running"); return }
        let items = newest(ext: "ARW", count: 20)
        guard !items.isEmpty else { log.warn("continued download: no ARW listed; tap List card first"); return }
        let prefix = "ptpip.\(net)"
        continued.run(title: "Importing over Wi-Fi (spike)", subtitle: "0 of \(items.count) ARW", totalUnits: items.count) { [weak self] report, shouldStop in
            guard let self else { return false }
            return await self.continuedBatch(items, client: c, prefix: prefix, report: report, shouldStop: shouldStop)
        }
    }

    private func continuedBatch(_ items: [CardObject], client c: PTPIPClient, prefix: String,
                                report: @escaping ContinuedTask.Report, shouldStop: @escaping ContinuedTask.ShouldStop) async -> Bool {
        busy = true
        activity = "Continued task: ARW batch"
        lifecycle.transferStarted(link: prefix)
        defer {
            busy = false
            activity = ""
            progress = nil
            lifecycle.transferEnded()
            lifecycle.operationEnded()
        }
        while keepAliveInFlight { try? await Task.sleep(for: .milliseconds(20)) }
        var done = 0
        var bytes: UInt64 = 0
        let clock = ContinuousClock()
        let started = clock.now
        for o in items {
            if shouldStop() {
                log.warn("continued batch stopping after \(done) of \(items.count) files (\(lifecycle.stateDescription))")
                return false
            }
            let url: URL
            do {
                url = try downloadURL(for: o)
            } catch {
                log.error("continued batch: no temporary file for \(o.info.filename): \(error)")
                return false
            }
            // Also on a link drop mid-file: the partial download must not stay in tmp.
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let r = try await c.getObject(o.handle, to: url)
                bytes += r.bytes
                done += 1
                log.throughput("\(prefix).getObject.file", bytes: Int(r.bytes), seconds: r.seconds,
                               context: "\(o.info.filename) in a continued task, \(lifecycle.stateDescription)")
                progress = Double(done) / Double(items.count)
                report(done, "\(done) of \(items.count) ARW")
                lifecycle.noteProgress("\(o.info.filename) (\(done) of \(items.count), continued task)", link: prefix)
            } catch {
                log.error("continued batch stopped at \(o.info.filename) (\(lifecycle.stateDescription)): \(error)")
                if let failure = await c.linkFailure { connectionState = "connection lost (\(failure)); tap Reconnect" }
                return false
            }
        }
        log.note(String(format: "continued batch finished: %ld files, %.1f MB in %.1f s", done, Double(bytes) / 1e6, (clock.now - started).inSeconds))
        return true
    }

    /// GetObject for each item, streamed to a temporary file and deleted after measuring. A non-OK response
    /// skips the file; a link failure ends the batch.
    private func downloadBatch(_ items: [CardObject], client c: PTPIPClient, prefix: String, perFile: String, label: String) async throws -> BatchResult {
        var result = BatchResult()
        let clock = ContinuousClock()
        let started = clock.now
        for (i, o) in items.enumerated() {
            activity = "\(label) \(i + 1) of \(items.count): \(o.info.filename)"
            progress = Double(i) / Double(items.count)
            let url = try downloadURL(for: o)
            defer { try? FileManager.default.removeItem(at: url) }
            let r: PTPIPClient.FileDownload
            do {
                r = try await c.getObject(o.handle, to: url)
            } catch PTPIPClient.ClientError.response(let op, let code) {
                result.failures += 1
                log.warn("\(op) \(o.info.filename): \(code); skipped")
                continue
            }
            result.bytes += r.bytes
            result.files += 1
            let expected = UInt64(o.info.objectCompressedSize)
            if o.info.objectCompressedSize != UInt32.max, r.bytes != expected {
                log.warn("\(o.info.filename): received \(r.bytes) bytes but ObjectInfo says \(expected)")
            }
            log.throughput(perFile, bytes: Int(r.bytes), seconds: r.seconds,
                           context: String(format: "%@, %.1f MB in %.2f s, sha256 %@…", o.info.filename, Double(r.bytes) / 1e6, r.seconds, String(r.sha256.prefix(12))))
            lifecycle.noteProgress("\(o.info.filename) (\(i + 1) of \(items.count))", link: prefix)
        }
        result.seconds = (clock.now - started).inSeconds
        return result
    }

    private func newest(ext: String, count: Int) -> [CardObject] {
        Array(objects.lazy.filter { $0.info.fileExtension == ext }.prefix(count))
    }

    private func downloadURL(for o: CardObject) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptpip-downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = o.info.filename.isEmpty ? "object-\(o.handle.rawValue)" : WiFiResumeStore.safeComponent(o.info.filename)
        return dir.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: Copy all RAW to Files

    /// Every ARW listed, oldest first by capture date (`objects` is newest first).
    private var copyAllObjects: [CardObject] {
        Array(objects.filter { $0.info.fileExtension.uppercased() == "ARW" }.reversed())
    }

    /// What *Copy all RAW to Files* would copy now, for the guided run's count and size.
    var copyAllItems: [CopyAllItem] {
        copyAllObjects.map { CopyAllItem(name: $0.info.filename, size: $0.info.sizeExceeds32Bits ? 0 : UInt64($0.info.objectCompressedSize)) }
    }

    /// *Copy all RAW to Files* over Wi-Fi: every ARW listed, oldest first, inside a continued task (so it survives the
    /// phone locking), each one GetObject to a temporary file and then moved into a new folder in Files
    /// (FilesDestination). Measurements `ptpip.<net>.copyAll.…`. Must be started from a tap. With nothing listed in a
    /// contents-transfer session it lists the card first and then starts, if the app is still in front.
    /// Build 14: a camera that drops its card storage, its session or its Wi-Fi stops the loop for a recovery (at most
    /// three per copy) instead of failing file after file; `recovery` says whether that may use Bluetooth (the guided
    /// run asks; the Wi-Fi tab's button never does) and what the copy runs under (Creators' App).
    func copyAllARW(recovery: CopyAllRecovery = CopyAllRecovery()) {
        let label = "Copy all RAW to Files"
        let destination = FilesDestination.shared
        guard client != nil, sessionNet != nil else {
            log.warn("\(label): not connected; tap Contents transfer: whole card (or Connect), then List card")
            return
        }
        guard !busy, !continued.isRunning else { log.warn("\(label): another operation is running; wait for it or stop it first"); return }
        guard destination.run == nil else { log.warn("\(label): a copy is already running"); return }
        // Build 14: one pause record at a time; a new copy would leave the paused one behind.
        guard destination.paused == nil else {
            log.warn("\(label): a paused copy is waiting: Continue copy or Discard it first")
            return
        }
        guard objects.isEmpty else {
            startCopyAll(destination, recovery: recovery)
            return
        }
        guard contentsMode != nil else {
            log.warn("\(label): nothing listed; tap List card first")
            return
        }
        log.note("\(label): the card isn't listed yet; listing it first in this contents-transfer session, then the copy starts")
        runSession("List card", needsListing: false) { c, net in try await self.listObjects(c, net: net) }
        Task { @MainActor in
            // runSession marked the lab busy before returning (unless it refused); its work runs in a Task of its own.
            while self.busy { try? await Task.sleep(for: .milliseconds(200)) }
            guard !self.objects.isEmpty else {
                self.log.warn("\(label): the listing found nothing (see above); nothing copied")
                return
            }
            // A continued task has to be asked for while the app is in front.
            guard self.lifecycle.isInForeground else {
                self.log.warn("\(label): the app left the foreground during the listing; tap Copy all RAW to Files again")
                return
            }
            self.startCopyAll(destination, recovery: recovery)
        }
    }

    private func startCopyAll(_ destination: FilesDestination, recovery: CopyAllRecovery) {
        let label = "Copy all RAW to Files"
        guard let c = client, let net = sessionNet else { log.warn("\(label): not connected"); return }
        guard !busy, !continued.isRunning, destination.run == nil, destination.paused == nil else {
            log.warn("\(label): another operation is running, or a paused copy is waiting")
            return
        }
        let items = copyAllObjects
        guard !items.isEmpty else {
            log.warn("\(label): no ARW among the \(objects.count) objects listed")
            return
        }
        let link = "ptpip.\(net)"
        let files = copyAllItems
        // Only Sony's whole-card contents transfer has listed the whole card; another session's list may be a part of it.
        let session = sessionKind
        if contentsMode != .wholeCard {
            log.warn("\(label): this session (\(session)) lists \(objects.count) objects, not necessarily the whole card; for the whole card use Contents transfer: whole card, then List card")
        }
        do {
            try destination.checkSpace(for: files, link: link)
        } catch {
            log.error("\(label): \(CopyAllFormat.describe(error))")
            return
        }
        // Where a recovery reconnects to: this session's camera address and GUID.
        let target = sessionTarget
        log.note("\(label): submitting a continued task for \(items.count) ARW (oldest first) over \(net == "lan" ? "the home LAN" : "the camera's network"); \(recovery.conditions); lock the phone once it has started")
        // Build 14: in bytes (the listed sizes), so the progress moves while a file arrives and during a recovery.
        let totalBytes = files.reduce(UInt64(0)) { $0 + $1.size }
        continued.run(title: "Copying RAW to Files (spike)", subtitle: "0 of \(items.count)",
                      totalUnits: Int(clamping: totalBytes), byteUnits: true) { [weak self] report, shouldStop in
            guard let self else { return false }
            return await self.continuedCopyAll(items, files: files, client: c, link: link, session: session, target: target,
                                               recovery: recovery, destination: destination, report: report, shouldStop: shouldStop)
        }
    }

    private func continuedCopyAll(_ items: [CardObject], files: [CopyAllItem], client c: PTPIPClient, link: String,
                                  session: String, target: WiFiTarget?, recovery: CopyAllRecovery, destination: FilesDestination,
                                  report: @escaping ContinuedTask.Report, shouldStop: @escaping ContinuedTask.ShouldStop) async -> Bool {
        busy = true
        activity = "Copy all RAW to Files"
        progress = 0
        lifecycle.transferStarted(link: link)
        defer {
            busy = false
            activity = ""
            progress = nil
            lifecycle.transferEnded()
            lifecycle.operationEnded()
        }
        while keepAliveInFlight { try? await Task.sleep(for: .milliseconds(20)) }
        // Before begin: a dead link creates no run folder and records nothing.
        if let failure = await c.linkFailure {
            connectionState = "connection lost (\(failure)); tap Reconnect"
            log.error("Copy all RAW to Files: the connection had already dropped (\(failure)); reconnect, List card and copy again")
            return false
        }
        let run: CopyAllRun
        do {
            run = try destination.begin(link: link, items: files, session: session, conditions: recovery.conditions)
        } catch {
            // Not the error itself: a file error's userInfo can hold the chosen folder's full path.
            log.error("Copy all RAW to Files: couldn't start: \(CopyAllFormat.describe(error))")
            return false
        }
        let meter = CopyProgress(report: report, totalBytes: run.totalBytes)
        meter.attach(run)
        return await runCopy(items, run: run, client: c, link: link, target: target, recovery: recovery,
                             destination: destination, meter: meter, shouldStop: shouldStop)
    }

    /// The loop of a new or continued copy, and its end. Build 14: if iOS expired the continued task, the file in
    /// flight is cut off (TransferAbort) and the copy pauses (pauseWiFiCopy) instead of ending; otherwise (the list
    /// done, Stop, Cancel run, a failure) it ends with its measurements. `resumedFrom`: a continued copy's pause record;
    /// if this segment loses its session before it copies a file, the record is put back (FilesDestination.repause)
    /// rather than the copy ending for good.
    private func runCopy(_ items: [CardObject], run: CopyAllRun, client c: PTPIPClient, link: String, target: WiFiTarget?,
                         recovery: CopyAllRecovery, destination: FilesDestination, meter: CopyProgress,
                         resumedFrom: CopyPauseRecord? = nil,
                         shouldStop: @escaping ContinuedTask.ShouldStop) async -> Bool {
        // A StoreRemoved from before this copy isn't the one its "added back" line measures from.
        storeRemovedAt = nil
        copyWatch = run
        copyLeft = []
        copySessionLost = false
        // Build 14: on an expiry the copy finishes nothing more: the file in flight is cut off at its next chunk. During
        // a recovery the client is also cut off (no CloseSession), so a pending reopen, poll or listing fails at once
        // and the recovery reaches its stop check: otherwise the pause would wait for them (up to a minute or more)
        // with the expired task not completed. Between files the loop's own check catches the expiry, and the pause
        // then closes the session cleanly.
        let abort = TransferAbort()
        continued.onExpire = { [weak self] in
            abort.abort()
            guard let self, self.copyRecovering else { return }
            self.log.note("Copy all RAW: iOS ended the continued task during a recovery: the PTP/IP connection is cut off so the recovery stops at once")
            Task { @MainActor in await self.closeClient(closingSession: false) }
        }
        // A continued copy starts with what was done before the pause.
        meter.files(run.copied + run.failed, run.subtitle)
        let reason = await log.withMemoryPeak(run.prefix, context: "\(items.count) ARW to Files over PTP/IP; \(recovery.conditions)") {
            await self.copyAllLoop(items, run: run, client: c, link: link, target: target, recovery: recovery,
                                   meter: meter, abort: abort, shouldStop: shouldStop)
        }
        copyWatch = nil
        let left = copyLeft
        copyLeft = []
        // Build 14: iOS expired the continued task with files left: a pause, not an end (a Stop never pauses).
        if reason != nil, continued.expired, !left.isEmpty,
           await pauseWiFiCopy(run, left: left, target: target, destination: destination) {
            pausedRecovery = recovery
            await releaseCopyBluetooth("the copy paused", copyEnded: true)
            return false
        }
        // Build 14: a continued segment that lost its session before copying a file keeps the copy paused.
        if let record = resumedFrom, let why = reason, !continued.expired, copySessionLost, run.copied == record.copied,
           destination.repause(run, record: record, why: why) {
            pausedRecovery = recovery
            await releaseCopyBluetooth("the continued copy lost its session", copyEnded: true)
            if client == nil { connectionState = "not connected (the copy is still paused)" }
            return false
        }
        // The measurements first: releasing Bluetooth can wait for the camera's answers (or connect once more), and a
        // continued task the system has expired may be suspended before that ends.
        destination.finish(run, stopReason: reason)
        // A Bluetooth link a recovery still holds (the session never came back): notifications off, disconnected.
        await releaseCopyBluetooth("the copy ended", copyEnded: true)
        return reason == nil && run.copied == run.total
    }

    /// Build 14: iOS expired the copy's continued task. The pause record first (FilesDestination.pause: the files
    /// left, the run folder, the counts; it also records `<link>.copyAll.expired` with the conditions and posts the
    /// notification), with the session to reopen; then the session closed, with CloseSession only if no transaction
    /// was cut off on it. False when the record couldn't be saved: the caller then ends the copy as before.
    private func pauseWiFiCopy(_ run: CopyAllRun, left: [CardObject], target: WiFiTarget?, destination: FilesDestination) async -> Bool {
        let files = left.map { CopyPauseRecord.File(name: Self.copyName($0), size: Self.listedSize($0), handle: $0.handle.rawValue) }
        // The card's other ARW in the latest listing: they claim their matches first when Continue lists the card again.
        let leftHandles = Set(left.map { $0.handle.rawValue })
        let others = copyAllObjects.filter { !leftHandles.contains($0.handle.rawValue) }
            .map { CopyPauseRecord.File(name: Self.copyName($0), size: Self.listedSize($0), handle: $0.handle.rawValue) }
        let wifi = target.map { CopyPauseRecord.WiFiSession(net: $0.net, host: $0.host, guid: $0.guid.uuidString,
                                                            contentsMode: contentsMode?.rawValue) }
        let expiry = continued.expiryConditions ?? continued.conditions()
        do {
            try await destination.pause(run, remaining: files, others: others, wifi: wifi,
                                        expiredAt: continued.expiredAt ?? Date(), expiry: expiry)
        } catch {
            log.flag("\(run.prefix).expired", true,
                     context: "iOS ended the continued task (an expiry, or Stop in the Live Activity) at \(run.copied + run.failed) of \(run.total) ARW; \(expiry); the pause record couldn't be saved, so the copy ended" + (run.conditions.map { "; \($0)" } ?? ""))
            log.error("Copy all RAW: iOS ended the continued task, but the pause record couldn't be saved (\(CopyAllFormat.describe(error))); the copy ends here instead")
            return false
        }
        if let c = client {
            let failure = await c.linkFailure
            await closeClient(closingSession: failure == nil)
            let how: String
            if let failure {
                how = "the connection closed without CloseSession for the pause (the file in flight was cut off: \(failure))"
            } else {
                how = "the session closed (CloseSession) for the pause"
            }
            log.note("Copy all RAW: \(how); Continue copy reopens it")
        }
        connectionState = "not connected (the copy is paused: Continue copy reopens the session)"
        return true
    }

    /// Build 14: Continue copy over Wi-Fi, from a tap (the Wi-Fi tab, or the guided run's question, which passes its
    /// recovery settings): submits a new continued task at once and, inside it, gets the session back the way a
    /// recovery reopens it (the open session if it is the same kind on the same network and still up; otherwise the
    /// same kind of session reopened at the camera's address once its port answers), lists the card, finds the files
    /// left by name and size (the same handle first), and continues into the same run folder (FilesDestination.resume).
    /// If the session can't be had, the pause record is kept for another try. Only the guided run's Continue (which
    /// passes `recovery`) may use Bluetooth: from the Wi-Fi tab (`recovery` nil) the paused copy's Creators' App answer
    /// is kept and Bluetooth dropped, as the section's footer says, and the conditions then say "Bluetooth recovery off".
    func continuePausedCopy(recovery: CopyAllRecovery? = nil) {
        let label = "Continue copy"
        let destination = FilesDestination.shared
        guard let record = destination.paused, record.link.hasPrefix("ptpip") else {
            log.warn("\(label): no paused Wi-Fi copy")
            return
        }
        guard !busy, !continued.isRunning, destination.run == nil else {
            log.warn("\(label): another operation is running; wait for it or stop it first")
            return
        }
        let net = record.wifi?.net ?? (record.link == "ptpip.lan" ? "lan" : "ap")
        let target: WiFiTarget
        if let wifi = record.wifi {
            target = WiFiTarget(net: wifi.net, host: wifi.host, guid: UUID(uuidString: wifi.guid) ?? sessionTarget?.guid ?? UUID())
        } else if let known = sessionTarget, known.net == net {
            target = known
        } else {
            log.error("\(label): the pause record has no camera address and no session is known; Discard it and copy again")
            return
        }
        let settings = recovery ?? CopyAllRecovery(bluetooth: nil, creatorsApp: pausedRecovery?.creatorsApp,
                                                   bluetoothNote: pausedRecovery?.bluetoothNote)
        let tappedAt = Date()
        log.note("\(label): submitting a continued task for the \(record.remaining.count) ARW left of the paused copy (\(record.done) of \(record.total) done) over \(net == "lan" ? "the home LAN" : "the camera's network"); \(settings.conditions); lock the phone once it has started")
        continued.run(title: "Copying RAW to Files (spike)", subtitle: "\(record.done) of \(record.total)",
                      totalUnits: Int(clamping: record.totalBytes), byteUnits: true) { [weak self] report, shouldStop in
            guard let self else { return false }
            return await self.continuedPausedCopy(record, target: target, recovery: settings, destination: destination,
                                                  tappedAt: tappedAt, report: report, shouldStop: shouldStop)
        }
    }

    private func continuedPausedCopy(_ record: CopyPauseRecord, target: WiFiTarget, recovery: CopyAllRecovery,
                                     destination: FilesDestination, tappedAt: Date,
                                     report: @escaping ContinuedTask.Report, shouldStop: @escaping ContinuedTask.ShouldStop) async -> Bool {
        let link = record.link
        busy = true
        activity = "Continue copy: getting the session back"
        progress = nil
        lifecycle.transferStarted(link: link)
        defer {
            busy = false
            activity = ""
            progress = nil
            copyRecovering = false
            lifecycle.transferEnded()
            lifecycle.operationEnded()
        }
        while keepAliveInFlight { try? await Task.sleep(for: .milliseconds(20)) }
        let meter = CopyProgress(report: report, totalBytes: record.totalBytes, doneBytes: record.doneBytes)
        meter.files(record.done, "\(record.done) of \(record.total) · reconnecting")
        let steps = CopyRecoverySteps(log: log, number: 0, meter: meter, label: "continuing the paused copy")
        // Build 14: an expiry during the reconnect cuts the PTP/IP client off at once, as during a recovery, so a pending
        // reopen, poll or listing fails and the task can end promptly (runCopy sets its own onExpire once the copy runs).
        copyRecovering = true
        continued.onExpire = { [weak self] in
            guard let self, self.copyRecovering else { return }
            self.log.note("Continue copy: iOS ended the continued task during the reconnect: the PTP/IP connection is cut off")
            Task { @MainActor in await self.closeClient(closingSession: false) }
        }
        var wantedMode: SonyContentsMode?
        if let raw = record.wifi?.contentsMode { wantedMode = SonyContentsMode(rawValue: raw) }
        var opened: PTPIPClient?
        // The open session, if it is the paused copy's kind on its network and still up (the tester reconnected).
        if let open = client, sessionNet == target.net, contentsMode == wantedMode, await open.linkFailure == nil {
            do {
                let arw = try await relistForCopy(open, net: target.net, poll: true, shouldStop: shouldStop)
                if arw > 0 {
                    opened = open
                    steps.add("using the open session (\(sessionKind)): \(arw) ARW listed")
                } else {
                    steps.add("the open session lists no ARW")
                }
            } catch {
                steps.add("listing the card in the open session failed: \(error)")
            }
        }
        if opened == nil && !shouldStop() {
            if client != nil {
                await closeClient(closingSession: true)
                steps.add("closed the session that was open")
            }
            // reopen() opens the kind of session in contentsMode: the paused copy's.
            contentsMode = wantedMode
            if let after = await waitForCameraPort(host: target.host, seconds: 30, steps: steps, shouldStop: shouldStop) {
                steps.add(String(format: "%@:15740 answered after %.1f s", target.host, after))
                opened = await reopenForCopy(target, steps: steps, shouldStop: shouldStop)
            } else if !shouldStop() {
                steps.add("nothing answered at \(target.host):15740 within 30 s (is the phone on the camera's network?)")
                // Build 14: as a recovery's step c, if the guided run allowed Bluetooth (the camera's own network only).
                if let handover = recovery.bluetooth, target.net == "ap" {
                    opened = await continueOverBluetooth(handover, target: target, steps: steps, shouldStop: shouldStop)
                }
            }
        }
        copyRecovering = false
        guard let c = opened, !shouldStop() else {
            let why: String
            if continued.expired {
                why = "iOS ended the continued task again during the reconnect (an expiry, or Stop in the Live Activity)"
                log.flag("\(record.link).copyAll.expired", true,
                         context: "iOS ended the continued task (an expiry, or Stop in the Live Activity; no reason given) while Continue copy was getting the session back, before anything was copied (pause \(record.pauses) at \(record.done) of \(record.total) ARW); \(continued.expiryConditions ?? continued.conditions()); the copy is still paused"
                            + (record.conditions.map { "; \($0)" } ?? ""))
            } else if shouldStop() {
                why = "stopped (Stop or Cancel run) during the reconnect"
            } else {
                why = "the session isn't back: keep the camera on with its Wi-Fi up, join its network and tap Continue copy again"
            }
            log.error("Continue copy: \(why) (\(steps.summary)); nothing was copied and the copy is still paused (its pause record is kept): Continue copy again, or Discard [\(lifecycle.stateDescription)]")
            if client == nil { connectionState = "not connected (the copy is still paused)" }
            await releaseCopyBluetooth("Continue copy didn't get the session back", copyEnded: true)
            return false
        }
        // A Bluetooth link the fallback used is released once the session is back.
        await releaseCopyBluetooth("the session is back", copyEnded: false)
        let remap = remapPaused(record.remaining, others: record.others ?? [])
        // From the Wi-Fi tab (or after a relaunch) a copy the guided run allowed Bluetooth for continues without it.
        let change: String? = (record.conditions ?? "").contains("Bluetooth recovery allowed") && recovery.bluetooth == nil
            ? "Bluetooth recovery off" : nil
        let run: CopyAllRun
        do {
            run = try destination.resume(record, tappedAt: tappedAt, change: change)
        } catch {
            log.error("Continue copy: couldn't continue: \(CopyAllFormat.describe(error)); the copy is still paused (its pause record is kept)")
            return false
        }
        meter.attach(run)
        for name in remap.missing {
            run.fileFailed(name, "not in the camera's listing when the copy continued (no ARW of that name and size)")
        }
        // Nothing is skipped as "already there": no file left was placed before the pause, and a same-named file in the
        // folder (another DCIM folder's) makes the new one "NAME (2).ARW", so nothing is overwritten.
        let queue = remap.found
        log.note("Continue copy: \(remap.found.count) of \(record.remaining.count) file(s) found again in the listing (\(remap.sameHandle) under the same handle), \(remap.missing.count) not found; \(queue.count) to copy [\(lifecycle.stateDescription)]")
        pausedRecovery = nil
        activity = "Copy all RAW to Files"
        return await runCopy(queue, run: run, client: c, link: link, target: target, recovery: recovery,
                             destination: destination, meter: meter, resumedFrom: record, shouldStop: shouldStop)
    }

    /// Build 14: Continue copy's fallback when the camera's port doesn't answer and the guided run allowed Bluetooth (the
    /// camera's own network only): recovery step c (the camera's Wi-Fi switched on over Bluetooth, the one write CC08 =
    /// 01 unless CC09 already reports it on; up to 30 s for iOS to rejoin; one join with the details read over Bluetooth
    /// if the app is in front), then the session reopened and the card listed. Nil when that doesn't get the session
    /// back or the copy is stopped; the caller releases the Bluetooth link either way.
    private func continueOverBluetooth(_ handover: SonyWiFiHandover, target: WiFiTarget, steps: CopyRecoverySteps,
                                       shouldStop: ContinuedTask.ShouldStop) async -> PTPIPClient? {
        guard await switchWiFiOnForCopy(handover, steps: steps, shouldStop: shouldStop) else { return nil }
        if let after = await waitForCameraPort(host: target.host, seconds: 30, steps: steps, shouldStop: shouldStop) {
            steps.add(String(format: "the phone rejoined by itself: %@:15740 answered after %.1f s", target.host, after))
        } else if shouldStop() {
            return nil
        } else if !lifecycle.isInForeground {
            steps.add("the camera's Wi-Fi is on, but the phone didn't rejoin its network within 30 s, and a join needs the app in the foreground")
            return nil
        } else {
            steps.add("the phone didn't rejoin within 30 s; one join with the details read over Bluetooth (the app is in the foreground)")
            guard await joinForCopy(handover, steps: steps, shouldStop: shouldStop) else { return nil }
            guard let after = await waitForCameraPort(host: target.host, seconds: 30, steps: steps, shouldStop: shouldStop) else {
                if !shouldStop() { steps.add("nothing answered at \(target.host):15740 within 30 s of the join") }
                return nil
            }
            steps.add(String(format: "%@:15740 answered %.1f s after the join", target.host, after))
        }
        return await reopenForCopy(target, steps: steps, shouldStop: shouldStop)
    }

    /// Build 14: a paused copy's files found in the new listing: the same handle with the same name and size first,
    /// otherwise the first ARW of that name and size not taken yet. The card's `others` at the pause (copied, failed or
    /// not part of the copy) claim their matches first, so with two ARW of the same name and size one already copied
    /// isn't taken for one left. The files found (in the old order), the names not found, and how many kept their handle.
    private func remapPaused(_ files: [CopyPauseRecord.File], others: [CopyPauseRecord.File]) -> (found: [CardObject], missing: [String], sameHandle: Int) {
        var byHandle: [UInt32: CardObject] = [:]
        var byKey: [String: [CardObject]] = [:]
        for o in copyAllObjects {
            byHandle[o.handle.rawValue] = o
            byKey[Self.pauseKey(Self.copyName(o), Self.listedSize(o)), default: []].append(o)
        }
        var used: Set<UInt32> = []
        func claim(_ f: CopyPauseRecord.File) -> (object: CardObject, sameHandle: Bool)? {
            let key = Self.pauseKey(f.name, f.size)
            if let h = f.handle, let same = byHandle[h], Self.pauseKey(Self.copyName(same), Self.listedSize(same)) == key,
               !used.contains(h) {
                used.insert(h)
                return (same, true)
            }
            if let other = byKey[key]?.first(where: { !used.contains($0.handle.rawValue) }) {
                used.insert(other.handle.rawValue)
                return (other, false)
            }
            return nil
        }
        for f in others { _ = claim(f) }
        var found: [CardObject] = []
        var missing: [String] = []
        var sameHandle = 0
        for f in files {
            if let hit = claim(f) {
                found.append(hit.object)
                if hit.sameHandle { sameHandle += 1 }
            } else {
                missing.append(f.name)
            }
        }
        return (found, missing, sameHandle)
    }

    /// Name (case-insensitive) and size, for a paused copy's files.
    private static func pauseKey(_ name: String, _ size: UInt64) -> String {
        "\(name.lowercased())|\(size)"
    }

    /// The listed size; 0 when over 4 GB (unknown over PTP/IP).
    private static func listedSize(_ o: CardObject) -> UInt64 {
        o.info.sizeExceeds32Bits ? 0 : UInt64(o.info.objectCompressedSize)
    }

    /// At most this many recoveries per copy; the next interruption ends it.
    static let copyRecoveryLimit = 3
    /// Failures of any kind in a row (non-OK answers, size mismatches) that stop the loop for a recovery.
    static let copyFailuresBeforeRecovery = 3

    /// The copy itself. Returns why it ended early, or nil once it has been through the list. Build 14: failures are
    /// classified. Session-level, which stop the loop for a recovery (recoverCopy, at most `copyRecoveryLimit` per copy):
    /// a StoreRemoved since the last file, StoreNotAvailable, InvalidObjectHandle on the first file after a store change
    /// or on two files in a row, `copyFailuresBeforeRecovery` failures of any kind in a row, and a link failure. The
    /// file in flight is then not counted as failed: its temporary file is deleted and it is tried again after the
    /// recovery, with any non-OK answers before it not yet counted. Per-file: any other non-OK answer is counted as
    /// failed once a later file copies (so a camera that has lost its card can't fail the rest of the list in a second,
    /// as it did 81 times on 3 Nov). A file a recovery put back that gets such an answer again is counted as failed at
    /// once, outside the in-a-row rules, so a file the camera always refuses can't use up the recoveries. A size
    /// mismatch is counted at once; a local file error ends the run.
    /// Build 14: an expiry (not a Stop) leaves the files not copied in `copyLeft` for the pause record, the file in flight
    /// (cut off through `abort`) and the files whose non-OK answer wasn't counted yet among them, uncounted; the byte
    /// progress gets each file's bytes as they arrive.
    private func copyAllLoop(_ items: [CardObject], run: CopyAllRun, client first: PTPIPClient, link: String,
                             target: WiFiTarget?, recovery: CopyAllRecovery,
                             meter: CopyProgress, abort: TransferAbort,
                             shouldStop: @escaping ContinuedTask.ShouldStop) async -> String? {
        let net = target?.net ?? (link == "ptpip.lan" ? "lan" : "ap")
        let clock = ContinuousClock()
        var queue = items
        var position = 0
        var c = first
        // Non-OK answers since the last file that copied, not counted yet: files before `position` (normally just
        // before it; a file a recovery put back and counted at once can sit between them).
        var pending: [PendingCopyFailure] = []
        // Files already copied or counted as failed, from queues before a recovery: they claim their match in a new
        // listing first, so a file of the same name and size still to copy isn't taken for one of them.
        var done: [CardObject] = []
        // Name and size of the files recoveries put back to try again.
        var retriedKeys: Set<String> = []
        // StoreAdded events before the latest GetObject started: the card counts as back once there are more.
        var addsBefore = storeAdds
        // Failures of any kind since the last file that copied.
        var inARow = 0
        // Counted per copy (a continued copy carries on the count from before its pause, for the measurements), but the
        // limit applies per segment (build 14): a copy that used its recoveries before a pause can still recover after
        // Continue copy.
        var recoveries = run.recoveries
        let recoveriesBefore = run.recoveries
        var seenStoreChanges = storeChanges
        // A recovery that brought the session back: measured when the next file starts.
        var resumed: (failedAt: ContinuousClock.Instant, cause: String, steps: String)?

        while position < queue.count {
            if shouldStop() {
                if continued.expired {
                    // Build 14: a pause: the held non-OK answers aren't counted; their files go back with the rest.
                    copyLeft = pending.map { queue[$0.position] } + Array(queue[position...])
                } else {
                    countPendingCopyFailures(&pending, run: run)
                }
                meter.files(run.copied + run.failed, run.subtitle)
                if let back = resumed {
                    measureCopyRecovery(run, seconds: (clock.now - back.failedAt).inSeconds, cause: back.cause, steps: back.steps,
                                        until: "the copy stopping before the next file")
                }
                return "\(copyStopWhy()) after \(run.copied + run.failed) of \(run.total) [\(lifecycle.stateDescription)]"
            }
            var interruption: CopyInterruption?
            if !removedStores.isEmpty {
                // Recover before asking for another file: on 3 Nov the next GetObject answered StoreNotAvailable, and 81
                // InvalidObjectHandle followed within a second.
                interruption = CopyInterruption(cause: "StoreRemoved (storage \(Self.storeIDs(removedStores))) after \(run.copied) files",
                                                storeGone: true, inFlight: false)
            } else {
                let o = queue[position]
                let name = Self.copyName(o)
                activity = "Copy all RAW: \(run.copied + run.failed + pending.count + 1) of \(run.total), \(name)"
                progress = Double(run.copied + run.failed) / Double(max(run.total, 1))
                let tmp = run.temporaryURL("object-\(o.handle.rawValue).download")
                run.willRequest(name)
                addsBefore = storeAdds
                if let back = resumed {
                    resumed = nil
                    measureCopyRecovery(run, seconds: (clock.now - back.failedAt).inSeconds, cause: back.cause, steps: back.steps,
                                        until: "\(name) starting")
                }
                // Build 14: the bytes as they arrive, for the continued task's progress (one main-actor hop per callback,
                // which the client makes at most every 0.25 s).
                let fileNumber = meter.startFile()
                do {
                    let r = try await c.getObject(o.handle, to: tmp, abort: abort, progress: { received in
                        Task { @MainActor in meter.received(received, file: fileNumber) }
                    })
                    // The camera served a file: the non-OK answers just before it were about those files.
                    countPendingCopyFailures(&pending, run: run)
                    seenStoreChanges = storeChanges
                    position += 1
                    // PTPIPClient only warns when the data phase is short but the response is OK: a short file is failed
                    // and deleted here, never put in the folder under the card's name.
                    let expected: UInt64? = o.info.sizeExceeds32Bits ? nil : UInt64(o.info.objectCompressedSize)
                    let shortOfAnnounced = r.announcedLength.map { $0 != r.bytes } ?? false
                    let shortOfListing = expected.map { $0 > 0 && $0 != r.bytes } ?? false
                    if shortOfAnnounced || shortOfListing {
                        try? FileManager.default.removeItem(at: tmp)
                        let wanted = expected ?? r.announcedLength ?? 0
                        run.fileFailed(name, "size mismatch: \(r.bytes) B received, \(wanted) B expected; the copy was deleted")
                        meter.files(run.copied + run.failed, run.subtitle)
                        inARow += 1
                        if inARow >= Self.copyFailuresBeforeRecovery {
                            interruption = CopyInterruption(cause: "\(inARow) failures in a row (the last: \(name), size mismatch)",
                                                            storeGone: false, inFlight: false)
                        }
                    } else {
                        do {
                            try await run.place(tmp, cardName: name, bytes: r.bytes, seconds: r.seconds,
                                                detail: "sha256 \(r.sha256.prefix(12))…", state: lifecycle.stateDescription)
                        } catch {
                            try? FileManager.default.removeItem(at: tmp)
                            run.fileFailed(name, "couldn't be moved into the folder: \(error.localizedDescription)")
                            meter.files(run.copied + run.failed, run.subtitle)
                            return "couldn't write to \(run.destinationLabel): \(error.localizedDescription)"
                        }
                        inARow = 0
                        progress = Double(run.copied + run.failed) / Double(max(run.total, 1))
                        meter.files(run.copied + run.failed, run.subtitle)
                        lifecycle.noteProgress("copy all: \(name) (\(run.copied + run.failed) of \(run.total))", link: link)
                    }
                } catch PTPIPClient.ClientError.response(let op, let code) {
                    try? FileManager.default.removeItem(at: tmp)
                    // A StoreRemoved sent with this answer may still be on its way through the event stream.
                    try? await Task.sleep(for: .milliseconds(300))
                    let answer = "\(op) \(name) answered \(WirelessLab.codeText(code))"
                    let previousInvalid = pending.last.map { $0.code == .invalidObjectHandle } ?? false
                    if !removedStores.isEmpty {
                        interruption = CopyInterruption(cause: "StoreRemoved (storage \(Self.storeIDs(removedStores))) after \(run.copied) files; \(answer)",
                                                        storeGone: true, inFlight: true)
                    } else if code == .storeNotAvailable {
                        interruption = CopyInterruption(cause: "\(answer) after \(run.copied) files", storeGone: true, inFlight: true)
                    } else if code == .invalidObjectHandle && storeChanges != seenStoreChanges {
                        interruption = CopyInterruption(cause: "\(answer), the first file after a store change", storeGone: false, inFlight: true)
                    } else if retriedKeys.contains(Self.copyKey(o)) {
                        // Put back by a recovery and refused again with a per-file answer: counted as failed at once and
                        // outside the in-a-row rules, so a file the camera always refuses can't use up the recoveries.
                        retriedKeys.remove(Self.copyKey(o))
                        run.fileFailed(name, "\(op) answered \(WirelessLab.codeText(code)), again after a recovery")
                        meter.files(run.copied + run.failed, run.subtitle)
                        seenStoreChanges = storeChanges
                        position += 1
                        log.note("  copy: \(answer) again after a recovery; counted as failed")
                        continue
                    } else if code == .invalidObjectHandle && previousInvalid {
                        interruption = CopyInterruption(cause: "\(answer), the second file in a row", storeGone: false, inFlight: true)
                    } else if inARow + 1 >= Self.copyFailuresBeforeRecovery {
                        interruption = CopyInterruption(cause: "\(inARow + 1) failures in a row (the last: \(answer))", storeGone: false, inFlight: true)
                    } else {
                        pending.append(PendingCopyFailure(position: position, name: name, code: code,
                                                          why: "\(op) answered \(WirelessLab.codeText(code))"))
                        inARow += 1
                        seenStoreChanges = storeChanges
                        position += 1
                        log.note("  copy: \(answer); counted as failed once a later file copies, tried again after a recovery otherwise")
                        continue
                    }
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    if continued.expired {
                        // Build 14: the expiry cut this file off (TransferAbort): it goes back into the list, uncounted,
                        // with the held non-OK answers and the rest.
                        copyLeft = pending.map { queue[$0.position] } + Array(queue[position...])
                        meter.files(run.copied + run.failed, run.subtitle)
                        return "\(copyStopWhy()) during \(name) after \(run.copied + run.failed) of \(run.total) (\(error)) [\(lifecycle.stateDescription)]"
                    }
                    var localFile = false
                    if let clientError = error as? PTPIPClient.ClientError, case .fileError = clientError { localFile = true }
                    if !localFile, let failure = await c.linkFailure {
                        connectionState = "connection lost (\(failure)); the copy is recovering"
                        interruption = CopyInterruption(cause: "the link failed at \(name): \(failure)", storeGone: false, inFlight: true)
                    } else {
                        // Not the camera (the temporary file couldn't be written, or another local error): ends the run.
                        countPendingCopyFailures(&pending, run: run)
                        run.fileFailed(name, "\(error)")
                        meter.files(run.copied + run.failed, run.subtitle)
                        return "GetObject \(name) failed: \(error) [\(lifecycle.stateDescription)]"
                    }
                }
            }
            guard let cut = interruption else { continue }

            // Session-level: the file in flight, and those whose non-OK answer isn't counted yet, are tried again.
            let failedAt = clock.now
            // A Stop or expiry that came during the GetObject or the wait: no recovery is started or counted, and the
            // non-OK answers held so far count as failed, as on a Stop at the top of the loop.
            if shouldStop() {
                if continued.expired {
                    // Build 14: a pause: the held files, the file in flight (when there is one) and the rest go back.
                    copyLeft = pending.map { queue[$0.position] } + Array(queue[position...])
                } else {
                    countPendingCopyFailures(&pending, run: run)
                }
                meter.files(run.copied + run.failed, run.subtitle)
                if let back = resumed {
                    measureCopyRecovery(run, seconds: (failedAt - back.failedAt).inSeconds, cause: back.cause, steps: back.steps,
                                        until: "the copy stopping before the next file")
                }
                return "\(copyStopWhy()) after \(run.copied + run.failed) of \(run.total) (with \(cut.cause)) [\(lifecycle.stateDescription)]"
            }
            // A recovery that brought the session back, with no file started since: measured up to this interruption.
            if let back = resumed {
                resumed = nil
                measureCopyRecovery(run, seconds: (failedAt - back.failedAt).inSeconds, cause: back.cause, steps: back.steps,
                                    until: "the next interruption, before any file started (\(cut.cause))")
            }
            let held = pending
            let heldPositions = Set(held.map { $0.position })
            for i in 0..<position where !heldPositions.contains(i) { done.append(queue[i]) }
            // Still to copy, in order: the held files, then the file in flight (when there is one) and the rest.
            var again = held.map { queue[$0.position] }
            if position < queue.count { again += queue[position...] }
            let retried = held.count + (cut.inFlight ? 1 : 0)
            pending = []
            inARow = 0
            guard recoveries - recoveriesBefore < Self.copyRecoveryLimit else {
                log.error("Copy all RAW: \(cut.cause); \(recoveries - recoveriesBefore) recoveries already made \(recoveriesBefore > 0 ? "since the copy continued" : "in this copy"), so the copy gives up [\(lifecycle.stateDescription)]")
                copySessionLost = true
                return "gave up after \(recoveries) recoveries: \(cut.cause) [\(lifecycle.stateDescription)]"
            }
            recoveries += 1
            run.recoveryStarted(cut.cause)
            meter.files(run.copied + run.failed, "recovering · \(run.subtitle)")
            log.warn("Copy all RAW: recovery \(recoveries) (\(recoveries - recoveriesBefore) of at most \(Self.copyRecoveryLimit) \(recoveriesBefore > 0 ? "since the copy continued" : "in this copy")): \(cut.cause); \(retried) file(s) to try again, \(again.count) in all still to copy [\(lifecycle.stateDescription)]")
            let steps = CopyRecoverySteps(log: log, number: recoveries, meter: meter)
            // Build 14: an expiry while this runs cuts the client off (runCopy's onExpire), so the recovery stops at once.
            copyRecovering = true
            let outcome = await recoverCopy(c, interruption: cut, steps: steps, addsBefore: addsBefore, target: target, net: net,
                                            recovery: recovery, shouldStop: shouldStop)
            copyRecovering = false
            switch outcome {
            case .resumed(let client, let stepsText):
                c = client
                let remap = remapForCopy(again, done: done)
                for missing in remap.missing {
                    run.fileFailed(missing, "not in the camera's listing after the recovery (no ARW of that name and size)")
                }
                // Put back by this recovery: one refused again with a per-file answer counts as failed at once.
                for o in again.prefix(retried) { retriedKeys.insert(Self.copyKey(o)) }
                queue = remap.found
                position = 0
                // The listing was made after any store change so far.
                seenStoreChanges = storeChanges
                addsBefore = storeAdds
                log.note(String(format: "Copy all RAW: recovery %ld done %.1f s after the failure: %ld file(s) found again in the new listing (%ld under the same handle), %ld not found; the copy goes on [%@]",
                                recoveries, (clock.now - failedAt).inSeconds, remap.found.count, remap.sameHandle, remap.missing.count,
                                lifecycle.stateDescription))
                meter.files(run.copied + run.failed, run.subtitle)
                resumed = (failedAt: failedAt, cause: cut.cause, steps: stepsText)
                // Once the session is back, a Bluetooth link the recovery used is released.
                await releaseCopyBluetooth("the session is back", copyEnded: false)
            case .failed(let why, let stepsText):
                log.error(String(format: "Copy all RAW: recovery %ld failed %.1f s after the failure: %@ (%@)",
                                 recoveries, (clock.now - failedAt).inSeconds, why, stepsText))
                measureCopyRecovery(run, seconds: (clock.now - failedAt).inSeconds, cause: cut.cause, steps: stepsText,
                                    until: "the recovery failing (\(why))")
                if client == nil { connectionState = "not connected (the copy gave up; see the log)" }
                copySessionLost = true
                return "gave up: \(cut.cause); recovery \(recoveries) failed: \(why) [\(lifecycle.stateDescription)]"
            case .stopped(let why):
                if continued.expired {
                    // Build 14: a pause: the held files and the rest (`again`) go back into the list, uncounted.
                    copyLeft = again
                } else {
                    // As on a Stop at the top of the loop: the held non-OK answers count as failed.
                    for p in held { run.fileFailed(p.name, p.why) }
                }
                meter.files(run.copied + run.failed, run.subtitle)
                measureCopyRecovery(run, seconds: (clock.now - failedAt).inSeconds, cause: cut.cause, steps: steps.summary,
                                    until: "the copy stopping during the recovery (\(why))")
                return "\(why) during recovery \(recoveries) (\(cut.cause)) after \(run.copied + run.failed) of \(run.total) [\(lifecycle.stateDescription)]"
            }
        }
        // No later file to tell: the non-OK answers at the end of the list count as failed.
        countPendingCopyFailures(&pending, run: run)
        if let back = resumed {
            measureCopyRecovery(run, seconds: (clock.now - back.failedAt).inSeconds, cause: back.cause, steps: back.steps,
                                until: "the end of the list (no file left to copy)")
        }
        meter.files(run.copied + run.failed, run.subtitle)
        return nil
    }

    private func copyStopWhy() -> String {
        continued.expired ? "the system expired the continued task" : "Stop (or Cancel run)"
    }

    private func countPendingCopyFailures(_ pending: inout [PendingCopyFailure], run: CopyAllRun) {
        for p in pending { run.fileFailed(p.name, p.why) }
        pending = []
    }

    /// `<link>.copyAll.recovery.seconds`, one value per recovery: from the failure to the next file starting, or to
    /// the next interruption, the recovery failing, the copy stopping or the end of the list (`until` says which), with
    /// the cause and the steps in the context.
    private func measureCopyRecovery(_ run: CopyAllRun, seconds: Double, cause: String, steps: String, until: String) {
        log.measure("\(run.prefix).recovery.seconds", seconds, "s",
                    context: "\(cause); from the failure to \(until); \(steps)" + (run.conditions.map { "; \($0)" } ?? ""))
    }

    private static func copyName(_ o: CardObject) -> String {
        o.info.filename.isEmpty ? "object-\(o.handle.rawValue).ARW" : o.info.filename
    }

    /// Name (case-insensitive) and size: how a file is found again in a new listing.
    private static func copyKey(_ o: CardObject) -> String {
        "\(o.info.filename.lowercased())|\(o.info.objectCompressedSize)"
    }

    private static func storeIDs(_ ids: Set<UInt32>) -> String {
        ids.sorted().map { String(format: "0x%08X", $0) }.joined(separator: ", ")
    }

    /// Build 14: the files still to copy, found again in the new listing: the same handle with the same name and size
    /// first (handles have been stable across sessions), otherwise the first ARW of that name and size not taken yet.
    /// The files already `done` claim their matches first (and are then left out), so with two ARW of the same name
    /// and size (File Number Reset across DCIM folders) a copied one isn't fetched again in place of the other.
    /// Returns the files found, in the old order, the names not found, and how many kept their handle.
    private func remapForCopy(_ remaining: [CardObject], done: [CardObject]) -> (found: [CardObject], missing: [String], sameHandle: Int) {
        var byHandle: [UInt32: CardObject] = [:]
        var byKey: [String: [CardObject]] = [:]
        for o in copyAllObjects {
            byHandle[o.handle.rawValue] = o
            byKey[Self.copyKey(o), default: []].append(o)
        }
        var used: Set<UInt32> = []
        func match(_ o: CardObject) -> (CardObject, sameHandle: Bool)? {
            let key = Self.copyKey(o)
            if let same = byHandle[o.handle.rawValue], Self.copyKey(same) == key, !used.contains(same.handle.rawValue) {
                used.insert(same.handle.rawValue)
                return (same, sameHandle: true)
            }
            if let other = byKey[key]?.first(where: { !used.contains($0.handle.rawValue) }) {
                used.insert(other.handle.rawValue)
                return (other, sameHandle: false)
            }
            return nil
        }
        for o in done { _ = match(o) }
        var found: [CardObject] = []
        var missing: [String] = []
        var sameHandle = 0
        for o in remaining {
            if let hit = match(o) {
                found.append(hit.0)
                if hit.sameHandle { sameHandle += 1 }
            } else {
                missing.append(Self.copyName(o))
            }
        }
        return (found, missing, sameHandle)
    }

    /// Build 14: one recovery, inside the copy's continued task (so it also runs with the phone locked).
    /// a. The session is still up: up to 15 s for StoreAdded (when the card was reported gone, unless StoreAdded has
    ///    already come), then the card is listed again in the same session.
    /// b. Otherwise (or if that listing fails or finds no ARW): what is left of the session is closed, up to 30 s for
    ///    the camera's port to answer (iOS rejoins the saved network by itself, joinOnce false), then the same kind of
    ///    session is reopened (Sony's whole-card contents transfer for a whole-card copy) and the card listed.
    /// c. If the port doesn't answer and the tester allowed it: the camera's Wi-Fi switched on over Bluetooth, up to 30 s
    ///    for iOS to rejoin, one join with the details read over Bluetooth if the app is in the foreground (a join
    ///    prompt can't show in the background), then as b.
    /// Every step is logged with its time (in `steps`, which the caller keeps for the measurement), and Stop is honoured
    /// between steps. `addsBefore`: the StoreAdded count before the GetObject before the interruption started.
    private func recoverCopy(_ c: PTPIPClient, interruption: CopyInterruption, steps: CopyRecoverySteps, addsBefore: Int,
                             target: WiFiTarget?, net: String,
                             recovery: CopyAllRecovery, shouldStop: @escaping ContinuedTask.ShouldStop) async -> CopyRecoveryOutcome {
        activity = "Copy all RAW: recovering (recovery \(steps.number))"
        progress = nil
        if shouldStop() { return .stopped(copyStopWhy()) }

        // a. The session is still up.
        if client === c, await c.linkFailure == nil {
            if interruption.storeGone || !removedStores.isEmpty {
                // The card is back once no storage is reported removed and a StoreAdded has come since that GetObject
                // started: it may have come already (a StoreRemoved and StoreAdded during the GetObject, then
                // StoreNotAvailable while the camera indexes the card), so the count isn't taken here.
                let clock = ContinuousClock()
                let started = clock.now
                var outcome = "no StoreAdded within 15 s"
                while (clock.now - started).inSeconds < 15 {
                    if removedStores.isEmpty && storeAdds > addsBefore {
                        let waited = (clock.now - started).inSeconds
                        outcome = waited < 0.1 ? "StoreAdded had already come, so no wait"
                            : String(format: "StoreAdded after %.1f s", waited)
                        break
                    }
                    if shouldStop() { return .stopped(copyStopWhy()) }
                    if let failure = await c.linkFailure {
                        outcome = "the link failed while waiting (\(failure))"
                        break
                    }
                    steps.tick()
                    try? await Task.sleep(for: .milliseconds(250))
                }
                steps.add("waited for the card to come back: \(outcome)")
            }
            if shouldStop() { return .stopped(copyStopWhy()) }
            if client === c, await c.linkFailure == nil {
                do {
                    let arw = try await relistForCopy(c, net: net, poll: true, shouldStop: shouldStop)
                    if arw > 0 {
                        if !removedStores.isEmpty {
                            steps.add("no StoreAdded for \(Self.storeIDs(removedStores)), but the card lists, so it counts as back")
                            removedStores = []
                        }
                        steps.add("listed the card again in the same session: \(arw) ARW")
                        return .resumed(c, steps: steps.summary)
                    }
                    steps.add("listed the card again in the same session: no ARW")
                } catch {
                    steps.add("listing the card again in the same session failed: \(error)")
                }
            }
        } else {
            let failure = await c.linkFailure
            steps.add("the session is gone (\(failure.map { "\($0)" } ?? "the client was replaced"))")
        }
        if shouldStop() { return .stopped(copyStopWhy()) }
        guard let target else { return .failed("no camera address to reconnect to", steps: steps.summary) }

        // b. Close what is left, wait for the camera's port, reopen.
        await closeClient(closingSession: true)
        connectionState = "the copy is reconnecting to \(target.host)"
        steps.add("closed what was left of the session")
        if let after = await waitForCameraPort(host: target.host, seconds: 30, steps: steps, shouldStop: shouldStop) {
            steps.add(String(format: "%@:15740 answered after %.1f s", target.host, after))
            if let back = await reopenForCopy(target, steps: steps, shouldStop: shouldStop) { return .resumed(back, steps: steps.summary) }
            if shouldStop() { return .stopped(copyStopWhy()) }
            return .failed("the camera answered on its port, but the session couldn't be reopened and listed", steps: steps.summary)
        }
        if shouldStop() { return .stopped(copyStopWhy()) }
        steps.add("nothing answered at \(target.host):15740 within 30 s")

        // c. Bluetooth, only if the tester allowed it at the start of the copy.
        guard let handover = recovery.bluetooth else {
            return .failed("the camera's port didn't answer within 30 s, and this copy may not switch the camera's Wi-Fi on over Bluetooth",
                           steps: steps.summary)
        }
        guard target.net == "ap" else {
            return .failed("the camera's port on the home LAN didn't answer within 30 s (Bluetooth recovery is for the camera's own network only)",
                           steps: steps.summary)
        }
        guard await switchWiFiOnForCopy(handover, steps: steps, shouldStop: shouldStop) else {
            if shouldStop() { return .stopped(copyStopWhy()) }
            return .failed("the camera's Wi-Fi couldn't be switched back on over Bluetooth", steps: steps.summary)
        }
        if let after = await waitForCameraPort(host: target.host, seconds: 30, steps: steps, shouldStop: shouldStop) {
            steps.add(String(format: "the phone rejoined by itself: %@:15740 answered after %.1f s", target.host, after))
        } else if shouldStop() {
            return .stopped(copyStopWhy())
        } else if !lifecycle.isInForeground {
            return .failed("the camera's Wi-Fi is on, but the phone didn't rejoin its network within 30 s, and a join needs the app in the foreground",
                           steps: steps.summary)
        } else {
            steps.add("the phone didn't rejoin within 30 s; one join with the details read over Bluetooth (the app is in the foreground)")
            guard await joinForCopy(handover, steps: steps, shouldStop: shouldStop) else {
                if shouldStop() { return .stopped(copyStopWhy()) }
                return .failed("the join with the details read over Bluetooth didn't work", steps: steps.summary)
            }
            guard let after = await waitForCameraPort(host: target.host, seconds: 30, steps: steps, shouldStop: shouldStop) else {
                if shouldStop() { return .stopped(copyStopWhy()) }
                return .failed("nothing answered at \(target.host):15740 within 30 s of the join", steps: steps.summary)
            }
            steps.add(String(format: "%@:15740 answered %.1f s after the join", target.host, after))
        }
        if let back = await reopenForCopy(target, steps: steps, shouldStop: shouldStop) { return .resumed(back, steps: steps.summary) }
        if shouldStop() { return .stopped(copyStopWhy()) }
        return .failed("the camera's Wi-Fi came back, but the session couldn't be reopened and listed", steps: steps.summary)
    }

    /// TCP connects to `host`:15740 (2 s each, 1 s apart) until one answers or `seconds` pass; the seconds it took, or
    /// nil (also when the copy is stopped). Quiet: a refused or timed-out connect is the expected case here.
    private func waitForCameraPort(host: String, seconds: Double, steps: CopyRecoverySteps,
                                   shouldStop: ContinuedTask.ShouldStop) async -> Double? {
        let clock = ContinuousClock()
        let started = clock.now
        let quiet: PTPIPClient.Logger = { _, _ in }
        while (clock.now - started).inSeconds < seconds {
            if shouldStop() { return nil }
            steps.tick()
            if (try? await PTPIPClient.probePort(host: host, timeout: 2, log: quiet)) != nil {
                return (clock.now - started).inSeconds
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    /// The card listed again for a recovery, without the enumerate measurements: a poll for handles first when `poll`
    /// (the same session, which may still be indexing the card), then List card's work. Returns the ARW listed.
    /// Build 14: `shouldStop` ends the poll (throwing) and is checked again before the listing.
    private func relistForCopy(_ c: PTPIPClient, net: String, poll: Bool,
                               shouldStop: ContinuedTask.ShouldStop = { false }) async throws -> Int {
        if poll, let mode = contentsMode {
            let clock = ContinuousClock()
            _ = try await pollForHandles(c, mode: mode, clock: clock, started: clock.now, limit: 30, shouldStop: shouldStop)
        }
        if shouldStop() { throw WiFiLabError.message("the copy stopped (Stop, or iOS ended the continued task) before the listing") }
        try await listObjects(c, net: net, record: false)
        return copyAllObjects.count
    }

    /// Recovery b's reopen: the same kind of session as before (reopen: Sony's whole-card contents transfer for a
    /// whole-card copy, with its poll for handles), then the card listed. Nil when either fails, no ARW is listed or
    /// the copy is stopped. The recovery has already closed the client, so connectFresh's protection (a 500 ms pause,
    /// and one retry of a refused connection after 1 s, for a camera that may briefly refuse a new connection straight
    /// after the old session closes; `unverified` on the α7C II) doesn't apply there: it is applied here.
    private func reopenForCopy(_ target: WiFiTarget, steps: CopyRecoverySteps, shouldStop: ContinuedTask.ShouldStop) async -> PTPIPClient? {
        try? await Task.sleep(for: .milliseconds(500))
        var opened: PTPIPClient?
        for attempt in 1 ... 2 {
            if shouldStop() { return nil }
            do {
                opened = try await reopen(target, shouldStop: shouldStop)
                break
            } catch {
                guard attempt == 1 else {
                    steps.add("reopening the session failed again: \(error)")
                    return nil
                }
                // A failed connect or session set-up has closed the client, so the second attempt starts from none (a
                // failed poll for handles leaves it open, and then connectFresh's own pause and retry apply).
                steps.add("reopening the session failed: \(error); trying once more in 1 s")
                if shouldStop() { return nil }
                try? await Task.sleep(for: .seconds(1))
                let quiet: PTPIPClient.Logger = { _, _ in }
                guard (try? await PTPIPClient.probePort(host: target.host, timeout: 2, log: quiet)) != nil else {
                    steps.add("\(target.host):15740 no longer answers, so the session isn't reopened again")
                    return nil
                }
            }
        }
        guard let c = opened else { return nil }
        steps.add("reopened the session (\(sessionKind))")
        if shouldStop() { return nil }
        do {
            let arw = try await relistForCopy(c, net: target.net, poll: false, shouldStop: shouldStop)
            guard arw > 0 else {
                steps.add("listed the card again: no ARW")
                return nil
            }
            steps.add("listed the card again: \(arw) ARW")
            return c
        } catch {
            steps.add("listing the card again failed: \(error)")
            return nil
        }
    }

    /// Recovery c: the camera's Wi-Fi switched on over Bluetooth, as the guided runs do it (joinCameraOverBluetooth):
    /// connect, discover, a CC09 read; unless that already reports status 2, Sony's five notifications on, then
    /// switchWiFiOn (the one write, CC08 = 01, allowed by the tester at the start of the copy) until status 2. The link
    /// is held in `copyBluetooth` from the start, so releaseCopyBluetooth turns the notifications off and disconnects
    /// once the session is back or the copy ends. True when the camera reports its Wi-Fi on. Stop and Cancel run are
    /// checked after each Bluetooth step: after one, the notifications aren't turned on and CC08 isn't written.
    private func switchWiFiOnForCopy(_ h: SonyWiFiHandover, steps: CopyRecoverySteps, shouldStop: ContinuedTask.ShouldStop) async -> Bool {
        let clock = ContinuousClock()
        let started = clock.now
        while h.busy && (clock.now - started).inSeconds < 30 {
            if shouldStop() { return false }
            steps.tick()
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !h.busy else {
            steps.add("Bluetooth: another Bluetooth operation was still running after 30 s")
            return false
        }
        let ownLink = !h.isConnected
        let notifyingBefore = h.notifyingCount
        copyBluetooth = CopyBluetoothHold(handover: h, ownLink: ownLink, subscribedHere: false, notifyingBefore: notifyingBefore)
        do {
            _ = try await h.connect()
            if shouldStop() { return false }
            _ = try await h.discover(record: nil)
            if shouldStop() { return false }
            steps.add(ownLink ? "Bluetooth: connected to the camera and listed its services" : "Bluetooth: using the link already up")
            let status = try await h.readWiFiStatus("before the copy's recovery switches the camera's Wi-Fi on")
            if status == 2 {
                steps.add("the camera already reports its Wi-Fi on (CC09 status 2), so nothing is written")
                return true
            }
            // A stopped copy never turns the notifications on.
            if shouldStop() { return false }
            copyBluetooth = CopyBluetoothHold(handover: h, ownLink: ownLink, subscribedHere: true, notifyingBefore: notifyingBefore)
            let codes = try await h.subscribe(SonyWiFiHandover.sonyNotificationCodes, attempt: "Copy all RAW recovery")
            copyBluetooth = CopyBluetoothHold(handover: h, ownLink: ownLink, subscribedHere: true, notifyingBefore: notifyingBefore,
                                              turnedOn: codes)
            steps.add("Sony's notifications on: \(codes.isEmpty ? "none" : codes.joined(separator: ", "))")
            // The last point before the one write (CC08 = 01).
            if shouldStop() {
                steps.add("stopped before CC08 was written")
                return false
            }
            let on = try await h.switchWiFiOn(timeout: 30, attempt: "Copy all RAW recovery")
            steps.add("CC08 = 01 written; \(on ? "the camera reports its Wi-Fi on (status 2)" : "no status 2 within 30 s") [\(h.lastStatusSequence)]")
            return on
        } catch {
            steps.add("Bluetooth: \(SonyWiFiHandover.errorName(error))")
            return false
        }
    }

    /// Recovery c's one join (foreground only): the network name and password read over Bluetooth, joined as the
    /// Bluetooth handover joins (joinHandover: never logged or stored), waiting up to 90 s for it to finish. A stopped
    /// copy never asks iOS to join, and stops waiting.
    private func joinForCopy(_ h: SonyWiFiHandover, steps: CopyRecoverySteps, shouldStop: ContinuedTask.ShouldStop) async -> Bool {
        if shouldStop() { return false }
        guard h.isConnected, !h.busy else {
            steps.add("no Bluetooth link to read the network details over")
            return false
        }
        do {
            // The network name and password: only in this scope.
            let details = try await h.readCredentials(record: nil)
            guard !details.ssid.isEmpty, HandoverCredentials.isValidPassphrase(details.passphrase) else {
                steps.add("the network details read over Bluetooth aren't usable (\(details.description))")
                return false
            }
            steps.add("network details read over Bluetooth (\(details.description))")
            if shouldStop() { return false }
            joinHandover(ssid: details.ssid, passphrase: details.passphrase, source: "Copy all RAW recovery")
        } catch {
            steps.add("reading the network details over Bluetooth failed: \(SonyWiFiHandover.errorName(error))")
            return false
        }
        let clock = ContinuousClock()
        let started = clock.now
        while joining && (clock.now - started).inSeconds < 90 {
            if shouldStop() { break }
            steps.tick()
            try? await Task.sleep(for: .milliseconds(250))
        }
        if shouldStop() {
            steps.add("stopped during the join")
            return false
        }
        guard let already = lastJoinAlreadyAssociated else {
            steps.add(joining ? "the join didn't finish within 90 s" : "the join failed (see the log)")
            return false
        }
        steps.add(already ? "the join found the phone already on the camera's network" : "joined the camera's network")
        return true
    }

    /// The end of a recovery's Bluetooth use: on a link the copy connected, every notification off (waiting for the
    /// camera) and Bluetooth disconnected; on a link the Bluetooth tab or the guided run holds, the notifications the
    /// copy turned on are turned off only if none were on before (turning off is all or nothing), and the link stays.
    /// If the camera has dropped the link with notification switches this app turned on still set at the camera (a
    /// bonded camera keeps them for the next link), they are cleared over one more connect once the copy has ended
    /// (`copyEnded`); in the middle of the copy the hold is kept until then, so the resumed copy isn't held up.
    private func releaseCopyBluetooth(_ why: String, copyEnded: Bool) async {
        guard let hold = copyBluetooth else { return }
        let h = hold.handover
        if (hold.ownLink || hold.subscribedHere) && !h.isConnected && !h.busy && !h.earlierLinkCodes.isEmpty {
            let codes = h.earlierLinkCodes.joined(separator: ", ")
            guard copyEnded else {
                log.note("Copy all RAW: the camera dropped the Bluetooth link the recovery used, with notifications this app turned on (\(codes)) still set at the camera; they are turned off over one more connect when the copy ends (\(why))")
                return
            }
            copyBluetooth = nil
            await clearCopyNotificationsOverNewLink(h, codes: codes, why: why)
            return
        }
        copyBluetooth = nil
        if hold.ownLink {
            guard h.isConnected || h.busy else {
                log.note("Copy all RAW: the Bluetooth link the recovery used is already down, with nothing this app turned on left set at the camera (\(why))")
                return
            }
            if continued.expired {
                // No time to wait for the camera's answers: Disconnect turns off what is on over this link at once.
                h.disconnect()
                log.note("Copy all RAW: Bluetooth disconnected without waiting for the camera's answers, the continued task having expired (\(why))")
                return
            }
            if h.isConnected && !h.busy && (h.notifyingCount > 0 || !h.earlierLinkCodes.isEmpty) {
                do {
                    let left = try await h.unsubscribeAll()
                    log.note("Copy all RAW: Bluetooth notifications off: \(left.isEmpty ? "all confirmed" : "not confirmed: \(left.joined(separator: ", "))")")
                } catch {
                    log.warn("Copy all RAW: turning the Bluetooth notifications off didn't finish (\(SonyWiFiHandover.errorName(error))); Disconnect turns any left off without waiting")
                }
            }
            h.disconnect()
            log.note("Copy all RAW: Bluetooth disconnected (\(why))")
        } else if hold.subscribedHere && hold.notifyingBefore == 0 && h.isConnected && !h.busy {
            do {
                let left = try await h.unsubscribeAll()
                log.note("Copy all RAW: Bluetooth notifications the recovery turned on are off (\(left.isEmpty ? "all confirmed" : "not confirmed: \(left.joined(separator: ", "))")); the link stays up for the Bluetooth tab or the guided run (\(why))")
            } catch {
                log.warn("Copy all RAW: turning the Bluetooth notifications off didn't finish (\(SonyWiFiHandover.errorName(error))); Disconnect on the Bluetooth tab turns them off")
            }
        } else if hold.subscribedHere && (h.isConnected || h.busy) {
            let codes = hold.turnedOn.isEmpty ? SonyWiFiHandover.sonyNotificationCodes.joined(separator: ", ")
                : hold.turnedOn.joined(separator: ", ")
            let reason = h.busy ? "the link is busy" : "some were already on before, and turning off is all or nothing"
            log.warn("Copy all RAW: notifications the recovery turned on (\(codes)) stay on over the link the Bluetooth tab or the guided run holds (\(reason)) (\(why)); Disconnect on the Bluetooth tab, or the end of the guided run that holds the link, turns them off")
        } else if hold.subscribedHere {
            log.note("Copy all RAW: the Bluetooth link the recovery used is down, with nothing this app turned on left set at the camera (\(why))")
        } else {
            log.note("Copy all RAW: the Bluetooth link the recovery used belongs to the Bluetooth tab or the guided run and stays up with its notifications (\(why)); the recovery turned none on")
        }
    }

    /// One more connect to a camera that dropped the link with notification switches this app turned on still set, as
    /// ble.auto does at its end: unsubscribeAll turns each on and off again over the new link (descriptor writes inside
    /// 8000CC00 only, no value written), then Bluetooth is disconnected (the connect is the copy's own).
    private func clearCopyNotificationsOverNewLink(_ h: SonyWiFiHandover, codes: String, why: String) async {
        guard !continued.expired else {
            log.warn("Copy all RAW: notifications this app turned on (\(codes)) are still set at the camera, which dropped the Bluetooth link; the continued task has expired, so they aren't turned off now: Connect and then Disconnect on the Bluetooth tab turns them off (\(why))")
            return
        }
        log.note("Copy all RAW: the camera dropped the Bluetooth link the recovery used, with notifications this app turned on (\(codes)) still set; connecting once more to turn them off (\(why))")
        do {
            _ = try await h.connect(timeout: 8)
            let left = try await h.unsubscribeAll()
            h.disconnect()
            if left.isEmpty {
                log.note("Copy all RAW: the notifications left from the dropped link are off, confirmed by the camera; Bluetooth disconnected (\(why))")
            } else {
                log.warn("Copy all RAW: notifications not confirmed off: \(left.joined(separator: ", ")); Bluetooth disconnected (\(why))")
            }
        } catch {
            let still = h.earlierLinkCodes.isEmpty ? codes : h.earlierLinkCodes.joined(separator: ", ")
            if h.isConnected || h.busy {
                // The connect is the copy's own. Disconnect turns off at once what is on over this link and warns about
                // any left from the dropped one.
                h.disconnect()
                log.warn("Copy all RAW: turning off the notifications left from the dropped link didn't finish (\(SonyWiFiHandover.errorName(error))); Bluetooth disconnected; the camera may keep \(still) on for this phone (\(why))")
            } else {
                log.warn("Copy all RAW: couldn't connect to the camera to turn off the notifications left from the dropped link (\(SonyWiFiHandover.errorName(error))); still set at the camera: \(still); Connect and then Disconnect on the Bluetooth tab turns them off (\(why))")
            }
        }
    }

    // MARK: Battery

    private func readBattery(_ c: PTPIPClient) async -> Int? {
        guard !batteryUnsupported else { return nil }
        // Only ask when DeviceInfo lists BatteryLevel. A Sony PC Remote or contents-transfer session lists no device
        // properties and never answers GetDevicePropValue: on 2 Nov the camera stayed silent for 30 s, the idle
        // timeout ended the connection, and the 20-ARW download never started. (Battery per GB is out of 1.0.)
        guard deviceInfo?.devicePropertiesSupported.contains(0x5001) == true else {
            batteryUnsupported = true
            log.note("BatteryLevel (0x5001) isn't in this session's DeviceInfo, so the battery isn't read (the camera wouldn't answer)")
            return nil
        }
        do {
            let raw = try await c.getDevicePropValue(0x5001)
            guard let first = raw.first else {
                log.warn("BatteryLevel (0x5001): empty value")
                return nil
            }
            if raw.count != 1 { log.note("BatteryLevel (0x5001) raw \(raw.hexDump()): expected one UINT8; using the first byte") }
            return Int(first)
        } catch PTPIPClient.ClientError.response(_, let code) {
            batteryUnsupported = true
            log.warn("GetDevicePropValue BatteryLevel (0x5001): \(code); battery per GB can't be measured this way on this mode")
            return nil
        } catch {
            log.warn("battery read failed: \(error)")
            return nil
        }
    }

    private func batteryBeforeDownload(_ c: PTPIPClient, prefix: String) async {
        guard batteryWindow == nil else { return }
        guard let level = await readBattery(c) else { return }
        batteryWindow = BatteryWindow(prefix: prefix, startPercent: level, startedAt: Date(), bytes: 0)
        batteryLine = "\(level) % at the start of the 1 GB window"
        log.note("battery window opened at \(level) % (BatteryLevel 0x5001); \(prefix).battery.per1GB is recorded once ≥ 1 GB has downloaded")
    }

    private func batteryAfterDownload(_ c: PTPIPClient, bytes: UInt64, prefix: String) async {
        guard var window = batteryWindow, window.prefix == prefix else { return }
        window.bytes += bytes
        batteryWindow = window
        guard let level = await readBattery(c) else { return }
        let gigabytes = Double(window.bytes) / 1e9
        let minutes = Date().timeIntervalSince(window.startedAt) / 60
        batteryLine = String(format: "%ld %% → %ld %% over %.2f GB", window.startPercent, level, gigabytes)
        if window.bytes >= 1_000_000_000 {
            let used = Double(window.startPercent - level)
            log.measure("\(prefix).battery.per1GB", used / gigabytes, "%/GB",
                        context: String(format: "%ld %% → %ld %% over %.2f GB in %.0f min (BatteryLevel 0x5001; includes idle drain between batches)",
                                        window.startPercent, level, gigabytes, minutes))
            batteryWindow = nil
        } else {
            log.note(String(format: "battery %ld %% → %ld %% after %.2f GB; the window needs ≥ 1 GB", window.startPercent, level, gigabytes))
        }
    }

    // MARK: Shutter test

    /// Waits for ObjectAdded while the user presses the shutter; records a "no" if none arrives.
    func shutterTest(seconds: Double = 20) {
        runSession("Shutter test") { c, net in
            let before = self.objectAddedCount
            self.log.note("Shutter test: press the shutter now; waiting \(Int(seconds)) s for ObjectAdded (0x4002) or Sony ObjectAdded (0xC201)")
            let clock = ContinuousClock()
            let started = clock.now
            var lastTransaction = started
            while (clock.now - started).inSeconds < seconds, self.objectAddedCount == before {
                self.progress = (clock.now - started).inSeconds / seconds
                if (clock.now - lastTransaction).inSeconds >= 10 {
                    // The keep-alive skips busy operations, and the camera drops a session idle for about 30 s. This
                    // also reads any event queued on the command channel. A non-OK reply (DeviceBusy while the
                    // camera writes the frame) is noted, not fatal: the test still records yes or no.
                    do { _ = try await c.getDeviceInfo() } catch PTPIPClient.ClientError.response(_, let code) {
                        self.log.note("Shutter test: GetDeviceInfo \(WirelessLab.codeText(code))")
                    }
                    lastTransaction = clock.now
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            if self.objectAddedCount == before {
                // Events sent on the command channel are only read during a transaction: run one to drain it.
                // GetDeviceInfo, since GetStorageIDs answers 0x2013 on a PC Remote session.
                do { _ = try await c.getDeviceInfo() } catch PTPIPClient.ClientError.response(_, let code) {
                    self.log.note("Shutter test: GetDeviceInfo \(WirelessLab.codeText(code))")
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            if self.objectAddedCount > before {
                self.log.note("Shutter test: \(self.objectAddedCount - before) ObjectAdded event(s) arrived")
            } else if self.log.measurements.contains(where: { $0.name == "ptpip.\(net).event.objectAdded" && $0.value == 1 }) {
                // A "yes" is already recorded for this column (ObjectAdded is a property of the camera mode, not
                // of one session); don't contradict it.
                self.log.note("Shutter test: no new ObjectAdded within \(Int(seconds)) s, but one arrived earlier on \(net); not recording a no")
            } else {
                self.log.flag("ptpip.\(net).event.objectAdded", false,
                              context: "none within \(Int(seconds)) s of the shutter test; \(self.eventCount) other event(s) this session; session: \(self.sessionKind)")
            }
        }
    }

    // MARK: Day 9 · Resume

    func referenceHash() {
        runSession("Reference hash", needsListing: true) { c, _ in
            guard let o = self.newest(ext: "ARW", count: 1).first else { throw WiFiLabError.message("no ARW listed; tap List card first") }
            self.log.note("Reference hash: GetObject \(o.info.filename) (\(o.info.objectCompressedSize) bytes)…")
            let r = try await self.downloadReference(c, object: o)
            let identity = o.info.identity(cameraSerial: self.cameraSerial)
            if !WiFiResumeStore.saveReference(WiFiReferenceHash(identity: identity, sha256: r.sha256, bytes: r.bytes, savedAt: Date())) {
                self.log.error("could not save the reference hash")
            }
            self.log.note(String(format: "Reference SHA-256 of %@: %@ (%llu bytes, %.1f MB/s)", o.info.filename, r.sha256, r.bytes,
                                 r.seconds > 0 ? Double(r.bytes) / r.seconds / 1e6 : 0))
            FixtureStore.saveText("\(r.sha256)  \(o.info.filename)  \(r.bytes) bytes  GetObject over PTP/IP\n",
                                  link: .ptpip, name: "getobject.sha256", log: self.log)
        }
    }

    /// GetObject of `o` into a kept temporary file (replacing the previous copy), which the partial read probe can
    /// reuse in the same session. Throws, and keeps nothing, if the size is off: a truncated or padded reference
    /// would later make resume.verified or a probe match a false "no".
    private func downloadReference(_ c: PTPIPClient, object o: CardObject) async throws -> PTPIPClient.FileDownload {
        discardReferenceCopy()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptpip-reference", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = o.info.filename.isEmpty ? "object-\(o.handle.rawValue)" : WiFiResumeStore.safeComponent(o.info.filename)
        let url = dir.appendingPathComponent(name, isDirectory: false)
        let r: PTPIPClient.FileDownload
        do {
            r = try await c.getObject(o.handle, to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        let expected = UInt64(o.info.objectCompressedSize)
        guard r.bytes == expected, r.announcedLength.map({ $0 == r.bytes }) ?? true else {
            try? FileManager.default.removeItem(at: url)
            throw WiFiLabError.message("GetObject returned \(r.bytes) bytes (Start_Data announced \(r.announcedLength.map { String($0) } ?? "unknown"), ObjectInfo says \(expected)); reference not kept, try again")
        }
        referenceCopy = ReferenceCopy(client: c, handle: o.handle, size: r.bytes, url: url, sha256: r.sha256)
        return r
    }

    private func discardReferenceCopy() {
        if let copy = referenceCopy { try? FileManager.default.removeItem(at: copy.url) }
        referenceCopy = nil
    }

    /// The Wi-Fi tab's line about the remembered probe result for `net` in the current kind of session.
    func partialProbeLabel(net: String) -> String {
        _ = partialProbeRuns
        let session = partialProbeSession
        return PartialReadProbe.remembered(net: net, session: session).label + " (\(session) session)"
    }

    // MARK: Day 9 · Partial read probe

    /// Which byte-range layout does the camera answer correctly? On 2 Nov (build 9.1, whole-card contents transfer)
    /// GetObject worked on the newest ARW but GetPartialObject 0x101B with three parameters answered
    /// InvalidObjectHandle. This takes a GetObject reference of the newest ARW, then asks for [0, 1 MiB) with each
    /// layout in PTPPartialRead.probeOrder whose operation DeviceInfo lists (15 s idle timeout; no answer means a
    /// reconnect and the next layout), compares each answer's SHA-256 with the reference's, and, when it matches, reads
    /// one middle chunk with that layout too, so a layout that ignores the offset can't pass. Each layout's
    /// `ptpip.<net>.partial.<variant>` is recorded as soon as it is known, and the first working layout is remembered
    /// for the net and kind of session (PartialReadProbe) with `ptpip.<net>.getPartialObject.supported` before the
    /// remaining layouts are sent, so a later one that wedges the camera can't lose it. If reconnecting fails, the
    /// probe stops and keeps what it has. A reconnect empties the card listing, so the card is listed again at the end.
    func probePartialReads() {
        runSession("Partial read probe", needsListing: true) { c, net in
            try await self.runPartialProbe(c, net: net)
        }
    }

    private func runPartialProbe(_ start: PTPIPClient, net: String) async throws {
        let prefix = "ptpip.\(net)"
        guard let o = newest(ext: "ARW", count: 1).first else { throw WiFiLabError.message("no ARW listed; tap List card first") }
        guard o.info.objectCompressedSize > 0, o.info.objectCompressedSize != UInt32.max else {
            throw WiFiLabError.message("\(o.info.filename): size unknown in ObjectInfo")
        }
        let size = UInt64(o.info.objectCompressedSize)
        let serial = cameraSerial
        let identity = o.info.identity(cameraSerial: serial)
        let name = o.info.filename
        var c = start
        var handle = o.handle
        let probeLength = UInt64(PartialReadProbe.chunkLength)
        let firstChunk = PTPPartialRead.Chunk(offset: 0, length: UInt32(min(probeLength, size)))
        // Half way, rounded down to 4 KiB.
        let middleOffset = (size / 2) & ~UInt64(4095)
        let middleChunk = PTPPartialRead.Chunk(offset: middleOffset, length: UInt32(min(probeLength, size - middleOffset)))
        let orderText = PTPPartialRead.probeOrder.map { $0.rawValue }.joined(separator: ", ")
        log.note("Partial read probe: \(name), \(size) bytes, handle \(handle), on \(sessionKind); chunks \(firstChunk) and \(middleChunk); layouts in order: \(orderText)")

        // The reference: this session's Reference hash download when it is the same object, else a GetObject now.
        activity = "Partial read probe: GetObject reference"
        let referenceURL: URL
        if let copy = referenceCopy, copy.client === c, copy.handle.rawValue == o.handle.rawValue, copy.size == size,
           WiFiPartFile.size(copy.url) == size {
            referenceURL = copy.url
            log.note("Partial read probe: reusing this session's GetObject of \(name) as the reference (SHA-256 \(String(copy.sha256.prefix(16)))…)")
        } else {
            let r = try await downloadReference(c, object: o)
            guard let copy = referenceCopy else { throw WiFiLabError.message("the reference download wasn't kept") }
            referenceURL = copy.url
            log.note(String(format: "Partial read probe: reference GetObject of %@, %llu bytes in %.2f s (%.1f MB/s), SHA-256 %@…",
                            name, r.bytes, r.seconds, r.seconds > 0 ? Double(r.bytes) / r.seconds / 1e6 : 0, String(r.sha256.prefix(16))))
            if !WiFiResumeStore.saveReference(WiFiReferenceHash(identity: identity, sha256: r.sha256, bytes: r.bytes, savedAt: Date())) {
                log.error("could not save the reference hash")
            }
        }
        // Read into memory now: a reconnect below discards the kept copy with the old session.
        let referenceFirst = try Self.readBytes(referenceURL, offset: firstChunk.offset, count: Int(firstChunk.length))
        let referenceMiddle = try Self.readBytes(referenceURL, offset: middleChunk.offset, count: Int(middleChunk.length))
        log.note("Partial read probe: reference SHA-256 of \(firstChunk) \(String(PTPIPClient.sha256(of: referenceFirst).prefix(16)))…, of \(middleChunk) \(String(PTPIPClient.sha256(of: referenceMiddle).prefix(16)))…")

        // Captured now: a failed reconnect clears contentsMode with the client.
        let kind = sessionKind
        let session = partialProbeSession
        let key = PartialReadProbe.key(net: net, session: session)
        var outcomes: [ProbeOutcome] = []
        var working: PTPPartialRead.Variant?
        // Set when reconnecting after a request with no answer failed: no more layouts are sent.
        var stopped: String?
        let order = PTPPartialRead.probeOrder
        for (i, variant) in order.enumerated() {
            let op = PTPPartialRead.operationCode(for: variant)
            let opText = String(format: "0x%04X ", op.rawValue) + op.description
            guard deviceInfo?.supports(op) == true else {
                log.note("Partial read probe · \(variant.rawValue): DeviceInfo doesn't list \(opText); not sent")
                continue
            }
            activity = "Partial read probe: \(variant.rawValue) (\(i + 1) of \(order.count))"
            progress = Double(i) / Double(order.count)
            // Overwritten when probeRequest returns; it throws only when reconnecting after no answer failed.
            var outcome = ProbeOutcome(variant: variant, operation: opText, first: "no answer, then reconnecting failed")
            do {
                let answer = try await probeRequest(&c, handle: &handle, chunk: firstChunk, variant: variant, opText: opText,
                                                    identity: identity, serial: serial, net: net)
                outcome.first = answer.result
                if let data = answer.data {
                    outcome.firstBytes = data.count
                    outcome.firstMatches = Self.matches(data, reference: referenceFirst)
                }
                // The middle chunk with every layout whose first chunk matched.
                if outcome.firstMatches {
                    activity = "Partial read probe: middle chunk with \(variant.rawValue)"
                    outcome.middle = "no answer, then reconnecting failed"
                    outcome.middleMatches = false
                    let middle = try await probeRequest(&c, handle: &handle, chunk: middleChunk, variant: variant, opText: opText,
                                                        identity: identity, serial: serial, net: net)
                    outcome.middle = middle.result
                    outcome.middleBytes = middle.data?.count
                    outcome.middleMatches = middle.data.map { Self.matches($0, reference: referenceMiddle) } ?? false
                }
            } catch {
                stopped = "\(variant.rawValue): \(error)"
                log.warn("Partial read probe stopped at \(variant.rawValue): reconnecting after no answer failed (\(error)); the results so far are kept and the remaining layouts aren't sent")
            }
            log.note("Partial read probe · \(outcome.summary)")
            outcomes.append(outcome)
            // Recorded now, so a later layout that wedges the camera can't lose it. Yes: both chunks matched the reference.
            log.flag("\(prefix).partial.\(variant.rawValue)", outcome.works, context: "\(outcome.summary); \(name), \(kind)")
            if outcome.works, working == nil {
                working = variant
                PartialReadProbe.remember(variant, net: net, session: session)
                partialSupportFlagged.insert(prefix)
                log.flag("\(prefix).getPartialObject.supported", true,
                         context: "\(variant.rawValue) (\(op)); partial read probe on \(name), \(kind)")
                partialProbeRuns += 1
                log.note("Partial read probe: \(variant.rawValue) works, remembered as \(key) before any further layout is sent")
            }
            if stopped != nil { break }
        }

        if working == nil {
            if let stopped {
                // Not every listed layout was sent, so "none works" would be a guess: back to not probed.
                PartialReadProbe.forget(net: net, session: session)
                log.warn("Partial read probe: stopped (\(stopped)) before every listed layout was sent, and none worked; \(key) cleared (not probed), getPartialObject.supported not recorded")
            } else {
                let listed = outcomes.isEmpty ? "DeviceInfo lists none of the layouts' operations" : "\(outcomes.count) layout(s) sent"
                partialSupportFlagged.insert(prefix)
                log.flag("\(prefix).getPartialObject.supported", false, context: "none; \(listed); partial read probe on \(name), \(kind)")
                PartialReadProbe.remember(nil, net: net, session: session)
            }
        }
        partialProbeRuns += 1
        let lines = outcomes.map { x -> String in
            let first = x.firstBytes.map { "\(x.first) \($0) B \(x.firstMatches ? "match" : "no match")" } ?? x.first
            let middle = x.middle.map { m in x.middleBytes.map { "\(m) \($0) B \(x.middleMatches == true ? "match" : "no match")" } ?? m }
            return "\(x.variant.rawValue) \(first)" + (middle.map { ", middle \($0)" } ?? "")
        }
        log.note("Partial read probe on \(net): " + (lines.isEmpty ? "nothing sent" : lines.joined(separator: "; ")) +
                 "; working: \(working?.rawValue ?? "none")" + (stopped == nil ? "" : " (stopped early)") + " (\(key))")

        // Every reconnect above starts a session with an empty listing: list the card again so Reference hash,
        // Start resumable read and the guided resume find the newest ARW (with this session's handles).
        if objects.isEmpty, client === c {
            let healthy = await c.linkFailure == nil
            if healthy {
                log.note("Partial read probe: a reconnect emptied the card listing; listing the card again")
                activity = "Partial read probe: listing the card again"
                do {
                    try await listObjects(c, net: net)
                } catch {
                    log.warn("Partial read probe: listing the card again failed (\(error)); tap List card")
                }
            }
        }
    }

    /// One probe request with the probe's idle timeout. A response code is an answer; a link failure (no answer
    /// within the timeout, or a reply that poisoned the channel) is logged, the session is reopened the way
    /// runSession reopens it, the object is found again by identity (`c` and `handle` updated), and the probe goes on.
    /// It throws only when reconnecting or finding the object fails. The new session starts with an empty listing;
    /// runPartialProbe lists the card again at the end.
    private func probeRequest(_ c: inout PTPIPClient, handle: inout PTPObjectHandle, chunk: PTPPartialRead.Chunk,
                              variant: PTPPartialRead.Variant, opText: String, identity: PTPObjectIdentity,
                              serial: String, net: String) async throws -> (result: String, data: Data?) {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let data = try await c.getPartialObject(handle, chunk: chunk, variant: variant, idleTimeout: PartialReadProbe.idleTimeout)
            log.note(String(format: "Partial read probe · %@ %@: OK, %ld bytes in %.2f s", variant.rawValue, chunk.description,
                            data.count, (clock.now - started).inSeconds))
            return ("OK", data)
        } catch PTPIPClient.ClientError.response(_, let code) {
            log.note(String(format: "Partial read probe · %@ %@: %@ after %.2f s", variant.rawValue, chunk.description,
                            WirelessLab.codeText(code), (clock.now - started).inSeconds))
            return (WirelessLab.codeText(code), nil)
        } catch {
            guard let failure = await c.linkFailure else {
                // Not on the wire (the command can't be built for this chunk): no reconnect needed.
                log.warn("Partial read probe · \(variant.rawValue) \(chunk): \(error)")
                return ("failed (\(error))", nil)
            }
            log.warn(String(format: "Partial read probe · %@ (%@) %@: no usable answer after %.1f s (%@); reconnecting, then the next layout",
                            variant.rawValue, opText, chunk.description, (clock.now - started).inSeconds, "\(failure)"))
            guard let t = sessionTarget else { throw failure }
            let fresh = try await reopen(t)
            c = fresh
            guard let found = try await findObject(fresh, identity: identity, serial: serial) else {
                throw WiFiLabError.message("\(identity.filename) not found on the card after reconnecting; probe stopped")
            }
            if found.handle.rawValue != handle.rawValue {
                log.warn("Partial read probe: \(identity.filename) is handle \(found.handle) on the new session (was \(handle))")
            }
            handle = found.handle
            return ("no answer (\(failure))", nil)
        }
    }

    /// True when `data` is non-empty, no longer than the reference, and its SHA-256 equals that of the reference's
    /// first `data.count` bytes (a short read with the right bytes counts).
    private static func matches(_ data: Data, reference: Data) -> Bool {
        guard !data.isEmpty, data.count <= reference.count else { return false }
        return PTPIPClient.sha256(of: data) == PTPIPClient.sha256(of: reference.prefix(data.count))
    }

    private static func readBytes(_ url: URL, offset: UInt64, count: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: offset)
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else {
            throw WiFiLabError.message("the reference file has \(data.count) bytes at \(offset), expected \(count)")
        }
        return data
    }

    func startResumableRead(pauseAtHalf: Bool) {
        runSession("Resumable read", transfer: true, needsListing: true) { c, net in
            guard let o = self.newest(ext: "ARW", count: 1).first, let di = self.deviceInfo else {
                throw WiFiLabError.message("no ARW listed; tap List card first")
            }
            let identity = o.info.identity(cameraSerial: self.cameraSerial)
            guard identity.size > 0, o.info.objectCompressedSize != UInt32.max else {
                throw WiFiLabError.message("\(o.info.filename): size unknown in ObjectInfo")
            }
            // The layout the partial read probe found working on this net, if it ran; else DeviceInfo's choice.
            let variant: PTPPartialRead.Variant
            let session = self.partialProbeSession
            switch PartialReadProbe.remembered(net: net, session: session) {
            case .noneWorks:
                self.log.warn("Resumable read: the partial read probe found no byte-range read that returns the right bytes on \(net) (\(PartialReadProbe.key(net: net, session: session)) = none), so byte-range reads don't work in this session: a drop means restarting \(identity.filename) from zero. Not started; tap Partial read probe to check again.")
                return
            case .works(let remembered):
                variant = remembered
                self.log.note("Resumable read: \(remembered.rawValue) (\(PTPPartialRead.operationCode(for: remembered))), the layout the partial read probe found working on \(net) in a \(session) session")
            case .notProbed:
                let listed = PTPPartialRead.variant(objectSize: identity.size, device: di)
                if listed == nil {
                    self.log.warn("DeviceInfo lists neither GetPartialObject (0x101B) nor GetPartialObject64 (0x95C1); trying 0x101B anyway")
                }
                variant = listed ?? .standard32
                self.log.note("Resumable read: no partial read probe on \(net) in a \(session) session yet, so \(variant.rawValue) from DeviceInfo (on 2 Nov the camera answered 0x101B with three parameters InvalidObjectHandle; Partial read probe tries the other layouts)")
            }
            let reference = WiFiResumeStore.loadReference().flatMap { $0.identity == identity && $0.bytes == identity.size ? $0.sha256 : nil }
            if reference == nil {
                self.log.warn("no reference hash for \(identity.filename): tap Reference hash first, or the resumed file can't be verified")
            }
            let relative = WiFiResumeStore.partRelativePath(serial: identity.cameraSerial, filename: identity.filename)
            // Only one record is kept: an earlier read of another file would otherwise leave its .part in Caches.
            if let previous = WiFiResumeStore.load(), previous.partPath != relative {
                WiFiPartFile.remove(WiFiResumeStore.url(forRelativePath: previous.partPath))
                self.log.note("discarded the earlier partial read of \(previous.identity.filename)")
            }
            WiFiPartFile.remove(WiFiResumeStore.url(forRelativePath: relative))
            let record = WiFiResumeRecord(identity: identity, offset: 0, partPath: relative, referenceSHA256: reference,
                                          variant: variant.rawValue, chunkSize: PTPPartialRead.defaultChunkSize, net: net,
                                          resumes: 0, savedAt: Date())
            guard WiFiResumeStore.save(record) else { throw WiFiLabError.message("could not save the resume record") }
            self.refreshResumeSummary()
            self.log.note("Resumable read: \(identity.filename), \(identity.size) bytes, \(variant.rawValue) in 4 MiB chunks into Caches/\(relative); " +
                          (pauseAtHalf ? "it pauses at 50 % for you to turn Wi-Fi off" : "turn Wi-Fi off at about 50 %"))
            try await self.runPartialRead(c, handle: o.handle, record: record, isResume: false, pauseAtHalf: pauseAtHalf)
        }
    }

    func resumeRead(_ t: WiFiTarget) {
        guard let saved = WiFiResumeStore.load() else {
            log.warn("Resume read: nothing saved; tap Start resumable read first")
            return
        }
        runCamera("Resume read", transferLink: "ptpip.\(saved.net)") {
            if saved.net != t.net { self.log.warn("the saved read started on \(saved.net); it stays in the ptpip.\(saved.net) column") }
            let target = WiFiTarget(net: saved.net, host: t.host, guid: t.guid)
            let how = self.contentsMode.map { "Sony contents transfer, " + $0.label } ?? "handshake + OpenSession"
            // The variant comes from the record, so the resume reads with the layout the read started with.
            self.log.note("Resume read: \(saved.summary), \(saved.variant). Reconnecting (\(how))…")
            let c = try await self.reopen(target)
            let serial = self.cameraSerial
            if serial != saved.identity.cameraSerial {
                self.log.warn("the camera's serial differs from the saved read's")
            }
            guard let found = try await self.findObject(c, identity: saved.identity, serial: serial) else {
                self.log.error("Resume read: \(saved.identity) not found on the card; the engine would restart that file from zero. The partial file is kept; Forget partial read discards it.")
                return
            }
            let current = found.info.identity(cameraSerial: serial)
            let url = WiFiResumeStore.url(forRelativePath: saved.partPath)
            var offset = PTPPartialRead.resumeOffset(savedOffset: saved.offset, saved: saved.identity, current: current)
            let onDisk = WiFiPartFile.size(url)
            if onDisk < offset {
                self.log.warn("the part file holds \(onDisk) bytes, less than the saved offset \(offset); resuming from \(onDisk)")
                offset = onDisk
            }
            self.log.note(String(format: "Resume read: found %@ as handle %@ after %ld ObjectInfo(s) in %.2f s; resuming at %llu of %llu (%.1f %%), dropping %llu byte(s) written after the last checkpoint",
                                 found.info.filename, found.handle.description, found.scanned, found.seconds, offset, current.size,
                                 Double(offset) / Double(max(current.size, 1)) * 100, onDisk > offset ? onDisk - offset : 0))
            var record = saved
            record.offset = offset
            if offset > 0 {
                record.resumes += 1
            } else {
                // A read from 0 is a full re-read, not a resume; an earlier resume must not count for it either.
                record.resumes = 0
                self.log.warn("Resume read: restarting from 0 (saved offset \(saved.offset), part file \(onDisk) bytes); this run does not exercise resume")
            }
            record.savedAt = Date()
            WiFiResumeStore.save(record)
            try await self.runPartialRead(c, handle: found.handle, record: record, isResume: true, pauseAtHalf: false)
        }
    }

    func forgetPartialRead() {
        if let saved = WiFiResumeStore.load() {
            WiFiPartFile.remove(WiFiResumeStore.url(forRelativePath: saved.partPath))
            log.note("forgot the partial read of \(saved.identity.filename)")
        }
        WiFiResumeStore.clear()
        refreshResumeSummary()
    }

    private func refreshResumeSummary() {
        resumeSummary = WiFiResumeStore.load()?.summary
    }

    /// Scans ObjectInfos newest first (highest handle first) until one has `identity`.
    private func findObject(_ c: PTPIPClient, identity: PTPObjectIdentity, serial: String) async throws -> FoundObject? {
        let clock = ContinuousClock()
        let started = clock.now
        let (ids, _) = try await c.getStorageIDs()
        var handles: [PTPObjectHandle] = []
        for id in ids where id.hasLogicalStore {
            handles.append(contentsOf: try await c.getObjectHandles(storage: id).handles)
        }
        var scanned = 0
        for handle in handles.sorted(by: { $0.rawValue > $1.rawValue }) {
            let (info, _) = try await c.getObjectInfo(handle)
            scanned += 1
            progress = Double(scanned) / Double(max(handles.count, 1))
            if info.identity(cameraSerial: serial) == identity {
                return FoundObject(handle: handle, info: info, scanned: scanned, seconds: (clock.now - started).inSeconds)
            }
        }
        return nil
    }

    /// The chunk loop shared by Start and Resume. Persists the record every 16 MiB and on error; on completion
    /// hashes the file, compares with the reference and records the day-9 results.
    private func runPartialRead(_ c: PTPIPClient, handle: PTPObjectHandle, record initial: WiFiResumeRecord,
                                isResume: Bool, pauseAtHalf: Bool) async throws {
        var record = initial
        let prefix = "ptpip.\(record.net)"
        let size = record.identity.size
        let name = record.identity.filename
        let label = isResume ? "Resume read" : "Resumable read"
        let url = WiFiResumeStore.url(forRelativePath: record.partPath)
        let file = try WiFiPartFile.open(url, at: record.offset)
        defer { try? file.close() }
        let variant = PTPPartialRead.Variant(rawValue: record.variant) ?? .standard32
        let clock = ContinuousClock()
        // Time spent on whole chunks (request, response, file write, checkpoint): the pause and a chunk cut off by
        // the link drop are excluded, as are their bytes.
        var active = Duration.zero
        var didPause = false
        let startOffset = record.offset
        var chunks = 0
        var lastDecile = Int(record.fractionDone * 10)

        do {
            while let chunk = PTPPartialRead.nextChunk(at: record.offset, objectSize: size, chunkSize: record.chunkSize) {
                let chunkStarted = clock.now
                let data: Data
                do {
                    data = try await c.getPartialObject(handle, chunk: chunk, variant: variant)
                } catch PTPIPClient.ClientError.response(let op, let code) {
                    if chunks == 0, !partialSupportFlagged.contains(prefix) {
                        partialSupportFlagged.insert(prefix)
                        log.flag("\(prefix).getPartialObject.supported", false,
                                 context: "\(op) answered \(code) to the first chunk \(chunk) of \(name)")
                    }
                    throw PTPIPClient.ClientError.response(operation: op, code: code)
                }
                // "Supported" means OK with usable bytes: an OK with no data (or more than asked) is a no.
                let usable = !data.isEmpty && data.count <= Int(chunk.length)
                if chunks == 0, !partialSupportFlagged.contains(prefix) {
                    partialSupportFlagged.insert(prefix)
                    log.flag("\(prefix).getPartialObject.supported", usable,
                             context: usable
                                ? "\(variant.rawValue) returned \(data.count) bytes for \(chunk) of \(name)"
                                : "\(variant.rawValue) answered OK but with \(data.count) bytes for the \(chunk.length)-byte request \(chunk) of \(name)")
                }
                chunks += 1
                guard !data.isEmpty else { throw WiFiLabError.message("the camera returned 0 bytes for \(chunk)") }
                guard data.count <= Int(chunk.length) else {
                    throw WiFiLabError.message("the camera returned \(data.count) bytes for a \(chunk.length)-byte request at \(chunk.offset)")
                }
                try file.write(contentsOf: data)
                let previous = record.offset
                record.offset += UInt64(data.count)
                if data.count < Int(chunk.length) {
                    log.note("short read: \(data.count) of \(chunk.length) bytes at \(chunk.offset); continuing from \(record.offset)")
                }
                if PTPPartialRead.crossesCheckpoint(from: previous, to: record.offset) {
                    try? file.synchronize()
                    record.savedAt = Date()
                    WiFiResumeStore.save(record)
                }
                let fraction = record.fractionDone
                progress = fraction
                activity = String(format: "%@ %.0f %%", label, fraction * 100)
                let decile = Int(fraction * 10)
                if decile > lastDecile {
                    lastDecile = decile
                    log.note(String(format: "%@: %.0f %% (%llu of %llu bytes)", label, fraction * 100, record.offset, size))
                }
                lifecycle.noteProgress(String(format: "%@ %.0f %%", name, fraction * 100), link: prefix)
                active += clock.now - chunkStarted
                if pauseAtHalf, !didPause, record.offset * 2 >= size, record.offset < size {
                    didPause = true
                    try? file.synchronize()
                    record.savedAt = Date()
                    WiFiResumeStore.save(record)
                    await pauseForLinkDrop(c, seconds: 30, at: fraction)
                }
            }
        } catch {
            try? file.synchronize()
            record.savedAt = Date()
            if !WiFiResumeStore.save(record) { log.error("could not save the resume record") }
            refreshResumeSummary()
            recordPartialThroughput(prefix: prefix, bytes: record.offset - startOffset, seconds: active.inSeconds,
                                    context: String(format: "%@ of %@, interrupted at %.0f %%", label, name, record.fractionDone * 100))
            let linkGone = (error as? PTPIPClient.ClientError)?.isLinkFailure ?? false
            let advice = linkGone
                ? "Saved; when Wi-Fi is back and the phone is on the camera's network, tap Resume read."
                : "Saved, but this is not a link drop, so resuming may hit the same error."
            log.error(String(format: "%@ of %@ stopped at %.1f %% (offset %llu of %llu): %@. %@",
                             label, name, record.fractionDone * 100, record.offset, size, "\(error)", advice))
            if let failure = await c.linkFailure { connectionState = "connection lost (\(failure)); Resume read reconnects" }
            return
        }

        try? file.synchronize()
        recordPartialThroughput(prefix: prefix, bytes: record.offset - startOffset, seconds: active.inSeconds,
                                context: "\(label) of \(name) to the end, \(chunks) chunk(s) from offset \(startOffset)")
        let onDisk = WiFiPartFile.size(url)
        guard onDisk == size else {
            log.error("\(name): the part file holds \(onDisk) bytes, expected \(size); record kept")
            WiFiResumeStore.save(record)
            refreshResumeSummary()
            return
        }
        let sha = try PTPIPClient.sha256(ofFile: url)
        FixtureStore.saveText("\(sha)  \(name)  \(size) bytes  GetPartialObject (\(record.variant)) reassembly over PTP/IP, \(record.resumes) resume(s)\n",
                              link: .ptpip, name: "getpartialobject.sha256", log: log)
        if let reference = record.referenceSHA256 {
            let same = sha == reference
            if isResume, startOffset > 0, record.resumes > 0 {
                log.flag("\(prefix).resume.verified", same,
                         context: "\(name) after \(record.resumes) resume(s): SHA-256 \(same ? "matches" : "DIFFERS from") the GetObject reference (\(String(sha.prefix(16)))… vs \(String(reference.prefix(16)))…)")
            } else {
                log.note(isResume
                    ? "\(name): the resumed read restarted from 0 (nothing usable was saved), so it \(same ? "matches" : "DIFFERS from") the GetObject reference but resume.verified isn't recorded; turn Wi-Fi off mid-read next time."
                    : "\(name): uninterrupted reassembly \(same ? "matches" : "DIFFERS from") the GetObject reference. No resume happened, so resume.verified isn't recorded; turn Wi-Fi off mid-read next time.")
            }
        } else {
            log.warn("\(name): SHA-256 \(sha), but no reference hash to compare with; tap Reference hash and run the test again")
        }
        WiFiPartFile.remove(url)
        WiFiResumeStore.clear()
        refreshResumeSummary()
    }

    /// Holds the read between chunks (at the first 4 MiB boundary past half way) so the user can turn Wi-Fi off;
    /// returns once the link has dropped or after `seconds`.
    private func pauseForLinkDrop(_ c: PTPIPClient, seconds: Double, at fraction: Double) async {
        let clock = ContinuousClock()
        let started = clock.now
        activity = String(format: "Paused at %.0f %% — turn Wi-Fi off now", fraction * 100)
        log.note(String(format: "Paused at %.0f %%: turn Wi-Fi off now (Control Centre). Waiting up to %ld s for the link to drop…", fraction * 100, Int(seconds)))
        while (clock.now - started).inSeconds < seconds {
            if await c.linkFailure != nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let waited = clock.now - started
        if let failure = await c.linkFailure {
            log.note(String(format: "link drop detected %.1f s into the pause: %@", waited.inSeconds, "\(failure)"))
        } else {
            log.note("no link drop within \(Int(seconds)) s; continuing the read")
        }
    }

    private func recordPartialThroughput(prefix: String, bytes: UInt64, seconds: Double, context: String) {
        guard bytes > 0, seconds > 0 else { return }
        log.throughput("\(prefix).getPartialObject.throughput", bytes: Int(bytes), seconds: seconds,
                       context: "\(context); 4 MiB chunks, whole chunks only, pause excluded")
    }

    // MARK: Day 9 · QR and join

    func applyScanned(_ payload: String) {
        do {
            let code = try CameraQRCode.parse(payload)
            joinSSID = code.ssid
            joinPassphrase = code.passphrase ?? ""
            qrSummary = code.description
            qrScans += 1
            log.note("QR scanned: \(code.description)")
            for note in code.notes { log.note("QR: \(note)") }
        } catch {
            qrSummary = "QR not understood"
            log.warn("QR: \(error)")
        }
    }

    func join() {
        guard !joining else { return }
        joining = true
        lastJoinGateway = nil
        lastJoinAlreadyAssociated = nil
        let ssid = joinSSID
        let passphrase = joinPassphrase
        Task { @MainActor in
            let outcome = await HotspotJoiner.join(ssid: ssid, passphrase: passphrase, log: self.log)
            if let gateway = outcome?.gateway {
                self.joinedGateway = gateway
                self.lastJoinGateway = gateway
                self.log.note("Join: gateway \(gateway); tap \"Use gateway as camera IP\" if the camera is the access point")
            }
            self.lastJoinAlreadyAssociated = outcome?.alreadyAssociated
            self.joining = false
        }
    }

    /// Build 10, Bluetooth handover: joins the network whose name and password the camera gave over Bluetooth, the
    /// same way as Join camera Wi-Fi (NEHotspotConfiguration, joinOnce false, timed as `ptpip.ap.join` with `source`
    /// as the context, "Bluetooth handover" unless the caller names its run or tab; never the SSID or passphrase), but
    /// the SSID and passphrase stay in this call: never in joinSSID or
    /// joinPassphrase, UserDefaults or the log (HotspotJoiner's redacted path logs the SSID as its length and
    /// whether it starts with "DIRECT-", and the joined network's SSID and BSSID as yes/no answers only).
    func joinHandover(ssid: String, passphrase: String, source: String = "Bluetooth handover") {
        guard !joining else { return }
        joining = true
        lastJoinGateway = nil
        lastJoinAlreadyAssociated = nil
        Task { @MainActor in
            let outcome = await HotspotJoiner.join(ssid: ssid, passphrase: passphrase, log: self.log, redacted: true,
                                                   source: source)
            if let gateway = outcome?.gateway {
                self.joinedGateway = gateway
                self.lastJoinGateway = gateway
                self.log.note("Join (Bluetooth handover): gateway \(gateway)")
            }
            self.lastJoinAlreadyAssociated = outcome?.alreadyAssociated
            self.joining = false
        }
    }

    func forgetJoinedNetwork() {
        HotspotJoiner.forget(ssid: joinSSID, log: log)
        joinedGateway = nil
    }
}
