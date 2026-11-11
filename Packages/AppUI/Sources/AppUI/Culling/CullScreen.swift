#if canImport(SwiftUI) && canImport(UIKit) && canImport(Accessibility) && canImport(CoreImage) && canImport(ImageIO) && canImport(CoreGraphics) && canImport(UniformTypeIdentifiers) && os(iOS)
import SwiftUI
import UIKit

/// The Staging screen in a sheet over Cameras, with its own navigation stack and a close button: culling of staged
/// files lives here (D5) until I10's tab bar gives it a tab of its own. The model is made each time the sheet opens
/// (`AppModel.stagingModel`), so it reads Staging as it is then.
struct StagingScreen: View {
    @State private var model: CullModel<DecodedPreviewImage>
    @Environment(\.dismiss) private var dismiss

    init(model: CullModel<DecodedPreviewImage>) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            CullScreen(model: model)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { dismiss() }
                    }
                }
        }
    }
}

/// The cull screen (backlog section 7.3): the staged files by camera and capture day, newest day first, each day with
/// its counts ("Today: 120 staged, 34 kept, 60 rejected"), from the catalogue with no camera connected. A day opens the
/// loupe over its photos, full screen, at the first one with no mark. Staged files that can't be shown are counted
/// under the list, with why. Pull to refresh reads Staging again.
struct CullScreen: View {
    let model: CullModel<DecodedPreviewImage>
    @Environment(\.displayScale) private var displayScale
    /// The screen's size, for the previews' decode size.
    @State private var size: CGSize = .zero
    /// The loupe's cover; when it closes, however it closes, the model closes its loupe.
    @State private var showsLoupe = false

    var body: some View {
        content
            .navigationTitle(CullWording.title)
            .onGeometryChange(for: CGSize.self) { proxy in proxy.size } action: { size = $0 }
            .task { await model.load() }
            .fullScreenCover(isPresented: $showsLoupe, onDismiss: {
                let model = self.model
                Task { await model.closeLoupe() }
            }) {
                if let loupe = model.loupe {
                    LoupeView(loupe: loupe) { showsLoupe = false }
                }
            }
    }

    /// The longer side of the screen in pixels: the size previews are decoded to.
    private var maxPixelSize: Int {
        let side = max(size.width, size.height) * displayScale
        return side > 0 ? Int(side.rounded(.up)) : 2_800
    }

    @ViewBuilder private var content: some View {
        if model.phase == .failed, model.isEmpty {
            ContentUnavailableView {
                Label(CullWording.loadFailedTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(CullWording.loadFailedDetail)
            } actions: {
                Button(CullWording.tryAgain) {
                    let model = self.model
                    Task { await model.load() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if model.phase == .loading, model.isEmpty {
            ProgressView(CullWording.loading)
        } else if model.isEmpty, model.unavailable.total == 0 {
            ContentUnavailableView(CullWording.emptyTitle, systemImage: "tray",
                                   description: Text(CullWording.emptyDetail))
        } else {
            List {
                ForEach(model.sections) { section in
                    Section(section.name) {
                        ForEach(section.days) { row in
                            CullDayRowView(row: row, counts: model.counts(of: row)) {
                                model.openLoupe(row.id, maxPixelSize: maxPixelSize)
                                showsLoupe = model.loupe != nil
                            }
                        }
                    }
                }
                let lines = CullWording.unavailableLines(model.unavailable)
                if !lines.isEmpty {
                    Section {
                        ForEach(lines, id: \.self) { line in
                            Text(line)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .refreshable { await model.load() }
        }
    }
}

/// One day: its title ("Today", "Yesterday" or the date) and its counts. A button that opens the loupe; VoiceOver reads
/// it as one sentence with a hint.
private struct CullDayRowView: View {
    let row: CullDayRow
    let counts: CullCounts
    let open: () -> Void

    var body: some View {
        let title = CullWording.dayTitle(row.day, now: Date())
        Button(action: open) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(CullWording.countsLine(counts))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(CullWording.dayLabel(title: title, counts: counts))
        .accessibilityHint(CullWording.dayHint)
    }
}
#endif
