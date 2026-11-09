import BLEKit
import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PTPKit
import PTPSimulator
import SimulatedLink
import Synchronization
import Testing
@testable import AppUI

// The live wiring's pure half (wireless plan W16): the scene as the Wi-Fi sessions read it, the one central made on first
// need, the reminder's notification responses, its count, the continued task kept to Wi-Fi jobs, the expiry's abort, the
// composition order of the scan and the reminder, the Wi-Fi connector over `WirelessSession` and `IPLink`, and the app
// model's routing of the scene and of each job. Every wait is bounded.

private let pairedID = UUID(uuidString: "0E1D2C3B-4A59-6877-8695-A4B3C2D1E0F0")!
/// 12:00 UTC on 9 Nov 2026: outside the default quiet hours.
private let noon = Date(timeIntervalSince1970: 1_794_225_600)
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

// MARK: - Fakes

/// A central: a connector and a scanner, recording what is asked of it.
private final class FakeCentral: GATTConnector, ProximityScanning, @unchecked Sendable {
    enum Call: Equatable { case connect, start, restart, stop }

    private let lock = NSLock()
    private var recorded: [Call] = []
    let proximityReports: AsyncStream<ProximityReport>
    private let reportSink: AsyncStream<ProximityReport>.Continuation
    private let powerStream: AsyncStream<BluetoothPower>
    private let powerSink: AsyncStream<BluetoothPower>.Continuation

    init() {
        (proximityReports, reportSink) = AsyncStream.makeStream()
        (powerStream, powerSink) = AsyncStream.makeStream()
    }

    var calls: [Call] { lock.withLock { recorded } }
    var powerState: AsyncStream<BluetoothPower> { powerStream }

    func connect(known: PeripheralID?) async throws(GATTFailure) -> any GATTLink {
        lock.withLock { recorded.append(.connect) }
        throw .bluetoothOff
    }

    func startProximityScan() async { lock.withLock { recorded.append(.start) } }
    func restartProximityScan() async { lock.withLock { recorded.append(.restart) } }
    func stopProximityScan() async { lock.withLock { recorded.append(.stop) } }

    func send(_ report: ProximityReport) { reportSink.yield(report) }
    func send(_ power: BluetoothPower) { powerSink.yield(power) }
}

/// Counts how often the central is made.
private final class Maker: Sendable {
    let central = FakeCentral()
    private let made = Mutex(0)
    var count: Int { made.withLock { $0 } }

    func make() -> any GATTConnector & ProximityScanning {
        made.withLock { $0 += 1 }
        return central
    }
}

private final class NoRefresh: ProximityRefreshScheduling {
    func scheduleRefresh(earliest date: Date?) {}
}

/// A link that can stop its transfer.
private actor AbortingLink: TransferAborting {
    nonisolated let descriptor = CameraDescriptor(id: .init(rawValue: "aborting"), name: "Camera",
                                                  mode: .wifi(.cameraNetwork))
    nonisolated let capabilities: CameraLinkCapabilities = .wifi
    nonisolated var events: AsyncStream<CameraLinkEvent> { AsyncStream { $0.finish() } }
    private(set) var aborts = 0

    func open() async throws(CameraLinkFailure) {}
    func list() async throws(CameraLinkFailure) -> [CameraItem] { [] }
    func info(of item: CameraItem.ID) async throws(CameraLinkFailure) -> CameraItem {
        throw CameraLinkFailure(.disconnected)
    }
    func thumbnail(of item: CameraItem.ID) async throws(CameraLinkFailure) -> Data { Data() }
    func bytes(of item: CameraItem.ID, into directory: URL, resuming: PartialDownload?,
               checkpoint: @escaping @Sendable (PartialDownload) -> Void,
               progress: @escaping @Sendable (_ bytesWritten: UInt64) -> Void) async throws(CameraLinkFailure) -> URL {
        throw CameraLinkFailure(.disconnected)
    }
    func close() async {}
    func abortCurrentTransfer() async { aborts += 1 }
}

/// A channel factory whose port refuses, recording where it was asked to connect.
private final class RefusingChannels: ByteChannelFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [PTPIPEndpoint] = []
    var endpoints: [PTPIPEndpoint] { lock.withLock { asked } }

    func open(_ endpoint: PTPIPEndpoint, timeout: Duration,
              state: @escaping @Sendable (ByteChannelState) -> Void) async throws(ByteChannelFailure) -> any ByteChannel {
        lock.withLock { asked.append(endpoint) }
        throw .refused
    }
}

private struct NoJoin: HotspotJoining {
    func apply(_ credentials: SonyWiFiCredentials) async throws(JoinFailure) { throw .userDenied }
    func leave(ssid: String) async {}
}

private struct NoPath: WiFiPathWatching {
    func gateway() async -> String? { nil }
    func waitForGateway(_ ip: String, timeout: Duration) async -> Bool { false }
}

/// Records which links were observed for which camera.
private actor Observer: WiFiLinkObserving {
    private(set) var observed: [CameraDescriptor.ID] = []
    func observe(_ link: any CameraLink, for id: CameraDescriptor.ID) { observed.append(id) }
}

/// The recovery's session, recording nothing: only its identity matters here.
private final class StubRecoverySession: WiFiRecoverySession, @unchecked Sendable {
    func prepareImport(bluetoothSwitchOnWhenAway: Bool) async throws(WirelessFailure) -> any CameraLink {
        throw .cancelled
    }
    func importFinished() async {}
}

private func report(_ id: UUID = pairedID, at date: Date = noon) -> ProximityReport {
    ProximityReport(peripheral: PeripheralID(id), at: date, rssi: -60,
                    manufacturerData: Data([0x2D, 0x01] + [UInt8](repeating: 0x5A, count: 20)), name: "ILCE-7CM2")
}

// MARK: - The scene

