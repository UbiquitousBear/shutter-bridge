import Foundation
import PTPKit
import Testing
@testable import Catalogue

/// The staging rules every catalogue store keeps (Shamil, 11 Nov): being staged is a fact of its own beside the
/// state, written by `markStaged` and `clearStaged` only, and matched by content. Run against the in-memory store
/// everywhere and the SwiftData store where SwiftData exists (CI's iOS Simulator run).
@Suite("Catalogue store contract: staging")
struct StagingContractTests {
    typealias C = CatalogueContractTests

    let first = C.id("DSC00001.ARW", "20261101T143005", 44_000_000)
    let iCloud = StagedLocation(root: .iCloudDrive, relativePath: "Staging/ILCE-7CM2/2026-11-01/DSC00001.ARW",
                                stagedAt: Date(timeIntervalSinceReferenceDate: 815_000_100.25))
    let local = StagedLocation(root: .onThisIPhone, relativePath: "Staging/ILCE-7CM2/2026-11-01/DSC00001 (2).ARW",
                               stagedAt: Date(timeIntervalSinceReferenceDate: 815_000_200.5))

    @Test(arguments: StoreKind.available)
    func stagingAnUnknownFileAddsANewRowThatReadsStaged(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.markStaged(first, format: .raw, at: iCloud)
        let expected = CatalogueRecord(identity: first, format: .raw, state: .new, staged: iCloud)
        #expect(try await s.rows() == [expected])
        #expect(try await s.store.record(for: first) == expected)
        #expect(try await s.store.states(of: [first]) == [first: .new], "staged is not imported")
        #expect(try await s.store.stagedStates(of: [first]) == [first])
    }

    @Test(arguments: StoreKind.available)
    func stagingAnImportedFileKeepsItImportedWithItsLocation(_ kind: StoreKind) async throws {
        let imported = CatalogueRecord(identity: first, format: .raw, state: .imported,
                                       location: .photosAsset(localIdentifier: "A/L0/001"))
        let s = try await kind.make(records: [imported])
        try await s.store.markStaged(first, format: .raw, at: iCloud)
        var expected = imported
        expected.staged = iCloud
        #expect(try await s.store.record(for: first) == expected)
        #expect(try await s.store.states(of: [first]) == [first: .imported], "never downgraded")
        #expect(try await s.store.stagedStates(of: [first]) == [first])
        // A file imported to Files by an earlier build keeps that location too.
        let toFiles = C.id("DSC00002.ARW", "20261101T143006", 44_000_001)
        let filesRow = CatalogueRecord(identity: toFiles, format: .raw, state: .imported,
                                       location: .file(relativePath: "ILCE-7CM2/DSC00002.ARW"))
        try await s.store.upsert(filesRow)
        try await s.store.markStaged(toFiles, format: .raw, at: local)
        #expect(try await s.store.record(for: toFiles)?.location == .file(relativePath: "ILCE-7CM2/DSC00002.ARW"))
        #expect(try await s.store.record(for: toFiles)?.state == .imported)
    }

