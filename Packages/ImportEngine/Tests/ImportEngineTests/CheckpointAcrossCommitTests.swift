import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// A file's commit writes its row last: a checkpoint (`markPartial`) handed over after the commit began is not
/// written, and one already on its way to the catalogue lands before the row. Otherwise a staged file's row, which
/// stays `.new`, would read `.partial` again with the resume the commit cleared (CI's iOS Simulator run of
/// `aLaterJobContinuesFromTheCatalogue`). An imported row is kept by the catalogue either way. On a link that resumes,
/// a catalogue that holds calls before they run (`HoldingCatalogue`), the manual clock, and waits on the trace.
@Suite("Checkpoint writes across a commit", .timeLimit(.minutes(1)))
struct CheckpointAcrossCommitTests {
    /// How a checkpoint write comes after the download has finished.
    enum Late: Sendable, CaseIterable {
        /// The crossing's hand-over task runs only once the commit has begun.
        case crossing
        /// `flushCheckpoints()` while the file is committing.
        case flush
    }

    private func harness() -> (Harness, HoldingExecutor) {
        var policy = ImportPolicy.standard
        policy.checkpointInterval = 1000
        let catalogue = HoldingCatalogue()
        return (Harness(catalogue: catalogue, policy: policy), catalogue.executor)
    }

    private func route(_ kind: DestinationKind, through destination: any ImportDestination, _ h: Harness)
        -> ImportRoute {
        switch kind {
        case .photos: h.photosRoute(to: destination)
        case .staging: .staging(destination, reason: .chosen, place: Harness.onThisIPhone, onThisIPhone: h.files)
        }
    }

    /// The commit's row: staged, back to new with its resume cleared, or imported.
    private func expectCommittedRow(_ h: Harness, _ item: CameraItem, _ kind: DestinationKind,
                                    sourceLocation: SourceLocation = #_sourceLocation) async {
        let row = await h.record(for: item)
        switch kind {
        case .staging:
            #expect(row?.state == .new, sourceLocation: sourceLocation)
            #expect(row?.resumeOffset == 0 && row?.tempURL == nil, sourceLocation: sourceLocation)
            #expect(row?.staged?.relativePath == "Untitled/\(item.name)", sourceLocation: sourceLocation)
        case .photos:
            #expect(row?.state == .imported, sourceLocation: sourceLocation)
            #expect(row?.resumeOffset == 0 && row?.tempURL == nil, sourceLocation: sourceLocation)
        }
    }

    private static func isCheckpoint(_ name: String, _ offset: UInt64) -> @Sendable (EngineTrace) -> Bool {
        { $0 == .checkpointSaved(name, offset: offset) }
    }

