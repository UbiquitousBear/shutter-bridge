import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import PTPKit
import Synchronization

/// An `InMemoryCatalogue` seen through a launch the app is killed in between a commit's save and its row: every call
/// goes through to the store, except `finishCommit`, which never lands (it throws, and the engine that made it is
/// then dropped, so what it kept in memory goes with it). A second engine over `inner` is the next launch. It runs on
/// `inner`'s executor, so it calls the store synchronously, as one actor call, like the store itself.
actor KilledAtFinishCatalogue: CatalogueStore {
    struct Killed: Error {}
    let inner: InMemoryCatalogue
    nonisolated var unownedExecutor: UnownedSerialExecutor { inner.unownedExecutor }
    /// `finishCommit` calls refused.
    private(set) var finishCalls = 0

    init(_ inner: InMemoryCatalogue) { self.inner = inner }

    private func store<T: Sendable>(_ call: (isolated InMemoryCatalogue) throws -> T) rethrows -> T {
        try inner.assumeIsolated(call)
    }

    func record(for identity: ObjectIdentity) throws -> CatalogueRecord? { store { $0.record(for: identity) } }
    func states(of identities: [ObjectIdentity]) throws -> [ObjectIdentity: ObjectState] {
        store { $0.states(of: identities) }
    }
    func upsert(_ record: CatalogueRecord) throws { store { $0.upsert(record) } }
    func saveListing(_ listing: CardListing) throws { store { $0.saveListing(listing) } }
    func lastListing(for camera: CameraKey) throws -> CardListing? { store { $0.lastListing(for: camera) } }
    func markPartial(_ identity: ObjectIdentity, format: PTPMediaKind, tempURL: URL, offset: UInt64) throws {
        try store { try $0.markPartial(identity, format: format, tempURL: tempURL, offset: offset) }
    }
    func partialRecords() throws -> [CatalogueRecord] { store { $0.partialRecords() } }
    func markStaged(_ identity: ObjectIdentity, format: PTPMediaKind, at location: StagedLocation) throws {
        store { $0.markStaged(identity, format: format, at: location) }
    }
    func clearStaged(_ identity: ObjectIdentity) throws { store { $0.clearStaged(identity) } }
    func stagedStates(of identities: [ObjectIdentity]) throws -> Set<ObjectIdentity> {
        store { $0.stagedStates(of: identities) }
    }
    func camera(_ key: CameraKey) throws -> CameraRecord? { store { $0.camera(key) } }
    func cameras() throws -> [CameraRecord] { store { $0.cameras() } }
    func upsertCamera(_ record: CameraRecord) throws { store { $0.upsertCamera(record) } }
    func setMark(_ decision: MarkRecord.Decision?, rating: Int, for keys: [ObjectIdentity.ContentKey],
                 at date: Date) throws {
        try store { try $0.setMark(decision, rating: rating, for: keys, at: date) }
    }
    func marks(of keys: [ObjectIdentity.ContentKey]) throws -> [ObjectIdentity.ContentKey: MarkRecord] {
        store { $0.marks(of: keys) }
    }
    func clearMarks(of keys: [ObjectIdentity.ContentKey]) throws { store { $0.clearMarks(of: keys) } }
    func recordJob(_ job: JobRecord) throws { store { $0.recordJob(job) } }
    func job(_ id: UUID) throws -> JobRecord? { store { $0.job(id) } }
    func jobs(camera: CameraKey?) throws -> [JobRecord] { store { $0.jobs(camera: camera) } }
    func stagedRecords(camera: CameraKey?) throws -> [CatalogueRecord] { store { $0.stagedRecords(camera: camera) } }
    func forgetImports(camera: CameraKey) throws -> Int { store { $0.forgetImports(camera: camera) } }
    func beginCommit(_ pending: PendingCommit) throws { try store { try $0.beginCommit(pending) } }
    func finishCommit(_ id: UUID, writing writes: [CommitWrite]) throws {
        finishCalls += 1
        throw Killed()
    }
    func abandonCommit(_ id: UUID) throws { store { $0.abandonCommit(id) } }
    func pendingCommits() throws -> [PendingCommit] { store { $0.pendingCommits() } }
}

/// A Photos library that answers `findAsset` from what a recording destination committed: an asset is there when a
/// committed unit, laid out as the save lays it out (`AssetCreation(unit:options:)`), matches the query
/// (`AssetQuery.matches(_:)`) and its date; its identifier is the one `FakeDestination` returned for it
/// ("asset-<n>"). `deleted` makes every asset gone (deleted since, or out of sight); `access` is what it reads as.
actor CommittedLibrary: PhotoLibraryClient {
    let destination: FakeDestination
    private(set) var queries: [AssetQuery] = []
    var deleted = false
    var access: PhotosAuthorisation = .authorised

    init(_ destination: FakeDestination) { self.destination = destination }

    func setDeleted(_ on: Bool) { deleted = on }
    func setAccess(_ access: PhotosAuthorisation) { self.access = access }

    func authorisation() -> PhotosAuthorisation { access }
    func requestReadWriteAuthorisation() -> PhotosAuthorisation { access }
    func album(withIdentifier identifier: String) -> AlbumLookup { .missing }
    func createAlbum(titled title: String) throws(PhotoLibraryFailure) -> String {
        throw PhotoLibraryFailure(domain: "test", code: 1)
    }
    func save(_ asset: AssetCreation, toAlbums albumIdentifiers: [String]) throws(PhotoLibraryFailure) -> String {
        throw PhotoLibraryFailure(domain: "test", code: 2)
    }

    func findAsset(_ query: AssetQuery) async -> AssetSearch {
        queries.append(query)
        switch access {
        case .authorised, .limited: break
        case .notDetermined, .denied, .restricted: return .cannotSearch
        }
        guard !deleted else { return .notFound(underLimitedAccess: access == .limited) }
        for (n, unit) in await destination.commits.enumerated() {
            let asset = AssetCreation(unit: unit, options: PhotosImportOptions())
            let originals = asset.resources.map {
                AssetQuery.Original(role: $0.role, originalFilename: $0.originalFilename)
            }
            guard let date = asset.creationDate, query.dateRange.contains(date), query.matches(originals) else { continue }
            return .found(localIdentifier: "asset-\(n + 1)")
        }
        return .notFound(underLimitedAccess: access == .limited)
    }
}