@Suite("Live wiring: the scene as the Wi-Fi sessions read it")
struct SceneForegroundSignalTests {
    @Test func itIsAwayUntilActiveAndInactiveChangesNothing() async {
        let signal = SceneForegroundSignal()
        #expect(await signal.isInForeground == false)   // a background relaunch has no scene
        signal.sceneChanged(.inactive)
        #expect(await signal.isInForeground == false)
        signal.sceneChanged(.active)
        #expect(await signal.isInForeground)
        signal.sceneChanged(.inactive)   // Control Centre, a system alert: still in front
        #expect(await signal.isInForeground)
        signal.sceneChanged(.background)
        #expect(await signal.isInForeground == false)
        signal.sceneChanged(.inactive)   // on the way back: still away until active
        #expect(await signal.isInForeground == false)
        signal.sceneChanged(.active)
        #expect(await signal.isInForeground)
    }
}

// MARK: - The central

@Suite("Live wiring: the one central, made on first need")
struct OnDemandBluetoothTests {
    @Test func nothingIsMadeUntilBluetoothIsNeeded() async {
        let maker = Maker()
        let bluetooth = OnDemandBluetooth(existing: nil, make: { maker.make() })
        await bluetooth.stopProximityScan()   // switching the reminder off at launch makes nothing
        let powers = Collector(bluetooth.powerState)
        #expect(await waitUntil(seconds: 5) { powers.all == [.unknown] })
        #expect(maker.count == 0)
        #expect(!bluetooth.isMade)

        await bluetooth.startProximityScan()
        #expect(maker.count == 1)
        #expect(bluetooth.isMade)
        _ = try? await bluetooth.connect(known: nil)
        await bluetooth.restartProximityScan()
        #expect(maker.count == 1)   // made once
        #expect(maker.central.calls == [.start, .connect, .restart])

        // From then on the central's reports and power are relayed.
        let reports = Collector(bluetooth.proximityReports)
        maker.central.send(report())
        maker.central.send(.poweredOn)
        #expect(await waitUntil(seconds: 5) { reports.all.count == 1 && powers.all == [.unknown, .poweredOn] })
        let later = Collector(bluetooth.powerState)
        #expect(await waitUntil(seconds: 5) { later.all == [.poweredOn] })   // starts with the state now
    }

    @Test func aCentralMadeAtLaunchIsUsedAndNeverMadeAgain() async {
        let maker = Maker()
        let existing = FakeCentral()
        let bluetooth = OnDemandBluetooth(existing: existing, make: { maker.make() })
        #expect(bluetooth.isMade)
        let reports = Collector(bluetooth.proximityReports)
        existing.send(report())   // the report that relaunched the app
        #expect(await waitUntil(seconds: 5) { reports.all.count == 1 })
        await bluetooth.stopProximityScan()
        #expect(existing.calls == [.stop])
        #expect(maker.count == 0)
    }
}

// MARK: - Responses, the count, the continued task and the abort

@Suite("Live wiring: responses, the count, the continued task and the abort")
struct LiveWiringPieceTests {
    @Test func aReminderResponseMapsToThePersonsAction() {
        let category = AppNotificationCategory.cameraNearby.identifier
        func action(_ id: String, category: String = category) -> ReminderAction? {
            ReminderResponseMapping.action(categoryIdentifier: category, actionIdentifier: id,
                                           defaultIdentifier: "default", dismissIdentifier: "dismiss")
        }
        #expect(action("default") == .opened)
        #expect(action("dismiss") == .dismissed)
        #expect(action(AppNotificationCategory.Action.importNowIdentifier) == .importNow)
        #expect(action(AppNotificationCategory.Action.notNowIdentifier) == .notNow)
        #expect(action(AppNotificationCategory.Action.snoozeIdentifier) == .snooze)
        #expect(action("something-else") == nil)
        // The pause notification's tap only opens the app.
        #expect(action("default", category: AppNotificationCategory.importPaused.identifier) == nil)
    }

    @Test func theCountIsTheLastKnownCardLessWhatIsImported() async throws {
        let catalogue = InMemoryCatalogue()
        let key = CameraKey(rawValue: "camera")
        #expect(await NotImportedCount.count(for: key, in: catalogue) == nil)   // never listed
        let identities = (1...3).map {
            ObjectIdentity(camera: key, folder: "DCIM/100MSDCF", filename: "DSC0000\($0).ARW",
                           captureDate: CaptureDate(rawValue: "20261109T12000\($0)")!,
                           size: 1_000)
        }
        await catalogue.saveListing(CardListing(camera: key, listedAt: noon,
                                                    entries: identities.map { .init(identity: $0, format: .raw) }))
        #expect(await NotImportedCount.count(for: key, in: catalogue) == 3)
        await catalogue.upsert(CatalogueRecord(identity: identities[0], format: .raw, state: .imported))
        #expect(await NotImportedCount.count(for: key, in: catalogue) == 2)
    }

    @MainActor
    @Test func theContinuedTaskIsBegunForWiFiJobsOnly() async throws {
        let run = FakeBackgroundRun()
        final class Box: @unchecked Sendable { var carrier: CameraCarrier? }
        let box = Box()
        let gated = WiFiOnlyBackgroundRun(run, carrier: { box.carrier })
        for carrier in [CameraCarrier.usb, nil] {
            box.carrier = carrier
            await #expect(throws: ImportBackgroundRunError.unavailable) {
                _ = try await gated.begin(title: "t", subtitle: "s")
            }
        }
        #expect(run.begins.isEmpty)
        box.carrier = .wifi
        _ = try await gated.begin(title: "t", subtitle: "s")
        #expect(run.begins.count == 1)
    }

    @Test func theExpiryStopsTheTransferOfALinkThatCanAndLeavesOthersAlone() async {
        let aborting = AbortingLink()
        await TransferAbort.abort(aborting)
        #expect(await aborting.aborts == 1)
        await TransferAbort.abort(FakeLink(items: []))   // USB adopts nothing: nothing happens
    }
}

// MARK: - The wireless runtime

