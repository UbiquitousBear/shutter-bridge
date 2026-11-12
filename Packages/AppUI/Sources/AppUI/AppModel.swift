import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import Observation
import PhotosBridge

/// The composition root's plain half: the app's models, wired to each other. The app (Apple-only) opens the
/// catalogue, makes the engine, the Photos library and the destinations, and hands them here; everything below is
/// tested on Linux with fakes.
///
/// - One `CamerasModel`, one `ImportModel` and one `SettingsModel`, sharing one `LinkLeases`, so leaving Browse never
///   closes a link a job uses.
/// - The Cameras model finds a camera by key for the import, and tells it when a camera is connected.
/// - Browse models come from `browseModel(for:)` with the catalogue (last-known card, badge) and the import.
@MainActor
@Observable
public final class AppModel {
    public let cameras: CamerasModel
    public let importer: ImportModel
    public let settings: SettingsModel
    public let leases: LinkLeases
    /// The Wi-Fi cameras, when the app has them (`WiFiSupport`); nil leaves the app USB-only, as it was.
    public let wifi: WiFiSupport?
    /// The wireless parts that live for the app's whole run (the central, the scene signal, the proximity scan and the
    /// reminder), when the app has them; made before launch finishes (W16).
    public let wireless: WirelessRuntime?
    /// Gets a Wi-Fi job back after the camera drops its card or the session (W14), when the app has Wi-Fi. Attached to
    /// `importer`, whose `tryAgainWiFi()` is the Import screen's Try Again.
    public let wifiRecovery: WiFiRecoveryCoordinator?
    /// The Cameras screen's way in to setting a Wi-Fi camera up (the pairing and typed-address sheets), when the app has
    /// Wi-Fi; nil leaves the screen as the USB screen it was. It pairs over the app's one central
    /// (`BluetoothPairingChecker` over `wireless.bluetooth`) and offers no pairing without one (W16).
    public let wirelessSetup: WirelessSetupModel?
    /// What the App Intents asked the app to do (I16): the import "Import new photos" waits to start, and what the
    /// screens show for it (`AppIntentRequests.navigation`).
    public let intents = AppIntentRequests()
    @ObservationIgnored private let notifier: any LocalNotifier
    @ObservationIgnored let discovery: any CameraDiscovery
    @ObservationIgnored let log: any BenchLog
    /// The catalogue key of a camera, as Browse and the import read it.
    @ObservationIgnored let cameraKeying: CameraKeying
    @ObservationIgnored private var registeredCategories = false
    /// The reminder's begin and end for connections and imports, one after the other, so an end never overtakes its begin.
    @ObservationIgnored private var reminderActivity: Task<Void, Never>?
    /// When each camera counts as connected for the reminder (W18), when the app has a reminder.
    @ObservationIgnored let connectionHolds: ConnectionHolds?
    /// For the Staging screen (`stagingModel`): the staged files and their marks, and where staging's iCloud folder is.
    @ObservationIgnored let catalogue: any CatalogueStore
    @ObservationIgnored private let stagingLocator: any StagingLocator