/// A lookup that counts the markers it is asked about and answers with `inner`'s answer, or `answer` when set.
final class CountingLookup: CommitLookup {
    private let state = Mutex<(asked: [PendingCommit], answer: CommitLookupAnswer?)>(([], nil))
    let inner: any CommitLookup

    init(_ inner: any CommitLookup = NoCommitLookup(), answer: CommitLookupAnswer? = nil) {
        self.inner = inner
        state.withLock { $0.answer = answer }
    }

    var asked: [PendingCommit] { state.withLock { $0.asked } }

    func look(for pending: PendingCommit) async -> CommitLookupAnswer {
        let answer = state.withLock { s in
            s.asked.append(pending)
            return s.answer
        }
        if let answer { return answer }
        return await inner.look(for: pending)
    }
}

/// A lookup whose first answer waits until the test releases it.
actor GatedLookup: CommitLookup {
    private let answer: @Sendable (PendingCommit) -> CommitLookupAnswer
    private var gate: CheckedContinuation<Void, Never>?
    private var arrived: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var calls = 0

    init(answer: @escaping @Sendable (PendingCommit) -> CommitLookupAnswer) { self.answer = answer }

    func look(for pending: PendingCommit) async -> CommitLookupAnswer {
        calls += 1
        if !isOpen {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                gate = c
                arrived?.resume()
                arrived = nil
            }
        }
        return answer(pending)
    }

    /// Returns once a lookup is waiting.
    func waitArrived() async {
        if gate != nil { return }
        await withCheckedContinuation { arrived = $0 }
    }

    func open() {
        isOpen = true
        gate?.resume()
        gate = nil
    }
}

/// A destination that holds its first commit until released, then hands it to `inner`.
actor GateDestination: ImportDestination {
    nonisolated let kind: DestinationKind
    private let inner: any ImportDestination
    private var holdFirst = true
    private var held: CheckedContinuation<Void, Never>?
    private var arrived: CheckedContinuation<Void, Never>?

    init(_ inner: any ImportDestination) {
        self.inner = inner
        kind = inner.kind
    }

    func commit(_ unit: CommitUnit) async throws(ImportDestinationFailure) -> ImportResult {
        if holdFirst {
            holdFirst = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                held = c
                arrived?.resume()
                arrived = nil
            }
        }
        return try await inner.commit(unit)
    }

    nonisolated func commitTarget(for unit: CommitUnit) -> CommitTarget { inner.commitTarget(for: unit) }

    func waitArrived() async {
        if held != nil { return }
        await withCheckedContinuation { arrived = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }
}

/// A real staging folder (`StagingFolderDestination`) on this iPhone under a temporary Documents folder, and the
/// production lookup over it and a library.
struct RealStaging {
    static let cameraName = "ILCE-7CM2"
    let documents: URL
    let destination: StagingFolderDestination

    init(under root: URL, zone: TimeZone) {
        documents = root.appendingPathComponent("Documents", isDirectory: true)
        destination = StagingFolderDestination(root: documents, place: Harness.onThisIPhone,
                                               cameraName: Self.cameraName, timeZone: zone)
    }

    var route: ImportRoute {
        .staging(destination, reason: .chosen, place: Harness.onThisIPhone, onThisIPhone: destination)
    }

    /// The day folder of a file taken at `Harness.t0` (UTC), relative to `documents`.
    var dayFolder: String { "Staging/\(Self.cameraName)/2026-10-26" }

    var dayFolderURL: URL {
        documents.appendingPathComponent("Staging/\(Self.cameraName)/2026-10-26", isDirectory: true)
    }

    /// Writes a file of `size` bytes in the day folder.
    func put(_ name: String, size: Int) throws {
        try FileManager.default.createDirectory(at: dayFolderURL, withIntermediateDirectories: true)
        try Data(repeating: 7, count: size).write(to: dayFolderURL.appendingPathComponent(name))
    }

    /// The names in the day folder, sorted.
    var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dayFolderURL.path(percentEncoded: false))) ?? []).sorted()
    }

    func lookup(library: any PhotoLibraryClient) -> LibraryCommitLookup {
        LibraryCommitLookup(library: library, staging: FakeStagingLocator(.unavailable(.containerUnavailable)),
                            onThisIPhone: documents)
    }
}
