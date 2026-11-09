import BLEKit
import Foundation
import Testing
@testable import CameraTransport

/// The stay after an import and the leave: one 3-minute timer from the end of the import, in front only; the Bluetooth link
/// kept up and the stay ended when it can't be restored within 60 s; leaving at once in the background; a second import
/// inside the stay with no join; Wi-Fi retried for 30 s before Bluetooth (Shamil, 8 and 9 Nov; backlog section 8).
///
/// Where the stay's timer runs, `drive` moves the clock while the test waits for a phase; a moment the test acts at is a gate
/// registered on the clock before the stay starts, so the driver can never move past it.
@Suite("Wireless session: stay and leave", .timeLimit(.minutes(1)))
struct WirelessStayTests {
    private let fiveOn = CameraControlCharacteristic.sonyNotificationSet.map { Call.notify(true, $0) }
    private let fiveOff = CameraControlCharacteristic.sonyNotificationSet.map { Call.notify(false, $0) }

    /// The default rig joined and ready: the session opened at 1.5 s (the gateway's 1.5 s after an immediate `apply`).
    private func joinedRig() async throws -> (Rig, StubLink) {
        let rig = Rig()
        let link = try #require(opened(await rig.prepare()))
        return (rig, link)
    }

    // MARK: The stay

    @Test func theStayEndsThreeMinutesAfterTheImportAndLeaves() async throws {
        let (rig, link) = try await joinedRig()
        let end = rig.clock.elapsed
        await drive(rig.clock) {
            await rig.session.importFinished()
            await rig.phases.waitFor(.idle, times: 2)
        }
        #expect(await link.closeCount == 1)
        #expect(rig.joiner.leaveTimes == [end + WirelessTiming.stay])
        #expect(rig.joiner.leftNetworks == [Cam.ssid])
        #expect(Array(rig.phases.all.suffix(4)) == [.ready, .staying, .leaving, .idle])
        // In the stay the session is already closed, so: the configuration, the notifications, the link.
        #expect(rig.journal.all == ["close session", "leave network", "notifications off"])
        #expect(Array(rig.link.calls.suffix(6)) == fiveOff + [.disconnect])
        #expect(rig.link.count(.write(.wifiOn)) == 0)
        #expect(await rig.session.network == nil)
    }

    @Test func aSecondImportInsideTheStayReopensWithNoJoin() async throws {
        let (rig, first) = try await joinedRig()
        let end = rig.clock.elapsed
        let session = rig.session
        let second: Int? = await drive(rig.clock) {
            let oneMinuteIn = rig.clock.gate(at: end + .seconds(60))
            await session.importFinished()
            await oneMinuteIn.wait()
            return (try? await session.prepareImport() as? StubLink)?.number
        }
        #expect(second == 2)
        #expect(await first.closeCount == 1)
        #expect(rig.opener.reopenings == [false, true])
        #expect(rig.opener.times == [.milliseconds(1_500), end + .seconds(60)])
        #expect(rig.connector.count == 1)
        #expect(rig.handoff.calls.count == 1)
        #expect(rig.joiner.applyTimes.count == 1)
        #expect(await session.phase == .ready)
        // The stay's timer is gone with the stay: nothing is left sleeping on the clock.
        await rig.clock.waitUntil { sleepers, _, _ in sleepers == 0 }
        #expect(rig.joiner.leaveTimes.isEmpty)
    }

    @Test func goingToTheBackgroundDuringTheStayLeavesAtOnce() async throws {
        let (rig, _) = try await joinedRig()
        let end = rig.clock.elapsed
        await rig.session.importFinished()
        #expect(await rig.session.phase == .staying)
        await rig.session.appMovedToBackground()
        #expect(await rig.session.phase == .idle)
        #expect(rig.joiner.leaveTimes == [end])
        #expect(rig.link.calls.last == .disconnect)
    }