    public init(
        discovery: any CameraDiscovery,
        services: BrowseServices,
        catalogue: any CatalogueStore,
        engine: ImportEngine,
        settingsStore: any DestinationSettingStore,
        photos: any PhotosAuthorising,
        destinations: any ImportDestinationMaking,
        cameraKey: @escaping CameraKeying,
        now: @escaping @Sendable () -> Date = { Date() },
        notifier: any LocalNotifier = SilentNotifier(),
        notificationAsks: any NotificationAskRecord = InMemoryNotificationAskRecord(),
        background: any ImportBackgroundRun = NoImportBackgroundRun(),
        wifi: WiFiSupport? = nil,
        wireless: WirelessRuntime? = nil,
        diagnostics: (any DiagnosticsExporting)? = nil
    ) {
        self.notifier = notifier
        self.catalogue = catalogue
        stagingLocator = destinations
        self.wifi = wifi
        self.wireless = wireless
        self.discovery = discovery
        log = services.log
        let leases = LinkLeases()
        self.leases = leases
        // Weakly: the leases' hooks hold the connection holds.
        let connectionHolds = wireless == nil ? nil : ConnectionHolds(isHeld: { [weak leases] link in
            (leases?.holders(of: link) ?? 0) > 0
        })
        self.connectionHolds = connectionHolds
        // A Wi-Fi camera that has connected before is keyed by the key its discovery kept for it, so Browse and the
        // import always write under the catalogue row's key; a name-hash fallback only ever shows for one that has none
        // (`CameraKeys.isUnidentifiedWiFi`), and Browse refuses to import under it.
        // Each key read for a link also tells the reminder's connection hold which camera the link is (W18).
        let keying: CameraKeying = { descriptor, link in
            let key: CameraKey
            if descriptor.carrier == .wifi, let known = await discovery.knownKey(for: descriptor.id) {
                key = known
            } else {
                key = await cameraKey(descriptor, link)
            }
            await connectionHolds?.keyed(link, as: key)
            return key
        }
        cameraKeying = keying
        cameras = CamerasModel(discovery: discovery, services: services, catalogue: catalogue,
                               cameraKey: keying, leases: leases)
        // The continued task carries Wi-Fi jobs only (`WiFiOnlyBackgroundRun`): USB keeps its leaving rule (decision 1).
        let jobShown = ImportJobCarrier()
        let importer = ImportModel(engine: engine, settings: settingsStore, photos: photos, destinations: destinations,
                                   leases: leases, log: services.log, now: now,
                                   background: WiFiOnlyBackgroundRun(background, carrier: { jobShown.carrier }),
                                   notifier: notifier, notificationAsks: notificationAsks,
                                   abortTransfer: { link in await TransferAbort.abort(link) }, catalogue: catalogue)
        self.importer = importer
        jobShown.importer = importer
        if let wifi {
            // The Wi-Fi status posts one notification while a join is held with the app away (bench 19.1).
            wifi.status.notifier = notifier
            let recovery = WiFiRecoveryCoordinator(engine: engine, log: services.log)
            importer.attachWiFiRecovery(recovery)
            wifiRecovery = recovery
            let checker = wireless.map { BluetoothPairingChecker(connector: $0.bluetooth) }
            wirelessSetup = WirelessSetupModel(source: wifi.source, checker: checker, log: services.log)
        } else {
            wifiRecovery = nil
            wirelessSetup = nil
        }
        settings = SettingsModel(photos: photos, staging: destinations, diagnostics: diagnostics)
        cameras.importModel = importer
        importer.cameraFinder = cameras
        // A Wi-Fi camera's stay starts when the last holder lets its link go (the import has finished, and Browse is closed).
        // In the background it doesn't wait for Browse: an import's lease going with no import running is its end, and the
        // camera is no longer connected for the reminder, though Browse still holds the closed link.
        if let source = wifi?.source {
            leases.onReleased = { [weak self] link in
                if await source.linkReleased(link, activeImport: self?.activeImportKey) { connectionHolds?.closed(link) }
            }
            // iOS ended the continued task with the app away: the camera is let go rather than kept until the person is
            // back (W13).
            importer.onPausedAwayForExpiry = { camera in
                if let link = await source.importPausedAway(camera.descriptor.id) { connectionHolds?.closed(link) }
            }
        }
        if wifi != nil || connectionHolds != nil {
            let source = wifi?.source
            leases.onClosed = { link in
                connectionHolds?.closed(link)
                await source?.linkClosed(link)
            }
        }
        // A camera is connected, for the reminder, while its link is held, over either link (W18; USB too).
        if let connectionHolds {
            leases.onAcquired = { link in connectionHolds.acquired(link) }
            connectionHolds.onBegin = { [weak self] camera in
                self?.queueReminder { await $0.begin(.connection, camera: camera) }
            }
            connectionHolds.onEnd = { [weak self] camera in
                self?.queueReminder { $0.end(.connection, camera: camera) }
            }
        }
        // "Import new photos" (I16) starts once Browse has read the camera's card.
        cameras.onBrowseListed = { [weak self] browse in self?.browseListed(browse) }
        // ... and is dropped as soon as Browse is left, so a later visit of the person's own starts nothing.
        cameras.onPathChanged = { [weak self] path in self?.browsePathChanged(path) }
        // ... and moves over to the live camera when an offline Browse is replaced by its live one (W6-absent).
        cameras.onOfflineReplaced = { [weak self] offline, live in self?.offlineCameraReplaced(offline, by: live) }
        importer.onJobStarted = { [weak self] camera in self?.jobStarted(camera) }
        importer.onJobEnded = { [weak self] camera in self?.jobEnded(camera) }
        // A pass before a job's diff that wrote rows (a replay, or a waiting marker found once access returns) may have
        // changed what an open Browse shows as imported or staged, and a job that then imports nothing wouldn't tell it:
        // the badges are read again. The launch pass does so itself (`runLaunchPass()`).
        Task { [weak self] in
            await engine.setOnRowsRecovered {
                Task { @MainActor in await self?.cameras.refreshBrowseBadges() }
            }
        }
        if let wireless {
            // The known cameras go to the proximity confirmation before the reminder applies its setting (W17).
            Task { await wireless.catalogueOpened(catalogue) }
        }
    }

