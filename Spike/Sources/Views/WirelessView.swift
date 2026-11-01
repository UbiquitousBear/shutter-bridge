import SwiftUI
import PTPKit

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
