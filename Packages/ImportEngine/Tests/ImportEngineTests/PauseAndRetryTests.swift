import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

@Suite("Pausing, continuing and the camera coming back", .timeLimit(.minutes(1)))
struct PauseTests {
    @Test func didSuspendPausesUntilTheAppReturns() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link = h.link(card)
        await link.script("A.JPG", .hold)
        await link.script("B.JPG", .hold)
        try await h.start(.items(card), from: link)
        let a = await link.nextHeldCall("A.JPG")

        link.send(.willSuspend)
        link.send(.didSuspend)
        await h.trace.next(.paused(.appInBackground))
        #expect(await h.engine.state == .paused(.appInBackground))
        #expect(await !h.engine.isUSBImportRunning)

        link.send(.resumedOperations) // fires spuriously; not a reason to continue
        await h.trace.next(.linkEvent(.resumedOperations))
        #expect(await h.engine.state == .paused(.appInBackground))

        a.release() // the download in flight finishes during the pause and is committed (decision 4)
        await h.trace.next(.imported("A.JPG", .photos))
        await h.trace.next(.idle(queued: 2, inFlight: 0))
        #expect(await link.bytesCalls == ["A.JPG"])
        #expect(await h.outcome(of: card[0]) == .imported(.photosAsset(localIdentifier: "asset-1")))

