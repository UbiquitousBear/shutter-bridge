import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// The engine on a link that resumes (W7): checkpoints in memory and in the catalogue, the resume after the camera
/// or the card comes back, the identity check before a resume, Wi-Fi's pause reasons and their lifting, the cap on
/// downloads in flight, and a later job continuing from the catalogue. All on the manual clock, waiting on the trace.
@Suite("Wi-Fi pauses, resume and concurrency", .timeLimit(.minutes(1)))
struct WiFiPauseAndResumeTests {
    /// The bytes the staging folder holds for `name`.
    private func imported(_ h: Harness, _ name: String) -> Data? {
        try? Data(contentsOf: h.filesDirectory.appendingPathComponent(name))
    }

    private func expectImported(_ h: Harness, _ items: [CameraItem],
                                sourceLocation: SourceLocation = #_sourceLocation) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: h.filesDirectory.path)) ?? []
        #expect(Set(names) == Set(items.map(\.name)), sourceLocation: sourceLocation)
        for item in items {
            #expect(imported(h, item.name) == ResumingLink.content(of: item.name, count: item.size),
                    "\(item.name) bytes", sourceLocation: sourceLocation)
        }
    }

    /// The row of a file a stage job committed: staged, and back to new with its resume cleared (the partial file was
    /// what was staged; `CatalogueStore.markStaged`).
    private func expectStagedRow(_ h: Harness, _ item: CameraItem,
                                 sourceLocation: SourceLocation = #_sourceLocation) async {
        let row = await h.record(for: item)
        #expect(row?.state == .new, sourceLocation: sourceLocation)
        #expect(row?.resumeOffset == 0 && row?.tempURL == nil, sourceLocation: sourceLocation)
        #expect(row?.staged?.relativePath == "Untitled/\(item.name)", sourceLocation: sourceLocation)
    }

    private static func isCheckpoint(_ name: String, _ offset: UInt64) -> @Sendable (EngineTrace) -> Bool {
        { $0 == .checkpointSaved(name, offset: offset) }
    }

    // MARK: - Resume

    /// A file cut part-way by a lost session resumes at the link's latest checkpoint after the reconnect, once the
    /// camera confirms its name and size, and the copy is byte-for-byte the camera's file (backlog Iteration 3,
    /// section 3: the 54 % cut of 2 Nov 23:10).
    @Test func aFileCutAt55PercentResumesAtItsCheckpoint() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.resumingLink(card)
        await link.script("A.JPG", .holdAfter(1650))
        let job = try await h.start(.items(card), from: link, to: h.stageRoute)
        await link.waitUntilHeld("A.JPG")

        link.send(.sessionLost)
        await h.trace.next(.paused(.cameraUnreachable))
        #expect(await h.engine.state == .paused(.cameraUnreachable))
        #expect(await h.engine.currentProgress.filesFailed == 0)
        // The interruption writes the checkpoint to the catalogue, relative to the staging folder.
        await h.trace.next(where: Self.isCheckpoint("A.JPG", 1650))
        let row = try #require(await h.record(for: card[0]))
        #expect(row.state == .partial && row.resumeOffset == 1650)
        #expect(row.tempURL?.relativePath.hasPrefix("Partials/") == true)
        let partial = try #require(row.partialFile(in: h.staging))
        #expect(DownloadAttempt.length(of: partial) >= 1650)

        try await h.engine.reconnect(job, to: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.resumes == [ResumingLink.Resume(name: "A.JPG", offset: 1650)])
        #expect(await link.infoCalls == ["A.JPG"])
        #expect(await link.bytesCalls == ["A.JPG", "A.JPG", "B.JPG"])
        expectImported(h, card)
        await expectStagedRow(h, card[0])
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// The catalogue gets the checkpoint each time it crosses the interval (16 MiB in the app, 1,000 B here), and
    /// `flushCheckpoints()` writes the latest; the commit clears it.
    @Test func checkpointsReachTheCatalogueAtEachIntervalAndOnAFlush() async throws {
        var policy = ImportPolicy.standard
        policy.checkpointInterval = 1000
        let h = Harness(policy: policy)
        let a = h.item("A.ARW", size: 5000)
        let link = h.resumingLink([a])
        await link.script("A.ARW", .holdAfter(2400))
        try await h.start(.items([a]), from: link, to: h.stageRoute)
        await h.trace.next(where: Self.isCheckpoint("A.ARW", 1200))
        await h.trace.next(where: Self.isCheckpoint("A.ARW", 2100))
        #expect(await h.record(for: a)?.resumeOffset == 2100)
        #expect(h.trace.count { if case .checkpointSaved = $0 { true } else { false } } == 2)

        await link.waitUntilHeld("A.ARW")
        await h.engine.flushCheckpoints()
        #expect(await h.record(for: a)?.resumeOffset == 2400)
        #expect(await h.record(for: a)?.state == .partial)

        await link.release("A.ARW")
        #expect(await h.waitFinished() == .completed)
        await expectStagedRow(h, a)
        expectImported(h, [a])
        await h.cleanup()
    }

    /// Expiry: the app flushes, pauses with `.taskExpired` and stops the transfer (the session goes); Continue is a
    /// reconnect, and every file is written exactly once, the one in flight continued from its offset (backlog
    /// Iteration 3, section 9: 360 files each copied once across the 23:51 pause).
    @Test func expiryFlushesAndContinueWritesEachFileOnce() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link = h.resumingLink(card)
        await link.script("B.JPG", .holdAfter(1500))
        let job = try await h.start(.items(card), from: link, to: h.stageRoute)
        await link.waitUntilHeld("B.JPG")

        await h.engine.flushCheckpoints()
        #expect(await h.record(for: card[1])?.resumeOffset == 1500)
        try await h.engine.pause(.taskExpired)
        #expect(await h.engine.state == .paused(.taskExpired))
        #expect(await !h.engine.importRunning(carrier: .wifi))
        link.send(.sessionLost) // the app stops the link's transfer after the pause (W13)
        await h.trace.next(.paused(.cameraUnreachable))
        #expect(await h.engine.state == .paused(.taskExpired)) // open the app first
        try await h.engine.resume(.appInBackground)
        #expect(await h.engine.state == .paused(.taskExpired))

        try await h.engine.reconnect(job, to: link)
        #expect(await h.waitFinished() == .completed)
        expectImported(h, card)
        #expect(await h.files.committedNames == ["A.JPG", "B.JPG", "C.JPG"])
        #expect(await link.resumes == [ResumingLink.Resume(name: "B.JPG", offset: 1500)])
        await h.cleanup()
    }

    /// The handle a reopen still lists for the file now names another file (another size; the card was swapped):
    /// the camera's answer refuses the resume, the partial is dropped, the card is listed again and the job's file,
    /// found by content under its new handle, is copied from its start.
    @Test func aChangedSizeRefusesTheResumeAndRestartsTheFile() async throws {
        let h = Harness()
        let a = h.item("A.JPG", size: 3000)
        let link = h.resumingLink([a])
        await link.script("A.JPG", .holdAfter(1500))
        let job = try await h.start(.items([a]), from: link, to: h.stageRoute)
        await link.waitUntilHeld("A.JPG")
        link.send(.sessionLost)
        await h.trace.next(.paused(.cameraUnreachable))

        // Under the old handle, a different A.JPG; the job's file is now under s2-A.JPG.
        let other = h.item("A.JPG", size: 4000, date: Harness.t0.addingTimeInterval(60))
        let moved = h.item("A.JPG", size: 3000, prefix: "s2")
        await link.setCard([other, moved])
        // The app's reopen still carries the old handle's facts (W8 re-checks known handles only when used).
        try await h.engine.reconnect(job, to: link, knownItems: [a])
        await h.trace.next(.identityChanged("A.JPG"))
        #expect(await h.waitFinished() == .completed)
        #expect(await link.resumes.isEmpty)
        #expect(await link.listCount == 2) // the first listing, then the one after the refusal
        #expect(await link.bytesCalls == ["A.JPG", "A.JPG"])
        expectImported(h, [a])
        #expect(await h.files.committedNames == ["A.JPG"])
        await h.cleanup()
    }

    /// A partial file shorter than its checkpoint (cut back on disk) is not continued: the file is copied from 0.
    @Test func aPartialShorterThanItsCheckpointIsCopiedAgain() async throws {
        let h = Harness()
        let a = h.item("A.JPG", size: 3000)
        let link = h.resumingLink([a])
        await link.script("A.JPG", .failAfter(1500, .busy))
        try await h.start(.items([a]), from: link, to: h.stageRoute)
        await h.trace.next(where: EngineTrace.isRetrying("A.JPG", 1))
        let folder = h.staging.appendingPathComponent(ImportEngine.partialsFolderName, isDirectory: true)
        let partial = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.lastPathComponent == "A.JPG" })
        let handle = try FileHandle(forWritingTo: partial)
        try handle.truncate(atOffset: 100)
        try handle.close()
        await h.advance(by: .milliseconds(500))
        #expect(await h.waitFinished() == .completed)
        #expect(await link.resumes.isEmpty)
        #expect(await link.infoCalls.isEmpty)
        expectImported(h, [a])
        await h.cleanup()
    }

    // MARK: - The card and the session

    /// StoreRemoved pauses for the card and fails nothing (the spike's 82-files bug); StoreAdded lists the card again
    /// on the same session and the file in flight continues from its checkpoint.
    @Test func aLostCardFailsNothingAndItsReturnCarriesOn() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link = h.resumingLink(card)
        await link.script("B.JPG", .holdAfter(1500))
        try await h.start(.items(card), from: link, to: h.stageRoute)
        await link.waitUntilHeld("B.JPG")
        link.send(.storeRemoved)
        await h.trace.next(.paused(.cardUnavailable))
        #expect(await h.engine.state == .paused(.cardUnavailable))
        let p = await h.engine.currentProgress
        #expect(p.filesFailed == 0 && p.filesSkipped == 0)
        #expect(await h.engine.importRunning(carrier: .wifi)) // it gets over this by itself

        link.send(.storeAdded)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.listCount == 2)
        #expect(await link.openCount == 2)
        #expect(await link.resumes == [ResumingLink.Resume(name: "B.JPG", offset: 1500)])
        #expect(await h.engine.currentProgress.filesFailed == 0)
        expectImported(h, card)
        await h.cleanup()
    }

    /// The camera drops its card, then its Wi-Fi about 6 s later (3 and 4 Nov): the session's loss is what the
    /// screen shows, a StoreAdded from the dead session lists nothing, and the reconnect carries on.
    @Test func aLostCardThenALostSessionWaitsForTheReconnect() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.resumingLink(card)
        await link.script("A.JPG", .holdAfter(900))
        let job = try await h.start(.items(card), from: link, to: h.stageRoute)
        await link.waitUntilHeld("A.JPG")
        link.send(.storeRemoved)
        await h.trace.next(.paused(.cardUnavailable))
        link.send(.sessionLost)
        await h.trace.next(.paused(.cameraUnreachable))
        #expect(await h.engine.state == .paused(.cameraUnreachable))
        link.send(.storeAdded)
        await h.trace.next(.linkEvent(.storeAdded))
        #expect(await link.listCount == 1)
        #expect(await h.engine.state == .paused(.cameraUnreachable))

        try await h.engine.reconnect(job, to: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await h.engine.currentProgress.filesFailed == 0)
        #expect(await link.resumes == [ResumingLink.Resume(name: "A.JPG", offset: 900)])
        expectImported(h, card)
        await h.cleanup()
    }

    /// A `cardUnavailable` failure that comes before the StoreRemoved event pauses for the card too.
    @Test func aCardUnavailableFailurePausesForTheCard() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.resumingLink(card)
        await link.script("A.JPG", .failAfter(900, .cardUnavailable))
        try await h.start(.items(card), from: link, to: h.stageRoute)
        await h.trace.next(.paused(.cardUnavailable))
        #expect(await h.engine.currentProgress.filesFailed == 0)
        #expect(h.trace.count { if case .retrying = $0 { true } else { false } } == 0)
        link.send(.storeAdded)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.resumes == [ResumingLink.Resume(name: "A.JPG", offset: 900)])
        expectImported(h, card)
        await h.cleanup()
    }

    /// A `disconnected` failure that beats the `.sessionLost` event reads as a removal until the event names it.
    @Test func aDisconnectBeforeTheLostSessionIsNamedUnreachable() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let link = h.resumingLink(card)
        await link.script("A.JPG", .failAfter(600, .disconnected))
        let job = try await h.start(.items(card), from: link, to: h.stageRoute)
        await h.trace.next(.paused(.cameraRemoved))
        link.send(.sessionLost)
        await h.trace.next(.paused(.cameraUnreachable))
        #expect(await h.engine.state == .paused(.cameraUnreachable))
        try await h.engine.reconnect(job, to: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.resumes == [ResumingLink.Resume(name: "A.JPG", offset: 600)])
        expectImported(h, card)
        await h.cleanup()
    }

    /// A retry whose question to the camera (its file's name and size) fails keeps the checkpoint: the retry after it
    /// continues from there rather than copying the file from its start. The first retry wrote the checkpoint to the
    /// catalogue before its backoff, so an app ended meanwhile keeps it too.
    @Test func aRetryWhoseCameraQuestionFailsKeepsTheCheckpoint() async throws {
        var policy = ImportPolicy.standard
        policy.retryDelays = [.zero, .zero, .zero]
        let h = Harness(policy: policy)
        let card = h.singles(["A.JPG"])
        let link = h.resumingLink(card)
        await link.script("A.JPG", .failAfter(1500, .busy))
        await link.failInfo("A.JPG", .busy)
        try await h.start(.items(card), from: link, to: h.stageRoute)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["A.JPG", "A.JPG"])
        #expect(await link.infoCalls == ["A.JPG", "A.JPG"])
        #expect(await link.resumes == [ResumingLink.Resume(name: "A.JPG", offset: 1500)])
        #expect(h.trace.count { $0 == .checkpointSaved("A.JPG", offset: 1500) } == 1)
        expectImported(h, card)
        await h.cleanup()
    }

    /// Cancel while a resumable file with no checkpoint in the catalogue is being committed: its staged copy stays
    /// until the commit has it, and its row is written.
    @Test func aCancelKeepsACommittingFilesStagedCopy() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let link = h.resumingLink(card)
        let holding = HoldingDestination()
        try await h.start(.items(card), from: link, to: h.photosRoute(to: holding))
        await holding.waitArrived()
        let mark = h.trace.count
        await h.engine.cancel()
        await holding.release()
        _ = await h.trace.wait(from: mark) { $0 == .imported("A.JPG", .photos) }
        #expect(await holding.stagedFileAtCommit == [true])
        #expect(await holding.commits == ["A.JPG"])
        #expect(await h.record(for: card[0])?.state == .imported)
        await h.cleanup()
    }

    /// Attempts abandoned one after another while the first call ignores cancellation: the third waits for the first
    /// call to end before it writes the file, then continues from that call's last checkpoint.
    @Test func aChainOfAbandonedAttemptsNeverWritesBesideTheFirstCall() async throws {
        let h = Harness()
        let a = h.item("A.JPG", size: 3000)
        let link = h.resumingLink([a])
        await link.script("A.JPG", .holdIgnoringCancellationAfter(600))
        let folder = h.staging.appendingPathComponent("chain", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clock = EngineClock(h.clock)
        func attempt(onDiscard: (@Sendable () -> Void)? = nil) -> DownloadAttempt {
            DownloadAttempt(directory: folder, clock: clock, origin: (a.name, a.size), keepsFiles: true,
                            onDiscard: onDiscard)
        }

        let first = attempt()
        first.start(link: link, item: a.id, resume: .init())
        await link.waitUntilHeld("A.JPG")
        first.abandon()

        let (discarded, discard) = AsyncStream<Void>.makeStream()
        let second = attempt(onDiscard: { discard.yield() })
        second.start(link: link, item: a.id, resume: .init(previous: first))
        second.abandon() // its wait for the first call is cancelled
        for await _ in discarded { break }
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(!second.callHasEnded, "the first call is still writing the file")

        let third = attempt()
        third.start(link: link, item: a.id, resume: .init(previous: second))
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(await link.bytesCalls == ["A.JPG"])
        #expect(await link.infoCalls.isEmpty)

        await link.release("A.JPG")
        guard case let .written(url) = await third.outcome() else {
            Issue.record("the third attempt didn't write the file")
            return
        }
        #expect(second.callHasEnded)
        #expect(await link.resumes == [ResumingLink.Resume(name: "A.JPG", offset: 2700)])
        #expect(try Data(contentsOf: url) == ResumingLink.content(of: "A.JPG", count: 3000))
        await h.cleanup()
    }

    // MARK: - Concurrency, lifting rules and the running state

    /// Wi-Fi carries one transaction at a time: the setting's 2 is capped at the link's 1 (backlog Iteration 3,
    /// section 1).
    @Test func wifiRunsOneDownloadAtATimeWhateverTheSetting() async throws {
        let h = Harness(downloadsInFlight: 2)
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG", "D.JPG"])
        let link = h.resumingLink(card)
        await link.script("A.JPG", .holdAfter(300))
        try await h.start(.items(card), from: link, to: h.stageRoute)
        await link.waitUntilHeld("A.JPG")
        // A second file would be claimed in the same step on the engine's actor as A: once a call to the actor has
        // returned, B has started if the cap were ignored.
        _ = await h.engine.state
        #expect(h.trace.count { if case .started("B.JPG", _) = $0 { true } else { false } } == 0)
        #expect(await link.bytesCalls == ["A.JPG"])
        await link.release("A.JPG")
        #expect(await h.waitFinished() == .completed)
        #expect(await link.maxConcurrentBytes == 1)
        expectImported(h, card)
        await h.cleanup()
    }

    /// A link that allows two takes two with the setting at 2, and one with it at 1.
    @Test(arguments: [1, 2])
    func aLinkThatAllowsTwoFollowsTheSetting(_ n: Int) async throws {
        let h = Harness(downloadsInFlight: n)
        let card = h.singles(["A.JPG", "B.JPG"])
        var caps = CameraLinkCapabilities.wifi
        caps.maxDownloadsInFlight = 2
        let link = h.resumingLink(card, capabilities: caps)
        await link.script("A.JPG", .holdAfter(300))
        await link.script("B.JPG", .holdAfter(300))
        try await h.start(.items(card), from: link, to: h.stageRoute)
        await link.waitUntilHeld("A.JPG")
        if n == 2 { await link.waitUntilHeld("B.JPG") } // both calls are in the link at once
        await link.release("A.JPG")
        if n == 1 { await link.waitUntilHeld("B.JPG") }
        await link.release("B.JPG")
        #expect(await h.waitFinished() == .completed)
        #expect(await link.maxConcurrentBytes == n)
        await h.cleanup()
    }

    @Test func reconnectNamesItsJobAndTakesKnownItems() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.resumingLink(card)
        await link.script("A.JPG", .holdAfter(300))
        let job = try await h.start(.items(card), from: link, to: h.stageRoute)
        await link.waitUntilHeld("A.JPG")
        // Running: nothing to reconnect.
        await #expect(throws: ImportEngineError.cameraNotRemoved) { try await h.engine.reconnect(job, to: link) }
        // Not this job.
        let other = Harness()
        let otherJob = try await other.start(.items(card), from: other.link(card))
        await #expect(throws: ImportEngineError.noJob) { try await h.engine.reconnect(otherJob, to: link) }
        await other.cleanup()

        link.send(.sessionLost)
        await h.trace.next(.paused(.cameraUnreachable))
        try await h.engine.reconnect(job, to: link, knownItems: card)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.listCount == 1) // the known items stood in for a second listing
        #expect(await link.openCount == 2)
        await h.cleanup()
    }

    /// A needed join waits for the reconnect, whatever Continue says; an expiry alone is lifted by Continue.
    @Test func needsJoinWaitsForTheReconnectAndContinueLiftsAnExpiry() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.resumingLink(card)
        await link.script("A.JPG", .holdAfter(300))
        let job = try await h.start(.items(card), from: link, to: h.stageRoute)
        await link.waitUntilHeld("A.JPG")

        try await h.engine.pause(.taskExpired)
        try await h.engine.resume(.appInBackground)
        #expect(await h.engine.state == .paused(.taskExpired))
        try await h.engine.resume()
        #expect(await h.engine.state == .running)

        try await h.engine.pause(.cameraUnreachable)
        try await h.engine.pause(.needsJoin)
        #expect(await h.engine.state == .paused(.needsJoin))
        #expect(await !h.engine.importRunning(carrier: .wifi))
        try await h.engine.resume()
        #expect(await h.engine.state == .paused(.needsJoin))
        try await h.engine.reconnect(job, to: link)
        #expect(await h.waitFinished() == .completed)
        expectImported(h, card)
        await h.cleanup()
    }

    /// An expiry hidden behind a needed join is still seen (`isPaused(for:)`), and a reconnect that keeps it lifts the
    /// rest but copies nothing until Continue lifts the expiry (W14).
    @Test func aReconnectKeepingTheExpiryWaitsForContinue() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.resumingLink(card)
        await link.script("A.JPG", .holdAfter(300))
        let job = try await h.start(.items(card), from: link, to: h.stageRoute)
        await link.waitUntilHeld("A.JPG")

        try await h.engine.pause(.cameraUnreachable)
        try await h.engine.pause(.needsJoin)
        try await h.engine.pause(.taskExpired)
        #expect(await h.engine.state == .paused(.needsJoin))
        #expect(await h.engine.isPaused(for: .taskExpired))
        #expect(await !h.engine.isPaused(for: .byPerson))

        try await h.engine.reconnect(job, to: link, knownItems: card, keepingExpiry: true)
        #expect(await h.engine.state == .paused(.taskExpired))
        #expect(await !h.engine.isPaused(for: .needsJoin))
        #expect(await !h.engine.isPaused(for: .cameraUnreachable))
        try await h.engine.resume()
        #expect(await h.waitFinished() == .completed)
        #expect(await !h.engine.isPaused(for: .taskExpired))
        expectImported(h, card)
        await h.cleanup()
    }

    @Test func importRunningFollowsTheLinksCarrier() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let link = h.resumingLink(card)
        await link.script("A.JPG", .holdAfter(300))
        try await h.start(.items(card), from: link, to: h.stageRoute)
        await link.waitUntilHeld("A.JPG")
        #expect(await h.engine.importRunning(carrier: .wifi))
        #expect(await !h.engine.importRunning(carrier: .usb))
        #expect(await !h.engine.isUSBImportRunning) // the screen-on rule stays USB-only
        #expect(await h.engine.currentProgress.runningCarrier == .wifi)
        link.send(.sessionLost)
        await h.trace.next(.paused(.cameraUnreachable))
        #expect(await h.engine.importRunning(carrier: .wifi))
        try await h.engine.pause()
        #expect(await !h.engine.importRunning(carrier: .wifi))
        #expect(await h.engine.currentProgress.runningCarrier == nil)
        await h.cleanup()
    }

    // MARK: - Across jobs

    /// A job that ends with a checkpoint in the catalogue leaves its partial file; the next job continues it from
    /// the catalogue's offset.
    @Test func aLaterJobContinuesFromTheCatalogue() async throws {
        var policy = ImportPolicy.standard
        policy.checkpointInterval = 1000
        let h = Harness(policy: policy)
        let a = h.item("A.ARW", size: 5000)
        let link = h.resumingLink([a])
        await link.script("A.ARW", .holdAfter(2400))
        try await h.start(.allNew, from: link, to: h.stageRoute)
        await h.trace.next(where: Self.isCheckpoint("A.ARW", 2100))
        await link.waitUntilHeld("A.ARW")
        await h.engine.cancel()
        #expect(await h.record(for: a)?.state == .partial)
        #expect(h.stagedFiles == 1) // the partial file stays where the catalogue points

        let mark = h.trace.count
        try await h.start(.allNew, from: link, to: h.stageRoute)
        #expect(await h.waitFinished(after: mark) == .completed)
        #expect(await link.resumes == [ResumingLink.Resume(name: "A.ARW", offset: 2100)])
        expectImported(h, [a])
        await expectStagedRow(h, a)
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// Over a link that can't resume (USB) an earlier job's partial file is deleted and the file copied from 0.
    @Test func aLinkThatCannotResumeDeletesTheCataloguesPartial() async throws {
        var policy = ImportPolicy.standard
        policy.checkpointInterval = 1000
        let h = Harness(policy: policy)
        let a = h.item("A.ARW", size: 5000)
        let wifi = h.resumingLink([a])
        await wifi.script("A.ARW", .holdAfter(2400))
        try await h.start(.allNew, from: wifi, to: h.stageRoute)
        await h.trace.next(where: Self.isCheckpoint("A.ARW", 2100))
        await h.engine.cancel()
        #expect(h.stagedFiles == 1)

        let usb = h.link([a])
        let mark = h.trace.count
        try await h.start(.allNew, from: usb, to: h.stageRoute)
        #expect(await h.waitFinished(after: mark) == .completed)
        #expect(await usb.bytesCalls == ["A.ARW"])
        await expectStagedRow(h, a)
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// At launch the staging folder is emptied except for partial files, and those not written for 7 days go.
    @Test func launchKeepsRecentPartialsOnly() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let partials = staging.appendingPathComponent(ImportEngine.partialsFolderName, isDirectory: true)
        let old = partials.appendingPathComponent("old", isDirectory: true)
        let recent = partials.appendingPathComponent("recent", isDirectory: true)
        for folder in [old, recent] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data([1]).write(to: old.appendingPathComponent("A.ARW"))
        try Data([2]).write(to: recent.appendingPathComponent("B.ARW"))
        try Data([3]).write(to: staging.appendingPathComponent("leftover"))
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        try fm.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: old.appendingPathComponent("A.ARW").path)
        try fm.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: old.path)

        _ = ImportEngine(catalogue: InMemoryCatalogue(), stagingDirectory: staging)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: recent.appendingPathComponent("B.ARW").path))
        #expect(!fm.fileExists(atPath: staging.appendingPathComponent("leftover").path))
    }
}
