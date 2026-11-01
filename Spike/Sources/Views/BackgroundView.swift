import SwiftUI

struct BackgroundView: View {
    @Environment(ContinuedTask.self) private var task

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("State", value: task.state)
                ProgressView(value: Double(task.completed), total: Double(max(task.total, 1)))
                Button("Start 2-minute continued task, then lock the phone") { task.startTimerTest(units: 240) }
                Button("Stop", role: .destructive) { task.stop() }
                Text("Expected on iOS 26+: the system shows its own progress UI and the counter keeps running while locked. Record when (if) it expires.").font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Background")
        }
    }
}
