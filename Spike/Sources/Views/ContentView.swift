import SwiftUI
import ImageCaptureCore

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Wired", systemImage: "cable.connector") { WiredView() }
            Tab("Wi-Fi", systemImage: "wifi") { WirelessView() }
            Tab("Bluetooth", systemImage: "dot.radiowaves.left.and.right") { BluetoothView() }
            Tab("Background", systemImage: "moon.zzz") { BackgroundView() }
            Tab("Log", systemImage: "list.bullet.rectangle") { LogView() }
        }
    }
}

// MARK: - Wired (days 1–5)

struct WiredView: View {
    @Environment(DeviceBrowser.self) private var browser
    @Environment(SpikeLog.self) private var log
    @State private var session: CameraSession?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section("Browser") {
                    LabeledContent("Authorization", value: browser.authorization)
                    Button(browser.isBrowsing ? "Stop browsing" : "Start browsing") {
                        if browser.isBrowsing { browser.stop() } else { Task { await browser.start() } }
                    }
                }
                Section("Cameras") {
                    if browser.cameras.isEmpty {
                        Text("None yet. Camera USB mode → Still Img Transfer (MTP), then plug in.").foregroundStyle(.secondary)
                    }
                    ForEach(browser.cameras, id: \.uuidString) { camera in
                        Button {
                            session = CameraSession(device: camera, log: log)
                            run { await session?.open() }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(camera.name ?? "Camera").font(.headline)
                                Text("\(camera.transportType ?? "?") · \(camera.capabilities.count) capabilities").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let session {
                    Section("Session · \(session.isOpen ? "open" : "closed") · \(session.files.count) files") {
                        Button("Refresh catalogue") { session.refreshFiles() }
                        Button("Time 50 thumbnails") { run { await session.timeThumbnails() } }
                        Button("Download 20 newest, serial") { run { await session.download(newest(session, 20), parallel: 1) } }
                        Button("Download 20 newest, 2 in flight") { run { await session.download(newest(session, 20), parallel: 2) } }
                        Button("Download newest MP4 (if any)") {
                            if let mp4 = session.files.first(where: { ($0.name ?? "").uppercased().hasSuffix(".MP4") }) {
                                run { await session.download([mp4]) }
                            } else { log.warn("no MP4 on card") }
                        }
                    }
                    Section("Day 4 · PTP pass-through") {
                        Button("GetDeviceInfo") { run { await session.fetchDeviceInfo() } }
                        Button("GetObjectInfo (newest ARW)") { if let f = newestARW(session) { run { await session.fetchObjectInfo(f) } } }
                        Button("Read newest ARW via requestReadData (4 MiB chunks)") { if let f = newestARW(session) { run { await session.readPartialViaICC(f) } } }
                        Button("Read newest ARW via GetPartialObject (4 MiB chunks)") { if let f = newestARW(session) { run { await session.readPartialViaPTP(f) } } }
                        Text("Then press the shutter and watch the log for ObjectAdded.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Close session", role: .destructive) { run { await session.close() } }
                    }
                }
            }
            .navigationTitle("Wired")
            .overlay { if busy { ProgressView().controlSize(.large) } }
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task { await work(); busy = false }
    }

    private func newest(_ s: CameraSession, _ n: Int) -> [ICCameraFile] {
        Array(s.files.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }.prefix(n))
    }

    private func newestARW(_ s: CameraSession) -> ICCameraFile? {
        let arw = newest(s, 400).first { ($0.name ?? "").uppercased().hasSuffix(".ARW") }
        if arw == nil { log.warn("no ARW on card") }
        return arw
    }
}

// MARK: - Wireless (days 7–9)

