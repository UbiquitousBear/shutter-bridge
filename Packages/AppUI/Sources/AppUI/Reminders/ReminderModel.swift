import CameraTransport
import Catalogue
import Foundation
import Observation

// The reminder's app side (Iteration 4, section 12; wireless plan, W18): it reads `ProximityModel`'s arrivals, asks
// `ReminderPolicy` what to do, posts the notification, keeps the holds and the snooze, and answers the person's response to the
// notification. Plain Swift and Foundation, so it is tested on Linux against a fake notifier, a fake store and fixed dates.
// Wiring it in (launch, the settings sheet, telling it when a connection or an import begins and ends, the notification
// delegate, opening a camera) is W16's.

/// What the person did with a reminder. The three buttons (`AppNotificationCategory.cameraNearby`), a tap on the notification
/// itself, and a swipe away.
public enum ReminderAction: Sendable, Equatable {
    case importNow
    case notNow
    case snooze
    /// A tap on the notification (iOS's default action).
    case opened
    /// A swipe away (iOS's dismiss action, which the category asks to hear about). Counts as Not Now.
    case dismissed

    /// The action for one of the reminder's own button identifiers; nil for any other. The default and dismiss actions have
    /// identifiers of iOS's own (`UNNotificationDefaultActionIdentifier`, `UNNotificationDismissActionIdentifier`): the
    /// notification delegate maps those to `.opened` and `.dismissed`.
    public init?(buttonIdentifier: String) {
        switch buttonIdentifier {
        case AppNotificationCategory.Action.importNowIdentifier: self = .importNow
        case AppNotificationCategory.Action.notNowIdentifier: self = .notNow
        case AppNotificationCategory.Action.snoozeIdentifier: self = .snooze
        default: return nil
        }
    }
}

/// What the model did with an arrival, for callers and tests.
public enum ReminderOutcome: Sendable, Equatable {
    case posted(CameraKey)
    case suppressed(ReminderSuppression)
    /// The rules said post, but iOS wouldn't deliver (permission denied, or never asked). No hold is started, so the
    /// first arrival after the person allows notifications can remind.
    case notAllowed
}

/// What the app is doing with a camera that holds reminders back.
public enum ReminderActivity: Sendable, Hashable {
    /// A link to the camera is open, over USB or Wi-Fi.
    case connection
    /// An import is running (or paused and not given up).
    case importing
}

/// The copy of the reminder's settings. British English. "Nearby", never "switched on" (decision 8).
public enum ReminderWording {
    public static let title = "Reminders"
    public static let toggle = "Remind Me When My Camera Is Nearby"
    public static let quietHoursHeader = "Quiet Hours"
    public static let quietFrom = "From"
    public static let quietTo = "To"
    public static let camerasHeader = "Remind Me About"
    public static let camerasFooter = "Switch a camera off to stop reminders about it."
    /// Under the toggle: what a reminder is, and the limits of the scan (backlog section 11).
    public static let footer = [
        "A reminder says your camera is nearby, once, and not again for 4 hours.",
        ProximityWording.cameraSetting,
        ProximityWording.swipeAwayStops,
        ProximityWording.lowPowerMayStop,
    ].joined(separator: " ")
    /// When notifications are off for the app in Settings.
    public static let notificationsOff =
        "Notifications are off for Shutter Bridge. Turn them on in Settings to get reminders."

    /// The line under the quiet hours, "No reminders from 22:00 to 08:00."
    public static func quietSummary(_ hours: QuietHours) -> String {
        guard hours.startMinute != hours.endMinute else { return "No quiet hours." }
        return "No reminders from \(QuietHours.label(forMinute: hours.startMinute)) to "
            + "\(QuietHours.label(forMinute: hours.endMinute))."
    }
}

