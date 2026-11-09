// The reminder's model (Iteration 4, section 12; W18) against a fake notifier, a fake store and a clock the test moves:
// posting, the hold across a relaunch, a connection or an import holding reminders back, the permission, and the
// responses to the notification. Every wait is bounded.

import CameraTransport
import Catalogue
import Foundation
import Synchronization
import Testing
@testable import AppUI

/// A wall clock the test moves.
private final class ReminderClock: Sendable {
    private let value = Mutex(reminderDate(12))
    var date: Date { value.withLock { $0 } }
    func set(_ date: Date) { value.withLock { $0 = date } }
    func advance(minutes: Double) { value.withLock { $0 = $0.addingTimeInterval(minutes * 60) } }
}

private final class ReminderLog: BenchLog, Sendable {
    private let recorded = Mutex<[String]>([])
    var lines: [String] { recorded.withLock { $0 } }
    func note(_ line: String) { recorded.withLock { $0.append(line) } }
}

/// What the model told the scan.
private final class ScanSwitches: Sendable {
    private let recorded = Mutex<[Bool]>([])
    var calls: [Bool] { recorded.withLock { $0 } }
    func record(_ on: Bool) { recorded.withLock { $0.append(on) } }
}

/// Holds a fake call (iOS's permission prompt) until the test lets it go, polling with a bounded wait that ends on
/// cancellation too (no bare continuation).
private final class PromptHold: Sendable {
    private let state = Mutex((entered: false, released: false))
    var entered: Bool { state.withLock { $0.entered } }
    func release() { state.withLock { $0.released = true } }

    /// Waits until released, for at most about 10 seconds.
    func wait() async {
        state.withLock { $0.entered = true }
        for _ in 0 ..< 1000 where !state.withLock({ $0.released }) {
            if (try? await Task.sleep(for: .milliseconds(10))) == nil { return }
        }
    }
}

/// The model a fake closure acts on once it exists.
@MainActor
private final class ModelBox {
    var model: ReminderModel?
}

/// One phone: the stored values and the clock outlive a model, so a second model over them is the next launch.
@MainActor
private struct Phone {
    let backing = InMemoryKeyValueStore()
    let clock = ReminderClock()
    let log = ReminderLog()
    let scans = ScanSwitches()
    let notifier: FakeNotifier

    init(_ status: NotificationAuthorisation = .authorised, answer: NotificationAuthorisation = .authorised) {
        notifier = FakeNotifier(status, answer: answer)
    }

    func launch(enabled: Bool? = true, holds: ReminderHoldStore? = nil,
                count: (@Sendable (CameraKey) async -> Int?)? = nil) -> ReminderModel {
        let settings = ReminderSettingsStore(store: backing)
        if let enabled {
            var stored = settings.load()
            stored.enabled = enabled
            settings.save(stored)
        }
        return model(holds: holds, count: count)
    }

    /// A model over what is stored, as at a launch. `count` stands in for the catalogue's last-known count.
    func model(holds: ReminderHoldStore? = nil,
               count: (@Sendable (CameraKey) async -> Int?)? = nil) -> ReminderModel {
        let clock = clock
        let scans = scans
        return ReminderModel(
            settings: ReminderSettingsStore(store: backing), holds: holds ?? ReminderHoldStore(store: backing),
            notifier: notifier, now: { clock.date }, calendar: { reminderCalendar() }, log: log, tags: CameraKeyTags(),
            notImportedCount: count ?? { camera in camera == reminderCamera ? 318 : nil },
            scanEnabled: { scans.record($0) })
    }

    func arrival(_ camera: CameraKey = reminderCamera) -> ProximityArrival {
        reminderArrival(camera, at: clock.date)
    }
}

@MainActor
@Suite("Reminder model", .timeLimit(.minutes(1)))
struct ReminderModelTests {
    // MARK: Posting and the hold

    @Test func aKnownCameraPostsOneReminderWithTheLastKnownCount() async {
        let phone = Phone()
        let model = phone.launch()
        let outcome = await model.handle(phone.arrival())
        #expect(outcome == .posted(reminderCamera))
        #expect(phone.notifier.posts == [.cameraNearby(reminderCamera, notImported: 318)])
        #expect(phone.notifier.posts.first?.userInfo == ["camera": reminderCamera.rawValue])
        #expect(ReminderModel.camera(fromUserInfo: ["camera": reminderCamera.rawValue]) == reminderCamera)
    }

