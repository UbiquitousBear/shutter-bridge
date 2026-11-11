import Foundation
import PTPKit

/// A `CatalogueStore` that keeps everything in memory: for unit tests and previews, on any platform. It keeps the
/// same rules as `SwiftDataCatalogue`, down to when a camera gets a row (`CatalogueContractTests`,
/// `CameraRowContractTests`).
public actor InMemoryCatalogue: CatalogueStore {
    private var records: [ObjectIdentity: CatalogueRecord] = [:]
    /// Every identity with a row, by its content key, for "already imported" (`ContentMatch`).
    private var byContent: [ObjectIdentity.ContentKey: Set<ObjectIdentity>] = [:]
    private var listings: [CameraKey: CardListing] = [:]
    private var cameraRows: [CameraKey: CameraRecord] = [:]
    /// Cull marks by content key: one per key, by the store's rule.
    private var cullMarks: [ObjectIdentity.ContentKey: MarkRecord] = [:]
    private var jobRecords: [UUID: JobRecord] = [:]
    /// Pending-commit markers as `PendingCommitFile` rows, one per file, read back through the same mapping as
    /// SwiftData's, so both stores answer `pendingCommits()` alike.
    private var markerRows: [PendingCommitColumns] = []

    public init(records: [CatalogueRecord] = [], cameras: [CameraRecord] = []) {
        for c in cameras {
            cameraRows[c.key] = c.written(over: cameraRows[c.key])
        }
        for r in records {
            self.records[r.identity] = r
            byContent[r.identity.contentKey, default: []].insert(r.identity)
            let key = r.identity.camera
            if cameraRows[key] == nil { cameraRows[key] = CameraRecord(key: key) }
        }
    }

    public func record(for identity: ObjectIdentity) -> CatalogueRecord? { records[identity] }

    /// By content, whatever the camera or folder (`ContentMatch`).
    public func states(of identities: [ObjectIdentity]) -> [ObjectIdentity: ObjectState] {
        ContentMatch.states(of: identities, among: candidates(for: identities))
    }

    /// Keeps the stored row's staged copy (`StagedMark.upserting`).
    public func upsert(_ record: CatalogueRecord) {
        write(StagedMark.upserting(record, over: stored(record.identity)))
    }

    public func saveListing(_ listing: CardListing) {
        listings[listing.camera] = listing
        let camera = cameraRows[listing.camera] ?? CameraRecord(key: listing.camera)
        if listing.listedAt > camera.lastSeen {
            var seen = camera
            seen.lastSeen = listing.listedAt
            cameraRows[listing.camera] = seen
        } else {
            cameraRows[listing.camera] = camera
        }
    }

    public func lastListing(for camera: CameraKey) -> CardListing? { listings[camera] }

    public func markPartial(_ identity: ObjectIdentity, format: PTPMediaKind, tempURL: URL,
                            offset: UInt64) throws(CatalogueFailure) {
        if let record = try PartialMark.record(for: identity, format: format, tempURL: tempURL, offset: offset,
                                               existing: stored(identity)) {
            upsert(record)
        }
    }

    public func markStaged(_ identity: ObjectIdentity, format: PTPMediaKind, at location: StagedLocation) {
        write(StagedMark.record(for: identity, format: format, at: location, existing: records[identity]))
    }

    public func clearStaged(_ identity: ObjectIdentity) {
        guard var record = records[identity], record.staged != nil else { return }
        record.staged = nil
        records[identity] = record
    }

    /// By content, whatever the camera or folder (`ContentMatch`).
    public func stagedStates(of identities: [ObjectIdentity]) -> Set<ObjectIdentity> {
        ContentMatch.staged(of: identities, among: candidates(for: identities))
    }

    public func camera(_ key: CameraKey) -> CameraRecord? { cameraRows[key] }

    public func cameras() -> [CameraRecord] { CameraOrder.sorted(cameraRows.values) }

    public func upsertCamera(_ record: CameraRecord) {
        cameraRows[record.key] = record.written(over: cameraRows[record.key])
    }

    // MARK: Cull marks (Catalogue V4)

    public func setMark(_ decision: MarkRecord.Decision?, rating: Int, for keys: [ObjectIdentity.ContentKey],
                        at date: Date) throws(CatalogueFailure) {
        guard let mark = try MarkRule.mark(decision, rating: rating, at: date) else {
            clearMarks(of: keys)
            return
        }
        for key in keys {
            cullMarks[key] = mark
        }
    }

    public func marks(of keys: [ObjectIdentity.ContentKey]) -> [ObjectIdentity.ContentKey: MarkRecord] {
        var out: [ObjectIdentity.ContentKey: MarkRecord] = [:]
        for key in keys {
            if let mark = cullMarks[key] { out[key] = mark }
        }
        return out
    }

    public func clearMarks(of keys: [ObjectIdentity.ContentKey]) {
        for key in keys {
            cullMarks[key] = nil
        }
    }

    // MARK: Job records (Catalogue V4)

    public func recordJob(_ job: JobRecord) {
        jobRecords[job.id] = job
        ensureCamera(job.camera)
    }

    public func job(_ id: UUID) -> JobRecord? { jobRecords[id] }

    public func jobs(camera: CameraKey?) -> [JobRecord] {
        JobOrder.sorted(jobRecords.values.filter { camera == nil || $0.camera == camera })
    }

    // MARK: Staged files and Forget imports (Catalogue V4)

    public func stagedRecords(camera: CameraKey?) -> [CatalogueRecord] {
        StagedOrder.sorted(records.values.filter {
            $0.staged != nil && (camera == nil || $0.identity.camera == camera)
        })
    }

    @discardableResult
    public func forgetImports(camera: CameraKey) -> Int {
        var forgotten = 0
        for (identity, record) in records where identity.camera == camera {
            switch ForgetRule.change(for: CatalogueRow(record)) {
            case .keep:
                continue
            case .delete:
                records[identity] = nil
                byContent[identity.contentKey]?.remove(identity)
                if byContent[identity.contentKey]?.isEmpty == true { byContent[identity.contentKey] = nil }
            case let .rewrite(row):
                records[identity] = row.record
            }
            forgotten += 1
        }
        markerRows.removeAll { $0.cameraKey == camera.rawValue }
        return forgotten
    }

    // MARK: Pending commits (Catalogue V4)

    public func beginCommit(_ pending: PendingCommit) throws(CatalogueFailure) {
        guard !pending.files.isEmpty else { throw .emptyCommit }
        markerRows.removeAll { $0.commitID == pending.id }
        markerRows += PendingCommitColumns.rows(of: pending)
    }

    /// All or nothing within one actor call: none of these writes can fail here, and nothing suspends between them.
    public func finishCommit(_ id: UUID, writing writes: [CommitWrite]) {
        for write in writes {
            switch write {
            case let .imported(record): upsert(record)
            case let .staged(identity, format, location): markStaged(identity, format: format, at: location)
            }
        }
        abandonCommit(id)
    }

    public func abandonCommit(_ id: UUID) {
        markerRows.removeAll { $0.commitID == id }
    }

    public func pendingCommits() -> [PendingCommit] {
        PendingCommitColumns.commits(from: markerRows)
    }

    // MARK: Beyond the protocol

    /// Every row, in no particular order.
    public var allRecords: [CatalogueRecord] { Array(records.values) }

    /// Every row with the content of one of `identities`.
    private func candidates(for identities: [ObjectIdentity]) -> [CatalogueRow] {
        var candidates: [CatalogueRow] = []
        for key in Set(identities.map(\.contentKey)) {
            for identity in byContent[key] ?? [] {
                if let record = records[identity] { candidates.append(CatalogueRow(record)) }
            }
        }
        return candidates
    }

    /// The stored row a write builds on, through the same rule as `SwiftDataCatalogue`'s
    /// (`StagedMark.healed(_:among:)`). This store holds one row per identity, so there is no duplicate to take a
    /// staged copy from, and the row comes back as it is.
    private func stored(_ identity: ObjectIdentity) -> CatalogueRecord? {
        let row = records[identity]
        return StagedMark.healed(row, among: [row?.staged])
    }

    /// Stores the row as given, staged copy and all.
    private func write(_ record: CatalogueRecord) {
        records[record.identity] = record
        byContent[record.identity.contentKey, default: []].insert(record.identity)
        ensureCamera(record.identity.camera)
    }

    /// A camera row with empty fields for `key` when there is none, as SwiftData's store makes one for a file row.
    private func ensureCamera(_ key: CameraKey) {
        if cameraRows[key] == nil { cameraRows[key] = CameraRecord(key: key) }
    }
}
