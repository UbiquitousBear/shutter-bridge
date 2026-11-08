#if canImport(SwiftData)
import Foundation
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

    public func states(of identities: [ObjectIdentity]) throws -> [ObjectIdentity: ObjectState] {
        // One fetch per camera (a job has one), then the diff in memory.
        var known: [String: ObjectState] = [:]
        for camera in Set(identities.map(\.camera.rawValue)) {
            let descriptor = FetchDescriptor<CameraObject>(predicate: #Predicate<CameraObject> { object in
                object.cameraKey == camera
            })
            for object in try modelContext.fetch(descriptor) {
                let state = object.row.objectState
                if let seen = known[object.identityKey], seen.progressRank >= state.progressRank { continue }
                known[object.identityKey] = state
            }
        }
        var out: [ObjectIdentity: ObjectState] = [:]
        for identity in identities {
            out[identity] = known[identity.storageKey] ?? .new
        }
        return out
    }

    public func upsert(_ record: CatalogueRecord) throws {
        let row = CatalogueRow(record)
        try write { context in
            let existing = try objects(withKey: row.identityKey)
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

    private func objects(withKey key: String) throws -> [CameraObject] {
        let descriptor = FetchDescriptor<CameraObject>(predicate: #Predicate<CameraObject> { object in
            object.identityKey == key
        })
        return try modelContext.fetch(descriptor)
    }

    /// The camera's row; with `creating`, a new one when there is none. Unique by serial, by the same rule.
    private func cameraRow(serial: String, creating: Bool) throws -> Camera? {
        let descriptor = FetchDescriptor<Camera>(predicate: #Predicate<Camera> { camera in
            camera.serial == serial
        })
        let found = try modelContext.fetch(descriptor)
        if let first = found.first { return first }
        guard creating else { return nil }
        let camera = Camera(serial: serial)
        modelContext.insert(camera)
        return camera
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
