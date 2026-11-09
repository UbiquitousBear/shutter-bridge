import CameraTransport
import Foundation
import PTPKit
import Synchronization

/// Waits for a condition on some locked state, woken by the mutations that might make it true. No polling, no wall
/// clock: a test that waits for a condition that never comes hits its suite's time limit.
private struct Waiters<State>: ~Copyable {
    private var list: [(condition: @Sendable (State) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    init() {}

    mutating func add(_ condition: @escaping @Sendable (State) -> Bool, _ c: CheckedContinuation<Void, Never>) {
        list.append((condition, c))
    }

    mutating func due(in state: State) -> [CheckedContinuation<Void, Never>] {
        var due: [CheckedContinuation<Void, Never>] = []
        list.removeAll { waiter in
            guard waiter.condition(state) else { return false }
            due.append(waiter.continuation)
            return true
        }
        return due
    }
}

/// A clock that moves only when a test says so (the ImportEngine tests' manual clock, plus a wait for sleepers so a
/// test advances only once the timer it means is running).
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Snapshot: Sendable {
        var sleepers: Int
    }

    private struct State: ~Copyable {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        var nextID = 0
        var waiters = Waiters<Snapshot>()
        mutating func due() -> [CheckedContinuation<Void, Never>] { waiters.due(in: Snapshot(sleepers: sleepers.count)) }
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// Sleepers waiting now.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { s -> Int in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                enum Next { case resume, cancel, wait }
                let (next, woken) = state.withLock { s -> (Next, [CheckedContinuation<Void, Never>]) in
                    if Task.isCancelled { return (.cancel, []) }
                    if deadline <= s.now { return (.resume, []) }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: c))
                    return (.wait, s.due())
                }
                for w in woken { w.resume() }
                switch next {
                case .resume: c.resume()
                case .cancel: c.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let (c, woken) = state.withLock { s -> (CheckedContinuation<Void, any Error>?, [CheckedContinuation<Void, Never>]) in
                guard let i = s.sleepers.firstIndex(where: { $0.id == id }) else { return (nil, []) }
                let c = s.sleepers.remove(at: i).continuation
                return (c, s.due())
            }
            c?.resume(throwing: CancellationError())
            for w in woken { w.resume() }
        }
    }

    func advance(by duration: Duration) {
        let (due, woken) = state.withLock { s -> ([CheckedContinuation<Void, any Error>], [CheckedContinuation<Void, Never>]) in
            s.now = s.now.advanced(by: duration)
            let now = s.now
            let due = s.sleepers.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline }
            s.sleepers.removeAll { $0.deadline <= now }
            return (due.map(\.continuation), s.due())
        }
        for c in due { c.resume() }
        for w in woken { w.resume() }
    }

    /// Returns once exactly `count` sleepers are waiting.
    func waitForSleepers(_ count: Int) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if s.sleepers.count == count { return true }
                s.waiters.add({ $0.sleepers == count }, c)
                return false
            }
            if ready { c.resume() }
        }
    }
}

/// One scripted TCP connection: the test pushes what the camera sends and reads what the connection sent. Receives
/// return what is queued, at most `readChunk` bytes at a time (to split packets), and wait when nothing is.
final class ScriptedChannel: ByteChannel, Sendable {
    struct Snapshot: Sendable {
        var sentCount: Int
        var receivePending: Bool
        var closed: Bool
    }

    private struct State: ~Copyable {
        var inbound = Data()
        var sent: [Data] = []
        /// Set by the camera hanging up or the link dropping: queued bytes are still delivered, then this is thrown.
        var hangUp: ByteChannelFailure?
        var closed = false
        var pending: (atMost: Int, continuation: CheckedContinuation<Result<Data, ByteChannelFailure>, Never>)?
        var receives = 0
        var waiters = Waiters<Snapshot>()

        var snapshot: Snapshot {
            Snapshot(sentCount: sent.count, receivePending: pending != nil, closed: closed)
        }
    }

    let readChunk: Int
    private let state = Mutex(State())

