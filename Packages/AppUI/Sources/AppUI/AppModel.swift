import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import Observation

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
    @ObservationIgnored private let notifier: any LocalNotifier
    @ObservationIgnored private var registeredCategories = false

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
        wifi: WiFiSupport? = nil
    ) {
        self.notifier = notifier
        self.wifi = wifi
        let leases = LinkLeases()
        self.leases = leases
        // A Wi-Fi camera that has connected before is keyed by the key its discovery kept for it, so Browse and the
        // import always write under the catalogue row's key; a name-hash fallback only ever shows for one that has none
        // (`CameraKeys.isUnidentifiedWiFi`), and Browse refuses to import under it.
        let keying: CameraKeying = { descriptor, link in
            if descriptor.carrier == .wifi, let known = await discovery.knownKey(for: descriptor.id) { return known }
            return await cameraKey(descriptor, link)
        }
        cameras = CamerasModel(discovery: discovery, services: services, catalogue: catalogue,
                               cameraKey: keying, leases: leases)
        importer = ImportModel(engine: engine, settings: settingsStore, photos: photos, destinations: destinations,
                               leases: leases, log: services.log, now: now, notifier: notifier,
                               notificationAsks: notificationAsks)
        settings = SettingsModel(store: settingsStore, photos: photos)
        cameras.importModel = importer
        importer.cameraFinder = cameras
        // A Wi-Fi camera's stay starts when the last holder lets its link go (the import has finished, and Browse is closed).
        // In the background it doesn't wait for Browse: an import's lease going with no import running is its end.
        if let source = wifi?.source {
            leases.onClosed = { link in await source.linkClosed(link) }
            leases.onReleased = { [weak self] link in
                await source.linkReleased(link, activeImport: self?.activeImportKey)
            }
        }
    }

    /// The key of the camera whose import is running (or paused, which still holds its link), if one is.
    private var activeImportKey: CameraKey? { importer.isActive ? importer.camera?.key : nil }

    /// The model for browsing `camera`, with the catalogue and the import.
    public func browseModel(for camera: CameraDescriptor) -> BrowseModel {
        cameras.browseModel(for: camera)
    }

    /// The scene's phase: discovery starts (again) when the app is active, Settings reads Photos access again (the
    /// person may have changed it in Settings), and a USB import pauses when the app leaves the foreground and
    /// carries on when it is back (decision 1). The notification permission is read again too, and the notification
    /// categories are registered at the first activation (W13).
    public func scenePhaseChanged(_ phase: AppScenePhase) async {
        if phase == .active {
            wifi?.status.start()
            await cameras.becameActive()
            await settings.refreshPhotosAccess()
            await importer.notificationPermission.refresh()
            if !registeredCategories {
                registeredCategories = true
                await notifier.registerCategories()
            }
        }
        await importer.scenePhaseChanged(phase)
        // After the import's own rule: the sessions leave the camera's network on the way to the background and check
        // the stay on the way back (`WirelessSession`). The caller holds the app's background time until this returns.
        await wifi?.source.scenePhaseChanged(phase, activeImport: activeImportKey)
    }

    /// Whether the app keeps the screen on (`UIApplication.isIdleTimerDisabled`): while a USB import runs.
    public var keepsScreenOn: Bool { importer.keepsScreenOn }
}

/// The Wi-Fi half of the app, composed by the live root (W16): the cameras the person set up (`source`, which is also
/// one of `CompositeDiscovery`'s sources) and the model of their connection's states (`status`). The onboarding and the
/// typed-address sheet are made when their screens open (`OnboardingModel`, `TypedAddressModel`), over `source`.
public struct WiFiSupport: Sendable {
    public let source: WiFiCameraSource
    public let status: WiFiImportModel

    public init(source: WiFiCameraSource, status: WiFiImportModel) {
        self.source = source
        self.status = status
    }
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
            log.note("launch: the catalogue didn't open: \(type(of: error))")
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
    public static let openingCatalogue = "Opening Shutter Bridge…"
    /// How long launch waits before showing a spinner: the catalogue usually opens well within it.
    public static let spinnerDelay: Duration = .milliseconds(500)
    public static let catalogueFailedTitle = "Shutter Bridge Couldn't Start"
    /// The screen has Try Again, so it never asks to restart the app (HIG: don't ask people to quit).
    public static let catalogueFailedDetail = "It couldn't open its catalogue of imported files, so it can't tell "
        + "which photos are already imported. Free some space on this iPhone, then tap Try Again."
    public static let tryAgain = "Try Again"
}