/// The proximity reminder's model.
///
/// - **Settings** persist as they change (`ReminderSettingsStore`). Switching the reminder on asks for notification
///   permission if iOS has never been asked, then starts the Bluetooth scan (`scanEnabled`), which asks for Bluetooth.
///   Switching it off stops the scan.
/// - **Arrivals** are decided by `ReminderPolicy` on the stored holds, the stored snooze and what the app is doing
///   (`begin(_:camera:)` and `end(_:camera:)`). A posted reminder starts the camera's 4-hour hold first.
/// - **None while the app is in front** (`setAppInFront(_:)`), and no hold starts then.
/// - **The rules run again after the last wait** before a reminder is posted, so a connection, an import, a switch-off or
///   a snooze that came meanwhile still stops it.
/// - **A connection or an import starts a hold** when it begins and again when it ends, so a long import doesn't leave the
///   camera free to remind the moment it's done, and takes back a reminder still on screen.
/// - **Responses**: *Import Now* and a tap set `cameraToOpen` for the screens to act on; *Snooze 1 Hour* snoozes every reminder for an
///   hour; *Not Now* and a swipe away do nothing more (the hold already runs).
///
/// Nothing logged names the camera: logs use `CameraKeyTags`, the report's time and its signal, which is what the bench
/// week's comparison of the hold with a quiet gap (option (d)) needs.
@MainActor
@Observable
public final class ReminderModel {
    /// The person's choices; change them with the methods below, which store them.
    public private(set) var settings: ReminderSettings
    /// The notification permission as last read; nil before the first read.
    public private(set) var authorisation: NotificationAuthorisation?
    /// When each camera was last reported nearby, for the Cameras screen's badge (`isNearby(_:)`), this run of the app.
    public private(set) var lastReport: [CameraKey: Date] = [:]
    /// The snooze's end, if one is running.
    public private(set) var snoozedUntil: Date?
    /// What the app is doing with each camera that holds reminders back, and why.
    public private(set) var activities: [ReminderActivityEntry] = []

    /// Whether the app is in front (W16 passes the scene phase through `setAppInFront(_:)`). While it is, no reminder is
    /// posted and no hold starts: the person is in the app, which shows the camera as nearby, and iOS shows no banner
    /// over the app without a presenting delegate, so a hold started then would silence a reminder the person never saw.
    /// False until told, as at a background relaunch.
    public private(set) var isAppInFront = false

    /// The camera that *Import Now* or a tap asked the app to open, until the screen has taken it (`takeCameraToOpen()`).
    /// It stays set until then, so a response that relaunched the app is still there when the screens are up.
    public private(set) var cameraToOpen: CameraKey?

    /// The cameras the settings list (`setCameras(_:)`).
    private var cameraNames: [ReminderCameraName] = []

    @ObservationIgnored private let settingsStore: ReminderSettingsStore
    @ObservationIgnored private let holds: ReminderHoldStore
    @ObservationIgnored private let notifier: any LocalNotifier
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: @Sendable () -> Calendar
    @ObservationIgnored private let log: any BenchLog
    @ObservationIgnored private let tags: CameraKeyTags
    @ObservationIgnored private let notImportedCount: @Sendable (CameraKey) async -> Int?
    @ObservationIgnored private let scanEnabled: @MainActor (Bool) async -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - settings: where the settings are kept (`UserDefaultsKeyValueStore` in the app).
    ///   - holds: where the holds and the snooze are kept, over the same kind of store.
    ///   - notifier: `UNLocalNotifier` in the app.
    ///   - now: the wall clock (fixed dates in tests).
    ///   - calendar: the person's calendar, read at each decision so a change of time zone is followed.
    ///   - notImportedCount: the last known count of photos not yet imported for a camera (the card as last listed), nil
    ///     when none.
    ///   - scanEnabled: switches the proximity scan on or off: `ProximityModel.setEnabled(_:)` in the app.
    public init(settings settingsStore: ReminderSettingsStore, holds: ReminderHoldStore, notifier: any LocalNotifier,
                now: @escaping @Sendable () -> Date = { Date() }, calendar: @escaping @Sendable () -> Calendar = { .current },
                log: any BenchLog = SilentBenchLog(), tags: CameraKeyTags = .shared,
                notImportedCount: @escaping @Sendable (CameraKey) async -> Int? = { _ in nil },
                scanEnabled: @escaping @MainActor (Bool) async -> Void = { _ in }) {
        self.settingsStore = settingsStore
        self.holds = holds
        self.notifier = notifier
        self.now = now
        self.calendar = calendar
        self.log = log
        self.tags = tags
        self.notImportedCount = notImportedCount
        self.scanEnabled = scanEnabled
        settings = settingsStore.load()
        snoozedUntil = holds.snoozedUntil(now: now())
    }

