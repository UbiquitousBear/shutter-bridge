import Foundation
import PTPKit
import Testing
@testable import Catalogue

// Catalogue V4's storage mapping in plain values: what the SwiftData models copy, tested on Linux too.

@Suite("Content keys as stored")
struct ContentKeyStorageTests {
    typealias C = CatalogueContractTests

    @Test func aContentKeyRoundTripsThroughCodableAndDecodesFolded() throws {
        let key = C.id("DSC00001.ARW", "20261101T143005", 44_000_000).contentKey
        let data = try JSONEncoder().encode(key)
        #expect(try JSONDecoder().decode(ObjectIdentity.ContentKey.self, from: data) == key)
        let lowerCase = Data(#"{"filename":"dsc00001.arw","captureDate":"20261101T143005","size":44000000}"#.utf8)
        #expect(try JSONDecoder().decode(ObjectIdentity.ContentKey.self, from: lowerCase) == key)
        let badDate = Data(#"{"filename":"A","captureDate":"2026","size":1}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ObjectIdentity.ContentKey.self, from: badDate)
        }
    }

    @Test func storageKeysAreOnePerContentKey() {
        let a = C.id("DSC00001.ARW", "20261101T143005", 1)
        #expect(a.contentKey.storageKey == C.id("dsc00001.arw", "20261101T143005", 1, folder: "",
                                               camera: C.otherCamera).contentKey.storageKey)
        #expect(a.contentKey.storageKey != C.id("DSC00001.ARW", "20261101T143005", 2).contentKey.storageKey)
        #expect(a.contentKey.storageKey != C.id("DSC00001.ARW", "20261101T143006", 1).contentKey.storageKey)
        // Length-prefixed, so a name can't run into the next component.
        #expect(C.id("A|1", "20261101T143005", 1).contentKey.storageKey
            != C.id("A", "20261101T143005", 11).contentKey.storageKey)
    }

    @Test func aBlobThisVersionCantReadIsNoKeys() {
        let keys = [C.id("A.ARW", "20261101T143005", 1).contentKey, C.id("B.ARW", "20261101T143006", 2).contentKey]
        #expect(StoredContentKeys.decode(StoredContentKeys.encode(keys)) == keys)
        #expect(StoredContentKeys.decode(StoredContentKeys.encode([])) == [])
        #expect(StoredContentKeys.decode(Data("junk".utf8)) == [])
        #expect(StoredContentKeys.decode(Data(#"{"version":2,"keys":[]}"#.utf8)) == [])
    }
}

@Suite("Cull mark columns")
struct CullMarkColumnTests {
    typealias C = CatalogueContractTests

    let key = C.id("dsc00001.arw", "20261101T143005", 44_000_000).contentKey
    let at = Date(timeIntervalSinceReferenceDate: 815_000_000.25)

    @Test func everyMarkRoundTrips() {
        for decision in [MarkRecord.Decision.keep, .reject, nil] {
            for rating in [0, 3, 5] {
                let mark = MarkRecord(decision: decision, rating: rating, markedAt: at)
                let columns = CullMarkColumns(mark, for: key)
                #expect(columns.markRecord == mark)
                #expect(columns.filename == "DSC00001.ARW", "the folded name")
                #expect(columns.captureDate == "20261101T143005")
                #expect(columns.size == 44_000_000)
                #expect(columns.contentKey == key.storageKey)
            }
        }
        #expect(CullMarkColumns(MarkRecord(decision: .keep, markedAt: at), for: key).mark == "keep")
        #expect(CullMarkColumns(MarkRecord(decision: .reject, markedAt: at), for: key).mark == "reject")
    }

    @Test func whatThisBuildCantReadReadsAsNothing() {
        var columns = CullMarkColumns(MarkRecord(decision: .keep, rating: 2, markedAt: at), for: key)
        columns.mark = "maybe"
        columns.rating = 9
        columns.markedAt = nil
        #expect(columns.markRecord == MarkRecord(decision: nil, rating: 0, markedAt: .distantPast))
        columns.rating = nil
        #expect(columns.markRecord.rating == 0)
    }

    @Test func theRuleRefusesARatingOutOfRangeAndTreatsNothingAsAClear() throws {
        #expect(throws: CatalogueFailure.ratingOutOfRange(6)) { try MarkRule.mark(.keep, rating: 6, at: at) }
        #expect(throws: CatalogueFailure.ratingOutOfRange(-1)) { try MarkRule.mark(nil, rating: -1, at: at) }
        #expect(try MarkRule.mark(nil, rating: 0, at: at) == nil)
        #expect(try MarkRule.mark(nil, rating: 1, at: at) == MarkRecord(decision: nil, rating: 1, markedAt: at))
        #expect(try MarkRule.mark(.reject, rating: 0, at: at) == MarkRecord(decision: .reject, markedAt: at))
    }

