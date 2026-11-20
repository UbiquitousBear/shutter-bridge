import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import Observation
import PhotosBridge
import Testing
@testable import AppUI

// Auto-import on connect (backlog section 14) through `AppModel`, with the real engine, catalogue and Browse over fake
// links: a USB camera with the setting on opens Browse when it connects with the app in front and imports its new photos
// once the card is read, with the remembered choice; a Wi-Fi camera imports at the first listing of a visit the person
// started; at most once per connection, never with the app away, while a job runs, while the person chooses files, when
// "Import new photos" takes the listing, or from a reminder alone. The screen's part (pushing Browse when the path
// changes) is played by the test, as `LiveApp` plays it, and as `IntentsAppModelTests` does.

/// A central for the reminder's bench: nothing connects and nothing is scanned.
private final class QuietCentral: GATTConnector, ProximityScanning, @unchecked Sendable {
    let proximityReports: AsyncStream<ProximityReport> = AsyncStream { _ in }
    let powerState: AsyncStream<BluetoothPower> = AsyncStream { _ in }
    func connect(known: PeripheralID?) async throws(GATTFailure) -> any GATTLink { throw .bluetoothOff }
    func startProximityScan() async {}
    func restartProximityScan() async {}
    func stopProximityScan() async {}
}

private final class NoRefreshScheduled: ProximityRefreshScheduling {
    func scheduleRefresh(earliest date: Date?) {}
}

/// Photos access nobody has asked for yet, whose prompt waits for `answer(_:)`: the first *Import to Photos* is held at
/// the prompt, as on a first import.
private final class PromptedPhotosAccess: PhotosAuthorising, @unchecked Sendable {
    private let lock = NSLock()
    private var status = PhotosAuthorisation.notDetermined
    private var waiters: [CheckedContinuation<PhotosAuthorisation, Never>] = []

    var isAsking: Bool { lock.withLock { !waiters.isEmpty } }

    func authorisation() async -> PhotosAuthorisation { lock.withLock { status } }

    func requestReadWriteAuthorisation() async -> PhotosAuthorisation {
        await withCheckedContinuation { continuation in
            let answered: PhotosAuthorisation? = lock.withLock {
                guard status == .notDetermined else { return status }
                waiters.append(continuation)
                return nil
            }
            if let answered { continuation.resume(returning: answered) }
        }
    }

    func answer(_ answer: PhotosAuthorisation) {
        let waiting = lock.withLock {
            status = answer
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume(returning: answer) }
    }
}

/// The person's Import, started from an observation's change.
@MainActor
private final class PersonsImport {
    var task: Task<ImportRequestOutcome?, Never>?
}

@MainActor
@Suite("Auto-import on connect, through the app model", .timeLimit(.minutes(1)))
struct AutoImportAppModelTests {
    /// DSC00001 and DSC00002 are new, DSC00003 is rejected, DSC00004 has no capture date, C0001 is a video.
    static let card = [
        item("DSC00001.JPG", at: 10),
        item("DSC00002.JPG", at: 20),
        item("DSC00003.JPG", at: 30),
        item("DSC00004.JPG", at: nil),
        item("C0001.MP4", at: 40),
    ]

    /// MTP gets a one-body key from its device (as `USBLink`'s key material gives it), a Wi-Fi camera its serial's key;
    /// MSC and Remote Shoot keep the name-hash fallback.
    static let bodyKeying: CameraKeying = { descriptor, _ in
        switch descriptor.mode {
        case .usb(.mtp): CameraKeys.key(for: descriptor, material: "body-\(descriptor.id.rawValue)")
        case .wifi: CameraKeys.key(for: descriptor, material: "serial-\(descriptor.id.rawValue)")
        default: CameraKeys.key(for: descriptor, material: nil)
        }
    }

    struct Rig {
        let app: AppModel
        let discovery: ScriptedDiscovery
        let catalogue: InMemoryCatalogue
        let log: RecordingLog
        let destinations: FakeDestinations

        /// How many jobs were started (each gets its destinations).
        var jobs: Int { destinations.cameras.count }
        func lines(beginning prefix: String) -> [String] { log.lines.filter { $0.hasPrefix(prefix) } }
    }

