import Foundation
import PTPKit

/// A commit the engine has started and not yet recorded: the pending-commit marker (backlog section 3.1, I20's
/// design). The engine writes it (`CatalogueStore.beginCommit(_:)`) before it calls the destination, and clears it in
/// the same store save as the rows (`finishCommit(_:writing:)`), so a commit whose catalogue write is lost (the app
/// killed after the save, or a store failing every try) is found again at the next pass (`pendingCommits()`) instead of
/// being imported a second time.
///
/// One marker per commit: a RAW+JPEG pair is one commit with two files. It names this iPhone's Photos library or
/// Staging root, so it is device-local.
public struct PendingCommit: Sendable, Hashable, Codable {
    /// Where the commit is sending its files.
    public enum Destination: Sendable, Hashable, Codable {
        case photos
        /// `folder`: the day folder relative to the root, "Staging/<camera>/<YYYY-MM-DD>".
        case staging(root: StagingRoot, folder: String)
    }

    /// A file's part in its commit, as PhotosBridge's `CommitUnit` gives it.
    public enum Role: String, Sendable, Hashable, Codable, CaseIterable {
        case single
        case raw
        case processed
    }

    /// One file of the commit.
    public struct File: Sendable, Hashable, Codable {
        public var identity: ObjectIdentity
        public var format: PTPMediaKind
        public var role: Role
        /// The exact `Date` the asset or the placed file was given (`StagedFile.captureDate`); nil when none was.
        public var assetDate: Date?

        public init(identity: ObjectIdentity, format: PTPMediaKind, role: Role, assetDate: Date? = nil) {
            self.identity = identity
            self.format = format
            self.role = role
            self.assetDate = assetDate
        }
    }

    /// The commit's token (the engine's `commitsInFlight` key).
    public var id: UUID
    public var jobID: UUID?
    public var destination: Destination
    /// A pair: the RAW first, as `CommitUnit.files`.
    public var files: [File]
    public var writtenAt: Date

    public init(id: UUID, jobID: UUID? = nil, destination: Destination, files: [File], writtenAt: Date) {
        self.id = id
        self.jobID = jobID
        self.destination = destination
        self.files = files
        self.writtenAt = writtenAt
    }
}

/// One row a commit that succeeded writes, in the same store save that clears its marker
/// (`CatalogueStore.finishCommit(_:writing:)`).
public enum CommitWrite: Sendable, Hashable {
    /// As `upsert(_:)` writes it: the stored row's staged copy is kept.
    case imported(CatalogueRecord)
    /// As `markStaged(_:format:at:)` writes it.
    case staged(ObjectIdentity, format: PTPMediaKind, at: StagedLocation)
}

/// The pending-commit rules, for both stores.
enum PendingCommitRule {
    /// The order `pendingCommits()` answers in: oldest first, ties by identifier.
    static func sorted(_ commits: some Sequence<PendingCommit>) -> [PendingCommit] {
        commits.sorted {
            $0.writtenAt != $1.writtenAt ? $0.writtenAt < $1.writtenAt : $0.id.uuidString < $1.id.uuidString
        }
    }
}

/// One `PendingCommitFile` row's columns as plain values: one row per file, grouped by `commitID` (section 3.1). So the
/// mapping is unit-tested on Linux; the SwiftData model only copies these. Enums are their raw strings.
struct PendingCommitColumns: Sendable, Hashable {
    var commitID: UUID?
    var jobID: UUID?
    var writtenAt: Date?
    /// "photos" or "staging".
    var destination: String
    /// `StagingRoot`'s raw value, for a staging commit.
    var stagingRoot: String?
    /// The day folder relative to the root, for a staging commit.
    var stagingFolder: String?
    // The file's identity as `CameraObject` keeps it.
    var cameraKey: String
    var identityKey: String
    var folder: String
    var filename: String
    var captureDate: String
    var size: Int64
    /// `PTPMediaKind`'s raw value.
    var format: String
    /// `PendingCommit.Role`'s raw value.
    var role: String
    var assetDate: Date?
}

extension PendingCommitColumns {
    /// The commit's rows, one per file, in its order.
    static func rows(of commit: PendingCommit) -> [PendingCommitColumns] {
        var destination = "photos"
        var root: String?
        var folder: String?
        if case let .staging(stagingRoot, stagingFolder) = commit.destination {
            destination = "staging"
            root = stagingRoot.rawValue
            folder = stagingFolder
        }
        return commit.files.map { file in
            let id = file.identity
            return PendingCommitColumns(commitID: commit.id, jobID: commit.jobID, writtenAt: commit.writtenAt,
                                        destination: destination, stagingRoot: root, stagingFolder: folder,
                                        cameraKey: id.camera.rawValue, identityKey: id.storageKey,
                                        folder: id.folder, filename: id.filename,
                                        captureDate: id.captureDate.rawValue, size: Int64(bitPattern: id.size),
                                        format: file.format.rawValue, role: file.role.rawValue,
                                        assetDate: file.assetDate)
        }
    }

    /// The commits `rows` hold, oldest first (`PendingCommitRule.sorted`). A commit's files come in their role's order
    /// (the RAW, then a single, then the processed file), which is `CommitUnit.files`' order.
    ///
    /// What a row holds that this build can't read is left out rather than guessed: a row with no commit identifier;
    /// a file whose capture date isn't one (the commit is kept with its other files, so it can still be resolved or
    /// abandoned by its identifier); and a commit whose destination is one a later version adds, which that version
    /// resolves.
    static func commits(from rows: some Sequence<PendingCommitColumns>) -> [PendingCommit] {
        var grouped: [UUID: [PendingCommitColumns]] = [:]
        for row in rows {
            guard let id = row.commitID else { continue }
            grouped[id, default: []].append(row)
        }
        var commits: [PendingCommit] = []
        for (id, rows) in grouped {
            let first = rows[0]
            let destination: PendingCommit.Destination
            switch first.destination {
            case "photos":
                destination = .photos
            case "staging":
                guard let raw = first.stagingRoot, let root = StagingRoot(rawValue: raw),
                      let folder = first.stagingFolder else { continue }
                destination = .staging(root: root, folder: folder)
            default:
                continue
            }
            let ordered = rows.sorted {
                $0.roleRank != $1.roleRank ? $0.roleRank < $1.roleRank : $0.identityKey < $1.identityKey
            }
            commits.append(PendingCommit(id: id, jobID: first.jobID, destination: destination,
                                         files: ordered.compactMap(\.file),
                                         writtenAt: rows.compactMap(\.writtenAt).min() ?? .distantPast))
        }
        return PendingCommitRule.sorted(commits)
    }

    /// The file this row holds; nil when its capture date isn't one (a row no version of this code writes).
    var file: PendingCommit.File? {
        guard let date = CaptureDate(rawValue: captureDate) else { return nil }
        let identity = ObjectIdentity(camera: CameraKey(rawValue: cameraKey), folder: folder, filename: filename,
                                      captureDate: date, size: UInt64(bitPattern: size))
        return PendingCommit.File(identity: identity, format: PTPMediaKind(rawValue: format) ?? .other,
                                  role: PendingCommit.Role(rawValue: role) ?? .single, assetDate: assetDate)
    }

    private var roleRank: Int {
        switch PendingCommit.Role(rawValue: role) {
        case .raw: 0
        case .single, nil: 1
        case .processed: 2
        }
    }
}
