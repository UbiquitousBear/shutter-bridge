import Foundation
import PTPKit
import Testing
@testable import Catalogue

// Catalogue V4 (Iteration 2): cull marks, job records, staged records, Forget imports and the pending-commit marker.
// The contract runs against every store this platform has (`StoreKind.available`): the in-memory store on Linux, and
// the SwiftData store too in CI's iOS Simulator run.

/// Made-up values for the V4 tests.
enum V4Fixtures {
    typealias C = CatalogueContractTests

    static let raw = C.id("DSC00001.ARW", "20261101T143005", 44_000_000)
    static let jpeg = C.id("DSC00001.JPG", "20261101T143005", 9_000_000)
    static let other = C.id("DSC00002.ARW", "20261101T143006", 44_000_001)

    static let t0 = Date(timeIntervalSinceReferenceDate: 815_000_000.25)
    static let t1 = Date(timeIntervalSinceReferenceDate: 815_000_100.5)
    static let t2 = Date(timeIntervalSinceReferenceDate: 815_000_200.75)

    static let jobA = UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!
    static let jobB = UUID(uuidString: "00000000-0000-4000-8000-00000000000B")!
    static let jobC = UUID(uuidString: "00000000-0000-4000-8000-00000000000C")!
    static let commit1 = UUID(uuidString: "00000000-0000-4000-8000-0000000000D1")!
    static let commit2 = UUID(uuidString: "00000000-0000-4000-8000-0000000000D2")!
    static let commit3 = UUID(uuidString: "00000000-0000-4000-8000-0000000000D3")!

    static let staged = StagedLocation(root: .iCloudDrive, relativePath: "Staging/ILCE-7CM2/2026-11-01/DSC00001.ARW",
                                       stagedAt: t1)

    /// A job with every field set.
    static var fullJob: JobRecord {
        JobRecord(id: jobA, camera: C.camera, purpose: .stage, destination: .staging, carrier: .wifi,
                  albumIdentifier: "ALBUM-0000/L0/040",
                  selection: .picked([raw.contentKey, C.id("dsc00003.jpg", "20261101T143007", 7).contentKey]),
                  startedAt: t0, finishedAt: t1, outcome: .stopped(reason: "storageFull"), filesTotal: 10,
                  filesImported: 0, filesStaged: 6, filesSkipped: 2, filesFailed: 2, bytesTotal: 400_000_000,
                  bytesDone: 300_000_000, failedFiles: [other.contentKey, jpeg.contentKey])
    }

    /// A Photos commit of a RAW+JPEG pair, the RAW first.
    static var pairCommit: PendingCommit {
        PendingCommit(id: commit1, jobID: jobA, destination: .photos,
                      files: [.init(identity: raw, format: .raw, role: .raw, assetDate: t0),
                              .init(identity: jpeg, format: .jpeg, role: .processed, assetDate: t0)],
                      writtenAt: t1)
    }
}

@Suite("Catalogue store contract: cull marks")
struct CullMarkContractTests {
    typealias C = CatalogueContractTests
    typealias F = V4Fixtures

    @Test(arguments: StoreKind.available)
    func aMarkRoundTripsAndIsMatchedByContent(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let inMSC = C.id("DSC04512.ARW", "20261108T101530", 40_329_216, camera: C.mscCamera)
        try await s.store.setMark(.keep, rating: 4, for: [inMSC.contentKey], at: F.t0)
        let expected = MarkRecord(decision: .keep, rating: 4, markedAt: F.t0)
        // The same file under another camera key, folder or ASCII case is the same key; another second or size isn't.
        let inMTP = C.id("DSC04512.ARW", "20261108T101530", 40_329_216, folder: "", camera: C.mtpCamera).contentKey
        let lowerCase = C.id("dsc04512.arw", "20261108T101530", 40_329_216, folder: "Staging").contentKey
        let otherSecond = C.id("DSC04512.ARW", "20261108T101531", 40_329_216).contentKey
        let otherSize = C.id("DSC04512.ARW", "20261108T101530", 40_329_217).contentKey
        #expect(inMTP == inMSC.contentKey && lowerCase == inMSC.contentKey)
        #expect(try await s.store.marks(of: [inMTP, otherSecond, otherSize]) == [inMTP: expected])
        #expect(try await s.store.marks(of: [lowerCase]) == [lowerCase: expected])
        #expect(try await s.store.marks(of: []).isEmpty)
        // A mark is not a file row.
        #expect(try await s.rows().isEmpty)
        #expect(try await s.store.states(of: [inMSC]) == [inMSC: .new])
    }

