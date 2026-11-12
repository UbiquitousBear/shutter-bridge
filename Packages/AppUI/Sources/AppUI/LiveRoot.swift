#if canImport(SwiftUI) && canImport(UIKit) && canImport(ImageCaptureCore) && canImport(Photos) && canImport(SwiftData) && canImport(BackgroundTasks) && canImport(UserNotifications) && canImport(CoreBluetooth) && canImport(Network) && canImport(NetworkExtension) && os(iOS)
import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import SwiftUI
import UIKit
import UserNotifications

// The composition root's Apple-only half (backlog section 6): the real catalogue, engine, Photos library, Files
// folder, discovery and camera key, handed to `AppModel`, and the root view that opens the catalogue first. The plain
// half (`AppModel`, `AppLauncher`, `WirelessRuntime`, `WirelessConnections`, `WiFiSupport.make`) is tested on Linux with
// fakes. Wireless (W16) is switched on here: every Apple-only radio piece is made in this file and handed in through its
// protocol (`GATTConnector` and `ProximityScanning`, `HotspotJoining`, `WiFiPathWatching`, `ByteChannelFactory`,
// `ImportBackgroundRun`, `LocalNotifier`, `ProximityRefreshScheduling`).

extension AppLauncher {
    /// The app's launcher. Nothing is opened here: `launch()` opens the catalogue (off the main actor, as
    /// `SwiftDataCatalogue.open(storeURL:)` does by itself) and then builds the app around it, with the wireless parts
    /// made before launch finished (`LiveLaunch`).
    static func live(wireless: WirelessRuntime) -> AppLauncher {
        AppLauncher(
            openCatalogue: { try await SwiftDataCatalogue.open(storeURL: SwiftDataCatalogue.defaultStoreURL) },
            build: { catalogue in AppModel.live(catalogue: catalogue, wireless: wireless) },
            log: AppLogging.shared.log
        )
    }
}

