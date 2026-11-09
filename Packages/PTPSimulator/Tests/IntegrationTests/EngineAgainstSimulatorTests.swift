import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import PTPSimulator
import SimulatedLink
import Testing

/// The engine end to end against the simulated link, through its public surface only: a real `ImportEngine` on the
/// continuous clock, the in-memory catalogue and the real Files destination in a temporary Documents folder. The
/// engine's own tests cover its rules with fakes on a manual clock; these check that the rules hold against a link
/// that behaves like ImageCaptureCore (backlog sections 3 and 7). Photos isn't reachable on Linux or in a package
/// test, so every job goes to Files.
final class Bench {
    static let zone = TimeZone(identifier: "UTC")!
    let root: URL
    let staging: URL
    let documents: URL
    let catalogue = InMemoryCatalogue()
    let camera = CameraKey(rawValue: "simulated-a7c2")
    let engine: ImportEngine
    let files: FilesFolderDestination

    init(downloadsInFlight: Int = 1) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntegrationTests-\(UUID().uuidString)", isDirectory: true)
        staging = root.appendingPathComponent("staging", isDirectory: true)
        documents = root.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        engine = ImportEngine(catalogue: catalogue, settings: ImportSettings(downloadsInFlight: downloadsInFlight),
                              stagingDirectory: staging, timeZone: Bench.zone)
        files = FilesFolderDestination(documentsDirectory: documents, cameraName: "ILCE-7CM2")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var route: ImportRoute { .filesFolder(files, reason: .chosen) }

    func link(_ card: ScriptedCard, mode: CameraMode = .usb(.mtp)) -> SimulatedCameraLink {
        SimulatedCameraLink(card: card, mode: mode, timeZone: Bench.zone, chunkSize: 4096)
    }

    func start(_ link: SimulatedCameraLink, _ selection: ImportSelection = .allNew) async throws {
        try await link.open()
        try await engine.start(selection, from: link, camera: camera, to: route)
    }

    /// Waits (polling, up to 20 s) until the engine's state satisfies `condition`, and returns it.
    @discardableResult
    func waitFor(_ what: String = "state",
                 _ condition: @Sendable (ImportJobState) -> Bool) async throws -> ImportJobState {
        for _ in 0 ..< 2000 {
            let state = await engine.state
            if condition(state) { return state }
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = await engine.state
        Issue.record("timed out waiting for \(what); state is \(state)")
        return state
    }

    func waitFinished() async throws -> JobOutcome? {
        let state = try await waitFor("the job to finish") { if case .finished = $0 { true } else { false } }
        if case let .finished(outcome) = state { return outcome }
        return nil
    }

    /// The files in the camera's Files folder, by name.
    func importedFiles() -> [String: Data] {
        let folder = files.folderURL
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var out: [String: Data] = [:]
        for name in names { out[name] = try? Data(contentsOf: folder.appendingPathComponent(name)) }
        return out
    }

    func stagedFiles() -> Int {
        guard let e = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey])
        else { return 0 }
        var n = 0
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            n += 1
        }
        return n
    }

    func state(of item: CameraItem) async -> ObjectState? {
        guard let identity = item.identity(camera: camera, timeZone: Bench.zone) else { return nil }
        return await catalogue.states(of: [identity])[identity]
    }

    /// Checks that every object of `card` named in `names` was imported with exactly its scripted bytes.
    func expectImported(_ names: [String], from card: ScriptedCard, sourceLocation: SourceLocation = #_sourceLocation) {
        let imported = importedFiles()
        #expect(Set(imported.keys) == Set(names), sourceLocation: sourceLocation)
        for o in card.objects where names.contains(o.filename) {
            #expect(imported[o.filename] == ScriptedCard.content(of: o.handle, in: 0 ..< o.size),
                    "\(o.filename) bytes", sourceLocation: sourceLocation)
        }
    }
}

/// Three RAW+JPEG frames and a JPEG, about 40, 20 and 20 KB each (the real sizes scaled down by 1,000).
private func shoot() throws -> ScriptedCard {
    try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG, .rawPlusJPEG, .jpeg])).scaled(down: 1000)
}

@Suite("ImportEngine against the simulated link", .timeLimit(.minutes(1)))
struct EngineAgainstSimulatorTests {
    @Test func importsTheCardIntoFilesAndNothingTwice() async throws {
        let bench = Bench()
        let card = try shoot()
        let link = bench.link(card)
        try await bench.start(link)
        #expect(try await bench.waitFinished() == .completed)
        bench.expectImported(card.objects.map(\.filename), from: card)
        let progress = await bench.engine.currentProgress
        #expect(progress.filesDone == 7 && progress.filesTotal == 7 && progress.filesSkipped == 0)
        #expect(progress.bytesDone == card.objects.reduce(0) { $0 + $1.size })
        #expect(bench.stagedFiles() == 0)
        for item in try await link.list() { #expect(await bench.state(of: item) == .imported, "\(item.name)") }
        // Files are dated by their capture date.
        let first = bench.files.folderURL.appendingPathComponent("DSC00001.ARW")
        let modified = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date
        #expect(modified == PTPDateTime.parse("20261101T090000", defaultTimeZone: Bench.zone))

        // The camera takes two more frames; a new job takes only them.
        await link.shoot([.rawPlusJPEG])
        try await bench.engine.start(.allNew, from: link, camera: bench.camera, to: bench.route)
        #expect(try await bench.waitFinished() == .completed)
        #expect(await bench.engine.currentProgress.filesTotal == 2)
        let all = await link.card
        bench.expectImported(all.objects.map(\.filename), from: all)
        #expect(await link.bytesCalls.count == 9)
    }

    @Test func aSlowCatalogueHoldsTheJobUntilItIsListed() async throws {
        let bench = Bench()
        let card = try shoot()
        let link = bench.link(card)
        await link.holdCatalogue()
        try await bench.start(link)
        await link.waitForListCall()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await bench.engine.state == .running)
        #expect(await bench.engine.currentProgress.filesTotal == 0)
        #expect(await link.bytesCalls.isEmpty)
        await link.releaseCatalogue()
        #expect(try await bench.waitFinished() == .completed)
        bench.expectImported(card.objects.map(\.filename), from: card)
    }

