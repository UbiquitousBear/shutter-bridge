import CameraTransport
import Foundation
import Testing
@testable import AppUI

// Browse over Wi-Fi when its link goes away under the screen (bench 19.1, 9 Nov): the card stays with a strip, a lost
// session reopens the same link in front, the return to the app reconnects once, thumbnails are asked again on the new
// link, wait while the link is reached, and are counted in the bench log without names or handles. Every wait is bounded.

/// A Wi-Fi link whose opens, listings and thumbnails a test scripts and counts. Its events reach every reader (as
/// `IPLink`'s do), and closing it finishes them.
actor ScriptedWiFiLink: CameraLink, ReusingListing {
    nonisolated let descriptor = CameraDescriptor(id: .init(rawValue: "scripted-wifi"), name: "Camera",
                                                  mode: .wifi(.cameraNetwork))
    nonisolated let capabilities: CameraLinkCapabilities = .wifi
    nonisolated var events: AsyncStream<CameraLinkEvent> { fanOut.stream() }
    private let fanOut = TestFanOut<CameraLinkEvent>()
    private let items: [CameraItem]
    private(set) var opens = 0
    private(set) var plainLists = 0
    private(set) var reusingLists: [[CameraItem.ID]] = []
    private(set) var thumbnailsAsked: [CameraItem.ID] = []
    private(set) var closed = false
    /// Opens after the first fail with this (a session that can't be reopened).
    private var reopenFailure: CameraLinkFailure?
    /// Thumbnails fail with these, each once, by file.
    private var thumbnailFailures: [CameraItem.ID: [CameraLinkFailure]] = [:]
    private var listGate: AsyncStream<Void>?

    init(items: [CameraItem]) { self.items = items }

    func send(_ event: CameraLinkEvent) { fanOut.send(event) }
    func set(reopenFailure: CameraLinkFailure?) { self.reopenFailure = reopenFailure }
    func failThumbnail(of id: CameraItem.ID, with failures: [CameraLinkFailure]) { thumbnailFailures[id] = failures }
    /// Listing waits until `releaseList()` (or its task's cancellation).
    func holdList() -> AsyncStream<Void>.Continuation {
        let (stream, sink) = AsyncStream<Void>.makeStream()
        listGate = stream
        return sink
    }

    func open() throws(CameraLinkFailure) {
        opens += 1
        if closed { throw CameraLinkFailure(.disconnected, detail: "open: closed") }
        if opens > 1, let reopenFailure { throw reopenFailure }
    }

    func list() async throws(CameraLinkFailure) -> [CameraItem] {
        plainLists += 1
        if let gate = listGate {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
        }
        return items.newestFirst()
    }

    func list(reusing known: [CameraItem]) throws(CameraLinkFailure) -> [CameraItem] {
        reusingLists.append(known.map(\.id))
        return items.newestFirst()
    }

    func info(of item: CameraItem.ID) throws(CameraLinkFailure) -> CameraItem {
        guard let found = items.first(where: { $0.id == item }) else { throw CameraLinkFailure(.itemNotFound) }
        return found
    }

    func thumbnail(of item: CameraItem.ID) throws(CameraLinkFailure) -> Data {
        thumbnailsAsked.append(item)
        if closed { throw CameraLinkFailure(.disconnected, detail: "thumbnail: closed") }
        if var failures = thumbnailFailures[item], !failures.isEmpty {
            let failure = failures.removeFirst()
            thumbnailFailures[item] = failures
            throw failure
        }
        return Data([0xFF, 0xD8, 0xFF])
    }

    func bytes(of item: CameraItem.ID, into directory: URL, resuming: PartialDownload?,
               checkpoint: @escaping @Sendable (PartialDownload) -> Void,
               progress: @escaping @Sendable (UInt64) -> Void) throws(CameraLinkFailure) -> URL {
        throw CameraLinkFailure(.unreadableItem, detail: "bytes: not in these tests")
    }

    func close() {
        closed = true
        fanOut.finish()
    }
}