extension AppModel {
    /// The app's models over the opened catalogue:
    ///
    /// - one `ImportEngine` with it, its work folder in Caches (`ImportEngine.cachesWorkFolder`, `Library/Caches/Imports`,
    ///   which iOS doesn't empty while the app is suspended, as it may `tmp`; I13), emptied at start-up except the partial
    ///   files a later job resumes; partials an earlier build left in `tmp/Imports` move in first, and the launch pass
    ///   (`launchPass()`) resolves pending commits left behind (I15, with `LibraryCommitLookup`), then sends a row whose
    ///   partial file is gone back to offset 0;
    /// - Photos through `SystemPhotoLibrary` (`PhotosLibraryDestination`, one album per camera by default), and the
    ///   staging folder, one folder per camera and capture day (`StagingFolderDestination`): in the app's iCloud Drive
    ///   folder when `UbiquityStagingLocator` finds it (iCloud Drive › Shutter Bridge › Staging, moved in with
    ///   `UbiquitousFileMover`), otherwise under Documents, which the Info.plist shows in Files as On My iPhone ›
    ///   Shutter Bridge › Staging;
    /// - the Import button's remembered choice (*Import to Photos* or *Stage*) and the album identifiers in
    ///   `UserDefaults`;
    /// - discovery through `USBCameraBrowser`, and the camera key from the USB link's key material
    ///   (`CameraKeys.keying(material:)`: hashed device UUID in MTP, mode and volume name in MSC; unverified, backlog
    ///   sections 2 and 4). The key groups imports (album, Camera row, last-known card, reconnecting); whether a file
    ///   is already imported doesn't depend on it (Shamil, 8 Nov);
    /// - local notifications through `UNLocalNotifier`, with the ask recorded in `UserDefaults` (W13: the permission
    ///   at the first Import, and the pause notification);
    /// - the continued task (`ContinuedImportRunner`, W13) for Wi-Fi jobs (`AppModel` keeps USB to its leaving rule), and
    ///   the expiry's transfer abort through `TransferAborting` (W8);
    /// - Wi-Fi (W16): the cameras the person set up as a second discovery source beside USB (`CompositeDiscovery`, W15),
    ///   each paired camera's `WirelessSession` (W11) over the app's one central (`wireless.bluetooth`, W10),
    ///   `NEHotspotJoiner` (W12), `NWPathGateway` and `NWByteChannelFactory` on Wi-Fi only (W9), and the scene as
    ///   `wireless.foreground`; the cameras paired but not yet connected and the Local Network explanation's record in
    ///   `UserDefaults`; the recovery (W14) and the reminder's holds (W18) follow each job (`AppModel`).
    static func live(catalogue: any CatalogueStore, wireless: WirelessRuntime) -> AppModel {
        let library = SystemPhotoLibrary()
        let logging = AppLogging.shared
        // The engine's own decisions (skips, failures, checkpoints, retries, reconnects, pauses) reach the log, one line each
        // (I8, `EngineTraceWording`); a real failure goes out at error level.
        let workFolder = ImportEngine.cachesWorkFolder
        ImportEngine.movePartials(from: FileManager.default.temporaryDirectory
            .appendingPathComponent("Imports", isDirectory: true), to: workFolder)
        // A commit whose catalogue write was lost (the app killed after the save, or the store failing every try) is
        // looked for before the next diff (backlog section 3.1, I15): in the library by date and original file names
        // (the album not consulted), or in its Staging day folder on this iPhone or in iCloud Drive.
        let commitLookup = LibraryCommitLookup(library: library, staging: UbiquityStagingLocator(),
                                               onThisIPhone: URL.documentsDirectory)
        let engine = ImportEngine(catalogue: catalogue, stagingDirectory: workFolder, trace: .bench(logging.log),
                                  commitLookup: commitLookup)
        // The launch pass the engine owns, after its prune: pending commits resolved, then rows whose partial file iOS
        // emptied from Caches, or the prune deleted, back to offset 0. The first job's pass waits for it; `AppModel`
        // awaits the same pass below, to read Browse's badges again if it wrote rows.
        Task { await engine.launchPass() }
        #if DEBUG
        // The commit-boundary bench check (docs/iteration-2-bench.md): Debug builds only.
        let benchLog = logging.log
        Task {
            await CommitBoundaryBench.install(on: engine, arguments: ProcessInfo.processInfo.arguments, log: benchLog,
                                              end: { exit(0) })
        }
        #endif
        let destinations = StandardImportDestinations(
            library: library,
            albumStore: UserDefaultsAlbumIdentifierStore(),
            metadata: ImageIOMetadataReader(),
            documentsDirectory: URL.documentsDirectory,
            // The app is signed with iCloud Documents and declares its container (docs/ci.md); when iCloud Drive
            // isn't available the locator says why and staging goes to the app's folder on this iPhone.
            stagingLocator: UbiquityStagingLocator(),
            iCloudDriveMover: UbiquitousFileMover()
        )
        let wifiLog = logging.log
        // The firmware the camera reports is also kept for the diagnostics export's header.
        let benchTrace = TransportTrace.bench(wifiLog)
        let firmware = logging.firmware
        let connections = WirelessConnections(
            connector: wireless.bluetooth,
            joiner: NEHotspotJoiner(),
            path: NWPathGateway(),
            foreground: wireless.foreground,
            channels: NWByteChannelFactory(interface: .wifi),
            // The bench lines for the wireless checks (W20): step times, CC09 and CC08, the RSSI, the poll, keep-alives,
            // GetDevicePropValue, 0x9211 resumes. Times, counts and statuses only.
            trace: TransportTrace { event in
                benchTrace.record(event)
                if case let .deviceInfoRead(version) = event { firmware.note(TransportTraceWording.firmwareWord(version)) }
            }
        )
        let wifi = WiFiSupport.make(
            catalogue: catalogue,
            connections: connections,
            pending: UserDefaultsPendingWiFiCameraStore(),
            explained: UserDefaultsLocalNetworkExplainedRecord(),
            log: wifiLog
        )
        let model = AppModel(
            discovery: CompositeDiscovery(sources: [USBCameraBrowser(), wifi.source]),
            services: .system(log: wifiLog),
            catalogue: catalogue,
            engine: engine,
            settingsStore: UserDefaultsDestinationSettingStore(),
            photos: LibraryPhotosAuthorisation(library: library),
            destinations: destinations,
            cameraKey: CameraKeys.keying(material: { link in
                guard let usb = link as? USBLink else { return nil }
                return await usb.cameraKeyMaterial()?.rawValue
            }),
            notifier: UNLocalNotifier(),
            notificationAsks: UserDefaultsNotificationAskRecord(),
            background: ContinuedImportRunner(),
            wifi: wifi,
            wireless: wireless,
            diagnostics: logging.exporter(catalogue: catalogue)
        )
        Task { await model.runLaunchPass() }
        return model
    }
}