    @Test(arguments: StoreKind.available)
    func aPairIsMarkedTogetherAndAMarkIsReplacedWhole(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let pair = [F.raw.contentKey, F.jpeg.contentKey]
        try await s.store.setMark(.keep, rating: 5, for: pair, at: F.t0)
        let kept = MarkRecord(decision: .keep, rating: 5, markedAt: F.t0)
        #expect(try await s.store.marks(of: pair + [F.other.contentKey])
            == [F.raw.contentKey: kept, F.jpeg.contentKey: kept])
        // A new mark with no stars clears the stars: the whole mark is written.
        try await s.store.setMark(.reject, rating: 0, for: pair, at: F.t1)
        let rejected = MarkRecord(decision: .reject, rating: 0, markedAt: F.t1)
        #expect(try await s.store.marks(of: pair) == [F.raw.contentKey: rejected, F.jpeg.contentKey: rejected])
        // Stars alone, with no decision.
        try await s.store.setMark(nil, rating: 2, for: [F.other.contentKey], at: F.t2)
        #expect(try await s.store.marks(of: [F.other.contentKey])
            == [F.other.contentKey: MarkRecord(decision: nil, rating: 2, markedAt: F.t2)])
        // One key given twice is one mark.
        try await s.store.setMark(.keep, rating: 1, for: [F.other.contentKey, F.other.contentKey], at: F.t2)
        #expect(try await s.store.marks(of: [F.other.contentKey])
            == [F.other.contentKey: MarkRecord(decision: .keep, rating: 1, markedAt: F.t2)])
    }

    @Test(arguments: StoreKind.available)
    func aRatingOutsideZeroToFiveIsRefusedAndWritesNothing(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.setMark(.keep, rating: 3, for: [F.raw.contentKey], at: F.t0)
        for rating in [-1, 6] {
            await #expect(throws: CatalogueFailure.ratingOutOfRange(rating)) {
                try await s.store.setMark(.reject, rating: rating, for: [F.raw.contentKey, F.other.contentKey],
                                          at: F.t1)
            }
        }
        #expect(try await s.store.marks(of: [F.raw.contentKey, F.other.contentKey])
            == [F.raw.contentKey: MarkRecord(decision: .keep, rating: 3, markedAt: F.t0)])
    }

    @Test(arguments: StoreKind.available)
    func clearingRemovesTheMarks(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let all = [F.raw.contentKey, F.jpeg.contentKey, F.other.contentKey]
        try await s.store.setMark(.keep, rating: 2, for: all, at: F.t0)
        try await s.store.clearMarks(of: [F.raw.contentKey, F.jpeg.contentKey])
        #expect(try await s.store.marks(of: all).keys.map(\.self) == [F.other.contentKey])
        // No decision and no stars is a clear too, as an unmarked mark is in the cull session.
        try await s.store.setMark(nil, rating: 0, for: [F.other.contentKey], at: F.t1)
        #expect(try await s.store.marks(of: all).isEmpty)
        // Nothing to clear: nothing happens.
        try await s.store.clearMarks(of: [F.raw.contentKey])
        try await s.store.clearMarks(of: [])
        try await s.store.setMark(nil, rating: 0, for: [F.raw.contentKey], at: F.t1)
        #expect(try await s.store.marks(of: all).isEmpty)
    }

    @Test(arguments: StoreKind.available)
    func marksNeverTouchFileRows(_ kind: StoreKind) async throws {
        let imported = CatalogueRecord(identity: F.raw, format: .raw, state: .imported,
                                       location: .photosAsset(localIdentifier: "A/L0/001"))
        let s = try await kind.make(records: [imported])
        try await s.store.markStaged(F.raw, format: .raw, at: F.staged)
        var expected = imported
        expected.staged = F.staged
        try await s.store.setMark(.reject, rating: 1, for: [F.raw.contentKey], at: F.t0)
        try await s.store.clearMarks(of: [F.raw.contentKey])
        try await s.store.setMark(.keep, rating: 0, for: [F.raw.contentKey], at: F.t1)
        #expect(try await s.rows() == [expected])
    }

    @Test(arguments: StoreKind.available)
    func aMarkWithoutADateIsStampedNow(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let before = Date()
        try await s.store.setMark(.keep, for: [F.raw.contentKey])
        let after = Date()
        let mark = try #require(try await s.store.marks(of: [F.raw.contentKey])[F.raw.contentKey])
        #expect(mark.decision == .keep)
        #expect(mark.rating == 0)
        #expect(mark.markedAt >= before && mark.markedAt <= after)
    }
}