    @Test func amongDuplicatesTheLatestThenARejectThenMoreStarsAnswers() {
        let early = MarkRecord(decision: .reject, markedAt: at)
        let late = MarkRecord(decision: .keep, markedAt: at.addingTimeInterval(1))
        #expect(MarkRule.preferred(late, over: early))
        #expect(!MarkRule.preferred(early, over: late))
        let keep = MarkRecord(decision: .keep, markedAt: at)
        #expect(MarkRule.preferred(early, over: keep))
        #expect(!MarkRule.preferred(keep, over: early))
        let starred = MarkRecord(decision: .keep, rating: 3, markedAt: at)
        #expect(MarkRule.preferred(starred, over: keep))
        #expect(!MarkRule.preferred(keep, over: starred))
    }

    @Test func theDecisionsMatchTheCullSessions() {
        // AppUI's `CullDecision` has the same raw values; the adapter maps by them.
        #expect(MarkRecord.Decision.allCases.map(\.rawValue) == ["keep", "reject"])
        #expect(MarkRecord.ratings == 0 ... 5)
    }
}

@Suite("Job columns")
struct JobColumnTests {
    typealias F = V4Fixtures

    @Test func aFullJobRoundTrips() {
        let columns = JobColumns(F.fullJob)
        #expect(columns.record(cameraKey: "ignored") == F.fullJob)
        #expect(columns.selection == "picked")
        #expect(columns.outcome == "stopped:storageFull")
        #expect(columns.purpose == "stage")
        #expect(columns.destination == "staging")
        #expect(columns.carrier == "wifi")
        #expect(columns.cameraKey == CatalogueContractTests.camera.rawValue)
    }

    @Test func selectionsAreStoredInVersion1sWordsAndBounds() {
        func columns(_ selection: JobRecord.Selection) -> JobColumns {
            JobColumns(JobRecord(id: F.jobA, camera: CatalogueContractTests.camera, selection: selection,
                                 startedAt: F.t0))
        }
        #expect(columns(.allNew).selection == "all-new")
        let range = columns(.dateRange(F.t0 ... F.t1))
        #expect(range.selection == "range")
        #expect(range.rangeStart == F.t0)
        #expect(range.rangeEnd == F.t1)
        #expect(columns(.picked([])).selection == "picked")
        #expect(columns(.pickedNew([F.raw.contentKey])).selection == "picked-new")
        #expect(columns(.allNew).pickedKeys == nil)
        #expect(columns(.allNew).failedKeys == nil)
    }

    /// A job row as versions 1 to 3 left it (none written by the app, but the schema had the model): an import of
    /// every new file, with no counts, under its camera relationship's key.
    @Test func aRowFromBeforeVersion4ReadsAsAnImportWithNoCounts() {
        let old = JobColumns(jobID: F.jobA, startedAt: F.t0, finishedAt: nil, selection: "", bytesTotal: 10,
                             bytesDone: 5, outcome: nil)
        #expect(old.record(cameraKey: "relationship-key")
            == JobRecord(id: F.jobA, camera: CameraKey(rawValue: "relationship-key"), startedAt: F.t0,
                         bytesTotal: 10, bytesDone: 5))
        var picked = old
        picked.selection = "picked"
        #expect(picked.record(cameraKey: "k").selection == .picked([]))
    }

    @Test func whatThisBuildCantReadFallsBack() {
        var columns = JobColumns(F.fullJob)
        columns.purpose = "later"
        columns.destination = "later"
        columns.carrier = "later"
        columns.selection = "later"
        columns.outcome = "later"
        columns.failedKeys = Data("junk".utf8)
        let job = columns.record(cameraKey: "k")
        #expect(job.purpose == .import)
        #expect(job.destination == nil)
        #expect(job.carrier == nil)
        #expect(job.selection == .allNew)
        #expect(job.outcome == .stopped(reason: "later"))
        #expect(job.failedFiles.isEmpty)
        // A range missing a bound, or reversed.
        columns.selection = "range"
        columns.rangeStart = F.t1
        columns.rangeEnd = nil
        #expect(columns.record(cameraKey: "k").selection == .allNew)
        columns.rangeEnd = F.t0
        #expect(columns.record(cameraKey: "k").selection == .allNew)
    }
}

@Suite("Pending commit columns")
struct PendingCommitColumnTests {
    typealias C = CatalogueContractTests
    typealias F = V4Fixtures

