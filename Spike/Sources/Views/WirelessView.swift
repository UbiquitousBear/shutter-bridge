import SwiftUI
import PTPKit

/// Week 2 (days 6–9): PTP/IP over Wi-Fi. Every button is one runbook step; each logs what it saw and records the
/// measurements the Log tab exports into the spike plan's table (names "ptpip.<net>.…", net = ap or lan from the
/// Network picker).
struct WirelessView: View {
    @Environment(SpikeLog.self) private var log
    @Environment(ContinuedTask.self) private var continued
    @Environment(LifecycleMonitor.self) private var lifecycle
    @State private var lab: WirelessLab?

    var body: some View {
        NavigationStack {
            Group {
                if let lab {
                    WirelessPanel(lab: lab)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Wi-Fi")
        }
        .task {
            if lab == nil { lab = WirelessLab(log: log, continued: continued, lifecycle: lifecycle) }
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
            downloadSection
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
                LabeledContent("Continued task", value: "\(continued.state) · \(continued.completed) of \(continued.total)")
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
            Button("Sony SDIO connect (PC Remote modes)") { lab.sonySDIO() }
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
            Text(verbatim: "Resume: Reference hash, then Start resumable read; turn Wi-Fi off when it pauses at 50 %; turn Wi-Fi on, rejoin the camera, tap Resume read. SSDP and Bonjour are under Day 6 · Probe.")
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
    var joinSSID = ""
    /// Never logged or persisted.
    var joinPassphrase = ""

    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var savedEventFixtures: Set<String> = []
    @ObservationIgnored private var batteryWindow: BatteryWindow?
    @ObservationIgnored private var batteryUnsupported = false
    /// Measurement prefixes ("ptpip.ap", "ptpip.lan") whose getPartialObject.supported has been recorded.
    @ObservationIgnored private var partialSupportFlagged: Set<String> = []

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

    private func runCamera(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { log.warn("\(label): wait for \(activity) to finish"); return }
        guard !continued.isRunning else { log.warn("\(label): a continued task is running; stop it first"); return }
        busy = true
        activity = label
        progress = nil
        Task { @MainActor in
            do {
                try await work()
            } catch {
                await self.failed(label, error)
            }
            self.busy = false
            self.activity = ""
            self.progress = nil
            self.lifecycle.operationEnded()
        }
    }

    /// Runs `work` with the open session's client and its net ("ap" / "lan").
    private func runSession(_ label: String, _ work: @escaping @MainActor (PTPIPClient, String) async throws -> Void) {
        guard let c = client, let net = sessionNet else {
            log.warn("\(label): not connected; tap Connect first")
            return
        }
        runCamera(label) { try await work(c, net) }
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
        runCamera("Connect") { try await self.open(t, closingPrevious: true) }
    }

    func reconnect(_ t: WiFiTarget) {
        runCamera("Reconnect") {
            self.log.note("Reconnect with the same GUID \(t.guid.uuidString): note what the camera shows (no prompt / prompt once / prompt every time)")
            try await self.open(t, closingPrevious: false)
        }
    }

    func disconnect() {
        runCamera("Disconnect") {
            await self.closeClient(closingSession: true)
            self.log.note("PTP/IP: disconnected")
        }
    }

    private func closeClient(closingSession: Bool) async {
        eventsTask?.cancel()
        eventsTask = nil
        if let c = client { await c.disconnect(closingSession: closingSession) }
        client = nil
        sessionNet = nil
        connectionState = "not connected"
    }

    /// Handshake + OpenSession + GetDeviceInfo. Used by Connect, Reconnect and Resume read.
    @discardableResult
    private func open(_ t: WiFiTarget, closingPrevious: Bool) async throws -> (PTPIPClient, PTPDeviceInfo) {
        if client != nil { await closeClient(closingSession: closingPrevious) }
        guard !t.host.isEmpty else { throw WiFiLabError.message("enter the camera IP first") }
        objects = []
        objectAddedCount = 0
        eventCount = 0
        batteryWindow = nil
        batteryLine = nil
        // Per session: BatteryLevel support depends on the camera mode, and day 6–8 switch modes between connects.
        batteryUnsupported = false
        let c = PTPIPClient(host: t.host, guid: t.guid, log: PTPIPClient.logger(log))
        client = c
        sessionNet = t.net
        connectionState = "connecting to \(t.host) (\(t.netLabel))…"
        listen(to: c, prefix: t.prefix)
        log.note("PTP/IP: connecting to \(t.host):15740 on \(t.netLabel) as \"\(c.friendlyName)\", GUID \(t.guid.uuidString)")
        do {
            let hs = try await c.connect()
            log.measure("\(t.prefix).handshake", hs.total, "s", context: hs.breakdown)
            log.note("Init_Command_Ack: responder \"\(hs.responderName)\", GUID \(hs.responderGUID.uuidString), connection #\(hs.connectionNumber), protocol 0x\(String(hs.protocolVersion, radix: 16)); Init_Event_Ack received")
            let alreadyOpen = try await c.openSession()
            log.note(alreadyOpen ? "OpenSession: SessionAlreadyOpen (treated as success)" : "OpenSession: OK")
            let (info, raw) = try await c.getDeviceInfo()
            deviceInfo = info
            logDeviceInfo(info, raw: raw)
            FixtureStore.saveDeviceInfo(raw, link: .ptpip, log: log)
            FixtureStore.recordFirmware(model: info.model, version: info.deviceVersion, link: .ptpip, log: log)
            connectionState = "connected · \(info.model) \(info.deviceVersion) · \(t.netLabel)"
            return (c, info)
        } catch {
            await closeClient(closingSession: false)
            connectionState = "not connected (last attempt failed)"
            throw error
        }
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
        log.note("supports GetPartialObject 0x101B \(yn(di.supports(.getPartialObject))), GetPartialObject64 0x95C1 \(yn(di.supports(.getPartialObject64))), GetThumb \(yn(di.supports(.getThumb))), Sony SDIO_Connect \(yn(di.supports(.sonySDIOConnect))), SDIO_GetExtDeviceInfo \(yn(di.supports(.sonySDIOGetExtDeviceInfo))), SDIO_GetPartialLargeObject \(yn(di.supports(.sonySDIOGetPartialLargeObject))), SDIO_SetContentsTransferMode \(yn(di.supports(.sonySDIOSetContentsTransferMode))); emits ObjectAdded \(yn(di.emits(.objectAdded))), Sony ObjectAdded \(yn(di.emits(.sonyObjectAdded)))")
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
        if e.code.signalsNewObject {
            objectAddedCount += 1
            if objectAddedCount == 1 {
                log.flag("\(prefix).event.objectAdded", true, context: "\(e.code) on the \(item.channel) channel, params [\(params)]")
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

    func sonySDIO() {
        runSession("Sony SDIO connect") { c, _ in
            self.log.note("Sony SDIO (experimental, PC Remote modes): SDIO_Connect 1, 2, SDIO_GetExtDeviceInfo, SDIO_Connect 3, in libgphoto2's order")
            try await self.sdioStep("SDIO_Connect(1)") { try await c.sonySDIOConnect(phase: 1) }
            try await self.sdioStep("SDIO_Connect(2)") { try await c.sonySDIOConnect(phase: 2) }
            var ext = try await self.sdioStep("SDIO_GetExtDeviceInfo(0x12C)") { try await c.sonySDIOGetExtDeviceInfo(version: 0x12C) }
            if ext == nil {
                ext = try await self.sdioStep("SDIO_GetExtDeviceInfo(0xC8)") { try await c.sonySDIOGetExtDeviceInfo(version: 0xC8) }
            }
            if let ext {
                FixtureStore.save(ext, link: .ptpip, name: "sdio-extdeviceinfo.bin", log: self.log)
                self.logExtDeviceInfo(ext)
            }
            try await self.sdioStep("SDIO_Connect(3)") { try await c.sonySDIOConnect(phase: 3) }
            let before = self.deviceInfo?.operationsSupported.count ?? 0
            let (info, raw) = try await c.getDeviceInfo()
            self.deviceInfo = info
            self.log.note("GetDeviceInfo after SDIO: \(info.operationsSupported.count) operations (before: \(before)), \(info.devicePropertiesSupported.count) properties, \(raw.count) bytes")
        }
    }

    /// One SDIO step. A non-OK response is logged and returns nil; a link failure throws.
    @discardableResult
    private func sdioStep(_ label: String, _ body: () async throws -> Data) async throws -> Data? {
        do {
            let data = try await body()
            log.note("\(label): OK, \(data.count) bytes \(data.hexDump())")
            return data
        } catch PTPIPClient.ClientError.response(_, let code) {
            log.warn("\(label): \(code)")
            return nil
        }
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

    // MARK: Day 8 · Enumerate and download

    func listCard() {
        runSession("List card") { c, net in
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
                guard id.hasLogicalStore else {
                    storageNotes.append("\(idText): no logical store (empty slot?)")
                    continue
                }
                let (si, siRaw) = try await c.getStorageInfo(id)
                if !fixtures.contains(where: { $0.0 == "storageinfo.bin" }) { fixtures.append(("storageinfo.bin", siRaw)) }
                storageNotes.append(String(format: "%@ \"%@\" label \"%@\", %.1f GB free of %.1f GB, type %ld fs %ld access %ld",
                                           idText, si.storageDescription, si.volumeLabel,
                                           Double(si.freeSpaceInBytes) / 1e9, Double(si.maxCapacity) / 1e9,
                                           Int(si.storageType), Int(si.filesystemType), Int(si.accessCapability)))
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
            self.log.measure("\(prefix).enumerate", seconds, "s",
                             context: "GetStorageIDs + GetStorageInfo + GetObjectHandles + GetObjectInfo × \(listed.count + folders) over \(ids.count) storage ID(s)")
            self.log.measure("\(prefix).objects", Double(listed.count), "count", context: "\(breakdown); \(folders) folder(s) not counted")
            for note in storageNotes { self.log.note("storage \(note)") }
            if let newest = self.objects.first {
                self.log.note("newest: \(newest.info.filename) \(newest.info.captureDateRaw) \(newest.info.objectCompressedSize) bytes, format \(newest.info.objectFormat), handle \(newest.handle)")
            }
            for (name, data) in fixtures { FixtureStore.save(data, link: .ptpip, name: name, log: self.log) }
        }
    }

    func thumbnails() {
        runSession("Thumbnails for 50 newest") { c, net in
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
        runSession("GetObject 20 newest ARW") { c, net in
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

    func downloadMP4() {
        runSession("GetObject 3 newest MP4") { c, net in
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
        defer {
            busy = false
            activity = ""
            progress = nil
            lifecycle.operationEnded()
        }
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

    // MARK: Battery

    private func readBattery(_ c: PTPIPClient) async -> Int? {
        guard !batteryUnsupported else { return nil }
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
            while (clock.now - started).inSeconds < seconds, self.objectAddedCount == before {
                self.progress = (clock.now - started).inSeconds / seconds
                try await Task.sleep(for: .milliseconds(250))
            }
            if self.objectAddedCount == before {
                // Events sent on the command channel are only read during a transaction: run one to drain it.
                _ = try await c.getStorageIDs()
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
                              context: "none within \(Int(seconds)) s of the shutter test; \(self.eventCount) other event(s) this session")
            }
        }
    }

    // MARK: Day 9 · Resume

    func referenceHash() {
        runSession("Reference hash") { c, _ in
            guard let o = self.newest(ext: "ARW", count: 1).first else { throw WiFiLabError.message("no ARW listed; tap List card first") }
            let url = try self.downloadURL(for: o)
            defer { try? FileManager.default.removeItem(at: url) }
            self.log.note("Reference hash: GetObject \(o.info.filename) (\(o.info.objectCompressedSize) bytes)…")
            let r = try await c.getObject(o.handle, to: url)
            let expected = UInt64(o.info.objectCompressedSize)
            // A truncated or padded reference would later make resume.verified a false "no".
            guard r.bytes == expected, r.announcedLength.map({ $0 == r.bytes }) ?? true else {
                throw WiFiLabError.message("GetObject returned \(r.bytes) bytes (Start_Data announced \(r.announcedLength.map { String($0) } ?? "unknown"), ObjectInfo says \(expected)); reference not saved, tap Reference hash again")
            }
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

    func startResumableRead(pauseAtHalf: Bool) {
        runSession("Resumable read") { c, net in
            guard let o = self.newest(ext: "ARW", count: 1).first, let di = self.deviceInfo else {
                throw WiFiLabError.message("no ARW listed; tap List card first")
            }
            let identity = o.info.identity(cameraSerial: self.cameraSerial)
            guard identity.size > 0, o.info.objectCompressedSize != UInt32.max else {
                throw WiFiLabError.message("\(o.info.filename): size unknown in ObjectInfo")
            }
            let reference = WiFiResumeStore.loadReference().flatMap { $0.identity == identity && $0.bytes == identity.size ? $0.sha256 : nil }
            if reference == nil {
                self.log.warn("no reference hash for \(identity.filename): tap Reference hash first, or the resumed file can't be verified")
            }
            let listed = PTPPartialRead.variant(objectSize: identity.size, device: di)
            if listed == nil {
                self.log.warn("DeviceInfo lists neither GetPartialObject (0x101B) nor GetPartialObject64 (0x95C1); trying 0x101B anyway")
            }
            let variant = listed ?? .standard32
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
        runCamera("Resume read") {
            if saved.net != t.net { self.log.warn("the saved read started on \(saved.net); it stays in the ptpip.\(saved.net) column") }
            let target = WiFiTarget(net: saved.net, host: t.host, guid: t.guid)
            self.log.note("Resume read: \(saved.summary). Reconnecting (handshake + OpenSession)…")
            let (c, _) = try await self.open(target, closingPrevious: false)
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
        let ssid = joinSSID
        let passphrase = joinPassphrase
        Task { @MainActor in
            let outcome = await HotspotJoiner.join(ssid: ssid, passphrase: passphrase, log: self.log)
            if let gateway = outcome?.gateway {
                self.joinedGateway = gateway
                self.log.note("Join: gateway \(gateway); tap \"Use gateway as camera IP\" if the camera is the access point")
            }
            self.joining = false
        }
    }

    func forgetJoinedNetwork() {
        HotspotJoiner.forget(ssid: joinSSID, log: log)
        joinedGateway = nil
    }
}
