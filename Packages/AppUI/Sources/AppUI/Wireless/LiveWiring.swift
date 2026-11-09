import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import Synchronization

// The pure half of the live wiring that switches wireless on (wireless plan W16). Everything here is plain Swift and
// Foundation, tested on Linux with fakes; LiveRoot.swift makes the Apple-only pieces (`BluetoothCentral`, `NEHotspotJoiner`,
// `NWPathGateway`, `NWByteChannelFactory`, `ContinuedImportRunner`, `UNLocalNotifier`, `BackgroundRefreshScheduler`, the
// notification delegate) and hands them in through their protocols.

// MARK: - The scene, as the Wi-Fi sessions read it

/// The app's scene phase as `WirelessSession` reads it (`ForegroundSignal`). It follows the Import model's rule for being
/// away (`ImportModel.scenePhaseChanged(_:)`), so the session and the Wi-Fi recovery, which asks the Import model, see one
/// phase (W14): away from `.background` until `.active`, with `.inactive` changing nothing. Inactive on the way out of
/// active (a system alert, Control Centre) is still in front, as `ForegroundSignal` asks; inactive on the way back from the
/// background is still away until the scene is active, so no join is tried in that moment.
///
/// Away until told otherwise, as at a background relaunch for Bluetooth, which has no scene.
public final class SceneForegroundSignal: ForegroundSignal, Sendable {
    private let away: Mutex<Bool>

    public init(inForeground: Bool = false) {
        away = Mutex(!inForeground)
    }

    /// The scene changed (`AppModel.scenePhaseChanged(_:)`, before anything else hears of it).
    public func sceneChanged(_ phase: AppScenePhase) {
        switch phase {
        case .background: away.withLock { $0 = true }
        case .active: away.withLock { $0 = false }
        case .inactive: break
        }
    }

    public var isInForeground: Bool {
        get async { !away.withLock { $0 } }
    }
}

// MARK: - The one Bluetooth central, made when first needed

/// The app's one Core Bluetooth central (section 0, item 2), reached only through here: the Wi-Fi sessions and the pairing
/// check connect through it (`GATTConnector`), and the proximity scan runs on it (`ProximityScanning`).
///
/// The central is made at launch only when that can't prompt (`BluetoothCentral.makeAtLaunchIfAllowed(remindersOn:)`, passed
/// as `existing`); otherwise it is made by the first call that needs Bluetooth (`make`, `BluetoothCentral.shared()`, which
/// may show the permission prompt): a connect (the pairing step, *Import* over Wi-Fi) or starting the scan (switching the
/// reminder on). Stopping a scan that was never started makes nothing. The reports and the power stream are relayed from
/// the moment the central exists, so the proximity model can read them from launch.
public final class OnDemandBluetooth: GATTConnector, ProximityScanning, Sendable {
    public typealias Central = any GATTConnector & ProximityScanning

    private struct State {
        var central: Central?
        var power: BluetoothPower = .unknown
        var nextKey: UInt64 = 0
        var powerSubscribers: [UInt64: AsyncStream<BluetoothPower>.Continuation] = [:]
        var relays: [Task<Void, Never>] = []
    }

    public let proximityReports: AsyncStream<ProximityReport>
    private let reportSink: AsyncStream<ProximityReport>.Continuation
    private let make: @Sendable () -> Central
    private let state = Mutex(State())

    /// - Parameters:
    ///   - existing: the central made at launch, if the launch rule allowed it.
    ///   - make: makes (or returns) the central on first need.
    public init(existing: Central?, make: @escaping @Sendable () -> Central) {
        self.make = make
        // The central holds the newest 16 reports for its first reader; so does the relay, for the proximity model.
        (proximityReports, reportSink) = AsyncStream.makeStream(of: ProximityReport.self,
                                                                bufferingPolicy: .bufferingNewest(16))
        if let existing { adopt(existing) }
    }

