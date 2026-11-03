import SwiftUI
import UniformTypeIdentifiers

/// The Wired and Wi-Fi tabs' *Copy all RAW to Files* section: the button, where the copies go (with the folder
/// picker), and the progress of a run with Stop. The copy itself is CameraSession.copyAllARW / WirelessLab.copyAllARW.
struct CopyAllSection: View {
    /// "USB-C" or "Wi-Fi", for the footer.
    let linkName: String
    /// The tab's own conditions (connected, idle); the section adds "no continued task and no copy running".
    let canStart: Bool
    /// Build 14: the tab is idle, so a copy iOS paused may be continued (Continue copy gets the session back itself).
    let canContinue: Bool
    /// Build 14: Continue copy, for a copy iOS paused over this tab's link.
    let continuePaused: () -> Void
    let start: () -> Void

    @Environment(ContinuedTask.self) private var continued
    @State private var destination = FilesDestination.shared
    /// Build 14: Discard asks first (it can't be undone).
    @State private var confirmingDiscard = false

    var body: some View {
        Section {
            Button("Copy all RAW to Files", action: start)
                .disabled(!canStart || continued.isRunning || destination.run != nil || destination.paused != nil)
            CopyAllDestinationRow()
                .disabled(destination.run != nil)
            Toggle("Keep the screen on during the copy", isOn: Binding(get: { destination.keepScreenOn },
                                                                       set: { destination.keepScreenOn = $0 }))
                .disabled(destination.run != nil)
            if let run = destination.run {
                CopyAllProgressRow(run: run)
                Button("Stop", role: .destructive) { continued.stop() }
                    .disabled(!continued.isRunning)
            } else if let paused = destination.paused {
                // Build 14: a copy iOS paused: continued or discarded on the tab of its link.
                Text(verbatim: paused.summary)
                    .font(.caption)
                    .foregroundStyle(.orange)
                if paused.belongs(toLinkName: linkName) {
                    Button("Continue copy (\(paused.remaining.count) left)", action: continuePaused)
                        .disabled(!canContinue || continued.isRunning)
                    // Disabled while the tab is busy too: over USB, Continue opens a session and waits for the catalogue
                    // before any continued task exists.
                    Button("Discard paused copy", role: .destructive) { confirmingDiscard = true }
                        .disabled(!canContinue || continued.isRunning)
                        .confirmationDialog("Discard the paused copy?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                            Button("Discard paused copy", role: .destructive) { destination.discardPaused() }
                            Button("Keep it", role: .cancel) {}
                        } message: {
                            Text(verbatim: discardMessage(paused))
                        }
                } else {
                    Text(verbatim: "It was copying over \(paused.link == "usb" ? "USB-C: Continue copy or Discard on the Wired tab" : "Wi-Fi: Continue copy or Discard on the Wi-Fi tab").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let outcome = destination.lastOutcome {
                Text(verbatim: outcome.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Copy all RAW to Files")
        } footer: {
            Text(verbatim: footer)
        }
    }

    /// "The 102 files copied stay in … › Copy …; the 165 left won't be copied. …"
    private func discardMessage(_ paused: CopyPauseRecord) -> String {
        "The \(paused.copied) files copied stay in \(paused.destination) › \(paused.folderName); the \(paused.remaining.count) left won't be copied. This can't be undone; the copy's measurements are recorded as a copy that ended early."
    }

    private var footer: String {
        var text = "Every ARW the session lists (on Wi-Fi, the whole card only in Sony's whole-card contents transfer), oldest first, over \(linkName), into a new folder named by the start time: nothing is overwritten, and every run copies everything. A file whose size doesn't match is deleted and counted as failed. Runs as a continued task, so start it and lock the phone; Stop keeps what has been copied."
        if linkName == "Wi-Fi" {
            // Build 14: the recovery; Bluetooth only from the guided run, which asks first.
            text += " If the camera drops its card, its session or its Wi-Fi, the copy waits for it, reconnects, lists the card again and carries on (up to three times, and up to three more after each Continue copy); only the guided run may switch the camera's Wi-Fi back on over Bluetooth, and Continue copy here never does."
        }
        // Build 14: pause and continue, and the screen.
        text += " If iOS ends the continued task (an expiry, or Stop in the Live Activity on the Lock Screen or in the Dynamic Island), the copy pauses: the file in flight is dropped, a notification says so (if notifications are allowed), and Continue copy checks the free space again and carries on into the same folder (a new copy waits until the paused one is continued or discarded; Discard keeps the files copied). Keep the screen on stops Auto-Lock while the copy runs with the app in front."
        if !destination.isPicked { text += " " + FilesDestination.defaultCaveat }
        return text
    }
}

/// Where the copies go, with *Choose folder…* (a folder anywhere in Files) and *Use the default folder*.
struct CopyAllDestinationRow: View {
    @State private var destination = FilesDestination.shared
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Copies go to") {
                Text(verbatim: destination.locationDescription)
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
            }
            if let problem = destination.problem {
                Text(verbatim: problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            // Borderless: two buttons in one list row would otherwise both fire on a tap anywhere in the row.
            HStack {
                Button("Choose folder…") { picking = true }
                Spacer()
                Button("Use the default folder") { destination.useDefault() }
                    .disabled(!destination.isPicked)
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): destination.usePicked(url)
            case .failure(let error): destination.pickFailed(error)
            }
        }
    }
}

/// n of N, GB and MB/s so far, while a copy runs.
private struct CopyAllProgressRow: View {
    let run: CopyAllRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(run.copied + run.failed), total: Double(max(run.total, 1)))
            Text(verbatim: run.progressLine)
                .font(.caption)
                .monospacedDigit()
            Text(verbatim: run.current.isEmpty ? "Into \(run.folderName)" : "\(run.current) → \(run.folderName)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
