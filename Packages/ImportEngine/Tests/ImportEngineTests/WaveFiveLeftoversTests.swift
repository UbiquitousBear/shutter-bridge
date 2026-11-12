import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Synchronization
import Testing

extension ImportEngine {
    /// Puts a queued file with an adopted partial copy in the current job, as an `append` during a relist would
    /// (`adopt(_:into:of:)`), for a test that needs one to appear while the engine awaits the catalogue.
    func addQueuedPartial(_ item: CameraItem, identity: ObjectIdentity, folder: URL, offset: UInt64) {
        guard let job else { return }
        let entry = FileEntry(identity: identity, index: job.entries.count, item: item)
        let seed = PartialSeed(download: PartialDownload(file: folder.appendingPathComponent(item.name),
                                                         bytesWritten: offset), name: item.name, size: item.size)
        entry.resumable = ResumableFile(folder: folder, adopted: seed, persistedOffset: offset)
        job.add(entry)
        job.requeue(entry)
    }
}

/// A count a `@Sendable` closure can raise.
final class Tally: Sendable {
    private let value = Mutex(0)
    func bump() { value.withLock { $0 += 1 } }
    var current: Int { value.withLock { $0 } }
}

/// A lookup whose answer a test can change between passes.
final class SwitchableLookup: CommitLookup {
    private let answer: Mutex<@Sendable (PendingCommit) -> CommitLookupAnswer>

    init(_ answer: @escaping @Sendable (PendingCommit) -> CommitLookupAnswer) {
        self.answer = Mutex(answer)
    }

    func set(_ answer: @escaping @Sendable (PendingCommit) -> CommitLookupAnswer) {
        self.answer.withLock { $0 = answer }
    }

    func look(for pending: PendingCommit) async -> CommitLookupAnswer {
        let answer = answer.withLock { $0 }
        return answer(pending)
    }
}

/// Wave 5's review leftovers in the engine (W6-fixes): the commit boundary's passes, and a resumable file resolved
/// without being committed.
@Suite("Wave 5 leftovers", .timeLimit(.minutes(1)))
struct WaveFiveLeftoversTests {
    private static func policy() -> ImportPolicy {
        var policy = ImportPolicy.standard
        policy.checkpointInterval = 1000
        return policy
    }

    private static func isCheckpoint(_ name: String, _ offset: UInt64) -> @Sendable (EngineTrace) -> Bool {
        { $0 == .checkpointSaved(name, offset: offset) }
    }

    private func marker(_ h: Harness, _ item: CameraItem, destination: PendingCommit.Destination = .photos,
                        at date: Date = Harness.t0) -> PendingCommit {
        PendingCommit(id: UUID(), destination: destination,
                      files: [PendingCommit.File(identity: h.identity(of: item), format: item.format, role: .single,
                                                 assetDate: item.captureDate)],
                      writtenAt: date)
    }

    // MARK: Resolving the markers (item 4)

    /// The store is read once after the lookups, not once per marker.
    @Test func theMarkersAreListedOnceAfterTheLookups() async throws {
        let store = FailingCatalogue()
        let h = Harness(catalogue: store, commitLookup: CountingLookup(answer: .notFound(underLimitedAccess: false)))
        for i in 1 ... 5 {
            try await store.beginCommit(marker(h, h.item("DSC0000\(i).ARW", size: 4000 + UInt64(i)),
                                               at: Harness.t0.addingTimeInterval(TimeInterval(i))))
        }
        let report = await h.engine.resolvePendingCommits()
        #expect(report == PendingCommitReport(notFound: 5))
        // The first listing and one read after the lookups, whatever the number of markers.
        #expect(await store.pendingCommitsCalls == 2)
        #expect(try await store.pendingCommits().isEmpty)
        await h.cleanup()
    }

