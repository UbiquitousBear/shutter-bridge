import Foundation

/// One job as History keeps it (backlog section 4; D6, Shamil, 11 Nov): what it was for, where its files went, how far
/// it got and how it ended, and enough of its selection to queue it again (*Resumable*) or re-run its failures. Written
/// with `CatalogueStore.recordJob(_:)` and `updateJob(_:_:)`, read with `job(_:)` and `jobs(camera:)`.
///
/// The catalogue sits below the engine, so the values here are the catalogue's own: the engine (I9) maps its
/// `ImportSelection`, `JobOutcome`, `DestinationKind` and `CameraCarrier` to them. The counts are the job's last
/// `ImportProgress`. A record with no `finishedAt` is a job that is running, or that the app's end interrupted.
///
/// Nothing in it names a network, an address or a serial; the camera is its key (`CameraKey`, already private).
public struct JobRecord: Sendable, Hashable {
    /// What the job was for (D6): an import to Photos, a stage job into Staging, or *Import keepers* from Staging.
    public enum Purpose: String, Sendable, Hashable, Codable, CaseIterable {
        case `import`
        case stage
        case keepers
    }

    /// Where the job's files went: Photos, or Staging (a stage job, or an import job Photos refused and staged).
    public enum Destination: String, Sendable, Hashable, Codable, CaseIterable {
        case photos
        case staging
    }

    /// How the files reached the phone: CameraTransport's carriers, and Staging itself for a keepers job (section
    /// 7.2's `StagingFolderLink`).
    public enum Carrier: String, Sendable, Hashable, Codable, CaseIterable {
        case usb
        case wifi
        case staging
    }

    /// What was asked for, as the engine's `ImportSelection` says it, with the picked files by content key (names,
    /// seconds and sizes) rather than link handles, which don't survive a replug.
    public enum Selection: Sendable, Hashable {
        /// Every new file.
        case allNew
        /// New files taken in this range.
        case dateRange(ClosedRange<Date>)
        /// Files picked in Browse (`ImportSelection.items`).
        case picked([ObjectIdentity.ContentKey])
        /// Files picked by *Select all new* (`ImportSelection.newItems`): only new ones are copied.
        case pickedNew([ObjectIdentity.ContentKey])
    }

    /// How the job ended, as the engine's `JobOutcome` says it.
    public enum Outcome: Sendable, Hashable {
        case completed
        case cancelled
        /// A failure that stopped the job; `reason` is the engine's name for its kind (`CameraLinkFailure.Kind`),
        /// for wording, never shown as it is.
        case stopped(reason: String)
        case catalogueUnavailable
    }

    /// The engine's job identifier.
    public var id: UUID
    /// The one camera key the job wrote rows under (a keepers job: the staged files' key).
    public var camera: CameraKey
    public var purpose: Purpose
    /// Nil until the job knows (Photos access asked, for example).
    public var destination: Destination?
    public var carrier: Carrier?
    /// The Photos album's local identifier, when the job had one; kept for when iOS offers a way to open it.
    public var albumIdentifier: String?
    public var selection: Selection
    public var startedAt: Date
    /// Nil while the job runs, and for a job the app's end interrupted (History reads it as *Stopped early*).
    public var finishedAt: Date?
    /// Nil while the job runs or when it was interrupted.
    public var outcome: Outcome?
    /// The job's last `ImportProgress`, field by field.
    public var filesTotal: Int
    public var filesImported: Int
    public var filesStaged: Int
    public var filesSkipped: Int
    public var filesFailed: Int
    public var bytesTotal: UInt64
    public var bytesDone: UInt64
    /// The files that failed after their retries, by content key, for *Re-run* (section 4).
    public var failedFiles: [ObjectIdentity.ContentKey]

    public init(id: UUID, camera: CameraKey, purpose: Purpose = .import, destination: Destination? = nil,
                carrier: Carrier? = nil, albumIdentifier: String? = nil, selection: Selection = .allNew,
                startedAt: Date, finishedAt: Date? = nil, outcome: Outcome? = nil, filesTotal: Int = 0,
                filesImported: Int = 0, filesStaged: Int = 0, filesSkipped: Int = 0, filesFailed: Int = 0,
                bytesTotal: UInt64 = 0, bytesDone: UInt64 = 0, failedFiles: [ObjectIdentity.ContentKey] = []) {
        self.id = id
        self.camera = camera
        self.purpose = purpose
        self.destination = destination
        self.carrier = carrier
        self.albumIdentifier = albumIdentifier
        self.selection = selection
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.filesTotal = filesTotal
        self.filesImported = filesImported
        self.filesStaged = filesStaged
        self.filesSkipped = filesSkipped
        self.filesFailed = filesFailed
        self.bytesTotal = bytesTotal
        self.bytesDone = bytesDone
        self.failedFiles = failedFiles
    }
}

/// The order `jobs(camera:)` answers in, for both stores: newest first, ties by identifier.
enum JobOrder {
    static func sorted(_ jobs: some Sequence<JobRecord>) -> [JobRecord] {
        jobs.sorted {
            $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : $0.id.uuidString < $1.id.uuidString
        }
    }
}

