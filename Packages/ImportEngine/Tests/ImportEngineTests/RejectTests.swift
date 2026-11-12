import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// Rejects stay rejected (D3, Shamil, 11 Nov; backlog section 7.4, I21): a file with a Reject mark in the catalogue is
/// left out of *all new*, a date range, *Select all new*'s pick and a job History queues again, even once its staged
/// copy has been removed (`clearStaged` makes it new again); an explicit pick still imports it, and clearing the mark
/// makes it new again. The marks are read by content key (`marks(of:)`), whatever the camera key or folder. All on the
/// manual clock, waiting on the trace.
@Suite("Rejects stay rejected", .timeLimit(.minutes(1)))
struct RejectTests {
    /// A harness whose catalogue has a card of three singles: A new, B staged then removed from Staging and rejected
    /// (under another camera key and folder, so only its content matches), C new. Returns the catalogue too, to change
    /// marks.
    static func seeded() async throws -> (Harness, InMemoryCatalogue, [CameraItem]) {
        let probe = Harness()
        let card = probe.singles(["A.JPG", "B.JPG", "C.JPG"])
        var staged = probe.identity(of: card[1])
        await probe.cleanup()
        staged.camera = CameraKey(rawValue: "usb-mtp-name:other")
        staged.folder = "DCIM/101MSDCF"
        let catalogue = InMemoryCatalogue()
        await catalogue.markStaged(staged, format: card[1].format,
                                   at: StagedLocation(root: .onThisIPhone, relativePath: "Staging/Camera/B.JPG"))
        try await catalogue.setMark(.reject, rating: 0, for: [staged.contentKey], at: Harness.t0)
        await catalogue.clearStaged(staged)
        return (Harness(catalogue: catalogue), catalogue, card)
    }

    // MARK: - All new, a date range and Select all new

