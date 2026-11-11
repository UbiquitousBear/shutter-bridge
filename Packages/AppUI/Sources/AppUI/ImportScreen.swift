#if canImport(SwiftUI) && canImport(UIKit) && os(iOS)
import ImportEngine
import PhotosBridge
import SwiftUI
import UIKit

/// The Import screen (backlog section 6, *Import*; decisions 1, 4 and 9): the job's state in the person's words, the
/// overall bytes, rate and time left, where the files go (named from the first file) and, when Files is forced, why,
/// with a button to the app's page in Settings when Photos access is off; then a row per file with its state and
/// progress. Pause or Continue (one button) and Cancel as the job allows, in the system bottom toolbar. Shown as a
/// sheet over the whole app, so it stays up when Browse closes because the cable was pulled; the job carries on when
/// the camera is back. The job runs on whether the sheet is up or not, so it closes with the system close button, not
/// Done (HIG Sheets); closing it and swiping it down do the same: the app clears a finished job when the sheet closes
/// either way (`LiveApp`).
///
/// A Wi-Fi job (wireless plan W16) adds, from the `WiFiImportModel` the app puts in the environment: the Local Network
/// explanation if a connection waits for it, the step of the join or the stay, the note that the phone's internet uses
/// mobile data while joined, and the note that the camera's Wi-Fi may stay on for a while after leaving. When the Wi-Fi
/// recovery (W14) gave up or needs a join it couldn't make from where it was, *Try Again* takes the pause button's place
/// (`ImportModel.wifiRecoveryControl`); while it reaches the camera by itself the summary shows a spinner instead.
struct ImportScreen: View {
    let model: ImportModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(WiFiImportModel.self) private var wifiStatus: WiFiImportModel?
    @State private var confirmsCancel = false

    var body: some View {
        NavigationStack {
            Group {
                if model.hasJob {
                    job
                } else {
                    ContentUnavailableView(ImportWording.noJobTitle, systemImage: "square.and.arrow.down",
                                           description: Text(ImportWording.noJobDetail))
                }
            }
            .navigationTitle(ImportWording.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
                // One button that changes between Pause and Continue, so VoiceOver's focus stays on it.
                if model.hasJob, let control = model.pauseControl {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            Task { await model.togglePause() }
                        } label: {
                            Label(control.title, systemImage: control.systemImage)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
                // A Wi-Fi job paused for its camera, its card or a join, once the recovery waits for the person: never
                // alongside Pause or Continue, which don't apply then.
                if model.hasJob, model.pauseControl == nil, model.wifiRecoveryControl == .tryAgain {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            model.tryAgainWiFi()
                        } label: {
                            Label(ImportWording.tryAgain, systemImage: "arrow.clockwise")
                                .labelStyle(.titleAndIcon)
                        }
                        .accessibilityHint(ImportWording.tryAgainHint)
                    }
                }
                if model.hasJob, model.canCancel {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button(ImportWording.cancel, role: .destructive) { confirmsCancel = true }
                    }
                }
            }
            .confirmationDialog(ImportWording.cancelConfirmTitle, isPresented: $confirmsCancel,
                                titleVisibility: .visible) {
                Button(ImportWording.cancel, role: .destructive) {
                    Task { await model.cancel() }
                }
                Button(ImportWording.keepImporting, role: .cancel) {}
            } message: {
                Text(ImportWording.cancelConfirmDetail)
            }
        }
        // VoiceOver hears the job's state when it changes kind (paused, carrying on, finished, stopped), never each
        // byte or file; pauses and stops are urgent, except a stall the engine retries by itself.
        .onChange(of: model.announcedState) { old, new in
            ImportWording.stateAnnouncement(from: old, to: new, statusLine: model.statusLine,
                                            counts: model.countsLine)?.post()
        }
    }

    private var job: some View {
        List {
            Section {
                ImportSummary(model: model)
            }
            if let wifiStatus, model.camera?.descriptor.carrier == .wifi {
                if wifiStatus.isExplainingLocalNetwork {
                    Section {
                        LocalNetworkExplanationView(status: wifiStatus, compact: true)
                    }
                } else if wifiStatus.hasStatus(for: model.camera?.descriptor.id) {
                    Section(ImportWording.wifiHeader) {
                        JoinStatusView(status: wifiStatus, style: .row)
                    }
                }
            }
            if model.destinationLine != nil || model.filesReasonLine != nil {
                Section {
                    destination
                }
            }
            if let message = model.message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                }
            }
            if !model.rows.isEmpty {
                Section(ImportWording.filesHeader) {
                    ForEach(model.rows) { row in
                        ImportRowView(row: row)
                    }
                }
            }
        }
    }

    @ViewBuilder private var destination: some View {
        if let line = model.destinationLine {
            Label(line, systemImage: model.progress.destination?.kind == .staging ? "folder" : "photo.on.rectangle")
        }
        if let reason = model.filesReasonLine {
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        if model.offersPhotosSettingsLink {
            Button(ImportWording.openSettings) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        }
    }
}

/// The job as a whole: its state, a bar by bytes, the bytes, the rate and time left while running, the counts, and
/// why the screen stays on.
struct ImportSummary: View {
    let model: ImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if model.isAskingForPhotosAccess || model.isWaitingForCamera
                    || model.wifiRecoveryControl == .reconnecting {
                    ProgressView()
                }
                Text(model.statusLine ?? "")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.progress.bytesTotal > 0 {
                ProgressView(value: model.progress.fractionCompleted)
            }
            if let bytes = model.bytesLine {
                Text(bytes)
                    .monospacedDigit()
            }
            // Abbreviated units on screen, whole words for VoiceOver ("MB per second", "3 minutes").
            if let rate = model.rateLine {
                Text(rate)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(model.rateSpokenLine ?? rate)
            }
            if let timeLeft = model.timeLeftLine {
                Text(timeLeft)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(model.timeLeftSpokenLine ?? timeLeft)
            }
            if let counts = model.countsLine {
                Text(counts)
            }
            if model.keepsScreenOn {
                Text(ImportWording.screenOnNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One file of the job: its name, size, state and, while it is copied or saved, a bar.
struct ImportRowView: View {
    let row: ImportRow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
            layout {
                Label {
                    Text(row.name)
                } icon: {
                    Image(systemName: symbol)
                        .foregroundStyle(symbolColour)
                }
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 8)
                }
                Text(row.sizeText)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // The reason a file was skipped or failed is the line people most need to read: primary, not orange
            // (HIG Colour and contrast); the symbol carries the colour.
            Text(row.stateText)
                .font(.subheadline)
                .foregroundStyle(row.isProblem ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
            if row.isInFlight {
                ProgressView(value: row.fraction)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private var symbolColour: Color {
        switch row.tone {
        case .neutral: .secondary
        case .done: .green
        case .skipped: .orange
        case .failed: .red
        }
    }

    private var symbol: String {
        switch row.phase {
        case .queued: "clock"
        case .downloading: "arrow.down.circle"
        case .waitingToRetry: "arrow.clockwise"
        case .committing: "square.and.arrow.down"
        case .imported: "checkmark.circle.fill"
        case .staged: "tray.full.fill"
        case .skipped: "minus.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .notImported: "circle"
        }
    }
}
#endif
