import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// A resumable file resolved without being committed (backlog section 3, the fault matrix's known issues; I15): a job
/// stopped by a full phone keeps the file's partial copy and its `.partial` row for the next job, while a file skipped
/// or failed for a reason of its own loses both, so a `.partial` row only ever names a copy some job will continue.
@Suite("Partial copies of files left uncommitted", .timeLimit(.minutes(1)))
struct LeftPartialsTests {
    private static func policy() -> ImportPolicy {
        var policy = ImportPolicy.standard
        policy.checkpointInterval = 1000
        return policy
    }

    private static func isCheckpoint(_ name: String, _ offset: UInt64) -> @Sendable (EngineTrace) -> Bool {
        { $0 == .checkpointSaved(name, offset: offset) }
    }

    /// The partial files under the work folder's `Partials`.
    private func partials(_ h: Harness) -> Int {
        h.regularFiles(under: h.staging.appendingPathComponent(ImportEngine.partialsFolderName, isDirectory: true))
    }

    /// A full phone mid-file stops the job: the file reads failed, but its partial copy stays with its latest
    /// checkpoint in the catalogue (written at the stop, past the last interval crossing), and the next job continues
    /// it from there.
    @Test func aFullPhoneKeepsThePartialForTheNextJob() async throws {
        let h = Harness(policy: Self.policy())
        let a = h.item("A.ARW", size: 5000)
        let link = h.resumingLink([a])
        await link.script("A.ARW", .holdThenFail(2400, .phoneStorageFull))
        try await h.start(.allNew, from: link, to: h.stageRoute)
        await h.trace.next(where: Self.isCheckpoint("A.ARW", 2100))
        await link.waitUntilHeld("A.ARW")
        await link.release("A.ARW")
        #expect(await h.waitFinished() == .stopped(.phoneStorageFull))
        #expect(await h.outcome(of: a) == .failed(.link(.phoneStorageFull)))
        let row = try #require(await h.record(for: a))
        #expect(row.state == .partial && row.resumeOffset == 2400)
        let file = try #require(row.partialFile(in: h.staging))
        #expect(DownloadAttempt.length(of: file) >= 2400)
        #expect(h.stagedFiles == 1 && partials(h) == 1)

        let mark = h.trace.count
        try await h.start(.allNew, from: link, to: h.stageRoute)
        #expect(await h.waitFinished(after: mark) == .completed)
        #expect(await link.resumes == [ResumingLink.Resume(name: "A.ARW", offset: 2400)])
        #expect(await h.files.committedNames == ["A.ARW"])
        #expect(await h.record(for: a)?.tempURL == nil)
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// A stop still ends the job when the camera goes while the engine waits on the catalogue before stopping (writing
    /// the latest checkpoint, or forgetting the row): the lost session puts the file back in the queue meanwhile, but
    /// the phone is still full (or the camera still another body), so the job doesn't wait for a reconnect that would
    /// only meet the same failure. A full phone still keeps the partial copy at its latest checkpoint; another body's
    /// stop still keeps nothing.
    @Test(arguments: [CameraLinkFailure.Kind.phoneStorageFull, .identityChanged])
    func aStopStillEndsTheJobWhenTheCameraGoesMeanwhile(_ kind: CameraLinkFailure.Kind) async throws {
        let catalogue = HoldingCatalogue()
        let executor = catalogue.executor
        let h = Harness(catalogue: catalogue, policy: Self.policy())
        let a = h.item("A.ARW", size: 5000)
        let link = h.resumingLink([a])
        await link.script("A.ARW", .holdThenFail(2400, kind))
        try await h.start(.allNew, from: link, to: h.stageRoute)
        await h.trace.next(where: Self.isCheckpoint("A.ARW", 2100))
        await link.waitUntilHeld("A.ARW")
        executor.hold()
        await link.release("A.ARW")
        // The stop's first catalogue call (the checkpoint, or reading the row to forget) is held there.
        await executor.waitUntil { $0.held > 0 }
        link.send(.sessionLost(generation: 0))
        await h.trace.next(.paused(.cameraUnreachable))
        executor.stopHolding()
        executor.runHeld()
        #expect(await h.waitFinished() == .stopped(kind))
        let row = try #require(await h.record(for: a))
        if kind == .phoneStorageFull {
            #expect(row.state == .partial && row.resumeOffset == 2400)
            #expect(partials(h) == 1)
        } else {
            #expect(row.state == .new && row.tempURL == nil)
            #expect(h.stagedFiles == 0)
        }
        await h.cleanup()
    }

    /// A stop that is the file's own (the camera is another body) keeps nothing: the copy goes and its row is new.
    @Test func anotherCamerasStopKeepsNothing() async throws {
        let h = Harness(policy: Self.policy())
        let a = h.item("A.ARW", size: 5000)
        let link = h.resumingLink([a])
        await link.script("A.ARW", .holdThenFail(2400, .identityChanged))
        try await h.start(.allNew, from: link, to: h.stageRoute)
        await h.trace.next(where: Self.isCheckpoint("A.ARW", 2100))
        await link.waitUntilHeld("A.ARW")
        await link.release("A.ARW")
        #expect(await h.waitFinished() == .stopped(.identityChanged))
        #expect(await h.record(for: a)?.state == .new)
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// A file skipped after a checkpoint reached the catalogue (it can't be read) loses its partial copy and its row
    /// goes back to new: nothing will continue it.
    @Test func aSkippedFileLeavesNoPartialRow() async throws {
        let h = Harness(policy: Self.policy())
        let card = [h.item("A.ARW", size: 5000), h.item("B.JPG", size: 900)]
        let link = h.resumingLink(card)
        await link.script("A.ARW", .holdThenFail(2400, .unreadableItem))
        try await h.start(.items(card), from: link, to: h.stageRoute)
        await h.trace.next(where: Self.isCheckpoint("A.ARW", 2100))
        await link.waitUntilHeld("A.ARW")
        #expect(await h.record(for: card[0])?.state == .partial)
        await link.release("A.ARW")
        #expect(await h.waitFinished() == .completed)
        #expect(await h.outcome(of: card[0]) == .skipped(.link(.unreadableItem)))
        let row = try #require(await h.record(for: card[0]))
        #expect(row.state == .new && row.resumeOffset == 0 && row.tempURL == nil)
        #expect(await h.files.committedNames == ["B.JPG"])
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// A file that fails once its retries are used up loses its partial copy and its row the same way.
    @Test func aFileFailedAfterItsRetriesLeavesNoPartialRow() async throws {
        let h = Harness(policy: Self.policy())
        let a = h.item("A.ARW", size: 5000)
        let link = h.resumingLink([a])
        await link.script("A.ARW", .holdThenFail(2400, .noAnswer), .fail(.noAnswer), .fail(.noAnswer), .fail(.noAnswer))
        try await h.start(.allNew, from: link, to: h.stageRoute)
        await h.trace.next(where: Self.isCheckpoint("A.ARW", 2100))
        await link.waitUntilHeld("A.ARW")
        await link.release("A.ARW")
        for (retry, delay) in zip(1..., ImportPolicy.standard.retryDelays) {
            await h.trace.next(where: EngineTrace.isRetrying("A.ARW", retry))
            await h.advance(by: delay)
        }
        #expect(await h.waitFinished() == .completed)
        #expect(await h.outcome(of: a) == .failed(.link(.noAnswer)))
        #expect(await h.record(for: a)?.state == .new)
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// A Wi-Fi card swapped while the session was down: the file in flight isn't on the listing after the reconnect,
    /// so it is skipped as gone, its partial copy deleted and its row back to new, and the rest carries on.
    @Test func aFileThatLeftTheCardLeavesNoPartialRow() async throws {
        let h = Harness(policy: Self.policy())
        let card = [h.item("A.ARW", size: 5000), h.item("B.JPG", size: 900)]
        let link = h.resumingLink(card)
        await link.script("A.ARW", .holdAfter(2400))
        let job = try await h.start(.items(card), from: link, to: h.stageRoute)
        await link.waitUntilHeld("A.ARW")
        link.send(.sessionLost(generation: 0))
        await h.trace.next(.paused(.cameraUnreachable))
        await h.trace.next(where: Self.isCheckpoint("A.ARW", 2400))
        #expect(await h.record(for: card[0])?.state == .partial)

        await link.setCard([card[1]])
        try await h.engine.reconnect(job, to: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await h.outcome(of: card[0]) == .skipped(.link(.itemNotFound)))
        let row = try #require(await h.record(for: card[0]))
        #expect(row.state == .new && row.tempURL == nil)
        #expect(await link.resumes.isEmpty)
        #expect(await h.files.committedNames == ["B.JPG"])
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }
}