    deinit {
        reportSink.finish()
        let (relays, subscribers) = state.withLock { ($0.relays, Array($0.powerSubscribers.values)) }
        for relay in relays { relay.cancel() }
        for subscriber in subscribers { subscriber.finish() }
    }

    /// Whether the central has been made.
    public var isMade: Bool { state.withLock { $0.central != nil } }

    public func connect(known: PeripheralID?) async throws(GATTFailure) -> any GATTLink {
        try await central().connect(known: known)
    }

    public func startProximityScan() async {
        await central().startProximityScan()
    }

    public func restartProximityScan() async {
        await central().restartProximityScan()
    }

    public func stopProximityScan() async {
        guard let made = state.withLock({ $0.central }) else { return }
        await made.stopProximityScan()
    }

    /// A new stream on every access, starting with the state now (`unknown` until the central exists and reports).
    public var powerState: AsyncStream<BluetoothPower> {
        let (stream, continuation) = AsyncStream.makeStream(of: BluetoothPower.self, bufferingPolicy: .bufferingNewest(8))
        let key: UInt64 = state.withLock { s in
            let key = s.nextKey
            s.nextKey += 1
            s.powerSubscribers[key] = continuation
            continuation.yield(s.power)
            return key
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.powerSubscribers.removeValue(forKey: key) }
        }
        return stream
    }

    // MARK: Private

    private func central() -> Central {
        if let made = state.withLock({ $0.central }) { return made }
        // `make` is `BluetoothCentral.shared()`, which returns one instance however often it is called.
        let made = make()
        adopt(made)
        return made
    }

    private func adopt(_ central: Central) {
        let first = state.withLock { s -> Bool in
            guard s.central == nil else { return false }
            s.central = central
            return true
        }
        guard first else { return }
        let reports = central.proximityReports
        let powers = central.powerState
        let sink = reportSink
        let reportRelay = Task {
            for await report in reports { sink.yield(report) }
        }
        let powerRelay = Task { [weak self] in
            for await power in powers {
                guard let self else { return }
                self.relay(power)
            }
        }
        state.withLock { $0.relays += [reportRelay, powerRelay] }
    }

    private func relay(_ power: BluetoothPower) {
        let subscribers = state.withLock { s -> [AsyncStream<BluetoothPower>.Continuation] in
            s.power = power
            return Array(s.powerSubscribers.values)
        }
        for subscriber in subscribers { subscriber.yield(power) }
    }
}

// MARK: - The reminder's notification response

/// Maps iOS's response to a reminder to the person's action (W18's `ReminderAction`). The notification delegate passes iOS's
/// own identifiers for a tap and a swipe away (`UNNotificationDefaultActionIdentifier`, `UNNotificationDismissActionIdentifier`),
/// so the mapping is tested without UserNotifications.
public enum ReminderResponseMapping {
    /// The action for a response, or nil when it isn't a reminder's (the pause notification's tap only opens the app) or the
    /// identifier is unknown.
    public static func action(categoryIdentifier: String, actionIdentifier: String, defaultIdentifier: String,
                              dismissIdentifier: String) -> ReminderAction? {
        guard categoryIdentifier == AppNotificationCategory.cameraNearby.identifier else { return nil }
        switch actionIdentifier {
        case defaultIdentifier: return .opened
        case dismissIdentifier: return .dismissed
        default: return ReminderAction(buttonIdentifier: actionIdentifier)
        }
    }
}

// MARK: - The reminder's connection hold

/// When a camera counts as connected for the reminder (W18: "a hold is started by a reminder, an import, or a connection over
/// either link (USB too)"): from when its link has a holder (Browse, or the import) and its catalogue key is known, until the
/// link is closed because its last holder let go. `AppModel` hands the keys on to `ReminderModel.begin`/`end(.connection)`.
///
/// The key is learned when the app keys the link (`AppModel`'s `CameraKeying`), which Browse does once it holds the link, and
/// the import's reconnect does just before it holds one; `LinkLeases.onAcquired` covers the second. A link keyed only to be
/// compared (a USB camera looked up by key) is never held: links are kept weakly, so a later link is never taken for it. A
/// Wi-Fi camera's name-hash key is no camera's key, so it starts nothing.
@MainActor
final class ConnectionHolds {
    private struct Entry {
        weak var link: AnyObject?
        var key: CameraKey
        var begun: Bool
    }