    @Test(arguments: StoreKind.available)
    func stagingAPartialFileMakesItNewAndClearsTheResume(_ kind: StoreKind) async throws {
        // A Wi-Fi download checkpointed, then committed into Staging: the partial file was the commit's.
        let s = try await kind.make()
        let url = CameraFixtures.partialFile("DSC00001")
        try await s.store.markPartial(first, format: .raw, tempURL: url, offset: 16_777_216)
        try await s.store.markStaged(first, format: .raw, at: iCloud)
        #expect(try await s.store.record(for: first)
            == CatalogueRecord(identity: first, format: .raw, state: .new, staged: iCloud))
        #expect(try await s.store.states(of: [first]) == [first: .new])
    }

    @Test(arguments: StoreKind.available)
    func stagingKeepsSkippedAndNewAsTheyAre(_ kind: StoreKind) async throws {
        let skipped = CatalogueRecord(identity: first, format: .raw, state: .skipped)
        let s = try await kind.make(records: [skipped])
        try await s.store.markStaged(first, format: .raw, at: local)
        #expect(try await s.store.record(for: first)
            == CatalogueRecord(identity: first, format: .raw, state: .skipped, staged: local))
    }

    @Test(arguments: StoreKind.available)
    func stagingAgainReplacesTheLocation(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.markStaged(first, format: .raw, at: iCloud)
        try await s.store.markStaged(first, format: .raw, at: local)
        #expect(try await s.rows() == [CatalogueRecord(identity: first, format: .raw, state: .new, staged: local)])
    }

    @Test(arguments: StoreKind.available)
    func anImportKeepsTheStagedCopy(_ kind: StoreKind) async throws {
        // The import commit (Import to Photos) writes upsert, which never forgets a staged copy.
        let s = try await kind.make()
        try await s.store.markStaged(first, format: .raw, at: iCloud)
        let imported = CatalogueRecord(identity: first, format: .raw, state: .imported,
                                       location: .photosAsset(localIdentifier: "A/L0/001"))
        try await s.store.upsert(imported)
        var expected = imported
        expected.staged = iCloud
        #expect(try await s.store.record(for: first) == expected)
        #expect(try await s.store.states(of: [first]) == [first: .imported])
        #expect(try await s.store.stagedStates(of: [first]) == [first])

        // A record that says otherwise doesn't change it either: only markStaged and clearStaged do.
        var other = imported
        other.staged = local
        try await s.store.upsert(other)
        #expect(try await s.store.record(for: first)?.staged == iCloud)
    }

    @Test(arguments: StoreKind.available)
    func anInsertTakesTheRecordsStagedCopy(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let record = CatalogueRecord(identity: first, format: .raw, state: .new, staged: local)
        try await s.store.upsert(record)
        #expect(try await s.store.record(for: first) == record)
    }

    @Test(arguments: StoreKind.available)
    func aCheckpointKeepsTheStagedCopy(_ kind: StoreKind) async throws {
        // Staged, then picked explicitly for Import to Photos over Wi-Fi: the checkpoint keeps the staged copy.
        let s = try await kind.make()
        try await s.store.markStaged(first, format: .raw, at: iCloud)
        let url = CameraFixtures.partialFile("DSC00001")
        try await s.store.markPartial(first, format: .raw, tempURL: url, offset: 4096)
        let record = try #require(try await s.store.record(for: first))
        #expect(record.state == .partial)
        #expect(record.resumeOffset == 4096)
        #expect(record.staged == iCloud)
    }

    @Test(arguments: StoreKind.available)
    func clearingForgetsOnlyTheStagedCopy(_ kind: StoreKind) async throws {
        let imported = CatalogueRecord(identity: first, format: .raw, state: .imported,
                                       location: .photosAsset(localIdentifier: "A/L0/001"))
        let s = try await kind.make(records: [imported])
        try await s.store.markStaged(first, format: .raw, at: iCloud)
        try await s.store.clearStaged(first)
        #expect(try await s.store.record(for: first) == imported)
        #expect(try await s.store.stagedStates(of: [first]).isEmpty)
        // No row, or no staged copy: nothing happens.
        let unknown = C.id("DSC09999.ARW", "20261101T150000", 1)
        try await s.store.clearStaged(unknown)
        try await s.store.clearStaged(first)
        #expect(try await s.rows() == [imported])
    }

    /// Shamil's rule of 8 Nov, applied to staging: a file staged in MSC reads as staged in MTP, from another folder,
    /// whatever the name's ASCII case; another second, size or name is another file.
    @Test(arguments: StoreKind.available)
    func stagedIsMatchedByContent(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let inMSC = C.id("DSC04512.ARW", "20261108T101530", 40_329_216, camera: C.mscCamera)
        try await s.store.markStaged(inMSC, format: .raw, at: iCloud)
        let inMTP = C.id("DSC04512.ARW", "20261108T101530", 40_329_216, folder: "", camera: C.mtpCamera)
        let lowerCase = C.id("dsc04512.arw", "20261108T101530", 40_329_216, folder: "DCIM/101MSDCF")
        let otherSecond = C.id("DSC04512.ARW", "20261108T101531", 40_329_216)
        let otherSize = C.id("DSC04512.ARW", "20261108T101530", 40_329_217)
        let otherName = C.id("DSC04513.ARW", "20261108T101530", 40_329_216)
        #expect(try await s.store.stagedStates(of: [inMSC, inMTP, lowerCase, otherSecond, otherSize, otherName])
            == [inMSC, inMTP, lowerCase])
        // The lookup by identity is still exact.
        #expect(try await s.store.record(for: inMTP) == nil)
        #expect(try await s.store.stagedStates(of: []) == [])
    }

    @Test(arguments: StoreKind.available)
    func importedAndStagedAreAnsweredApart(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let importedOnly = C.id("A.ARW", "20261101T143001", 1)
        let stagedOnly = C.id("B.ARW", "20261101T143002", 2)
        let both = C.id("C.ARW", "20261101T143003", 3)
        let neither = C.id("D.ARW", "20261101T143004", 4)
        try await s.store.upsert(CatalogueRecord(identity: importedOnly, format: .raw, state: .imported))
        try await s.store.markStaged(stagedOnly, format: .raw, at: iCloud)
        try await s.store.upsert(CatalogueRecord(identity: both, format: .raw, state: .imported))
        try await s.store.markStaged(both, format: .raw, at: local)
        let all = [importedOnly, stagedOnly, both, neither]
        #expect(try await s.store.states(of: all)
            == [importedOnly: .imported, stagedOnly: .new, both: .imported, neither: .new])
        #expect(try await s.store.stagedStates(of: all) == [stagedOnly, both])
    }

    @Test(arguments: StoreKind.available)
    func bothRootsAndAMissingDateRoundTrip(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let undated = StagedLocation(root: .onThisIPhone, relativePath: "Staging/Cam/Undated/X.JPG")
        let x = C.id("X.JPG", "20261101T143010", 10)
        try await s.store.markStaged(first, format: .raw, at: iCloud)
        try await s.store.markStaged(x, format: .jpeg, at: undated)
        #expect(try await s.store.record(for: first)?.staged == iCloud)
        #expect(try await s.store.record(for: x)?.staged == undated)
    }

    /// A store with one row per identity writes through the same healing rule as one that finds duplicates: an
    /// upsert and a checkpoint over a staged row keep its copy (the duplicates themselves are SwiftData's,
    /// `SwiftDataCatalogueTests`; the rule is `StagedMarkTests`').
    @Test(arguments: StoreKind.available)
    func upsertAndCheckpointKeepTheStagedCopyThroughTheHealingRule(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.markStaged(first, format: .raw, at: local)
        try await s.store.markPartial(first, format: .raw, tempURL: CameraFixtures.partialFile("DSC00001"),
                                      offset: 4096)
        #expect(try await s.store.record(for: first)?.staged == local)
        try await s.store.upsert(CatalogueRecord(identity: first, format: .raw, state: .imported))
        #expect(try await s.store.record(for: first)?.staged == local)
        #expect(try await s.rows().count == 1)
    }
}

