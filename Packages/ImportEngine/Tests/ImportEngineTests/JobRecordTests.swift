import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// Every job leaves one record for History, matching its last progress (backlog section 4; I9).
@Suite("Job records", .timeLimit(.minutes(1)))
struct JobRecordTests {
    /// The job's one record, once every write so far has landed.
    func onlyRecord(_ h: Harness, sourceLocation: SourceLocation = #_sourceLocation) async throws -> JobRecord {
        await h.engine.settleJobRecords()
        let jobs = try await h.catalogue.jobs(camera: nil)
        #expect(jobs.count == 1, "one record per job", sourceLocation: sourceLocation)
        return try #require(jobs.first, sourceLocation: sourceLocation)
    }

    /// The record's counts, field by field, against the progress the Import screen last had.
    func expectMatches(_ record: JobRecord, _ progress: ImportProgress,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(record.filesTotal == progress.filesTotal, sourceLocation: sourceLocation)
        #expect(record.filesImported == progress.filesImported, sourceLocation: sourceLocation)
        #expect(record.filesStaged == progress.filesStaged, sourceLocation: sourceLocation)
        #expect(record.filesSkipped == progress.filesSkipped, sourceLocation: sourceLocation)
        #expect(record.filesFailed == progress.filesFailed, sourceLocation: sourceLocation)
        #expect(record.bytesTotal == progress.bytesTotal, sourceLocation: sourceLocation)
        #expect(record.bytesDone == progress.bytesDone, sourceLocation: sourceLocation)
    }

    @Test func aCompletedJobsRecordMatchesItsLastProgress() async throws {
        let h = Harness()
        // A imported, B not on the card (skipped), C rejected by Photos (failed), D imported.
        let picked = h.singles(["A.JPG", "B.JPG", "C.JPG", "D.JPG"])
        let card = picked.filter { $0.name != "B.JPG" }
        await h.photos.fail(attempt: 2, with: .rejected(detail: "test"))
        let job = try await h.start(.items(picked), from: h.link(card))
        #expect(await h.waitFinished() == .completed)

        let record = try await onlyRecord(h)
        let progress = await h.engine.currentProgress
        #expect(progress.filesImported == 2 && progress.filesSkipped == 1 && progress.filesFailed == 1)
        expectMatches(record, progress)
        #expect(record.id == job.rawValue)
        #expect(record.camera == h.camera)
        #expect(record.purpose == .import && record.destination == .photos && record.carrier == .usb)
        #expect(record.selection == .picked(picked.map { h.identity(of: $0).contentKey }))
        #expect(record.outcome == .completed)
        let finished = try #require(record.finishedAt)
        #expect(finished >= record.startedAt)
        #expect(record.failedFiles == [h.identity(of: picked[2]).contentKey])
        #expect(record.albumIdentifier == nil, "a destination that files into no album")
        await h.cleanup()
    }

    /// A Photos job records the album its saves went into, as soon as the first save into it has resolved: a job the
    /// app's end interrupts still names it (History: "Photos, album “…”").
    @Test func aPhotosJobRecordsItsAlbumAsSoonAsItIsKnown() async throws {
        let h = Harness()
        await h.photos.fileInto(album: "ALBUM-1")
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card)
        await link.script("B.JPG", .hold)
        try await h.start(.items(card), from: link)
        await h.trace.next(.imported("A.JPG", .photos))
        let b = await link.nextHeldCall("B.JPG")
        let running = try await onlyRecord(h)
        #expect(running.finishedAt == nil && running.outcome == nil)
        #expect(running.albumIdentifier == "ALBUM-1")
        #expect(running.filesImported == 1, "the album is recorded with the file it holds")

