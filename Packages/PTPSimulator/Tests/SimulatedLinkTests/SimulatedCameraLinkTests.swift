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
    FileManager.default.temporaryDirectory.appendingPathComponent("SimulatedLinkTests-\(UUID().uuidString)",
                                                                  isDirectory: true)
}

/// Collects a link's events from the moment it is made.
private final class EventLog: Sendable {
    private let events = Mutex<[CameraLinkEvent]>([])
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)
    private let finished = Mutex(false)

    init(_ stream: AsyncStream<CameraLinkEvent>) {
        let t = Task { [self] in
            for await e in stream { self.events.withLock { $0.append(e) } }
            self.finished.withLock { $0 = true }
        }
        task.withLock { $0 = t }
    }

    var all: [CameraLinkEvent] { events.withLock { $0 } }
    var isFinished: Bool { finished.withLock { $0 } }

    func wait(until condition: @escaping ([CameraLinkEvent], Bool) -> Bool) async {
        for _ in 0 ..< 2000 where !condition(all, isFinished) { try? await Task.sleep(for: .milliseconds(1)) }
    }
}

/// The failure a task ended with, nil if it returned.
private func failure<T>(of task: Task<T, any Error>) async -> CameraLinkFailure? {
    do {
        _ = try await task.value
        return nil
    } catch {
        return error as? CameraLinkFailure
    }
}

private final class ProgressLog: Sendable {
    private let values = Mutex<[UInt64]>([])
    var all: [UInt64] { values.withLock { $0 } }
    var callback: @Sendable (UInt64) -> Void { { [self] v in self.values.withLock { $0.append(v) } } }
}

