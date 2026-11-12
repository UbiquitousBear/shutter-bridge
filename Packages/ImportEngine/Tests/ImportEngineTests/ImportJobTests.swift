import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

@Suite("Importing a selection", .timeLimit(.minutes(1)))
struct ImportJobTests {
    @Test(arguments: [DestinationKind.photos, .staging])
    func importsEverySelectedFile(_ kind: DestinationKind) async throws {
        let h = Harness()
        let frames = h.card(frames: 2)
        let video = h.item("C0001.MP4", size: 8000)
        let undated = h.item("DSC00003.JPG", size: 2000, date: nil)
        let link = h.link(frames + [video, undated])
        try await h.start(.allNew, from: link, to: h.route(kind))
        #expect(await h.waitFinished() == .completed)

        let order = ["DSC00002.ARW", "DSC00002.JPG", "DSC00001.ARW", "DSC00001.JPG"]
        #expect(await link.openCount == 1)
        #expect(await link.listCount == 1)
        #expect(await link.bytesCalls == order)

        let chosen = kind == .photos ? h.photos : h.files
        let other = kind == .photos ? h.files : h.photos
        // Each frame's ARW and JPG are one unit (section 7.1 of the Iteration 2 backlog): one Photos asset, or both
        // files staged together.
        let commits = await chosen.commits
        #expect(commits.count == 2)
        #expect(await other.attempts == 0)
        for (i, unit) in commits.enumerated() {
            guard case let .pair(raw, processed) = unit else {
                Issue.record("expected pairs, got \(unit)")
                continue
            }
            #expect(raw.filename == order[2 * i])
            #expect(processed.filename == order[2 * i + 1])
            #expect(raw.captureDate == frames.first { $0.name == order[2 * i] }?.captureDate)
            #expect(processed.captureDate == frames.first { $0.name == order[2 * i + 1] }?.captureDate)
        }

        #expect(await h.records().count == 4)
        for (i, name) in order.enumerated() {
            let item = try #require(frames.first { $0.name == name })
            let row = try #require(await h.record(for: item))
            #expect(row.format == item.format)
            switch kind {
            case .photos:
                #expect(row.state == .imported)
                #expect(row.location == .photosAsset(localIdentifier: "asset-\(i / 2 + 1)")) // one per pair
                #expect(row.staged == nil)
            case .staging:
                // Staged, not imported (Shamil, 11 Nov): the row stays new, with its staged copy beside the state.
                #expect(row.state == .new)
                #expect(row.location == nil)
                #expect(row.staged?.root == .onThisIPhone)
                #expect(row.staged?.relativePath == "Untitled/\(name)")
                #expect(row.staged?.stagedAt != nil)
                #expect(await h.outcome(of: item) == .staged(row.staged))
            }
            if kind == .staging {
                let moved = h.filesDirectory.appendingPathComponent(name)
                let data = try Data(contentsOf: moved)
                #expect(UInt64(data.count) == item.size)
                #expect(data == FakeCameraLink.payload(count: item.size))
            }
        }
        #expect(h.stagedFiles == 0)

        // The undated still is left out and counted (D10); the video is left out unsaid, as Browse never offers it.
        let p = await h.engine.currentProgress
        let total = frames.reduce(UInt64(0)) { $0 + $1.size } + undated.size
        #expect(p.filesDone == 5)
        #expect(p.filesTotal == 5)
        #expect(p.bytesDone == total)
        #expect(p.bytesTotal == total)
        #expect(p.filesFailed == 0)
        #expect(p.filesSkipped == 1)
        #expect(p.filesUndated == 1)
        #expect(p.filesStaged == (kind == .photos ? 0 : 4))
        #expect(p.filesImported == (kind == .photos ? 4 : 0))
        #expect(p.state == .finished(.completed))
        #expect(p.destination == (kind == .photos ? .photos : .stagedHere(.chosen)))
        #expect(await h.engine.state == .finished(.completed))
        await h.cleanup()
    }

