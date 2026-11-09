// The scan's restart rules (backlog section 11): from a wake, never a timer, and a camera that sits in range mustn't wake the
// app over and over. Every time is a fixed date, so the answers don't depend on the machine.

import Foundation
import Testing
@testable import CameraTransport

private let t0 = Date(timeIntervalSince1970: 1_794_000_000)
private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

@Suite("Proximity scan restarts")
struct ProximityRestartRulesTests {
    @Test func theRearmIsThirtyMinutes() {
        #expect(ProximityTiming.rearmAfterReport == .seconds(1800))
        #expect(ProximityRestartRules().rearmAfter == .seconds(1800))
    }

    @Test func switchingOnStartsTheScanAndKeepsARunningOne() {
        var rules = ProximityRestartRules()
        #expect(rules.handle(.enabled, at: t0) == .init(action: .start, refreshAt: nil))
    }

    @Test func aCamerasReportDoesntRestartButAsksForARefreshWhenTheRearmIsDue() {
        var rules = ProximityRestartRules()
        let decision = rules.handle(.cameraReported, at: t0)
        #expect(decision == .init(action: .none, refreshAt: at(30)))
        #expect(rules.rearmAt == at(30))
    }

    @Test func anotherReportBeforeTheRearmChangesNothing() {
        var rules = ProximityRestartRules()
        _ = rules.handle(.cameraReported, at: t0)
        #expect(rules.handle(.otherReported, at: at(29)) == .init(action: .none, refreshAt: at(30)))
    }

    @Test func anotherReportOnceTheRearmIsDueRestartsTheScan() {
        var rules = ProximityRestartRules()
        _ = rules.handle(.cameraReported, at: t0)
        #expect(rules.handle(.otherReported, at: at(30)) == .init(action: .restart, refreshAt: nil))
        #expect(rules.rearmAt == nil)
    }

    @Test func anotherReportWithNothingWaitingChangesNothing() {
        // Each peripheral is reported once per scan, so an unrelated device advertising 1800 doesn't hide the camera.
        var rules = ProximityRestartRules()
        #expect(rules.handle(.otherReported, at: t0) == .init(action: .none, refreshAt: nil))
    }

    @Test func aCameraSittingInRangeIsNeverRestartedByItsOwnReports() {
        // Even long after the rearm was due, a camera's report starts a new wait instead of restarting at once.
        var rules = ProximityRestartRules()
        for minute in stride(from: 0.0, through: 600, by: 45) {
            #expect(rules.handle(.cameraReported, at: at(minute)).action == .none)
            #expect(rules.rearmAt == at(minute + 30))
        }
    }

    @Test func aSecondCameraPushesTheRearmLaterNotEarlier() {
        var rules = ProximityRestartRules()
        _ = rules.handle(.cameraReported, at: at(0))
        #expect(rules.handle(.cameraReported, at: at(20)).refreshAt == at(50))
        // Time going backwards (a clock change) never brings the rearm forward.
        #expect(rules.handle(.cameraReported, at: at(5)).refreshAt == at(50))
    }

    @Test func theRefreshTaskRestartsOnceTheRearmIsDue() {
        var rules = ProximityRestartRules()
        _ = rules.handle(.cameraReported, at: t0)
        #expect(rules.handle(.refreshTask, at: at(10)) == .init(action: .none, refreshAt: at(30)))
        #expect(rules.handle(.refreshTask, at: at(31)) == .init(action: .restart, refreshAt: nil))
    }

    @Test func theRefreshTaskWithNothingWaitingRestartsBecauseARelaunchLostTheState() {
        var rules = ProximityRestartRules()
        #expect(rules.handle(.refreshTask, at: t0) == .init(action: .restart, refreshAt: nil))
    }

    @Test func theForegroundAlwaysRestartsAndClearsTheWait() {
        var rules = ProximityRestartRules()
        #expect(rules.handle(.foreground, at: t0) == .init(action: .restart, refreshAt: nil))
        _ = rules.handle(.cameraReported, at: at(1))
        #expect(rules.handle(.foreground, at: at(2)) == .init(action: .restart, refreshAt: nil))
        #expect(rules.rearmAt == nil)
    }

