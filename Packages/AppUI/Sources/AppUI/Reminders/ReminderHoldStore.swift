import Catalogue
import Foundation
import Synchronization

// What the reminder remembers across a relaunch (Iteration 4, section 12; wireless plan, W18): each camera's hold and the
// snooze. State restoration relaunches the app, and the spike's in-memory debounce didn't survive a kill and reopen, so
// both are stored. `KeyValueStore` is the seam: `UserDefaults` in the app, a fake on Linux.

/// A small key-value store holding `Data`. `UserDefaults` in the app (`UserDefaultsKeyValueStore`).
public protocol KeyValueStore: Sendable {
    func data(forKey key: String) -> Data?
    /// Stores `data`; nil removes the key.
    func set(_ data: Data?, forKey key: String)
}

/// The store in memory: for tests and previews. Two instances of a model over one of these behave like two launches.
public final class InMemoryKeyValueStore: KeyValueStore, Sendable {
    private let values = Mutex<[String: Data]>([:])

    public init() {}

    public func data(forKey key: String) -> Data? { values.withLock { $0[key] } }

    public func set(_ data: Data?, forKey key: String) {
        values.withLock { $0[key] = data }
    }
}

/// The store in `UserDefaults` (the required-reason API CA92.1 in App/ShutterBridge/PrivacyInfo.xcprivacy). Foundation
/// only, so it is tested on Linux against a suite of its own. (`UserDefaults` is thread-safe, hence `@unchecked Sendable`.)
public final class UserDefaultsKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }

    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Each camera's hold start and the snooze, kept in a `KeyValueStore` as one JSON value (so a write is all or nothing).
/// A value that can't be read is empty: no holds, no snooze. Reads and writes are serialised, so the model on the main
/// actor and a background caller can't lose each other's update.
///
/// What it returns is only what still matters at `now`: a hold older than its length, or started in the future (the
/// clock was set back), isn't returned, and a snooze that ended, or runs longer than a snooze can (same reason), isn't
/// either. Expired entries are dropped the next time something is written.
public final class ReminderHoldStore: Sendable {
    public static let key = "reminderHoldsAndSnooze"

    private struct Stored: Codable {
        /// The camera key's raw value to the hold's start, in seconds since 1970.
        var holds: [String: Double] = [:]
        var snoozedUntil: Double?
    }

    private let store: any KeyValueStore
    /// How long a hold lasts. `ReminderModel` gives the same length to `ReminderPolicy`, so the two agree.
    public let hold: Duration
    /// The longest snooze kept, and the one *Snooze 1 Hour* sets.
    public let snoozeLength: Duration
    private let lock = Mutex(())

    public init(store: any KeyValueStore, hold: Duration = ReminderPolicy.hold,
                snoozeLength: Duration = ReminderPolicy.snooze) {
        self.store = store
        self.hold = hold
        self.snoozeLength = snoozeLength
    }

    /// The holds still running at `now`: each camera's start.
    public func holds(now: Date) -> [CameraKey: Date] {
        lock.withLock { _ in live(read(), now: now).holds }
            .reduce(into: [:]) { $0[CameraKey(rawValue: $1.key)] = Date(timeIntervalSince1970: $1.value) }
    }

    /// Starts `camera`'s hold at `date` (a reminder, an import or a connection), replacing any earlier one.
    public func startHold(for camera: CameraKey, at date: Date) {
        lock.withLock { _ in
            var stored = live(read(), now: date)
            stored.holds[camera.rawValue] = date.timeIntervalSince1970
            write(stored)
        }
    }

    /// Ends `camera`'s hold at once.
    public func endHold(for camera: CameraKey, now: Date) {
        lock.withLock { _ in
            var stored = live(read(), now: now)
            stored.holds[camera.rawValue] = nil
            write(stored)
        }
    }

    /// When the snooze ends, or nil when there is none running at `now`.
    public func snoozedUntil(now: Date) -> Date? {
        lock.withLock { _ in live(read(), now: now).snoozedUntil }.map { Date(timeIntervalSince1970: $0) }
    }

    /// Snoozes every reminder until `date`.
    public func snooze(until date: Date, now: Date) {
        lock.withLock { _ in
            var stored = live(read(), now: now)
            stored.snoozedUntil = date.timeIntervalSince1970
            write(stored)
        }
    }

    public func clearSnooze(now: Date) {
        lock.withLock { _ in
            var stored = live(read(), now: now)
            stored.snoozedUntil = nil
            write(stored)
        }
    }

    // MARK: Private

    private func read() -> Stored {
        guard let data = store.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return Stored() }
        return stored
    }

    private func write(_ stored: Stored) {
        store.set(try? JSONEncoder().encode(stored), forKey: Self.key)
    }

    /// `stored` without what no longer matters at `now`.
    private func live(_ stored: Stored, now: Date) -> Stored {
        var result = Stored()
        for (key, start) in stored.holds
        where ReminderPolicy.holdEnd(started: Date(timeIntervalSince1970: start), now: now, hold: hold) != nil {
            result.holds[key] = start
        }
        if let until = stored.snoozedUntil {
            let end = Date(timeIntervalSince1970: until)
            if end > now, end.timeIntervalSince(now) <= snoozeLength.timeInterval { result.snoozedUntil = until }
        }
        return result
    }
}