@Suite("Catalogue store contract: job records")
struct JobRecordContractTests {
    typealias C = CatalogueContractTests
    typealias F = V4Fixtures

    @Test(arguments: StoreKind.available)
    func everyFieldRoundTrips(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.recordJob(F.fullJob)
        #expect(try await s.store.job(F.jobA) == F.fullJob)
        #expect(try await s.store.jobs(camera: C.camera) == [F.fullJob])
        #expect(try await s.store.jobs(camera: nil) == [F.fullJob])
        #expect(try await s.store.job(F.jobB) == nil)
    }

    /// The selection's parameters (I10 re-queues a *Resumable* job from them) and each outcome round-trip.
    @Test(arguments: StoreKind.available)
    func everySelectionAndOutcomeRoundTrips(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let selections: [JobRecord.Selection] = [
            .allNew, .dateRange(F.t0 ... F.t2), .dateRange(F.t1 ... F.t1), .picked([F.raw.contentKey]), .picked([]),
            .pickedNew([F.raw.contentKey, F.jpeg.contentKey]),
        ]
        let outcomes: [JobRecord.Outcome?] = [nil, .completed, .cancelled, .catalogueUnavailable,
                                              .stopped(reason: "storageFull"), .stopped(reason: "")]
        var written: [JobRecord] = []
        for (i, selection) in selections.enumerated() {
            for (j, outcome) in outcomes.enumerated() {
                let job = JobRecord(id: UUID(), camera: C.camera, selection: selection,
                                    startedAt: F.t0.addingTimeInterval(Double(i * 10 + j)), outcome: outcome)
                try await s.store.recordJob(job)
                written.append(job)
            }
        }
        for job in written {
            #expect(try await s.store.job(job.id) == job)
        }
    }

    @Test(arguments: StoreKind.available)
    func aSecondRecordReplacesTheFirst(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.recordJob(F.fullJob)
        let replaced = JobRecord(id: F.jobA, camera: C.camera, startedAt: F.t2)
        try await s.store.recordJob(replaced)
        #expect(try await s.store.jobs(camera: nil) == [replaced])
    }

    @Test(arguments: StoreKind.available)
    func jobsAreListedPerCameraAndOverallNewestFirst(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let oldest = JobRecord(id: F.jobB, camera: C.camera, startedAt: F.t0)
        let newest = JobRecord(id: F.jobA, camera: C.otherCamera, purpose: .keepers, carrier: .staging,
                               startedAt: F.t2)
        // Two started in the same second: the identifier orders them.
        let tieA = JobRecord(id: F.jobA, camera: C.camera, startedAt: F.t1)
        let tieC = JobRecord(id: F.jobC, camera: C.camera, startedAt: F.t1)
        for job in [oldest, tieC, newest] {
            try await s.store.recordJob(job)
        }
        #expect(try await s.store.jobs(camera: nil) == [newest, tieC, oldest])
        #expect(try await s.store.jobs(camera: C.camera) == [tieC, oldest])
        #expect(try await s.store.jobs(camera: C.otherCamera) == [newest])
        #expect(try await s.store.jobs(camera: C.mscCamera).isEmpty)
        let s2 = try await kind.make()
        try await s2.store.recordJob(tieC)
        try await s2.store.recordJob(tieA)
        #expect(try await s2.store.jobs(camera: nil) == [tieA, tieC])
    }

