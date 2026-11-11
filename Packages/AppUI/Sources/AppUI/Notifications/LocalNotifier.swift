import Catalogue
import Foundation

/// Whether the app may post notifications, as iOS says.
public enum NotificationAuthorisation: String, Sendable, Hashable, CaseIterable {
    /// Nobody has asked yet. A notification posted now fails (UNErrorDomain 2003 in the spike).
    case notDetermined
    case denied
    case authorised
    /// Delivered quietly to Notification Centre without asking.
    case provisional
    /// An App Clip's temporary permission; never this app's, kept so every iOS status has a case.
    case ephemeral

    /// Whether a notification posted now is delivered.
    public var allowsPosting: Bool {
        switch self {
        case .authorised, .provisional, .ephemeral: true
        case .notDetermined, .denied: false
        }
    }
}

/// A notification the app posts.
public enum AppNotification: Sendable, Hashable {
    /// An import paused while the app was away: iOS ended its continued task (Wi-Fi), the app left the foreground
    /// (USB; Shamil, 9 Nov), or getting the camera back needs a join (W14). One at a time: a newer one replaces it.
    case importPaused
    /// The same for a *Stage* job (Shamil, 11 Nov): "Staging paused." It shares the pause notification's identifier,
    /// so either replaces the other.
    case stagingPaused
    /// A known camera was noticed nearby (Iteration 4, section 12; W18). `notImported` is the last known count of photos
    /// not yet imported, from the card as last listed (a wake can't read the card), or nil when there is none.
    case cameraNearby(CameraKey, notImported: Int?)
    /// A Wi-Fi join is held because the app went away during it (`WirelessPhase.awaitingFront`; bench 19.1): posted once
    /// on entering the hold, only when notifications are already allowed (never a prompt), and withdrawn on return.
    case joinWaiting

    /// The request's identifier: the same for every pause, so a later one replaces an earlier one still shown; likewise
    /// for the reminder (one at a time, whichever camera).
    public var identifier: String {
        switch self {
        case .importPaused, .stagingPaused: "net.shamil.shutter-bridge.import-paused"
        case .cameraNearby: "net.shamil.shutter-bridge.camera-nearby"
        case .joinWaiting: "net.shamil.shutter-bridge.join-waiting"
        }
    }

    /// The category it is posted in.
    public var category: AppNotificationCategory {
        switch self {
        // No buttons: a tap opens the app, as the pause notification's does.
        case .importPaused, .stagingPaused, .joinWaiting: .importPaused
        case .cameraNearby: .cameraNearby
        }
    }

    /// The title; empty for none (iOS shows the app's name).
    public var title: String {
        switch self {
        case .importPaused, .stagingPaused, .joinWaiting: ""
        case .cameraNearby: NotificationWording.cameraNearbyTitle
        }
    }

    /// The text. Never a camera's serial number or network name (AGENTS.md).
    public var body: String {
        switch self {
        case .importPaused: NotificationWording.importPaused
        case .stagingPaused: NotificationWording.stagingPaused
        case .joinWaiting: NotificationWording.joinWaiting
        case let .cameraNearby(_, notImported): NotificationWording.cameraNearbyBody(notImported: notImported)
        }
    }

    /// What iOS keeps with the notification and hands back with the person's response: the reminder's camera, so *Import
    /// Now* and a tap open the app on it. The key is a hash (CameraKey), never the serial; it stays on the phone. Empty
    /// for a notification that names no camera.
    public var userInfo: [String: String] {
        switch self {
        case .importPaused, .stagingPaused, .joinWaiting: [:]
        case let .cameraNearby(camera, _): [Self.cameraUserInfoKey: camera.rawValue]
        }
    }

    /// The `userInfo` key that carries the camera of a `.cameraNearby` notification.
    public static let cameraUserInfoKey = "camera"
}

/// A notification category the app registers, with its actions: the pause notification's and the proximity reminder's
/// (Import Now, Not Now, Snooze 1 Hour; Shamil, 9 Nov).
public struct AppNotificationCategory: Sendable, Hashable {
    public var identifier: String
    /// The action buttons, in order; none for a notification that only opens the app.
    public var actions: [Action]
    /// Whether iOS tells the app when the person swipes the notification away (`customDismissAction`). The reminder
    /// counts that as *Not Now*.
    public var reportsDismissal: Bool

    public struct Action: Sendable, Hashable {
        public var identifier: String
        public var title: String
        /// Opens the app when tapped.
        public var opensApp: Bool

        /// The reminder's action identifiers.
        public static let importNowIdentifier = "net.shamil.shutter-bridge.camera-nearby.import-now"
        public static let notNowIdentifier = "net.shamil.shutter-bridge.camera-nearby.not-now"
        public static let snoozeIdentifier = "net.shamil.shutter-bridge.camera-nearby.snooze"

