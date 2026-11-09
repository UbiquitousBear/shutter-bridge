import BLEKit
import Foundation
import Testing
@testable import CameraTransport

/// The session's part of the Wi-Fi recovery (W14; backlog section 9): during an import whose session went, reopen on Wi-Fi
/// for 30 s, then, in front, Bluetooth and the join at status 2 with no second fixed wait (the 4 Nov 01:08 run replayed);
/// with the app away, never join: switch the camera's Wi-Fi on over Bluetooth when allowed and wait for iOS to rejoin by
/// itself, else pause with `.needsJoin` (B:211).
///
/// Every wait is on the rig's virtual clock, moved by `drive` only while the session is parked on it.
@Suite("Wireless session: recovery", .timeLimit(.minutes(1)))
struct WirelessRecoveryTests {
    /// The default rig joined, with the import running on its session (opened at 1.5 s), and the moment the session is
    /// lost, 100 s into the import.
    private func importingRig() async throws -> (rig: Rig, first: StubLink, lostAt: Duration) {
        let rig = Rig()
        let first = try #require(opened(await rig.prepare()))
        rig.clock.advance(by: .seconds(100))
        return (rig, first, rig.clock.elapsed)
    }

    // MARK: In front

    /// 4 Nov 01:08 (backlog section 9): the camera dropped its card and, about 6 s later, its Wi-Fi. The spike got the copy
    /// back 97 s after the failure: 30 s probing the port, Bluetooth (status 0, CC08, status 2 about 2.6 s later), a fixed
    /// 30 s wait for iOS to rejoin, then the join (`apply` 9.1 s, no prompt). 1.0 keeps the first wait and joins at once.
    @Test func the0108RecoveryJoinsAtStatusTwoWithoutTheSecondThirtySecondWait() async throws {
        let (rig, first, lostAt) = try await importingRig()
        rig.opener.script(Array(repeating: CameraLinkFailure(.disconnected), count: 31), fallback: .some(nil))
        // Bluetooth connect 0.52 s, status 0, CC08, status 2 2.6 s after the write: about 3.1 s.
        rig.handoff.script([.init(delay: .milliseconds(3_100))])
        rig.joiner.script([.init(delay: .milliseconds(9_100))])
        // The gateway 0.4 s after `apply` returned (9.5 s after the call, as measured).
        rig.path.script([.after(.milliseconds(400))])

        let reopened = try #require(opened(await rig.recover(bluetoothSwitchOnWhenAway: true)))
        #expect(reopened.number == 2)
        #expect(await first.closeCount == 1)

        // 31 tries on Wi-Fi, one a second, as the 30 s before Bluetooth (Shamil, 9 Nov).
        let tries = Array(rig.opener.times.dropFirst())
        #expect(tries.count == 32)
        #expect(Array(tries.prefix(31)) == (0...30).map { lostAt + .seconds($0) })
        let bluetoothAt = lostAt + WiFiRecoveryTiming.waitBeforeBluetooth
        #expect(rig.handoff.calls.map(\.at) == [.zero, bluetoothAt])
        // The held Bluetooth link is used: no new connection.
        #expect(rig.connector.count == 1)
        // `apply` the moment the hand-off returns with status 2: no fixed wait for iOS to rejoin.
        let statusTwoAt = bluetoothAt + .milliseconds(3_100)
        #expect(rig.joiner.applyTimes == [.zero, statusTwoAt])
        #expect(Array(rig.path.waitTimes.dropFirst()) == [statusTwoAt + .milliseconds(9_100)])
        let openedAt = statusTwoAt + .milliseconds(9_500)
        #expect(tries.last == openedAt)
        // 42.6 s from the failure to the session, against the spike's 97 s.
        #expect(openedAt - lostAt == .milliseconds(42_600))
        // The hand-off wrote CC08, so the camera starts its contents mode again: a fresh open.
        #expect(rig.opener.reopenings.last == false)
        #expect(await rig.session.phase == .ready)
        #expect(await rig.session.network == Cam.ssid)
        #expect(rig.joiner.leaveTimes.isEmpty)
    }

    @Test func aSessionThatReopensOnWiFiNeedsNoBluetooth() async throws {
        let (rig, first, lostAt) = try await importingRig()
        rig.opener.script(Array(repeating: CameraLinkFailure(.disconnected), count: 4), fallback: .some(nil))
        let reopened = try #require(opened(await rig.recover(bluetoothSwitchOnWhenAway: true)))
        #expect(reopened.number == 2)
        #expect(await first.closeCount == 1)
        #expect(rig.opener.times.last == lostAt + .seconds(4))
        #expect(rig.opener.reopenings.last == true)
        #expect(rig.handoff.calls.count == 1)
        #expect(rig.joiner.applyTimes.count == 1)
    }

    // MARK: With the app away

