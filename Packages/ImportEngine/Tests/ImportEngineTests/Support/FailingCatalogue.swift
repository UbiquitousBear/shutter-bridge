import Catalogue

/// A catalogue whose reads or writes can be made to fail.
actor FailingCatalogue: CatalogueStore {
    struct Broken: Error {}

    private var records: [ObjectIdentity: CatalogueRecord] = [:]
    var failUpserts = false
    var failStates = false

    func setFailUpserts(_ on: Bool) { failUpserts = on }
    func setFailStates(_ on: Bool) { failStates = on }

    func record(for identity: ObjectIdentity) throws -> CatalogueRecord? { records[identity] }

    func states(of identities: [ObjectIdentity]) throws -> [ObjectIdentity: ObjectState] {
        if failStates { throw Broken() }
        var out: [ObjectIdentity: ObjectState] = [:]
        for id in identities { out[id] = records[id]?.state ?? .new }
        return out
    }

    func upsert(_ record: CatalogueRecord) throws {
        if failUpserts { throw Broken() }
        records[record.identity] = record
    }

    func saveListing(_ listing: CardListing) throws {}
    func lastListing(for camera: CameraKey) throws -> CardListing? { nil }

    var allRecords: [CatalogueRecord] { Array(records.values) }
}