/// The rule both stores read a stored row through before a write (`StagedMark.healed(_:among:)`).
@Suite("Staged copies when healing duplicates")
struct StagedMarkTests {
    typealias C = CatalogueContractTests

    let identity = C.id("DSC00001.ARW", "20261101T143005", 44_000_000)
    let a = StagedLocation(root: .onThisIPhone, relativePath: "Staging/Cam/2026-11-01/DSC00001.ARW")
    let b = StagedLocation(root: .iCloudDrive, relativePath: "Staging/Cam/2026-11-01/DSC00001 (2).ARW")

    @Test func theKeptRowsOwnCopyWins() {
        let kept = CatalogueRecord(identity: identity, format: .raw, state: .imported, staged: b)
        #expect(StagedMark.healed(kept, among: [a, b])?.staged == b)
    }

    @Test func aKeptRowWithoutACopyTakesTheFirstDuplicatesCopy() {
        let kept = CatalogueRecord(identity: identity, format: .raw, state: .imported)
        var expected = kept
        expected.staged = a
        #expect(StagedMark.healed(kept, among: [nil, a, b]) == expected)
    }

    @Test func noCopyAnywhereOrNoRowChangesNothing() {
        let kept = CatalogueRecord(identity: identity, format: .raw, state: .partial)
        #expect(StagedMark.healed(kept, among: [nil, nil]) == kept)
        #expect(StagedMark.healed(kept, among: []) == kept)
        #expect(StagedMark.healed(nil, among: [a]) == nil)
    }
}

/// Turning a staged copy into a file (`StagedLocation.fileURL(in:)`): only paths inside the staging folder, never an
/// unknown (empty) one.
@Suite("Resolving a staged copy")
struct StagedLocationResolverTests {
    let documents = URL(fileURLWithPath: "/nonexistent/Documents", isDirectory: true)

    @Test func aRecordedPathResolvesUnderTheDocumentsFolder() throws {
        let location = StagedLocation(root: .onThisIPhone, relativePath: "Staging/ILCE-7CM2/2026-11-08/DSC00001.ARW")
        #expect(location.isResolvable)
        let url = try #require(location.fileURL(in: documents))
        #expect(url.path == "/nonexistent/Documents/Staging/ILCE-7CM2/2026-11-08/DSC00001.ARW")
        #expect(!url.hasDirectoryPath)
        let spaced = StagedLocation(root: .iCloudDrive, relativePath: "Staging/My Camera/Undated/DSC00001 (2).ARW")
        #expect(try #require(spaced.fileURL(in: documents)).lastPathComponent == "DSC00001 (2).ARW")
    }

    @Test(arguments: [
        "",                                      // unknown: the engine's unreported location
        "Staging",                               // the staging folder itself
        "Staging/",                              // likewise
        "ILCE-7CM2/DSC00001.ARW",                // a Files folder of a build before 11 Nov
        "staging/Cam/2026-11-08/DSC00001.ARW",   // not the folder the app writes
        "/Staging/Cam/2026-11-08/DSC00001.ARW",  // absolute
        "Staging/../Cam/DSC00001.ARW",           // climbs out
        "Staging/Cam/../../DSC00001.ARW",
        "Staging/./Cam/DSC00001.ARW",
        "Staging//DSC00001.ARW",
        "Staging/Cam/",
    ])
    func aPathOutsideTheStagingFolderOrUnknownNeverResolves(_ path: String) {
        let location = StagedLocation(root: .onThisIPhone, relativePath: path)
        #expect(!location.isResolvable)
        #expect(location.fileURL(in: documents) == nil)
    }
}