@MainActor
@Suite("Live wiring: the scan and the reminder, in order")
struct WirelessRuntimeTests {
    @MainActor
    fileprivate struct Bench {
        let central = FakeCentral()
        let notifier = FakeNotifier(.authorised)
        let store = InMemoryKeyValueStore()
        let catalogue = InMemoryCatalogue()
        let runtime: WirelessRuntime
        let key = CameraKey(rawValue: "paired-camera")

        init(remindersOn: Bool) {
            if remindersOn { ReminderSettingsStore(store: store).save(ReminderSettings(enabled: true)) }
            let central = central
            runtime = WirelessRuntime(bluetooth: OnDemandBluetooth(existing: central, make: { central }),
                                      refresh: NoRefresh(), notifier: notifier, store: store, now: { noon },
                                      calendar: { utc })
        }

        func addCamera() async throws {
            await catalogue.upsertCamera(CameraRecord(key: key, model: "ILCE-7CM2", bluetoothPeripheralID: pairedID))
        }
    }

    @Test func aReportFromBeforeTheCatalogueOpenedRemindsOnceTheCamerasAreKnown() async throws {
        let b = Bench(remindersOn: true)
        try await b.addCamera()
        b.runtime.launchEarly()
        b.central.send(report())   // the discovery that relaunched the app, before the catalogue opened
        try await Task.sleep(for: .milliseconds(20))
        #expect(b.notifier.posts.isEmpty)
        await b.runtime.catalogueOpened(b.catalogue)
        #expect(await eventuallyLong { b.notifier.posts == [.cameraNearby(b.key, notImported: nil)] })
        #expect(b.central.calls.contains(.start))   // the stored setting switched the scan on
        #expect(b.runtime.reminders.cameraChoices.map(\.camera) == [b.key])
    }

    @Test func withTheReminderOffNothingIsScannedOrPosted() async throws {
        let b = Bench(remindersOn: false)
        try await b.addCamera()
        b.runtime.launchEarly()
        b.central.send(report())
        await b.runtime.catalogueOpened(b.catalogue)
        #expect(await eventuallyLong { b.central.calls == [.stop] })
        try await Task.sleep(for: .milliseconds(20))
        #expect(b.notifier.posts.isEmpty)
    }

    @Test func theSceneReachesTheSignalTheReminderAndTheScan() async throws {
        let b = Bench(remindersOn: true)
        try await b.addCamera()
        await b.runtime.catalogueOpened(b.catalogue)
        #expect(await eventuallyLong { b.runtime.proximity.isEnabled })
        b.runtime.sceneChanged(.active)
        #expect(b.runtime.reminders.isAppInFront)
        #expect(await b.runtime.foreground.isInForeground)
        await b.runtime.becameActive()
        #expect(b.central.calls.contains(.restart))   // coming to the front restarts the scan
        b.runtime.sceneChanged(.inactive)
        #expect(b.runtime.reminders.isAppInFront)
        b.runtime.sceneChanged(.background)
        #expect(!b.runtime.reminders.isAppInFront)
        #expect(await b.runtime.foreground.isInForeground == false)
    }

    @Test func notificationResponsesReachTheReminder() async {
        let b = Bench(remindersOn: true)
        let category = AppNotificationCategory.cameraNearby.identifier
        await b.runtime.respond(categoryIdentifier: category,
                                actionIdentifier: AppNotificationCategory.Action.snoozeIdentifier, camera: b.key,
                                defaultIdentifier: "default", dismissIdentifier: "dismiss")
        #expect(b.runtime.reminders.snoozedUntil == noon.addingTimeInterval(3600))
        await b.runtime.respond(categoryIdentifier: AppNotificationCategory.importPaused.identifier,
                                actionIdentifier: "default", camera: nil,
                                defaultIdentifier: "default", dismissIdentifier: "dismiss")
        #expect(b.runtime.reminders.cameraToOpen == nil)
        await b.runtime.respond(categoryIdentifier: category,
                                actionIdentifier: AppNotificationCategory.Action.importNowIdentifier, camera: b.key,
                                defaultIdentifier: "default", dismissIdentifier: "dismiss")
        #expect(b.runtime.reminders.cameraToOpen == b.key)
    }

    @Test func theCountComesFromTheCatalogueOnceItIsOpen() async throws {
        let b = Bench(remindersOn: true)
        try await b.addCamera()
        let identity = ObjectIdentity(camera: b.key, folder: "DCIM/100MSDCF", filename: "DSC00001.ARW",
                                      captureDate: CaptureDate(rawValue: "20261109T120000")!, size: 1_000)
        await b.catalogue.saveListing(CardListing(camera: b.key, listedAt: noon,
                                                      entries: [.init(identity: identity, format: .raw)]))
        b.runtime.launchEarly()
        await b.runtime.catalogueOpened(b.catalogue)
        #expect(await eventuallyLong { b.runtime.proximity.isEnabled })
        b.central.send(report())
        #expect(await eventuallyLong { b.notifier.posts == [.cameraNearby(b.key, notImported: 1)] })
    }
}

// MARK: - The Wi-Fi connector

@Suite("Live wiring: the Wi-Fi connector over WirelessSession and IPLink")
struct WirelessConnectionsTests {
    func connections(channels: any ByteChannelFactory = RefusingChannels()) -> WirelessConnections {
        WirelessConnections(connector: FakeCentral(), joiner: NoJoin(), path: NoPath(),
                            foreground: SceneForegroundSignal(inForeground: true), channels: channels)
    }

    func entry(_ id: String, typed: TypedCameraAddress? = nil) -> WiFiCameraEntry {
        WiFiCameraEntry(descriptor: CameraDescriptor(id: .init(rawValue: id), name: "Camera",
                                                     mode: .wifi(typed == nil ? .cameraNetwork : .otherNetwork)),
                        key: nil, peripheral: PeripheralID(pairedID), guid: UUID(), typed: typed)
    }

    @Test func eachCameraHasOneSessionWhichTheRecoveryReaches() {
        let c = connections()
        let a = entry("wifi-a")
        let first = c.session(for: a)
        let again = c.session(for: a)
        #expect((first as AnyObject) === (again as AnyObject))
        let other = c.session(for: entry("wifi-b"))
        #expect((first as AnyObject) !== (other as AnyObject))
        #expect(c.sessionCount == 2)
        #expect((c.recoverySession(for: a.id) as AnyObject?) === (first as AnyObject))
        #expect(c.recoverySession(for: .init(rawValue: "never-opened")) == nil)
    }

