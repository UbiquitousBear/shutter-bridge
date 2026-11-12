import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import Testing
@testable import AppUI

// "Import new photos" with the camera away (W6-absent; backlog section 5's acceptance criterion): the camera's Browse
// opens offline with its last-known card and a line saying it isn't connected, offers nothing that needs the camera,
// becomes the live Browse once a USB camera is listed (a Wi-Fi camera offers Connect instead: no join starts by itself),
// and the intent answers within its budget. Driven through `AppModel` with the real engine, catalogue and Browse over
// fakes; the screen's part (making Browse's model when the path changes) is played by the test, as `LiveApp` plays it.

/// A discovery that knows a camera's key without a link (as `WiFiCameraSource` knows a Wi-Fi camera that has connected
/// before) and counts the links asked for: over Wi-Fi a link is a join.
actor KeyedDiscovery: CameraDiscovery {
    nonisolated let discoveries: AsyncStream<CameraDiscoveryEvent>
    private let sink: AsyncStream<CameraDiscoveryEvent>.Continuation
    let link: FakeLink
    let key: CameraKey
    private(set) var linksAsked = 0

    init(link: FakeLink, key: CameraKey) {
        self.link = link
        self.key = key
        (discoveries, sink) = AsyncStream.makeStream()
    }

    func send(_ event: CameraDiscoveryEvent) { sink.yield(event) }
    func start() throws(CameraLinkFailure) {}

    func cameraLink(for id: CameraDescriptor.ID) throws(CameraLinkFailure) -> any CameraLink {
        linksAsked += 1
        return link
    }

    func knownKey(for id: CameraDescriptor.ID) -> CameraKey? { id == link.descriptor.id ? key : nil }
}

/// A discovery with several cameras: each link by its camera's id, a key known without a link for some (as
/// `WiFiCameraSource` knows a Wi-Fi camera that has connected before), the links asked for counted by camera (over
/// Wi-Fi a link is a join), and the next few asks failing when scripted (a USB camera not ready yet).
actor MultiCameraDiscovery: CameraDiscovery {
    nonisolated let discoveries: AsyncStream<CameraDiscoveryEvent>
    private let sink: AsyncStream<CameraDiscoveryEvent>.Continuation
    private let links: [CameraDescriptor.ID: FakeLink]
    private let keys: [CameraDescriptor.ID: CameraKey]
    private(set) var linksAsked: [CameraDescriptor.ID: Int] = [:]
    private var failuresLeft = 0

    init(links: [FakeLink], knownKeys: [CameraDescriptor.ID: CameraKey] = [:]) {
        self.links = Dictionary(uniqueKeysWithValues: links.map { ($0.descriptor.id, $0) })
        keys = knownKeys
        (discoveries, sink) = AsyncStream.makeStream()
    }

    func send(_ event: CameraDiscoveryEvent) { sink.yield(event) }
    func failNextLinks(_ count: Int) { failuresLeft = count }
    func start() throws(CameraLinkFailure) {}

    func cameraLink(for id: CameraDescriptor.ID) throws(CameraLinkFailure) -> any CameraLink {
        linksAsked[id, default: 0] += 1
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw CameraLinkFailure(.disconnected, detail: "not ready yet")
        }
        guard let link = links[id] else { throw CameraLinkFailure(.disconnected, detail: "no such camera") }
        return link
    }

    func knownKey(for id: CameraDescriptor.ID) -> CameraKey? { keys[id] }
}

@MainActor
@Suite("Import new photos with the camera away: the offline Browse and the intent's timing")
struct OfflineBrowseTests {
    /// DSC00001 and DSC00002 are new, DSC00003 is rejected, DSC00004 has no capture date, C0001 is a video.
    let card = [
        item("DSC00001.JPG", at: 10),
        item("DSC00002.JPG", at: 20),
        item("DSC00003.JPG", at: 30),
        item("DSC00004.JPG", at: nil),
        item("C0001.MP4", at: 40),
    ]
    let listedAt = Date(timeIntervalSince1970: 1_794_000_000)

    struct Rig {
        let app: AppModel
        let link: FakeLink
        let discovery: FakeDiscovery
        let catalogue: InMemoryCatalogue
        let log: RecordingLog
        var key: CameraKey { CameraKeys.key(for: link.descriptor, material: nil) }
        var descriptor: CameraDescriptor { link.descriptor }
    }