    @Test func bluetoothComingBackOnStartsANewScanAndClearsTheWait() {
        var rules = ProximityRestartRules()
        _ = rules.handle(.cameraReported, at: t0)
        #expect(rules.handle(.bluetoothPoweredOn, at: at(5)) == .init(action: .start, refreshAt: nil))
        #expect(rules.rearmAt == nil)
    }

    @Test func resetForgetsTheWait() {
        var rules = ProximityRestartRules()
        _ = rules.handle(.cameraReported, at: t0)
        rules.reset()
        #expect(rules.rearmAt == nil)
        #expect(rules.handle(.otherReported, at: at(60)).action == .none)
    }

    @Test func aShorterRearmIsHonoured() {
        var rules = ProximityRestartRules(rearmAfter: .milliseconds(1500))
        _ = rules.handle(.cameraReported, at: t0)
        #expect(rules.rearmAt == t0.addingTimeInterval(1.5))
        #expect(rules.handle(.otherReported, at: t0.addingTimeInterval(1.4)).action == .none)
        #expect(rules.handle(.otherReported, at: t0.addingTimeInterval(1.5)).action == .restart)
    }

    @Test func onlyAWakeRestarts() {
        // Every event is a wake the app gets anyway; there is no timer event, and with no event nothing happens. Of the six,
        // the ones that restart a scan that reported a camera a moment ago are the app coming to the front and an expired wait.
        var rules = ProximityRestartRules()
        _ = rules.handle(.cameraReported, at: t0)
        let early = at(1)
        var copy = rules
        #expect(copy.handle(.otherReported, at: early).action == .none)
        copy = rules
        #expect(copy.handle(.refreshTask, at: early).action == .none)
        copy = rules
        #expect(copy.handle(.cameraReported, at: early).action == .none)
        copy = rules
        #expect(copy.handle(.foreground, at: early).action == .restart)
    }
}

@Suite("Holding fan-out")
struct HoldingEventFanOutTests {
    @Test func whatIsSentBeforeTheFirstReaderIsHeldForIt() async {
        let fan = HoldingEventFanOut<Int>(limit: 4)
        fan.send(1)
        fan.send(2)
        #expect(fan.heldCount == 2)
        let stream = fan.subscribe()
        #expect(fan.heldCount == 0)
        fan.send(3)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
        #expect(await iterator.next() == 3)
    }

    @Test func onlyTheNewestAreHeld() async {
        let fan = HoldingEventFanOut<Int>(limit: 2)
        for n in 1...5 { fan.send(n) }
        #expect(fan.heldCount == 2)
        var iterator = fan.subscribe().makeAsyncIterator()
        #expect(await iterator.next() == 4)
        #expect(await iterator.next() == 5)
    }

    @Test func aLiveReaderGetsEverythingAndNothingIsHeld() async {
        let fan = HoldingEventFanOut<Int>()
        let stream = fan.subscribe()
        fan.send(7)
        #expect(fan.heldCount == 0)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 7)
    }

    @Test func afterTheReaderGoesElementsAreHeldAgain() async {
        let fan = HoldingEventFanOut<Int>()
        do {
            let stream = fan.subscribe()
            let reader = Task {
                for await _ in stream {}
            }
            reader.cancel()
            await reader.value
        }
        // The termination handler ran when the reader was cancelled.
        #expect(fan.subscriberCount == 0)
        fan.send(9)
        #expect(fan.heldCount == 1)
        var iterator = fan.subscribe().makeAsyncIterator()
        #expect(await iterator.next() == 9)
    }

    @Test func aHoldOfZeroHoldsNothing() {
        let fan = HoldingEventFanOut<Int>(limit: 0)
        fan.send(1)
        #expect(fan.heldCount == 0)
    }
}
