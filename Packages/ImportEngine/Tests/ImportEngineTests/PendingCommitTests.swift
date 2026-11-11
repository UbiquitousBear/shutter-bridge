import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// A destination that, at each commit, reads the catalogue's pending-commit markers before handing the unit to `inner`:
/// what the engine had written by the time the destination was called.
actor MarkerWatchingDestination: ImportDestination {
    nonisolated let kind: DestinationKind
    private let inner: any ImportDestination
    private let catalogue: any CatalogueStore
    /// The markers in the store at each commit call, in order.
    private(set) var seen: [[PendingCommit]] = []

    init(_ inner: any ImportDestination, catalogue: any CatalogueStore) {
        self.inner = inner
        self.catalogue = catalogue
        kind = inner.kind
    }

    func commit(_ unit: CommitUnit) async throws(ImportDestinationFailure) -> ImportResult {
        seen.append((try? await catalogue.pendingCommits()) ?? [])
        return try await inner.commit(unit)
    }

    nonisolated func commitTarget(for unit: CommitUnit) -> CommitTarget { inner.commitTarget(for: unit) }
}

/// The pending-commit marker (backlog section 3.1; I9): written before the destination is called, rewritten on a switch
/// to another destination, removed when the commit fails, and cleared with the rows in one store save.
@Suite("Pending-commit markers", .timeLimit(.minutes(1)))
struct PendingCommitTests {
    /// The day folder the harness's staging fakes put every file in.
    static let fakeFolder = "Untitled"

    func route(_ kind: DestinationKind, through destination: any ImportDestination, _ h: Harness) -> ImportRoute {
        kind == .photos ? h.photosRoute(to: destination)
            : .staging(destination, reason: .chosen, place: Harness.onThisIPhone, onThisIPhone: h.files)
    }

    func expectedDestination(_ kind: DestinationKind) -> PendingCommit.Destination {
        kind == .photos ? .photos : .staging(root: .onThisIPhone, folder: Self.fakeFolder)
    }

