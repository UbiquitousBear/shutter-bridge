import Catalogue
import Foundation
import Testing
@testable import AppUI

/// The rules behind the VoiceOver review of History, the loupe and Export Diagnostics (I17). The views are CI only;
/// VoiceOver itself is the bench's check.
@MainActor
@Suite("VoiceOver review: History, the loupe, Export Diagnostics")
struct AccessibilityReviewTests {
    private func row(action: HistoryRules.Action?, staged: Bool) -> HistoryRow {
        HistoryRow(id: UUID(), camera: CameraKey(rawValue: "cam"), cameraName: "ILCE-7CM2", purpose: .import,
                   title: "Import from ILCE-7CM2", time: "14:05", outcome: "Finished", counts: "48 imported",
                   bytes: "1.24 GB", duration: "12 min", place: nil, action: action, actionLine: nil,
                   opensStagingFolder: staged, accessibilityLabel: "")
    }

    @Test func aHistoryRowsDoubleTapDoesItsMainAction() {
        #expect(row(action: .resume(filesLeft: 12), staged: false).spokenDefault(isBusy: false) == .act)
        #expect(row(action: .rerun(failedLeft: 2), staged: true).spokenDefault(isBusy: false) == .act)
        // Busy reading the card for it: nothing until it's done, rather than a second queueing.
        #expect(row(action: .resume(filesLeft: nil), staged: false).spokenDefault(isBusy: true) == nil)
        #expect(row(action: nil, staged: true).spokenDefault(isBusy: false) == .openFolder)
        #expect(row(action: nil, staged: false).spokenDefault(isBusy: false) == nil)
        #expect(HistoryWording.busyValue == "Reading the card…")
    }

    @Test func theLoupeSaysWhatThePreviewIsDoingUntilItShows() {
        func status(preview: Bool = false, none: Bool = false, failed: Bool = false,
                    download: DownloadProgress? = nil) -> String? {
            CullWording.previewStatusSpoken(hasPreview: preview, hasNoPreview: none, previewFailed: failed,
                                            download: download)
        }
        #expect(status(preview: true, download: DownloadProgress(fraction: 0.4)) == nil)
        #expect(status(none: true) == "There's no preview for this file.")
        #expect(status(failed: true) == "Couldn't Show This Photo")
        #expect(status(download: DownloadProgress(fraction: 0.4)) == "Downloading from iCloud Drive, 40 percent")
        #expect(status(download: DownloadProgress(fraction: 1.7)) == "Downloading from iCloud Drive, 100 percent")
        #expect(status(download: DownloadProgress(fraction: nil)) == "Downloading from iCloud Drive…")
        #expect(status(download: DownloadProgress(fraction: .nan)) == "Downloading from iCloud Drive…")
        #expect(status() == "Loading the preview")
    }

    @Test func exportDiagnosticsAnnouncesThePreparingAndAFailure() async {
        let exporter = HeldExporter()
        let model = SettingsModel(diagnostics: exporter)
        #expect(model.exportAnnouncement == nil)
        let export = Task { await model.exportDiagnostics() }
        #expect(await eventually { model.exportState == .preparing })
        #expect(model.exportAnnouncement == StatusAnnouncement("Preparing the file…"))
        exporter.release()
        await export.value
        #expect(model.exportState == .failed(DiagnosticsWording.failed))
        #expect(model.exportAnnouncement
            == StatusAnnouncement("The diagnostics file couldn't be made. Try again.", priority: .high))
        model.exportCouldNotBePresented()
        #expect(model.exportAnnouncement?.text == DiagnosticsWording.couldNotShare)
    }
}

/// An exporter that waits until released, then fails: the export row's two states VoiceOver is told about.
private final class HeldExporter: DiagnosticsExporting, Sendable {
    private struct Failure: Error {}
    private let gate: AsyncStream<Void>
    private let opener: AsyncStream<Void>.Continuation

    init() { (gate, opener) = AsyncStream.makeStream() }

    func release() {
        opener.yield()
        opener.finish()
    }

    func makeExport() async throws -> DiagnosticsExport {
        for await _ in gate { break }
        throw Failure()
    }

    func discard(_ export: DiagnosticsExport) {}
}
