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
            log: OSLogBenchLog()
        )
    }
}

extension AppModel {
    /// The app's models over the opened catalogue:
    ///
    /// - one `ImportEngine` with it, staging under the temporary folder (`tmp/Imports`, the engine's default, which it
    ///   empties at start-up);
    /// - Photos through `SystemPhotoLibrary` (`PhotosLibraryDestination`, one album per camera by default), and the
    ///   Files folder under Documents, one folder per camera (`FilesFolderDestination`), which the Info.plist shows in
    ///   Files as On My iPhone › Shutter Bridge;
    /// - the destination setting and the album identifiers in `UserDefaults`;
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
        let engine = ImportEngine(catalogue: catalogue)
        let destinations = StandardImportDestinations(
            library: library,
            albumStore: UserDefaultsAlbumIdentifierStore(),
            metadata: ImageIOMetadataReader(),
            documentsDirectory: URL.documentsDirectory
        )
        let wifiLog = OSLogBenchLog()
        let connections = WirelessConnections(
            connector: wireless.bluetooth,
            joiner: NEHotspotJoiner(),
            path: NWPathGateway(),
            foreground: wireless.foreground,
            channels: NWByteChannelFactory(interface: .wifi)
        )
        let wifi = WiFiSupport.make(
            catalogue: catalogue,
            connections: connections,
            pending: UserDefaultsPendingWiFiCameraStore(),
            explained: UserDefaultsLocalNetworkExplainedRecord(),
            log: wifiLog
        )
        return AppModel(
            discovery: CompositeDiscovery(sources: [USBCameraBrowser(), wifi.source]),
            services: .system(),
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
            wireless: wireless
        )
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

/// The app once the catalogue is open: Cameras in a navigation stack with Browse pushed onto it, and the Import and
/// Settings screens as sheets over the whole stack, so the Import screen outlives Browse when the cable is pulled.
/// (A tab bar with History, carrying the running import as its bottom accessory, waits for Iteration 2.)
///
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
    /// The last scene-phase change handed to the model, so a quick background-then-active is applied in order.
    @State private var phaseTask: Task<Void, Never>?

    var body: some View {
        @Bindable var cameras = model.cameras
        NavigationStack(path: $cameras.path) {
            CamerasScreen(model: cameras, importer: model.importer,
                          showSettings: { showsSettings = true },
                          showImport: { showsImport = true })
                .navigationDestination(for: CameraDescriptor.self) { camera in
                    BrowseScreen(model: model.browseModel(for: camera), importer: model.importer,
                                 isImportShown: showsImport, showImport: { showsImport = true })
                }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsScreen(model: model.settings)
        }
        // The close button and swiping down do the same (HIG Sheets): a finished job is cleared once it has been
        // seen, however the sheet closed; a running one stays.
        .sheet(isPresented: $showsImport, onDismiss: {
            if model.importer.isFinished { model.importer.dismiss() }
        }) {
            ImportScreen(model: model.importer)
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
            let model = self.model
            Task { await model.openCameraFromReminder() }
        }
        .onChange(of: model.cameras.cameras) { _, _ in
            let model = self.model
            Task { await model.openCameraFromReminder() }
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
/// - the catalogue's opening (`launcher`), so a background relaunch with no scene still builds the app's models.
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
            Task { await launcher.launch() }
        }
    }

    /// The wireless parts, made on first use (before launch finishes, from `beforeLaunchFinishes()`).
    @MainActor static var wireless: WirelessRuntime {
        if let runtime { return runtime }
        let log = OSLogBenchLog()
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
        let made = AppLauncher.live(wireless: wireless)
        madeLauncher = made
        return made
    }

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
