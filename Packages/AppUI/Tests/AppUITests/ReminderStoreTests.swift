// What the reminder remembers across a relaunch (Iteration 4, section 12; W18): the holds, the snooze and the settings, in a
// key-value store that is `UserDefaults` in the app and a fake here.

import Catalogue
import Foundation
import Testing
@testable import AppUI

@Suite("Reminder holds, snooze and settings", .timeLimit(.minutes(1)))
struct ReminderStoreTests {
    @Test func aHoldSurvivesARelaunch() {
        let backing = InMemoryKeyValueStore()
        let start = reminderDate(9)
        ReminderHoldStore(store: backing).startHold(for: reminderCamera, at: start)
        // A second store over the same values is the next launch.
        let relaunched = ReminderHoldStore(store: backing)
        #expect(relaunched.holds(now: reminderDate(10)) == [reminderCamera: start])
        #expect(relaunched.holds(now: reminderDate(12, 59)) == [reminderCamera: start])
        #expect(relaunched.holds(now: reminderDate(13)).isEmpty)
    }

    @Test func holdsAreKeptPerCameraAndStartingAgainRestartsTheHold() {
        let store = ReminderHoldStore(store: InMemoryKeyValueStore())
        store.startHold(for: reminderCamera, at: reminderDate(9))
        store.startHold(for: otherReminderCamera, at: reminderDate(10))
        #expect(store.holds(now: reminderDate(11)) == [reminderCamera: reminderDate(9), otherReminderCamera: reminderDate(10)])
        store.startHold(for: reminderCamera, at: reminderDate(11))
        #expect(store.holds(now: reminderDate(12))[reminderCamera] == reminderDate(11))
        store.endHold(for: reminderCamera, now: reminderDate(12))
        #expect(store.holds(now: reminderDate(12)) == [otherReminderCamera: reminderDate(10)])
    }

    @Test func expiredHoldsAreDroppedWhenSomethingIsWritten() throws {
        let backing = InMemoryKeyValueStore()
        let store = ReminderHoldStore(store: backing)
        store.startHold(for: reminderCamera, at: reminderDate(1))
        store.startHold(for: otherReminderCamera, at: reminderDate(12))
        let stored = try #require(backing.data(forKey: ReminderHoldStore.key))
        let text = String(decoding: stored, as: UTF8.self)
        #expect(!text.contains(reminderCamera.rawValue))
        #expect(text.contains(otherReminderCamera.rawValue))
    }

    @Test func aHoldStartedInTheFutureIsNotReturned() {
        let store = ReminderHoldStore(store: InMemoryKeyValueStore())
        store.startHold(for: reminderCamera, at: reminderDate(9, day: 11))
        // The clock is back on the 10th.
        #expect(store.holds(now: reminderDate(10)).isEmpty)
    }

    @Test func theHoldLengthIsFourHoursUnlessTold() {
        let backing = InMemoryKeyValueStore()
        ReminderHoldStore(store: backing).startHold(for: reminderCamera, at: reminderDate(9))
        let short = ReminderHoldStore(store: backing, hold: .seconds(60))
        #expect(short.holds(now: reminderDate(9, 0, second: 59)).count == 1)
        #expect(short.holds(now: reminderDate(9, 1)).isEmpty)
    }

    @Test func aSnoozeSurvivesARelaunchAndEnds() {
        let backing = InMemoryKeyValueStore()
        let now = reminderDate(12)
        let until = reminderDate(13)
        ReminderHoldStore(store: backing).snooze(until: until, now: now)
        let relaunched = ReminderHoldStore(store: backing)
        #expect(relaunched.snoozedUntil(now: reminderDate(12, 30)) == until)
        #expect(relaunched.snoozedUntil(now: until) == nil)
        relaunched.snooze(until: reminderDate(14), now: reminderDate(13, 30))
        relaunched.clearSnooze(now: reminderDate(13, 31))
        #expect(relaunched.snoozedUntil(now: reminderDate(13, 31)) == nil)
    }

