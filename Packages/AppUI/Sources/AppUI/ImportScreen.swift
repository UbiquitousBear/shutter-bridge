#if canImport(SwiftUI) && canImport(UIKit) && os(iOS)
import ImportEngine
import PhotosBridge
import SwiftUI
import UIKit

/// The Import screen (backlog section 6, *Import*; decisions 1, 4 and 9): the job's state in the person's words, the
/// overall bytes, rate and time left, where the files go (named from the first file) and, when Files is forced, why,
/// with a button to the app's page in Settings when Photos access is off; then a row per file with its state and
/// progress. Pause, Continue and Cancel as the job allows. Shown as a sheet over the whole app, so it stays up when
/// Browse closes because the cable was pulled; the job carries on when the camera is back.
struct ImportScreen: View {
    let model: ImportModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
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
                ToolbarItem(placement: .confirmationAction) {
                    Button(ImportWording.done) {
                        // A finished job is cleared once it has been seen; a running one stays.
                        if model.isFinished { model.dismiss() }
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.hasJob, model.canPause || model.canResume || model.canCancel {
                    ImportControls(model: model, confirmCancel: { confirmsCancel = true })
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
            Label(line, systemImage: model.progress.destination?.kind == .filesFolder ? "folder" : "photo.on.rectangle")
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
                if model.isAskingForPhotosAccess || model.isWaitingForCamera {
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
            if let rate = model.rateLine {
                Text(rate)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let timeLeft = model.timeLeftLine {
                Text(timeLeft)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
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

/// Pause, Continue and Cancel, side by side, or stacked at the accessibility text sizes.
struct ImportControls: View {
    let model: ImportModel
    let confirmCancel: @MainActor () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            if model.canPause {
                Button {
                    Task { await model.pause() }
                } label: {
                    Label(ImportWording.pause, systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if model.canResume {
                Button {
                    Task { await model.resume() }
                } label: {
                    Label(ImportWording.resume, systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            if model.canCancel {
                Button(role: .destructive) {
                    confirmCancel()
                } label: {
                    Text(ImportWording.cancel)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
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
        case .skipped: "minus.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .notImported: "circle"
        }
    }
}
#endif