    @Test func alreadyImportedFilesAreNotQueued() async throws {
        func seeded(_ h: Harness, _ items: [CameraItem]) -> [CatalogueRecord] {
            items.map { CatalogueRecord(identity: h.identity(of: $0), format: $0.format, state: .imported,
                                        location: .photosAsset(localIdentifier: "old-\($0.name)")) }
        }
        do { // all new
            let probe = Harness()
            let card = probe.card(frames: 2)
            let rows = seeded(probe, card.filter { $0.name.hasPrefix("DSC00002") })
            await probe.cleanup()
            let h = Harness(catalogue: InMemoryCatalogue(records: rows))
            let link = h.link(card)
            try await h.start(.allNew, from: link)
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls == ["DSC00001.ARW", "DSC00001.JPG"])
            #expect(await h.engine.currentProgress.filesTotal == 2)
            for row in rows { #expect(try await h.catalogue.record(for: row.identity) == row) }
            await h.cleanup()
        }
        do { // the same files picked by hand
            let probe = Harness()
            let card = probe.card(frames: 2)
            let rows = seeded(probe, card.filter { $0.name.hasPrefix("DSC00002") })
            await probe.cleanup()
            let h = Harness(catalogue: InMemoryCatalogue(records: rows))
            let link = h.link(card)
            try await h.start(.items(card), from: link)
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls == ["DSC00001.ARW", "DSC00001.JPG"])
            #expect(await h.engine.currentProgress.filesTotal == 2)
            await h.cleanup()
        }
        do { // nothing new at all
            let probe = Harness()
            let card = probe.card(frames: 2)
            let rows = seeded(probe, card)
            await probe.cleanup()
            let h = Harness(catalogue: InMemoryCatalogue(records: rows))
            let link = h.link(card)
            try await h.start(.allNew, from: link)
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls == [])
            #expect(await h.engine.currentProgress.filesTotal == 0)
            await h.cleanup()
        }
    }

    @Test func aDateRangeTakesOnlyItsFiles() async throws {
        let h = Harness()
        let card = h.card(frames: 3) // frames at t0+1, t0+2, t0+3
        let link = h.link(card)
        let range = Harness.t0.addingTimeInterval(2) ... Harness.t0.addingTimeInterval(3)
        try await h.start(.dateRange(range), from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["DSC00003.ARW", "DSC00003.JPG", "DSC00002.ARW", "DSC00002.JPG"])
        await h.cleanup()
    }

    @Test func filesAddedDuringAJobJoinIt() async throws {
        let probe = Harness()
        let card = probe.singles(["A.JPG", "B.JPG", "C.JPG", "D.JPG"])
        let dRow = CatalogueRecord(identity: probe.identity(of: card[3]), format: .jpeg, state: .imported)
        await probe.cleanup()
        let h = Harness(catalogue: InMemoryCatalogue(records: [dRow]))
        let link = h.link(card)
        await link.script("A.JPG", .hold)
        try await h.start(.items([card[0]]), from: link)
        let a = await link.nextHeldCall("A.JPG")

        #expect(try await h.engine.append([card[1], card[2], card[0]]) == 2)
        #expect(try await h.engine.append([card[3]]) == 0)
        #expect(try await h.engine.append([card[1]]) == 0)
        #expect(await h.engine.currentProgress.filesTotal == 3)

        a.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["A.JPG", "B.JPG", "C.JPG"])
        #expect(await h.engine.currentProgress.filesTotal == 3)
        #expect(await h.engine.currentProgress.filesDone == 3)
        for item in card.prefix(3) { #expect(await h.record(for: item)?.state == .imported) }
        await #expect(throws: ImportEngineError.noJob) { try await h.engine.append([card[1]]) }
        await h.cleanup()
    }

    @Test(arguments: [1, 2])
    func downloadsInFlightFollowsTheSetting(_ n: Int) async throws {
        let h = Harness(downloadsInFlight: n)
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG", "D.JPG", "E.JPG"])
        let link = h.link(card)
        await link.setDefaultStep(.hold)
        try await h.start(.items(card), from: link)
        var held: [FakeCameraLink.HeldCall] = []
        for _ in 0 ..< n { held.append(await link.nextHeldCall()) }
        var released = 0
        while released < card.count {
            held.removeFirst().release()
            released += 1
            if released + held.count < card.count { held.append(await link.nextHeldCall()) }
        }
        #expect(await h.waitFinished() == .completed)
        #expect(await link.maxConcurrentBytes == n)
        #expect(await h.records().count == 5)
        await h.cleanup()
    }

    @Test func skipThisFileGoesOnWithTheRest() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link = h.link(card)
        await link.script("B.JPG", .fail(.itemNotFound))
        try await h.start(.items(card), from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await h.photos.committedNames == ["A.JPG", "C.JPG"])
        #expect(await h.outcome(of: card[1]) == .skipped(.link(.itemNotFound)))
        #expect(await h.record(for: card[1]) == nil)
        let p = await h.engine.currentProgress
        #expect(p.filesSkipped == 1)
        #expect(p.filesDone == 3)
        #expect(p.bytesDone == p.bytesTotal)
        await h.cleanup()
    }

    @Test func pickedFilesThatCantBeImportedAreCountedAsSkipped() async throws {
        let h = Harness()
        let still = h.item("A.JPG", size: 3000)
        let video = h.item("C0001.MP4", size: 8000)
        let undated = h.item("B.JPG", size: 2000, date: nil)
        let gone = h.item("Z.JPG", size: 1000, prefix: "old")
        let link = h.link([still, video, undated])
        try await h.start(.items([still, video, undated, gone]), from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["A.JPG"])
        #expect(await h.outcome(of: video) == .skipped(.notAStill))
        #expect(await h.outcome(of: gone) == .skipped(.link(.itemNotFound)))
        #expect(h.trace.log.contains(.skipped("B.JPG", .noCaptureDate)))
        let p = await h.engine.currentProgress
        #expect(p.filesTotal == 4)
        #expect(p.filesSkipped == 3)
        #expect(p.bytesDone == p.bytesTotal)
        await h.cleanup()
    }

    @Test func stopTheJobKeepsWhatWasImported() async throws {
        do { // the link says the phone is full
            let h = Harness()
            let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
            let link = h.link(card)
            await link.script("B.JPG", .fail(.phoneStorageFull))
            try await h.start(.items(card), from: link)
            #expect(await h.waitFinished() == .stopped(.phoneStorageFull))
            #expect(await h.record(for: card[0])?.state == .imported)
            #expect(await link.bytesCalls == ["A.JPG", "B.JPG"])
            #expect(await h.records().count == 1)
            #expect(h.stagedFiles == 0)
            await h.cleanup()
        }
        do { // the destination says so
            let h = Harness()
            let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
            let link = h.link(card)
            await h.photos.fail(attempt: 2, with: .notEnoughSpace)
            try await h.start(.items(card), from: link)
            #expect(await h.waitFinished() == .stopped(.phoneStorageFull))
            #expect(await link.bytesCalls == ["A.JPG", "B.JPG"])
            #expect(await h.records().count == 1)
            #expect(h.stagedFiles == 0)
            await h.cleanup()
        }
    }

    @Test func aRejectedFileFailsWithoutARetry() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card)
        await h.photos.fail(attempt: 1, with: .rejected(detail: "test"))
        try await h.start(.items(card), from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["A.JPG", "B.JPG"])
        #expect(await h.outcome(of: card[0]) == .failed(.destination(.rejected(detail: "test"))))
        #expect(await h.engine.currentProgress.filesFailed == 1)
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    @Test func aStagedFileThatVanishesIsDownloadedAgain() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let link = h.link(card)
        await h.photos.fail(attempt: 1, with: .stagedFileMissing)
        try await h.start(.items(card), from: link)
        await h.trace.next(where: EngineTrace.isRetrying("A.JPG", 1))
        await h.advance(by: .milliseconds(500))
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["A.JPG", "A.JPG"])
        #expect(await h.photos.commits.count == 1)
        await h.cleanup()
    }

    @Test(arguments: [1, 2])
    func photosDenialMidImportSwitchesToFiles(_ n: Int) async throws {
        let h = Harness(downloadsInFlight: n)
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG", "D.JPG"])
        let link = h.link(card)
        await link.setDefaultStep(.hold)
        await h.photos.deny(from: 2)
        try await h.start(.items(card), from: link)

        let a = await link.nextHeldCall("A.JPG")
        let b = n == 2 ? await link.nextHeldCall("B.JPG") : nil
        a.release()
        await h.trace.next(.imported("A.JPG", .photos))
        if let b { b.release() } else { await link.nextHeldCall("B.JPG").release() }
        let files = DestinationDecision.stagedHere(.photosDenied)
        await h.trace.next(.destinationChanged(files))
        await h.trace.next { if case .staged("B.JPG", _) = $0 { true } else { false } }
        await link.nextHeldCall("C.JPG").release()
        await link.nextHeldCall("D.JPG").release()
        #expect(await h.waitFinished() == .completed)

        #expect(await h.photos.committedNames == ["A.JPG"])
        #expect(await h.photos.attempts == 2)
        #expect(await h.files.committedNames == ["B.JPG", "C.JPG", "D.JPG"])
        let p = await h.engine.currentProgress
        #expect(p.filesFailed == 0)
        #expect(p.destination == files)
        #expect(p.destination?.stagingReason?.offersSettingsLink == true)
        #expect(h.photosAccess.reads == 1) // read once, after the refusal, for the reason
        #expect(p.filesStaged == 3)
        let rows = await h.records()
        #expect(rows.count { if case .photosAsset = $0.location { true } else { false } } == 1)
        // Staged instead: recorded with `markStaged`, so they stay new and Import to Photos still offers them.
        #expect(rows.count { $0.state == .new && $0.staged?.root == .onThisIPhone } == 3)
        #expect(h.trace.count { $0.isDestinationChanged } == 1)
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// A save refused while Photos is restricted (3310, or the authorisation reads restricted after a 3311): Files
    /// for the rest, saying so without the Settings link the person couldn't use (decision 9, 8 Nov).
    @Test func photosRestrictedMidImportSwitchesWithoutTheSettingsLink() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link = h.link(card)
        await h.photos.deny(from: 2)
        h.photosAccess.set(.restricted)
        try await h.start(.items(card), from: link)
        #expect(await h.waitFinished() == .completed)
        let restricted = DestinationDecision.stagedHere(.photosRestricted)
        #expect(h.trace.log.contains(.destinationChanged(restricted)))
        #expect(h.trace.count { $0.isDestinationChanged } == 1)
        #expect(await h.photos.committedNames == ["A.JPG"])
        #expect(await h.files.committedNames == ["B.JPG", "C.JPG"])
        let p = await h.engine.currentProgress
        #expect(p.filesFailed == 0)
        #expect(p.destination == restricted)
        #expect(p.destination?.stagingReason?.offersSettingsLink == false)
        await h.cleanup()
    }

    @Test func bothFilesInFlightDeniedSwitchOnce() async throws {
        let h = Harness(downloadsInFlight: 2)
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link = h.link(card)
        // Both commits reach Photos before either is refused, so the second denial comes after the switch.
        let photos = DenyAllTogether(n: 2)
        try await h.engine.start(.items(card), from: link, camera: h.camera, to: h.photosRoute(to: photos))
        #expect(await h.waitFinished() == .completed)
        #expect(await photos.attempts == 2)
        #expect(Set(await h.files.committedNames) == ["A.JPG", "B.JPG", "C.JPG"])
        #expect(await h.engine.currentProgress.filesFailed == 0)
        #expect(h.trace.count { $0.isDestinationChanged } == 1)
        #expect(await h.records().count == 3)
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// Both refused files read access at the same time and get different answers: the switch still happens once,
    /// because the decision is checked again after the read.
    @Test func bothFilesReadAccessTogetherSwitchOnce() async throws {
        let h = Harness(downloadsInFlight: 2)
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link = h.link(card)
        let photos = DenyAllTogether(n: 2)
        let access = HeldPhotosAccess(n: 2, answers: [.denied, .restricted])
        let route = ImportRoute.photos(photos, staging: h.files, onThisIPhone: h.files,
                                       stagingPlace: Harness.onThisIPhone, authorisation: { await access.read() })
        try await h.engine.start(.items(card), from: link, camera: h.camera, to: route)
        #expect(await h.waitFinished() == .completed)
        #expect(await photos.attempts == 2)
        #expect(await access.reads == 2)
        #expect(h.trace.count { $0.isDestinationChanged } == 1)
        #expect(Set(await h.files.committedNames) == ["A.JPG", "B.JPG", "C.JPG"])
        #expect(await h.engine.currentProgress.filesFailed == 0)
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    @Test func resumeCanChangeTheRoute() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link = h.link(card)
        await link.script("A.JPG", .hold)
        try await h.start(.items(card), from: link)
        let a = await link.nextHeldCall("A.JPG")
        try await h.engine.pause()
        a.release()
        await h.trace.next(.imported("A.JPG", .photos))
        await h.trace.next(.idle(queued: 2, inFlight: 0))
        let restricted = DestinationDecision.stagedHere(.photosRestricted)
        try await h.engine.resume(to: h.stageRoute(reason: .photosRestricted))
        #expect(await h.waitFinished() == .completed)
        #expect(await h.photos.committedNames == ["A.JPG"])
        #expect(await h.files.committedNames == ["B.JPG", "C.JPG"])
        #expect(h.trace.log.contains(.destinationChanged(restricted)))
        let p = await h.engine.currentProgress
        #expect(p.destination == restricted)
        #expect(p.destination?.stagingReason?.offersSettingsLink == false)
        await h.cleanup()
    }

    @Test func cancelRemovesTemporaryFiles() async throws {
        let h = Harness(downloadsInFlight: 2)
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link = h.link(card)
        await link.setDefaultStep(.hold)
        await link.setWritesPartialWhileHeld(true)
        try await h.start(.items(card), from: link)
        let first = await link.nextHeldCall()
        let second = await link.nextHeldCall()
        #expect(h.stagedFiles == 2)

        await h.engine.cancel()
        #expect(await h.engine.state == .finished(.cancelled))
        #expect(h.stagedFiles == 0)

        first.release()
        second.release()
        await h.trace.next(.discardedLateFile)
        await h.trace.next(.discardedLateFile)
        #expect(h.trace.count { $0 == .discardedLateFile } == 2)
        #expect(h.stagedFiles == 0)
        #expect(await h.photos.attempts == 0)
        #expect(await h.records().isEmpty)
        #expect(Set(await link.bytesCalls) == ["A.JPG", "B.JPG"]) // the two calls race to the link

        let again = h.trace.count
        let link2 = h.link(h.singles(["A.JPG", "B.JPG", "C.JPG"], prefix: "s2"))
        try await h.start(.allNew, from: link2)
        #expect(await h.waitFinished(after: again) == .completed)
        #expect(await h.records().count == 3)
        await h.cleanup()
    }

    /// Cancel while a file is being committed, then start again at once: the new job's diff waits for the old
    /// commit's row, so the file is saved once, and the old commit isn't cancelled with its job.
    @Test func cancelThenStartDoesNotSaveAFileTwice() async throws {
        let h = Harness()
        let link = h.link(h.singles(["A.JPG"]))
        let dest = HoldingDestination()
        let route = h.photosRoute(to: dest)
        try await h.engine.start(.allNew, from: link, camera: h.camera, to: route)
        await dest.waitArrived()
        await h.engine.cancel()

        let mark = h.trace.count
        let link2 = h.link(h.singles(["A.JPG"], prefix: "s2"))
        try await h.engine.start(.allNew, from: link2, camera: h.camera, to: route)
        await dest.release()
        #expect(await h.waitFinished(after: mark) == .completed)
        #expect(await dest.commits == ["A.JPG"]) // saved once
        #expect(await dest.cancelledAtCommit == [false])
        #expect(await link2.bytesCalls == [])
        #expect(await h.records().count == 1)
        await h.cleanup()
    }

    /// Ending a job never cancels a commit in flight: a destination (or store) that checks for cancellation would
    /// otherwise abort the save, and the file would have no row.
    @Test func aCommitInFlightWhenTheJobEndsIsNotCancelled() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let link = h.link(card)
        let dest = HoldingDestination(failsIfCancelled: true)
        try await h.engine.start(.items(card), from: link, camera: h.camera, to: h.photosRoute(to: dest))
        await dest.waitArrived()
        await h.engine.cancel()
        await dest.release()
        await h.engine.settleCommits(ofJobsOtherThan: UUID())
        #expect(await dest.cancelledAtCommit == [false])
        #expect(await dest.commits == ["A.JPG"])
        #expect(await h.record(for: card[0])?.location == .photosAsset(localIdentifier: "held-1"))
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    @Test func aCatalogueThatCannotWriteStopsTheJob() async throws {
        do {
            let catalogue = FailingCatalogue()
            await catalogue.setFailUpserts(true)
            let h = Harness(catalogue: catalogue)
            let card = h.singles(["A.JPG", "B.JPG"])
            let link = h.link(card)
            try await h.start(.items(card), from: link)
            #expect(await h.waitFinished() == .catalogueUnavailable)
            #expect(await h.photos.commits.count == 1)
            #expect(await link.bytesCalls == ["A.JPG"])
            #expect(h.stagedFiles == 0)
            await h.cleanup()
        }
        do {
            let catalogue = FailingCatalogue()
            await catalogue.setFailStates(true)
            let h = Harness(catalogue: catalogue)
            let card = h.singles(["A.JPG", "B.JPG"])
            let link = h.link(card)
            try await h.start(.items(card), from: link)
            #expect(await h.waitFinished() == .catalogueUnavailable)
            #expect(await link.bytesCalls == [])
            await h.cleanup()
        }
    }
}
