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

    /// The request's identifier: the same for every pause, so a later one replaces an earlier one still shown.
    public var identifier: String {
        switch self {
        case .importPaused: "net.shamil.shutter-bridge.import-paused"
        }
    }

    /// The category it is posted in.
    public var category: AppNotificationCategory {
        switch self {
        case .importPaused: .importPaused
        }
    }

    /// The title; empty for none (iOS shows the app's name).
    public var title: String {
        switch self {
        case .importPaused: ""
        }
    }

    /// The text. Never a camera's serial number or network name (AGENTS.md).
    public var body: String {
        switch self {
        case .importPaused: NotificationWording.importPaused
        }
    }
}

/// A notification category the app registers, with its actions. W18 adds the proximity reminder's (Import now, Not
/// now, Snooze 1 hour; Shamil, 9 Nov) to `all`.
public struct AppNotificationCategory: Sendable, Hashable {
    public var identifier: String
    /// The action buttons, in order; none for a notification that only opens the app.
    public var actions: [Action]

    public struct Action: Sendable, Hashable {
        public var identifier: String
        public var title: String
        /// Opens the app when tapped.
        public var opensApp: Bool

        public init(identifier: String, title: String, opensApp: Bool) {
            self.identifier = identifier
            self.title = title
            self.opensApp = opensApp
        }
    }

    public init(identifier: String, actions: [Action]) {
        self.identifier = identifier
        self.actions = actions
    }

    /// The pause notification: no buttons, a tap opens the app on the Import screen's job.
    public static let importPaused = AppNotificationCategory(identifier: "net.shamil.shutter-bridge.import-paused",
                                                             actions: [])

    /// Every category `LocalNotifier.registerCategories()` registers.
    public static let all: [AppNotificationCategory] = [.importPaused]
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
    /// Shown at the first Import on either link, alongside iOS's prompt: iOS's notification prompt carries no reason
    /// of the app's own (decided by Shamil, 8 Nov, decision 4: "so we can tell you if the import pauses").
    public static let reason = "Shutter Bridge asks to send notifications so it can tell you if an import pauses."
}
