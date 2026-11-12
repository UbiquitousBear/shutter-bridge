import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import Testing
@testable import AppUI

private let peripheral = PeripheralID(UUID(uuidString: "0E1D2C3B-4A59-6877-8695-A4B3C2D1E0F0")!)

/// Parks until released or cancelled: an `AsyncStream`'s `next()` ends when its task is cancelled, so nothing can hang.
final class WiFiOpenGate: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let sink: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var arrived = 0

    init() { (stream, sink) = AsyncStream.makeStream() }

    /// How many opens have reached the gate: the point from which nothing before the open can still happen.
    var arrivals: Int { lock.withLock { arrived } }

    func wait() async {
        lock.withLock { arrived += 1 }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() { sink.yield() }
}

@MainActor
@Suite("Cameras model with Wi-Fi cameras")
struct WiFiCamerasModelTests {
    let wifiA = CameraDescriptor(id: .init(rawValue: "wifi-a"), name: "Camera", mode: .wifi(.cameraNetwork))
    let wifiB = CameraDescriptor(id: .init(rawValue: "wifi-b"), name: "Camera", mode: .wifi(.cameraNetwork))
    let wifiC = CameraDescriptor(id: .init(rawValue: "wifi-c"), name: "Camera", mode: .wifi(.cameraNetwork))
    let usb = CameraDescriptor(id: .init(rawValue: "usb-u"), name: "Untitled", mode: .usb(.massStorage))

    @Test func anImportFindsItsWiFiCameraByKeyAndJoinsNoOtherToLookFor() async {
        let discovery = ScriptedDiscovery()
        let keyA = CameraKey(rawValue: "wifi-serial:a")
        let keyB = CameraKey(rawValue: "wifi-serial:b")
        let linkA = FakeWiFiLink(id: "a")
        let linkB = FakeWiFiLink(id: "b")
        await discovery.set(key: keyA, for: wifiA.id)
        await discovery.set(key: keyB, for: wifiB.id)
        await discovery.set(link: linkA, for: wifiA.id)
        await discovery.set(link: linkB, for: wifiB.id)
        await discovery.set(link: FakeWiFiLink(id: "c"), for: wifiC.id)   // never connected: no key yet
        let usbLink = FakeLink(items: [])
        await discovery.set(link: usbLink, for: usb.id)
        let model = CamerasModel(discovery: discovery, services: services(), cameraKey: { descriptor, _ in
            descriptor.carrier == .usb ? CameraKey(rawValue: "usb-key") : CameraKey(rawValue: "unexpected")
        })
        await model.becameActive()
        for camera in [wifiA, wifiC, wifiB, usb] { await discovery.send(.appeared(camera)) }
        #expect(await eventuallyLong { model.cameras.count == 4 })

        #expect(await model.link(forCameraWith: keyB) === linkB)
        #expect(await discovery.linkRequests == [wifiB.id])   // A and C were not opened to be compared
        #expect(await model.link(forCameraWith: CameraKey(rawValue: "usb-key")) === usbLink)
        let requests = await discovery.linkRequests
        #expect(requests == [wifiB.id, usb.id])   // the USB camera is compared by its link, as always; no Wi-Fi join
        #expect(await model.link(forCameraWith: CameraKey(rawValue: "nobody")) == nil)
        let after = await discovery.linkRequests
        #expect(after == [wifiB.id, usb.id, usb.id])
    }

    @Test func notNowOnTheExplanationClosesTheCameraWithNoNotice() async {
        let discovery = ScriptedDiscovery()
        await discovery.set(declined: true, for: wifiA.id)   // the link isn't set: the open throws `disconnected`
        let model = CamerasModel(discovery: discovery, services: services(), cameraKey: { _, _ in CameraKey(rawValue: "k") })
        model.path = [wifiA]
        let browse = model.browseModel(for: wifiA)
        let run = Task { await browse.run() }
        #expect(await eventuallyLong { model.path.isEmpty })
        #expect(model.notice == nil)
        #expect(await bounded(run) != nil)
        // The same failure from a camera that wasn't declined is a camera that went away, with its notice.
        await discovery.set(declined: false, for: wifiA.id)
        model.path = [wifiA]
        let again = model.browseModel(for: wifiA)
        await again.run()
        #expect(model.path.isEmpty)
        #expect(model.notice != nil)
    }