    deinit { task?.cancel() }

    // MARK: Launch

    /// Applies the stored setting to the scan and reads the permission, then reads `arrivals` until the stream ends. Call
    /// once at launch, once the setting can be read. `launch(arrivals:)` runs it in a task.
    public func run(_ arrivals: AsyncStream<ProximityArrival>) async {
        await applyStoredSetting()
        for await arrival in arrivals {
            _ = await handle(arrival)
        }
    }

    /// `run(_:)` in a task of the model's own; calling it again does nothing.
    public func launch(arrivals: AsyncStream<ProximityArrival>) {
        guard task == nil else { return }
        task = Task { [weak self] in
            // Held weakly between arrivals, so a model that is let go ends the task at its next element.
            await self?.applyStoredSetting()
            for await arrival in arrivals {
                guard let self else { return }
                _ = await self.handle(arrival)
            }
        }
    }

    /// Tells the scan the stored setting and reads the permission. At launch.
    public func applyStoredSetting() async {
        authorisation = await notifier.authorisation()
        await scanEnabled(settings.enabled)
    }

    // MARK: Settings

    /// Switches the reminder on or off and stores it. On: asks for notification permission if iOS has never been asked, then
    /// starts the scan. Off: stops the scan. The reminder stays on when permission is denied (the person can allow it in
    /// Settings), and `authorisation` says so for the screen to show.
    public func setEnabled(_ on: Bool) async {
        guard on != settings.enabled else { return }
        settings.enabled = on
        save()
        await finishSwitching()
    }

    /// The Settings toggle's binding: the choice shows and is stored at once (so the toggle doesn't snap back), and the
    /// permission and the scan follow in a task.
    public var remindsWhenNearby: Bool {
        get { settings.enabled }
        set {
            guard newValue != settings.enabled else { return }
            settings.enabled = newValue
            save()
            Task { await finishSwitching() }
        }
    }

    /// The permission and the scan after the setting changed. The scan follows the setting as it is when this ends, so
    /// switching on and off quickly can't leave the scan the wrong way round.
    private func finishSwitching() async {
        if settings.enabled {
            var status = await notifier.authorisation()
            if status == .notDetermined {
                _ = await notifier.requestAuthorisation()
                status = await notifier.authorisation()
            }
            authorisation = status
            log.note("reminder: switched on, notifications \(status.rawValue)")
        } else {
            log.note("reminder: switched off")
        }
        await scanEnabled(settings.enabled)
    }

    /// Reads iOS's permission again (the person may have changed it in Settings).
    public func refreshAuthorisation() async {
        authorisation = await notifier.authorisation()
    }

    /// Whether the screen should say that notifications are off: the reminder is on and iOS won't deliver.
    public var notificationsAreOff: Bool {
        guard settings.enabled, let authorisation else { return false }
        return authorisation == .denied
    }

    public func setQuietHours(start: Int, end: Int) {
        settings.quietHours = QuietHours(startMinute: start, endMinute: end)
        save()
    }

    /// The quiet hours' ends as times today, for a time-only `DatePicker` (`ReminderSettingsView`); setting one stores its
    /// hour and minute.
    public var quietStart: Date {
        get { QuietHours.date(forMinute: settings.quietHours.startMinute, on: now(), calendar: calendar()) }
        set { setQuietHours(start: QuietHours.minuteOfDay(of: newValue, calendar: calendar()), end: settings.quietHours.endMinute) }
    }

