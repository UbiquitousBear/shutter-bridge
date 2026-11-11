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
        await h.cleanup()
    }

    @Test func aStageJobIsRecordedAsOne() async throws {
        let h = Harness()
        let card = h.card(frames: 2)
        let start = Harness.t0, end = Harness.t0.addingTimeInterval(60)
        try await h.start(.dateRange(start ... end), from: h.link(card), to: h.stageRoute)
        #expect(await h.waitFinished() == .completed)
        let record = try await onlyRecord(h)
        #expect(record.purpose == .stage && record.destination == .staging)
        #expect(record.selection == .dateRange(start ... end))
        #expect(record.filesStaged == 4 && record.filesImported == 0)
        expectMatches(record, await h.engine.currentProgress)
        await h.cleanup()
    }

    /// An import job Photos refused part-way is recorded as going to Staging.
    @Test func anImportJobStagedInsteadSaysStaging() async throws {
        let h = Harness()
        await h.photos.deny(from: 2)
        let card = h.singles(["A.JPG", "B.JPG"])
        try await h.start(.newItems(card), from: h.link(card))
        #expect(await h.waitFinished() == .completed)
        let record = try await onlyRecord(h)
        #expect(record.purpose == .import && record.destination == .staging)
        #expect(record.selection == .pickedNew(card.map { h.identity(of: $0).contentKey }))
        #expect(record.filesImported == 1 && record.filesStaged == 1)
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

        let link2 = h.link(h.singles(["A.JPG", "B.JPG"], prefix: "s2"), mode: .wifi(.cameraNetwork))
        try await h.engine.reconnect(link2)
        #expect(await h.waitFinished() == .completed)
        let record = try await onlyRecord(h)
        #expect(record.id == paused.id && record.startedAt == paused.startedAt)
        #expect(record.outcome == .completed && record.filesImported == 2)
        #expect(record.carrier == .wifi, "the link it finished on")
        expectMatches(record, await h.engine.currentProgress)
        await h.cleanup()
    }

    /// A commit still in flight when the job was cancelled resolves its file on the ended job: the record is written
    /// again, so it still matches the last progress.
    @Test func aCommitThatLandsAfterTheEndUpdatesTheRecord() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let dest = HoldingDestination()
        try await h.start(.items(card), from: h.link(card), to: h.photosRoute(to: dest))
        await dest.waitArrived()
        await h.engine.cancel()
        let atEnd = try await onlyRecord(h)
        #expect(atEnd.outcome == .cancelled && atEnd.filesImported == 0)

        await dest.release()
        await h.trace.next(.imported("A.JPG", .photos)) // resolved on the ended job
        let record = try await onlyRecord(h)
        #expect(record.outcome == .cancelled && record.filesImported == 1)
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