    @Test(arguments: StoreKind.available)
    func updateJobChangesTheStoredJobInOneCall(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let started = JobRecord(id: F.jobA, camera: C.camera, destination: .photos, carrier: .usb, startedAt: F.t0,
                                filesTotal: 3, bytesTotal: 30)
        try await s.store.recordJob(started)
        let stored = try await s.store.updateJob(F.jobA) { job in
            job.id = F.jobB   // can't move the record
            job.finishedAt = F.t1
            job.outcome = .completed
            job.filesImported = 3
            job.bytesDone = 30
        }
        var expected = started
        expected.finishedAt = F.t1
        expected.outcome = .completed
        expected.filesImported = 3
        expected.bytesDone = 30
        #expect(stored == expected)
        #expect(try await s.store.jobs(camera: nil) == [expected])
        // No such job: nothing is written.
        #expect(try await s.store.updateJob(F.jobC) { $0.filesFailed = 1 } == nil)
        #expect(try await s.store.job(F.jobC) == nil)
    }

    @Test(arguments: StoreKind.available)
    func concurrentUpdatesOfDifferentFieldsAreAllKept(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.recordJob(JobRecord(id: F.jobA, camera: C.camera, startedAt: F.t0))
        let store = s.store
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 20 {
                group.addTask {
                    _ = try? await store.updateJob(F.jobA) { job in
                        if i.isMultiple(of: 2) { job.filesImported += 1 } else { job.filesSkipped += 1 }
                    }
                }
            }
        }
        let job = try #require(try await s.store.job(F.jobA))
        #expect(job.filesImported == 10)
        #expect(job.filesSkipped == 10)
    }

    @Test(arguments: StoreKind.available)
    func aJobGivesItsCameraARowAndLeavesItsFieldsAlone(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.recordJob(JobRecord(id: F.jobA, camera: C.otherCamera, startedAt: F.t0))
        #expect(try await s.store.camera(C.otherCamera) == CameraRecord(key: C.otherCamera))
        try await s.store.upsertCamera(CameraFixtures.full)
        try await s.store.recordJob(JobRecord(id: F.jobB, camera: CameraFixtures.key, startedAt: F.t1))
        #expect(try await s.store.camera(CameraFixtures.key) == CameraFixtures.full)
        #expect(try await s.rows().isEmpty)
    }
}

@Suite("Catalogue store contract: staged records and Forget imports")
struct ForgetImportsContractTests {
    typealias C = CatalogueContractTests
    typealias F = V4Fixtures

    @Test(arguments: StoreKind.available)
    func stagedRecordsListOnlyStagedRowsInCaptureOrder(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let late = C.id("DSC00009.ARW", "20261102T090000", 9)
        let early = C.id("DSC00005.ARW", "20261101T080000", 5)
        let elsewhere = C.id("DSC00007.ARW", "20261101T120000", 7, camera: C.otherCamera)
        let notStaged = C.id("DSC00006.ARW", "20261101T100000", 6)
        let unknownPath = StagedLocation(root: .onThisIPhone, relativePath: "")
        try await s.store.markStaged(late, format: .raw, at: F.staged)
        try await s.store.upsert(CatalogueRecord(identity: early, format: .raw, state: .imported,
                                                 location: .photosAsset(localIdentifier: "A/L0/005")))
        try await s.store.markStaged(early, format: .raw, at: unknownPath)
        try await s.store.markStaged(elsewhere, format: .raw, at: F.staged)
        try await s.store.upsert(CatalogueRecord(identity: notStaged, format: .raw, state: .imported))

        let all = try await s.store.stagedRecords(camera: nil)
        #expect(all.map(\.identity) == [early, elsewhere, late])
        #expect(all.first?.state == .imported)
        #expect(all.first?.staged == unknownPath)
        #expect(try await s.store.stagedRecords(camera: C.camera).map(\.identity) == [early, late])
        #expect(try await s.store.stagedRecords(camera: C.mscCamera).isEmpty)
        let days = StagedDays.grouped(all)
        #expect(days.map(\.day) == ["2026-11-01", "2026-11-02"])
        #expect(days.map { $0.records.map(\.identity) } == [[early, elsewhere], [late]])
        // Cleared: no longer listed.
        try await s.store.clearStaged(late)
        #expect(try await s.store.stagedRecords(camera: C.camera).map(\.identity) == [early])
    }

