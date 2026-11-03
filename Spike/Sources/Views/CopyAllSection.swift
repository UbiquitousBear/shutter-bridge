import SwiftUI
import UniformTypeIdentifiers

/// The Wired and Wi-Fi tabs' *Copy all RAW to Files* section: the button, where the copies go (with the folder
/// picker), and the progress of a run with Stop. The copy itself is CameraSession.copyAllARW / WirelessLab.copyAllARW.
struct CopyAllSection: View {
    /// "USB-C" or "Wi-Fi", for the footer.
    let linkName: String
    /// The tab's own conditions (connected, idle); the section adds "no continued task and no copy running".
    let canStart: Bool
    let start: () -> Void

    @Environment(ContinuedTask.self) private var continued
    @State private var destination = FilesDestination.shared

    var body: some View {
        Section {
            Button("Copy all RAW to Files", action: start)
                .disabled(!canStart || continued.isRunning || destination.run != nil)
            CopyAllDestinationRow()
                .disabled(destination.run != nil)
            if let run = destination.run {
                CopyAllProgressRow(run: run)
                Button("Stop", role: .destructive) { continued.stop() }
                    .disabled(!continued.isRunning)
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

    private var footer: String {
        var text = "Every ARW the session lists (on Wi-Fi, the whole card only in Sony's whole-card contents transfer), oldest first, over \(linkName), into a new folder named by the start time: nothing is overwritten, and every run copies everything. A file whose size doesn't match is deleted and counted as failed. Runs as a continued task, so start it and lock the phone; Stop keeps what has been copied."
        if linkName == "Wi-Fi" {
            // Build 14: the recovery; Bluetooth only from the guided run, which asks first.
            text += " If the camera drops its card, its session or its Wi-Fi, the copy waits for it, reconnects, lists the card again and carries on (up to three times); only the guided run may switch the camera's Wi-Fi back on over Bluetooth."
        }
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
