import BLEKit
import Foundation
import Testing
@testable import CameraTransport

/// The onboarding pairing check (backlog section 6) against scripted links. The 12.3 s read is the 4 Nov 13:06 measurement.
@Suite("Pairing check", .timeLimit(.minutes(1)))
struct PairingCheckTests {
    private let five: [Call] = [.status, .battery, .media, .pushTransfer, .initialSetting].map { .notify(true, $0) }
    private let off: [Call] = [.status, .battery, .media, .pushTransfer, .initialSetting].map { .notify(false, $0) }

    private func check(
        _ connector: FakeGATTConnector, known: PeripheralID? = nil, on clock: VirtualClock
    ) async -> (PairingOutcome, PeripheralID?) {
        await driven(clock) { await PairingCheck(clock: clock).run(connector: connector, known: known) }
    }

    @Test func aReadThatComesBackAtOnceMeansAlreadyPaired() async {
        let clock = VirtualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        let connector = FakeGATTConnector([.success(link)])
        let (outcome, id) = await check(connector, on: clock)
        #expect(outcome == .alreadyPaired)
        #expect(id == link.peripheral)
        // Switches on, the protected read, switches off, closed.
        #expect(link.calls == five + [.read(.status)] + off + [.disconnect])
    }

    @Test func theReadThatWaitsForThePersonIsNotTimedOut() async {
        // 12.3 s with both prompts accepted (4 Nov 13:06): the read is given no timeout at all.
        let clock = VirtualClock()
        let link = FakeGATTLink(clock: clock)
        link.delayReads(.status, by: .milliseconds(12300))
        let connector = FakeGATTConnector([.success(link)])
        let (outcome, id) = await check(connector, on: clock)
        #expect(outcome == .paired)
        #expect(id == link.peripheral)
        #expect(link.timeouts(for: .status) == [nil])
        #expect(clock.elapsed == .milliseconds(12300))
        #expect(link.calls.last == .disconnect)
    }

    @Test func theFakeWouldHaveTimedOutAShortTimeout() async {
        // Guards the test above: a read given the spike's 15 s limit is cut off by this fake once it passes, so
        // "not timed out" really is about the nil timeout.
        let clock = VirtualClock()
        let link = FakeGATTLink(clock: clock)
        link.delayReads(.status, by: .seconds(20))
        let outcome: GATTFailure? = await driven(clock) {
            do throws(GATTFailure) {
                _ = try await link.read(.status, timeout: .seconds(15))
                return nil
            } catch {
                return error
            }
        }
        #expect(outcome == .timedOut)
    }

    @Test func aRefusalMeansNotPairedAndIsNeverRetried() async {
        let clock = VirtualClock()
        let link = FakeGATTLink(clock: clock)
        link.failReads(.status, with: [.notPaired, .notPaired, .notPaired])
        let connector = FakeGATTConnector([.success(link), .success(FakeGATTLink(clock: clock))])
        let (outcome, id) = await check(connector, on: clock)
        #expect(outcome == .notPaired)
        #expect(id == link.peripheral)
        #expect(connector.connectCount == 1)
        #expect(link.count(.read(.status)) == 1)
        #expect(link.count(.disconnect) == 1)
    }

    @Test func aRefusedSubscriptionIsNotPairedToo() async {
        let clock = VirtualClock()
        let link = FakeGATTLink(clock: clock)
        link.failNotify(.status, with: .notPaired)
        let (outcome, _) = await check(FakeGATTConnector([.success(link)]), on: clock)
        #expect(outcome == .notPaired)
        #expect(link.count(.read(.status)) == 0)
    }

    @Test func aDropIsRetriedOnceFromANewConnectionToTheSameCamera() async {
        let clock = VirtualClock()
        let first = FakeGATTLink(clock: clock)
        first.failReads(.status, with: [.linkDropped])
        let second = FakeGATTLink(clock: clock)
        let connector = FakeGATTConnector([.success(first), .success(second)])
        let (outcome, id) = await check(connector, on: clock)
        #expect(outcome == .alreadyPaired)
        #expect(id == second.peripheral)
        #expect(connector.knownArguments == [nil, first.peripheral])
    }