    /// D6 and the backlog's test (section 4, I7): one imported-and-staged file (back to new, still staged, still on the
    /// cull screen) and one imported file with no staged location (deleted).
    @Test(arguments: StoreKind.available)
    func forgettingACameraDeletesImportsAndReturnsStagedOnesToNew(_ kind: StoreKind) async throws {
        let importedAndStaged = CatalogueRecord(identity: F.raw, format: .raw, state: .imported,
                                                location: .photosAsset(localIdentifier: "A/L0/001"))
        let importedOnly = CatalogueRecord(identity: F.other, format: .raw, state: .imported,
                                           location: .photosAsset(localIdentifier: "A/L0/002"))
        let toFiles = CatalogueRecord(identity: C.id("DSC00003.HIF", "20261101T143007", 3), format: .heif,
                                      state: .imported, location: .file(relativePath: "ILCE-7CM2/DSC00003.HIF"))
        let skipped = CatalogueRecord(identity: C.id("DSC00004.JPG", "20261101T143008", 4), format: .jpeg,
                                      state: .skipped)
        let skippedAndStaged = CatalogueRecord(identity: C.id("DSC00005.JPG", "20261101T143009", 5), format: .jpeg,
                                               state: .skipped)
        let partial = CatalogueRecord(identity: C.id("DSC00006.ARW", "20261101T143010", 60), format: .raw,
                                      state: .partial, resumeOffset: 16, tempURL: CameraFixtures.partialFile("X"))
        let new = CatalogueRecord(identity: C.id("DSC00007.ARW", "20261101T143011", 7), format: .raw, state: .new)
        // The same content as `importedOnly`, imported under another key: it stays, and the file stays imported.
        let underOtherKey = CatalogueRecord(identity: C.id("DSC00002.ARW", "20261101T143006", 44_000_001,
                                                           camera: C.otherCamera),
                                            format: .raw, state: .imported,
                                            location: .photosAsset(localIdentifier: "A/L0/002"))
        let s = try await kind.make(records: [importedAndStaged, importedOnly, toFiles, skipped, skippedAndStaged,
                                              partial, new, underOtherKey])
        let stagedJPG = StagedLocation(root: .onThisIPhone, relativePath: "Staging/ILCE-7CM2/2026-11-01/DSC00005.JPG")
        try await s.store.markStaged(F.raw, format: .raw, at: F.staged)
        try await s.store.markStaged(skippedAndStaged.identity, format: .jpeg, at: stagedJPG)
        try await s.store.setMark(.keep, rating: 4, for: [F.raw.contentKey, F.other.contentKey], at: F.t0)
        try await s.store.recordJob(F.fullJob)
        let listing = CardListing(camera: C.camera, listedAt: F.t0, entries: [.init(identity: F.raw, format: .raw)])
        try await s.store.saveListing(listing)

        #expect(try await s.store.forgetImports(camera: C.camera) == 5)

        let forgottenRaw = CatalogueRecord(identity: F.raw, format: .raw, state: .new, staged: F.staged)
        let forgottenJPG = CatalogueRecord(identity: skippedAndStaged.identity, format: .jpeg, state: .new,
                                           staged: stagedJPG)
        #expect(Set(try await s.rows()) == [forgottenRaw, forgottenJPG, partial, new, underOtherKey])
        #expect(try await s.store.stagedRecords(camera: C.camera) == [forgottenRaw, forgottenJPG])
        #expect(try await s.store.states(of: [F.raw, F.other, toFiles.identity, skipped.identity])
            == [F.raw: .new, F.other: .imported, toFiles.identity: .new, skipped.identity: .new])
        // Marks, job records, the listing and the camera row are left alone.
        #expect(try await s.store.marks(of: [F.raw.contentKey, F.other.contentKey]).count == 2)
        #expect(try await s.store.jobs(camera: C.camera) == [F.fullJob])
        #expect(try await s.store.lastListing(for: C.camera) == listing)
        #expect(try await s.store.camera(C.camera) != nil)
        // Again: nothing left to forget.
        #expect(try await s.store.forgetImports(camera: C.camera) == 0)
        #expect(try await s.store.forgetImports(camera: C.mscCamera) == 0)
    }

    @Test(arguments: StoreKind.available)
    func forgettingACameraRemovesItsPendingCommitsOnly(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.beginCommit(F.pairCommit)
        let elsewhere = PendingCommit(id: F.commit2, destination: .photos,
                                      files: [.init(identity: C.id("DSC00009.ARW", "20261101T143010", 9,
                                                                   camera: C.otherCamera),
                                                    format: .raw, role: .single)],
                                      writtenAt: F.t2)
        try await s.store.beginCommit(elsewhere)
        try await s.store.forgetImports(camera: C.camera)
        #expect(try await s.store.pendingCommits() == [elsewhere])
    }
}