    init(readChunk: Int = .max) {
        self.readChunk = readChunk
    }

    // MARK: ByteChannel

    func send(_ data: Data) async throws(ByteChannelFailure) {
        let (failure, woken) = state.withLock { s -> (ByteChannelFailure?, [CheckedContinuation<Void, Never>]) in
            if s.closed { return (.closed, []) }
            if let f = s.hangUp { return (f, []) }
            s.sent.append(data)
            return (nil, s.waiters.due(in: s.snapshot))
        }
        for w in woken { w.resume() }
        if let failure { throw failure }
    }

    func receive(atMost: Int) async throws(ByteChannelFailure) -> Data {
        let result = await withCheckedContinuation { (c: CheckedContinuation<Result<Data, ByteChannelFailure>, Never>) in
            let (ready, woken) = state.withLock { s -> (Result<Data, ByteChannelFailure>?, [CheckedContinuation<Void, Never>]) in
                s.receives += 1
                if let r = Self.take(&s, atMost: atMost, chunk: readChunk) { return (r, []) }
                s.pending = (atMost, c)
                return (nil, s.waiters.due(in: s.snapshot))
            }
            for w in woken { w.resume() }
            if let ready { c.resume(returning: ready) }
        }
        return try result.get()
    }

    func close() async {
        let (pending, woken) = state.withLock { s -> (CheckedContinuation<Result<Data, ByteChannelFailure>, Never>?, [CheckedContinuation<Void, Never>]) in
            s.closed = true
            let p = s.pending?.continuation
            s.pending = nil
            return (p, s.waiters.due(in: s.snapshot))
        }
        pending?.resume(returning: .failure(.closed))
        for w in woken { w.resume() }
    }

    // MARK: The camera's side

    /// Queues bytes from the camera.
    func push(_ data: Data) {
        deliver { $0.inbound.append(data) }
    }

    /// Queues whole packets from the camera.
    func push(_ packets: PTPIP.Packet...) {
        push(packets.reduce(into: Data()) { $0.append($1.encode()) })
    }

    /// The camera closes the connection, or the link drops: queued bytes are delivered first.
    func hangUp(_ failure: ByteChannelFailure = .closed) {
        deliver { $0.hangUp = failure }
    }

    // MARK: What the connection did

    /// Everything sent, as packets (each send may hold several).
    var sentPackets: [PTPIP.Packet] {
        var decoder = PTPIPStreamDecoder()
        var packets: [PTPIP.Packet] = []
        var data: (type: PTPIPPacketType, tx: UInt32, bytes: Data)?
        for chunk in state.withLock({ $0.sent }) {
            for event in (try? decoder.feed(chunk)) ?? [] {
                switch event {
                case let .packet(p): packets.append(p)
                case let .dataPacketBegan(type, tx, _): data = (type, tx, Data())
                case let .dataBytes(b): data?.bytes.append(b)
                case .dataPacketEnded:
                    if let d = data {
                        var w = Data()
                        withUnsafeBytes(of: d.tx.littleEndian) { w.append(contentsOf: $0) }
                        packets.append(PTPIP.Packet(type: d.type, payload: w + d.bytes))
                    }
                    data = nil
                }
            }
        }
        return packets
    }

    var sendCount: Int { state.withLock { $0.sent.count } }
    var receiveCount: Int { state.withLock { $0.receives } }
    var isClosed: Bool { state.withLock { $0.closed } }

    func waitForSends(_ count: Int) async { await wait { $0.sentCount >= count } }
    func waitForPendingReceive() async { await wait { $0.receivePending } }
    func waitUntilClosed() async { await wait { $0.closed } }

    // MARK: Private

