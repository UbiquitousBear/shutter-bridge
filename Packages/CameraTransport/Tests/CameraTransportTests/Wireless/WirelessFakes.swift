// Scripted stand-ins for what `WirelessSession` is written against: iOS's hotspot joining, the Wi-Fi path, the scene phase,
// the hand-off and the camera's session. Each takes virtual time only by sleeping on the test's clock inside the call, so the
// session never has two sleepers at once during a join and `drive` moves time deterministically. The network name and
// password are the synthetic ones from FakeGATT.swift.

import BLEKit
import Foundation
import Synchronization
@testable import CameraTransport

/// What happened, in order, across fakes whose relative order a test checks (closing, leaving, releasing).
final class Journal: Sendable {
    private let entries = Mutex<[String]>([])
    func add(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
}

/// iOS's `apply` and `removeConfiguration`, scripted per call.
final class FakeJoiner: HotspotJoining {
    struct Step: Sendable {
        /// How long the call takes on the clock (iOS's prompt waiting for the person).
        var delay: Duration = .zero
        var failure: JoinFailure?
        /// Runs when the call starts (to drop the Bluetooth link meanwhile, say).
        var onCall: (@Sendable () -> Void)?
    }

    private struct State {
        var steps: [Step]
        var applies: [(at: Duration, ssid: String)] = []
        var leaves: [(at: Duration, ssid: String)] = []
    }

    private let clock: VirtualClock
    private let journal: Journal
    private let box: Mutex<State>

    init(clock: VirtualClock, journal: Journal, steps: [Step] = []) {
        self.clock = clock
        self.journal = journal
        box = Mutex(State(steps: steps))
    }

    func script(_ steps: [Step]) { box.withLock { $0.steps = steps } }

    var applyTimes: [Duration] { box.withLock { $0.applies.map(\.at) } }
    var appliedNetworks: [String] { box.withLock { $0.applies.map(\.ssid) } }
    var leaveTimes: [Duration] { box.withLock { $0.leaves.map(\.at) } }
    var leftNetworks: [String] { box.withLock { $0.leaves.map(\.ssid) } }

    func apply(_ credentials: SonyWiFiCredentials) async throws(JoinFailure) {
        let at = clock.elapsed
        let step = box.withLock { s -> Step in
            s.applies.append((at: at, ssid: credentials.ssid))
            return s.steps.isEmpty ? Step() : s.steps.removeFirst()
        }
        step.onCall?()
        if step.delay > .zero {
            do { try await clock.sleep(for: step.delay) } catch { throw .cancelled }
        }
        if let failure = step.failure { throw failure }
    }

    func leave(ssid: String) async {
        let at = clock.elapsed
        box.withLock { $0.leaves.append((at: at, ssid: ssid)) }
        journal.add("leave network")
    }
}

/// The Wi-Fi path: per call to `waitForGateway`, whether the camera's gateway appears and after how long.
final class FakePath: WiFiPathWatching {
    enum Appearance: Sendable {
        case after(Duration)
        case never
    }

    private struct State {
        var script: [Appearance]
        var fallback: Appearance
        var current: String?
        var waits: [(at: Duration, timeout: Duration)] = []
    }

    private let clock: VirtualClock
    private let box: Mutex<State>

    init(clock: VirtualClock, script: [Appearance] = [], fallback: Appearance = .after(.milliseconds(1500))) {
        self.clock = clock
        box = Mutex(State(script: script, fallback: fallback))
    }

    func script(_ appearances: [Appearance], fallback: Appearance? = nil) {
        box.withLock { s in
            s.script = appearances
            if let fallback { s.fallback = fallback }
        }
    }

    /// What `gateway()` answers.
    func setCurrent(_ gateway: String?) { box.withLock { $0.current = gateway } }

    var waitTimes: [Duration] { box.withLock { $0.waits.map(\.at) } }
    var waitTimeouts: [Duration] { box.withLock { $0.waits.map(\.timeout) } }

    func gateway() async -> String? { box.withLock { $0.current } }

    func waitForGateway(_ ip: String, timeout: Duration) async -> Bool {
        let at = clock.elapsed
        let appearance = box.withLock { s -> Appearance in
            s.waits.append((at: at, timeout: timeout))
            return s.script.isEmpty ? s.fallback : s.script.removeFirst()
        }
        switch appearance {
        case .after(let delay) where delay <= timeout && ip == WirelessCamera.cameraNetworkGateway:
            do { try await clock.sleep(for: delay) } catch { return false }
            box.withLock { $0.current = ip }
            return true
        default:
            try? await clock.sleep(for: timeout)
            return false
        }
    }
}

final class FakeForeground: ForegroundSignal {
    private struct State {
        var inForeground: Bool
        var onNextRead: (@Sendable () async -> Void)?
    }