    @Test func awayTheWiFiIsSwitchedOnOverBluetoothAndIOSRejoinsByItself() async throws {
        let (rig, _, lostAt) = try await importingRig()
        rig.foreground.set(false)
        rig.opener.script(Array(repeating: CameraLinkFailure(.disconnected), count: 31), fallback: .some(nil))
        rig.handoff.script([.init(delay: .milliseconds(3_100))])
        rig.path.script([.after(.seconds(12))])

        let reopened = try #require(opened(await rig.recover(bluetoothSwitchOnWhenAway: true)))
        #expect(reopened.number == 2)
        let bluetoothAt = lostAt + WiFiRecoveryTiming.waitBeforeBluetooth
        #expect(rig.handoff.calls.map(\.at) == [.zero, bluetoothAt])
        // Never `apply` from the background: only the first join's.
        #expect(rig.joiner.applyTimes == [.zero])
        // iOS is given 30 s to rejoin from status 2 (well inside the camera's 50 s).
        let statusTwoAt = bluetoothAt + .milliseconds(3_100)
        #expect(Array(rig.path.waitTimes.dropFirst()) == [statusTwoAt])
        #expect(Array(rig.path.waitTimeouts.dropFirst()) == [WiFiRecoveryTiming.rejoinWhileAway])
        #expect(rig.opener.times.last == statusTwoAt + .seconds(12))
        #expect(rig.opener.reopenings.last == false)
        #expect(await rig.session.phase == .ready)
        #expect(await rig.session.network == Cam.ssid)
        #expect(rig.joiner.leaveTimes.isEmpty)
    }

    @Test func awayWithNoRejoinThePreparationPausesForAJoin() async throws {
        let (rig, first, lostAt) = try await importingRig()
        rig.foreground.set(false)
        rig.opener.script([], fallback: .some(CameraLinkFailure(.disconnected)))
        rig.path.script([.never])

        #expect(failure(await rig.recover(bluetoothSwitchOnWhenAway: true)) == .paused(.needsJoin))
        #expect(await rig.session.phase == .paused(.needsJoin))
        #expect(rig.joiner.applyTimes == [.zero])
        let bluetoothAt = lostAt + WiFiRecoveryTiming.waitBeforeBluetooth
        #expect(rig.handoff.calls.map(\.at) == [.zero, bluetoothAt])
        #expect(Array(rig.path.waitTimeouts.dropFirst()) == [WiFiRecoveryTiming.rejoinWhileAway])
        // As every pause: nothing held (W11). The configuration goes 30 s after the hand-off.
        #expect(rig.joiner.leaveTimes == [bluetoothAt + WiFiRecoveryTiming.rejoinWhileAway])
        #expect(await first.closeCount == 1)
        #expect(rig.link.calls.last == .disconnect)
        #expect(await rig.session.network == nil)
    }

    @Test func awayTheRejoinWaitEndsWithTheCamerasFiftySeconds() async throws {
        let (rig, _, lostAt) = try await importingRig()
        rig.foreground.set(false)
        rig.opener.script([], fallback: .some(CameraLinkFailure(.disconnected)))
        // CC09 already read 2, seen 45 s before the hand-off returned: 5 s of the camera's 50 s left, so no write.
        rig.handoff.script([.init(statusTwoAgo: .seconds(45))])
        rig.path.script([.never])

        #expect(failure(await rig.recover(bluetoothSwitchOnWhenAway: true)) == .paused(.needsJoin))
        #expect(Array(rig.path.waitTimeouts.dropFirst()) == [.seconds(5)])
        #expect(rig.joiner.leaveTimes == [lostAt + WiFiRecoveryTiming.waitBeforeBluetooth + .seconds(5)])
    }

    @Test(arguments: [false, true])
    func awayWithoutTheSwitchOnItPausesAfterTheThirtySecondsOnWiFi(_ plainPrepare: Bool) async throws {
        let (rig, _, lostAt) = try await importingRig()
        rig.foreground.set(false)
        rig.opener.script([], fallback: .some(CameraLinkFailure(.disconnected)))
        let result = plainPrepare ? await rig.prepare() : await rig.recover(bluetoothSwitchOnWhenAway: false)
        #expect(failure(result) == .paused(.needsJoin))
        // No Bluetooth beyond the first join's, no `apply`.
        #expect(rig.handoff.calls.count == 1)
        #expect(rig.joiner.applyTimes == [.zero])
        #expect(rig.joiner.leaveTimes == [lostAt + WiFiRecoveryTiming.waitBeforeBluetooth])
    }

    @Test func awayTheSwitchOnNeedsTheNetworksSavedConfiguration() async throws {
        // Nothing joined yet (no configuration saved for iOS to rejoin): a join is needed, so it pauses before Bluetooth.
        let rig = Rig()
        rig.foreground.set(false)
        #expect(failure(await rig.recover(bluetoothSwitchOnWhenAway: true)) == .paused(.needsJoin))
        #expect(rig.connector.count == 0)
        #expect(rig.handoff.calls.isEmpty)
    }

    @Test func awayABluetoothFailureIsReportedAsItIs() async throws {
        let (rig, _, _) = try await importingRig()
        rig.foreground.set(false)
        rig.opener.script([], fallback: .some(CameraLinkFailure(.disconnected)))
        rig.handoff.script([.init(failure: .notPaired)])
        #expect(failure(await rig.recover(bluetoothSwitchOnWhenAway: true)) == .paused(.notPaired))
        #expect(rig.joiner.applyTimes == [.zero])
        #expect(rig.path.waitTimes.count == 1)
    }
}

extension Rig {
    /// `prepareImport(bluetoothSwitchOnWhenAway:)` with the clock driven until it returns.
    func recover(bluetoothSwitchOnWhenAway: Bool) async -> Result<any CameraLink, WirelessFailure> {
        let session = self.session
        return await drive(clock) {
            do throws(WirelessFailure) {
                return .success(try await session.prepareImport(bluetoothSwitchOnWhenAway: bluetoothSwitchOnWhenAway))
            } catch {
                return .failure(error)
            }
        }
    }
}