/// One `ImportJob` row's columns as plain values (the counterpart of `CatalogueRow` for `JobRecord`), so the mapping is
/// unit-tested on Linux; the SwiftData model only copies these. Version 1's columns keep their meaning (`selection` is
/// still "all-new", "range" or "picked"); everything version 4 adds is optional, because the stage from version 3 is
/// lightweight and rows written before it have none. Enums are their raw strings, so a value a later version adds
/// reads back as a fallback, not a failure.
struct JobColumns: Sendable, Hashable {
    // Version 1's.
    var jobID: UUID
    var startedAt: Date
    var finishedAt: Date?
    /// "all-new", "range", "picked" or (new in version 4) "picked-new".
    var selection: String
    var bytesTotal: Int64
    var bytesDone: Int64
    /// "completed", "cancelled", "catalogueUnavailable" or "stopped:<reason>"; nil while running or interrupted.
    var outcome: String?
    // New in version 4.
    /// The camera's key, repeated from the relationship, as `CameraObject.cameraKey` is.
    var cameraKey: String?
    var purpose: String?
    var destination: String?
    var carrier: String?
    var albumIdentifier: String?
    var rangeStart: Date?
    var rangeEnd: Date?
    /// The picked files' content keys (`StoredContentKeys`).
    var pickedKeys: Data?
    /// The failed files' content keys (`StoredContentKeys`).
    var failedKeys: Data?
    var filesTotal: Int?
    var filesImported: Int?
    var filesStaged: Int?
    var filesSkipped: Int?
    var filesFailed: Int?
}

extension JobColumns {
    init(_ job: JobRecord) {
        var selection: String
        var rangeStart: Date?
        var rangeEnd: Date?
        var picked: [ObjectIdentity.ContentKey]?
        switch job.selection {
        case .allNew:
            selection = "all-new"
        case let .dateRange(range):
            selection = "range"
            rangeStart = range.lowerBound
            rangeEnd = range.upperBound
        case let .picked(keys):
            selection = "picked"
            picked = keys
        case let .pickedNew(keys):
            selection = "picked-new"
            picked = keys
        }
        let outcome: String? = switch job.outcome {
        case nil: nil
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .catalogueUnavailable: "catalogueUnavailable"
        case let .stopped(reason): "stopped:" + reason
        }
        self.init(jobID: job.id, startedAt: job.startedAt, finishedAt: job.finishedAt, selection: selection,
                  bytesTotal: Int64(bitPattern: job.bytesTotal), bytesDone: Int64(bitPattern: job.bytesDone),
                  outcome: outcome, cameraKey: job.camera.rawValue, purpose: job.purpose.rawValue,
                  destination: job.destination?.rawValue, carrier: job.carrier?.rawValue,
                  albumIdentifier: job.albumIdentifier, rangeStart: rangeStart, rangeEnd: rangeEnd,
                  pickedKeys: picked.map(StoredContentKeys.encode),
                  failedKeys: job.failedFiles.isEmpty ? nil : StoredContentKeys.encode(job.failedFiles),
                  filesTotal: job.filesTotal, filesImported: job.filesImported, filesStaged: job.filesStaged,
                  filesSkipped: job.filesSkipped, filesFailed: job.filesFailed)
    }

    /// The record this row holds. `cameraKey` stands in for the column when the row has none (a row written before
    /// version 4: the store passes its camera relationship's key). What a row from before version 4 lacks reads as an
    /// import job of every new file with no counts; a selection this build doesn't know reads as every new file, a
    /// range with a bound missing or reversed likewise; a picked list it can't read as no files.
    func record(cameraKey fallback: String) -> JobRecord {
        let picked = pickedKeys.map(StoredContentKeys.decode) ?? []
        let selection: JobRecord.Selection = switch self.selection {
        case "range":
            if let rangeStart, let rangeEnd, rangeStart <= rangeEnd { .dateRange(rangeStart ... rangeEnd) } else {
                .allNew
            }
        case "picked": .picked(picked)
        case "picked-new": .pickedNew(picked)
        default: .allNew
        }
        let outcome: JobRecord.Outcome? = switch self.outcome {
        case nil: nil
        case "completed": .completed
        case "cancelled": .cancelled
        case "catalogueUnavailable": .catalogueUnavailable
        case let other?: .stopped(reason: other.hasPrefix("stopped:") ? String(other.dropFirst(8)) : other)
        }
        return JobRecord(id: jobID, camera: CameraKey(rawValue: cameraKey ?? fallback),
                         purpose: purpose.flatMap(JobRecord.Purpose.init(rawValue:)) ?? .import,
                         destination: destination.flatMap(JobRecord.Destination.init(rawValue:)),
                         carrier: carrier.flatMap(JobRecord.Carrier.init(rawValue:)),
                         albumIdentifier: albumIdentifier, selection: selection, startedAt: startedAt,
                         finishedAt: finishedAt, outcome: outcome, filesTotal: filesTotal ?? 0,
                         filesImported: filesImported ?? 0, filesStaged: filesStaged ?? 0,
                         filesSkipped: filesSkipped ?? 0, filesFailed: filesFailed ?? 0,
                         bytesTotal: UInt64(bitPattern: bytesTotal), bytesDone: UInt64(bitPattern: bytesDone),
                         failedFiles: failedKeys.map(StoredContentKeys.decode) ?? [])
    }
}

/// A list of content keys as a job row keeps it: one versioned blob per list (an encoded list rather than a related
/// model: a job's picks are read and written whole, and a blob keeps the row CloudKit-compatible with no relationship
/// to keep in step).
enum StoredContentKeys {
    struct Blob: Codable {
        var version: Int
        var keys: [ObjectIdentity.ContentKey]
    }

    static let version = 1

    static func encode(_ keys: [ObjectIdentity.ContentKey]) -> Data {
        // Encoding plain strings and integers can't fail.
        (try? JSONEncoder().encode(Blob(version: version, keys: keys))) ?? Data()
    }

    /// The keys, or none for a blob this version can't read.
    static func decode(_ data: Data) -> [ObjectIdentity.ContentKey] {
        guard let blob = try? JSONDecoder().decode(Blob.self, from: data), blob.version == version else { return [] }
        return blob.keys
    }
}
