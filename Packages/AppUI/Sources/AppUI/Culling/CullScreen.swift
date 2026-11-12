#if canImport(SwiftUI) && canImport(UIKit) && canImport(Accessibility) && canImport(CoreImage) && canImport(ImageIO) && canImport(CoreGraphics) && canImport(UniformTypeIdentifiers) && os(iOS)
import SwiftUI
import UIKit

/// The Staging screen in a sheet over Cameras, with its own navigation stack and a close button: culling of staged
/// files lives here (D5) until I10's tab bar gives it a tab of its own. The model is made each time the sheet opens
/// (`AppModel.stagingModel`), so it reads Staging as it is then.
struct StagingScreen: View {
    @State private var model: CullModel<DecodedPreviewImage>
    /// *Import keepers* (I12), made with the model; nil leaves the action out.
    @State private var keepers: KeepersImport?
    @Environment(\.dismiss) private var dismiss

    init(model: CullModel<DecodedPreviewImage>, keepers: KeepersImport? = nil) {
        _model = State(initialValue: model)
        _keepers = State(initialValue: keepers)
    }

    var body: some View {
        NavigationStack {
            CullScreen(model: model, keepers: keepers)
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
/// under the list, with why. Pull to refresh reads Staging again; if that fails, the list stays and a strip says so.
///
/// *Import keepers* (I12; sections 7.5 and 7.6) is a toolbar button for all of Staging and a day row's context menu for
/// that day or its camera; a strip follows it, and at its end one confirmation (D2) offers to remove the staged copies,
/// with Remove as its default action. Staging is read again once it is done.
struct CullScreen: View {
    let model: CullModel<DecodedPreviewImage>
    var keepers: KeepersImport?
    @Environment(\.displayScale) private var displayScale
    /// The screen's size, for the previews' decode size.
    @State private var size: CGSize = .zero
    /// The loupe's cover; when it closes, however it closes, the model closes the loupe it showed.
    @State private var showsLoupe = false
    /// The loupe the cover shows, so its dismissal closes that one and never one opened since.
    @State private var presented: CullLoupe<DecodedPreviewImage>?
    /// The removal's one confirmation (D2), up while *Import keepers* offers it.
    @State private var confirmsRemoval = false

    var body: some View {
        keepersFlow(on: cullContent)
    }

    /// The Staging screen without *Import keepers*.
    private var cullContent: some View {
        content
            .navigationTitle(CullWording.title)
            .onGeometryChange(for: CGSize.self) { proxy in proxy.size } action: { size = $0 }
            .safeAreaInset(edge: .top) {
                if let notice = model.loadFailureNotice {
                    NoticeStrip(notice: notice) { model.dismissLoadFailure() }
                        .padding(.horizontal)
                }
            }
            .onChange(of: model.loadFailureNotice) { _, notice in notice?.announcement.post() }
            .task { await model.load() }
            .fullScreenCover(isPresented: $showsLoupe, onDismiss: {
                guard let dismissed = presented else { return }
                presented = nil
                let model = self.model
                Task { await model.closeLoupe(dismissed) }
            }) {
                if let loupe = presented {
                    LoupeView(loupe: loupe) { showsLoupe = false }
                }
            }
    }

    /// *Import keepers* on the screen (I12): its strip, its toolbar button and the removal's one confirmation (D2).
    private func keepersFlow(on view: some View) -> some View {
        view
            .safeAreaInset(edge: .bottom) {
                if let keepers, let notice = keepers.notice {
                    NoticeStrip(notice: notice) { keepers.dismiss() }
                        .padding(.horizontal)
                }
            }
            .onChange(of: keepers?.notice) { _, notice in notice?.announcement.post() }
            .toolbar {
                if let keepers, !model.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            importKeepers(.all, with: keepers)
                        } label: {
                            Label(KeepersWording.importKeepers, systemImage: "photo.badge.checkmark")
                                .labelStyle(.titleAndIcon)
                        }
                        .disabled(keepers.isBusy)
                        .accessibilityHint(KeepersWording.importKeepersHint)
                    }
                }
            }
            // Initially too: in the Staging tab (I10) the screen is made again on each visit while *Import keepers*
            // lives on, so a confirmation offered while another tab was shown is put up when the person comes back,
            // rather than leaving the flow busy with nothing on screen.
            .onChange(of: keepers?.confirmation, initial: true) { _, plan in confirmsRemoval = plan != nil }
            .confirmationDialog(keepers?.confirmation.map(KeepersWording.confirmTitle) ?? "",
                                isPresented: $confirmsRemoval, titleVisibility: .visible) {
                Button(KeepersWording.remove, role: .destructive) {
                    // Taken at once, before the dialog closes, so its closing doesn't read as Keep.
                    guard let keepers, keepers.acceptRemoval() else { return }
                    let model = self.model
                    Task {
                        await keepers.removeAccepted()
                        await model.load()
                    }
                }
                .keyboardShortcut(.defaultAction)
                Button(KeepersWording.keepInStaging, role: .cancel) { keepers?.keepStaged() }
            } message: {
                Text(keepers?.confirmation.map(KeepersWording.confirmMessage) ?? "")
            }
            // Closed any other way: the copies are kept.
            .onChange(of: confirmsRemoval) { _, shown in
                if !shown, keepers?.confirmation != nil { keepers?.keepStaged() }
            }
    }

    /// Starts *Import keepers* over the rows shown, and reads Staging again when it is done.
    private func importKeepers(_ scope: KeepersScope, with keepers: KeepersImport) {
        let model = self.model
        Task {
            await keepers.start(scope, in: model.rows)
            if keepers.confirmation == nil { await model.load() }
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
                                presented = model.loupe
                                showsLoupe = presented != nil
                            }
                            .contextMenu {
                                if let keepers {
                                    Button(KeepersWording.importDayKeepers, systemImage: "photo.badge.checkmark") {
                                        importKeepers(.day(row.id), with: keepers)
                                    }
                                    .disabled(keepers.isBusy)
                                    Button(KeepersWording.importCameraKeepers(section.name),
                                           systemImage: "photo.stack") {
                                        importKeepers(.camera(section.name), with: keepers)
                                    }
                                    .disabled(keepers.isBusy)
                                }
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