    @Test func aTypedCameraIsOpenedAtItsAddressObservedFirstAndAFailureIsReported() async throws {
        let channels = RefusingChannels()
        let c = connections(channels: channels)
        let observer = Observer()
        c.attach(observer: observer)
        let address = try #require(TypedCameraAddress("10.0.0.20:15740"))
        let camera = entry("wifi-typed", typed: address)
        let open = Task { () -> CameraLinkFailure? in
            do throws(CameraLinkFailure) {
                _ = try await c.openTyped(address, for: camera)
                return nil
            } catch {
                return error
            }
        }
        let failure = try #require(await bounded(open))
        #expect(failure != nil)
        #expect(await observer.observed == [camera.id])   // the observer had the link before it opened
        #expect(channels.endpoints.first == address.endpoint)
        #expect(c.sessionCount == 0)   // a typed camera joins nothing
    }

    @MainActor
    @Test func theSourceAsksTheLocalNetworkExplanationAndObservesNewLinks() async throws {
        let catalogue = InMemoryCatalogue()
        let c = connections()
        let wifi = WiFiSupport.make(catalogue: catalogue, connections: c,
                                    explained: InMemoryLocalNetworkExplainedRecord(hasExplained: false))
        let address = try #require(TypedCameraAddress("10.0.0.21"))
        let camera = await wifi.source.addTypedCamera(address)
        let open = Task { try? await wifi.source.cameraLink(for: camera.id) }
        #expect(await eventuallyLong { wifi.status.isExplainingLocalNetwork })
        wifi.status.declineExplaining()
        _ = await bounded(Task { await open.value })
        #expect(await wifi.source.openWasDeclined(for: camera.id))
        #expect(await wifi.source.observerCount == 0)   // nothing was opened

        let again = Task { try? await wifi.source.cameraLink(for: camera.id) }
        #expect(await eventuallyLong { wifi.status.isExplainingLocalNetwork })
        wifi.status.continueAfterExplaining()
        _ = await bounded(Task { await again.value })
        #expect(await wifi.source.observerCount == 1)   // the new link's events went to the source before it opened
        #expect(wifi.recoverySession?(camera.id) == nil)
    }

    @MainActor
    @Test func theRecoveryReachesTheCamerasSessionThroughTheSource() throws {
        let c = connections()
        let wifi = WiFiSupport.make(catalogue: InMemoryCatalogue(), connections: c)
        let camera = entry("wifi-recovered")
        let made = c.session(for: camera)
        let given = try #require(wifi.recoverySession?(camera.id) as? SourceAdoptingRecoverySession)
        #expect((given.base as AnyObject) === (made as AnyObject))   // the session the source opened the job through
        #expect(given.source === wifi.source)   // which is told of each link the recovery opens again
        #expect(given.id == camera.id)
    }
}

// MARK: - The app model

@MainActor
@Suite("Live wiring: the app model routes the scene and each job")
struct LiveAppModelWiringTests {
    fileprivate struct Bench {
        let app: AppModel
        let runtime: WirelessRuntime
        let notifier: FakeNotifier
        let run: FakeBackgroundRun
        let usb: ScriptedDiscovery
        let source: WiFiCameraSource
        let catalogue: InMemoryCatalogue
        let session: StubRecoverySession
        let store: InMemoryKeyValueStore
        let central: FakeCentral
    }

    fileprivate func bench(wifi withWiFi: Bool = true, wireless withWireless: Bool = true) -> Bench {
        let central = FakeCentral()
        let store = InMemoryKeyValueStore()
        let catalogue = InMemoryCatalogue()
        let notifier = FakeNotifier(.authorised)
        let run = FakeBackgroundRun()
        let runtime = WirelessRuntime(bluetooth: OnDemandBluetooth(existing: central, make: { central }),
                                      refresh: NoRefresh(), notifier: notifier, store: store, now: { noon },
                                      calendar: { utc })
        let source = WiFiCameraSource(catalogue: catalogue, connecting: FakeConnecting())
        let session = StubRecoverySession()
        let wifi = WiFiSupport(source: source, status: WiFiImportModel(source: source),
                               recoverySession: { _ in session })
        let usb = ScriptedDiscovery()
        let app = AppModel(
            discovery: CompositeDiscovery(sources: withWiFi ? [usb, source] : [usb]), services: services(),
            catalogue: catalogue, engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
            settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(), destinations: FakeDestinations(),
            cameraKey: CameraKeys.fromDescriptor, notifier: notifier, background: run,
            wifi: withWiFi ? wifi : nil, wireless: withWireless ? runtime : nil)
        return Bench(app: app, runtime: runtime, notifier: notifier, run: run, usb: usb, source: source,
                     catalogue: catalogue, session: session, store: store, central: central)
    }

    @Test func theSceneReachesTheWirelessPartsFirst() async {
        let b = bench()
        await b.app.scenePhaseChanged(.active)
        #expect(await b.runtime.foreground.isInForeground)
        #expect(b.runtime.reminders.isAppInFront)
        await b.app.scenePhaseChanged(.inactive)
        #expect(await b.runtime.foreground.isInForeground)
        await b.app.scenePhaseChanged(.background)
        #expect(await b.runtime.foreground.isInForeground == false)
        #expect(!b.runtime.reminders.isAppInFront)
        #expect(b.app.importer.isAway == !(await b.runtime.foreground.isInForeground))   // one phase (W14)
    }

