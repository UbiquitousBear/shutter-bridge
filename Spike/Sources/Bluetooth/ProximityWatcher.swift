import Foundation
import Observation
import CoreBluetooth
import UserNotifications
import UIKit

/// Day 6 go/no-go for the proximity reminder (proposal: "Proximity reminder over Bluetooth LE"): does iOS wake
/// the app when the camera comes into range, how long after it was switched on, and does the reminder reach the
/// user? It runs the production design in miniature:
///
/// - a `CBCentralManager` with a restore identifier, recreated on every launch so iOS can relaunch the app for
///   Bluetooth and hand back the scan (`centralManager(_:willRestoreState:)` logs what came back);
/// - a background scan filtered on the one service UUID chosen on the Bluetooth tab (Apple requires a UUID for
///   background scans; `bluetooth-central` is in UIBackgroundModes);
/// - `registerForConnectionEvents` on the same UUID (requirement 3 in AdvertisementScanner.swift): when Creators'
///   App reconnects to the camera, the phone may report the connection even if the camera stops advertising;
/// - on each wake: log the app state and time, debounce (1 minute by default here, 30 minutes in the proposal),
///   post "Camera nearby · spike test" with Import now / Not now / Snooze today, and log what the user chose.
///
/// Measurements: `ble.proximity.latency` (s, "Camera switched on now" → first discovery),
/// `ble.proximity.connectionEvent.latency` (s, same mark → first peerConnected) and
/// `ble.proximity.detectToNotify` (s, discovery callback → notification accepted by the notification centre).
@Observable
@MainActor
final class ProximityWatcher: NSObject {
    static let shared = ProximityWatcher()

    /// Must be identical on every launch: iOS hands the scan back to the central created with this identifier.
    static let restoreIdentifier = "com.ubiquitousbear.shutterbridge.spike.proximity"
    static let categoryIdentifier = "spike.camera.nearby"
    static let importNowAction = "spike.camera.importNow"
    static let notNowAction = "spike.camera.notNow"
    static let snoozeTodayAction = "spike.camera.snoozeToday"

    /// UserDefaults keys. `serviceUUID` is shared with BluetoothView's @AppStorage.
    enum Keys {
        static let serviceUUID = "ble.serviceUUID"
        static let enabled = "ble.proximity.enabled"
        static let debounce = "ble.proximity.debounceSeconds"
        static let switchedOnAt = "ble.proximity.switchedOnAt"
        static let discoveryLatencyPending = "ble.proximity.discoveryLatencyPending"
        static let connectionLatencyPending = "ble.proximity.connectionLatencyPending"
        static let lastNotifiedAt = "ble.proximity.lastNotifiedAt"
        static let snoozedUntil = "ble.proximity.snoozedUntil"
    }

    private(set) var enabled: Bool
    private(set) var debounceSeconds: Double
    private(set) var centralState = "not created"
    private(set) var isScanning = false
    private(set) var scanFilter = "none"
    private(set) var notificationStatus = "not checked"
    private(set) var lastDiscovery = "none yet"
    private(set) var lastConnectionEvent = "none yet"
    private(set) var lastAction = "none yet"
    private(set) var restoration = "no restoration this launch"
    private(set) var switchedOnAt: Date?
    private(set) var discoveryLatencyPending: Bool
    private(set) var connectionLatencyPending: Bool
    private(set) var lastNotifiedAt: Date?
    private(set) var snoozedUntil: Date?
    /// Set when the user taps Import now (or the notification itself); ContentView switches to the Wired tab.
    private(set) var importRequestedAt: Date?
    var log: SpikeLog?

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var rearmTask: Task<Void, Never>?
    /// Scan services iOS handed back in willRestoreState, until the first powered-on update decides whether to
    /// keep that scan.
    @ObservationIgnored private var restoredScanServices: [String] = []
    private let clock = ContinuousClock()

    private var defaults: UserDefaults { .standard }