    public var quietEnd: Date {
        get { QuietHours.date(forMinute: settings.quietHours.endMinute, on: now(), calendar: calendar()) }
        set { setQuietHours(start: settings.quietHours.startMinute, end: QuietHours.minuteOfDay(of: newValue, calendar: calendar())) }
    }

    /// The cameras the settings list, with their names, for the per-camera choice. Call when the catalogue's cameras change.
    public func setCameras(_ cameras: [ReminderCameraName]) {
        cameraNames = cameras
    }

    /// One row per listed camera: on means reminders for it (not muted). A binding for `ForEach($model.cameraChoices)`.
    public var cameraChoices: [ReminderCameraChoice] {
        get {
            cameraNames.map { ReminderCameraChoice(camera: $0.camera, name: $0.name, isReminded: !isMuted($0.camera)) }
        }
        set {
            for choice in newValue where choice.isReminded == isMuted(choice.camera) {
                setMuted(!choice.isReminded, camera: choice.camera)
            }
        }
    }

    public func setMuted(_ muted: Bool, camera: CameraKey) {
        if muted { settings.mutedCameras.insert(camera) } else { settings.mutedCameras.remove(camera) }
        save()
    }

    public func isMuted(_ camera: CameraKey) -> Bool { settings.mutedCameras.contains(camera) }

    // MARK: Arrivals

    /// Decides one arrival and acts on it. A posted reminder starts the hold before the notification goes out, so a second
    /// arrival that follows is held. One reader at a time (`run(_:)`): two calls in flight could both decide to post.
    ///
    /// Reading the permission and the count waits, and the main actor runs other work meanwhile (a connection or an import
    /// beginning, the reminder switched off, a snooze, the app coming to the front), so the rules are applied again on what
    /// is true after the last wait, right before the hold starts and the notification goes out.
    @discardableResult
    public func handle(_ arrival: ProximityArrival) async -> ReminderOutcome {
        lastReport[arrival.camera] = arrival.report.at
        let tag = tags.tag(for: arrival.camera)
        let reported = "report at \(ReminderLogTime.string(arrival.report.at))"
            + (arrival.report.rssi.map { ", RSSI \($0) dBm" } ?? "")
        if case let .suppress(reason) = decide(arrival, now: now()) {
            log.note("reminder: \(tag) \(reported), no reminder: \(reason)")
            return .suppressed(reason)
        }
        guard await allowsPosting() else {
            log.note("reminder: \(tag) \(reported), no reminder: notifications not allowed")
            return .notAllowed
        }
        let count = await notImportedCount(arrival.camera)
        // No wait between this decision and the hold.
        let at = now()
        switch decide(arrival, now: at) {
        case let .suppress(reason):
            log.note("reminder: \(tag) \(reported), no reminder: \(reason) (while getting ready to post)")
            return .suppressed(reason)
        case let .post(camera):
            holds.startHold(for: camera, at: at)
            await notifier.post(.cameraNearby(camera, notImported: count))
            // A connection or an import that began while iOS took the request has already withdrawn the reminder, perhaps
            // before it was added: take it back again.
            if !activities.isEmpty { await notifier.withdraw(.cameraNearby(camera, notImported: nil)) }
            log.note("reminder: \(tag) \(reported), reminder posted, hold started")
            return .posted(camera)
        }
    }

    /// The rules on what is stored and known at `now`. The hold's length is the store's, so the reason logged and the hold
    /// kept agree.
    private func decide(_ arrival: ProximityArrival, now at: Date) -> ReminderDecision {
        ReminderPolicy(settings: settings, calendar: calendar(), hold: holds.hold)
            .decide(arrival, now: at, holds: holds.holds(now: at), connectedOrImporting: !activities.isEmpty,
                    snoozedUntil: holds.snoozedUntil(now: at), appInFront: isAppInFront)
    }

    /// Whether anything is holding reminders back because the app is busy with a camera.
    public var isBusy: Bool { !activities.isEmpty }

