import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import PTPSimulator
import SimulatedLink
import Synchronization
import Testing

// The fault matrix's commit-boundary rows (backlog section 3; I15, section 3.1): a commit reaches its destination and
// its catalogue write is lost, because the app is killed between the save (or the placing in Staging) and the row, or
// because the write fails every try. The next job, after a relaunch or later in the same launch, resolves the
// pending-commit marker before its diff, so every file lands exactly once, with its row, and no marker is left.
//
// Its own file and bench, beside `FaultMatrixSupport`'s: the case needs a catalogue whose `finishCommit` fails, a
// second engine with the production lookup, and the real staging folder (whose day folder the lookup lists), which
// `MatrixBench` doesn't make. It still takes the cards, links, Photos fake and work folder from a `MatrixBench`.

/// `InMemoryCatalogue` with a `finishCommit` that fails from a given call on (1-based), as a store failing every try
/// does, and as a kill between the save and the row looks to the engine that made the call. On the store's own
/// executor, so each call is one synchronous store call, like the store's.
private actor FinishFailingCatalogue: CatalogueStore {
    struct Broken: Error {}
    let inner: InMemoryCatalogue
    nonisolated var unownedExecutor: UnownedSerialExecutor { inner.unownedExecutor }
    private var calls = 0
    private var failFrom: Int?

    init(_ inner: InMemoryCatalogue) { self.inner = inner }

    func failFinish(from n: Int?) { failFrom = n }

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
        calls += 1
        if let failFrom, calls >= failFrom { throw Broken() }
        store { $0.finishCommit(id, writing: writes) }
    }
    func abandonCommit(_ id: UUID) throws { store { $0.abandonCommit(id) } }
    func pendingCommits() throws -> [PendingCommit] { store { $0.pendingCommits() } }
}

/// A Photos library that answers `findAsset` from what the bench's recording Photos fake committed: an asset is there
/// when a committed unit's files, laid out as the save lays them out (a pair's JPEG as the photo, its ARW as the
/// alternate), match the query; its identifier is the one the fake returned for it.
private struct RecordedLibrary: PhotoLibraryClient {
    let photos: RecordingDestination

    func authorisation() async -> PhotosAuthorisation { .authorised }
    func requestReadWriteAuthorisation() async -> PhotosAuthorisation { .authorised }
    func album(withIdentifier identifier: String) async -> AlbumLookup { .missing }
    func createAlbum(titled title: String) async throws(PhotoLibraryFailure) -> String {
        throw PhotoLibraryFailure(domain: "matrix", code: 1)
    }
    func save(_ asset: AssetCreation, toAlbums albumIdentifiers: [String]) async throws(PhotoLibraryFailure) -> String {
        throw PhotoLibraryFailure(domain: "matrix", code: 2)
    }

    func findAsset(_ query: AssetQuery) async -> AssetSearch {
        for (n, unit) in await photos.units.enumerated() {
            let originals = unit.map { file in
                let raw = file.name.uppercased().hasSuffix(".ARW") && unit.count == 2
                return AssetQuery.Original(role: raw ? .alternatePhoto : .photo, originalFilename: file.name)
            }
            if query.matches(originals) { return .found(localIdentifier: "asset-\(n + 1)") }
        }
        return .notFound(underLimitedAccess: false)
    }
}

/// The real staging folder (`StagingFolderDestination`, on this iPhone) under the bench's folder, recording every
/// unit it is given (names and bytes as read at the commit), so a file staged twice shows.
private actor RecordingStaging: ImportDestination {
    nonisolated let kind: DestinationKind = .staging
    let inner: StagingFolderDestination
    private(set) var units: [[RecordingDestination.File]] = []

    init(_ inner: StagingFolderDestination) { self.inner = inner }

    var files: [RecordingDestination.File] { units.flatMap { $0 } }

    func commit(_ unit: CommitUnit) async throws(ImportDestinationFailure) -> ImportResult {
        var recorded: [RecordingDestination.File] = []
        for file in unit.files {
            guard let data = try? Data(contentsOf: file.url) else { throw .stagedFileMissing }
            recorded.append(RecordingDestination.File(name: file.filename, data: data))
        }
        let result = try await inner.commit(unit)
        units.append(recorded)
        return result
    }

    nonisolated func commitTarget(for unit: CommitUnit) -> CommitTarget { inner.commitTarget(for: unit) }
}

