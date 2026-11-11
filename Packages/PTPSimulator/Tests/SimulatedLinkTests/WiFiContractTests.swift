import CameraTransport
import Foundation
import PTPKit
import PTPSimulator
import SimulatedLink
import Synchronization
import Testing

private let utc = TimeZone(identifier: "UTC")!

/// Two RAW+JPEG frames and a JPEG, about 40, 20 and 20 KB.
private func smallCard() throws -> ScriptedCard {
    try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG, .jpeg])).scaled(down: 1000)
}

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("WiFiContractTests-\(UUID().uuidString)",
                                                                  isDirectory: true)
}

private func failure<T>(of task: Task<T, any Error>) async -> CameraLinkFailure? {
    do {
        _ = try await task.value
        return nil
    } catch {
        return error as? CameraLinkFailure
    }
}

/// The next event the stream delivers; nil if it finishes first. Blocks without a timer, so a slow runner can't
/// make it give up early (the suite's time limit catches a hang).
private func nextEvent(_ iterator: inout AsyncStream<CameraLinkEvent>.Iterator) async -> CameraLinkEvent? {
    await iterator.next()
}

private final class Recorder: Sendable {
    private let checkpoints = Mutex<[PartialDownload]>([])
    private let progress = Mutex<[UInt64]>([])
    var checkpointed: [PartialDownload] { checkpoints.withLock { $0 } }
    var progressed: [UInt64] { progress.withLock { $0 } }
    var onCheckpoint: @Sendable (PartialDownload) -> Void { { [self] p in self.checkpoints.withLock { $0.append(p) } } }
    var onProgress: @Sendable (UInt64) -> Void { { [self] v in self.progress.withLock { $0.append(v) } } }
}

@Suite("Simulated link: the Wi-Fi contract", .timeLimit(.minutes(1)))
struct WiFiContractTests {
    // MARK: Capabilities and IDs

    @Test func capabilitiesDefaultToTheModesCarrier() async throws {
        let card = try smallCard()
        #expect(SimulatedCameraLink(card: card).capabilities == .usb)
        #expect(SimulatedCameraLink(card: card, mode: .usb(.massStorage)).capabilities == .usb)
        for route in WiFiRoute.allCases {
            #expect(SimulatedCameraLink(card: card, mode: .wifi(route)).capabilities == .wifi)
        }
        var custom = CameraLinkCapabilities.wifi
        custom.resumesPartialFiles = false
        let link = SimulatedCameraLink(card: card, mode: .wifi(.cameraNetwork), capabilities: custom)
        #expect(link.capabilities == custom)
        #expect(await link.replugged().capabilities == custom)
    }

    @Test func itemIDsLastAReopenOnlyWhereTheCapabilitySaysSo() async throws {
        let card = try smallCard()
        for (mode, lasts) in [(CameraMode.wifi(.cameraNetwork), true), (.usb(.mtp), false)] {
            let first = SimulatedCameraLink(card: card, mode: mode, timeZone: utc)
            try await first.open()
            let before = try await first.list()
            let second = await first.replugged()
            try await second.open()
            let after = try await second.list()
            #expect((before.map(\.id) == after.map(\.id)) == lasts, "\(mode)")
            // The old ID names the file on the new link exactly when IDs last.
            if lasts {
                #expect(try await second.info(of: before[0].id) == after[0])
            } else {
                await #expect(throws: CameraLinkFailure.self) { _ = try await second.info(of: before[0].id) }
            }
        }
    }

    // MARK: Resume

    /// A Wi-Fi link whose first RAW is held part-way, and the folder it writes into.
    private func heldDownload(cutAt cut: UInt64) async throws
        -> (link: SimulatedCameraLink, item: CameraItem, object: ScriptedCard.Object, folder: URL,
            recorder: Recorder, download: Task<URL, any Error>) {
        let card = try smallCard()
        let link = SimulatedCameraLink(card: card, mode: .wifi(.cameraNetwork), timeZone: utc, chunkSize: 4096)
        try await link.open()
        let item = try await link.list()[0]
        let object = card.objects[0]
        let folder = temporaryFolder()
        await link.script(object.filename, .holdAfter(cut))
        let recorder = Recorder()
        let download = Task {
            try await link.bytes(of: item.id, into: folder, resuming: nil, checkpoint: recorder.onCheckpoint,
                                 progress: recorder.onProgress)
        }
        await link.waitUntilHeld(object.filename)
        return (link, item, object, folder, recorder, download)
    }