    @Test func aUSBJobRunsNoContinuedTaskAndHoldsTheCamerasReminders() async throws {
        let b = bench()
        let link = FakeLink(items: [item("DSC00001.JPG"), item("DSC00002.JPG", at: 5)])
        await link.set(writesListedSize: true)
        let camera = ImportCamera(descriptor: link.descriptor, key: CameraKey(rawValue: "usb-camera"))
        _ = await b.app.importer.importItems(try await link.list(), from: camera, link: link)
        #expect(await eventuallyLong {
            await b.app.importer.refresh()
            return b.app.importer.isFinished
        })
        await b.app.reminderActivitySettled()
        #expect(b.run.begins.isEmpty)   // USB keeps its leaving rule
        #expect(b.notifier.withdrawals.contains(.cameraNearby(camera.key, notImported: nil)))   // began: reminder taken back
        #expect(!b.runtime.reminders.isBusy)   // ended
        #expect(b.app.wifiRecovery?.session == nil)
        #expect(b.app.importer.announcedJob == nil)
    }

    @Test func aWiFiJobGivesTheRecoveryItsSessionAndRunsTheContinuedTask() async throws {
        let b = bench()
        let link = FakeLink(items: [item("DSC00001.ARW"), item("DSC00002.ARW", at: 5)], mode: .wifi(.cameraNetwork),
                            id: "wifi-camera")
        await link.set(writesListedSize: true)
        let camera = ImportCamera(descriptor: link.descriptor, key: CameraKey(rawValue: "wifi-serial:abc"))
        _ = await b.app.importer.importItems(try await link.list(), from: camera, link: link)
        #expect(await eventuallyLong { b.run.begins.count == 1 })   // Wi-Fi jobs run in the continued task
        #expect(await eventuallyLong {
            await b.app.importer.refresh()
            return b.app.importer.isFinished
        })
        #expect(b.app.wifiRecovery?.session == nil)   // let go at the end
        await b.app.reminderActivitySettled()
        #expect(!b.runtime.reminders.isBusy)
    }

    @Test func theRecoveryGetsTheJobsSessionWhileItRuns() async throws {
        let b = bench()
        let link = FakeLink(items: [item("DSC00001.ARW")], mode: .wifi(.cameraNetwork), id: "wifi-camera")
        await link.set(writesListedSize: true)
        await link.set(bytesHangs: true)   // the job stays running
        let camera = ImportCamera(descriptor: link.descriptor, key: CameraKey(rawValue: "wifi-serial:abc"))
        _ = await b.app.importer.importItems(try await link.list(), from: camera, link: link)
        #expect(await eventuallyLong { b.app.wifiRecovery?.session != nil })
        #expect((b.app.wifiRecovery?.session as AnyObject?) === b.session)
        await b.app.reminderActivitySettled()
        #expect(b.runtime.reminders.isBusy)
        await b.app.importer.cancel()
        await link.set(bytesHangs: false)
        #expect(await eventuallyLong {
            await b.app.importer.refresh()
            return b.app.wifiRecovery?.session == nil
        })
    }

    @Test func importNowOpensBrowseOnTheCameraOnceItIsListed() async throws {
        let b = bench()
        let descriptor = CameraDescriptor(id: .init(rawValue: "usb-listed"), name: "Camera", mode: .usb(.mtp))
        let key = CameraKey(rawValue: "reminded")
        await b.runtime.reminders.respond(.importNow, camera: key)
        #expect(await b.app.openCameraFromReminder() == false)   // not listed yet: still asked for
        #expect(b.runtime.reminders.cameraToOpen == key)
        await b.usb.set(key: key, for: descriptor.id)
        await b.app.scenePhaseChanged(.active)
        await b.usb.send(.appeared(descriptor))
        #expect(await eventuallyLong { b.app.cameras.cameras.contains(descriptor) })
        #expect(await b.app.openCameraFromReminder())
        #expect(b.app.cameras.path == [descriptor])
        #expect(b.runtime.reminders.cameraToOpen == nil)
        // Asked again while it is being browsed: left as it is.
        await b.runtime.reminders.respond(.importNow, camera: key)
        #expect(await b.app.openCameraFromReminder())
        #expect(b.app.cameras.path == [descriptor])
    }

    @Test func aUSBCameraWithNoKnownKeyIsOpenedFromAReminderByItsLinksKey() async throws {
        let b = bench()
        let link = FakeLink(items: [], mode: .usb(.mtp), id: "usb-only")
        let descriptor = link.descriptor
        let key = await CameraKeys.fromDescriptor(descriptor, link)
        await b.usb.set(link: link, for: descriptor.id)   // discovery knows no key for it, as over USB
        await b.runtime.reminders.respond(.importNow, camera: key)
        await b.app.scenePhaseChanged(.active)
        await b.usb.send(.appeared(descriptor))
        #expect(await eventuallyLong { b.app.cameras.cameras.contains(descriptor) })
        #expect(await b.app.openCameraFromReminder())
        #expect(b.app.cameras.path == [descriptor])
        #expect(b.runtime.reminders.cameraToOpen == nil)
    }

    @Test func aReminderRequestNeverMatchedIsDroppedInTheBackground() async {
        let b = bench()
        await b.runtime.reminders.respond(.importNow, camera: CameraKey(rawValue: "not-here"))
        await b.app.scenePhaseChanged(.active)
        #expect(await b.app.openCameraFromReminder() == false)
        #expect(b.runtime.reminders.cameraToOpen != nil)
        await b.app.scenePhaseChanged(.background)
        #expect(b.runtime.reminders.cameraToOpen == nil)
    }

    @Test func aUSBConnectionHoldsTheCamerasRemindersUntilItsLinkCloses() async throws {
        let b = bench()
        let link = FakeLink(items: [item("DSC00001.JPG")], mode: .usb(.mtp), id: "usb-browsed")
        let descriptor = link.descriptor
        let key = await CameraKeys.fromDescriptor(descriptor, link)
        let connection = ReminderActivityEntry(activity: .connection, camera: key)
        await b.usb.set(link: link, for: descriptor.id)
        await b.app.scenePhaseChanged(.active)
        await b.usb.send(.appeared(descriptor))
        #expect(await eventuallyLong { b.app.cameras.cameras.contains(descriptor) })
        let browse = b.app.browseModel(for: descriptor)
        let run = Task { await browse.run() }
        #expect(await eventuallyLong {
            await b.app.reminderActivitySettled()
            return b.runtime.reminders.activities.contains(connection)
        })
        #expect(b.notifier.withdrawals.contains(.cameraNearby(key, notImported: nil)))   // a reminder showing is taken back
        #expect(ReminderHoldStore(store: b.store).holds(now: noon)[key] != nil)
        run.cancel()
        #expect(await bounded(run) != nil)
        #expect(await eventuallyLong {
            await b.app.reminderActivitySettled()
            return !b.runtime.reminders.isBusy
        })
        #expect(await link.closed)
        #expect(ReminderHoldStore(store: b.store).holds(now: noon)[key] != nil)   // the hold runs on from the end
    }

    @Test func theScanHearsOfCamerasAddedInFrontWhenTheAppGoesToTheBackground() async throws {
        let b = bench()
        await b.runtime.catalogueOpened(b.catalogue)
        try await Task.sleep(for: .milliseconds(20))   // the model's own opening has run by now
        #expect(b.runtime.reminders.cameraChoices.isEmpty)
        let key = CameraKey(rawValue: "first-import")
        await b.catalogue.upsertCamera(CameraRecord(key: key, model: "ILCE-7CM2", bluetoothPeripheralID: pairedID))
        await b.app.scenePhaseChanged(.background)
        #expect(b.runtime.reminders.cameraChoices.map(\.camera) == [key])
    }

    @Test func theSetupSheetsPairOverTheAppsOneCentralAndListATypedCamera() async throws {
        let b = bench()
        let setup = try #require(b.app.wirelessSetup)
        #expect(setup.canPair)
        setup.showPairing()
        let onboarding = try #require(setup.onboarding)
        await onboarding.start()
        #expect(b.central.calls.contains(.connect))   // the pairing check went through the one central
        setup.close()

        await b.app.scenePhaseChanged(.active)
        setup.showTypedAddress()
        let typed = try #require(setup.typedAddress)
        typed.text = "10.0.0.12"
        #expect(await typed.add())
        #expect(setup.sheet == nil)
        #expect(await eventuallyLong { b.app.cameras.cameras.contains { $0.carrier == .wifi } })
    }

    @Test func withoutBluetoothThereIsNoPairingAndWithoutWiFiNoSetupAtAll() {
        let noBluetooth = bench(wireless: false)
        let setup = noBluetooth.app.wirelessSetup
        #expect(setup != nil)
        #expect(setup?.canPair == false)
        let usbOnly = bench(wifi: false)
        #expect(usbOnly.app.wirelessSetup == nil)
        #expect(usbOnly.app.wifiRecovery == nil)
    }
}