        b.release()
        #expect(await h.waitFinished() == .completed)
        let record = try await onlyRecord(h)
        #expect(record.destination == .photos && record.albumIdentifier == "ALBUM-1")
        #expect(record.filesImported == 2)
        await h.cleanup()
    }

    /// End to end over the real Photos destination: the record keeps the identifier of the album the destination made
    /// and stored (its key read from the plan, so D11's keying doesn't touch this test).
    @Test func thePhotosDestinationsAlbumReachesTheRecord() async throws {
        let h = Harness()
        let library = AlbumLibrary()
        let store = InMemoryAlbumIdentifierStore()
        let plan = AlbumPlan(choice: .perCamera, cameraKey: h.camera.rawValue, cameraName: "ILCE-7CM2", importID: "job",
                             importDate: Harness.t0)
        let destination = PhotosLibraryDestination(library: library, albumStore: store, albumPlan: plan)
        let card = h.singles(["A.JPG", "B.JPG"])
        try await h.start(.items(card), from: h.link(card), to: h.photosRoute(to: destination))
        #expect(await h.waitFinished() == .completed)
        let record = try await onlyRecord(h)
        let stored = try #require(await store.albumIdentifier(forKey: plan.albums[0].key))
        #expect(record.albumIdentifier == stored)
        #expect(await library.created == ["ILCE-7CM2"])
        await h.cleanup()
    }

    @Test func aStageJobIsRecordedAsOne() async throws {
        let h = Harness()
        await h.photos.fileInto(album: "ALBUM-1")
        let card = h.card(frames: 2)
        let start = Harness.t0, end = Harness.t0.addingTimeInterval(60)
        try await h.start(.dateRange(start ... end), from: h.link(card), to: h.stageRoute)
        #expect(await h.waitFinished() == .completed)
        let record = try await onlyRecord(h)
        #expect(record.purpose == .stage && record.destination == .staging)
        #expect(record.selection == .dateRange(start ... end))
        #expect(record.filesStaged == 4 && record.filesImported == 0)
        #expect(record.albumIdentifier == nil, "a stage job files into no album")
        expectMatches(record, await h.engine.currentProgress)
        await h.cleanup()
    }

    /// An import job Photos refused part-way is recorded as going to Staging. Refused from the second save, it keeps
    /// the album the first went into (History: "Staging instead of Photos"); refused at the first, it has none.
    @Test(arguments: [1, 2])
    func anImportJobStagedInsteadSaysStaging(deniedFrom: Int) async throws {
        let h = Harness()
        await h.photos.fileInto(album: "ALBUM-1")
        await h.photos.deny(from: deniedFrom)
        let card = h.singles(["A.JPG", "B.JPG"])
        try await h.start(.newItems(card), from: h.link(card))
        #expect(await h.waitFinished() == .completed)
        let record = try await onlyRecord(h)
        #expect(record.purpose == .import && record.destination == .staging)
        #expect(record.selection == .pickedNew(card.map { h.identity(of: $0).contentKey }))
        if deniedFrom == 2 {
            #expect(record.filesImported == 1 && record.filesStaged == 1)
            #expect(record.albumIdentifier == "ALBUM-1")
        } else {
            #expect(record.filesImported == 0 && record.filesStaged == 2)
            #expect(record.albumIdentifier == nil)
        }
        await h.cleanup()
    }

    @Test func aCancelledJobIsRecordedCancelled() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card)
        await link.script("A.JPG", .hold)
        try await h.start(.allNew, from: link)
        _ = await link.nextHeldCall("A.JPG")
        await h.engine.cancel()
        let record = try await onlyRecord(h)
        #expect(record.outcome == .cancelled && record.finishedAt != nil)
        #expect(record.selection == .allNew)
        expectMatches(record, await h.engine.currentProgress)
        await h.cleanup()
    }

    @Test(arguments: [false, true])
    func aStoppedJobIsRecordedWithItsKind(_ byTheDestination: Bool) async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link = h.link(card)
        if byTheDestination {
            await h.photos.fail(attempt: 2, with: .notEnoughSpace)
        } else {
            await link.script("B.JPG", .fail(.phoneStorageFull))
        }
        try await h.start(.items(card), from: link)
        #expect(await h.waitFinished() == .stopped(.phoneStorageFull))
        let record = try await onlyRecord(h)
        #expect(record.outcome == .stopped(reason: CameraLinkFailure.Kind.phoneStorageFull.rawValue))
        #expect(record.failedFiles == [h.identity(of: card[1]).contentKey])
        expectMatches(record, await h.engine.currentProgress)
        await h.cleanup()
    }

    /// The catalogue can't be read: the job ends at its diff, and its record (which the store still takes) says so.
    @Test func aJobTheCatalogueStoppedIsRecordedSo() async throws {
        let catalogue = FailingCatalogue()
        await catalogue.setFailStates(true)
        let h = Harness(catalogue: catalogue)
        let card = h.singles(["A.JPG"])
        try await h.start(.items(card), from: h.link(card))
        #expect(await h.waitFinished() == .catalogueUnavailable)
        let record = try await onlyRecord(h)
        #expect(record.outcome == .catalogueUnavailable && record.finishedAt != nil)
        await h.cleanup()
    }

    /// The app is killed mid-job: the record written so far has no end time, which History reads as *Stopped early*;
    /// a later launch's engine over the same catalogue finds it as it was left, and its own job is a record of its own.
    @Test func aJobTheAppLosesLeavesARecordWithNoEnd() async throws {
        let catalogue = InMemoryCatalogue()
        let h = Harness(catalogue: catalogue)
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card)
        await link.script("B.JPG", .hold)
        try await h.start(.items(card), from: link)
        _ = await link.nextHeldCall("B.JPG")
        try await h.engine.pause(.byPerson) // a pause writes the record with the counts so far
        let record = try await onlyRecord(h)
        #expect(record.finishedAt == nil && record.outcome == nil)
        #expect(record.filesImported == 1 && record.filesTotal == 2)

        // The next launch: a new engine over the same store. The lost job's record is untouched by it.
        let next = Harness(catalogue: catalogue)
        let fresh = next.singles(["C.JPG"], prefix: "s2")
        try await next.start(.items(fresh), from: next.link(fresh))
        #expect(await next.waitFinished() == .completed)
        await next.engine.settleJobRecords()
        let lost = await catalogue.job(record.id)
        #expect(lost == record)
        #expect(await catalogue.jobs(camera: nil).count == 2)
        await next.cleanup()
        await h.cleanup()
    }

    /// A reconnect carries the same record on: one record for the job, whatever the links.
    @Test func aReconnectContinuesOneRecord() async throws {
        let h = Harness()
        await h.photos.fileInto(album: "ALBUM-1")
        let card1 = h.singles(["A.JPG", "B.JPG"], prefix: "s1")
        let link1 = h.link(card1)
        await link1.script("B.JPG", .hold)
        try await h.start(.items(card1), from: link1)
        let b = await link1.nextHeldCall("B.JPG")
        link1.send(.removed)
        await h.trace.next(.paused(.cameraRemoved))
        b.release(.fail(.disconnected))
        let paused = try await onlyRecord(h)
        #expect(paused.finishedAt == nil && paused.filesImported == 1)
        #expect(paused.albumIdentifier == "ALBUM-1")

        let link2 = h.link(h.singles(["A.JPG", "B.JPG"], prefix: "s2"), mode: .wifi(.cameraNetwork))
        await link2.script("B.JPG", .hold)
        try await h.engine.reconnect(link2)
        // Written at the reconnect itself: the job still running, over the new link.
        let b2 = await link2.nextHeldCall("B.JPG")
        let carriedOn = try await onlyRecord(h)
        #expect(carriedOn.id == paused.id && carriedOn.finishedAt == nil && carriedOn.outcome == nil)
        #expect(carriedOn.carrier == .wifi, "the link it carries on over")
        #expect(carriedOn.albumIdentifier == "ALBUM-1", "the album recorded before the loss")
        b2.release()
        #expect(await h.waitFinished() == .completed)
        let record = try await onlyRecord(h)
        #expect(record.id == paused.id && record.startedAt == paused.startedAt)
        #expect(record.outcome == .completed && record.filesImported == 2)
        #expect(record.carrier == .wifi, "the link it finished on")
        #expect(record.albumIdentifier == "ALBUM-1")
        expectMatches(record, await h.engine.currentProgress)
        await h.cleanup()
    }

    /// A commit still in flight when the job was cancelled resolves its file on the ended job: the record is written
    /// again, so it still matches the last progress, and names the album the save went into.
    @Test func aCommitThatLandsAfterTheEndUpdatesTheRecord() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let dest = HoldingDestination(filedAlbum: "ALBUM-H")
        try await h.start(.items(card), from: h.link(card), to: h.photosRoute(to: dest))
        await dest.waitArrived()
        await h.engine.cancel()
        let atEnd = try await onlyRecord(h)
        #expect(atEnd.outcome == .cancelled && atEnd.filesImported == 0)
        #expect(atEnd.albumIdentifier == nil)

        await dest.release()
        await h.trace.next(.imported("A.JPG", .photos)) // resolved on the ended job
        let record = try await onlyRecord(h)
        #expect(record.outcome == .cancelled && record.filesImported == 1)
        #expect(record.albumIdentifier == "ALBUM-H")
        expectMatches(record, await h.engine.currentProgress)
        await h.cleanup()
    }

    /// A commit still in flight when the job was cancelled fails on the ended job: the record is written again, with
    /// the file failed.
    @Test func aCommitThatFailsAfterTheEndUpdatesTheRecord() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let dest = HoldingDestination()
        try await h.start(.items(card), from: h.link(card), to: h.photosRoute(to: dest))
        await dest.waitArrived()
        await h.engine.cancel()
        let atEnd = try await onlyRecord(h)
        #expect(atEnd.outcome == .cancelled && atEnd.filesFailed == 0)

        await dest.release(throwing: .rejected(detail: "test"))
        await h.trace.next { if case .failed("A.JPG", _) = $0 { true } else { false } }
        let record = try await onlyRecord(h)
        #expect(record.outcome == .cancelled && record.filesFailed == 1)
        #expect(record.failedFiles == [h.identity(of: card[0]).contentKey])
        expectMatches(record, await h.engine.currentProgress)
        await h.cleanup()
    }

    /// A commit still in flight when the job was cancelled, whose marker can't be rewritten after Photos refused the
    /// save, sends its file back to the queue on the ended job: the record is written again, so it still matches the
    /// last progress.
    @Test func aCommitThatCannotBeginAfterTheEndUpdatesTheRecord() async throws {
        let catalogue = FailingCatalogue()
        await catalogue.setFailBeginCommit(from: 2)
        let h = Harness(catalogue: catalogue)
        let card = h.singles(["A.JPG"])
        let dest = HoldingDestination()
        try await h.start(.items(card), from: h.link(card), to: h.photosRoute(to: dest))
        await dest.waitArrived()
        await h.engine.cancel()
        let atEnd = try await onlyRecord(h)
        #expect(atEnd.outcome == .cancelled && atEnd.bytesDone == card[0].size)

        await dest.release(throwing: .photosAccessDenied)
        await h.trace.next(.commitMarkerNotWritten("A.JPG"))
        await h.engine.lastJobDriver()?.value // the lane that waited for the commit has settled it
        #expect(await catalogue.beginCommitCalls == 1 + ImportPolicy.standard.catalogueWriteAttempts,
                "the Photos marker, then every try at the rewrite")
        #expect(await h.outcome(of: card[0]) == nil, "back in the queue, not failed")
        let record = try await onlyRecord(h)
        #expect(record.outcome == .cancelled)
        expectMatches(record, await h.engine.currentProgress)
        await h.cleanup()
    }

    /// A record the store refuses doesn't stop the import; the next write replaces it.
    @Test func aRecordTheStoreRefusesIsWrittenAgainLater() async throws {
        let catalogue = FailingCatalogue()
        await catalogue.setFailRecordJob(true)
        let h = Harness(catalogue: catalogue)
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card)
        await link.script("B.JPG", .hold)
        try await h.start(.items(card), from: link)
        let b = await link.nextHeldCall("B.JPG")
        await h.engine.settleJobRecords()
        #expect(h.trace.log.contains(.jobRecordNotWritten))
        #expect(try await catalogue.jobs(camera: nil).isEmpty)

        await catalogue.setFailRecordJob(false)
        b.release()
        #expect(await h.waitFinished() == .completed)
        let record = try await onlyRecord(h)
        #expect(record.outcome == .completed && record.filesImported == 2)
        await h.cleanup()
    }
}

/// A Photos library that makes albums ("ALBUM-n"), finds them by identifier and saves into them, for the end-to-end
/// album test.
private actor AlbumLibrary: PhotoLibraryClient {
    private var albums: Set<String> = []
    private(set) var created: [String] = []
    private var saves = 0

    func authorisation() -> PhotosAuthorisation { .authorised }
    func requestReadWriteAuthorisation() -> PhotosAuthorisation { .authorised }
    func album(withIdentifier identifier: String) -> AlbumLookup {
        albums.contains(identifier) ? .found(canAddContent: true) : .missing
    }

    func createAlbum(titled title: String) throws(PhotoLibraryFailure) -> String {
        created.append(title)
        let id = "ALBUM-\(created.count)"
        albums.insert(id)
        return id
    }

    func save(_ asset: AssetCreation, toAlbums albumIdentifiers: [String]) throws(PhotoLibraryFailure) -> String {
        saves += 1
        return "asset-\(saves)"
    }
}