/// Every engine event, for the lines the case reads.
private final class Events: Sendable {
    private let log = Mutex<[EngineTrace]>([])
    var all: [EngineTrace] { log.withLock { $0 } }
    func record(_ event: EngineTrace) { log.withLock { $0.append(event) } }
}

/// The lookup the app uses (`LibraryCommitLookup`), counting the markers it is asked about.
private final class CountingLookup: CommitLookup {
    private let asked = Mutex(0)
    let inner: any CommitLookup
    init(_ inner: any CommitLookup) { self.inner = inner }
    var count: Int { asked.withLock { $0 } }
    func look(for pending: PendingCommit) async -> CommitLookupAnswer {
        asked.withLock { $0 += 1 }
        return await inner.look(for: pending)
    }
}

/// A link flavour and a job's purpose.
struct CommitBoundaryCase: Sendable, CustomTestStringConvertible {
    var link: MatrixLink
    var purpose: MatrixPurpose
    var testDescription: String { "\(link.rawValue) \(purpose.rawValue)" }
}

@Suite("Fault matrix: the commit boundary", .timeLimit(.minutes(2)))
struct FaultMatrixCommitBoundaryTests {
    /// How the second commit's catalogue write is lost.
    enum Fault: String, Sendable, CaseIterable, CustomTestStringConvertible {
        /// The app is killed between the save (or the placing in Staging) and the row: the next launch resolves it.
        case killedBetweenTheSaveAndTheRow
        /// The row fails every try: a job later in the same launch writes it from memory.
        case rowFailsEveryTry

        var testDescription: String { rawValue }
    }

    /// Every link flavour, for an import and a stage job.
    static let jobs: [CommitBoundaryCase] = MatrixLink.allCases.flatMap { link in
        MatrixPurpose.allCases.map { CommitBoundaryCase(link: link, purpose: $0) }
    }

