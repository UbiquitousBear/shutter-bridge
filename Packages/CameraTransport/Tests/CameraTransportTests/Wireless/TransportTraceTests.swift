import BLEKit
import Foundation
import Testing
@testable import CameraTransport

/// The bench log's events (W20): what the session and the hand-off record, on a virtual clock, and that recording changes
/// nothing they do.
@Suite("Transport trace: the join and the hand-off", .timeLimit(.minutes(1)))
struct TransportTraceTests {
    /// The real hand-off: status 0, CC08 after the spike's 1 s pause, status 1 at +0.09 s and 2 at +0.84 s; iOS's prompt
    /// accepted after `prompt`; the gateway 1.5 s later.
    private func realRig(prompt: Duration = .seconds(8), trace: TransportTrace)
        -> (VirtualClock, FakeGATTLink, FakeJoiner, LinkOpener, WirelessSession) {
        let clock = VirtualClock()
        let journal = Journal()
        let link = FakeGATTLink(clock: clock, initialStatus: 0)
        link.onWrite { link in
            link.schedule(status: 1, after: .milliseconds(90))
            link.schedule(status: 2, after: .milliseconds(840))
        }
        let joiner = FakeJoiner(clock: clock, journal: journal, steps: [.init(delay: prompt)])
        let opener = LinkOpener(clock: clock, journal: journal)
        let session = WirelessSession(
            camera: WirelessCamera(peripheral: nil),
            connector: ScriptedConnector(clock: clock, [.success(link)]),
            joiner: joiner, path: FakePath(clock: clock), foreground: FakeForeground(),
            openLink: { (reopening: Bool) async throws(CameraLinkFailure) -> any CameraLink in
                try await opener.open(reopening: reopening)
            },
            clock: clock, trace: trace)
        return (clock, link, joiner, opener, session)
    }

    private func prepare(_ session: WirelessSession, on clock: VirtualClock) async -> Result<any CameraLink, WirelessFailure> {
        await drive(clock) {
            do throws(WirelessFailure) { return .success(try await session.prepareImport()) } catch { return .failure(error) }
        }
    }

    @Test func aFirstJoinRecordsEveryStepWithItsTime() async throws {
        let recorder = TraceRecorder()
        let (clock, _, _, _, session) = realRig(trace: recorder.trace)
        _ = try #require(opened(await prepare(session, on: clock)))

        let wrote = HandoffTiming.afterSubscribe
        let statusTwo = wrote + .milliseconds(840)
        let expected: [TransportTraceEvent] = [
            .preparationStarted(joined: false, bluetoothFirst: false),
            .bluetoothConnected(after: .zero),
            .handoffStatus(0, after: wrote),
            .handoffWroteWiFiOn(after: wrote),
            .handoffStatus(1, after: wrote + .milliseconds(90)),
            .handoffStatus(2, after: statusTwo),
            .handoffDetailsRead(after: statusTwo, tries: 1),
            .handoffFinished(after: statusTwo, rewrite: false, wroteWiFiOn: true, statusTwoAlready: false,
                             windowLeft: HandoffTiming.cameraWiFiWindow),
            .joinApplied(attempt: 1, after: .seconds(8), failure: nil),
            .gateway(found: true, after: .milliseconds(1_500)),
            .sessionOpened(after: .zero, tries: 1, reopening: false),
            .preparationEnded(succeeded: true, times: WirelessStepTimes(
                total: statusTwo + .milliseconds(9_500), handingOff: statusTwo, joining: .milliseconds(9_500),
                openingSession: .zero)),
        ]
        #expect(recorder.all == expected)
    }

    @Test func recordingChangesNothingTheJoinDoes() async throws {
        let recorder = TraceRecorder()
        let (tracedClock, tracedLink, tracedJoiner, tracedOpener, traced) = realRig(trace: recorder.trace)
        let (plainClock, plainLink, plainJoiner, plainOpener, plain) = realRig(trace: .none)
        _ = try #require(opened(await prepare(traced, on: tracedClock)))
        _ = try #require(opened(await prepare(plain, on: plainClock)))
        #expect(tracedLink.logged == plainLink.logged)
        #expect(tracedJoiner.applyTimes == plainJoiner.applyTimes)
        #expect(tracedOpener.times == plainOpener.times)
        #expect(tracedClock.elapsed == plainClock.elapsed)
        #expect(!recorder.all.isEmpty)
    }