    private let box: Mutex<State>
    init(_ inForeground: Bool = true) { box = Mutex(State(inForeground: inForeground)) }
    func set(_ value: Bool) { box.withLock { $0.inForeground = value } }

    /// Runs `body` during the next read, after the value is taken and before it is returned: a scene change that overtakes
    /// the read.
    func onNextRead(_ body: @escaping @Sendable () async -> Void) { box.withLock { $0.onNextRead = body } }

    var isInForeground: Bool {
        get async {
            let (value, hook) = box.withLock { s -> (Bool, (@Sendable () async -> Void)?) in
                defer { s.onNextRead = nil }
                return (s.inForeground, s.onNextRead)
            }
            await hook?()
            return value
        }
    }
}

/// The hand-off, scripted per call; `release` is the real one, so the link records the five switches going off.
final class FakeHandoff: WiFiHandingOff {
    enum Kind: Equatable, Sendable { case run, rewrite }

    struct Step: Sendable {
        var delay: Duration = .zero
        /// How long before the call returns status 2 was first seen (the camera's 50 s run from then).
        var statusTwoAgo: Duration = .zero
        var failure: HandoffFailure?
    }

    struct Call: Equatable {
        var kind: Kind
        var at: Duration
        var peripheral: PeripheralID
    }

    private struct State {
        var steps: [Step]
        var calls: [Call] = []
    }

    private let clock: VirtualClock
    private let journal: Journal
    private let box: Mutex<State>

    init(clock: VirtualClock, journal: Journal, steps: [Step] = []) {
        self.clock = clock
        self.journal = journal
        box = Mutex(State(steps: steps))
    }

    func script(_ steps: [Step]) { box.withLock { $0.steps = steps } }

    var calls: [Call] { box.withLock { $0.calls } }
    var kinds: [Kind] { calls.map(\.kind) }

    func run(on link: any GATTLink) async throws(HandoffFailure) -> HandoffResult {
        try await perform(.run, on: link)
    }

    func rewriteIfLapsed(on link: any GATTLink) async throws(HandoffFailure) -> HandoffResult {
        try await perform(.rewrite, on: link)
    }

    func release(_ link: any GATTLink) async -> ReleaseReport {
        journal.add("notifications off")
        return await NotificationSwitches.turnOff(link)
    }

    private func perform(_ kind: Kind, on link: any GATTLink) async throws(HandoffFailure) -> HandoffResult {
        let at = clock.elapsed
        let step = box.withLock { s -> Step in
            s.calls.append(Call(kind: kind, at: at, peripheral: link.peripheral))
            return s.steps.isEmpty ? Step() : s.steps.removeFirst()
        }
        if step.delay > .zero {
            do { try await clock.sleep(for: step.delay) } catch { throw .cancelled }
        }
        if let failure = step.failure { throw failure }
        let credentials = try! SonyWiFiCredentials(ssid: Cam.ssid, passphrase: Cam.passphrase)
        return HandoffResult(
            credentials: credentials,
            statusTwoAt: ClockMark(clock, at: clock.now.advanced(by: .zero - step.statusTwoAgo)),
            launchedBeforeLooking: step.statusTwoAgo > .zero,
            wroteWiFiOn: step.statusTwoAgo == .zero,
            unconfirmedSwitches: []
        )
    }
}

/// Hands out the links the test queued, then `fallback` for every later call.
final class ScriptedConnector: GATTConnector {
    private struct State {
        var queue: [Result<FakeGATTLink, GATTFailure>]
        var fallback: GATTFailure
        var calls: [(at: Duration, known: PeripheralID?)] = []
    }

    private let clock: VirtualClock
    private let box: Mutex<State>

    init(clock: VirtualClock, _ queue: [Result<FakeGATTLink, GATTFailure>], fallback: GATTFailure = .timedOut) {
        self.clock = clock
        box = Mutex(State(queue: queue, fallback: fallback))
    }

    func enqueue(_ results: [Result<FakeGATTLink, GATTFailure>]) { box.withLock { $0.queue += results } }

    var count: Int { box.withLock { $0.calls.count } }
    var times: [Duration] { box.withLock { $0.calls.map(\.at) } }
    var knownArguments: [PeripheralID?] { box.withLock { $0.calls.map(\.known) } }

