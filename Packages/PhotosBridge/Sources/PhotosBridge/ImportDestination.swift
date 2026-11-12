import Foundation

/// The two places an import can go, which are also the two choices Browse's Import button offers at each import
/// (Shamil, 11 Nov): *Import to Photos* and *Stage*.
public enum DestinationKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// The Photos library, one asset per photo, in an album (*Import to Photos*; "Import only": staging untouched).
    case photos
    /// The staging folder (*Stage*; "Stage only"): the camera's originals, byte for byte, in
    /// iCloud Drive › Shutter Bridge › Staging › camera › capture day, or in On My iPhone › Shutter Bridge › Staging
    /// when iCloud Drive isn't available. Never asks for Photos access and never writes to Photos. Chosen at the
    /// import, or forced when Photos access is denied or restricted (Shamil, 11 Nov; it replaced the Files folder of
    /// 8 Nov).
    case staging

    /// Lenient, so nothing stored by an earlier build fails to read: `"filesFolder"`, the Files folder that staging
    /// replaced (Shamil, 11 Nov), reads as `.staging`, so a person who had chosen Files gets Stage. Anything else
    /// unknown is nil, and a reader falls back to its own default (`DestinationSetting` reads Photos).
    public init?(rawValue: String) {
        switch rawValue {
        case "photos": self = .photos
        case "staging", Self.legacyFilesFolder: self = .staging
        default: return nil
        }
    }

    /// The raw value builds before 11 Nov stored for the Files folder.
    static let legacyFilesFolder = "filesFolder"
}

/// A downloaded file waiting to be committed. Staged as complete-until-first-unlock, never `complete`, so a save
/// in the seconds after the phone locks still works (decision 9).
public struct StagedFile: Sendable, Hashable {
    /// The temporary file the link wrote.
    public var url: URL
    /// The camera's file name, which staging keeps.
    public var filename: String
    /// When the photo was taken, set on the Photos asset.
    public var captureDate: Date?

    public init(url: URL, filename: String, captureDate: Date?) {
        self.url = url
        self.filename = filename
        self.captureDate = captureDate
    }
}

/// What one commit takes: a lone file, or a RAW+JPEG (or RAW+HEIF) pair that Photos makes into one asset. Which
/// files pair is the pairing rule's call (same folder, same stem, within 1 s; section 5), not the destination's.
public enum CommitUnit: Sendable, Hashable {
    case single(StagedFile)
    case pair(raw: StagedFile, processed: StagedFile)

    /// The unit's files: the RAW first for a pair.
    public var files: [StagedFile] {
        switch self {
        case let .single(f): [f]
        case let .pair(raw, processed): [raw, processed]
        }
    }
}

/// Where a staged file landed, relative to the staging root (the Documents folder of the app's iCloud Drive
/// container, or the app's own Documents folder; see `StagingFolderDestination`), for example
/// "Staging/ILCE-7CM2/2026-11-08/DSC00001.ARW". Relative, because the container's absolute path changes between
/// installs and updates.
public struct FileLocation: Sendable, Hashable, Codable, CustomStringConvertible {
    public var relativePath: String

    public init(relativePath: String) { self.relativePath = relativePath }

    public var description: String { relativePath }

    /// The file's URL, given the root it is relative to as it is now.
    public func url(in root: URL) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: false)
    }
}

/// What a commit produced, for the catalogue to store.
public enum ImportResult: Sendable, Hashable {
    /// The Photos asset's `localIdentifier`; a pair is one asset.
    case photosAsset(localIdentifier: String)
    /// The files written to the staging folder, in the unit's order, relative to the staging root; a pair keeps both
    /// files, under their own names. `place` says which root: iCloud Drive, or this iPhone.
    case staged(place: StagingPlace, [FileLocation])
}

/// Why a commit failed.
public enum ImportDestinationFailure: Error, Sendable, Hashable {
    /// Photos refused the save because access is denied (`PHPhotosErrorDomain` 3311, `accessUserDenied`). Not a
    /// failed file: the engine stages this file and the rest instead (decision 9; Shamil, 11 Nov).
    case photosAccessDenied
    /// The phone has no room.
    case notEnoughSpace
    /// The staged file is gone (purged from the temporary folder, for one).
    case stagedFileMissing
    /// The iCloud Drive container went away while staging (signed out, or iCloud Drive turned off, mid-job:
    /// `NSCocoaErrorDomain` 4353, `NSUbiquitousFileUnavailableError`). Not a failed file: the engine switches once to
    /// the staging folder on this iPhone for this file and the rest, and says so (Shamil, 11 Nov).
    case stagingUnavailable
    /// Anything else; `detail` is for the log.
    case rejected(detail: String)
}

/// Where a commit is about to send its files, said before the commit: what the engine's pending-commit marker records
/// (backlog section 3.1), so a commit whose catalogue write is lost can be looked for there.
public enum CommitTarget: Sendable, Hashable {
    /// The Photos library (which album doesn't matter: the lookup is library-wide).
    case photosLibrary
    /// A day folder of the staging folder: `place` says which root, and `folderPath` is the folder relative to that
    /// root, "Staging/<camera>/<YYYY-MM-DD>", the folder the commit's files are placed in (under their own names, or
    /// numbered ones when the names are taken).
    case stagingFolder(place: StagingPlace, folderPath: String)
}

/// Somewhere an import can go. The engine takes one per job, so the same pause, continue and retry rules apply to
/// Photos and to staging (backlog section 3).
public protocol ImportDestination: Sendable {
    var kind: DestinationKind { get }

    /// Moves or saves the unit's files and says where they went. The staged files are consumed: staging moves them
    /// into place, never copies (backlog section 3), and never overwrites a file of the same name.
    func commit(_ unit: CommitUnit) async throws(ImportDestinationFailure) -> ImportResult

    /// Where `commit(_:)` would send `unit` if it were called now: the engine writes it into the commit's marker before
    /// it calls `commit(_:)` (backlog section 3.1). Synchronous and nonisolated, with no side effect; a folder
    /// destination computes it with the same function its commit uses, so the two can't drift.
    func commitTarget(for unit: CommitUnit) -> CommitTarget

    /// The Photos album this destination's saves have gone into, for the job's History record (backlog section 4): its
    /// `localIdentifier`, or nil while no save has gone into one. Always nil for a staging folder. Read by the engine
    /// after each successful commit; it never creates, fetches or asks for anything.
    func filedAlbumIdentifier() async -> String?
}

extension ImportDestination {
    /// No album: the staging folders, and destinations that don't file into one.
    public func filedAlbumIdentifier() async -> String? { nil }
}
