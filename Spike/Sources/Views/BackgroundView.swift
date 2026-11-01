import SwiftUI

/// Day 5 without a camera: does a BGContinuedProcessingTask keep counting while the phone is locked, and when does
/// the system expire it? ContinuedTask logs bgcontinued.startLatency and bgcontinued.ran; the app-lifecycle lines
/// come from LifecycleMonitor. The real-download variants are on the Wired and Wi-Fi tabs.
struct BackgroundView: View {
    @Environment(ContinuedTask.self) private var task
    @Environment(LifecycleMonitor.self) private var lifecycle
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
                    Picker("Length", selection: $minutes) {
                        Text("2 min").tag(2)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
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