    /// A USB camera the catalogue knows as "ILCE-7CM2", with DSC00003 rejected; its card listed in the catalogue when
    /// `lastKnown`; listed by discovery when `listed`.
    func rig(lastKnown: Bool = true, listed: Bool = false) async throws -> Rig {
        let link = FakeLink(items: card)
        await link.set(writesListedSize: true)
        let discovery = FakeDiscovery(link: link)
        let catalogue = InMemoryCatalogue()
        let log = RecordingLog()
        let app = AppModel(discovery: discovery, services: services(log: log), catalogue: catalogue,
                           engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
                           settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
                           destinations: FakeDestinations(), cameraKey: CameraKeys.fromDescriptor)
        let key = CameraKeys.key(for: link.descriptor, material: nil)
        await catalogue.upsertCamera(CameraRecord(key: key, model: "ILCE-7CM2", friendlyName: "ILCE-7CM2",
                                                  lastSeen: listedAt))
        let rejected = card[2].identity(camera: key, timeZone: .current)!.contentKey
        try await catalogue.setMark(.reject, rating: 0, for: [rejected], at: listedAt)
        if lastKnown { await catalogue.saveListing(listing(for: key)) }
        await discovery.allow()
        await app.scenePhaseChanged(.active)
        if listed {
            await discovery.send(.appeared(link.descriptor))
            #expect(await eventually { app.cameras.cameras == [link.descriptor] })
        }
        return Rig(app: app, link: link, discovery: discovery, catalogue: catalogue, log: log)
    }

    func listing(for key: CameraKey) -> CardListing {
        let entries = card.compactMap { file in
            file.identity(camera: key, timeZone: .current).map { CardListing.Entry(identity: $0, format: file.format) }
        }
        return CardListing(camera: key, listedAt: listedAt, entries: entries)
    }

    /// What `LiveApp` does when the path changes: Browse's screen makes the model for the camera on top and runs it.
    func pushBrowse(_ app: AppModel) -> (BrowseModel, Task<Void, Never>)? {
        guard let camera = app.cameras.path.last else { return nil }
        let browse = app.browseModel(for: camera)
        return (browse, Task { await browse.run() })
    }