    /// The camera is connected (`ReminderModel.begin(.connection, camera:)`).
    var onBegin: (@MainActor (CameraKey) -> Void)?
    /// The camera is no longer connected (`ReminderModel.end(.connection, camera:)`), after its last link closed.
    var onEnd: (@MainActor (CameraKey) -> Void)?

    private let isHeld: @MainActor (any CameraLink) -> Bool
    private var entries: [Entry] = []

    /// - Parameter isHeld: whether someone holds the link (`LinkLeases.holders(of:) > 0`).
    init(isHeld: @escaping @MainActor (any CameraLink) -> Bool) {
        self.isHeld = isHeld
    }

    /// The app learned `link`'s key: the camera is connected now if the link is held.
    func keyed(_ link: any CameraLink, as key: CameraKey) {
        guard !CameraKeys.isUnidentifiedWiFi(key) else { return }
        entries.removeAll { $0.link == nil }
        let index: Int
        if let found = entries.firstIndex(where: { $0.link === link }) {
            guard entries[found].key != key else {
                if isHeld(link) { begin(at: found) }
                return
            }
            // Another key for the same link (it shouldn't happen): the old camera's connection ends first.
            if entries[found].begun { finish(entries.remove(at: found)) } else { entries.remove(at: found) }
            entries.append(Entry(link: link, key: key, begun: false))
            index = entries.count - 1
        } else {
            entries.append(Entry(link: link, key: key, begun: false))
            index = entries.count - 1
        }
        if isHeld(link) { begin(at: index) }
    }

    /// `link` got its first holder (`LinkLeases.onAcquired`).
    func acquired(_ link: any CameraLink) {
        guard let index = entries.firstIndex(where: { $0.link === link }) else { return }
        begin(at: index)
    }

    /// `link` was closed because its last holder let go (`LinkLeases.onClosed`).
    func closed(_ link: any CameraLink) {
        guard let index = entries.firstIndex(where: { $0.link === link }) else { return }
        let entry = entries.remove(at: index)
        if entry.begun { finish(entry) }
    }

    private func begin(at index: Int) {
        guard !entries[index].begun else { return }
        let key = entries[index].key
        let alreadyConnected = entries.contains { $0.begun && $0.key == key }
        entries[index].begun = true
        if !alreadyConnected { onBegin?(key) }
    }

    /// Ends the camera's connection unless another of its links is still held.
    private func finish(_ entry: Entry) {
        guard !entries.contains(where: { $0.begun && $0.key == entry.key }) else { return }
        onEnd?(entry.key)
    }
}

// MARK: - The reminder's count

/// The reminder's "N photos not yet imported when you last connected" (W18): the camera's last-known card (its last listing)
/// less what the catalogue has as imported, by content. Nil when there is no listing or the catalogue can't be read.
public enum NotImportedCount {
    public static func count(for camera: CameraKey, in catalogue: any CatalogueStore) async -> Int? {
        guard let listing = try? await catalogue.lastListing(for: camera) else { return nil }
        let identities = Array(Set(listing.entries.map(\.identity)))
        guard !identities.isEmpty else { return 0 }
        guard let states = try? await catalogue.states(of: identities) else { return nil }
        return identities.filter { states[$0] != .imported }.count
    }
}

// MARK: - The continued task, for Wi-Fi jobs