// MARK: - The reminder's connection hold

@MainActor
@Suite("Live wiring: when a camera counts as connected for the reminder")
struct ConnectionHoldsTests {
    final class Recorder {
        var calls: [String] = []
    }

    func holds(held: @escaping @MainActor (any CameraLink) -> Bool) -> (ConnectionHolds, Recorder) {
        let holds = ConnectionHolds(isHeld: held)
        let recorder = Recorder()
        holds.onBegin = { recorder.calls.append("begin \($0.rawValue)") }
        holds.onEnd = { recorder.calls.append("end \($0.rawValue)") }
        return (holds, recorder)
    }

    @Test func aHeldLinkBeginsWhenKeyedAndEndsWhenClosed() {
        let link = FakeLink(items: [])
        let (holds, recorder) = holds(held: { _ in true })
        holds.keyed(link, as: CameraKey(rawValue: "a"))
        holds.keyed(link, as: CameraKey(rawValue: "a"))   // keyed again (a second Browse): nothing new
        holds.acquired(link)
        holds.closed(link)
        holds.closed(link)
        #expect(recorder.calls == ["begin a", "end a"])
    }

    @Test func aLinkKeyedBeforeItIsHeldBeginsWhenAcquired() {
        let link = FakeLink(items: [])
        let held = Recorder()   // held once it has a call
        let (holds, recorder) = holds(held: { _ in !held.calls.isEmpty })
        holds.keyed(link, as: CameraKey(rawValue: "a"))   // the reconnect's comparison
        #expect(recorder.calls.isEmpty)
        held.calls.append("acquire")
        holds.acquired(link)
        holds.closed(link)
        #expect(recorder.calls == ["begin a", "end a"])
    }

    @Test func aLinkOnlyComparedNeverBeginsAndAnUnkeyedLinkDoesNothing() {
        let compared = FakeLink(items: [])
        let other = FakeLink(items: [])
        let (holds, recorder) = holds(held: { _ in false })
        holds.keyed(compared, as: CameraKey(rawValue: "a"))
        holds.closed(compared)
        holds.acquired(other)
        holds.closed(other)
        #expect(recorder.calls.isEmpty)
    }

    @Test func twoLinksToOneCameraEndOnlyWhenBothHaveClosed() {
        let first = FakeLink(items: [])
        let second = FakeLink(items: [])
        let (holds, recorder) = holds(held: { _ in true })
        holds.keyed(first, as: CameraKey(rawValue: "a"))
        holds.keyed(second, as: CameraKey(rawValue: "a"))
        holds.closed(first)
        #expect(recorder.calls == ["begin a"])
        holds.closed(second)
        #expect(recorder.calls == ["begin a", "end a"])
    }

    @Test func aWiFiNameHashKeyIsNoCamerasKey() {
        let link = FakeLink(items: [], mode: .wifi(.cameraNetwork))
        let (holds, recorder) = holds(held: { _ in true })
        holds.keyed(link, as: CameraKeys.key(for: link.descriptor, material: nil))
        holds.closed(link)
        #expect(recorder.calls.isEmpty)
    }
}

// MARK: - The source, the recovery, the continued task and the reminder together

/// The scripted session as the recovery reaches it too, as the live `WirelessSession` is both.
extension FakeSession: WiFiRecoverySession {
    func prepareImport(bluetoothSwitchOnWhenAway: Bool) async throws(WirelessFailure) -> any CameraLink {
        try await prepareImport()
    }
}

/// A background run that notes, at each finish, how many times the session had been told the import finished.
private final class RunNotingTheSession: ImportBackgroundRun, @unchecked Sendable {
    final class Handle: ImportBackgroundHandle, @unchecked Sendable {
        let expired: AsyncStream<Void>
        private let sink: AsyncStream<Void>.Continuation
        private let lock = NSLock()
        private var storedUpdates = 0
        private let onFinish: @Sendable () -> Void

