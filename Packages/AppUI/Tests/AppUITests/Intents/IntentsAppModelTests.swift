import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import Testing
@testable import AppUI

// What the App Intents reach in the app (I16; backlog section 5, D7 (a)), driven through `AppModel` with the real
// engine, catalogue and Browse over a fake link: "Import new photos" opens Browse on the camera and starts what
// *Select All New* then *Import* start there, with the remembered choice; "How many new photos" answers from the live
// card over USB and from the last-known card otherwise; the camera picker lists the catalogue's cameras by name.
// The screen's part (pushing Browse when the path changes) is played by the test, as `LiveApp` plays it.

@MainActor
@Suite("App Intents: Import new photos, How many new photos and the camera picker, through the app model")
struct IntentsAppModelTests {
    /// DSC00001 and DSC00002 are new, DSC00003 is rejected, DSC00004 has no capture date, C0001 is a video.
    let card = [
        item("DSC00001.JPG", at: 10),
        item("DSC00002.JPG", at: 20),
        item("DSC00003.JPG", at: 30),
        item("DSC00004.JPG", at: nil),
        item("C0001.MP4", at: 40),
    ]

    struct Rig {
        let app: AppModel
        let link: FakeLink
        let discovery: FakeDiscovery
        let catalogue: InMemoryCatalogue
        let log: RecordingLog
        let settings: InMemoryDestinationSettingStore
        var key: CameraKey { CameraKeys.key(for: link.descriptor, material: nil) }
        var descriptor: CameraDescriptor { link.descriptor }
    }

    func rig(catalogue: InMemoryCatalogue = InMemoryCatalogue(), listed: Bool = true,
             mode: CameraMode = .usb(.massStorage), name: String = "Untitled",
             choice: DestinationKind = .photos) async throws -> Rig {
        let link = FakeLink(items: card, mode: mode, name: name)
        await link.set(writesListedSize: true)
        let discovery = FakeDiscovery(link: link)
        let log = RecordingLog()
        let settings = InMemoryDestinationSettingStore()
        if choice == .staging { settings.save(DestinationSetting(preferred: .staging)) }
        let app = AppModel(discovery: discovery, services: services(log: log), catalogue: catalogue,
                           engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
                           settingsStore: settings, photos: FakePhotosAccess(), destinations: FakeDestinations(),
                           cameraKey: CameraKeys.fromDescriptor)
        let key = CameraKeys.key(for: link.descriptor, material: nil)
        let rejected = card[2].identity(camera: key, timeZone: .current)!.contentKey
        try await catalogue.setMark(.reject, rating: 0, for: [rejected], at: Date(timeIntervalSince1970: 1_793_000_000))
        await discovery.allow()
        await app.scenePhaseChanged(.active)
        if listed {
            await discovery.send(.appeared(link.descriptor))
            #expect(await eventually { app.cameras.cameras == [link.descriptor] })
        }
        return Rig(app: app, link: link, discovery: discovery, catalogue: catalogue, log: log, settings: settings)
    }

    /// What `LiveApp` does when the path gets the camera: Browse's screen makes its model and runs it.
    func pushBrowse(_ r: Rig) async -> (BrowseModel, Task<Void, Never>)? {
        guard await eventually({ r.app.cameras.path == [r.descriptor] }) else { return nil }
        let browse = r.app.browseModel(for: r.descriptor)
        return (browse, Task { await browse.run() })
    }