    @Test func aCutFileResumesAtItsCheckpointAndMatchesWhole() async throws {
        let size = try smallCard().objects[0].size
        let cut = size * 54 / 100
        let (link, item, object, folder, recorder, download) = try await heldDownload(cutAt: cut)
        defer { try? FileManager.default.removeItem(at: folder) }

        // The session is lost 54 % in: the call ends, the partial file stays.
        await link.loseSession()
        #expect(await failure(of: download)?.outcome == .retryOnReconnect)
        let checkpoints = recorder.checkpointed
        let last = try #require(checkpoints.last)
        #expect(last.bytesWritten == cut)
        #expect(checkpoints.map(\.bytesWritten) == checkpoints.map(\.bytesWritten).sorted())
        #expect(Set(checkpoints.map(\.file)).count == 1)
        #expect(last.bytesWritten < size)                              // never for the whole file
        let onDisk = try Data(contentsOf: last.file)
        #expect(onDisk == ScriptedCard.content(of: object.handle, in: 0 ..< cut))

        // The link opens again with the same IDs; the engine's identity check passes (name and size), and it resumes.
        try await link.open()
        let again = try await link.info(of: item.id)
        #expect(again.name == item.name && again.size == item.size)
        let resumed = Recorder()
        let url = try await link.bytes(of: item.id, into: folder, resuming: last, checkpoint: resumed.onCheckpoint,
                                       progress: resumed.onProgress)
        #expect(url == last.file)
        #expect(try Data(contentsOf: url) == ScriptedCard.content(of: object.handle, in: 0 ..< size))
        #expect(await link.resumes == [.init(filename: object.filename, offset: cut)])
        // Progress counts bytes in the file, so a resumed copy starts above its offset; checkpoints too.
        #expect(try #require(resumed.progressed.first) > cut)
        #expect(resumed.progressed.last == size)
        #expect(resumed.checkpointed.allSatisfy { $0.bytesWritten > cut && $0.bytesWritten < size })
    }

