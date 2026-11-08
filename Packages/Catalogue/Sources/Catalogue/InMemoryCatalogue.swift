/// A `CatalogueStore` that keeps everything in memory: for unit tests and previews, on any platform.
public actor InMemoryCatalogue: CatalogueStore {
    private var records: [ObjectIdentity: CatalogueRecord] = [:]
    /// Every identity with a row, by its content key, for "already imported" (`ContentMatch`).
    private var byContent: [ObjectIdentity.ContentKey: Set<ObjectIdentity>] = [:]
    private var listings: [CameraKey: CardListing] = [:]

    public init(records: [CatalogueRecord] = []) {
        for r in records {
            self.records[r.identity] = r
            byContent[r.identity.contentKey, default: []].insert(r.identity)
        }
    }

    public func record(for identity: ObjectIdentity) -> CatalogueRecord? { records[identity] }

    /// By content, whatever the camera or folder (`ContentMatch`).
    public func states(of identities: [ObjectIdentity]) -> [ObjectIdentity: ObjectState] {
        var candidates: [CatalogueRow] = []
        for key in Set(identities.map(\.contentKey)) {
            for identity in byContent[key] ?? [] {
                if let record = records[identity] { candidates.append(CatalogueRow(record)) }
            }
        }
        return ContentMatch.states(of: identities, among: candidates)
    }

    public func upsert(_ record: CatalogueRecord) {
        records[record.identity] = record
        byContent[record.identity.contentKey, default: []].insert(record.identity)
    }

    public func saveListing(_ listing: CardListing) { listings[listing.camera] = listing }

    public func lastListing(for camera: CameraKey) -> CardListing? { listings[camera] }

    /// Every row, in no particular order.
    public var allRecords: [CatalogueRecord] { Array(records.values) }
}