    @Test func aWiFiRowHasNoBatteryOrFreeSpaceEvenIfSomeoneHandsOneOver() {
        let model = CamerasModel(discovery: ScriptedDiscovery(), services: services())
        #expect(model.deviceStatusLines(for: wifiA).isEmpty)
        #expect(model.deviceStatusLines(for: wifiA, batteryPercent: 0, freeBytes: 0).isEmpty)
        #expect(model.deviceStatusLines(for: wifiA, batteryPercent: 80, freeBytes: 5_000_000_000).isEmpty)
        // Over USB the same call shows what has been read, and never an unknown value as 0.
        #expect(model.deviceStatusLines(for: usb).isEmpty)
        let lines = model.deviceStatusLines(for: usb, batteryPercent: 80, freeBytes: nil)
        #expect(lines == ["Battery 80%"])
        let both = model.deviceStatusLines(for: usb, batteryPercent: 250, freeBytes: 12_000_000_000)
        #expect(both.count == 2 && both[0] == "Battery 100%" && both[1].hasSuffix("free"))
    }

    @Test func theBadgeFollowsTheCarrier() {
        #expect(CamerasWording.badge(for: .usb(.mtp)) == "USB-C")
        #expect(CamerasWording.badge(for: .wifi(.cameraNetwork)) == "Wi-Fi")
        #expect(CamerasWording.badge(for: .wifi(.otherNetwork)) == "Wi-Fi")
    }
}

@MainActor
@Suite("Browse over Wi-Fi: the last-known card while joining, and why it failed")
struct WiFiBrowseTests {
    let camera = CameraDescriptor(id: .init(rawValue: "wifi-a"), name: "Camera", mode: .wifi(.cameraNetwork))
    let key = CameraKey(rawValue: "wifi-serial:known")
    let listedAt = Date(timeIntervalSince1970: 1_792_000_000)
    let card = [item("DSC00010.ARW", at: 30, size: 100), item("DSC00011.ARW", at: 40, size: 100)]

    final class GoneBox: @unchecked Sendable {
        var ids: [CameraDescriptor.ID] = []
    }

    /// A catalogue holding a last-known card for `key`.
    func catalogue(for key: CameraKey) async -> InMemoryCatalogue {
        let catalogue = InMemoryCatalogue()
        let old = [item("DSC00001.ARW", at: 10, size: 40), item("DSC00002.ARW", at: 20, size: 41)]
        await catalogue.saveListing(CardListing(camera: key, listedAt: listedAt, entries: old.map {
            CardListing.Entry(identity: $0.identity(camera: key, timeZone: .current)!, format: $0.format)
        }))
        return catalogue
    }

    func model(catalogue: InMemoryCatalogue, knownKey: CameraKey?, openedKey: CameraKey, gate: WiFiOpenGate,
               link: FakeWiFiLink, openFails: CameraLinkFailure? = nil, text: String? = nil,
               gone: GoneBox = GoneBox()) -> BrowseModel {
        BrowseModel(
            camera: camera,
            openLink: { () async throws(CameraLinkFailure) -> any CameraLink in
                await gate.wait()
                if let openFails { throw openFails }
                return link
            },
            services: services(),
            openFailureText: { text },
            onGone: { gone.ids.append($0) },
            catalogue: BrowseCatalogue(store: catalogue, cameraKey: { _, _ in openedKey },
                                       knownKey: { knownKey })
        )
    }

