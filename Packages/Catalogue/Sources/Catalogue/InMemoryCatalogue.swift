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
        write(StagedMark.upserting(record, over: records[record.identity]))
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
                                               existing: records[identity]) {
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