@Suite("Catalogue store contract: pending commits")
struct PendingCommitContractTests {
    typealias C = CatalogueContractTests
    typealias F = V4Fixtures

    @Test(arguments: StoreKind.available)
    func aPairRoundTripsAsOneCommit(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.beginCommit(F.pairCommit)
        #expect(try await s.store.pendingCommits() == [F.pairCommit])
        // A marker is not a file row.
        #expect(try await s.rows().isEmpty)
        #expect(try await s.store.states(of: [F.raw]) == [F.raw: .new])
    }

    @Test(arguments: StoreKind.available)
    func beginThenFinishLeavesTheRowsAndNoMarker(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.beginCommit(F.pairCommit)
        let rawRow = CatalogueRecord(identity: F.raw, format: .raw, state: .imported,
                                     location: .photosAsset(localIdentifier: "P/L0/001"))
        let jpegRow = CatalogueRecord(identity: F.jpeg, format: .jpeg, state: .imported,
                                      location: .photosAsset(localIdentifier: "P/L0/001"))
        try await s.store.finishCommit(F.commit1, writing: [.imported(rawRow), .imported(jpegRow)])
        #expect(try await s.store.pendingCommits().isEmpty)
        #expect(Set(try await s.rows()) == [rawRow, jpegRow])
    }

    @Test(arguments: StoreKind.available)
    func beginThenAbandonLeavesNeither(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.beginCommit(F.pairCommit)
        try await s.store.abandonCommit(F.commit1)
        #expect(try await s.store.pendingCommits().isEmpty)
        #expect(try await s.rows().isEmpty)
        // No such marker: nothing happens.
        try await s.store.abandonCommit(F.commit1)
        try await s.store.abandonCommit(F.commit2)
    }

    /// The engine's switch from Photos to Staging (3311) rewrites the marker under the same id.
    @Test(arguments: StoreKind.available)
    func aReplaceKeepsOneCommit(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.beginCommit(F.pairCommit)
        var restaged = F.pairCommit
        restaged.destination = .staging(root: .onThisIPhone, folder: "Staging/ILCE-7CM2/2026-11-01")
        restaged.writtenAt = F.t2
        try await s.store.beginCommit(restaged)
        #expect(try await s.store.pendingCommits() == [restaged])
        // Down to one file under the same id.
        var single = restaged
        single.files = [restaged.files[0]]
        try await s.store.beginCommit(single)
        #expect(try await s.store.pendingCommits() == [single])
    }