    @Test func aResumeCutsTheFileBackToItsOffset() async throws {
        let size = try smallCard().objects[0].size
        let cut = size / 2
        let (link, item, object, folder, _, download) = try await heldDownload(cutAt: cut)
        defer { try? FileManager.default.removeItem(at: folder) }
        await link.loseSession()
        _ = await failure(of: download)
        let file = folder.appendingPathComponent(object.filename)
        // Bytes the engine never confirmed: the file is longer than the offset it kept, and the extra is wrong.
        let kept = cut - 1000
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xEE, count: 500))
        try handle.close()
        try await link.open()
        let url = try await link.bytes(of: item.id, into: folder, resuming: PartialDownload(file: file, bytesWritten: kept),
                                       checkpoint: { _ in }, progress: { _ in })
        #expect(try Data(contentsOf: url) == ScriptedCard.content(of: object.handle, in: 0 ..< size))
        #expect(await link.resumes.map(\.offset) == [kept])
    }

    @Test func aPartialTheLinkCantContinueIsCopiedAgainFromZero() async throws {
        let card = try smallCard()
        let link = SimulatedCameraLink(card: card, mode: .wifi(.otherNetwork), timeZone: utc, chunkSize: 4096)
        try await link.open()
        let item = try await link.list()[0]
        let object = card.objects[0]
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Missing file.
        let missing = folder.appendingPathComponent("missing.part")
        var url = try await link.bytes(of: item.id, into: folder,
                                       resuming: PartialDownload(file: missing, bytesWritten: 100),
                                       checkpoint: { _ in }, progress: { _ in })
        #expect(url == missing)
        #expect(try Data(contentsOf: url) == ScriptedCard.content(of: object.handle, in: 0 ..< object.size))
        // Shorter than its offset.
        let short = folder.appendingPathComponent("short.part")
        try Data(repeating: 1, count: 10).write(to: short)
        url = try await link.bytes(of: item.id, into: folder, resuming: PartialDownload(file: short, bytesWritten: 100),
                                   checkpoint: { _ in }, progress: { _ in })
        #expect(try Data(contentsOf: url) == ScriptedCard.content(of: object.handle, in: 0 ..< object.size))
        // An offset past the end of the camera's file.
        let long = folder.appendingPathComponent("long.part")
        try Data(repeating: 1, count: Int(object.size) + 50).write(to: long)
        url = try await link.bytes(of: item.id, into: folder,
                                   resuming: PartialDownload(file: long, bytesWritten: object.size + 10),
                                   checkpoint: { _ in }, progress: { _ in })
        #expect(try Data(contentsOf: url) == ScriptedCard.content(of: object.handle, in: 0 ..< object.size))
        #expect(await link.resumes.map(\.offset) == [0, 0, 0])
    }

    @Test func aLinkWithoutResumeIgnoresThePartialAndNeverCheckpoints() async throws {
        let card = try smallCard()
        let link = SimulatedCameraLink(card: card, mode: .usb(.massStorage), timeZone: utc, chunkSize: 4096)
        try await link.open()
        let item = try await link.list()[0]
        let object = card.objects[0]
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let partial = PartialDownload(file: folder.appendingPathComponent("elsewhere.part"), bytesWritten: 8192)
        let recorder = Recorder()
        let url = try await link.bytes(of: item.id, into: folder, resuming: partial,
                                       checkpoint: recorder.onCheckpoint, progress: recorder.onProgress)
        #expect(url == folder.appendingPathComponent(object.filename))   // in the folder, not at the partial
        #expect(try Data(contentsOf: url) == ScriptedCard.content(of: object.handle, in: 0 ..< object.size))
        #expect(recorder.checkpointed.isEmpty)
        #expect(recorder.progressed.first == 4096)                        // from 0, not from the offset
        #expect(await link.resumes.isEmpty)
    }

    @Test func aScriptedFailureLeavesTheCallersPartialFileAndTheResumeLogAlone() async throws {
        let card = try smallCard()
        let link = SimulatedCameraLink(card: card, mode: .wifi(.cameraNetwork), timeZone: utc, chunkSize: 4096)
        try await link.open()
        let item = try await link.list()[0]
        let object = card.objects[0]
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(object.filename)
        let content = ScriptedCard.content(of: object.handle, in: 0 ..< 10_000)
        try content.write(to: file)

        await link.script(object.filename, .fail(.busy))
        let partial = PartialDownload(file: file, bytesWritten: 6000)
        do {
            _ = try await link.bytes(of: item.id, into: folder, resuming: partial, checkpoint: { _ in },
                                     progress: { _ in })
            Issue.record("the scripted failure didn't throw")
        } catch {
            #expect(error.kind == .busy)
        }
        // The file was not cut back to the offset, and no resume was recorded for a call that never began one.
        #expect(try Data(contentsOf: file) == content)
        #expect(await link.resumes.isEmpty)
        // The next call, with no failure scripted, resumes as usual.
        _ = try await link.bytes(of: item.id, into: folder, resuming: partial, checkpoint: { _ in }, progress: { _ in })
        #expect(await link.resumes == [.init(filename: object.filename, offset: 6000)])
    }

    // MARK: Wi-Fi events

    @Test func aRemovedCardFailsEveryCallAsCardUnavailableUntilItIsBack() async throws {
        let link = SimulatedCameraLink(card: try smallCard(), mode: .wifi(.cameraNetwork), timeZone: utc)
        var events = link.events.makeAsyncIterator()
        try await link.open()
        let item = try await link.list()[0]
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        await link.removeStore()
        await link.removeStore() // already gone: no second event
        #expect(await nextEvent(&events) == .storeRemoved)
        #expect(await link.isStoreAvailable == false)
        let calls: [(String, @Sendable () async throws -> Void)] = [
            ("list", { _ = try await link.list() }),
            ("info", { _ = try await link.info(of: item.id) }),
            ("thumbnail", { _ = try await link.thumbnail(of: item.id) }),
            ("bytes", { _ = try await link.bytes(of: item.id, into: folder) }),
        ]
        for (name, call) in calls {
            let failed = await failure(of: Task { try await call() })
            #expect(failed?.kind == .cardUnavailable, "\(name)")
            #expect(failed?.outcome == .retryOnReconnect, "\(name)")
        }
        #expect(await link.bytesCalls.isEmpty)

        await link.addStore()
        await link.addStore()
        #expect(await nextEvent(&events) == .storeAdded)   // the second removal sent nothing in between
        #expect(try await link.list().count == 5)
        #expect(try await link.bytes(of: item.id, into: folder).lastPathComponent == item.name)
    }

    @Test func aCardRemovedMidFileStopsTheCopyAtItsNextChunk() async throws {
        let size = try smallCard().objects[0].size
        let (link, item, object, folder, _, download) = try await heldDownload(cutAt: size / 2)
        defer { try? FileManager.default.removeItem(at: folder) }
        await link.removeStore()
        await link.release(object.filename)
        let failed = await failure(of: download)
        #expect(failed?.kind == .cardUnavailable)
        // Nothing was lost: with the card back, the same file copies in full.
        await link.addStore()
        let url = try await link.bytes(of: item.id, into: folder)
        #expect(try Data(contentsOf: url) == ScriptedCard.content(of: object.handle, in: 0 ..< size))
    }

    @Test func aLostSessionEndsPendingCallsButTheLinkOpensAgain() async throws {
        let link = SimulatedCameraLink(card: try smallCard(), mode: .wifi(.cameraNetwork), timeZone: utc)
        var events = link.events.makeAsyncIterator()
        try await link.open()
        let items = try await link.list()

        // A listing waiting on the catalogue ends as disconnected instead of waiting on.
        await link.holdCatalogue()
        let listing = Task { try await link.list() }
        await link.waitForListCall(2)
        await link.loseSession()
        #expect(await nextEvent(&events) == .sessionLost(generation: 1))
        #expect(await failure(of: listing)?.outcome == .retryOnReconnect)
        #expect(await link.isOpen == false)
        await #expect(throws: CameraLinkFailure.self) { _ = try await link.list() }

        // Not removed: the events are still open, and the same link opens again.
        await link.releaseCatalogue()
        try await link.open()
        #expect(try await link.list().map(\.id) == items.map(\.id))
        await link.removeStore()
        #expect(await nextEvent(&events) == .storeRemoved)
        #expect(await link.openCount == 2)
    }

    @Test func aLostSessionEndsADownloadWithItsPartialFileLeft() async throws {
        let size = try smallCard().objects[0].size
        let (link, _, object, folder, _, download) = try await heldDownload(cutAt: size / 3)
        defer { try? FileManager.default.removeItem(at: folder) }
        await link.loseSession()
        let failed = await failure(of: download)
        #expect(failed?.kind == .disconnected)
        let partial = try Data(contentsOf: folder.appendingPathComponent(object.filename))
        #expect(partial.count == Int(size / 3))
    }

    @Test func aDownloadParkedBetweenChunksDoesNotContinueIntoTheNextSession() async throws {
        let size = try smallCard().objects[0].size
        let cut = size / 3
        let (link, item, object, folder, recorder, download) = try await heldDownload(cutAt: cut)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Suspended, the released download writes one more chunk and then waits for the suspension to end.
        await link.suspend()
        await link.release(object.filename)
        while (recorder.progressed.last ?? 0) <= cut { await Task.yield() }

        // The session is lost and opens again before the parked call wakes: the old call must not carry on into it.
        await link.loseSessionAndReopen()
        await link.resumeOperations()
        let failed = await failure(of: download)
        #expect(failed?.kind == .disconnected)
        #expect(await link.delivered.isEmpty)
        let written = try Data(contentsOf: folder.appendingPathComponent(object.filename))
        #expect(UInt64(written.count) < size)

        // The new session works: the file copies in full.
        #expect(try await link.bytes(of: item.id, into: folder).lastPathComponent == object.filename)
        #expect(await link.delivered == [object.filename])
    }

    @Test func aListingParkedOnTheCatalogueEndsWhenTheSessionIsLostAndOpenedAgain() async throws {
        let link = SimulatedCameraLink(card: try smallCard(), mode: .wifi(.cameraNetwork), timeZone: utc)
        try await link.open()
        _ = try await link.list()
        await link.holdCatalogue()
        let listing = Task { try await link.list() }
        await link.waitForListCall(2)
        await link.loseSessionAndReopen()
        await link.releaseCatalogue()
        #expect(await failure(of: listing)?.kind == .disconnected)
        #expect(try await link.list().count == 5)   // the new session lists as usual
    }

    @Test func theLocalNetworkPromptHoldsOpenAndIsNeverAFailure() async throws {
        let link = SimulatedCameraLink(card: try smallCard(), mode: .wifi(.cameraNetwork))
        var events = link.events.makeAsyncIterator()
        await link.holdForLocalNetworkPrompt()
        let opening = Task { try await link.open() }
        #expect(await nextEvent(&events) == .waitingForLocalNetwork)
        #expect(await link.isOpen == false)
        await link.allowLocalNetwork()
        try await opening.value
        #expect(await link.isOpen)
        #expect(await link.openCount == 1)
        // Once answered the prompt doesn't come back for the next open.
        await link.loseSession()
        _ = await nextEvent(&events)
        try await link.open()
        #expect(await link.openCount == 2)
    }

    @Test func closingWhileThePromptIsUnansweredFailsTheOpen() async throws {
        let link = SimulatedCameraLink(card: try smallCard(), mode: .wifi(.cameraNetwork))
        var events = link.events.makeAsyncIterator()
        await link.holdForLocalNetworkPrompt()
        let opening = Task { try await link.open() }
        #expect(await nextEvent(&events) == .waitingForLocalNetwork)
        await link.close()
        #expect(await failure(of: opening) == CameraLinkFailure(.disconnected, detail: "open: the link is closed"))
    }

    @Test func aCancelledOpenWaitingForThePromptEndsWhenCancellationIsHonoured() async throws {
        let link = SimulatedCameraLink(card: try smallCard(), mode: .wifi(.cameraNetwork), honoursCancellation: true)
        var events = link.events.makeAsyncIterator()
        await link.holdForLocalNetworkPrompt()
        let opening = Task { try await link.open() }
        #expect(await nextEvent(&events) == .waitingForLocalNetwork)
        opening.cancel()
        #expect(await failure(of: opening) == CameraLinkFailure(.noAnswer, detail: "open: cancelled"))
    }
}