    @Test func theReminderIsOffByDefaultAndPostsNothing() async {
        let phone = Phone()
        let model = phone.launch(enabled: nil)
        #expect(!model.settings.enabled)
        #expect(await model.handle(phone.arrival()) == .suppressed(.disabled))
        #expect(phone.notifier.posts.isEmpty)
    }

    @Test func aCameraAtTheEdgeOfRangeRemindsOnceInFourHours() async {
        let phone = Phone()
        let model = phone.launch()
        #expect(await model.handle(phone.arrival()) == .posted(reminderCamera))
        // The spike's night: reports every few minutes. Every one is held until the fourth hour.
        for _ in 0 ..< 47 {
            phone.clock.advance(minutes: 5)
            if phone.clock.date >= reminderDate(16) { break }
            guard case .suppressed(.held) = await model.handle(phone.arrival()) else {
                Issue.record("a report inside the hold wasn't held")
                return
            }
        }
        #expect(phone.notifier.posts.count == 1)
        phone.clock.set(reminderDate(16))
        #expect(await model.handle(phone.arrival()) == .posted(reminderCamera))
        #expect(phone.notifier.posts.count == 2)
    }

    @Test func theHoldSurvivesARelaunch() async {
        let phone = Phone()
        #expect(await phone.launch().handle(phone.arrival()) == .posted(reminderCamera))
        phone.clock.advance(minutes: 90)
        // The app was killed and state restoration relaunched it for the next report.
        let relaunched = phone.model()
        guard case .suppressed(.held) = await relaunched.handle(phone.arrival()) else {
            Issue.record("the relaunched app reminded again inside the hold")
            return
        }
        #expect(phone.notifier.posts.count == 1)
        phone.clock.advance(minutes: 150)
        #expect(await phone.model().handle(phone.arrival()) == .posted(reminderCamera))
    }

    @Test func aHoldIsPerCamera() async {
        let phone = Phone()
        let model = phone.launch()
        #expect(await model.handle(phone.arrival()) == .posted(reminderCamera))
        #expect(await model.handle(phone.arrival(otherReminderCamera)) == .posted(otherReminderCamera))
        #expect(phone.notifier.posts.count == 2)
    }

    // MARK: Connected or importing

    @Test func aUSBConnectionStartsAHoldAndNoReminderComesWhileItLasts() async {
        let phone = Phone()
        let model = phone.launch()
        await model.begin(.connection, camera: reminderCamera)
        #expect(model.isBusy)
        #expect(await model.handle(phone.arrival()) == .suppressed(.connectedOrImporting))
        // The camera keeps advertising over a connection (the spike posted one a minute over USB).
        phone.clock.advance(minutes: 1)
        #expect(await model.handle(phone.arrival()) == .suppressed(.connectedOrImporting))
        phone.clock.advance(minutes: 10)
        model.end(.connection, camera: reminderCamera)
        #expect(!model.isBusy)
        phone.clock.advance(minutes: 5)
        guard case .suppressed(.held) = await model.handle(phone.arrival()) else {
            Issue.record("a reminder came right after the connection ended")
            return
        }
        #expect(phone.notifier.posts.isEmpty)
    }

    @Test func theHoldRunsFromTheEndOfALongImportNotOnlyItsStart() async {
        let phone = Phone()
        let model = phone.launch()
        await model.begin(.importing, camera: reminderCamera)
        phone.clock.advance(minutes: 5 * 60)
        model.end(.importing, camera: reminderCamera)
        phone.clock.advance(minutes: 3 * 60 + 59)
        guard case .suppressed(.held) = await model.handle(phone.arrival()) else {
            Issue.record("a reminder came inside four hours of the import's end")
            return
        }
        phone.clock.advance(minutes: 1)
        #expect(await model.handle(phone.arrival()) == .posted(reminderCamera))
    }

    @Test func noReminderDuringAnImportEvenForAnotherCameraAndBothActivitiesCount() async {
        let phone = Phone()
        let model = phone.launch()
        await model.begin(.connection, camera: reminderCamera)
        await model.begin(.importing, camera: reminderCamera)
        await model.begin(.importing, camera: reminderCamera) // twice: still one entry
        #expect(model.activities.count == 2)
        #expect(await model.handle(phone.arrival(otherReminderCamera)) == .suppressed(.connectedOrImporting))
        model.end(.importing, camera: reminderCamera)
        #expect(await model.handle(phone.arrival(otherReminderCamera)) == .suppressed(.connectedOrImporting))
        model.end(.connection, camera: reminderCamera)
        #expect(await model.handle(phone.arrival(otherReminderCamera)) == .posted(otherReminderCamera))
    }

