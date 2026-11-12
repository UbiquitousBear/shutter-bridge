import Foundation
import Observation
import PhotosBridge

/// The Settings screen's model (backlog section 6; Shamil, 11 Nov). There is no destination choice: since 11 Nov the
/// Import button offers *Import to Photos* and *Stage* at each import and remembers the last one used (`ImportModel`),
/// which replaced the app-wide Photos-or-Files setting decided on 8 Nov.
///
/// The screen shows where staging goes (`stagingLocation`: iCloud Drive › Shutter Bridge › Staging, or On My iPhone ›
/// Shutter Bridge › Staging) and, when it is on this iPhone, why (`stagingFallbackLine`). It also says what *Import to
/// Photos* will do when Photos access is off or restricted (`forcedStagingLine`, with Open Settings when
/// `offersPhotosSettingsLink`). Both are read in `refresh()`, when the screen appears and when the app comes back to
/// the foreground (the person may have changed them in Settings). The rules are the import's
/// (`DestinationDecision.resolve(choice:authorisation:staging:)`); nothing here changes them. It is reached from the
/// Cameras screen's toolbar.
///
/// The Staging section also says when staged files haven't uploaded to iCloud Drive, the full iCloud quota first
/// (`uploadProblemLine`), or else how many are waiting to (`uploadWaitingLine`), from the app's `StagedUploadMonitor`
/// (staging PR 7). The screen reads it again when it appears (`refreshUploads()`); the app reads it when it comes to
/// the front and when a job starts and ends. `refresh()` doesn't read it, because the app awaits `refresh()` at each
/// activation and the upload read mustn't hold that up.
///
/// **Export Diagnostics…** (I8) makes the plain-text archive through `DiagnosticsExporting` and hands its file to the share
/// sheet, which the screen presents; the file's folder is removed once the sheet has closed, however it closed, and if the
/// person leaves Settings first. Nothing is sent anywhere.
@MainActor
@Observable
public final class SettingsModel {
    /// Photos access as last read; nil before the first read, or without a way to read it.
    public private(set) var photosAccess: PhotosAuthorisation?
    /// Where staging goes, as last read; nil before the first read, or without a staging locator.
    public private(set) var stagingPlace: StagingPlace?

    /// Where the diagnostics export is, for the screen.
    public enum ExportState: Sendable, Hashable {
        case idle
        /// The archive is being built.
        case preparing
        /// Written and waiting for the share sheet, which the screen presents.
        case ready(DiagnosticsExport)
        /// The archive couldn't be made, or the share sheet couldn't be shown.
        case failed(String)
    }

    public private(set) var exportState: ExportState = .idle

    @ObservationIgnored private let photos: (any PhotosAuthorising)?
    @ObservationIgnored private let staging: (any StagingLocator)?
    @ObservationIgnored private let diagnostics: (any DiagnosticsExporting)?
    @ObservationIgnored private let uploads: StagedUploadMonitor?
    /// Counts the times the person left Settings, so an export that finishes after that is discarded, not shown.
    @ObservationIgnored private var exportEpoch = 0

    /// - Parameters:
    ///   - photos: Reads Photos access (never asks); without it the screen says nothing about access.
    ///   - staging: Finds where staging goes (the app's `ImportDestinationMaking`); without it the screen says
    ///     nothing about staging.
    ///   - diagnostics: Makes the diagnostics export; without it the screen has no export row.
    ///   - uploads: Whether staged files in iCloud Drive have uploaded; without it the screen says nothing about
    ///     uploads.
    public init(photos: (any PhotosAuthorising)? = nil, staging: (any StagingLocator)? = nil,
                diagnostics: (any DiagnosticsExporting)? = nil, uploads: StagedUploadMonitor? = nil) {
        self.photos = photos
        self.staging = staging
        self.diagnostics = diagnostics
        self.uploads = uploads
    }

    // MARK: Diagnostics export