    @Test func theLastKnownCardShowsWhileTheJoinIsStillUnderWayThenTheLiveCardReplacesIt() async {
        let gate = WiFiOpenGate()
        let link = FakeWiFiLink(items: card)
        let browse = model(catalogue: await catalogue(for: key), knownKey: key, openedKey: key, gate: gate, link: link)
        let run = Task { await browse.run() }
        #expect(await eventuallyLong { browse.lastKnownListedAt == listedAt })
        // The link isn't open yet, so nothing can be picked from the card, and the screen is still connecting: the card
        // isn't being read until the link is in hand (bench 19.1).
        guard case .connecting = browse.phase else { Issue.record("not connecting: \(browse.phase)"); return }
        #expect(browse.navigationSubtitle == BrowseWording.connectingSubtitle)
        #expect(browse.sections.flatMap(\.items).map(\.name) == ["DSC00002.ARW", "DSC00001.ARW"])
        #expect(!browse.canImport)
        gate.release()
        #expect(await eventuallyLong { browse.phase == .listed })
        #expect(browse.lastKnownListedAt == nil)
        #expect(browse.sections.flatMap(\.items).map(\.name) == ["DSC00011.ARW", "DSC00010.ARW"])
        run.cancel()
        #expect(await bounded(run) != nil)
    }

    @Test func aCameraWithNoKnownKeyShowsNothingUntilItsLinkIsOpen() async {
        let gate = WiFiOpenGate()
        let link = FakeWiFiLink(items: card)
        let browse = model(catalogue: await catalogue(for: key), knownKey: nil, openedKey: key, gate: gate, link: link)
        let run = Task { await browse.run() }
        // The open has been reached, so the known-key step is over: it found none and showed nothing.
        #expect(await waitUntil { gate.arrivals == 1 })
        #expect(browse.lastKnownListedAt == nil && browse.sections.isEmpty)
        guard case .connecting = browse.phase else { Issue.record("not connecting: \(browse.phase)"); return }
        gate.release()
        #expect(await eventuallyLong { browse.phase == .listed })
        run.cancel()
        #expect(await bounded(run) != nil)
    }

    @Test func aFailedJoinTakesTheLastKnownCardOffAndSaysWhyWithTheNextStep() async {
        let gate = WiFiOpenGate()
        let gone = GoneBox()
        let text = WiFiWording.paused(.joinDeclined)
        let browse = model(catalogue: await catalogue(for: key), knownKey: key, openedKey: key, gate: gate,
                           link: FakeWiFiLink(), openFails: CameraLinkFailure(.notAuthorised), text: text, gone: gone)
        let run = Task { await browse.run() }
        #expect(await eventuallyLong { browse.lastKnownListedAt == listedAt })
        gate.release()
        #expect(await eventuallyLong { browse.phase == .failed(text) })
        #expect(browse.lastKnownListedAt == nil && browse.sections.isEmpty)
        #expect(gone.ids.isEmpty)
        // A failed open offers Try Again (it prepares the link again), under the connection's own title.
        #expect(browse.canRetry)
        #expect(browse.failedTitle == WiFiWording.failedTitle)
        run.cancel()
        #expect(await bounded(run) != nil)
    }

    @Test func aFailureWithTextIsNotTakenForACameraThatWentAway() async {
        let gate = WiFiOpenGate()
        let gone = GoneBox()
        let browse = model(catalogue: InMemoryCatalogue(), knownKey: nil, openedKey: key, gate: gate,
                           link: FakeWiFiLink(), openFails: CameraLinkFailure(.disconnected), text: "Open the camera again.",
                           gone: gone)
        let run = Task { await browse.run() }
        gate.release()
        #expect(await eventuallyLong { browse.phase == .failed("Open the camera again.") })
        #expect(gone.ids.isEmpty)
        run.cancel()
        #expect(await bounded(run) != nil)
    }

    @Test func aDisconnectWithNoTextStillReturnsToCameras() async {
        let gate = WiFiOpenGate()
        let gone = GoneBox()
        let browse = model(catalogue: InMemoryCatalogue(), knownKey: nil, openedKey: key, gate: gate,
                           link: FakeWiFiLink(), openFails: CameraLinkFailure(.disconnected), text: nil, gone: gone)
        let run = Task { await browse.run() }
        gate.release()
        #expect(await eventuallyLong { browse.phase == .gone })
        #expect(gone.ids == [camera.id])
        #expect(await bounded(run) != nil)
    }

