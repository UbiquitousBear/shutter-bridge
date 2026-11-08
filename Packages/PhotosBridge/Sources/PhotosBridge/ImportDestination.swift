import Foundation

/// The two places an import can go (backlog section 5).
public enum DestinationKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// The Photos library, one asset per photo, in an album.
    case photos
    /// A folder in the app's Documents folder, shown in Files under On My iPhone › the app: the path when Photos
    /// access is denied (decision 9). Whether it can also be chosen when Photos is allowed is open, for Shamil.
    case filesFolder
}

/// A downloaded file waiting to be committed. Staged as complete-until-first-unlock, never `complete`, so a save
/// in the seconds after the phone locks still works (decision 9).
public struct StagedFile: Sendable, Hashable {
    /// The temporary file the link wrote.
    public var url: URL
    /// The camera's file name, which a Files import keeps.
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

/// Where a file landed in the app's Documents folder. Relative, because the container's absolute path changes
/// between installs and updates.
public struct FileLocation: Sendable, Hashable, Codable, CustomStringConvertible {
    public var relativePath: String

    public init(relativePath: String) { self.relativePath = relativePath }

    public var description: String { relativePath }
}

/// What a commit produced, for the catalogue to store.
public enum ImportResult: Sendable, Hashable {
    /// The Photos asset's `localIdentifier`; a pair is one asset.
    case photosAsset(localIdentifier: String)
    /// The files written to the Files folder; a pair keeps both files, under their own names.
    case files([FileLocation])
}

/// Why a commit failed.
public enum ImportDestinationFailure: Error, Sendable, Hashable {
    /// Photos refused the save because access is denied (`PHPhotosErrorDomain` 3311, `accessUserDenied`). Not a
    /// failed file: the engine sends this file and the rest to the Files folder (decision 9).
    case photosAccessDenied
    /// The phone has no room.
    case notEnoughSpace
    /// The staged file is gone (purged from the temporary folder, for one).
    case stagedFileMissing
    /// Anything else; `detail` is for the log.
    case rejected(detail: String)
}

/// Somewhere an import can go. The engine takes one per job, so the same pause, continue and retry rules apply to
/// Photos and to Files (backlog section 3).
public protocol ImportDestination: Sendable {
    var kind: DestinationKind { get }

    /// Moves or saves the unit's files and says where they went. The staged files are consumed: a Files import
    /// moves them into place, never copies (backlog section 3), and never overwrites a file of the same name.
    func commit(_ unit: CommitUnit) async throws(ImportDestinationFailure) -> ImportResult
}