    /// Whether the screen offers *Export Diagnostics…*.
    public var offersDiagnosticsExport: Bool { diagnostics != nil }

    /// Whether the row is busy: the file is being made, or the share sheet is up.
    public var isExporting: Bool {
        switch exportState {
        case .preparing, .ready: true
        case .idle, .failed: false
        }
    }

    /// Builds the archive. Does nothing while one is being made or shared. When it is ready `exportState` is `.ready`, and
    /// the screen presents the share sheet and calls `exportFinished()` or `exportCouldNotBePresented()`; when the person
    /// left Settings meanwhile, the file is removed at once and nothing is shown.
    public func exportDiagnostics() async {
        guard let diagnostics, !isExporting else { return }
        exportState = .preparing
        let epoch = exportEpoch
        do {
            let export = try await diagnostics.makeExport()
            if epoch == exportEpoch {
                exportState = .ready(export)
            } else {
                diagnostics.discard(export)
            }
        } catch {
            if epoch == exportEpoch { exportState = .failed(DiagnosticsWording.failed) }
        }
    }

    /// The share sheet closed, shared or not: the file's folder is removed.
    public func exportFinished() {
        discardReadyExport()
        exportState = .idle
    }

    /// The share sheet couldn't be shown: the folder is removed and the row says so.
    public func exportCouldNotBePresented() {
        discardReadyExport()
        exportState = .failed(DiagnosticsWording.couldNotShare)
    }

    /// The person left Settings: a file that is ready is removed, one being made is removed when it is done.
    public func settingsClosed() {
        exportEpoch += 1
        discardReadyExport()
        exportState = .idle
    }

    private func discardReadyExport() {
        if case let .ready(export) = exportState { diagnostics?.discard(export) }
    }

    /// Reads Photos access and where staging goes again. Never asks for Photos access: that happens at the first
    /// *Import to Photos*.
    public func refresh() async {
        if let photos {
            let read = await photos.authorisation()
            if read != photosAccess { photosAccess = read }
        }
        if let staging {
            let place = await staging.locate().place
            if place != stagingPlace { stagingPlace = place }
        }
    }

    /// Where staging goes, as Files names it; nil before it is read.
    public var stagingLocation: String? { stagingPlace.map(SettingsWording.stagingLocation) }

    /// Why staging is on this iPhone rather than in iCloud Drive; nil when it is in iCloud Drive or not read yet.
    public var stagingFallbackLine: String? { stagingPlace.flatMap(SettingsWording.stagingFallback) }

    /// Why *Import to Photos* stages instead: access denied or restricted; nil when it imports to Photos (or access
    /// isn't read yet).
    public var forcedStagingReason: StagingReason? {
        guard let photosAccess else { return nil }
        let reason = DestinationDecision.resolve(choice: .photos, authorisation: photosAccess,
                                                 staging: stagingPlace ?? .iCloudDrive).stagingReason
        return reason?.isForced == true ? reason : nil
    }

    /// "Photos access is off, so Import to Photos stages the photos instead." when access overrides it.
    public var forcedStagingLine: String? { forcedStagingReason.flatMap(SettingsWording.forcedStaging) }

    /// Open Settings beside that line: for a denial only (a restriction can't be changed there).
    public var offersPhotosSettingsLink: Bool { forcedStagingReason?.offersSettingsLink == true }

    /// Staged files that haven't uploaded to iCloud Drive, and why: "Your iCloud storage is full, so 2 staged files
    /// haven't uploaded to iCloud Drive…"; nil when there is no problem, or nothing to say.
    public var uploadProblemLine: String? { uploads?.problemLine }

    /// "3 staged files are waiting to upload to iCloud Drive.", when there is no problem line.
    public var uploadWaitingLine: String? { uploads?.waitingLine }

    /// Reads the staged files' upload states again (the screen, when it appears).
    public func refreshUploads() async { await uploads?.refresh() }
}
