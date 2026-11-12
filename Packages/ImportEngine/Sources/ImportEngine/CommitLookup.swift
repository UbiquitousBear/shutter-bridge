import Catalogue
import Foundation
import PhotosBridge

// Resolving pending-commit markers (backlog section 3.1, I15): how the engine asks whether a commit whose catalogue
// write was lost reached its destination, and what a pass did. Declared here, where both `Catalogue` and `PhotosBridge`
// are seen; the app composes the production lookup (`LibraryCommitLookup` over `SystemPhotoLibrary` and its staging
// locator), and Linux tests answer from what a recording destination committed.

/// Looks for what a pending commit would have left: the asset in Photos, or the files in their Staging day folder.
/// Never writes to Photos or to Staging; the engine writes only to the catalogue with the answer.
public protocol CommitLookup: Sendable {
    func look(for pending: PendingCommit) async -> CommitLookupAnswer
}

/// What a lookup found for one marker.
public enum CommitLookupAnswer: Sendable, Hashable {
    /// The commit reached its destination: the rows to write, in one save with the marker's removal
    /// (`PendingCommit.importedWrites(localIdentifier:)` or `stagedWrites(at:)`).
    case found([CommitWrite])
    /// It didn't (or nothing shows it did): the marker is removed and the files read as their rows say.
    /// `underLimitedAccess`: possibly there but out of sight, said as a possible duplicate.
    case notFound(underLimitedAccess: Bool)
    /// Can't tell yet (Photos access not given, iCloud Drive away): the marker waits for a later pass.
    case cannotLook
}

/// Answers `.cannotLook` for every marker: markers wait, nothing is guessed. The engine's default.
public struct NoCommitLookup: CommitLookup {
    public init() {}
    public func look(for pending: PendingCommit) async -> CommitLookupAnswer { .cannotLook }
}

/// What one `resolvePendingCommits()` pass did, by commit (a pair counts once).
public struct PendingCommitReport: Sendable, Hashable {
    /// Commits whose `.imported` rows were written: found in Photos, or this launch's own, written from memory.
    public var foundInPhotos: Int
    /// Commits whose staged copies were recorded: found in Staging, or this launch's own, written from memory.
    public var foundInStaging: Int
    /// Of the two above, this launch's own commits whose `finishCommit` had failed, written from memory with no lookup.
    public var replayed: Int
    /// Commits not found: the marker removed, the files read as their rows say.
    public var notFound: Int
    /// Of `notFound`, those not found under Limited Access (or by the fallback): possibly in Photos twice now.
    public var possibleDuplicates: Int
    /// Markers kept for a later pass: the lookup can't look yet, or the catalogue refused the write.
    public var waiting: Int

    public init(foundInPhotos: Int = 0, foundInStaging: Int = 0, replayed: Int = 0, notFound: Int = 0,
                possibleDuplicates: Int = 0, waiting: Int = 0) {
        self.foundInPhotos = foundInPhotos
        self.foundInStaging = foundInStaging
        self.replayed = replayed
        self.notFound = notFound
        self.possibleDuplicates = possibleDuplicates
        self.waiting = waiting
    }

    /// Whether rows were written, so what Browse shows as imported or staged may have changed.
    public var changedRows: Bool { foundInPhotos + foundInStaging > 0 }

    /// Whether the pass resolved anything (rows written or markers removed).
    public var resolvedAny: Bool { changedRows || notFound > 0 }
}

/// Why a marker's resolution came out as it did, for the trace (`EngineTrace.pendingCommitResolved`).
public enum PendingCommitResolution: String, Sendable, Hashable, CaseIterable {
    /// This launch's own commit, whose rows were kept in memory when `finishCommit` failed: written now.
    case replayed
    case foundInPhotos
    case foundInStaging
    case notFound
    /// Not found under Limited Access: the photo may now be in Photos twice.
    case possibleDuplicate
    /// Kept for a later pass: the lookup can't look yet, or the catalogue refused the write.
    case waiting
}