/// The app's logging, made once: the unified log (`OSLogBenchLog`) and the rolling file of the last few launches
/// (`RollingLogFile`, decision D8) as one `BenchLog`, so every line goes to both, at the level it came with. The Settings
/// export reads the file for earlier launches and the unified log for this one (`DiagnosticsExporter`).
final class AppLogging: Sendable {
    static let shared = AppLogging()

    let rolling: RollingLogFile
    let log: any BenchLog
    /// The firmware version last read from a camera this launch, for the export's header.
    let firmware = CameraFirmwareNotes()

    private init() {
        let rolling = RollingLogFile.inCaches()
        self.rolling = rolling
        log = TeeBenchLog([OSLogBenchLog(), rolling])
    }

    /// The export, over `catalogue` for the cameras' models and the values to redact. Exports a crash left behind are removed
    /// first (the file is in Caches, and `discard` removes it as soon as the share sheet closes).
    func exporter(catalogue: any CatalogueStore) -> DiagnosticsExporter {
        let exporter = DiagnosticsExporter(scratch: DiagnosticsExporter.scratchInCaches(), info: .current(),
                                           catalogue: catalogue, firmware: firmware, current: LogStoreReader(),
                                           rollingFile: rolling)
        exporter.removeLeftovers()
        return exporter
    }
}

extension AppScenePhase {
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .background: self = .background
        case .inactive: self = .inactive
        @unknown default: self = .inactive
        }
    }
}

/// The live root on iPhone: opens the catalogue, then shows the app; if the catalogue can't be opened, a clear error
/// with Try Again instead of a crash. Meanwhile the Cameras screen's bar and title are up at once, matching the launch
/// screen's navigation bar (Info.plist), with no splash text; a plain spinner shows only if opening takes longer than
/// `AppWording.spinnerDelay` (HIG Launching).
struct LiveRoot: View {
    /// The launcher `LiveLaunch` started before launch finished, so the catalogue opens (and the reminder and the scan get
    /// their cameras) even when iOS relaunches the app in the background for Bluetooth, with no scene.
    @State private var launcher = LiveLaunch.launcher