    @Test func aSnoozeLongerThanAnHourFromNowIsIgnoredSoAWrongClockCannotSilenceTheReminder() {
        let store = ReminderHoldStore(store: InMemoryKeyValueStore())
        store.snooze(until: reminderDate(12, day: 20), now: reminderDate(12))
        #expect(store.snoozedUntil(now: reminderDate(12, 1)) == nil)
    }

    @Test func holdsAndSnoozeDoNotDisturbEachOther() {
        let store = ReminderHoldStore(store: InMemoryKeyValueStore())
        store.startHold(for: reminderCamera, at: reminderDate(12))
        store.snooze(until: reminderDate(12, 30), now: reminderDate(12))
        store.startHold(for: otherReminderCamera, at: reminderDate(12, 10))
        #expect(store.snoozedUntil(now: reminderDate(12, 15)) == reminderDate(12, 30))
        store.clearSnooze(now: reminderDate(12, 15))
        #expect(store.holds(now: reminderDate(12, 15)).count == 2)
    }

    @Test func unreadableStoredDataIsNoHoldsAndNoSnooze() {
        let backing = InMemoryKeyValueStore()
        backing.set(Data("not json".utf8), forKey: ReminderHoldStore.key)
        let store = ReminderHoldStore(store: backing)
        #expect(store.holds(now: reminderDate(12)).isEmpty)
        #expect(store.snoozedUntil(now: reminderDate(12)) == nil)
        store.startHold(for: reminderCamera, at: reminderDate(12))
        #expect(store.holds(now: reminderDate(12)).count == 1)
    }

    @Test func userDefaultsKeepsTheValuesAcrossStores() throws {
        let suite = "ReminderStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ReminderHoldStore(store: UserDefaultsKeyValueStore(defaults: defaults)).startHold(for: reminderCamera, at: reminderDate(9))
        let again = try #require(UserDefaults(suiteName: suite))
        let relaunched = ReminderHoldStore(store: UserDefaultsKeyValueStore(defaults: again))
        #expect(relaunched.holds(now: reminderDate(10)) == [reminderCamera: reminderDate(9)])
        let kv = UserDefaultsKeyValueStore(defaults: again)
        kv.set(nil, forKey: ReminderHoldStore.key)
        #expect(kv.data(forKey: ReminderHoldStore.key) == nil)
    }

    // MARK: Settings

    @Test func theSettingsStartOffWithTheStandardQuietHours() {
        let store = ReminderSettingsStore(store: InMemoryKeyValueStore())
        #expect(store.load() == ReminderSettings.default)
        #expect(!store.load().enabled)
        #expect(store.load().quietHours.startMinute == 22 * 60)
        #expect(store.load().quietHours.endMinute == 8 * 60)
    }

    @Test func theSettingsRoundTrip() {
        let backing = InMemoryKeyValueStore()
        let settings = ReminderSettings(enabled: true, quietHours: QuietHours(startMinute: 23 * 60, endMinute: 7 * 60 + 30),
                                        mutedCameras: [reminderCamera])
        ReminderSettingsStore(store: backing).save(settings)
        #expect(ReminderSettingsStore(store: backing).load() == settings)
    }

    @Test func unreadableOrPartialSettingsLoadAsDefaults() {
        let backing = InMemoryKeyValueStore()
        backing.set(Data("{".utf8), forKey: ReminderSettingsStore.key)
        #expect(ReminderSettingsStore(store: backing).load() == .default)
        backing.set(Data(#"{"enabled":true}"#.utf8), forKey: ReminderSettingsStore.key)
        let partial = ReminderSettingsStore(store: backing).load()
        #expect(partial.enabled)
        #expect(partial.quietHours == .standard)
        #expect(partial.mutedCameras.isEmpty)
    }
}