    @Test(arguments: StoreKind.available)
    func aStageCommitWritesTheStagedFactAsMarkStagedDoes(_ kind: StoreKind) async throws {
        let imported = CatalogueRecord(identity: F.raw, format: .raw, state: .imported,
                                       location: .photosAsset(localIdentifier: "A/L0/001"))
        let partialFile = CameraFixtures.partialFile("DSC00002")
        let s = try await kind.make(records: [imported])
        try await s.store.markPartial(F.other, format: .raw, tempURL: partialFile, offset: 4096)
        let commit = PendingCommit(id: F.commit2, destination: .staging(root: .iCloudDrive,
                                                                        folder: "Staging/ILCE-7CM2/2026-11-01"),
                                   files: [.init(identity: F.raw, format: .raw, role: .single, assetDate: F.t0)],
                                   writtenAt: F.t1)
        try await s.store.beginCommit(commit)
        let otherStaged = StagedLocation(root: .iCloudDrive,
                                         relativePath: "Staging/ILCE-7CM2/2026-11-01/DSC00002 (2).ARW", stagedAt: F.t1)
        try await s.store.finishCommit(F.commit2, writing: [.staged(F.raw, format: .raw, at: F.staged),
                                                           .staged(F.other, format: .raw, at: otherStaged)])
        var importedStaged = imported
        importedStaged.staged = F.staged
        #expect(try await s.store.record(for: F.raw) == importedStaged, "an imported file stays imported")
        #expect(try await s.store.record(for: F.other)
            == CatalogueRecord(identity: F.other, format: .raw, state: .new, staged: otherStaged),
            "a partial row goes back to new")
        #expect(try await s.store.pendingCommits().isEmpty)
    }

    @Test(arguments: StoreKind.available)
    func anImportedWriteKeepsTheStagedCopy(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.markStaged(F.raw, format: .raw, at: F.staged)
        try await s.store.beginCommit(F.pairCommit)
        let row = CatalogueRecord(identity: F.raw, format: .raw, state: .imported,
                                  location: .photosAsset(localIdentifier: "P/L0/001"))
        try await s.store.finishCommit(F.commit1, writing: [.imported(row)])
        var expected = row
        expected.staged = F.staged
        #expect(try await s.store.record(for: F.raw) == expected)
    }

    @Test(arguments: StoreKind.available)
    func finishingWithNoMarkerWritesTheRowsAlone(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.beginCommit(F.pairCommit)
        let row = CatalogueRecord(identity: F.other, format: .raw, state: .imported,
                                  location: .photosAsset(localIdentifier: "P/L0/002"))
        try await s.store.finishCommit(F.commit3, writing: [.imported(row)])
        #expect(try await s.rows() == [row])
        #expect(try await s.store.pendingCommits() == [F.pairCommit], "another commit's marker is left alone")
        // No writes and no marker: nothing at all.
        try await s.store.finishCommit(F.commit3, writing: [])
        #expect(try await s.rows() == [row])
    }

    @Test(arguments: StoreKind.available)
    func commitsComeOldestFirst(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        func commit(_ id: UUID, _ at: Date, _ name: String) -> PendingCommit {
            PendingCommit(id: id, destination: .photos,
                          files: [.init(identity: C.id(name, "20261101T143005", 1), format: .jpeg, role: .single)],
                          writtenAt: at)
        }
        let newest = commit(F.commit1, F.t2, "A.JPG")
        let oldest = commit(F.jobA, F.t0, "B.JPG")
        // Two written at the same moment: the identifier orders them ("…D2" before "…D3").
        let tieFirst = commit(F.commit2, F.t1, "C.JPG")
        let tieSecond = commit(F.commit3, F.t1, "D.JPG")
        for c in [newest, tieSecond, oldest, tieFirst] {
            try await s.store.beginCommit(c)
        }
        #expect(try await s.store.pendingCommits() == [oldest, tieFirst, tieSecond, newest])
    }

    @Test(arguments: StoreKind.available)
    func aCommitWithNoFilesIsRefused(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        var empty = F.pairCommit
        empty.files = []
        await #expect(throws: CatalogueFailure.emptyCommit) {
            try await s.store.beginCommit(empty)
        }
        #expect(try await s.store.pendingCommits().isEmpty)
    }
}
