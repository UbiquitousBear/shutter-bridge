import Foundation
import Observation

/// Whether the app has asked for notification permission, kept across launches so the reason line and iOS's prompt
/// come once even when iOS couldn't show its prompt (the status then stays not determined).
public protocol NotificationAskRecord: Sendable {
    var hasAsked: Bool { get }
    func recordAsked()
}

/// The record in memory: for tests and previews.
public final class InMemoryNotificationAskRecord: NotificationAskRecord, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: Bool

    public init(hasAsked: Bool = false) { asked = hasAsked }

    public var hasAsked: Bool { lock.withLock { asked } }
    public func recordAsked() { lock.withLock { asked = true } }
}

/// The record in `UserDefaults`, one Boolean. Foundation only. (`UserDefaults` is thread-safe, hence
/// `@unchecked Sendable`.)
public final class UserDefaultsNotificationAskRecord: NotificationAskRecord, @unchecked Sendable {
    public static let key = "notificationPermissionAsked"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var hasAsked: Bool { defaults.bool(forKey: Self.key) }
    public func recordAsked() { defaults.set(true, forKey: Self.key) }
}

/// The notification permission, asked once, at the first *Import* on either link (decided by Shamil, 8 and 9 Nov;
/// backlog Iteration 3, section 9): the pause notification needs it, and in the spike a notification failed while
/// permission was undetermined (UNErrorDomain 2003). iOS's prompt carries no reason of the app's own, so the reason
/// line (`NotificationWording.reason`) goes up as the Import screen's and the strips' status line, and iOS's prompt is
/// asked for in the same turn, so the line shows alongside the prompt (as the Photos ask does) rather than before it.
/// Switching the proximity reminder on asks too, if still undetermined (section 12, W18).
@MainActor
@Observable
public final class NotificationPermissionModel {
    /// iOS's answer as last read; nil before the first read.
    public private(set) var authorisation: NotificationAuthorisation?
    /// True from the moment the reason line goes up until iOS's prompt is answered.
    public private(set) var isExplaining = false
    /// Whether the app has asked (across launches).
    public private(set) var hasAsked: Bool

    @ObservationIgnored private let notifier: any LocalNotifier
    @ObservationIgnored private let record: any NotificationAskRecord

    public init(notifier: any LocalNotifier, record: any NotificationAskRecord = InMemoryNotificationAskRecord()) {
        self.notifier = notifier
        self.record = record
        hasAsked = record.hasAsked
    }

    /// Whether the next Import explains and asks: nobody has asked, and iOS doesn't say otherwise.
    public var shouldExplainBeforeImport: Bool {
        !hasAsked && (authorisation ?? .notDetermined) == .notDetermined
    }

    /// The reason line, while it is up.
    public var reasonLine: String? { isExplaining ? NotificationWording.reason : nil }

    /// Reads iOS's answer again (the person may have changed it in Settings).
    public func refresh() async {
        authorisation = await notifier.authorisation()
    }

    /// At an Import: when nobody has asked and iOS says not determined, puts the reason line up, then shows iOS's
    /// prompt, and records the ask before the prompt so a second Import never asks again, whatever the answer.
    /// Returns whether it asked.
    @discardableResult
    public func askAtImport() async -> Bool {
        guard !hasAsked, !isExplaining else { return false }
        let status = await notifier.authorisation()
        authorisation = status
        guard status == .notDetermined, !hasAsked, !isExplaining else { return false }
        isExplaining = true
        hasAsked = true
        record.recordAsked()
        _ = await notifier.requestAuthorisation()
        authorisation = await notifier.authorisation()
        isExplaining = false
        return true
    }

    /// Whether a notification posted now would be delivered, read from iOS.
    public func allowsPosting() async -> Bool {
        let status = await notifier.authorisation()
        authorisation = status
        return status.allowsPosting
    }
}