    /// A store that can't list the markers again after the lookups leaves each for the next pass, and counts each as
    /// waiting rather than dropping it from the report.
    @Test func aMarkerThatCouldNotBeReadAgainCountsAsWaiting() async throws {
        let store = FailingCatalogue()
        let lookup = CountingLookup(answer: .notFound(underLimitedAccess: false))
        let h = Harness(catalogue: store, commitLookup: lookup)
        let a = h.item("DSC00001.ARW", size: 4016)
        let b = h.item("DSC00002.ARW", size: 4032, date: Harness.t0.addingTimeInterval(1))
        try await store.beginCommit(marker(h, a))
        try await store.beginCommit(marker(h, b, at: Harness.t0.addingTimeInterval(1)))
        await store.setFailPendingCommits(from: 2)
        let report = await h.engine.resolvePendingCommits()
        #expect(report == PendingCommitReport(waiting: 2))
        #expect(h.trace.log.filter { $0 == .pendingCommitResolved("DSC00001.ARW", .waiting)
                || $0 == .pendingCommitResolved("DSC00002.ARW", .waiting) }.count == 2)
        await store.setFailPendingCommits(from: nil)
        #expect(try await store.pendingCommits().count == 2, "the markers stay")
        #expect(await h.engine.resolvePendingCommits() == PendingCommitReport(notFound: 2))
        #expect(try await store.pendingCommits().isEmpty)
        await h.cleanup()
    }

    // MARK: A stage commit not found reads as not staged (item 2)

    @Test(arguments: [DestinationKind.photos, .staging])
    func aMarkerNotFoundIsSaidInItsDestinationsWords(_ kind: DestinationKind) async throws {
        let store = InMemoryCatalogue()
        let h = Harness(catalogue: store, commitLookup: CountingLookup(answer: .notFound(underLimitedAccess: false)))
        let a = h.item("DSC00001.ARW", size: 4016)
        let destination: PendingCommit.Destination = kind == .photos
            ? .photos : .staging(root: .onThisIPhone, folder: "Staging/ILCE-7CM2/2026-10-26")
        try await store.beginCommit(marker(h, a, destination: destination))
        #expect(await h.engine.launchPass() == PendingCommitReport(notFound: 1))
        #expect(h.trace.log.contains(.pendingCommitResolved("DSC00001.ARW", kind == .photos ? .notFound : .notStaged)))
        await h.cleanup()
    }

    // MARK: Browse is told when a pass wrote rows (item 3)

    /// A marker found by the pass before a job's diff (rows written) tells the app, though the job then imports
    /// nothing; a pass that wrote no rows doesn't.
    @Test func aJobPassThatWroteRowsTellsTheApp() async throws {
        let store = InMemoryCatalogue()
        let lookup = SwitchableLookup { .found($0.importedWrites(localIdentifier: "earlier")) }
        let h = Harness(catalogue: store, commitLookup: lookup)
        let told = Tally()
        await h.engine.setOnRowsRecovered { told.bump() }
        let a = h.item("DSC00001.ARW", size: 4016)
        try await store.beginCommit(marker(h, a))
        try await h.start(.allNew, from: h.link([a]), to: h.photosRoute)
        #expect(await h.waitFinished() == .completed)
        #expect(await h.photos.attempts == 0, "the file was found, so the job imported nothing")
        #expect(told.current == 1)
        #expect(await h.record(for: a)?.location == .photosAsset(localIdentifier: "earlier"))

        // A pass that finds nothing wrote no rows: nobody is told.
        let b = h.item("DSC00002.ARW", size: 4032, date: Harness.t0.addingTimeInterval(1))
        lookup.set { _ in .notFound(underLimitedAccess: false) }
        try await store.beginCommit(marker(h, b, at: Harness.t0.addingTimeInterval(1)))
        let mark = h.trace.count
        try await h.start(.allNew, from: h.link([a, b]), to: h.photosRoute)
        #expect(await h.waitFinished(after: mark) == .completed)
        #expect(told.current == 1)
        await h.cleanup()
    }

    // MARK: A marker found for a file staged elsewhere meanwhile (item 8)

    /// A stage marker for iCloud Drive that couldn't be looked up waits; the next stage job stages the same file On My
    /// iPhone. Found once iCloud Drive returns, the marker is removed and the row keeps the copy it has: nothing is
    /// repointed, nothing deleted, and the spare copy is said.
    @Test func aMarkerFoundForAFileStagedElsewhereKeepsTheExistingRow() async throws {
        let store = InMemoryCatalogue()
        let lookup = SwitchableLookup { _ in .cannotLook }
        let h = Harness(catalogue: store, commitLookup: lookup)
        let a = h.item("DSC00001.ARW", size: 4016)
        let folder = "Staging/ILCE-7CM2/2026-10-26"
        let waiting = marker(h, a, destination: .staging(root: .iCloudDrive, folder: folder))
        try await store.beginCommit(waiting)

        // The next stage job can't look the marker up, so it stages the file On My iPhone.
        try await h.start(.allNew, from: h.link([a]), to: h.stageRoute)
        #expect(await h.waitFinished() == .completed)
        let staged = try #require(await h.record(for: a)?.staged)
        #expect(staged.root == .onThisIPhone)
        #expect(await store.pendingCommits().map(\.id) == [waiting.id], "still waiting")

        // iCloud Drive is back and holds the first commit's copy.
        let iCloudCopy = [FileLocation(relativePath: folder + "/DSC00001.ARW")]
        lookup.set { .found($0.stagedWrites(at: iCloudCopy) ?? []) }
        let report = await h.engine.resolvePendingCommits()
        #expect(report == PendingCommitReport(spareCopies: 1))
        #expect(await store.pendingCommits().isEmpty)
        #expect(await h.record(for: a)?.staged == staged, "the row keeps the copy it has")
        #expect(h.trace.log.contains(.pendingCommitResolved("DSC00001.ARW", .spareStagedCopy)))
        await h.cleanup()
    }

    /// A pair whose RAW was staged elsewhere meanwhile and whose JPEG wasn't: the JPEG's row is written at the found copy,
    /// the RAW's row keeps the copy it has, and the RAW's spare copy is said under its own name.
    @Test func aFoundPairWithOneFileStagedElsewhereSaysItsSpareCopy() async throws {
        let store = InMemoryCatalogue()
        let folder = "Staging/ILCE-7CM2/2026-10-26"
        let found = [FileLocation(relativePath: folder + "/DSC00001.ARW"),
                     FileLocation(relativePath: folder + "/DSC00001.JPG")]
        let h = Harness(catalogue: store, commitLookup: SwitchableLookup { .found($0.stagedWrites(at: found) ?? []) })
        let raw = h.item("DSC00001.ARW", size: 4016)
        let jpeg = h.item("DSC00001.JPG", size: 900)
        let elsewhere = StagedLocation(root: .onThisIPhone, relativePath: folder + "/DSC00001.ARW", stagedAt: Harness.t0)
        await store.markStaged(h.identity(of: raw), format: raw.format, at: elsewhere)
        let pair = PendingCommit(id: UUID(), destination: .staging(root: .iCloudDrive, folder: folder), files: [
            PendingCommit.File(identity: h.identity(of: raw), format: raw.format, role: .raw, assetDate: raw.captureDate),
            PendingCommit.File(identity: h.identity(of: jpeg), format: jpeg.format, role: .processed,
                               assetDate: jpeg.captureDate),
        ], writtenAt: Harness.t0)
        try await store.beginCommit(pair)
        #expect(await h.engine.resolvePendingCommits() == PendingCommitReport(foundInStaging: 1))
        #expect(await store.pendingCommits().isEmpty)
        #expect(await h.record(for: raw)?.staged == elsewhere, "the RAW's row keeps the copy it has")
        #expect(await h.record(for: jpeg)?.staged
            == StagedLocation(root: .iCloudDrive, relativePath: folder + "/DSC00001.JPG", stagedAt: Harness.t0))
        #expect(h.trace.log.contains(.pendingCommitResolved("DSC00001.ARW", .spareStagedCopy)))
        #expect(h.trace.log.contains(.pendingCommitResolved("DSC00001.ARW", .foundInStaging)))
        #expect(!h.trace.log.contains(.pendingCommitResolved("DSC00001.JPG", .spareStagedCopy)))
        await h.cleanup()
    }

    /// With no staged copy elsewhere, a found stage marker writes its row as before.
    @Test func aFoundStageMarkerWithNoOtherCopyWritesItsRow() async throws {
        let store = InMemoryCatalogue()
        let folder = "Staging/ILCE-7CM2/2026-10-26"
        let copy = [FileLocation(relativePath: folder + "/DSC00001.ARW")]
        let h = Harness(catalogue: store, commitLookup: SwitchableLookup { .found($0.stagedWrites(at: copy) ?? []) })
        let a = h.item("DSC00001.ARW", size: 4016)
        let waiting = marker(h, a, destination: .staging(root: .iCloudDrive, folder: folder))
        try await store.beginCommit(waiting)
        #expect(await h.engine.resolvePendingCommits() == PendingCommitReport(foundInStaging: 1))
        #expect(await h.record(for: a)?.staged
            == StagedLocation(root: .iCloudDrive, relativePath: folder + "/DSC00001.ARW", stagedAt: waiting.writtenAt))
        await h.cleanup()
    }

    // MARK: A file resolved from its lane while the job ends (item 6)

    /// A file skipped for a reason of its own, whose partial row is being sent back to new when the job is cancelled,
    /// reads skipped in the ended job's list, not queued.
    @Test func aSkippedFileReadsSkippedWhenTheJobEndsWhileItsRowIsForgotten() async throws {
        let catalogue = HoldingCatalogue()
        let executor = catalogue.executor
        let h = Harness(catalogue: catalogue, policy: Self.policy())
        let a = h.item("A.ARW", size: 5000)
        let link = h.resumingLink([a])
        await link.script("A.ARW", .holdThenFail(2400, .unreadableItem))
        try await h.start(.items([a]), from: link, to: h.stageRoute)
        await h.trace.next(where: Self.isCheckpoint("A.ARW", 2100))
        await link.waitUntilHeld("A.ARW")
        executor.hold()
        await link.release("A.ARW")
        await executor.waitUntil { $0.held > 0 } // the forget's first catalogue call
        await h.engine.cancel()
        executor.stopHolding()
        executor.runHeld()
        #expect(await h.waitFinished() == .cancelled)
        #expect(await h.outcome(of: a) == .skipped(.link(.unreadableItem)))
        await h.cleanup()
    }

    /// The same for a file failed once its retries are used up.
    @Test func aFailedFileReadsFailedWhenTheJobEndsWhileItsRowIsForgotten() async throws {
        let catalogue = HoldingCatalogue()
        let executor = catalogue.executor
        let h = Harness(catalogue: catalogue, policy: Self.policy())
        let a = h.item("A.ARW", size: 5000)
        let link = h.resumingLink([a])
        await link.script("A.ARW", .holdThenFail(2400, .noAnswer), .fail(.noAnswer), .fail(.noAnswer), .fail(.noAnswer))
        try await h.start(.allNew, from: link, to: h.stageRoute)
        await h.trace.next(where: Self.isCheckpoint("A.ARW", 2100))
        await link.waitUntilHeld("A.ARW")
        await link.release("A.ARW")
        let delays = ImportPolicy.standard.retryDelays
        for (retry, delay) in zip(1..., delays.dropLast()) {
            await h.trace.next(where: EngineTrace.isRetrying("A.ARW", retry))
            await h.advance(by: delay)
        }
        await h.trace.next(where: EngineTrace.isRetrying("A.ARW", delays.count))
        executor.hold()
        await h.advance(by: delays[delays.count - 1])
        await executor.waitUntil { $0.held > 0 } // the forget's first catalogue call, after the last failure
        await h.engine.cancel()
        executor.stopHolding()
        executor.runHeld()
        #expect(await h.waitFinished() == .cancelled)
        #expect(await h.outcome(of: a) == .failed(.link(.noAnswer)))
        await h.cleanup()
    }

    // MARK: A file queued while the listing's rows are forgotten (item 5)

    /// A file leaves the card while the session is down; while its row is awaited another queued file with a partial
    /// row appears in the job (as an `append` during the relist adopts one) that isn't on the new listing either. Both
    /// rows go back to new, not only the first's. (A file still waiting to retry can't be one: the driver lists only
    /// once its lanes have returned.)
    @Test func aFileQueuedWhileTheListingsRowsAreForgottenIsForgottenToo() async throws {
        let catalogue = HoldingCatalogue()
        let executor = catalogue.executor
        let h = Harness(catalogue: catalogue, policy: Self.policy())
        let a = h.item("A.ARW", size: 5000)
        let b = h.item("B.ARW", size: 5000, date: Harness.t0.addingTimeInterval(1))
        let c = h.item("C.JPG", size: 900, date: Harness.t0.addingTimeInterval(2))
        // B's partial copy and row, from an earlier job.
        let folder = "\(ImportEngine.partialsFolderName)/\(UUID().uuidString)"
        let folderURL = h.staging.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data(count: 2400).write(to: folderURL.appendingPathComponent("B.ARW"))
        await catalogue.markPartial(h.identity(of: b), format: b.format,
                                    tempURL: URL(fileURLWithPath: folder + "/B.ARW", relativeTo: h.staging), offset: 2400)

        let link = h.resumingLink([a])
        await link.script("A.ARW", .holdAfter(2400))
        let job = try await h.start(.items([a]), from: link, to: h.stageRoute)
        await link.waitUntilHeld("A.ARW")
        link.send(.sessionLost(generation: 0))
        await h.trace.next(.paused(.cameraUnreachable))
        await h.trace.next(where: Self.isCheckpoint("A.ARW", 2400)) // A queued, its checkpoint flushed
        #expect(await h.record(for: a)?.state == .partial)
        #expect(await h.record(for: b)?.state == .partial)

        // The card was swapped: neither is on it. A's row is awaited; B appears in the job meanwhile.
        await link.setCard([c])
        executor.hold()
        let mark = h.trace.count
        try await h.engine.reconnect(job, to: link)
        await executor.waitUntil { $0.held > 0 }
        await h.engine.addQueuedPartial(b, identity: h.identity(of: b), folder: folderURL, offset: 2400)
        executor.stopHolding()
        executor.runHeld()
        #expect(await h.waitFinished(after: mark) == .completed)
        #expect(await h.outcome(of: a) == .skipped(.link(.itemNotFound)))
        #expect(await h.outcome(of: b) == .skipped(.link(.itemNotFound)))
        for item in [a, b] {
            let row = try #require(await h.record(for: item))
            #expect(row.state == .new && row.tempURL == nil && row.resumeOffset == 0, "\(item.name)'s row is new")
        }
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }
}
