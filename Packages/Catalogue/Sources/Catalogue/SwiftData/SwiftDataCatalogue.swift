#if canImport(SwiftData)
import Foundation
import PTPKit
import SwiftData

/// The catalogue in SwiftData: a `ModelActor`, so every read and write runs on its own serial executor and none on
/// the main actor (backlog section 4). Compiled only where SwiftData exists; CI runs the contract tests against it in
/// the iOS Simulator, with an in-memory container.
///
/// **Identity is unique by this actor's rule, not the schema's** (decision recorded in section 4, 8 Nov): a unique
/// attribute would keep the schema from syncing through CloudKit, which the proposal keeps open. Every write is one
/// synchronous actor call (look up the identity's row, update it or insert one, save), so writes never interleave and
/// a second insert of the same identity updates the row. That holds for one store per container: the app makes one
/// and shares it. Should two rows for one identity ever exist (a second store on the same file, a later sync), reads
/// answer with the furthest-along row and the next write for that identity removes the others.
///
/// **"Already imported" is by content** (Shamil, 8 Nov; `CatalogueStore`): `states(of:)` fetches candidate rows by
/// size, whatever their camera, and matches them with `ContentMatch`. Rows of one file under two cameras (build 17.1
/// wrote them for a file imported in MSC and again in MTP) both count and are both kept: each records a real copy.
/// No schema change was needed: every version-1 row already holds the file name, capture date and size.
///
/// **The Camera row and partial files** (Iteration 3, schema version 2): `camera(_:)`, `cameras()` and
/// `upsertCamera(_:)` read and write the `Camera` row's fields through `CameraRecord` (never a password: there is no
/// column for one), and `markPartial` writes a download checkpoint (`resumeOffset` and `tempURL`). A store written
/// by an earlier build opens through `CatalogueMigrationPlan`'s lightweight stages. Camera rows are unique by key by
/// the same rule; should a key ever have two, every read picks the same one (`CameraOrder.preferred(_:)`) and
/// `upsertCamera(_:)` writes the same fields to all of them.
///
/// **Staging** (Shamil, 11 Nov; schema version 3): `markStaged` and `clearStaged` write the file row's staged copy,
/// which `upsert` and `markPartial` keep, and `stagedStates(of:)` matches it by content as `states(of:)` does.
///
/// Each write is saved before the call returns. If any step of a write throws (a fetch, the save), every change it
/// made is rolled back and the error thrown, so a failed write leaves nothing pending for later reads or writes.
///
/// **Open it with `open(storeURL:)`.** A `ModelContext` made on the main thread is a main-queue context, and an actor
/// built on it runs its work on the main thread (Apple Developer Forums 736226, FB13399899), so the store has to be
/// built off the main actor for "no catalogue write on the main actor" to hold.
public actor SwiftDataCatalogue: ModelActor, CatalogueStore {
    public nonisolated let modelExecutor: any ModelExecutor
    public nonisolated let modelContainer: ModelContainer

    /// Opens the store at `storeURL` (in memory when nil) off the main actor, so its context, and every read and write
    /// on it, runs on the actor's own executor even when the caller is main-actor code such as the app's launch.
    @concurrent
    public static func open(storeURL: URL?) async throws -> SwiftDataCatalogue {
        SwiftDataCatalogue(modelContainer: try makeContainer(storeURL: storeURL))
    }

    /// A store over `modelContainer`, which should come from `makeContainer(storeURL:)`. What `@ModelActor` would
    /// generate, written out so the initialiser is public.
    ///
    /// Call it off the main thread: called on the main thread, the context it makes is a main-queue context and the
    /// store's work runs on the main thread. Prefer `open(storeURL:)`.
    public init(modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.modelContainer = modelContainer
    }

    /// A container for the catalogue's schema with its migration plan: on disk at `storeURL` (its folder is created
    /// if missing), or in memory when `storeURL` is nil (tests, previews). CloudKit stays off.
    public static func makeContainer(storeURL: URL?) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CatalogueCurrentSchema.self)
        let configuration: ModelConfiguration
        if let storeURL {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: storeURL,
                                               cloudKitDatabase: ModelConfiguration.CloudKitDatabase.none)
        } else {
            // A name of its own, so two in-memory containers in one process never share a store.
            configuration = ModelConfiguration("Catalogue-\(UUID().uuidString)", schema: schema,
                                               isStoredInMemoryOnly: true,
                                               cloudKitDatabase: ModelConfiguration.CloudKitDatabase.none)
        }
        return try ModelContainer(for: schema, migrationPlan: CatalogueMigrationPlan.self,
                                  configurations: configuration)
    }

    /// Where the app keeps the catalogue: `Catalogue.store` in Application Support.
    public static var defaultStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "Catalogue.store", directoryHint: .notDirectory)
    }

    // MARK: CatalogueStore

    public func record(for identity: ObjectIdentity) throws -> CatalogueRecord? {
        try furthestAlong(objects(withKey: identity.storageKey))?.row.record
    }

    /// By content (Shamil, 8 Nov): the rows of every camera and folder whose size is one of the request's are
    /// fetched, a chunk of sizes at a time, and matched on name, capture time and size by `ContentMatch`. Rows written
    /// by any earlier build have these columns, so they match as they are; the schema is unchanged.
    public func states(of identities: [ObjectIdentity]) throws -> [ObjectIdentity: ObjectState] {
        guard !identities.isEmpty else { return [:] }
        return ContentMatch.states(of: identities, among: try candidates(for: identities))
    }

    /// Sizes per fetch in `states(of:)` and `stagedStates(of:)`, so one predicate never carries an unbounded list
    /// (SQLite limits the variables in one statement).
    static let sizesPerFetch = 500

    /// Keeps the stored row's staged copy (`StagedMark.upserting`).
    public func upsert(_ record: CatalogueRecord) throws {
        let existing = try objects(withKey: record.identity.storageKey)
        let kept = StagedMark.upserting(record, over: furthestAlong(existing)?.row.record)
        try write { context in
            try upsertObject(CatalogueRow(kept), existing: existing, in: context)
        }
    }

    public func saveListing(_ listing: CardListing) throws {
        let data = try StoredListing.encode(listing)
        try write { _ in
            guard let camera = try cameraRow(serial: listing.camera.rawValue, creating: true) else { return }
            camera.lastListing = data
            camera.lastListedAt = listing.listedAt
            if listing.listedAt > camera.lastSeen { camera.lastSeen = listing.listedAt }
        }
    }

    public func lastListing(for camera: CameraKey) throws -> CardListing? {
        guard let stored = try cameraRow(serial: camera.rawValue, creating: false),
              let data = stored.lastListing, let listedAt = stored.lastListedAt else { return nil }
        return try StoredListing.decode(data, camera: camera, listedAt: listedAt)
    }

    /// Looks up the identity's row, applies `PartialMark`'s rule to it and writes the result, all in one actor call,
    /// so a checkpoint and a commit of the same file never interleave. Duplicates for the identity are healed as by
    /// `upsert`; an imported row is left as it is, duplicates and all.
    public func markPartial(_ identity: ObjectIdentity, format: PTPMediaKind, tempURL: URL,
                            offset: UInt64) throws {
        let existing = try objects(withKey: identity.storageKey)
        guard let record = try PartialMark.record(for: identity, format: format, tempURL: tempURL, offset: offset,
                                                  existing: furthestAlong(existing)?.row.record) else { return }
        try write { context in
            try upsertObject(CatalogueRow(record), existing: existing, in: context)
        }
    }

    /// Looks up the identity's row, applies `StagedMark`'s rule to it and writes the result, in one actor call.
    /// Duplicates for the identity are healed as by `upsert`.
    public func markStaged(_ identity: ObjectIdentity, format: PTPMediaKind, at location: StagedLocation) throws {
        let existing = try objects(withKey: identity.storageKey)
        let record = StagedMark.record(for: identity, format: format, at: location,
                                       existing: furthestAlong(existing)?.row.record)
        try write { context in
            try upsertObject(CatalogueRow(record), existing: existing, in: context)
        }
    }

    /// Clears the staged copy on every row of the identity (one, by the store's rule), leaving the rest as it is.
    public func clearStaged(_ identity: ObjectIdentity) throws {
        let existing = try objects(withKey: identity.storageKey)
        guard existing.contains(where: { $0.stagedRelativePath != nil || $0.stagedRoot != nil }) else { return }
        try write { _ in
            for object in existing {
                object.stagedRelativePath = nil
                object.stagedRoot = nil
                object.stagedAt = nil
            }
        }
    }

    /// By content, as `states(of:)`: the rows of every camera and folder whose size is one of the request's.
    public func stagedStates(of identities: [ObjectIdentity]) throws -> Set<ObjectIdentity> {
        guard !identities.isEmpty else { return [] }
        return ContentMatch.staged(of: identities, among: try candidates(for: identities))
    }

    public func camera(_ key: CameraKey) throws -> CameraRecord? {
        preferred(try cameraRows(serial: key.rawValue))?.columns.record
    }

    public func cameras() throws -> [CameraRecord] {
        CameraOrder.sorted(try modelContext.fetch(FetchDescriptor<Camera>()).map(\.columns.record))
    }

    /// Writes every `CameraRecord` field to the key's `Camera` row (made if missing), keeping the later `lastSeen`;
    /// the row's listing, files and jobs are left alone. Should the key have several rows (see the type's
    /// documentation), every one gets the same fields, so whichever a later read picks answers the same. They are
    /// not merged into one: each may own file rows and jobs (which a deleted row's cascade would take with it).
    public func upsertCamera(_ record: CameraRecord) throws {
        try write { context in
            let rows = try cameraRows(serial: record.key.rawValue)
            let stored = preferred(rows)
            let columns = CameraColumns(record.written(over: stored?.columns.record))
            if rows.isEmpty {
                let camera = Camera(serial: record.key.rawValue)
                context.insert(camera)
                camera.apply(columns)
            }
            for camera in rows {
                camera.apply(columns)
            }
        }
    }

    // MARK: Beyond the protocol

    /// Every row, in no particular order (duplicates, if a store ever holds any, included).
    public func allRecords() throws -> [CatalogueRecord] {
        try modelContext.fetch(FetchDescriptor<CameraObject>()).compactMap { $0.row.record }
    }

    // MARK: Internal

    /// One write: runs `body` on the store's context, then saves. If `body` or the save throws, every change since
    /// the last save is rolled back before the error is thrown, so nothing half-written stays pending in the context
    /// for later reads (fetches include pending changes) or for the next write's save. Internal so tests can make a
    /// write fail part-way.
    func write(_ body: (ModelContext) throws -> Void) throws {
        do {
            try body(modelContext)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Whether the actor's work runs on the main thread (tests only: the store must never).
    func isOnMainThread() -> Bool {
        Thread.isMainThread
    }

    // MARK: Private

    /// Inside a write: updates the furthest-along of `existing` (the identity's rows) to `row` and deletes the others,
    /// or inserts a row when there are none, then links it to its camera's row.
    private func upsertObject(_ row: CatalogueRow, existing: [CameraObject], in context: ModelContext) throws {
        let object: CameraObject
        if let kept = furthestAlong(existing) {
            object = kept
            object.apply(row)
            for other in existing where other !== kept {
                context.delete(other)
            }
        } else {
            object = CameraObject(row: row)
            context.insert(object)
        }
        if object.camera?.serial != row.cameraKey {
            object.camera = try cameraRow(serial: row.cameraKey, creating: true)
        }
    }

    /// Every row, of any camera and folder, whose size is one of `identities`', fetched a chunk of sizes at a time:
    /// the candidates `ContentMatch` matches on name, capture time and size.
    private func candidates(for identities: [ObjectIdentity]) throws -> [CatalogueRow] {
        let sizes = Set(identities.map { Int64(bitPattern: $0.size) }).sorted()
        var candidates: [CatalogueRow] = []
        var start = sizes.startIndex
        while start < sizes.endIndex {
            let end = min(start + Self.sizesPerFetch, sizes.endIndex)
            let chunk = Array(sizes[start ..< end])
            start = end
            let descriptor = FetchDescriptor<CameraObject>(predicate: #Predicate<CameraObject> { object in
                chunk.contains(object.size)
            })
            for object in try modelContext.fetch(descriptor) {
                candidates.append(object.row)
            }
        }
        return candidates
    }

    private func objects(withKey key: String) throws -> [CameraObject] {
        let descriptor = FetchDescriptor<CameraObject>(predicate: #Predicate<CameraObject> { object in
            object.identityKey == key
        })
        return try modelContext.fetch(descriptor)
    }

    /// The camera's row (`preferred(_:)` of its rows); with `creating`, a new one when there is none. Unique by
    /// serial, by the same rule.
    private func cameraRow(serial: String, creating: Bool) throws -> Camera? {
        if let found = preferred(try cameraRows(serial: serial)) { return found }
        guard creating else { return nil }
        let camera = Camera(serial: serial)
        modelContext.insert(camera)
        return camera
    }

    /// Every `Camera` row with this serial: one, by the store's rule, unless someone else wrote another.
    private func cameraRows(serial: String) throws -> [Camera] {
        let descriptor = FetchDescriptor<Camera>(predicate: #Predicate<Camera> { camera in
            camera.serial == serial
        })
        return try modelContext.fetch(descriptor)
    }

    /// The row every read answers with among one serial's rows, by `CameraOrder.preferred(_:)`, so `camera(_:)`,
    /// `cameras()`, the listing and the file rows' link all pick the same one.
    private func preferred(_ rows: [Camera]) -> Camera? {
        CameraOrder.preferred(rows.map(\.columns.record)).map { rows[$0] }
    }

    /// The row to answer with when there are several for one identity: the furthest along, the first of equals.
    private func furthestAlong(_ objects: [CameraObject]) -> CameraObject? {
        var best: CameraObject?
        var bestRank = -1
        for object in objects {
            let rank = object.row.objectState.progressRank
            if rank > bestRank {
                best = object
                bestRank = rank
            }
        }
        return best
    }
}
#endif
