import BLEKit
import Foundation
import Testing
@testable import CameraTransport

/// The hand-off's order and waiting, against a link that replays the spike's timelines on a virtual clock (no real waits).
/// Timelines come from spike-findings.md, *BLE advertisement*: status 1 at +0.09 to +0.11 s and 2 at +0.8 to +2.7 s after
/// the write; the camera giving up 0 → 1 → 0 without the five notifications; CC06 and CC07 refused with ATT 0x9D while the
/// Wi-Fi is off. No two scripted events share an instant with a sequencer timer, so the order of events is fixed.
@Suite("Wi-Fi hand-off over Bluetooth", .timeLimit(.minutes(1)))
struct WiFiHandoffTests {
    private let fiveInOrder: [Call] = [.status, .battery, .media, .pushTransfer, .initialSetting].map { .notify(true, $0) }
    /// The spike's pause after the switches: everything after it, on the virtual clock, is shifted by this.
    private let pause = HandoffTiming.afterSubscribe

    private func run(
        _ link: FakeGATTLink, on clock: ManualClock, rewrite: Bool = false
    ) async -> Result<HandoffResult, HandoffFailure> {
        await driven(clock) {
            let handoff = WiFiHandoff(clock: clock)
            do throws(HandoffFailure) {
                return .success(rewrite ? try await handoff.rewriteIfLapsed(on: link) : try await handoff.run(on: link))
            } catch {
                return .failure(error)
            }
        }
    }

    private func failure(_ result: Result<HandoffResult, HandoffFailure>) -> HandoffFailure? {
        if case .failure(let failure) = result { failure } else { nil }
    }

    private func success(_ result: Result<HandoffResult, HandoffFailure>) -> HandoffResult? {
        if case .success(let value) = result { value } else { nil }
    }

    // MARK: Order