struct WirelessView: View {
    @Environment(SpikeLog.self) private var log
    @AppStorage("ptpip.host") private var host = "192.168.122.1"
    @AppStorage("ptpip.guid") private var guidString = UUID().uuidString
    @State private var client: PTPIPClient?
    @State private var handles: [String] = []
    @State private var status = "disconnected"
    @State private var ssdp: SSDPProbe?

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera") {
                    TextField("Camera IP", text: $host).keyboardType(.decimalPad)
                    LabeledContent("Initiator GUID") { Text(guidString).font(.caption2).lineLimit(1) }
                    Button("New GUID (re-pair test)") { guidString = UUID().uuidString }
                    LabeledContent("Status", value: status)
                }
                Section("Day 7 · handshake") {
                    Button("Connect + OpenSession + GetDeviceInfo") { Task { await connect() } }
                    Button("Disconnect") { Task { await client?.disconnect(); status = "disconnected" } }
                }
                Section("Day 8 · enumerate and download") {
                    Button("GetStorageIDs + GetObjectHandles") { Task { await enumerate() } }
                    Button("GetObjectInfo + GetThumb for first 50") { Task { await infoAndThumbs() } }
                    Button("GetObject for newest handle") { Task { await downloadNewest() } }
                    Button("GetPartialObject newest in 4 MiB chunks") { Task { await partialNewest() } }
                    if !handles.isEmpty { Text("\(handles.count) handles; first \(handles.prefix(3).joined(separator: ", "))").font(.caption) }
                }
                Section("Day 9 · discovery") {
                    Button("SSDP M-SEARCH (needs multicast entitlement)") {
                        ssdp = SSDPProbe(log: log); ssdp?.start()
                    }
                    Text("QR scan + NEHotspotConfiguration join is on the day-9 list; add it once PTP/IP works over a typed IP.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Wi-Fi")
        }
    }

    private func connect() async {
        let c = PTPIPClient(host: host, guid: UUID(uuidString: guidString) ?? UUID())
        client = c
        do {
            let info = try await log.timed("ptpip.handshake", context: host) { try await c.connect() }
            status = "connected to \(info.responderName) (#\(info.connectionNumber))"
            log.note("PTP/IP handshake ok: \(info.responderName) guid=\(info.responderGUID)")
            try await c.openSession()
            let di = try await c.getDeviceInfo()
            log.note("PTP/IP DeviceInfo: \(di.manufacturer) \(di.model) fw=\(di.deviceVersion); ops=\(di.operationsSupported.count) GetPartialObject=\(di.supports(.getPartialObject)) ObjectAdded=\(di.emits(.objectAdded))")
            Task { for await e in c.events { log.note("PTP/IP event: \(e.code) \(e.parameters)") } }
        } catch {
            status = "failed: \(error)"
            log.error("PTP/IP connect failed: \(error)")
        }
    }

    private func enumerate() async {
        guard let client else { return }
        do {
            let stores = try await client.getStorageIDs()
            log.note("storages: \(stores.map { String(format: "0x%08X", $0.rawValue) })")
            let hs = try await log.timed("ptpip.getObjectHandles") { try await client.getObjectHandles() }
            handles = hs.map(\.description)
            log.measure("ptpip.handles.count", Double(hs.count), "objects")
        } catch { log.error("enumerate failed: \(error)") }
    }

    private func infoAndThumbs() async {
        guard let client else { return }
        do {
            let hs = try await client.getObjectHandles()
            var infos = 0, thumbs = 0
            let clock = ContinuousClock(); let start = clock.now
            for h in hs.suffix(50) {
                let info = try await client.getObjectInfo(h)
                infos += 1
                if info.thumbCompressedSize > 0 { _ = try await client.getThumb(h); thumbs += 1 }
                if infos == 1 { log.note("first ObjectInfo: \(info.filename) \(info.objectFormat) \(info.objectCompressedSize)B \(info.captureDateRaw)") }
            }
            let elapsed = clock.now - start
            log.measure("ptpip.info+thumb.avg", (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) / Double(max(infos, 1)) * 1000, "ms", context: "\(infos) infos, \(thumbs) thumbs")
        } catch { log.error("info/thumb failed: \(error)") }
    }

    private func downloadNewest() async {
        guard let client else { return }
        do {
            guard let h = try await client.getObjectHandles().last else { return }
            let info = try await client.getObjectInfo(h)
            let clock = ContinuousClock(); let start = clock.now
            let data = try await client.getObject(h)
            let e = clock.now - start
            log.throughput("ptpip.getObject.throughput", bytes: data.count, seconds: Double(e.components.seconds) + Double(e.components.attoseconds) / 1e18, context: info.filename)
        } catch { log.error("GetObject failed: \(error)") }
    }

    private func partialNewest() async {
        guard let client else { return }
        do {
            guard let h = try await client.getObjectHandles().last else { return }
            let info = try await client.getObjectInfo(h)
            var offset: UInt32 = 0
            let clock = ContinuousClock(); let start = clock.now
            while offset < info.objectCompressedSize {
                let len = min(UInt32(4 * 1024 * 1024), info.objectCompressedSize - offset)
                let chunk = try await client.getPartialObject(h, offset: offset, length: len)
                guard !chunk.isEmpty else { break }
                offset += UInt32(chunk.count)
            }
            let e = clock.now - start
            log.throughput("ptpip.getPartialObject.throughput", bytes: Int(offset), seconds: Double(e.components.seconds) + Double(e.components.attoseconds) / 1e18, context: info.filename)
        } catch { log.error("GetPartialObject failed: \(error)") }
    }
}