/// The links a Browse model is handed in turn, and how many times it asked. A nil entry fails the open.
final class LinkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [(any CameraLink)?]
    private var asked = 0
    private var gate: AsyncStream<Void>?
    private var release: AsyncStream<Void>.Continuation?

    init(_ links: [(any CameraLink)?]) { queue = links }

    var opens: Int { lock.withLock { asked } }

    /// The next open waits until `releaseOpen()` (or its task's cancellation).
    func holdOpen() {
        let (stream, sink) = AsyncStream<Void>.makeStream()
        lock.withLock { gate = stream; release = sink }
    }

    func releaseOpen() {
        let sink = lock.withLock { () -> AsyncStream<Void>.Continuation? in
            defer { gate = nil; release = nil }
            return release
        }
        sink?.finish()
    }

    func next() async throws(CameraLinkFailure) -> any CameraLink {
        let held = lock.withLock { () -> AsyncStream<Void>? in
            asked += 1
            return gate
        }
        if let held {
            var iterator = held.makeAsyncIterator()
            _ = await iterator.next()
        }
        let link = lock.withLock { () -> (any CameraLink)?? in queue.isEmpty ? nil : queue.removeFirst() }
        guard let link, let link else { throw CameraLinkFailure(.noAnswer, detail: "wifi: scripted failure") }
        return link
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    private var asked = 0
    init(_ value: Bool) { self.value = value }
    func set(_ value: Bool) { lock.withLock { self.value = value } }
    var asks: Int { lock.withLock { asked } }
    func ask() -> Bool { lock.withLock { asked += 1; return value } }
}

/// A clock for `now` the test moves by hand.
final class HandClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_794_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@MainActor
@Suite("Browse over Wi-Fi: the link going away under the screen")
struct BrowseReconnectTests {
    let camera = CameraDescriptor(id: .init(rawValue: "wifi-a"), name: "Camera", mode: .wifi(.cameraNetwork))
    let card = [item("DSC00001.ARW", at: 10, size: 1_000), item("DSC00002.ARW", at: 20, size: 1_000),
                item("DSC00003.ARW", at: 30, size: 1_000)]

    struct Harness {
        let model: BrowseModel
        let links: LinkQueue
        let log: RecordingLog
        let leases: LinkLeases
        let run: Task<Void, Never>

        func stop() async {
            run.cancel()
            #expect(await bounded(run) != nil)
        }
    }

    func start(_ links: [(any CameraLink)?], camera: CameraDescriptor? = nil, openFailureText: String? = nil,
               opensAgain: Flag? = nil, clock: HandClock? = nil, holdFirstOpen: Bool = false) -> Harness {
        let queue = LinkQueue(links)
        if holdFirstOpen { queue.holdOpen() }
        let log = RecordingLog()
        let leases = LinkLeases()
        var again: (@Sendable () async -> Bool)?
        if let opensAgain { again = { opensAgain.ask() } }
        var now: @Sendable () -> Date = { Date() }
        if let clock { now = { clock.now } }
        let model = BrowseModel(
            camera: camera ?? self.camera,
            openLink: { () async throws(CameraLinkFailure) -> any CameraLink in try await queue.next() },
            services: services(log: log),
            openFailureText: { openFailureText },
            opensAgainOnReturn: again,
            onGone: { _ in },
            leases: leases,
            now: now)
        let run = Task { await model.run() }
        return Harness(model: model, links: queue, log: log, leases: leases, run: run)
    }

    var ids: [CameraItem.ID] { card.newestFirst().map(\.id) }

    // MARK: The link closed by a leave

    @Test func aLinkClosedUnderTheCardShowsTheStripAndTheReturnReconnectsKeepingSelectionAndThumbnails() async {
        let first = ScriptedWiFiLink(items: card)
        let second = ScriptedWiFiLink(items: card)
        let h = start([first, second])
        #expect(await eventuallyLong { h.model.phase == .listed })
        #expect(h.model.linkGeneration == 1)
        #expect(await h.model.thumbnail(for: ids[0]) != nil)
        h.model.tap(card[0])
        // The app goes to the background with Browse open and no import: the session leaves and closes the link.
        h.model.scenePhaseChanged(.background)
        await first.close()
        #expect(await eventuallyLong { h.model.interruption == .disconnected })
        #expect(h.model.phase == .listed)
        #expect(h.model.sections.flatMap(\.items).count == 3)
        #expect(h.model.selection == [card[0].id])
        #expect(!h.model.canImport && !h.model.offersJPEGActions(card[1]))
        // Nothing reconnects while the app is away.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.links.opens == 1)
        #expect(await h.model.thumbnail(for: ids[1]) == nil)
        // Back in front: one reconnect, the card listed again from what is known, the selection and thumbnails kept.
        h.model.scenePhaseChanged(.active)
        #expect(await eventuallyLong { h.model.interruption == nil && h.model.linkGeneration == 2 })
        #expect(h.links.opens == 2)
        #expect(await second.reusingLists == [ids])
        #expect(h.model.selection == [card[0].id])
        #expect(await h.model.thumbnail(for: ids[0]) != nil)   // from the cache
        #expect(await h.model.thumbnail(for: ids[1]) != nil)
        #expect(await second.thumbnailsAsked == [ids[1]])
        let lines = h.log.lines
        #expect(lines.contains { $0.hasPrefix("browse: the link ended under the screen (events finished) ") })
        #expect(lines.contains("browse: reconnecting (back in front)"))
        #expect(lines.contains { $0.hasPrefix("browse: reconnected: a link in ") })
        await h.stop()
        #expect(await second.closed)
    }