    @Test(arguments: [DestinationKind.photos, .staging])
    func aSingleFileIsCommittedUnderAMarkerThatIsGoneAfterwards(_ kind: DestinationKind) async throws {
        let catalogue = InMemoryCatalogue()
        let h = Harness(catalogue: catalogue)
        let card = h.singles(["A.JPG"])
        let watcher = MarkerWatchingDestination(kind == .photos ? h.photos : h.files, catalogue: catalogue)
        let job = try await h.start(.items(card), from: h.link(card), to: route(kind, through: watcher, h))
        #expect(await h.waitFinished() == .completed)

        let seen = await watcher.seen
        #expect(seen.count == 1)
        let marker = try #require(seen.first?.first)
        #expect(seen.first?.count == 1)
        #expect(marker.jobID == job.rawValue)
        #expect(marker.destination == expectedDestination(kind))
        #expect(marker.files == [PendingCommit.File(identity: h.identity(of: card[0]), format: card[0].format,
                                                    role: .single, assetDate: card[0].captureDate)])
        #expect(await catalogue.pendingCommits().isEmpty)
        let row = await h.record(for: card[0])
        if kind == .photos { #expect(row?.state == .imported) } else { #expect(row?.staged != nil) }
        await h.cleanup()
    }

    @Test(arguments: [DestinationKind.photos, .staging])
    func aPairIsOneCommitUnderOneMarker(_ kind: DestinationKind) async throws {
        let catalogue = InMemoryCatalogue()
        let h = Harness(catalogue: catalogue)
        let card = h.card(frames: 1)
        let (raw, jpeg) = (card[0], card[1])
        let watcher = MarkerWatchingDestination(kind == .photos ? h.photos : h.files, catalogue: catalogue)
        try await h.start(.allNew, from: h.link(card), to: route(kind, through: watcher, h))
        #expect(await h.waitFinished() == .completed)

        let seen = await watcher.seen
        #expect(seen.count == 1)
        let marker = try #require(seen.first?.first)
        #expect(seen.first?.count == 1)
        #expect(marker.destination == expectedDestination(kind))
        #expect(marker.files.map(\.identity) == [h.identity(of: raw), h.identity(of: jpeg)])
        #expect(marker.files.map(\.role) == [.raw, .processed])
        #expect(await catalogue.pendingCommits().isEmpty)
        #expect(await h.records().count == 2)
        await h.cleanup()
    }

    /// The marker can't be written: nothing reaches the destination, the download is deleted, the file isn't failed
    /// (no retry counted), the job ends `.catalogueUnavailable`, and the next job copies the file again.
    @Test(arguments: [DestinationKind.photos, .staging])
    func aMarkerThatCannotBeWrittenCommitsNothing(_ kind: DestinationKind) async throws {
        let catalogue = FailingCatalogue()
        await catalogue.setFailBeginCommit(from: 1)
        let h = Harness(catalogue: catalogue)
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card)
        let destination = kind == .photos ? h.photos : h.files
        try await h.start(.items(card), from: link, to: h.route(kind))
        #expect(await h.waitFinished() == .catalogueUnavailable)

        #expect(await destination.attempts == 0)
        #expect(await catalogue.beginCommitCalls == ImportPolicy.standard.catalogueWriteAttempts)
        #expect(await link.bytesCalls == ["A.JPG"])
        #expect(h.trace.log.contains(.commitMarkerNotWritten("A.JPG")))
        #expect(await h.outcome(of: card[0]) == nil, "not failed, not skipped: back in the queue")
        let progress = await h.engine.currentProgress
        #expect(progress.filesFailed == 0 && progress.filesDone == 0)
        #expect(await h.records().isEmpty)
        #expect(try await catalogue.pendingCommits().isEmpty)
        await h.engine.lastJobDriver()?.value
        #expect(h.stagedFiles == 0)

        // The catalogue is back: the next job queues the file again and commits it once.
        await catalogue.setFailBeginCommit(from: nil)
        let mark = h.trace.count
        try await h.start(.items(card), from: link, to: h.route(kind))
        #expect(await h.waitFinished(after: mark) == .completed)
        #expect(await destination.committedNames == ["A.JPG", "B.JPG"])
        #expect(try await catalogue.pendingCommits().isEmpty)
        await h.cleanup()
    }

    /// On a link that resumes, the partial copy goes too, even one a checkpoint row points to (which the job's end
    /// would otherwise keep for a later job): the whole download was there, and a row left pointing to a missing file
    /// is restarted by whoever reads it.
    @Test func aMarkerThatCannotBeWrittenDeletesAResumablePartial() async throws {
        let catalogue = FailingCatalogue()
        await catalogue.setFailBeginCommit(from: 1)
        var policy = ImportPolicy.standard
        policy.checkpointInterval = 1000
        let h = Harness(catalogue: catalogue, policy: policy)
        let a = h.item("A.ARW", size: 3000)
        let link = h.resumingLink([a])
        await link.script("A.ARW", .holdAfter(2400))
        try await h.start(.allNew, from: link, to: h.photosRoute)
        // Both crossings (1,200 and 2,100 B) are in the catalogue before the download ends.
        await h.trace.next { $0 == .checkpointSaved("A.ARW", offset: 2100) }
        await link.waitUntilHeld("A.ARW")
        await link.release("A.ARW")
        #expect(await h.waitFinished() == .catalogueUnavailable)
        await h.engine.lastJobDriver()?.value
        #expect(await h.photos.attempts == 0)
        #expect(h.stagedFiles == 0, "the partial's folder is deleted with the download")
        await h.cleanup()
    }

    /// A pair's marker that can't be written sends both halves back: neither is committed.
    @Test func aPairWhoseMarkerCannotBeWrittenGoesBackWhole() async throws {
        let catalogue = FailingCatalogue()
        await catalogue.setFailBeginCommit(from: 1)
        let h = Harness(catalogue: catalogue)
        let card = h.card(frames: 1)
        try await h.start(.allNew, from: h.link(card), to: h.photosRoute)
        #expect(await h.waitFinished() == .catalogueUnavailable)
        #expect(await h.photos.attempts == 0)
        #expect(await h.engine.outcomes().isEmpty)
        #expect(h.trace.log.contains(.commitMarkerNotWritten("DSC00001.ARW")))
        await h.engine.lastJobDriver()?.value
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// Photos refuses the save (3311): the marker is rewritten under the same id with the staging folder before the
    /// staging commit, then cleared with the staged row.
    @Test func thePhotosRefusalRewritesTheMarkerForStaging() async throws {
        let catalogue = FailingCatalogue()
        let h = Harness(catalogue: catalogue)
        await h.photos.deny(from: 1)
        let card = h.singles(["A.JPG"])
        try await h.start(.items(card), from: h.link(card), to: h.photosRoute)
        #expect(await h.waitFinished() == .completed)

        let log = await catalogue.markerLog
        #expect(log.map(\.destination) == [.photos, .staging(root: .onThisIPhone, folder: Self.fakeFolder)])
        #expect(Set(log.map(\.id)).count == 1, "one commit: the same id")
        #expect(log.last?.files.map(\.identity) == [h.identity(of: card[0])])
        #expect(try await catalogue.pendingCommits().isEmpty)
        #expect(await h.files.committedNames == ["A.JPG"])
        #expect(await h.record(for: card[0])?.staged != nil)
        await h.cleanup()
    }

    /// The rewrite after the refusal can't be written: nothing is staged (Photos saved nothing either), and the job
    /// ends `.catalogueUnavailable` with the file back in the queue.
    @Test func aRewriteThatCannotBeWrittenStagesNothing() async throws {
        let catalogue = FailingCatalogue()
        await catalogue.setFailBeginCommit(from: 2)
        let h = Harness(catalogue: catalogue)
        await h.photos.deny(from: 1)
        let card = h.singles(["A.JPG"])
        try await h.start(.items(card), from: h.link(card), to: h.photosRoute)
        #expect(await h.waitFinished() == .catalogueUnavailable)
        #expect(await h.photos.attempts == 1)
        #expect(await h.files.attempts == 0)
        #expect(await h.outcome(of: card[0]) == nil)
        #expect(await h.records().isEmpty)
        // The Photos marker was written, then removed, as nothing was saved.
        #expect(await catalogue.markerLog.map(\.destination) == [.photos])
        #expect(try await catalogue.pendingCommits().isEmpty)
        await h.engine.lastJobDriver()?.value
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// Photos refuses the save, and by then another job has staged the file: nothing is left to stage, so the marker
    /// (written for Photos, which saved nothing) is removed and the file is left out as already staged.
    @Test func aRefusalWithNothingLeftToStageRemovesTheMarker() async throws {
        let catalogue = FailingCatalogue()
        let h = Harness(catalogue: catalogue)
        let card = h.singles(["A.JPG"])
        let dest = HoldingDestination()
        try await h.start(.items(card), from: h.link(card), to: h.photosRoute(to: dest))
        await dest.waitArrived()
        #expect(try await catalogue.pendingCommits().count == 1)
        // Another job stages the same file while Photos has it.
        try await catalogue.markStaged(h.identity(of: card[0]), format: card[0].format,
                                       at: StagedLocation(root: .onThisIPhone, relativePath: "Untitled/A.JPG"))
        await dest.release(throwing: .photosAccessDenied)
        #expect(await h.waitFinished() == .completed)

        #expect(await h.outcome(of: card[0]) == .skipped(.alreadyStaged))
        #expect(await catalogue.markerLog.map(\.destination) == [.photos], "no rewrite: nothing was staged")
        #expect(await catalogue.abandonCommitCalls == 1)
        #expect(try await catalogue.pendingCommits().isEmpty)
        #expect(await h.files.attempts == 0)
        await h.cleanup()
    }

    /// iCloud Drive goes away mid-commit: the marker is rewritten for the staging folder on this iPhone.
    @Test func losingICloudDriveRewritesTheMarkerForThisIPhone() async throws {
        let catalogue = FailingCatalogue()
        let h = Harness(catalogue: catalogue)
        await h.iCloud.becomeUnavailable(from: 1)
        let card = h.singles(["A.JPG"])
        try await h.start(.items(card), from: h.link(card), to: h.stageRouteInICloud)
        #expect(await h.waitFinished() == .completed)
        let log = await catalogue.markerLog
        #expect(log.map(\.destination) == [.staging(root: .iCloudDrive, folder: Self.fakeFolder),
                                           .staging(root: .onThisIPhone, folder: Self.fakeFolder)])
        #expect(Set(log.map(\.id)).count == 1)
        #expect(try await catalogue.pendingCommits().isEmpty)
        await h.cleanup()
    }

    /// A commit that fails removes its marker (one try).
    @Test func aFailedCommitRemovesItsMarker() async throws {
        let catalogue = FailingCatalogue()
        let h = Harness(catalogue: catalogue)
        await h.photos.fail(attempt: 1, with: .rejected(detail: "test"))
        let card = h.singles(["A.JPG", "B.JPG"])
        try await h.start(.items(card), from: h.link(card), to: h.photosRoute)
        #expect(await h.waitFinished() == .completed)
        #expect(await h.outcome(of: card[0]) == .failed(.destination(.rejected(detail: "test"))))
        #expect(await catalogue.markerLog.count == 2)
        #expect(await catalogue.abandonCommitCalls == 1)
        #expect(try await catalogue.pendingCommits().isEmpty)
        await h.cleanup()
    }

    /// A marker whose removal fails is left behind; the job goes on as before.
    @Test func aFailedAbandonLeavesTheMarkerAndTheJobGoesOn() async throws {
        let catalogue = FailingCatalogue()
        await catalogue.setFailAbandonCommit(true)
        let h = Harness(catalogue: catalogue)
        await h.photos.fail(attempt: 1, with: .rejected(detail: "test"))
        let card = h.singles(["A.JPG", "B.JPG"])
        try await h.start(.items(card), from: h.link(card), to: h.photosRoute)
        #expect(await h.waitFinished() == .completed)
        #expect(await catalogue.abandonCommitCalls == 1, "one try")
        let left = try await catalogue.pendingCommits()
        #expect(left.map { $0.files.map(\.identity.filename) } == [["A.JPG"]])
        #expect(await h.record(for: card[1])?.state == .imported)
        await h.cleanup()
    }

    /// `finishCommit` fails every try: no row, the marker stays in the store, and the writes it couldn't make stay in
    /// memory under the marker's id, for the resolution to write later in this launch. The job ends as before.
    @Test(arguments: [DestinationKind.photos, .staging])
    func aFinishThatFailsKeepsTheMarkerAndTheWrites(_ kind: DestinationKind) async throws {
        let catalogue = FailingCatalogue()
        await catalogue.setFailFinishCommit(true)
        let h = Harness(catalogue: catalogue)
        let card = h.card(frames: 1)
        try await h.start(.allNew, from: h.link(card), to: h.route(kind))
        #expect(await h.waitFinished() == .catalogueUnavailable)
        await h.engine.settleCommits(ofJobsOtherThan: UUID())

        let left = try await catalogue.pendingCommits()
        #expect(left.count == 1)
        let marker = try #require(left.first)
        #expect(marker.files.map(\.role) == [.raw, .processed])
        let unrecorded = await h.engine.unrecordedCommits
        #expect(Array(unrecorded.keys) == [marker.id])
        let writes = try #require(unrecorded[marker.id])
        #expect(writes.count == 2)
        for (write, item) in zip(writes, card) {
            switch (kind, write) {
            case let (.photos, .imported(record)):
                #expect(record.identity == h.identity(of: item) && record.state == .imported)
                #expect(record.location == .photosAsset(localIdentifier: "asset-1"))
            case let (.staging, .staged(identity, _, location)):
                #expect(identity == h.identity(of: item))
                #expect(location.relativePath == "Untitled/" + item.name)
            default:
                Issue.record("unexpected write \(write) for \(kind)")
            }
        }
        #expect(await h.records().isEmpty)
        await h.cleanup()
    }
}