    @Test func aDeclinedOpenClosesBrowseWithNoNoticeThatTheCameraWentAway() async {
        let gone = GoneBox()
        let declined = GoneBox()
        let gate = WiFiOpenGate()
        let browse = BrowseModel(
            camera: camera,
            openLink: { () async throws(CameraLinkFailure) -> any CameraLink in
                await gate.wait()
                throw CameraLinkFailure(.disconnected, detail: "wifi: not started")
            },
            services: services(), openFailureText: { nil }, openWasDeclined: { true },
            onGone: { gone.ids.append($0) }, onDeclined: { declined.ids.append($0) })
        let run = Task { await browse.run() }
        gate.release()
        #expect(await eventuallyLong { browse.phase == .gone })
        #expect(declined.ids == [camera.id])
        #expect(gone.ids.isEmpty)
        #expect(await bounded(run) != nil)
    }

    @Test func aDisconnectThatWasntADeclineStillSaysTheCameraWentAway() async {
        let gone = GoneBox()
        let declined = GoneBox()
        let browse = BrowseModel(
            camera: camera,
            openLink: { () async throws(CameraLinkFailure) -> any CameraLink in throw CameraLinkFailure(.disconnected) },
            services: services(), openFailureText: { nil }, openWasDeclined: { false },
            onGone: { gone.ids.append($0) }, onDeclined: { declined.ids.append($0) })
        await browse.run()
        #expect(gone.ids == [camera.id] && declined.ids.isEmpty)
    }

    @Test func aCameraThatAnswersWithAnotherKeyDoesntKeepTheOthersCard() async {
        let gate = WiFiOpenGate()
        let link = FakeWiFiLink(items: card)
        let other = CameraKey(rawValue: "wifi-serial:other")
        let browse = model(catalogue: await catalogue(for: key), knownKey: key, openedKey: other, gate: gate, link: link)
        let run = Task { await browse.run() }
        #expect(await eventuallyLong { browse.lastKnownListedAt == listedAt })
        gate.release()
        #expect(await eventuallyLong { browse.phase == .listed })
        #expect(browse.lastKnownListedAt == nil)
        #expect(browse.sections.flatMap(\.items).map(\.name) == ["DSC00011.ARW", "DSC00010.ARW"])
        run.cancel()
        #expect(await bounded(run) != nil)
    }
}

@MainActor
@Suite("The app with Wi-Fi: wiring and a whole import")
struct WiFiAppModelTests {
    struct Bench {
        let app: AppModel
        let source: WiFiCameraSource
        let status: WiFiImportModel
        let connecting: FakeConnecting
        let usb: ScriptedDiscovery
        let catalogue: InMemoryCatalogue
        let record = InMemoryLocalNetworkExplainedRecord(hasExplained: true)
    }

    func bench(log: RecordingLog = RecordingLog()) -> Bench {
        let catalogue = InMemoryCatalogue()
        let connecting = FakeConnecting()
        let source = WiFiCameraSource(catalogue: catalogue, connecting: connecting)
        let status = WiFiImportModel(source: source)
        let usb = ScriptedDiscovery()
        let composite = CompositeDiscovery(sources: [usb, source])
        let app = AppModel(
            discovery: composite, services: services(log: log), catalogue: catalogue,
            engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
            settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
            destinations: FakeDestinations(), cameraKey: CameraKeys.keying(material: { _ in nil }),
            wifi: WiFiSupport(source: source, status: status))
        return Bench(app: app, source: source, status: status, connecting: connecting, usb: usb, catalogue: catalogue)
    }

