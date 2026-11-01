import SwiftUI
import ImageCaptureCore
import PTPKit

/// Week 1 over USB-C. One section per spike day; each button is one step of docs/spike-plan.md and logs what it
/// measured to the Log tab. Only one operation runs at a time: buttons are disabled while it runs, and the overlay
/// shows it with a Stop button.
struct WiredView: View {
    @Environment(DeviceBrowser.self) private var browser
    @Environment(SpikeLog.self) private var log
    @Environment(LifecycleMonitor.self) private var lifecycle
    @Environment(ContinuedTask.self) private var continued
    @State private var session: CameraSession?
    @State private var selectedCameraID: ObjectIdentifier?
    @State private var batteryGB = 1
    /// Off: Open session returns when the session is open and the catalogue is logged in the background.
    @State private var waitForCatalogue = true

    var body: some View {
        @Bindable var bindableBrowser = browser
        NavigationStack {
            List {
                Section("Session") {
                    LabeledContent("Camera", value: selectedCamera?.name ?? "none")
                    LabeledContent("State", value: session?.stateDescription ?? "no session")
                    LabeledContent("Files", value: session.map { "\($0.files.count)" } ?? "–")
                    if let info = session?.deviceInfo {
                        LabeledContent("DeviceInfo", value: "\(info.model) \(info.deviceVersion)")
                    }
                    if let result = session?.lastResult, !result.isEmpty {
                        Text(result).font(.footnote)
                    }
                }

                Section("Day 1 · Browser") {
                    LabeledContent("Authorisation", value: browser.authorization)
                    Picker("Device mask", selection: $bindableBrowser.maskChoice) {
                        ForEach(DeviceBrowser.MaskChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .disabled(browser.isBrowsing)
                    LabeledContent("Mask in use", value: browser.maskDescription)
                    Button(browser.isBrowsing ? "Stop browsing" : "Start browsing") {
                        if browser.isBrowsing {
                            browser.stop()
                        } else {
                            Task { await browser.start() }
                        }
                    }
                    .disabled(isBusy)
                    if browser.cameras.isEmpty {
                        Text("No camera yet. On the camera: Setup → USB → USB Connection Mode; try each mode, then plug in.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(browser.cameras, id: \.self) { camera in
                        cameraRow(camera)
                    }
                }

                Section("Day 2 · Catalogue") {
                    Toggle("Wait for ImageCaptureCore's catalogue", isOn: $waitForCatalogue)
                        .disabled(isBusy)
                    Button("Open session") { openSession() }
                        .disabled(selectedCamera == nil || isBusy || isOpen)
                    Button("PTP listing (GetObjectHandles + GetObjectInfo for every object)") { run { await $0.ptpListing() } }
                        .disabled(!canRun)
                    Button("Refresh catalogue") { session?.refreshCatalogue(record: true) }
                        .disabled(!canRun)
                    Button("Thumbnails, 50 newest") { run { await $0.timeThumbnails(count: 50) } }
                        .disabled(!canRun)
                    Button("Close session", role: .destructive) { run { await $0.closeSession() } }
                        .disabled(!canRun)
                    Text("Wait off: Open session returns at once and the catalogue is logged every 2 s until usb.catalog.complete; PTP buttons work meanwhile, thumbnails and downloads wait for it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Day 3 · Throughput") {
                    ForEach(USBDownloadPreset.allCases) { preset in
                        Button(preset.label) { run { await $0.downloadBatch(preset) } }
                            .disabled(!canRun)
                    }
                    Text("Records MB/s per file and per batch, and the memory high-water mark. Copies are deleted afterwards.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Day 4 · PTP pass-through") {
                    Button("GetDeviceInfo") { run { await $0.ptpGetDeviceInfo() } }
                        .disabled(!canRun)
                    Button("GetStorageIDs + GetStorageInfo") { run { await $0.ptpStorage() } }
                        .disabled(!canRun)
                    Button("GetObjectHandles") { run { await $0.ptpObjectHandles() } }
                        .disabled(!canRun)
                    Button("GetObjectInfo: newest ARW + pair") { run { await $0.ptpObjectInfo() } }
                        .disabled(!canRun)
                    Button("GetPartialObject: newest ARW") { run { await $0.getPartialObjectTest() } }
                        .disabled(!canRun)
                    Button("Watch for ObjectAdded (60 s)") { run { await $0.watchForObjectAdded(seconds: 60) } }
                        .disabled(!canRun)
                    Stepper("Battery test size: \(batteryGB) GB", value: $batteryGB, in: 1 ... 10)
                        .disabled(isBusy)
                    Button("Battery per GB") {
                        let size = batteryGB
                        run { await $0.batteryPerGB(targetGB: size) }
                    }
                    .disabled(!canRun)
                    Text("Battery: set Setup → USB → USB Power Supply to Off first, or the camera charges from the phone. ObjectAdded: tap Watch, then press the shutter.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Day 4 · Resume over USB") {
                    LabeledContent("Saved read", value: session?.resumeSummary ?? "open a session to see it")
                    Button("Start resumable read") { run { await $0.startResumableRead() } }
                        .disabled(!canRun)
                    Button("Resume read") { run { await $0.resumeRead() } }
                        .disabled(!canRun)
                    Button("Forget saved read", role: .destructive) { session?.forgetSavedRead() }
                        .disabled(session == nil || isBusy)
                    Text("Start, pull the cable when the log says PULL NOW, plug back in, Open session, then Resume read. Start resumable read replaces any saved read.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Day 5 · Lifecycle") {
                    LabeledContent("App", value: lifecycle.stateDescription)
                    Button("Long serial download (lock the phone now)") { run { await $0.longSerialDownload() } }
                        .disabled(!canRun)
                    Button("Download 20 newest ARW inside a continued task") { session?.continuedDownload(using: continued) }
                        .disabled(!canRun || continued.isRunning)
                    LabeledContent("Continued task", value: "\(continued.state) · \(continued.completed)/\(continued.total)")
                    Button("Stop continued task") { continued.stop() }
                        .disabled(!continued.isRunning)
                }
            }
            .navigationTitle("Wired")
            .overlay(alignment: .bottom) {
                if let session, let activity = session.activity {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(activity)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        if !session.progressText.isEmpty {
                            Text(session.progressText)
                                .font(.caption)
                                .monospacedDigit()
                        }
                        Button("Stop") { session.requestStop() }
                            .buttonStyle(.bordered)
                            .disabled(session.stopRequested)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                }
            }
        }
    }

    private func cameraRow(_ camera: ICCameraDevice) -> some View {
        Button {
            selectedCameraID = ObjectIdentifier(camera)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(camera.name ?? "Camera")
                        .font(.headline)
                    Text("\(camera.transportType ?? "?") · \(camera.capabilities.count) capabilities")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if camera === selectedCamera {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(isBusy)
    }

    private var selectedCamera: ICCameraDevice? {
        if let id = selectedCameraID, let camera = browser.cameras.first(where: { ObjectIdentifier($0) == id }) {
            return camera
        }
        return browser.cameras.first
    }

    private var isBusy: Bool { session?.isBusy ?? false }
    private var isOpen: Bool { session?.isOpen ?? false }
    private var canRun: Bool { isOpen && !isBusy }

    /// Reuses the session if it belongs to the selected camera and the camera is still attached; otherwise starts a
    /// new one (after a cable pull the re-plugged camera is a new ICCameraDevice).
    private func openSession() {
        guard let camera = selectedCamera else {
            log.warn("No camera: start browsing and plug the camera in (Day 1)")
            return
        }
        let wait = waitForCatalogue
        if let session, session.device === camera, !session.removed {
            Task { await session.openSession(waitForCatalogue: wait) }
            return
        }
        session?.detach()
        let fresh = CameraSession(device: camera, log: log, lifecycle: lifecycle)
        session = fresh
        Task { await fresh.openSession(waitForCatalogue: wait) }
    }

    private func run(_ work: @escaping @MainActor (CameraSession) async -> Void) {
        guard let session else {
            log.warn("Open a session first (Day 2)")
            return
        }
        Task { await work(session) }
    }
}
