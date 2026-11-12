#if canImport(SwiftUI) && canImport(UIKit) && canImport(UniformTypeIdentifiers) && os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The History tab (backlog section 4; D6): past jobs, newest first and grouped by day, for every camera or the one
/// chosen in the bar's menu, each with its counts, bytes, duration, outcome and where its files went, read by VoiceOver
/// as one line. A *Resumable* row's Resume, and a row's Re-run Failed Files, reopen Import with the files queued when the
/// camera is connected (otherwise a strip says to connect it); a stage job's row shows its Staging folder in a document
/// picker (no public API opens one album in Photos or a folder in Files, so a Photos job's row only names where its files
/// went). *Forget imports* for a camera is in the bar's menu, behind a confirmation. The list is read again when it
/// appears, when a job ends and on pull to refresh.
struct HistoryScreen: View {
    let model: HistoryModel
    let importer: ImportModel
    let showImport: @MainActor () -> Void
    /// The camera whose imports the confirmation is about, while it is up.
    @State private var forgetting: HistoryCamera?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            content
                .navigationTitle(HistoryWording.title)
                .toolbar {
                    if !model.forgettableCameras.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                if !model.cameras.isEmpty {
                                    Picker(HistoryWording.filterMenu, selection: $model.cameraFilter) {
                                        Text(HistoryWording.allCameras).tag(String?.none)
                                        ForEach(model.cameras) { camera in
                                            Text(camera.name).tag(String?.some(camera.name))
                                        }
                                    }
                                }
                                Menu(HistoryWording.forgetImportsAction) {
                                    ForEach(model.forgettableCameras) { camera in
                                        Button(camera.name, role: .destructive) { forgetting = camera }
                                    }
                                }
                            } label: {
                                Label(HistoryWording.filterMenu, systemImage: "line.3.horizontal.decrease.circle")
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .top) {
                    if let notice = model.notice {
                        NoticeStrip(notice: notice) { model.dismissNotice() }
                            .padding(.horizontal)
                    }
                }
                .onChange(of: model.notice) { _, notice in notice?.announcement.post() }
                .task { await model.load() }
                // A job that ends (or is dismissed) changes its row.
                .onChange(of: importer.isFinished) { _, _ in
                    let model = self.model
                    Task { await model.load() }
                }
                .confirmationDialog(forgetting.map { model.forgetConfirmation(for: $0).title } ?? "",
                                    isPresented: Binding(get: { forgetting != nil },
                                                         set: { if !$0 { forgetting = nil } }),
                                    titleVisibility: .visible, presenting: forgetting) { camera in
                    let confirmation = model.forgetConfirmation(for: camera)
                    Button(confirmation.confirm, role: .destructive) {
                        let model = self.model
                        Task { await model.forgetImports(of: camera) }
                    }
                    Button(confirmation.cancel, role: .cancel) {}
                } message: { camera in
                    Text(model.forgetConfirmation(for: camera).dialogMessage)
                }
        }
    }

    @ViewBuilder private var content: some View {
        if model.phase == .failed, model.isEmpty {
            ContentUnavailableView {
                Label(HistoryWording.loadFailedTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(HistoryWording.loadFailedDetail)
            } actions: {
                Button(HistoryWording.tryAgain) {
                    let model = self.model
                    Task { await model.load() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if model.phase == .loading, model.isEmpty {
            ProgressView(HistoryWording.loading)
        } else if model.isEmpty {
            ContentUnavailableView(HistoryWording.emptyTitle, systemImage: "clock",
                                   description: Text(HistoryWording.emptyDetail))
        } else {
            List {
                ForEach(model.sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            HistoryRowView(row: row, isBusy: model.busyJob == row.id,
                                           act: { act(on: row) }, openFolder: { openFolder(of: row) })
                        }
                    }
                }
            }
            .refreshable { await model.load() }
        }
    }

    private func act(on row: HistoryRow) {
        let model = self.model
        let showImport = self.showImport
        Task {
            if await model.act(on: row.id) { showImport() }
        }
    }

    private func openFolder(of row: HistoryRow) {
        let model = self.model
        Task {
            guard let url = await model.stagingFolder(for: row.id) else { return }
            StagingFolderPresenter.present(url)
        }
    }
}

/// One job: its title and time, how it ended, the counts, the bytes and duration, where its files went and, when it
/// applies, *Resumable* or the failures left with their button. VoiceOver reads it as one line, with the button and the
/// folder as actions.
private struct HistoryRowView: View {
    let row: HistoryRow
    let isBusy: Bool
    let act: () -> Void
    let openFolder: () -> Void

    private var actionTitle: String {
        if case .rerun = row.action { HistoryWording.rerun } else { HistoryWording.resume }
    }

    private var actionHint: String {
        if case .rerun = row.action { HistoryWording.rerunHint } else { HistoryWording.resumeHint }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.time)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(row.outcome)
                .font(.subheadline)
            Text(row.counts)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text([row.bytes, row.duration].compactMap(\.self).joined(separator: " · "))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if let place = row.place {
                Label(place, systemImage: row.opensStagingFolder ? "tray.full" : "photo.on.rectangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let line = row.actionLine {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isBusy {
                        ProgressView()
                    } else {
                        Button(actionTitle, action: act)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if row.opensStagingFolder { openFolder() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(row.action != nil ? actionHint : row.opensStagingFolder ? HistoryWording.openStagingHint : "")
        .accessibilityActions {
            if row.action != nil, !isBusy {
                Button(actionTitle, action: act)
            }
            if row.opensStagingFolder {
                Button(HistoryWording.showInStaging, action: openFolder)
            }
        }
    }
}

/// Shows a Staging folder in the system's document picker (`UIDocumentPickerViewController` with its `directoryURL`
/// set: public API, D6), presented from UIKit's top-most view controller as `SharePresenter` presents the share sheet.
/// Picking a file there does nothing more: the picker is for looking.
@MainActor
private enum StagingFolderPresenter {
    static func present(_ url: URL) {
        guard let presenter = topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.directoryURL = url
        picker.allowsMultipleSelection = false
        presenter.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
#endif