    func connect(known: PeripheralID?) async throws(GATTFailure) -> any GATTLink {
        let at = clock.elapsed
        let next = box.withLock { s -> Result<FakeGATTLink, GATTFailure> in
            s.calls.append((at: at, known: known))
            return s.queue.isEmpty ? .failure(s.fallback) : s.queue.removeFirst()
        }
        switch next {
        case .success(let link): return link
        case .failure(let failure): throw failure
        }
    }
}

/// The camera's session as `openLink` gives it.
actor StubLink: CameraLink {
    nonisolated let descriptor = CameraDescriptor(id: .init(rawValue: "wifi"), name: "Camera", mode: .wifi(.cameraNetwork))
    nonisolated let capabilities = CameraLinkCapabilities.wifi
    nonisolated let number: Int
    private let journal: Journal
    private let fanOut = EventFanOut<CameraLinkEvent>()
    private(set) var closeCount = 0

    init(number: Int, journal: Journal) {
        self.number = number
        self.journal = journal
    }

    nonisolated var events: AsyncStream<CameraLinkEvent> { fanOut.subscribe() }
    func open() throws(CameraLinkFailure) {}
    func list() throws(CameraLinkFailure) -> [CameraItem] { [] }
    func info(of item: CameraItem.ID) throws(CameraLinkFailure) -> CameraItem { throw CameraLinkFailure(.itemNotFound) }
    func thumbnail(of item: CameraItem.ID) throws(CameraLinkFailure) -> Data { Data() }
    func bytes(of item: CameraItem.ID, into directory: URL, resuming: PartialDownload?,
               checkpoint: @escaping @Sendable (PartialDownload) -> Void,
               progress: @escaping @Sendable (UInt64) -> Void) throws(CameraLinkFailure) -> URL {
        throw CameraLinkFailure(.itemNotFound)
    }

    func close() {
        closeCount += 1
        journal.add("close session")
        fanOut.finish()
    }
}

/// `openLink`, scripted per call: nil opens, a failure fails.
final class LinkOpener: Sendable {
    private struct State {
        var script: [CameraLinkFailure?]
        var fallback: CameraLinkFailure?
        var calls: [(at: Duration, reopening: Bool)] = []
        var opened: [StubLink] = []
    }

    private let clock: VirtualClock
    private let journal: Journal
    private let box: Mutex<State>

    init(clock: VirtualClock, journal: Journal, script: [CameraLinkFailure?] = [], fallback: CameraLinkFailure? = nil) {
        self.clock = clock
        self.journal = journal
        box = Mutex(State(script: script, fallback: fallback))
    }

    func script(_ results: [CameraLinkFailure?], fallback: CameraLinkFailure?? = nil) {
        box.withLock { s in
            s.script = results
            if let fallback { s.fallback = fallback }
        }
    }

    var times: [Duration] { box.withLock { $0.calls.map(\.at) } }
    var reopenings: [Bool] { box.withLock { $0.calls.map(\.reopening) } }
    var opened: [StubLink] { box.withLock { $0.opened } }

    func open(reopening: Bool) async throws(CameraLinkFailure) -> any CameraLink {
        let at = clock.elapsed
        let (failure, link) = box.withLock { s -> (CameraLinkFailure?, StubLink?) in
            s.calls.append((at: at, reopening: reopening))
            let failure = s.script.isEmpty ? s.fallback : s.script.removeFirst()
            if failure != nil { return (failure, nil) }
            let link = StubLink(number: s.opened.count + 1, journal: journal)
            s.opened.append(link)
            return (nil, link)
        }
        if let failure { throw failure }
        return link!
    }
}

/// Every phase the session reported, in order, with a way to wait for one.
final class PhaseLog: Sendable {
    private struct State {
        var phases: [WirelessPhase] = []
        var waiters: [(phase: WirelessPhase, times: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func count(of phase: WirelessPhase) -> Int { phases.filter { $0 == phase }.count }
    }

    private final class Store: Sendable {
        let state = Mutex(State())

        func append(_ phase: WirelessPhase) {
            let ready = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.phases.append(phase)
                let snapshot = s
                let due = s.waiters.filter { snapshot.count(of: $0.phase) >= $0.times }
                s.waiters.removeAll { snapshot.count(of: $0.phase) >= $0.times }
                return due.map(\.continuation)
            }
            for continuation in ready { continuation.resume() }
        }
    }

    private let store = Store()
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<WirelessPhase>) {
        let store = self.store
        task = Task {
            for await phase in stream { store.append(phase) }
        }
    }

    deinit { task.cancel() }