    func rig(choice: DestinationKind = .photos, active: Bool = true,
             photos: any PhotosAuthorising = FakePhotosAccess()) async throws -> Rig {
        let catalogue = InMemoryCatalogue()
        let discovery = ScriptedDiscovery()
        let log = RecordingLog()
        let settings = InMemoryDestinationSettingStore()
        if choice == .staging { settings.save(DestinationSetting(preferred: .staging)) }
        let destinations = FakeDestinations()
        let app = AppModel(discovery: discovery, services: services(log: log), catalogue: catalogue,
                           engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
                           settingsStore: settings, photos: photos, destinations: destinations,
                           cameraKey: Self.bodyKeying)
        let rejected = Self.card[2].identity(camera: bodyMTPKey, timeZone: .current)!.contentKey
        try await catalogue.setMark(.reject, rating: 0, for: [rejected], at: Date(timeIntervalSince1970: 1_793_000_000))
        if active { await app.scenePhaseChanged(.active) }
        return Rig(app: app, discovery: discovery, catalogue: catalogue, log: log, destinations: destinations)
    }

    /// A camera discovery can open: a fake link over the card, given to discovery under its ID.
    func camera(_ r: Rig, id: String = "usb-camera", mode: CameraMode = .usb(.mtp), name: String = autoImportModel,
                items: [CameraItem] = card) async -> FakeLink {
        let link = FakeLink(items: items, mode: mode, id: id, name: name)
        await link.set(writesListedSize: true)
        await r.discovery.set(link: link, for: link.descriptor.id)
        return link
    }

    /// The camera's body row, with the setting on or off.
    func seedBody(_ r: Rig, _ link: FakeLink, name: String = autoImportModel, on: Bool = true) async {
        let key = await Self.bodyKeying(link.descriptor, link)
        await r.catalogue.upsertCamera(bodyRow(key, name, on: on, carrier: link.descriptor.carrier == .wifi ? .wifi : .usb))
    }

    func connect(_ r: Rig, _ camera: CameraDescriptor) async {
        await r.discovery.send(.appeared(camera))
        #expect(await eventually { r.app.cameras.cameras.contains { $0.id == camera.id } })
    }

    /// What `LiveApp` does when the path gets the camera: Browse's screen makes its model and runs it. A path that never
    /// gets the camera is a failure, not a quiet pass.
    func pushBrowse(_ r: Rig, _ camera: CameraDescriptor) async -> (BrowseModel, Task<Void, Never>)? {
        guard await eventually({ r.app.cameras.path.last?.id == camera.id }) else {
            Issue.record("Browse wasn't opened on \(camera.id.rawValue)")
            return nil
        }
        let browse = r.app.browseModel(for: camera)
        return (browse, Task { await browse.run() })
    }

    /// Waits until Browse has handed its listing on (`browseListed` counts each one).
    func listed(_ r: Rig, after revision: Int) async -> Bool {
        await eventually { r.app.intents.camerasRevision > revision }
    }

