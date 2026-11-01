import SwiftUI

/// Day 5 without a camera: does a BGContinuedProcessingTask keep counting while the phone is locked, and when does
/// the system expire it? ContinuedTask logs bgcontinued.startLatency and bgcontinued.ran; the app-lifecycle lines
/// come from LifecycleMonitor. The real-download variants are on the Wired and Wi-Fi tabs.
/// Also, not in the plan: the Photos album and locked-save test (PhotosProbe, added 1 Nov).
struct BackgroundView: View {
    @Environment(ContinuedTask.self) private var task
    @Environment(LifecycleMonitor.self) private var lifecycle
    @Environment(PhotosProbe.self) private var photos
    @State private var minutes = 2

    var body: some View {
        NavigationStack {
            Form {
                Section("Day 5 · Continued task, no camera") {
                    LabeledContent("State", value: task.state)
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(task.completed), total: Double(max(task.total, 1)))
                        Text("\(task.completed) of \(task.total) half-second steps")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Expired by the system", value: task.expired ? "yes" : "no")
                    // A full card over USB 2 takes longer than 10 minutes, so the longer runs check the system's limit.
                    Picker("Length", selection: $minutes) {
                        Text("2 min").tag(2)
                        Text("10 min").tag(10)
                        Text("30 min").tag(30)
                        Text("60 min").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .disabled(task.isRunning)
                    Button("Start timer test, then lock the phone") { task.startTimerTest(units: minutes * 120) }
                        .disabled(task.isRunning)
                    Button("Stop", role: .destructive) { task.stop() }
                        .disabled(!task.isRunning)
                    Text("Expected on iOS 26 and later: the system shows its own progress UI and the count keeps going while locked. The log records when the task started (bgcontinued.startLatency), how long it ran (bgcontinued.ran) and whether the system expired it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Photos albums, no camera (not in the plan)") {
                    LabeledContent("Add-only access", value: photos.addOnly)
                    LabeledContent("Read/write access", value: photos.readWrite)
                    LabeledContent("Test album", value: photos.albumID == nil ? "none yet" : "created")
                    Button("1. Ask for add-only access") { photos.request(.addOnly) }
                        .disabled(photos.isBusy)
                    Button("2. Save a test photo, no album") { photos.saveOnly() }
                        .disabled(photos.isBusy)
                    Button("3. Save a test photo into a new album") { photos.saveIntoNewAlbum() }
                        .disabled(photos.isBusy)
                    Button("4. Find the album and save into it") { photos.saveIntoExistingAlbum() }
                        .disabled(photos.isBusy)
                    Button("5. Ask for read/write access") { photos.request(.readWrite) }
                        .disabled(photos.isBusy)
                    Button("6. Locked save test: start, then lock the phone") { photos.startLockedSave(using: task) }
                        .disabled(photos.isBusy || task.isRunning)
                    Text(photos.lastResult)
                        .font(.footnote)
                    Text("Can each import go into an album with add-only access, or does it need limited access, and can the app save while locked? Run the steps in the order in the runbook (\"Photos albums\"): add-only first, then limited, then the locked test. Delete the test album and photos in Photos afterwards.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .onAppear { photos.refresh() }

                Section("Day 5 · App lifecycle") {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        LabeledContent("App", value: lifecycle.stateDescription)
                    }
                    LabeledContent("Last progress", value: lifecycle.lastProgressNote.isEmpty ? "none yet" : lifecycle.lastProgressNote)
                    if let at = lifecycle.lastProgressAt {
                        LabeledContent("Progress at", value: at.formatted(date: .omitted, time: .standard))
                        LabeledContent("Link", value: lifecycle.lastProgressLink)
                    }
                    Text("When the app returns to the foreground after real downloads, LifecycleMonitor records usb, ptpip.ap or ptpip.lan .lifecycle.progressAfterBackground: the \"Session survives phone lock (seconds)\" row.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("The real-download variants are on the Wired tab (Day 5 · Lifecycle: long serial download, and 20 ARW inside a continued task) and on the Wi-Fi tab (20 newest ARW in a continued task). This timer test needs no camera.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Background")
        }
    }
}