    @Test func aLapseAfterASlowPromptRecordsTheStatusSeenAndTheRewrite() async throws {
        // The camera's 50 s end at 20 s (status 2 seen 30 s before the hand-off returned); the person answers the prompt at
        // 55 s, by when the camera's Wi-Fi went to 3 (at 22 s). The session looks, sees 3, and rewrites CC08.
        let recorder = TraceRecorder()
        let rig = Rig(trace: recorder.trace)
        rig.handoff.script([.init(statusTwoAgo: .seconds(30)), .init()])
        rig.joiner.script([.init(delay: .seconds(55))])
        rig.link.schedule(status: 3, after: .seconds(22), notify: false)
        _ = try #require(opened(await rig.prepare()))

        let events = recorder.all
        #expect(events.contains(.joinApplied(attempt: 1, after: .seconds(55), failure: nil)))
        let checked = try #require(events.firstIndex(of: .cameraWiFiChecked(.read(3), windowPassed: true, off: true)))
        let rewrite = try #require(events.firstIndex(of: .rewriteStarted(number: 1, limit: WirelessTiming.rewritesPerJoin)))
        #expect(checked < rewrite)
        let rewritten = events.firstIndex {
            if case .handoffFinished(_, true, _, _, _) = $0 { true } else { false }
        }
        #expect(rewritten.map { $0 > rewrite } == true)
        // The second join after the rewrite reached the gateway.
        #expect(events.filter { if case .joinApplied = $0 { true } else { false } }.count == 2)
        #expect(events.last.map { if case .preparationEnded(true, _) = $0 { true } else { false } } == true)
    }

    @Test func aDeclinedPromptIsRecordedWithItsFailureAndTheFailedPreparation() async throws {
        let recorder = TraceRecorder()
        let rig = Rig(trace: recorder.trace)
        rig.joiner.script([.init(delay: .seconds(3), failure: .userDenied)])
        #expect(failure(await rig.prepare()) == .paused(.joinDeclined))
        let events = recorder.all
        #expect(events.contains(.joinApplied(attempt: 1, after: .seconds(3), failure: .userDenied)))
        #expect(events.last.map { if case .preparationEnded(false, _) = $0 { true } else { false } } == true)
    }

    @Test func aDroppedHandoffLinkIsRecordedWithTheReconnect() async throws {
        let recorder = TraceRecorder()
        let rig = Rig(trace: recorder.trace)
        rig.connector.enqueue([.success(rig.anotherLink())])
        rig.handoff.script([.init(failure: .linkDropped(afterWrite: true)), .init()])
        _ = try #require(opened(await rig.prepare()))
        #expect(recorder.all.contains(.bluetoothDropped(afterWrite: true, reconnect: 1)))
        #expect(recorder.all.filter { if case .bluetoothConnected = $0 { true } else { false } }.count == 2)
    }

    @Test func thePortTriesAreCounted() async throws {
        let recorder = TraceRecorder()
        let rig = Rig(trace: recorder.trace)
        rig.opener.script([CameraLinkFailure(.noAnswer), CameraLinkFailure(.noAnswer), nil])
        _ = try #require(opened(await rig.prepare()))
        #expect(recorder.all.contains(.sessionOpened(after: WirelessTiming.portRetryEvery * 2, tries: 3, reopening: false)))
    }

    @Test func aReopenInsideTheStayIsRecordedWithoutAJoin() async throws {
        let recorder = TraceRecorder()
        let rig = Rig(trace: recorder.trace)
        _ = try #require(opened(await rig.prepare()))
        await rig.session.importFinished()
        await rig.phases.waitFor(.staying)
        _ = try #require(opened(await rig.prepare()))
        let events = recorder.all
        let second = try #require(events.lastIndex(of: .preparationStarted(joined: true, bluetoothFirst: false)))
        let after = Array(events[second...])
        #expect(!after.contains { if case .joinApplied = $0 { true } else { false } })
        #expect(after.contains(.sessionOpened(after: .zero, tries: 1, reopening: true)))
    }