    /// Waits for a job to end, then stops every Browse run, so nothing runs on into the next test.
    func finish(_ r: Rig, _ runs: Task<Void, Never>...) async {
        if r.app.importer.isActive {
            #expect(await eventuallyLong {
                await r.app.importer.refresh()
                return r.app.importer.isFinished
            })
        }
        for run in runs {
            run.cancel()
            await run.value
        }
    }

    func jobFinished(_ r: Rig) async -> Bool {
        await eventuallyLong {
            await r.app.importer.refresh()
            return r.app.importer.isFinished
        }
    }

    // MARK: - USB

    @Test func aUSBCameraConnectingWithTheSettingOnOpensBrowseAndImportsTheNewPhotos() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await connect(r, link.descriptor)
        #expect(await eventually { r.app.cameras.path == [link.descriptor] })
        #expect(r.app.intents.navigation?.showsImport == false)
        #expect(r.app.intents.navigation?.importOverCamera == nil)
        guard let (browse, run) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await eventually { r.app.importer.hasJob })
        #expect(await eventually { browse.importNotice == "Importing 2 files automatically." })
        #expect(await eventually { r.app.intents.navigation?.showsImport == true })
        #expect(r.app.intents.navigation?.importOverCamera == link.descriptor.id)
        #expect(browse.selection.isEmpty && !browse.isSelecting)
        #expect(await jobFinished(r))
        #expect(Set(await link.fetched) == Set([Self.card[0].id, Self.card[1].id]))
        #expect(r.jobs == 1)
        let lines = r.lines(beginning: "auto-import:")
        #expect(lines == [
            "auto-import: a camera connected over USB (mtp): on; opening Browse",
            "auto-import: the card is read (usb); importing all new to Photos",
            "auto-import: started with 2 files to Photos",
        ])
        await finish(r, run)
    }

    @Test func itUsesTheRememberedStageChoice() async throws {
        let r = try await rig(choice: .staging)
        let link = await camera(r)
        await seedBody(r, link)
        await connect(r, link.descriptor)
        guard let (browse, run) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await eventually { browse.importNotice == "Staging 2 files automatically." })
        #expect(r.log.lines.contains("auto-import: the card is read (usb); importing all new to stage"))
        #expect(r.log.lines.contains("auto-import: started with 2 files to stage"))
        await finish(r, run)
    }

    @Test func withTheSettingOffAConnectionOpensNothing() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link, on: false)
        await connect(r, link.descriptor)
        #expect(await eventually {
            r.log.lines.contains("auto-import: a camera connected over USB (mtp): off (off for this camera)")
        })
        #expect(r.app.cameras.path.isEmpty)
        #expect(r.app.intents.navigation == nil)
        // No row has the setting on, so the camera's link isn't even asked for.
        #expect(await r.discovery.linkRequests.isEmpty)
        // A Browse the person opens lists, and starts nothing.
        let revision = r.app.intents.camerasRevision
        r.app.cameras.path = [link.descriptor]
        guard let (browse, run) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await listed(r, after: revision))
        #expect(browse.showsLiveCard)
        #expect(!r.app.importer.hasJob)
        await finish(r, run)
    }

    @Test func turningItOnWithTheCameraConnectedStartsNothing() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link, on: false)
        await connect(r, link.descriptor)
        #expect(await eventually { r.log.lines.contains { $0.hasSuffix(": off (off for this camera)") } })
        await r.app.autoImport.set(true, for: autoImportModel)
        #expect(r.app.autoImport.choices == [AutoImportChoice(name: autoImportModel, isOn: true)])
        let revision = r.app.intents.camerasRevision
        r.app.cameras.path = [link.descriptor]
        guard let (_, run) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await listed(r, after: revision))
        #expect(!r.app.importer.hasJob)
        #expect(r.app.cameras.path == [link.descriptor])
        await finish(r, run)
    }

    @Test func aSecondListingInTheSameConnectionStartsNothing() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await connect(r, link.descriptor)
        guard let (_, first) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await eventually { r.app.importer.hasJob })
        // SwiftUI makes Browse's screen again for the camera: its model lists the card again.
        let revision = r.app.intents.camerasRevision
        let again = r.app.browseModel(for: link.descriptor)
        let second = Task { await again.run() }
        #expect(await listed(r, after: revision))
        #expect(r.log.lines.contains("auto-import: not again for this connection (the card was listed again)"))
        #expect(await jobFinished(r))
        #expect(r.jobs == 1)
        await finish(r, first, second)
    }

    @Test func aReplugIsANewConnection() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await connect(r, link.descriptor)
        guard let (_, first) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await eventually { r.app.importer.hasJob })
        #expect(await jobFinished(r))
        await r.discovery.send(.disappeared(link.descriptor.id))
        #expect(await eventually { r.app.cameras.cameras.isEmpty && r.app.cameras.path.isEmpty })
        first.cancel()
        await first.value
        // Plugged in again: a new device, so a new connection.
        let replugged = await camera(r)
        await connect(r, replugged.descriptor)
        #expect(await eventually { r.app.cameras.path == [replugged.descriptor] })
        guard let (browse, second) = await pushBrowse(r, replugged.descriptor) else { return }
        #expect(await eventually { browse.importNotice == "No new photos to import." })
        #expect(r.log.lines.contains("auto-import: nothing new to Photos"))
        #expect(r.app.intents.navigation?.showsImport == false)
        #expect(r.jobs == 1)
        #expect(r.lines(beginning: "auto-import: a camera connected").count == 2)
        await finish(r, second)
    }

    @Test func aCameraConnectedWhileAwayIsDecidedWhenTheAppIsInFront() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await r.app.scenePhaseChanged(.background)
        await connect(r, link.descriptor)
        #expect(await eventually {
            r.log.lines.contains("auto-import: a camera connected over USB (mtp) with the app away; deciding when it is "
                + "in front")
        })
        #expect(r.app.cameras.path.isEmpty)
        await r.app.scenePhaseChanged(.active)
        #expect(r.log.lines.contains("auto-import: the app is in front; deciding 1 camera(s) connected while it was away"))
        #expect(r.app.cameras.path == [link.descriptor])
        guard let (_, run) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await eventually { r.app.importer.hasJob })
        await finish(r, run)
    }

    @Test func aCardReadWhileAwayStartsOnlyWhenTheAppIsBack() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await link.set(listHangs: true)
        await connect(r, link.descriptor)
        guard let (browse, run) = await pushBrowse(r, link.descriptor) else { return }
        await r.app.scenePhaseChanged(.background)
        let revision = r.app.intents.camerasRevision
        await link.set(listHangs: false)
        #expect(await listed(r, after: revision))
        #expect(browse.showsLiveCard)
        #expect(!r.app.importer.hasJob)
        #expect(r.log.lines.contains("auto-import: the card was read with the app away; waiting for it to be in front"))
        await r.app.scenePhaseChanged(.active)
        #expect(await eventually { r.app.importer.hasJob })
        #expect(await jobFinished(r))
        #expect(r.jobs == 1)
        await finish(r, run)
    }

    /// A return to the front decides only a card read with the app away, and only once: a connection left waiting for
    /// any other reason (its card listed while Browse couldn't import) waits for a listing, so a later lock and unlock
    /// never starts an import after the person has chosen and imported files themselves.
    @Test func aReturnDecidesOnlyACardReadWhileAwayAndOnlyOnce() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await connect(r, link.descriptor)
        guard let (browse, run) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await jobFinished(r))
        #expect(r.jobs == 1)
        #expect(browse.isReadyToImportAllNew)
        let id = link.descriptor.id
        let decided = r.lines(beginning: "auto-import: the card is read").count
        // The connection waiting again, as if its listing had come while Browse couldn't import (not read while away).
        var arms = AutoImportArms()
        let armed = arms.connected(link.descriptor)
        #expect(armed)
        arms.decided(id, .on)
        r.app.autoImportArms = arms
        await r.app.scenePhaseChanged(.background)
        await r.app.scenePhaseChanged(.active)
        try await Task.sleep(for: .milliseconds(100))
        #expect(r.lines(beginning: "auto-import: the card is read").count == decided)
        #expect(r.app.autoImportArms.state(of: id) == .waiting)
        // Read while away: decided at the first return (nothing new is left), and not at the next.
        r.app.autoImportArms.readWhileAway(id)
        await r.app.scenePhaseChanged(.background)
        await r.app.scenePhaseChanged(.active)
        #expect(await eventually { r.lines(beginning: "auto-import: the card is read").count == decided + 1 })
        #expect(await eventually { r.app.autoImportArms.state(of: id) == .ended(.started) })
        var again = AutoImportArms()
        _ = again.connected(link.descriptor)
        again.decided(id, .on)
        r.app.autoImportArms = again
        await r.app.scenePhaseChanged(.background)
        await r.app.scenePhaseChanged(.active)
        try await Task.sleep(for: .milliseconds(100))
        #expect(r.lines(beginning: "auto-import: the card is read").count == decided + 1)
        #expect(r.jobs == 1)
        await finish(r, run)
    }

    @Test func leavingBrowseBeforeTheCardIsReadEndsItForTheConnection() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await link.set(listHangs: true)
        await connect(r, link.descriptor)
        guard let (_, first) = await pushBrowse(r, link.descriptor) else { return }
        r.app.cameras.path = []
        #expect(r.log.lines.contains("auto-import: dropped: Browse was left before the card was read"))
        first.cancel()
        await link.set(listHangs: false)
        await first.value
        // Opened again in the same connection: the person's own visit, which imports nothing.
        let revision = r.app.intents.camerasRevision
        r.app.cameras.path = [link.descriptor]
        guard let (browse, second) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await listed(r, after: revision))
        #expect(browse.showsLiveCard)
        #expect(!r.app.importer.hasJob)
        await finish(r, second)
    }

    @Test func turningItOffBeforeTheCardIsReadStartsNothing() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await link.set(listHangs: true)
        await connect(r, link.descriptor)
        guard let (_, run) = await pushBrowse(r, link.descriptor) else { return }
        await r.app.autoImport.set(false, for: autoImportModel)
        await link.set(listHangs: false)
        #expect(await eventually {
            r.log.lines.contains("auto-import: the card is read (usb): off (off for this camera)")
        })
        #expect(!r.app.importer.hasJob)
        await finish(r, run)
    }

    @Test func aRunningJobHoldsBrowseBackAndEndsTheConnectionAtItsListing() async throws {
        let r = try await rig()
        let first = await camera(r, id: "usb-a")
        await seedBody(r, first)
        await first.set(bytesHangs: true)
        await connect(r, first.descriptor)
        guard let (_, runA) = await pushBrowse(r, first.descriptor) else { return }
        #expect(await eventually { r.app.importer.isActive })
        r.app.cameras.path = []
        // Another body, switched on, connects while the first one's job runs.
        let second = await camera(r, id: "usb-b", name: "ILCE-7M4")
        await seedBody(r, second, name: "ILCE-7M4")
        await connect(r, second.descriptor)
        #expect(await eventually {
            r.log.lines.contains("auto-import: a camera connected over USB (mtp): on; not opening Browse (a job is "
                + "running); it starts if the camera is opened")
        })
        #expect(r.app.cameras.path.isEmpty)
        // Opened by hand while the job still runs: its listing ends the connection's auto-import.
        r.app.cameras.path = [second.descriptor]
        guard let (_, runB) = await pushBrowse(r, second.descriptor) else { return }
        #expect(await eventually { r.log.lines.contains("auto-import: not started: a job is running") })
        #expect(r.jobs == 1)
        await r.app.importer.cancel()
        await finish(r, runA, runB)
    }

    @Test func anotherCamerasBrowseIsNotReplacedAndTheCameraImportsWhenOpened() async throws {
        let r = try await rig()
        let first = await camera(r, id: "usb-a", name: "ILCE-7M4")
        await seedBody(r, first, name: "ILCE-7M4", on: false)
        await connect(r, first.descriptor)
        r.app.cameras.path = [first.descriptor]
        guard let (_, runA) = await pushBrowse(r, first.descriptor) else { return }
        let second = await camera(r, id: "usb-b")
        await seedBody(r, second)
        await connect(r, second.descriptor)
        #expect(await eventually {
            r.log.lines.contains("auto-import: a camera connected over USB (mtp): on; not opening Browse (another "
                + "camera's Browse is open); it starts if the camera is opened")
        })
        #expect(r.app.cameras.path == [first.descriptor])
        // The person goes back and opens the second camera: its first listing imports.
        r.app.cameras.path = []
        r.app.cameras.path = [second.descriptor]
        guard let (browse, runB) = await pushBrowse(r, second.descriptor) else { return }
        #expect(await eventually { browse.importNotice == "Importing 2 files automatically." })
        #expect(await jobFinished(r))
        #expect(Set(await second.fetched) == Set([Self.card[0].id, Self.card[1].id]))
        #expect(await first.fetched.isEmpty)
        await finish(r, runA, runB)
    }

    @Test func thePersonsChoosingIsNeverReplaced() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await link.set(listHangs: true)
        await connect(r, link.descriptor)
        guard let (browse, run) = await pushBrowse(r, link.descriptor) else { return }
        browse.isSelecting = true
        await link.set(listHangs: false)
        #expect(await eventually { r.log.lines.contains("auto-import: not started: the person is choosing files") })
        #expect(!r.app.importer.hasJob)
        #expect(browse.isSelecting)
        await finish(r, run)
    }

    @Test func thePersonsImportStartedBeforeTheListingArrivedIsNeverAddedTo() async throws {
        let photos = PromptedPhotosAccess()
        let r = try await rig(photos: photos)
        let link = await camera(r)
        await seedBody(r, link)
        await link.set(listHangs: true)
        await connect(r, link.descriptor)
        guard let (browse, run) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await eventually { await link.listCount == 1 })
        // As soon as the grid shows the live card, and before Browse hands its listing on (the badges and the listing
        // are saved first), the person taps a photo and Import; Photos asks, the first time, which holds the Import.
        let person = PersonsImport()
        withObservationTracking { _ = browse.phase } onChange: {
            Task { @MainActor in
                browse.tap(Self.card[0])
                person.task = Task { await browse.importSelected() }
            }
        }
        let revision = r.app.intents.camerasRevision
        await link.set(listHangs: false)
        #expect(await listed(r, after: revision))
        #expect(person.task != nil)
        #expect(r.app.autoImportArms.state(of: link.descriptor.id) == .ended(.choosingFiles))
        #expect(r.log.lines.contains("auto-import: not started: the person is choosing files"))
        // Photos answers: the person's one file is imported.
        #expect(await eventually { photos.isAsking })
        photos.answer(.authorised)
        if let outcome = await person.task?.value {
            #expect(outcome == .started(1))
        } else {
            Issue.record("the person's Import didn't run")
        }
        #expect(await jobFinished(r))
        // A later lock and unlock with Browse still open starts nothing more.
        await r.app.scenePhaseChanged(.background)
        await r.app.scenePhaseChanged(.active)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(r.app.autoImportArms.state(of: link.descriptor.id) == .ended(.choosingFiles))
        #expect(r.jobs == 1)
        #expect(await link.fetched == [Self.card[0].id])
        #expect(!r.log.lines.contains { $0.contains("importing all new") })
        await finish(r, run)
    }

    @Test func aCableThatGoesUnderBrowseIsNotThePersonLeavingIt() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await link.set(listHangs: true)
        await connect(r, link.descriptor)
        guard let (browse, run) = await pushBrowse(r, link.descriptor) else { return }
        // The device's own removal reaches Browse before discovery's: Browse closes itself.
        await link.remove()
        #expect(await eventually { browse.phase == .gone && r.app.cameras.path.isEmpty })
        #expect(!r.log.lines.contains { $0.hasPrefix("auto-import: dropped") })
        // Until discovery says the camera went, its connection still waits (a session closed under an attached camera).
        #expect(r.app.autoImportArms.state(of: link.descriptor.id) == .waiting)
        await r.discovery.send(.disappeared(link.descriptor.id))
        #expect(await eventually { r.app.autoImportArms.state(of: link.descriptor.id) == nil })
        #expect(!r.log.lines.contains { $0.hasPrefix("auto-import: dropped") })
        await link.set(listHangs: false)
        await finish(r, run)
    }

    @Test func aListingThatFailsAsDisconnectedIsNotThePersonLeavingBrowse() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await link.set(listHangs: true)
        await connect(r, link.descriptor)
        guard let (browse, run) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await eventually { await link.listCount == 1 })
        // The cable is pulled during the listing, which fails as disconnected before discovery reports the removal.
        await link.set(listFailure: CameraLinkFailure(.disconnected))
        await link.set(listHangs: false)
        #expect(await eventually { browse.phase == .gone && r.app.cameras.path.isEmpty })
        #expect(r.app.autoImportArms.state(of: link.descriptor.id) == .waiting)
        await r.discovery.send(.disappeared(link.descriptor.id))
        #expect(await eventually { r.app.cameras.cameras.isEmpty })
        #expect(r.app.autoImportArms.state(of: link.descriptor.id) == nil)
        #expect(!r.log.lines.contains { $0.hasPrefix("auto-import: dropped") })
        #expect(!r.app.importer.hasJob)
        await finish(r, run)
    }

    @Test func anImportNewPhotosRequestImportsOnce() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await link.set(listHangs: true)
        await connect(r, link.descriptor)
        guard let (_, run) = await pushBrowse(r, link.descriptor) else { return }
        let key = await Self.bodyKeying(link.descriptor, link)
        #expect(await r.app.importNewPhotos(cameraWith: key, waitingForImport: .zero) == .waitingForCard(choice: .photos))
        await link.set(listHangs: false)
        #expect(await eventually { r.log.lines.contains("intents: import new photos: started with 2 files to Photos") })
        #expect(r.log.lines.contains("auto-import: an Import new photos request took this connection"))
        #expect(!r.log.lines.contains { $0.hasPrefix("auto-import: started") })
        #expect(await jobFinished(r))
        #expect(r.jobs == 1)
        await finish(r, run)
    }

    @Test func mscFollowsTheOneNamedBodyAndNotWithTwo() async throws {
        let r = try await rig()
        await r.catalogue.upsertCamera(bodyRow(bodyMTPKey, on: true))
        let msc = await camera(r, id: "usb-msc", mode: .usb(.massStorage), name: "Untitled")
        await connect(r, msc.descriptor)
        #expect(await eventually { r.app.cameras.path == [msc.descriptor] })
        #expect(r.log.lines.contains("auto-import: a camera connected over USB (msc): on; opening Browse"))
        await r.discovery.send(.disappeared(msc.descriptor.id))
        #expect(await eventually { r.app.cameras.cameras.isEmpty && r.app.cameras.path.isEmpty })
        // A second named body: MSC can't tell which one this is.
        await r.catalogue.upsertCamera(bodyRow(CameraKey(rawValue: "usb-device:another"), "ILCE-7M4", on: true))
        let again = await camera(r, id: "usb-msc", mode: .usb(.massStorage), name: "Untitled")
        await connect(r, again.descriptor)
        #expect(await eventually {
            r.log.lines.contains("auto-import: a camera connected over USB (msc): off (no camera name (MSC with no "
                + "single named camera, or never named))")
        })
        #expect(r.app.cameras.path.isEmpty)
    }

    @Test func aCardThatListsNoFilesOpensBrowseAndImportsNothing() async throws {
        // Remote Shoot is reported as MTP until its card is read, and lists nothing: Browse asks for MSC or MTP.
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await link.set(listFailure: CameraLinkFailure(.modeListsNoFiles))
        await connect(r, link.descriptor)
        guard let (browse, run) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await eventually { browse.phase == .listsNoFiles })
        #expect(!r.app.importer.hasJob)
        #expect(!r.log.lines.contains { $0.hasPrefix("auto-import: the card is read") })
        await finish(r, run)
    }

    @Test func aFailedFirstListingStartsOnTryAgain() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await link.set(listFailure: CameraLinkFailure(.noAnswer))
        await connect(r, link.descriptor)
        guard let (browse, run) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await eventually { if case .failed = browse.phase { true } else { false } })
        #expect(!r.app.importer.hasJob)
        await link.set(listFailure: nil)
        browse.retry()
        #expect(await eventually { r.app.importer.hasJob })
        #expect(await jobFinished(r))
        await finish(r, run)
    }

    @Test func aJobPausedByAPulledCableCarriesOnAndAutoImportStandsAside() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await link.set(bytesHangs: true)
        await connect(r, link.descriptor)
        guard let (_, run) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await eventually { r.app.importer.isActive })
        // The cable is pulled: the link goes (its download fails as disconnected), the job pauses, and Browse gives way.
        await link.close()
        await r.discovery.send(.disappeared(link.descriptor.id))
        #expect(await eventuallyLong {
            await r.app.importer.refresh()
            return r.app.importer.state == .paused(.cameraRemoved)
        })
        #expect(await eventually { r.app.cameras.path.isEmpty })
        // Plugged in again: the job carries on over the new link, and auto-import stands aside.
        let replugged = await camera(r)
        await replugged.set(bytesHangs: true)
        await connect(r, replugged.descriptor)
        #expect(await eventually {
            r.log.lines.contains("auto-import: a camera connected over USB (mtp): on; not opening Browse (a job is "
                + "running); it starts if the camera is opened")
        })
        #expect(await eventuallyLong { await replugged.bytesStarted > 0 })
        #expect(r.app.cameras.path.isEmpty)
        #expect(r.jobs == 1)
        await r.app.importer.cancel()
        await finish(r, run)
    }

    @Test func anUpdateAppearanceIsNotAConnection() async throws {
        let r = try await rig()
        let link = await camera(r)
        await seedBody(r, link)
        await connect(r, link.descriptor)
        #expect(await eventually { r.app.cameras.path == [link.descriptor] })
        // ImageCaptureCore renames the device: the same connection.
        let renamed = CameraDescriptor(id: link.descriptor.id, name: autoImportModel + " ", mode: .usb(.mtp))
        await r.discovery.send(.appeared(renamed))
        #expect(await eventually { r.app.cameras.cameras == [renamed] })
        #expect(r.app.autoImportArms.state(of: link.descriptor.id) == .waiting)
        #expect(r.lines(beginning: "auto-import: a camera connected").count == 1)
        r.app.cameras.path = []
    }

    // MARK: - Wi-Fi

    @Test func aWiFiCameraImportsOnlyAfterItIsOpenedOncePerVisit() async throws {
        let r = try await rig()
        let link = await camera(r, id: "wifi-camera", mode: .wifi(.cameraNetwork))
        let key = await Self.bodyKeying(link.descriptor, link)
        await r.discovery.set(key: key, for: link.descriptor.id)
        await seedBody(r, link)
        await connect(r, link.descriptor)
        #expect(await eventually { r.app.cameras.knownKeys[link.descriptor.id] == key })
        // Listed is not connected: nothing opens and nothing joins.
        #expect(r.app.cameras.path.isEmpty)
        #expect(await r.discovery.linkRequests.isEmpty)
        #expect(r.app.autoImportArms.state(of: link.descriptor.id) == nil)
        // The person taps the camera.
        r.app.cameras.path = [link.descriptor]
        guard let (browse, first) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await eventually { browse.importNotice == "Importing 2 files automatically." })
        #expect(r.log.lines.contains("auto-import: the card is read (wifi); importing all new to Photos"))
        // A second Browse model in the same visit lists again: not again.
        let revision = r.app.intents.camerasRevision
        let again = r.app.browseModel(for: link.descriptor)
        let second = Task { await again.run() }
        #expect(await listed(r, after: revision))
        #expect(r.log.lines.contains("auto-import: not again for this connection (the card was listed again)"))
        #expect(await jobFinished(r))
        #expect(r.jobs == 1)
        await finish(r, first, second)
        // Back, and tapped again: a new visit (and a new connection, the last one having been let go), which finds
        // nothing new.
        r.app.cameras.path = []
        _ = await camera(r, id: "wifi-camera", mode: .wifi(.cameraNetwork))
        r.app.cameras.path = [link.descriptor]
        guard let (third, run) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await eventually { third.importNotice == "No new photos to import." })
        #expect(r.jobs == 1)
        await finish(r, run)
    }

    @Test func aWiFiCamerasFirstConnectionFollowsItsBodysMTPRow() async throws {
        let r = try await rig()
        // Switched on through its MTP row; its Wi-Fi key isn't known before its first connection.
        await r.catalogue.upsertCamera(bodyRow(bodyMTPKey, on: true))
        let link = await camera(r, id: "wifi-first", mode: .wifi(.cameraNetwork))
        await connect(r, link.descriptor)
        r.app.cameras.path = [link.descriptor]
        guard let (browse, run) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await eventually { browse.importNotice == "Importing 2 files automatically." })
        #expect(browse.liveCardKey?.rawValue.hasPrefix("wifi-serial:") == true)
        #expect(r.log.lines.contains("auto-import: the card is read (wifi); importing all new to Photos"))
        await finish(r, run)
    }

    // MARK: - The reminder

    @Test func theRemindersImportNowCountsAsTheTapAndAReminderAloneStartsNothing() async throws {
        let central = QuietCentral()
        let store = InMemoryKeyValueStore()
        ReminderSettingsStore(store: store).save(ReminderSettings(enabled: true))
        let runtime = WirelessRuntime(bluetooth: OnDemandBluetooth(existing: central, make: { central }),
                                      refresh: NoRefreshScheduled(), notifier: FakeNotifier(.authorised), store: store)
        let catalogue = InMemoryCatalogue()
        let discovery = ScriptedDiscovery()
        let log = RecordingLog()
        let destinations = FakeDestinations()
        let app = AppModel(discovery: discovery, services: services(log: log), catalogue: catalogue,
                           engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
                           settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
                           destinations: destinations, cameraKey: Self.bodyKeying, wireless: runtime)
        let r = Rig(app: app, discovery: discovery, catalogue: catalogue, log: log, destinations: destinations)
        let rejected = Self.card[2].identity(camera: bodyMTPKey, timeZone: .current)!.contentKey
        try await catalogue.setMark(.reject, rating: 0, for: [rejected], at: Date(timeIntervalSince1970: 1_793_000_000))
        let link = await camera(r, id: "wifi-reminded", mode: .wifi(.cameraNetwork))
        let key = await Self.bodyKeying(link.descriptor, link)
        await discovery.set(key: key, for: link.descriptor.id)
        await seedBody(r, link)
        await app.scenePhaseChanged(.active)
        await connect(r, link.descriptor)

        // A proximity report and the reminder's other answers open nothing.
        let report = ProximityReport(peripheral: PeripheralID(UUID()), at: Date(), rssi: -60, manufacturerData: nil,
                                     name: autoImportModel)
        _ = await runtime.reminders.handle(ProximityArrival(camera: key, report: report, match: .storedIdentifier))
        await runtime.reminders.respond(.notNow, camera: key)
        #expect(await app.openCameraFromReminder() == false)
        #expect(app.cameras.path.isEmpty)
        #expect(await discovery.linkRequests.isEmpty)
        #expect(!app.importer.hasJob)

        // Import Now is the person's tap: the visit starts, and its first listing imports.
        await runtime.reminders.respond(.importNow, camera: key)
        #expect(await app.openCameraFromReminder())
        #expect(app.cameras.path == [link.descriptor])
        guard let (browse, run) = await pushBrowse(r, link.descriptor) else { return }
        #expect(await eventually { browse.importNotice == "Importing 2 files automatically." })
        #expect(log.lines.contains("auto-import: started with 2 files to Photos"))
        await finish(r, run)
    }
}