    @Test func aConnectionTakesBackAReminderStillShowing() async {
        let phone = Phone()
        let model = phone.launch()
        #expect(await model.handle(phone.arrival()) == .posted(reminderCamera))
        await model.begin(.connection, camera: reminderCamera)
        #expect(phone.notifier.withdrawals.count == 1)
        #expect(phone.notifier.withdrawals.first?.identifier == AppNotification.cameraNearby(reminderCamera, notImported: nil).identifier)
    }

    @Test func aConnectionThatBeginsWhileTheReminderIsBeingReadiedStopsIt() async {
        let phone = Phone()
        let box = ModelBox()
        // The cable goes in while the model reads the last-known count, after it has decided to post.
        let model = phone.launch(count: { @MainActor camera in
            await box.model?.begin(.connection, camera: camera)
            return 318
        })
        box.model = model
        #expect(await model.handle(phone.arrival()) == .suppressed(.connectedOrImporting))
        #expect(phone.notifier.posts.isEmpty)
    }

    @Test func switchingOffOrComingToTheFrontWhileTheReminderIsBeingReadiedStopsIt() async {
        let off = Phone()
        let offBox = ModelBox()
        let offModel = off.launch(count: { @MainActor _ in
            await offBox.model?.setEnabled(false)
            return 318
        })
        offBox.model = offModel
        #expect(await offModel.handle(off.arrival()) == .suppressed(.disabled))
        #expect(off.notifier.posts.isEmpty)
        #expect(ReminderHoldStore(store: off.backing).holds(now: off.clock.date).isEmpty)

        let front = Phone()
        let frontBox = ModelBox()
        let frontModel = front.launch(count: { @MainActor _ in
            frontBox.model?.setAppInFront(true)
            return 318
        })
        frontBox.model = frontModel
        #expect(await frontModel.handle(front.arrival()) == .suppressed(.appInFront))
        #expect(front.notifier.posts.isEmpty)
    }

    // MARK: The app in front

    @Test func noReminderAndNoHoldWhileTheAppIsInFront() async {
        let phone = Phone()
        let model = phone.launch()
        model.setAppInFront(true)
        #expect(await model.handle(phone.arrival()) == .suppressed(.appInFront))
        #expect(phone.notifier.posts.isEmpty)
        // The camera still shows as nearby in the app.
        #expect(model.isNearby(reminderCamera))
        // No hold started: the person leaves without importing, and the next report reminds.
        model.setAppInFront(false)
        phone.clock.advance(minutes: 10)
        #expect(await model.handle(phone.arrival()) == .posted(reminderCamera))
    }

    // MARK: Lengths

    @Test func theHoldAndSnoozeLengthsComeFromTheStore() async {
        let phone = Phone()
        let store = ReminderHoldStore(store: phone.backing, hold: .seconds(600), snoozeLength: .seconds(300))
        let model = phone.launch(holds: store)
        let start = phone.clock.date
        #expect(await model.handle(phone.arrival()) == .posted(reminderCamera))
        phone.clock.advance(minutes: 5)
        #expect(await model.handle(phone.arrival()) == .suppressed(.held(until: start.addingTimeInterval(600))))
        await model.respond(.snooze, camera: reminderCamera)
        #expect(model.snoozedUntil == phone.clock.date.addingTimeInterval(300))
        #expect(store.snoozedUntil(now: phone.clock.date) == phone.clock.date.addingTimeInterval(300))
    }

    // MARK: Quiet hours, snooze, mute

    @Test func quietHoursHoldTheReminderBackWithoutStartingAHold() async {
        let phone = Phone()
        let model = phone.launch()
        phone.clock.set(reminderDate(23))
        #expect(await model.handle(phone.arrival()) == .suppressed(.quietHours))
        phone.clock.set(reminderDate(7, 59))
        #expect(await model.handle(phone.arrival()) == .suppressed(.quietHours))
        phone.clock.set(reminderDate(8))
        #expect(await model.handle(phone.arrival()) == .posted(reminderCamera))
    }

    @Test func snoozeOneHourSilencesRemindersForAnHourAndSurvivesARelaunch() async {
        let phone = Phone()
        let model = phone.launch()
        await model.respond(.snooze, camera: reminderCamera)
        #expect(model.snoozedUntil == reminderDate(13))
        phone.clock.advance(minutes: 59)
        #expect(await phone.model().handle(phone.arrival()) == .suppressed(.snoozed(until: reminderDate(13))))
        phone.clock.advance(minutes: 1)
        #expect(await phone.model().handle(phone.arrival()) == .posted(reminderCamera))
    }