    @Test func aCommitIsOneRowPerFileAndReadsBack() {
        let rows = PendingCommitColumns.rows(of: F.pairCommit)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.commitID == F.commit1 && $0.jobID == F.jobA && $0.writtenAt == F.t1 })
        #expect(rows.map(\.role) == ["raw", "processed"])
        #expect(rows.allSatisfy { $0.destination == "photos" && $0.stagingRoot == nil && $0.stagingFolder == nil })
        #expect(rows[0].identityKey == F.raw.storageKey)
        #expect(rows[0].cameraKey == C.camera.rawValue)
        #expect(PendingCommitColumns.commits(from: rows) == [F.pairCommit])
        // Read in any order, the RAW comes first.
        #expect(PendingCommitColumns.commits(from: rows.reversed()) == [F.pairCommit])
    }

    @Test func aStagingCommitKeepsItsRootAndFolder() {
        var commit = F.pairCommit
        commit.destination = .staging(root: .iCloudDrive, folder: "Staging/ILCE-7CM2/2026-11-01")
        let rows = PendingCommitColumns.rows(of: commit)
        #expect(rows.allSatisfy {
            $0.destination == "staging" && $0.stagingRoot == "iCloudDrive"
                && $0.stagingFolder == "Staging/ILCE-7CM2/2026-11-01"
        })
        #expect(PendingCommitColumns.commits(from: rows) == [commit])
    }

    @Test func whatThisBuildCantReadIsLeftOutNotGuessed() {
        var unknownDestination = PendingCommitColumns.rows(of: F.pairCommit)
        for i in unknownDestination.indices {
            unknownDestination[i].destination = "later"
        }
        #expect(PendingCommitColumns.commits(from: unknownDestination).isEmpty)

        var commit = F.pairCommit
        commit.destination = .staging(root: .iCloudDrive, folder: "Staging/a/b")
        var unknownRoot = PendingCommitColumns.rows(of: commit)
        for i in unknownRoot.indices {
            unknownRoot[i].stagingRoot = "later"
        }
        #expect(PendingCommitColumns.commits(from: unknownRoot).isEmpty)

        var noCommit = PendingCommitColumns.rows(of: F.pairCommit)
        noCommit[0].commitID = nil
        noCommit[1].commitID = nil
        #expect(PendingCommitColumns.commits(from: noCommit).isEmpty)

        // A file whose date isn't one: the commit stays, with its other file, so it can still be resolved by its id.
        var badDate = PendingCommitColumns.rows(of: F.pairCommit)
        badDate[1].captureDate = "junk"
        var expected = F.pairCommit
        expected.files = [F.pairCommit.files[0]]
        #expect(PendingCommitColumns.commits(from: badDate) == [expected])

        // An unknown role or format reads as a single file of another format.
        var unknownRole = PendingCommitColumns.rows(of: F.pairCommit)
        unknownRole[0].role = "later"
        unknownRole[0].format = "later"
        let read = PendingCommitColumns.commits(from: unknownRole)
        #expect(read.first?.files.first?.role == .single)
        #expect(read.first?.files.first?.format == .other)
    }
}

@Suite("Forget imports and staged days, the rules")
struct ForgetRuleTests {
    typealias C = CatalogueContractTests
    typealias F = V4Fixtures

    @Test func eachStateAndStagedCopy() {
        func change(_ state: ObjectState, staged: StagedLocation?) -> ForgetRule.Change {
            ForgetRule.change(for: CatalogueRow(CatalogueRecord(identity: F.raw, format: .raw, state: state,
                                                                location: .photosAsset(localIdentifier: "A"),
                                                                staged: staged)))
        }
        #expect(change(.imported, staged: nil) == .delete)
        #expect(change(.skipped, staged: nil) == .delete)
        #expect(change(.new, staged: nil) == .keep)
        #expect(change(.partial, staged: F.staged) == .keep)
        let back = CatalogueRow(CatalogueRecord(identity: F.raw, format: .raw, state: .new, staged: F.staged))
        #expect(change(.imported, staged: F.staged) == .rewrite(back))
        #expect(change(.skipped, staged: F.staged) == .rewrite(back))
        // A copy under a root a later version adds is still a copy to keep.
        var laterRoot = CatalogueRow(CatalogueRecord(identity: F.raw, format: .raw, state: .imported))
        laterRoot.stagedRelativePath = "Staging/a/b/c.ARW"
        laterRoot.stagedRoot = "later"
        guard case let .rewrite(row) = ForgetRule.change(for: laterRoot) else {
            Issue.record("expected the row to be kept")
            return
        }
        #expect(row.state == "new")
        #expect(row.stagedRoot == "later")
    }

    @Test func daysAreTheCameraWallClockDays() {
        #expect(StagedDays.day(of: CaptureDate(rawValue: "20261101T235959")!) == "2026-11-01")
        let a = CatalogueRecord(identity: C.id("B.ARW", "20261101T235959", 1), format: .raw, state: .new)
        let b = CatalogueRecord(identity: C.id("A.ARW", "20261102T000000", 1), format: .raw, state: .new)
        let c = CatalogueRecord(identity: C.id("A.ARW", "20261101T235959", 1), format: .raw, state: .new)
        #expect(StagedDays.grouped([b, a, c])
            == [StagedDay(day: "2026-11-01", records: [c, a]), StagedDay(day: "2026-11-02", records: [b])])
        #expect(StagedDays.grouped([]).isEmpty)
    }
}