        try await h.engine.resume(.appInBackground)
        await h.trace.next(.resumed)
        #expect(await h.engine.state == .running)
        await link.nextHeldCall("B.JPG").release()
        #expect(await h.waitFinished() == .completed)
        #expect(await link.openCount == 1)
        #expect(await h.records().count == 3)
        await h.cleanup()
    }

    @Test func appReturnDoesNotLiftAPersonsPause() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card)
        await link.script("A.JPG", .hold)
        try await h.start(.items(card), from: link)
        let a = await link.nextHeldCall("A.JPG")

        try await h.engine.pause()
        try await h.engine.resume(.appInBackground)
        #expect(await h.engine.state == .paused(.byPerson))

        // The scene-phase fallback for a *did suspend* that never arrives, on top of the person's pause.
        try await h.engine.pause(.appInBackground)
        #expect(await h.engine.state == .paused(.appInBackground))
        try await h.engine.resume(.appInBackground)
        #expect(await h.engine.state == .paused(.byPerson))

        try await h.engine.resume()
        #expect(await h.engine.state == .running)
        a.release()
        #expect(await h.waitFinished() == .completed)
        await h.cleanup()
    }

    @Test func cablePullPausesAndTheInterruptedFileIsCopiedAgain() async throws {
        let h = Harness()
        let card1 = h.singles(["A.JPG", "B.JPG", "C.JPG"], prefix: "s1")
        let link1 = h.link(card1)
        await link1.script("B.JPG", .hold)
        await link1.setWritesPartialWhileHeld(true)
        try await h.start(.items(card1), from: link1)
        let b = await link1.nextHeldCall("B.JPG")
        b.progress(card1[1].size / 2)
        #expect(h.stagedFiles == 1)
        await #expect(throws: ImportEngineError.cameraNotRemoved) { try await h.engine.reconnect(link1) }

        link1.send(.removed)
        await h.trace.next(.paused(.cameraRemoved))
        #expect(h.stagedFiles == 0)
        #expect(await h.engine.isUSBImportRunning)
        try await h.engine.resume() // only the camera coming back lifts a removal
        #expect(await h.engine.state == .paused(.cameraRemoved))

        b.release(.fail(.disconnected)) // the old call ends late: ignored
        await h.trace.next(.discardedLateFile)
        #expect(await h.engine.currentProgress.filesFailed == 0)

        // A new session: new handles, the same files, and a newer one that isn't part of the job.
        var card2 = h.singles(["A.JPG", "B.JPG", "C.JPG"], prefix: "s2")
        card2.append(h.item("E.JPG", size: 3000, prefix: "s2", date: Harness.t0.addingTimeInterval(60)))
        let link2 = h.link(card2)
        try await h.engine.reconnect(link2)
        #expect(await h.waitFinished() == .completed)

        #expect(await link2.openCount == 1)
        #expect(await link2.listCount == 1)
        #expect(await link2.bytesCalls == ["B.JPG", "C.JPG"])
        #expect(await link1.bytesCalls == ["A.JPG", "B.JPG"])
        #expect(await h.photos.sizes["B.JPG"] == card1[1].size) // whole, from its start
        let rows = await h.records()
        #expect(Set(rows.map(\.identity.filename)) == ["A.JPG", "B.JPG", "C.JPG"])
        #expect(rows.count == 3)
        let p = await h.engine.currentProgress
        #expect(p.filesFailed == 0)
        #expect(p.filesDone == 3)
        await h.cleanup()
    }

    @Test func aFileMissingAfterReplugIsSkipped() async throws {
        let h = Harness()
        let card1 = h.singles(["A.JPG", "B.JPG", "C.JPG"], prefix: "s1")
        let link1 = h.link(card1)
        await link1.script("B.JPG", .hold)
        try await h.start(.items(card1), from: link1)
        let b = await link1.nextHeldCall("B.JPG")
        link1.send(.removed)
        await h.trace.next(.paused(.cameraRemoved))
        b.release(.fail(.disconnected))

        let link2 = h.link(h.singles(["A.JPG", "B.JPG"], prefix: "s2"))
        try await h.engine.reconnect(link2)
        #expect(await h.waitFinished() == .completed)
        #expect(await link2.bytesCalls == ["B.JPG"])
        #expect(await h.outcome(of: card1[2]) == .skipped(.link(.itemNotFound)))
        #expect(await h.engine.currentProgress.filesSkipped == 1)
        await h.cleanup()
    }

    @Test func aDisconnectedFailureActsAsARemoval() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card)
        await link.script("A.JPG", .fail(.disconnected))
        try await h.start(.items(card), from: link)
        await h.trace.next(.paused(.cameraRemoved))
        link.send(.removed) // and the event after it changes nothing
        await h.trace.next(.linkEvent(.removed))
        #expect(h.trace.count { $0 == .paused(.cameraRemoved) } == 1)
        #expect(h.stagedFiles == 0)
        // The same link object may come back.
        try await h.engine.reconnect(link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["A.JPG", "A.JPG", "B.JPG"])
        #expect(await link.openCount == 2)
        #expect(await h.engine.currentProgress.filesFailed == 0)
        await h.cleanup()
    }

    /// Browse had the link; the app left and came back before Import was tapped. Those events happened before the
    /// engine listened, so they don't pause the job.
    @Test func eventsFromBeforeTheJobDoNotPauseIt() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let link = h.link(card)
        await link.script("A.JPG", .hold)
        link.send(.willSuspend)
        link.send(.didSuspend)
        link.send(.resumedOperations)
        try await h.start(.items(card), from: link)
        link.send(.cancelledSuspending) // after the start: delivered
        await h.trace.next(.linkEvent(.cancelledSuspending))
        #expect(h.trace.count { if case .linkEvent = $0 { true } else { false } } == 1)
        #expect(await h.engine.state == .running)
        await h.cleanup()
    }

    /// Waiting for the Local Network prompt only informs: traced, and the job keeps running (backlog Iteration 3,
    /// section 1). The other Wi-Fi events pause it (`WiFiPauseTests`).
    @Test func waitingForLocalNetworkOnlyInforms() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card, mode: .wifi(.cameraNetwork))
        await link.script("A.JPG", .hold, .deliver)
        try await h.start(.items(card), from: link)
        let a = await link.nextHeldCall("A.JPG")
        link.send(.waitingForLocalNetwork)
        await h.trace.next(.linkEvent(.waitingForLocalNetwork))
        #expect(await h.engine.state == .running)
        a.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await h.engine.currentProgress.filesFailed == 0)
        #expect(await link.bytesCalls == ["A.JPG", "B.JPG"])
        await h.cleanup()
    }

    /// The cable comes out while the last file is being saved: nothing is left to copy, so the job completes rather
    /// than waiting (screen on) for the camera.
    @Test func aRemovalDuringTheLastCommitStillCompletes() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let link = h.link(card)
        let dest = HoldingDestination()
        try await h.engine.start(.items(card), from: link, camera: h.camera, to: h.photosRoute(to: dest))
        await dest.waitArrived()
        link.send(.removed)
        await h.trace.next(.paused(.cameraRemoved))
        #expect(await h.engine.state == .paused(.cameraRemoved))
        await dest.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await !h.engine.isUSBImportRunning)
        #expect(await h.records().count == 1)
        await h.cleanup()
    }

    @Test func reconnectCanChangeTheRoute() async throws {
        let h = Harness()
        let card1 = h.singles(["A.JPG", "B.JPG"], prefix: "s1")
        let link1 = h.link(card1)
        await link1.script("B.JPG", .hold)
        try await h.start(.items(card1), from: link1)
        let b = await link1.nextHeldCall("B.JPG")
        link1.send(.removed)
        await h.trace.next(.paused(.cameraRemoved))
        b.release(.fail(.disconnected))
        let link2 = h.link(h.singles(["A.JPG", "B.JPG"], prefix: "s2"))
        let denied = DestinationDecision.stagedHere(.photosDenied)
        try await h.engine.reconnect(link2, to: .filesFolder(h.files, reason: .photosDenied))
        #expect(await h.waitFinished() == .completed)
        #expect(await h.photos.committedNames == ["A.JPG"])
        #expect(await h.files.committedNames == ["B.JPG"])
        #expect(h.trace.log.contains(.destinationChanged(denied)))
        #expect(await h.engine.currentProgress.destination == denied)
        await h.cleanup()
    }

    @Test func usbImportRunningFlag() async throws {
        do {
            let h = Harness()
            let card = h.singles(["A.JPG"])
            let link = h.link(card)
            await link.script("A.JPG", .hold)
            #expect(await !h.engine.isUSBImportRunning)
            try await h.start(.items(card), from: link)
            _ = await link.nextHeldCall("A.JPG")
            #expect(await h.engine.isUSBImportRunning)
            #expect(await h.engine.currentProgress.isUSBImportRunning)
            try await h.engine.pause()
            #expect(await !h.engine.isUSBImportRunning)
            #expect(await !h.engine.currentProgress.isUSBImportRunning)
            try await h.engine.resume()
            #expect(await h.engine.isUSBImportRunning)
            link.send(.removed)
            await h.trace.next(.paused(.cameraRemoved))
            #expect(await h.engine.isUSBImportRunning)
            await h.engine.cancel()
            #expect(await !h.engine.isUSBImportRunning)
            #expect(await !h.engine.currentProgress.isUSBImportRunning)
            await h.cleanup()
        }
        do {
            let h = Harness()
            let card = h.singles(["A.JPG"])
            let link = h.link(card, mode: .wifi(.cameraNetwork))
            await link.script("A.JPG", .hold)
            try await h.start(.items(card), from: link)
            _ = await link.nextHeldCall("A.JPG")
            #expect(await h.engine.state == .running)
            #expect(await !h.engine.isUSBImportRunning)
            #expect(await !h.engine.currentProgress.isUSBImportRunning)
            await h.cleanup()
        }
    }
}

