// The reminder's rules (Iteration 4, section 12; W18) as a pure policy, on fixed dates: the 4-hour hold per camera, quiet hours
// over midnight, snooze, mute, and holding back while connected or importing.

import CameraTransport
import Catalogue
import Foundation
import Testing
@testable import AppUI

/// A calendar in a fixed time zone, so "22:00" means the same on every machine.
func reminderCalendar(offsetHours: Int = 0) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: offsetHours * 3600)!
    return calendar
}

/// A date on 10 Nov 2026 (the bench week) at `hour:minute` in `calendar`'s zone.
func reminderDate(_ hour: Int, _ minute: Int = 0, second: Int = 0, day: Int = 10, calendar: Calendar = reminderCalendar()) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
}

let reminderCamera = CameraKey(rawValue: "usb-device:camera-a")
let otherReminderCamera = CameraKey(rawValue: "usb-device:camera-b")

func reminderArrival(_ camera: CameraKey = reminderCamera, at: Date) -> ProximityArrival {
    let report = ProximityReport(peripheral: PeripheralID(UUID(uuidString: "0E1D2C3B-4A59-6877-8695-A4B3C2D1E0F0")!),
                                 at: at, rssi: -62, manufacturerData: nil, name: nil)
    return ProximityArrival(camera: camera, report: report, match: .storedIdentifier)
}

private func policy(enabled: Bool = true, quiet: QuietHours = .standard, muted: Set<CameraKey> = [],
                    calendar: Calendar = reminderCalendar()) -> ReminderPolicy {
    ReminderPolicy(settings: ReminderSettings(enabled: enabled, quietHours: quiet, mutedCameras: muted), calendar: calendar)
}

private func decide(_ policy: ReminderPolicy, at now: Date, camera: CameraKey = reminderCamera,
                    holds: [CameraKey: Date] = [:], busy: Bool = false, snoozedUntil: Date? = nil) -> ReminderDecision {
    policy.decide(reminderArrival(camera, at: now), now: now, holds: holds, connectedOrImporting: busy,
                  snoozedUntil: snoozedUntil)
}

@Suite("Reminder policy", .timeLimit(.minutes(1)))
struct ReminderPolicyTests {
    @Test func theDecidedConstants() {
        #expect(ReminderPolicy.hold == .seconds(4 * 3600))
        #expect(ReminderPolicy.snooze == .seconds(3600))
        #expect(ReminderSettings.default.enabled == false)
        #expect(QuietHours.standard == QuietHours(startMinute: 22 * 60, endMinute: 8 * 60))
        #expect(ReminderSettings.default.quietHours == .standard)
        #expect(ReminderSettings.default.mutedCameras.isEmpty)
    }

    @Test func aKnownCameraInTheDaytimePostsAReminder() {
        #expect(decide(policy(), at: reminderDate(12)) == .post(reminderCamera))
    }

    @Test func offByDefaultMeansNothingIsPosted() {
        let off = ReminderPolicy(settings: .default, calendar: reminderCalendar())
        #expect(decide(off, at: reminderDate(12)) == .suppress(.disabled))
    }

    @Test func aMutedCameraIsNotRemindedButAnotherIs() {
        let p = policy(muted: [reminderCamera])
        #expect(decide(p, at: reminderDate(12)) == .suppress(.muted))
        #expect(decide(p, at: reminderDate(12), camera: otherReminderCamera) == .post(otherReminderCamera))
    }

    // MARK: The hold

    @Test func aHoldSilencesTheCameraForFourHoursExactly() {
        let started = reminderDate(9)
        let holds = [reminderCamera: started]
        let end = started.addingTimeInterval(4 * 3600)
        let p = policy()
        #expect(decide(p, at: started, holds: holds) == .suppress(.held(until: end)))
        #expect(decide(p, at: reminderDate(10), holds: holds) == .suppress(.held(until: end)))
        #expect(decide(p, at: reminderDate(12, 59, second: 59), holds: holds) == .suppress(.held(until: end)))
        // At the fourth hour the hold is over.
        #expect(decide(p, at: reminderDate(13), holds: holds) == .post(reminderCamera))
        #expect(decide(p, at: reminderDate(15), holds: holds) == .post(reminderCamera))
    }