/// The background run, begun only for a Wi-Fi job (the job's carrier when the person taps *Import* or *Continue*); for any
/// other job `begin` throws `.unavailable` and the import goes on as before. USB behaviour stays as it was (decision 1: a USB
/// import pauses when the app leaves the foreground, with its one pause notification), and the system's continued-task UI
/// never shows a USB import whose progress stands still until iOS expires it (W13's open question, for Shamil).
public struct WiFiOnlyBackgroundRun: ImportBackgroundRun {
    private let run: any ImportBackgroundRun
    private let carrier: @MainActor @Sendable () -> CameraCarrier?

    /// - Parameters:
    ///   - run: `ContinuedImportRunner` in the app.
    ///   - carrier: the carrier of the job shown (`ImportModel.camera`).
    public init(_ run: any ImportBackgroundRun, carrier: @escaping @MainActor @Sendable () -> CameraCarrier?) {
        self.run = run
        self.carrier = carrier
    }

    public func begin(title: String, subtitle: String) async throws -> any ImportBackgroundHandle {
        guard await carrier() == .wifi else { throw ImportBackgroundRunError.unavailable }
        return try await run.begin(title: title, subtitle: subtitle)
    }
}

/// The expiry's last step (W13): stops the link's transfer in flight, through `TransferAborting` (W8), so the hook depends on
/// no particular link. `IPLink` cuts its connection; a link that can't stop a transfer (USB) is left alone.
public enum TransferAbort {
    public static func abort(_ link: any CameraLink) async {
        await (link as? any TransferAborting)?.abortCurrentTransfer()
    }
}

// MARK: - The wireless half of the app

/// The catalogue, once it has opened: the reminder's count reads it, and the reminder model exists before it (it is made
/// before launch finishes, so a notification response that launched the app has somewhere to go).
final class CatalogueSlot: Sendable {
    private let store = Mutex<(any CatalogueStore)?>(nil)

    func set(_ catalogue: any CatalogueStore) { store.withLock { $0 = catalogue } }
    var catalogue: (any CatalogueStore)? { store.withLock { $0 } }
}

/// The parts of wireless that live for the app's whole run, made before launch finishes (LiveRoot.swift's `LiveLaunch`), not
/// with the catalogue: the one Bluetooth central (`bluetooth`), the scene as the Wi-Fi sessions read it (`foreground`), the
/// proximity scan (`proximity`, W17) and the reminder (`reminders`, W18).
///
/// **Order** (the reasons are iOS's and W17's):
/// 1. Made before launch finishes, with the central made only if the launch rule allows it (`OnDemandBluetooth`), so state
///    restoration finds it and launch never prompts; `launchEarly()` starts reading the scan's reports (held until the
///    setting is known).
/// 2. `catalogueOpened(_:)`: the known cameras go to the confirmation first, then the reminder applies its stored setting,
///    which switches the scan on or off and handles the reports held until then against those cameras. Before that, a held
///    report would be checked against no cameras and dropped.
/// 3. The scene (`sceneChanged(_:)`, then `becameActive()`), the app-refresh task (`refreshTaskRan()`) and the reminder's
///    notification responses (`respond(...)`) at any time after 1.
@MainActor
public final class WirelessRuntime {
    public let bluetooth: OnDemandBluetooth
    public let foreground: SceneForegroundSignal
    public let proximity: ProximityModel
    public let reminders: ReminderModel

    private let slot: CatalogueSlot
    private let log: any BenchLog
    private var launchedEarly = false
    private var remindersLaunched = false