    @Test func aDropWhileTheReadWaitsForThePersonEndsTheReadAndIsRetried() async {
        // Opening the Pairing screen can drop the link under the waiting read (5 Nov 01:19:41): the read ends with
        // `linkDropped` at the drop instead of waiting out its delay, and the check goes again from a new connection.
        let clock = VirtualClock()
        let first = FakeGATTLink(clock: clock)
        first.delayReads(.status, by: .milliseconds(12300))
        first.scheduleDrop(after: .seconds(5))
        let second = FakeGATTLink(clock: clock)
        let connector = FakeGATTConnector([.success(first), .success(second)])
        let (outcome, id) = await check(connector, on: clock)
        #expect(outcome == .alreadyPaired)
        #expect(id == second.peripheral)
        #expect(clock.elapsed == .seconds(5))
        #expect(first.count(.disconnect) == 1)
        #expect(connector.knownArguments == [nil, first.peripheral])
    }

    @Test func aSecondDropEndsItAsUnavailable() async {
        let clock = VirtualClock()
        let first = FakeGATTLink(clock: clock)
        first.failReads(.status, with: [.linkDropped])
        let second = FakeGATTLink(clock: clock)
        second.failReads(.status, with: [.linkDropped])
        let third = FakeGATTLink(clock: clock)
        let connector = FakeGATTConnector([.success(first), .success(second), .success(third)])
        let (outcome, id) = await check(connector, on: clock)
        #expect(outcome == .unavailable(.linkDropped))
        #expect(id == second.peripheral)
        #expect(connector.connectCount == 2)
    }

    @Test func aRefusalAfterTheRetriedDropIsStillNotPaired() async {
        let clock = VirtualClock()
        let first = FakeGATTLink(clock: clock)
        first.failReads(.status, with: [.linkDropped])
        let second = FakeGATTLink(clock: clock)
        second.failReads(.status, with: [.notPaired])
        let (outcome, _) = await check(FakeGATTConnector([.success(first), .success(second)]), on: clock)
        #expect(outcome == .notPaired)
    }

    @Test func cancellingTheWaitingReadEndsItAndClosesTheLink() async {
        let clock = VirtualClock()
        let link = FakeGATTLink(clock: clock)
        link.delayReads(.status, by: .milliseconds(12300))
        let connector = FakeGATTConnector([.success(link)])
        let task = Task { await PairingCheck(clock: clock).run(connector: connector, known: nil) }
        await clock.waitUntilSomeoneSleeps() // the read is waiting for the person
        task.cancel()
        let (outcome, id) = await task.value
        #expect(outcome == .cancelled)
        #expect(id == link.peripheral)
        #expect(link.count(.disconnect) == 1)
        #expect(connector.connectCount == 1)
    }

    @Test func aCameraThatCantBeReachedSaysWhyAndHasNoIdentifier() async {
        for failure in [GATTFailure.bluetoothOff, .unauthorised, .timedOut, .serviceMissing, .other(3)] {
            let clock = VirtualClock()
            let connector = FakeGATTConnector([.failure(failure)])
            let (outcome, id) = await check(connector, on: clock)
            #expect(outcome == .unavailable(failure))
            #expect(id == nil)
            #expect(connector.connectCount == 1)
        }
    }

    @Test func theStoredIdentifierIsHandedToTheConnector() async {
        let clock = VirtualClock()
        let known = PeripheralID(UUID())
        let connector = FakeGATTConnector([.success(FakeGATTLink(clock: clock, peripheral: known))])
        let (outcome, id) = await check(connector, known: known, on: clock)
        #expect(outcome == .alreadyPaired)
        #expect(id == known)
        #expect(connector.knownArguments == [known])
    }
}