    /// A job started: a Wi-Fi job's recovery gets the camera's session (W14; none for a typed-address camera, which joins
    /// nothing), and the camera's reminders are held back while it imports (W18).
    private func jobStarted(_ camera: ImportCamera) {
        if camera.descriptor.carrier == .wifi, let recovery = wifiRecovery {
            recovery.session = wifi?.recoverySession?(camera.descriptor.id)
        }
        queueReminder { await $0.begin(.importing, camera: camera.key) }
        // The job wrote its camera's name to its row (D11), which may name the one body an MSC camera is named after.
        Task { [weak self] in await self?.cameras.refreshOnlyBodyName() }
    }

    /// The job ended: the recovery lets the session go (the job's end has already reset it), and the camera's reminders
    /// are free again after a new hold from now.
    private func jobEnded(_ camera: ImportCamera) {
        if camera.descriptor.carrier == .wifi { wifiRecovery?.session = nil }
        queueReminder { $0.end(.importing, camera: camera.key) }
    }

    /// Hands `step` to the reminder after the steps handed over before it.
    private func queueReminder(_ step: @escaping @MainActor (ReminderModel) async -> Void) {
        guard let reminders = wireless?.reminders else { return }
        let previous = reminderActivity
        reminderActivity = Task {
            await previous?.value
            await step(reminders)
        }
    }

    /// Waits for the reminder's begin and end handed over so far (for tests).
    func reminderActivitySettled() async { await reminderActivity?.value }

    /// Opens Browse on the camera a reminder's Import Now (or a tap) asked for (`ReminderModel.cameraToOpen`), once it is
    /// listed: a Wi-Fi camera's import then starts with the join, as Browse opens its link. Matched as
    /// `CamerasModel.link(forCameraWith:)` matches: by the key discovery knows for it (a Wi-Fi camera that has connected
    /// before), so no other Wi-Fi camera is joined to compare, else, over USB, by the key read from its link (cheap: nothing
    /// is opened). A camera not listed yet stays asked for, and the app calls this again when the list changes; the request
    /// is dropped when the app goes to the background with it still unmatched. Returns whether Browse was opened.
    @discardableResult
    public func openCameraFromReminder() async -> Bool {
        guard let reminders = wireless?.reminders, let key = reminders.cameraToOpen else { return false }
        for camera in cameras.cameras {
            guard await isCamera(camera, withKey: key) else { continue }
            // Taken only once it is found, and only if it is still the one asked for.
            guard reminders.cameraToOpen == key else { return false }
            _ = reminders.takeCameraToOpen()
            // By ID: a Wi-Fi camera's descriptor is renamed by its model at its first connection (D11).
            if cameras.path.last?.id != camera.id { cameras.path = [camera] }
            return true
        }
        return false
    }

    /// Whether `camera` is the one whose catalogue key is `key`. A Wi-Fi camera with no key yet has never connected, so it
    /// can't be the reminder's camera, and asking for its link would start a join.
    func isCamera(_ camera: CameraDescriptor, withKey key: CameraKey) async -> Bool {
        if let known = await discovery.knownKey(for: camera.id) { return known == key }
        guard camera.carrier != .wifi, let link = try? await discovery.cameraLink(for: camera.id) else { return false }
        return await cameraKeying(camera, link) == key
    }

    /// The key of the camera whose import is running (or paused, which still holds its link), if one is.
    /// A keepers job (I12) reads Staging under the staged files' key, which a connected camera may share: it holds no
    /// camera's link.
    private var activeImportKey: CameraKey? {
        importer.camera?.descriptor.carrier != .staging ? importer.activeJobKey : nil
    }