    @Test func theRSSIIsReadBesideTheHandoffAtItsStartAndEnd() async throws {
        // A link that can read its RSSI: read when the hand-off starts and when it gives the details, on tasks of their own,
        // so the join's timeline is the same as without the trace.
        func run(trace: TransportTrace) async throws -> (FakeJoiner, LinkOpener) {
            let clock = VirtualClock()
            let journal = Journal()
            let link = SignalReadingLink(FakeGATTLink(clock: clock, initialStatus: 2), dBm: -58)
            let handoff = FakeHandoff(clock: clock, journal: journal, steps: [.init(delay: .seconds(2))])
            let joiner = FakeJoiner(clock: clock, journal: journal)
            let opener = LinkOpener(clock: clock, journal: journal)
            let session = WirelessSession(
                camera: WirelessCamera(peripheral: nil),
                connector: OneLink(link: link),
                joiner: joiner, path: FakePath(clock: clock), foreground: FakeForeground(),
                openLink: { (reopening: Bool) async throws(CameraLinkFailure) -> any CameraLink in
                    try await opener.open(reopening: reopening)
                },
                clock: clock, handoff: handoff, trace: trace)
            _ = try #require(opened(await prepare(session, on: clock)))
            return (joiner, opener)
        }
        let recorder = TraceRecorder()
        let (tracedJoiner, tracedOpener) = try await run(trace: recorder.trace)
        let (plainJoiner, plainOpener) = try await run(trace: .none)
        #expect(tracedJoiner.applyTimes == plainJoiner.applyTimes)
        #expect(tracedOpener.times == plainOpener.times)
        let signals = { recorder.all.compactMap { if case let .bluetoothSignal(dBm, _) = $0 { dBm } else { nil } } }
        let deadline = ContinuousClock.now + .seconds(10)
        while signals().count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(signals() == [-58, -58])
    }

    @Test func theStepTimelineSumsEachPhase() {
        var timeline = StepTimeline(start: .seconds(10), phase: .idle)
        timeline.move(to: .handingOff, at: .seconds(10))
        timeline.move(to: .joining, at: .seconds(14))
        timeline.move(to: .handingOff, at: .seconds(20))
        timeline.move(to: .joining, at: .seconds(23))
        timeline.move(to: .openingSession, at: .seconds(25))
        timeline.move(to: .ready, at: .seconds(29))
        timeline.move(to: .ready, at: .seconds(29))
        #expect(timeline.times == WirelessStepTimes(total: .seconds(19), handingOff: .seconds(7), joining: .seconds(8),
                                                    openingSession: .seconds(4)))
    }

    @Test func theNoneTraceIsOff() {
        #expect(!TransportTrace.none.isOn)
        #expect(TraceRecorder().trace.isOn)
    }
}

/// A scripted link that also reads its RSSI, as `CoreBluetoothGATTLink` does.
final class SignalReadingLink: GATTLink, GATTSignalReading {
    let base: FakeGATTLink
    let dBm: Int?

    init(_ base: FakeGATTLink, dBm: Int?) {
        self.base = base
        self.dBm = dBm
    }

    var peripheral: PeripheralID { base.peripheral }
    var notifications: AsyncStream<(CameraControlCharacteristic, Data)> { base.notifications }
    var state: AsyncStream<GATTLinkState> { base.state }
    var anotherAppHoldsLink: Bool { base.anotherAppHoldsLink }

    func read(_ characteristic: CameraControlCharacteristic, timeout: Duration?) async throws(GATTFailure) -> Data {
        try await base.read(characteristic, timeout: timeout)
    }

    func write(_ write: CameraControlWrite, timeout: Duration) async throws(GATTFailure) {
        try await base.write(write, timeout: timeout)
    }

    func setNotify(_ on: Bool, _ characteristic: CameraControlCharacteristic, timeout: Duration) async throws(GATTFailure) {
        try await base.setNotify(on, characteristic, timeout: timeout)
    }

    func disconnect() async { await base.disconnect() }

    func readSignalStrength(timeout: Duration) async -> Int? { dBm }
}

/// Hands out one link, whatever its type.
private struct OneLink: GATTConnector {
    let link: any GATTLink
    func connect(known: PeripheralID?) async throws(GATTFailure) -> any GATTLink { link }
}