    @Test func aSnoozeStartedAtALaunchIsReadBack() async {
        let phone = Phone()
        await phone.launch().respond(.snooze, camera: nil)
        #expect(phone.model().snoozedUntil == reminderDate(13))
        phone.clock.advance(minutes: 61)
        #expect(phone.model().snoozedUntil == nil)
    }

    @Test func aMutedCameraIsNotRemindedAndTheMuteIsStored() async {
        let phone = Phone()
        let model = phone.launch()
        model.setMuted(true, camera: reminderCamera)
        #expect(model.isMuted(reminderCamera))
        #expect(await phone.model().handle(phone.arrival()) == .suppressed(.muted))
        #expect(await phone.model().handle(phone.arrival(otherReminderCamera)) == .posted(otherReminderCamera))
        model.setMuted(false, camera: reminderCamera)
        #expect(await phone.model().handle(phone.arrival()) == .posted(reminderCamera))
    }

    @Test func theSettingsRowsFollowTheMutes() {
        let phone = Phone()
        let model = phone.launch()
        model.setCameras([ReminderCameraName(camera: reminderCamera, name: "Camera A"),
                          ReminderCameraName(camera: otherReminderCamera, name: "Camera B")])
        #expect(model.cameraChoices.map(\.isReminded) == [true, true])
        var choices = model.cameraChoices
        choices[1].isReminded = false
        model.cameraChoices = choices
        #expect(model.isMuted(otherReminderCamera))
        #expect(!model.isMuted(reminderCamera))
        #expect(model.cameraChoices.map(\.isReminded) == [true, false])
        #expect(model.cameraChoices.map(\.name) == ["Camera A", "Camera B"])
        #expect(phone.model().isMuted(otherReminderCamera))
    }

    @Test func theQuietHoursPickersEditTheStoredMinutes() {
        let phone = Phone()
        let model = phone.launch()
        #expect(QuietHours.minuteOfDay(of: model.quietStart, calendar: reminderCalendar()) == 22 * 60)
        #expect(QuietHours.minuteOfDay(of: model.quietEnd, calendar: reminderCalendar()) == 8 * 60)
        model.quietStart = reminderDate(23, 15)
        model.quietEnd = reminderDate(7, 30)
        #expect(model.settings.quietHours == QuietHours(startMinute: 23 * 60 + 15, endMinute: 7 * 60 + 30))
        #expect(phone.model().settings.quietHours == QuietHours(startMinute: 23 * 60 + 15, endMinute: 7 * 60 + 30))
    }

    // MARK: Permission and the scan

    @Test func switchingOnAsksForPermissionOnceWhenUndeterminedThenStartsTheScan() async {
        let phone = Phone(.notDetermined, answer: .authorised)
        let model = phone.launch(enabled: false)
        await model.setEnabled(true)
        #expect(phone.notifier.requests == 1)
        #expect(model.authorisation == .authorised)
        #expect(phone.scans.calls == [true])
        #expect(phone.model().settings.enabled)
        await model.setEnabled(true) // again: nothing more
        #expect(phone.notifier.requests == 1)
        #expect(phone.scans.calls == [true])
    }

    @Test func switchingOnDoesNotAskWhenIOSHasAlreadyAnswered() async {
        for status in [NotificationAuthorisation.authorised, .denied, .provisional] {
            let phone = Phone(status)
            let model = phone.launch(enabled: false)
            await model.setEnabled(true)
            #expect(phone.notifier.requests == 0)
            #expect(phone.scans.calls == [true])
        }
    }

    @Test func aDeniedPermissionKeepsTheReminderOnAndSaysSo() async {
        let phone = Phone(.notDetermined, answer: .denied)
        let model = phone.launch(enabled: false)
        await model.setEnabled(true)
        #expect(model.notificationsAreOff)
        #expect(model.settings.enabled)
        #expect(await model.handle(phone.arrival()) == .notAllowed)
        #expect(phone.notifier.posts.isEmpty)
        // A denied reminder starts no hold: nothing was shown.
        #expect(ReminderHoldStore(store: phone.backing).holds(now: phone.clock.date).isEmpty)
    }

