import SwiftUI
import ImageCaptureCore

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