    @Test func aReconnectThatFailsWaitsForReconnectAndIsTriedOncePerReturn() async {
        let first = ScriptedWiFiLink(items: card)
        let third = ScriptedWiFiLink(items: card)
        let h = start([first, nil, third], openFailureText: "Open the camera again.")
        #expect(await eventuallyLong { h.model.phase == .listed })
        h.model.scenePhaseChanged(.background)
        await first.close()
        #expect(await eventuallyLong { h.model.interruption == .disconnected })
        h.model.scenePhaseChanged(.active)
        #expect(await eventuallyLong { h.links.opens == 2 && h.model.interruption == .disconnected })
        #expect(h.model.interruptionDetail == "Open the camera again.")
        // Once per return: an inactive and active again (no trip to the background) doesn't try again.
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.links.opens == 2)
        // Reconnect does.
        h.model.reconnect()
        #expect(await eventuallyLong { h.model.interruption == nil && h.model.linkGeneration == 2 })
        #expect(h.links.opens == 3)
        #expect(h.model.interruptionDetail == nil)
        await h.stop()
    }

    // MARK: The session lost

    @Test func aLostSessionInFrontReopensTheSameLinkAndListsAgain() async {
        let link = ScriptedWiFiLink(items: card)
        let h = start([link])
        #expect(await eventuallyLong { h.model.phase == .listed })
        #expect(await h.model.thumbnail(for: ids[0]) != nil)
        await link.send(.sessionLost)
        #expect(await eventuallyLong { h.model.linkGeneration == 2 && h.model.interruption == nil })
        #expect(await link.opens == 2)
        #expect(await link.reusingLists == [ids])
        #expect(h.links.opens == 1)   // the same link: nothing prepared again
        #expect(await h.model.thumbnail(for: ids[2]) != nil)
        #expect(h.log.lines.contains("browse: reconnecting (the session was lost; reopening the same link)"))
        await h.stop()
    }

    @Test func aLostSessionThatDoesntReopenShowsTheStripAndReconnectPreparesANewLink() async {
        let first = ScriptedWiFiLink(items: card)
        let second = ScriptedWiFiLink(items: card)
        await first.set(reopenFailure: CameraLinkFailure(.disconnected, detail: "open: PTP/IP linkLost"))
        let h = start([first, second])
        #expect(await eventuallyLong { h.model.phase == .listed })
        await first.send(.sessionLost)
        #expect(await eventuallyLong { h.model.interruption == .disconnected && h.model.canRetry == false })
        #expect(await first.closed)   // let go: Browse was its only holder
        #expect(h.log.lines.contains { $0.hasPrefix("browse: the link ended under the screen (sessionLost)") })
        h.model.reconnect()
        #expect(await eventuallyLong { h.model.interruption == nil && h.model.linkGeneration == 2 })
        #expect(h.links.opens == 2)
        await h.stop()
    }

    @Test func aLostSessionUnderAnImportIsLeftToTheImportsRecovery() async {
        let link = ScriptedWiFiLink(items: card)
        let h = start([link])
        #expect(await eventuallyLong { h.model.phase == .listed })
        h.leases.acquire(link)   // the import
        await link.send(.sessionLost)
        #expect(await eventuallyLong { h.log.lines.contains("browse: link event sessionLost") })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await link.opens == 1)
        #expect(h.model.interruption == nil)
        await h.stop()
        await h.leases.release(link)
    }

    @Test func aLostSessionWithTheAppAwayLetsTheLinkGoAndTheReturnReconnects() async {
        let first = ScriptedWiFiLink(items: card)
        let second = ScriptedWiFiLink(items: card)
        let h = start([first, second])
        #expect(await eventuallyLong { h.model.phase == .listed })
        h.model.scenePhaseChanged(.background)
        await first.send(.sessionLost)
        #expect(await eventuallyLong { h.model.interruption == .disconnected })
        #expect(await first.opens == 1)   // not reopened from the background
        h.model.scenePhaseChanged(.active)
        #expect(await eventuallyLong { h.model.interruption == nil && h.model.linkGeneration == 2 })
        #expect(h.links.opens == 2)
        await h.stop()
    }

    // MARK: Opening

    @Test func aWiFiCameraConnectsFirstAndReadsOnlyOnceTheLinkIsInHand() async {
        let clock = HandClock()
        let link = ScriptedWiFiLink(items: card)
        let releaseList = await link.holdList()
        let h = start([link], clock: clock, holdFirstOpen: true)
        let began = clock.now
        #expect(await waitUntil { h.links.opens == 1 })
        #expect(h.model.phase == .connecting(since: began))
        clock.advance(40)   // the join took 40 s
        h.links.releaseOpen()
        // Reading the Card and its time so far start when the link has opened, not at the join.
        #expect(await eventuallyLong { h.model.phase == .reading(since: began.addingTimeInterval(40)) })
        releaseList.finish()
        #expect(await eventuallyLong { h.model.phase == .listed })
        await h.stop()
    }

    @Test func aUSBCameraReadsFromTheStartAndStopsWhenItsLinkEnds() async {
        let usb = CameraDescriptor(id: .init(rawValue: "usb"), name: "Untitled", mode: .usb(.massStorage))
        let link = FakeLink(items: card)
        let h = start([link], camera: usb)
        #expect(await eventuallyLong { h.model.phase == .listed })
        await link.close()
        // As before: the screen's run ends with its link, with no strip and nothing reconnected.
        #expect(await bounded(h.run) != nil)
        #expect(h.model.interruption == nil && h.links.opens == 1)
        h.model.scenePhaseChanged(.background)
        h.model.scenePhaseChanged(.active)
        #expect(h.links.opens == 1)
    }

    @Test func tryAgainAfterAFailedOpenPreparesTheLinkAgain() async {
        let link = ScriptedWiFiLink(items: card)
        let h = start([nil, link], openFailureText: "The camera didn't answer.")
        #expect(await eventuallyLong { h.model.phase == .failed("The camera didn't answer.") })
        #expect(h.model.canRetry)
        #expect(h.model.failedTitle == WiFiWording.failedTitle)
        h.model.retry()
        #expect(await eventuallyLong { h.model.phase == .listed })
        #expect(h.links.opens == 2 && !h.model.canReopen)
        #expect(h.log.lines.contains("browse: opening again (Try Again)"))
        await h.stop()
    }

    @Test func aFailedOpenOpensAgainOnTheReturnOnlyWhenDiscoverySaysSoAndOncePerReturn() async {
        let link = ScriptedWiFiLink(items: card)
        let opensAgain = Flag(false)
        let h = start([nil, link], openFailureText: WiFiWording.needsAppToJoin, opensAgain: opensAgain)
        #expect(await eventuallyLong { h.model.phase == .failed(WiFiWording.needsAppToJoin) })
        // Discovery says no: nothing.
        h.model.scenePhaseChanged(.background)
        h.model.scenePhaseChanged(.active)
        #expect(await waitUntil { opensAgain.asks == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.links.opens == 1)
        // The next return, discovery says yes (the join needed the app in front): one open.
        opensAgain.set(true)
        h.model.scenePhaseChanged(.background)
        h.model.scenePhaseChanged(.active)
        #expect(await eventuallyLong { h.model.phase == .listed })
        #expect(h.links.opens == 2 && opensAgain.asks == 2)
        await h.stop()
    }

    // MARK: Thumbnails

    @Test func aThumbnailAskedWhileConnectingWaitsAndIsAnsweredOnceListed() async {
        let link = ScriptedWiFiLink(items: card)
        let h = start([link], holdFirstOpen: true)
        #expect(await waitUntil { h.links.opens == 1 })
        let id = ids[1]
        let asked = Task { await h.model.thumbnail(for: id) }
        try? await Task.sleep(for: .milliseconds(20))
        h.links.releaseOpen()
        let data = await bounded(asked)
        #expect(data == .some(Data([0xFF, 0xD8, 0xFF])))
        await h.stop()
    }

    @Test func aThumbnailWaitEndsWithTheCellsTask() async {
        let h = start([ScriptedWiFiLink(items: card)], holdFirstOpen: true)
        #expect(await waitUntil { h.links.opens == 1 })
        let id = ids[0]
        let asked = Task { await h.model.thumbnail(for: id) }
        try? await Task.sleep(for: .milliseconds(20))
        asked.cancel()
        let answer = await bounded(asked)
        #expect(answer == .some(nil))
        h.links.releaseOpen()
        await h.stop()
    }

    @Test func onlyAThumbnailTheCameraCanNeverGiveIsNotAskedAgain() async {
        let link = ScriptedWiFiLink(items: card)
        await link.failThumbnail(of: ids[0], with: [CameraLinkFailure(.unreadableItem, detail: "thumbnail: OperationNotSupported")])
        await link.failThumbnail(of: ids[1], with: [CameraLinkFailure(.disconnected, detail: "thumbnail: PTP/IP closed")])
        let h = start([link])
        #expect(await eventuallyLong { h.model.phase == .listed })
        #expect(await h.model.thumbnail(for: ids[0]) == nil)
        #expect(await h.model.thumbnail(for: ids[0]) == nil)
        #expect(await h.model.thumbnail(for: ids[1]) == nil)
        #expect(await h.model.thumbnail(for: ids[1]) != nil)
        #expect(await link.thumbnailsAsked == [ids[0], ids[1], ids[1]])
        await h.stop()
    }

    @Test func theThumbnailCountsAreLoggedWithoutNamesHandlesOrIdentifiers() async {
        let link = ScriptedWiFiLink(items: card)
        await link.failThumbnail(of: ids[0], with: [CameraLinkFailure(.unreadableItem, detail: "thumbnail: OperationNotSupported")])
        let h = start([link])
        #expect(await eventuallyLong { h.model.phase == .listed })
        _ = await h.model.thumbnail(for: ids[0])
        let data = await h.model.thumbnail(for: ids[1])
        h.model.thumbnailShown(data ?? Data(), decoded: false, for: ids[1])
        h.model.thumbnailShown(data ?? Data(), decoded: false, for: ids[1])   // the same file again: counted once
        await h.stop()
        let lines = h.log.lines
        #expect(lines.contains("browse: thumbnail failed (first on this screen): unreadableItem (thumbnail: OperationNotSupported)"))
        #expect(lines.contains("browse: a thumbnail of 3 B didn't decode (starts FFD8: yes)"))
        #expect(lines.contains("browse: thumbnails (the screen went): asked 2: ok 1, failed 1 (unreadableItem 1), skipped "
            + "no-link 0, not-listed 0, cancelled 0, undecodable 1"))
        let mine = lines.filter { $0.hasPrefix("browse: thumbnail") || $0.hasPrefix("browse: a thumbnail")
            || $0.hasPrefix("browse: the link") || $0.hasPrefix("browse: reconnect") || $0.hasPrefix("browse: the screen") }
        #expect(!mine.isEmpty)
        for line in mine {
            for file in card {
                #expect(!line.contains(file.name) && !line.contains(file.id.rawValue), "\"\(line)\" names a file")
            }
            #expect(!line.contains(camera.id.rawValue), "\"\(line)\" holds the camera's ID")
        }
    }

    @Test func everyHundredAskedTheCountsAreLogged() async {
        let link = ScriptedWiFiLink(items: card)
        await link.failThumbnail(of: ids[0], with: Array(repeating: CameraLinkFailure(.busy), count: 120))
        let h = start([link])
        #expect(await eventuallyLong { h.model.phase == .listed })
        for _ in 0..<100 { _ = await h.model.thumbnail(for: ids[0]) }
        #expect(h.log.lines.contains { $0.hasPrefix("browse: thumbnails (every 100 asked): asked 100: ok 0, failed 100 (busy 100)") })
        await h.stop()
    }

    @Test func theCellsTaskIsKeyedByTheLinkGeneration() {
        let id = CameraItem.ID(rawValue: "a")
        let same = ThumbnailTaskID(item: id, generation: 1) == ThumbnailTaskID(item: id, generation: 1)
        let next = ThumbnailTaskID(item: id, generation: 1) == ThumbnailTaskID(item: id, generation: 2)
        #expect(same && !next)
    }
}
