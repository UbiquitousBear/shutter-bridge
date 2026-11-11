import Catalogue
import Foundation
import PTPKit

/// A catalogue whose reads or writes can be made to fail, call by call. It keeps the pending-commit markers and job
/// records (Catalogue V4) as the real stores do, and logs every marker written, so a test can see each one the engine
/// wrote, in order.
actor FailingCatalogue: CatalogueStore {
    struct Broken: Error {}

    private var records: [ObjectIdentity: CatalogueRecord] = [:]
    private var markers: [UUID: PendingCommit] = [:]
    private var jobRecords: [UUID: JobRecord] = [:]
    /// Every marker `beginCommit` stored, in order (a rewrite under the same id is a second entry).
    private(set) var markerLog: [PendingCommit] = []
    /// Every `beginCommit` call, stored or refused.
    private(set) var beginCommitCalls = 0
    /// Every `abandonCommit` call, done or refused.
    private(set) var abandonCommitCalls = 0
    /// `upsert`, `markPartial`, `markStaged` and `finishCommit` (whose writes are row writes) fail.
    var failUpserts = false
    /// `states(of:)` and `stagedStates(of:)` fail.
    var failStates = false
    /// `beginCommit` fails from this call on (1-based); nil: never.
    var failBeginCommitFrom: Int?
    /// `finishCommit` fails, as a whole: nothing it would write is written and the marker stays.
    var failFinishCommit = false
    /// `abandonCommit` fails: the marker stays.
    var failAbandonCommit = false
    /// `recordJob` fails.
    var failRecordJob = false

    func setFailUpserts(_ on: Bool) { failUpserts = on }
    func setFailStates(_ on: Bool) { failStates = on }
    /// Every `beginCommit` from call `n` on fails (1 fails them all); nil lets them through again.
    func setFailBeginCommit(from n: Int?) { failBeginCommitFrom = n }
    func setFailFinishCommit(_ on: Bool) { failFinishCommit = on }
    func setFailAbandonCommit(_ on: Bool) { failAbandonCommit = on }
    func setFailRecordJob(_ on: Bool) { failRecordJob = on }

    func record(for identity: ObjectIdentity) throws -> CatalogueRecord? { records[identity] }

    func states(of identities: [ObjectIdentity]) throws -> [ObjectIdentity: ObjectState] {
        if failStates { throw Broken() }
        var out: [ObjectIdentity: ObjectState] = [:]
        for id in identities { out[id] = records[id]?.state ?? .new }
        return out
    }

    func upsert(_ record: CatalogueRecord) throws {
        if failUpserts { throw Broken() }
        var stored = record
        stored.staged = records[record.identity]?.staged ?? record.staged
        records[record.identity] = stored
    }

    func saveListing(_ listing: CardListing) throws {}
    func lastListing(for camera: CameraKey) throws -> CardListing? { nil }

    func markPartial(_ identity: ObjectIdentity, format: PTPMediaKind, tempURL: URL, offset: UInt64) throws {
        if failUpserts { throw Broken() }
        records[identity] = CatalogueRecord(identity: identity, format: format, state: .partial,
                                            resumeOffset: offset, tempURL: tempURL)
    }

    func markStaged(_ identity: ObjectIdentity, format: PTPMediaKind, at location: StagedLocation) throws {
        if failUpserts { throw Broken() }
        var record = records[identity] ?? CatalogueRecord(identity: identity, format: format, state: .new)
        record.staged = location
        records[identity] = record
    }
    func clearStaged(_ identity: ObjectIdentity) throws { records[identity]?.staged = nil }
    func stagedStates(of identities: [ObjectIdentity]) throws -> Set<ObjectIdentity> {
        if failStates { throw Broken() }
        return Set(identities.filter { records[$0]?.staged != nil })
    }
    func camera(_ key: CameraKey) throws -> CameraRecord? { nil }
    func cameras() throws -> [CameraRecord] { [] }
    func upsertCamera(_ record: CameraRecord) throws {}

    // MARK: Job records

    func recordJob(_ job: JobRecord) throws {
        if failRecordJob { throw Broken() }
        jobRecords[job.id] = job
    }

    func job(_ id: UUID) throws -> JobRecord? { jobRecords[id] }

    func jobs(camera: CameraKey?) throws -> [JobRecord] {
        jobRecords.values.filter { camera == nil || $0.camera == camera }.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: Pending commits

    func beginCommit(_ pending: PendingCommit) throws {
        beginCommitCalls += 1
        if let n = failBeginCommitFrom, beginCommitCalls >= n { throw Broken() }
        if pending.files.isEmpty { throw CatalogueFailure.emptyCommit }
        markers[pending.id] = pending
        markerLog.append(pending)
    }

    /// All or nothing: refused before anything is written.
    func finishCommit(_ id: UUID, writing writes: [CommitWrite]) throws {
        if failUpserts || failFinishCommit { throw Broken() }
        for write in writes {
            switch write {
            case let .imported(record): try upsert(record)
            case let .staged(identity, format, location): try markStaged(identity, format: format, at: location)
            }
        }
        markers[id] = nil
    }

    func abandonCommit(_ id: UUID) throws {
        abandonCommitCalls += 1
        if failAbandonCommit { throw Broken() }
        markers[id] = nil
    }

    func pendingCommits() throws -> [PendingCommit] {
        markers.values.sorted { $0.writtenAt < $1.writtenAt }
    }

    var allRecords: [CatalogueRecord] { Array(records.values) }
}