    @Test func switchingOffStopsTheScanAndIsStored() async {
        let phone = Phone()
        let model = phone.launch()
        await model.setEnabled(false)
        #expect(phone.scans.calls == [false])
        #expect(!phone.model().settings.enabled)
        #expect(await model.handle(phone.arrival()) == .suppressed(.disabled))
    }

    @Test func theToggleShowsTheChoiceAtOnceAndTheScanFollowsTheFinalState() async throws {
        let phone = Phone(.notDetermined)
        let prompt = PromptHold()
        phone.notifier.onRequest = { await prompt.wait() }
        let model = phone.launch(enabled: false)
        model.remindsWhenNearby = true
        #expect(model.remindsWhenNearby)
        // The "on" task is held at iOS's prompt...
        for _ in 0 ..< 1000 where !prompt.entered { try await Task.sleep(for: .milliseconds(10)) }
        #expect(prompt.entered)
        // ...while the person switches it off again, and that task finishes first.
        model.remindsWhenNearby = false
        #expect(!model.remindsWhenNearby)
        for _ in 0 ..< 1000 where phone.scans.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(phone.scans.calls == [false])
        // The prompt is answered: the "on" task ends with the scan as the setting is now, off.
        prompt.release()
        for _ in 0 ..< 1000 where phone.scans.calls.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(phone.scans.calls == [false, false])
        #expect(phone.notifier.requests == 1)
        #expect(!phone.model().settings.enabled)
    }

    @Test func atLaunchTheStoredSettingIsTheScansAndThePermissionIsRead() async {
        let on = Phone()
        await on.launch(enabled: true).applyStoredSetting()
        #expect(on.scans.calls == [true])
        let off = Phone()
        let model = off.launch(enabled: nil)
        await model.applyStoredSetting()
        #expect(off.scans.calls == [false])
        #expect(model.authorisation == .authorised)
    }

    // MARK: Responses

    @Test func importNowAndATapOpenTheCameraTheNotificationCarried() async {
        let phone = Phone()
        let model = phone.launch()
        await model.respond(.importNow, camera: reminderCamera)
        #expect(model.cameraToOpen == reminderCamera)
        #expect(model.takeCameraToOpen() == reminderCamera)
        #expect(model.takeCameraToOpen() == nil)
        await model.respond(.opened, camera: otherReminderCamera)
        #expect(model.takeCameraToOpen() == otherReminderCamera)
        await model.respond(.opened, camera: nil)
        #expect(model.cameraToOpen == nil)
    }

    @Test func notNowAndASwipeAwayChangeNothingAndTheHoldKeepsRunning() async {
        let phone = Phone()
        let model = phone.launch()
        #expect(await model.handle(phone.arrival()) == .posted(reminderCamera))
        await model.respond(.notNow, camera: reminderCamera)
        await model.respond(.dismissed, camera: reminderCamera)
        #expect(model.cameraToOpen == nil)
        #expect(model.snoozedUntil == nil)
        phone.clock.advance(minutes: 30)
        guard case .suppressed(.held) = await model.handle(phone.arrival()) else {
            Issue.record("a report after Not Now wasn't held")
            return
        }
    }

    @Test func theReminderButtonsMapToActions() {
        #expect(ReminderAction(buttonIdentifier: AppNotificationCategory.Action.importNowIdentifier) == .importNow)
        #expect(ReminderAction(buttonIdentifier: AppNotificationCategory.Action.notNowIdentifier) == .notNow)
        #expect(ReminderAction(buttonIdentifier: AppNotificationCategory.Action.snoozeIdentifier) == .snooze)
        #expect(ReminderAction(buttonIdentifier: "something else") == nil)
        #expect(ReminderModel.camera(fromUserInfo: [:]) == nil)
        #expect(ReminderModel.camera(fromUserInfo: ["camera": 3]) == nil)
    }

    // MARK: Nearby and the log

    @Test func aCameraShowsAsNearbyForTwoMinutesAfterItsReport() async {
        let phone = Phone()
        let model = phone.launch()
        #expect(!model.isNearby(reminderCamera))
        await model.handle(phone.arrival())
        #expect(model.isNearby(reminderCamera))
        phone.clock.advance(minutes: 1)
        #expect(model.isNearby(reminderCamera))
        phone.clock.advance(minutes: 1)
        #expect(!model.isNearby(reminderCamera))
        #expect(!model.isNearby(otherReminderCamera))
    }

