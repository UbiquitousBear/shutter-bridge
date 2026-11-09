import CameraTransport
import Catalogue
import Foundation

// The reminder's rules as a pure policy (Iteration 4, section 12; wireless plan, W18): given a confirmed arrival and what the
// app knows, post a reminder or say why not. Nothing here reads a clock, a store or the notification centre: the caller
// passes `now`, the holds and the snooze in, so the rules are tested on Linux with fixed dates.

/// Why a reminder wasn't posted. The first rule that applies, in the order of `ReminderPolicy.decide`.
public enum ReminderSuppression: Sendable, Equatable, CustomStringConvertible {
    /// The reminder is off.
    case disabled
    /// The person muted this camera.
    case muted
    /// The app is connected to a camera or importing (over USB too; decision 8).
    case connectedOrImporting
    /// The app is in front: the person is using it, and it shows the camera as nearby. Starts no hold.
    case appInFront
    /// Inside the quiet hours.
    case quietHours
    /// Snoozed, until the date.
    case snoozed(until: Date)
    /// The camera has a hold: it reminded, imported or connected less than 4 hours ago. The hold ends at the date.
    case held(until: Date)

    /// For the bench log. Carries no camera, and the dates only for the options (d) comparison's sake, in UTC to the second.
    public var description: String {
        switch self {
        case .disabled: "reminder is off"
        case .muted: "camera muted"
        case .connectedOrImporting: "connected or importing"
        case .appInFront: "app in front"
        case .quietHours: "quiet hours"
        case let .snoozed(until): "snoozed until \(ReminderLogTime.string(until))"
        case let .held(until): "held until \(ReminderLogTime.string(until))"
        }
    }
}

public enum ReminderDecision: Sendable, Equatable {
    /// Post the reminder for this camera, and start its hold.
    case post(CameraKey)
    case suppress(ReminderSuppression)

    public typealias Reason = ReminderSuppression
}

/// A date for the log: ISO 8601 in UTC, to the second.
enum ReminderLogTime {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// The reminder rules (backlog section 12; decided by Shamil on 8 and 9 Nov), pure.
///
/// - **One reminder per arrival, with a long hold per camera.** A reminder, an import or a connection over either link
///   starts the camera's 4-hour hold (`hold`; Shamil, 8 Nov, option (b)), so a camera at the edge of range that comes and
///   goes doesn't remind again and again (the spike's 60 s debounce let 38 through in a night). The caller starts it;
///   `ReminderHoldStore` keeps it across a relaunch.
/// - **Held while connected or importing,** over USB too.
/// - **None while the app is in front:** the person is in the app, which shows the camera as nearby. No hold starts.
/// - **Quiet hours and snooze apply on top** of the hold: a camera reported at 23:00 isn't reminded of, and neither is one
///   while a snooze runs. Neither starts a hold, so the first report after they end can still remind.
/// - **Mute** is per camera; **off** silences everything.
public struct ReminderPolicy: Sendable {
    /// The hold per camera: 4 hours (decided, Shamil, 8 Nov; the bench week compares it with a quiet gap, option (d)).
    public static let hold: Duration = .seconds(4 * 3600)
    /// What *Snooze 1 Hour* sets (decided, Shamil, 9 Nov: one hour, not "Snooze today").
    public static let snooze: Duration = .seconds(3600)
    /// How long after its last report a camera still counts as nearby for the Cameras screen's badge. **Unverified:** iOS
    /// reports a camera only when the scan is armed afresh (backlog section 11), so this is a guess to adjust at the bench.
    public static let nearbyWindow: Duration = .seconds(120)

    public var settings: ReminderSettings
    /// The calendar whose time zone quiet hours are read in: the person's (`Calendar.current` in the app).
    public var calendar: Calendar
    public var hold: Duration

    public init(settings: ReminderSettings = .default, calendar: Calendar = .current, hold: Duration = ReminderPolicy.hold) {
        self.settings = settings
        self.calendar = calendar
        self.hold = hold
    }

    /// - Parameters:
    ///   - arrival: the camera reported nearby, from `ProximityModel.arrivals`.
    ///   - now: the wall clock.
    ///   - holds: when each camera's hold started (`ReminderHoldStore.holds(now:)`).
    ///   - connectedOrImporting: whether the app is connected to a camera or importing, over either link.
    ///   - snoozedUntil: the snooze's end, or nil.
    ///   - appInFront: whether the app is in front.
    public func decide(_ arrival: ProximityArrival, now: Date, holds: [CameraKey: Date], connectedOrImporting: Bool,
                       snoozedUntil: Date?, appInFront: Bool = false) -> ReminderDecision {
        decide(arrival.report, camera: arrival.camera, now: now, holds: holds, connectedOrImporting: connectedOrImporting,
               snoozedUntil: snoozedUntil, appInFront: appInFront)
    }

    /// The same, from the report and the camera it was confirmed as (the report's own time doesn't enter: the rules run
    /// on `now`, as a report is handled as it arrives).
    public func decide(_ report: ProximityReport, camera: CameraKey, now: Date, holds: [CameraKey: Date],
                       connectedOrImporting: Bool, snoozedUntil: Date?, appInFront: Bool = false) -> ReminderDecision {
        guard settings.enabled else { return .suppress(.disabled) }
        if settings.mutedCameras.contains(camera) { return .suppress(.muted) }
        if connectedOrImporting { return .suppress(.connectedOrImporting) }
        if appInFront { return .suppress(.appInFront) }
        if settings.quietHours.contains(now, calendar: calendar) { return .suppress(.quietHours) }
        if let snoozedUntil, now < snoozedUntil { return .suppress(.snoozed(until: snoozedUntil)) }
        if let started = holds[camera], let end = Self.holdEnd(started: started, now: now, hold: hold) {
            return .suppress(.held(until: end))
        }
        return .post(camera)
    }

    /// When a hold that started at `started` ends, or nil when it already has. A start in the future (the clock was
    /// set back) is no hold, so a wrong clock can't silence a camera for longer than 4 hours; the next reminder, import or
    /// connection starts a fresh one.
    static func holdEnd(started: Date, now: Date, hold: Duration) -> Date? {
        guard started <= now else { return nil }
        let end = started.addingTimeInterval(hold.timeInterval)
        return now < end ? end : nil
    }

    /// Whether `lastReport` is recent enough for the camera to be shown as nearby.
    public static func isNearby(lastReport: Date?, now: Date, window: Duration = ReminderPolicy.nearbyWindow) -> Bool {
        guard let lastReport, lastReport <= now else { return false }
        return now.timeIntervalSince(lastReport) < window.timeInterval
    }
}

extension Duration {
    /// Seconds, as Foundation's `TimeInterval` (to the attosecond's rounding).
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
