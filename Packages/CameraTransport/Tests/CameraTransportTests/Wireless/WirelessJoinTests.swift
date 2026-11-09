import BLEKit
import Foundation
import Testing
@testable import CameraTransport

/// The join: hand-off, `apply` at once, the gateway, the camera's 50 s, retries, pauses and the port, on a virtual clock (no
/// real waits). Timelines are the spike's: `apply` 7.3 to 9.1 s with the prompt, the gateway 1 to 2 s after it, the 12:34
/// join that returned without joining (backlog section 8).
@Suite("Wireless session: join", .timeLimit(.minutes(1)))
struct WirelessJoinTests {
    private let fiveOff = CameraControlCharacteristic.sonyNotificationSet.map { Call.notify(false, $0) }

    // MARK: The proven order

    @Test func joinsInTheSpikesOrder() async throws {
        let rig = Rig()
        rig.joiner.script([.init(delay: .seconds(8))]) // iOS's prompt, accepted after 8 s
        let link = try #require(opened(await rig.prepare()))

        #expect(rig.connector.knownArguments == [rig.peripheral])
        #expect(rig.handoff.kinds == [.run])
        // `apply` as soon as the hand-off returns, which is as soon as status 2 is in and the details read.
        #expect(rig.joiner.applyTimes == [.zero])
        #expect(rig.joiner.appliedNetworks == [Cam.ssid])
        #expect(rig.path.waitTimes == [.seconds(8)])
        #expect(rig.path.waitTimeouts == [WirelessTiming.gatewayWait])
        #expect(rig.opener.times == [.milliseconds(9_500)])
        #expect(rig.opener.reopenings == [false])
        #expect(link.number == 1)
        // The gateway came, so the camera wasn't looked at again.
        #expect(rig.link.count(.read(.status)) == 0)
        await rig.phases.waitFor(.ready)
        #expect(rig.phases.all == [.idle, .handingOff, .joining, .openingSession, .ready])
        #expect(await rig.session.phase == .ready)
        #expect(await rig.session.network == Cam.ssid)
        #expect(await rig.session.peripheral == rig.peripheral)
        #expect(rig.joiner.leaveTimes.isEmpty)
    }