@Suite("Stalls and retries", .timeLimit(.minutes(1)))
struct RetryTests {
    @Test func aStallPausesThenRetriesTheFile() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let link = h.link(card)
        await link.script("A.JPG", .hold, .hold)
        try await h.start(.items(card), from: link)
        let first = await link.nextHeldCall("A.JPG")

        await h.advance(by: .seconds(20))
        first.progress(100)
        await h.advance(by: .seconds(20))
        #expect(await h.engine.state == .running)
        await h.advance(by: .seconds(10)) // 30 s since the last progress
        await h.trace.next(.stalled("A.JPG", count: 1))
        await h.trace.next(.paused(.stalled))
        #expect(await h.engine.state == .paused(.stalled))
        #expect(await h.engine.isUSBImportRunning)

        await h.advance(by: .seconds(5))
        await h.trace.next(.resumed)
        let second = await link.nextHeldCall("A.JPG")
        second.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["A.JPG", "A.JPG"])
        #expect(await h.engine.currentProgress.filesFailed == 0)

        first.release() // the abandoned call finishes late
        await h.trace.next(.discardedLateFile)
        #expect(h.stagedFiles == 0)
        #expect(await h.photos.commits.count == 1)
        await h.cleanup()
    }

    @Test func repeatedStallsWaitForThePerson() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let link = h.link(card)
        await link.setDefaultStep(.hold)
        try await h.start(.items(card), from: link)
        for n in 1 ... 3 {
            await h.trace.next(.started("A.JPG", attempt: n))
            _ = await link.nextHeldCall("A.JPG")
            await h.advance(by: .seconds(30))
            await h.trace.next(.stalled("A.JPG", count: n))
            await h.advance(by: .seconds(5))
            await h.trace.next(.resumed)
        }
        await h.trace.next(.started("A.JPG", attempt: 4))
        _ = await link.nextHeldCall("A.JPG")
        await h.advance(by: .seconds(30))
        await h.trace.next(.stalled("A.JPG", count: 4))
        await h.advance(by: .seconds(60))
        #expect(h.trace.count { $0.isResumed } == 3)
        #expect(await h.engine.state == .paused(.stalled))
        #expect(await !h.engine.isUSBImportRunning) // waiting for the person: the screen may sleep
        #expect(await link.bytesCalls.count == 4)
        #expect(await h.engine.currentProgress.filesFailed == 0)

        try await h.engine.resume()
        await h.trace.next(.resumed)
        #expect(await h.engine.isUSBImportRunning)
        await link.nextHeldCall("A.JPG").release()
        #expect(await h.waitFinished() == .completed)
        #expect(await h.record(for: card[0])?.state == .imported)
        await h.cleanup()
    }

    /// The stall count is per file: progress on each attempt doesn't reset it, so a file that always stalls part-way
    /// still waits for the person after the automatic retries.
    @Test func stallsThatEachMakeSomeProgressStillWaitForThePerson() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let link = h.link(card)
        await link.setDefaultStep(.hold)
        try await h.start(.items(card), from: link)
        for n in 1 ... 4 {
            await h.trace.next(.started("A.JPG", attempt: n))
            let call = await link.nextHeldCall("A.JPG")
            call.progress(100)
            await h.advance(by: .seconds(30))
            await h.trace.next(.stalled("A.JPG", count: n))
            if n < 4 { await h.advance(by: .seconds(5)) }
        }
        await h.advance(by: .seconds(60))
        let counts = h.trace.log.compactMap { e -> Int? in if case let .stalled(_, c) = e { c } else { nil } }
        #expect(counts == [1, 2, 3, 4])
        #expect(h.trace.count { $0.isResumed } == 3)
        #expect(await h.engine.state == .paused(.stalled))
        #expect(await !h.engine.isUSBImportRunning)
        await h.cleanup()
    }

    /// An abandoned download's call is cancelled, so a link that honours cancellation stops transferring it and
    /// never has the abandoned call and the retry in flight together.
    @Test func anAbandonedDownloadIsCancelled() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let link = CancellableLink(card: card)
        try await h.engine.start(.items(card), from: link, camera: h.camera, to: h.photosRoute)
        await link.waitCalls(1)
        await h.advance(by: .seconds(30))
        await h.trace.next(.stalled("A.JPG", count: 1))
        await link.waitEnded(1) // the stalled call was asked to stop, and did
        #expect(await link.cancellations == 1)
        await h.advance(by: .seconds(5))
        await h.trace.next(.started("A.JPG", attempt: 2))
        await link.waitCalls(2)
        #expect(await link.maxInFlight == 1) // downloads in flight: 1
        await h.engine.cancel()
        await link.waitEnded(2) // and the cancelled job's call too
        #expect(await link.cancellations == 2)
        #expect(await h.photos.attempts == 0)
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    @Test func transientFailuresAreRetriedALimitedNumberOfTimes() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link = h.link(card)
        await link.script("A.JPG", .fail(.busy), .fail(.noAnswer), .deliver)
        await link.script("B.JPG", .fail(.busy), .fail(.busy), .fail(.busy), .fail(.busy))
        try await h.start(.items(card), from: link)

        await h.trace.next(where: EngineTrace.isRetrying("A.JPG", 1))
        await h.advance(by: .milliseconds(500))
        await h.trace.next(where: EngineTrace.isRetrying("A.JPG", 2))
        await h.advance(by: .seconds(2))
        await h.trace.next(.imported("A.JPG", .photos))

        for (n, delay) in zip(1 ... 3, ImportPolicy.standard.retryDelays) {
            await h.trace.next(where: EngineTrace.isRetrying("B.JPG", n))
            await h.advance(by: delay)
        }
        await h.trace.next(.failed("B.JPG", .link(.busy)))
        #expect(await h.waitFinished() == .completed)

        let calls = await link.bytesCalls
        #expect(calls.filter { $0 == "A.JPG" }.count == 3)
        #expect(calls.filter { $0 == "B.JPG" }.count == 4)
        #expect(calls.filter { $0 == "C.JPG" }.count == 1)
        #expect(await h.record(for: card[1]) == nil)
        let p = await h.engine.currentProgress
        #expect(p.filesFailed == 1)
        #expect(p.filesDone == 3)
        await h.cleanup()
    }

    @Test(arguments: CameraLinkFailure.Kind.allCases)
    func everyLinkFailureFollowsItsOutcome(_ kind: CameraLinkFailure.Kind) async throws {
        let h = Harness()
        let card = h.singles(["X.JPG", "Y.JPG"])
        let link = h.link(card)
        await link.script("X.JPG", .fail(kind), .fail(kind), .fail(kind), .fail(kind))
        try await h.start(.items(card), from: link)
        switch kind.outcome {
        case .retryNow:
            for (n, delay) in zip(1 ... 3, ImportPolicy.standard.retryDelays) {
                await h.trace.next(where: EngineTrace.isRetrying("X.JPG", n))
                await h.advance(by: delay)
            }
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls == ["X.JPG", "X.JPG", "X.JPG", "X.JPG", "Y.JPG"])
            #expect(await h.outcome(of: card[0]) == .failed(.link(kind)))
            #expect(await h.record(for: card[1])?.state == .imported)
        case .retryOnReconnect:
            // A lost card pauses for the card (the session is up); anything else for the camera.
            let reason: PauseReason = kind == .cardUnavailable ? .cardUnavailable : .cameraRemoved
            await h.trace.next(.paused(reason))
            #expect(await h.engine.state == .paused(reason))
            #expect(await link.bytesCalls == ["X.JPG"])
            #expect(await h.engine.currentProgress.filesFailed == 0)
        case .skipFile:
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls == ["X.JPG", "Y.JPG"])
            #expect(await h.outcome(of: card[0]) == .skipped(.link(kind)))
            #expect(await h.record(for: card[1])?.state == .imported)
        case .stopJob:
            #expect(await h.waitFinished() == .stopped(kind))
            #expect(await link.bytesCalls == ["X.JPG"])
            #expect(await h.records().isEmpty)
        }
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    @Test func aFailureOfACallInFlightAcrossAPauseIsNotCounted() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let link = h.link(card)
        await link.script("A.JPG", .hold, .deliver)
        try await h.start(.items(card), from: link)
        let a = await link.nextHeldCall("A.JPG")
        try await h.engine.pause()
        a.release(.fail(.busy))
        await h.trace.next(.idle(queued: 1, inFlight: 0))
        #expect(h.trace.count { if case .retrying = $0 { true } else { false } } == 0)
        try await h.engine.resume()
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["A.JPG", "A.JPG"])
        await h.cleanup()
    }

    @Test func suspiciouslyFastFileAfterAContinueIsSizeChecked() async throws {
        let h = Harness()
        let a = h.item("A.ARW", size: 35_400)
        let link = h.link([a])
        await link.script("A.ARW", .hold, .deliver)
        try await h.start(.items([a]), from: link)
        let held = await link.nextHeldCall("A.ARW")
        link.send(.didSuspend)
        await h.trace.next(.paused(.appInBackground))
        try await h.engine.resume(.appInBackground)
        await h.trace.next(.resumed)
        held.release(.deliverBytes(100)) // done at the same instant as the continue

        await h.trace.next(.sizeMismatch("A.ARW", expected: 35_400, actual: 100))
        await h.trace.next(where: EngineTrace.isRetrying("A.ARW", 1))
        await h.advance(by: .milliseconds(500))
        #expect(await h.waitFinished() == .completed)
        #expect(await h.photos.commits.count == 1)
        #expect(await h.photos.sizes["A.ARW"] == 35_400)
        let p = await h.engine.currentProgress
        #expect(p.filesFailed == 0)
        #expect(p.bytesPerSecond == nil) // in flight across the pause: not throughput
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    @Test(arguments: ListingCase.allCases)
    func listingFailuresFollowTheirOutcome(_ c: ListingCase) async throws {
        let h = Harness()
        let link = h.link(h.singles(["A.JPG"]))
        switch c {
        case .busyOnce: await link.setListFailures([.busy])
        case .modeListsNoFiles: await link.setListFailures([.modeListsNoFiles])
        case .disconnected: await link.setListFailures([.disconnected])
        case .notAuthorised: await link.setOpenFailures([.notAuthorised])
        }
        try await h.start(.allNew, from: link)
        switch c {
        case .busyOnce:
            await h.trace.next(where: EngineTrace.isRetrying(EngineTrace.listingName, 1))
            await h.advance(by: .seconds(1))
            #expect(await h.waitFinished() == .completed)
            #expect(await link.listCount == 2)
        case .modeListsNoFiles:
            #expect(await h.waitFinished() == .stopped(.modeListsNoFiles))
        case .disconnected:
            await h.trace.next(.paused(.cameraRemoved))
            #expect(await h.engine.state == .paused(.cameraRemoved))
            try await h.engine.reconnect(link)
            #expect(await h.waitFinished() == .completed)
        case .notAuthorised:
            #expect(await h.waitFinished() == .stopped(.notAuthorised))
            #expect(await link.listCount == 0)
        }
        await h.cleanup()
    }

    enum ListingCase: String, CaseIterable, Sendable {
        case busyOnce, modeListsNoFiles, disconnected, notAuthorised
    }
}