    @Test func anImportFinishingInTheBackgroundLeavesAsItsLastStep() async throws {
        let (rig, link) = try await joinedRig()
        let end = rig.clock.elapsed
        rig.foreground.set(false)
        await rig.session.importFinished()
        #expect(await rig.session.phase == .idle)
        #expect(await link.closeCount == 1)
        #expect(rig.joiner.leaveTimes == [end])
        #expect(!rig.phases.all.contains(.staying))
    }

    @Test func goingToTheBackgroundDuringTheImportKeepsEverything() async throws {
        let (rig, link) = try await joinedRig()
        await rig.session.appMovedToBackground()
        #expect(await rig.session.phase == .ready)
        #expect(await link.closeCount == 0)
        #expect(rig.joiner.leaveTimes.isEmpty)
    }

    @Test func aReturnToTheFrontAfterTheStayRanOutLeavesOnce() async throws {
        // Whether the stay's own timer or the return to the front gets there first, the session leaves exactly once.
        let (rig, _) = try await joinedRig()
        await rig.session.importFinished()
        rig.clock.advance(by: .seconds(200))
        await rig.session.appBecameActive()
        await rig.phases.waitFor(.idle, times: 2)
        #expect(rig.joiner.leaveTimes.count == 1)
        #expect(await rig.session.phase == .idle)
    }

    @Test func theStaysRemainingTimeIsWorkedOutWhenAsked() async throws {
        let (rig, _) = try await joinedRig()
        let end = rig.clock.elapsed
        #expect(await rig.session.stayRemaining == nil)
        let session = rig.session
        let (remaining, first): (Duration?, WirelessPhase?) = await drive(rig.clock) {
            let hundredSecondsIn = rig.clock.gate(at: end + .seconds(100))
            await session.importFinished()
            await hundredSecondsIn.wait()
            var late = session.phases.makeAsyncIterator() // a screen that subscribes 100 s into the stay
            return (await session.stayRemaining, await late.next())
        }
        #expect(remaining == .seconds(80))
        #expect(first == .staying)
        await rig.session.leave()
        #expect(await rig.session.stayRemaining == nil)
    }

    @Test func anImportEndingAsTheAppGoesToTheBackgroundLeaves() async throws {
        // The scene goes to the background while the session reads `isInForeground`, which had already said yes: the
        // change wins, so no stay starts in the background.
        let (rig, _) = try await joinedRig()
        let end = rig.clock.elapsed
        let session = rig.session
        rig.foreground.onNextRead { await session.appMovedToBackground() }
        await session.importFinished()
        #expect(await session.phase == .idle)
        #expect(rig.joiner.leaveTimes == [end])
        #expect(!rig.phases.all.contains(.staying))
    }

    @Test func importFinishedDoesNothingUnlessReady() async throws {
        let rig = Rig()
        await rig.session.importFinished()
        #expect(await rig.session.phase == .idle)
        #expect(rig.joiner.leaveTimes.isEmpty)
    }

    // MARK: The Bluetooth link during the stay

    @Test func aLinkThatDropsDuringTheStayIsReconnected() async throws {
        let (rig, _) = try await joinedRig()
        let second = rig.anotherLink()
        rig.connector.enqueue([.success(second)])
        let end = rig.clock.elapsed
        await drive(rig.clock) {
            rig.link.scheduleDrop(after: .seconds(30))
            await rig.session.importFinished()
            await rig.phases.waitFor(.idle, times: 2)
        }
        #expect(rig.connector.times == [.zero, end + .seconds(30)])
        #expect(rig.connector.knownArguments == [rig.peripheral, rig.peripheral])
        #expect(rig.link.calls.last == .disconnect)
        // The new link gets Sony's notifications, as in the 785 s stay, and is the one released at the end.
        #expect(second.calls == fiveOn + fiveOff + [.disconnect])
        #expect(rig.joiner.leaveTimes == [end + WirelessTiming.stay])
    }