    /// - Parameters:
    ///   - bluetooth: the central, made on first need.
    ///   - refresh: the app-refresh task (`BackgroundRefreshScheduler`).
    ///   - notifier: local notifications (`UNLocalNotifier`).
    ///   - store: where the reminder's settings, holds and snooze are kept (`UserDefaultsKeyValueStore`).
    public init(bluetooth: OnDemandBluetooth, refresh: any ProximityRefreshScheduling, notifier: any LocalNotifier,
                store: any KeyValueStore, now: @escaping @Sendable () -> Date = { Date() },
                calendar: @escaping @Sendable () -> Calendar = { .current }, log: any BenchLog = SilentBenchLog()) {
        let slot = CatalogueSlot()
        let proximity = ProximityModel(scanner: bluetooth, refresh: refresh, now: now, log: log)
        self.bluetooth = bluetooth
        self.slot = slot
        self.log = log
        self.proximity = proximity
        foreground = SceneForegroundSignal()
        reminders = ReminderModel(
            settings: ReminderSettingsStore(store: store), holds: ReminderHoldStore(store: store), notifier: notifier,
            now: now, calendar: calendar, log: log,
            notImportedCount: { camera in
                guard let catalogue = slot.catalogue else { return nil }
                return await NotImportedCount.count(for: camera, in: catalogue)
            },
            scanEnabled: { on in await proximity.setEnabled(on) })
    }

    /// Step 1: starts reading the scan's reports and Bluetooth's state. Before launch finishes; again does nothing.
    public func launchEarly() {
        guard !launchedEarly else { return }
        launchedEarly = true
        proximity.launch()
    }

    /// Step 2: the catalogue has opened. The known cameras first, then the reminder (which applies the stored setting to the
    /// scan and reads the arrivals). Again (Try Again after a failed open) only refreshes the cameras.
    public func catalogueOpened(_ catalogue: any CatalogueStore) async {
        slot.set(catalogue)
        launchEarly()
        await camerasChanged()
        guard !remindersLaunched else { return }
        remindersLaunched = true
        reminders.launch(arrivals: proximity.arrivals)
    }

    /// Reads the catalogue's cameras again, for the confirmation and the reminder's settings: at launch and each time the
    /// app is back in front (a camera may have connected for the first time, or had its Bluetooth identifier stored).
    public func camerasChanged() async {
        guard let catalogue = slot.catalogue else { return }
        let cameras: [CameraRecord]
        do {
            cameras = try await catalogue.cameras()
        } catch {
            log.note("wireless: the catalogue's cameras couldn't be read: \(type(of: error))")
            return
        }
        proximity.setKnownCameras(cameras)
        reminders.setCameras(cameras.map {
            ReminderCameraName(camera: $0.key, name: $0.friendlyName.isEmpty ? CamerasWording.genericName : $0.friendlyName)
        })
    }

    /// The scene changed: first of all, so a Wi-Fi session that reads the scene and the reminder's rules see it before
    /// anything else acts on it. In front means active (W18: `.inactive` changes nothing).
    public func sceneChanged(_ phase: AppScenePhase) {
        foreground.sceneChanged(phase)
        switch phase {
        case .active: reminders.setAppInFront(true)
        case .background: reminders.setAppInFront(false)
        case .inactive: break
        }
    }

    /// The app is in front again: the permission and the snooze are read again, the scan restarts (W17: coming to the front
    /// always restarts), and the cameras are read again.
    public func becameActive() async {
        await reminders.refreshAuthorisation()
        reminders.refreshSnooze()
        await camerasChanged()
        await proximity.appBecameActive()
    }

    /// The app-refresh task ran (`BackgroundRefreshScheduler`).
    public func refreshTaskRan() async {
        await proximity.refreshTaskRan()
    }

    /// The person's response to a notification. Only a reminder's response does anything: Import Now and a tap set the
    /// camera to open, Snooze 1 Hour snoozes, Not Now and a swipe away leave the hold as it is (`ReminderModel.respond`).
    public func respond(categoryIdentifier: String, actionIdentifier: String, camera: CameraKey?,
                        defaultIdentifier: String, dismissIdentifier: String) async {
        guard let action = ReminderResponseMapping.action(
            categoryIdentifier: categoryIdentifier, actionIdentifier: actionIdentifier,
            defaultIdentifier: defaultIdentifier, dismissIdentifier: dismissIdentifier) else { return }
        await reminders.respond(action, camera: camera)
    }
}