    /// A model for the Staging screen (backlog section 7.3; D5), over the app's catalogue and staging locator, made each
    /// time the screen opens so it reads the staged files as they are then. The app passes its Documents folder (On My
    /// iPhone's staging root) and the Apple-only parts: the preview loader, iCloud's file availability and the EXIF
    /// reader.
    public func stagingModel<Image: Sendable>(documents: URL, loader: any PreviewLoading<Image>,
                                              files: any StagedFileAvailability = AlwaysLocalFiles(),
                                              reader: any StagedFileReading = StagedFileReaders.platform,
                                              exif: (@Sendable (URL) async -> EXIFSummary?)? = nil) -> CullModel<Image> {
        CullModel(catalogue: catalogue, onThisIPhone: documents, locator: stagingLocator, reader: reader,
                  loader: loader, files: files, exif: exif, log: log)
    }

    /// *Import keepers* for the Staging screen (backlog sections 7.5 and 7.6; I12), over the app's catalogue, the Import
    /// screen's model and the staging locator, made with the screen's model. The app passes its Documents folder (On My
    /// iPhone's staging root), iCloud's file availability (evicted keepers are downloaded before the job) and the
    /// reader its jobs copy the staged files with.
    public func keepersImport(documents: URL, files: any StagedFileAvailability = AlwaysLocalFiles(),
                              reader: any StagedFileReading = StagedFileReaders.platform) -> KeepersImport {
        KeepersImport(catalogue: catalogue, importer: importer, onThisIPhone: documents, locator: stagingLocator,
                      reader: reader, files: files, log: log)
    }

    /// A model for the History screen (backlog section 4; D6), over the app's catalogue, the import and the staging
    /// locator. *Resume* and *Re-run* reach a camera through `HistoryCameraFinder`, which never starts a Wi-Fi join; the
    /// running job is the import's, a keepers job included (its record has no end yet, and isn't *Stopped early*; its
    /// camera's imports aren't forgotten while it runs). The app passes its Documents
    /// folder, On My iPhone's staging root, for a stage job's folder.
    public func historyModel(documents: URL) -> HistoryModel {
        let discovery = self.discovery
        let cameras = self.cameras
        let finder = HistoryCameraFinder(leases: leases, cameras: { cameras.cameras },
                                         link: { id in try? await discovery.cameraLink(for: id) }, key: cameraKeying)
        return HistoryModel(catalogue: catalogue, importer: importer, finder: finder, leases: leases,
                            onThisIPhone: documents, locator: stagingLocator,
                            activeCamera: { [weak self] in self?.importer.activeJobKey }, log: log)
    }

    /// The model for browsing `camera`, with the catalogue and the import.
    public func browseModel(for camera: CameraDescriptor) -> BrowseModel {
        cameras.browseModel(for: camera)
    }

    /// The scene's phase: discovery starts (again) when the app is active, Settings reads Photos access again (the
    /// person may have changed it in Settings), and a USB import pauses when the app leaves the foreground and
    /// carries on when it is back (decision 1). The notification permission is read again too, and the notification
    /// categories are registered at the first activation (W13).
    public func scenePhaseChanged(_ phase: AppScenePhase) async {
        // First, so the Wi-Fi sessions reading the scene and the reminder's rules see it before anything acts on it (W16).
        wireless?.sceneChanged(phase)
        // The reminder's request as it stood when the app left, so one made while this runs (Import Now) isn't dropped.
        let requestOnLeaving = phase == .background ? wireless?.reminders.cameraToOpen : nil
        // Browse hears the way to the background before its link is let go, so it doesn't take the end for one in front.
        if phase == .background {
            cameras.browseScenePhaseChanged(.background)
            // An "Import new photos" still waiting for its card doesn't outlive the app leaving the foreground (I16).
            dropPendingNewPhotosImport(because: "the app is in the background")
        }
        if phase == .active {
            wifi?.status.start()
            await cameras.becameActive()
            await settings.refresh()
            await importer.notificationPermission.refresh()
            if !registeredCategories {
                registeredCategories = true
                await notifier.registerCategories()
            }
        }
        await importer.scenePhaseChanged(phase)
        // After the import's own rule: the sessions leave the camera's network on the way to the background and check
        // the stay on the way back (`WirelessSession`). The caller holds the app's background time until this returns.
        // A camera let go is no longer connected for the reminder, though Browse may still hold its closed link (W18).
        let letGo = await wifi?.source.scenePhaseChanged(phase, activeImport: activeImportKey) ?? []
        for link in letGo {
            connectionHolds?.closed(link)
            // Still held means Browse holds it: the phone leaves the camera's network anyway (bench 19.1 log line).
            if leases.holders(of: link) > 0 { log.note("wifi: let go on the way to the background (Browse open, no import)") }
        }
        switch phase {
        case .active:
            // After the sessions have heard the return: Browse notes it is in front again (it reconnects nothing by itself;
            // a link let go waits for Reconnect, Shamil 10 Nov).
            cameras.browseScenePhaseChanged(.active)
            // After the import's rule and the sessions, so a paused USB import carries on as soon as it did before (W16).
            await wireless?.becameActive()
        case .background:
            // A reminder's camera that never showed up isn't opened the next time the person happens to open the app.
            if let reminders = wireless?.reminders, let asked = requestOnLeaving, reminders.cameraToOpen == asked {
                _ = reminders.takeCameraToOpen()
                log.note("reminder: the camera asked for wasn't listed, so it won't be opened")
            }
            // A camera added (or given its Bluetooth identifier) while in front is checked by the scan from now on.
            await wireless?.camerasChanged()
        case .inactive:
            break
        }
    }