    @Test func aLinkThatCantBeRestoredEndsTheStaySixtySecondsAfterTheDrop() async throws {
        let (rig, _) = try await joinedRig()
        let end = rig.clock.elapsed
        await drive(rig.clock) {
            rig.link.scheduleDrop(after: .seconds(30))
            await rig.session.importFinished()
            await rig.phases.waitFor(.idle, times: 2)
        }
        let tries = stride(from: 30, through: 85, by: 5).map { end + .seconds($0) }
        #expect(rig.connector.times == [.zero] + tries)
        #expect(rig.joiner.leaveTimes == [end + .seconds(30) + WirelessTiming.linkDownStayLimit])
        #expect(rig.journal.all == ["close session", "leave network"])
    }

    @Test func aLinkThatDropsAtOnceDoesntResetTheSixtySeconds() async throws {
        let (rig, _) = try await joinedRig()
        // Every reconnect gives a link that has already dropped again.
        let flaky = (0..<20).map { _ in rig.anotherLink() }
        for link in flaky { link.drop(.linkDropped) }
        rig.connector.enqueue(flaky.map { .success($0) })
        let end = rig.clock.elapsed
        await drive(rig.clock) {
            rig.link.scheduleDrop(after: .seconds(30))
            await rig.session.importFinished()
            await rig.phases.waitFor(.idle, times: 2)
        }
        let tries = stride(from: 30, through: 85, by: 5).map { end + .seconds($0) }
        #expect(rig.connector.times == [.zero] + tries)
        #expect(rig.joiner.leaveTimes == [end + .seconds(30) + WirelessTiming.linkDownStayLimit])
    }

    @Test func aLinkThatDroppedDuringTheImportIsReconnectedWhenTheStayStarts() async throws {
        let (rig, _) = try await joinedRig()
        let second = rig.anotherLink()
        rig.connector.enqueue([.success(second)])
        rig.link.drop(.linkDropped)
        let end = rig.clock.elapsed
        await drive(rig.clock) {
            await rig.session.importFinished()
            await rig.phases.waitFor(.idle, times: 2)
        }
        #expect(rig.connector.times == [.zero, end])
        #expect(rig.joiner.leaveTimes == [end + WirelessTiming.stay])
        #expect(second.calls.last == .disconnect)
    }

    // MARK: Inside the stay, back to Bluetooth

    @Test func aSessionThatWontReopenIsRetriedOnWiFiForThirtySecondsThenBluetooth() async throws {
        let (rig, _) = try await joinedRig()
        let end = rig.clock.elapsed
        rig.opener.script(Array(repeating: CameraLinkFailure(.disconnected), count: 31), fallback: .some(nil))
        let session = rig.session
        let reopened: Int? = await drive(rig.clock) {
            let oneMinuteIn = rig.clock.gate(at: end + .seconds(60))
            await session.importFinished()
            await oneMinuteIn.wait()
            return (try? await session.prepareImport() as? StubLink)?.number
        }
        #expect(reopened == 2)
        let start = end + .seconds(60)
        let times = rig.opener.times
        #expect(times.count == 33)
        #expect(Array(times[1...31]) == (0...30).map { start + .seconds($0) })
        // Shamil, 9 Nov: Bluetooth only after 30 s on Wi-Fi; the held link is used, so no new connection.
        #expect(rig.handoff.calls.map(\.at) == [.zero, start + WirelessTiming.wifiRetryBeforeBluetooth])
        #expect(rig.connector.count == 1)
        #expect(rig.joiner.applyTimes == [.zero, start + .seconds(30)])
        // Reopens on Wi-Fi; the open after the hand-off that switched the camera's Wi-Fi on again is a fresh one.
        #expect(rig.opener.reopenings == [false] + Array(repeating: true, count: 31) + [false])
        #expect(rig.joiner.leaveTimes.isEmpty)
    }