extension PendingCommit {
    /// The rows of a Photos commit found as `localIdentifier`: each file `.imported` there (a pair's two files share
    /// the one asset), as the commit would have written them.
    public func importedWrites(localIdentifier: String) -> [CommitWrite] {
        files.map {
            .imported(CatalogueRecord(identity: $0.identity, format: $0.format, state: .imported,
                                      location: .photosAsset(localIdentifier: localIdentifier)))
        }
    }

    /// The rows of a stage commit found at `paths` (relative to its root, one per file in the commit's order), staged
    /// when the marker was written; nil for a commit that isn't a stage commit or paths that don't match its files.
    public func stagedWrites(at paths: [FileLocation]) -> [CommitWrite]? {
        guard case let .staging(root, _) = destination, paths.count == files.count else { return nil }
        return zip(files, paths).map { file, path in
            .staged(file.identity, format: file.format,
                    at: StagedLocation(root: root, relativePath: path.relativePath, stagedAt: writtenAt))
        }
    }

    /// The asset the save would have created for this commit, as `AssetCreation(unit:options:)` lays it out (a pair's
    /// processed file as `.photo`, its RAW as `.alternatePhoto`), with no files behind it: for a query.
    var assetCreation: AssetCreation {
        let staged = files.map {
            StagedFile(url: URL(fileURLWithPath: "/dev/null"), filename: $0.identity.filename, captureDate: $0.assetDate)
        }
        let unit: CommitUnit = staged.count == 2 && files[0].role == .raw
            ? .pair(raw: staged[0], processed: staged[1]) : .single(staged[0])
        return AssetCreation(unit: unit, options: PhotosImportOptions())
    }
}

/// The production lookup (backlog section 3.1): a Photos commit by `findAsset` in the library, a stage commit by
/// `StagedCopyFinder` in its day folder under the root the marker names (the app's Documents folder on this iPhone,
/// or the iCloud container's Documents folder from the locator now; a marker for iCloud Drive while iCloud Drive
/// isn't available can't be looked up yet). Pure over its parts, so it is tested on Linux with a fake library and
/// temporary folders; the app gives it `SystemPhotoLibrary` and `UbiquityStagingLocator`.
public struct LibraryCommitLookup: CommitLookup {
    let library: any PhotoLibraryClient
    let staging: any StagingLocator
    let onThisIPhone: URL
    let finder: StagedCopyFinder

    /// - Parameters:
    ///   - onThisIPhone: The app's Documents folder: the staging root on this iPhone.
    public init(library: any PhotoLibraryClient, staging: any StagingLocator, onThisIPhone: URL,
                finder: StagedCopyFinder = StagedCopyFinder()) {
        self.library = library
        self.staging = staging
        self.onThisIPhone = onThisIPhone
        self.finder = finder
    }

    public func look(for pending: PendingCommit) async -> CommitLookupAnswer {
        guard !pending.files.isEmpty else { return .notFound(underLimitedAccess: false) }
        switch pending.destination {
        case .photos:
            // A file with no capture date has no identity, so the engine never commits one; were a marker to name
            // one, no fetch by date could find it, and not found is the side that can't lose a photo.
            guard let query = AssetQuery(pending.assetCreation) else { return .notFound(underLimitedAccess: false) }
            switch await library.findAsset(query) {
            case let .found(localIdentifier): return .found(pending.importedWrites(localIdentifier: localIdentifier))
            case let .notFound(limited): return .notFound(underLimitedAccess: limited)
            case .cannotSearch: return .cannotLook
            }
        case let .staging(root, folder):
            let rootURL: URL
            switch root {
            case .onThisIPhone:
                rootURL = onThisIPhone
            case .iCloudDrive:
                guard let documents = await staging.locate().iCloudDocuments else { return .cannotLook }
                rootURL = documents
            }
            let wanted = pending.files.map {
                StagedCopyFinder.Wanted(filename: $0.identity.filename, size: $0.identity.size,
                                        modificationDate: $0.assetDate)
            }
            guard let paths = finder.find(wanted, in: folder, under: rootURL),
                  let writes = pending.stagedWrites(at: paths) else { return .notFound(underLimitedAccess: false) }
            return .found(writes)
        }
    }
}