        init(onFinish: @escaping @Sendable () -> Void) {
            (expired, sink) = AsyncStream.makeStream(of: Void.self)
            self.onFinish = onFinish
        }

        var updates: Int { lock.withLock { storedUpdates } }
        func update(completedBytes: Int64, totalBytes: Int64, title: String?, subtitle: String?) {
            lock.withLock { storedUpdates += 1 }
        }
        func finish(success: Bool) {
            onFinish()
            sink.finish()
        }
    }

    private let lock = NSLock()
    private var noted: [Int] = []
    private var storedHandles: [Handle] = []
    private let read: @Sendable () -> Int

    init(read: @escaping @Sendable () -> Int) { self.read = read }

    /// `importFinished` calls the session had had at each finish.
    var finishesSaw: [Int] { lock.withLock { noted } }
    var handles: [Handle] { lock.withLock { storedHandles } }

    func begin(title: String, subtitle: String) async throws -> any ImportBackgroundHandle {
        let read = self.read
        let handle = Handle(onFinish: { [weak self] in
            let count = read()
            self?.lock.withLock { self?.noted.append(count) }
        })
        lock.withLock { storedHandles.append(handle) }
        return handle
    }
}

@MainActor
@Suite("Live wiring: the Wi-Fi source with the recovery, the continued task and the reminder", .timeLimit(.minutes(1)))
struct LiveWiFiTogetherTests {
    fileprivate struct Bench {
        let app: AppModel
        let runtime: WirelessRuntime
        let source: WiFiCameraSource
        let session: FakeSession
        let camera: CameraDescriptor
        let key: CameraKey
        let run: any ImportBackgroundRun

        var importCamera: ImportCamera { ImportCamera(descriptor: camera, key: key) }

        func finished() async -> Bool {
            await eventuallyLong {
                await app.importer.refresh()
                return app.importer.isFinished
            }
        }
    }

    /// A Wi-Fi camera that has connected before (a catalogue row with its key), the source over scripted sessions, the
    /// recovery reaching the same sessions through `WiFiSupport.recoverySessions`, and the app with the reminder.
    fileprivate func bench(remindersOn: Bool = false,
                           run makeRun: (FakeSession) -> any ImportBackgroundRun = { _ in FakeBackgroundRun() })
        async throws -> Bench {
        let store = InMemoryKeyValueStore()
        if remindersOn { ReminderSettingsStore(store: store).save(ReminderSettings(enabled: true)) }
        let central = FakeCentral()
        let notifier = FakeNotifier(.authorised)
        let runtime = WirelessRuntime(bluetooth: OnDemandBluetooth(existing: central, make: { central }),
                                      refresh: NoRefresh(), notifier: notifier, store: store, now: { noon },
                                      calendar: { utc })
        let catalogue = InMemoryCatalogue()
        let key = CameraKey(rawValue: "wifi-serial:together")
        await catalogue.upsertCamera(CameraRecord(key: key, preferredCarrier: .wifi, ptpipGUID: UUID()))
        let connecting = FakeConnecting()
        let source = WiFiCameraSource(catalogue: catalogue, connecting: connecting)
        try await source.start()
        let entry = try #require(await source.cameras.first)
        let session = try #require(connecting.session(for: entry) as? FakeSession)
        let wifi = WiFiSupport(source: source, status: WiFiImportModel(source: source),
                               recoverySession: WiFiSupport.recoverySessions({ connecting.fakeSession($0) },
                                                                             source: source))
        let run = makeRun(session)
        let app = AppModel(
            discovery: CompositeDiscovery(sources: [source]), services: services(), catalogue: catalogue,
            engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
            settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(), destinations: FakeDestinations(),
            cameraKey: CameraKeys.fromDescriptor, notifier: notifier, background: run, wifi: wifi, wireless: runtime)
        return Bench(app: app, runtime: runtime, source: source, session: session, camera: entry.descriptor, key: key,
                     run: run)
    }

    private static let chunk: UInt64 = 64 * 1024
    private static let card = ScriptedCard(objects: [
        .init(handle: PTPObjectHandle(rawValue: 1), folder: "DCIM/100MSDCF", filename: "DSC00001.ARW",
              size: 4 * chunk + 11, captureDateRaw: "20261101T090000", format: .sonyARW),
        .init(handle: PTPObjectHandle(rawValue: 2), folder: "DCIM/100MSDCF", filename: "DSC00002.ARW",
              size: 8 * chunk + 13, captureDateRaw: "20261101T090002", format: .sonyARW),
    ])
    private static let victim = "DSC00002.ARW"
    private static let cut: UInt64 = 3 * chunk

    /// Whether a download of the victim is held part-way on `link` (a bounded poll).
    private func held(_ link: SimulatedCameraLink) async -> Bool {
        let flag = HeldFlag()
        Task { await link.waitUntilHeld(Self.victim); flag.set() }
        return await eventuallyLong { flag.isSet }
    }

    @Test func afterARecoveryTheJobsNewLinkStaysOpenAndTheRecoveredJobsEndStartsTheStay() async throws {
        let b = try await bench()
        let first = SimulatedCameraLink(card: Self.card, mode: .wifi(.cameraNetwork), honoursCancellation: true,
                                        chunkSize: Self.chunk)
        await first.script(Self.victim, .holdAfter(Self.cut))
        let second = await first.replugged()
        await second.script(Self.victim, .holdAfter(Self.cut + Self.chunk))
        try await second.open()   // as `WirelessSession.prepareImport` gives it: open
        b.session.script(.success(first), .success(second))

        let opened = try await b.source.cameraLink(for: b.camera.id)
        #expect((opened as AnyObject) === first)
        try await first.open()
        let items = try await first.list()
        #expect(await b.app.importer.importItems(items, from: b.importCamera, link: first) == .started(2))
        #expect(await held(first))
        // Browse isn't open: the import holds the only lease. The session drops, and the recovery reopens through it.
        await first.loseSession()
        #expect(await held(second))
        #expect(b.session.count("prepare") == 2)
        // The old link's last holder letting go wasn't taken for the import's end: the job's new link is still open.
        #expect(b.session.count("importFinished") == 0)
        #expect(await b.source.hasLiveLink(for: b.camera.id))
        let browsed = try await b.source.cameraLink(for: b.camera.id)   // Browse opened now gets the job's link
        #expect((browsed as AnyObject) === second)
        #expect(b.session.count("prepare") == 2)

        _ = await second.release(Self.victim)
        #expect(await b.finished())
        #expect(b.app.importer.state == .finished(.completed))
        // The recovered job's end, its link's last holder letting go, starts the stay.
        #expect(await waitUntil { b.session.count("importFinished") == 1 })
    }