    /// Whether to show `camera` as nearby on the Cameras screen: reported within `ReminderPolicy.nearbyWindow`.
    public func isNearby(_ camera: CameraKey) -> Bool {
        ReminderPolicy.isNearby(lastReport: lastReport[camera], now: now())
    }

    // MARK: What the app is doing

    /// The app came to the front (`true`, scene phase `.active`) or left it (`false`, `.background`). W16 calls it.
    public func setAppInFront(_ inFront: Bool) {
        isAppInFront = inFront
    }

    /// The app began `activity` with `camera`: holds reminders back until it ends, starts the camera's hold, and takes back a
    /// reminder still showing (it would be out of date).
    public func begin(_ activity: ReminderActivity, camera: CameraKey) async {
        let entry = ReminderActivityEntry(activity: activity, camera: camera)
        if !activities.contains(entry) { activities.append(entry) }
        holds.startHold(for: camera, at: now())
        await notifier.withdraw(.cameraNearby(camera, notImported: nil))
    }

    /// `activity` with `camera` ended: starts the camera's hold again from now, so it doesn't remind the moment the import
    /// is done, however long it ran.
    public func end(_ activity: ReminderActivity, camera: CameraKey) {
        activities.removeAll { $0 == ReminderActivityEntry(activity: activity, camera: camera) }
        holds.startHold(for: camera, at: now())
    }

    // MARK: Responses

    /// The person's response to a reminder, with the camera the notification carried (`AppNotification.userInfo`; nil when
    /// iOS handed back none).
    public func respond(_ action: ReminderAction, camera: CameraKey?) async {
        switch action {
        case .importNow, .opened:
            log.note("reminder: \(action == .importNow ? "Import Now" : "tapped")")
            guard let camera else { return }
            cameraToOpen = camera
        case .notNow, .dismissed:
            // The hold started when the reminder was posted, so there is nothing more to do.
            log.note("reminder: \(action == .notNow ? "Not Now" : "swiped away")")
        case .snooze:
            let at = now()
            let until = at.addingTimeInterval(holds.snoozeLength.timeInterval)
            holds.snooze(until: until, now: at)
            snoozedUntil = until
            log.note("reminder: snoozed until \(ReminderLogTime.string(until))")
        }
    }

    /// The camera of a reminder's `userInfo`, or nil.
    public nonisolated static func camera(fromUserInfo userInfo: [AnyHashable: Any]) -> CameraKey? {
        (userInfo[AppNotification.cameraUserInfoKey] as? String).map(CameraKey.init(rawValue:))
    }

    /// Hands over the camera to open, once.
    public func takeCameraToOpen() -> CameraKey? {
        defer { cameraToOpen = nil }
        return cameraToOpen
    }

    /// The snooze's end if it is still running, for the screen.
    public func refreshSnooze() {
        snoozedUntil = holds.snoozedUntil(now: now())
    }

    // MARK: Private

    private func save() { settingsStore.save(settings) }

    private func allowsPosting() async -> Bool {
        let status = await notifier.authorisation()
        authorisation = status
        return status.allowsPosting
    }
}

/// A camera and the name the settings show for it (the Cameras screen's).
public struct ReminderCameraName: Sendable, Equatable {
    public let camera: CameraKey
    public let name: String

    public init(camera: CameraKey, name: String) {
        self.camera = camera
        self.name = name
    }
}

/// A camera's row in the settings: whether it gets reminders.
public struct ReminderCameraChoice: Sendable, Equatable, Identifiable {
    public let camera: CameraKey
    public let name: String
    public var isReminded: Bool
    public var id: String { camera.rawValue }
}

/// One thing the app is doing with a camera.
public struct ReminderActivityEntry: Sendable, Hashable {
    public let activity: ReminderActivity
    public let camera: CameraKey

    public init(activity: ReminderActivity, camera: CameraKey) {
        self.activity = activity
        self.camera = camera
    }
}
