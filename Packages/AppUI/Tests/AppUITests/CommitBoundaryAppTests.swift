import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import Synchronization
import Testing
@testable import AppUI

/// A lookup that gives one answer for every marker, built from the marker.
private struct AnsweringLookup: CommitLookup {
    let answer: @Sendable (PendingCommit) -> CommitLookupAnswer
    func look(for pending: PendingCommit) async -> CommitLookupAnswer { answer(pending) }
}

/// The commit boundary in the app (backlog section 3.1, I15): the launch pass, Browse's badges after it, the
/// possible-duplicate line in the Import outcome and the bench check's launch argument.
@MainActor
@Suite("The commit boundary in the app")
struct CommitBoundaryAppTests {
    func appModel(discovery: FakeDiscovery, catalogue: InMemoryCatalogue,
                  lookup: any CommitLookup) -> (AppModel, ImportEngine) {
        let engine = ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging(), commitLookup: lookup)
        let app = AppModel(discovery: discovery, services: services(), catalogue: catalogue, engine: engine,
                           settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
                           destinations: FakeDestinations(), cameraKey: CameraKeys.fromDescriptor)
        return (app, engine)
    }

    /// A Photos commit of `item` left behind by an earlier launch, under the key and zone Browse reads it with.
    func leaveMarker(for item: CameraItem, of link: FakeLink, in catalogue: InMemoryCatalogue) async throws {
        let key = CameraKeys.key(for: link.descriptor, material: nil)
        let identity = try #require(item.identity(camera: key, timeZone: TimeZone.current))
        try await catalogue.beginCommit(PendingCommit(
            id: UUID(), destination: .photos,
            files: [PendingCommit.File(identity: identity, format: item.format, role: .single,
                                       assetDate: item.captureDate)],
            writtenAt: Date()))
    }

    @Test func theLaunchPassReadsBrowsesBadgesAgainWhenItWroteRows() async throws {
        let shown = item("DSC00001.JPG")
        let link = FakeLink(items: [shown, item("DSC00002.JPG", at: 5)])
        let discovery = FakeDiscovery(link: link)
        let catalogue = InMemoryCatalogue()
        try await leaveMarker(for: shown, of: link, in: catalogue)
        let (app, _) = appModel(discovery: discovery, catalogue: catalogue, lookup: AnsweringLookup {
            .found($0.importedWrites(localIdentifier: "earlier"))
        })
        let browse = app.browseModel(for: link.descriptor)
        let run = Task { await browse.run() }
        #expect(await eventually { browse.phase == .listed })
        #expect(browse.imported.isEmpty)

        let report = await app.runLaunchPass()
        #expect(report == PendingCommitReport(foundInPhotos: 1))
        #expect(browse.imported == [shown.id])
        #expect(await catalogue.pendingCommits().isEmpty)
        // Called again, it is the same pass.
        #expect(await app.runLaunchPass() == report)
        run.cancel()
        await run.value
    }

    @Test func aPossibleDuplicateIsSaidInTheNextImportsOutcome() async throws {
        let first = item("DSC00001.JPG")
        let link = FakeLink(items: [first])
        await link.set(writesListedSize: true)
        let discovery = FakeDiscovery(link: link)
        let catalogue = InMemoryCatalogue()
        try await leaveMarker(for: first, of: link, in: catalogue)
        let (app, _) = appModel(discovery: discovery, catalogue: catalogue,
                                lookup: AnsweringLookup { _ in .notFound(underLimitedAccess: true) })
        #expect(await app.runLaunchPass() == PendingCommitReport(notFound: 1, possibleDuplicates: 1))
        let browse = app.browseModel(for: link.descriptor)
        let run = Task { await browse.run() }
        #expect(await eventually { browse.phase == .listed })
        browse.selectAllNew()
        await browse.importSelected()
        #expect(await eventually {
            await app.importer.refresh()
            return app.importer.isFinished
        })
        #expect(app.importer.possibleDuplicatesLine == "1 photo from an interrupted import may now be in Photos twice.")
        run.cancel()
        await run.value
    }

    @Test func thePossibleDuplicateWording() {
        #expect(ImportWording.possibleDuplicates(0) == nil)
        #expect(ImportWording.possibleDuplicates(1) == "1 photo from an interrupted import may now be in Photos twice.")
        #expect(ImportWording.possibleDuplicates(3) == "3 photos from an interrupted import may now be in Photos twice.")
    }

    /// The bench check's launch argument ends the app between a commit and its row: here `end` only counts, so the row
    /// still follows.
    @Test func theBenchArgumentEndsTheAppBeforeTheCatalogueWrite() async throws {
        let engine = ImportEngine(catalogue: InMemoryCatalogue(), stagingDirectory: temporaryStaging())
        let log = LeveledLog()
        #expect(!(await CommitBoundaryBench.install(on: engine, arguments: ["ShutterBridge"], log: log, end: {})))
        #expect(log.entries.isEmpty)

        let first = item("DSC00001.JPG")
        let link = FakeLink(items: [first])
        await link.set(writesListedSize: true)
        let discovery = FakeDiscovery(link: link)
        let catalogue = InMemoryCatalogue()
        let (app, appEngine) = appModel(discovery: discovery, catalogue: catalogue, lookup: NoCommitLookup())
        let ended = Mutex<[Int]>([])
        #expect(await CommitBoundaryBench.install(on: appEngine, arguments: ["ShutterBridge", "-EndBeforeFinishCommit"],
                                                  log: log, end: { ended.withLock { $0.append(1) } }))
        #expect(log.entries.map(\.line) == ["bench: this launch ends the app after the first commit, before its catalogue write"])
        let browse = app.browseModel(for: link.descriptor)
        let run = Task { await browse.run() }
        #expect(await eventually { browse.phase == .listed })
        browse.selectAllNew()
        await browse.importSelected()
        #expect(await eventually {
            await app.importer.refresh()
            return app.importer.isFinished
        })
        #expect(ended.withLock { $0 } == [1])
        #expect(log.entries.last?.line == "bench: ending the app between a commit and its catalogue write")
        run.cancel()
        await run.value
    }
}
