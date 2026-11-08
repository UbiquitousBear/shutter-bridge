/// A `CatalogueStore` that keeps everything in memory: for unit tests and previews, on any platform.
public actor InMemoryCatalogue: CatalogueStore {
    private var records: [ObjectIdentity: CatalogueRecord] = [:]
    private var listings: [CameraKey: CardListing] = [:]

    public init(records: [CatalogueRecord] = []) {
        for r in records { self.records[r.identity] = r }
    }

    public func record(for identity: ObjectIdentity) -> CatalogueRecord? { records[identity] }

    public func states(of identities: [ObjectIdentity]) -> [ObjectIdentity: ObjectState] {
        var out: [ObjectIdentity: ObjectState] = [:]
        for id in identities { out[id] = records[id]?.state ?? .new }
        return out
    }

    public func upsert(_ record: CatalogueRecord) { records[record.identity] = record }

    public func saveListing(_ listing: CardListing) { listings[listing.camera] = listing }

    public func lastListing(for camera: CameraKey) -> CardListing? { listings[camera] }

    /// Every row, in no particular order.
    public var allRecords: [CatalogueRecord] { Array(records.values) }
}