    @Test func aPairedCameraIsListedBrowsedImportedAndItsStayStartsWhenEveryoneLetsGo() async throws {
        let b = bench()
        let files = [item("DSC00001.ARW", at: 10, size: 1_000), item("DSC00002.ARW", at: 20, size: 2_000)]
        let descriptor = await b.source.registerPairedCamera(peripheral: peripheral)
        let session = b.connecting.session(for: WiFiCameraEntry(
            descriptor: descriptor, key: nil, peripheral: peripheral, guid: UUID())) as! FakeSession
        session.script(.success(FakeWiFiLink(items: files)))

        await b.app.scenePhaseChanged(.active)   // discovery starts; the Wi-Fi model follows its source
        #expect(await eventuallyLong { b.app.cameras.cameras == [descriptor] })

        let browse = b.app.browseModel(for: descriptor)
        let run = Task { await browse.run() }
        #expect(await eventuallyLong { browse.phase == .listed })
        // The key is the serial's, whatever the descriptor says.
        let key = CameraKeys.key(for: descriptor, material: fakeSerial)
        #expect(await b.source.knownKey(for: descriptor.id) == key)
        #expect(await waitUntilOnMain { b.status.camera == descriptor.id })   // the status model saw the connection begin

        browse.selectAllNew()
        await browse.importSelected()
        #expect(b.app.importer.camera?.key == key)
        #expect(await eventuallyLong {
            await b.app.importer.refresh()
            return b.app.importer.isFinished
        })
        // Browse still holds the link: the stay hasn't started.
        #expect(session.count("importFinished") == 0)
        run.cancel()
        #expect(await bounded(run) != nil)
        #expect(await waitUntil { session.count("importFinished") == 1 })
        #expect(session.count("prepare") == 1)
    }

    /// Import new photos through the real source and composite (Shamil, 12 Nov): inside the stay the camera is still
    /// joined, so its live Browse opens and reopens it with no join; once the session has left, the offline Browse offers
    /// Connect and nothing is asked of the session.
    @Test func importNewPhotosGoesLiveInsideTheStayAndOffersConnectOnceTheCameraIsLeft() async throws {
        let b = bench()
        let files = [item("DSC00001.ARW", at: 10, size: 1_000), item("DSC00002.ARW", at: 20, size: 2_000)]
        let descriptor = await b.source.registerPairedCamera(peripheral: peripheral)
        let session = b.connecting.session(for: WiFiCameraEntry(
            descriptor: descriptor, key: nil, peripheral: peripheral, guid: UUID())) as! FakeSession
        session.script(.success(FakeWiFiLink(items: files)))
        await b.app.scenePhaseChanged(.active)
        #expect(await eventuallyLong { b.app.cameras.cameras == [descriptor] })
        // Browsed once, so its key is known; then Browse is closed and the stay starts.
        let first = b.app.browseModel(for: descriptor)
        let firstRun = Task { await first.run() }
        #expect(await eventuallyLong { first.phase == .listed })
        let key = try #require(await b.source.knownKey(for: descriptor.id))
        firstRun.cancel()
        #expect(await bounded(firstRun) != nil)
        #expect(await waitUntil { session.count("importFinished") == 1 })
        #expect(session.count("prepare") == 1)

        // Inside the stay: the live Browse.
        session.set(phase: .staying)
        b.app.cameras.path = []
        let asked = Task { await b.app.importNewPhotos(cameraWith: key, waitingForCamera: .zero,
                                                       waitingForImport: .milliseconds(200)) }
        #expect(await eventuallyLong { b.app.cameras.path == [descriptor] })
        _ = await asked.value
        b.app.cameras.path = []

        // The session has left: the offline Browse with Connect, and the session isn't asked to prepare.
        session.set(phase: .idle)
        let start = await b.app.importNewPhotos(cameraWith: key, waitingForCamera: .zero)
        #expect(start == .waitingForConnection(choice: .photos, cardRead: true))
        let shown = try #require(b.app.cameras.path.last)
        #expect(b.app.cameras.isOffline(shown.id))
        #expect(session.count("prepare") == 1)
    }

    @Test func theSceneReachesTheSessionsAfterTheImportsOwnRule() async throws {
        let b = bench()
        let descriptor = await b.source.registerPairedCamera(peripheral: peripheral)
        let session = b.connecting.session(for: WiFiCameraEntry(
            descriptor: descriptor, key: nil, peripheral: peripheral, guid: UUID())) as! FakeSession
        session.script(.success(FakeWiFiLink()))
        _ = try await b.source.cameraLink(for: descriptor.id)
        await b.app.scenePhaseChanged(.background)
        await b.app.scenePhaseChanged(.inactive)
        await b.app.scenePhaseChanged(.active)
        #expect(session.calls == ["prepare", "background", "importFinished", "active"])
    }

    @Test func goingToTheBackgroundWithBrowseOpenAndNoImportLeavesTheCameraNetworkAndOnlyReconnectGetsItBack() async throws {
        let log = RecordingLog()
        let b = bench(log: log)
        let descriptor = await b.source.registerPairedCamera(peripheral: peripheral)
        let session = b.connecting.session(for: WiFiCameraEntry(
            descriptor: descriptor, key: nil, peripheral: peripheral, guid: UUID())) as! FakeSession
        let files = [item("DSC00001.ARW", at: 10, size: 1_000), item("DSC00002.ARW", at: 20, size: 1_000)]
        let first = FakeWiFiLink(items: files)
        let second = FakeWiFiLink(items: files)
        session.script(.success(first), .success(second))
        // As the real session: the import's end closes the link it handed out (bench 19.1's dead grid).
        session.set(closesLinkWhenFinished: true)
        await b.app.scenePhaseChanged(.active)
        #expect(await eventuallyLong { b.app.cameras.cameras == [descriptor] })
        let browse = b.app.browseModel(for: descriptor)
        let run = Task { await browse.run() }
        #expect(await eventuallyLong { browse.phase == .listed })
        let ids = files.newestFirst().map(\.id)
        #expect(await browse.thumbnail(for: ids[0]) != nil)
        browse.tap(files[0])
        // Browse is open, nothing is imported: the phone still leaves when the app does.
        await b.app.scenePhaseChanged(.background)
        #expect(session.count("importFinished") == 1)
        #expect(await !b.source.hasLiveLink(for: descriptor.id))
        #expect(await first.closed)
        #expect(log.lines.contains("wifi: let go on the way to the background (Browse open, no import)"))
        // Browse leaves the silent dead grid for its disconnected strip, keeping the card and the selection, and nothing
        // reconnects while the app is away.
        #expect(await eventuallyLong { browse.interruption == .disconnected })
        #expect(browse.phase == .listed && browse.selection == [files[0].id])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.count("prepare") == 1)
        #expect(await browse.thumbnail(for: ids[1]) == nil)
        // Back in front: nothing is prepared by itself (Shamil, 10 Nov); the strip, the card and the selection stay.
        await b.app.scenePhaseChanged(.active)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.count("prepare") == 1)
        #expect(browse.interruption == .disconnected && browse.linkGeneration == 1)
        #expect(browse.phase == .listed && browse.selection == [files[0].id])
        // Reconnect: the same Browse prepares again (no closed link handed out), lists and loads thumbnails.
        browse.reconnect()
        #expect(await eventuallyLong { browse.interruption == nil && browse.linkGeneration == 2 })
        #expect(session.count("prepare") == 2)
        #expect(browse.phase == .listed && browse.selection == [files[0].id])
        #expect(await browse.thumbnail(for: ids[1]) != nil)
        // The open the next screen makes is handed the same live link, prepared once.
        _ = try await b.source.cameraLink(for: descriptor.id)
        #expect(session.count("prepare") == 2)
        run.cancel()
        #expect(await bounded(run) != nil)
        // The new link's last holder letting go is the end of its import; the closed one's ended at the leave.
        #expect(await waitUntil { session.count("importFinished") == 2 })
        #expect(log.lines.contains { $0.hasPrefix("browse: the link ended under the screen (events finished)") })
        #expect(log.lines.contains("browse: reconnecting (Reconnect)"))
    }

    @Test func anOpenThatNeededTheAppInFrontIsNotPreparedAgainOnTheReturnOnlyByTryAgain() async throws {
        let log = RecordingLog()
        let b = bench(log: log)
        let descriptor = await b.source.registerPairedCamera(peripheral: peripheral)
        let session = b.connecting.session(for: WiFiCameraEntry(
            descriptor: descriptor, key: nil, peripheral: peripheral, guid: UUID())) as! FakeSession
        let files = [item("DSC00001.ARW", at: 10, size: 1_000)]
        session.script(.failure(.paused(.needsJoin)), .success(FakeWiFiLink(items: files)))
        await b.app.scenePhaseChanged(.active)
        #expect(await eventuallyLong { b.app.cameras.cameras == [descriptor] })
        let browse = b.app.browseModel(for: descriptor)
        let run = Task { await browse.run() }
        #expect(await eventuallyLong { browse.phase == .failed(WiFiWording.needsAppToJoin) })
        #expect(session.count("prepare") == 1)
        // Away and back, twice: nothing is prepared by itself (Shamil, 10 Nov); the failure and Try Again stay.
        for _ in 0..<2 {
            await b.app.scenePhaseChanged(.background)
            await b.app.scenePhaseChanged(.inactive)
            await b.app.scenePhaseChanged(.active)
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.count("prepare") == 1)
        #expect(browse.phase == .failed(WiFiWording.needsAppToJoin) && browse.canRetry)
        // Try Again prepares once more, and the card lists.
        browse.retry()
        #expect(await eventuallyLong { browse.phase == .listed })
        #expect(session.count("prepare") == 2)
        #expect(log.lines.contains("browse: opening again (Try Again)"))
        run.cancel()
        #expect(await bounded(run) != nil)
    }

    @Test func anImportsLeaseGoingInTheBackgroundWhileBrowseHoldsTheLinkLeavesTheCameraNetwork() async throws {
        let b = bench()
        let descriptor = await b.source.registerPairedCamera(peripheral: peripheral)
        let session = b.connecting.session(for: WiFiCameraEntry(
            descriptor: descriptor, key: nil, peripheral: peripheral, guid: UUID())) as! FakeSession
        session.script(.success(FakeWiFiLink()), .success(FakeWiFiLink()), .success(FakeWiFiLink()))
        _ = try await b.source.cameraLink(for: descriptor.id)
        await b.app.scenePhaseChanged(.background)   // nothing imports, so the scene lets the camera go
        #expect(session.count("importFinished") == 1)
        // Still in the background, the camera is opened again (the continued task's import) and Browse holds it too.
        let link = try await b.source.cameraLink(for: descriptor.id)
        b.app.leases.acquire(link)   // Browse
        b.app.leases.acquire(link)   // the import
        await b.app.leases.release(link)   // the import's lease goes: Browse still holds the link, but the import is over
        #expect(b.app.leases.holders(of: link) == 1)
        #expect(session.count("importFinished") == 2)
        #expect(await !b.source.hasLiveLink(for: descriptor.id))
        // In front the same release changes nothing: the stay starts when the last holder lets go.
        await b.app.scenePhaseChanged(.active)
        let front = try await b.source.cameraLink(for: descriptor.id)
        b.app.leases.acquire(front)
        b.app.leases.acquire(front)
        await b.app.leases.release(front)
        #expect(session.count("importFinished") == 2)
        await b.app.leases.release(front)
        #expect(session.count("importFinished") == 3)
    }

    @Test func aKnownKeyIsWhatBrowseAndTheImportUseForAWiFiCamera() async throws {
        let known = CameraKey(rawValue: "wifi-serial:known")
        let discovery = ScriptedDiscovery()
        let camera = CameraDescriptor(id: .init(rawValue: "wifi-a"), name: "Camera", mode: .wifi(.cameraNetwork))
        await discovery.set(key: known, for: camera.id)
        await discovery.set(link: FakeWiFiLink(serial: nil, items: [item("DSC00001.ARW", at: 10, size: 1_000)]), for: camera.id)
        let catalogue = InMemoryCatalogue()
        let app = AppModel(
            discovery: discovery, services: services(), catalogue: catalogue,
            engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
            settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
            destinations: FakeDestinations(), cameraKey: CameraKeys.keying(material: { _ in nil }))
        let browse = app.browseModel(for: camera)
        let run = Task { await browse.run() }
        #expect(await eventuallyLong { browse.phase == .listed })
        browse.selectAllNew()
        #expect(browse.canImport)
        await browse.importSelected()
        #expect(app.importer.camera?.key == known)   // not `wifi-name:…`, though the link gave no serial
        #expect(await catalogue.lastListing(for: known) != nil)
        run.cancel()
        #expect(await bounded(run) != nil)
    }

    @Test func aWiFiCameraWithNoKeyAtAllIsListedButNeverImportedOrSaved() async throws {
        let discovery = ScriptedDiscovery()
        let camera = CameraDescriptor(id: .init(rawValue: "wifi-a"), name: "Camera", mode: .wifi(.cameraNetwork))
        await discovery.set(link: FakeWiFiLink(serial: nil, items: [item("DSC00001.ARW", at: 10, size: 1_000)]), for: camera.id)
        let catalogue = InMemoryCatalogue()
        let log = RecordingLog()
        let app = AppModel(
            discovery: discovery, services: services(log: log), catalogue: catalogue,
            engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
            settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
            destinations: FakeDestinations(), cameraKey: CameraKeys.keying(material: { _ in nil }))
        let browse = app.browseModel(for: camera)
        let run = Task { await browse.run() }
        #expect(await eventuallyLong { browse.phase == .listed })
        #expect(browse.sections.flatMap(\.items).count == 1)   // the card is still shown
        browse.selectAllNew()
        #expect(!browse.canImport)
        #expect(await browse.importSelected() == nil)
        #expect(app.importer.camera == nil)
        let name = CameraKeys.key(for: camera, material: nil)
        #expect(await catalogue.lastListing(for: name) == nil)   // nothing saved under the shared name-hash key
        #expect(log.lines.contains { $0.contains("no key of its own") })
        run.cancel()
        #expect(await bounded(run) != nil)
    }

    @Test func aUSBOnlyAppIsUnchanged() async {
        let catalogue = InMemoryCatalogue()
        let discovery = FakeDiscovery(link: FakeLink(items: []))
        let app = AppModel(
            discovery: discovery, services: services(), catalogue: catalogue,
            engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
            settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
            destinations: FakeDestinations(), cameraKey: CameraKeys.fromDescriptor)
        #expect(app.wifi == nil)
        #expect(app.leases.onClosed == nil && app.leases.onReleased == nil)
        await app.scenePhaseChanged(.background)
        await app.scenePhaseChanged(.active)
        // Active started the discovery, as it always did, and nothing Wi-Fi came of the scene changes.
        #expect(await discovery.starts == 1)
        #expect(!app.importer.isActive && !app.keepsScreenOn)
        // A USB link still closes when its last holder lets go.
        let link = FakeLink(items: [])
        app.leases.acquire(link)
        app.leases.acquire(link)
        await app.leases.release(link)
        #expect(app.leases.holders(of: link) == 1)
        await app.leases.release(link)
        #expect(app.leases.holders(of: link) == 0)
    }

    @Test func aUSBLinkClosingIsNoneOfTheWiFiCamerasBusiness() async throws {
        let b = bench()
        let descriptor = await b.source.registerPairedCamera(peripheral: peripheral)
        let session = b.connecting.session(for: WiFiCameraEntry(
            descriptor: descriptor, key: nil, peripheral: peripheral, guid: UUID())) as! FakeSession
        session.script(.success(FakeWiFiLink()))
        _ = try await b.source.cameraLink(for: descriptor.id)
        let usbLink = FakeLink(items: [])
        b.app.leases.acquire(usbLink)
        await b.app.leases.release(usbLink)
        #expect(session.count("importFinished") == 0)
    }
}