    /// Waits for a job the test started to end, then stops Browse, so no job runs on into the next test.
    func finish(_ r: Rig, _ run: Task<Void, Never>) async {
        if r.app.importer.hasJob {
            #expect(await eventually {
                await r.app.importer.refresh()
                return r.app.importer.isFinished
            })
        }
        run.cancel()
        await run.value
    }

    // MARK: - Import new photos

    @Test func itOpensBrowseAndStartsSelectAllNewWithTheRememberedChoice() async throws {
        let r = try await rig()
        let asked = Task { await r.app.importNewPhotos(cameraWith: r.key, waitingForImport: .seconds(30)) }
        guard let (browse, run) = await pushBrowse(r) else {
            Issue.record("Browse wasn't opened")
            return
        }
        // The two new stills: not the reject, the undated still or the video.
        #expect(await asked.value == .requested(.started(2), choice: .photos))
        #expect(r.app.importer.hasJob)
        #expect(r.app.intents.navigation?.showsImport == true)
        #expect(r.app.intents.pending == nil)
        #expect(browse.selection.isEmpty && !browse.isSelecting)
        #expect(r.log.lines.contains("intents: import new photos: waiting for the card"))
        #expect(r.log.lines.contains("intents: import new photos: started with 2 files to Photos"))
        #expect(await eventually {
            await r.app.importer.refresh()
            return r.app.importer.isFinished
        })
        let fetched = await r.link.fetched
        #expect(Set(fetched) == Set([card[0].id, card[1].id]))
        await finish(r, run)
    }

    @Test func aStageChoiceStages() async throws {
        let r = try await rig(choice: .staging)
        #expect(r.app.importer.importChoice == .staging)
        let asked = Task { await r.app.importNewPhotos(cameraWith: r.key, waitingForImport: .seconds(30)) }
        guard let (_, run) = await pushBrowse(r) else {
            Issue.record("Browse wasn't opened")
            return
        }
        #expect(await asked.value == .requested(.started(2), choice: .staging))
        await finish(r, run)
    }

    @Test func withBrowseAlreadyShowingTheLiveCardItStartsAtOnce() async throws {
        let r = try await rig()
        r.app.cameras.path = [r.descriptor]
        let browse = r.app.browseModel(for: r.descriptor)
        let run = Task { await browse.run() }
        #expect(await eventually { browse.showsLiveCard && !browse.rejected.isEmpty })
        // A filter and a selection of the person's are replaced: every new file is picked.
        browse.filter = BrowseFilter(types: [.raw])
        browse.tap(card[0])
        let start = await r.app.importNewPhotos(cameraWith: r.key, waitingForImport: .seconds(30))
        #expect(start == .requested(.started(2), choice: .photos))
        #expect(!browse.filter.isActive)
        #expect(r.app.cameras.path == [r.descriptor])
        await finish(r, run)
    }

    @Test func nothingNewIsSaidAndStartsNothing() async throws {
        let r = try await rig()
        let key = r.key
        for file in card.prefix(2) {
            await r.catalogue.upsert(CatalogueRecord(identity: file.identity(camera: key, timeZone: .current)!,
                                                     format: .jpeg, state: .imported))
        }
        let asked = Task { await r.app.importNewPhotos(cameraWith: key, waitingForImport: .seconds(30)) }
        guard let (browse, run) = await pushBrowse(r) else {
            Issue.record("Browse wasn't opened")
            return
        }
        #expect(await asked.value == .requested(.nothingNew(staging: false), choice: .photos))
        #expect(!r.app.importer.hasJob)
        #expect(!browse.isSelecting)
        #expect(r.app.intents.navigation?.showsImport == false)
        await finish(r, run)
    }

    @Test func aCameraThatIsntListedIsNotConnected() async throws {
        let r = try await rig(listed: false)
        let start = await r.app.importNewPhotos(cameraWith: r.key, waitingForCamera: .zero)
        #expect(start == .notConnected)
        #expect(r.app.cameras.path.isEmpty)
        #expect(r.app.intents.navigation?.showsImport == false)
        #expect(r.log.lines.contains("intents: import new photos: the camera isn't connected"))
    }

    @Test func aCameraListedWhileItWaitsIsFound() async throws {
        let r = try await rig(listed: false)
        let asked = Task {
            await r.app.importNewPhotos(cameraWith: r.key, waitingForCamera: .seconds(30), waitingForImport: .seconds(30))
        }
        await r.discovery.send(.appeared(r.descriptor))
        guard let (_, run) = await pushBrowse(r) else {
            Issue.record("Browse wasn't opened")
            return
        }
        #expect(await asked.value == .requested(.started(2), choice: .photos))
        await finish(r, run)
    }

    @Test func itSaysItIsWaitingForTheCardAndStartsOnceTheCardIsRead() async throws {
        let r = try await rig()
        await r.link.set(listHangs: true)
        let asked = Task { await r.app.importNewPhotos(cameraWith: r.key, waitingForImport: .zero) }
        guard let (_, run) = await pushBrowse(r) else {
            Issue.record("Browse wasn't opened")
            return
        }
        #expect(await asked.value == .waitingForCard(choice: .photos))
        #expect(!r.app.importer.hasJob)
        await r.link.set(listHangs: false)
        #expect(await eventually { r.app.importer.hasJob && r.app.intents.navigation?.showsImport == true })
        await finish(r, run)
    }

    @Test func leavingBrowseBeforeTheCardIsReadDropsTheImport() async throws {
        let r = try await rig()
        await r.link.set(listHangs: true)
        let asked = Task { await r.app.importNewPhotos(cameraWith: r.key, waitingForImport: .zero) }
        guard let (browse, run) = await pushBrowse(r) else {
            Issue.record("Browse wasn't opened")
            return
        }
        #expect(await asked.value == .waitingForCard(choice: .photos))
        r.app.cameras.path = []
        await r.link.set(listHangs: false)
        #expect(await eventually { r.app.intents.pending == nil })
        #expect(browse.showsLiveCard)
        #expect(!r.app.importer.hasJob)
        #expect(r.log.lines.contains("intents: import new photos dropped: Browse was left"))
        await finish(r, run)
    }

    @Test func aNewerRequestReplacesOneStillWaiting() async throws {
        let r = try await rig()
        await r.link.set(listHangs: true)
        let first = await r.app.importNewPhotos(cameraWith: r.key, waitingForImport: .zero)
        #expect(first == .waitingForCard(choice: .photos))
        let replaced = r.app.intents.pending
        let second = await r.app.importNewPhotos(cameraWith: r.key, waitingForImport: .zero)
        #expect(second == .waitingForCard(choice: .photos))
        #expect(replaced?.result == .couldNotStart)
        #expect(r.app.intents.pending !== replaced)
        guard let (_, run) = await pushBrowse(r) else {
            Issue.record("Browse wasn't opened")
            return
        }
        await r.link.set(listHangs: false)
        #expect(await eventually { r.app.importer.hasJob })
        await finish(r, run)
    }

    // MARK: - How many new photos

    @Test func theCountIsLiveWhileAUSBCameraIsListedInBrowse() async throws {
        let r = try await rig()
        r.app.cameras.path = [r.descriptor]
        let browse = r.app.browseModel(for: r.descriptor)
        let run = Task { await browse.run() }
        #expect(await eventually { browse.showsLiveCard && !browse.rejected.isEmpty })
        #expect(await r.app.newPhotoCount(cameraWith: r.key) == .live(2))
        // A file staged meanwhile (from another screen) is read again before counting.
        await r.catalogue.markStaged(card[0].identity(camera: r.key, timeZone: .current)!, format: .jpeg,
                                     at: StagedLocation(root: .onThisIPhone, relativePath: "Staging/C/DSC00001.JPG"))
        #expect(await r.app.newPhotoCount(cameraWith: r.key) == .live(1))
        #expect(r.log.lines.contains("intents: new photo count from the live card: 1"))
        // Another camera's key has no live card, and no listing.
        #expect(await r.app.newPhotoCount(cameraWith: CameraKey(rawValue: "someone-else")) == .neverRead)
        await finish(r, run)
    }

    @Test func otherwiseTheCountIsTheLastKnownCards() async throws {
        let catalogue = InMemoryCatalogue()
        let r = try await rig(catalogue: catalogue, listed: false)
        #expect(await r.app.newPhotoCount(cameraWith: r.key) == .neverRead)
        let listedAt = Date(timeIntervalSince1970: 1_794_000_000)
        let entries = card.compactMap { file in
            file.identity(camera: r.key, timeZone: .current).map { CardListing.Entry(identity: $0, format: file.format) }
        }
        await catalogue.saveListing(CardListing(camera: r.key, listedAt: listedAt, entries: entries))
        #expect(await r.app.newPhotoCount(cameraWith: r.key) == .lastKnown(2, listedAt: listedAt))
        #expect(r.log.lines.contains("intents: new photo count from the last-known card: 2"))
    }

    @Test func aCatalogueThatCantBeReadIsUnavailable() async throws {
        let link = FakeLink(items: card)
        let catalogue = BrokenCatalogue()
        let log = RecordingLog()
        let app = AppModel(discovery: FakeDiscovery(link: link), services: services(log: log), catalogue: catalogue,
                           engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
                           settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
                           destinations: FakeDestinations(), cameraKey: CameraKeys.fromDescriptor)
        #expect(await app.newPhotoCount(cameraWith: CameraKey(rawValue: "a")) == .unavailable)
        #expect(log.lines.contains("intents: new photo count: catalogue error (Broken)"))
        #expect(await app.intentCameras().isEmpty)
    }

    // MARK: - The camera picker

    @Test func thePickerListsTheCataloguesCamerasByNameMostRecentFirst() async throws {
        let catalogue = InMemoryCatalogue()
        let earlier = Date(timeIntervalSince1970: 1_793_000_000)
        let later = Date(timeIntervalSince1970: 1_794_000_000)
        await catalogue.upsertCamera(CameraRecord(key: CameraKey(rawValue: "wifi-a"), model: "ILCE-7CM2",
                                                  friendlyName: "ILCE-7CM2", lastSeen: earlier, preferredCarrier: .wifi))
        await catalogue.upsertCamera(CameraRecord(key: CameraKey(rawValue: "usb-b"), lastSeen: later))
        let r = try await rig(catalogue: catalogue, mode: .usb(.mtp), name: "ILCE-7CM2")
        let cameras = await r.app.intentCameras()
        #expect(cameras == [
            IntentCamera(key: CameraKey(rawValue: "usb-b"), name: "Camera", lastConnected: later),
            IntentCamera(key: CameraKey(rawValue: "wifi-a"), name: "ILCE-7CM2", lastConnected: earlier),
            // Connected now and never listed: the catalogue has no row, so it is named as the Cameras screen names it.
            IntentCamera(key: r.key, name: "ILCE-7CM2", lastConnected: nil),
        ])
        #expect(cameras.allSatisfy { $0.id == $0.key.rawValue })
    }

    @Test func aCatalogueRowWithNoNameTakesTheConnectedCamerasName() async throws {
        let catalogue = InMemoryCatalogue()
        let link = FakeLink(items: [], mode: .usb(.mtp), name: "ILCE-7CM2")
        let key = CameraKeys.key(for: link.descriptor, material: nil)
        let seen = Date(timeIntervalSince1970: 1_794_000_000)
        await catalogue.upsertCamera(CameraRecord(key: key, lastSeen: seen))
        let r = try await rig(catalogue: catalogue, mode: .usb(.mtp), name: "ILCE-7CM2")
        #expect(r.key == key)
        #expect(await r.app.intentCameras() == [IntentCamera(key: key, name: "ILCE-7CM2", lastConnected: seen)])
    }

    // MARK: - Reaching the model

    @Test func theIntentsWaitForTheCatalogueToOpen() async {
        let discovery = FakeDiscovery(link: FakeLink(items: []))
        let catalogue = InMemoryCatalogue()
        let launcher = AppLauncher(
            openCatalogue: { catalogue },
            build: { store in
                AppModel(discovery: discovery, services: services(), catalogue: store,
                         engine: ImportEngine(catalogue: store, stagingDirectory: temporaryStaging()),
                         settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
                         destinations: FakeDestinations(), cameraKey: CameraKeys.fromDescriptor)
            }
        )
        // Nothing launched it: the wait launches it.
        let model = await launcher.readyModel(waitingUpTo: .seconds(30))
        #expect(model != nil)
        #expect(model === launcher.model)
        #expect(await launcher.readyModel(waitingUpTo: .zero) === model)
    }

    @Test func aCatalogueThatWontOpenGivesTheIntentsNoModel() async {
        struct NoStore: Error {}
        let discovery = FakeDiscovery(link: FakeLink(items: []))
        let launcher = AppLauncher(
            openCatalogue: { throw NoStore() },
            build: { store in
                AppModel(discovery: discovery, services: services(), catalogue: store,
                         engine: ImportEngine(catalogue: store, stagingDirectory: temporaryStaging()),
                         settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
                         destinations: FakeDestinations(), cameraKey: CameraKeys.fromDescriptor)
            }
        )
        #expect(await launcher.readyModel(waitingUpTo: .seconds(30)) == nil)
        // Tried again once, and still failing.
        #expect(await launcher.readyModel(waitingUpTo: .seconds(30)) == nil)
    }

    @Test func withNoLauncherThereIsNoModel() async {
        let kept = IntentHost.launcher
        IntentHost.launcher = nil
        #expect(await IntentHost.model(waitingUpTo: .zero) == nil)
        IntentHost.launcher = kept
    }
}