    /// Whether the app keeps the screen on (`UIApplication.isIdleTimerDisabled`): while a USB import runs.
    public var keepsScreenOn: Bool { importer.keepsScreenOn }
}

/// The Wi-Fi half of the app, composed by the live root (W16): the cameras the person set up (`source`, which is also
/// one of `CompositeDiscovery`'s sources) and the model of their connection's states (`status`). The pairing and
/// typed-address sheets' models are made by `AppModel.wirelessSetup` (`WirelessSetupModel`) when their sheets open, over
/// `source`. `recoverySession` gives the Wi-Fi recovery the session a camera's job runs over (W14).
public struct WiFiSupport: Sendable {
    public let source: WiFiCameraSource
    public let status: WiFiImportModel
    public let recoverySession: (@Sendable (CameraDescriptor.ID) -> (any WiFiRecoverySession)?)?

    public init(source: WiFiCameraSource, status: WiFiImportModel,
                recoverySession: (@Sendable (CameraDescriptor.ID) -> (any WiFiRecoverySession)?)? = nil) {
        self.source = source
        self.status = status
        self.recoverySession = recoverySession
    }

    /// The live composition's Wi-Fi half over `connections` (W16): the source, the status model, the Local Network
    /// explanation before each new connection (`WiFiImportModel.beforeFirstConnection()`), each new link's events forwarded
    /// to the source before it opens, and the recovery's sessions.
    @MainActor
    public static func make(catalogue: any CatalogueStore, connections: WirelessConnections,
                            pending: any PendingWiFiCameraStore = InMemoryPendingWiFiCameraStore(),
                            explained: any LocalNetworkExplainedRecord = InMemoryLocalNetworkExplainedRecord(),
                            now: @escaping @Sendable () -> Date = { Date() },
                            log: any BenchLog = SilentBenchLog()) -> WiFiSupport {
        let gate = LocalNetworkGate()
        let source = WiFiCameraSource(catalogue: catalogue, pending: pending, connecting: connections,
                                      beforeFirstConnection: { await gate.ask() }, now: now, log: log)
        let status = WiFiImportModel(source: source, record: explained, now: now, log: log)
        gate.status = status
        connections.attach(observer: source)
        return WiFiSupport(source: source, status: status,
                           recoverySession: recoverySessions({ id in connections.recoverySession(for: id) },
                                                             source: source))
    }

    /// `sessions`' sessions as the recovery uses them, each handing the link it opens again to `source`
    /// (`WiFiCameraSource.adoptRecovered(_:for:)`): the recovery reopens through the session, not through the source, and
    /// the source must know the job's new link, or the old link's last holder letting go would end the import.
    static func recoverySessions(_ sessions: @escaping @Sendable (CameraDescriptor.ID) -> (any WiFiRecoverySession)?,
                                 source: WiFiCameraSource) -> @Sendable (CameraDescriptor.ID) -> (any WiFiRecoverySession)? {
        { id in sessions(id).map { SourceAdoptingRecoverySession(base: $0, source: source, id: id) } }
    }
}