    /// Waits for a job the test started to end, then stops Browse, so no job runs on into the next test.
    func finish(_ app: AppModel, _ runs: Task<Void, Never>...) async {
        if app.importer.hasJob {
            #expect(await eventually {
                await app.importer.refresh()
                return app.importer.isFinished
            })
        }
        for run in runs {
            run.cancel()
            await run.value
        }
    }

    // MARK: - The offline Browse

    @Test func anAbsentCameraOpensItsBrowseWithTheLastKnownCardAndNothingThatNeedsTheCamera() async throws {
        let r = try await rig()
        let start = await r.app.importNewPhotos(cameraWith: r.key, waitingForCamera: .zero)
        #expect(start == .waitingForConnection(choice: .photos, cardRead: true))
        #expect(NewPhotosWording.importAnswer(start, camera: "ILCE-7CM2")
            == "ILCE-7CM2 isn't connected. Connect it while Shutter Bridge shows its card, and its new photos will be "
            + "imported to Photos.")
        // Browse is open on the camera, not the Cameras tab alone, and the import waits for it.
        let shown = try #require(r.app.cameras.path.last)
        #expect(r.app.cameras.path.count == 1)
        #expect(r.app.cameras.isOffline(shown.id))
        #expect(!r.app.cameras.cameras.contains(shown))
        #expect(shown.carrier == .usb)
        #expect(r.app.intents.navigation?.showsImport == false)
        #expect(r.app.intents.pending?.camera == shown.id)
        #expect(r.log.lines.contains("intents: import new photos: the camera isn't connected; showing its last-known card"))

        let (browse, run) = try #require(pushBrowse(r.app))
        #expect(browse.phase == .notConnected)
        #expect(await eventually { browse.offlineCard == .shown && !browse.rejected.isEmpty })
        #expect(browse.lastKnownListedAt == listedAt)
        #expect(browse.hasFiles)
        #expect(browse.navigationTitle == "ILCE-7CM2")
        #expect(browse.navigationSubtitle == BrowseWording.notConnectedSubtitle)
        // The four dated files of the listing, with the reject's badge read from the catalogue.
        let shownItems = browse.sections.flatMap(\.items)
        #expect(Set(shownItems.map(\.name)) == ["DSC00001.JPG", "DSC00002.JPG", "DSC00003.JPG", "C0001.MP4"])
        #expect(browse.rejected.count == 1)
        // Nothing that needs the camera: no selection, no import, no Copy or Share, no thumbnail asked of a link.
        for file in shownItems {
            #expect(!browse.canSelect(file))
            #expect(!browse.offersJPEGActions(file))
            #expect(await browse.thumbnail(for: file.id) == nil)
            browse.tap(file)
        }
        browse.selectAllNew()
        #expect(browse.selection.isEmpty)
        #expect(!browse.canImport)
        #expect(await browse.importSelected() == nil)
        #expect(!browse.canConnect && !browse.canRetry)
        // The link was never asked for, opened or listed.
        #expect(await r.link.isOpen == false)
        #expect(await r.link.bytesStarted == 0)
        #expect(r.log.lines.contains("browse: the camera isn't connected; looking for its last-known card"))
        #expect(r.log.lines.contains("browse: showing the last-known card (4 files)"))
        await finish(r.app, run)
    }

    @Test func withNoLastKnownCardItSaysTheCardHasntBeenRead() async throws {
        let r = try await rig(lastKnown: false)
        let start = await r.app.importNewPhotos(cameraWith: r.key, waitingForCamera: .zero)
        #expect(start == .waitingForConnection(choice: .photos, cardRead: false))
        #expect(NewPhotosWording.importAnswer(start, camera: CamerasWording.genericName)
            == "The camera isn't connected, and Shutter Bridge hasn't read its card yet. Connect it while Shutter Bridge "
            + "is open, and its new photos will be imported to Photos.")
        #expect(r.log.lines.contains(
            "intents: import new photos: the camera isn't connected; showing that its card hasn't been read"))
        let (browse, run) = try #require(pushBrowse(r.app))
        #expect(await eventually { browse.offlineCard == .neverRead })
        #expect(browse.phase == .notConnected)
        #expect(!browse.hasFiles && browse.lastKnownListedAt == nil)
        #expect(r.log.lines.contains("browse: the camera isn't connected and its card hasn't been read yet"))
        await finish(r.app, run)
    }

    @Test func theSameCameraAskedForAgainKeepsItsOfflineBrowse() async throws {
        let r = try await rig()
        _ = await r.app.importNewPhotos(cameraWith: r.key, waitingForCamera: .zero)
        let first = r.app.intents.pending
        let shown = r.app.cameras.path
        let again = await r.app.importNewPhotos(cameraWith: r.key, waitingForCamera: .zero)
        #expect(again == .waitingForConnection(choice: .photos, cardRead: true))
        #expect(r.app.cameras.path == shown)
        #expect(first?.result == .couldNotStart)
        #expect(r.app.intents.pending !== first)
        #expect(r.app.intents.pending?.camera == shown.last?.id)
    }

    @Test func theOfflineBrowseBecomesTheLiveOneWhenTheUSBCameraIsListedAndTheImportStarts() async throws {
        let r = try await rig()
        _ = await r.app.importNewPhotos(cameraWith: r.key, waitingForCamera: .zero)
        let (offline, offlineRun) = try #require(pushBrowse(r.app))
        #expect(await eventually { offline.offlineCard == .shown })
        // The cable goes in: discovery lists the camera, and Browse on it replaces the offline one by itself.
        await r.discovery.send(.appeared(r.descriptor))
        #expect(await eventually { r.app.cameras.path == [r.descriptor] })
        #expect(r.app.intents.pending?.camera == r.descriptor.id)
        #expect(r.log.lines.contains("cameras: the camera shown as not connected is connected; opening its card"))
        #expect(r.log.lines.contains("intents: import new photos: the camera is connected; waiting for the card"))
        // The live Browse reads the card, and the waiting import starts with Select All New's files.
        let (live, liveRun) = try #require(pushBrowse(r.app))
        #expect(live.offline == nil)
        #expect(await eventually { r.app.importer.hasJob && r.app.intents.navigation?.showsImport == true })
        #expect(r.app.intents.pending == nil)
        #expect(r.log.lines.contains("intents: import new photos: started with 2 files to Photos"))
        await finish(r.app, offlineRun, liveRun)
        #expect(Set(await r.link.fetched) == Set([card[0].id, card[1].id]))
    }

    @Test func leavingTheOfflineBrowseDropsTheImportAndALaterListingOpensNothing() async throws {
        let r = try await rig()
        _ = await r.app.importNewPhotos(cameraWith: r.key, waitingForCamera: .zero)
        let (_, run) = try #require(pushBrowse(r.app))
        r.app.cameras.path = []
        #expect(r.app.intents.pending == nil)
        #expect(r.log.lines.contains("intents: import new photos dropped: Browse was left"))
        await r.discovery.send(.appeared(r.descriptor))
        #expect(await eventually { r.app.cameras.cameras == [r.descriptor] })
        // Nothing is pushed: the offline Browse isn't shown any more, so the listing is the person's to open.
        #expect(r.app.cameras.path.isEmpty)
        #expect(!r.log.lines.contains("cameras: the camera shown as not connected is connected; opening its card"))
        #expect(!r.app.importer.hasJob)
        await finish(r.app, run)
    }

    @Test func leavingTheAppDropsTheWaitingImport() async throws {
        let r = try await rig()
        _ = await r.app.importNewPhotos(cameraWith: r.key, waitingForCamera: .zero)
        await r.app.scenePhaseChanged(.background)
        #expect(r.app.intents.pending == nil)
        #expect(r.log.lines.contains("intents: import new photos dropped: the app is in the background"))
        await r.app.scenePhaseChanged(.active)
    }

    @Test func aWiFiCameraListedLaterOffersConnectAndStartsNoJoin() async throws {
        let link = FakeLink(items: card, mode: .wifi(.cameraNetwork), id: "wifi-camera", name: "ILCE-7CM2")
        let key = CameraKey(rawValue: "wifi-key")
        let discovery = KeyedDiscovery(link: link, key: key)
        let catalogue = InMemoryCatalogue()
        let log = RecordingLog()
        await catalogue.upsertCamera(CameraRecord(key: key, model: "ILCE-7CM2", friendlyName: "ILCE-7CM2",
                                                  lastSeen: listedAt, preferredCarrier: .wifi))
        await catalogue.saveListing(listing(for: key))
        let app = AppModel(discovery: discovery, services: services(log: log), catalogue: catalogue,
                           engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
                           settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
                           destinations: FakeDestinations(), cameraKey: CameraKeys.fromDescriptor)
        await app.scenePhaseChanged(.active)

        let start = await app.importNewPhotos(cameraWith: key, waitingForCamera: .zero)
        #expect(start == .waitingForConnection(choice: .photos, cardRead: true))
        let shown = try #require(app.cameras.path.last)
        #expect(shown.carrier == .wifi)
        let (browse, run) = try #require(pushBrowse(app))
        #expect(await eventually { browse.offlineCard == .shown })
        #expect(!browse.canConnect)
        browse.connect()
        #expect(app.cameras.path == [shown])

        // The camera is listed: Browse offers Connect, and stays offline; no link is asked for, so no join starts.
        await discovery.send(.appeared(link.descriptor))
        #expect(await eventually { browse.canConnect })
        #expect(app.cameras.path == [shown])
        #expect(await discovery.linksAsked == 0)
        #expect(log.lines.contains("cameras: the camera shown as not connected is listed over Wi-Fi; offering Connect"))
        // A model made again for the screen offers it too.
        #expect(app.browseModel(for: shown).canConnect)
        // The person taps Connect: the live Browse replaces it, and the waiting import moves over to it.
        browse.connect()
        #expect(app.cameras.path == [link.descriptor])
        #expect(app.intents.pending?.camera == link.descriptor.id)
        #expect(log.lines.contains("browse: Connect tapped on a camera that wasn't connected"))
        #expect(await discovery.linksAsked == 0)
        await finish(app, run)
    }

    @Test func aWiFiCameraThatGoesWithdrawsConnect() async throws {
        let link = FakeLink(items: card, mode: .wifi(.cameraNetwork), id: "wifi-camera", name: "ILCE-7CM2")
        let key = CameraKey(rawValue: "wifi-key")
        let discovery = KeyedDiscovery(link: link, key: key)
        let catalogue = InMemoryCatalogue()
        await catalogue.upsertCamera(CameraRecord(key: key, preferredCarrier: .wifi))
        let app = AppModel(discovery: discovery, services: services(), catalogue: catalogue,
                           engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
                           settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
                           destinations: FakeDestinations(), cameraKey: CameraKeys.fromDescriptor)
        await app.scenePhaseChanged(.active)
        _ = await app.importNewPhotos(cameraWith: key, waitingForCamera: .zero)
        let (browse, run) = try #require(pushBrowse(app))
        #expect(await eventually { browse.offlineCard == .neverRead })
        await discovery.send(.appeared(link.descriptor))
        #expect(await eventually { browse.canConnect })
        await discovery.send(.disappeared(link.descriptor.id))
        #expect(await eventually { !browse.canConnect })
        await finish(app, run)
    }

    /// A USB camera and a Wi-Fi camera with the offline Browse's key, sharing it (the same camera on both links).
    func twoLinkRig() async -> (app: AppModel, usb: FakeLink, wifi: FakeLink, discovery: MultiCameraDiscovery,
                                key: CameraKey, log: RecordingLog) {
        let usb = FakeLink(items: card)
        await usb.set(writesListedSize: true)
        let wifi = FakeLink(items: card, mode: .wifi(.cameraNetwork), id: "wifi-camera", name: "ILCE-7CM2")
        let key = CameraKeys.key(for: usb.descriptor, material: nil)
        let discovery = MultiCameraDiscovery(links: [usb, wifi], knownKeys: [wifi.descriptor.id: key])
        let catalogue = InMemoryCatalogue()
        let log = RecordingLog()
        await catalogue.upsertCamera(CameraRecord(key: key, model: "ILCE-7CM2", friendlyName: "ILCE-7CM2",
                                                  lastSeen: listedAt, preferredCarrier: .wifi))
        await catalogue.saveListing(listing(for: key))
        let app = AppModel(discovery: discovery, services: services(log: log), catalogue: catalogue,
                           engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
                           settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
                           destinations: FakeDestinations(), cameraKey: CameraKeys.fromDescriptor)
        await app.scenePhaseChanged(.active)
        return (app, usb, wifi, discovery, key, log)
    }

    @Test func aUSBCameraPluggedInGoesLiveEvenWhileConnectIsOfferedOverWiFi() async throws {
        let r = await twoLinkRig()
        _ = await r.app.importNewPhotos(cameraWith: r.key, waitingForCamera: .zero)
        let (browse, run) = try #require(pushBrowse(r.app))
        #expect(await eventually { browse.offlineCard == .shown })
        await r.discovery.send(.appeared(r.wifi.descriptor))
        #expect(await eventually { browse.canConnect })
        // The cable goes in: the USB listing turns it live, though the Wi-Fi listing came first and offers Connect.
        await r.discovery.send(.appeared(r.usb.descriptor))
        #expect(await eventually { r.app.cameras.path == [r.usb.descriptor] })
        #expect(r.app.intents.pending?.camera == r.usb.descriptor.id)
        #expect(r.log.lines.contains("cameras: the camera shown as not connected is connected; opening its card"))
        // Nothing joined the Wi-Fi camera.
        #expect(await r.discovery.linksAsked[r.wifi.descriptor.id] == nil)
        await finish(r.app, run)
    }

    @Test func aLiveBrowseIsNeverOfferedConnect() async throws {
        let r = try await rig(listed: true)
        let browse = r.app.browseModel(for: r.descriptor)
        browse.offerConnect(true)
        #expect(!browse.canConnect)
        #expect(browse.offlineCard == nil)
        #expect(browse.phase != .notConnected)
    }

    // MARK: - The intent's timing

    @Test func theStandardTimingAnswersWithinTenSeconds() {
        let timing = NewPhotosTiming.standard
        #expect(timing.answer == .seconds(10))
        #expect(timing.catalogue + timing.camera < timing.answer)
    }

    @Test func theIntentAnswersWithinItsBudgetAndStartsTheImportOnceTheCardIsRead() async throws {
        let r = try await rig(listed: true)
        await r.link.set(listHangs: true)
        let timing = NewPhotosTiming(answer: .milliseconds(300), catalogue: .seconds(30), camera: .seconds(30))
        let started = ContinuousClock.now
        let asked = Task { await IntentHost.importNewPhotos(cameraWith: r.key, timing: timing, model: { _ in r.app }) }
        #expect(await eventually { r.app.cameras.path == [r.descriptor] })
        let (_, run) = try #require(pushBrowse(r.app))
        // The card is still being read when the budget ends: the answer says so, long before the old 20 s wait.
        #expect(await asked.value == .waitingForCard(choice: .photos))
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(!r.app.importer.hasJob)
        // ... and the import still starts once the card is read.
        await r.link.set(listHangs: false)
        #expect(await eventually { r.app.importer.hasJob })
        await finish(r.app, run)
    }

    @Test func aCameraThatIsntListedIsAnsweredAfterTheCameraWait() async throws {
        let r = try await rig()
        let timing = NewPhotosTiming(answer: .seconds(60), catalogue: .seconds(1), camera: .milliseconds(200))
        let started = ContinuousClock.now
        let start = await IntentHost.importNewPhotos(cameraWith: r.key, timing: timing, model: { _ in r.app })
        #expect(start == .waitingForConnection(choice: .photos, cardRead: true))
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func everyWaitEndsByTheDeadline() async throws {
        let r = try await rig()
        let started = ContinuousClock.now
        let start = await r.app.importNewPhotos(cameraWith: r.key, waitingForCamera: .seconds(60),
                                                waitingForImport: .seconds(60),
                                                answeringBy: started.advanced(by: .milliseconds(200)))
        #expect(start == .waitingForConnection(choice: .photos, cardRead: true))
        #expect(ContinuousClock.now - started < .seconds(10))
        // A deadline already past waits for nothing.
        #expect(AppModel.left(until: started) == .zero)
    }

    @Test func theCatalogueWaitIsBoundedByTheBudget() async {
        var limits: [Duration] = []
        let key = CameraKey(rawValue: "a")
        let timing = NewPhotosTiming(answer: .seconds(10), catalogue: .seconds(5), camera: .seconds(4))
        #expect(await IntentHost.importNewPhotos(cameraWith: key, timing: timing, model: { limits.append($0); return nil })
            == .appNotReady)
        let short = NewPhotosTiming(answer: .seconds(2), catalogue: .seconds(5), camera: .seconds(4))
        _ = await IntentHost.importNewPhotos(cameraWith: key, timing: short, model: { limits.append($0); return nil })
        #expect(limits == [.seconds(5), .seconds(2)])
    }

    // MARK: - Wording

    @Test func theAnswersAndTheLogWords() {
        #expect(NewPhotosWording.importAnswer(.waitingForConnection(choice: .staging, cardRead: true), camera: "ILCE-7CM2")
            == "ILCE-7CM2 isn't connected. Connect it while Shutter Bridge shows its card, and its new photos will be "
            + "staged.")
        #expect(AppModel.logWords(for: .waitingForConnection(choice: .photos, cardRead: true))
            == "the camera isn't connected (last-known card shown); waiting for it")
        #expect(AppModel.logWords(for: .waitingForConnection(choice: .photos, cardRead: false))
            == "the camera isn't connected (card never read); waiting for it")
        #expect(BrowseWording.notConnectedNextStep(carrier: .usb, canConnect: false)
            == "Connect it with its cable to read its card and import new photos.")
        #expect(BrowseWording.notConnectedNextStep(carrier: .wifi, canConnect: true)
            == "Tap Connect to reach it over Wi-Fi and read its card.")
        #expect(BrowseWording.notConnectedNextStep(carrier: .wifi, canConnect: false)
            == "Its card will be read once Shutter Bridge can reach it.")
        #expect(BrowseWording.emptyLastKnownDetail("8 Nov 2026 at 14:05")
            == "The card had no files when it was last read, on 8 Nov 2026 at 14:05.")
    }
}
