import SwiftUI
import UIKit

/// Guided runs: the spike's own tests in session order, with alerts for the physical steps (change the USB mode,
/// pull the cable, lock the phone, press the shutter). At the end of a run its log and the measurements table are
/// on the clipboard, ready to paste into the chat.
struct GuidedView: View {
    @Environment(GuidedRunner.self) private var runner

    private var groups: [String] {
        var seen: [String] = []
        for script in GuidedScript.all where !seen.contains(script.group) { seen.append(script.group) }
        return seen
    }

    var body: some View {
        NavigationStack {
            List {
                if let title = runner.runningTitle {
                    Section("Running") {
                        Text(title).font(.headline)
                        if !runner.step.isEmpty { Text(runner.step).font(.subheadline) }
                        Button("Cancel run", role: .destructive) { runner.requestCancel() }
                    }
                }
                if let pending = runner.pending {
                    Section("Waiting for you") {
                        Text(pending.title).font(.headline)
                        Text(pending.message).font(.callout)
                        Button("Done") { runner.answerPending("Done") }
                        Button("Skip") { runner.answerPending("Skip") }
                    }
                }
                if !runner.steps.isEmpty {
                    Section(runner.isRunning ? "Steps so far" : "Steps of the last run") {
                        ForEach(Array(runner.steps.enumerated()), id: \.offset) { item in
                            Text(item.element).font(.caption)
                        }
                    }
                }
                if let report = runner.lastReport, !runner.isRunning {
                    Section("Last run") {
                        Button("Copy report again") { UIPasteboard.general.string = report }
                        ShareLink("Share report", item: report)
                    }
                }
                ForEach(groups, id: \.self) { group in
                    Section(group) {
                        ForEach(GuidedScript.all.filter { $0.group == group }) { script in
                            Button {
                                runner.start(script)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(script.title)
                                    Text(script.summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(runner.isRunning)
                        }
                    }
                }
                Section {
                    Text("Alerts appear over any tab. Where the app can see a step happen (the cable pulled, the camera back, the phone unlocked) the alert closes by itself. Steps done in another tab (scanning the camera's QR code) wait here with Done and Skip. Every run logs to the Log tab as usual; at the end its log and the measurements table are copied for you to paste into the chat.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Guided")
        }
    }
}