    @Test func didSuspendPausesAndTheAppsReturnContinues() async throws {
        let bench = Bench()
        let card = try shoot()
        let link = bench.link(card)
        // The engine takes the newest first: the JPEG of the last frame.
        let newest = card.objects.last!.filename
        await link.script(newest, .holdAfter(4096))
        try await bench.start(link)
        await link.waitUntilHeld(newest)
        await link.appLeavesForeground()
        await link.suspend()
        try await bench.waitFor("the pause") { $0 == .paused(.appInBackground) }
        // The download in flight carries on once the session resumes, and is committed; nothing new starts while
        // the job is paused, and *resumed operations* alone doesn't continue it (decision 1).
        await link.release(newest)
        await link.resumeOperations()
        for _ in 0 ..< 200 where !bench.importedFiles().keys.contains(newest) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(bench.importedFiles().keys.sorted() == [newest])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.bytesCalls == [newest])
        #expect(await bench.engine.state == .paused(.appInBackground))
        try await bench.engine.resume(.appInBackground)
        #expect(try await bench.waitFinished() == .completed)
        bench.expectImported(card.objects.map(\.filename), from: card)
        #expect(await link.bytesCalls.count == 7)
    }

    @Test func aRemovalMidFileWaitsAndTheReplugCopiesItAgainFromItsStart() async throws {
        let bench = Bench()
        let card = try shoot()
        let link = bench.link(card)
        let victim = "DSC00003.ARW"
        await link.script(victim, .holdAfter(8192))
        try await bench.start(link)
        await link.waitUntilHeld(victim)
        await link.remove()
        try await bench.waitFor("the removal pause") { $0 == .paused(.cameraRemoved) }
        #expect(bench.stagedFiles() == 0) // the partial file was deleted
        #expect(!bench.importedFiles().keys.contains(victim))

        let again = await link.replugged()
        try await bench.engine.reconnect(again)
        #expect(try await bench.waitFinished() == .completed)
        bench.expectImported(card.objects.map(\.filename), from: card)
        // The interrupted file was asked for again, on the new link, from its start (decision 7).
        #expect(await again.bytesCalls.first == victim)
        #expect(await again.resumes.isEmpty) // USB doesn't resume: nothing continued a partial file
        #expect(await again.openCount == 1)
        #expect(await again.listCount == 1)
        #expect(await !link.delivered.contains(victim))
    }

    @Test func failuresFollowTheirOutcomes() async throws {
        let bench = Bench()
        let card = try shoot()
        let link = bench.link(card)
        // Busy: retried after 0.5 s and imported. Unreadable: skipped, the rest go on.
        await link.script("DSC00004.JPG", .fail(.busy))
        await link.script("DSC00002.JPG", .fail(.unreadableItem))
        await link.fail(.list, with: .noAnswer)
        try await bench.start(link)
        #expect(try await bench.waitFinished() == .completed)
        let names = card.objects.map(\.filename).filter { $0 != "DSC00002.JPG" }
        bench.expectImported(names, from: card)
        let progress = await bench.engine.currentProgress
        #expect(progress.filesSkipped == 1 && progress.filesFailed == 0 && progress.filesDone == 7)
        #expect(await link.bytesCalls.filter { $0 == "DSC00004.JPG" }.count == 2)
        #expect(await link.listCount == 2)
    }

    @Test func aShortFileIsCaughtBySizeAndFetchedAgain() async throws {
        let bench = Bench()
        let card = try shoot()
        let link = bench.link(card)
        await link.script("DSC00001.ARW", .deliverShort(100))
        try await bench.start(link)
        #expect(try await bench.waitFinished() == .completed)
        bench.expectImported(card.objects.map(\.filename), from: card)
        #expect(await link.bytesCalls.filter { $0 == "DSC00001.ARW" }.count == 2)
    }

    @Test func phoneStorageFullStopsTheJobAndKeepsWhatWasImported() async throws {
        let bench = Bench()
        let card = try shoot()
        let link = bench.link(card)
        await link.script("DSC00002.ARW", .fail(.phoneStorageFull))
        try await bench.start(link)
        #expect(try await bench.waitFinished() == .stopped(.phoneStorageFull))
        let imported = bench.importedFiles().keys
        #expect(!imported.contains("DSC00002.ARW") && imported.contains("DSC00004.JPG"))
        #expect(bench.stagedFiles() == 0)
    }

    @Test func remoteShootStopsTheJob() async throws {
        let bench = Bench()
        let link = bench.link(try shoot(), mode: .usb(.remoteShoot))
        try await bench.start(link)
        #expect(try await bench.waitFinished() == .stopped(.modeListsNoFiles))
        #expect(bench.importedFiles().isEmpty)
    }

    @Test func twoInFlightAgainstTheSimulator() async throws {
        let bench = Bench(downloadsInFlight: 2)
        let card = try #require(ScriptedCard.rawPlusJPEG(pairs: 10)).scaled(down: 1000)
        let link = bench.link(card)
        try await bench.start(link)
        #expect(try await bench.waitFinished() == .completed)
        bench.expectImported(card.objects.map(\.filename), from: card)
        // Two downloads really ran together, and never more.
        #expect(await link.maxBytesInFlight == 2)
    }
}