    override init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Keys.enabled)
        let debounce = d.double(forKey: Keys.debounce)
        debounceSeconds = debounce > 0 ? debounce : 60
        switchedOnAt = Self.storedDate(d, Keys.switchedOnAt)
        discoveryLatencyPending = d.bool(forKey: Keys.discoveryLatencyPending)
        connectionLatencyPending = d.bool(forKey: Keys.connectionLatencyPending)
        lastNotifiedAt = Self.storedDate(d, Keys.lastNotifiedAt)
        snoozedUntil = Self.storedDate(d, Keys.snoozedUntil)
        super.init()
    }

    // MARK: - Launch

    /// Called from the app delegate's didFinishLaunching, before any UI exists. As Apple asks since iOS 26 (the
    /// `.bluetoothCentrals` launch option is deprecated, and always nil in a scene-based app anyway), the central
    /// is recreated here on every launch with the stored restore identifier, and `willRestoreState` tells us if
    /// iOS relaunched the app for it.
    func launch(log: SpikeLog, launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        self.log = log
        registerNotificationCategory()
        let optionsText = launchOptions.map { opts in
            opts.keys.map(\.rawValue).sorted().joined(separator: ", ")
        } ?? "none (expected for a scene-based app)"
        let authorization = CBManager.authorization
        var line = "proximity watcher at launch: \(enabled ? "on" : "off"), filter \(storedServiceUUID ?? "none")"
        line += ", Bluetooth permission \(Self.describe(authorization)), app \(Self.appStateDescription())"
        line += ", launch options: \(optionsText)"
        log.note(line)
        // Creating a central prompts for Bluetooth permission, so only do it at launch once the watcher has been
        // switched on or permission is already granted (the enabled flag can't be read before the first unlock
        // after a reboot, but the authorisation can).
        if enabled || authorization == .allowedAlways {
            makeCentral()
        }
        Task { await refreshNotificationStatus() }
    }

    private func makeCentral() {
        guard central == nil else { return }
        centralState = "starting"
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: false,
        ])
    }

    // MARK: - Controls (Bluetooth tab)

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Keys.enabled)
        if on {
            log?.note("proximity watcher switched on")
            Task { await requestNotificationAuthorization() }
            if central == nil { makeCentral() } else { startScan(reason: "watcher switched on") }
        } else {
            rearmTask?.cancel()
            central?.stopScan()
            // Releasing the manager ends its scan and connection-event registration, so iOS has nothing to
            // restore and won't relaunch the app for it.
            central = nil
            isScanning = false
            scanFilter = "none"
            centralState = "released"
            log?.note("proximity watcher switched off: scan stopped, central released")
        }
    }

    func setDebounce(_ seconds: Double) {
        debounceSeconds = max(10, seconds)
        defaults.set(debounceSeconds, forKey: Keys.debounce)
    }

    /// The chosen proximity UUID changed on the Bluetooth tab.
    func serviceUUIDChanged() {
        log?.note("proximity filter set to \(storedServiceUUID ?? "none")")
        if enabled { startScan(reason: "filter changed") }
    }

    /// Timestamps the moment the camera was switched on: the next discovery records `ble.proximity.latency` and
    /// the next peerConnected records `ble.proximity.connectionEvent.latency`. Re-arms the scan and the debounce
    /// so this test gets a fresh discovery and a reminder.
    func markCameraSwitchedOn() {
        let now = Date()
        switchedOnAt = now
        discoveryLatencyPending = true
        connectionLatencyPending = true
        lastNotifiedAt = nil
        defaults.set(now.timeIntervalSince1970, forKey: Keys.switchedOnAt)
        defaults.set(true, forKey: Keys.discoveryLatencyPending)
        defaults.set(true, forKey: Keys.connectionLatencyPending)
        defaults.removeObject(forKey: Keys.lastNotifiedAt)
        log?.note("proximity: camera switched on at \(Self.time(now)). Lock the phone now; the next discovery records ble.proximity.latency.")
        if let snoozedUntil, snoozedUntil > now {
            log?.warn("proximity: reminders are snoozed until \(Self.time(snoozedUntil)); tap Clear snooze or no reminder will be posted")
        }
        if enabled {
            startScan(reason: "camera switched on (re-armed so the camera is reported afresh)")
        } else {
            log?.warn("proximity watcher is off: switch on Watch in background first, or nothing will be detected")
        }
    }

    func rearmNow() {
        guard enabled else { log?.warn("proximity watcher is off"); return }
        startScan(reason: "re-armed by hand")
    }

    /// ContentView has switched to the Wired tab for an Import now tap.
    func consumeImportRequest() {
        importRequestedAt = nil
    }

    func clearSnooze() {
        snoozedUntil = nil
        defaults.removeObject(forKey: Keys.snoozedUntil)
        log?.note("proximity: snooze cleared")
    }

    func sendTestNotification() {
        postNotification(source: "test button", name: "Test camera", detected: nil, appState: Self.appStateDescription())
    }

    /// SIGKILL looks to iOS like the system ending a suspended app, which (unlike a swipe-away in the app
    /// switcher) still allows a Bluetooth relaunch: the way to test state restoration without waiting for memory
    /// pressure. verify on day 1: that iOS 27 still relaunches after a self-SIGKILL.
    func terminateForRelaunchTest() {
        // Arm this test like "Camera switched on now": the relaunch discovery records ble.proximity.latency
        // (measured from this tap), the debounce is cleared and the scan restarts so the camera is reported afresh.
        if enabled { markCameraSwitchedOn() }
        defaults.synchronize()   // flush the re-armed state before SIGKILL
        log?.warn("proximity: killing the app (SIGKILL) to test a Bluetooth relaunch; latency is measured from now. Lock the phone and switch the camera on straight away, wait for the reminder, then reopen and check this log for willRestoreState.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            kill(getpid(), SIGKILL)
        }
    }

    // MARK: - Scanning

    var storedServiceUUID: String? {
        guard let s = defaults.string(forKey: Keys.serviceUUID), !s.isEmpty else { return nil }
        return s
    }

    private func startScan(reason: String) {
        guard let central else { makeCentral(); return }
        guard central.state == .poweredOn else {
            log?.note("proximity scan waits for Bluetooth (\(centralState)): \(reason)")
            return
        }
        guard let raw = storedServiceUUID, let uuid = Self.serviceUUID(from: raw) else {
            rearmTask?.cancel()
            central.stopScan()
            // stopScan leaves the connection-event registration in place; swap it for one no peer can match.
            central.registerForConnectionEvents(options: [.serviceUUIDs: [CBUUID(nsuuid: UUID())]])
            isScanning = false
            scanFilter = "none"
            log?.warn("proximity watcher: no valid service UUID, so scan and connection events are off. Pick one under Day 6 · Proximity filter; background scans need one.")
            return
        }
        rearmTask?.cancel()
        central.stopScan()
        central.scanForPeripherals(withServices: [uuid], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        central.registerForConnectionEvents(options: [.serviceUUIDs: [uuid]])
        isScanning = true
        scanFilter = uuid.uuidString
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? " · Low Power Mode ON (iOS stops background scans)" : ""
        log?.note("proximity scan started for \(uuid.uuidString) + connection events: \(reason) · app \(Self.appStateDescription())\(lowPower)")
    }

    /// Without duplicates iOS reports a peripheral once per scan, so the scan is restarted one debounce interval
    /// after a discovery. While suspended the restart waits for the next wake; that is part of what day 6 measures.
    private func scheduleRearm() {
        rearmTask?.cancel()
        let delay = debounceSeconds
        rearmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.enabled else { return }
            self.startScan(reason: "re-armed \(Int(delay)) s after the last discovery")
        }
    }

    // MARK: - Reminder

    private func considerNotifying(source: String, name: String, detected: ContinuousClock.Instant, appState: String) {
        let now = Date()
        if let until = snoozedUntil, until > now {
            log?.note("proximity: snoozed until \(Self.time(until)); no reminder (\(source))")
            return
        }
        if let last = lastNotifiedAt, now.timeIntervalSince(last) < debounceSeconds {
            log?.note(String(format: "proximity: debounced (last reminder %.0f s ago, debounce %.0f s; %@)",
                             now.timeIntervalSince(last), debounceSeconds, source))
            return
        }
        lastNotifiedAt = now
        defaults.set(now.timeIntervalSince1970, forKey: Keys.lastNotifiedAt)
        postNotification(source: source, name: name, detected: detected, appState: appState)
    }

    private func postNotification(source: String, name: String, detected: ContinuousClock.Instant?, appState: String) {
        let content = UNMutableNotificationContent()
        content.title = "Camera nearby · spike test"
        content.body = "\(name) seen (\(source)). Import now opens the spike app."
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["source": source]
        let request = UNNotificationRequest(identifier: "spike.nearby.\(UUID().uuidString)", content: content, trigger: nil)
        let clock = self.clock
        UNUserNotificationCenter.current().add(request) { error in
            let accepted = clock.now
            let errorText: String? = error.map { "\($0)" }
            Task { @MainActor in
                ProximityWatcher.shared.notificationAdded(errorText: errorText, source: source, detected: detected,
                                                          accepted: accepted, appState: appState)
            }
        }
    }

    private func notificationAdded(errorText: String?, source: String, detected: ContinuousClock.Instant?,
                                   accepted: ContinuousClock.Instant, appState: String) {
        if let errorText {
            log?.error("proximity: reminder not scheduled (\(source)): \(errorText); notification permission: \(notificationStatus)")
            return
        }
        guard let detected else {
            log?.note("proximity: test reminder scheduled; notification permission: \(notificationStatus)")
            return
        }
        log?.measure("ble.proximity.detectToNotify", (accepted - detected).inSeconds, "s",
                     context: "\(source) callback → reminder accepted by the notification centre; app \(appState); permission \(notificationStatus)")
    }

    private func registerNotificationCategory() {
        let importNow = UNNotificationAction(identifier: Self.importNowAction, title: "Import now", options: [.foreground])
        let notNow = UNNotificationAction(identifier: Self.notNowAction, title: "Not now", options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeTodayAction, title: "Snooze today", options: [])
        // customDismissAction: a swipe-away reaches the delegate too (the proposal treats it as Not now).
        let category = UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [importNow, notNow, snooze],
                                              intentIdentifiers: [], options: [.customDismissAction])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func requestNotificationAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            log?.note("notification permission \(granted ? "granted" : "not granted")")
        } catch {
            log?.error("notification permission request failed: \(error)")
        }
        await refreshNotificationStatus()
    }

    func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        var text = Self.describe(settings.authorizationStatus)
        if settings.authorizationStatus == .authorized, settings.alertSetting != .enabled { text += ", alerts off" }
        notificationStatus = text
    }

    /// From ProximityNotificationDelegate (main actor).
    func notePresentedInForeground(category: String) {
        guard category == Self.categoryIdentifier else { return }
        log?.note("proximity: reminder shown as a banner while the app is in the foreground")
    }

    /// From ProximityNotificationDelegate (main actor): which action the user took, and how long after delivery.
    func handleResponse(action: String, deliveredAt: Date, category: String) {
        let now = Date()
        let state = Self.appStateDescription()
        guard category == Self.categoryIdentifier else {
            log?.note("notification response \(action) for category \(category) · app \(state)")
            return
        }
        let what: String
        switch action {
        case Self.importNowAction:
            what = "Import now"
            importRequestedAt = now
        case Self.notNowAction:
            what = "Not now"
        case Self.snoozeTodayAction:
            what = "Snooze today"
            let calendar = Calendar.current
            let until = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
            snoozedUntil = until
            defaults.set(until.timeIntervalSince1970, forKey: Keys.snoozedUntil)
        case UNNotificationDismissActionIdentifier:
            what = "dismissed (counts as Not now)"
        case UNNotificationDefaultActionIdentifier:
            what = "opened the app from the reminder"
            importRequestedAt = now
        default:
            what = action
        }
        let after = now.timeIntervalSince(deliveredAt)
        lastAction = "\(what) at \(Self.time(now)), \(String(format: "%.0f", after)) s after delivery · app \(state)"
        log?.note("proximity: user chose \(what) \(String(format: "%.1f", after)) s after the reminder · app \(state)")
    }

    // MARK: - Helpers

    /// A CBUUID for a 16-bit ("FE2C"), 32-bit or 128-bit UUID string, or nil. `CBUUID(string:)` raises an
    /// Objective-C exception on malformed input, so nothing user-typed reaches it unchecked.
    nonisolated static func serviceUUID(from text: String) -> CBUUID? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let hexDigits = CharacterSet(charactersIn: "0123456789ABCDEF")
        if t.count == 4 || t.count == 8, t.unicodeScalars.allSatisfy({ hexDigits.contains($0) }) {
            return CBUUID(string: t)
        }
        if t.count == 36, UUID(uuidString: t) != nil {
            return CBUUID(string: t)
        }
        return nil
    }

    /// The canonical string for a typed service UUID ("fe2c" → "FE2C"), or nil if it isn't one.
    nonisolated static func normalizedServiceUUID(_ text: String) -> String? {
        serviceUUID(from: text)?.uuidString
    }

    /// "active", "background", "background, locked".
    static func appStateDescription() -> String {
        let app = UIApplication.shared
        let state: String
        switch app.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        return app.isProtectedDataAvailable ? state : state + ", locked"
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    nonisolated static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "powered on"
        case .poweredOff: return "Bluetooth off"
        case .resetting: return "resetting"
        case .unauthorized: return "unauthorised"
        case .unsupported: return "unsupported"
        case .unknown: return "unknown"
        @unknown default: return "state \(state.rawValue)"
        }
    }

    nonisolated static func describe(_ authorization: CBManagerAuthorization) -> String {
        switch authorization {
        case .allowedAlways: return "allowed"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "authorisation \(authorization.rawValue)"
        }
    }

    nonisolated static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "allowed"
        case .denied: return "denied (Settings → SB Spike → Notifications)"
        case .notDetermined: return "not asked yet"
        case .provisional: return "provisional (quiet delivery)"
        case .ephemeral: return "ephemeral"
        @unknown default: return "status \(status.rawValue)"
        }
    }

    private static func storedDate(_ d: UserDefaults, _ key: String) -> Date? {
        let t = d.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
}