    @Test func aHandoffThatFindsTheWiFiStillOnKeepsTheReopen() async throws {
        let (rig, _) = try await joinedRig()
        let end = rig.clock.elapsed
        rig.opener.script(Array(repeating: CameraLinkFailure(.disconnected), count: 31), fallback: .some(nil))
        rig.handoff.script([.init(statusTwoAgo: .seconds(5))]) // status 2 already: no CC08 written
        let session = rig.session
        let reopened: Int? = await drive(rig.clock) {
            let oneMinuteIn = rig.clock.gate(at: end + .seconds(60))
            await session.importFinished()
            await oneMinuteIn.wait()
            return (try? await session.prepareImport() as? StubLink)?.number
        }
        #expect(reopened == 2)
        #expect(rig.handoff.calls.count == 2)
        #expect(rig.opener.reopenings == [false] + Array(repeating: true, count: 32))
    }

    @Test func aRefusedReopenLeaves() async throws {
        let (rig, _) = try await joinedRig()
        let end = rig.clock.elapsed
        rig.opener.script([CameraLinkFailure(.identityChanged)])
        let session = rig.session
        let result: WirelessFailure? = await drive(rig.clock) {
            let oneMinuteIn = rig.clock.gate(at: end + .seconds(60))
            await session.importFinished()
            await oneMinuteIn.wait()
            do throws(WirelessFailure) {
                _ = try await session.prepareImport()
                return nil
            } catch {
                return error
            }
        }
        #expect(result == .link(CameraLinkFailure(.identityChanged)))
        #expect(rig.joiner.leaveTimes == [end + .seconds(60)])
        #expect(await session.phase == .idle)
    }

    @Test func aPhoneMovedOffTheNetworkLongerThanTheCamerasFiftySecondsGoesToBluetoothAtOnce() async throws {
        let (rig, first) = try await joinedRig()
        await rig.session.appMovedToBackground() // a paused import, still joined
        rig.clock.advance(by: .seconds(60))
        rig.path.setCurrent(nil) // iOS moved the phone off the camera's network meanwhile
        await rig.session.appBecameActive()
        _ = try #require(opened(await rig.prepare()))
        // No Wi-Fi retry: straight to the hand-off, which switched the camera's Wi-Fi on again, so the open is a fresh one.
        #expect(rig.opener.reopenings == [false, false])
        #expect(rig.handoff.calls.count == 2)
        #expect(rig.joiner.applyTimes.count == 2)
        #expect(await first.closeCount == 1)
    }

    @Test func aPhoneMovedOffTheNetworkWithinTheCamerasFiftySecondsTriesWiFiFirst() async throws {
        let (rig, _) = try await joinedRig()
        await rig.session.appMovedToBackground()
        rig.clock.advance(by: .seconds(40))
        rig.path.setCurrent(nil)
        await rig.session.appBecameActive()
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.opener.reopenings == [false, true])
        #expect(rig.handoff.calls.count == 1)
        #expect(rig.joiner.applyTimes.count == 1)
    }

    // MARK: Leave

    @Test func leavingDuringTheImportClosesTheSessionFirst() async throws {
        let (rig, link) = try await joinedRig()
        await rig.session.leave()
        #expect(await link.closeCount == 1)
        #expect(rig.journal.all == ["close session", "leave network", "notifications off"])
        #expect(Array(rig.link.calls.suffix(6)) == fiveOff + [.disconnect])
        #expect(await rig.session.phase == .idle)
        #expect(await rig.session.network == nil)
        // A second leave finds nothing to do.
        await rig.session.leave()
        #expect(rig.joiner.leaveTimes.count == 1)
    }

    @Test func leavingWhileIdleDoesNothing() async throws {
        let rig = Rig()
        await rig.session.leave()
        #expect(rig.journal.all.isEmpty)
        #expect(rig.link.calls.isEmpty)
        #expect(await rig.session.phase == .idle)
    }

    @Test func leavingAPauseReturnsToIdle() async throws {
        let rig = Rig()
        rig.foreground.set(false)
        _ = await rig.prepare()
        await rig.session.leave()
        #expect(await rig.session.phase == .idle)
        #expect(rig.journal.all.isEmpty)
    }

    @Test func everyPhaseStreamStartsWithTheCurrentPhase() async throws {
        let (rig, _) = try await joinedRig()
        var iterator = rig.session.phases.makeAsyncIterator()
        #expect(await iterator.next() == .ready)
    }
}