    @Test("Commit boundary", arguments: Self.jobs, Fault.allCases)
    func theCommitBoundary(_ job: CommitBoundaryCase, _ fault: Fault) async throws {
        let (flavour, purpose) = (job.link, job.purpose)
        let bench = MatrixBench()
        let card = try MatrixBench.card()
        let link = bench.link(card, flavour)
        let store = FinishFailingCatalogue(bench.catalogue)
        let documents = bench.root.appendingPathComponent("Documents", isDirectory: true)
        let staging = RecordingStaging(StagingFolderDestination(root: documents, place: MatrixBench.place,
                                                                cameraName: "ILCE-7CM2", timeZone: MatrixBench.zone))
        let lookup = CountingLookup(LibraryCommitLookup(library: RecordedLibrary(photos: bench.photos),
                                                        staging: FakeStagingLocator(.unavailable(.containerUnavailable)),
                                                        onThisIPhone: documents))
        let events = Events()
        func engine(over catalogue: any CatalogueStore) -> ImportEngine {
            ImportEngine(catalogue: catalogue, stagingDirectory: bench.work, clock: bench.clock,
                         timeZone: MatrixBench.zone, trace: EngineTraceSink { events.record($0) },
                         commitLookup: lookup)
        }
        let route: ImportRoute = switch purpose {
        case .importToPhotos:
            .photos(bench.photos, staging: staging, onThisIPhone: staging, stagingPlace: MatrixBench.place,
                    authorisation: { .denied })
        case .stage:
            .staging(staging, reason: .chosen, place: MatrixBench.place, onThisIPhone: staging)
        }

        // The second commit (a RAW+JPEG pair) reaches its destination and its row is lost.
        await store.failFinish(from: 2)
        var current = engine(over: store)
        try await link.open()
        try await current.start(.allNew, from: link, camera: MatrixBench.camera, to: route)
        #expect(try await waitFinished(current, bench) == .catalogueUnavailable)
        let left = await bench.catalogue.pendingCommits()
        #expect(left.count == 1)
        #expect(left.first?.files.map(\.role) == [.raw, .processed])

        switch fault {
        case .killedBetweenTheSaveAndTheRow:
            // A new engine over the same catalogue and work folder: what the first kept in memory is gone.
            current = engine(over: bench.catalogue)
            let report = await current.launchPass()
            #expect(report == (purpose == .stage ? PendingCommitReport(foundInStaging: 1)
                                                 : PendingCommitReport(foundInPhotos: 1)))
            #expect(lookup.count == 1)
        case .rowFailsEveryTry:
            await store.failFinish(from: nil)
        }

        try await link.open()
        try await current.start(.allNew, from: link, camera: MatrixBench.camera, to: route)
        #expect(try await waitFinished(current, bench) == .completed)
        if fault == .rowFailsEveryTry {
            #expect(lookup.count == 0, "replayed from memory, no lookup asked")
            #expect(events.all.contains { if case .pendingCommitResolved(_, .replayed) = $0 { true } else { false } })
        }

        // No duplicates, no loss: each file committed once, to the job's destination, with its row; no marker left.
        let committed = purpose == .stage ? await staging.files : await bench.photos.files
        #expect(committed.map(\.name).sorted() == card.objects.map(\.filename).sorted())
        for file in committed {
            let object = try #require(card.objects.first { $0.filename == file.name })
            #expect(file.data == ScriptedCard.content(of: object.handle, in: 0 ..< object.size), "\(file.name)'s bytes")
        }
        #expect(await (purpose == .stage ? bench.photos.attempts : staging.units.count) == 0)
        for object in card.objects {
            let row = await bench.record(of: object)
            if purpose == .stage {
                #expect(row?.staged != nil && row?.state != .partial, "\(object.filename): staged")
            } else {
                #expect(row?.state == .imported, "\(object.filename): imported")
            }
            #expect(row?.tempURL == nil && (row?.resumeOffset ?? 0) == 0)
        }
        #expect(await bench.catalogue.pendingCommits().isEmpty)
        // One copy of each file in Staging, none numbered.
        if purpose == .stage {
            #expect(stagedNames(under: documents) == card.objects.map(\.filename).sorted())
        }
        try await waitUntil("the work folder to empty") { MatrixBench.workFiles(in: bench.work).others.isEmpty }
        #expect(MatrixBench.workFiles(in: bench.work).partials.isEmpty)
        await bench.finish()
    }

    /// Polls the engine (every 2 ms, for at most `MatrixBench.patience`) until its job has finished, moving the clock
    /// past any retry delay; returns the outcome once no file is committing.
    private func waitFinished(_ engine: ImportEngine, _ bench: MatrixBench,
                              sourceLocation: SourceLocation = #_sourceLocation) async throws -> JobOutcome? {
        let deadline = ContinuousClock.now.advanced(by: MatrixBench.patience)
        while true {
            if case let .finished(outcome) = await engine.state,
               !(await engine.currentFiles.contains { $0.phase == .committing }) {
                return outcome
            }
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for the job to finish", sourceLocation: sourceLocation)
                throw MatrixTimeout(what: "the job to finish")
            }
            if await engine.currentFiles.contains(where: { $0.phase == .waitingToRetry }) {
                bench.clock.advance(by: .seconds(6))
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func waitUntil(_ what: String, sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: MatrixBench.patience)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
                throw MatrixTimeout(what: what)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// The names of the regular files under the staging root, sorted.
    private func stagedNames(under root: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        var names: [String] = []
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            names.append(url.lastPathComponent)
        }
        return names.sorted()
    }
}