    @Test func withNoStoredPeripheralTheConnectorScansAndThePeripheralIsKept() async throws {
        let rig = Rig(knownPeripheral: false)
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.connector.knownArguments == [nil])
        #expect(await rig.session.peripheral == rig.peripheral)
    }

    @Test func theRealHandoffAppliesTheMomentStatusTwoArrives() async throws {
        // The public initialiser with the real `WiFiHandoff`: status 0, CC08 written after the spike's 1 s pause, status 1 at
        // +0.09 s and 2 at +0.84 s (the typical timeline); `apply` follows the details' reads at once.
        let clock = VirtualClock()
        let journal = Journal()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.onWrite { link in
            link.schedule(status: 1, after: .milliseconds(90))
            link.schedule(status: 2, after: .milliseconds(840))
        }
        let joiner = FakeJoiner(clock: clock, journal: journal)
        let opener = LinkOpener(clock: clock, journal: journal)
        let session = WirelessSession(
            camera: WirelessCamera(peripheral: nil),
            connector: ScriptedConnector(clock: clock, [.success(link)]),
            joiner: joiner, path: FakePath(clock: clock), foreground: FakeForeground(),
            openLink: { (reopening: Bool) async throws(CameraLinkFailure) -> any CameraLink in
                try await opener.open(reopening: reopening)
            },
            clock: clock)
        let result: Result<any CameraLink, WirelessFailure> = await drive(clock) {
            do throws(WirelessFailure) { return .success(try await session.prepareImport()) } catch { return .failure(error) }
        }
        _ = try #require(opened(result))
        let statusTwo = HandoffTiming.afterSubscribe + .milliseconds(840)
        #expect(joiner.applyTimes == [statusTwo])
        #expect(link.count(.write(.wifiOn)) == 1)

        // Leaving writes nothing over Bluetooth (B:188): the five switches go off and the link closes.
        await session.leave()
        #expect(link.count(.write(.wifiOn)) == 1)
        #expect(Array(link.calls.suffix(6)) == fiveOff + [.disconnect])
        #expect(joiner.leftNetworks == [Cam.ssid])
    }

    // MARK: The camera's 50 s, counted from status 2

    /// Status 0, the write at 1 s and status 2 at 3.7 s (+2.7 s, the slowest measured): the camera's 50 s end at 53.7 s,
    /// not at 51 s, as they would counted from the write.
    private func realHandoffRig(applyReturnsAt: Duration) -> (VirtualClock, FakeGATTLink, FakeJoiner, FakePath, WirelessSession) {
        let clock = VirtualClock()
        let journal = Journal()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.onWrite { link in
            link.schedule(status: 1, after: .milliseconds(100))
            link.schedule(status: 2, after: .milliseconds(2_700))
        }
        let statusTwo = HandoffTiming.afterSubscribe + .milliseconds(2_700)
        let joiner = FakeJoiner(clock: clock, journal: journal, steps: [.init(delay: applyReturnsAt - statusTwo)])
        let path = FakePath(clock: clock, fallback: .after(.seconds(1)))
        let opener = LinkOpener(clock: clock, journal: journal)
        let session = WirelessSession(
            camera: WirelessCamera(peripheral: nil),
            connector: ScriptedConnector(clock: clock, [.success(link)]),
            joiner: joiner, path: path, foreground: FakeForeground(),
            openLink: { (reopening: Bool) async throws(CameraLinkFailure) -> any CameraLink in
                try await opener.open(reopening: reopening)
            },
            clock: clock)
        return (clock, link, joiner, path, session)
    }

    private func statusReadTimes(_ link: FakeGATTLink) -> [Duration] {
        link.logged.filter { $0.call == .read(.status) }.map(\.at)
    }

    @Test func applyReturningInsideTheFiftySecondsFromStatusTwoWaitsForTheGatewayAtOnce() async throws {
        let (clock, link, _, path, session) = realHandoffRig(applyReturnsAt: .seconds(52))
        let result: Result<any CameraLink, WirelessFailure> = await drive(clock) {
            do throws(WirelessFailure) { return .success(try await session.prepareImport()) } catch { return .failure(error) }
        }
        _ = try #require(opened(result))
        // 52 s is past 51 s (50 s from the write) but inside 53.7 s (50 s from status 2): no look at CC09.
        #expect(statusReadTimes(link) == [HandoffTiming.afterSubscribe])
        #expect(path.waitTimes == [.seconds(52)])
    }

    @Test func applyReturningAfterTheFiftySecondsFromStatusTwoLooksAtTheCameraFirst() async throws {
        let (clock, link, _, path, session) = realHandoffRig(applyReturnsAt: .seconds(54))
        let result: Result<any CameraLink, WirelessFailure> = await drive(clock) {
            do throws(WirelessFailure) { return .success(try await session.prepareImport()) } catch { return .failure(error) }
        }
        _ = try #require(opened(result))
        // Past 53.7 s: CC09 is read before the gateway is awaited. It still says 2 (the phone joined in time), so on.
        #expect(statusReadTimes(link) == [HandoffTiming.afterSubscribe, .seconds(54)])
        #expect(path.waitTimes == [.seconds(54)])
    }

    @Test func aLapseSeenAfterTheWindowSwitchesTheWiFiOnAgainWithoutWaitingForTheGateway() async throws {
        let rig = Rig()
        // Status 2 was first seen 30 s before the hand-off returned, so the camera's 50 s end at 20 s; the person answers
        // the prompt at 25 s, and the camera's Wi-Fi went off at 22 s.
        rig.handoff.script([.init(statusTwoAgo: .seconds(30))])
        rig.joiner.script([.init(delay: .seconds(25))])
        rig.link.schedule(status: 0, after: .seconds(22), notify: false)
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.link.logged.filter { $0.call == .read(.status) }.map(\.at) == [.seconds(25)])
        #expect(rig.handoff.kinds == [.run, .rewrite])
        #expect(rig.handoff.calls.map(\.at) == [.zero, .seconds(25)])
        #expect(rig.joiner.applyTimes == [.zero, .seconds(25)])
        // Only the second `apply` waited for the gateway.
        #expect(rig.path.waitTimes == [.seconds(25)])
        #expect(rig.connector.count == 1)
    }

    // MARK: Retries

    @Test func aGatewayThatDoesntComeIsAppliedAgainOnce() async throws {
        // The 12:34 case: `apply` returned, no gateway; with nothing changed, the next try joined.
        let rig = Rig()
        rig.path.script([.never, .after(.seconds(1))])
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.joiner.applyTimes == [.zero, .seconds(20)])
        // CC09 was read at 20 s and still said 2, so no Bluetooth write and no second hand-off.
        #expect(rig.link.logged.filter { $0.call == .read(.status) }.map(\.at) == [.seconds(20)])
        #expect(rig.link.timeouts(for: .status) == [HandoffTiming.pollRead])
        #expect(rig.handoff.kinds == [.run])
        #expect(rig.opener.times == [.seconds(21)])
    }

    @Test func aGatewayThatNeverComesGivesUpAndLetsGoOfEverything() async throws {
        let rig = Rig()
        rig.path.script([.never, .never])
        #expect(failure(await rig.prepare()) == .noGateway)
        #expect(rig.joiner.applyTimes == [.zero, .seconds(20)])
        #expect(rig.joiner.leftNetworks == [Cam.ssid])
        #expect(rig.joiner.leaveTimes == [.seconds(40)])
        #expect(Array(rig.link.calls.suffix(6)) == fiveOff + [.disconnect])
        #expect(rig.opener.times.isEmpty)
        #expect(await rig.session.phase == .idle)
        #expect(await rig.session.network == nil)
    }

    @Test func theCameraWiFiGoingOffDuringTheJoinIsSwitchedOnAgainOnTheSameLink() async throws {
        let rig = Rig()
        rig.link.schedule(status: 0, after: .seconds(10), notify: false)
        rig.path.script([.never, .after(.seconds(1))])
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.handoff.kinds == [.run, .rewrite])
        #expect(rig.handoff.calls.map(\.at) == [.zero, .seconds(20)])
        #expect(rig.joiner.applyTimes == [.zero, .seconds(20)])
        #expect(rig.connector.count == 1)
        await rig.phases.waitFor(.ready)
        #expect(rig.phases.all == [.idle, .handingOff, .joining, .handingOff, .joining, .openingSession, .ready])
    }

    @Test func aDroppedLinkPastTheCamerasFiftySecondsReconnectsAndRunsTheHandoffAgain() async throws {
        let rig = Rig()
        let second = rig.anotherLink()
        rig.connector.enqueue([.success(second)])
        let link = rig.link
        // The link drops while the prompt is up; the person answers at 45 s; no gateway by 65 s.
        rig.joiner.script([.init(delay: .seconds(45), onCall: { link.drop(.linkDropped) })])
        rig.path.script([.never, .after(.seconds(1))])
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.connector.times == [.zero, .seconds(65)])
        // A new link has no subscriptions, so `run`, not `rewriteIfLapsed`.
        #expect(rig.handoff.kinds == [.run, .run])
        #expect(rig.link.calls.last == .disconnect)
        #expect(rig.joiner.applyTimes == [.zero, .seconds(65)])
    }

    @Test func aDroppedLinkInsideTheCamerasFiftySecondsAppliesAgainWithoutBluetooth() async throws {
        let rig = Rig()
        let link = rig.link
        rig.joiner.script([.init(onCall: { link.drop(.linkDropped) })])
        rig.path.script([.never, .after(.seconds(1))])
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.connector.count == 1)
        #expect(rig.handoff.kinds == [.run])
        #expect(rig.joiner.applyTimes == [.zero, .seconds(20)])
    }

    @Test func theWiFiLapsingMoreThanTwiceGivesUp() async throws {
        let rig = Rig()
        rig.link.schedule(status: 0, after: .seconds(1), notify: false)
        rig.path.script([], fallback: .never)
        #expect(failure(await rig.prepare()) == .cameraWiFiLapsed)
        #expect(rig.handoff.kinds == [.run, .rewrite, .rewrite])
        #expect(rig.joiner.applyTimes == [.zero, .seconds(20), .seconds(40)])
        #expect(rig.joiner.leftNetworks == [Cam.ssid])
        #expect(await rig.session.phase == .idle)
    }

    @Test func aRewriteAfterALapseGetsItsOwnTwoTries() async throws {
        // No gateway with CC09 still at 2 (one try used), then the Wi-Fi lapses and is switched on again: the new hand-off
        // gets two tries of its own, so the second miss after the rewrite is tried once more.
        let rig = Rig()
        rig.path.script([.never, .never, .never, .after(.seconds(1))])
        rig.link.schedule(status: 0, after: .seconds(30), notify: false)
        rig.link.schedule(status: 2, after: .seconds(41), notify: false)
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.handoff.kinds == [.run, .rewrite])
        #expect(rig.handoff.calls.map(\.at) == [.zero, .seconds(40)])
        #expect(rig.joiner.applyTimes == [.zero, .seconds(20), .seconds(40), .seconds(60)])
        #expect(rig.opener.times == [.seconds(61)])
    }

    @Test func aHandoffWhoseLinkDropsIsRunAgainOnceFromANewConnection() async throws {
        let rig = Rig()
        rig.connector.enqueue([.success(rig.anotherLink())])
        rig.handoff.script([.init(failure: .linkDropped(afterWrite: true))])
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.connector.count == 2)
        #expect(rig.handoff.kinds == [.run, .run])
        #expect(rig.link.calls.last == .disconnect)
    }

    @Test func aHandoffWhoseLinkDropsTwiceFails() async throws {
        let rig = Rig()
        rig.connector.enqueue([.success(rig.anotherLink())])
        rig.handoff.script([.init(failure: .linkDropped(afterWrite: true)), .init(failure: .linkDropped(afterWrite: false))])
        #expect(failure(await rig.prepare()) == .handoff(.linkDropped(afterWrite: false)))
        #expect(rig.connector.count == 2)
        #expect(rig.joiner.applyTimes.isEmpty)
        #expect(await rig.session.phase == .idle)
    }

    // MARK: Pauses and failures

    @Test func aDeclinedPromptPausesAndLetsGo() async throws {
        let rig = Rig()
        rig.joiner.script([.init(failure: .userDenied)])
        #expect(failure(await rig.prepare()) == .paused(.joinDeclined))
        #expect(await rig.session.phase == .paused(.joinDeclined))
        #expect(rig.joiner.applyTimes == [.zero])
        #expect(rig.path.waitTimes.isEmpty)
        #expect(rig.opener.times.isEmpty)
        #expect(Array(rig.link.calls.suffix(6)) == fiveOff + [.disconnect])
        #expect(await rig.session.network == nil)
    }

    @Test func notInForegroundTwiceWithTheSceneActivePausesForAJoin() async throws {
        // iOS says the app isn't in front while the scene reads active (an inactive to active race): once more after a
        // second, then pause.
        let rig = Rig()
        rig.joiner.script([.init(failure: .notInForeground), .init(failure: .notInForeground)])
        #expect(failure(await rig.prepare()) == .paused(.needsJoin))
        #expect(rig.joiner.applyTimes == [.zero, WirelessTiming.applyAgainInFrontAfter])
        #expect(await rig.session.phase == .paused(.needsJoin))
        #expect(!rig.phases.all.contains(.awaitingFront))
    }

    @Test func notInForegroundOnceWithTheSceneActiveIsTriedOnceMore() async throws {
        let rig = Rig()
        rig.joiner.script([.init(failure: .notInForeground)])
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.joiner.applyTimes == [.zero, WirelessTiming.applyAgainInFrontAfter])
    }

    @Test func aJoinFromTheBackgroundPausesWithoutTouchingBluetooth() async throws {
        let rig = Rig()
        rig.foreground.set(false)
        #expect(failure(await rig.prepare()) == .paused(.needsJoin))
        #expect(rig.connector.count == 0)
        await rig.phases.waitFor(.paused(.needsJoin))
        #expect(rig.phases.all == [.idle, .paused(.needsJoin)])
    }

    @Test(arguments: [
        (GATTFailure.notPaired, WirelessFailure.paused(.notPaired)),
        (.bluetoothOff, .paused(.bluetoothOff)),
        (.unauthorised, .paused(.bluetoothNotAllowed)),
        (.timedOut, .cameraNotFound),
        (.serviceMissing, .bluetooth(.serviceMissing)),
    ])
    func bluetoothConnectFailures(connect: GATTFailure, expected: WirelessFailure) async throws {
        let rig = Rig()
        let connector = ScriptedConnector(clock: rig.clock, [.failure(connect)])
        let session = WirelessSession(
            camera: WirelessCamera(peripheral: rig.peripheral), connector: connector, joiner: rig.joiner, path: rig.path,
            foreground: rig.foreground,
            openLink: { (_: Bool) async throws(CameraLinkFailure) -> any CameraLink in throw CameraLinkFailure(.refused) },
            clock: rig.clock, handoff: rig.handoff)
        let result: Result<any CameraLink, WirelessFailure> = await drive(rig.clock) {
            do throws(WirelessFailure) { return .success(try await session.prepareImport()) } catch { return .failure(error) }
        }
        #expect(failure(result) == expected)
        #expect(rig.handoff.calls.isEmpty)
        if case .paused(let pause) = expected {
            #expect(await session.phase == .paused(pause))
        } else {
            #expect(await session.phase == .idle)
        }
    }

    @Test func aRefusalInTheHandoffPausesForPairing() async throws {
        let rig = Rig()
        rig.handoff.script([.init(failure: .notPaired)])
        #expect(failure(await rig.prepare()) == .paused(.notPaired))
        #expect(rig.connector.count == 1)
    }

    @Test func refusedNetworkDetailsAreNotTriedAgain() async throws {
        let rig = Rig()
        rig.joiner.script([.init(failure: .invalidCredentials)])
        #expect(failure(await rig.prepare()) == .join(.invalidCredentials))
        #expect(rig.joiner.applyTimes == [.zero])
    }

    @Test func anApplyThatFailsTwiceGivesItsFailure() async throws {
        let rig = Rig()
        rig.joiner.script([.init(failure: .systemConfiguration), .init(failure: .systemConfiguration)])
        #expect(failure(await rig.prepare()) == .join(.systemConfiguration))
        // The retry waits `applyRetryAfter`, not going out at the same instant.
        #expect(rig.joiner.applyTimes == [.zero, WirelessTiming.applyRetryAfter])
        #expect(rig.path.waitTimes.isEmpty)
    }

    // MARK: The port

    @Test func thePortIsTriedEverySecond() async throws {
        let rig = Rig()
        rig.opener.script([CameraLinkFailure(.disconnected), CameraLinkFailure(.disconnected), CameraLinkFailure(.noAnswer), nil])
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.opener.times == [1_500, 2_500, 3_500, 4_500].map { Duration.milliseconds($0) })
    }

    @Test func aPortThatNeverAnswersGivesUpAfterSixtySeconds() async throws {
        let rig = Rig()
        rig.opener.script([], fallback: CameraLinkFailure(.noAnswer))
        #expect(failure(await rig.prepare()) == .link(CameraLinkFailure(.noAnswer)))
        let times = rig.opener.times
        #expect(times.count == 61)
        #expect(times.first == .milliseconds(1_500))
        #expect(times.last == .milliseconds(61_500))
        #expect(rig.joiner.leftNetworks == [Cam.ssid])
        #expect(await rig.session.phase == .idle)
    }

    @Test func aRefusedSessionStopsAtOnce() async throws {
        let rig = Rig()
        rig.opener.script([CameraLinkFailure(.refused)])
        #expect(failure(await rig.prepare()) == .link(CameraLinkFailure(.refused)))
        #expect(rig.opener.times.count == 1)
        #expect(rig.joiner.leftNetworks == [Cam.ssid])
    }

    // MARK: Concurrency

    @Test func twoPreparationsAtOnceShareOneJoin() async throws {
        let rig = Rig()
        rig.joiner.script([.init(delay: .seconds(8))])
        let session = rig.session
        let (first, second): (Int?, Int?) = await drive(rig.clock) {
            async let a = try? await session.prepareImport()
            async let b = try? await session.prepareImport()
            let links = await [a, b]
            return ((links[0] as? StubLink)?.number, (links[1] as? StubLink)?.number)
        }
        #expect(first == 1)
        #expect(second == 1)
        #expect(rig.connector.count == 1)
        #expect(rig.joiner.applyTimes.count == 1)
    }

    @Test func leavingDuringTheJoinStopsItAndLetsGo() async throws {
        let rig = Rig()
        rig.joiner.script([.init(delay: .seconds(8))])
        let session = rig.session
        let preparing = Task { () -> WirelessFailure? in
            do throws(WirelessFailure) {
                _ = try await session.prepareImport()
                return nil
            } catch {
                return error
            }
        }
        await rig.clock.waitUntilSomeoneSleeps() // the prompt is up
        await session.leave()
        #expect(await preparing.value == .cancelled)
        #expect(rig.joiner.leftNetworks == [Cam.ssid])
        #expect(rig.link.calls.last == .disconnect)
        #expect(rig.path.waitTimes.isEmpty)
        #expect(await session.phase == .idle)
        #expect(await session.network == nil)
    }

    // MARK: The app away during the join (bench 19.1)

    @Test func awayDuringTheHandoffHoldsTheJoinUntilTheAppIsBack() async throws {
        // The person switches apps 2 s into a 5 s hand-off and comes back at 30 s: nothing is applied while away.
        let rig = Rig()
        rig.handoff.script([.init(delay: .seconds(5), during: rig.away(after: .seconds(2)))])
        rig.comeBack(at: .seconds(30))
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.joiner.applyTimes == [.seconds(30)])
        #expect(rig.handoff.kinds == [.run])
        // Inside the camera's 50 s (they end at 55 s): no look at CC09, no second switch-on.
        #expect(rig.link.count(.read(.status)) == 0)
        // The Bluetooth link was kept through the hold.
        #expect(rig.connector.count == 1)
        #expect(!rig.link.calls.contains(.disconnect))
        await rig.phases.waitFor(.ready)
        #expect(rig.phases.all == [.idle, .handingOff, .awaitingFront, .joining, .openingSession, .ready])
    }

    @Test func awayPastTheCamerasFiftySecondsSwitchesTheWiFiOnAgainOnReturnWithoutUsingARewrite() async throws {
        // Away from 2 s to 90 s; the camera's Wi-Fi went off at 56 s. On the return: CC09 read in front, a fresh `run`,
        // then the join. Two lapses after that still get their two rewrites, so the switch-on on return wasn't counted.
        let rig = Rig()
        rig.handoff.script([.init(delay: .seconds(5), during: rig.away(after: .seconds(2)))])
        rig.link.schedule(status: 0, after: .seconds(56), notify: false)
        rig.comeBack(at: .seconds(90))
        rig.path.script([.never, .never, .after(.seconds(1))])
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.handoff.kinds == [.run, .run, .rewrite, .rewrite])
        #expect(rig.handoff.calls.map(\.at) == [.zero, .seconds(90), .seconds(110), .seconds(130)])
        #expect(rig.joiner.applyTimes == [.seconds(90), .seconds(110), .seconds(130)])
        #expect(rig.link.logged.filter { $0.call == .read(.status) }.map(\.at) == [.seconds(90), .seconds(110), .seconds(130)])
        #expect(rig.connector.count == 1)
    }

    @Test func notInForegroundWhileAwayHoldsAndAppliesAgainOnReturn() async throws {
        // iOS refuses the first `apply` (code 14) as the person leaves; they come back at 20 s. The refusal is not a failed
        // try: the join after it still gets its two.
        let rig = Rig()
        rig.joiner.script([.init(failure: .notInForeground, during: rig.away(after: .zero))])
        rig.comeBack(at: .seconds(20))
        rig.path.script([.never, .after(.seconds(1))])
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.joiner.applyTimes == [.zero, .seconds(20), .seconds(40)])
        await rig.phases.waitFor(.ready)
        #expect(rig.phases.all.contains(.awaitingFront))
    }

    @Test func theHoldRunningOutLetsGoOfEverythingAndPausesForAJoin() async throws {
        let rig = Rig()
        rig.handoff.script([.init(delay: .seconds(5), during: rig.away(after: .seconds(2)))])
        #expect(failure(await rig.prepare()) == .paused(.needsJoin))
        #expect(rig.clock.elapsed == .seconds(5) + WirelessTiming.joinHoldWhileAway)
        #expect(rig.joiner.applyTimes.isEmpty)
        #expect(Array(rig.link.calls.suffix(6)) == fiveOff + [.disconnect])
        #expect(rig.journal.all == ["notifications off"])
        #expect(await rig.session.phase == .paused(.needsJoin))
        #expect(await rig.session.network == nil)
    }

    @Test func leavingDuringTheHoldEndsItPromptlyAndLetsGo() async throws {
        let rig = Rig()
        rig.handoff.script([.init(during: rig.away(after: .zero))])
        let session = rig.session
        let preparing = Task { () -> WirelessFailure? in
            do throws(WirelessFailure) {
                _ = try await session.prepareImport()
                return nil
            } catch {
                return error
            }
        }
        await rig.clock.waitUntilSomeoneSleeps() // the hold's limit
        #expect(await session.phase == .awaitingFront)
        await session.leave()
        #expect(await preparing.value == .cancelled)
        #expect(rig.clock.elapsed == .zero)
        #expect(rig.joiner.applyTimes.isEmpty)
        #expect(rig.link.calls.last == .disconnect)
        #expect(await session.phase == .idle)
    }

    /// Bench 19.1's probes B, C and D: the person left during the hand-off and never came back. `apply` used to be called
    /// from the background, the camera's 50 s ran out, and the rewrite's failure was reported as the hand-off's ("The
    /// camera didn't switch its Wi-Fi on"). Now nothing is applied or rewritten while away, and the join pauses for the app.
    @Test(arguments: [HandoffFailure.timedOut(lastStatus: .terminated), .wifiDidNotStart(lastStatus: .terminated)])
    func awayThroughoutAfterTheHandoffPausesForAJoinNotAHandoffFailure(rewriteFailure: HandoffFailure) async throws {
        let rig = Rig()
        rig.handoff.script([.init(delay: .seconds(5), during: rig.away(after: .seconds(2))),
                            .init(delay: .seconds(30), failure: rewriteFailure)])
        rig.link.schedule(status: 0, after: .seconds(56), notify: false)
        rig.path.script([], fallback: .never)
        rig.joiner.script([.init(delay: .seconds(60))])
        #expect(failure(await rig.prepare()) == .paused(.needsJoin))
        #expect(rig.joiner.applyTimes.isEmpty)
        #expect(rig.handoff.kinds == [.run])
    }

    /// The person left while iOS's prompt was up, and `apply` came back (with nothing, or failing) after the camera's 50 s:
    /// no rewrite while away; the hold runs out and the join pauses for the app.
    @Test(arguments: [JoinFailure?.none, .other(11)])
    func leavingWhileThePromptIsUpHoldsTheRewriteAndPausesForAJoin(applyFailure: JoinFailure?) async throws {
        let rig = Rig()
        rig.handoff.script([.init(), .init(delay: .seconds(30), failure: .timedOut(lastStatus: .terminated))])
        rig.joiner.script([.init(delay: .seconds(60), failure: applyFailure, during: rig.away(after: .seconds(2)))])
        rig.link.schedule(status: 0, after: .seconds(56), notify: false)
        rig.path.script([], fallback: .never)
        #expect(failure(await rig.prepare()) == .paused(.needsJoin))
        #expect(rig.handoff.kinds == [.run])
        #expect(rig.joiner.applyTimes == [.zero])
        #expect(rig.clock.elapsed == .seconds(60) + WirelessTiming.joinHoldWhileAway)
        #expect(rig.joiner.leftNetworks == [Cam.ssid])
        #expect(Array(rig.link.calls.suffix(6)) == fiveOff + [.disconnect])
    }

    /// As above, but the person comes back at 90 s: the switch-on runs in front (a fresh `run`) and fails. The lapse came
    /// while the app was away with no prompt answered, so the join pauses for the app rather than blaming the camera.
    @Test(arguments: [HandoffFailure.timedOut(lastStatus: .terminated), .wifiDidNotStart(lastStatus: .terminated)])
    func aSwitchOnAfterALapseWhileAwayThatFailsPausesForAJoin(rewriteFailure: HandoffFailure) async throws {
        let rig = Rig()
        rig.handoff.script([.init(), .init(delay: .seconds(30), failure: rewriteFailure)])
        rig.joiner.script([.init(delay: .seconds(60), during: rig.away(after: .seconds(2)))])
        rig.link.schedule(status: 0, after: .seconds(56), notify: false)
        rig.path.script([], fallback: .never)
        rig.comeBack(at: .seconds(90))
        #expect(failure(await rig.prepare()) == .paused(.needsJoin))
        #expect(rig.handoff.kinds == [.run, .run])
        #expect(rig.handoff.calls.map(\.at) == [.zero, .seconds(90)])
        #expect(rig.joiner.applyTimes == [.zero])
    }

    @Test func aHandoffThatTimedOutWhileTheAppWasAwayIsRunOnceMoreFromTheFront() async throws {
        // Its time limits may have run out while the app was suspended, without the camera having had its time.
        let rig = Rig()
        rig.handoff.script([.init(delay: .seconds(5), failure: .timedOut(lastStatus: .terminated),
                                  during: rig.away(after: .seconds(2))),
                            .init()])
        rig.comeBack(at: .seconds(20))
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.handoff.kinds == [.run, .run])
        #expect(rig.handoff.calls.map(\.at) == [.zero, .seconds(20)])
        #expect(rig.joiner.applyTimes == [.seconds(20)])
    }

    @Test func aHandoffThatTimedOutInFrontFailsAsBefore() async throws {
        let rig = Rig()
        rig.handoff.script([.init(delay: .seconds(5), failure: .timedOut(lastStatus: .terminated))])
        #expect(failure(await rig.prepare()) == .handoff(.timedOut(lastStatus: .terminated)))
        #expect(rig.handoff.kinds == [.run])
        #expect(rig.joiner.applyTimes.isEmpty)
    }

    @Test func aRewriteThatFailsInFrontIsARewriteFailure() async throws {
        let rig = Rig()
        rig.link.schedule(status: 0, after: .seconds(10), notify: false)
        rig.path.script([.never])
        rig.handoff.script([.init(), .init(failure: .wifiDidNotStart(lastStatus: .terminated))])
        #expect(failure(await rig.prepare()) == .rewriteFailed(.wifiDidNotStart(lastStatus: .terminated)))
        #expect(rig.handoff.kinds == [.run, .rewrite])
        #expect(await rig.session.phase == .idle)
    }

    @Test func theAppAwayWhileThePromptIsUpStillJoins() async throws {
        // 5 Nov 01:21: in the background 8.9 s with iOS's prompt up, and still joined. `apply` is already out, so nothing
        // is held: the gateway is awaited as usual.
        let rig = Rig()
        rig.joiner.script([.init(delay: .seconds(9), during: rig.away(after: .seconds(1)))])
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.joiner.applyTimes == [.zero])
        #expect(rig.path.waitTimes == [.seconds(9)])
        await rig.phases.waitFor(.ready)
        #expect(!rig.phases.all.contains(.awaitingFront))
    }

    @Test func anInactiveAppIsInFrontSoNothingIsHeld() async throws {
        // iOS's prompt, Control Centre or a call banner make the app inactive, not background: `isInForeground` reads true
        // and no move to the background is told, so the join goes on.
        let rig = Rig()
        rig.foreground.set(true)
        rig.joiner.script([.init(delay: .seconds(8))])
        _ = try #require(opened(await rig.prepare()))
        #expect(rig.joiner.applyTimes == [.zero])
        await rig.phases.waitFor(.ready)
        #expect(rig.phases.all == [.idle, .handingOff, .joining, .openingSession, .ready])
    }
}
