import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// RAW+JPEG pairs through the engine (section 7.1 of docs/iteration-2-backlog.md, I6): a RAW and its JPEG (same folder,
/// same stem, within 1 s) are one unit, committed together once both are downloaded, so Photos makes one asset of
/// them and staging puts both in the RAW's day folder; a half whose partner is skipped, fails or is already done goes
/// alone.
@Suite("RAW+JPEG pairs", .timeLimit(.minutes(1)))
struct PairTests {
    /// The ARW and JPG of one frame, taken at `date` (the JPG `gap` seconds later).
    static func frame(_ h: Harness, _ stem: String, at date: Date, gap: TimeInterval = 0,
                      prefix: String = "s1") -> (raw: CameraItem, jpeg: CameraItem) {
        (h.item(stem + ".ARW", size: 4000, prefix: prefix, date: date),
         h.item(stem + ".JPG", size: 2000, prefix: prefix, date: date.addingTimeInterval(gap)))
    }

    /// The pair units among `commits`, as (RAW name, processed name).
    static func pairs(_ commits: [CommitUnit]) -> [[String]] {
        commits.compactMap { unit in
            guard case let .pair(raw, processed) = unit else { return nil }
            return [raw.filename, processed.filename]
        }
    }

    /// The lone units among `commits`, by name.
    static func singles(_ commits: [CommitUnit]) -> [String] {
        commits.compactMap { unit in
            guard case let .single(f) = unit else { return nil }
            return f.filename
        }
    }

    // MARK: - Pairs

    /// One Photos asset for the pair, with one or two downloads in flight; nothing of the pair is committed before
    /// both halves are downloaded, and lone files stay lone.
    @Test(arguments: [1, 2])
    func aPairIsOnePhotosAsset(_ inFlight: Int) async throws {
        let h = Harness(downloadsInFlight: inFlight)
        let (raw, jpeg) = Self.frame(h, "DSC00005", at: Harness.t0.addingTimeInterval(5))
        let loneRaw = h.item("DSC00002.ARW", size: 4100, date: Harness.t0.addingTimeInterval(2))
        let loneJPEG = h.item("DSC00001.JPG", size: 2100, date: Harness.t0.addingTimeInterval(1))
        let link = h.link([loneJPEG, raw, loneRaw, jpeg])
        await link.script(raw.name, .hold)
        await link.script(jpeg.name, .hold)
        try await h.start(.allNew, from: link)

        if inFlight == 1 {
            await link.nextHeldCall(raw.name).release()
            await h.trace.next(.waitingForPartner(raw.name))
            let second = await link.nextHeldCall(jpeg.name)
            #expect(await h.photos.attempts == 0)
            second.release()
        } else {
            // Both halves download together; the first to arrive waits for the other.
            let first = await link.nextHeldCall(raw.name)
            let second = await link.nextHeldCall(jpeg.name)
            second.release()
            await h.trace.next(.waitingForPartner(jpeg.name))
            let early = await h.photos.committedNames
            #expect(!early.contains(raw.name) && !early.contains(jpeg.name))
            first.release()
        }
        #expect(await h.waitFinished() == .completed)

        let commits = await h.photos.commits
        #expect(Self.pairs(commits) == [[raw.name, jpeg.name]])
        #expect(Set(Self.singles(commits)) == [loneRaw.name, loneJPEG.name])
        let rawRow = try #require(await h.record(for: raw))
        let jpegRow = try #require(await h.record(for: jpeg))
        #expect(rawRow.state == .imported && jpegRow.state == .imported)
        #expect(rawRow.location == jpegRow.location) // one asset
        #expect(await h.record(for: loneRaw)?.location != rawRow.location)
        let p = await h.engine.currentProgress
        #expect(p.filesDone == 4 && p.filesImported == 4 && p.filesFailed == 0 && p.filesSkipped == 0)
        if inFlight == 2 { #expect(await link.maxConcurrentBytes == 2) }
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// A pair's halves are queued next to each other even when the listing's order (newest first) puts another file
    /// between them, and in a pick wherever they were picked.
    @Test func partnersAreQueuedTogether() async throws {
        do { // the whole card
            let h = Harness()
            let (raw, jpeg) = Self.frame(h, "DSC00001", at: Harness.t0, gap: 0.8)
            let other = h.item("DSC00009.JPG", size: 3000, date: Harness.t0.addingTimeInterval(0.5))
            let link = h.link([raw, other, jpeg])
            try await h.start(.allNew, from: link)
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls == [jpeg.name, raw.name, other.name])
            let commits = await h.photos.commits
            #expect(Self.pairs(commits) == [[raw.name, jpeg.name]])
            #expect(Self.singles(commits) == [other.name])
            await h.cleanup()
        }
        do { // picked by hand
            let h = Harness()
            let (raw, jpeg) = Self.frame(h, "DSC00001", at: Harness.t0)
            let other = h.item("DSC00009.JPG", size: 3000, date: Harness.t0.addingTimeInterval(9))
            let link = h.link([raw, other, jpeg])
            try await h.start(.items([raw, other, jpeg]), from: link)
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls == [raw.name, jpeg.name, other.name])
            #expect(await h.engine.currentFiles.map(\.item.name) == [raw.name, jpeg.name, other.name])
            #expect(Self.pairs(await h.photos.commits) == [[raw.name, jpeg.name]])
            await h.cleanup()
        }
    }