        public init(identifier: String, title: String, opensApp: Bool) {
            self.identifier = identifier
            self.title = title
            self.opensApp = opensApp
        }
    }

    public init(identifier: String, actions: [Action], reportsDismissal: Bool = false) {
        self.identifier = identifier
        self.actions = actions
        self.reportsDismissal = reportsDismissal
    }

    /// The pause notification: no buttons, a tap opens the app on the Import screen's job.
    public static let importPaused = AppNotificationCategory(identifier: "net.shamil.shutter-bridge.import-paused",
                                                             actions: [])

    /// The proximity reminder: *Import Now* opens the app on the camera, *Not Now* and *Snooze 1 Hour* act without opening
    /// it, and swiping it away is reported too (it counts as Not Now). Shamil, 9 Nov: the snooze is one hour.
    public static let cameraNearby = AppNotificationCategory(
        identifier: "net.shamil.shutter-bridge.camera-nearby",
        actions: [
            Action(identifier: Action.importNowIdentifier, title: NotificationWording.importNow, opensApp: true),
            Action(identifier: Action.notNowIdentifier, title: NotificationWording.notNow, opensApp: false),
            Action(identifier: Action.snoozeIdentifier, title: NotificationWording.snoozeOneHour, opensApp: false),
        ],
        reportsDismissal: true
    )

    /// Every category `LocalNotifier.registerCategories()` registers.
    public static let all: [AppNotificationCategory] = [.importPaused, .cameraNearby]
}

/// Local notifications: the permission and posting. A protocol so the rules are tested on Linux with a fake; on iPhone
/// it is `UNLocalNotifier`.
public protocol LocalNotifier: Sendable {
    func authorisation() async -> NotificationAuthorisation
    /// Shows iOS's prompt (only while `.notDetermined`; iOS shows it once). Returns whether posting is allowed after.
    func requestAuthorisation() async -> Bool
    /// Posts `notification` now. Fails quietly when not allowed; callers check `authorisation()` first.
    func post(_ notification: AppNotification) async
    /// Takes `notification` back from Notification Centre and the Lock Screen (and drops it if not yet delivered),
    /// once what it says is no longer true: the paused import is going again, or has ended.
    func withdraw(_ notification: AppNotification) async
    /// Registers `AppNotificationCategory.all`.
    func registerCategories() async
}

/// A notifier that never posts and was never allowed: the default where none is wired (tests, previews, a Mac).
public struct SilentNotifier: LocalNotifier {
    public init() {}
    public func authorisation() async -> NotificationAuthorisation { .denied }
    public func requestAuthorisation() async -> Bool { false }
    public func post(_ notification: AppNotification) async {}
    public func withdraw(_ notification: AppNotification) async {}
    public func registerCategories() async {}
}

/// The copy of the app's notifications and of the reason line before iOS's prompt. British English; never a camera's
/// serial number or network name.
public enum NotificationWording {
    /// The pause notification (backlog Iteration 3, section 9, *Expiry is normal*; section 13, *did suspend*).
    public static let importPaused = "Import paused. Open Shutter Bridge to continue."
    /// The pause notification for a *Stage* job (Shamil, 11 Nov).
    public static let stagingPaused = "Staging paused. Open Shutter Bridge to continue."
    /// While a Wi-Fi join waits for the app to come back (bench 19.1).
    public static let joinWaiting = "Open Shutter Bridge to join the camera's Wi-Fi."
    /// Shown at the first Import on either link, alongside iOS's prompt: iOS's notification prompt carries no reason
    /// of the app's own (decided by Shamil, 8 Nov, decision 4: "so we can tell you if the import pauses").
    public static let reason = "Shutter Bridge asks to send notifications so it can tell you if an import pauses."

    // The proximity reminder (Iteration 4, section 12). "Nearby", never "switched on" (decision 8): the camera is noticed
    // while off. Button titles are in title case, as iOS's own are (Shamil, 9 Nov: "Snooze 1 Hour").
    public static let cameraNearbyTitle = "Camera Nearby"
    public static let importNow = "Import Now"
    public static let notNow = "Not Now"
    public static let snoozeOneHour = "Snooze 1 Hour"

    /// The reminder's text. The count is the last known one (the card as last listed), so the text says so; with no
    /// count, or none to import, it says only that the camera is nearby.
    public static func cameraNearbyBody(notImported: Int?) -> String {
        guard let count = notImported, count > 0 else {
            return "Your camera is nearby. Open Shutter Bridge to import your photos."
        }
        let photos = count == 1 ? "1 photo" : "\(count) photos"
        return "Your camera is nearby. \(photos) not yet imported when you last connected."
    }
}