    private func wait(_ condition: @escaping @Sendable (Snapshot) -> Bool) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if condition(s.snapshot) { return true }
                s.waiters.add(condition, c)
                return false
            }
            if ready { c.resume() }
        }
    }

    private func deliver(_ change: (inout State) -> Void) {
        let (resume, woken) = state.withLock { s -> ((CheckedContinuation<Result<Data, ByteChannelFailure>, Never>, Result<Data, ByteChannelFailure>)?, [CheckedContinuation<Void, Never>]) in
            change(&s)
            var resume: (CheckedContinuation<Result<Data, ByteChannelFailure>, Never>, Result<Data, ByteChannelFailure>)?
            if let p = s.pending, let r = Self.take(&s, atMost: p.atMost, chunk: readChunk) {
                s.pending = nil
                resume = (p.continuation, r)
            }
            return (resume, s.waiters.due(in: s.snapshot))
        }
        if let (c, r) = resume { c.resume(returning: r) }
        for w in woken { w.resume() }
    }

    private static func take(_ s: inout State, atMost: Int, chunk: Int) -> Result<Data, ByteChannelFailure>? {
        if s.closed { return .failure(.closed) }
        if !s.inbound.isEmpty {
            let n = min(atMost, chunk, s.inbound.count)
            let out = Data(s.inbound.prefix(n))
            s.inbound = Data(s.inbound.dropFirst(n))
            return .success(out)
        }
        if let f = s.hangUp { return .failure(f) }
        return nil
    }
}

/// Hands out scripted channels in order, or fails or hangs as scripted. Records each open.
final class ScriptedFactory: ByteChannelFactory, Sendable {
    enum Step: Sendable {
        /// Report these states, then return the channel.
        case channel(ScriptedChannel, states: [ByteChannelState] = [.connecting, .ready])
        /// Report these states, then throw.
        case fail(ByteChannelFailure, states: [ByteChannelState] = [.connecting])
        /// Report these states, then wait until cancelled (then throw `.closed`).
        case hang(states: [ByteChannelState])
    }

    private struct State: ~Copyable {
        var steps: [Step]
        var opened: [(endpoint: PTPIPEndpoint, timeout: Duration)] = []
        var waiters = Waiters<Int>()
    }

    private let state: Mutex<State>

    init(_ steps: [Step]) {
        state = Mutex(State(steps: steps))
    }

    var openCount: Int { state.withLock { $0.opened.count } }
    var opened: [(endpoint: PTPIPEndpoint, timeout: Duration)] { state.withLock { $0.opened } }

    func waitForOpens(_ count: Int) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if s.opened.count >= count { return true }
                s.waiters.add({ $0 >= count }, c)
                return false
            }
            if ready { c.resume() }
        }
    }

    func open(_ endpoint: PTPIPEndpoint, timeout: Duration,
              state report: @escaping @Sendable (ByteChannelState) -> Void) async throws(ByteChannelFailure) -> any ByteChannel {
        let (step, woken) = state.withLock { s -> (Step?, [CheckedContinuation<Void, Never>]) in
            s.opened.append((endpoint, timeout))
            let step = s.steps.isEmpty ? nil : s.steps.removeFirst()
            return (step, s.waiters.due(in: s.opened.count))
        }
        for w in woken { w.resume() }
        switch step {
        case nil:
            throw .refused
        case let .channel(channel, states):
            states.forEach(report)
            return channel
        case let .fail(failure, states):
            states.forEach(report)
            throw failure
        case let .hang(states):
            states.forEach(report)
            let once = Hang()
            await withTaskCancellationHandler {
                await once.wait()
            } onCancel: {
                once.release()
            }
            throw .closed
        }
    }
}

/// A wait that ends when released, before or after it begins.
private final class Hang: Sendable {
    private let state = Mutex<(released: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    func release() {
        let w = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.released = true
            defer { s.waiter = nil }
            return s.waiter
        }
        w?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let go = state.withLock { s -> Bool in
                if s.released { return true }
                s.waiter = c
                return false
            }
            if go { c.resume() }
        }
    }
}

/// Collects data-phase bytes from a sink.
final class Collected: Sendable {
    private let bytes = Mutex(Data())
    func append(_ data: Data) { bytes.withLock { $0.append(data) } }
    var data: Data { bytes.withLock { $0 } }
}