    @Test func statusAlreadyTwoReadsTheDetailsAndWritesNothing() async throws {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 2)
        let result = try #require(success(await run(link, on: clock)))
        #expect(link.calls == fiveInOrder + [.read(.status), .read(.ssid), .read(.passphrase)])
        #expect(result.wroteWiFiOn == false)
        #expect(result.launchedBeforeLooking)
        #expect(clock.elapsed == pause)
    }

    @Test func statusZeroSubscribesThenWritesThenWaitsForTwo() async throws {
        // 0 → 1 → 2, the typical timeline: acknowledged, then 1 at +0.09 s and 2 at +0.84 s.
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.onWrite { link in
            link.schedule(status: 1, after: .milliseconds(90))
            link.schedule(status: 2, after: .milliseconds(840))
        }
        let result = try #require(success(await run(link, on: clock)))
        // The five switches, each before the baseline read, which is before the write, which is before the details.
        #expect(link.calls == fiveInOrder + [.read(.status), .write(.wifiOn), .read(.ssid), .read(.passphrase)])
        // The baseline read waits for the spike's pause after the switches; the write follows it at once.
        #expect(link.time(of: .read(.status)) == pause)
        #expect(link.time(of: .write(.wifiOn)) == pause)
        #expect(result.wroteWiFiOn)
        #expect(result.launchedBeforeLooking == false)
        #expect(link.time(of: .read(.ssid)) == pause + .milliseconds(840))
        // The notifications came, so CC09 was never polled.
        #expect(link.count(.read(.status)) == 1)
        #expect(result.unconfirmedSwitches.isEmpty)
    }

    @Test func detailsAreReadWithTheirOwnTimeoutsAndNeverPrinted() async throws {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 2)
        let result = try #require(success(await run(link, on: clock)))
        #expect(link.timeouts(for: .status) == [HandoffTiming.statusRead])
        #expect(link.timeouts(for: .ssid) == [HandoffTiming.credentialRead])
        #expect(result.credentials.ssid == Cam.ssid)
        for text in ["\(result.credentials)", String(reflecting: result.credentials), String(describing: result)] {
            #expect(!text.contains("DIRECT-ab12"))
            #expect(!text.contains("test-pass"))
        }
    }

    @Test func theWindowIsCountedFromStatusTwo() async throws {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.onWrite { $0.schedule(status: 2, after: .seconds(1)) }
        let result = try #require(success(await run(link, on: clock)))
        #expect(clock.elapsed == pause + .seconds(1))
        #expect(result.windowRemaining == HandoffTiming.cameraWiFiWindow)
        clock.advance(by: .seconds(20))
        #expect(result.statusTwoAt.elapsed == .seconds(20))
        #expect(result.windowRemaining == .seconds(30))
        clock.advance(by: .seconds(60))
        #expect(result.windowRemaining == .zero)
    }

    // MARK: The wait for status 2

    @Test func theCameraGivingUpIsNoticedThreeSecondsAfterTheFallback() async {
        // 0 → 1 → 0: what the camera did without the five notifications (3 Nov 00:04).
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.onWrite { link in
            link.schedule(status: 1, after: .milliseconds(90))
            link.schedule(status: 0, after: .milliseconds(300))
        }
        let outcome = await failure(run(link, on: clock))
        #expect(outcome == .wifiDidNotStart(lastStatus: .terminated))
        #expect(clock.elapsed == pause + .milliseconds(3300))
        #expect(link.count(.read(.ssid)) == 0)
    }

    @Test func aStatusThatBouncesBackAndForthDoesNotEndTheWaitEarly() async throws {
        // 0 → 1 → 0 → 1 → 2: the fallback timer is cancelled when the status leaves its earlier value again.
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.onWrite { link in
            link.schedule(status: 1, after: .milliseconds(90))
            link.schedule(status: 0, after: .milliseconds(300))
            link.schedule(status: 1, after: .seconds(2))
            link.schedule(status: 2, after: .milliseconds(4500))
        }
        let result = try #require(success(await run(link, on: clock)))
        #expect(result.wroteWiFiOn)
        #expect(clock.elapsed == pause + .milliseconds(4500))
        #expect(link.count(.write(.wifiOn)) == 1)
    }

    @Test func silentNotificationsMeanReadingCC09OnceASecondFromThreeSecondsOn() async throws {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.onWrite { link in
            link.schedule(status: 1, after: .milliseconds(90), notify: false)
            link.schedule(status: 2, after: .milliseconds(4200), notify: false)
        }
        let result = try #require(success(await run(link, on: clock)))
        let reads = link.logged.filter { $0.call == .read(.status) }.map(\.at)
        // The baseline, then 3 s, 4 s and 5 s after the acknowledgement; the 5 s read sees status 2.
        #expect(reads == [pause, pause + .seconds(3), pause + .seconds(4), pause + .seconds(5)])
        #expect(link.timeouts(for: .status).dropFirst().allSatisfy { $0 == HandoffTiming.pollRead })
        #expect(result.wroteWiFiOn)
        #expect(clock.elapsed == pause + .seconds(5))
    }

    @Test func aStatusThatNeverMovesTimesOutAtThirtySeconds() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        let outcome = await failure(run(link, on: clock))
        #expect(outcome == .timedOut(lastStatus: .terminated))
        #expect(clock.elapsed == pause + HandoffTiming.statusTwo)
        // The baseline, then polls at 3 s and every second after up to 29 s: the poll due at 30 s loses the tie to the deadline.
        #expect(link.count(.read(.status)) == 28)
        #expect(link.count(.write(.wifiOn)) == 1)
    }

    // MARK: Notifications from before the write

    @Test func aStatusNotificationFromTheSubscriptionsDoesNotCountAsSilenceBroken() async throws {
        // The camera sends status 0 while the switches go on, then nothing after the write: the polling still starts 3 s
        // after the acknowledgement, and status 2 at +4.2 s is found by the read at 5 s.
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.schedule(status: 0, after: .milliseconds(300))
        link.onWrite { link in
            link.schedule(status: 1, after: .milliseconds(90), notify: false)
            link.schedule(status: 2, after: .milliseconds(4200), notify: false)
        }
        let result = try #require(success(await run(link, on: clock)))
        let reads = link.logged.filter { $0.call == .read(.status) }.map(\.at)
        #expect(reads == [pause, pause + .seconds(3), pause + .seconds(4), pause + .seconds(5)])
        #expect(result.wroteWiFiOn)
        #expect(clock.elapsed == pause + .seconds(5))
    }

    @Test func aStatusNotificationFromTheBaselineReadDoesNotCountAsSilenceBrokenEither() async throws {
        // The same, with the notification arriving while the baseline read is answered: queued when the write is due, and
        // emptied before it, as the spike did.
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.announceDuringStatusReads([0])
        link.onWrite { link in
            link.schedule(status: 1, after: .milliseconds(90), notify: false)
            link.schedule(status: 2, after: .milliseconds(4200), notify: false)
        }
        let result = try #require(success(await run(link, on: clock)))
        let reads = link.logged.filter { $0.call == .read(.status) }.map(\.at)
        #expect(reads == [pause, pause + .seconds(3), pause + .seconds(4), pause + .seconds(5)])
        #expect(result.wroteWiFiOn)
        #expect(link.count(.write(.wifiOn)) == 1)
    }

    @Test func aQueuedStatusTwoStopsTheWrite() async throws {
        // The read said 0, but a notification of status 2 came with it: the Wi-Fi is on, so nothing is written.
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.announceDuringStatusReads([2])
        let result = try #require(success(await run(link, on: clock)))
        #expect(link.calls == fiveInOrder + [.read(.status), .read(.ssid), .read(.passphrase)])
        #expect(result.wroteWiFiOn == false)
        #expect(result.launchedBeforeLooking == false)
    }

    @Test func aQueuedStatusOneSendsTheRunBackToWaiting() async throws {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.announceDuringStatusReads([1])
        link.schedule(status: 2, after: pause + .seconds(2))
        let result = try #require(success(await run(link, on: clock)))
        #expect(link.count(.write(.wifiOn)) == 0)
        #expect(result.wroteWiFiOn == false)
        #expect(link.time(of: .read(.ssid)) == pause + .seconds(2))
    }

    @Test func aFallbackToZeroDuringThePauseIsWrittenToAtOnce() async throws {
        // Status 1 at the start, 0 from 0.3 s: the baseline read after the pause sees 0, and the write follows it.
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 1)
        link.schedule(status: 0, after: .milliseconds(300))
        link.onWrite { $0.schedule(status: 2, after: .milliseconds(800)) }
        let result = try #require(success(await run(link, on: clock)))
        #expect(result.wroteWiFiOn)
        #expect(link.time(of: .write(.wifiOn)) == pause)
    }

    // MARK: The pause after the switches

    @Test func aDropDuringThePauseEndsTheRunBeforeAnyReadOrWrite() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.scheduleDrop(after: .milliseconds(500))
        let outcome = await failure(run(link, on: clock))
        #expect(outcome == .linkDropped(afterWrite: false))
        #expect(link.count(.read(.status)) == 0)
        #expect(link.count(.write(.wifiOn)) == 0)
        #expect(clock.elapsed == .milliseconds(500))
    }

    @Test func theRewriteHasNoPauseBecauseItHasNoSwitches() async throws {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 2)
        _ = try #require(success(await run(link, on: clock, rewrite: true)))
        #expect(clock.elapsed == .zero)
    }

    @Test func launchingIsWaitedOutWithoutWriting() async throws {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 1)
        link.schedule(status: 2, after: pause + .seconds(1))
        let result = try #require(success(await run(link, on: clock)))
        #expect(result.wroteWiFiOn == false)
        #expect(link.count(.write(.wifiOn)) == 0)
        #expect(link.time(of: .read(.ssid)) == pause + .seconds(1))
    }

    @Test func launchingThatFallsBackToZeroIsThenWrittenTo() async throws {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 1)
        link.schedule(status: 0, after: pause + .milliseconds(500))
        link.onWrite { link in
            link.schedule(status: 1, after: .milliseconds(90))
            link.schedule(status: 2, after: .milliseconds(900))
        }
        let result = try #require(success(await run(link, on: clock)))
        #expect(result.wroteWiFiOn)
        #expect(link.time(of: .write(.wifiOn)) == pause + .milliseconds(500))
        #expect(link.time(of: .read(.ssid)) == pause + .milliseconds(1400))
    }

    @Test func terminatingWaitsForZeroAndThenWrites() async throws {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 3)
        link.schedule(status: 0, after: .seconds(2))
        link.onWrite { link in
            link.schedule(status: 1, after: .milliseconds(90))
            link.schedule(status: 2, after: .milliseconds(800))
        }
        let result = try #require(success(await run(link, on: clock)))
        #expect(result.wroteWiFiOn)
        // Not a moment before 0: a write during status 3 is untested.
        #expect(link.time(of: .write(.wifiOn)) == .seconds(2))
        #expect(link.time(of: .read(.ssid)) == .milliseconds(2800))
    }

    // MARK: The link going away

    @Test func aDropAfterTheWriteIsAnOutcomeNotAGenericError() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.onWrite { link in
            link.schedule(status: 1, after: .milliseconds(90))
            link.scheduleDrop(after: .milliseconds(200))
        }
        let outcome = await failure(run(link, on: clock))
        #expect(outcome == .linkDropped(afterWrite: true))
        #expect(link.count(.write(.wifiOn)) == 1)
    }

    @Test func aDropThatTheWriteItselfReportsCountsAsAfterTheWrite() async {
        // Unknown whether the camera got it, so the caller must not assume the Wi-Fi is off.
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.failWrite(with: .linkDropped)
        let outcome = await failure(run(link, on: clock))
        #expect(outcome == .linkDropped(afterWrite: true))
    }

    @Test func aDropBeforeTheWriteSaysSo() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.failNotify(.battery, with: .linkDropped)
        let outcome = await failure(run(link, on: clock))
        #expect(outcome == .linkDropped(afterWrite: false))
        #expect(link.count(.write(.wifiOn)) == 0)
    }

    // MARK: Network details

    @Test func aWiFiOffRefusalIsRetriedEveryTwoSecondsWhileTheStatusStaysTwo() async throws {
        // ATT 0x9D on CC06 means the Wi-Fi is off (5 Nov 02:21); the camera may need a moment after status 2.
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 2)
        link.failReads(.ssid, with: [.wifiOff, .wifiOff])
        let result = try #require(success(await run(link, on: clock)))
        #expect(link.logged.filter { $0.call == .read(.ssid) }.map(\.at) == [pause, pause + .seconds(2), pause + .seconds(4)])
        #expect(result.credentials.ssid == Cam.ssid)
    }

    @Test func theDetailsGiveUpAfterTwentySecondsOfRetries() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 2)
        link.failReads(.ssid, with: Array(repeating: .wifiOff, count: 50))
        let outcome = await failure(run(link, on: clock))
        #expect(outcome == .gatt(.wifiOff, during: .readCredentials))
        // Tries at 0, 2, ... 20 s: eleven.
        #expect(link.count(.read(.ssid)) == 11)
        #expect(clock.elapsed == pause + HandoffTiming.credentialWindow)
        #expect(link.count(.write(.wifiOn)) == 0)
    }

    @Test func readsThatTimeOutAreTriedThreeTimesWhateverTheWindow() async {
        // Each read gets its 15 s, so the 20 s window would allow one or two tries: the guided run's minimum of three holds.
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 2)
        link.delayReads(.ssid, by: .seconds(20))
        let outcome = await failure(run(link, on: clock))
        #expect(outcome == .gatt(.timedOut, during: .readCredentials))
        let tries = link.logged.filter { $0.call == .read(.ssid) }.map(\.at)
        #expect(tries == [pause, pause + .seconds(17), pause + .seconds(34)])
        #expect(clock.elapsed == pause + .seconds(49))
    }

    @Test func theMinimumOfThreeTriesEndsWhenTheStatusLeavesTwo() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 2)
        link.delayReads(.ssid, by: .seconds(20))
        link.schedule(status: 3, after: pause + .seconds(16))
        let outcome = await failure(run(link, on: clock))
        #expect(outcome == .wifiLapsed(lastStatus: .terminating))
        #expect(link.count(.read(.ssid)) == 1)
    }

    @Test func detailsThatAreNotANetworkAreRetriedThenReportedByLengthOnly() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 2)
        link.set(Data([0x01, 0x02, 0x03]), for: .ssid) // the prefix and no text
        let outcome = await failure(run(link, on: clock))
        #expect(outcome == .credentialsInvalid(.noText(.ssid, byteCount: 3)))
        #expect(!"\(String(describing: outcome))".contains("DIRECT-"))
    }

    @Test func theStatusLeavingTwoDuringTheRetriesIsALapse() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 2)
        link.failReads(.ssid, with: Array(repeating: .wifiOff, count: 50))
        link.schedule(status: 3, after: pause + .seconds(1))
        let outcome = await failure(run(link, on: clock))
        #expect(outcome == .wifiLapsed(lastStatus: .terminating))
        #expect(clock.elapsed == pause + .seconds(1))
    }

    @Test func aTimedOutReadOfTheDetailsIsRetriedToo() async throws {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 2)
        link.failReads(.passphrase, with: [.timedOut])
        let result = try #require(success(await run(link, on: clock)))
        #expect(link.count(.read(.passphrase)) == 2)
        #expect(result.credentials.passphrase == Cam.passphrase)
    }

    // MARK: Pairing problems, odd statuses, cancellation

    @Test func aRefusedBaselineReadIsNotPairedAndNothingIsWritten() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock)
        link.failReads(.status, with: [.notPaired])
        let outcome = await failure(run(link, on: clock))
        #expect(outcome == .notPaired)
        #expect(link.count(.write(.wifiOn)) == 0)
    }

    @Test func aRefusedWriteIsNotPaired() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.failWrite(with: .notPaired)
        let outcome = await failure(run(link, on: clock))
        #expect(outcome == .notPaired)
    }

    @Test func aSwitchThatTimesOutIsReportedAndTheRunGoesOn() async throws {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 2)
        link.failNotify(.battery, with: .timedOut)
        let result = try #require(success(await run(link, on: clock)))
        #expect(result.unconfirmedSwitches == [.battery])
        #expect(link.count(.notify(true, .initialSetting)) == 1)
    }

    @Test func aSwitchRefusedAsNotPairedStopsTheRun() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 2)
        link.failNotify(.media, with: .notPaired)
        let outcome = await failure(run(link, on: clock))
        #expect(outcome == .notPaired)
        #expect(link.count(.read(.status)) == 0)
    }

    @Test func statusBytesThatDontDecodeAreRefused() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock)
        link.set(Data([0x00, 0x01]), for: .status) // a zero length byte: the strict decoder refuses it
        #expect(await failure(run(link, on: clock)) == .statusUnreadable)
        #expect(link.count(.write(.wifiOn)) == 0)
    }

    @Test func aStatusWithoutTheWiFiTagIsRefused() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock)
        link.set(Data([0x03, 0x00, 0x02, 0x01]), for: .status) // tag 0x0002 only
        #expect(await failure(run(link, on: clock)) == .statusUnreadable)
        #expect(link.count(.write(.wifiOn)) == 0)
    }

    @Test func aStatusOutsideZeroToThreeIsNotGuessedAt() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 7)
        let outcome = await failure(run(link, on: clock))
        #expect(outcome == .unexpectedStatus(7))
        #expect(link.count(.write(.wifiOn)) == 0)
    }

    @Test func cancellingWhileWaitingEndsTheRunAsCancelled() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        let task = Task {
            do throws(HandoffFailure) {
                _ = try await WiFiHandoff(clock: clock).run(on: link)
                return HandoffFailure?.none
            } catch {
                return error
            }
        }
        await clock.waitUntilSomeoneSleeps() // parked in the pause after the switches
        clock.advanceToNext()
        await clock.waitUntil { sleepers, _, _ in sleepers > 0 && link.count(.write(.wifiOn)) == 1 } // parked, after the write
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(link.count(.write(.wifiOn)) == 1)
    }

    // MARK: Writing again

    @Test func rewriteDoesNotSubscribeAgainAndWritesWhenTheWiFiIsOff() async throws {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.onWrite { link in
            link.schedule(status: 1, after: .milliseconds(90))
            link.schedule(status: 2, after: .milliseconds(900))
        }
        let result = try #require(success(await run(link, on: clock, rewrite: true)))
        #expect(link.calls == [.read(.status), .write(.wifiOn), .read(.ssid), .read(.passphrase)])
        #expect(result.wroteWiFiOn)
    }

    @Test func rewriteLeavesAWiFiThatIsStillOnAlone() async throws {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 2)
        let result = try #require(success(await run(link, on: clock, rewrite: true)))
        #expect(link.count(.write(.wifiOn)) == 0)
        #expect(result.wroteWiFiOn == false)
    }

    @Test func rewriteWaitsOutTerminatingBeforeItWrites() async throws {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock, initialStatus: 3)
        link.schedule(status: 0, after: .milliseconds(1500))
        link.onWrite { $0.schedule(status: 2, after: .milliseconds(900)) }
        _ = try #require(success(await run(link, on: clock, rewrite: true)))
        #expect(link.time(of: .write(.wifiOn)) == .milliseconds(1500))
    }

    // MARK: Release

    @Test func releaseTurnsTheFiveOffInOrder() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock)
        let report = await WiFiHandoff(clock: clock).release(link)
        #expect(report.turnedOff == CameraControlCharacteristic.sonyNotificationSet)
        #expect(link.calls == [.status, .battery, .media, .pushTransfer, .initialSetting].map { .notify(false, $0) })
    }

    @Test func unknownWhileAnotherAppHoldsTheLinkIsHarmless() async {
        // Measured with Creators' App: only CC0E confirmed off; the other four came back "unknown" (code 0).
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock)
        link.setAnotherAppHoldsLink(true)
        for c in [CameraControlCharacteristic.status, .battery, .media, .pushTransfer] {
            link.failNotify(c, with: .other(0))
        }
        let report = await WiFiHandoff(clock: clock).release(link)
        #expect(report.turnedOff == [.initialSetting])
        #expect(report.leftOnHarmlessly == [.status, .battery, .media, .pushTransfer])
        #expect(report.failed.isEmpty)
    }

    @Test func unknownWithNoOtherAppIsAFailureNotAShrug() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock)
        link.failNotify(.battery, with: .other(0))
        let report = await WiFiHandoff(clock: clock).release(link)
        #expect(report.failed == [.battery: .other(0)])
        #expect(report.leftOnHarmlessly.isEmpty)
        #expect(report.turnedOff.count == 4)
    }

    @Test func aDropEndsTheReleaseWithoutTryingTheRest() async {
        let clock = ManualClock()
        let link = FakeGATTLink(clock: clock)
        link.failNotify(.media, with: .linkDropped)
        let report = await WiFiHandoff(clock: clock).release(link)
        #expect(report.turnedOff == [.status, .battery])
        #expect(report.notTried == [.media, .pushTransfer, .initialSetting])
    }
}
