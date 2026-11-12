import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// *Import keepers* in the engine (backlog Iteration 2, sections 7.2 and 7.5; I12): a Photos route with no fallback over
/// a `StagingFolderLink`, recorded as a keepers job, and a 3311 that stops the job for Photos access rather than staging
/// files that are in Staging already.
@Suite("Keepers jobs", .timeLimit(.minutes(1)))
struct KeepersJobTests {
    /// Staged copies of three files from the card (a pair and a lone JPG), under names of their own in a temporary
    /// Staging folder, as `stagedRecords` and the marks give *Import keepers* its entries.
    private func staged(_ h: Harness) throws -> (entries: [StagedEntry], urls: [URL], bytes: [Data]) {
        let folder = h.root.appendingPathComponent("Documents/Staging/ILCE-7CM2/2026-10-26", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files: [(String, UInt64, TimeInterval)] = [("DSC00001.ARW", 4000, 1), ("DSC00001.JPG", 2000, 1),
                                                    ("DSC00002.JPG", 3000, 2)]
        var entries: [StagedEntry] = []
        var urls: [URL] = []
        var bytes: [Data] = []
        for (name, count, offset) in files {
            let data = FakeCameraLink.payload(count: count)
            let url = folder.appendingPathComponent(name)
            try data.write(to: url)
            entries.append(StagedEntry(folder: "DCIM/100MSDCF", name: name,
                                       captureDate: Harness.t0.addingTimeInterval(offset),
                                       size: count, url: url))
            urls.append(url)
            bytes.append(data)
        }
        return (entries, urls, bytes)
    }

    private func keepersRoute(_ h: Harness, to photos: (any ImportDestination)? = nil) -> ImportRoute {
        .keepers(photos ?? h.photos, authorisation: h.photosAccess.read)
    }

    private func link(_ entries: [StagedEntry]) -> StagingFolderLink {
        StagingFolderLink(descriptor: StagingFolderLink.descriptor(named: "ILCE-7CM2"), entries: entries,
                          reader: PlainStagedFileReader())
    }

    @Test func aKeepersRouteGoesToPhotosWithNoFallback() {
        let h = Harness()
        let route = keepersRoute(h)
        #expect(route.isKeepers && !route.fallsBackToStaging)
        #expect(route.decision == .photos && route.purpose == .photos)
        #expect(!h.photosRoute.isKeepers && h.photosRoute.fallsBackToStaging)
        #expect(!h.stageRoute.isKeepers)
        // Its staging folders are none at all: anything handed to them is refused.
        #expect(route.staging.kind == .staging && route.stagingOnThisIPhone.kind == .staging)
        // A keepers job keeps a keepers route; no other job becomes one.
        #expect(route.mayChange(to: keepersRoute(h)))
        #expect(!route.mayChange(to: h.photosRoute))
        #expect(!route.mayChange(to: h.stageRoute))
        #expect(!h.photosRoute.mayChange(to: route))
    }

    @Test func aKeepersJobImportsFromStagingIntoPhotosAndIsRecordedAsOne() async throws {
        let h = Harness()
        await h.photos.fileInto(album: "ALBUM-K")
        let (entries, urls, bytes) = try staged(h)
        let job = try await h.start(.allNew, from: link(entries), to: keepersRoute(h))
        #expect(await h.waitFinished() == .completed)

        #expect(Set(await h.photos.committedNames) == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.JPG"])
        // The pair is one Photos asset.
        #expect(await h.photos.commits.count == 2)
        let rows = await h.records()
        #expect(rows.count == 3 && rows.allSatisfy { $0.state == .imported && $0.identity.camera == h.camera })
        // Copy, never move: Staging is as it was. Removal is Staging's own, after the confirmation (section 7.6).
        for (url, data) in zip(urls, bytes) { #expect(try Data(contentsOf: url) == data) }
        #expect(await h.files.attempts == 0)
        #expect(await h.iCloud.attempts == 0)
        #expect(h.stagedFiles == 0)

        await h.engine.settleJobRecords()
        let record = try #require(await h.catalogue.job(job.rawValue))
        #expect(record.purpose == .keepers && record.destination == .photos && record.carrier == .staging)
        #expect(record.albumIdentifier == "ALBUM-K", "the album its saves went into")
        #expect(record.camera == h.camera && record.outcome == .completed && record.filesImported == 3)
        await h.cleanup()
    }

    @Test(arguments: [PhotosAuthorisation.denied, .restricted])
    func aRefusedSaveStopsTheJobForPhotosAccessAndStagesNothing(_ access: PhotosAuthorisation) async throws {
        let catalogue = InMemoryCatalogue()
        let h = Harness(catalogue: catalogue)
        let (entries, urls, bytes) = try staged(h)
        // Newest first: the lone JPG goes in; Photos refuses the pair's save (3311) and says why when asked.
        await h.photos.deny(from: 2)
        h.photosAccess.set(access)
        let job = try await h.start(.allNew, from: link(entries), to: keepersRoute(h))
        #expect(await h.waitFinished() == .photosAccessNeeded(access))

        // Nothing was staged: not into either staging folder, and Staging itself is untouched.
        #expect(await h.files.attempts == 0)
        #expect(await h.iCloud.attempts == 0)
        #expect(h.regularFiles(under: h.filesDirectory) == 0)
        for (url, data) in zip(urls, bytes) { #expect(try Data(contentsOf: url) == data) }
        #expect(h.trace.log.contains(.finished(.photosAccessNeeded(access))))
        #expect(!h.trace.log.contains { $0.isDestinationChanged })
        #expect(h.photosAccess.reads == 1)

        // The JPG has its row; the refused pair has none and isn't failed: it waits in Staging.
        #expect(await h.photos.committedNames == ["DSC00002.JPG"])
        let rows = await h.records()
        #expect(rows.map(\.identity.filename) == ["DSC00002.JPG"])
        let progress = await h.engine.currentProgress
        #expect(progress.filesImported == 1 && progress.filesFailed == 0 && progress.filesStaged == 0)
        // I9's marker rules: the refused commit's marker is gone, and the job's end leaves no download behind.
        #expect(await catalogue.pendingCommits().isEmpty)
        #expect(h.stagedFiles == 0)

        await h.engine.settleJobRecords()
        let record = try #require(await catalogue.job(job.rawValue))
        #expect(record.purpose == .keepers)
        #expect(record.outcome == .stopped(reason: "photosAccess"))
        #expect(record.filesImported == progress.filesImported && record.failedFiles.isEmpty)
        await h.cleanup()
    }

    /// Two saves in flight both refused: the job ends once, with nothing staged, and both files stay unsaved.
    @Test func twoRefusalsInFlightEndTheJobOnce() async throws {
        let catalogue = InMemoryCatalogue()
        let h = Harness(catalogue: catalogue, downloadsInFlight: 2)
        let card = h.singles(["A.JPG", "B.JPG"])
        let photos = DenyAllTogether(n: 2)
        h.photosAccess.set(.denied)
        try await h.start(.items(card), from: h.link(card), to: keepersRoute(h, to: photos))
        #expect(await h.waitFinished() == .photosAccessNeeded(.denied))
        await h.engine.settleJobRecords()
        #expect(h.trace.count { if case .finished = $0 { true } else { false } } == 1)
        #expect(await h.files.attempts == 0)
        #expect(await h.records().isEmpty)
        #expect(await catalogue.pendingCommits().isEmpty)
        #expect(await catalogue.jobs(camera: nil).count == 1)
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// A paused keepers job continued with Photos access turned off meanwhile is offered a staging route: refused, so
    /// it stays a keepers job and the next refusal stops it.
    @Test func aContinueNeverStagesAKeepersJob() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card)
        await link.script("A.JPG", .hold)
        try await h.start(.items(card), from: link, to: keepersRoute(h))
        let a = await link.nextHeldCall("A.JPG")
        try await h.engine.pause()
        try await h.engine.resume(to: h.stageRoute(reason: .photosDenied))
        #expect(h.trace.log.contains(.routeRefused(.staging(.photosDenied, Harness.onThisIPhone))))
        await h.photos.deny(from: 1)
        h.photosAccess.set(.denied)
        a.release()
        #expect(await h.waitFinished() == .photosAccessNeeded(.denied))
        #expect(await h.files.attempts == 0)
        await h.cleanup()
    }
}