extension ProximityWatcher: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        centralState = Self.describe(central.state)
        switch central.state {
        case .poweredOn:
            let restored = restoredScanServices
            restoredScanServices = []
            if enabled, let raw = storedServiceUUID, let uuid = Self.serviceUUID(from: raw), restored == [uuid.uuidString] {
                // iOS relaunched the app with this very scan still running. Keep it rather than stop and restart
                // it: the discovery that woke the app can still be queued behind this callback and must not be lost, or
                // ble.proximity.latency on the relaunch path would be late or missing.
                central.registerForConnectionEvents(options: [.serviceUUIDs: [uuid]])
                isScanning = true
                scanFilter = uuid.uuidString
                log?.note("proximity: kept the restored scan for \(uuid.uuidString) and re-registered connection events · app \(Self.appStateDescription())")
            } else if enabled {
                startScan(reason: "Bluetooth powered on")
            } else if isScanning {
                log?.note("proximity: a restored scan is running while the watcher reads as off (locked since boot?); leaving it")
            }
        case .poweredOff:
            isScanning = false
            log?.warn("proximity: Bluetooth is off; background scanning stops until it is back on")
        case .unauthorized:
            isScanning = false
            log?.error("proximity: Bluetooth permission denied (Settings → SB Spike → Bluetooth)")
        case .unsupported:
            isScanning = false
            log?.error("proximity: Bluetooth LE unsupported on this device")
        default:
            log?.note("proximity central: \(centralState)")
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        let services = (dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID]) ?? []
        let options = (dict[CBCentralManagerRestoredStateScanOptionsKey] as? [String: Any]) ?? [:]
        let peripheralText = peripherals.isEmpty ? "none"
            : peripherals.map { "\($0.name ?? "(no name)") [\($0.identifier.uuidString.prefix(8))]" }.joined(separator: ", ")
        let serviceText = services.isEmpty ? "none" : services.map(\.uuidString).joined(separator: ", ")
        let optionText = options.isEmpty ? "none" : options.keys.sorted().map { "\($0)=\(options[$0] ?? "")" }.joined(separator: ", ")
        let now = Date()
        restoration = "restored at \(Self.time(now)) · scan services: \(serviceText) · peripherals: \(peripheralText)"
        restoredScanServices = services.map(\.uuidString)
        if !services.isEmpty {
            isScanning = true
            scanFilter = serviceText
        }
        var line = "proximity: willRestoreState (iOS relaunched or restored the central) · app \(Self.appStateDescription())"
        line += " · scan services: \(serviceText) · scan options: \(optionText) · peripherals: \(peripheralText)"
        line += " · keys: \(dict.keys.sorted())"
        log?.note(line)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let detected = clock.now
        let now = Date()
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "(no name)"
        let state = Self.appStateDescription()
        let description = "\(name) [\(peripheral.identifier.uuidString.prefix(8))] RSSI \(RSSI) at \(Self.time(now)) · app \(state)"
        lastDiscovery = description
        log?.note("proximity: discovered \(description)")
        if discoveryLatencyPending, let on = switchedOnAt {
            discoveryLatencyPending = false
            defaults.set(false, forKey: Keys.discoveryLatencyPending)
            log?.measure("ble.proximity.latency", now.timeIntervalSince(on), "s",
                         context: "camera switched on → background-scan discovery; app \(state); \(name), RSSI \(RSSI)")
        }
        considerNotifying(source: "advertisement", name: name, detected: detected, appState: state)
        scheduleRearm()
    }

    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        let detected = clock.now
        let now = Date()
        let name = peripheral.name ?? "(no name)"
        let state = Self.appStateDescription()
        let what: String
        switch event {
        case .peerConnected: what = "peerConnected"
        case .peerDisconnected: what = "peerDisconnected"
        @unknown default: what = "event \(event.rawValue)"
        }
        lastConnectionEvent = "\(what): \(name) at \(Self.time(now)) · app \(state)"
        log?.note("proximity: connection event \(what) for \(name) [\(peripheral.identifier.uuidString.prefix(8))] · app \(state)")
        guard event == .peerConnected else { return }
        if connectionLatencyPending, let on = switchedOnAt {
            connectionLatencyPending = false
            defaults.set(false, forKey: Keys.connectionLatencyPending)
            log?.measure("ble.proximity.connectionEvent.latency", now.timeIntervalSince(on), "s",
                         context: "camera switched on → peerConnected; app \(state); \(name)")
        }
        considerNotifying(source: "connection event", name: name, detected: detected, appState: state)
    }
}

/// UNUserNotificationCenter's delegate (set in the app delegate before launch finishes, as Apple requires). Not
/// main-actor isolated: the system may call it off the main thread, so it copies the strings it needs, hops to
/// the main actor, and calls the completion handlers from there.
final class ProximityNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Show the reminder as a banner even while the spike is open, so foreground tests see it too.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let category = notification.request.content.categoryIdentifier
        Task { @MainActor in
            ProximityWatcher.shared.notePresentedInForeground(category: category)
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let action = response.actionIdentifier
        let deliveredAt = response.notification.date
        let category = response.notification.request.content.categoryIdentifier
        Task { @MainActor in
            ProximityWatcher.shared.handleResponse(action: action, deliveredAt: deliveredAt, category: category)
            completionHandler()
        }
    }
}
