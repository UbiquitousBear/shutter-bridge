import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import Testing
@testable import AppUI

// Shamil, 20 Nov: a Wi-Fi Browse hidden behind another tab lets go once it is idle, after an idle timeout
// (`BrowseTiming.hiddenIdleTimeout`), so the camera's 3-minute stay starts as if the person had left; shown again within
// the stay it reopens with no join; after the stay, it offers Reconnect (no join without a tap). A join or an import in
// progress carries on behind the tab, and USB Browse keeps its card. The screen's part is played by the test as `LiveApp`
// plays it: the path set, the model made and `start()` called as it appears, `hidden()` as another tab hides it. The idle
// timer is the test's (`IdleTimerControl`), fired by hand, so nothing waits 30 s.

private let peripheral = PeripheralID(UUID(uuidString: "1F2E3D4C-5B6A-4978-8695-A4B3C2D1E0F1")!)

/// An idle timer the test fires: each `sleep` waits for `fire()` or its task's cancellation.
final class IdleTimerControl: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var next = 0
    private var startedCount = 0

    var timer: BrowseIdleTimer {
        BrowseIdleTimer(timeout: BrowseTiming.hiddenIdleTimeout) { [self] _ in try await self.sleep() }
    }

    /// How many timers have been started.
    var started: Int { lock.withLock { startedCount } }
    /// How many timers are waiting now (a cancelled one no longer is).
    var pending: Int { lock.withLock { waiters.count } }

    /// Every timer waiting now runs out.
    func fire() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        for waiter in all { waiter.resume() }
    }

    private func sleep() async throws {
        let id = lock.withLock { () -> Int in
            next += 1
            startedCount += 1
            return next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    waiters[id] = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

@MainActor
@Suite("Browse hidden behind another tab: a Wi-Fi Browse lets go when idle", .timeLimit(.minutes(1)))
struct HiddenBrowseTests {
    static let idleLine = "browse: hidden and idle for 30 s; letting the Wi-Fi link go (the stay can start)"
    let files = [item("DSC00001.ARW", at: 10, size: 1_000), item("DSC00002.ARW", at: 20, size: 2_000)]

    struct Bench {
        let app: AppModel
        let source: WiFiCameraSource
        let connecting: FakeConnecting
        let log: RecordingLog
        let timer: IdleTimerControl
        let descriptor: CameraDescriptor
        let session: FakeSession
        @MainActor var leases: LinkLeases { app.leases }
    }

    /// A paired camera through the real source and composite, its session answering with `links` in turn (the last
    /// repeats), with the app active and the camera listed.
    func bench(_ links: [FakeWiFiLink]) async -> Bench {
        let catalogue = InMemoryCatalogue()
        let connecting = FakeConnecting()
        let source = WiFiCameraSource(catalogue: catalogue, connecting: connecting)
        let status = WiFiImportModel(source: source)
        let log = RecordingLog()
        let app = AppModel(
            discovery: CompositeDiscovery(sources: [ScriptedDiscovery(), source]), services: services(log: log),
            catalogue: catalogue, engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
            settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
            destinations: FakeDestinations(), cameraKey: CameraKeys.keying(material: { _ in nil }),
            wifi: WiFiSupport(source: source, status: status))
        let timer = IdleTimerControl()
        app.cameras.browseIdleTimer = timer.timer
        let descriptor = await source.registerPairedCamera(peripheral: peripheral)
        let session = connecting.session(for: WiFiCameraEntry(
            descriptor: descriptor, key: nil, peripheral: peripheral, guid: UUID())) as! FakeSession
        session.script(links.map { .success($0) })
        await app.scenePhaseChanged(.active)
        #expect(await eventuallyLong { app.cameras.cameras.map(\.id) == [descriptor.id] })
        return Bench(app: app, source: source, connecting: connecting, log: log, timer: timer, descriptor: descriptor,
                     session: session)
    }

    /// What `LiveApp` does when the person opens the camera: the path, then the screen's model, started as it appears.
    func open(_ b: Bench) -> BrowseModel {
        b.app.cameras.path = [b.descriptor]
        let browse = b.app.browseModel(for: b.descriptor)
        browse.start()
        return browse
    }

    /// Opened, listed, hidden, and let go when the idle timer fires: the stay has started.
    func letGo(_ b: Bench) async -> BrowseModel {
        let browse = open(b)
        #expect(await eventuallyLong { browse.showsLiveCard })
        browse.hidden()
        #expect(await waitUntil { b.timer.pending == 1 })
        b.timer.fire()
        #expect(await waitUntil { b.session.count("importFinished") == 1 })
        #expect(await eventuallyLong { browse.interruption == .disconnected })
        return browse
    }

    func leave(_ b: Bench, _ browse: BrowseModel) async {
        b.app.cameras.path = []
        #expect(await eventuallyLong { !browse.isStarted })
    }

    // MARK: Letting go

    /// On main a hidden Browse kept its lease until Back, so the stay never started behind another tab.
    @Test func aHiddenListedWiFiBrowseLetsGoAfterTheTimeoutAndTheStayStarts() async throws {
        let first = FakeWiFiLink(items: files)
        let b = await bench([first])
        let browse = open(b)
        #expect(await eventuallyLong { browse.showsLiveCard })
        browse.hidden()
        #expect(await waitUntil { b.timer.pending == 1 })
        // Nothing until the timeout: the link is held and the session is ready.
        #expect(b.leases.holders(of: first) == 1)
        #expect(b.session.count("importFinished") == 0)
        b.timer.fire()
        // Browse let go of its lease, as leaving it would: the link closed and the session started the stay.
        #expect(await waitUntil { b.session.count("importFinished") == 1 })
        #expect(await first.closed)
        #expect(b.leases.holders(of: first) == 0)
        #expect(b.log.lines.contains(Self.idleLine))
        // The run, the path and the card stay as they are, with the disconnected strip.
        #expect(browse.isStarted)
        #expect(b.app.cameras.path.map(\.id) == [b.descriptor.id])
        #expect(browse.phase == .listed)
        #expect(await eventuallyLong { browse.interruption == .disconnected })
        #expect(b.session.count("prepare") == 1)
        await leave(b, browse)
    }

    @Test func shownAgainBeforeTheTimeoutKeepsTheLink() async throws {
        let first = FakeWiFiLink(items: files)
        let b = await bench([first])
        let browse = open(b)
        #expect(await eventuallyLong { browse.showsLiveCard })
        browse.hidden()
        #expect(await waitUntil { b.timer.pending == 1 })
        browse.start()   // shown again
        #expect(await waitUntil { b.timer.pending == 0 })
        b.timer.fire()   // nothing is waiting: nothing happens
        try await Task.sleep(for: .milliseconds(200))
        #expect(b.session.count("importFinished") == 0)
        #expect(await !first.closed)
        #expect(b.leases.holders(of: first) == 1)
        #expect(browse.interruption == nil)
        #expect(!b.log.lines.contains(Self.idleLine))
        // Hidden again: a fresh timer, which runs its full time from now.
        browse.hidden()
        #expect(await waitUntil { b.timer.pending == 1 })
        #expect(b.timer.started == 2)
        await leave(b, browse)
        #expect(await waitUntil { b.timer.pending == 0 })
    }

    /// A join under way carries on behind the tab: no timer runs until the link is open and the card listed.
    @Test func hiddenWhileJoiningLetsGoOnlyOnceConnectedListedAndIdleForTheTimeout() async throws {
        let first = FakeWiFiLink(items: files)
        let b = await bench([first])
        b.session.set(phase: .joining)
        b.session.holdPrepare()
        let browse = open(b)
        #expect(await waitUntil { b.session.preparesStarted == 1 })
        browse.hidden()
        try await Task.sleep(for: .milliseconds(200))
        #expect(b.timer.started == 0)
        #expect(b.session.count("leave") == 0)
        #expect(await b.source.isConnecting(b.descriptor.id))
        // The camera answers; Browse reads the card, still hidden: no timer while it does.
        await first.holdListing()
        b.session.set(phase: .ready)
        b.session.releasePrepare()
        #expect(await eventuallyLong { await first.listCount == 1 })
        #expect(await eventuallyLong { if case .reading = browse.phase { true } else { false } })
        try await Task.sleep(for: .milliseconds(200))
        #expect(b.timer.started == 0)
        #expect(b.session.count("importFinished") == 0)
        // The card is listed: now the timer starts.
        await first.releaseListing()
        #expect(await eventuallyLong { browse.showsLiveCard })
        #expect(await waitUntil { b.timer.pending == 1 })
        #expect(b.session.count("importFinished") == 0)
        b.timer.fire()
        #expect(await waitUntil { b.session.count("importFinished") == 1 })
        #expect(b.session.count("prepare") == 1)
        await leave(b, browse)
    }

    /// An import holds its own lease: Browse lets go of its own, and the stay starts only when the job ends.
    @Test func lettingGoWhileAnImportRunsKeepsTheImportsLinkAndTheStayFollowsTheJob() async throws {
        let first = FakeWiFiLink(items: files)
        await first.holdBytes()
        let b = await bench([first])
        let browse = open(b)
        #expect(await eventuallyLong { browse.showsLiveCard })
        browse.selectAllNew()
        await browse.importSelected()
        #expect(b.app.importer.isActive)
        browse.hidden()
        #expect(await waitUntil { b.timer.pending == 1 })
        b.timer.fire()
        #expect(await eventuallyLong { b.leases.holders(of: first) == 1 })   // the job's
        #expect(await eventuallyLong { browse.interruption == .disconnected })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await !first.closed)
        #expect(b.session.count("importFinished") == 0)
        await first.releaseBytes()
        #expect(await eventuallyLong {
            await b.app.importer.refresh()
            return b.app.importer.isFinished
        })
        #expect(await waitUntil { b.session.count("importFinished") == 1 })
        await leave(b, browse)
    }

    /// A first listing that failed keeps the link for Try Again; hidden like that, it lets go after the timeout too, so the
    /// stay starts rather than the phone staying on the camera's network until Back. It stays failed, showing it again
    /// reopens nothing, and Try Again (the person's tap) prepares the link again.
    @Test func aHiddenWiFiBrowseWhoseListingFailedLetsGoAfterTheTimeout() async throws {
        let first = FakeWiFiLink(items: files)
        await first.failNextListing(CameraLinkFailure(.busy))
        let second = FakeWiFiLink(items: files, id: "fake-wifi-link-2")
        let b = await bench([first, second])
        let browse = open(b)
        #expect(await eventuallyLong { if case .failed = browse.phase { true } else { false } })
        #expect(b.leases.holders(of: first) == 1)
        browse.hidden()
        #expect(await waitUntil { b.timer.pending == 1 })
        #expect(b.session.count("importFinished") == 0)
        b.timer.fire()
        #expect(await waitUntil { b.session.count("importFinished") == 1 })
        #expect(await first.closed)
        #expect(b.leases.holders(of: first) == 0)
        #expect(b.log.lines.contains(Self.idleLine))
        // Still the failed state with Try Again, not the disconnected strip.
        #expect(await eventuallyLong { browse.canReopen })
        #expect(browse.canRetry)
        #expect(browse.interruption == nil)
        if case .failed = browse.phase {} else { Issue.record("expected the failed state, got \(browse.phase)") }
        // Shown again: nothing reopens by itself.
        browse.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(b.session.count("reopen") == 0)
        #expect(b.session.count("reopen refused") == 0)
        #expect(b.session.preparesStarted == 1)
        // Try Again within the stay: the link is prepared again and the card listed.
        b.session.set(phase: .staying)
        browse.retry()
        #expect(await eventuallyLong { browse.showsLiveCard })
        #expect(b.session.count("prepare") == 2)
        #expect(b.leases.holders(of: second) == 1)
        await leave(b, browse)
    }

    // MARK: Shown again

    @Test func shownAgainWithinTheStayReopensAndListsWithNoJoin() async throws {
        let second = FakeWiFiLink(items: files, id: "fake-wifi-link-2")
        let b = await bench([FakeWiFiLink(items: files), second])
        let browse = await letGo(b)
        b.session.set(phase: .staying)
        let generation = browse.linkGeneration
        browse.start()   // shown again
        #expect(await eventuallyLong { browse.interruption == nil && browse.linkGeneration > generation })
        #expect(browse.showsLiveCard)
        #expect(b.session.count("reopen") == 1)
        #expect(b.session.count("prepare") == 1)   // the first open only: nothing joined
        #expect(b.leases.holders(of: second) == 1)
        #expect(b.log.lines.contains(
            "browse: shown again; reopening with no join (within the stay, or on a job's link)"))
        // Hidden again: the same rule from the start.
        browse.hidden()
        #expect(await waitUntil { b.timer.pending == 1 })
        await leave(b, browse)
    }

    /// After the stay ended (the phone left the camera's network), showing Browse again starts no join: the card stays
    /// with Reconnect, and only the tap prepares the link.
    @Test func shownAgainAfterTheStayEndedOffersReconnectAndStartsNoJoin() async throws {
        let second = FakeWiFiLink(items: files, id: "fake-wifi-link-2")
        let b = await bench([FakeWiFiLink(items: files), second])
        let browse = await letGo(b)
        b.session.set(phase: .idle)
        browse.start()   // shown again
        #expect(await waitUntil { b.session.count("reopen refused") == 1 })
        #expect(await eventuallyLong {
            b.log.lines.contains("browse: shown again; the camera's Wi-Fi was left; offering Reconnect")
        })
        #expect(browse.interruption == .disconnected)
        #expect(browse.interruptionDetail == nil)
        #expect(b.session.preparesStarted == 1)
        #expect(await !b.source.isConnecting(b.descriptor.id))
        // Showing it again once more reopens nothing by itself.
        browse.hidden()
        browse.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(b.session.preparesStarted == 1)
        #expect(b.session.count("reopen refused") == 1)
        // Reconnect is the person's tap: it may join.
        browse.reconnect()
        #expect(await waitUntil { b.session.count("prepare") == 2 })
        #expect(await eventuallyLong { browse.interruption == nil && browse.showsLiveCard })
        #expect(b.leases.holders(of: second) == 1)
        await leave(b, browse)
    }

    @Test func backAfterALetGoStopsCleanly() async throws {
        let b = await bench([FakeWiFiLink(items: files)])
        let browse = await letGo(b)
        b.app.cameras.path = []
        #expect(await eventuallyLong { !browse.isStarted })
        #expect(b.log.lines.contains("browse: left; stopping"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(b.session.preparesStarted == 1)
        #expect(b.session.count("reopen") == 0)
        #expect(b.session.count("reopen refused") == 0)
        #expect(b.session.count("importFinished") == 1)
        // The screen's disappearance after the pop changes nothing.
        browse.hidden()
        #expect(b.timer.started == 1)
    }

    /// Popped while hidden and idle (code replacing the path behind another tab): the timer goes with the run.
    @Test func backWhileTheTimerRunsDropsIt() async throws {
        let b = await bench([FakeWiFiLink(items: files)])
        let browse = open(b)
        #expect(await eventuallyLong { browse.showsLiveCard })
        browse.hidden()
        #expect(await waitUntil { b.timer.pending == 1 })
        await leave(b, browse)
        #expect(await waitUntil { b.timer.pending == 0 })
        #expect(await waitUntil { b.session.count("importFinished") == 1 })
        #expect(!b.log.lines.contains(Self.idleLine))
    }

    // MARK: "Import new photos" on a Browse that let go

    /// The let-go Browse still shows its card but can't hand files over, so the intent doesn't take it as listed: it waits,
    /// showing Browse again reopens with no join within the stay, and the import starts on that listing.
    @Test func importNewPhotosOnABrowseThatLetGoWithinTheStayStartsOnTheReopensListing() async throws {
        let second = FakeWiFiLink(items: files, id: "fake-wifi-link-2")
        let b = await bench([FakeWiFiLink(items: files), second])
        let browse = await letGo(b)
        b.session.set(phase: .staying)
        let key = try #require(await b.source.knownKey(for: b.descriptor.id))
        let app = b.app
        let asked = Task {
            await app.importNewPhotos(cameraWith: key, waitingForCamera: .zero, waitingForImport: .seconds(20))
        }
        #expect(await eventuallyLong { b.log.lines.contains("intents: import new photos: waiting for the card") })
        #expect(!browse.isSelecting)
        #expect(browse.selection.isEmpty)
        browse.start()   // the intent's switch to Cameras shows Browse again
        #expect(await asked.value == .requested(.started(2), choice: .photos))
        #expect(b.session.count("reopen") == 1)
        #expect(b.session.count("prepare") == 1)   // nothing joined
        #expect(b.leases.holders(of: second) >= 1)
        #expect(await eventuallyLong {
            await b.app.importer.refresh()
            return b.app.importer.isFinished
        })
        await leave(b, browse)
    }

    /// After the stay, showing Browse again offers Reconnect and joins nothing; the intent's request waits for the person
    /// and says so, with nothing picked.
    @Test func importNewPhotosOnABrowseThatLetGoAfterTheStayWaitsForThePersonAndStartsNoJoin() async throws {
        let b = await bench([FakeWiFiLink(items: files), FakeWiFiLink(items: files, id: "fake-wifi-link-2")])
        let browse = await letGo(b)
        b.session.set(phase: .idle)
        let key = try #require(await b.source.knownKey(for: b.descriptor.id))
        let app = b.app
        let asked = Task {
            await app.importNewPhotos(cameraWith: key, waitingForCamera: .zero, waitingForImport: .seconds(1))
        }
        #expect(await eventuallyLong { b.log.lines.contains("intents: import new photos: waiting for the card") })
        browse.start()   // the intent's switch to Cameras shows Browse again
        #expect(await waitUntil { b.session.count("reopen refused") == 1 })
        #expect(await asked.value == .waitingForPerson(choice: .photos, why: .disconnected))
        #expect(browse.interruption == .disconnected)
        #expect(!browse.isSelecting)
        #expect(browse.selection.isEmpty)
        #expect(b.session.preparesStarted == 1)
        #expect(await !b.source.isConnecting(b.descriptor.id))
        #expect(!b.app.importer.isActive)
        await leave(b, browse)
    }

    // MARK: The source's reopen

    /// A camera never opened through a session: reaching it is the hand-off and the join, so the reopen refuses at once
    /// and nothing is asked of the session.
    @Test func theSourcesReopenRefusesACameraNeverConnected() async throws {
        let b = await bench([FakeWiFiLink(items: files)])
        let fresh = await b.source.registerPairedCamera(peripheral: PeripheralID(UUID()))
        await #expect(throws: CameraLinkFailure.self) {
            _ = try await b.source.cameraLinkWithoutJoining(for: fresh.id)
        }
        #expect(b.connecting.fakeSession(fresh.id) == nil)
        #expect(await !b.source.isConnecting(fresh.id))
    }

    /// The person's tap (`cameraLink(for:)`) while a reopen that may not join is under way waits for it, then connects
    /// afresh when it found a join needed, rather than taking the refusal.
    @Test func aTapDuringAReopenThatMayNotJoinConnectsAfterIt() async throws {
        let second = FakeWiFiLink(items: files, id: "fake-wifi-link-2")
        let b = await bench([FakeWiFiLink(items: files), second])
        let browse = await letGo(b)
        await leave(b, browse)
        b.session.set(phase: .idle)
        let source = b.source
        let id = b.descriptor.id
        let reopen = Task { () -> Bool in (try? await source.cameraLinkWithoutJoining(for: id)) != nil }
        let tap = Task { () -> Bool in (try? await source.cameraLink(for: id)) != nil }
        #expect(await bounded(reopen) == false)
        #expect(await bounded(tap) == true)
        #expect(b.session.count("prepare") == 2)
    }
}

/// USB keeps its card behind another tab (unchanged from #152): no idle timer, no let-go.
@MainActor
@Suite("Browse hidden behind another tab: USB keeps its card")
struct HiddenUSBBrowseTests {
    @Test func aHiddenUSBBrowseNeverLetsGo() async throws {
        let link = FakeLink(items: [item("DSC00001.ARW", at: 10)], id: "usb-a")
        let discovery = ScriptedDiscovery()
        await discovery.set(link: link, for: link.descriptor.id)
        let leases = LinkLeases()
        let log = RecordingLog()
        let cameras = CamerasModel(discovery: discovery, services: services(log: log), leases: leases)
        let timer = IdleTimerControl()
        cameras.browseIdleTimer = timer.timer
        cameras.path = [link.descriptor]
        let browse = cameras.browseModel(for: link.descriptor)
        browse.start()
        #expect(await eventually { browse.phase == .listed })
        browse.hidden()
        try await Task.sleep(for: .milliseconds(200))
        #expect(timer.started == 0)
        timer.fire()
        #expect(await !link.closed)
        #expect(leases.holders(of: link) == 1)
        browse.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.listCount == 1)
        cameras.path = []
        #expect(await eventually { await link.closed })
    }
}