    @Test func everyReportIsLoggedWithItsTimeAndNeverTheCamera() async {
        let phone = Phone()
        let model = phone.launch()
        await model.handle(phone.arrival())
        phone.clock.advance(minutes: 5)
        await model.handle(phone.arrival())
        phone.clock.set(reminderDate(23))
        await model.handle(phone.arrival())
        let lines = phone.log.lines.filter { $0.contains("report at") }
        #expect(lines.count == 3)
        #expect(lines[0].contains("2026-11-10T12:00:00Z"))
        #expect(lines[0].contains("reminder posted"))
        #expect(lines[0].contains("RSSI -62 dBm"))
        #expect(lines[1].contains("held until 2026-11-10T16:00:00Z"))
        #expect(lines[2].contains("quiet hours"))
        for line in phone.log.lines {
            #expect(!line.contains(reminderCamera.rawValue))
            #expect(!line.contains("camera-a"))
        }
        #expect(lines[0].contains("k1 (usb-device)"))
    }

    // MARK: Reading the arrivals

    @Test func runReadsEveryArrivalUntilTheStreamEnds() async {
        let phone = Phone()
        let model = phone.launch()
        let (arrivals, sink) = AsyncStream.makeStream(of: ProximityArrival.self)
        sink.yield(phone.arrival())
        sink.yield(phone.arrival(otherReminderCamera))
        sink.yield(phone.arrival())
        sink.finish()
        await model.run(arrivals)
        #expect(phone.scans.calls == [true])
        #expect(phone.notifier.posts.count == 2)
    }

    @Test func launchReadsArrivalsInATaskOfItsOwn() async throws {
        let phone = Phone()
        let model = phone.launch()
        let (arrivals, sink) = AsyncStream.makeStream(of: ProximityArrival.self)
        model.launch(arrivals: arrivals)
        model.launch(arrivals: arrivals) // again: nothing more
        sink.yield(phone.arrival())
        // Bounded: a missed delivery fails the test after 20 s rather than hanging it.
        for _ in 0 ..< 2000 where phone.notifier.posts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(phone.notifier.posts.count == 1)
        sink.finish()
    }
}

// MARK: - The notification

@Suite("Reminder notification", .timeLimit(.minutes(1)))
struct ReminderNotificationTests {
    @Test func theCategoryHasTheThreeButtonsInOrderAndHearsASwipeAway() {
        let category = AppNotificationCategory.cameraNearby
        #expect(category.actions.map(\.title) == ["Import Now", "Not Now", "Snooze 1 Hour"])
        #expect(category.actions.map(\.opensApp) == [true, false, false])
        #expect(category.reportsDismissal)
        #expect(Set(category.actions.map(\.identifier)).count == 3)
        #expect(AppNotificationCategory.all.contains(.cameraNearby))
        #expect(AppNotificationCategory.all.contains(.importPaused))
        #expect(!AppNotificationCategory.importPaused.reportsDismissal)
        #expect(Set(AppNotificationCategory.all.map(\.identifier)).count == AppNotificationCategory.all.count)
    }

    @Test func theReminderIsPostedInItsCategoryAndReplacesTheLastOne() {
        let a = AppNotification.cameraNearby(reminderCamera, notImported: 3)
        let b = AppNotification.cameraNearby(otherReminderCamera, notImported: nil)
        #expect(a.category == .cameraNearby)
        #expect(a.identifier == b.identifier)
        #expect(a.identifier != AppNotification.importPaused.identifier)
        #expect(a.title == "Camera Nearby")
        #expect(AppNotification.importPaused.userInfo.isEmpty)
    }

    @Test func theTextSaysTheCountIsTheLastKnownOneAndNeverNamesAThing() {
        #expect(NotificationWording.cameraNearbyBody(notImported: 318)
            == "Your camera is nearby. 318 photos not yet imported when you last connected.")
        #expect(NotificationWording.cameraNearbyBody(notImported: 1)
            == "Your camera is nearby. 1 photo not yet imported when you last connected.")
        for count in [nil, 0, -1] {
            #expect(NotificationWording.cameraNearbyBody(notImported: count)
                == "Your camera is nearby. Open Shutter Bridge to import your photos.")
        }
        // "Nearby", never "switched on" (decision 8).
        #expect(!ReminderWording.footer.lowercased().contains("switched on"))
        #expect(ReminderWording.quietSummary(.standard) == "No reminders from 22:00 to 08:00.")
        #expect(ReminderWording.quietSummary(QuietHours(startMinute: 60, endMinute: 60)) == "No quiet hours.")
    }
}