    var body: some View {
        Group {
            switch launcher.state {
            case .opening:
                LaunchShell {
                    DelayedSpinner()
                }
            case let .ready(model):
                LiveApp(model: model)
            case .failed:
                LaunchShell {
                    ContentUnavailableView {
                        Label(AppWording.catalogueFailedTitle, systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(AppWording.catalogueFailedDetail)
                    } actions: {
                        Button(AppWording.tryAgain) {
                            Task { await launcher.launch() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .task { await launcher.launch() }
    }
}

/// The Cameras screen's navigation shell before the app is ready: its bar and title around `content`.
private struct LaunchShell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            ZStack {
                Color.clear
                content
            }
            .navigationTitle(CamerasWording.title)
        }
    }
}

/// Nothing at first; a plain spinner once `AppWording.spinnerDelay` has passed, so a quick launch doesn't flicker.
private struct DelayedSpinner: View {
    @State private var showsSpinner = false

    var body: some View {
        ZStack {
            if showsSpinner {
                ProgressView()
                    .accessibilityLabel(AppWording.openingCatalogue)
            }
        }
        .task {
            guard (try? await Task.sleep(for: AppWording.spinnerDelay)) != nil else { return }
            showsSpinner = true
        }
    }
}

/// The app once the catalogue is open: a tab bar (I10; backlog section 4) with Cameras (a navigation stack with Browse
/// pushed onto it), Staging (the cull screen, D5) and History, and the running import as the bar's bottom accessory,
/// whose tap opens the Import screen. The Import and Settings screens are sheets over the whole tab bar, so the Import
/// screen outlives Browse when the cable is pulled; Settings stays in the Cameras screen's bar.
///
/// - Staging's model is made afresh each time its tab is chosen (it reads Staging as it is then) and let go when another
///   tab is chosen, closing the loupe first, so its previews are released and its marks counted. Its *Import keepers*
///   (I12) is made once and kept, so a keepers run and its one confirmation (D2) outlive a visit to another tab. History's
///   model is made once and reads the job records each time its tab appears.
/// - The scene's phase goes to the app model in order (discovery starts when active; a USB import pauses when the
///   app leaves the foreground and carries on when it is back, decision 1), with background time held while a change to
///   the background is handled.
/// - The screen stays on while a USB import runs (`UIApplication.isIdleTimerDisabled`), and goes back to normal
///   otherwise.
/// - Wi-Fi (W16): the Wi-Fi status (`WiFiImportModel`), the setup sheets' model (`WirelessSetupModel`) and the reminder
///   (`ReminderModel`) go in the environment for the screens. The Local Network explanation is presented by Browse (a
///   sheet) or, while the Import sheet covers Browse, inline in the Import screen; nothing here presents it. A reminder's
///   Import Now opens its camera here (`AppModel.openCameraFromReminder()`), USB or Wi-Fi.
struct LiveApp: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsSettings = false
    @State private var showsImport = false
    /// The tab shown.
    @State private var tab: AppTab = .cameras
    /// The Staging tab's model (D5), made afresh each time the tab is chosen.
    @State private var staging: CullModel<DecodedPreviewImage>?
    /// *Import keepers* for the Staging tab (I12), made the first time the tab is chosen and kept while the app runs,
    /// so a keepers run and its one confirmation (D2) outlive a visit to another tab.
    @State private var stagingKeepers: KeepersImport?
    /// The History tab's model, made the first time the tab is chosen.
    @State private var history: HistoryModel?
    /// The last scene-phase change handed to the model, so a quick background-then-active is applied in order.
    @State private var phaseTask: Task<Void, Never>?

    var body: some View {
        @Bindable var cameras = model.cameras
        TabView(selection: $tab) {
            Tab(CamerasWording.title, systemImage: "camera", value: AppTab.cameras) {
                NavigationStack(path: $cameras.path) {
                    CamerasScreen(model: cameras, importer: model.importer,
                                  showSettings: { showsSettings = true },
                                  showImport: { showsImport = true })
                        .navigationDestination(for: CameraDescriptor.self) { camera in
                            BrowseScreen(model: model.browseModel(for: camera), importer: model.importer,
                                         isImportShown: showsImport, showImport: { showsImport = true })
                        }
                }
            }
            Tab(CullWording.title, systemImage: "tray.full", value: AppTab.staging) {
                StagingTab(model: staging, keepers: stagingKeepers)
            }
            Tab(HistoryWording.title, systemImage: "clock.arrow.circlepath", value: AppTab.history) {
                if let history {
                    HistoryScreen(model: history, importer: model.importer, showImport: { showsImport = true })
                }
            }
        }
        // The running import above the tab bar, wherever the person is; its tap opens the Import screen.
        .tabViewBottomAccessory(isEnabled: model.importer.hasJob) {
            ImportAccessory(model: model.importer) { showsImport = true }
        }
        // Staging is read afresh each time its tab is chosen, and let go when another is: however it is left (a tab, or
        // the reminder opening a camera while the loupe's cover is up), the loupe is closed too, so its previews are
        // released and its marks counted.
        .onChange(of: tab, initial: true) { _, chosen in
            if chosen == .staging {
                if staging == nil { staging = makeStagingModel() }
                if stagingKeepers == nil { stagingKeepers = makeKeepersImport() }
            } else if let closing = staging {
                staging = nil
                Task { await closing.closeLoupe() }
            }
            if chosen == .history, history == nil {
                history = model.historyModel(documents: LiveLaunch.documents)
            }
        }
        // However Settings closes, a diagnostics file that is ready (or being made) is removed.
        .sheet(isPresented: $showsSettings, onDismiss: { model.settings.settingsClosed() }) {
            SettingsScreen(model: model.settings)
        }
        // The close button and swiping down do the same (HIG Sheets): a finished job is cleared once it has been
        // seen, however the sheet closed; a running one stays.
        .sheet(isPresented: $showsImport, onDismiss: {
            if model.importer.isFinished { model.importer.dismiss() }
        }) {
            ImportScreen(model: model.importer)
        }
        // The Staging tab's loupe (D5), full screen over the whole tab view like the sheets above, rather than from
        // inside the tab: on a wide iPhone, whose tabs and toolbar are a strip at the side, a cover put up from the
        // tab's own screen never showed (#139). It is bound to the model's open loupe, so leaving the tab (which lets
        // the model go) takes it down too.
        .fullScreenCover(item: stagingLoupe) { loupe in
            LoupeView(loupe: loupe) { staging?.dismissLoupe(loupe) }
        }
        // The wireless screens' models (W16), each optional so a screen without one is the USB screen it was. Applied
        // outside the sheets so the Settings and Import sheets, and Browse in the stack, read them too.
        .environment(model.wifi?.status)
        .environment(model.wirelessSetup)
        .environment(model.wireless?.reminders)
        // The job's outcome is felt wherever the person is in the app (HIG Playing haptics): success, a warning when
        // it needs them, an error when it stopped.
        .sensoryFeedback(trigger: model.importer.feedbackState) { old, new in
            OutcomeFeedback.forImport(from: old, to: new)?.sensoryFeedback
        }
        .task { model.cameras.launch() }
        // "Import new photos" (I16) opened its camera in Browse, or found it not connected: the Cameras tab, with
        // Settings closed, and the Import sheet once the import has started (otherwise closed unless its job is that
        // camera's).
        .onChange(of: model.intents.navigation) { _, navigation in
            guard let navigation else { return }
            tab = .cameras
            showsSettings = false
            if navigation.showsImport {
                showsImport = true
            } else if model.importer.camera?.descriptor.id != model.cameras.path.last?.id {
                showsImport = false
            }
        }
        // A card listed may be a camera the intents' picker didn't list yet: App Shortcuts' phrases with a camera are
        // made again.
        .onChange(of: model.intents.camerasRevision, initial: true) { _, _ in
            Self.refreshShortcutParameters()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            let previous = phaseTask
            let model = self.model
            let appPhase = AppScenePhase(phase)
            // On the way to the background the app is kept awake until the change has been handled, so a Wi-Fi session
            // leaves the camera's network before iOS suspends the app (Shamil: leaving at once in the background).
            let awake = appPhase == .background ? SceneChangeAwake.begin() : nil
            phaseTask = Task { @MainActor in
                await previous?.value
                await model.scenePhaseChanged(appPhase)
                awake?.end()
            }
        }
        .onChange(of: model.keepsScreenOn, initial: true) { _, keepsOn in
            UIApplication.shared.isIdleTimerDisabled = keepsOn
        }
        // A reminder's Import Now (or a tap) opens Browse on its camera once it is listed (W18); a Wi-Fi camera's import
        // then starts with the join.
        .onChange(of: model.wireless?.reminders.cameraToOpen, initial: true) { _, _ in
            Task { @MainActor in await openCameraFromReminder() }
        }
        .onChange(of: model.cameras.cameras) { _, _ in
            Task { @MainActor in await openCameraFromReminder() }
        }
    }

    /// Tells App Shortcuts the cameras may have changed (I16), so its phrases that name a camera are made again.
    private static func refreshShortcutParameters() {
        #if canImport(AppIntents)
        ShutterBridgeShortcuts.updateAppShortcutParameters()
        #endif
    }

    /// The Staging screen's model: the staged copies under the app's Documents folder (On My iPhone) or the iCloud
    /// container's, previews decoded with ImageIO and Core Image, evicted iCloud files downloaded ahead, and the EXIF line
    /// read with ImageIO off the main actor.
    /// The Staging tab's open loupe for its cover: a dismissal closes it at once (`dismissLoupe`), so the binding reads
    /// nil as the cover goes and it isn't put up again.
    private var stagingLoupe: Binding<CullLoupe<DecodedPreviewImage>?> {
        Binding(
            get: { staging?.loupe },
            set: { shown in
                guard shown == nil, let staging, let open = staging.loupe else { return }
                staging.dismissLoupe(open)
            }
        )
    }

    private func makeStagingModel() -> CullModel<DecodedPreviewImage> {
        model.stagingModel(documents: LiveLaunch.documents, loader: ImageIOPreviewLoader(),
                           files: UbiquitousFileAvailability(), reader: StagedFileReaders.platform,
                           exif: { url in await Task.detached(priority: .utility) { EXIFSummary.read(from: url) }.value })
    }

    /// *Import keepers* for the Staging tab: its jobs read the staged copies coordinated (iCloud Drive) and download an
    /// evicted keeper before the job starts.
    private func makeKeepersImport() -> KeepersImport {
        model.keepersImport(documents: LiveLaunch.documents, files: UbiquitousFileAvailability(),
                            reader: StagedFileReaders.platform)
    }

    /// Opens the reminder's camera in Browse, if it is listed: the Cameras tab (leaving Staging closes its loupe), with
    /// the sheets that would hide it closed: Settings, and Import unless its job is that camera's.
    private func openCameraFromReminder() async {
        guard await model.openCameraFromReminder() else { return }
        tab = .cameras
        showsSettings = false
        if model.importer.camera?.descriptor.id != model.cameras.path.last?.id { showsImport = false }
    }
}

/// The tab bar's tabs (I10; D5): Cameras, Staging and History.
private enum AppTab: Hashable {
    case cameras
    case staging
    case history
}

/// The Staging tab: the cull screen in its own navigation stack, with no close button (it was a sheet before the tab
/// bar); nothing while its model is being made.
private struct StagingTab: View {
    let model: CullModel<DecodedPreviewImage>?
    /// *Import keepers* (I12): the toolbar button, the day rows' menu, the strip and the one confirmation (D2).
    let keepers: KeepersImport?

    var body: some View {
        NavigationStack {
            if let model {
                CullScreen(model: model, keepers: keepers)
            } else {
                Color.clear
                    .navigationTitle(CullWording.title)
            }
        }
    }
}

/// Background time for one scene change (`UIApplication.beginBackgroundTask`), ended once: when the change has been handled,
/// or when iOS says the time is up, whichever comes first.
@MainActor
private final class SceneChangeAwake {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    static func begin() -> SceneChangeAwake {
        let awake = SceneChangeAwake()
        awake.identifier = UIApplication.shared.beginBackgroundTask(withName: "Scene change") {
            MainActor.assumeIsolated { awake.end() }
        }
        return awake
    }

    func end() {
        guard identifier != .invalid else { return }
        let ending = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(ending)
    }
}

/// What the app sets up before it finishes launching: called from the app's `init`, on the main thread. iOS requires a
/// background task's launch handler, the notification centre's delegate and a restoring Core Bluetooth central to be in
/// place by then, so none of them can wait for `LiveRoot` or the catalogue:
///
/// - the continued import's launch handler (`ContinuedImportRunner.register()`, W13) and the proximity scan's app-refresh
///   task (`BackgroundRefreshScheduler.register`, W17);
/// - the wireless parts that live for the app's run (`WirelessRuntime`): the central made now only if the launch rule
///   allows it (the reminder is on or Bluetooth is already allowed, W10), so launch never prompts and state restoration
///   finds it; the scan's reports read from now on;
/// - the delegate that hands a reminder's response (Import Now, Not Now, Snooze 1 Hour, a tap, a swipe away) to the
///   reminder model;
/// - the catalogue's opening (`launcher`), so a background relaunch with no scene still builds the app's models;
/// - the App Intents' way to the app's model (`IntentHost.launcher`, I16), so an intent that launched the app waits for
///   the catalogue.
public enum LiveLaunch {
    @MainActor private static var runtime: WirelessRuntime?
    @MainActor private static var madeLauncher: AppLauncher?
    @MainActor private static let responder = NotificationResponder()

    public static func beforeLaunchFinishes() {
        MainActor.assumeIsolated {
            ContinuedImportRunner.register()
            BackgroundRefreshScheduler.register { await LiveLaunch.refreshTaskRan() }
            wireless.launchEarly()
            UNUserNotificationCenter.current().delegate = responder
            let launcher = self.launcher
            // The App Intents (I16) wait for the catalogue through it, even when one launched the app.
            IntentHost.launcher = launcher
            Task { await launcher.launch() }
        }
    }

    /// The wireless parts, made on first use (before launch finishes, from `beforeLaunchFinishes()`).
    @MainActor static var wireless: WirelessRuntime {
        if let runtime { return runtime }
        let log = AppLogging.shared.log
        let store = UserDefaultsKeyValueStore()
        // Before the first unlock after a restart the setting reads as off; Bluetooth's permission can still be read.
        let remindersOn = ReminderSettingsStore(store: store).load().enabled
        let central = BluetoothCentral.makeAtLaunchIfAllowed(remindersOn: remindersOn)
        let bluetooth = OnDemandBluetooth(existing: central, make: { BluetoothCentral.shared() })
        let made = WirelessRuntime(bluetooth: bluetooth, refresh: BackgroundRefreshScheduler(log: log),
                                   notifier: UNLocalNotifier(), store: store, log: log)
        runtime = made
        return made
    }

    /// The app's one launcher, over `wireless`.
    @MainActor static var launcher: AppLauncher {
        if let madeLauncher { return madeLauncher }
        let made = uiTestLauncher() ?? AppLauncher.live(wireless: wireless)
        madeLauncher = made
        return made
    }

    /// The UI tests' seeded app (I18; D14 (c)) in a Debug build started with `UITestFixture.launchArgument`: the app
    /// over an `InMemoryCatalogue` seeded with job records, staged files and marks (`UITestFixture`), with no camera.
    /// Nil otherwise, and always in a Release build, which has no fixture.
    @MainActor private static func uiTestLauncher() -> AppLauncher? {
        #if DEBUG
        if UITestFixture.isRequested() { return AppLauncher.uiTestFixture() }
        #endif
        return nil
    }

    /// The app's Documents folder, On My iPhone's staging root, for the Staging and History tabs; the fixture's folder in
    /// the UI tests' seeded app (Debug builds only).
    static let documents: URL = {
        #if DEBUG
        if UITestFixture.isRequested() { return UITestFixture.documents }
        #endif
        return URL.documentsDirectory
    }()

    @MainActor static func refreshTaskRan() async {
        await wireless.refreshTaskRan()
    }

    @MainActor static func respond(category: String, action: String, camera: CameraKey?) async {
        await wireless.respond(categoryIdentifier: category, actionIdentifier: action, camera: camera,
                               defaultIdentifier: UNNotificationDefaultActionIdentifier,
                               dismissIdentifier: UNNotificationDismissActionIdentifier)
    }
}

/// The notification centre's delegate (set before launch finishes, as iOS requires for a response that launched the app):
/// hands each response to `LiveLaunch.respond`, which acts only on a reminder's (`ReminderResponseMapping`). It doesn't
/// present notifications while the app is in front (no `willPresent`): the reminder rules post none then (W18). The camera
/// comes from the notification's `userInfo` (`ReminderModel.camera(fromUserInfo:)`); nothing is logged here. The completion
/// handler is called once the response has been handled, so a Snooze from the background is stored before iOS suspends the
/// app.
private final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    @objc(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:)
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        let action = response.actionIdentifier
        let camera = ReminderModel.camera(fromUserInfo: content.userInfo)
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            await LiveLaunch.respond(category: category, action: action, camera: camera)
            done()
        }
    }
}
#endif