    var all: [WirelessPhase] { store.state.withLock { $0.phases } }

    /// Returns once `phase` has been reported `times` times in all (the session starts `idle`, so a leave's `idle` is the
    /// second).
    func waitFor(_ phase: WirelessPhase, times: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = store.state.withLock { s -> Bool in
                if s.count(of: phase) >= times { return true }
                s.waiters.append((phase: phase, times: times, continuation: continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }
}

/// Opens when the clock reaches an instant: a scripted moment registered at once, so a driver can't move past it.
final class Gate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { s -> Bool in
                if s.open { return true }
                s.waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }
}

extension VirtualClock {
    func gate(at offset: Duration) -> Gate {
        let gate = Gate()
        schedule(at: offset) { gate.open() }
        return gate
    }
}

/// One session with every fake, the camera already paired and its Wi-Fi already on (status 2).
final class Rig: Sendable {
    let clock = VirtualClock()
    let journal = Journal()
    let peripheral = PeripheralID(UUID())
    let link: FakeGATTLink
    let connector: ScriptedConnector
    let joiner: FakeJoiner
    let path: FakePath
    let foreground = FakeForeground()
    let handoff: FakeHandoff
    let opener: LinkOpener
    let session: WirelessSession
    let phases: PhaseLog

    init(knownPeripheral: Bool = true) {
        link = FakeGATTLink(clock: clock, initialStatus: 2, peripheral: peripheral)
        connector = ScriptedConnector(clock: clock, [.success(link)])
        joiner = FakeJoiner(clock: clock, journal: journal)
        path = FakePath(clock: clock)
        handoff = FakeHandoff(clock: clock, journal: journal)
        opener = LinkOpener(clock: clock, journal: journal)
        let opener = self.opener
        session = WirelessSession(
            camera: WirelessCamera(peripheral: knownPeripheral ? peripheral : nil),
            connector: connector, joiner: joiner, path: path, foreground: foreground,
            openLink: { (reopening: Bool) async throws(CameraLinkFailure) -> any CameraLink in
                try await opener.open(reopening: reopening)
            },
            clock: clock, handoff: handoff)
        phases = PhaseLog(session.phases)
    }

    /// A second camera link, as the connector would give after a reconnect.
    func anotherLink(status: UInt8 = 2) -> FakeGATTLink {
        FakeGATTLink(clock: clock, initialStatus: status, peripheral: peripheral)
    }

    /// `prepareImport()` with the clock driven until it returns.
    func prepare() async -> Result<any CameraLink, WirelessFailure> {
        let session = self.session
        return await drive(clock) {
            do throws(WirelessFailure) {
                return .success(try await session.prepareImport())
            } catch {
                return .failure(error)
            }
        }
    }
}

func failure(_ result: Result<any CameraLink, WirelessFailure>) -> WirelessFailure? {
    if case .failure(let failure) = result { failure } else { nil }
}

func opened(_ result: Result<any CameraLink, WirelessFailure>) -> StubLink? {
    if case .success(let link) = result { link as? StubLink } else { nil }
}

/// A flag and the clock generation a driver last saw, shared with `VirtualClock.waitUntil`'s predicate.
private final class DriveState: Sendable {
    private let state = Mutex<(done: Bool, generation: Int)>((false, 0))
    var done: Bool { state.withLock { $0.done } }
    func finish() { state.withLock { $0.done = true } }
    var generation: Int { state.withLock { $0.generation } }
    func saw(_ generation: Int) { state.withLock { $0.generation = generation } }
}

/// `driven`, usable more than once on one clock. `VirtualClock.markFinished()` can't be undone, so after a first `driven`
/// a second would return at once and leave its body waiting on a sleeper nobody moves. This driver keeps its own flag and
/// uses `markFinished()` only to wake the clock's waiters. Each round, as in `runUntilFinished`: wait for a sleeper, fire the
/// earliest deadline, wait for the code to react (the woken sleeper gone and a new one parked) or for the body to end.
func drive<T: Sendable>(_ clock: VirtualClock, _ body: @escaping @Sendable () async -> T) async -> T {
    let state = DriveState()
    let task = Task {
        let result = await body()
        state.finish()
        clock.markFinished()
        return result
    }
    while true {
        await clock.waitUntil { sleepers, generation, _ in
            state.saw(generation)
            return sleepers > 0 || state.done
        }
        if state.done { break }
        let before = state.generation
        clock.advanceToNext()
        await clock.waitUntil { _, generation, _ in state.done || generation >= before + 2 }
    }
    return await task.value
}