    /// Files appended while a job runs pair among themselves, and with a lone file of the job still to download.
    @Test func appendedFilesArePaired() async throws {
        let h = Harness()
        let first = h.item("A.JPG", size: 3000, date: Harness.t0.addingTimeInterval(30))
        let (raw, jpeg) = Self.frame(h, "DSC00001", at: Harness.t0)
        let (raw2, jpeg2) = Self.frame(h, "DSC00002", at: Harness.t0.addingTimeInterval(2))
        let link = h.link([first, raw, jpeg, raw2, jpeg2])
        await link.script(first.name, .hold)
        try await h.start(.items([first, raw2]), from: link)
        let held = await link.nextHeldCall(first.name)
        #expect(try await h.engine.append([raw, jpeg, jpeg2]) == 3)
        held.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == [first.name, raw2.name, raw.name, jpeg.name, jpeg2.name])
        let commits = await h.photos.commits
        #expect(Self.singles(commits) == [first.name])
        #expect(Set(Self.pairs(commits)) == [[raw.name, jpeg.name], [raw2.name, jpeg2.name]])
        await h.cleanup()
    }

    // MARK: - Partial pairs

    /// A half skipped by the link (unreadable here; missing after a replug below) leaves the other half to be
    /// committed alone, and the outcome lists the skip.
    @Test func aSkippedHalfLeavesTheOtherAlone() async throws {
        let h = Harness()
        let (raw, jpeg) = Self.frame(h, "DSC00001", at: Harness.t0)
        let link = h.link([raw, jpeg])
        await link.script(jpeg.name, .fail(.unreadableItem))
        try await h.start(.allNew, from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(h.trace.log.contains(.waitingForPartner(raw.name)))
        #expect(h.trace.log.contains(.committedWithoutPartner(raw.name)))
        #expect(Self.singles(await h.photos.commits) == [raw.name])
        #expect(await h.outcome(of: jpeg) == .skipped(.link(.unreadableItem)))
        #expect(await h.record(for: raw)?.state == .imported)
        #expect(await h.record(for: jpeg) == nil)
        let p = await h.engine.currentProgress
        #expect(p.filesImported == 1 && p.filesSkipped == 1)
        await h.cleanup()
    }

    /// A half that fails for a real error after its retries is listed as failed; the other half waits until nothing
    /// else is left to download, then is committed alone.
    @Test func aFailedHalfLeavesTheOtherUntilTheJobEnds() async throws {
        let h = Harness()
        let (raw, jpeg) = Self.frame(h, "DSC00005", at: Harness.t0.addingTimeInterval(5))
        let later = h.item("C.JPG", size: 3000, date: Harness.t0.addingTimeInterval(1))
        let link = h.link([raw, jpeg, later])
        await link.script(jpeg.name, .fail(.busy), .fail(.busy), .fail(.busy), .fail(.busy))
        try await h.start(.allNew, from: link)
        for (n, delay) in zip(1 ... 3, ImportPolicy.standard.retryDelays) {
            await h.trace.next(where: EngineTrace.isRetrying(jpeg.name, n))
            await h.advance(by: delay)
        }
        await h.trace.next(.failed(jpeg.name, .link(.busy)))
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == [raw.name, jpeg.name, jpeg.name, jpeg.name, jpeg.name, later.name])
        // C.JPG, downloaded after the failure, is committed first; the ARW once nothing else is left.
        #expect(await h.photos.committedNames == [later.name, raw.name])
        #expect(Self.pairs(await h.photos.commits).isEmpty)
        #expect(h.trace.log.contains(.committedWithoutPartner(raw.name)))
        #expect(await h.record(for: raw)?.state == .imported)
        #expect(await h.record(for: jpeg) == nil)
        let p = await h.engine.currentProgress
        #expect(p.filesImported == 2 && p.filesFailed == 1)
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// A half no longer on the card after a replug is skipped; the half downloaded before the removal was kept on
    /// disk meanwhile and is committed alone.
    @Test func aHalfMissingAfterAReplugLeavesTheOtherAlone() async throws {
        let h = Harness()
        let (raw, jpeg) = Self.frame(h, "DSC00001", at: Harness.t0)
        let link1 = h.link([raw, jpeg])
        await link1.script(jpeg.name, .hold)
        try await h.start(.allNew, from: link1)
        let call = await link1.nextHeldCall(jpeg.name)
        link1.send(.removed)
        await h.trace.next(.paused(.cameraRemoved))
        call.release(.fail(.disconnected))
        #expect(h.stagedFiles == 1) // the ARW, waiting for its JPG
        #expect(await h.photos.attempts == 0)

        let (raw2, _) = Self.frame(h, "DSC00001", at: Harness.t0, prefix: "s2")
        let link2 = h.link([raw2])
        try await h.engine.reconnect(link2)
        #expect(await h.waitFinished() == .completed)
        #expect(await link2.bytesCalls.isEmpty)
        #expect(Self.singles(await h.photos.commits) == [raw.name])
        #expect(await h.outcome(of: jpeg) == .skipped(.link(.itemNotFound)))
        #expect(await h.record(for: raw)?.state == .imported)
        await h.cleanup()
    }

    /// A file without a capture date never pairs (D10: it is skipped and counted); its partner goes alone.
    @Test func aDatelessHalfLeavesTheOtherAlone() async throws {
        let h = Harness()
        let raw = h.item("DSC00001.ARW", size: 4000, date: nil)
        let jpeg = h.item("DSC00001.JPG", size: 2000, date: Harness.t0)
        let link = h.link([raw, jpeg])
        try await h.start(.items([raw, jpeg]), from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == [jpeg.name])
        #expect(Self.singles(await h.photos.commits) == [jpeg.name])
        #expect(!h.trace.log.contains(.waitingForPartner(jpeg.name)))
        let p = await h.engine.currentProgress
        #expect(p.filesImported == 1 && p.filesSkipped == 1)
        await h.cleanup()
    }

    /// A pair with one half imported already: the other half is imported as a lone file (Photos can't add a resource
    /// to an existing asset), whether the card is listed or the pair picked; a pair imported already isn't queued.
    @Test func aHalfAlreadyImportedLeavesTheOtherAsALoneFile() async throws {
        for selection in ["allNew", "items"] {
            let probe = Harness()
            let (raw, jpeg) = Self.frame(probe, "DSC00001", at: Harness.t0)
            let (raw2, jpeg2) = Self.frame(probe, "DSC00002", at: Harness.t0.addingTimeInterval(2))
            let rows = [raw, raw2, jpeg2].map {
                CatalogueRecord(identity: probe.identity(of: $0), format: $0.format, state: .imported,
                                location: .photosAsset(localIdentifier: "earlier"))
            }
            await probe.cleanup()
            let h = Harness(catalogue: InMemoryCatalogue(records: rows))
            let link = h.link([raw, jpeg, raw2, jpeg2])
            try await h.start(selection == "items" ? .items([raw, jpeg, raw2, jpeg2]) : .allNew, from: link)
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls == [jpeg.name], "\(selection)")
            #expect(Self.singles(await h.photos.commits) == [jpeg.name], "\(selection)")
            #expect(await h.record(for: raw)?.location == .photosAsset(localIdentifier: "earlier"), "\(selection)")
            #expect(await h.record(for: jpeg)?.location == .photosAsset(localIdentifier: "asset-1"), "\(selection)")
            await h.cleanup()
        }
    }

    // MARK: - Pauses, stalls and ends mid-pair

    /// A pause between the halves keeps the downloaded half on disk, waiting, until the job continues; then the pair
    /// is committed as one.
    @Test func aPauseMidPairKeepsTheDownloadedHalf() async throws {
        let h = Harness()
        let (raw, jpeg) = Self.frame(h, "DSC00001", at: Harness.t0)
        let link = h.link([raw, jpeg])
        await link.script(jpeg.name, .hold, .deliver)
        try await h.start(.allNew, from: link)
        let call = await link.nextHeldCall(jpeg.name)
        try await h.engine.pause()
        call.release(.fail(.busy)) // in flight across the pause: put back, no retry counted
        await h.trace.next(.idle(queued: 1, inFlight: 0))

        #expect(h.stagedFiles == 1)
        #expect(await h.photos.attempts == 0)
        let files = await h.engine.currentFiles
        let rawRow = try #require(files.first { $0.item.name == raw.name })
        #expect(rawRow.phase == .queued && rawRow.bytesDone == raw.size) // copied, waiting for its JPG
        #expect(await h.engine.currentProgress.bytesDone == raw.size)
        #expect(await h.engine.state == .paused(.byPerson))

        try await h.engine.resume()
        #expect(await h.waitFinished() == .completed)
        #expect(Self.pairs(await h.photos.commits) == [[raw.name, jpeg.name]])
        #expect(h.trace.count { if case .retrying = $0 { true } else { false } } == 0)
        await h.cleanup()
    }

    /// A job cancelled with a half waiting for its partner commits neither: both stay on the card for the next import.
    @Test func aCancelMidPairCommitsNeitherHalf() async throws {
        let h = Harness()
        let (raw, jpeg) = Self.frame(h, "DSC00001", at: Harness.t0)
        let link = h.link([raw, jpeg])
        await link.script(jpeg.name, .hold)
        try await h.start(.allNew, from: link)
        _ = await link.nextHeldCall(jpeg.name)
        await h.engine.cancel()
        #expect(await h.waitFinished() == .cancelled)
        #expect(await h.photos.attempts == 0)
        #expect(await h.records().isEmpty)
        #expect(await h.engine.currentFiles.map(\.phase) == [.notImported, .notImported])
        await h.cleanup()
    }

    /// A stall on the second half pauses the job and retries it; the first half waits on disk, and the pair is
    /// committed as one once the retry delivers.
    @Test func aStallOnOneHalf() async throws {
        let h = Harness()
        let (raw, jpeg) = Self.frame(h, "DSC00001", at: Harness.t0)
        let link = h.link([raw, jpeg])
        await link.script(jpeg.name, .hold, .hold)
        try await h.start(.allNew, from: link)
        _ = await link.nextHeldCall(jpeg.name)
        await h.advance(by: .seconds(30))
        await h.trace.next(.stalled(jpeg.name, count: 1))
        await h.trace.next(.paused(.stalled))
        #expect(h.stagedFiles == 1)
        await h.advance(by: .seconds(5))
        await h.trace.next(.resumed)
        await link.nextHeldCall(jpeg.name).release()
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == [raw.name, jpeg.name, jpeg.name])
        #expect(Self.pairs(await h.photos.commits) == [[raw.name, jpeg.name]])
        #expect(await h.photos.attempts == 1)
        await h.cleanup()
    }

    /// A pair whose staged files the destination can't find is downloaded again, both halves, and committed as one.
    @Test func aPairWhoseFilesVanishIsDownloadedAgain() async throws {
        let h = Harness()
        let (raw, jpeg) = Self.frame(h, "DSC00001", at: Harness.t0)
        let link = h.link([raw, jpeg])
        await h.photos.fail(attempt: 1, with: .stagedFileMissing)
        try await h.start(.allNew, from: link)
        await h.trace.next(where: EngineTrace.isRetrying(jpeg.name, 1))
        await h.advance(by: ImportPolicy.standard.retryDelays[0])
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls.sorted() == [raw.name, raw.name, jpeg.name, jpeg.name])
        #expect(await h.photos.attempts == 2)
        #expect(Self.pairs(await h.photos.commits) == [[raw.name, jpeg.name]])
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// On a link that resumes (Wi-Fi), a JPG cut part-way by a lost session continues from its checkpoint after the
    /// reconnect while its ARW waits in its partial-file folder, and the pair is staged together, byte for byte.
    @Test func aPairOverALinkThatResumes() async throws {
        let h = Harness()
        let (raw, jpeg) = Self.frame(h, "DSC00001", at: Harness.t0)
        let link = h.resumingLink([raw, jpeg])
        await link.script(jpeg.name, .holdAfter(1200))
        let job = try await h.start(.allNew, from: link, to: h.stageRoute)
        await link.waitUntilHeld(jpeg.name)
        #expect(h.trace.log.contains(.waitingForPartner(raw.name)))
        link.send(.sessionLost)
        await h.trace.next(.paused(.cameraUnreachable))
        #expect(await h.files.attempts == 0)

        try await h.engine.reconnect(job, to: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.resumes == [ResumingLink.Resume(name: jpeg.name, offset: 1200)])
        #expect(Self.pairs(await h.files.commits) == [[raw.name, jpeg.name]])
        for item in [raw, jpeg] {
            let data = try Data(contentsOf: h.filesDirectory.appendingPathComponent(item.name))
            #expect(data == ResumingLink.content(of: item.name, count: item.size), "\(item.name)")
            #expect(await h.record(for: item)?.staged != nil)
        }
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    // MARK: - Destinations

    /// Photos access turned off mid-job: the refused pair is staged instead, still together.
    @Test func aRefusedPairIsStagedTogether() async throws {
        let h = Harness()
        let (raw, jpeg) = Self.frame(h, "DSC00001", at: Harness.t0)
        let link = h.link([raw, jpeg])
        await h.photos.deny(from: 1)
        h.photosAccess.set(.denied)
        try await h.start(.allNew, from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(Self.pairs(await h.files.commits) == [[raw.name, jpeg.name]])
        #expect(await h.record(for: raw)?.staged?.relativePath == "Untitled/" + raw.name)
        #expect(await h.record(for: jpeg)?.staged?.relativePath == "Untitled/" + jpeg.name)
        await h.cleanup()
    }

    /// Through the real Photos destination over a fake library: one save, the JPG as the photo and the ARW as the
    /// alternate, the RAW as the original, and both rows naming the one asset.
    @Test func thePhotosDestinationSavesOneAssetForAPair() async throws {
        let h = Harness()
        let library = PairLibrary()
        let destination = PhotosLibraryDestination(library: library, albumStore: InMemoryAlbumIdentifierStore(),
                                                   albumPlan: AlbumPlan(albums: []))
        let (raw, jpeg) = Self.frame(h, "DSC00001", at: Harness.t0)
        let link = h.link([raw, jpeg])
        try await h.start(.allNew, from: link, to: h.photosRoute(to: destination))
        #expect(await h.waitFinished() == .completed)
        let saves = await library.saves
        try #require(saves.count == 1)
        #expect(saves[0].resources.map(\.role) == [.photo, .alternatePhoto])
        #expect(saves[0].resources.map(\.originalFilename) == [jpeg.name, raw.name])
        #expect(saves[0].originalChoice == .raw)
        #expect(saves[0].creationDate == raw.captureDate)
        #expect(await h.record(for: raw)?.location == .photosAsset(localIdentifier: "library-1"))
        #expect(await h.record(for: jpeg)?.location == .photosAsset(localIdentifier: "library-1"))
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// A stage job puts both halves in the RAW's day folder under one stem, even when the JPG was written just after
    /// midnight.
    @Test func aStageJobKeepsAPairInOneDayFolder() async throws {
        let h = Harness()
        let documents = h.root.appendingPathComponent("Documents", isDirectory: true)
        let staging = StagingFolderDestination(root: documents, place: Harness.onThisIPhone,
                                               cameraName: "ILCE-7CM2", timeZone: h.zone)
        let route = ImportRoute.staging(staging, reason: .chosen, place: Harness.onThisIPhone, onThisIPhone: staging)
        // 25 Oct 2026, 23:59:59.6 UTC, and the JPG 0.7 s later, on the 26th.
        let (raw, jpeg) = Self.frame(h, "DSC00001", at: Date(timeIntervalSince1970: 1_792_972_799.6), gap: 0.7)
        let lone = h.item("DSC00002.JPG", size: 3000, date: Harness.t0)
        let link = h.link([raw, jpeg, lone])
        try await h.start(.allNew, from: link, to: route)
        #expect(await h.waitFinished() == .completed)

        let day = staging.cameraFolderURL.appendingPathComponent("2026-10-25", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: day.path).sorted()
        #expect(names == [raw.name, jpeg.name])
        #expect(await h.record(for: raw)?.staged?.relativePath == "Staging/ILCE-7CM2/2026-10-25/" + raw.name)
        #expect(await h.record(for: jpeg)?.staged?.relativePath == "Staging/ILCE-7CM2/2026-10-25/" + jpeg.name)
        #expect(await h.record(for: lone)?.staged?.relativePath == "Staging/ILCE-7CM2/2026-10-26/" + lone.name)
        #expect(await h.record(for: jpeg)?.state == .new) // staged, not imported
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }
}

/// A Photos library that saves every asset and records it, with no albums.
private actor PairLibrary: PhotoLibraryClient {
    private(set) var saves: [AssetCreation] = []

    func authorisation() -> PhotosAuthorisation { .authorised }
    func requestReadWriteAuthorisation() -> PhotosAuthorisation { .authorised }
    func album(withIdentifier identifier: String) -> AlbumLookup { .missing }
    func createAlbum(titled title: String) throws(PhotoLibraryFailure) -> String { "album" }

    func save(_ asset: AssetCreation, toAlbums albumIdentifiers: [String]) throws(PhotoLibraryFailure) -> String {
        saves.append(asset)
        return "library-\(saves.count)"
    }
}