    @Test func aHoldIsPerCamera() {
        let holds = [reminderCamera: reminderDate(9)]
        #expect(decide(policy(), at: reminderDate(10), camera: otherReminderCamera, holds: holds)
            == .post(otherReminderCamera))
    }

    @Test func aHoldStartedInTheFutureIsIgnoredSoAWrongClockCannotSilenceACamera() {
        // The clock was put back a day after the hold started.
        let holds = [reminderCamera: reminderDate(9, day: 11)]
        #expect(decide(policy(), at: reminderDate(10), holds: holds) == .post(reminderCamera))
    }

    @Test func theHoldLengthComesFromThePolicy() {
        let short = ReminderPolicy(settings: ReminderSettings(enabled: true), calendar: reminderCalendar(), hold: .seconds(600))
        let holds = [reminderCamera: reminderDate(9)]
        #expect(decide(short, at: reminderDate(9, 9), holds: holds) == .suppress(.held(until: reminderDate(9, 10))))
        #expect(decide(short, at: reminderDate(9, 10), holds: holds) == .post(reminderCamera))
    }

    // MARK: Connected or importing

    @Test func nothingIsPostedWhileConnectedOrImporting() {
        #expect(decide(policy(), at: reminderDate(12), busy: true) == .suppress(.connectedOrImporting))
        #expect(decide(policy(), at: reminderDate(12), camera: otherReminderCamera, busy: true)
            == .suppress(.connectedOrImporting))
        #expect(decide(policy(), at: reminderDate(12), busy: false) == .post(reminderCamera))
    }

    @Test func nothingIsPostedWhileTheAppIsInFrontAndConnectedComesFirst() {
        let p = policy()
        let at = reminderDate(12)
        #expect(p.decide(reminderArrival(at: at), now: at, holds: [:], connectedOrImporting: false, snoozedUntil: nil,
                         appInFront: true) == .suppress(.appInFront))
        #expect(p.decide(reminderArrival(at: at), now: at, holds: [:], connectedOrImporting: true, snoozedUntil: nil,
                         appInFront: true) == .suppress(.connectedOrImporting))
        // In front comes before quiet hours, snooze and the hold, none of which it starts.
        #expect(p.decide(reminderArrival(at: at), now: at, holds: [reminderCamera: at], connectedOrImporting: false,
                         snoozedUntil: at.addingTimeInterval(60), appInFront: true) == .suppress(.appInFront))
    }

    // MARK: Quiet hours

    @Test func quietHoursRunOverMidnightWithTheStartIncludedAndTheEndNot() {
        let p = policy()
        #expect(decide(p, at: reminderDate(21, 59)) == .post(reminderCamera))
        #expect(decide(p, at: reminderDate(22, 0)) == .suppress(.quietHours))
        #expect(decide(p, at: reminderDate(23, 30)) == .suppress(.quietHours))
        #expect(decide(p, at: reminderDate(0, 0)) == .suppress(.quietHours))
        #expect(decide(p, at: reminderDate(3, 15)) == .suppress(.quietHours))
        #expect(decide(p, at: reminderDate(7, 59)) == .suppress(.quietHours))
        #expect(decide(p, at: reminderDate(8, 0)) == .post(reminderCamera))
    }

    @Test func quietHoursAreReadInThePersonsTimeZone() {
        // 22:30 in UTC+9 is 13:30 UTC: quiet for the person, though it is afternoon in UTC.
        let tokyo = reminderCalendar(offsetHours: 9)
        let p = policy(calendar: tokyo)
        #expect(decide(p, at: reminderDate(22, 30, calendar: tokyo)) == .suppress(.quietHours))
        #expect(decide(p, at: reminderDate(12, 0, calendar: tokyo)) == .post(reminderCamera))
        // And the same instant, read in UTC, is the afternoon.
        #expect(decide(policy(), at: reminderDate(22, 30, calendar: tokyo)) == .post(reminderCamera))
    }

    @Test func aSpanInsideOneDayAndAnEmptySpan() {
        let lunch = QuietHours(startMinute: 12 * 60, endMinute: 13 * 60 + 30)
        #expect(lunch.contains(minuteOfDay: 12 * 60))
        #expect(lunch.contains(minuteOfDay: 13 * 60 + 29))
        #expect(!lunch.contains(minuteOfDay: 13 * 60 + 30))
        #expect(!lunch.contains(minuteOfDay: 11 * 60 + 59))
        let none = QuietHours(startMinute: 8 * 60, endMinute: 8 * 60)
        #expect(!none.contains(minuteOfDay: 8 * 60))
        #expect(!none.contains(minuteOfDay: 0))
        #expect(decide(policy(quiet: none), at: reminderDate(23)) == .post(reminderCamera))
    }

    @Test func quietHoursComeBeforeTheHoldInTheReason() {
        let held = [reminderCamera: reminderDate(21)]
        #expect(decide(policy(), at: reminderDate(23), holds: held) == .suppress(.quietHours))
        // The morning after, a hold from 21:00 the evening before is over; one from 06:00 is not.
        let yesterday = [reminderCamera: reminderDate(21, day: 9)]
        #expect(decide(policy(), at: reminderDate(8, 30), holds: yesterday) == .post(reminderCamera))
        let dawn = [reminderCamera: reminderDate(6)]
        #expect(decide(policy(), at: reminderDate(8, 30), holds: dawn) == .suppress(.held(until: reminderDate(10))))
    }

    // MARK: Snooze

    @Test func aSnoozeSilencesEveryReminderUntilItEnds() {
        let until = reminderDate(13)
        let p = policy()
        #expect(decide(p, at: reminderDate(12), snoozedUntil: until) == .suppress(.snoozed(until: until)))
        #expect(decide(p, at: reminderDate(12, 59, second: 59), camera: otherReminderCamera, snoozedUntil: until)
            == .suppress(.snoozed(until: until)))
        #expect(decide(p, at: reminderDate(13), snoozedUntil: until) == .post(reminderCamera))
    }

    @Test func quietHoursAndSnoozeStillApplyOnTopOfAnExpiredHold() {
        let holds = [reminderCamera: reminderDate(1, day: 9)]
        #expect(decide(policy(), at: reminderDate(23), holds: holds) == .suppress(.quietHours))
        #expect(decide(policy(), at: reminderDate(12), holds: holds, snoozedUntil: reminderDate(12, 30))
            == .suppress(.snoozed(until: reminderDate(12, 30))))
    }

    // MARK: Nearby badge

    @Test func aCameraIsNearbyForTheWindowAfterItsLastReport() {
        let last = reminderDate(12)
        #expect(ReminderPolicy.isNearby(lastReport: last, now: last))
        #expect(ReminderPolicy.isNearby(lastReport: last, now: last.addingTimeInterval(119)))
        #expect(!ReminderPolicy.isNearby(lastReport: last, now: last.addingTimeInterval(120)))
        #expect(!ReminderPolicy.isNearby(lastReport: nil, now: last))
        #expect(!ReminderPolicy.isNearby(lastReport: last.addingTimeInterval(60), now: last))
    }

    // MARK: Quiet hours values

    @Test func quietHoursClampTheirValuesAndDecodeLeniently() throws {
        #expect(QuietHours(startMinute: -5, endMinute: 99_999) == QuietHours(startMinute: 0, endMinute: 1439))
        var hours = QuietHours.standard
        hours.startMinute = 5000
        #expect(hours.startMinute == 1439)
        let decoded = try JSONDecoder().decode(QuietHours.self, from: Data(#"{"startMinute":-3}"#.utf8))
        #expect(decoded == QuietHours(startMinute: 0, endMinute: 8 * 60))
        #expect(QuietHours.label(forMinute: 22 * 60) == "22:00")
        #expect(QuietHours.label(forMinute: 8 * 60 + 5) == "08:05")
    }

    @Test func aTimeOnlyPickerRoundTripsThroughMinutes() {
        let calendar = reminderCalendar(offsetHours: 1)
        let reference = reminderDate(15, 20, calendar: calendar)
        for minute in [0, 1, 8 * 60, 22 * 60, 23 * 60 + 59] {
            let date = QuietHours.date(forMinute: minute, on: reference, calendar: calendar)
            #expect(QuietHours.minuteOfDay(of: date, calendar: calendar) == minute)
            #expect(calendar.isDate(date, inSameDayAs: reference))
        }
    }
}