/// A camera's session for the Wi-Fi recovery, telling the source of each link it opens again (`WiFiSupport.make`).
struct SourceAdoptingRecoverySession: WiFiRecoverySession {
    let base: any WiFiRecoverySession
    let source: WiFiCameraSource
    let id: CameraDescriptor.ID

    func prepareImport(bluetoothSwitchOnWhenAway: Bool) async throws(WirelessFailure) -> any CameraLink {
        let link = try await base.prepareImport(bluetoothSwitchOnWhenAway: bluetoothSwitchOnWhenAway)
        await source.adoptRecovered(link, for: id)
        return link
    }

    func importFinished() async {
        await base.importFinished()
    }
}

/// The Local Network explanation the source asks before a new connection, reaching the status model once it exists (the
/// source is made first, as the model reads the source's events).
@MainActor
final class LocalNetworkGate {
    weak var status: WiFiImportModel?

    /// True to go on; with no status model there is nothing to explain.
    func ask() async -> Bool {
        guard let status else { return true }
        return await status.beforeFirstConnection()
    }
}

/// The carrier of the job the Import model shows, for `WiFiOnlyBackgroundRun` (the model is made after the run it is given).
@MainActor
final class ImportJobCarrier {
    weak var importer: ImportModel?
    var carrier: CameraCarrier? { importer?.camera?.descriptor.carrier }
}

/// Opens the catalogue at launch and builds the app's models, or shows a clear error instead of crashing when the
/// catalogue can't be opened (backlog section 4: the app makes one `SwiftDataCatalogue` with
/// `open(storeURL:)`, off the main actor).
@MainActor
@Observable
public final class AppLauncher {
    public enum State {
        case opening
        case ready(AppModel)
        /// The catalogue couldn't be opened; the screen shows `AppWording.catalogueFailed…` with Try Again.
        case failed
    }

    public private(set) var state: State = .opening

    @ObservationIgnored private let openCatalogue: @Sendable () async throws -> any CatalogueStore
    @ObservationIgnored private let build: @MainActor (any CatalogueStore) -> AppModel
    @ObservationIgnored private let log: any BenchLog
    @ObservationIgnored private var launching = false

    /// - Parameters:
    ///   - openCatalogue: Opens the store (the app: `SwiftDataCatalogue.open(storeURL:)`, which runs off the main
    ///     actor by itself).
    ///   - build: Makes the app's models around the store (the engine, Photos, destinations and discovery).
    public init(openCatalogue: @escaping @Sendable () async throws -> any CatalogueStore,
                build: @escaping @MainActor (any CatalogueStore) -> AppModel,
                log: any BenchLog = SilentBenchLog()) {
        self.openCatalogue = openCatalogue
        self.build = build
        self.log = log
    }

    /// Opens the catalogue once; again after a failure (Try Again).
    public func launch() async {
        guard !launching else { return }
        switch state {
        case .ready: return
        case .opening, .failed: break
        }
        launching = true
        defer { launching = false }
        state = .opening
        do {
            let store = try await openCatalogue()
            state = .ready(build(store))
        } catch {
            // A real failure, so an error: the definition of done counts error-level lines.
            log.note("launch: the catalogue didn't open: \(type(of: error))", level: .error)
            state = .failed
        }
    }

    public var model: AppModel? {
        if case let .ready(model) = state { model } else { nil }
    }
}

/// App-wide copy.
public enum AppWording {
    /// The launch spinner's VoiceOver label; nothing is written on screen (HIG Launching).
    public static let openingCatalogue = AppText.string("Opening Shutter Bridge…")
    /// How long launch waits before showing a spinner: the catalogue usually opens well within it.
    public static let spinnerDelay: Duration = .milliseconds(500)
    public static let catalogueFailedTitle = AppText.string("Shutter Bridge Couldn't Start")
    /// The screen has Try Again, so it never asks to restart the app (HIG: don't ask people to quit).
    public static let catalogueFailedDetail = AppText.string("It couldn't open its catalogue of imported files, so it "
        + "can't tell "
        + "which photos are already imported. Free some space on this iPhone, then tap Try Again.")
    public static let tryAgain = AppText.string("Try Again")
}
