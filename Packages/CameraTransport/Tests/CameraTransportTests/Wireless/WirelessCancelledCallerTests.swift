import BLEKit
import Foundation
import Synchronization
import Testing
@testable import CameraTransport

/// A hand-off whose `release` (part of every leave) waits until the test opens `gate`: a leave held in progress, as a
/// slow Bluetooth release (five notification switches, each with its own time limit) holds one on the bench.
private final class SlowReleaseHandoff: WiFiHandingOff {
    let base: FakeHandoff
    let gate = Gate()
    private let count = Mutex(0)
    var releases: Int { count.withLock { $0 } }
    init(base: FakeHandoff) { self.base = base }
    func run(on link: any GATTLink) async throws(HandoffFailure) -> HandoffResult { try await base.run(on: link) }
    func rewriteIfLapsed(on link: any GATTLink) async throws(HandoffFailure) -> HandoffResult {
        try await base.rewriteIfLapsed(on: link)
    }
    func release(_ link: any GATTLink) async -> ReleaseReport {
        count.withLock { $0 += 1 }
        await gate.wait()
        return await base.release(link)
    }
}

/// Bench 22.1, from the review of the fix: the app's connection asks the session to leave when the person leaves Browse,
/// but a `prepareImport` that was waiting for a leave already under way began its preparation after that leave had found
/// nothing to stop, and ran the whole Bluetooth hand-off and join with nobody waiting. A cancelled caller now starts none.
@Suite("Wireless session: a cancelled caller starts no preparation")
struct WirelessCancelledCallerTests {
    @Test func aCallerCancelledWhileALeaveRunsStartsNoPreparation() async throws {
        let clock = VirtualClock()
        let journal = Journal()
        let peripheral = PeripheralID(UUID())
        let gatt = FakeGATTLink(clock: clock, initialStatus: 2, peripheral: peripheral)
        let connector = ScriptedConnector(clock: clock, [.success(gatt)])
        let joiner = FakeJoiner(clock: clock, journal: journal)
        let base = FakeHandoff(clock: clock, journal: journal)
        let handoff = SlowReleaseHandoff(base: base)
        let opener = LinkOpener(clock: clock, journal: journal)
        let session = WirelessSession(
            camera: WirelessCamera(peripheral: peripheral),
            connector: connector, joiner: joiner, path: FakePath(clock: clock), foreground: FakeForeground(),
            openLink: { (reopening: Bool) async throws(CameraLinkFailure) -> any CameraLink in
                try await opener.open(reopening: reopening)
            },
            clock: clock, handoff: handoff)
        let phases = PhaseLog(session.phases)
        let first: Result<any CameraLink, WirelessFailure> = await drive(clock) {
            do throws(WirelessFailure) { return .success(try await session.prepareImport()) } catch { return .failure(error) }
        }
        #expect(opened(first) != nil)

        // A leave begins and is held in its Bluetooth release.
        let leaving = Task { await session.leave() }
        await phases.waitFor(.leaving)
        for _ in 0 ..< 400 where handoff.releases == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(handoff.releases == 1)

        // A connection asks for the camera meanwhile, as the app's source does, and is stopped before the leave ends.
        connector.enqueue([.success(FakeGATTLink(clock: clock, initialStatus: 2, peripheral: peripheral))])
        let connect = Task { () -> Result<any CameraLink, WirelessFailure> in
            await withTaskCancellationHandler {
                do throws(WirelessFailure) {
                    return .success(try await session.prepareImport())
                } catch {
                    return .failure(error)
                }
            } onCancel: {
                Task { await session.leave() }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        connect.cancel()
        try await Task.sleep(for: .milliseconds(100))
        handoff.gate.open()
        await drive(clock) { await leaving.value }
        let result = await drive(clock) { await connect.value }

        if case .failure(.cancelled) = result {} else { Issue.record("expected .cancelled, got \(result)") }
        #expect(connector.count == 1, "no second Bluetooth connection")
        #expect(base.kinds.count == 1, "no second hand-off")
        #expect(joiner.applyTimes.count == 1, "no second join")
        #expect(await session.phase == .idle)
    }

    /// Fourth review: the app stops a connection during its hand-off (the person left Browse), and while that preparation
    /// is still letting go the Wi-Fi recovery's Try Again asks for the camera. It gets a preparation of its own, not the
    /// stopped one's `.cancelled`.
    @Test func aCallerArrivingWhileALeaveStopsThePreparationGetsAFreshOne() async throws {
        let clock = VirtualClock()
        let journal = Journal()
        let peripheral = PeripheralID(UUID())
        let connector = ScriptedConnector(clock: clock, [
            .success(FakeGATTLink(clock: clock, initialStatus: 2, peripheral: peripheral)),
            .success(FakeGATTLink(clock: clock, initialStatus: 2, peripheral: peripheral)),
        ])
        let joiner = FakeJoiner(clock: clock, journal: journal)
        let base = FakeHandoff(clock: clock, journal: journal,
                               steps: [FakeHandoff.Step(delay: .seconds(20)), FakeHandoff.Step()])
        let handoff = SlowReleaseHandoff(base: base)
        let opener = LinkOpener(clock: clock, journal: journal)
        let session = WirelessSession(
            camera: WirelessCamera(peripheral: peripheral),
            connector: connector, joiner: joiner, path: FakePath(clock: clock), foreground: FakeForeground(),
            openLink: { (reopening: Bool) async throws(CameraLinkFailure) -> any CameraLink in
                try await opener.open(reopening: reopening)
            },
            clock: clock, handoff: handoff)
        let phases = PhaseLog(session.phases)
        // The app's connection, as WiFiCameraSource.open(_:) makes it, stopped during its hand-off.
        let stopped = Task { () -> Result<any CameraLink, WirelessFailure> in
            await withTaskCancellationHandler {
                do throws(WirelessFailure) {
                    return .success(try await session.prepareImport())
                } catch {
                    return .failure(error)
                }
            } onCancel: {
                Task { await session.leave() }
            }
        }
        await phases.waitFor(.handingOff)
        stopped.cancel()
        for _ in 0 ..< 400 where handoff.releases == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(handoff.releases == 1, "the stopped preparation is letting go")
        // The recovery's reopen arrives while it does.
        let recovery = Task { () -> Result<any CameraLink, WirelessFailure> in
            do throws(WirelessFailure) {
                return .success(try await session.prepareImport(bluetoothSwitchOnWhenAway: true))
            } catch {
                return .failure(error)
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        handoff.gate.open()
        let first = await drive(clock) { await stopped.value }
        let second = await drive(clock) { await recovery.value }

        if case .failure(.cancelled) = first {} else { Issue.record("the stopped preparation: \(first)") }
        #expect(opened(second) != nil, "the recovery got \(second)")
        #expect(connector.count == 2, "a fresh Bluetooth connection for the recovery")
        #expect(base.kinds.count == 2)
    }
}
