import Catalogue
import Foundation

// The reminder's settings (Iteration 4, section 12; wireless plan, W18): off by default, quiet hours 22:00 to 08:00, and a
// per-camera mute. Plain Swift and Foundation, so they are tested on Linux. `ReminderSettingsStore` keeps them in a
// `KeyValueStore`; `ReminderSettingsView` is the one SwiftUI file.

/// A daily span of local time in which no reminder is posted. It may run over midnight (22:00 to 08:00). The start is
/// included and the end isn't: at 22:00 sharp it is quiet, at 08:00 sharp it isn't. A start equal to the end is no quiet
/// hours at all.
public struct QuietHours: Sendable, Codable, Equatable {
    public static let minutesPerDay = 24 * 60
    /// Shamil, 9 Nov: 22:00 to 08:00.
    public static let standard = QuietHours(startMinute: 22 * 60, endMinute: 8 * 60)

    /// Minutes after local midnight, 0 up to 1439.
    public var startMinute: Int { didSet { startMinute = Self.clamped(startMinute) } }
    public var endMinute: Int { didSet { endMinute = Self.clamped(endMinute) } }

    /// Values outside a day are clamped into it (a stored value can't be trusted to be in range).
    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = Self.clamped(startMinute)
        self.endMinute = Self.clamped(endMinute)
    }

    private enum CodingKeys: String, CodingKey { case startMinute, endMinute }

    /// Lenient: a field that is missing reads as its standard value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(startMinute: try container.decodeIfPresent(Int.self, forKey: .startMinute) ?? Self.standard.startMinute,
                  endMinute: try container.decodeIfPresent(Int.self, forKey: .endMinute) ?? Self.standard.endMinute)
    }

    /// Whether `minuteOfDay` (0 up to 1439) falls in the span.
    public func contains(minuteOfDay minute: Int) -> Bool {
        if startMinute == endMinute { return false }
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }

    /// Whether `date`, read as local time in `calendar`, falls in the span.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        contains(minuteOfDay: Self.minuteOfDay(of: date, calendar: calendar))
    }

    /// Minutes after local midnight of `date` in `calendar`.
    public static func minuteOfDay(of date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return clamped((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    /// A date on `reference`'s day, in `calendar`, at `minute` after midnight: what a time-only `DatePicker` edits.
    public static func date(forMinute minute: Int, on reference: Date, calendar: Calendar) -> Date {
        let clampedMinute = clamped(minute)
        let day = calendar.startOfDay(for: reference)
        return calendar.date(bySettingHour: clampedMinute / 60, minute: clampedMinute % 60, second: 0, of: day) ?? day
    }

    /// "22:00" for 1320, whatever the person's clock style (a stable form for the log and the tests).
    public static func label(forMinute minute: Int) -> String {
        let m = clamped(minute)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    private static func clamped(_ minute: Int) -> Int { min(max(minute, 0), minutesPerDay - 1) }
}

/// What the person chose for the proximity reminder.
public struct ReminderSettings: Sendable, Codable, Equatable {
    /// Off until the person switches it on (Shamil, 9 Nov). Switching it on starts the Bluetooth scan.
    public var enabled: Bool
    public var quietHours: QuietHours
    /// Cameras the person muted: no reminder for them (an arrival still counts for the *nearby* badge).
    public var mutedCameras: Set<CameraKey>

    public init(enabled: Bool = false, quietHours: QuietHours = .standard, mutedCameras: Set<CameraKey> = []) {
        self.enabled = enabled
        self.quietHours = quietHours
        self.mutedCameras = mutedCameras
    }

    public static let `default` = ReminderSettings()

    private enum CodingKeys: String, CodingKey { case enabled, quietHours, mutedCameras }

    /// Lenient: a missing field reads as its default, so a value written by an earlier or later version still loads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                  quietHours: try container.decodeIfPresent(QuietHours.self, forKey: .quietHours) ?? .standard,
                  mutedCameras: try container.decodeIfPresent(Set<CameraKey>.self, forKey: .mutedCameras) ?? [])
    }
}

/// Where the settings are kept: one JSON value in a `KeyValueStore` (`UserDefaults` in the app). A value that can't be read
/// is the default, so the reminder stays off rather than failing.
public struct ReminderSettingsStore: Sendable {
    public static let key = "reminderSettings"
    private let store: any KeyValueStore

    public init(store: any KeyValueStore) { self.store = store }

    public func load() -> ReminderSettings {
        guard let data = store.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(ReminderSettings.self, from: data) else { return .default }
        return settings
    }

    public func save(_ settings: ReminderSettings) {
        store.set(try? JSONEncoder().encode(settings), forKey: Self.key)
    }
}