    @Test func aFinishedWiFiJobLetsTheCameraGoBeforeItsContinuedTaskIsFinished() async throws {
        let b = try await bench(run: { session in RunNotingTheSession(read: { session.count("importFinished") }) })
        let run = try #require(b.run as? RunNotingTheSession)
        let link = FakeLink(items: [item("DSC00001.ARW")], mode: .wifi(.cameraNetwork), id: "wifi-together")
        await link.set(writesListedSize: true)
        await link.set(bytesHangs: true)   // the job runs until it is cancelled
        b.session.script(.success(link))
        _ = try await b.source.cameraLink(for: b.camera.id)
        _ = await b.app.importer.importItems(try await link.list(), from: b.importCamera, link: link)
        #expect(await eventuallyLong { run.handles.first.map { $0.updates > 0 } ?? false })   // the run is live
        await b.app.importer.cancel()
        await link.set(bytesHangs: false)
        #expect(await b.finished())
        #expect(await eventuallyLong { run.finishesSaw.count == 1 })
        #expect(run.finishesSaw == [1])   // the session had been told the import finished before the run was
    }

    @Test func anExpiryWithTheAppAwayLetsTheCameraGoAndTheJobKeepsItsLease() async throws {
        let b = try await bench(run: { _ in FakeBackgroundRun() })
        let run = try #require(b.run as? FakeBackgroundRun)
        let link = FakeLink(items: [item("DSC00001.ARW")], mode: .wifi(.cameraNetwork), id: "wifi-together")
        await link.set(writesListedSize: true)
        await link.set(bytesHangs: true)
        b.session.script(.success(link), .success(FakeWiFiLink(serial: nil)))
        _ = try await b.source.cameraLink(for: b.camera.id)
        _ = await b.app.importer.importItems(try await link.list(), from: b.importCamera, link: link)
        #expect(await eventuallyLong { run.handles.first.map { !$0.updates.isEmpty } ?? false })
        await b.app.scenePhaseChanged(.background)
        #expect(b.session.count("importFinished") == 0)   // the import runs on in the continued task

        try #require(run.handles.first).expire()
        #expect(await eventuallyLong {
            await b.app.importer.refresh()
            return b.app.importer.state == .paused(.taskExpired)
        })
        // The session was told, so in the background it leaves the camera's network; the job keeps its lease.
        #expect(await waitUntil { b.session.count("importFinished") == 1 })
        #expect(await !b.source.hasLiveLink(for: b.camera.id))
        #expect(b.app.leases.holders(of: link) == 1)
        // Back in front, the camera is connected again rather than handed out closed (Continue's lookup).
        await b.app.scenePhaseChanged(.active)
        _ = try await b.source.cameraLink(for: b.camera.id)
        #expect(b.session.count("prepare") == 2)
        await b.app.importer.cancel()
        await link.set(bytesHangs: false)
    }

    @Test func browseLeftOpenOnAWiFiCameraNoLongerHoldsRemindersOnceTheAppHasLetItGo() async throws {
        let b = try await bench(remindersOn: true)
        b.session.script(.success(FakeWiFiLink(serial: nil, items: [item("DSC00001.ARW", at: 10, size: 1_000)])))
        await b.app.scenePhaseChanged(.active)
        #expect(await eventuallyLong { b.app.cameras.cameras.contains(b.camera) })
        let browse = b.app.browseModel(for: b.camera)
        let browsing = Task { await browse.run() }
        #expect(await eventuallyLong { browse.phase == .listed })
        let connection = ReminderActivityEntry(activity: .connection, camera: b.key)
        #expect(await eventuallyLong {
            await b.app.reminderActivitySettled()
            return b.runtime.reminders.activities.contains(connection)
        })

        // Swiped home with Browse still open: the camera is let go, so it is no longer connected.
        await b.app.scenePhaseChanged(.background)
        #expect(b.session.count("importFinished") == 1)
        #expect(await eventuallyLong {
            await b.app.reminderActivitySettled()
            return !b.runtime.reminders.isBusy
        })
        // Another camera arriving is reminded of.
        let other = CameraKey(rawValue: "another-camera")
        let arrival = ProximityArrival(camera: other, report: report(), match: .storedIdentifier)
        #expect(await b.runtime.reminders.handle(arrival) == .posted(other))

        browsing.cancel()
        #expect(await bounded(browsing) != nil)
    }

    @Test func theReminderReadsItsSettingsAgainWhenItAppliesThem() async {
        // Made while the store reads as empty (before the first unlock after a restart).
        let store = InMemoryKeyValueStore()
        let model = ReminderModel(settings: ReminderSettingsStore(store: store), holds: ReminderHoldStore(store: store),
                                  notifier: FakeNotifier(.authorised), now: { noon }, calendar: { utc })
        #expect(!model.settings.enabled)
        let muted = CameraKey(rawValue: "muted-camera")
        var stored = ReminderSettings(enabled: true)
        stored.mutedCameras = [muted]
        ReminderSettingsStore(store: store).save(stored)
        await model.applyStoredSetting()
        #expect(model.settings.enabled)
        // A later save keeps what was stored.
        model.setQuietHours(start: 60, end: 120)
        let saved = ReminderSettingsStore(store: store).load()
        #expect(saved.enabled && saved.mutedCameras == [muted])
    }
}