    /// The download has finished and the destination has the file; a crossing (or a flush) then asks to write the
    /// latest checkpoint, 2,700 B. It is refused, so the row the commit writes stays the file's last.
    @Test(arguments: [DestinationKind.staging, .photos], Late.allCases)
    func aCheckpointAfterTheCommitBeganIsNotWritten(_ kind: DestinationKind, _ late: Late) async throws {
        let (h, executor) = harness()
        let a = h.item("A.ARW", size: 3000)
        let identity = h.identity(of: a)
        let link = h.resumingLink([a])
        await link.script("A.ARW", .holdAfter(2400))
        let gate = GatedDestination(kind == .photos ? h.photos : h.files)
        let job = try await h.start(.allNew, from: link, to: route(kind, through: gate, h))
        await h.trace.next(where: Self.isCheckpoint("A.ARW", 2100)) // both crossings written: none in flight
        await link.waitUntilHeld("A.ARW")
        await link.release("A.ARW")
        await gate.waitArrived()

        executor.hold()
        let attempt = try #require(await h.engine.latestAttempt(of: identity))
        let seed = try #require(attempt.latestCheckpoint)
        #expect(seed.offset == 2700)
        let engine = h.engine
        let late = Task {
            switch late {
            case .crossing: await engine.checkpointCrossed(seed, by: attempt, of: identity, in: job.rawValue)
            case .flush: await engine.flushCheckpoints()
            }
            executor.note("returned")
        }
        // Refused at once, or its write reached the catalogue and is held there.
        await executor.waitUntil { $0.held > 0 || $0.notes.contains("returned") }
        executor.stopHolding()
        await gate.release()
        #expect(await h.waitFinished() == .completed)
        executor.runHeld() // a write that got through lands after the row
        await late.value

        await expectCommittedRow(h, a, kind)
        #expect(executor.seen.markPartials == 2) // 1,200 and 2,100, during the download
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// The 1,200 B crossing's write is on its way to the catalogue (held there) when the download finishes and the
    /// commit begins. The commit waits for it before it writes its row; the 2,100 B crossing, queued behind it, is
    /// refused.
    @Test(arguments: [DestinationKind.staging, .photos])
    func aCheckpointInFlightWhenTheCommitBeginsLandsBeforeTheRow(_ kind: DestinationKind) async throws {
        let (h, executor) = harness()
        let a = h.item("A.ARW", size: 3000)
        let link = h.resumingLink([a])
        await link.script("A.ARW", .holdAfterEach([900, 1500]))
        try await h.start(.allNew, from: link, to: route(kind, through: kind == .photos ? h.photos : h.files, h))
        await link.waitUntilHeld("A.ARW")
        executor.hold()
        await link.release("A.ARW")
        await link.waitUntilHeld("A.ARW")
        await executor.waitUntil { $0.held == 1 } // the 1,200 B write
        executor.stopHolding()

        let trace = h.trace
        let mark = trace.count
        Task {
            await trace.wait(from: mark) { $0 == .waitingForCheckpointWrites("A.ARW") }
            executor.note("commit waits")
        }
        await link.release("A.ARW")
        // The commit waits for the write, or has written its row past it.
        await executor.waitUntil { $0.rows > 0 || $0.notes.contains("commit waits") }
        executor.runHeld()
        #expect(await h.waitFinished() == .completed)

        await expectCommittedRow(h, a, kind)
        #expect(h.trace.count(where: Self.isCheckpoint("A.ARW", 1200)) == 1)
        #expect(executor.seen.markPartials == 1)
        #expect(h.trace.count { $0 == .checkpointWritesUnsettled("A.ARW") } == 0)
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// A catalogue that never answers the write in flight holds the commit for `checkpointWriteWait` (10 s), not for
    /// ever: the row is then written and the job finishes.
    @Test func theCommitWaitsForAStuckCheckpointWriteOnlySoLong() async throws {
        let (h, executor) = harness()
        let a = h.item("A.ARW", size: 3000)
        let link = h.resumingLink([a])
        await link.script("A.ARW", .holdAfterEach([900, 1500]))
        try await h.start(.allNew, from: link, to: h.stageRoute)
        await link.waitUntilHeld("A.ARW")
        executor.hold()
        await link.release("A.ARW")
        await link.waitUntilHeld("A.ARW")
        await executor.waitUntil { $0.held == 1 }
        executor.stopHolding()

        let trace = h.trace
        let mark = trace.count
        Task {
            await trace.wait(from: mark) { $0 == .waitingForCheckpointWrites("A.ARW") }
            executor.note("commit waits")
        }
        await link.release("A.ARW")
        await executor.waitUntil { $0.rows > 0 || $0.notes.contains("commit waits") }
        try #require(executor.seen.rows == 0) // waiting, not past the write
        await h.advance(by: ImportPolicy.standard.checkpointWriteWait)
        await h.trace.wait(from: mark) { $0 == .checkpointWritesUnsettled("A.ARW") }
        #expect(await h.waitFinished(after: mark) == .completed)
        await expectCommittedRow(h, a, .staging)

        executor.runHeld() // the stuck write, so nothing is left waiting
        await h.cleanup()
    }
}