@Suite("Simulated camera link", .timeLimit(.minutes(1)))
struct SimulatedCameraLinkTests {
    @Test func listsTheCardAsItems() async throws {
        let card = try smallCard()
        let link = SimulatedCameraLink(card: card, timeZone: utc)
        try await link.open()
        let items = try await link.list()
        #expect(items.map(\.name) == card.objects.map(\.filename))
        #expect(items.map(\.size) == card.objects.map(\.size))
        #expect(items.allSatisfy { $0.folder == "DCIM/100MSDCF" })
        #expect(items.map(\.format) == [.raw, .jpeg, .raw, .jpeg, .jpeg])
        #expect(items[0].captureDate == PTPDateTime.parse("20261101T090000", defaultTimeZone: utc))
        #expect(items[2].captureDate == PTPDateTime.parse("20261101T090002", defaultTimeZone: utc))
        #expect(try await link.info(of: items[3].id) == items[3])
        #expect(link.descriptor.mode == .usb(.mtp) && link.descriptor.name == "ILCE-7CM2")
        let thumb = try await link.thumbnail(of: items[0].id)
        #expect(thumb.count == 6_584 && thumb.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func callsNeedAnOpenLink() async throws {
        let link = SimulatedCameraLink(card: try smallCard())
        await #expect(throws: CameraLinkFailure(.disconnected, detail: "list: the link isn't open")) {
            _ = try await link.list()
        }
        try await link.open()
        await link.close()
        await #expect(throws: CameraLinkFailure(.disconnected, detail: "list: the link is closed")) {
            _ = try await link.list()
        }
    }

    @Test func aClosedLinkCantBeOpenedAgain() async throws {
        let link = SimulatedCameraLink(card: try smallCard())
        let log = EventLog(link.events)
        try await link.open()
        await link.close()
        // As USBLink: closing is final, since the events have finished; a replug is a new link.
        await #expect(throws: CameraLinkFailure(.disconnected, detail: "open: the link is closed")) {
            try await link.open()
        }
        #expect(await link.openCount == 1)
        #expect(await link.isOpen == false)
        await log.wait { _, finished in finished }
        #expect(log.isFinished)
        let again = await link.replugged()
        try await again.open()
        #expect(try await again.list().count == 5)
    }

    @Test func closingWhileAnOpenWaitsOutASuspensionFailsIt() async throws {
        let link = SimulatedCameraLink(card: try smallCard())
        await link.suspend()
        let opening = Task { try await link.open() }
        try await Task.sleep(for: .milliseconds(20))
        await link.close()
        #expect(await failure(of: opening) == CameraLinkFailure(.disconnected, detail: "open: the link is closed"))
    }

    @Test func bytesAreTheCardsWithProgress() async throws {
        let card = try smallCard()
        let link = SimulatedCameraLink(card: card, chunkSize: 4096)
        try await link.open()
        let items = try await link.list()
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let progress = ProgressLog()
        let url = try await link.bytes(of: items[0].id, into: folder, progress: progress.callback)
        #expect(url.lastPathComponent == "DSC00001.ARW" && url.deletingLastPathComponent().lastPathComponent == folder.lastPathComponent)
        let o = card.objects[0]
        #expect(try Data(contentsOf: url) == ScriptedCard.content(of: o.handle, in: 0 ..< o.size))
        #expect(progress.all.last == o.size && progress.all == progress.all.sorted() && progress.all.count > 2)
        #expect(await link.bytesCalls == ["DSC00001.ARW"])
        #expect(await link.delivered == ["DSC00001.ARW"])
    }

    @Test func aSlowCatalogueHoldsTheListing() async throws {
        let link = SimulatedCameraLink(card: try smallCard())
        await link.holdCatalogue()
        try await link.open()
        let listing = Task { try await link.list() }
        await link.waitForListCall()
        #expect(await link.isCatalogueHeld)
        await link.releaseCatalogue()
        #expect(try await listing.value.count == 5)
    }

    @Test func suspensionHoldsCallsAndDownloadsUntilResumed() async throws {
        let card = try smallCard()
        let link = SimulatedCameraLink(card: card, chunkSize: 1000)
        let log = EventLog(link.events)
        try await link.open()
        let items = try await link.list()
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await link.script("DSC00001.ARW", .holdAfter(5000))
        let download = Task { try await link.bytes(of: items[0].id, into: folder) }
        await link.waitUntilHeld("DSC00001.ARW")
        await link.appLeavesForeground()
        await link.suspend()
        await link.release("DSC00001.ARW")
        let listing = Task { try await link.list() }
        try await Task.sleep(for: .milliseconds(50))
        // Nothing finishes while suspended.
        #expect(await link.delivered.isEmpty)
        #expect(await link.listCount == 1)
        await link.resumeOperations()
        let url = try await download.value
        #expect(try Data(contentsOf: url).count == Int(card.objects[0].size))
        #expect(try await listing.value.count == 5)
        await log.wait { events, _ in events.count >= 3 }
        #expect(log.all == [.willSuspend, .didSuspend, .resumedOperations])
    }

    @Test func removalFailsPendingCallsAndFinishesTheEvents() async throws {
        let link = SimulatedCameraLink(card: try smallCard(), chunkSize: 1000)
        let log = EventLog(link.events)
        try await link.open()
        let items = try await link.list()
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await link.script("DSC00001.JPG", .holdAfter(3000))
        let download = Task { try await link.bytes(of: items[1].id, into: folder) }
        await link.waitUntilHeld()
        await link.holdCatalogue()
        let listing = Task { try await link.list() }
        await link.waitForListCall(2)
        await link.remove()
        let failed = await failure(of: download)
        #expect(failed?.kind == .disconnected && failed?.outcome == .retryOnReconnect)
        #expect(await failure(of: listing)?.kind == .disconnected)
        // The partial file is left behind, as ImageCaptureCore can leave one; the engine deletes it.
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("DSC00001.JPG").path))
        await #expect(throws: CameraLinkFailure.self) { try await link.open() }
        await log.wait { _, finished in finished }
        #expect(log.all == [.removed] && log.isFinished)
        // A stream read after the removal is finished at once.
        var it = link.events.makeAsyncIterator()
        #expect(await it.next() == nil)
    }

    @Test func eventsAreLiveNotReplayed() async throws {
        let link = SimulatedCameraLink(card: try smallCard())
        await link.appLeavesForeground()
        let log = EventLog(link.events)
        await link.suspend()
        await log.wait { events, _ in !events.isEmpty }
        #expect(log.all == [.didSuspend])
    }

    @Test func aReplugIsANewLinkWithNewIDs() async throws {
        let link = SimulatedCameraLink(card: try smallCard())
        try await link.open()
        let before = try await link.list()
        await link.delete(["DSC00002.JPG"])
        await link.remove()
        let again = await link.replugged()
        #expect(again.generation == 2 && again.descriptor == link.descriptor)
        try await again.open()
        let after = try await again.list()
        #expect(after.map(\.name) == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.ARW", "DSC00003.JPG"])
        #expect(Set(after.map(\.id)).isDisjoint(with: before.map(\.id)))
        await #expect(throws: CameraLinkFailure(.itemNotFound, detail: "info: not on the card")) {
            _ = try await again.info(of: before[0].id)
        }
    }

    @Test func injectedFailuresAndScriptedSteps() async throws {
        let card = try smallCard()
        let link = SimulatedCameraLink(card: card)
        await link.fail(.open, with: .busy)
        await #expect(throws: CameraLinkFailure(.busy, detail: "open: injected")) { try await link.open() }
        try await link.open()
        await link.fail(.list, with: .noAnswer, times: 2)
        for _ in 0 ..< 2 { await #expect(throws: CameraLinkFailure.self) { _ = try await link.list() } }
        let items = try await link.list()
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await link.script("DSC00001.ARW", .fail(.unreadableItem), .deliverShort(100))
        await #expect(throws: CameraLinkFailure(.unreadableItem, detail: "bytes: scripted")) {
            _ = try await link.bytes(of: items[0].id, into: folder)
        }
        let short = try await link.bytes(of: items[0].id, into: folder)
        #expect(try Data(contentsOf: short).count == 100)
        let full = try await link.bytes(of: items[0].id, into: folder)
        #expect(try Data(contentsOf: full).count == Int(card.objects[0].size))
        await link.fail(.thumbnail, with: .busy)
        await #expect(throws: CameraLinkFailure.self) { _ = try await link.thumbnail(of: items[0].id) }
    }

    @Test func remoteShootListsNoFiles() async throws {
        let link = SimulatedCameraLink(card: try smallCard(), mode: .usb(.remoteShoot))
        try await link.open()
        let failed = await failure(of: Task { try await link.list() })
        #expect(failed?.kind == .modeListsNoFiles && failed?.outcome == .stopJob)
    }

    @Test func cancellationIsIgnoredUnlessHonoured() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for honours in [false, true] {
            let link = SimulatedCameraLink(card: try smallCard(), honoursCancellation: honours, chunkSize: 1000)
            try await link.open()
            let items = try await link.list()
            await link.script("DSC00001.ARW", .holdAfter(2000))
            let download = Task { try await link.bytes(of: items[0].id, into: folder) }
            await link.waitUntilHeld()
            download.cancel()
            if honours {
                #expect(await failure(of: download)?.kind == .noAnswer)
            } else {
                try await Task.sleep(for: .milliseconds(20))
                // ImageCaptureCore ignores cancellation: the call is still held, and finishes when released.
                #expect(await link.release("DSC00001.ARW"))
                _ = try await download.value
            }
        }
    }

    @Test func honouredCancellationEndsCallsWaitingOutASuspensionOrTheCatalogue() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for honours in [false, true] {
            let link = SimulatedCameraLink(card: try smallCard(), honoursCancellation: honours, chunkSize: 1000)
            try await link.open()
            let items = try await link.list()
            await link.suspend()
            let download = Task { try await link.bytes(of: items[0].id, into: folder) }
            let thumbnail = Task { try await link.thumbnail(of: items[0].id) }
            try await Task.sleep(for: .milliseconds(20))
            download.cancel()
            thumbnail.cancel()
            if honours {
                #expect(await failure(of: download) == CameraLinkFailure(.noAnswer, detail: "bytes: cancelled"))
                #expect(await failure(of: thumbnail) == CameraLinkFailure(.noAnswer, detail: "thumbnail: cancelled"))
                #expect(await link.bytesCalls.isEmpty)
            } else {
                try await Task.sleep(for: .milliseconds(20))
                // ImageCaptureCore ignores cancellation: both still wait, and finish after the return.
                #expect(await link.bytesCalls.isEmpty)
                await link.resumeOperations()
                _ = try await download.value
                _ = try await thumbnail.value
            }
            await link.resumeOperations()

            await link.holdCatalogue()
            let listing = Task { try await link.list() }
            await link.waitForListCall(2)
            listing.cancel()
            if honours {
                #expect(await failure(of: listing) == CameraLinkFailure(.noAnswer, detail: "list: cancelled"))
            } else {
                try await Task.sleep(for: .milliseconds(20))
                await link.releaseCatalogue()
                #expect(try await listing.value.count == 5)
            }
            await link.releaseCatalogue()
            // The link still works after the cancelled calls.
            #expect(try await link.list().count == 5)
        }
    }

    @Test func infoAnswersDuringASuspension() async throws {
        let link = SimulatedCameraLink(card: try smallCard())
        try await link.open()
        let items = try await link.list()
        await link.suspend()
        #expect(try await link.info(of: items[1].id) == items[1])
    }

    @Test func shootingAddsFilesForTheNextListing() async throws {
        let link = SimulatedCameraLink(card: try smallCard())
        try await link.open()
        let added = await link.shoot([.rawPlusJPEG])
        #expect(added.map(\.name) == ["DSC00004.ARW", "DSC00004.JPG"])
        #expect(try await link.list().suffix(2) == added[...])
        #expect(await link.item(named: "DSC00004.JPG") == added[1])
    }
}