// MARK: - Bluetooth (day 6)

struct BluetoothView: View {
    @Environment(SpikeLog.self) private var log
    @State private var scanner = AdvertisementScanner()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("State", value: scanner.state)
                    Button("Scan (Sony only)") { scanner.log = log; scanner.start(sonyOnly: true) }
                    Button("Scan (everything)") { scanner.log = log; scanner.start(sonyOnly: false) }
                    Button("Stop and summarise") { scanner.stop() }
                }
                Section("Seen (\(scanner.seen.count))") {
                    ForEach(scanner.seen.values.sorted { $0.rssi > $1.rssi }) { s in
                        VStack(alignment: .leading) {
                            Text("\(s.name)  \(s.rssi) dBm  ×\(s.count)").font(.headline)
                            Text("services: \(s.serviceUUIDs.isEmpty ? "none" : s.serviceUUIDs.joined(separator: ", "))").font(.caption)
                            Text("mfg: \(s.manufacturerHex)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Text("Repeat with the camera on, asleep, and powered off (Bluetooth Function on, Remote Power ON/OFF on). The service UUID the camera advertises in all three states is the one the production proximity reminder filters on.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Bluetooth")
        }
    }
}

// MARK: - Background (day 5)

struct BackgroundView: View {
    @Environment(ContinuedTask.self) private var task

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("State", value: task.state)
                ProgressView(value: Double(task.completed), total: Double(max(task.total, 1)))
                Button("Start 2-minute continued task, then lock the phone") { task.start(units: 240) }
                Button("Stop", role: .destructive) { task.stop() }
                Text("Expected on iOS 26+: the system shows its own progress UI and the counter keeps running while locked. Record when (if) it expires.").font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Background")
        }
    }
}

// MARK: - Log

struct LogView: View {
    @Environment(SpikeLog.self) private var log
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            List {
                Section("Measurements (\(log.measurements.count))") {
                    ForEach(log.measurements.suffix(30).reversed()) { m in
                        LabeledContent(m.name, value: String(format: "%.2f %@", m.value, m.unit))
                    }
                }
                Section("Entries (\(log.entries.count))") {
                    ForEach(log.entries.suffix(200).reversed()) { e in
                        Text(e.text).font(.caption.monospaced()).foregroundStyle(e.level == "error" ? .red : e.level == "warn" ? .orange : .primary)
                    }
                }
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Clear") { log.clear() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if let exportURL { ShareLink(item: exportURL) { Label("Share", systemImage: "square.and.arrow.up") } }
                    else { Button("Export") { exportURL = try? log.export() } }
                }
            }
        }
    }
}