    /// *All new* leaves out the reject whose staged copy was removed, says so, and counts it for the outcome.
    @Test func allNewLeavesOutARejectWhoseStagedCopyWasRemoved() async throws {
        for route in [DestinationKind.photos, .staging] {
            let (h, _, card) = try await Self.seeded()
            let b = h.identity(of: card[1])
            #expect(try await h.catalogue.states(of: [b])[b] ?? .new == .new)
            #expect(try await h.catalogue.stagedStates(of: [b]).isEmpty)
            let link = h.link(card)
            try await h.start(.allNew, from: link, to: h.route(route))
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls.sorted() == ["A.JPG", "C.JPG"], "\(route)")
            #expect(h.trace.log.contains(.rejectedLeftOut("B.JPG")))
            let progress = await h.engine.currentProgress
            #expect(progress.rejectsLeftOut == 1)
            #expect(progress.filesTotal == 2)
            #expect(progress.filesSkipped == 0)
            #expect(await h.record(for: card[1]) == nil)
            await h.cleanup()
        }
    }

    @Test func aDateRangeLeavesOutARejectToo() async throws {
        let (h, _, card) = try await Self.seeded()
        let link = h.link(card)
        try await h.start(.dateRange(Harness.t0 ... Harness.t0.addingTimeInterval(1)), from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["A.JPG"])
        #expect(await h.engine.currentProgress.rejectsLeftOut == 1)
        await h.cleanup()
    }

    /// *Select all new*'s pick (`newItems`) leaves the reject out, both when the job starts and when it is appended to a
    /// running job; `picksToDo` agrees, so the app's count is what the job copies. A reject left out twice counts once,
    /// and one picked explicitly afterwards no longer counts.
    @Test func selectAllNewsPickLeavesOutARejectWhenStartedAndWhenAppended() async throws {
        do {
            let (h, _, card) = try await Self.seeded()
            #expect(try await h.engine.picksToDo(.newItems(card), camera: h.camera, for: h.photosRoute).map(\.name)
                == ["A.JPG", "C.JPG"])
            let link = h.link(card)
            try await h.start(.newItems(card), from: link)
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls == ["A.JPG", "C.JPG"])
            #expect(await h.engine.currentProgress.rejectsLeftOut == 1)
            await h.cleanup()
        }
        do {
            let (h, _, card) = try await Self.seeded()
            let link = h.link(card)
            await link.script("A.JPG", .hold)
            try await h.start(.items([card[0]]), from: link)
            let held = await link.nextHeldCall("A.JPG")
            #expect(try await h.engine.append(card, newOnly: true) == 1) // C; B is a reject
            #expect(h.trace.log.contains(.rejectedLeftOut("B.JPG")))
            // *Select all new* again: B is still one reject left out, counted and logged once.
            #expect(try await h.engine.append(card, newOnly: true) == 0)
            #expect(await h.engine.currentProgress.rejectsLeftOut == 1)
            #expect(h.trace.log.filter { $0 == .rejectedLeftOut("B.JPG") }.count == 1)
            #expect(try await h.engine.append(card) == 1) // B, picked explicitly
            // B is in the job now, so it wasn't left out after all: the outcome mustn't say it was.
            #expect(await h.engine.currentProgress.rejectsLeftOut == 0)
            held.release()
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls == ["A.JPG", "C.JPG", "B.JPG"])
            #expect(await h.engine.currentProgress.rejectsLeftOut == 0)
            await h.cleanup()
        }
    }

    // MARK: - An explicit pick, a lifted reject, other marks

    /// An explicit pick of a rejected file imports it, and nothing is counted as left out.
    @Test func anExplicitPickImportsARejectedFile() async throws {
        let (h, _, card) = try await Self.seeded()
        #expect(try await h.engine.picksToDo(.items(card), camera: h.camera, for: h.photosRoute).map(\.name)
            == ["A.JPG", "B.JPG", "C.JPG"])
        let link = h.link(card)
        try await h.start(.items([card[1]]), from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["B.JPG"])
        #expect(await h.photos.committedNames == ["B.JPG"])
        #expect(await h.engine.currentProgress.rejectsLeftOut == 0)
        #expect(!h.trace.log.contains(.rejectedLeftOut("B.JPG")))
        await h.cleanup()
    }

    /// Clearing the mark (Browse's lift) makes the file new again: *all new* imports it.
    @Test func aLiftedRejectIsNewAgain() async throws {
        let (h, catalogue, card) = try await Self.seeded()
        await catalogue.clearMarks(of: [h.identity(of: card[1]).contentKey])
        let link = h.link(card)
        try await h.start(.allNew, from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls.sorted() == ["A.JPG", "B.JPG", "C.JPG"])
        #expect(await h.engine.currentProgress.rejectsLeftOut == 0)
        await h.cleanup()
    }

    /// Only a Reject leaves a file out: a Keep, or stars alone, don't.
    @Test func aKeepOrARatingAloneLeavesNothingOut() async throws {
        let (h, catalogue, card) = try await Self.seeded()
        try await catalogue.setMark(.keep, rating: 0, for: [h.identity(of: card[1]).contentKey], at: Harness.t0)
        try await catalogue.setMark(nil, rating: 3, for: [h.identity(of: card[2]).contentKey], at: Harness.t0)
        let link = h.link(card)
        try await h.start(.allNew, from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls.sorted() == ["A.JPG", "B.JPG", "C.JPG"])
        #expect(await h.engine.currentProgress.rejectsLeftOut == 0)
        await h.cleanup()
    }

    /// A rejected RAW+JPEG pair (one mark per pair, both halves written together: D4) is left out whole.
    @Test func aRejectedPairIsLeftOutWhole() async throws {
        let catalogue = InMemoryCatalogue()
        let h = Harness(catalogue: catalogue)
        let card = h.card(frames: 2)
        try await catalogue.setMark(.reject, rating: 0, for: card[0 ... 1].map { h.identity(of: $0).contentKey },
                                    at: Harness.t0)
        let link = h.link(card)
        try await h.start(.allNew, from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls.sorted() == ["DSC00002.ARW", "DSC00002.JPG"])
        #expect(await h.engine.currentProgress.rejectsLeftOut == 2)
        await h.cleanup()
    }

    /// An imported reject is done anyway: it isn't counted as left out for its mark.
    @Test func anImportedRejectIsNotCountedAsLeftOut() async throws {
        let (h, catalogue, card) = try await Self.seeded()
        let a = h.identity(of: card[0])
        await catalogue.upsert(CatalogueRecord(identity: a, format: card[0].format, state: .imported,
                                                   location: .photosAsset(localIdentifier: "old-A")))
        try await catalogue.setMark(.reject, rating: 0, for: [a.contentKey], at: Harness.t0)
        let link = h.link(card)
        try await h.start(.allNew, from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["C.JPG"])
        #expect(await h.engine.currentProgress.rejectsLeftOut == 1) // B only
        await h.cleanup()
    }

    // MARK: - Queued again from History

    /// A *Resumable* job queued again from its record: an explicit pick comes back as `requeued`, which leaves out a
    /// file rejected since; the record of the new job keeps the pick as a pick.
    @Test func aRequeuedJobLeavesOutARejectEvenFromAnExplicitPick() async throws {
        let (h, _, card) = try await Self.seeded()
        let keys = card.map { h.identity(of: $0).contentKey }
        let selection = ImportSelection(requeueing: .picked(keys), from: card, camera: h.camera, timeZone: h.zone)
        #expect(selection == .requeued(card))
        #expect(!selection.newOnly)
        #expect(try await h.engine.picksToDo(selection, camera: h.camera, for: h.photosRoute).map(\.name)
            == ["A.JPG", "C.JPG"])
        let link = h.link(card)
        let id = try await h.start(selection, from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["A.JPG", "C.JPG"])
        #expect(await h.engine.currentProgress.rejectsLeftOut == 1)
        #expect(h.trace.log.contains(.rejectedLeftOut("B.JPG")))
        let record = try #require(try await h.catalogue.job(id.rawValue))
        #expect(record.selection == .picked(keys))
        await h.cleanup()
    }

    /// A *Re-run* of failed files leaves out one rejected since; a requeued stage job may still stage an imported file,
    /// as an explicit pick may.
    @Test func aRerunLeavesOutARejectAndOtherwiseActsAsAPick() async throws {
        do {
            let (h, _, card) = try await Self.seeded()
            let failed = [card[1], card[2]].map { h.identity(of: $0).contentKey }
            let selection = ImportSelection.rerun(failed, from: card, camera: h.camera, timeZone: h.zone)
            #expect(selection == .requeued([card[1], card[2]]))
            let link = h.link(card)
            try await h.start(selection, from: link)
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls == ["C.JPG"])
            #expect(await h.engine.currentProgress.rejectsLeftOut == 1)
            await h.cleanup()
        }
        do {
            let (h, catalogue, card) = try await Self.seeded()
            let a = h.identity(of: card[0])
            await catalogue.upsert(CatalogueRecord(identity: a, format: card[0].format, state: .imported,
                                                       location: .photosAsset(localIdentifier: "old-A")))
            let selection = ImportSelection.rerun([a.contentKey], from: card, camera: h.camera, timeZone: h.zone)
            let link = h.link(card)
            try await h.start(selection, from: link, to: h.stageRoute)
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls == ["A.JPG"])
            await h.cleanup()
        }
    }

    /// Queuing a record again maps each stored selection, matching stored keys against the listing in their order,
    /// each once; a key no longer on the card is left out, and a pick with nothing left is empty (no job starts).
    @Test func aStoredSelectionIsQueuedAgainByContent() async {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let keys = card.map { h.identity(of: $0).contentKey }
        // The same files listed in another folder, with other handles: found by content.
        let relisted = card.map { h.item($0.name, size: $0.size, prefix: "s2", date: $0.captureDate, folder: "100") }
        let range = Harness.t0 ... Harness.t0.addingTimeInterval(5)
        func requeue(_ stored: JobRecord.Selection, _ listed: [CameraItem] = relisted) -> ImportSelection {
            ImportSelection(requeueing: stored, from: listed, camera: h.camera, timeZone: h.zone)
        }
        #expect(requeue(.allNew) == .allNew)
        #expect(requeue(.dateRange(range)) == .dateRange(range))
        #expect(requeue(.picked([keys[2], keys[0], keys[2]])) == .requeued([relisted[2], relisted[0]]))
        #expect(requeue(.pickedNew([keys[1]])) == .newItems([relisted[1]]))
        #expect(requeue(.picked([keys[1]]), [relisted[0]]).isEmpty)
        #expect(ImportSelection.rerun([], from: relisted, camera: h.camera, timeZone: h.zone).isEmpty)
        // Which selections leave rejects out: all but an explicit pick.
        #expect(!ImportSelection.items(card).leavesOutRejects)
        #expect(ImportSelection.newItems(card).leavesOutRejects)
        #expect(ImportSelection.requeued(card).leavesOutRejects)
        #expect(ImportSelection.allNew.leavesOutRejects)
        #expect(ImportSelection.dateRange(range).leavesOutRejects)
        await h.cleanup()
    }
}
