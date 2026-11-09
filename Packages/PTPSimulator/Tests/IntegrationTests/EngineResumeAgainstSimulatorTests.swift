import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import PTPSimulator
import SimulatedLink
import Testing

/// The engine's Wi-Fi rules (W7) end to end against `SimulatedCameraLink` playing the Wi-Fi link's contract
/// (`CameraLinkCapabilities.wifi`: one transaction, 0x9211-style resume, handles that survive a reopen; cancellation
/// honoured, as `IPLink` honours it), through the engine's public surface on the continuous clock. Every imported
/// file is compared byte for byte with the camera's (stronger than the SHA-256 the plan names, which needs no
/// CryptoKit this way).
@Suite("ImportEngine resume and Wi-Fi pauses against the simulated link", .timeLimit(.minutes(1)))
struct EngineResumeAgainstSimulatorTests {
    private func wifiLink(_ card: ScriptedCard, chunkSize: UInt64 = 4096) -> SimulatedCameraLink {
        SimulatedCameraLink(card: card, mode: .wifi(.cameraNetwork), timeZone: Bench.zone, honoursCancellation: true,
                            chunkSize: chunkSize)
    }

    private func shoot() throws -> ScriptedCard {
        try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG, .rawPlusJPEG, .jpeg])).scaled(down: 1000)
    }

    private func jobID(_ bench: Bench) async throws -> ImportJobID {
        try #require(await bench.engine.currentJobID)
    }

    /// Polls the catalogue (up to 10 s) until `item`'s row satisfies `condition`.
    private func waitForRow(_ bench: Bench, _ item: CameraItem, _ what: String,
                            _ condition: @Sendable (CatalogueRecord?) -> Bool) async throws -> CatalogueRecord? {
        let identity = try #require(item.identity(camera: bench.camera, timeZone: Bench.zone))
        for _ in 0 ..< 1000 {
            let row = try await bench.catalogue.record(for: identity)
            if condition(row) { return row }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)")
        return try await bench.catalogue.record(for: identity)
    }

    /// The 2 Nov 23:10 run: a read cut at 54 % by the Wi-Fi going, a reopen that finds the same handle, and the
    /// rest read from the saved offset; the copy matches the camera's file. The app's reopen hands its listing over,
    /// so the engine doesn't list again.
    @Test func aFileCutAt54PercentResumesAtTheCheckpoint() async throws {
        let bench = Bench()
        let card = try shoot()
        let link = wifiLink(card)
        let victim = try #require(card.objects.first { $0.filename == "DSC00003.ARW" })
        let cut = victim.size * 54 / 100
        await link.script(victim.filename, .holdAfter(cut))
        try await bench.start(link)
        let job = try await jobID(bench)
        await link.waitUntilHeld(victim.filename)

        await link.loseSession()
        try await bench.waitFor("the lost session") { $0 == .paused(.cameraUnreachable) }
        #expect(await bench.engine.currentProgress.filesFailed == 0)
        #expect(!bench.importedFiles().keys.contains(victim.filename))
        #expect(bench.stagedFiles() == 1) // the partial file is kept for the resume

        try await link.open()
        let known = try await link.list()
        try await bench.engine.reconnect(job, to: link, knownItems: known)
        #expect(try await bench.waitFinished() == .completed)
        bench.expectImported(card.objects.map(\.filename), from: card)
        #expect(await link.resumes == [SimulatedCameraLink.Resume(filename: victim.filename, offset: cut)])
        #expect(await link.listCount == 2) // the engine's first listing and the app's reopen; none after it
        #expect(await link.bytesCalls.filter { $0 == victim.filename }.count == 2)
        #expect(bench.stagedFiles() == 0)
        for item in known { #expect(await bench.state(of: item) == .imported, "\(item.name)") }
    }

    /// A 40 MiB file: the catalogue gets the 16 MiB checkpoint while it downloads; on expiry the app flushes (the
    /// row moves to the latest offset), pauses and stops the transfer; Continue reconnects, and every file is
    /// written exactly once, the big one continued from the flushed offset.
    @Test func sixteenMiBCheckpointsAndExpiryThenContinueWritesEachFileOnce() async throws {
        let bench = Bench()
        let mib: UInt64 = 1024 * 1024
        let card = ScriptedCard(objects: [
            .init(handle: PTPObjectHandle(rawValue: 1), folder: "DCIM/100MSDCF", filename: "DSC00001.ARW",
                  size: 40 * mib, captureDateRaw: "20261101T090000", format: .sonyARW),
            .init(handle: PTPObjectHandle(rawValue: 2), folder: "DCIM/100MSDCF", filename: "DSC00002.JPG",
                  size: 3 * mib + 17, captureDateRaw: "20261101T090002", format: .exifJPEG),
        ])
        let link = wifiLink(card, chunkSize: mib)
        await link.script("DSC00001.ARW", .holdAfter(22 * mib))
        try await bench.start(link)
        let job = try await jobID(bench)
        let raw = try #require(await link.item(named: "DSC00001.ARW"))

        let checkpoint = try await waitForRow(bench, raw, "the 16 MiB checkpoint") { $0?.resumeOffset == 16 * mib }
        #expect(checkpoint?.state == .partial)
        let partial = try #require(checkpoint?.partialFile(in: bench.staging))
        #expect(checkpoint?.tempURL?.relativePath.hasPrefix("Partials/") == true)
        #expect(FileManager.default.fileExists(atPath: partial.path))

        await link.waitUntilHeld("DSC00001.ARW")
        // iOS closes the sockets in the background (POSIX 53 after 4.8 s on 5 Nov), then the continued task expires:
        // the app flushes, then pauses. (Lost first here so the test can see each step: the expiry shows first.)
        await link.loseSession()
        try await bench.waitFor("the lost session") { $0 == .paused(.cameraUnreachable) }
        await bench.engine.flushCheckpoints()
        let identity = try #require(raw.identity(camera: bench.camera, timeZone: Bench.zone))
        #expect(try await bench.catalogue.record(for: identity)?.resumeOffset == 22 * mib)
        try await bench.engine.pause(.taskExpired)
        #expect(await bench.engine.state == .paused(.taskExpired))

        try await bench.engine.reconnect(job, to: link)
        #expect(try await bench.waitFinished() == .completed)
        bench.expectImported(["DSC00001.ARW", "DSC00002.JPG"], from: card)
        #expect(await link.resumes == [SimulatedCameraLink.Resume(filename: "DSC00001.ARW", offset: 22 * mib)])
        #expect(await link.delivered.sorted() == ["DSC00001.ARW", "DSC00002.JPG"])
        #expect(try await bench.catalogue.record(for: identity)?.state == .imported)
        #expect(bench.stagedFiles() == 0)
    }

    /// The camera drops its card: the job pauses for the card and no file counts as failed (the spike's 3 Nov 15:13
    /// copy counted 82); the card's return lists it again and the file in flight continues.
    @Test func aLostCardFailsNothingAndItsReturnCarriesOn() async throws {
        let bench = Bench()
        let card = try shoot()
        let link = wifiLink(card)
        let victim = "DSC00002.ARW"
        await link.script(victim, .holdAfter(8192))
        try await bench.start(link)
        await link.waitUntilHeld(victim)

        await link.removeStore()
        try await bench.waitFor("the lost card") { $0 == .paused(.cardUnavailable) }
        let progress = await bench.engine.currentProgress
        #expect(progress.filesFailed == 0 && progress.filesSkipped == 0)

        await link.addStore()
        #expect(try await bench.waitFinished() == .completed)
        bench.expectImported(card.objects.map(\.filename), from: card)
        #expect(await bench.engine.currentProgress.filesFailed == 0)
        #expect(await link.resumes == [SimulatedCameraLink.Resume(filename: victim, offset: 8192)])
        #expect(await link.listCount == 2)
    }

    /// The card goes, then the session (the camera's Wi-Fi goes about 6 s later, 3 and 4 Nov); after the reconnect
    /// the card is still away, so the job waits for it, and carries on when it is back.
    @Test func aLostCardThenSessionWaitsAndCarriesOnAfterTheReconnect() async throws {
        let bench = Bench()
        let card = try shoot()
        let link = wifiLink(card)
        let victim = "DSC00004.JPG"
        await link.script(victim, .holdAfter(4096))
        try await bench.start(link)
        let job = try await jobID(bench)
        await link.waitUntilHeld(victim)

        await link.removeStore()
        try await bench.waitFor("the lost card") { $0 == .paused(.cardUnavailable) }
        await link.loseSession()
        try await bench.waitFor("the lost session") { $0 == .paused(.cameraUnreachable) }

        try await bench.engine.reconnect(job, to: link)
        try await bench.waitFor("the card still away") { $0 == .paused(.cardUnavailable) }
        await link.addStore()
        #expect(try await bench.waitFinished() == .completed)
        bench.expectImported(card.objects.map(\.filename), from: card)
        #expect(await bench.engine.currentProgress.filesFailed == 0)
        #expect(await link.resumes == [SimulatedCameraLink.Resume(filename: victim, offset: 4096)])
    }

    /// One transaction at a time over Wi-Fi, whatever the setting.
    @Test func wifiIsCappedAtOneInFlight() async throws {
        let bench = Bench(downloadsInFlight: 2)
        let card = try #require(ScriptedCard.rawPlusJPEG(pairs: 5)).scaled(down: 1000)
        let link = wifiLink(card)
        try await bench.start(link)
        #expect(try await bench.waitFinished() == .completed)
        bench.expectImported(card.objects.map(\.filename), from: card)
        #expect(await link.maxBytesInFlight == 1)
    }
}
